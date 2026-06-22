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
@testable import Onset
import Testing

// MARK: - Idle states

@Suite("MenuBarLabelMapper — idle states")
@MainActor
struct MenuBarLabelMapperIdleTests {
    @Test("Idle phase produces hollow dot, no warning, no timer")
    func idlePhase() {
        let desc = MenuBarLabelMapper.descriptor(phase: .idle, recordingState: .normal, elapsed: 0)
        #expect(desc.dot == .hollow)
        #expect(desc.dot.systemName == "circle")
        #expect(desc.dot.showsWarning == false)
        #expect(desc.elapsed == nil)
    }

    @Test("Main phase produces hollow dot, no warning, no timer")
    func mainPhase() {
        let desc = MenuBarLabelMapper.descriptor(phase: .main, recordingState: .normal, elapsed: 42)
        #expect(desc.dot == .hollow)
        #expect(desc.dot.systemName == "circle")
        #expect(desc.dot.showsWarning == false)
        #expect(desc.elapsed == nil)
    }

    @Test("Finished phase (transient) produces hollow dot — same as idle")
    func finishedPhase() {
        let desc = MenuBarLabelMapper.descriptor(phase: .finished, recordingState: .normal, elapsed: 100)
        #expect(desc.dot == .hollow)
        #expect(desc.dot.systemName == "circle")
        #expect(desc.dot.showsWarning == false)
        #expect(desc.elapsed == nil)
    }

    @Test("Idle phase ignores degraded recordingState")
    func idleWithDegradedState() {
        let desc = MenuBarLabelMapper.descriptor(phase: .idle, recordingState: .degraded, elapsed: 0)
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
        let desc = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .normal, elapsed: 0)
        #expect(desc.dot == .red)
        #expect(desc.dot.systemName == "record.circle.fill")
    }

    @Test("Recording+normal shows no warning")
    func normalHasNoWarning() {
        let desc = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .normal, elapsed: 0)
        #expect(desc.dot.showsWarning == false)
    }

    @Test("Recording+normal carries elapsed timer at 0")
    func normalElapsedZero() {
        let desc = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .normal, elapsed: 0)
        #expect(desc.elapsed == 0)
    }

    @Test("Recording+normal carries elapsed timer at 257 (04:17)")
    func normalElapsedNonZero() {
        let desc = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .normal, elapsed: 257)
        #expect(desc.elapsed == 257)
    }
}

// MARK: - Recording / Degraded

@Suite("MenuBarLabelMapper — recording degraded")
@MainActor
struct MenuBarLabelMapperRecordingDegradedTests {
    @Test("Recording+degraded uses yellow dot with circle.fill symbol")
    func degradedUsesYellowDot() {
        let desc = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .degraded, elapsed: 0)
        #expect(desc.dot == .yellow)
        #expect(desc.dot.systemName == "circle.fill")
    }

    @Test("Recording+degraded shows warning triangle")
    func degradedShowsWarning() {
        let desc = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .degraded, elapsed: 0)
        #expect(desc.dot.showsWarning == true)
    }

    @Test("Recording+degraded carries elapsed timer")
    func degradedElapsed() {
        let desc = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .degraded, elapsed: 3661)
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
            liveCriticalView: .cameraLost(scope: .cameraOnly)
        )
        #expect(desc.dot == .critical)
        #expect(desc.elapsed == nil)
        #expect(desc.accessibilityLabel == "Onset, критическая ошибка: камера отключена, запись остановлена")
    }

    @Test("Critical a11y label is distinct from degraded and from normal")
    func criticalA11yDistinctFromDegradedAndNormal() {
        let normal = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .normal, elapsed: 60)
        let degraded = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .degraded, elapsed: 60)
        let critical = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .normal,
            elapsed: 60,
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
            liveCriticalView: nil
        )
        let degraded = MenuBarLabelMapper.descriptor(
            phase: .recording,
            recordingState: .degraded,
            elapsed: 60,
            liveCriticalView: nil
        )
        #expect(normal.dot == .red)
        #expect(degraded.dot == .yellow)
    }
}

// MARK: - Phase transitions

@Suite("MenuBarLabelMapper — phase transitions")
@MainActor
struct MenuBarLabelMapperPhaseTransitionTests {
    @Test("Normal→degraded changes descriptor (showsWarning + dot case)")
    func normalToDegraded() {
        let normal = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .normal, elapsed: 60)
        let degraded = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .degraded, elapsed: 60)
        #expect(normal != degraded)
        #expect(normal.dot.showsWarning == false)
        #expect(degraded.dot.showsWarning == true)
    }

    @Test("Recording→idle clears timer (elapsed becomes nil)")
    func recordingToIdle() {
        let recording = MenuBarLabelMapper.descriptor(phase: .recording, recordingState: .normal, elapsed: 120)
        let idle = MenuBarLabelMapper.descriptor(phase: .idle, recordingState: .normal, elapsed: 120)
        #expect(recording.elapsed != nil)
        #expect(idle.elapsed == nil)
    }
}
