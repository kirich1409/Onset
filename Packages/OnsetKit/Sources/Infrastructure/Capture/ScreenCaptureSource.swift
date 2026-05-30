import CoreGraphics
import CoreMedia
import Domain
import Foundation
import ScreenCaptureKit

// MARK: - ScreenCaptureSource

/// Infrastructure implementation of `CaptureSource` for screen capture via `SCStream`.
///
/// ## Design overview
///
/// `ScreenCaptureSource` captures the main display and delivers timestamped
/// `CMSampleBuffer`s (backed by `IOSurface`) to a `SampleSink` on the
/// dedicated GCD serial queue `com.app.capture.screen`.
///
/// ### Concurrency / Sendable
///
/// `final class: NSObject` is required because `SCStreamOutput` and `SCStreamDelegate`
/// are ObjC protocols. The class is declared `@unchecked Sendable` because Swift's type
/// system cannot verify thread-safety automatically for NSObject subclasses, but safety
/// is established structurally:
///
/// - `sink` is accessed exclusively on `captureQueue`:
///   - Set via `captureQueue.sync` in `start` **before** `addStreamOutput`/`startCapture()`,
///     so it is visible to the first callback. At that point `captureQueue` is idle
///     (capture not yet started), so `.sync` runs instantly — no deadlock possible.
///     Cleared via `captureQueue.sync` in `stop` after `stopCapture` returns and the
///     queue has drained — a clean happens-before for the nil write.
///   - Read only inside `stream(_:didOutputSampleBuffer:ofType:)` which runs on
///     `captureQueue`. The queue serialises all reads and writes; no lock needed.
/// - `stream` and `streamConfig` are written on `configure`/`start` and read on `stop`,
///   all serialised by the coordinator (CaptureSource contract).
/// - The SCK callback queue (`com.app.capture.screen`) is the **only** thread that reads
///   `sink` during capture; the coordinator serialises `stop` such that `stopCapture`
///   has returned (and the queue has been flushed by `captureQueue.sync`) before `sink`
///   is nilled.
///
/// ### Display dimensions resolution
///
/// `CGMainDisplayID()` and `pixelSize(of:)` are resolved once in `configure(_:)` and
/// stored in `resolvedDisplayID` / `resolvedPixelSize`. `start(emittingTo:)` reuses
/// these stored values, so the main display is queried exactly once per session.
///
/// - Note: `SourceConfiguration.width/height` are intentionally **not** used for the
///   screen surface. The display's native pixel dimensions win (see `pixelSize(of:)`)
///   because `captureResolution = .best` must be paired with the actual pixel count to
///   avoid unnecessary scaling. Display selection (#30) will extend `SourceConfiguration`
///   with a display identifier; for MVP the main display is always targeted.
///
/// ### Display selection seam
///
/// Currently targets `CGMainDisplayID()`. Display selection (#30/#31) will pass
/// a `CGDirectDisplayID` via `SourceConfiguration` (or a new domain type).
/// The display-resolution helper `pixelSize(of:)` is the seam point: swap the
/// display identifier there, and the rest of the pipeline is unchanged.
public final class ScreenCaptureSource: NSObject, CaptureSource, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{

    // MARK: - CaptureSource: kind

    public let kind: SourceKind = .screen

    // MARK: - CaptureSource: sourceClock

    /// The host-time clock used by SCStream to timestamp `CMSampleBuffer`s.
    ///
    /// SCStream delivers buffers stamped on `CMClockGetHostTimeClock()`.
    /// The recording-session coordinator (#34) reconciles PTS via
    /// `ClockProviding.convert(_:from:)` when aligning multiple sources.
    public let sourceClock: CMClock = CMClockGetHostTimeClock()

    // MARK: - Private state

    /// The GCD queue on which SCStream delivers sample buffers.
    ///
    /// All hot-path work (status check + emit) executes on this queue.
    /// No actor hops occur between here and `SampleSink.receive`.
    /// `sink` reads and writes are also serialised through this queue (see Sendable note).
    private let captureQueue = DispatchQueue(label: "com.app.capture.screen")

    /// The prepared `SCStreamConfiguration`; stored after `configure(_:)`.
    private var streamConfig: SCStreamConfiguration?

    /// The live stream; non-nil between successful `start` and `stop`.
    private var stream: SCStream?

    /// The downstream sample sink.
    ///
    /// All accesses (reads and writes) go through `captureQueue` to serialise
    /// with the hot-path callback. Set via `captureQueue.sync` in `start` before
    /// capture begins (visible to the first callback); cleared via `captureQueue.sync`
    /// in `stop` after `stopCapture` returns (after all callbacks have drained).
    private var sink: (any SampleSink)?

    /// Display ID resolved during `configure(_:)`. Reused in `start(emittingTo:)` to
    /// avoid calling `CGMainDisplayID()` twice per session.
    private var resolvedDisplayID: CGDirectDisplayID?

    // MARK: - CaptureSource: configure

    /// Builds and stores the `SCStreamConfiguration` for the main display.
    ///
    /// Also resolves and stores the main display ID and its native pixel dimensions so
    /// `start(emittingTo:)` can reuse them without a second `CGMainDisplayID()` call.
    ///
    /// - Parameter config: Capture parameters (fps) from the coordinator.
    ///
    /// - Throws: Never in practice — the protocol requires `throws` for conformance.
    ///   (The display-not-found path is guarded at runtime in `start`; `configure` has
    ///   no async work and cannot fail on a running system.)
    public func configure(_ config: SourceConfiguration) throws {
        let displayID = CGMainDisplayID()
        let (pixelW, pixelH) = pixelSize(of: displayID)
        let maxFPS = mainScreenMaxFPS()
        resolvedDisplayID = displayID
        streamConfig = ScreenCaptureSource.makeStreamConfiguration(
            pixelWidth: pixelW,
            pixelHeight: pixelH,
            fps: config.fps,
            displayMaxFPS: maxFPS
        )
        Log.capture.debug(
            "configure: pixelW=\(pixelW) pixelH=\(pixelH) fps=\(config.fps) maxFPS=\(maxFPS)"
        )
    }

    // MARK: - CaptureSource: start

    /// Resolves the main display, creates and starts the `SCStream`, and begins
    /// delivering frames to `sink`.
    ///
    /// - Parameter sink: The downstream sample router.
    ///
    /// - Throws:
    ///   - `ScreenCaptureError.notConfigured` if `configure` was not called first.
    ///   - `ScreenCaptureError.shareableContentUnavailable` if TCC is denied or
    ///     `SCShareableContent.current` fails.
    ///   - `ScreenCaptureError.displayNotFound` if the main display is not in the
    ///     shareable content list (cannot occur on a normal system).
    ///   - `ScreenCaptureError.startCaptureFailed` if `startCapture` returns an error.
    ///   - Any `NSError` thrown by `addStreamOutput`.
    public func start(emittingTo sink: any SampleSink) async throws {
        guard let config = streamConfig, let mainDisplayID = resolvedDisplayID else {
            throw ScreenCaptureError.notConfigured
        }

        // Fetch shareable content — async, no thread blocking.
        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.current
        } catch {
            throw ScreenCaptureError.shareableContentUnavailable(error)
        }

        guard let display = shareableContent.displays.first(where: { $0.displayID == mainDisplayID })
        else {
            throw ScreenCaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)

        // Set sink before addStreamOutput/startCapture so it is guaranteed visible to
        // the first callback. captureQueue is idle here (capture not yet started), so
        // .sync runs instantly — no deadlock. All subsequent sink reads on captureQueue
        // see this write (single-queue confinement, no lock needed).
        captureQueue.sync { self.sink = sink }

        do {
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            // addStreamOutput failed; clear the sink set above before rethrowing.
            captureQueue.sync { self.sink = nil }
            throw error
        }

        // Start the stream — async, no thread blocking.
        do {
            try await newStream.startCapture()
        } catch {
            // startCapture failed; clear the sink set above before rethrowing.
            captureQueue.sync { self.sink = nil }
            throw ScreenCaptureError.startCaptureFailed(error)
        }

        self.stream = newStream
        Log.capture.info("recording.start source=screen")
    }

    // MARK: - CaptureSource: stop

    /// Stops the stream and releases the sink reference. Idempotent.
    ///
    /// `stopCapture()` is awaited directly. After it returns, `sink` is nilled on
    /// `captureQueue` so the write is serialised with any in-flight callback reads:
    /// SCK guarantees no more callbacks are delivered after `stopCapture` resolves,
    /// so the `captureQueue.sync` after that point establishes a clean happens-before.
    public func stop() async {
        guard let liveStream = stream else { return }
        stream = nil

        do {
            try await liveStream.stopCapture()
        } catch {
            Log.emitSourceFailure(kind: .screen, error: error)
        }

        // Nil the sink on captureQueue to serialise with the hot-path callback.
        // SCK guarantees no more didOutputSampleBuffer callbacks after stopCapture
        // returns, so this sync serves as the happens-before fence.
        captureQueue.sync { self.sink = nil }
        Log.capture.info("recording.stop source=screen")
    }

    // MARK: - SCStreamDelegate

    /// Called by SCK when the stream stops unexpectedly mid-capture (e.g. TCC revocation).
    ///
    /// Logs the failure so it is visible in system logs and `Instruments`. Full
    /// `isolateAndContinue` coordinator routing is deferred to #36.
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.emitSourceFailure(kind: .screen, error: error)
    }

    // MARK: - SCStreamOutput (hot path)

    /// Called by SCStream on `com.app.capture.screen` for every delivered buffer.
    ///
    /// ## Hot-path discipline (architecture §hot path)
    ///
    /// This method runs on `com.app.capture.screen`. It does ONLY:
    /// 1. Guard the output type and frame status.
    /// 2. Call `sink.receive(_:kind:)` — zero-copy: the `CMSampleBuffer` wraps
    ///    the `IOSurface`/`CVPixelBuffer` directly; no pixel data is copied.
    ///
    /// No actor hops, no locks, no per-frame allocations. Buffer hold time is bounded
    /// by the duration of `sink.receive`, which must return before the next frame's
    /// deadline (`minimumFrameInterval × (queueDepth − 1)`).
    ///
    /// ## Non-complete statuses
    ///
    /// `.idle` — no change on display; `.blank` — display off; `.suspended` —
    /// updates suspended; `.started` — first frame marker; `.stopped` — stream
    /// stopping. None of these represent dropped frames by the capture layer —
    /// they are normal operating states. Only `.complete` carries new pixel data.
    ///
    /// ## Capture-layer drop accounting
    ///
    /// `Log.emitFrameDropped` is NOT called here. Emission to the sink is
    /// fire-and-forget (the sink owns backpressure via `SampleRouter`); non-complete
    /// statuses are expected operating states, not drops. Full `DroppedFrameStats`
    /// aggregation is deferred to #39.
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard ScreenCaptureSource.shouldEmit(sampleBuffer) else { return }
        guard let sink else {
            // sink is set on captureQueue before capture starts and cleared on captureQueue
            // after stopCapture returns. Reaching here means a callback fired outside the
            // [set, clear] window — an SCK delivery guarantee violation that should not occur.
            Log.capture.error(
                "ScreenCaptureSource: sink is nil on capture queue — frame skipped"
            )
            return
        }
        // Zero-copy: CMSampleBuffer wraps IOSurface — no pixel copy occurs here.
        sink.receive(sampleBuffer, kind: .screen)
    }
}

// MARK: - Testable pure functions

extension ScreenCaptureSource {

    // MARK: SCStreamConfiguration factory

    /// Builds an `SCStreamConfiguration` from validated primitives.
    ///
    /// Extracted as a `static func` so it can be unit-tested without a real display.
    ///
    /// - Parameters:
    ///   - pixelWidth: Native pixel width of the target display.
    ///   - pixelHeight: Native pixel height of the target display.
    ///   - fps: Requested capture rate (from `SourceConfiguration`). Floored at 1 to
    ///     prevent a zero or negative timescale in `CMTime`, which would be invalid.
    ///   - displayMaxFPS: The display's reported maximum refresh rate.
    ///     `fps` is clamped to `min(fps, displayMaxFPS)` to prevent requesting
    ///     frames faster than the display can produce them.
    ///
    /// - Returns: A fully configured `SCStreamConfiguration` ready for use.
    static func makeStreamConfiguration(
        pixelWidth: Int,
        pixelHeight: Int,
        fps: Int,
        displayMaxFPS: Int
    ) -> SCStreamConfiguration {
        // Floor at 1: a zero or negative fps would produce CMTime(value:1, timescale:0)
        // which is kCMTimeInvalid and illegal as minimumFrameInterval.
        let clampedFPS = max(1, min(fps, displayMaxFPS))
        let config = SCStreamConfiguration()
        // captureResolution = .best: capture at the display's native resolution.
        // Must be paired with the display's actual pixel dimensions (see configure).
        config.captureResolution = .best
        config.width = pixelWidth
        config.height = pixelHeight
        // minimumFrameInterval throttles SCStream to at most `clampedFPS` frames/sec.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
        // 8-bit SDR BGRA. captureDynamicRange is intentionally not set (defaults to SDR).
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // queueDepth: spec §backpressure requires 5–6; 6 gives hold-time budget of 5 frame intervals.
        config.queueDepth = 6
        // showsCursor: default (true). Spec does not require hiding the cursor.
        return config
    }

    // MARK: Frame-status gate

    /// Returns `true` only when `sampleBuffer` carries a complete new frame.
    ///
    /// Extracted as a `static func` so it can be unit-tested independently.
    ///
    /// ## Implementation — CF-level read (no per-frame allocation)
    ///
    /// `SCFrameStatus` is stored as a `CFNumber` in the sample buffer's attachment
    /// dictionary under the `SCStreamFrameInfo.status.rawValue` key (a `CFString`).
    /// Reading via the CF API (`CFArrayGetValueAtIndex`, `CFDictionaryGetValue`,
    /// `CFNumberGetValue`) avoids the Swift bridge allocation that
    /// `CMSampleBufferGetSampleAttachmentsArray(...) as? [[SCStreamFrameInfo: Any]]`
    /// would incur on every frame — a per-frame heap cost on the hot path.
    ///
    /// Non-complete statuses (`.idle`, `.blank`, `.suspended`, `.started`,
    /// `.stopped`) indicate no new pixel data and are silently skipped.
    static func shouldEmit(_ sampleBuffer: CMSampleBuffer) -> Bool {
        // CF-level read: no Swift bridge, no allocation on the hot path.
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false)
        else {
            // No attachment array: conservative skip (unexpected state).
            return false
        }
        guard CFArrayGetCount(attachmentsArray) > 0 else { return false }

        // Unretained borrow — the array owns the dict; we don't need to retain it here.
        let rawDict = CFArrayGetValueAtIndex(attachmentsArray, 0)
        guard let rawDict else { return false }
        let dict = unsafeBitCast(rawDict, to: CFDictionary.self)

        // Key: SCStreamFrameInfo.status.rawValue bridged to CFString.
        let key = SCStreamFrameInfo.status.rawValue as CFString
        let rawValue = CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque())
        guard let rawValue else { return false }

        let cfNumber = Unmanaged<CFNumber>.fromOpaque(rawValue).takeUnretainedValue()
        var intValue: Int = 0
        guard CFNumberGetValue(cfNumber, .nsIntegerType, &intValue) else { return false }

        return intValue == SCFrameStatus.complete.rawValue
    }
}

// MARK: - Private helpers

extension ScreenCaptureSource {

    // MARK: Native pixel size

    /// Returns the native pixel dimensions of `displayID`.
    ///
    /// `SCDisplay.width/height` are in *points*, not pixels. On Retina displays
    /// points ≠ pixels (×`backingScaleFactor`). Using points for
    /// `SCStreamConfiguration.width/height` would capture at 1/4 resolution on
    /// a 2× Retina screen — a silent quality defect.
    ///
    /// `CGDisplayCopyDisplayMode` returns the actual hardware pixel count;
    /// it is the correct source for `captureResolution = .best`.
    ///
    /// Falls back to `SCDisplay`-equivalent via `NSScreen.main` scale if the
    /// display mode is unavailable (degenerate case).
    private func pixelSize(of displayID: CGDirectDisplayID) -> (Int, Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        // Fallback: CoreGraphics bounds × backing scale factor.
        // This path is not expected on a running system.
        let bounds = CGDisplayBounds(displayID)
        let scale =
            NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    == displayID
            })?.backingScaleFactor ?? 1.0
        Log.capture.warning(
            "CGDisplayCopyDisplayMode returned nil for displayID=\(displayID); using fallback pixel size"
        )
        return (Int(bounds.width * scale), Int(bounds.height * scale))
    }

    // MARK: Display max FPS

    /// Returns `NSScreen.maximumFramesPerSecond` for the main screen.
    ///
    /// `NSScreen.main` is the screen containing the key window (focused screen),
    /// which may differ from `CGMainDisplayID()` on multi-display setups. For
    /// MVP single-display capture this is always the same screen. Display
    /// selection (#30/#31) should match by `NSScreenNumber` in `deviceDescription`
    /// for precise alignment.
    private func mainScreenMaxFPS() -> Int {
        NSScreen.main?.maximumFramesPerSecond ?? 60
    }
}

// MARK: - Error type

/// Errors thrown by `ScreenCaptureSource`.
public enum ScreenCaptureError: Error {
    /// `start(emittingTo:)` was called before `configure(_:)`.
    case notConfigured
    /// `SCShareableContent.current` failed (TCC denied, system error, etc.).
    case shareableContentUnavailable(Error?)
    /// The main display was not found in `SCShareableContent.displays`.
    case displayNotFound
    /// `SCStream.startCapture` completed with an error.
    case startCaptureFailed(Error)
}
