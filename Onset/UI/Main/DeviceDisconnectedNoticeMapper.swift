// MARK: - DeviceDisconnectedNoticeMapper

/// Pure formatter for the "selected device disappeared" notice shown in the main window's
/// device pickers (#261).
///
/// `DeviceSelectionResolver` already detects the disconnected-device case
/// (`.disconnected(savedName:)`); this mapper turns that outcome into explicit, user-facing text
/// — what dropped and what to do — so the picker never falls back to reading as a silent
/// "Выключен"/empty selection. Mirrors the existing camera notice (`CameraUnavailableRow`) but
/// is the single, testable source of the copy for both roles.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
/// enables direct use from tests without an actor context.
nonisolated enum DeviceDisconnectedNoticeMapper {
    /// Which capture role the notice describes — drives grammatical gender agreement
    /// ("недоступна" for the feminine «камера», "недоступен" for the masculine «микрофон»)
    /// and the alternative-device hint noun.
    enum DeviceKind: Equatable {
        case camera
        case microphone

        fileprivate var nominativeLabel: String {
            switch self {
            case .camera: "Камера"
            case .microphone: "Микрофон"
            }
        }

        fileprivate var unavailableWord: String {
            switch self {
            case .camera: "недоступна"
            case .microphone: "недоступен"
            }
        }

        fileprivate var alternativeHint: String {
            switch self {
            case .camera: "выберите другую камеру"
            case .microphone: "выберите другой микрофон"
            }
        }
    }

    /// Visible row text explaining the disconnected device.
    ///
    /// - Parameters:
    ///   - kind: Camera or microphone — drives gender agreement and the hint noun.
    ///   - name: The saved device's display name (UI only — never logged, PII policy).
    ///   - hasAlternatives: `true` when other devices of the same role are currently available,
    ///     appending a hint to pick one; `false` when there is nothing to switch to.
    static func rowText(kind: DeviceKind, name: String, hasAlternatives: Bool) -> String {
        let base = "\(kind.nominativeLabel) «\(name)» \(kind.unavailableWord)"
        return hasAlternatives ? "\(base) — \(kind.alternativeHint)" : base
    }

    /// VoiceOver label for the notice row — same content as `rowText`, phrased as a full sentence.
    static func accessibilityLabel(kind: DeviceKind, name: String, hasAlternatives: Bool) -> String {
        "\(self.rowText(kind: kind, name: name, hasAlternatives: hasAlternatives))."
    }
}
