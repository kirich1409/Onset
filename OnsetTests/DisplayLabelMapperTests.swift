import CoreGraphics
@testable import Onset
import Testing

// MARK: - DisplayLabelMapper — label formatting

@Suite("DisplayLabelMapper — label(name:pixelWidth:pixelHeight:refreshHz:)")
struct DisplayLabelMapperLabelTests {
    // MARK: - Format: name — WxH @ hz

    @Test("External display with known Hz → name — W×H @ hz (no unit)")
    func externalDisplay_withHz() {
        let label = DisplayLabelMapper.label(
            name: "Внешний дисплей",
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 60.0
        )
        #expect(label == "Внешний дисплей — 3840×2160 @ 60")
    }

    @Test("Built-in display (refreshHz 0) → name — W×H (no @ hz segment)")
    func builtinDisplay_zeroHz_omitsFpsSegment() {
        let label = DisplayLabelMapper.label(
            name: "Встроенный дисплей",
            pixelWidth: 2560,
            pixelHeight: 1600,
            refreshHz: 0.0
        )
        #expect(label == "Встроенный дисплей — 2560×1600")
    }

    @Test("Fractional Hz 59.94 → rounds to 60")
    func fractionalHz_roundsToNearest() {
        let label = DisplayLabelMapper.label(
            name: "Внешний дисплей",
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshHz: 59.94
        )
        #expect(label == "Внешний дисплей — 1920×1080 @ 60")
    }

    @Test("Fractional Hz 144.5 → rounds to 145")
    func fractionalHz_roundsUp() {
        let label = DisplayLabelMapper.label(
            name: "Gaming Monitor",
            pixelWidth: 2560,
            pixelHeight: 1440,
            refreshHz: 144.5
        )
        #expect(label == "Gaming Monitor — 2560×1440 @ 145")
    }

    @Test("label(for:) delegates to low-level overload — same result")
    func labelForDisplay_delegatesToLowLevel() {
        let display = Display(
            displayID: 1,
            name: "Внешний дисплей",
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshHz: 60.0
        )
        let fromDisplay = DisplayLabelMapper.label(for: display)
        let fromPrimitives = DisplayLabelMapper.label(
            name: display.name,
            pixelWidth: display.pixelWidth,
            pixelHeight: display.pixelHeight,
            refreshHz: display.refreshHz
        )
        #expect(fromDisplay == fromPrimitives)
    }
}

// MARK: - DisplayLabelMapper — recording HUD formatting

@Suite("DisplayLabelMapper — recordingScreenLabel(pixelWidth:pixelHeight:refreshHz:)")
struct DisplayLabelMapperHUDLabelTests {
    @Test("Known Hz → W×H @ hz Гц (no name, with unit)")
    func withHz_producesHUDFormat() {
        let label = DisplayLabelMapper.recordingScreenLabel(
            pixelWidth: 3840,
            pixelHeight: 2160,
            refreshHz: 60.0
        )
        #expect(label == "3840×2160 @ 60 Гц")
    }

    @Test("Zero Hz → W×H only (omits @ hz Гц segment)")
    func zeroHz_omitsRateSegment() {
        let label = DisplayLabelMapper.recordingScreenLabel(
            pixelWidth: 2560,
            pixelHeight: 1600,
            refreshHz: 0.0
        )
        #expect(label == "2560×1600")
    }

    @Test("Fractional Hz 59.94 → rounds to 60 Гц")
    func fractionalHz_59_94_roundsTo60() {
        let label = DisplayLabelMapper.recordingScreenLabel(
            pixelWidth: 1280,
            pixelHeight: 720,
            refreshHz: 59.94
        )
        #expect(label == "1280×720 @ 60 Гц")
    }

    @Test("Fractional Hz 144.5 → rounds to 145 Гц")
    func fractionalHz_144_5_roundsTo145() {
        let label = DisplayLabelMapper.recordingScreenLabel(
            pixelWidth: 2560,
            pixelHeight: 1440,
            refreshHz: 144.5
        )
        #expect(label == "2560×1440 @ 145 Гц")
    }
}

// MARK: - DisplayLabelMapper — name resolution

@Suite("DisplayLabelMapper — name(localizedName:isBuiltin:ordinal:)")
struct DisplayLabelMapperNameTests {
    @Test("Non-empty localizedName → returned as-is (builtin, external both)")
    func nonEmptyLocalizedName_returned() {
        #expect(
            DisplayLabelMapper.name(
                localizedName: "LG UltraFine",
                isBuiltin: false,
                ordinal: 1
            ) == "LG UltraFine"
        )
        #expect(
            DisplayLabelMapper.name(
                localizedName: "Built-in Retina Display",
                isBuiltin: true,
                ordinal: 1
            ) == "Built-in Retina Display"
        )
    }

    @Test("nil localizedName + isBuiltin true → Встроенный дисплей")
    func nilName_builtin_fallsBackToBuiltinLabel() {
        let name = DisplayLabelMapper.name(
            localizedName: nil,
            isBuiltin: true,
            ordinal: 1
        )
        #expect(name == "Встроенный дисплей")
    }

    @Test("nil localizedName + isBuiltin false → Дисплей N (ordinal)")
    func nilName_external_fallsBackToOrdinalLabel() {
        #expect(
            DisplayLabelMapper.name(localizedName: nil, isBuiltin: false, ordinal: 1) == "Дисплей 1"
        )
        #expect(
            DisplayLabelMapper.name(localizedName: nil, isBuiltin: false, ordinal: 2) == "Дисплей 2"
        )
    }

    @Test("empty localizedName → treated as absent, applies isBuiltin fallback")
    func emptyLocalizedName_treatedAsAbsent() {
        #expect(
            DisplayLabelMapper.name(
                localizedName: "",
                isBuiltin: true,
                ordinal: 1
            ) == "Встроенный дисплей"
        )
        #expect(
            DisplayLabelMapper.name(
                localizedName: "",
                isBuiltin: false,
                ordinal: 3
            ) == "Дисплей 3"
        )
    }
}
