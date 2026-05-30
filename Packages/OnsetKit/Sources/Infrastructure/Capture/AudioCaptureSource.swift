import AVFoundation
import CoreMedia
import Domain
import Foundation

// MARK: - AudioCaptureSource

/// Infrastructure implementation of `CaptureSource` for microphone capture via AVFoundation.
///
/// Uses an **independent audio-only `AVCaptureSession`** — the microphone is deliberately
/// **not** added to the camera session to avoid slaving the master clock to audio hardware
/// (architecture.md §sync invariant).
///
/// Two clocks: `audioDeviceClock` (`session.synchronizationClock`) is used **only** as the
/// `from:` argument to `clock.convert`; `clock.referenceClock` is the host-time reference
/// reported as `sourceClock`. Callback order: gap-detect → silence fill → convert → emit.
///
/// ## Concurrency / Sendable
///
/// `@unchecked Sendable`: `sink`, `lastBufferEnd`, and `audioDeviceClock` are accessed
/// exclusively on `captureQueue`. All three are written via `captureQueue.sync` barrier
/// (sink before `startRunning`; audioDeviceClock after, still before callbacks can read it)
/// and cleared via `.sync` on stop. `session` and `clock` are write-once.
///
/// ## SampleSink threading contract (#35)
///
/// `captureOutput` calls `sink.receive` **synchronously** on `captureQueue` with no
/// internal buffer. `SampleRouter` (#35) MUST enqueue without blocking — blocking the
/// audio callback will overflow the HAL input buffer (lossless violation).
///
/// ### Device selection seam (#30/#31)
///
/// Defaults to `AVCaptureDevice.default(for: .audio)`. Swap in `configure(_:)` when
/// #30/#31 land.
public final class AudioCaptureSource: NSObject, CaptureSource,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{

    // MARK: - CaptureSource: kind

    public let kind: SourceKind = .audio

    // MARK: - CaptureSource: sourceClock

    /// The injected host-time reference clock. All emitted buffers are pre-converted to this
    /// time base; `audioDeviceClock` is used only internally as the `from:` arg.
    public var sourceClock: CMClock { clock.referenceClock }

    // MARK: - Private state

    /// The injected clock provider; supplies `referenceClock` and `convert(_:from:)`.
    private let clock: any ClockProviding

    /// GCD queue on which AVFoundation delivers audio buffers. All hot-path work and
    /// `sink`/`lastBufferEnd`/`audioDeviceClock` accesses are serialised through this queue.
    private let captureQueue = DispatchQueue(label: "com.app.capture.audio")

    /// The live audio-only `AVCaptureSession`; non-nil after `configure(_:)` succeeds.
    private var session: AVCaptureSession?

    /// The downstream sample sink. Accessed exclusively on `captureQueue`.
    /// Set via `.sync` before `startRunning`; cleared via `.sync` after `stopRunning`.
    private var sink: (any SampleSink)?

    /// The device clock AVFoundation uses to stamp incoming buffers.
    ///
    /// Written via `captureQueue.sync` after `startRunning` succeeds (`synchronizationClock`
    /// is nil before the session runs). The barrier serialises this write with all subsequent
    /// callback reads — TSan-clean happens-before. Falls back to `CMClockGetHostTimeClock()`
    /// on nil (logged as warning; host→host conversion is ≈identity but sync is coincidental).
    /// Init-time default covers the zero-duration window before publication.
    private var audioDeviceClock: CMClock = CMClockGetHostTimeClock()

    /// Observer token for `AVCaptureSession.runtimeErrorNotification`.
    private var runtimeErrorObserver: (any NSObjectProtocol)?

    /// End PTS of the last emitted buffer in device time. `nil` until the first buffer.
    /// Accessed exclusively on `captureQueue`; used by gap-detection.
    private var lastBufferEnd: CMTime?

    /// Max silence fill in seconds. Gaps beyond this are capped (degradation warning logged).
    /// Prevents unbounded `silenceBuffers` materialisation from stalling `captureQueue`
    /// with hundreds of synchronous `sink.receive` calls → HAL overflow (lossless violation).
    private static let maxSilenceFillSeconds: Double = 3.0

    // MARK: - init

    /// - Parameter clock: Session-wide clock; `referenceClock` is `sourceClock`,
    ///   `convert(_:from:)` translates device PTS to host time.
    public init(clock: any ClockProviding) {
        self.clock = clock
    }

    // MARK: - CaptureSource: configure

    /// Builds the audio-only session at 48 kHz.
    /// - Throws: `AudioCaptureError.noDeviceAvailable` / `.sessionInputRejected` / `.sessionOutputRejected`.
    public func configure(_ config: SourceConfiguration) throws {
        // Seam for #30/#31: replace default-mic lookup with DiscoverySession by identifier.
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            throw AudioCaptureError.noDeviceAvailable
        }
        Log.capture.debug("configure: mic=\(micDevice.localizedName, privacy: .public)")

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        // defer ensures commitConfiguration() is always called, even on throws.
        defer { newSession.commitConfiguration() }

        // Audio-only session — no video input. Adding audio to the camera session would
        // slave its master clock to audio hardware (architecture.md §sync invariant).
        let micInput = try AVCaptureDeviceInput(device: micDevice)
        guard newSession.canAddInput(micInput) else {
            throw AudioCaptureError.sessionInputRejected
        }
        newSession.addInput(micInput)

        // Request 48 kHz (architecture mandate). Channel count / bit depth left to
        // AVFoundation; silence buffers derive format from incoming CMFormatDescription.
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.audioSettings = [AVSampleRateKey: 48_000]
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard newSession.canAddOutput(audioOutput) else {
            throw AudioCaptureError.sessionOutputRejected
        }
        newSession.addOutput(audioOutput)

        self.session = newSession
        Log.capture.info(
            "configure: audio session ready mic=\(micDevice.localizedName, privacy: .public)"
        )
    }

    // MARK: - CaptureSource: start

    /// Starts capture; `startRunning()` runs off the cooperative pool via `withCheckedContinuation`.
    /// - Throws: `AudioCaptureError.notConfigured` / `.startFailed`.
    public func start(emittingTo sink: any SampleSink) async throws {
        guard let liveSession = session else {
            throw AudioCaptureError.notConfigured
        }
        guard runtimeErrorObserver == nil else {
            Log.capture.warning("AudioCaptureSource: start called while already running — ignored")
            return
        }

        // Set sink before startRunning (visible to first callback). captureQueue is
        // idle here, so .sync is instantaneous — no deadlock risk.
        captureQueue.sync { self.sink = sink }

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: liveSession,
            queue: nil
        ) { notification in
            let error =
                notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? AudioCaptureError.unknownRuntimeError
            Log.emitSourceFailure(kind: .audio, error: error)
        }

        // Off-pool: startRunning() blocks tens-to-hundreds of ms negotiating Core Audio.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.session?.startRunning()
                cont.resume()
            }
        }

        guard liveSession.isRunning else {
            captureQueue.sync { self.sink = nil }
            if let observer = runtimeErrorObserver {
                NotificationCenter.default.removeObserver(observer)
                runtimeErrorObserver = nil
            }
            throw AudioCaptureError.startFailed
        }

        // Capture device clock AFTER startRunning: `synchronizationClock` is nil before
        // the session runs. Publish via captureQueue.sync — the barrier ensures every
        // subsequent callback read sees the real clock (happens-before, TSan-clean).
        let deviceClock = liveSession.synchronizationClock
        if deviceClock == nil {
            Log.capture.warning(
                "AudioCaptureSource: synchronizationClock nil — host clock fallback; PTS identity"
            )
        }
        let resolvedDeviceClock = deviceClock ?? CMClockGetHostTimeClock()
        captureQueue.sync { self.audioDeviceClock = resolvedDeviceClock }

        Log.capture.debug("start: audioDeviceClock acquired, isRunning=true")
        Log.capture.info("recording.start source=audio")
    }

    // MARK: - CaptureSource: stop

    /// Stops the capture session and releases the sink reference. Idempotent.
    public func stop() async {
        guard session != nil else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.session?.stopRunning()
                cont.resume()
            }
        }

        session = nil

        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }

        // Nil sink + reset gap state. AVFoundation guarantees no callbacks after
        // stopRunning returns, so this .sync is a clean happens-before fence.
        captureQueue.sync {
            self.sink = nil
            self.lastBufferEnd = nil
        }
        Log.capture.info("recording.stop source=audio")
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate (hot path)

    /// Called by AVFoundation on `captureQueue` for every delivered audio buffer.
    ///
    /// Steps: (1) guard sink; (2) gap-detect → insert silence (AC-13); (3) convert
    /// device PTS → host; (4) emit (AC-9). Audio is **never dropped** — lossless guarantee.
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let sink else {
            Log.capture.error(
                "AudioCaptureSource: sink is nil on capture queue — buffer skipped"
            )
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)

        // Gap-detect + silence insertion (AC-13). Happens BEFORE sink/fan-out so both
        // downstream files receive a bit-identical stream. All in device time here.
        if let prevEnd = lastBufferEnd, let desc = formatDesc {
            let rawGap = CMTimeRange(start: prevEnd, end: pts)
            // Cap: prevent unbounded silence materialization (HAL stall → lossless violation).
            let capDuration = CMTime(
                seconds: AudioCaptureSource.maxSilenceFillSeconds,
                preferredTimescale: prevEnd.timescale
            )
            let cappedEnd = CMTimeAdd(prevEnd, capDuration)
            let gapIsCapped = CMTimeCompare(pts, cappedEnd) > 0
            if gapIsCapped {
                let gapDur = rawGap.duration.seconds
                let capMax = AudioCaptureSource.maxSilenceFillSeconds
                Log.capture.warning(
                    "AudioCaptureSource: gap \(gapDur, format: .fixed(precision: 3))s > cap \(capMax)s — capped"
                )
            }
            let effectiveEnd = gapIsCapped ? cappedEnd : pts
            let fillRange = CMTimeRange(start: prevEnd, end: effectiveEnd)

            let silences = AudioCaptureSource.silenceBuffers(
                filling: fillRange,
                referenceDuration: duration,
                formatDescription: desc
            )
            for silence in silences {
                emitBuffer(silence, sink: sink, deviceClock: audioDeviceClock)
            }
        }

        // Update last-end in device time for the next gap-detect cycle.
        lastBufferEnd = CMTimeAdd(pts, duration)

        // Convert real buffer PTS to host time and emit.
        emitBuffer(sampleBuffer, sink: sink, deviceClock: audioDeviceClock)
    }

    /// Converts `buffer` to host-time via `hostStamp` and emits to `sink`.
    /// On failure emits the original buffer (lossless fallback, device-time PTS).
    private func emitBuffer(_ buffer: CMSampleBuffer, sink: any SampleSink, deviceClock: CMClock) {
        if let hostBuf = AudioCaptureSource.hostStamp(buffer, deviceClock: deviceClock, clock: clock) {
            sink.receive(hostBuf, kind: .audio)
        } else {
            // restamp failed — emit original (device-time PTS). This preserves lossless
            // but the PTS is in device-time space, not host-time: possible drift vs. video.
            sink.receive(buffer, kind: .audio)
            Log.capture.error(
                "AudioCaptureSource: hostStamp failed — device-time PTS emitted; possible drift vs. video"
            )
        }
    }
}

// MARK: - Testable pure functions

extension AudioCaptureSource {

    // MARK: Host-stamp seam (AC-9 clock wiring)

    /// Converts `buffer`'s device-time PTS to host time, guards `.isNumeric`, and re-stamps.
    ///
    /// Single conversion seam for both real buffers and silence fills — `from:` is always
    /// `deviceClock`. Returns `nil` on non-numeric converted PTS or `restamp` failure; callers
    /// MUST emit the original buffer as a lossless fallback.
    public static func hostStamp(
        _ buffer: CMSampleBuffer,
        deviceClock: CMClock,
        clock: any ClockProviding
    ) -> CMSampleBuffer? {
        let devicePTS = CMSampleBufferGetPresentationTimeStamp(buffer)
        let hostPTS = clock.convert(devicePTS, from: deviceClock)
        guard hostPTS.isNumeric else {
            Log.capture.error(
                "AudioCaptureSource: clock.convert returned non-numeric PTS; device-time fallback"
            )
            return nil
        }
        return restamp(buffer, pts: hostPTS)
    }

    // MARK: Silence buffer generation

    /// Generates silence buffers to fill `gap`. Each segment ≤ `referenceDuration`; the last
    /// may be shorter. All PTS values are in device time — caller converts before emitting.
    /// - Returns: Zero or more silence `CMSampleBuffer`s in PTS-ascending order.
    public static func silenceBuffers(
        filling gap: CMTimeRange,
        referenceDuration: CMTime,
        formatDescription: CMFormatDescription
    ) -> [CMSampleBuffer] {
        guard gap.duration > .zero, referenceDuration > .zero,
            referenceDuration.isNumeric, gap.start.isNumeric
        else { return [] }

        guard
            let streamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
            )?.pointee
        else {
            Log.capture.error(
                "AudioCaptureSource: CMAudioFormatDescriptionGetStreamBasicDescription nil — gap fill skipped"
            )
            return []
        }

        let bytesPerFrame = Int(streamDesc.mBytesPerFrame)
        let sampleRate = streamDesc.mSampleRate
        guard bytesPerFrame > 0, sampleRate > 0 else {
            Log.capture.error(
                "AudioCaptureSource: invalid ASBD (bytesPerFrame=\(bytesPerFrame)) — gap fill skipped"
            )
            return []
        }

        var silences: [CMSampleBuffer] = []
        var cursor = gap.start
        while CMTimeCompare(cursor, gap.end) < 0 {
            let remaining = CMTimeSubtract(gap.end, cursor)
            let segDur = CMTimeMinimum(referenceDuration, remaining)
            let sampleCount = Int((CMTimeGetSeconds(segDur) * sampleRate).rounded())
            guard sampleCount > 0 else { break }

            if let buf = makeSilenceSegment(
                pts: cursor, sampleCount: sampleCount,
                bytesPerFrame: bytesPerFrame, sampleRate: sampleRate,
                formatDescription: formatDescription
            ) {
                silences.append(buf)
            }
            cursor = CMTimeAdd(cursor, segDur)
        }
        return silences
    }

    /// Builds one silent `CMSampleBuffer` segment. Extracted to keep `silenceBuffers` concise.
    private static func makeSilenceSegment(
        pts: CMTime,
        sampleCount: Int,
        bytesPerFrame: Int,
        sampleRate: Float64,
        formatDescription: CMFormatDescription
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,  // nil → CMBlockBuffer allocates and zero-fills (= PCM silence)
            blockLength: sampleCount * bytesPerFrame,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleCount * bytesPerFrame,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let validBlock = blockBuffer else {
            Log.capture.error(
                "AudioCaptureSource: CMBlockBufferCreateWithMemoryBlock failed \(bbStatus)"
            )
            return nil
        }
        var silenceBuf: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: validBlock,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,  // nil = constant bytes-per-packet (uncompressed PCM)
            sampleBufferOut: &silenceBuf
        )
        if sbStatus != noErr {
            Log.capture.error(
                "AudioCaptureSource: CMAudioSampleBufferCreateReadyWithPacketDescriptions failed \(sbStatus)"
            )
        }
        return silenceBuf
    }

    // MARK: PTS re-stamp

    /// Creates a copy of `buffer` with `pts` as the new presentation timestamp.
    ///
    /// `CMSampleBufferCreateCopyWithNewTiming` allocs a lightweight CM wrapper — no data copy.
    /// Uses `CMSampleBufferGetSampleTimingInfo(at: 0)` for per-sample duration: with
    /// `sampleTimingEntryCount: 1`, CoreMedia treats `duration` as per-sample (not total),
    /// so passing total `N/48000` would be N× too large.
    ///
    /// - Returns: The re-stamped buffer, or `nil` on CoreMedia failure.
    public static func restamp(_ buffer: CMSampleBuffer, pts: CMTime) -> CMSampleBuffer? {
        var perSampleTiming = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(
            buffer, at: 0, timingInfoOut: &perSampleTiming
        )
        let perSampleDuration: CMTime
        if timingStatus == noErr {
            perSampleDuration = perSampleTiming.duration
        } else {
            // Fallback: total duration ÷ sample count. May lose sub-sample precision.
            let numSamples = CMSampleBufferGetNumSamples(buffer)
            let total = CMSampleBufferGetDuration(buffer)
            perSampleDuration =
                (numSamples > 0 && total.isNumeric)
                ? CMTimeMultiplyByRatio(total, multiplier: 1, divisor: Int32(numSamples))
                : total
            Log.capture.error(
                "AudioCaptureSource: GetSampleTimingInfo failed \(timingStatus) — fallback duration"
            )
        }
        var timing = CMSampleTimingInfo(
            duration: perSampleDuration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var outBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &outBuffer
        )
        if status != noErr {
            Log.capture.error(
                "AudioCaptureSource: CMSampleBufferCreateCopyWithNewTiming failed \(status)"
            )
        }
        return status == noErr ? outBuffer : nil
    }
}

// MARK: - Error type

/// Errors thrown by `AudioCaptureSource`.
public enum AudioCaptureError: Error {
    /// `start(emittingTo:)` was called before `configure(_:)`.
    case notConfigured
    /// No audio capture device (microphone) was found on this system.
    case noDeviceAvailable
    /// The `AVCaptureSession` rejected the microphone device input.
    case sessionInputRejected
    /// The `AVCaptureSession` rejected the audio data output.
    case sessionOutputRejected
    /// `startRunning()` returned but `isRunning` is false.
    case startFailed
    /// A runtime error notification was received but carried no `Error` in userInfo.
    case unknownRuntimeError
}
