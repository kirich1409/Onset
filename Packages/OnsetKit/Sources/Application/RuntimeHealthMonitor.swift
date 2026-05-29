import Foundation

// MARK: - RuntimeHealthMonitor

/// Monitors runtime health signals and surfaces them to the session coordinator.
///
/// Runs as an `actor` because it will own mutable aggregated runtime stats
/// (DroppedFrameStats accumulation, #39) on the control plane. Actor isolation
/// ensures those mutations are safe without locks. (A plain `final class` holding
/// only the immutable `ProcessInfo` `let` would be implicitly `Sendable`, but this
/// type is designed to grow stateful aggregation — actor is the right primitive here.)
///
/// Current capability: reads the system thermal state on demand via `ProcessInfo`.
///
/// - Note: Dropped-frame statistics aggregation is deferred to issue #39/#41.
///   When `DroppedFrameStats` lands, add an accumulation seam here (see TODO below).
public actor RuntimeHealthMonitor {

    // MARK: Dependencies

    /// `ProcessInfo` provider. Injected via init for testability (default: `.processInfo`).
    private let processInfo: ProcessInfo

    // MARK: Initializer

    /// Creates a `RuntimeHealthMonitor`.
    ///
    /// - Parameter processInfo: The `ProcessInfo` instance to query for system state.
    ///   Provide a substitute in tests if needed; in production the default suffices.
    public init(processInfo: ProcessInfo = .processInfo) {
        self.processInfo = processInfo
    }

    // MARK: Thermal state

    /// The current system thermal state.
    ///
    /// Reads `ProcessInfo.thermalState` synchronously. Call from the session coordinator's
    /// control plane only (not from a hot sample path).
    public var thermalState: ProcessInfo.ThermalState {
        processInfo.thermalState
    }

    // MARK: Seam — DroppedFrameStats aggregation (#39/#41)
    //
    // TODO(#39/#41): When `DroppedFrameStats` is defined, add accumulation here, e.g.:
    //   func record(_ stats: DroppedFrameStats) { ... }
    //   func currentStats() -> DroppedFrameStats { ... }
    //
    // The seam receives events from the hot path via an actor-hop-safe enqueue mechanism
    // (e.g. a non-isolated nonisolated method that schedules the actor work), ensuring
    // the hot path itself is never blocked.
}
