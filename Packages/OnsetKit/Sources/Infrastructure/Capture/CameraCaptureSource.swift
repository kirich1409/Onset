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

    /// The clock that timestamps camera `CMSampleBuffer`s.
    ///
    /// `AVCaptureSession.synchronizationClock` (macOS 13+) is the clock that AVFoundation
    /// uses internally to stamp capture buffers; exposing it here lets the recording-session
    /// coordinator (#34) align camera PTS to the host-time reference clock via
    /// `CMSyncConvertTime`. The property is `nil` before inputs are added, so we fall back
    /// to `CMClockGetHostTimeClock()` — which is what AVFoundation itself uses as the
    /// default hardware clock on Apple Silicon.
    ///
    /// This is a computed property (not stored) so the fallback covers the pre-configure
    /// window and any window where the session has no inputs yet.
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

    /// The selected camera device; non-nil after `configure(_:)` succeeds.
    private var device: AVCaptureDevice?

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

        try captureDevice.lockForConfiguration()
        captureDevice.activeFormat = selection.format
        // Pin min and max to the same value to enforce a fixed frame rate.
        captureDevice.activeVideoMinFrameDuration = selection.frameDuration
        captureDevice.activeVideoMaxFrameDuration = selection.frameDuration
        captureDevice.unlockForConfiguration()
        Log.capture.debug(
            "configure: format=\(selection.format.debugDescription, privacy: .public) fps=\(config.fps)"
        )

        // ── AVCaptureSession ──────────────────────────────────────────────────
        let newSession = AVCaptureSession()
        newSession.beginConfiguration()

        // Add video input. NO audio input — adding audio would slave
        // the session's master clock to the audio hardware, breaking the
        // cross-source PTS alignment (architecture.md §sync invariant).
        let deviceInput = try AVCaptureDeviceInput(device: captureDevice)
        guard newSession.canAddInput(deviceInput) else {
            newSession.commitConfiguration()
            throw CameraCaptureError.sessionInputRejected
        }
        newSession.addInput(deviceInput)

        // ── AVCaptureVideoDataOutput ──────────────────────────────────────────
        //
        // videoSettings forces AVFoundation to hardware-decode MJPEG (as delivered
        // by 4K MX Brio and other UVC cameras) into a CVPixelBuffer. Without this
        // key the output stays compressed and cannot be passed directly to VideoToolbox
        // for re-encoding. kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange is the
        // native chroma-subsampled format for BT.709 camera output.
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
            newSession.commitConfiguration()
            throw CameraCaptureError.sessionOutputRejected
        }
        newSession.addOutput(videoOutput)
        newSession.commitConfiguration()

        self.session = newSession
        self.device = captureDevice
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
    ///
    /// `session.startRunning()` is synchronous and can block for hundreds of milliseconds
    /// while AVFoundation negotiates the hardware format. It is called directly here
    /// (not dispatched) because `start(emittingTo:)` is already async — calling it on
    /// the cooperative thread is acceptable; Swift concurrency treats blocking here the
    /// same as a long-running async step. A `withCheckedContinuation` wrapper would add
    /// complexity without benefit since `startRunning` has no async variant.
    public func start(emittingTo sink: any SampleSink) async throws {
        guard let liveSession = session else {
            throw CameraCaptureError.notConfigured
        }

        // Set sink before startRunning so it is guaranteed visible to the first callback.
        // captureQueue is idle here (capture not yet started), so .sync runs instantly —
        // no deadlock. All subsequent sink reads on captureQueue see this write
        // (single-queue confinement, no lock needed).
        captureQueue.sync { self.sink = sink }

        // Observe runtime errors (e.g. camera physically disconnected mid-capture).
        // Selector-based registration avoids the Sendable/closure issue with the
        // block-based addObserver(forName:using:) variant in Swift 6 strict concurrency.
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: liveSession,
            queue: nil
        ) { [weak self] notification in
            guard self != nil else { return }
            let error =
                notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? CameraCaptureError.unknownRuntimeError
            Log.emitSourceFailure(kind: .camera, error: error)
        }

        liveSession.startRunning()
        Log.capture.info("recording.start source=camera")
    }

    // MARK: - CaptureSource: stop

    /// Stops the capture session and releases the sink reference. Idempotent.
    ///
    /// `stopRunning()` is synchronous and blocks until in-flight callbacks complete.
    /// After it returns AVFoundation guarantees no more delegate calls will be delivered,
    /// so the subsequent `captureQueue.sync` that nils `sink` establishes a clean
    /// happens-before — the same pattern used by `ScreenCaptureSource`.
    public func stop() async {
        guard let liveSession = session else { return }

        liveSession.stopRunning()

        // Remove the runtime-error observer before nilling the session so no
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

    /// A pure-data projection of an `AVCaptureDevice.Format`, for consumption by the
    /// capability-and-settings pickers (AC-3) and unit tests.
    ///
    /// Uses only types that can be constructed in tests without a live device:
    /// `CMVideoDimensions` (a plain struct) and `Double` fps ranges.
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

    /// Projects a `CMFormatDescription` into the data needed by `FormatOption`.
    ///
    /// Extracted as a standalone `static func` so unit tests can call it with a
    /// `CMVideoFormatDescription` built via `CMVideoFormatDescriptionCreate` — no live
    /// device required.
    ///
    /// - Parameters:
    ///   - description: The format description to project.
    ///   - fpsRanges: The supported fps ranges for this format, expressed as `(min, max)`
    ///     pairs in frames per second. Supplied by the caller (from
    ///     `AVFrameRateRange.minFrameRate` / `maxFrameRate`) because `AVFrameRateRange`
    ///     has no public initialiser and cannot be constructed in unit tests.
    ///
    /// - Returns: The projected `FormatOption`.
    public static func projectFormatOption(
        description: CMFormatDescription,
        fpsRanges: [(minFPS: Double, maxFPS: Double)]
    ) -> FormatOption {
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        return FormatOption(dimensions: dims, fpsRanges: fpsRanges)
    }

    /// Enumerates all `AVCaptureDevice.Format`s and projects them into `FormatOption`s.
    ///
    /// AC-3 invariant: only combinations present in `device.formats` are produced.
    /// No synthetic combinations are added.
    ///
    /// This function is non-testable in unit tests because `AVCaptureDevice.Format` has
    /// no public initialiser. The testable core is `projectFormatOption(description:fpsRanges:)`.
    ///
    /// - Parameter formats: The `device.formats` array from an `AVCaptureDevice`.
    /// - Returns: One `FormatOption` per format, in the same order as `formats`.
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

    /// Selects the best `AVCaptureDevice.Format` and the corresponding frame duration
    /// for the requested parameters.
    ///
    /// Selection strategy:
    /// 1. Find formats whose dimensions match `width × height`.
    /// 2. Among those, find one whose `videoSupportedFrameRateRanges` cover `fps`.
    /// 3. If no exact dimension match, fall back to the first format that supports `fps`.
    /// 4. If no format supports `fps`, fall back to the first available format at its
    ///    max supported fps.
    ///
    /// Extracted as a `static func` for unit-testability — the fps→CMTime mapping is
    /// fully pure and can be driven without a live device.
    ///
    /// - Parameters:
    ///   - formats: `device.formats` from the target `AVCaptureDevice`.
    ///   - width: Requested frame width (from `SourceConfiguration`).
    ///   - height: Requested frame height (from `SourceConfiguration`).
    ///   - fps: Requested frame rate (from `SourceConfiguration`).
    ///
    /// - Returns: A `FormatSelection` with the chosen format and pinned frame duration.
    ///
    /// - Throws: `CameraCaptureError.noCompatibleFormat` when `formats` is empty.
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
        let fmt = formats[0]
        let maxFPS = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? targetFPS
        return FormatSelection(
            format: fmt,
            frameDuration: fpsToFrameDuration(maxFPS, requested: maxFPS)
        )
    }

    // MARK: fps → CMTime

    /// Converts a frames-per-second value to a `CMTime` frame duration.
    ///
    /// `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration` are set to the
    /// same value (fixed fps) to pin the capture rate rather than letting it float.
    ///
    /// The `requested` fps is clamped to `available` and floored at 1 to produce a
    /// valid `CMTime`. A zero or negative timescale would be `kCMTimeInvalid`.
    ///
    /// - Parameters:
    ///   - available: The maximum fps the selected format/range supports.
    ///   - requested: The fps value from `SourceConfiguration`.
    ///
    /// - Returns: `CMTime(value: 1, timescale: clampedFPS)` as the frame duration.
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
    /// A runtime error notification was received but carried no `Error` in userInfo.
    case unknownRuntimeError
}
