@testable import Onset
import Testing

// MARK: - Display mapper tests

@Suite("DeviceDiscovery.makeDisplay — primitive seam")
struct DisplayMapperTests {
    @Test("makeDisplay preserves displayID")
    func makeDisplay_preservesDisplayID() {
        let display = DeviceDiscovery.makeDisplay(
            displayID: 42,
            name: "Test Display",
            pixelWidth: 2560,
            pixelHeight: 1600,
            refreshHz: 60.0
        )

        #expect(display.displayID == 42)
    }

    @Test("makeDisplay preserves pixel width")
    func makeDisplay_preservesPixelWidth() {
        let display = DeviceDiscovery.makeDisplay(
            displayID: 1,
            name: "Test Display",
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 60.0
        )

        #expect(display.name == "Test Display")
        #expect(display.pixelWidth == 3840)
    }

    @Test("makeDisplay preserves pixel height")
    func makeDisplay_preservesPixelHeight() {
        let display = DeviceDiscovery.makeDisplay(
            displayID: 1,
            name: "Test Display",
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 60.0
        )

        #expect(display.pixelHeight == 2160)
    }

    @Test("makeDisplay preserves refresh rate")
    func makeDisplay_preservesRefreshRate() {
        let display = DeviceDiscovery.makeDisplay(
            displayID: 1,
            name: "Test Display",
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 144.0
        )

        #expect(display.refreshHz == 144.0)
    }

    @Test("makeDisplay carries 0.0 refresh rate — no premature fallback for built-in displays")
    func makeDisplay_preservesZeroRefreshRate() {
        // CGDisplayMode.refreshRate returns 0.0 for Apple built-in displays
        // (Liquid Retina, Pro Display XDR, etc.) because the refresh rate is variable.
        // The value MUST be carried as-is; no 60 Hz substitution.
        let display = DeviceDiscovery.makeDisplay(
            displayID: 1,
            name: "Встроенный дисплей",
            pixelWidth: 3456,
            pixelHeight: 2234,
            refreshHz: 0.0
        )

        #expect(display.refreshHz == 0.0)
    }

    @Test("makeDisplay carries zero pixel dimensions for unavailable mode")
    func makeDisplay_zeroPixels_unavailableMode() {
        // When CGDisplayCopyDisplayMode returns nil (display disconnecting, TCC race),
        // pixel dimensions default to 0 — not a fallback resolution.
        let display = DeviceDiscovery.makeDisplay(
            displayID: 1,
            name: "Test Display",
            pixelWidth: 0,
            pixelHeight: 0,
            refreshHz: 0.0
        )

        #expect(display.pixelWidth == 0)
        #expect(display.pixelHeight == 0)
    }

    @Test("makeDisplay preserves name")
    func makeDisplay_preservesName() {
        let display = DeviceDiscovery.makeDisplay(
            displayID: 1,
            name: "LG UltraFine",
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 60.0
        )

        #expect(display.name == "LG UltraFine")
    }

    @Test("Display stores a 4K Retina display correctly")
    func display_4K_retina() {
        let display = DeviceDiscovery.makeDisplay(
            displayID: 7,
            name: "Test Display",
            pixelWidth: 7680,
            pixelHeight: 4320,
            refreshHz: 60.0
        )

        #expect(display.displayID == 7)
        #expect(display.pixelWidth == 7680)
        #expect(display.pixelHeight == 4320)
        #expect(display.refreshHz == 60.0)
    }
}

// MARK: - CameraFormat model tests

@Suite("CameraFormat")
struct CameraFormatTests {
    @Test("CameraFormat stores pixel width")
    func cameraFormat_storesPixelWidth() {
        let format = CameraFormat(pixelWidth: 3840, pixelHeight: 2160, minFps: 24.0, maxFps: 60.0)

        #expect(format.pixelWidth == 3840)
    }

    @Test("CameraFormat stores pixel height")
    func cameraFormat_storesPixelHeight() {
        let format = CameraFormat(pixelWidth: 3840, pixelHeight: 2160, minFps: 24.0, maxFps: 60.0)

        #expect(format.pixelHeight == 2160)
    }

    @Test("CameraFormat stores minFps")
    func cameraFormat_storesMinFps() {
        let format = CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1.0, maxFps: 120.0)

        #expect(format.minFps == 1.0)
    }

    @Test("CameraFormat stores maxFps")
    func cameraFormat_storesMaxFps() {
        let format = CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 1.0, maxFps: 120.0)

        #expect(format.maxFps == 120.0)
    }

    @Test("CameraFormat stores 4K at 30fps correctly")
    func cameraFormat_4K_30fps() {
        let format = CameraFormat(pixelWidth: 3840, pixelHeight: 2160, minFps: 24.0, maxFps: 30.0)

        #expect(format.pixelWidth == 3840)
        #expect(format.pixelHeight == 2160)
        #expect(format.minFps == 24.0)
        #expect(format.maxFps == 30.0)
    }
}

// MARK: - Display permission gating tests

@Suite("DeviceDiscovery.displays — permission gating")
struct DisplayGatingTests {
    @Test("displays returns empty when screenAuthorized is false")
    func displays_empty_whenNotAuthorized() async throws {
        let result = try await DeviceDiscovery.displays(screenAuthorized: false)

        #expect(result.isEmpty)
    }
}

// MARK: - Camera permission gating tests

@Suite("DeviceDiscovery.cameras — permission gating")
struct CameraGatingTests {
    @Test("cameras returns empty when cameraAuthorized is false")
    func cameras_empty_whenNotAuthorized() {
        let result = DeviceDiscovery.cameras(cameraAuthorized: false)

        #expect(result.isEmpty)
    }
}

// MARK: - Microphone permission gating tests

@Suite("DeviceDiscovery.microphones — permission gating")
struct MicrophoneGatingTests {
    @Test("microphones returns empty when microphoneAuthorized is false")
    func microphones_empty_whenNotAuthorized() {
        let result = DeviceDiscovery.microphones(microphoneAuthorized: false)

        #expect(result.isEmpty)
    }
}

// MARK: - CameraDevice model tests

@Suite("CameraDevice")
struct CameraDeviceTests {
    @Test("CameraDevice stores uniqueID")
    func cameraDevice_storesUniqueID() {
        let device = CameraDevice(
            uniqueID: "device-001",
            formats: []
        )

        #expect(device.uniqueID == "device-001")
    }

    @Test("CameraDevice stores empty formats list")
    func cameraDevice_emptyFormats() {
        let device = CameraDevice(uniqueID: "device-001", formats: [])

        #expect(device.formats.isEmpty)
    }

    @Test("CameraDevice stores multiple formats")
    func cameraDevice_multipleFormats() {
        let formats = [
            CameraFormat(pixelWidth: 1920, pixelHeight: 1080, minFps: 30.0, maxFps: 60.0),
            CameraFormat(pixelWidth: 3840, pixelHeight: 2160, minFps: 24.0, maxFps: 30.0),
        ]
        let device = CameraDevice(uniqueID: "device-001", formats: formats)

        #expect(device.formats.count == 2)
        #expect(device.formats[0].pixelWidth == 1920)
        #expect(device.formats[1].pixelWidth == 3840)
    }

    @Test("isContinuityCamera defaults to false, can be set to true")
    func isContinuityCamera_defaultAndExplicit() {
        let regular = CameraDevice(uniqueID: "cam-001", formats: [])
        let continuity = CameraDevice(uniqueID: "cam-002", formats: [], isContinuityCamera: true)

        #expect(regular.isContinuityCamera == false)
        #expect(continuity.isContinuityCamera == true)
    }
}

// MARK: - MicrophoneDevice model tests

@Suite("MicrophoneDevice")
struct MicrophoneDeviceTests {
    @Test("MicrophoneDevice stores uniqueID")
    func microphoneDevice_storesUniqueID() {
        let device = MicrophoneDevice(uniqueID: "mic-001")

        #expect(device.uniqueID == "mic-001")
    }

    @Test("MicrophoneDevice uniqueID is distinct from another device")
    func microphoneDevice_distinctUniqueID() {
        let first = MicrophoneDevice(uniqueID: "mic-001")
        let second = MicrophoneDevice(uniqueID: "mic-002")

        #expect(first.uniqueID != second.uniqueID)
    }

    @Test("isBuiltIn defaults to false")
    func microphoneDevice_isBuiltIn_defaultsFalse() {
        let device = MicrophoneDevice(uniqueID: "mic-001")

        #expect(device.isBuiltIn == false)
    }

    @Test("isBuiltIn can be set to true")
    func microphoneDevice_isBuiltIn_canBeTrue() {
        let device = MicrophoneDevice(uniqueID: "mic-builtin", isBuiltIn: true)

        #expect(device.isBuiltIn == true)
    }
}

// MARK: - microphonesAvailable lid-filter tests

@Suite("DeviceDiscovery.microphonesAvailable — lid filter")
struct MicrophonesAvailableTests {
    private func makeBuiltIn(id: String = "builtin") -> MicrophoneDevice {
        MicrophoneDevice(uniqueID: id, isBuiltIn: true)
    }

    private func makeExternal(id: String = "external") -> MicrophoneDevice {
        MicrophoneDevice(uniqueID: id, isBuiltIn: false)
    }

    @Test("lid open — all devices returned including built-in")
    func lidOpen_allDevicesReturned() {
        let devices = [makeBuiltIn(), makeExternal()]

        let result = DeviceDiscovery.microphonesAvailable(devices, lidClosed: false)

        #expect(result.count == 2)
    }

    @Test("lid closed — built-in mic removed, external kept")
    func lidClosed_builtInRemoved_externalKept() {
        let builtIn = self.makeBuiltIn(id: "builtin")
        let external = self.makeExternal(id: "usb-mic")
        let devices = [builtIn, external]

        let result = DeviceDiscovery.microphonesAvailable(devices, lidClosed: true)

        #expect(result.count == 1)
        #expect(result[0].uniqueID == "usb-mic")
    }

    @Test("lid closed — list with only external mics unchanged")
    func lidClosed_onlyExternals_unchanged() {
        let devices = [makeExternal(id: "usb-1"), makeExternal(id: "usb-2")]

        let result = DeviceDiscovery.microphonesAvailable(devices, lidClosed: true)

        #expect(result.count == 2)
    }

    @Test("empty list — returns empty regardless of lid state")
    func emptyList_alwaysEmpty() {
        let resultOpen = DeviceDiscovery.microphonesAvailable([], lidClosed: false)
        let resultClosed = DeviceDiscovery.microphonesAvailable([], lidClosed: true)

        #expect(resultOpen.isEmpty)
        #expect(resultClosed.isEmpty)
    }

    @Test("lid open — built-in mic present in result")
    func lidOpen_builtInPresent() {
        let builtIn = self.makeBuiltIn(id: "builtin")
        let devices = [builtIn]

        let result = DeviceDiscovery.microphonesAvailable(devices, lidClosed: false)

        #expect(result.count == 1)
        #expect(result[0].uniqueID == "builtin")
    }
}
