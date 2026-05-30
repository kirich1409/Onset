import CoreMedia
import Domain
import Foundation

// MARK: - Validator

/// Validates user `Selections` against a `CapabilitySnapshot` and produces a
/// `ValidationOutcome` — the sole constructor of `RecordingConfiguration`.
///
/// ## Parse-don't-validate contract
/// `RecordingConfiguration` has a `package init` that only this Validator is
/// architecturally permitted to call. Any `RecordingConfiguration` in circulation
/// is therefore guaranteed-realizable by construction.
///
/// ## Purity
/// The Validator is a pure function: no I/O, no system calls, no logging. All
/// inputs are in `selections` and `snapshot`. The caller is responsible for logging
/// the outcome.
///
/// ## Audio fan-out contract
/// When a microphone is selected, `.audio` tracks are added to **every** video output
/// file (screen and camera). Mic audio is fanned-out before writer branching, so both
/// files receive bit-identical audio. This is the contract that `SampleRouter` (#35)
/// and the encoding writers (#37) depend on. Do not change the fan-out without
/// coordinating those issues.
///
/// ## Output naming
/// Output files are named `screen.<ext>` and `camera.<ext>` (ext = mov/mp4 from
/// container). Timestamped names and collision avoidance are deferred to the
/// recording-session layer (#37).
///
/// ## Validation check order (correctness constraint)
/// 1. Device availability (TOCTOU) — must run first; later steps read device properties.
/// 2. No-video-source — nil selection, not absent device.
/// 3. Codec availability (HW preference, SW-only warning).
/// 4. Output path writability.
/// 5. Camera format resolution (pick format, clamp fps).
/// 6. Screen fps clamp.
/// 7. Resolution × codec maxDimensions check (all active video sources).
/// 8. Stream-budget check.
/// 9. Compose RecordingConfiguration and emit outcome.
public struct Validator {
    public init() {}

    /// Validates `selections` against `snapshot` and returns a `ValidationOutcome`.
    ///
    /// - Parameters:
    ///   - selections: The user's draft recording choices.
    ///   - snapshot: A fresh `CapabilitySnapshot` from `CapabilityService`.
    /// - Returns: `.valid`, `.autoCorrected`, or `.rejected` — never throws.
    public func validate(
        _ selections: Selections,
        against snapshot: CapabilitySnapshot
    ) -> ValidationOutcome {
        // Step 1: Device availability (TOCTOU)
        if let rejection = checkDeviceAvailability(selections, snapshot: snapshot) {
            return rejection
        }
        // Step 2: At least one video source
        guard selections.screenDisplayID != nil || selections.cameraUniqueID != nil else {
            return .rejected(reasons: [.noVideoSource])
        }
        // Step 3: Codec availability
        let codecResult = checkCodec(selections.codec, encoders: snapshot.encoders)
        switch codecResult {
        case .rejected:
            return codecResult
        default:
            break
        }
        var corrections = extractCorrections(from: codecResult)

        // Step 4: Output path writability
        if let rejection = checkOutputPath(selections.outputDirectory) {
            return rejection
        }

        let preferredEncoder = preferredEncoder(for: selections.codec, in: snapshot.encoders)

        // Steps 5–6: Format selection and fps clamping
        let screenResolved = resolveScreen(selections, snapshot: snapshot, corrections: &corrections)
        let cameraResolved = resolveCamera(selections, snapshot: snapshot, corrections: &corrections)

        // Step 7: Resolution vs encoder maxDimensions
        if let rejection = checkResolution(
            screen: screenResolved,
            camera: cameraResolved,
            encoder: preferredEncoder,
            codec: selections.codec
        ) {
            return rejection
        }

        // Step 8: Stream budget
        if let rejection = checkStreamBudget(
            screenActive: selections.screenDisplayID != nil,
            cameraActive: selections.cameraUniqueID != nil,
            system: snapshot.system
        ) {
            return rejection
        }

        // Step 9: Compose
        let config = compose(
            selections: selections,
            screenResolved: screenResolved,
            cameraResolved: cameraResolved
        )
        return corrections.isEmpty ? .valid(config) : .autoCorrected(config, corrections: corrections)
    }
}

// MARK: - Private validation steps

extension Validator {
    private func checkDeviceAvailability(
        _ selections: Selections, snapshot: CapabilitySnapshot
    ) -> ValidationOutcome? {
        if let displayID = selections.screenDisplayID,
            !snapshot.displays.contains(where: { $0.id == displayID })
        {
            return .rejected(reasons: [.deviceUnavailable(id: String(displayID), kind: .screen)])
        }
        if let cameraID = selections.cameraUniqueID,
            !snapshot.cameras.contains(where: { $0.uniqueID == cameraID })
        {
            return .rejected(reasons: [.deviceUnavailable(id: cameraID, kind: .camera)])
        }
        if let micID = selections.microphoneUniqueID,
            !snapshot.microphones.contains(where: { $0.uniqueID == micID })
        {
            return .rejected(reasons: [.deviceUnavailable(id: micID, kind: .audio)])
        }
        return nil
    }

    private func checkCodec(
        _ codec: CodecKind,
        encoders: [EncoderCapability]
    ) -> ValidationOutcome {
        let matching = encoders.filter { $0.codec == codec }
        guard !matching.isEmpty else {
            return .rejected(reasons: [.codecUnavailable(codec)])
        }
        let hasHW = matching.contains { $0.isHardwareAccelerated }
        if !hasHW {
            // SW-only: still allowed, but surface the warning.
            // Returned as autoCorrected with no config yet; caller extracts corrections.
            return .autoCorrected(
                RecordingConfiguration(sources: [], outputs: []),
                corrections: [.softwareEncoderOnly(codec)]
            )
        }
        return .valid(RecordingConfiguration(sources: [], outputs: []))
    }

    private func extractCorrections(from outcome: ValidationOutcome) -> [ValidationIssue] {
        if case .autoCorrected(_, let corrections) = outcome { return corrections }
        return []
    }

    private func preferredEncoder(
        for codec: CodecKind, in encoders: [EncoderCapability]
    ) -> EncoderCapability? {
        let matching = encoders.filter { $0.codec == codec }
        return matching.first { $0.isHardwareAccelerated } ?? matching.first
    }

    private func checkOutputPath(_ directory: URL) -> ValidationOutcome? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: directory.path, isDirectory: &isDir)
        guard exists && isDir.boolValue && fm.isWritableFile(atPath: directory.path) else {
            return .rejected(reasons: [.outputPathNotWritable(directory)])
        }
        return nil
    }

    /// Resolves camera format + fps. Returns (width, height, fps) tuple or zeroes if no camera.
    private func resolveCamera(
        _ selections: Selections,
        snapshot: CapabilitySnapshot,
        corrections: inout [ValidationIssue]
    ) -> ResolvedSource {
        guard let cameraID = selections.cameraUniqueID,
            let camera = snapshot.cameras.first(where: { $0.uniqueID == cameraID })
        else { return ResolvedSource(width: 0, height: 0, fps: selections.targetFPS) }

        let chosenFormat: CameraFormatOption?
        if let override = selections.cameraFormatOverride, camera.formats.contains(override) {
            chosenFormat = override
        } else {
            chosenFormat = camera.formats.max(by: {
                Int($0.dimensions.width) * Int($0.dimensions.height)
                    < Int($1.dimensions.width) * Int($1.dimensions.height)
            })
        }
        guard let fmt = chosenFormat else {
            return ResolvedSource(width: 0, height: 0, fps: selections.targetFPS)
        }

        let maxFPS = fmt.fpsRanges.map(\.maxFPS).max().map(Int.init) ?? selections.targetFPS
        let clampedFPS = min(selections.targetFPS, maxFPS)
        if clampedFPS != selections.targetFPS {
            corrections.append(.frameRateClamped(requested: selections.targetFPS, applied: clampedFPS))
        }
        return ResolvedSource(
            width: Int(fmt.dimensions.width),
            height: Int(fmt.dimensions.height),
            fps: clampedFPS
        )
    }

    /// Resolves screen display resolution + fps. Returns zeroes if no display selected.
    private func resolveScreen(
        _ selections: Selections,
        snapshot: CapabilitySnapshot,
        corrections: inout [ValidationIssue]
    ) -> ResolvedSource {
        guard let displayID = selections.screenDisplayID,
            let display = snapshot.displays.first(where: { $0.id == displayID })
        else { return ResolvedSource(width: 0, height: 0, fps: selections.targetFPS) }

        let maxFPS = Int(display.maxRefreshFPS)
        let clampedFPS = min(selections.targetFPS, maxFPS)
        if clampedFPS != selections.targetFPS {
            let alreadyRecorded = corrections.contains(where: {
                if case .frameRateClamped(let req, _) = $0 { return req == selections.targetFPS }
                return false
            })
            if !alreadyRecorded {
                corrections.append(.frameRateClamped(requested: selections.targetFPS, applied: clampedFPS))
            }
        }
        return ResolvedSource(width: display.pixelWidth, height: display.pixelHeight, fps: clampedFPS)
    }

    private func checkResolution(
        screen: ResolvedSource,
        camera: ResolvedSource,
        encoder: EncoderCapability?,
        codec: CodecKind
    ) -> ValidationOutcome? {
        guard let maxDims = encoder?.maxDimensions else { return nil }
        if screen.width > Int(maxDims.width) || screen.height > Int(maxDims.height) {
            let req = CMVideoDimensions(width: Int32(screen.width), height: Int32(screen.height))
            return .rejected(reasons: [.resolutionUnsupported(requested: req, maxSupported: maxDims, codec: codec)])
        }
        if camera.width > Int(maxDims.width) || camera.height > Int(maxDims.height) {
            let req = CMVideoDimensions(width: Int32(camera.width), height: Int32(camera.height))
            return .rejected(reasons: [.resolutionUnsupported(requested: req, maxSupported: maxDims, codec: codec)])
        }
        return nil
    }

    private func checkStreamBudget(
        screenActive: Bool,
        cameraActive: Bool,
        system: SystemCapability
    ) -> ValidationOutcome? {
        // CapabilityMatrix is the sole source for multi-stream budgets (architecture.md §Capability-модель).
        // For .unknown tier, the matrix already returns the conservative budget of 1.
        // Using performanceCoreCount to raise the budget above the matrix value is
        // explicitly avoided — it would loosen the spec'd constraint.
        let requested = (screenActive ? 1 : 0) + (cameraActive ? 1 : 0)
        let budget = CapabilityMatrix.budget(for: system.chipTier).maxHardwareEncodeSessions
        guard requested <= budget else {
            return .rejected(reasons: [.streamBudgetExceeded(requested: requested, budget: budget)])
        }
        return nil
    }

    private func compose(
        selections: Selections,
        screenResolved: ResolvedSource,
        cameraResolved: ResolvedSource
    ) -> RecordingConfiguration {
        var sources: [SourceConfiguration] = []
        var outputs: [OutputDescriptor] = []
        let ext = fileExtension(for: selections.container)
        let hasMic = selections.microphoneUniqueID != nil
        let tracks: Set<TrackKind> = hasMic ? [.video, .audio] : [.video]

        if selections.screenDisplayID != nil {
            sources.append(
                SourceConfiguration(
                    kind: .screen,
                    width: screenResolved.width,
                    height: screenResolved.height,
                    fps: screenResolved.fps
                ))
            outputs.append(
                OutputDescriptor(
                    destination: selections.outputDirectory.appendingPathComponent("screen.\(ext)"),
                    codec: selections.codec,
                    container: selections.container,
                    tracks: tracks
                ))
        }

        if selections.cameraUniqueID != nil {
            sources.append(
                SourceConfiguration(
                    kind: .camera,
                    width: cameraResolved.width,
                    height: cameraResolved.height,
                    fps: cameraResolved.fps
                ))
            outputs.append(
                OutputDescriptor(
                    destination: selections.outputDirectory.appendingPathComponent("camera.\(ext)"),
                    codec: selections.codec,
                    container: selections.container,
                    tracks: tracks
                ))
        }

        if hasMic {
            sources.append(SourceConfiguration(kind: .audio, width: 0, height: 0, fps: 0))
        }

        return RecordingConfiguration(sources: sources, outputs: outputs)
    }

    private func fileExtension(for container: ContainerKind) -> String {
        switch container {
        case .mov: return "mov"
        case .mp4: return "mp4"
        }
    }
}

// MARK: - ResolvedSource

/// Internal helper capturing the resolved (post-clamp) parameters for a single capture source.
private struct ResolvedSource {
    let width: Int
    let height: Int
    let fps: Int
}
