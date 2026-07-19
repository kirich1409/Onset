import CoreMedia
import CoreVideo
import os
import ScreenCaptureKit

// file_length is disabled: the telemetry flush task added in the cadence-telemetry change brings
// ScreenSource over 400 lines. The extra length is inline documentation + the task; splitting
// the telemetry into a separate file would scatter the lifecycle-cancel coupling (stop /
// handleTerminalStop cancel the task). The actor + shim are genuinely cohesive here.
// swiftlint:disable file_length

// MARK: - FrameAction

/// The pipeline decision for a single SCStream sample.
///
/// Extracted as a testable, `nonisolated` type so the classification logic can be
/// exercised in unit tests without any SCStream or actor machinery.
nonisolated enum FrameAction {
    /// The frame carries new pixel content — process and forward downstream.
    case process

    /// The frame is a static-screen idle tick with no new content — skip silently.
    ///
    /// `.idle`, `.blank`, `.started`, `.stopped`, and `.suspended` indicate the display
    /// has not changed. These are NOT drops; no `DropEvent` is emitted.
    case skipStatic
}

// MARK: - Testable pure helpers

/// Classifies a `SCFrameStatus` value into a pipeline action.
///
/// Only `.complete` carries new pixel data. All other statuses indicate no new frame
/// content; skip them without emitting a drop event.
nonisolated func classifyFrameStatus(_ status: SCFrameStatus) -> FrameAction {
    switch status {
    case .complete:
        .process

    case .idle, .blank, .started, .stopped, .suspended:
        // Static-screen or lifecycle ticks — not pipeline drops. Skip without a DropEvent.
        .skipStatic

    @unknown default:
        // Future SDK additions: treat conservatively as static to avoid phantom frames.
        .skipStatic
    }
}

/// Returns a `DropEvent` when `yieldResult` indicates the frame was dropped due to
/// backpressure overflow, or `nil` when the frame was enqueued or the stream is terminated.
///
/// Extracted as a testable `nonisolated` function so backpressure logic can be exercised
/// in unit tests without live SCStream or actor machinery.
nonisolated func backpressureDropEvent(
    for yieldResult: AsyncStream<VideoFrame>.Continuation.YieldResult,
    pts: CMTime
)
-> DropEvent? {
    guard case .dropped = yieldResult else { return nil }
    return DropEvent(reason: .captureBackpressureDrops, source: .captureScreen, count: 1, detectedAt: pts)
}

/// Returns `true` when `frameHostTime >= sessionStart`.
nonisolated func shouldKeepFrame(frameHostTime: CMTime, sessionStart: CMTime) -> Bool {
    CMTimeCompare(frameHostTime, sessionStart) >= 0
}

/// Returns `.displayDisconnected` when `displayPresent` is `false`, otherwise
/// `.sourceInterrupted(reason:)`. Extracted as a pure `nonisolated` helper so
/// the classification can be unit-tested without SCShareableContent or actor machinery.
nonisolated func terminalStopEvent(displayPresent: Bool, reason: String) -> SourceEvent {
    displayPresent ? .sourceInterrupted(reason: reason) : .displayDisconnected
}

// MARK: - Private logger

/// Logger is `Sendable`; `nonisolated let` avoids a `@MainActor` hop under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated private let screenSourceLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "ScreenSource"
)

/// Builds the SCContentFilter for a display, excluding all Onset windows by app identity so the
/// on-demand recording window (#244) never appears in captured video. Falls back to no exclusion
/// if Onset's own `SCRunningApplication` is absent from shareable content — defensive; should not
/// happen in practice, but the SCShareableContent query may race at startup.
nonisolated private func makeScreenContentFilter(
    display: SCDisplay,
    onsetApp: SCRunningApplication?
)
-> SCContentFilter {
    guard let onsetApp else {
        screenSourceLogger.warning("Onset app not in SCShareableContent — skipping app exclusion filter")
        return SCContentFilter(display: display, excludingWindows: [])
    }
    return SCContentFilter(display: display, excludingApplications: [onsetApp], exceptingWindows: [])
}

// MARK: - CaptureState

/// Lifecycle state of a `ScreenSource` actor.
///
/// Replaces two independent optionals (`stream?` + `outputShim?`) to eliminate
/// representable invalid intermediate states. Transitioning `.idle → .starting`
/// synchronously before the first `await` in `start()` closes the actor-reentrancy window.
private enum CaptureState {
    case idle
    case starting
    case running(stream: SCStream, shim: StreamOutputShim)
    case stopped
}

// MARK: - ScreenSource

/// Actor that captures a single display via ScreenCaptureKit and emits `VideoFrame`s.
///
/// The `frames` stream uses `.bufferingNewest(4)` — deliberately shallower than SCStream's
/// `queueDepth` (8) so pool buffers return to SCKit sooner under consumer backpressure.
/// Hotplug: `stream(_:didStopWithError:)` checks SCShareableContent and emits
/// `.displayDisconnected` or `.sourceInterrupted`, then finishes all streams.
/// ScreenSource has no auto-restart in MVP — any stop-with-error is terminal.
actor ScreenSource: VideoFrameSource {
    // MARK: - Constants

    /// Buffer depth for `frames`. Lower than SCStream `queueDepth` (8) to release pool
    /// buffers back to SCKit sooner under consumer backpressure.
    private static let framesBufferDepth = 4

    /// Buffer depth for `drops`. Kept at 8 (≥ SCStream queueDepth) so drop records
    /// are not lost even when the consumer is behind. Decoupled from `framesBufferDepth`.
    private static let dropsBufferDepth = 8

    /// Buffer depth for `events`. 4 slots: headroom for #34 teardown races.
    private static let eventsBufferDepth = 4

    // MARK: - Protocol streams (nonisolated let — no actor hop for subscribers)

    nonisolated let frames: AsyncStream<VideoFrame>
    nonisolated let events: AsyncStream<SourceEvent>
    nonisolated let drops: AsyncStream<DropEvent>

    // MARK: - Private state

    private let plan: ResolvedRecordingPlan
    private let config: RecordingConfiguration
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation
    private let eventsContinuation: AsyncStream<SourceEvent>.Continuation
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation
    private let sampleHandlerQueue = DispatchQueue(
        label: "dev.androidbroadcast.Onset.ScreenSource.sampleHandler",
        qos: .userInteractive
    )
    private var captureState: CaptureState = .idle

    // MARK: - Telemetry

    /// Lock shared with `StreamOutputShim` so the shim (running on `sampleHandlerQueue`) and this
    /// actor's flush tick can both safely access the same `StageRateAggregator` struct.
    private let captureRateLock: OSAllocatedUnfairLock<StageRateAggregator>

    /// ~1 s periodic flush task started after a successful capture start, cancelled in `stop()`.
    private var captureTelemetryTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a `ScreenSource` for the display described in `plan`.
    ///
    /// All three `AsyncStream`s are created here so callers can subscribe before
    /// `start(anchoredTo:)` is called without missing any events.
    init(plan: ResolvedRecordingPlan, config: RecordingConfiguration) {
        self.plan = plan
        self.config = config
        let (frames, framesContinuation) = AsyncStream.makeStream(
            of: VideoFrame.self,
            bufferingPolicy: .bufferingNewest(Self.framesBufferDepth)
        )
        self.frames = frames
        self.framesContinuation = framesContinuation

        let (events, eventsContinuation) = AsyncStream.makeStream(
            of: SourceEvent.self,
            bufferingPolicy: .bufferingNewest(Self.eventsBufferDepth)
        )
        self.events = events
        self.eventsContinuation = eventsContinuation

        let (drops, dropsContinuation) = AsyncStream.makeStream(
            of: DropEvent.self,
            bufferingPolicy: .bufferingNewest(Self.dropsBufferDepth)
        )
        self.drops = drops
        self.dropsContinuation = dropsContinuation

        self.captureRateLock = OSAllocatedUnfairLock(
            initialState: StageRateAggregator(lane: "screen", stage: .capture, nominalFps: plan.screenFps)
        )
    }

    // MARK: - VideoFrameSource

    /// Starts display capture anchored to `anchor`.
    ///
    /// `.idle → .starting` is set synchronously before the first `await` so a racing
    /// second invocation sees `.starting` and returns immediately.
    ///
    /// - Throws: `RecordingError.displayDiscoveryFailed` or `.captureSetupFailed`.
    func start(anchoredTo anchor: HostTimeAnchor) async throws {
        guard case .idle = self.captureState else {
            screenSourceLogger.info("start() called in non-idle state — ignoring")
            return
        }
        self.captureState = .starting

        let sessionStart = anchor.anchorTime
        let onTerminalStop: @Sendable (any Error)
            async -> Void = { [weak self] error in
                await self?.handleTerminalStop(error: error)
            }

        let scDisplay: SCDisplay
        let onsetApp: SCRunningApplication?
        do {
            (scDisplay, onsetApp) = try await self.discoverDisplay()
        } catch {
            self.captureState = .idle
            throw error
        }

        let shim = self.makeShim(sessionStart: sessionStart, onTerminalStop: onTerminalStop)
        let captureStarted: Bool
        do {
            captureStarted = try await self.startSCStream(display: scDisplay, onsetApp: onsetApp, shim: shim)
        } catch {
            self.captureState = .idle
            throw error
        }
        if captureStarted {
            self.startCaptureTelemetryTask()
        }
    }

    private func discoverDisplay() async throws -> (SCDisplay, SCRunningApplication?) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            screenSourceLogger.error("SCShareableContent.current failed: \(error)")
            throw RecordingError.displayDiscoveryFailed(error)
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == plan.displayID }) else {
            let err = ScreenSourceError.displayNotFound(id: self.plan.displayID)
            screenSourceLogger.error("Target display not in shareable content")
            throw RecordingError.displayDiscoveryFailed(err)
        }
        screenSourceLogger.info(
            "Display found — count: \(content.displays.count), dims: \(self.plan.screenWidth)×\(self.plan.screenHeight)"
        )
        // Resolve Onset's own SCRunningApplication from the same content fetch to exclude
        // the on-demand recording window from capture (#244). Avoids a second SCShareableContent call.
        let onsetApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return (scDisplay, onsetApp)
    }

    private func makeShim(
        sessionStart: CMTime,
        onTerminalStop: @escaping @Sendable (any Error) async -> Void
    )
    -> StreamOutputShim {
        StreamOutputShim(
            sessionStart: sessionStart,
            framesContinuation: self.framesContinuation,
            dropsContinuation: self.dropsContinuation,
            eventsContinuation: self.eventsContinuation,
            displayID: self.plan.displayID,
            onTerminalStop: onTerminalStop,
            rateLock: self.captureRateLock
        )
    }

    /// Returns `true` when capture reached the `.running` state, `false` when the
    /// stop()-during-startup abort path was taken (stop() raced and already ran).
    /// Callers must gate any post-start work (e.g. telemetry) on the return value.
    private func startSCStream(
        display: SCDisplay,
        onsetApp: SCRunningApplication?,
        shim: StreamOutputShim
    ) async throws
    -> Bool {
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: self.plan, config: self.config)
        // Static filter — no live SCStream.updateContentFilter.
        let filter = makeScreenContentFilter(display: display, onsetApp: onsetApp)
        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: shim)
        do {
            try scStream.addStreamOutput(shim, type: .screen, sampleHandlerQueue: self.sampleHandlerQueue)
        } catch {
            screenSourceLogger.error("addStreamOutput failed: \(error)")
            throw RecordingError.captureSetupFailed(error)
        }
        do {
            try await scStream.startCapture()
        } catch {
            screenSourceLogger.error("startCapture failed: \(error)")
            throw RecordingError.captureSetupFailed(error)
        }
        // Close the stop()-during-.starting race: if stop() ran while startCapture()
        // was suspended, captureState is now .stopped and streams are already finished.
        // Continuing would overwrite .stopped with .running, creating a zombie SCStream
        // that captures forever (screen-recording indicator stuck, resource leak).
        guard case .starting = self.captureState else {
            try? await scStream.stopCapture()
            screenSourceLogger.info("Capture aborted — stop() called during startup")
            return false
        }
        self.captureState = .running(stream: scStream, shim: shim)
        screenSourceLogger.info("Capture started — fps: \(self.plan.screenFps)")
        return true
    }

    /// Handles a terminal stop from the shim (SCStreamDelegate path).
    ///
    /// ScreenSource has no auto-restart in MVP — any `didStopWithError` is terminal.
    /// Emits the appropriate event, then finishes all streams. Idempotent.
    func handleTerminalStop(error: any Error) async {
        self.captureTelemetryTask?.cancel()
        self.captureTelemetryTask = nil
        guard case .running = self.captureState else { return }
        self.captureState = .stopped
        screenSourceLogger.error("SCStream stopped with error: \(error)")
        // Default true: if the query throws we cannot confirm the display is gone,
        // so fall back to .sourceInterrupted — matching the original catch-branch.
        var displayPresent = true
        do {
            let content = try await SCShareableContent.current
            displayPresent = content.displays.contains { $0.displayID == self.plan.displayID }
        } catch {
            screenSourceLogger.error("SCShareableContent.current failed during stop: \(error)")
        }
        let event = terminalStopEvent(displayPresent: displayPresent, reason: "SCStream stopped with error")
        self.eventsContinuation.yield(event)
        // No auto-restart: finish streams so consumer for-await loops terminate.
        self.finishAllStreams()
    }

    /// Stops display capture. Finishes all three streams idempotently.
    func stop() async {
        self.captureTelemetryTask?.cancel()
        self.captureTelemetryTask = nil
        defer { self.finishAllStreams() }
        guard case let .running(scStream, shim) = captureState else {
            self.captureState = .stopped
            return
        }
        self.captureState = .stopped
        try? scStream.removeStreamOutput(shim, type: .screen)
        do {
            try await scStream.stopCapture()
        } catch {
            screenSourceLogger.error("stopCapture error (ignored): \(error)")
        }
        screenSourceLogger.info("Capture stopped")
    }

    private func startCaptureTelemetryTask() {
        self.captureTelemetryTask = Task { [weak self] in
            let clock = ContinuousClock()
            var lastInstant = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let now = clock.now
                let elapsedSeconds = (now - lastInstant).totalSeconds
                lastInstant = now
                if let line = self.captureRateLock.withLock({ $0.flush(elapsedSeconds: elapsedSeconds) }) {
                    telemetryLogger.notice("\(line, privacy: .public)")
                } else {
                    screenSourceLogger.debug("flushTelemetry: skipped (elapsed ≤ 0)")
                }
            }
        }
    }

    private func finishAllStreams() {
        self.framesContinuation.finish()
        self.eventsContinuation.finish()
        self.dropsContinuation.finish()
    }
}

// MARK: - StreamOutputShim

/// Bridges SCStream callbacks into the three AsyncStream continuations.
///
/// `@unchecked Sendable` rationale:
/// - Stored `let` fields (continuations, sessionStart, displayID, onTerminalStop) are immutable.
/// - `didLogStatusAnomaly` is `nonisolated(unsafe) var`, confined exclusively to
///   `sampleHandlerQueue` (a serial queue). That queue is the synchronisation mechanism.
private final class StreamOutputShim: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sessionStart: CMTime
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation
    private let eventsContinuation: AsyncStream<SourceEvent>.Continuation
    private let displayID: CGDirectDisplayID
    /// Routes terminal-stop handling to the `ScreenSource` actor. `weak self` inside the
    /// closure prevents a retain cycle; the actor owns the shim.
    private let onTerminalStop: @Sendable (any Error) async -> Void

    /// Rate-limiting flag for `frameStatus(from:)` anomaly logging.
    /// `nonisolated(unsafe)`: confined to `sampleHandlerQueue` (serial). That queue is the lock.
    nonisolated(unsafe) private var didLogStatusAnomaly = false

    /// Per-stage cadence accumulator, shared with the owning `ScreenSource` actor for flushing.
    ///
    /// `OSAllocatedUnfairLock` because `StreamOutputShim` runs on `sampleHandlerQueue` (a GCD
    /// serial queue) while the flush tick runs actor-isolated — two isolation domains. The lock is
    /// `Sendable`, so storing it as `let` satisfies the `@unchecked Sendable` contract.
    private let rateLock: OSAllocatedUnfairLock<StageRateAggregator>

    // nonisolated: overrides @MainActor inference (SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor)
    // so ScreenSource can construct the shim without an await hop.
    nonisolated init(
        sessionStart: CMTime,
        framesContinuation: AsyncStream<VideoFrame>.Continuation,
        dropsContinuation: AsyncStream<DropEvent>.Continuation,
        eventsContinuation: AsyncStream<SourceEvent>.Continuation,
        displayID: CGDirectDisplayID,
        onTerminalStop: @escaping @Sendable (any Error) async -> Void,
        rateLock: OSAllocatedUnfairLock<StageRateAggregator>
    ) {
        self.sessionStart = sessionStart
        self.framesContinuation = framesContinuation
        self.dropsContinuation = dropsContinuation
        self.eventsContinuation = eventsContinuation
        self.displayID = displayID
        self.onTerminalStop = onTerminalStop
        self.rateLock = rateLock
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        let status = self.frameStatus(from: sampleBuffer)
        guard classifyFrameStatus(status) == .process else {
            // skipStatic callbacks (idle, blank, started, stopped, suspended) are counted as idle.
            self.rateLock.withLock { $0.recordIdle() }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard shouldKeepFrame(frameHostTime: pts, sessionStart: self.sessionStart) else { return }
        // A .complete frame with no image buffer is a contract violation — log at .error.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            screenSourceLogger.error("Complete sample has no image buffer — pts: \(pts.value)/\(pts.timescale)")
            return
        }
        let frame = VideoFrame(pixelBuffer: pixelBuffer, ptsHostTime: pts, isHoldRepeat: false)
        let yieldResult = self.framesContinuation.yield(frame)
        self.rateLock.withLock { aggregator in
            if case .dropped = yieldResult {
                aggregator.recordOverflow()
            } else {
                aggregator.recordFresh()
            }
        }
        if let dropEvent = backpressureDropEvent(for: yieldResult, pts: pts) {
            self.dropsContinuation.yield(dropEvent)
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { await self.onTerminalStop(error) }
    }

    // MARK: - Private helpers

    /// Reads `SCFrameStatus` from the first sample attachment.
    ///
    /// Logs `.error` (rate-limited to first occurrence) when the attachment is absent or
    /// the status value is unrecognised — both indicate a contract violation from SCKit.
    nonisolated private func frameStatus(from sampleBuffer: CMSampleBuffer) -> SCFrameStatus {
        // CFArray has no pure-Swift bridge; NSArray toll-free bridging is canonical.
        // swiftlint:disable legacy_objc_type
        let firstAttachment = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { ($0 as NSArray).firstObject as? [AnyHashable: Any] }
        // swiftlint:enable legacy_objc_type
        guard let dict = firstAttachment,
              let rawStatus = dict[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else {
            // `unsafe`: STRICT_MEMORY_SAFETY=YES requires this for nonisolated(unsafe) access.
            // Safety: read+write confined to sampleHandlerQueue (serial); that queue is the lock.
            if unsafe !self.didLogStatusAnomaly {
                unsafe self.didLogStatusAnomaly = true
                screenSourceLogger.error("SCStream sample has no status attachment or unrecognised status value")
            }
            return .idle
        }
        return status
    }
}

// MARK: - ScreenSourceError

private enum ScreenSourceError: Error {
    case displayNotFound(id: CGDirectDisplayID)
}
