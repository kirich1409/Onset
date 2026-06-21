// MARK: - CameraPreviewState

/// Progress state of the camera preview connection.
///
/// Replaces the previously independent pair (`previewHandle: SessionHandle?`,
/// `previewFailed: Bool`) with a single exhaustive enum, eliminating the illegal
/// combination "handle set AND failed". Reads are exposed back to the view through
/// get-only computed bridges (`previewHandle`/`previewFailed`/`previewIsConnectingSlow`),
/// so existing predicates and view read-sites stay unchanged.
///
/// `isCameraActive` (`cameraEnabled && selectedCamera`) is an INDEPENDENT axis by
/// design and is intentionally NOT folded into this enum.
///
/// The `.idle`/`.connecting`/`.connectingSlow` cases are only distinguished for the
/// follow-up timeout (#255) and VoiceOver-announcement (#256) work; for the #254
/// predicates they all collapse to "handle nil, not failed".
///
/// Deliberately NOT `Equatable`: `SessionHandle` wraps a non-`Sendable`
/// `AVCaptureSession` and is not `Equatable`. All consumers branch via `if case`.
enum CameraPreviewState {
    /// Preview not running (camera disabled OR torn down).
    case idle
    /// A connection attempt is in progress (valid camera, handle not yet available).
    case connecting
    /// #255: the slow-connect threshold was exceeded, still attempting (non-terminal).
    case connectingSlow
    /// Preview is live; carries the session handle used to build the preview layer.
    case live(SessionHandle)
    /// Explicit startup failure / hot-unplug (terminal until the camera is re-selected).
    case failed
}

// MARK: - Connect-timeout policy (#255)

/// Soft-connect timeout thresholds for the preview watchdog (#255).
///
/// Continuity (iPhone) cameras need a longer grace period than built-in / USB cameras:
/// the iPhone may wake, re-join the network, or re-establish the AirPlay link mid-connect,
/// so a premature "slow" notice would be misleading. Built-in / USB cameras come up fast,
/// so a shorter threshold surfaces a genuinely stuck connection sooner.
///
/// `nonisolated` pure helper (state-free, no MainActor hop) — mirrors `MenuBarLabelMapper`
/// / `CFRNormalizer`. The thresholds are orientation values from #255; finalize on L5 with
/// real Continuity hardware.
nonisolated enum CameraPreviewTimeout {
    // swiftlint:disable no_magic_numbers
    // Threshold seconds are named constants here; the literals are the definition site.
    /// Grace period before a connecting Continuity (iPhone) preview is flagged as slow.
    static let continuity: Duration = .seconds(10)
    /// Grace period before a connecting built-in / USB preview is flagged as slow.
    static let builtInOrUSB: Duration = .seconds(5)
    // swiftlint:enable no_magic_numbers

    /// Threshold after which a still-`.connecting` preview flips to `.connectingSlow`.
    static func threshold(isContinuity: Bool) -> Duration {
        isContinuity ? self.continuity : self.builtInOrUSB
    }
}
