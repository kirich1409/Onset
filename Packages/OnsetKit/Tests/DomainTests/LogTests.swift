import Testing

@testable import Domain

// Tests for the unified logger API (issue #20).
// os.Logger emitters are stateless and fire-and-forget; the only properties under test
// are (a) that the helpers compile and do not crash at runtime, and (b) that DropReason
// covers its declared cases and conforms to Equatable.

@Suite("Log event helpers")
struct LogEventTests {

    // Each @Test calls exactly one event helper to prove it compiles and does not trap.

    @Test("emitRecordingStart does not crash")
    func recordingStart() {
        Log.emitRecordingStart()
    }

    @Test("emitRecordingStop does not crash")
    func recordingStop() {
        Log.emitRecordingStop()
        Log.emitRecordingStop(droppedFrameCount: 42)
    }

    @Test("emitFrameDropped does not crash for all DropReason cases")
    func frameDropped() {
        // Audio is never dropped (lossless audio guarantee); DropReason applies to video only.
        Log.emitFrameDropped(source: .screen, reason: .captureBound)
        Log.emitFrameDropped(source: .camera, reason: .poolExhausted)
        Log.emitFrameDropped(source: .screen, reason: .encoderBound)
        Log.emitFrameDropped(source: .camera, reason: .diskBound)
    }

    @Test("emitSourceFailure does not crash")
    func sourceFailure() {
        struct TestError: Error {}
        Log.emitSourceFailure(kind: .screen, error: TestError())
        Log.emitSourceFailure(kind: .camera, error: TestError())
        Log.emitSourceFailure(kind: .audio, error: TestError())
    }

    @Test("emitWriterFailure does not crash")
    func writerFailure() {
        struct TestError: Error {}
        Log.emitWriterFailure(output: "screen.mov", error: TestError(), isolated: true)
        Log.emitWriterFailure(output: "camera.mov", error: TestError(), isolated: false)
    }

    @Test("emitDegradationStep does not crash")
    func degradationStep() {
        Log.emitDegradationStep(step: "1", trigger: "dropped>5%", cooldown: false)
        Log.emitDegradationStep(step: "low-fps", trigger: "thermal", cooldown: true)
    }

    @Test("emitCapabilityProbe does not crash")
    func capabilityProbe() {
        Log.emitCapabilityProbe(hardwareHEVC: true, encoderCount: 2)
        Log.emitCapabilityProbe(hardwareHEVC: false, encoderCount: 0)
    }

    @Test("emitPermission does not crash")
    func permissionEvent() {
        Log.emitPermission(type: "screen", status: "granted")
        Log.emitPermission(type: "microphone", status: "denied")
    }
}

@Suite("DropReason")
struct DropReasonTests {

    @Test("DropReason covers all four cases")
    func allCases() {
        #expect(DropReason.allCases.count == 4)
    }

    @Test("DropReason Equatable")
    func equatable() {
        #expect(DropReason.captureBound == .captureBound)
        #expect(DropReason.poolExhausted != .diskBound)
    }
}
