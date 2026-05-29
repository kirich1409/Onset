import AVFoundation
import CoreGraphics
import Domain
import Foundation

// MARK: - PermissionsManager

/// Infrastructure implementation of `PermissionsProviding`.
///
/// Wraps native TCC APIs:
/// - **Screen Recording**: CoreGraphics `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`
/// - **Camera**: `AVCaptureDevice.authorizationStatus(for: .video)` / `requestAccess(for: .video)`
/// - **Microphone**: `AVCaptureDevice.authorizationStatus(for: .audio)` / `requestAccess(for: .audio)`
///
/// `UserDefaults` is injected via the initializer (mirroring `SettingsStore`) — the manager
/// never reaches `UserDefaults.standard` inside method bodies (AC: no hidden-singleton access).
///
/// A `final class` (not an actor) because `status(for:)` is synchronous; actor isolation
/// would force the method async or `nonisolated`, which adds friction without benefit.
public final class PermissionsManager: PermissionsProviding {

    // MARK: - Dependencies

    /// The backing key-value store for persisted permission state.
    /// Injected via init — never accessed as a global singleton inside method bodies.
    ///
    /// Marked `nonisolated(unsafe)` because `UserDefaults` is not declared `Sendable` in the
    /// SDK headers, but its documentation guarantees thread-safe read/write access. This
    /// annotation acknowledges that contract explicitly rather than hiding it behind
    /// `@unchecked Sendable` on the whole class.
    private nonisolated(unsafe) let defaults: UserDefaults

    // MARK: - Persisted keys

    /// Key that records whether the screen-recording request dialog has been triggered
    /// at least once. Used to distinguish `.notDetermined` from `.denied` for screen
    /// recording, since `CGPreflightScreenCaptureAccess()` returns a plain `Bool` with
    /// no way to distinguish the two states.
    private static let screenRecordingRequestedKey = "onset.permissions.screenRecording.requested"

    // MARK: - Initializer

    /// Creates a `PermissionsManager` backed by the given `UserDefaults` instance.
    ///
    /// - Parameter defaults: The `UserDefaults` to read and write persisted permission
    ///   state from. Pass a suite-namespaced instance in tests
    ///   (`UserDefaults(suiteName: UUID().uuidString)`) to isolate test state from the
    ///   application's real preferences store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - PermissionsProviding

    /// Returns the current TCC authorization status for `kind` without triggering a dialog.
    ///
    /// ### Screen Recording
    /// `CGPreflightScreenCaptureAccess()` returns a `Bool` — the OS provides no four-state
    /// enum for screen recording the way AVFoundation does for camera/mic. To distinguish
    /// `.notDetermined` (never requested) from `.denied` (user or policy denied), this
    /// implementation persists a "have we ever requested" flag in `UserDefaults`:
    /// - Flag **false** (never requested) → `.notDetermined`
    /// - Flag **true** + preflight returns `true` → `.authorized`
    /// - Flag **true** + preflight returns `false` → `.denied`
    ///
    /// This allows the `configuring→ready` gate (#36) to correctly detect first-run state
    /// rather than misreporting `.denied` before any dialog has appeared.
    public func status(for kind: PermissionKind) -> PermissionStatus {
        let result: PermissionStatus
        switch kind {
        case .screenRecording:
            let hasRequested = defaults.bool(forKey: Self.screenRecordingRequestedKey)
            if hasRequested {
                result = CGPreflightScreenCaptureAccess() ? .authorized : .denied
            } else {
                result = .notDetermined
            }
        case .camera:
            result = PermissionsManager.mapAVStatus(
                AVCaptureDevice.authorizationStatus(for: .video)
            )
        case .microphone:
            result = PermissionsManager.mapAVStatus(
                AVCaptureDevice.authorizationStatus(for: .audio)
            )
        }
        Log.emitPermission(type: kind.logLabel, status: "preflight:\(result.logLabel)")
        return result
    }

    /// Requests authorization for `kind`, returning the resulting status.
    ///
    /// For `.camera` and `.microphone`, suspends until the user responds to the TCC dialog
    /// (or returns immediately if already determined). For `.screenRecording`, sets the
    /// persisted "requested" flag, calls `CGRequestScreenCaptureAccess()` (which may show
    /// a one-time dialog or direct the user to System Settings on macOS), then re-reads
    /// the status via `CGPreflightScreenCaptureAccess`.
    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        let result: PermissionStatus
        switch kind {
        case .screenRecording:
            // Mark that we have requested at least once, so subsequent status() calls
            // correctly return .authorized or .denied rather than .notDetermined.
            defaults.set(true, forKey: Self.screenRecordingRequestedKey)
            Log.emitPermission(type: kind.logLabel, status: "requesting")
            // CGRequestScreenCaptureAccess returns a Bool immediately; on macOS the system
            // may also show a dialog directing the user to System Settings for Screen Recording.
            _ = CGRequestScreenCaptureAccess()
            result = CGPreflightScreenCaptureAccess() ? .authorized : .denied
        case .camera:
            await AVCaptureDevice.requestAccess(for: .video)
            result = PermissionsManager.mapAVStatus(
                AVCaptureDevice.authorizationStatus(for: .video)
            )
        case .microphone:
            await AVCaptureDevice.requestAccess(for: .audio)
            result = PermissionsManager.mapAVStatus(
                AVCaptureDevice.authorizationStatus(for: .audio)
            )
        }
        Log.emitPermission(type: kind.logLabel, status: "requested:\(result.logLabel)")
        return result
    }

    // MARK: - Internal mapping

    /// Maps `AVAuthorizationStatus` to `PermissionStatus`.
    ///
    /// Extracted as a `static func` so it can be unit-tested without touching the live OS.
    /// `AVAuthorizationStatus` is an imported non-frozen Obj-C enum; `@unknown default`
    /// handles any future cases safely by mapping them to `.denied` (a non-authorized status
    /// is the safe conservative fallback — better to deny access than silently allow it).
    static func mapAVStatus(_ avStatus: AVAuthorizationStatus) -> PermissionStatus {
        switch avStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            // Future AVAuthorizationStatus value: treat as denied (safe conservative fallback).
            // Log at warning level so a future OS enum addition is surfaced, not silently coerced.
            Log.permission.warning(
                "AVAuthorizationStatus unknown raw=\(avStatus.rawValue, privacy: .public); treating as denied"
            )
            return .denied
        }
    }
}

// MARK: - Private helpers

extension PermissionKind {
    fileprivate var logLabel: String {
        switch self {
        case .screenRecording: return "screen"
        case .camera: return "camera"
        case .microphone: return "microphone"
        }
    }
}

extension PermissionStatus {
    fileprivate var logLabel: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        }
    }
}
