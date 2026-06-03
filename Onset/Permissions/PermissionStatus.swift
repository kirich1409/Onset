/// Permission authorization status shared across all permission types.
///
/// Intentionally limited to four cases. The "Ожидание…" (awaiting) in-flight state
/// for screen recording is modelled in the VM layer (Stage 4), not here — keeping
/// this enum as a clean TCC-status mirror avoids leaking UI concepts into the domain.
///
/// `Equatable` is implemented manually with `nonisolated` to remain usable from any
/// isolation context without actor hopping. This is necessary because Swift 6's
/// `InferIsolatedConformances` feature (enabled automatically in Swift 6 mode) would
/// otherwise infer `@MainActor` isolation on synthesized conformances under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
enum PermissionStatus: CustomStringConvertible {
    /// The user has not been asked for this permission yet.
    case notDetermined
    /// The permission has been explicitly granted.
    case authorized
    /// The permission has been explicitly denied by the user.
    case denied
    /// The permission is restricted by device policy (e.g. parental controls, MDM).
    case restricted

    // MARK: - CustomStringConvertible (required for os.Logger string interpolation)

    nonisolated var description: String {
        switch self {
        case .notDetermined:
            "notDetermined"

        case .authorized:
            "authorized"

        case .denied:
            "denied"

        case .restricted:
            "restricted"
        }
    }
}

extension PermissionStatus: Equatable {
    /// Manual implementation so `==` is `nonisolated` and usable from any isolation context.
    nonisolated static func == (lhs: PermissionStatus, rhs: PermissionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notDetermined, .notDetermined),
             (.authorized, .authorized),
             (.denied, .denied),
             (.restricted, .restricted):
            true

        default:
            false
        }
    }
}
