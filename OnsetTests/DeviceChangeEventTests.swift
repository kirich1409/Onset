@testable import Onset
import Testing

// MARK: - DeviceChangeEventTests

/// L2 tests for the pure `DeviceChangeEvent` reducer feeding `DeviceAvailabilityObserver`:
/// connect/disconnect changes the device set (KVO must be re-registered), a suspension
/// flip does not (the device set is unchanged — re-registration would be churn).
@Suite("DeviceChangeEvent — reobservation reducer")
struct DeviceChangeEventTests {
    @Test("connected requires KVO reobservation")
    func connected_requiresReobservation() {
        #expect(DeviceChangeEvent.connected.requiresReobservation)
    }

    @Test("disconnected requires KVO reobservation")
    func disconnected_requiresReobservation() {
        #expect(DeviceChangeEvent.disconnected.requiresReobservation)
    }

    @Test("suspensionChanged does not require KVO reobservation")
    func suspensionChanged_doesNotRequireReobservation() {
        #expect(!DeviceChangeEvent.suspensionChanged.requiresReobservation)
    }
}
