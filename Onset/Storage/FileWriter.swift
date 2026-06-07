import AVFoundation
import CoreAudio
import CoreMedia
import OSLog

// swiftlint:disable file_length type_body_length
// Rationale: FileWriter is a single-responsibility actor. The extra length comes from its
// complete lifecycle (init / start / append / finish), telemetry task, test seams, and their
// inline doc comments. The telemetry flush task added for cadence telemetry is lifecycle-coupled
// to markFinished() — splitting it to an extension would scatter the cancel coupling.

// MARK: - FileWriter

/// Muxes compressed HEVC video (and optionally AAC audio) into an MP4 file.
///
/// FileWriter is a passthrough video muxer: it receives already-compressed HEVC samples
/// from `VideoEncoder` and writes them directly to the container without re-encoding.
/// Audio (raw PCM microphone) is encoded to AAC by `AVAssetWriter` itself.
///
/// ### Init contract — sourceFormatHint is REQUIRED for MP4 passthrough
///
/// `AVAssetWriterInput(outputSettings: nil)` instructs the input to pass compressed
/// samples through without re-encoding. For non-QuickTime containers (`.mp4`), a non-nil
/// `sourceFormatHint` is REQUIRED — the input cannot infer the media subtype from the first
/// appended sample buffer.
///
/// Empirically verified (probe run, 2026-06-04, macOS 26.5): building the passthrough video
/// input with a `nil` hint and adding it crashes the process at `AVAssetWriter.add(input:)` —
/// **before** `startWriting()` is ever reached — with an uncaught `NSInvalidArgumentException`:
///
///     *** -[AVAssetWriter addInput:] In order to perform passthrough to file type
///         public.mpeg-4, please provide a format hint in the AVAssetWriterInput initializer
///
/// This is a fatal Objective-C exception, not a recoverable `false` return or Swift `throw`,
/// so the nil case cannot be guarded by `FileWriterError.startFailed` — `start()` calls
/// `add()` before `startWriting()`, and the crash happens at `add()`. The hint must therefore
/// be non-optional. The with-hint path was verified to round-trip the encoder's `hvc1` subtype
/// through the muxer unchanged (`FileWriterLiveTests.liveEncode_fileContainsHEVCTrack`).
///
/// Therefore `sourceFormatHint` cannot be `nil` when writing MP4. Callers (#34
/// `RecordingSession`) must:
/// 1. Start `VideoEncoder` and await the first `EncodedSample` from `encodedSamples`.
/// 2. Extract `CMSampleBufferGetFormatDescription(sample.sampleBuffer)`.
/// 3. Construct `FileWriter(outputURL:configuration:includeAudio:sourceFormatHint:)` with
///    that description.
/// 4. Call `appendVideo(_:)` starting from the first sample (raw — no PTS conversion).
///
/// ### PTS contract — append raw, no conversion
/// `start(atSourceTime:)` establishes the timeline origin via `startSession(atSourceTime:)`.
/// `appendVideo` appends `sample.sampleBuffer` **raw** — adding a `PipelineClock.convert()`
/// call here would double-subtract the anchor offset and place samples before session start.
///
/// ### Lifecycle
///   `init` → `start(atSourceTime:)` → `appendVideo` / `appendAudio` → `markFinished()`
///   → `finish()`.
///
/// ### Drop channel
/// `drops` exposes writer-side backpressure events for `DropMonitor` (#35). The stream is
/// intentionally built here even though no consumer exists until #34/#35 — placing it now
/// is deliberate (matches `VideoEncoder`'s pattern) so the type contract is stable.
actor FileWriter {
    // MARK: - Stored state

    private let outputURL: URL
    private let configuration: RecordingConfiguration

    private let assetWriter: AVAssetWriter

    /// Video input seam — injectable for testing (allows simulating not-ready state).
    private var videoSeam: any WriterInputSeam
    /// Audio input seam, nil when `includeAudio` was false.
    private var audioSeam: (any WriterInputSeam)?

    /// Backing `AVAssetWriterInput` for the video track.
    /// Kept separately so `start()` can call `add()` on it and tests can inspect settings.
    private let rawVideoInput: AVAssetWriterInput
    /// Backing `AVAssetWriterInput` for the audio track; nil when audio is disabled.
    private let rawAudioInput: AVAssetWriterInput?

    /// Set once an `append()` returns `false` — a hard, terminal writer fault, NOT recoverable
    /// backpressure. Post-fault `isReadyForMoreMediaData` stays `false`, so further `appendVideo`
    /// calls would otherwise be misclassified as `.encoderBackpressureDrops`; the top-guards in
    /// `appendVideo`/`appendAudio` short-circuit them and keep the failure logged exactly once.
    private var isFaulted = false

    // MARK: - Diagnostics (#105)

    /// Source time passed to `startSession(atSourceTime:)` — captured for first-append logging (#105).
    private var sessionSourceTime: CMTime = .invalid
    /// One-shot: true until the first successful audio append has been logged (#105).
    private var firstAudioAppendPending = true
    /// One-shot: true until the first successful video append has been logged (#105).
    private var firstVideoAppendPending = true

    // MARK: - Output streams

    /// Writer-side backpressure drop events for `DropMonitor` (#35).
    ///
    /// Emitted when `videoSeam.isReadyForMoreMediaData == false` at the moment
    /// `appendVideo(_:)` is called. Audio drops are NOT surfaced here (spec does not
    /// include audio in the three tracked `Degraded` counters).
    ///
    /// Intentional build-now: nobody consumes `FileWriter.drops` until #34 wires
    /// `DropMonitor`. Placing the stream here keeps the type contract stable across waves.
    nonisolated let drops: AsyncStream<DropEvent>
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    /// Hard-fault signal — emits once when the writer faults, then finishes (#105 fail-fast).
    ///
    /// Finished (without yielding) in `markFinished()` and `deinit` so consumers never hang.
    nonisolated let faults: AsyncStream<Void>
    private let faultsContinuation: AsyncStream<Void>.Continuation

    // MARK: - Logger

    nonisolated let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "FileWriter"
    )

    // MARK: - Telemetry

    /// Per-stage cadence accumulator. Flushed every ~1 s on the telemetry tick.
    private var aggregator: StageRateAggregator

    /// ~1 s periodic flush task started in `start(atSourceTime:)`, cancelled in `markFinished()`.
    private var telemetryTask: Task<Void, Never>?

    /// Lane label used in telemetry lines ("screen" / "camera" / "writer").
    private let label: String

    // MARK: - Init

    /// Creates a FileWriter for one recording stream.
    ///
    /// - Parameters:
    ///   - outputURL: Destination file URL (parent directory must exist).
    ///   - configuration: Recording policy scalars (fragment interval, audio settings).
    ///   - includeAudio: Whether to mux a microphone audio track.
    ///   - sourceFormatHint: The `CMFormatDescription` of the compressed HEVC stream.
    ///     **Required for MP4 passthrough** — see type-level doc. Obtain from the first
    ///     `EncodedSample.sampleBuffer` produced by `VideoEncoder`.
    ///   - label: Lane label emitted in telemetry lines ("screen", "camera"). Default "writer"
    ///     is safe for standalone / test use; `LiveWriterFactory` overrides it per pipeline kind.
    ///   - nominalFps: The pipeline's target frame rate for telemetry. Default 0 when unknown.
    /// - Throws: `CocoaError` if `AVAssetWriter(url:fileType:)` fails (disk full, bad path).
    init( // swiftlint:disable:this function_body_length
        outputURL: URL,
        configuration: RecordingConfiguration,
        includeAudio: Bool,
        sourceFormatHint: CMFormatDescription,
        label: String = "writer",
        nominalFps: Int = 0
    ) throws {
        self.outputURL = outputURL
        self.configuration = configuration

        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)

        // movieFragmentInterval MUST be set before startWriting() — setting it after is a
        // documented no-op. It controls how frequently the MP4 container is finalised
        // in-stream; shorter = less data lost on crash (AC-10). 600-timescale gives exact
        // integer CMTime values for whole-second intervals.
        let standardTimescale: CMTimeScale = 600
        writer.movieFragmentInterval = CMTime(
            seconds: configuration.movieFragmentInterval,
            preferredTimescale: standardTimescale
        )

        // Video input: outputSettings nil → passthrough (no re-encode). The sourceFormatHint
        // is required for non-QuickTime containers; without it AVAssetWriter crashes at
        // add(input:) with an uncaught NSInvalidArgumentException for MP4 (see type-level doc
        // for the empirical evidence). The hvc1 tag is preserved from the encoder's
        // CMFormatDescription — do not set it manually.
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
        )
        videoInput.expectsMediaDataInRealTime = true
        self.rawVideoInput = videoInput
        self.videoSeam = LiveWriterInput(videoInput)

        // Audio input (mono mic AAC). kAudioFormatMPEG4AAC encodes raw PCM from the
        // microphone track; AVAssetWriter owns the encode step.
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: configuration.audioSampleRate,
                AVNumberOfChannelsKey: configuration.audioChannelCount,
                AVEncoderBitRateKey: configuration.audioBitrate,
            ]
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings
            )
            audioInput.expectsMediaDataInRealTime = true
            self.rawAudioInput = audioInput
            self.audioSeam = LiveWriterInput(audioInput)
        } else {
            self.rawAudioInput = nil
            self.audioSeam = nil
        }

        self.assetWriter = writer
        self.label = label
        self.aggregator = StageRateAggregator(lane: label, stage: .writer, nominalFps: nominalFps)

        let (stream, continuation) = AsyncStream.makeStream(of: DropEvent.self)
        self.drops = stream
        self.dropsContinuation = continuation

        let (faultStream, faultContinuation) = AsyncStream.makeStream(of: Void.self)
        self.faults = faultStream
        self.faultsContinuation = faultContinuation
    }

    deinit {
        // Best-effort safety net: if the writer is released without `markFinished()`, finish
        // both continuations so consumers' `for await` loops don't hang indefinitely.
        // Mirrors `DropMonitor.deinit`. `markFinished()` is the primary, ordered terminator;
        // double-finishing a continuation is a documented no-op.
        self.dropsContinuation.finish()
        self.faultsContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Prepares the writer and starts the recording session at the given source time.
    ///
    /// - `add(input:)` is called for each input before `startWriting()`.
    /// - `movieFragmentInterval` must already be set (done in `init`) before this call.
    /// - `startSession(atSourceTime:)` establishes the timeline origin: all appended
    ///   `CMSampleBuffer` PTS values are interpreted relative to this anchor.
    ///
    /// After a successful start, the output file is locked to owner-read/write (`0o600`).
    ///
    /// - Parameter sourceTime: The session timeline origin — pass the first sample's `ptsHostTime`.
    /// - Throws: `FileWriterError.startFailed` if `startWriting()` returns `false`.
    func start(atSourceTime sourceTime: CMTime) throws {
        self.assetWriter.add(self.rawVideoInput)
        if let audio = self.rawAudioInput {
            self.assetWriter.add(audio)
        }

        guard self.assetWriter.startWriting() else {
            let underlying = self.assetWriter.error
            self.logger.error(
                "AVAssetWriter.startWriting() failed: \(String(describing: underlying))"
            )
            throw FileWriterError.startFailed(underlying)
        }

        self.assetWriter.startSession(atSourceTime: sourceTime)
        self.sessionSourceTime = sourceTime // captured for first-append diagnostics (#105)

        // Restrict the file to owner-read/write after AVAssetWriter creates it.
        try RecordingOutput.setOwnerOnly(file: self.outputURL)

        self.startTelemetryTask()
        self.logger.info("FileWriter started: \(self.outputURL.lastPathComponent)")
    }

    // MARK: - Append

    /// Appends a compressed HEVC sample to the video track.
    ///
    /// The sample buffer is appended raw — `startSession(atSourceTime:)` in `start()` sets
    /// the timeline origin, so NO timestamp conversion is applied here. Adding a conversion
    /// would double-subtract and push samples before the session start (PTS landmine).
    ///
    /// If the input is not ready (disk/writer backpressure), the sample is dropped and a
    /// `DropEvent(.encoderBackpressureDrops)` is emitted on `drops`.
    ///
    /// ### Drop tradeoff
    /// Dropping a compressed HEVC sample tears the GOP — the decoder glitches until the next
    /// keyframe, but the file remains valid and playable.
    /// `expectsMediaDataInRealTime = true` means "drop, don't block" (AC-10 / AC-4 both hold:
    /// the file is valid/playable; the decoder may show a brief artifact after the drop).
    ///
    /// - Parameter sample: An `EncodedSample` produced by `VideoEncoder`.
    func appendVideo(_ sample: EncodedSample) {
        // Post-fault short-circuit: prevents a hard failure from masquerading as backpressure
        // and keeps the error logged once (see `isFaulted`).
        guard !self.isFaulted else { return }

        let nowSeconds = CMTimeGetSeconds(PipelineClock.currentHostTime())
        guard self.videoSeam.isReadyForMoreMediaData else {
            // Writer/disk backpressure — distinct from encoder backpressure (which originates
            // in VideoEncoder before the sample is compressed). Both map to
            // .encoderBackpressureDrops in the spec's three-counter model because the spec
            // does not distinguish writer-side from encoder-side drops at the DropMonitor
            // level; the log message disambiguates for diagnostics (AC-4 / spec §163).
            // Per-frame backpressure detail is stripped from release at .debug; DropMonitor owns
            // the aggregate .warning/Degraded signal, and the DropEvent already carries the data.
            self.aggregator.openEpisode(nowSeconds: nowSeconds)
            self.logger.debug(
                "FileWriter video input not ready (backpressure) — dropping sample (writer/disk)"
            )
            self.dropsContinuation.yield(
                DropEvent(
                    reason: .encoderBackpressureDrops,
                    count: 1,
                    detectedAt: sample.ptsHostTime
                )
            )
            return
        }

        // append() returns false only after the writer faulted (input is ready here, so not-ready
        // is excluded) — a hard failure, NOT backpressure, so it must NOT feed the drop counter.
        let videoPTS = CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)
        let videoDTS = CMSampleBufferGetDecodeTimeStamp(sample.sampleBuffer)
        guard self.videoSeam.append(sample.sampleBuffer) else {
            // diagnostic for #105: include pts/dts the writer rejected
            self.logger.error(
                // swiftlint:disable:next line_length
                "FileWriter video append rejected at pts=\(Self.secStr(videoPTS), privacy: .public)s dts=\(Self.secStr(videoDTS), privacy: .public)s"
            )
            self.markFaulted(track: "video")
            return
        }

        // diagnostic for #105: one-shot first-append pts/dts to confirm session timeline alignment
        if self.firstVideoAppendPending {
            self.firstVideoAppendPending = false
            self.logger.notice(
                // swiftlint:disable:next line_length
                "first video append: pts=\(Self.secStr(videoPTS), privacy: .public)s dts=\(Self.secStr(videoDTS), privacy: .public)s"
            )
        }

        // Successful append: close any active not-ready episode and count the frame.
        self.aggregator.closeEpisode(nowSeconds: nowSeconds)
        self.aggregator.recordFresh()
    }

    /// Appends a raw PCM audio buffer to the audio track (encoded to AAC by `AVAssetWriter`).
    ///
    /// Audio drops are logged but NOT emitted on `drops` — the spec's three `Degraded`
    /// counters cover video-pipeline drops only.
    ///
    /// - Parameter buffer: A raw PCM `CMSampleBuffer` from the microphone.
    func appendAudio(_ buffer: CMSampleBuffer) {
        // Shared fault gate: once the writer faults, both tracks are dead (see `isFaulted`).
        guard !self.isFaulted else { return }
        guard let audio = self.audioSeam else { return }
        guard audio.isReadyForMoreMediaData else {
            self.logger.warning("FileWriter audio input not ready — skipping audio buffer")
            return
        }
        // append() returns false only after the writer faulted — a hard failure, not backpressure.
        // Audio is NOT surfaced on any drop counter (spec tracks video only), but is logged once.
        let audioPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
        let appended = audio.append(buffer)

        guard appended else {
            // diagnostic for #105: include the PTS that the writer rejected
            self.logger.error(
                "FileWriter audio append rejected at pts=\(Self.secStr(audioPTS), privacy: .public)s"
            )
            self.markFaulted(track: "audio")
            return
        }
        // diagnostic for #105: one-shot first-append format summary to identify USB mic mismatches
        if self.firstAudioAppendPending {
            self.firstAudioAppendPending = false
            let info = Self.audioFormatInfo(from: buffer)
            let fmtTag = Self.fourCC(info?.formatID ?? 0)
            self.logger.notice(
                // swiftlint:disable:next line_length
                "first audio append: rate=\(info?.sampleRate ?? 0, privacy: .public) ch=\(info?.channelCount ?? 0, privacy: .public) fmt=\(fmtTag, privacy: .public) pts=\(Self.secStr(audioPTS), privacy: .public)s t0=\(Self.secStr(self.sessionSourceTime), privacy: .public)s"
            )
        }
    }

    // MARK: - Telemetry task

    /// Spawns the ~1 s telemetry flush task.
    private func startTelemetryTask() {
        self.telemetryTask = Task { [weak self] in
            let clock = ContinuousClock()
            var lastInstant = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let now = clock.now
                let elapsedSeconds = (now - lastInstant).totalSeconds
                lastInstant = now
                // Hop into the actor's isolation to mutate the aggregator.
                await self.flushTelemetry(elapsedSeconds: elapsedSeconds)
            }
        }
    }

    private func flushTelemetry(elapsedSeconds: Double) {
        if let line = self.aggregator.flush(elapsedSeconds: elapsedSeconds) {
            telemetryLogger.notice("\(line, privacy: .public)")
        } else {
            self.logger.debug("flushTelemetry: skipped (elapsed ≤ 0)")
        }
    }

    /// Records a hard writer failure (an `append()` returned `false`) and logs it once —
    /// the `isFaulted` top-guards ensure this runs only on the faulting transition.
    private func markFaulted(track: String) {
        self.isFaulted = true
        let status = self.assetWriter.status.rawValue
        let underlying = String(describing: self.assetWriter.error)
        // .public on all interpolations so the NSError details survive privacy redaction (#105).
        self.logger.error(
            // swiftlint:disable:next line_length
            "FileWriter \(track, privacy: .public) append failed (writer faulted) — status \(status, privacy: .public): \(underlying, privacy: .public)"
        )
        // Signal the fault immediately so DualFileOutputStage can stop the recording without
        // waiting for the user to press Stop (#105 fail-fast). Yield then finish: one value
        // tells observers the fault occurred; finish prevents hangs if nobody consumes it yet.
        self.faultsContinuation.yield(())
        self.faultsContinuation.finish()
    }

    // MARK: - Helpers

    private struct AudioFormatInfo {
        let sampleRate: Int
        let channelCount: UInt32
        let formatID: UInt32
    }

    /// Extracts sample rate, channel count, and format ID from a `CMSampleBuffer`'s ASBD.
    /// Returns `nil` when no format description is available — diagnostic for #105.
    private static func audioFormatInfo(from buffer: CMSampleBuffer) -> AudioFormatInfo? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(buffer) else { return nil }
        guard let asbd = unsafe CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            return nil
        }
        return AudioFormatInfo(
            sampleRate: Int(unsafe asbd.pointee.mSampleRate),
            channelCount: unsafe asbd.pointee.mChannelsPerFrame,
            formatID: unsafe asbd.pointee.mFormatID
        )
    }

    /// Formats a `CMTime` seconds value to three decimal places without `String(format:)`,
    /// which trips `SWIFT_STRICT_MEMORY_SAFETY` — diagnostic for #105.
    private static func secStr(_ time: CMTime) -> String {
        // Guard against invalid/indefinite CMTime (.invalid, .indefinite) whose
        // CMTimeGetSeconds returns NaN/Inf — Int(NaN) crashes at runtime.
        guard time.isValid, time.isNumeric else { return "invalid" }
        // Round to 3 decimal places using integer arithmetic (same pattern as StageRateAggregator).
        // swiftlint:disable no_magic_numbers
        let scaled = Int((CMTimeGetSeconds(time) * 1000).rounded())
        let whole = scaled / 1000
        let frac = abs(scaled % 1000)
        let fracPadded = frac < 10 ? "00\(frac)" : frac < 100 ? "0\(frac)" : "\(frac)"
        // swiftlint:enable no_magic_numbers
        return "\(whole).\(fracPadded)"
    }

    /// Renders a CoreAudio FourCC `UInt32` as a 4-character ASCII tag (e.g. `lpcm`).
    /// Falls back to hex if any byte is outside printable ASCII — diagnostic for #105.
    /// `internal` (not `private`) so tests can reuse it directly.
    static func fourCC(_ code: UInt32) -> String {
        // swiftlint:disable no_magic_numbers
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            return String(code, radix: 16)
        }
        return String(bytes: bytes, encoding: .ascii) ?? String(code, radix: 16)
        // swiftlint:enable no_magic_numbers
    }

    // MARK: - Finish

    /// Marks all inputs as finished, signalling no more data will be appended.
    ///
    /// Must be called before `finish()`. After this, `append*` calls are no-ops on a
    /// real `AVAssetWriterInput`.
    func markFinished() {
        self.telemetryTask?.cancel()
        self.telemetryTask = nil
        self.rawVideoInput.markAsFinished()
        self.rawAudioInput?.markAsFinished()
        self.dropsContinuation.finish()
        // Safety finish: prevents `for await writer.faults` from hanging if the writer
        // completed normally (no fault). Double-finish is a documented no-op.
        self.faultsContinuation.finish()
        self.logger.info("FileWriter inputs marked as finished")
    }

    /// Finalises the file and returns the write outcome.
    ///
    /// Suspends until `AVAssetWriter.finishWriting()` completes (potentially several
    /// seconds for large files).
    ///
    /// - Returns: A `FinishResult` enum case reflecting the terminal `AVAssetWriter.Status`.
    func finish() async -> FinishResult {
        await self.assetWriter.finishWriting()

        let url = self.outputURL
        let result: FinishResult
        switch self.assetWriter.status {
        case .completed:
            result = .completed(url: url)
            self.logger.info("FileWriter finished successfully: \(url.lastPathComponent)")

        case .cancelled:
            result = .cancelled(url: url)
            self.logger.info("FileWriter cancelled: \(url.lastPathComponent)")

        case .failed:
            let error = self.assetWriter.error ?? FileWriterError.finishFailed(nil)
            result = .failed(url: url, error: error)
            self.logger.error(
                "FileWriter finished with .failed: \(String(describing: self.assetWriter.error))"
            )

        default:
            // .unknown / .writing: should not occur after finishWriting() returns, but mapped
            // for exhaustiveness so the enum stays closed over AVAssetWriter.Status.
            let underlyingError = self.assetWriter.error ?? FileWriterError.finishFailed(nil)
            result = .failed(url: url, error: underlyingError)
            let writerStatus = self.assetWriter.status.rawValue
            let writerError = String(describing: self.assetWriter.error)
            self.logger.error(
                "FileWriter finished in unexpected status \(writerStatus): \(writerError)"
            )
        }

        return result
    }

    // MARK: - Test accessors

    /// Whether the video input was configured in passthrough mode (`outputSettings == nil`).
    ///
    /// Tests assert this is `true` to confirm no re-encode path is active.
    var isVideoPassthroughForTesting: Bool {
        self.rawVideoInput.outputSettings == nil
    }

    /// Whether an audio input was created (i.e. `includeAudio` was `true`).
    var hasAudioInputForTesting: Bool {
        self.rawAudioInput != nil
    }

    /// Whether a hard writer failure has been recorded (an `append()` returned `false`).
    var isFaultedForTesting: Bool {
        self.isFaulted
    }

    /// AAC output settings used by the audio input.
    ///
    /// Returns typed scalars so only `Sendable` values cross the actor boundary.
    /// `[String: Any]` is not `Sendable` and cannot be returned directly.
    var audioSettingsForTesting: AudioSettingsSnapshot? {
        guard let settings = self.rawAudioInput?.outputSettings else { return nil }
        let formatID = settings[AVFormatIDKey] as? UInt32
        let sampleRate = settings[AVSampleRateKey] as? Double
        let channels = settings[AVNumberOfChannelsKey] as? Int
        let bitrate = settings[AVEncoderBitRateKey] as? Int
        return AudioSettingsSnapshot(
            formatID: formatID,
            sampleRate: sampleRate,
            channelCount: channels,
            bitrate: bitrate
        )
    }

    /// The configured `movieFragmentInterval` on the underlying `AVAssetWriter`.
    var movieFragmentIntervalForTesting: CMTime {
        self.assetWriter.movieFragmentInterval
    }

    /// Replaces the video seam with a test stub (e.g. to simulate not-ready state).
    func injectVideoInputForTesting(_ seam: some WriterInputSeam) {
        self.videoSeam = seam
    }

    /// Replaces the audio seam with a test stub (e.g. to simulate not-ready state).
    ///
    /// Only effective when the writer was initialised with `includeAudio: true`.
    func injectAudioInputForTesting(_ seam: some WriterInputSeam) {
        self.audioSeam = seam
    }

    /// Finishes the `drops` stream without calling `markFinished()` or `finish()`.
    ///
    /// Used by tests that verify drop emission in isolation — they do not need a full
    /// write lifecycle (startWriting → finishWriting) and calling `finish()` without
    /// prior `startWriting()` crashes `AVAssetWriter`.
    func finishDropsForTesting() {
        self.dropsContinuation.finish()
    }
}

// swiftlint:enable type_body_length
