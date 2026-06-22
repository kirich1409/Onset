@testable import Onset
import Testing
import UserNotifications

// MARK: - Off-actor witness probe

/// A free `nonisolated` function that compares and hashes `CriticalIncident` values off the main
/// actor. It compiling AT ALL proves the `==` / `hash(into:)` witnesses are `nonisolated` — under
/// `InferIsolatedConformances` a `@MainActor`-inferred witness would make this fail to build.
nonisolated private func compareOffActor(
    _ lhs: CriticalIncident,
    _ rhs: CriticalIncident
)
-> (equal: Bool, sameHash: Bool) {
    let equal = lhs == rhs
    var lhsHasher = Hasher()
    var rhsHasher = Hasher()
    lhs.hash(into: &lhsHasher)
    rhs.hash(into: &rhsHasher)
    return (equal, lhsHasher.finalize() == rhsHasher.finalize())
}

// MARK: - CriticalIncident tests

@Suite("CriticalIncident — severity + nonisolated witnesses")
struct CriticalIncidentTests {
    // MARK: - Severity

    @Test("cameraAndScreen loss is soft; everything else is hard")
    func severity_byCase() {
        #expect(CriticalIncident.cameraLost(scope: .cameraAndScreen).severity == .soft)
        #expect(CriticalIncident.cameraLost(scope: .cameraOnly).severity == .hard)
        #expect(CriticalIncident.sustainedDrops.severity == .hard)
        #expect(CriticalIncident.fpsCollapse.severity == .hard)
    }

    // MARK: - Off-actor Equatable / Hashable

    @Test("equal incidents compare equal and hash equal off the main actor — both scopes")
    func witnesses_equalOffActor() {
        let cameraOnly = compareOffActor(
            .cameraLost(scope: .cameraOnly),
            .cameraLost(scope: .cameraOnly)
        )
        #expect(cameraOnly.equal == true)
        #expect(cameraOnly.sameHash == true)

        let cameraAndScreen = compareOffActor(
            .cameraLost(scope: .cameraAndScreen),
            .cameraLost(scope: .cameraAndScreen)
        )
        #expect(cameraAndScreen.equal == true)
        #expect(cameraAndScreen.sameHash == true)

        let drops = compareOffActor(.sustainedDrops, .sustainedDrops)
        #expect(drops.equal == true)
        #expect(drops.sameHash == true)
    }

    @Test("incidents differing only by scope are not equal off the main actor")
    func witnesses_scopeDistinguishesOffActor() {
        let result = compareOffActor(
            .cameraLost(scope: .cameraOnly),
            .cameraLost(scope: .cameraAndScreen)
        )
        #expect(result.equal == false)
    }

    @Test("different cases are not equal off the main actor")
    func witnesses_differentCasesOffActor() {
        let result = compareOffActor(.sustainedDrops, .fpsCollapse)
        #expect(result.equal == false)
    }

    // MARK: - Usable in a Set (Hashable end-to-end)

    @Test("incidents are usable as Set members")
    func incidents_inSet() {
        let set: Set<CriticalIncident> = [
            .cameraLost(scope: .cameraOnly),
            .cameraLost(scope: .cameraAndScreen),
            .cameraLost(scope: .cameraOnly), // duplicate
            .sustainedDrops,
            .fpsCollapse,
        ]
        #expect(set.count == 4)
    }
}

// MARK: - Notifier level-by-tier tests

@Suite("RecordingStartNotifying critical contract — level by tier via Fake")
@MainActor
struct CriticalNotifierContractTests {
    @Test("hard incident records a timeSensitive interruption level")
    func hardIncident_recordsTimeSensitive() {
        let fake = FakeRecordingStartNotifier()
        fake.notifyCriticalIncident(.fpsCollapse)
        fake.notifyCriticalIncident(.cameraLost(scope: .cameraOnly))

        #expect(fake.criticalIncidents == [.fpsCollapse, .cameraLost(scope: .cameraOnly)])
        #expect(fake.criticalIncidentLevels == [.timeSensitive, .timeSensitive])
    }

    @Test("soft incident records an active interruption level")
    func softIncident_recordsActive() {
        let fake = FakeRecordingStartNotifier()
        fake.notifyCriticalIncident(.cameraLost(scope: .cameraAndScreen))

        #expect(fake.criticalIncidents == [.cameraLost(scope: .cameraAndScreen)])
        #expect(fake.criticalIncidentLevels == [.active])
    }

    @Test("post-stop summary records the severity passed")
    func postStopSummary_recordsSeverity() {
        let fake = FakeRecordingStartNotifier()
        fake.notifyPostStopSummary(severity: .hard)
        fake.notifyPostStopSummary(severity: .soft)
        #expect(fake.postStopSeverities == [.hard, .soft])
    }

    @Test("severity maps to interruption level via the shared mapping")
    func severity_interruptionLevelMapping() {
        #expect(CriticalSeverity.hard.interruptionLevel == .timeSensitive)
        #expect(CriticalSeverity.soft.interruptionLevel == .active)
    }
}
