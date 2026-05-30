import CoreMedia
import Domain
import Foundation
import Testing

@testable import Infrastructure

// MARK: - Fixtures

/// Synthetic `CapabilitySnapshot` builders — no hardware required.
private enum Fixtures {
    static let outputDir = URL(fileURLWithPath: "/tmp")

    /// A snapshot with HW HEVC + SW H.264, one 4K@60 display, one 1080p@30 camera,
    /// one microphone, and a Pro-tier chip (2 encode sessions).
    static func proSnapshot(generation: Int = 1) -> CapabilitySnapshot {
        CapabilitySnapshot(
            generation: generation,
            displays: [
                DisplayCapability(id: 1, pixelWidth: 3840, pixelHeight: 2160, maxRefreshFPS: 60)
            ],
            cameras: [
                CameraCapability(
                    uniqueID: "cam-1",
                    localizedName: "FaceTime HD Camera",
                    formats: [
                        CameraFormatOption(
                            dimensions: CMVideoDimensions(width: 1920, height: 1080),
                            fpsRanges: [(minFPS: 1, maxFPS: 30)])
                    ])
            ],
            microphones: [AudioCapability(uniqueID: "mic-1", localizedName: "Built-in Mic")],
            encoders: [
                EncoderCapability(codec: .hevc, isHardwareAccelerated: true),
                EncoderCapability(codec: .h264, isHardwareAccelerated: false),
            ],
            system: SystemCapability(chipTier: .pro, performanceCoreCount: 8)
        )
    }

    /// Snapshot with `.unknown` chip tier and only 1 encode session budget.
    static func unknownTierSnapshot() -> CapabilitySnapshot {
        CapabilitySnapshot(
            generation: 1,
            displays: [
                DisplayCapability(id: 1, pixelWidth: 1920, pixelHeight: 1080, maxRefreshFPS: 60)
            ],
            cameras: [
                CameraCapability(
                    uniqueID: "cam-1",
                    localizedName: "Generic Cam",
                    formats: [
                        CameraFormatOption(
                            dimensions: CMVideoDimensions(width: 1920, height: 1080),
                            fpsRanges: [(minFPS: 1, maxFPS: 30)])
                    ])
            ],
            microphones: [],
            encoders: [EncoderCapability(codec: .hevc, isHardwareAccelerated: true)],
            system: SystemCapability(chipTier: .unknown, performanceCoreCount: 4)
        )
    }

    /// Snapshot with a 5K display and a codec encoder limited to 4K.
    static func fiveKDisplaySnapshot() -> CapabilitySnapshot {
        CapabilitySnapshot(
            generation: 1,
            displays: [
                DisplayCapability(id: 1, pixelWidth: 5120, pixelHeight: 2880, maxRefreshFPS: 60)
            ],
            cameras: [
                CameraCapability(
                    uniqueID: "cam-1",
                    localizedName: "5K Cam",
                    formats: [
                        CameraFormatOption(
                            dimensions: CMVideoDimensions(width: 5120, height: 2880),
                            fpsRanges: [(minFPS: 1, maxFPS: 30)])
                    ])
            ],
            microphones: [],
            encoders: [
                EncoderCapability(
                    codec: .h264,
                    isHardwareAccelerated: true,
                    maxDimensions: CMVideoDimensions(width: 3840, height: 2160))
            ],
            system: SystemCapability(chipTier: .max, performanceCoreCount: 12)
        )
    }

    /// Snapshot where only a SW HEVC encoder is available.
    static func swOnlyHevcSnapshot() -> CapabilitySnapshot {
        CapabilitySnapshot(
            generation: 1,
            displays: [
                DisplayCapability(id: 1, pixelWidth: 1920, pixelHeight: 1080, maxRefreshFPS: 60)
            ],
            cameras: [],
            microphones: [],
            encoders: [EncoderCapability(codec: .hevc, isHardwareAccelerated: false)],
            system: SystemCapability(chipTier: .pro, performanceCoreCount: 8)
        )
    }

    /// Snapshot with HW HEVC encoder only (no SW fallback needed).
    static func hwHevcSnapshot() -> CapabilitySnapshot {
        CapabilitySnapshot(
            generation: 1,
            displays: [
                DisplayCapability(id: 1, pixelWidth: 1920, pixelHeight: 1080, maxRefreshFPS: 60)
            ],
            cameras: [],
            microphones: [],
            encoders: [EncoderCapability(codec: .hevc, isHardwareAccelerated: true)],
            system: SystemCapability(chipTier: .pro, performanceCoreCount: 8)
        )
    }
}

// MARK: - TC-4: Valid configuration

@Suite("TC-4 — Valid configuration (P0)")
struct TC4ValidConfigurationTests {
    private let validator = Validator()

    @Test("Screen + mic: valid outcome, audio fanned to screen output")
    func screenWithMic() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            microphoneUniqueID: "mic-1",
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .valid(let cfg) = outcome else {
            Issue.record("Expected .valid, got \(outcome)")
            return
        }
        // Sources: screen + audio
        #expect(cfg.sources.count == 2)
        #expect(cfg.sources.contains(where: { $0.kind == .screen }))
        #expect(cfg.sources.contains(where: { $0.kind == .audio }))
        // Outputs: one screen file with video+audio tracks
        #expect(cfg.outputs.count == 1)
        #expect(cfg.outputs[0].tracks.contains(.video))
        #expect(cfg.outputs[0].tracks.contains(.audio))
        #expect(cfg.outputs[0].destination.lastPathComponent == "screen.mov")
    }

    @Test("Screen + camera + mic: audio fanned into both output files")
    func screenCameraWithMic() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            cameraUniqueID: "cam-1",
            microphoneUniqueID: "mic-1",
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .valid(let cfg) = outcome else {
            Issue.record("Expected .valid, got \(outcome)")
            return
        }
        // Sources: screen, camera, audio
        #expect(cfg.sources.count == 3)
        // Outputs: screen + camera, both carrying .audio
        #expect(cfg.outputs.count == 2)
        for output in cfg.outputs {
            #expect(output.tracks.contains(.audio), "Missing audio track in \(output.destination)")
            #expect(output.tracks.contains(.video))
        }
        let names = cfg.outputs.map(\.destination.lastPathComponent)
        #expect(names.contains("screen.mov"))
        #expect(names.contains("camera.mov"))
    }

    @Test("Camera only (no screen, no mic): valid, video-only output")
    func cameraOnlyNoMic() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            cameraUniqueID: "cam-1",
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .valid(let cfg) = outcome else {
            Issue.record("Expected .valid, got \(outcome)")
            return
        }
        #expect(cfg.outputs.count == 1)
        #expect(cfg.outputs[0].tracks == [.video])
        #expect(cfg.outputs[0].destination.lastPathComponent == "camera.mov")
    }

    @Test("mp4 container produces .mp4 extensions")
    func mp4Container() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            codec: .hevc,
            container: .mp4,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .valid(let cfg) = outcome else {
            Issue.record("Expected .valid, got \(outcome)")
            return
        }
        #expect(cfg.outputs[0].destination.pathExtension == "mp4")
    }
}

// MARK: - TC-5: FPS auto-clamp

@Suite("TC-5 — FPS auto-clamp (P1)")
struct TC5FpsClampTests {
    private let validator = Validator()

    @Test("Screen maxRefresh=60, targetFPS=120 → autoCorrected with frameRateClamped")
    func screenFpsClamped() {
        let snap = Fixtures.proSnapshot()  // display maxRefreshFPS = 60
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 120,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .autoCorrected(let cfg, let corrections) = outcome else {
            Issue.record("Expected .autoCorrected, got \(outcome)")
            return
        }
        let screenSource = cfg.sources.first(where: { $0.kind == .screen })
        #expect(screenSource?.fps == 60)
        #expect(corrections.contains(.frameRateClamped(requested: 120, applied: 60)))
    }

    @Test("Camera maxFPS=30, targetFPS=60 → autoCorrected with frameRateClamped")
    func cameraFpsClamped() {
        let snap = Fixtures.proSnapshot()  // camera fpsRanges max = 30
        let sel = Selections(
            cameraUniqueID: "cam-1",
            targetFPS: 60,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .autoCorrected(let cfg, let corrections) = outcome else {
            Issue.record("Expected .autoCorrected, got \(outcome)")
            return
        }
        let camSource = cfg.sources.first(where: { $0.kind == .camera })
        #expect(camSource?.fps == 30)
        #expect(corrections.contains(.frameRateClamped(requested: 60, applied: 30)))
    }

    @Test("targetFPS=30 within display maxRefresh=60 → valid (no clamp)")
    func noClampNeeded() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .valid = outcome else {
            Issue.record("Expected .valid, got \(outcome)")
            return
        }
    }
}

// MARK: - TC-6: Resolution unsupported

@Suite("TC-6 — Resolution unsupported (P1)")
struct TC6ResolutionUnsupportedTests {
    private let validator = Validator()

    @Test("5K display with H.264 encoder limited to 4K → rejected resolutionUnsupported")
    func fiveKDisplayRejected() {
        let snap = Fixtures.fiveKDisplaySnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            codec: .h264,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .rejected(let reasons) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(
            reasons.contains(where: {
                if case .resolutionUnsupported(_, _, let codec) = $0 { return codec == .h264 }
                return false
            }))
    }

    @Test("5K camera with H.264 encoder limited to 4K → rejected resolutionUnsupported")
    func fiveKCameraRejected() {
        let snap = Fixtures.fiveKDisplaySnapshot()
        let sel = Selections(
            cameraUniqueID: "cam-1",
            targetFPS: 30,
            codec: .h264,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .rejected(let reasons) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(
            reasons.contains(where: {
                if case .resolutionUnsupported = $0 { return true }
                return false
            }))
    }

    @Test("Encoder with no maxDimensions reported: no resolution rejection")
    func noMaxDimensionsAllowed() {
        // proSnapshot HW HEVC encoder has no maxDimensions → resolution check skipped.
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        // Should not be rejected for resolution
        if case .rejected(let reasons) = outcome {
            #expect(
                !reasons.contains(where: {
                    if case .resolutionUnsupported = $0 { return true }
                    return false
                }))
        }
    }
}

// MARK: - TC-7: Stream budget

@Suite("TC-7 — Stream budget (P2)")
struct TC7StreamBudgetTests {
    private let validator = Validator()

    @Test("Unknown tier (budget=1): screen+camera rejected as streamBudgetExceeded")
    func unknownTierTwoStreamsRejected() {
        let snap = Fixtures.unknownTierSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            cameraUniqueID: "cam-1",
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .rejected(let reasons) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(
            reasons.contains(where: {
                if case .streamBudgetExceeded(let req, let bud) = $0 {
                    return req == 2 && bud == 1
                }
                return false
            }))
    }

    @Test("Unknown tier (budget=1): screen only → valid (single stream within budget)")
    func unknownTierSingleStreamValid() {
        let snap = Fixtures.unknownTierSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        // Should not be rejected for stream budget
        if case .rejected(let reasons) = outcome {
            #expect(
                !reasons.contains(where: {
                    if case .streamBudgetExceeded = $0 { return true }
                    return false
                }))
        }
    }

    @Test("Pro tier (budget=2): screen+camera → valid (within budget)")
    func proTierTwoStreamsValid() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            cameraUniqueID: "cam-1",
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        // Must not be rejected for stream budget
        if case .rejected(let reasons) = outcome {
            #expect(
                !reasons.contains(where: {
                    if case .streamBudgetExceeded = $0 { return true }
                    return false
                }))
        }
    }
}

// MARK: - TC-8: Codec HW/SW detection

@Suite("TC-8 — Codec hardware vs software (P0)")
struct TC8CodecHWTests {
    private let validator = Validator()

    @Test("HW HEVC encoder present → .valid (no softwareEncoderOnly correction)")
    func hwHevcValid() {
        let snap = Fixtures.hwHevcSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            codec: .hevc,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .valid = outcome else {
            Issue.record("Expected .valid, got \(outcome)")
            return
        }
    }

    @Test("SW-only HEVC encoder → .autoCorrected with softwareEncoderOnly warning")
    func swOnlyHevcWarning() {
        let snap = Fixtures.swOnlyHevcSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            codec: .hevc,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .autoCorrected(_, let corrections) = outcome else {
            Issue.record("Expected .autoCorrected, got \(outcome)")
            return
        }
        #expect(corrections.contains(.softwareEncoderOnly(.hevc)))
    }

    @Test("No encoder for codec → .rejected with codecUnavailable")
    func noEncoderRejected() {
        let snap = Fixtures.hwHevcSnapshot()  // only HEVC encoder
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            codec: .h264,  // no H.264 encoder in snapshot
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .rejected(let reasons) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(reasons.contains(.codecUnavailable(.h264)))
    }
}

// MARK: - TC-27: TOCTOU device availability

@Suite("TC-27 — TOCTOU device re-validate (P1)")
struct TC27TOCTOUTests {
    private let validator = Validator()

    @Test("Camera in snapshot A → valid; camera removed in snapshot B → rejected deviceUnavailable")
    func cameraRemovedBetweenSnapshots() {
        let snapA = Fixtures.proSnapshot(generation: 1)
        let snapB = CapabilitySnapshot(
            generation: 2,  // newer snapshot — camera has been disconnected
            displays: snapA.displays,
            cameras: [],  // camera removed
            microphones: snapA.microphones,
            encoders: snapA.encoders,
            system: snapA.system
        )
        let sel = Selections(
            cameraUniqueID: "cam-1",
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )

        // Snapshot A: camera present → valid (or autoCorrected if fps clamped)
        let outcomeA = validator.validate(sel, against: snapA)
        if case .rejected = outcomeA {
            Issue.record("Expected non-rejected on snapshot A, got \(outcomeA)")
        }

        // Snapshot B: camera removed → rejected
        let outcomeB = validator.validate(sel, against: snapB)
        guard case .rejected(let reasons) = outcomeB else {
            Issue.record("Expected .rejected on snapshot B, got \(outcomeB)")
            return
        }
        #expect(
            reasons.contains(where: {
                if case .deviceUnavailable(let id, let kind) = $0 {
                    return id == "cam-1" && kind == .camera
                }
                return false
            }))
    }

    @Test("Display removed between snapshots → rejected deviceUnavailable")
    func displayRemovedBetweenSnapshots() {
        let snapA = Fixtures.proSnapshot(generation: 1)
        let snapB = CapabilitySnapshot(
            generation: 2,
            displays: [],  // display removed
            cameras: snapA.cameras,
            microphones: snapA.microphones,
            encoders: snapA.encoders,
            system: snapA.system
        )
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )

        let outcomeA = validator.validate(sel, against: snapA)
        if case .rejected = outcomeA {
            Issue.record("Expected non-rejected on snapshot A, got \(outcomeA)")
        }

        let outcomeB = validator.validate(sel, against: snapB)
        guard case .rejected(let reasons) = outcomeB else {
            Issue.record("Expected .rejected on snapshot B, got \(outcomeB)")
            return
        }
        #expect(
            reasons.contains(where: {
                if case .deviceUnavailable(_, let kind) = $0 { return kind == .screen }
                return false
            }))
    }
}

// MARK: - Additional rejection cases

@Suite("Validator — rejection cases")
struct ValidatorRejectionTests {
    private let validator = Validator()

    @Test("No video source selected → rejected noVideoSource")
    func noVideoSourceRejected() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            microphoneUniqueID: "mic-1",  // mic only, no screen/camera
            targetFPS: 30,
            outputDirectory: Fixtures.outputDir
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .rejected(let reasons) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(reasons.contains(.noVideoSource))
    }

    @Test("Non-writable output path → rejected outputPathNotWritable")
    func nonWritablePathRejected() {
        let snap = Fixtures.proSnapshot()
        let sel = Selections(
            screenDisplayID: 1,
            targetFPS: 30,
            outputDirectory: URL(fileURLWithPath: "/nonexistent/path/onset-test")
        )
        let outcome = validator.validate(sel, against: snap)
        guard case .rejected(let reasons) = outcome else {
            Issue.record("Expected .rejected, got \(outcome)")
            return
        }
        #expect(
            reasons.contains(where: {
                if case .outputPathNotWritable = $0 { return true }
                return false
            }))
    }
}

// MARK: - ValidationIssue equality tests

@Suite("ValidationIssue — Equatable")
struct ValidationIssueEqualityTests {
    @Test("noVideoSource equals itself")
    func noVideoSourceEquality() {
        #expect(ValidationIssue.noVideoSource == .noVideoSource)
    }

    @Test("frameRateClamped equality on matching values")
    func frameRateClampedEquality() {
        let a = ValidationIssue.frameRateClamped(requested: 120, applied: 60)
        let b = ValidationIssue.frameRateClamped(requested: 120, applied: 60)
        let c = ValidationIssue.frameRateClamped(requested: 90, applied: 60)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("codecUnavailable equality")
    func codecUnavailableEquality() {
        #expect(ValidationIssue.codecUnavailable(.hevc) == .codecUnavailable(.hevc))
        #expect(ValidationIssue.codecUnavailable(.hevc) != .codecUnavailable(.h264))
    }

    @Test("streamBudgetExceeded equality")
    func streamBudgetExceededEquality() {
        let a = ValidationIssue.streamBudgetExceeded(requested: 2, budget: 1)
        let b = ValidationIssue.streamBudgetExceeded(requested: 2, budget: 1)
        let c = ValidationIssue.streamBudgetExceeded(requested: 3, budget: 2)
        #expect(a == b)
        #expect(a != c)
    }

    @Test("resolutionUnsupported equality (manual CMVideoDimensions compare)")
    func resolutionUnsupportedEquality() {
        let req = CMVideoDimensions(width: 5120, height: 2880)
        let max = CMVideoDimensions(width: 3840, height: 2160)
        let a = ValidationIssue.resolutionUnsupported(
            requested: req, maxSupported: max, codec: .h264)
        let b = ValidationIssue.resolutionUnsupported(
            requested: req, maxSupported: max, codec: .h264)
        let c = ValidationIssue.resolutionUnsupported(
            requested: req, maxSupported: nil, codec: .h264)
        #expect(a == b)
        #expect(a != c)
    }
}
