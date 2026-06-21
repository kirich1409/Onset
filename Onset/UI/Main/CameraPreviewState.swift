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
///
/// `nonisolated` so the pure label/announcement helpers below can read it without a
/// MainActor hop (it carries no conformances, so this is free).
nonisolated enum CameraPreviewState {
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

// MARK: - Preview placeholder label (single source of text, #256)

/// Pure source of the camera-preview placeholder text (#256).
///
/// Extracted from the view's `cameraPlaceholderLabel` so the VoiceOver announcement
/// (`previewAnnouncement`) and the visible label read the SAME string instead of
/// duplicating literals that could drift apart (red-team finding). `nonisolated` pure
/// helper, mirroring `MenuBarLabelMapper` / `CameraPreviewTimeout`.
///
/// Branches on the preview state + whether the device is a Continuity (iPhone) camera —
/// 1:1 with the prior view logic. `.idle` and `.connecting` both yield the "connecting"
/// copy (as before); `.live` has no placeholder (returns `nil`).
///
/// NB: this label covers the *preview* surface only. The involuntary-disconnect notice
/// (`CameraUnavailableRow` "…недоступна") and the disconnect announcement ("…отключена")
/// are deliberately distinct strings on a different surface — see `cameraDisconnectAnnouncement`.
nonisolated enum CameraPreviewLabel {
    /// Placeholder/announcement text for a preview state, or `nil` when the preview is
    /// live (no placeholder shown). Final wording is a user copy decision (not finalized
    /// by agents) — placeholder copy here.
    static func text(for state: CameraPreviewState, isContinuity: Bool) -> String? {
        switch state {
        case .live:
            nil

        case .failed:
            isContinuity ? "Не удалось подключить iPhone" : "Не удалось подключить камеру"

        case .connectingSlow:
            // #255 slow-connect: keep the spinner but carry recovery guidance (what to do),
            // not just status — a "soft" timeout must be actionable.
            isContinuity
                ? "Подключение занимает больше обычного. Разбудите iPhone или поднесите ближе."
                : "Подключение занимает больше обычного. Проверьте, что камера включена и подключена."

        case .idle, .connecting:
            isContinuity ? "Подключение iPhone…" : "Подключение камеры…"
        }
    }
}

// MARK: - VoiceOver announcement policy (#256)

/// A VoiceOver announcement to post: the spoken text plus whether it should interrupt
/// (high priority) or queue behind current speech (normal priority).
nonisolated struct PreviewAnnouncement {
    /// The text VoiceOver speaks. Equals the visible label (single source) where applicable.
    let text: String
    /// `true` → interrupt current speech (e.g. a hanging "slow" notice); `false` → normal.
    let isHighPriority: Bool
}

/// Posting policy for a preview-state transition (#256). `nil` = do not announce.
///
/// Anti-spam policy (ux finding — a sub-second `connecting→live` would otherwise speak
/// "Подключение… Подключено"):
/// - `→ .connecting`: `nil` — the spinner + on-focus label cover the start; staying silent
///   avoids spamming on a fast connect.
/// - `→ .connectingSlow`: status + recovery guidance, normal priority.
/// - `→ .live`: "Камера подключена", normal priority (a single announcement, not a pair —
///   `connecting` was never spoken).
/// - `→ .failed`: the visible failure label, high priority (interrupts a hanging slow notice).
/// - `→ .idle`: `nil`.
///
/// Reuses `CameraPreviewLabel` for the text so announcement and visible label cannot drift.
nonisolated func previewAnnouncement(
    from old: CameraPreviewState,
    to new: CameraPreviewState,
    isContinuity: Bool
)
-> PreviewAnnouncement? {
    switch new {
    case .connecting, .idle:
        return nil

    case .connectingSlow:
        guard let text = CameraPreviewLabel.text(for: new, isContinuity: isContinuity) else { return nil }
        return PreviewAnnouncement(text: text, isHighPriority: false)

    case .live:
        return PreviewAnnouncement(text: "Камера подключена", isHighPriority: false)

    case .failed:
        guard let text = CameraPreviewLabel.text(for: new, isContinuity: isContinuity) else { return nil }
        return PreviewAnnouncement(text: text, isHighPriority: true)
    }
}

// MARK: - Camera disconnect announcement (#256)

/// Posting policy for an involuntary live-camera disconnect (#256). `nil` = do not announce.
///
/// Distinct from `previewAnnouncement`: the dominant disconnect flow nils `selectedCameraID`,
/// so the preview goes to `.idle` (announced `nil`) and the silent `CameraUnavailableRow` is
/// drawn — leaving an unfocused VoiceOver user with no signal. This fires a high-priority
/// announcement at the single real live-unplug site.
///
/// Gated by `hasObservedPresentCamera`: only announce if the camera was ever seen present this
/// session, so launching with a saved-but-absent camera does not speak a spurious "…отключена".
/// The wording mirrors the visible `CameraUnavailableRow` ("…недоступна") but uses "отключена"
/// to convey the *event* (just disconnected) rather than the static state — final copy is a
/// user decision.
nonisolated func cameraDisconnectAnnouncement(
    name: String,
    hasObservedPresentCamera: Bool
)
-> PreviewAnnouncement? {
    guard hasObservedPresentCamera else { return nil }
    return PreviewAnnouncement(text: "Камера «\(name)» отключена", isHighPriority: true)
}
