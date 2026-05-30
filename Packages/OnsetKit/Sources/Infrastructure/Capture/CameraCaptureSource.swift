import AVFoundation
import CoreMedia
import Domain
import Foundation

// MARK: - CameraCaptureSource

/// Infrastructure implementation of `CaptureSource` for camera capture via AVFoundation.
///
/// Delivers `CMSampleBuffer`s on `com.app.capture.camera`. The session contains
/// **no audio input** — an audio `AVCaptureDeviceInput` would slave the master clock to
/// audio hardware, breaking cross-source PTS alignment (architecture.md §sync).
///
/// MJPEG: setting a `videoSettings` pixel-format key causes AVFoundation to hardware-decode
/// MJPEG (4K MX Brio, other UVC cameras) into `CVPixelBuffer`-backed buffers automatically.
///
/// ### Concurrency / Sendable
///
/// `@unchecked Sendable`: safety is structural. `sink` is accessed exclusively on
/// `captureQueue` — set via `.sync` before `startRunning` (visible to first callback),
/// cleared via `.sync` after `stopRunning` (clean happens-before). All other mutable
/// state (`session`, `device`) is serialised by the coordinator's CaptureSource contract.
///
/// ### Device selection seam (#30/#31)
///
/// Defaults to the first discovered external/built-in/continuity device. The seam is the
/// device-discovery block in `configure(_:)`; swap it when #30/#31 land.
public final class CameraCaptureSource: NSObject, CaptureSource,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{

    // MARK: - CaptureSource: kind

    public let kind: SourceKind = .camera

    // MARK: - CaptureSource: sourceClock

    /// `AVCaptureSession.synchronizationClock` (macOS 13+) — the clock AVFoundation uses to
    /// stamp buffers. Falls back to `CMClockGetHostTimeClock()` before `configure` and after
    /// `stop` (session nil). The coordinator (#34) uses this for `CMSyncConvertTime` alignment.
    public var sourceClock: CMClock {
        session?.synchronizationClock ?? CMClockGetHostTimeClock()
    }

    // MARK: - Private state

    /// The GCD queue on which AVFoundation delivers sample buffers.
    ///
    /// All hot-path work (sink emit, drop logging) executes on this queue.
    /// No actor hops occur between here and `SampleSink.receive`.
    /// `sink` reads and writes are also serialised through this queue (see Sendable note).
    private let captureQueue = DispatchQueue(label: "com.app.capture.camera")

    /// The live `AVCaptureSession`; non-nil after `configure(_:)` succeeds.
    private var session: AVCaptureSession?

    /// The downstream sample sink.
    ///
    /// All accesses (reads and writes) go through `captureQueue` to serialise
    /// with the hot-path callback. Set via `captureQueue.sync` in `start` before
    /// capture begins (visible to the first callback); cleared via `captureQueue.sync`
    /// in `stop` after `stopRunning` returns (after all callbacks have drained).
    private var sink: (any SampleSink)?

    /// Observer token for `AVCaptureSession.runtimeErrorNotification`.
    /// Retained between `start` and `stop`; removing it in `stop` stops error delivery.
    private var runtimeErrorObserver: (any NSObjectProtocol)?

    // MARK: - CaptureSource: configure

    /// Builds the `AVCaptureSession` (video-only), selects the camera device, sets
    /// `activeFormat` + frame rate, and attaches `AVCaptureVideoDataOutput`.
    ///
    /// The session is fully configured here — **no reconfiguration occurs at record time**.
    /// `session.startRunning()` is deferred to `start(emittingTo:)`.
    ///
    /// - Parameter config: Capture parameters (fps, width, height) from the coordinator.
    ///
    /// - Throws: `CameraCaptureError.noDeviceAvailable` when no camera is discoverable.
    ///           `CameraCaptureError.noCompatibleFormat` when the device has no format
    ///           matching the requested parameters.
    public func configure(_ config: SourceConfiguration) throws {
        // ── Device discovery ──────────────────────────────────────────────────
        //
        // Seam for #30/#31 (device selection): replace the first-discovered-device
        // default with a lookup by the camera identifier in `SourceConfiguration`
        // once that field is added.
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard
            let captureDevice = discoverySession.devices.first
                ?? AVCaptureDevice.default(for: .video)
        else {
            throw CameraCaptureError.noDeviceAvailable
        }
        Log.capture.debug(
            "configure: device=\(captureDevice.localizedName, privacy: .public)"
        )

        // ── Format + frame-rate selection ─────────────────────────────────────
        let selection =
            try CameraCaptureSource
            .selectFormat(
                from: captureDevice.formats,
                width: config.width,
                height: config.height,
                fps: config.fps
            )

        // ── AVCaptureSession ──────────────────────────────────────────────────
        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        // defer ensures commitConfiguration() is always called on every exit path —
        // including throws — keeping the session in a consistent AVFoundation state.
        defer { newSession.commitConfiguration() }

        // Add video input. NO audio input — adding audio would slave
        // the session's master clock to the audio hardware, breaking the
        // cross-source PTS alignment (architecture.md §sync invariant).
        let deviceInput = try AVCaptureDeviceInput(device: captureDevice)
        guard newSession.canAddInput(deviceInput) else {
            throw CameraCaptureError.sessionInputRejected
        }
        newSession.addInput(deviceInput)

        // Set activeFormat AFTER addInput so AVFoundation does not re-assert the default
        // session preset over our chosen format at startRunning. AVCaptureSessionPresetInputPriority
        // exists on macOS too; setting activeFormat inside beginConfiguration/commit achieves
        // the same effect without setting the preset explicitly.
        try captureDevice.lockForConfiguration()
        captureDevice.activeFormat = selection.format
        // Pin min and max to the same value to enforce a fixed frame rate.
        captureDevice.activeVideoMinFrameDuration = selection.frameDuration
        captureDevice.activeVideoMaxFrameDuration = selection.frameDuration
        captureDevice.unlockForConfiguration()
        Log.capture.debug(
            "configure: format=\(selection.format.debugDescription, privacy: .public) fps=\(config.fps)"
        )

        // ── AVCaptureVideoDataOutput ──────────────────────────────────────────
        //
        // videoSettings requests decoded CVPixelBuffer output; for MJPEG cameras
        // (e.g. MX Brio) this triggers hardware-decode into CVPixelBuffer — verified
        // at L5. kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange is native BT.709.
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        // alwaysDiscardsLateVideoFrames = true: AVFoundation drops frames it cannot
        // deliver on time rather than queuing them indefinitely. The architecture
        // specifies drop-oldest for video backpressure; this enforces that at the
        // capture layer. didDrop callback fires for each discarded frame.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard newSession.canAddOutput(videoOutput) else {
            throw CameraCaptureError.sessionOutputRejected
        }
        newSession.addOutput(videoOutput)

        self.session = newSession
        Log.capture.info(
            "configure: camera session ready device=\(captureDevice.localizedName, privacy: .public)"
        )
    }

    // MARK: - CaptureSource: start

    /// Starts the capture session and begins delivering frames to `sink`.
    ///
    /// - Parameter sink: The downstream sample router.
    ///
    /// - Throws: `CameraCaptureError.notConfigured` if `configure` was not called first.
    ///           `CameraCaptureError.startFailed` if AVFoundation reports the session
    ///           did not start (e.g. camera in use by another process).
    ///
    /// `session.startRunning()` is synchronous and can block for hundreds of milliseconds
    /// while AVFoundation negotiates the hardware format. It is dispatched to a global
    /// queue via `withCheckedContinuation` to avoid occupying a Swift cooperative-pool
    /// thread for the duration of the blocking call — the same discipline applied to
    /// `stopRunning()` in `stop()`.
    public func start(emittingTo sink: any SampleSink) async throws {
        guard let liveSession = session else {
            throw CameraCaptureError.notConfigured
        }

        // Guard against double-start: a second call would overwrite (and leak) the
        // existing notification observer. Log and return instead.
        guard runtimeErrorObserver == nil else {
            Log.capture.warning("CameraCaptureSource: start called while already running — ignored")
            return
        }

        // Set sink before startRunning so it is guaranteed visible to the first callback.
        // captureQueue is idle here (capture not yet started), so .sync runs instantly —
        // no deadlock. All subsequent sink reads on captureQueue see this write
        // (single-queue confinement, no lock needed).
        captureQueue.sync { self.sink = sink }

        // Observe runtime errors (e.g. camera physically disconnected mid-capture).
        // Uses the block-based addObserver(forName:object:queue:using:) variant;
        // `Log.emitSourceFailure` is a static call so no `self` capture is needed.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: liveSession,
            queue: nil
        ) { notification in
            let error =
                notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? CameraCaptureError.unknownRuntimeError
            Log.emitSourceFailure(kind: .camera, error: error)
        }

        // Off-pool: startRunning() blocks for hundreds of ms; don't occupy a
        // cooperative-pool thread. Capture self (@unchecked Sendable) to avoid
        // transferring non-Sendable AVCaptureSession across isolation boundaries.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.session?.startRunning()
                cont.resume()
            }
        }

        // Detect immediate start failure: AVFoundation returns from startRunning()
        // without error but isRunning == false when the camera is unavailable
        // (e.g. in use by another process, hardware error).
        guard liveSession.isRunning else {
            captureQueue.sync { self.sink = nil }
            if let observer = runtimeErrorObserver {
                NotificationCenter.default.removeObserver(observer)
                runtimeErrorObserver = nil
            }
            throw CameraCaptureError.startFailed
        }

        Log.capture.info("recording.start source=camera")
    }

    // MARK: - CaptureSource: stop

    /// Stops the capture session and releases the sink reference. Idempotent.
    ///
    /// `stopRunning()` is synchronous and blocks until in-flight callbacks complete.
    /// It is dispatched off the Swift cooperative thread pool via `withCheckedContinuation`
    /// for the same reason as `startRunning()` in `start(emittingTo:)`.
    /// After it returns AVFoundation guarantees no more delegate calls will be delivered,
    /// so the subsequent `captureQueue.sync` that nils `sink` establishes a clean
    /// happens-before. Nilling `session` after stop makes a second `stop()` call a no-op
    /// and lets `sourceClock` fall back to `CMClockGetHostTimeClock()`.
    public func stop() async {
        guard session != nil else { return }

        // Off-pool: stopRunning() blocks until callbacks drain; same rationale as
        // startRunning() above. session is read via self (@unchecked Sendable).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.session?.stopRunning()
                cont.resume()
            }
        }

        // Nil session after stopRunning returns so a second stop() call is a no-op
        // and sourceClock falls back to CMClockGetHostTimeClock().
        session = nil

        // Remove the runtime-error observer before nilling the sink so no
        // callbacks fire against a partially torn-down object.
        if let observer = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            runtimeErrorObserver = nil
        }

        // Nil the sink on captureQueue to serialise with the hot-path callback.
        // AVFoundation guarantees no more delegate calls after stopRunning returns,
        // so this sync serves as the happens-before fence.
        captureQueue.sync { self.sink = nil }
        Log.capture.info("recording.stop source=camera")
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (hot path)

    /// Called by AVFoundation on `com.app.capture.camera` for every delivered frame.
    ///
    /// ## Hot-path discipline (architecture §hot path)
    ///
    /// This method runs exclusively on `com.app.capture.camera`. It does ONLY:
    /// 1. Guard the sink.
    /// 2. Call `sink.receive(_:kind:)` — zero-copy: the `CMSampleBuffer` wraps a
    ///    `CVPixelBuffer` (hardware-decoded from MJPEG); no pixel data is copied here.
    ///
    /// No actor hops, no locks, no per-frame allocations. Buffer hold time is bounded
    /// by the duration of `sink.receive`, which must return before the next frame's
    /// deadline (`minimumFrameInterval × (queueDepth − 1)` for the session's queue).
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let sink else {
            // sink is set on captureQueue before capture starts and cleared on captureQueue
            // after stopRunning returns. Reaching here means a callback fired outside the
            // [set, clear] window — an AVFoundation delivery guarantee violation.
            Log.capture.error(
                "CameraCaptureSource: sink is nil on capture queue — frame skipped"
            )
            return
        }
        // Zero-copy: CMSampleBuffer wraps CVPixelBuffer — no pixel copy occurs here.
        sink.receive(sampleBuffer, kind: .camera)
    }

    /// Called by AVFoundation on `captureQueue` when a frame is dropped at the capture layer.
    ///
    /// AVFoundation drops frames when `alwaysDiscardsLateVideoFrames = true` and the
    /// delegate queue is busy. This maps to `poolExhausted` (the CVPixelBuffer pool that
    /// backs the hardware decoder could not provide a free buffer in time). Full
    /// `DroppedFrameStats` aggregation is deferred to #39.
    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // AVFoundation's did-drop path does not expose a typed reason enum. The dominant
        // cause when alwaysDiscardsLateVideoFrames=true is pixel-buffer pool exhaustion
        // (the hardware MJPEG decoder could not acquire a free CVPixelBuffer). We log
        // poolExhausted as the canonical reason; captureBound would be appropriate if we
        // observe explicit queue-overflow attachments — not surfaced by AVFoundation today.
        Log.emitFrameDropped(source: .camera, reason: .poolExhausted)
    }
}

// MARK: - Testable pure functions

extension CameraCaptureSource {

    // MARK: Format projection

    /// Pure-data projection of an `AVCaptureDevice.Format` for capability pickers (AC-3)
    /// and unit tests. Uses only types constructable without a live device.
    public struct FormatOption: Sendable, Equatable {
        /// Native pixel dimensions of the format.
        public let dimensions: CMVideoDimensions
        /// Supported fps ranges as `(min, max)` pairs (both in frames per second).
        public let fpsRanges: [(minFPS: Double, maxFPS: Double)]

        public static func == (lhs: FormatOption, rhs: FormatOption) -> Bool {
            lhs.dimensions.width == rhs.dimensions.width
                && lhs.dimensions.height == rhs.dimensions.height
                && lhs.fpsRanges.elementsEqual(rhs.fpsRanges) {
                    $0.minFPS == $1.minFPS && $0.maxFPS == $1.maxFPS
                }
        }
    }

    /// Projects a `CMFormatDescription` into a `FormatOption`.
    ///
    /// Extracted as a `static func` for unit testability — `AVFrameRateRange` has no
    /// public initialiser, so the caller supplies fps ranges directly.
    ///
    /// - Parameters:
    ///   - description: The format description to project.
    ///   - fpsRanges: Fps ranges as `(min, max)` pairs (from `AVFrameRateRange`).
    /// - Returns: The projected `FormatOption`.
    public static func projectFormatOption(
        description: CMFormatDescription,
        fpsRanges: [(minFPS: Double, maxFPS: Double)]
    ) -> FormatOption {
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        return FormatOption(dimensions: dims, fpsRanges: fpsRanges)
    }

    /// Enumerates `AVCaptureDevice.Format`s into `FormatOption`s.
    ///
    /// AC-3: only combinations present in `device.formats` are produced — no synthesis.
    /// Non-testable in unit tests (`AVCaptureDevice.Format` has no public initialiser);
    /// the testable core is `projectFormatOption(description:fpsRanges:)`.
    ///
    /// - Parameter formats: `device.formats` from an `AVCaptureDevice`.
    /// - Returns: One `FormatOption` per format, preserving order.
    public static func enumerateFormats(
        _ formats: [AVCaptureDevice.Format]
    ) -> [FormatOption] {
        formats.map { fmt in
            let fpsRanges = fmt.videoSupportedFrameRateRanges.map { range in
                (minFPS: range.minFrameRate, maxFPS: range.maxFrameRate)
            }
            return projectFormatOption(
                description: fmt.formatDescription,
                fpsRanges: fpsRanges
            )
        }
    }

    // MARK: Format + frame-rate selection

    /// Result of `selectFormat(from:width:height:fps:)`.
    public struct FormatSelection {
        /// The chosen `AVCaptureDevice.Format` to assign to `device.activeFormat`.
        public let format: AVCaptureDevice.Format
        /// The frame duration for `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration`.
        /// Both are set to the same value to pin capture to a fixed rate.
        public let frameDuration: CMTime
    }

    /// Selects the best `AVCaptureDevice.Format` for the requested parameters.
    ///
    /// Strategy: (1) dimension + fps match; (2) fps match only; (3) first format at
    /// its max fps (NFR-ERR warning emitted). Throws `.noCompatibleFormat` when empty.
    /// `static func` for testability — fps→CMTime is pure, no live device required.
    public static func selectFormat(
        from formats: [AVCaptureDevice.Format],
        width: Int,
        height: Int,
        fps: Int
    ) throws -> FormatSelection {
        guard !formats.isEmpty else {
            throw CameraCaptureError.noCompatibleFormat
        }

        let targetFPS = Double(max(1, fps))

        // Try: dimension match + fps coverage.
        for fmt in formats {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard dims.width == Int32(width) && dims.height == Int32(height) else { continue }
            if let range = fmt.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
            }) {
                return FormatSelection(
                    format: fmt,
                    frameDuration: fpsToFrameDuration(range.maxFrameRate, requested: targetFPS)
                )
            }
        }

        // Fallback: any format that covers the requested fps.
        for fmt in formats {
            if let range = fmt.videoSupportedFrameRateRanges.first(where: {
                $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
            }) {
                return FormatSelection(
                    format: fmt,
                    frameDuration: fpsToFrameDuration(range.maxFrameRate, requested: targetFPS)
                )
            }
        }

        // Last resort: first available format at its max fps.
        // NFR-ERR: warn so a mismatch between requested and actual parameters is visible.
        let fmt = formats[0]
        let maxFPS = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? targetFPS
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        Log.capture.warning(
            "selectFormat: no match \(width)×\(height)@\(fps)fps; using \(dims.width)×\(dims.height)@\(Int(maxFPS))fps"
        )
        return FormatSelection(
            format: fmt,
            frameDuration: fpsToFrameDuration(maxFPS, requested: maxFPS)
        )
    }

    // MARK: fps → CMTime

    /// Converts fps to `CMTime(value:1, timescale:clampedFPS)`.
    ///
    /// `requested` is clamped to `available` and floored at 1 (zero timescale is invalid).
    /// Both `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration` are set to
    /// the same value to pin capture to a fixed rate.
    public static func fpsToFrameDuration(_ available: Double, requested: Double) -> CMTime {
        let clamped = max(1.0, min(requested, available))
        let timescale = CMTimeScale(clamped.rounded())
        return CMTime(value: 1, timescale: timescale)
    }
}

// MARK: - Error type

/// Errors thrown by `CameraCaptureSource`.
public enum CameraCaptureError: Error {
    /// `start(emittingTo:)` was called before `configure(_:)`.
    case notConfigured
    /// No video capture device was found on this system.
    case noDeviceAvailable
    /// The device has no format compatible with the requested parameters.
    case noCompatibleFormat
    /// The `AVCaptureSession` rejected the device input.
    case sessionInputRejected
    /// The `AVCaptureSession` rejected the video data output.
    case sessionOutputRejected
    /// `startRunning()` returned but `isRunning` is false — camera unavailable
    /// (e.g. in use by another process, or a hardware error).
    case startFailed
    /// A runtime error notification was received but carried no `Error` in userInfo.
    case unknownRuntimeError
}
