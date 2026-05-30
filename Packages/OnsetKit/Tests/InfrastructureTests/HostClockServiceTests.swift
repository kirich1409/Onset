import CoreMedia
import Domain
import Foundation
import Testing

@testable import Infrastructure

// MARK: - HostClockServiceTests

/// Unit tests for `HostClockService` (AC-12: host-time clock reference).
///
/// ## What is deterministically testable here
///
/// - `referenceClock` identity: the stored clock equals `CMClockGetHostTimeClock()`.
/// - `now()` numeric and monotonically non-decreasing across two consecutive calls.
/// - `convert(_:from:)` identity: when `src` is `referenceClock` the result equals
///   the input (CMSyncConvertTime detects the same-clock case and returns unchanged).
/// - `convert(_:from:)` monotonicity for increasing inputs: a sequence of inputs
///   strictly ordered by `src` (the host clock itself) must produce outputs that are
///   also non-decreasing after conversion.
/// - Sendability: the type compiles when passed across an actor boundary (compile-level
///   check; no runtime assertion needed).
///
/// ## What requires hardware / AC-12 L5 acceptance
///
/// Genuine cross-clock conversion — verifying that a device audio clock whose PTS is on
/// a different hardware oscillator is correctly mapped to host time — cannot be asserted
/// deterministically at unit level. `convert(_:from:)` accepts a `CMClock` argument;
/// there is no deterministic synthetic `CMClock` with a controlled, inspectable offset
/// available in the Swift/CoreMedia API. `CMTimebase` (a related CF type that *does*
/// support controlled offsets) is a different type and is not accepted by
/// `CMSyncConvertTime` in place of a `CMClock`. Real cross-clock conversion (offset
/// device audio clock → host) is therefore verified at L5 on reference hardware per the
/// acceptance checklist in `docs/spec/testing.md`.
@Suite("HostClockService")
struct HostClockServiceTests {

    // MARK: - Helpers

    private let sut = HostClockService()

    // MARK: - referenceClock

    @Test("referenceClock is the host-time clock")
    func referenceClockIsHostTimeClock() {
        let expected = CMClockGetHostTimeClock()
        // CMClock is a CFTypeRef; pointer equality asserts same singleton.
        #expect(sut.referenceClock === expected)
    }

    // MARK: - now()

    @Test("now() returns a numeric CMTime")
    func nowIsNumeric() {
        let t = sut.now()
        #expect(t.isNumeric)
    }

    @Test("now() is monotonically non-decreasing")
    func nowIsNonDecreasing() {
        let t0 = sut.now()
        let t1 = sut.now()
        // Two consecutive calls may be equal at high clock resolution.
        #expect(CMTimeCompare(t1, t0) >= 0)
    }

    // MARK: - convert(_:from:)

    @Test("convert(_:from: referenceClock) returns identity")
    func convertIdentityCase() {
        let input = CMTime(seconds: 3.14, preferredTimescale: 90_000)
        let output = sut.convert(input, from: sut.referenceClock)
        // CMSyncConvertTime with same src and dst returns the input unchanged.
        #expect(output.isNumeric)
        #expect(CMTimeCompare(output, input) == 0)
    }

    @Test("convert(_:from: referenceClock) preserves ordering — same-clock identity path")
    func convertIdentityCasePreservesOrdering() {
        // src === dst (referenceClock): this is the same-clock identity path through
        // CMSyncConvertTime. The test verifies that passing monotonically increasing
        // inputs through this path produces non-decreasing outputs — it does NOT exercise
        // cross-clock conversion math, which requires a real device audio clock and is
        // covered at L5 (see suite-level doc above).
        let inputs: [CMTime] = [
            CMTime(seconds: 1.0, preferredTimescale: 90_000),
            CMTime(seconds: 1.5, preferredTimescale: 90_000),
            CMTime(seconds: 2.0, preferredTimescale: 90_000),
        ]
        let outputs = inputs.map { sut.convert($0, from: sut.referenceClock) }
        for i in outputs.indices.dropFirst() {
            #expect(
                CMTimeCompare(outputs[i], outputs[i - 1]) >= 0,
                "Output at index \(i) must be >= output at index \(i - 1)")
        }
    }

    @Test("convert(_:from:) returns invalid CMTime for invalid input")
    func convertInvalidInputYieldsInvalid() {
        // Document the contract: callers are responsible for numeric inputs;
        // CMSyncConvertTime propagates invalidity unchanged.
        let output = sut.convert(.invalid, from: sut.referenceClock)
        #expect(!output.isNumeric)
    }

    // MARK: - Sendability (compile-level)

    @Test("HostClockService is Sendable across an actor boundary")
    func sendableConformance() async {
        // Passing into a @Sendable closure would be a compile error if
        // HostClockService were not Sendable.
        let clock = HostClockService()
        let t = await Task.detached { @Sendable in
            clock.now()
        }.value
        #expect(t.isNumeric)
    }
}
