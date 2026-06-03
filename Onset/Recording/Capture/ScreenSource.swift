import CoreMedia
import CoreVideo
import os
import ScreenCaptureKit

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
    /// `.idle` and `.blank` indicate the display has not changed since the previous
    /// delivery. These are NOT drops; no `DropEvent` is emitted.
    case skipStatic
}

// MARK: - Testable pure helpers

/// Classifies a `SCFrameStatus` value into a pipeline action.
///
/// Only `.complete` carries new pixel data. All other statuses (`.idle`, `.blank`,
/// `.started`, `.stopped`) indicate no new frame content is available; skip them
/// silently without emitting a drop event.
///
/// - Parameter status: The frame status from the SCStream sample attachment.
/// - Returns: `.process` for `.complete`; `.skipStatic` for all other values.
nonisolated func classifyFrameStatus(_ status: SCFrameStatus) -> FrameAction {
    switch status {
    case .complete:
        .process

    default:
        // .idle, .blank, .started, .stopped — static-screen or lifecycle ticks,
        // not pipeline drops. Skip without emitting a DropEvent.
        .skipStatic
    }
}

/// Returns `true` when the frame's host-time PTS meets or postdates the session T0.
///
/// Frames captured before `start(anchoredTo:)` was called can arrive during the
/// brief window between stream start and T0 lock-in. Drop them silently.
///
/// - Parameters:
///   - frameHostTime: Absolute host-clock PTS from the sample buffer.
///   - sessionStart: Absolute host-clock time at which the session started (T0).
/// - Returns: `true` when `frameHostTime >= sessionStart`.
nonisolated func shouldKeepFrame(frameHostTime: CMTime, sessionStart: CMTime) -> Bool {
    CMTimeCompare(frameHostTime, sessionStart) >= 0
}

// MARK: - Private logger

/// Logger is `Sendable`; `nonisolated let` avoids a `@MainActor` hop under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated private let screenSourceLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "ScreenSource"
)

// MARK: - ScreenSource

/// Actor that captures a single display via ScreenCaptureKit and emits host-time-stamped `VideoFrame`s.
///
/// SCStream sample buffers are already stamped on the host clock; no `CMSyncConvertTime` needed.
/// The `frames` stream is bounded (`.bufferingNewest(8)`); overflow emits `DropEvent(.encoderBackpressureDrops)`.
/// Hotplug: `stream(_:didStopWithError:)` checks `SCShareableContent.current` and emits `.displayDisconnected`
/// or `.sourceInterrupted(reason:)`.
actor ScreenSource: VideoFrameSource {
    // MARK: - Constants

    /// Buffer depth for the `frames` stream. Matches `captureQueueDepth` (SCStream cap = 8).
    private static let framesBufferDepth = 8

    /// Buffer depth for the `events` AsyncStream. 4 slots: headroom for #34 teardown races.
    private static let eventsBufferDepth = 4

    // MARK: - Protocol streams (nonisolated let — no actor hop for subscribers)

    /// The stream of captured video frames. Bounded with `.bufferingNewest(8)`.
    nonisolated let frames: AsyncStream<VideoFrame>

    /// Out-of-band lifecycle events (disconnect, interruption).
    nonisolated let events: AsyncStream<SourceEvent>

    /// Drop events emitted by this source.
    nonisolated let drops: AsyncStream<DropEvent>

    // MARK: - Private state

    /// The resolved recording plan injected at init; consumed during `start()`.
    private let plan: ResolvedRecordingPlan

    /// The recording policy injected at init; consumed during `start()`.
    private let config: RecordingConfiguration

    /// Continuation backing `frames`. Held by the actor; driven from `StreamOutputShim`.
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation

    /// Continuation backing `events`. Held by the actor; driven from `StreamOutputShim`.
    private let eventsContinuation: AsyncStream<SourceEvent>.Continuation

    /// Continuation backing `drops`. Held by the actor; driven from `StreamOutputShim`.
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    /// Dedicated serial queue for SCStream sample delivery; guarantees ordered, non-concurrent frames.
    private let sampleHandlerQueue = DispatchQueue(
        label: "dev.androidbroadcast.Onset.ScreenSource.sampleHandler",
        qos: .userInteractive
    )

    /// The live SCStream. Created in `start()`, torn down in `stop()`.
    private var stream: SCStream?

    /// The SCStreamOutput/SCStreamDelegate shim. Created in `start()` after T0 is known.
    private var outputShim: StreamOutputShim?

    // MARK: - Init

    /// Creates a `ScreenSource` for the display described in `plan`.
    ///
    /// All three `AsyncStream`s are created here so that callers can subscribe to them
    /// before `start(anchoredTo:)` is called without missing any events.
    ///
    /// - Parameters:
    ///   - plan: Resolved recording plan containing the target display ID, dimensions, and fps.
    ///   - config: Recording policy (pixel format preference).
    init(plan: ResolvedRecordingPlan, config: RecordingConfiguration) {
        self.plan = plan
        self.config = config

        // Capture continuations during stream creation — stored as `let` on the actor.
        var capturedFrames: AsyncStream<VideoFrame>.Continuation!
        var capturedEvents: AsyncStream<SourceEvent>.Continuation!
        var capturedDrops: AsyncStream<DropEvent>.Continuation!

        self.frames = AsyncStream(VideoFrame.self, bufferingPolicy: .bufferingNewest(Self.framesBufferDepth)) { cont in
            capturedFrames = cont
        }
        self.events = AsyncStream(SourceEvent.self, bufferingPolicy: .bufferingNewest(Self.eventsBufferDepth)) { cont in
            capturedEvents = cont
        }
        self.drops = AsyncStream(DropEvent.self, bufferingPolicy: .bufferingNewest(Self.framesBufferDepth)) { cont in
            capturedDrops = cont
        }

        self.framesContinuation = capturedFrames
        self.eventsContinuation = capturedEvents
        self.dropsContinuation = capturedDrops
    }

    // MARK: - VideoFrameSource

    /// Starts display capture anchored to `anchor`. Discovers the target display, builds config, starts SCStream.
    ///
    /// - Throws: `RecordingError.displayDiscoveryFailed` or `.captureSetupFailed`.
    func start(anchoredTo anchor: HostTimeAnchor) async throws {
        let sessionStart = anchor.anchorTime
        let scDisplay = try await discoverDisplay()
        let shim = self.makeShim(sessionStart: sessionStart)
        try await self.startSCStream(display: scDisplay, shim: shim)
    }

    /// Discovers and returns the SCDisplay matching plan.displayID; throws RecordingError on failure.
    private func discoverDisplay() async throws -> SCDisplay {
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
        return scDisplay
    }

    /// Creates and stores the StreamOutputShim wired to this actor's three continuations.
    private func makeShim(sessionStart: CMTime) -> StreamOutputShim {
        let shim = StreamOutputShim(
            sessionStart: sessionStart,
            framesContinuation: framesContinuation,
            dropsContinuation: dropsContinuation,
            eventsContinuation: eventsContinuation,
            displayID: plan.displayID
        )
        self.outputShim = shim
        return shim
    }

    /// Builds, wires, and starts an SCStream for display using shim as output/delegate.
    private func startSCStream(display: SCDisplay, shim: StreamOutputShim) async throws {
        defer { if stream == nil { outputShim = nil } } // on throw: clear orphaned shim
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: self.plan, config: self.config)
        let filter = SCContentFilter(display: display, excludingWindows: [])
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

        self.stream = scStream
        let fps = self.plan.screenFps
        screenSourceLogger.info("Capture started — fps: \(fps)")
    }

    /// Stops display capture. Finishes all three streams idempotently — safe before `start()` or twice.
    func stop() async {
        guard let scStream = stream else {
            self.finishAllStreams()
            return
        }

        self.stream = nil

        if let shim = outputShim {
            // Remove the output callback before stopping to avoid late deliveries.
            try? scStream.removeStreamOutput(shim, type: .screen)
            self.outputShim = nil
        }

        do {
            try await scStream.stopCapture()
        } catch {
            screenSourceLogger.error("stopCapture error (ignored): \(error)")
        }

        self.finishAllStreams()
        screenSourceLogger.info("Capture stopped")
    }

    /// Finishes all three AsyncStream continuations. `finish()` after `finish()` is a no-op.
    private func finishAllStreams() {
        self.framesContinuation.finish()
        self.eventsContinuation.finish()
        self.dropsContinuation.finish()
    }
}

// MARK: - StreamOutputShim

/// Bridges SCStream callbacks into the three AsyncStream continuations. All state is immutable `let`;
/// no lock needed. nonisolated because SCKit calls it from its own internal queue.
private final class StreamOutputShim: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // MARK: - Immutable state (let — no lock needed)

    /// Absolute host-clock session start time (T0). Frames predating this are dropped silently.
    private let sessionStart: CMTime

    /// Destination for processed video frames.
    private let framesContinuation: AsyncStream<VideoFrame>.Continuation

    /// Destination for drop events (backpressure overflow).
    private let dropsContinuation: AsyncStream<DropEvent>.Continuation

    /// Destination for source lifecycle events (disconnect, interruption).
    private let eventsContinuation: AsyncStream<SourceEvent>.Continuation

    /// Display ID under capture — used for hotplug classification.
    private let displayID: CGDirectDisplayID

    // MARK: - Init

    // nonisolated: NSObject init inferred @MainActor under SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor;
    // nonisolated overrides inference so ScreenSource can construct the shim without an await hop.
    nonisolated init(
        sessionStart: CMTime,
        framesContinuation: AsyncStream<VideoFrame>.Continuation,
        dropsContinuation: AsyncStream<DropEvent>.Continuation,
        eventsContinuation: AsyncStream<SourceEvent>.Continuation,
        displayID: CGDirectDisplayID
    ) {
        self.sessionStart = sessionStart
        self.framesContinuation = framesContinuation
        self.dropsContinuation = dropsContinuation
        self.eventsContinuation = eventsContinuation
        self.displayID = displayID
    }

    // MARK: - SCStreamOutput

    /// SCStreamOutput: classify status, apply T0 gate, yield VideoFrame, emit DropEvent on overflow.
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }

        // Read SCFrameStatus from the sample attachment dictionary.
        // CMSampleBufferGetSampleAttachmentsArray does not require `unsafe` in this SDK.
        let status = Self.frameStatus(from: sampleBuffer)

        // Classify: only .complete frames carry new pixel data.
        guard classifyFrameStatus(status) == .process else { return }

        // T0 gate: drop frames captured before the session started.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard shouldKeepFrame(frameHostTime: pts, sessionStart: self.sessionStart) else { return }

        // Extract the pixel buffer.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            screenSourceLogger.debug("Sample has no image buffer — skipping")
            return
        }

        let frame = VideoFrame(pixelBuffer: pixelBuffer, ptsHostTime: pts, isHoldRepeat: false)

        // Yield; detect backpressure overflow.
        if case .dropped = self.framesContinuation.yield(frame) {
            let dropEvent = DropEvent(
                reason: .encoderBackpressureDrops,
                count: 1,
                detectedAt: pts
            )
            self.dropsContinuation.yield(dropEvent)
        }
    }

    // MARK: - SCStreamDelegate

    /// SCStreamDelegate: async display check distinguishes disconnected display from transient interruption.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        screenSourceLogger.error("SCStream stopped with error: \(error)")
        // SCStreamDelegate has no actor context — unstructured Task only touches Sendable continuations.
        Task { await self.classifyAndEmitStopEvent() }
    }

    // MARK: - Private helpers

    /// Reads SCFrameStatus from the first sample attachment; no unsafe needed in this SDK.
    nonisolated private static func frameStatus(from sampleBuffer: CMSampleBuffer) -> SCFrameStatus {
        // CFArray from CoreMedia has no pure-Swift bridge; NSArray toll-free bridging is canonical here.
        // swiftlint:disable legacy_objc_type
        let firstAttachment = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            .flatMap { ($0 as NSArray).firstObject as? [AnyHashable: Any] }
        // swiftlint:enable legacy_objc_type
        guard let dict = firstAttachment,
              let rawStatus = dict[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else {
            // No attachment or unrecognised status — skip safely.
            return .idle
        }
        return status
    }

    /// Emits a `.displayDisconnected` or `.sourceInterrupted(reason:)` event by
    /// checking live `SCShareableContent` for the recorded display.
    private func classifyAndEmitStopEvent() async {
        let event: SourceEvent

        do {
            let content = try await SCShareableContent.current
            let stillPresent = content.displays.contains { $0.displayID == self.displayID }
            event = stillPresent
                ? .sourceInterrupted(reason: "SCStream stopped with error")
                : .displayDisconnected
        } catch {
            // Cannot determine display state — assume interruption.
            screenSourceLogger.error("SCShareableContent.current failed during stop: \(error)")
            event = .sourceInterrupted(reason: "SCStream stopped with error")
        }

        self.eventsContinuation.yield(event)
        // Do not finish here — ScreenSource.stop() owns stream teardown and final finish().
    }
}

// MARK: - ScreenSourceError

/// Internal errors produced exclusively by `ScreenSource`.
private enum ScreenSourceError: Error {
    /// The display described by `id` was not found in `SCShareableContent.current`.
    case displayNotFound(id: CGDirectDisplayID)
}
