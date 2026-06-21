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
