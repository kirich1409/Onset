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
