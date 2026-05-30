import AVFoundation
import AppKit
import CoreMedia
import Darwin
import Domain
import Foundation
import ScreenCaptureKit
import VideoToolbox

// MARK: - CapabilityService

/// Control-plane actor that builds and caches `CapabilitySnapshot`s.
///
/// `CapabilityService` is the single source of truth for hardware capability discovery.
/// It is a control-plane component — not on any hot path.
///
/// ### Snapshot lifecycle
/// 1. Call `start()` once at app launch. This performs an initial probe and registers
///    hotplug observers.
/// 2. Read `current` to get the most recent `CapabilitySnapshot`.
/// 3. Call `stop()` at app termination to clean up observers.
///
/// ### Hotplug
/// Device-connect/disconnect notifications bump `generation` and rebuild the snapshot
/// asynchronously. Display change callbacks do the same via `NSApplication.didChangeScreenParametersNotification`.
///
/// ### Display discovery and TCC
/// `SCShareableContent.current` requires Screen Recording TCC authorization.
/// If unavailable (denied or not yet granted), `displays` is empty in the snapshot.
/// The service logs a warning but does **not** crash — a partial snapshot with no displays
/// is a valid state (the Validator will reject screen-capture configurations accordingly).
public actor CapabilityService {

    // MARK: - Public state

    /// The most recently built capability snapshot.
    /// Always non-nil after `start()` completes; `nil` before first probe.
    public private(set) var current: CapabilitySnapshot?

    // MARK: - Private state

    /// Monotonically increasing generation counter. Bumped on each hotplug event.
    private var generation: Int = 0

    /// Observer tokens for device-connect/disconnect and display-change notifications.
    /// Removed in `stop()`.
    private var observers: [any NSObjectProtocol] = []

    /// Guards against concurrent or repeated `start()` calls.
    ///
    /// Set synchronously (before the first `await`) so the actor's isolation guarantee
    /// makes the check-and-set atomic up to the first suspension point. Two concurrent
    /// `start()` callers both enter the actor; the second finds `didStart == true` and
    /// returns immediately, preventing double observer registration and token leaks.
    private var didStart = false

    // MARK: - Init / start / stop

    public init() {}

    /// Performs the initial capability probe and registers hotplug observers.
    ///
    /// Safe to call multiple times — subsequent calls after the first are no-ops.
    /// Call this once from the composition root before any Validator usage.
    public func start() async {
        guard !didStart else { return }
        didStart = true
        await rebuildSnapshot()
        registerObservers()
    }

    /// Unregisters all hotplug observers.
    ///
    /// Call at app termination or when the service is no longer needed.
    public func stop() {
        let tokens = observers
        observers.removeAll()
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        didStart = false
    }

    // MARK: - Snapshot construction

    /// Rebuilds the capability snapshot from scratch.
    ///
    /// Each call increments `generation` to signal staleness to consumers.
    /// Called from `start()` and from hotplug observer closures (via `Task { await ... }`).
    private func rebuildSnapshot() async {
        generation += 1
        let gen = generation

        let cameras = CapabilityService.discoverCameras()
        let microphones = CapabilityService.discoverMicrophones()
        let displays = await CapabilityService.discoverDisplays()
        let encoders = CapabilityService.probeEncoders()
        let system = CapabilityService.probeSystem()

        let snapshot = CapabilitySnapshot(
            generation: gen,
            displays: displays,
            cameras: cameras,
            microphones: microphones,
            encoders: encoders,
            system: system
        )

        current = snapshot

        Log.emitCapabilityProbe(
            hardwareHEVC: encoders.contains { $0.codec == .hevc && $0.isHardwareAccelerated },
            encoderCount: encoders.filter(\.isHardwareAccelerated).count
        )
        let tierLabel = String(describing: system.chipTier)
        Log.capability.info(
            """
            capability.probe generation=\(gen, privacy: .public) \
            displays=\(displays.count, privacy: .public) \
            cameras=\(cameras.count, privacy: .public) \
            mics=\(microphones.count, privacy: .public) \
            encoders=\(encoders.count, privacy: .public) \
            tier=\(tierLabel, privacy: .public)
            """
        )
    }

    // MARK: - Hotplug observer registration

    /// Registers notification-center observers for device connect/disconnect and display change.
    ///
    /// Observers use `Task { [weak self] in await self?.... }` to hop back onto the actor
    /// isolation — the only correct approach for actor methods called from
    /// notification-center closures in Swift 6 strict concurrency.
    private func registerObservers() {
        // AVCaptureDevice connect (cameras, mics).
        let connectToken = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleDeviceChange(reason: "device connected") }
        }

        // AVCaptureDevice disconnect.
        let disconnectToken = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleDeviceChange(reason: "device disconnected") }
        }

        // Display configuration change (display hotplug, resolution change).
        let displayToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleDeviceChange(reason: "display parameters changed") }
        }

        observers = [connectToken, disconnectToken, displayToken]
    }

    /// Called from hotplug notification observers. Bumps generation and rebuilds the snapshot.
    private func handleDeviceChange(reason: String) async {
        Log.capability.info("capability: hotplug — \(reason, privacy: .public)")
        await rebuildSnapshot()
    }
}

// MARK: - Pure discovery helpers (static — testable without the actor)

extension CapabilityService {

    // MARK: Camera discovery

    /// Enumerates connected video capture devices and maps them to `CameraCapability`.
    ///
    /// Delegates format projection to `CameraCaptureSource.enumerateFormats` — the single
    /// canonical implementation shared between the capability layer and capture source (#30/#31).
    /// Pure function — no actor isolation needed.
    static func discoverCameras() -> [CameraCapability] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { device in
            let formats = CameraCaptureSource.enumerateFormats(device.formats)
            return CameraCapability(
                uniqueID: device.uniqueID,
                localizedName: device.localizedName,
                formats: formats
            )
        }
    }

    // MARK: Microphone discovery

    /// Enumerates available audio input devices and maps them to `AudioCapability`.
    ///
    /// Uses a DiscoverySession with `.microphone` for audio media. `.external` is a video
    /// device type and is not used here — it is a no-op for `.audio` media type.
    /// Falls back to the system default audio device when the session returns no results.
    static func discoverMicrophones() -> [AudioCapability] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let discovered = session.devices.map { device in
            AudioCapability(uniqueID: device.uniqueID, localizedName: device.localizedName)
        }
        if !discovered.isEmpty { return discovered }

        // Fallback: system default audio input device.
        Log.capability.warning(
            "capability: discovery returned no microphones — fallback to default audio device"
        )
        if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            return [AudioCapability(uniqueID: defaultDevice.uniqueID, localizedName: defaultDevice.localizedName)]
        }
        Log.capability.error(
            "capability: no audio input device available — microphone list is empty"
        )
        return []
    }

    // MARK: Display discovery

    /// Fetches displays via `SCShareableContent.current`.
    ///
    /// Requires Screen Recording TCC authorization. Returns an empty array on denial
    /// or any other error — the Validator will reject screen-capture configurations in
    /// that case. TCC denial is logged as `.warning` with a `permission` event so
    /// `PermissionsManager` (#21) can surface the UI prompt; other errors are logged
    /// at `.error` with full cause detail.
    static func discoverDisplays() async -> [DisplayCapability] {
        do {
            let content = try await SCShareableContent.current
            return content.displays.map { display in
                CapabilityService.displayCapability(for: display.displayID)
            }
        } catch let error as SCStreamError where error.code == .userDeclined {
            // TCC screen-recording permission denied by the user.
            Log.capability.warning(
                "capability: SCShareableContent.current — screen recording permission denied"
            )
            Log.emitPermission(type: "screen", status: "denied")
            return []
        } catch {
            Log.capability.error(
                "capability: SCShareableContent.current failed: \(String(reflecting: error), privacy: .public)"
            )
            return []
        }
    }

    /// Builds a `DisplayCapability` for `displayID` using native pixel dimensions.
    ///
    /// `CGDisplayCopyDisplayMode` returns hardware pixels — not points — which is the correct
    /// input for `SCStreamConfiguration.width/height` (`captureResolution = .best`).
    /// Mirrors the `pixelSize(of:)` helper in `ScreenCaptureSource`.
    static func displayCapability(for displayID: CGDirectDisplayID) -> DisplayCapability {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let fps = mode.refreshRate > 0 ? mode.refreshRate : 60.0
            return DisplayCapability(
                id: displayID,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                maxRefreshFPS: fps
            )
        }
        // Fallback: CoreGraphics bounds. Not expected on a running system.
        let bounds = CGDisplayBounds(displayID)
        return DisplayCapability(
            id: displayID,
            pixelWidth: Int(bounds.width),
            pixelHeight: Int(bounds.height),
            maxRefreshFPS: 60.0
        )
    }

    // MARK: Encoder probe

    /// Probes VideoToolbox for available HEVC and H.264 encoder capabilities.
    ///
    /// `VTCopyVideoEncoderList` returns an array of encoder dictionaries. For each
    /// matching codec (`kCMVideoCodecType_HEVC`, `kCMVideoCodecType_H264`) we read
    /// `kVTVideoEncoderList_IsHardwareAccelerated` and (where present) the maximum
    /// supported pixel dimensions.
    ///
    /// Pure function — testable by passing a synthesized encoder dict array.
    static func probeEncoders() -> [EncoderCapability] {
        var encoderList: CFArray?
        let status = VTCopyVideoEncoderList(nil as CFDictionary?, &encoderList)
        guard status == noErr, let list = encoderList as? [[String: Any]] else {
            Log.capability.error(
                "capability: VTCopyVideoEncoderList failed status=\(status, privacy: .public) — HEVC/H.264 unavailable"
            )
            return []
        }
        return list.compactMap { dict in
            CapabilityService.encoderCapability(from: dict)
        }
    }

    /// Maps a single VideoToolbox encoder dictionary to `EncoderCapability`.
    ///
    /// Extracted as a `static func` for unit-testability: tests can pass a synthesized
    /// dict without calling live VT APIs.
    ///
    /// Keys of interest:
    /// - `kVTVideoEncoderList_CodecType` (`OSType`/`FourCharCode`) — codec identifier.
    /// - `kVTVideoEncoderList_IsHardwareAccelerated` (`CFBoolean`) — HW accelerated flag.
    ///
    /// Supported codecs: HEVC (`kCMVideoCodecType_HEVC`) and H.264 (`kCMVideoCodecType_H264`).
    /// All other codec types are skipped (returns `nil`).
    static func encoderCapability(from dict: [String: Any]) -> EncoderCapability? {
        // Codec type is stored as a CFNumber (OSType / UInt32).
        guard
            let codecNumber = dict[kVTVideoEncoderList_CodecType as String] as? NSNumber
        else { return nil }

        let codecType = CMVideoCodecType(codecNumber.uint32Value)
        let codec: CodecKind
        switch codecType {
        case kCMVideoCodecType_HEVC:
            codec = .hevc
        case kCMVideoCodecType_H264:
            codec = .h264
        default:
            return nil
        }

        // IsHardwareAccelerated: CFBoolean → Bool.
        // Log at .debug when the key is absent so a software-only encoder path is observable.
        let isHW: Bool
        if let hwValue = dict[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool {
            isHW = hwValue
        } else {
            Log.capability.debug(
                "capability: IsHardwareAccelerated key missing for codec \(codecType, privacy: .public) — assumed SW"
            )
            isHW = false
        }

        return EncoderCapability(
            codec: codec,
            isHardwareAccelerated: isHW,
            maxDimensions: nil  // VTCopyVideoEncoderList does not expose max dimensions per-encoder.
        )
    }

    // MARK: System probe

    /// Reads chip brand string + P-core count via sysctl and maps to `SystemCapability`.
    ///
    /// `machdep.cpu.brand_string` on Apple Silicon returns e.g. "Apple M3 Max".
    /// `hw.perflevel0.physicalcpu` is the P-core count.
    /// Falls back to `ProcessInfo.activeProcessorCount` when sysctl is unavailable.
    static func probeSystem() -> SystemCapability {
        let brand: String
        if let brandString = sysctlString(name: "machdep.cpu.brand_string"), !brandString.isEmpty {
            brand = brandString
        } else {
            brand = ""
            Log.capability.warning(
                "capability: machdep.cpu.brand_string unavailable or empty — chipTier falls back to .unknown"
            )
        }
        let tier = CapabilityMatrix.classifyChipTier(brand: brand)

        let pCores: Int
        if let count = sysctlUInt32(name: "hw.perflevel0.physicalcpu"), count > 0 {
            pCores = Int(count)
        } else {
            pCores = ProcessInfo.processInfo.activeProcessorCount
            Log.capability.warning(
                "capability: hw.perflevel0.physicalcpu unavailable — P-cores=\(pCores, privacy: .public) fallback"
            )
        }

        return SystemCapability(chipTier: tier, performanceCoreCount: pCores)
    }

    // MARK: sysctl helpers

    /// Reads a NUL-terminated C string from sysctl by name.
    ///
    /// Returns `nil` if the key is not available (e.g. non-Apple silicon, sandboxed, or
    /// a future OS version where the key is renamed).
    static func sysctlString(name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // Drop the trailing NUL byte(s) before decoding.
        let bytes = buffer.prefix(while: { $0 != 0 })
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Reads an integer (64-bit) from sysctl by name.
    ///
    /// Returns `nil` if the key is not available.
    static func sysctlInt(name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Reads a 32-bit unsigned integer from sysctl by name.
    ///
    /// Use this for 32-bit sysctl keys (e.g. `hw.perflevel0.physicalcpu`) where reading
    /// into a 64-bit `Int` is fragile — the kernel writes exactly 4 bytes and the upper
    /// 4 bytes of an 8-byte buffer may be garbage on big-endian reads or alignment issues.
    ///
    /// Returns `nil` if the key is not available.
    static func sysctlUInt32(name: String) -> UInt32? {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
