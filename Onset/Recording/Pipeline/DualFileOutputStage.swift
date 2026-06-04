import CoreMedia
import OSLog

// type_body_length is disabled file-wide: the lazy-writer / pending-audio / fan-out /
// per-pipeline-finalize responsibilities are one cohesive state machine sharing the `writers` /
// `pendingAudio` state; splitting it across extensions would scatter that invariant for no
// readability gain (same rationale `FileWriter` documents for its `file_length` disable).
// swiftlint:disable type_body_length file_length

// MARK: - DualFileOutputStage

/// Owns the two `FileWriter`s and fans the microphone audio into both (#33), keeping both files
/// aligned on the single session timeline (#34 / AC-7).
///
/// ### Responsibilities
/// - **Lazy writer creation.** A writer needs the `CMFormatDescription` from its pipeline's first
///   `EncodedSample`, so it is built on that first sample, then started with the verbatim session
///   T0 (`startSession(atSourceTime: t0)` — NEVER `.zero`, NEVER first-sample PTS). T0 is captured
///   once by `RecordingSession` and passed in at init; it is reused no matter when the writer
///   object is constructed.
/// - **Audio fan-out + retiming (#33).** Each mic `CMSampleBuffer` is retimed ONCE to absolute
///   host-time (see `retime`) and the SAME retimed buffer reference is handed to BOTH writers.
/// - **Pending-audio buffering.** Audio that arrives before a writer exists is buffered (already
///   retimed) and drained into each writer at creation (replay), so a late-created writer still
///   receives identical early audio.
/// - **Per-pipeline finalize.** AC-12 finalises one pipeline while the other keeps recording.
///
/// `actor`: serialises all mutation. Each `FileWriter` is itself an actor serialising its own
/// `appendAudio` behind its `isReadyForMoreMediaData` gate — there is no shared append.
actor DualFileOutputStage {
    // MARK: - Constants

    /// Upper bound on buffered pending-audio samples before a writer exists.
    ///
    /// Drop-oldest on overflow. Sized for the worst realistic gap between session start and the
    /// first `EncodedSample`: a static screen sends no frames, so the screen writer can be created
    /// late; at 48 kHz / ~1024-frame mic packets that is ~47 packets/s, so 256 covers ~5 s of
    /// pre-writer audio. Beyond that the OLDEST retimed buffers are dropped — the late writer's
    /// audio track then simply starts a little later, the file stays valid.
    private static let maxPendingAudioBuffers = 256

    // MARK: - Logger

    nonisolated let logger = Logger(
        subsystem: "dev.androidbroadcast.Onset",
        category: "DualFileOutputStage"
    )

    // MARK: - Dependencies

    /// The session timeline origin (AC-7). Captured once by `RecordingSession.start()`; every
    /// writer's `startSession(atSourceTime:)` receives this verbatim.
    /// The session timeline origin (AC-7); named `sessionT0` (not `t0`) to satisfy the
    /// identifier-name minimum length while preserving the "T0" meaning from the spec.
    private let sessionT0: CMTime
    private let writerFactory: any WriterFactory
    private let includeAudio: Bool

    /// Called once per writer at creation so its `drops` channel is registered with `DropMonitor`.
    private let onWriterCreated: @Sendable (any WriterControlling) async -> Void

    // MARK: - Per-pipeline writer state

    /// A writer plus its terminal status, tracked so an early-finalised pipeline (AC-12) still
    /// contributes its `FinishResult` to the final `RecordingResult`.
    private struct PipelineWriter {
        let writer: any WriterControlling
        /// Set when the writer has been finalised early (AC-12). When non-nil the writer is no
        /// longer in the fan-out set and must not receive further audio/video.
        var finishResult: FinishResult?
    }

    private var writers: [RecordingPipelineKind: PipelineWriter] = [:]

    /// The pipelines that are expected to produce a writer. The pending-audio buffer is held until
    /// every expected writer has been created (so each gets the identical replay), then released.
    private let expectedKinds: Set<RecordingPipelineKind>

    /// Already-retimed mic buffers awaiting the first writer of each pipeline (drop-oldest cap).
    private var pendingAudio: [RetimedAudioBuffer] = []

    /// Cumulative count of pending-audio buffers dropped on overflow (observability, FIX-2).
    private(set) var pendingAudioDropped = 0

    // MARK: - Init

    /// - Parameters:
    ///   - sessionT0: The session timeline origin (AC-7). Reused verbatim for every writer.
    ///   - expectedPipelines: The pipelines that will run (from `RecordingStartPlan`). Determines
    ///     when the pending-audio buffer can be released.
    ///   - includeAudio: Whether a mic audio track is muxed into the file(s).
    ///   - writerFactory: Builds writers lazily from `(kind, sourceFormatHint, includeAudio)`.
    ///   - onWriterCreated: Registers a new writer's `drops` channel with `DropMonitor`.
    init(
        sessionT0: CMTime,
        expectedPipelines: Set<RecordingPipelineKind>,
        includeAudio: Bool,
        writerFactory: any WriterFactory,
        onWriterCreated: @escaping @Sendable (any WriterControlling) async -> Void
    ) {
        self.sessionT0 = sessionT0
        self.expectedKinds = expectedPipelines
        self.includeAudio = includeAudio
        self.writerFactory = writerFactory
        self.onWriterCreated = onWriterCreated
    }

    // MARK: - Video routing

    /// Routes one `EncodedSample` to its pipeline's writer, creating the writer lazily on the first
    /// sample (it needs the sample's `CMFormatDescription`).
    ///
    /// Routing is isolated per pipeline: a screen sample never reaches the camera writer or vice
    /// versa — the writer is selected by `kind`.
    func routeVideo(_ sample: EncodedSample, from kind: RecordingPipelineKind) async {
        let pipelineWriter: PipelineWriter
        if let existing = self.writers[kind] {
            // An early-finalised writer (AC-12) drops further video silently — its file is sealed.
            guard existing.finishResult == nil else { return }
            pipelineWriter = existing
        } else {
            guard let created = await self.createWriter(for: kind, firstSample: sample) else {
                return
            }
            pipelineWriter = created
        }

        await pipelineWriter.writer.appendVideo(sample)
    }

    /// Builds, starts (at the verbatim T0), registers, and drains-pending into a new writer.
    ///
    /// Returns `nil` if writer construction or start fails — the failure is logged and that
    /// pipeline produces no file; the other pipeline is unaffected.
    private func createWriter(
        for kind: RecordingPipelineKind,
        firstSample: EncodedSample
    ) async
    -> PipelineWriter? {
        guard let hint = CMSampleBufferGetFormatDescription(firstSample.sampleBuffer) else {
            self.logger.error("First \(String(describing: kind)) sample lacks a format description")
            return nil
        }

        let writer: any WriterControlling
        do {
            writer = try self.writerFactory.makeWriter(
                kind: kind,
                sourceFormatHint: hint,
                includeAudio: self.includeAudio
            )
            // AC-7: the writer's session origin is the verbatim session T0 captured at session
            // start — NOT this first sample's PTS and NOT .zero. Both files share this one epoch
            // so their internal timelines cannot diverge by the first-frame arrival delta.
            try await writer.start(atSourceTime: self.sessionT0)
        } catch {
            self.logger.error("Failed to create/start \(String(describing: kind)) writer: \(error)")
            return nil
        }

        let pipelineWriter = PipelineWriter(writer: writer, finishResult: nil)
        self.writers[kind] = pipelineWriter

        // Register the writer's backpressure channel with DropMonitor (AC-8/AC-9) — without this a
        // lazily-created writer's drops would be silently unobserved.
        await self.onWriterCreated(writer)

        await self.drainPendingAudio(into: writer)
        self.releasePendingIfAllWritersCreated()

        self.logger.info("Created \(String(describing: kind)) writer")
        return pipelineWriter
    }

    // MARK: - Audio routing (#33 fan-out + retiming)

    /// Retimes one mic sample to absolute host-time ONCE, then fans the SAME buffer reference into
    /// every live writer. If a writer does not yet exist, the retimed buffer is buffered for replay.
    func routeAudio(_ sample: AudioSample) async {
        guard self.includeAudio else { return }

        guard let retimed = self.retime(sample) else {
            // Retiming failed (degenerate buffer) — drop this sample rather than write a
            // mis-timed one. Logged inside `retime`.
            return
        }

        let carrier = RetimedAudioBuffer(buffer: retimed)

        let liveWriters = self.liveWriters()
        if liveWriters.isEmpty {
            self.bufferPendingAudio(carrier)
            return
        }

        // Same retimed buffer reference handed to every writer (carrier wraps one CMSampleBuffer —
        // retain, no second copy). Each writer actor serialises its own appendAudio behind its
        // readiness gate.
        for writer in liveWriters {
            await writer.appendAudio(carrier)
        }

        // If not every expected writer exists yet, the just-created-late writer must still receive
        // this sample on creation — so keep buffering until all writers exist (drained on creation).
        if !self.allWritersCreated() {
            self.bufferPendingAudio(carrier)
        }
    }

    /// Produces a copy of the mic buffer with timestamps shifted into the absolute host-time domain
    /// the video timeline lives in (#33).
    ///
    /// ### Why retiming exists (history)
    /// `AudioSample.ptsHostTime` already carries the buffer's absolute host-clock first-sample time.
    /// The raw `CMSampleBuffer` from `AVCaptureAudioDataOutput`, however, is stamped on the capture
    /// device's own clock, NOT the host clock — appending it raw would place audio on a different
    /// timeline than video (whose `EncodedSample` PTS are already absolute host-time, anchored at
    /// T0). `AudioSample.ptsHostTime` exists precisely so this stage rebases the buffer once, here.
    /// Video appends raw under `startSession(atSourceTime: T0)`; audio must land in the SAME domain,
    /// so the new first-entry PTS becomes `ptsHostTime` (NOT a T0-relative or zero rebase).
    ///
    /// `delta = ptsHostTime − originalFirstPTS`; every timing entry's PTS (and DTS, when valid) is
    /// offset by `delta`. Per-sample DURATION is preserved unchanged — audio buffers are
    /// multi-sample and collapsing to a single timing entry would corrupt sub-buffer timing.
    ///
    /// Body length is over the soft limit by design: reading the timing array, offsetting each
    /// entry, and recreating the buffer is one indivisible CoreMedia transaction (#33) that reads
    /// poorly when split across helpers — the two CM out-pointer calls must share the same array.
    private func retime( // swiftlint:disable:this function_body_length
        _ sample: AudioSample
    )
    -> CMSampleBuffer? {
        let buffer = sample.sampleBuffer
        let originalFirstPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard originalFirstPTS.isValid else {
            self.logger.error("Audio buffer has invalid PTS — cannot retime, dropping")
            return nil
        }

        // newPTS = originalPTS + delta, so the FIRST entry's new PTS equals ptsHostTime exactly.
        let delta = CMTimeSubtract(sample.ptsHostTime, originalFirstPTS)

        // Read the original per-sample timing array. One entry may describe all samples (uniform
        // duration); allocate exactly the entry count CoreMedia reports — single call, no
        // ArrayTooSmall two-pass dance.
        let sampleCount = CMSampleBufferGetNumSamples(buffer)
        guard sampleCount > 0 else {
            self.logger.error("Audio buffer reports 0 samples — cannot retime, dropping")
            return nil
        }

        let emptyTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var timingArray = [CMSampleTimingInfo](repeating: emptyTiming, count: sampleCount)
        var entriesNeeded: CMItemCount = 0
        // `unsafe`: CoreMedia fills the caller-allocated array via an out-pointer under
        // SWIFT_STRICT_MEMORY_SAFETY = YES. The array is stack-local and sized to `sampleCount`;
        // we only read it back. (Same pattern as the CF pointer reads in `EncodedSampleSink`.)
        let getStatus = unsafe CMSampleBufferGetSampleTimingInfoArray(
            buffer,
            entryCount: sampleCount,
            arrayToFill: &timingArray,
            entriesNeededOut: &entriesNeeded
        )
        guard getStatus == noErr else {
            self.logger.error("CMSampleBufferGetSampleTimingInfoArray failed: \(getStatus) — dropping audio")
            return nil
        }

        // CoreMedia may collapse to a single entry that applies to all samples; only the populated
        // prefix (`entriesNeeded`) is valid.
        let validCount = max(1, min(Int(entriesNeeded), timingArray.count))
        for index in 0..<validCount {
            timingArray[index].presentationTimeStamp = CMTimeAdd(
                timingArray[index].presentationTimeStamp,
                delta
            )
            // Offset DTS only when it is genuinely set; an invalid (kCMTimeInvalid) DTS means
            // "presentation order" and must stay invalid — duration is left untouched.
            if timingArray[index].decodeTimeStamp.isValid {
                timingArray[index].decodeTimeStamp = CMTimeAdd(
                    timingArray[index].decodeTimeStamp,
                    delta
                )
            }
        }

        var retimedBuffer: CMSampleBuffer?
        // `unsafe`: passes the timing array as a const pointer to CoreMedia, which copies it (per the
        // header: "All parameters are copied; on return, the caller can release them"). The pointer
        // does not escape the call; `withUnsafeBufferPointer` bounds its lifetime to this closure.
        let createStatus = unsafe timingArray.withUnsafeBufferPointer { pointer -> OSStatus in
            unsafe CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: buffer,
                sampleTimingEntryCount: validCount,
                sampleTimingArray: pointer.baseAddress,
                sampleBufferOut: &retimedBuffer
            )
        }
        guard createStatus == noErr, let retimedBuffer else {
            self.logger.error("CMSampleBufferCreateCopyWithNewTiming failed: \(createStatus) — dropping audio")
            return nil
        }
        return retimedBuffer
    }

    // MARK: - Pending-audio buffer

    /// Appends a retimed buffer to the pending list, dropping the OLDEST on overflow (bounded cap).
    private func bufferPendingAudio(_ carrier: RetimedAudioBuffer) {
        if self.pendingAudio.count >= Self.maxPendingAudioBuffers {
            // Drop-oldest: a static screen produces no frames, so its writer is created late and
            // the cap can be hit before it exists — the earliest mic audio is then sacrificed and
            // the late writer's audio track simply starts later. Documented edge (AC-7 replay).
            self.pendingAudioDropped += 1
            let cap = Self.maxPendingAudioBuffers
            self.logger.warning(
                "Dropping oldest pending-audio buffer (cap=\(cap), total dropped: \(self.pendingAudioDropped))"
            )
            self.pendingAudio.removeFirst()
        }
        self.pendingAudio.append(carrier)
    }

    /// Replays every pending retimed buffer into a freshly-created writer (identical early audio).
    private func drainPendingAudio(into writer: any WriterControlling) async {
        for carrier in self.pendingAudio {
            await writer.appendAudio(carrier)
        }
    }

    /// Releases the pending list once every expected writer exists (each has now been drained).
    private func releasePendingIfAllWritersCreated() {
        guard self.allWritersCreated() else { return }
        self.pendingAudio.removeAll()
    }

    private func allWritersCreated() -> Bool {
        self.expectedKinds.allSatisfy { self.writers[$0] != nil }
    }

    /// The writers currently eligible to receive media (created and not early-finalised).
    private func liveWriters() -> [any WriterControlling] {
        self.writers.values.compactMap { $0.finishResult == nil ? $0.writer : nil }
    }

    // MARK: - Finalize

    /// Finalises ONE pipeline (AC-12): marks its writer finished, finishes it, records the result,
    /// and removes it from the fan-out set so no further audio/video is routed to it. The other
    /// pipeline keeps recording.
    ///
    /// No-op if the pipeline never produced a writer (e.g. a static screen that sent no frames
    /// before the revoke) or was already finalised.
    func finalizePipeline(_ kind: RecordingPipelineKind) async {
        guard var pipelineWriter = self.writers[kind], pipelineWriter.finishResult == nil else {
            return
        }
        await pipelineWriter.writer.markFinished()
        let result = await pipelineWriter.writer.finish()
        pipelineWriter.finishResult = result
        self.writers[kind] = pipelineWriter
        if case let .failed(url, error) = result {
            let name = url.lastPathComponent
            self.logger.error(
                "Finalise \(String(describing: kind)) pipeline (revoke) FAILED — url=\(name) error=\(error)"
            )
        } else {
            self.logger.info("Finalised \(String(describing: kind)) pipeline early (revoke)")
        }
    }

    // MARK: - Stop

    /// Finalises ALL remaining pipelines in parallel and returns each pipeline's `FinishResult`.
    ///
    /// AC-9 independence: each writer is finished with its own `async let` so one writer ending in
    /// `.failed` does not prevent the other from completing. Already-finalised pipelines (AC-12)
    /// keep the result captured at finalize time.
    ///
    /// `markFinished()` is called on every still-open writer first (so all inputs are sealed),
    /// then both `finish()` calls run concurrently.
    func finishAll() async -> [RecordingPipelineKind: FinishResult] {
        // Seal every still-open writer's inputs before finishing.
        for (kind, pipelineWriter) in self.writers where pipelineWriter.finishResult == nil {
            await pipelineWriter.writer.markFinished()
            self.logger.info("Marked \(String(describing: kind)) writer finished")
        }

        // Finish open writers in parallel (independent — one .failed must not fail the other).
        async let screenResult = self.finishIfOpen(.screen)
        async let cameraResult = self.finishIfOpen(.camera)
        let screen = await screenResult
        let camera = await cameraResult

        var results: [RecordingPipelineKind: FinishResult] = [:]
        // Prefer the early-finalised result when present; otherwise the just-finished one.
        if let screen { results[.screen] = screen }
        if let camera { results[.camera] = camera }
        return results
    }

    /// Finishes one pipeline's writer if it is open, or returns its already-captured result.
    private func finishIfOpen(_ kind: RecordingPipelineKind) async -> FinishResult? {
        guard let pipelineWriter = self.writers[kind] else { return nil }
        if let existing = pipelineWriter.finishResult {
            return existing
        }
        let result = await pipelineWriter.writer.finish()
        var updated = pipelineWriter
        updated.finishResult = result
        self.writers[kind] = updated
        if case let .failed(url, error) = result {
            self.logger.error(
                "Finish \(String(describing: kind)) writer FAILED — url=\(url.lastPathComponent) error=\(error)"
            )
        }
        return result
    }
}

// swiftlint:enable type_body_length
// file_length stays disabled through EOF: re-enabling a whole-file rule before the last line
// would re-trigger on the total count (same pattern as FileWriter).
