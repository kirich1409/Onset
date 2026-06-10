import AVFoundation
import os

// MARK: - Logger

/// Logger is Sendable; nonisolated private let avoids a MainActor hop under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated private let deviceAvailabilityLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "DeviceAvailabilityObserver"
)

// MARK: - DeviceChangeEvent

/// A coarse capture-device topology change.
///
/// Carries no device identity on purpose (PII discipline — uniqueIDs and names never
/// leave the AVFoundation layer here); the consumer re-enumerates the full device list
/// on every event anyway.
nonisolated enum DeviceChangeEvent: Equatable {
    /// `AVCaptureDevice.wasConnectedNotification` fired — a device became available.
    case connected

    /// `AVCaptureDevice.wasDisconnectedNotification` fired — a device went away.
    case disconnected

    /// KVO on `isSuspended` fired for an observed device (e.g. notebook lid closed/opened).
    case suspensionChanged

    /// Whether the KVO observer set must be rebuilt after this event.
    ///
    /// Connect/disconnect changes the set of devices whose `isSuspended` needs watching;
    /// a suspension flip leaves the device set unchanged, so re-registration would be churn.
    var requiresReobservation: Bool {
        switch self {
        case .connected, .disconnected:
            true

        case .suspensionChanged:
            false
        }
    }
}

// MARK: - DeviceAvailabilityObserver

/// Produces a stream of capture-device topology changes while the main window is open.
///
/// There is no suspend/resume NotificationCenter notification on macOS — `isSuspended`
/// is only KVO-observable — so this type merges two signal sources into one stream:
/// - `AVCaptureDevice.wasConnectedNotification` / `wasDisconnectedNotification`
///   (block-based NotificationCenter observers), and
/// - KVO on `isSuspended` for every currently connected camera and microphone,
///   including already-suspended ones (required to observe lid-open un-suspension).
///
/// ### Ownership
/// Lifetime is tied to the returned stream: `continuation.onTermination` strongly
/// captures the observer and schedules `stop()` when the consuming task is cancelled
/// (i.e. the main window disappears), which removes notification observers, invalidates
/// KVO, and releases the instance deterministically. Callers do not need to retain it.
@MainActor
final class DeviceAvailabilityObserver {
    // MARK: - State

    /// KVO tokens for `isSuspended` on every currently connected capture device.
    private var suspensionObservations: [NSKeyValueObservation] = []

    /// Block-based NotificationCenter observer tokens (connect / disconnect).
    private var notificationTokens: [any NSObjectProtocol] = []

    /// Guards the one-shot `events()` contract — a second call returns a finished stream.
    private var hasStarted = false

    // MARK: - Stream

    /// Starts observing and returns the event stream. One-shot: call once per instance.
    ///
    /// The stream uses `.bufferingNewest(1)`: a burst of KVO/notification events while
    /// the consumer is busy collapses to at most one pending event — the consumer
    /// re-enumerates everything per event, so intermediate events carry no information.
    func events() -> AsyncStream<DeviceChangeEvent> {
        guard !self.hasStarted else {
            deviceAvailabilityLogger.error("events() called twice on one observer — returning finished stream")
            return AsyncStream { $0.finish() }
        }
        self.hasStarted = true

        let (stream, continuation) = AsyncStream.makeStream(
            of: DeviceChangeEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.rebuildSuspensionObservers(continuation: continuation)
        self.registerTopologyObservers(continuation: continuation)

        // Strong self capture is the ownership anchor: the observer lives exactly as long
        // as someone consumes the stream; teardown runs when iteration ends or the
        // consuming task is cancelled.
        continuation.onTermination = { _ in
            Task { @MainActor in
                self.stop()
            }
        }
        return stream
    }

    /// Stops all observation. Idempotent; also invoked via the stream's `onTermination`.
    func stop() {
        for token in self.notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        self.notificationTokens.removeAll()
        for observation in self.suspensionObservations {
            observation.invalidate()
        }
        self.suspensionObservations.removeAll()
        deviceAvailabilityLogger.debug("Device availability observation stopped")
    }

    // MARK: - Notification observers

    /// Registers block-based observers for device connect/disconnect notifications.
    ///
    /// The handler runs on the posting thread, touches only Sendable captures (the
    /// continuation and the event value), and hops to the main actor to rebuild the
    /// KVO set when the device topology changed.
    private func registerTopologyObservers(
        continuation: AsyncStream<DeviceChangeEvent>.Continuation
    ) {
        let pairs: [(Notification.Name, DeviceChangeEvent)] = [
            (AVCaptureDevice.wasConnectedNotification, .connected),
            (AVCaptureDevice.wasDisconnectedNotification, .disconnected),
        ]
        self.notificationTokens = pairs.map { name, event in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                continuation.yield(event)
                guard event.requiresReobservation else { return }
                Task { @MainActor [weak self] in
                    self?.rebuildSuspensionObservers(continuation: continuation)
                }
            }
        }
    }

    // MARK: - KVO on isSuspended

    /// Drops the current KVO set and re-registers `isSuspended` observation for every
    /// currently connected capture device (cameras and microphones).
    ///
    /// Suspended devices are deliberately included: they are exactly the ones that must
    /// be watched to catch the lid-open transition back to available.
    private func rebuildSuspensionObservers(
        continuation: AsyncStream<DeviceChangeEvent>.Continuation
    ) {
        for observation in self.suspensionObservations {
            observation.invalidate()
        }
        let devices = Self.allCaptureDevices()
        self.suspensionObservations = Self.makeSuspensionObservations(
            devices: devices,
            continuation: continuation
        )
        // PII policy: log counts only, never device names or uniqueIDs.
        deviceAvailabilityLogger.debug("Suspension observers rebuilt — devices: \(devices.count)")
    }

    /// Registers KVO on `isSuspended` for each device.
    ///
    /// `nonisolated` static + an explicitly `@Sendable` handler: KVO fires on an arbitrary
    /// thread, and the closure captures ONLY the Sendable continuation — never `self`,
    /// never the device. Do not inline this registration into a `@MainActor` method body:
    /// the closure would infer main-actor isolation and fail to compile.
    nonisolated private static func makeSuspensionObservations(
        devices: [AVCaptureDevice],
        continuation: AsyncStream<DeviceChangeEvent>.Continuation
    )
    -> [NSKeyValueObservation] {
        devices.map { device in
            device.observe(\.isSuspended, options: []) { @Sendable _, _ in
                continuation.yield(.suspensionChanged)
            }
        }
    }

    /// Raw (unfiltered) enumeration of all capture devices for KVO registration.
    ///
    /// Must NOT reuse `DeviceDiscovery.cameras()` / `microphones()` — those exclude
    /// suspended devices, but suspended devices are exactly the ones to observe here.
    /// Permission gating is also intentionally absent: an unauthorized `DiscoverySession`
    /// simply returns no devices, and any spurious reload is permission-gated downstream
    /// in `MainViewModel.loadCamerasAndMicrophones()`.
    nonisolated private static func allCaptureDevices() -> [AVCaptureDevice] {
        let video = AVCaptureDevice.DiscoverySession(
            deviceTypes: DeviceDiscovery.cameraDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let audio = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return video.devices + audio.devices
    }
}
