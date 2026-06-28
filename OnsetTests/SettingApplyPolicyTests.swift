@testable import Onset
import Testing

// MARK: - SettingApplyPolicyTests

/// L2 test confirming `SettingApplyPolicy`'s manual `nonisolated` equality witness is usable off
/// the main actor — the conformance must not be inferred as `@MainActor`-isolated under
/// `InferIsolatedConformances`, or the `ControlAvailability` classifier could not compare it from
/// its `nonisolated` context.
@Suite("SettingApplyPolicy — off-main equality")
struct SettingApplyPolicyTests {
    /// Exercises `==` / `!=` inside a detached (nonisolated) task. The fact that this closure
    /// COMPILES is itself the proof of off-main usability — a `@MainActor`-isolated `==` could not
    /// be called from a `@Sendable` detached closure without `await`. The boolean results are
    /// returned and asserted on the test's own context (detached tasks drop the Swift Testing
    /// task-local, so `#expect` must not run inside the detached task).
    @Test("equality witness is usable off the main actor")
    func equalityWitness_usableOffMain() async {
        let results = await Task.detached {
            [
                SettingApplyPolicy.immediate == .immediate,
                SettingApplyPolicy.nextRecordingStart == .nextRecordingStart,
                SettingApplyPolicy.requiresRelaunch == .requiresRelaunch,
                SettingApplyPolicy.immediate != .nextRecordingStart,
                SettingApplyPolicy.nextRecordingStart != .requiresRelaunch,
            ]
        }.value
        #expect(!results.contains(false))
    }
}
