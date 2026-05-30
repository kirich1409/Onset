import CoreMedia
import Foundation
import Testing

@testable import Application
@testable import Domain

// MARK: - In-test fakes
//
// These fakes prove that Domain protocols are sufficient to substitute real
// Infrastructure implementations in tests — no concrete sources or writers required.

private final class FakeClock: ClockProviding, @unchecked Sendable {
    let referenceClock: CMClock = CMClockGetHostTimeClock()
    func now() -> CMTime { .zero }
    func convert(_ time: CMTime, from src: CMClock) -> CMTime { time }
}

private final class FakeCaptureSource: CaptureSource, @unchecked Sendable {
    let kind: SourceKind
    let sourceClock: CMClock = CMClockGetHostTimeClock()

    init(kind: SourceKind) { self.kind = kind }

    func configure(_ config: SourceConfiguration) throws {}
    func start(emittingTo sink: any SampleSink) async throws {}
    func stop() async {}
}

private final class FakeEncodingWriter: EncodingWriter, @unchecked Sendable {
    // Always healthy; cannot exercise the isolateAndContinue failure path —
    // extend for #36 failure-mode tests.
    var health: WriterHealth = .alive
    var isAlive: Bool = true

    func prepare(_ descriptor: OutputDescriptor) throws {}
    func beginSession(atSourceTime time: CMTime) {}
    func append(_ buf: CMSampleBuffer, track: TrackKind) {}
    func finalize() async throws {}
}

// MARK: - DI graph construction tests

@Suite("Application DI graph")
struct ApplicationDITests {

    @Test("RecordingSessionCoordinator is constructible with injected fakes")
    func coordinatorConstructibleWithFakes() async {
        let clock = FakeClock()
        let store = SettingsStore(defaults: UserDefaults(suiteName: "test-settings-\(UUID())")!)
        let monitor = RuntimeHealthMonitor()
        let source: any CaptureSource = FakeCaptureSource(kind: .screen)
        let writer: any EncodingWriter = FakeEncodingWriter()

        let coordinator = RecordingSessionCoordinator(
            clock: clock,
            healthMonitor: monitor,
            settingsStore: store,
            makeSources: { [source] },
            makeWriter: { writer }
        )

        // Verify the coordinator is live (start/stop are smoke-tested below)
        _ = coordinator
    }

    @Test("RecordingSessionCoordinator start and stop are callable (skeleton)")
    func coordinatorStartStop() async {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "test-start-stop-\(UUID())")!)
        let monitor = RuntimeHealthMonitor()
        let coordinator = RecordingSessionCoordinator(
            clock: FakeClock(),
            healthMonitor: monitor,
            settingsStore: store
        )

        await coordinator.start()
        await coordinator.stop()
        // No assertion beyond "did not crash" — full state machine is #36
    }

    @Test("SettingsStore accepts injected UserDefaults (no singleton inside)")
    func settingsStoreInjectsDefaults() async {
        let suiteName = "test-store-\(UUID())"
        let customDefaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: customDefaults)
        // Smoke: store is constructible and usable; typed API lands in #30/#31
        _ = store
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test("RuntimeHealthMonitor exposes thermal state")
    func monitorThermalState() async {
        let monitor = RuntimeHealthMonitor()
        let state = await monitor.thermalState
        // ThermalState is an enum; just assert it is a valid value
        let validStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        #expect(validStates.contains(state))
    }

    @Test("DI graph is constructible without a concrete clock (nil seam)")
    func coordinatorNoClockSeam() async {
        let suiteName = "test-nil-clock-\(UUID())"
        let store = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let monitor = RuntimeHealthMonitor()
        let coordinator = RecordingSessionCoordinator(
            clock: nil,  // concrete ClockProviding not yet available (#34)
            healthMonitor: monitor,
            settingsStore: store
        )
        _ = coordinator
    }
}
