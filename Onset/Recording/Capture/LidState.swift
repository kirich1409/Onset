import IOKit

/// Reads the notebook lid (clamshell) state from IOKit.
nonisolated enum LidState {
    /// `true` when the notebook lid is closed (clamshell with an external display).
    ///
    /// Reads `AppleClamshellState` from `IOPMrootDomain`. Returns `false` when the key
    /// is absent (desktop Macs / no lid) — correct, since those have no built-in mic to hide.
    ///
    /// The pointer-returning IOKit calls are marked `unsafe` under SWIFT_STRICT_MEMORY_SAFETY;
    /// `IOObjectRelease` (an integer-handle call) is not. `IOObjectRelease` runs unconditionally
    /// via `defer`, and `takeRetainedValue()` transfers ownership of the copied property.
    static var isClosed: Bool {
        let service = unsafe IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let unmanaged = unsafe IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return false }
        let value = unsafe unmanaged.takeRetainedValue()
        return (value as? Bool) == true
    }
}
