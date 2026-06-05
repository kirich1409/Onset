// CFRNormalizerCatchUpHoldsTests.swift
// OnsetTests
//
// Swift Testing suite for CFRNormalizer.catchUpHolds, nextDeadlineSeconds, and
// monotonicity of interleaved catch-up sequences — Stage (a) of fix #102.
// All tests are pure and deterministic — no clock reads, no actors.
//
@testable import Onset
import Testing

// MARK: - catchUpHolds

@Suite("CFRNormalizer — catchUpHolds")
struct CFRNormalizerCatchUpHoldsTests {
    private let anchor = 0.0

    // Grace boundary: slot N eligible when now >= anchor + (N+0.5)/fps + grace.
    // ε = 0.001s (1ms): at fps=30 that's 0.03 slots — well clear of float noise.

    @Test("grace boundary at fps=30: slot N NOT eligible just before window close")
    func graceBoundary_30fps_notEligible() {
        let fps = 30
        let grace = 0.005
        let slotN = 3
        // Boundary: now = anchor + (3 + 0.5)/30 + 0.005 = anchor + 3.5/30 + 0.005
        let boundary = self.anchor + 3.5 / Double(fps) + grace
        let nowBefore = boundary - 0.001 // 1ms before eligibility
        var norm = CFRNormalizer()
        // Open grid at slot 0.
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: fps)
        // Advance via processFrame to slot 2 (slots 1,2 emitted).
        _ = norm.processFrame(ptsSeconds: self.anchor + 1.0 / Double(fps), anchorSeconds: self.anchor, fps: fps)
        _ = norm.processFrame(ptsSeconds: self.anchor + 2.0 / Double(fps), anchorSeconds: self.anchor, fps: fps)
        // lastEmittedSlot == 2; slot 3 should not yet be eligible.
        let emission = norm.catchUpHolds(
            nowSeconds: nowBefore,
            anchorSeconds: self.anchor,
            fps: fps,
            graceSeconds: grace,
            cap: 10
        )
        #expect(emission.slots.isEmpty, "slot \(slotN) must not be eligible at nowBefore")
        #expect(norm.lastEmittedSlot == 2)
    }

    @Test("grace boundary at fps=30: slot N becomes eligible just after window close")
    func graceBoundary_30fps_eligible() {
        let fps = 30
        let grace = 0.005
        let slotN = 3
        let boundary = self.anchor + 3.5 / Double(fps) + grace
        let nowAfter = boundary + 0.001 // 1ms after eligibility
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: fps)
        _ = norm.processFrame(ptsSeconds: self.anchor + 1.0 / Double(fps), anchorSeconds: self.anchor, fps: fps)
        _ = norm.processFrame(ptsSeconds: self.anchor + 2.0 / Double(fps), anchorSeconds: self.anchor, fps: fps)
        let emission = norm.catchUpHolds(
            nowSeconds: nowAfter,
            anchorSeconds: self.anchor,
            fps: fps,
            graceSeconds: grace,
            cap: 10
        )
        #expect(
            emission.slots == [CFREmittedSlot(slotIndex: slotN, isHold: true)],
            "slot \(slotN) must be eligible at nowAfter"
        )
        #expect(norm.lastEmittedSlot == slotN)
        // Holds must not increment the drop counter (OpAC-4.2).
        #expect(norm.cfrNormalizationDrops == 0)
    }

    @Test("grace boundary at fps=60: slot N NOT eligible just before window close")
    func graceBoundary_60fps_notEligible() {
        let fps = 60
        let grace = 0.005
        let slotN = 5
        let boundary = self.anchor + 5.5 / Double(fps) + grace
        let nowBefore = boundary - 0.001
        var norm = CFRNormalizer()
        for idx in 0..<slotN { // open grid through slot slotN-1
            _ = norm.processFrame(
                ptsSeconds: self.anchor + Double(idx) / Double(fps),
                anchorSeconds: self.anchor,
                fps: fps
            )
        }
        let emission = norm.catchUpHolds(
            nowSeconds: nowBefore,
            anchorSeconds: self.anchor,
            fps: fps,
            graceSeconds: grace,
            cap: 10
        )
        #expect(emission.slots.isEmpty)
    }

    @Test("grace boundary at fps=60: slot N becomes eligible just after window close")
    func graceBoundary_60fps_eligible() {
        let fps = 60
        let grace = 0.005
        let slotN = 5
        let boundary = self.anchor + 5.5 / Double(fps) + grace
        let nowAfter = boundary + 0.001
        var norm = CFRNormalizer()
        for idx in 0..<slotN {
            _ = norm.processFrame(
                ptsSeconds: self.anchor + Double(idx) / Double(fps),
                anchorSeconds: self.anchor,
                fps: fps
            )
        }
        let emission = norm.catchUpHolds(
            nowSeconds: nowAfter,
            anchorSeconds: self.anchor,
            fps: fps,
            graceSeconds: grace,
            cap: 10
        )
        #expect(emission.slots == [CFREmittedSlot(slotIndex: slotN, isHold: true)])
    }

    @Test("eligibleThrough <= lastEmittedSlot: returns empty")
    func eligibleThroughBehindLastEmitted_empty() {
        let fps = 30
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: fps) // slot 0
        // now is just barely past slot 0's window (eligibleThrough = 0 = lastEmittedSlot)
        let now = self.anchor + 0.5 / Double(fps) + 0.001
        let emission = norm.catchUpHolds(
            nowSeconds: now, anchorSeconds: self.anchor, fps: fps, graceSeconds: 0.0, cap: 10
        )
        #expect(emission.slots.isEmpty)
    }

    @Test("lastEmittedSlot == -1: returns empty (grid not open)")
    func gridNotOpen_empty() {
        let fps = 30
        var norm = CFRNormalizer()
        let emission = norm.catchUpHolds(
            nowSeconds: self.anchor + 100.0, anchorSeconds: self.anchor, fps: fps, graceSeconds: 0.0, cap: 10
        )
        #expect(emission.slots.isEmpty)
        #expect(norm.lastEmittedSlot == -1)
    }

    @Test("multi-slot catch-up emits all eligible slots ascending")
    func multiSlot_allEligible_ascending() {
        let fps = 30
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: fps) // slot 0
        // now is well past slots 1,2,3 (no grace).
        let now = self.anchor + 3.5 / Double(fps) + 0.001
        let emission = norm.catchUpHolds(
            nowSeconds: now, anchorSeconds: self.anchor, fps: fps, graceSeconds: 0.0, cap: 10
        )
        let expected: [CFREmittedSlot] = [
            CFREmittedSlot(slotIndex: 1, isHold: true),
            CFREmittedSlot(slotIndex: 2, isHold: true),
            CFREmittedSlot(slotIndex: 3, isHold: true),
        ]
        #expect(emission.slots == expected)
        #expect(!emission.cappedShort)
        #expect(norm.lastEmittedSlot == 3)
    }

    @Test("cap truncation produces cappedShort and continuation on next call")
    func cap_truncation_cappedShort_continuation() {
        let fps = 30
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: fps) // slot 0
        // now is past slots 1..5.
        let now = self.anchor + 5.5 / Double(fps) + 0.001
        // First call: cap=2 → holds 1,2; lastEmittedSlot=2; cappedShort
        let emission1 = norm.catchUpHolds(
            nowSeconds: now, anchorSeconds: self.anchor, fps: fps, graceSeconds: 0.0, cap: 2
        )
        #expect(emission1.slots == [
            CFREmittedSlot(slotIndex: 1, isHold: true),
            CFREmittedSlot(slotIndex: 2, isHold: true),
        ])
        #expect(emission1.cappedShort)
        #expect(norm.lastEmittedSlot == 2)

        // Second call: cap=2 → holds 3,4; lastEmittedSlot=4; cappedShort
        let emission2 = norm.catchUpHolds(
            nowSeconds: now, anchorSeconds: self.anchor, fps: fps, graceSeconds: 0.0, cap: 2
        )
        #expect(emission2.slots == [
            CFREmittedSlot(slotIndex: 3, isHold: true),
            CFREmittedSlot(slotIndex: 4, isHold: true),
        ])
        #expect(emission2.cappedShort)
        #expect(norm.lastEmittedSlot == 4)

        // Third call: cap=2 → holds 5 only (just 1 eligible); NOT cappedShort
        let emission3 = norm.catchUpHolds(
            nowSeconds: now, anchorSeconds: self.anchor, fps: fps, graceSeconds: 0.0, cap: 2
        )
        #expect(emission3.slots == [CFREmittedSlot(slotIndex: 5, isHold: true)])
        #expect(!emission3.cappedShort)
        #expect(norm.lastEmittedSlot == 5)
    }

    @Test("cfrNormalizationDrops is not touched by catchUpHolds")
    func catchUpHolds_doesNotTouchDropCounter() {
        let fps = 30
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: fps)
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: fps) // duplicate → drop
        let dropsBefore = norm.cfrNormalizationDrops
        let now = self.anchor + 3.5 / Double(fps) + 0.001
        _ = norm.catchUpHolds(
            nowSeconds: now, anchorSeconds: self.anchor, fps: fps, graceSeconds: 0.0, cap: 10
        )
        #expect(norm.cfrNormalizationDrops == dropsBefore)
    }
}

// MARK: - nextDeadlineSeconds

@Suite("CFRNormalizer — nextDeadlineSeconds")
struct CFRNormalizerNextDeadlineTests {
    @Test("nextDeadlineSeconds at fps=30, no grace: deadline for slot lastEmittedSlot+1")
    func nextDeadline_30fps_noGrace() {
        var norm = CFRNormalizer()
        let anchor = 0.0
        let fps = 30
        // lastEmittedSlot == -1 → deadline = anchor + 0.5/fps (slot 0 boundary).
        let deadline0 = norm.nextDeadlineSeconds(anchorSeconds: anchor, fps: fps, graceSeconds: 0.0)
        #expect(deadline0 == anchor + 0.5 / Double(fps))
        _ = norm.processFrame(ptsSeconds: anchor, anchorSeconds: anchor, fps: fps) // slot 0
        let deadline1 = norm.nextDeadlineSeconds(anchorSeconds: anchor, fps: fps, graceSeconds: 0.0)
        #expect(deadline1 == anchor + 1.5 / Double(fps))
    }

    @Test("nextDeadlineSeconds at fps=60, no grace")
    func nextDeadline_60fps_noGrace() {
        var norm = CFRNormalizer()
        let anchor = 5.0
        let fps = 60
        _ = norm.processFrame(ptsSeconds: anchor, anchorSeconds: anchor, fps: fps)
        _ = norm.processFrame(ptsSeconds: anchor + 1.0 / Double(fps), anchorSeconds: anchor, fps: fps)
        // After slot 1: deadline = anchor + 2.5/60.
        let deadline = norm.nextDeadlineSeconds(anchorSeconds: anchor, fps: fps, graceSeconds: 0.0)
        #expect(deadline == anchor + 2.5 / Double(fps))
    }

    @Test("nextDeadlineSeconds with grace shifts deadline by graceSeconds")
    func nextDeadline_withGrace() {
        var norm = CFRNormalizer()
        let anchor = 0.0
        let fps = 30
        let grace = 0.005
        _ = norm.processFrame(ptsSeconds: anchor, anchorSeconds: anchor, fps: fps) // slot 0
        let deadline = norm.nextDeadlineSeconds(anchorSeconds: anchor, fps: fps, graceSeconds: grace)
        let expected = anchor + 1.5 / Double(fps) + grace
        #expect(deadline == expected)
    }

    @Test("nextDeadlineSeconds equals catchUpHolds eligibility boundary (consistent contract)")
    func nextDeadline_matchesCatchUpHoldsEligibility() {
        // nextDeadlineSeconds returns the earliest time at which catchUpHolds would emit.
        // Verify: calling catchUpHolds at deadline - ε returns empty; at deadline + ε returns one hold.
        let fps = 30
        let grace = 0.005
        let anchor = 0.0
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: anchor, anchorSeconds: anchor, fps: fps) // slot 0

        let deadline = norm.nextDeadlineSeconds(anchorSeconds: anchor, fps: fps, graceSeconds: grace)

        var normBefore = norm
        let emissionBefore = normBefore.catchUpHolds(
            nowSeconds: deadline - 0.001,
            anchorSeconds: anchor,
            fps: fps,
            graceSeconds: grace,
            cap: 10
        )
        #expect(emissionBefore.slots.isEmpty, "before deadline: no hold expected")

        var normAfter = norm
        let emissionAfter = normAfter.catchUpHolds(
            nowSeconds: deadline + 0.001,
            anchorSeconds: anchor,
            fps: fps,
            graceSeconds: grace,
            cap: 10
        )
        #expect(emissionAfter.slots.count == 1, "after deadline: exactly one hold expected")
        #expect(emissionAfter.slots.first?.isHold == true)
    }
}

// MARK: - Monotonicity (interleaved sequence)

@Suite("CFRNormalizer — monotonicity (interleaved catch-up sequence)")
struct CFRNormalizerCatchUpMonotonicityTests {
    private let anchor = 0.0
    private let fps = 30

    // Sequence: slots 0,1 via processFrame; frame at slot 5 (holds 2,3,4 via catchUpThenEncode);
    // clock tick to slot 7 (holds 6,7 via catchUpHolds); frame at slot 8.
    // Expected: 0,1,2,3,4,5,6,7,8 — contiguous, no gaps.
    @Test("interleaved catchUpThenEncode + catchUpHolds: all emitted slots strictly ascending, no gaps")
    func interleaved_strictlyAscendingNoGaps() {
        var norm = CFRNormalizer()
        var allEmitted: [Int] = []

        // Slots 0, 1 via processFrame.
        for idx in 0..<2 {
            let decision = norm.processFrame(
                ptsSeconds: self.anchor + Double(idx) / Double(self.fps),
                anchorSeconds: self.anchor,
                fps: self.fps
            )
            if case let .encode(slotIndex, _, _) = decision { allEmitted.append(slotIndex) }
        }

        // Real frame at slot 5 → holds 2,3,4 then real 5.
        let pts5 = self.anchor + 5.0 / Double(self.fps)
        let catchUp1 = norm.catchUpThenEncode(ptsSeconds: pts5, anchorSeconds: self.anchor, fps: self.fps, cap: 100)
        allEmitted.append(contentsOf: catchUp1.slots.map(\.slotIndex))

        // Clock advances to now = anchor + 7.5/fps + ε (slots 6 and 7 now eligible, no grace).
        let now = self.anchor + 7.5 / Double(self.fps) + 0.001
        let clockHolds = norm.catchUpHolds(
            nowSeconds: now, anchorSeconds: self.anchor, fps: self.fps, graceSeconds: 0.0, cap: 100
        )
        allEmitted.append(contentsOf: clockHolds.slots.map(\.slotIndex))

        // Real frame at slot 8.
        let pts8 = self.anchor + 8.0 / Double(self.fps)
        let catchUp2 = norm.catchUpThenEncode(ptsSeconds: pts8, anchorSeconds: self.anchor, fps: self.fps, cap: 100)
        allEmitted.append(contentsOf: catchUp2.slots.map(\.slotIndex))

        // Verify: strictly ascending.
        #expect(
            zip(allEmitted, allEmitted.dropFirst()).allSatisfy { $0 < $1 },
            "slots must be strictly ascending, got \(allEmitted)"
        )
        // Verify: no gaps (contiguous from 0 to 8).
        let expectedSlots = Array(0...8)
        #expect(allEmitted == expectedSlots, "expected contiguous 0..8, got \(allEmitted)")
    }

    @Test("cfrNormalizationDrops unaffected by catchUpThenEncode and catchUpHolds calls")
    func cfrNormalizationDrops_unaffectedByNewAPIs() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps) // dup → drop
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps) // dup → drop
        #expect(norm.cfrNormalizationDrops == 2)
        let pts8 = self.anchor + 8.0 / Double(self.fps)
        _ = norm.catchUpThenEncode(ptsSeconds: pts8, anchorSeconds: self.anchor, fps: self.fps, cap: 100)
        let now = self.anchor + 12.5 / Double(self.fps) + 0.001
        _ = norm.catchUpHolds(nowSeconds: now, anchorSeconds: self.anchor, fps: self.fps, graceSeconds: 0.0, cap: 100)
        #expect(norm.cfrNormalizationDrops == 2)
    }
}
