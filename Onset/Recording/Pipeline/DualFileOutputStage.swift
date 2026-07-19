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

    /// Called once when ALL currently-live writers have faulted — triggers immediate stop (#105).
    ///
    /// Invoked from fault-observer tasks started at writer creation. The callback is expected
    /// to call `RecordingSession.stop()`, which is idempotent (memoised via `stopTask`).
    private let onAllWritersFaulted: @Sendable () async -> Void

    /// Called when ONE writer faults while the other pipeline is still live (#197 live UI seam).
    ///
    /// The callback is expected to stop and finalise the faulted pipeline's source + encoder, then
    /// signal the `RecordingCoordinator` so the recording window immediately shows the source as
    /// stopped. The surviving pipeline is NOT touched — it continues recording.
    private let onWriterFaulted: @Sendable (RecordingPipelineKind) async -> Void

    /// Observer tasks started per writer to watch for faults. Cancelled in `finishAll()` and
    /// `finalizePipeline(_:)` once the writer is no longer live — prevents a late delivery on a
    /// gracefully stopped writer from firing the callback erroneously.
    private var faultObserverTasks: [RecordingPipelineKind: Task<Void, Never>] = [:]

    /// Pipelines whose writers have signalled a hard fault via `writer.faults`.
    ///
    /// Maintained by fault-observer tasks inside this actor's isolation. When this set
    /// covers all live (non-early-finalised) writers, `onAllWritersFaulted` is called.
    private var faultedWriterKinds: Set<RecordingPipelineKind> = []

    // MARK: - Per-pipeline writer state

    /// Lifecycle state of a single pipeline writer.
    ///
    /// Replaces the `FinishResult?` nullable: `nil` mapped to "not yet finalised" was stringly typed —
    /// any code path forgetting the nil-check would silently route audio/video into a sealed writer.
    /// With `WriterState`, the compiler enforces exhaustive handling via `switch`.
    private enum WriterState {
        /// The writer is open and accepting audio/video.
        case live
        /// The writer has been finalised (either early via AC-12 or in `finishAll`).
        case finalized(FinishResult)
    }

    /// A writer plus its lifecycle state, tracked so an early-finalised pipeline (AC-12) still
    /// contributes its `FinishResult` to the final `RecordingResult`.
    private struct PipelineWriter {
        let writer: any WriterControlling
        /// Lifecycle state: `.live` while accepting input; `.finalized` once sealed.
        var state: WriterState = .live

        /// `true` while the writer is open and accepting audio/video.
        ///
        /// A faulted writer MUST remain `isLive` (i.e. `recordFault` must never flip `state` to
        /// `.finalized`): `finishAll`/`finalizePipeline` skip `markFinished()` on non-live writers,
        /// and `markFinished()` is what seals the `drops` stream. If a fault left `drops` open,
        /// `DropMonitor.stop()` — which drains those streams — would hang on session stop (#202).
        var isLive: Bool {
            if case .live = self.state {
                return true
            }
            return false
        }
    }

    private var writers: [RecordingPipelineKind: PipelineWriter] = [:]

    /// The pipelines that are expected to produce a writer. The pending-audio buffer is held until
    /// every expected writer has been created (so each gets the identical replay), then released.
    private let expectedKinds: Set<RecordingPipelineKind>

    /// Expected pipelines that were revoked BEFORE ever creating a writer (#201). Subtracted from
    /// `expectedKinds` when deciding "all writers created", so pending audio destined for a pipeline
    /// that will never exist is released instead of buffered forever. `expectedKinds` is a `let`
    /// (immutable plan); this mutable set records which of those plans turned out dead at runtime.
    private var deadKinds: Set<RecordingPipelineKind> = []

    /// Already-retimed mic buffers awaiting the first writer of each pipeline (drop-oldest cap).
    private var pendingAudio: [RetimedAudioBuffer] = []

    /// Cumulative count of pending-audio buffers dropped on overflow (observability, FIX-2).
    private(set) var pendingAudioDropped = 0

    // MARK: - Audio format canary (#105)

    /// Format description of the most recent audio buffer — for mid-stream format-change detection.
    ///
    /// The canary log below fires when this changes: after the Commit-1 LPCM fix the format must
    /// be stable for the entire session. A change here means the fix regressed or a new device
    /// sends formats outside the pinned LPCM spec. Permanent — a format change is a class-#105
    /// regression and must not silently pass.
    private var audioPrevFmtDesc: CMFormatDescription?

    // MARK: - Init

    /// - Parameters:
    ///   - sessionT0: The session timeline origin (AC-7). Reused verbatim for every writer.
    ///   - expectedPipelines: The pipelines that will run (from `RecordingStartPlan`). Determines
    ///     when the pending-audio buffer can be released.
    ///   - includeAudio: Whether a mic audio track is muxed into the file(s).
    ///   - writerFactory: Builds writers lazily from `(kind, sourceFormatHint, includeAudio)`.
    ///   - onWriterCreated: Registers a new writer's `drops` channel with `DropMonitor`.
    ///   - onAllWritersFaulted: Called when every live writer has faulted — expected to stop the
    ///     session immediately.
    ///   - onWriterFaulted: Called when ONE writer faults while the other pipeline is still live —
    ///     expected to stop + finalise the faulted pipeline and signal the coordinator (#197).
    init(
        sessionT0: CMTime,
        expectedPipelines: Set<RecordingPipelineKind>,
        includeAudio: Bool,
        writerFactory: any WriterFactory,
        onWriterCreated: @escaping @Sendable (any WriterControlling) async -> Void,
        onAllWritersFaulted: @escaping @Sendable () async -> Void,
        onWriterFaulted: @escaping @Sendable (RecordingPipelineKind) async -> Void = { _ in }
    ) {
        self.sessionT0 = sessionT0
        self.expectedKinds = expectedPipelines
        self.includeAudio = includeAudio
        self.writerFactory = writerFactory
        self.onWriterCreated = onWriterCreated
        self.onAllWritersFaulted = onAllWritersFaulted
        self.onWriterFaulted = onWriterFaulted
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
            guard existing.isLive else { return }
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

        let pipelineWriter = PipelineWriter(writer: writer)
        self.writers[kind] = pipelineWriter

        // Register the writer's backpressure channel with DropMonitor (AC-8/AC-9) — without this a
        // lazily-created writer's drops would be silently unobserved.
        await self.onWriterCreated(writer)

        // Start a fault-observer task for this writer (#105 fail-fast). The task reads the
        // writer's `faults` stream (at most one value) and calls back into this actor to record
        // the fault and — when all live writers have faulted — trigger an immediate stop. The task
        // is cancelled in `finalizePipeline` / `finishAll` so a graceful stop does not fire it.
        let faultsStream = writer.faults // capture nonisolated property before the actor hop
        let faultTask = Task { [weak self] in
            for await _ in faultsStream {
                await self?.recordFault(for: kind)
                break // at-most-once: the stream yields exactly one value then finishes
            }
        }
        self.faultObserverTasks[kind] = faultTask

        await self.drainPendingAudio(into: writer)
        self.releasePendingIfAllWritersCreated()

        self.logger.info("Created \(String(describing: kind)) writer")
        return pipelineWriter
    }

    /// Records that `kind`'s writer has faulted and fires the appropriate callback.
    ///
    /// - When ALL live writers have faulted: calls `onAllWritersFaulted` (existing #105 path).
    /// - When ONE writer faults and the other is still live: calls `onWriterFaulted(kind)` so the
    ///   faulted pipeline is stopped and the coordinator gets a live UI update (#197).
    ///
    /// Called exclusively from the per-writer fault-observer `Task` — runs on this actor.
    /// Writers not yet created (lazy — no video frame yet) are not considered live and don't
    /// block the callback.
    ///
    /// **Re-entrancy:** `onWriterFaulted` awaits back into `RecordingSession`, which calls
    /// `stage.finalizePipeline(kind)`. That re-enters this actor only after the current `await`
    /// suspends, so there is no deadlock. `finalizePipeline` cancels
    /// `faultObserverTasks[kind]` — harmless because the observer task has already passed its
    /// `break` and is about to return.
    private func recordFault(for kind: RecordingPipelineKind) async {
        self.faultedWriterKinds.insert(kind)

        let liveKinds = Set(self.writers.filter(\.value.isLive).keys)
        guard !liveKinds.isEmpty else { return }

        if liveKinds.isSubset(of: self.faultedWriterKinds) {
            self.logger.error(
                "All live writers faulted — stopping recording immediately (#105)"
            )
            await self.onAllWritersFaulted()
        } else {
            self.logger.error(
                "\(String(describing: kind), privacy: .public) writer faulted; other pipeline still live (#197)"
            )
            await self.onWriterFaulted(kind)
        }
    }

    // MARK: - Audio routing (#33 fan-out + retiming)

    /// Retimes one mic sample to absolute host-time ONCE, then fans the SAME buffer reference into
    /// every live writer. If a writer does not yet exist, the retimed buffer is buffered for replay.
    func routeAudio( // swiftlint:disable:this function_body_length
        _ sample: AudioSample
    ) async {
        let buf = sample.sampleBuffer
        let curFmt = CMSampleBufferGetFormatDescription(buf)

        guard self.includeAudio else { return }

        // Permanent canary: after the Commit-1 LPCM fix the audio format must not change
        // mid-stream. A change means the fix regressed or a new device sends variable formats.
        // Placed after the includeAudio guard: when audio is disabled there is no writer to
        // fault, so the comparison is irrelevant and skipped entirely.
        // `unsafe`: CMAudioFormatDescriptionGetStreamBasicDescription returns UnsafePointer;
        // SWIFT_STRICT_MEMORY_SAFETY = YES requires the annotation at call sites (#105 pattern).
        let fmtChanged = if let prev = self.audioPrevFmtDesc, let cur = curFmt {
            !CMFormatDescriptionEqual(cur, otherFormatDescription: prev)
        } else {
            false
        }
        if fmtChanged, let prevFmt = self.audioPrevFmtDesc, let curFmt {
            var prevRate = -1
            var prevCh = -1
            var prevBits = -1
            var prevFlags = "?"
            var prevBpf = -1
            if let prevDesc = unsafe CMAudioFormatDescriptionGetStreamBasicDescription(prevFmt) {
                prevRate = unsafe Int(prevDesc.pointee.mSampleRate)
                prevCh = unsafe Int(prevDesc.pointee.mChannelsPerFrame)
                prevBits = unsafe Int(prevDesc.pointee.mBitsPerChannel)
                prevFlags = Self.hexFlags(unsafe prevDesc.pointee.mFormatFlags)
                prevBpf = unsafe Int(prevDesc.pointee.mBytesPerFrame)
            }
            var curRate = -1
            var curCh = -1
            var curBits = -1
            var curFlags = "?"
            var curBpf = -1
            if let curDesc = unsafe CMAudioFormatDescriptionGetStreamBasicDescription(curFmt) {
                curRate = unsafe Int(curDesc.pointee.mSampleRate)
                curCh = unsafe Int(curDesc.pointee.mChannelsPerFrame)
                curBits = unsafe Int(curDesc.pointee.mBitsPerChannel)
                curFlags = Self.hexFlags(unsafe curDesc.pointee.mFormatFlags)
                curBpf = unsafe Int(curDesc.pointee.mBytesPerFrame)
            }
            // Mid-stream audio format change: should never happen with the pinned LPCM capture
            // settings (CameraSource.audioOutputSettings). If this fires it is a regression of
            // the class-#105 bug and will cause AVAssetWriterInput to fault with -12737.
            // .error: any format change after the fix is a regression — must not be filtered out.
            self.logger.error(
                // swiftlint:disable:next line_length
                "Audio format changed mid-stream (#105 regression): prev rate=\(prevRate, privacy: .public) ch=\(prevCh, privacy: .public) bits=\(prevBits, privacy: .public) flags=\(prevFlags, privacy: .public) bpf=\(prevBpf, privacy: .public) → cur rate=\(curRate, privacy: .public) ch=\(curCh, privacy: .public) bits=\(curBits, privacy: .public) flags=\(curFlags, privacy: .public) bpf=\(curBpf, privacy: .public)"
            )
        }
        // Update baseline only when curFmt is non-nil: a nil format description (degenerate
        // buffer) must not reset the baseline and mask the next real format change.
        if let curFmt {
            self.audioPrevFmtDesc = curFmt
        }

        guard let retimed = self.retime(sample) else {
            // Retiming failed (degenerate buffer) — drop this sample rather than write a
            // mis-timed one. Logged inside `retime`.
            return
        }

        let carrier = RetimedAudioBuffer(buffer: retimed)

        guard self.writers.contains(where: \.value.isLive) else {
            self.bufferPendingAudio(carrier)
            return
        }

        // Same retimed buffer reference handed to every writer (carrier wraps one CMSampleBuffer —
        // retain, no second copy). Each writer actor serialises its own appendAudio behind its
        // readiness gate.
        for (_, pipelineWriter) in self.writers where pipelineWriter.isLive {
            await pipelineWriter.writer.appendAudio(carrier)
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
            // Throttle the warning (#201): a never-finalised static pipeline drops ~47 buffers/s,
            // which spammed one warning per sample for the whole session. Log only the FIRST drop
            // and then every `maxPendingAudioBuffers`-th drop; the cumulative `pendingAudioDropped`
            // count is carried in every line so no information is lost between throttled logs.
            let cap = Self.maxPendingAudioBuffers
            if self.pendingAudioDropped == 1 || self.pendingAudioDropped.isMultiple(of: cap) {
                self.logger.warning(
                    "Dropping oldest pending-audio buffer (cap=\(cap), total dropped: \(self.pendingAudioDropped))"
                )
            }
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
        // Effective expected set excludes pipelines revoked before any writer (#201): a dead
        // pipeline will never produce a writer, so pending audio must not wait on it forever.
        // When the effective set is empty (every expected pipeline died before a writer existed),
        // `allSatisfy` is vacuously true — pending audio is released rather than buffered forever.
        self.expectedKinds.subtracting(self.deadKinds).allSatisfy { self.writers[$0] != nil }
    }

    // MARK: - Finalize

    /// Finalises ONE pipeline (AC-12): marks its writer finished, finishes it, records the result,
    /// and removes it from the fan-out set so no further audio/video is routed to it. The other
    /// pipeline keeps recording.
    ///
    /// When the pipeline never produced a writer (e.g. a camera revoked before its first frame, or
    /// a static screen that sent no frames before the revoke), it is marked dead (#201): it is
    /// excluded from the effective expected set so any pending audio held for it is released instead
    /// of buffered forever. No-op if the pipeline was already finalised (writer present, not live).
    func finalizePipeline(_ kind: RecordingPipelineKind) async {
        guard let existing = self.writers[kind] else {
            // Never-created revoke (#201): record the pipeline as dead and release pending audio if
            // every surviving expected writer now exists. The pending list has already been drained
            // into each survivor at THEIR creation, so releasing only stops the unbounded buffering.
            self.deadKinds.insert(kind)
            self.releasePendingIfAllWritersCreated()
            return
        }
        // Writer exists but is not live → already finalised: still a no-op, and it does not block
        // `allWritersCreated()` (its entry stays in `writers`, so it counts as created).
        guard existing.isLive else {
            return
        }
        var pipelineWriter = existing
        // Cancel the fault-observer task before markFinished() so the faults stream finishing
        // (via markFinished → faultsContinuation.finish) does not trigger onAllWritersFaulted
        // on a gracefully stopped pipeline.
        self.faultObserverTasks[kind]?.cancel()
        self.faultObserverTasks[kind] = nil

        await pipelineWriter.writer.markFinished()
        let result = await pipelineWriter.writer.finish()
        pipelineWriter.state = .finalized(result)
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
        // Cancel all fault-observer tasks before marking writers finished. markFinished()
        // calls faultsContinuation.finish(), which would otherwise make the observer task
        // fire on a graceful stop — producing a spurious onAllWritersFaulted call.
        self.faultObserverTasks.values.forEach { $0.cancel() }
        self.faultObserverTasks.removeAll()

        // Seal every still-open writer's inputs before finishing.
        for (kind, pipelineWriter) in self.writers where pipelineWriter.isLive {
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
        if let screen {
            results[.screen] = screen
        }
        if let camera {
            results[.camera] = camera
        }
        return results
    }

    /// Finishes one pipeline's writer if it is open, or returns its already-captured result.
    private func finishIfOpen(_ kind: RecordingPipelineKind) async -> FinishResult? {
        guard let pipelineWriter = self.writers[kind] else { return nil }
        if case let .finalized(existing) = pipelineWriter.state {
            return existing
        }
        let result = await pipelineWriter.writer.finish()
        var updated = pipelineWriter
        updated.state = .finalized(result)
        self.writers[kind] = updated
        if case let .failed(url, error) = result {
            self.logger.error(
                "Finish \(String(describing: kind)) writer FAILED — url=\(url.lastPathComponent) error=\(error)"
            )
        }
        return result
    }

    // MARK: - Private helpers

    /// Formats a `UInt32` format-flags field as a zero-padded 8-digit lowercase hex string,
    /// e.g. `0x0000000c`. Uses radix arithmetic (no Foundation/CVarArg) consistent with the
    /// `String(_:radix:)` pattern used elsewhere in the codebase.
    private static func hexFlags(_ flags: UInt32) -> String {
        // swiftlint:disable no_magic_numbers
        // 16: hex radix; 8: digits in a 32-bit hex word (UInt32 max = 0xFFFFFFFF).
        let hex = String(flags, radix: 16, uppercase: false)
        return "0x" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
        // swiftlint:enable no_magic_numbers
    }
}

// swiftlint:enable type_body_length
// file_length stays disabled through EOF: re-enabling a whole-file rule before the last line
// would re-trigger on the total count (same pattern as FileWriter).
