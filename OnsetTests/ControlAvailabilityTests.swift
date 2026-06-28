@testable import Onset
import Testing

// MARK: - ControlAvailabilityTests

/// L2 matrix tests for the pure `ControlAvailability.classify(policy:isRecordingActive:)`
/// classifier — every `SettingApplyPolicy` case crossed with both recording states.
@Suite("ControlAvailability — policy × recording-active matrix")
struct ControlAvailabilityTests {
    @Test("immediate is enabled regardless of recording state", arguments: [false, true])
    func immediate_alwaysEnabled(isRecordingActive: Bool) {
        #expect(
            ControlAvailability.classify(policy: .immediate, isRecordingActive: isRecordingActive) == .enabled
        )
    }

    @Test("nextRecordingStart is disabled while recording")
    func nextRecordingStart_disabledWhileRecording() {
        #expect(
            ControlAvailability.classify(policy: .nextRecordingStart, isRecordingActive: true) == .disabled
        )
    }

    @Test("nextRecordingStart is enabled when not recording")
    func nextRecordingStart_enabledWhenIdle() {
        #expect(
            ControlAvailability.classify(policy: .nextRecordingStart, isRecordingActive: false) == .enabled
        )
    }

    @Test("requiresRelaunch is enabled regardless of recording state", arguments: [false, true])
    func requiresRelaunch_alwaysEnabled(isRecordingActive: Bool) {
        #expect(
            ControlAvailability.classify(policy: .requiresRelaunch, isRecordingActive: isRecordingActive) == .enabled
        )
    }
}
