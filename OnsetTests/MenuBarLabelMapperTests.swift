// MenuBarLabelMapperTests.swift
// OnsetTests
//
// Swift Testing suite for MenuBarLabelMapper (#38).
//
// Tests the pure static mapper in `MenuBarLabelMapper` — covers all three visual states
// (idle, recording/normal, recording/degraded) and the phase-to-label mapping.
// No SwiftUI rendering — all assertions are against value returns, making these fast L2 tests.
//
// The «Начать запись» dispatch path relies on @Environment(\.openWindow) and closure side
// effects — no natural unit-test boundary exists here. Covered by L5 manual verification.
//
// file_length: one file per mapper input dimension (idle/normal/degraded/timer/device-lost/
// low-space/transitions) keeps related suites together; splitting would scatter shared context.
// swiftlint:disable file_length
@testable import Onset
import Testing

// MARK: - Idle states

@Suite("MenuBarLabelMapper — idle states")
@MainActor
struct MenuBarLabelMapperIdleTests {
    @Test("Idle phase produces hollow dot, no warning, no timer")
    func idlePhase() {
        let desc = MenuBarLabelMapper.descriptor(phase: .idle, recordingState: .normal, elapsed: 0, showTimer: true)
        #expect(desc.dot == .hollow)
        #expect(desc.dot.systemName == "circle")
        #expect(desc.dot.showsWarning == false)
        #expect(desc.elapsed == nil)
    }

    @Test("Main phase produces hollow dot, no warning, no timer")
    func mainPhase() {
        let desc = MenuBarLabelMapper.descriptor(phase: .main, recordingState: .normal, elapsed: 42, showTimer: true)
        #expect(desc.dot == .hollow)
        #expect(desc.dot.systemName == "circle")
        #expect(desc.dot.showsWarning == false)
        #expect(desc.elapsed == nil)
    }

    @Test("Finished phase (transient) produces hollow dot — same as idle")
    func finishedPhase() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .finished,
            recordingState: .normal,
            elapsed: 100,
            showTimer: true
        )
        #expect(desc.dot == .hollow)
        #expect(desc.dot.systemName == "circle")
        #expect(desc.dot.showsWarning == false)
        #expect(desc.elapsed == nil)
    }

    @Test("Idle phase ignores degraded recordingState")
    func idleWithDegradedState() {
        let desc = MenuBarLabelMapper.descriptor(phase: .idle, recordingState: .degraded, elapsed: 0, showTimer: true)
        #expect(desc.dot == .hollow)
        #expect(desc.dot.showsWarning == false)
        #expect(desc.elapsed == nil)
    }
}

// MARK: - Recording / Normal

@Suite("MenuBarLabelMapper — recording normal")
@MainActor
struct MenuBarLabelMapperRecordingNormalTests {
    @Test("Recording+normal uses red dot with record.circle.fill symbol")
    func normalUsesRedDot() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 0,
            showTimer: true
        )
        #expect(desc.dot == .red)
        #expect(desc.dot.systemName == "record.circle.fill")
    }

    @Test("Recording+normal shows no warning")
    func normalHasNoWarning() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 0,
            showTimer: true
        )
        #expect(desc.dot.showsWarning == false)
    }

    @Test("Recording+normal carries elapsed timer at 0")
    func normalElapsedZero() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 0,
            showTimer: true
        )
        #expect(desc.elapsed == 0)
    }

    @Test("Recording+normal carries elapsed timer at 257 (04:17)")
    func normalElapsedNonZero() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 257,
            showTimer: true
        )
        #expect(desc.elapsed == 257)
    }
}

// MARK: - Recording / Degraded

@Suite("MenuBarLabelMapper — recording degraded")
@MainActor
struct MenuBarLabelMapperRecordingDegradedTests {
    @Test("Recording+degraded uses yellow dot with circle.fill symbol")
    func degradedUsesYellowDot() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 0,
            showTimer: true
        )
        #expect(desc.dot == .yellow)
        #expect(desc.dot.systemName == "circle.fill")
    }

    @Test("Recording+degraded shows warning triangle")
    func degradedShowsWarning() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 0,
            showTimer: true
        )
        #expect(desc.dot.showsWarning == true)
    }

    @Test("Recording+degraded carries elapsed timer")
    func degradedElapsed() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 3661,
            showTimer: true
        )
        #expect(desc.elapsed == 3661)
    }
}

// MARK: - Critical (hard) states — AC-11

@Suite("MenuBarLabelMapper — critical states")
@MainActor
struct MenuBarLabelMapperCriticalTests {
    @Test("sustainedDrops (hard) uses critical octagon symbol, not degraded/normal")
    func sustainedDropsUsesOctagon() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: .sustainedDrops
        )
        #expect(desc.dot == .critical)
        #expect(desc.dot.systemName == "exclamationmark.octagon.fill")
    }

    @Test("fpsCollapse (hard) uses critical octagon symbol")
    func fpsCollapseUsesOctagon() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: .fpsCollapse
        )
        #expect(desc.dot == .critical)
        #expect(desc.dot.systemName == "exclamationmark.octagon.fill")
    }

    @Test("cameraOnly (hard, terminal) uses octagon, drops the timer, distinct a11y")
    func cameraOnlyUsesOctagon() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: .cameraLost(scope: .cameraOnly)
        )
        #expect(desc.dot == .critical)
        #expect(desc.elapsed == nil)
        #expect(desc.accessibilityLabel == "Onset, критическая ошибка: камера отключена, запись остановлена")
    }

    @Test("Critical a11y label is distinct from degraded and from normal")
    func criticalA11yDistinctFromDegradedAndNormal() {
        let normal = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true
        )
        let degraded = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: true
        )
        let critical = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: .sustainedDrops
        )
        #expect(critical.accessibilityLabel != degraded.accessibilityLabel)
        #expect(critical.accessibilityLabel != normal.accessibilityLabel)
    }

    @Test("Precedence: hard critical outranks degraded — octagon, not yellow")
    func hardOutranksDegraded() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: .fpsCollapse
        )
        #expect(desc.dot == .critical)
        #expect(desc.dot != .yellow)
        #expect(desc.dot.showsWarning == false)
    }

    @Test("cameraAndScreen (soft) shows NO octagon but updates the a11y label")
    func softShowsNoOctagonButUpdatesA11y() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: .cameraLost(scope: .cameraAndScreen)
        )
        #expect(desc.dot == .red)
        #expect(desc.dot != .critical)
        #expect(desc.accessibilityLabel == "Onset, камера отключена, запись экрана продолжается, 01:00")
    }

    @Test("cameraAndScreen (soft) over degraded keeps the yellow dot, no octagon")
    func softOverDegradedKeepsYellow() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: .cameraLost(scope: .cameraAndScreen)
        )
        #expect(desc.dot == .yellow)
        #expect(desc.dot != .critical)
    }

    @Test("No liveCriticalView leaves normal/degraded mapping unchanged")
    func nilCriticalLeavesBaselineMapping() {
        let normal = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: nil
        )
        let degraded = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: true,
            liveCriticalView: nil
        )
        #expect(normal.dot == .red)
        #expect(degraded.dot == .yellow)
    }
}

// MARK: - Timer toggle (showTimer == false)

@Suite("MenuBarLabelMapper — timer toggle off")
@MainActor
struct MenuBarLabelMapperTimerToggleTests {
    @Test("Recording+normal with showTimer false omits elapsed, dot unchanged")
    func normalTimerOffOmitsElapsed() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 257,
            showTimer: false
        )
        // The visible time string is suppressed…
        #expect(desc.elapsed == nil)
        // …but the recording dot is unchanged (recording is still signalled).
        #expect(desc.dot == .red)
        #expect(desc.dot.systemName == "record.circle.fill")
    }

    @Test("Recording+degraded with showTimer false omits elapsed, dot unchanged")
    func degradedTimerOffOmitsElapsed() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: false
        )
        #expect(desc.elapsed == nil)
        #expect(desc.dot == .yellow)
        #expect(desc.dot.showsWarning == true)
    }
}

// MARK: - Device lost mid-recording (#261)

@Suite("MenuBarLabelMapper — device lost mid-recording")
@MainActor
struct MenuBarLabelMapperDeviceLostTests {
    @Test("Recording+normal with all sources live shows no device-lost warning")
    func allLiveShowsNoWarning() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            sourceLiveness: .allLive
        )
        #expect(desc.deviceLostWarning == false)
        #expect(desc.dot == .red)
    }

    @Test("Recording+normal with camera lost shows device-lost warning, dot stays red")
    func cameraLostShowsWarningDotStaysRed() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            sourceLiveness: SourceLiveness(screen: true, camera: false, microphone: false)
        )
        #expect(desc.deviceLostWarning == true)
        #expect(desc.dot == .red)
    }

    @Test("Recording+normal with screen lost shows device-lost warning")
    func screenLostShowsWarning() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            sourceLiveness: SourceLiveness(screen: false, camera: true, microphone: true)
        )
        #expect(desc.deviceLostWarning == true)
    }

    @Test("Device-lost warning composes with degraded recordingState")
    func deviceLostAndDegradedCompose() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: true,
            sourceLiveness: SourceLiveness(screen: true, camera: false, microphone: false)
        )
        #expect(desc.deviceLostWarning == true)
        #expect(desc.dot == .yellow)
    }

    @Test("Device-lost warning appends a note to the accessibility label")
    func deviceLostAppendsAccessibilityNote() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 5,
            showTimer: true,
            sourceLiveness: SourceLiveness(screen: true, camera: false, microphone: false)
        )
        #expect(desc.accessibilityLabel.contains("устройство отключено"))
    }

    @Test("Idle phase ignores sourceLiveness — no device-lost warning")
    func idlePhaseIgnoresSourceLiveness() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .idle,
            recordingState: .normal,
            elapsed: 0,
            showTimer: true,
            sourceLiveness: SourceLiveness(screen: false, camera: false, microphone: false)
        )
        #expect(desc.deviceLostWarning == false)
    }

    @Test("Default sourceLiveness parameter is allLive — existing call sites unaffected")
    func defaultParameterIsAllLive() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true
        )
        #expect(desc.deviceLostWarning == false)
    }
}

// MARK: - Low disk space mid-recording (AC-12a, #88, T-8)

@Suite("MenuBarLabelMapper — low disk space mid-recording")
@MainActor
struct MenuBarLabelMapperLowSpaceTests {
    @Test("Recording+normal with no disk warning shows no low-space warning")
    func noWarningShowsNoLowSpace() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            diskWarning: nil
        )
        #expect(desc.lowSpaceWarning == false)
        #expect(desc.dot == .red)
    }

    @Test("Recording+normal with a disk warning shows low-space warning, dot stays red")
    func diskWarningShowsLowSpaceDotStaysRed() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            diskWarning: .outputFree
        )
        #expect(desc.lowSpaceWarning == true)
        #expect(desc.dot == .red)
    }

    @Test("Low-space warning composes with degraded recordingState")
    func lowSpaceAndDegradedCompose() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: true,
            diskWarning: .outputEta
        )
        #expect(desc.lowSpaceWarning == true)
        #expect(desc.dot == .yellow)
    }

    @Test("Low-space warning appends a note to the accessibility label")
    func lowSpaceAppendsAccessibilityNote() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 5,
            showTimer: true,
            diskWarning: .systemFree
        )
        #expect(desc.accessibilityLabel.contains("мало места на диске"))
    }

    @Test("De-escalation: disk warning clearing to nil clears the low-space warning")
    func deescalationClearsLowSpaceWarning() {
        let warned = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            diskWarning: .outputFree
        )
        let cleared = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            diskWarning: nil
        )
        #expect(warned.lowSpaceWarning == true)
        #expect(cleared.lowSpaceWarning == false)
        #expect(warned != cleared)
    }

    @Test("Idle phase ignores diskWarning — no low-space warning")
    func idlePhaseIgnoresDiskWarning() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .idle,
            recordingState: .normal,
            elapsed: 0,
            showTimer: true,
            diskWarning: .outputFree
        )
        #expect(desc.lowSpaceWarning == false)
    }

    @Test("Default diskWarning parameter is nil — existing call sites unaffected")
    func defaultParameterIsNil() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true
        )
        #expect(desc.lowSpaceWarning == false)
    }

    @Test("Low-space warning composes with device-lost warning independently")
    func lowSpaceAndDeviceLostCompose() {
        let desc = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true,
            sourceLiveness: SourceLiveness(screen: true, camera: false, microphone: true),
            diskWarning: .outputFree
        )
        #expect(desc.deviceLostWarning == true)
        #expect(desc.lowSpaceWarning == true)
    }
}

// MARK: - Phase transitions

@Suite("MenuBarLabelMapper — phase transitions")
@MainActor
struct MenuBarLabelMapperPhaseTransitionTests {
    @Test("Normal→degraded changes descriptor (showsWarning + dot case)")
    func normalToDegraded() {
        let normal = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
            showTimer: true
        )
        let degraded = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            showTimer: true
        )
        #expect(normal != degraded)
        #expect(normal.dot.showsWarning == false)
        #expect(degraded.dot.showsWarning == true)
    }

    @Test("Recording→idle clears timer (elapsed becomes nil)")
    func recordingToIdle() {
        let recording = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 120,
            showTimer: true
        )
        let idle = MenuBarLabelMapper.descriptor(phase: .idle, recordingState: .normal, elapsed: 120, showTimer: true)
        #expect(recording.elapsed != nil)
        #expect(idle.elapsed == nil)
    }
}

// file_length stays disabled through EOF — whole-file rule, same pattern as FileWriterTests.
// swiftlint:enable file_length
