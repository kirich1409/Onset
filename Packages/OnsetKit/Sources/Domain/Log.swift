import os

// Sanctioned logging facade for Onset. All layers import Domain, so this facade
// is available everywhere. The no-print gate enforces use of this facade over bare output.
//
// Design — static facade vs injectable logger:
//   `os.Logger` is a stateless, thread-safe value type — holding one costs nothing and there
//   is no mutable control-plane state here. The static `Log` facade is therefore NOT the kind
//   of hidden singleton that the architecture bans (which targets hot-path mutable state).
//   Components that need test-observability of emitted events (e.g. to assert a specific event
//   was fired) can inject a logging sink at a higher layer without changing this facade.
//   If that need arises, add a `LogSink` protocol in Application and wire it via the
//   composition root — this file stays as the emit mechanism.
//
// Usage:
//   Log.general.debug("message")
//   Log.recording.info("session started")
//   Log.emitRecordingStart()
public enum Log {

    // MARK: - Subsystem

    private static let subsystem = "dev.androidbroadcast.onset"

    // MARK: - Per-area categories

    /// General-purpose logger; used when no narrower category applies.
    public static let general = Logger(subsystem: subsystem, category: "general")

    /// Recording session lifecycle (start, stop, state transitions).
    public static let recording = Logger(subsystem: subsystem, category: "recording")

    /// Capture-source operations (ScreenCaptureKit / AVCapture callbacks).
    public static let capture = Logger(subsystem: subsystem, category: "capture")

    /// Encoding writer operations (AVAssetWriter, VideoToolbox, file I/O).
    public static let writer = Logger(subsystem: subsystem, category: "writer")

    /// Degradation-ladder decisions and quality-step changes.
    public static let degradation = Logger(subsystem: subsystem, category: "degradation")

    /// Hardware capability probes and codec availability checks.
    public static let capability = Logger(subsystem: subsystem, category: "capability")

    /// Permission request and authorization-status changes.
    public static let permission = Logger(subsystem: subsystem, category: "permission")

    // MARK: - Legacy convenience helpers (keep existing call sites compiling)

    /// Emits a debug message on the given category logger.
    ///
    /// Prefer calling a category logger directly (e.g. `Log.recording.debug(…)`).
    public static func debug(_ message: String, category: String = "general") {
        Logger(subsystem: subsystem, category: category)
            .debug("\(message, privacy: .public)")
    }

    /// Emits an error message on the given category logger.
    ///
    /// Prefer calling a category logger directly (e.g. `Log.writer.error(…)`).
    public static func error(_ message: String, category: String = "general") {
        Logger(subsystem: subsystem, category: category)
            .error("\(message, privacy: .public)")
    }

    // MARK: - Standard event helpers

    // ── recording.start ──────────────────────────────────────────────────────

    /// Emits the `recording.start` standard event.
    ///
    /// Call this once when the session transitions into `.recording` state.
    public static func emitRecordingStart() {
        recording.info("recording.start")
    }

    // ── recording.stop ───────────────────────────────────────────────────────

    /// Emits the `recording.stop` standard event with a basic drop summary.
    ///
    /// - Parameter droppedFrameCount: Total frames dropped across all sources during the
    ///   session. Defaults to 0 for callers that do not yet track drops.
    ///
    /// - Note: Issue #39 (`DroppedFrameStats`) will enrich this call site with a typed
    ///   summary struct once that type is available. The `droppedFrameCount` parameter
    ///   is a forward-compatible shim.
    public static func emitRecordingStop(droppedFrameCount: Int = 0) {
        recording.info(
            "recording.stop droppedFrames=\(droppedFrameCount, privacy: .public)"
        )
    }

    // ── frame.dropped ────────────────────────────────────────────────────────

    /// Emits the `frame.dropped` standard event.
    ///
    /// - Parameters:
    ///   - source: The capture source that dropped the frame.
    ///   - reason: Why the frame was dropped (bounded queue overflow, pool exhaustion, etc.).
    public static func emitFrameDropped(source: SourceKind, reason: DropReason) {
        let msg = "frame.dropped source=\(source) reason=\(reason)"
        capture.notice("\(msg, privacy: .public)")
    }

    // ── source.failure ───────────────────────────────────────────────────────

    /// Emits the `source.failure` standard event.
    ///
    /// - Parameters:
    ///   - kind: The capture source that failed.
    ///   - error: The underlying error.
    public static func emitSourceFailure(kind: SourceKind, error: any Error) {
        let msg = "source.failure kind=\(kind) error=\(String(reflecting: error))"
        capture.error("\(msg, privacy: .public)")
    }

    // ── writer.failure ───────────────────────────────────────────────────────

    /// Emits the `writer.failure` standard event.
    ///
    /// - Parameters:
    ///   - output: The output file name or path that failed. Only the last path component
    ///     (everything after the final `/`) is logged to avoid leaking the macOS username
    ///     into sysdiagnose captures.
    ///   - error: The underlying error.
    ///   - isolated: `true` when the session applied `isolateAndContinue` — i.e. this writer
    ///     was finalized independently and the remaining writers are still running.
    public static func emitWriterFailure(output: String, error: any Error, isolated: Bool) {
        let filename = output.split(separator: "/").last.map(String.init) ?? output
        let msg =
            "writer.failure output=\(filename) isolated=\(isolated) error=\(String(reflecting: error))"
        writer.error("\(msg, privacy: .public)")
    }

    // ── degradation.step ─────────────────────────────────────────────────────

    /// Emits the `degradation.step` standard event.
    ///
    /// - Parameters:
    ///   - step: Human-readable identifier for the degradation rung (e.g. `"2"` or `"low-fps"`).
    ///   - trigger: What metric or condition caused the step (e.g. `"dropped>5%"`).
    ///   - cooldown: `true` when the step triggered a cooldown period during which further
    ///     degradation is suppressed.
    ///
    /// - Note: Issue #40 will introduce typed degradation-ladder types. When those land,
    ///   replace the primitive `step`/`trigger` parameters with the appropriate Domain value.
    public static func emitDegradationStep(step: String, trigger: String, cooldown: Bool) {
        let msg = "degradation.step step=\(step) trigger=\(trigger) cooldown=\(cooldown)"
        degradation.warning("\(msg, privacy: .public)")
    }

    // ── capability.probe ─────────────────────────────────────────────────────

    /// Emits the `capability.probe` standard event.
    ///
    /// - Parameters:
    ///   - hardwareHEVC: `true` when `VTCompressionSession` reports `IsHardwareAccelerated`
    ///     for HEVC on the current device.
    ///   - encoderCount: Number of independent hardware encoder engines available
    ///     (on multi-engine chips, screen and camera each target a distinct engine).
    ///
    /// - Note: The field `UsingHardwareAcceleratedVideoEncoder` matches the NFR-HW acceptance
    ///   grep token (`UsingHardwareAcceleratedVideoEncoder==true`) used in L5 hardware acceptance
    ///   to verify that VideoToolbox reports hardware encoding active.
    public static func emitCapabilityProbe(hardwareHEVC: Bool, encoderCount: Int) {
        let msg =
            "capability.probe UsingHardwareAcceleratedVideoEncoder==\(hardwareHEVC) encoderCount=\(encoderCount)"
        capability.info("\(msg, privacy: .public)")
    }

    // ── permission ───────────────────────────────────────────────────────────

    /// Emits the `permission` standard event.
    ///
    /// - Parameters:
    ///   - type: The permission type as a string (e.g. `"screen"`, `"camera"`, `"microphone"`).
    ///   - status: The authorization status as a string (e.g. `"granted"`, `"denied"`).
    ///
    /// - Note: Issue #21 will introduce typed permission enums. When those land, replace
    ///   the primitive `type`/`status` parameters with the appropriate Domain types.
    public static func emitPermission(type: String, status: String) {
        let msg = "permission type=\(type) status=\(status)"
        permission.info("\(msg, privacy: .public)")
    }
}
