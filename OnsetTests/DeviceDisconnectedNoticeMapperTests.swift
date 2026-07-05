@testable import Onset
import Testing

// MARK: - DeviceDisconnectedNoticeMapperTests

/// L2 tests for `DeviceDisconnectedNoticeMapper` (#261) — the picker-transparency notice shown
/// when a saved camera/microphone selection disappears (`DeviceSelectionResolver.resolve(...)
/// -> .disconnected(name:)`).
///
/// Covers gender agreement (camera feminine / microphone masculine) and the
/// with-alternatives / without-alternatives wording branches.
@Suite("DeviceDisconnectedNoticeMapper — notice text")
struct DeviceDisconnectedNoticeMapperTests {
    // MARK: - Camera

    @Test("Camera, with alternatives — names the device and hints at another camera")
    func cameraWithAlternatives() {
        let text = DeviceDisconnectedNoticeMapper.rowText(kind: .camera, name: "MX Brio", hasAlternatives: true)
        #expect(text == "Камера «MX Brio» недоступна — выберите другую камеру")
    }

    @Test("Camera, without alternatives — names the device only, no hint")
    func cameraWithoutAlternatives() {
        let text = DeviceDisconnectedNoticeMapper.rowText(kind: .camera, name: "MX Brio", hasAlternatives: false)
        #expect(text == "Камера «MX Brio» недоступна")
    }

    // MARK: - Microphone

    @Test("Microphone, with alternatives — names the device and hints at another microphone")
    func microphoneWithAlternatives() {
        let text = DeviceDisconnectedNoticeMapper.rowText(
            kind: .microphone,
            name: "MacBook Pro",
            hasAlternatives: true
        )
        #expect(text == "Микрофон «MacBook Pro» недоступен — выберите другой микрофон")
    }

    @Test("Microphone, without alternatives — names the device only, no hint")
    func microphoneWithoutAlternatives() {
        let text = DeviceDisconnectedNoticeMapper.rowText(
            kind: .microphone,
            name: "MacBook Pro",
            hasAlternatives: false
        )
        #expect(text == "Микрофон «MacBook Pro» недоступен")
    }

    // MARK: - Accessibility label

    @Test("Accessibility label appends a period to the row text")
    func accessibilityLabelAppendsPeriod() {
        let label = DeviceDisconnectedNoticeMapper.accessibilityLabel(
            kind: .microphone,
            name: "MacBook Pro",
            hasAlternatives: false
        )
        #expect(label == "Микрофон «MacBook Pro» недоступен.")
    }
}
