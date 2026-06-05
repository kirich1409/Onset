// CFRNormalizerCatchUpTests.swift
// OnsetTests
//
// Swift Testing suite for CFRNormalizer catch-up API — Stage (a) of fix #102.
// All tests are pure and deterministic — no clock reads, no actors.
//
@testable import Onset
import Testing

// MARK: - slotFor

@Suite("CFRNormalizer — slotFor")
struct CFRNormalizerSlotForTests {
    private let anchor = 10.0

    // Verify slotFor produces the same mapping as processFrame for representative PTS values.

    @Test("slotFor matches processFrame for exact grid points at 30 fps")
    func slotFor_matchesProcessFrame_exactGridPoints_30fps() {
        let fps = 30
        for idx in 0..<10 {
            let pts = self.anchor + Double(idx) / Double(fps)
            let expected = idx
            let actual = CFRNormalizer.slotFor(ptsSeconds: pts, anchorSeconds: self.anchor, fps: fps)
            #expect(actual == expected, "slot mismatch at idx=\(idx)")
        }
    }

    @Test("slotFor matches processFrame for exact grid points at 60 fps")
    func slotFor_matchesProcessFrame_exactGridPoints_60fps() {
        let fps = 60
        for idx in 0..<10 {
            let pts = self.anchor + Double(idx) / Double(fps)
            let actual = CFRNormalizer.slotFor(ptsSeconds: pts, anchorSeconds: self.anchor, fps: fps)
            #expect(actual == idx, "slot mismatch at idx=\(idx)")
        }
    }

    @Test("slotFor mid-slot PTS maps to the enclosing slot (30 fps)")
    func slotFor_midSlot_30fps() {
        // Slot 3 centre = 3/30 = 0.1s; a PTS at 3.2/30 is still closer to slot 3 than slot 4.
        let fps = 30
        let pts = self.anchor + 3.2 / Double(fps)
        let actual = CFRNormalizer.slotFor(ptsSeconds: pts, anchorSeconds: self.anchor, fps: fps)
        #expect(actual == 3)
    }

    @Test("slotFor at exactly +0.5/fps boundary rounds to next slot (round-half-away-from-zero)")
    func slotFor_halfBoundary_roundsUp() {
        // 0.5/fps is the midpoint between slot 0 and slot 1.
        // Swift's `.rounded()` uses .toNearestOrAwayFromZero, so 0.5 → 1.
        let fps = 30
        let pts = self.anchor + 0.5 / Double(fps)
        let actual = CFRNormalizer.slotFor(ptsSeconds: pts, anchorSeconds: self.anchor, fps: fps)
        #expect(actual == 1)
    }

    @Test("slotFor pre-anchor PTS returns negative index")
    func slotFor_preAnchor_negative() {
        let fps = 30
        let pts = self.anchor - 1.0 / Double(fps) // exactly one frame before anchor → slot -1
        let actual = CFRNormalizer.slotFor(ptsSeconds: pts, anchorSeconds: self.anchor, fps: fps)
        #expect(actual == -1)
    }

    @Test("slotFor parity: processFrame internal slot agrees with slotFor for same PTS")
    func slotFor_parityWithProcessFrame() {
        var norm = CFRNormalizer()
        let fps = 30
        // Jump directly to slot 7 and confirm processFrame's internal slot equals slotFor.
        let pts = self.anchor + 7.0 / Double(fps)
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: fps)
        let expected = CFRNormalizer.slotFor(ptsSeconds: pts, anchorSeconds: self.anchor, fps: fps)
        if case let .encode(slotIndex, _, _) = decision {
            #expect(slotIndex == expected)
        } else {
            Issue.record("Expected .encode, got \(decision)")
        }
    }
}

// MARK: - catchUpThenEncode

@Suite("CFRNormalizer — catchUpThenEncode")
struct CFRNormalizerCatchUpThenEncodeTests {
    private let anchor = 0.0
    private let fps = 30

    @Test("adjacent slot (no holds): S = lastEmittedSlot + 1")
    func adjacentSlot_noHolds() {
        var norm = CFRNormalizer()
        // Open grid at slot 0 via processFrame.
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        // Frame at slot 1: no gap → no holds, just the real slot.
        let pts1 = self.anchor + 1.0 / Double(self.fps)
        let emission = norm.catchUpThenEncode(ptsSeconds: pts1, anchorSeconds: self.anchor, fps: self.fps, cap: 10)
        #expect(emission.slots == [CFREmittedSlot(slotIndex: 1, isHold: false)])
        #expect(!emission.cappedShort)
        #expect(norm.lastEmittedSlot == 1)
    }

    @Test("gap S=5 after slot 1 emits holds 2,3,4 then real 5; ascending; lastEmittedSlot=5")
    func gap_holdsBeforeReal() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(
            ptsSeconds: self.anchor + 1.0 / Double(self.fps),
            anchorSeconds: self.anchor,
            fps: self.fps
        )
        let pts5 = self.anchor + 5.0 / Double(self.fps)
        let emission = norm.catchUpThenEncode(ptsSeconds: pts5, anchorSeconds: self.anchor, fps: self.fps, cap: 10)
        let expected: [CFREmittedSlot] = [
            CFREmittedSlot(slotIndex: 2, isHold: true),
            CFREmittedSlot(slotIndex: 3, isHold: true),
            CFREmittedSlot(slotIndex: 4, isHold: true),
            CFREmittedSlot(slotIndex: 5, isHold: false),
        ]
        #expect(emission.slots == expected)
        #expect(!emission.cappedShort)
        #expect(norm.lastEmittedSlot == 5)
        // Slots are strictly ascending.
        let indices = emission.slots.map(\.slotIndex)
        #expect(zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("first frame at S=5 with lastEmittedSlot==-1 emits single real slot, no holds")
    func firstFrame_noLeadingHolds() {
        // When lastEmittedSlot == -1, there is no prior compressed frame to hold.
        // The encoder's buffer is empty; emitting holds would reference a non-existent output.
        var norm = CFRNormalizer()
        let pts5 = self.anchor + 5.0 / Double(self.fps)
        let emission = norm.catchUpThenEncode(ptsSeconds: pts5, anchorSeconds: self.anchor, fps: self.fps, cap: 10)
        #expect(emission.slots == [CFREmittedSlot(slotIndex: 5, isHold: false)])
        #expect(!emission.cappedShort)
        #expect(norm.lastEmittedSlot == 5)
    }

    @Test("duplicate S (== lastEmittedSlot): returns empty emission, counters untouched")
    func duplicate_returnsEmpty_countersUntouched() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        let dropsBefore = norm.cfrNormalizationDrops
        let lastBefore = norm.lastEmittedSlot
        let emission = norm.catchUpThenEncode(
            ptsSeconds: self.anchor,
            anchorSeconds: self.anchor,
            fps: self.fps,
            cap: 10
        )
        #expect(emission.slots.isEmpty)
        #expect(!emission.cappedShort)
        #expect(norm.cfrNormalizationDrops == dropsBefore)
        #expect(norm.lastEmittedSlot == lastBefore)
    }

    @Test("pre-anchor S (< 0): returns empty emission, counters untouched")
    func preAnchor_returnsEmpty_countersUntouched() {
        var norm = CFRNormalizer()
        let ptsBefore = self.anchor - 1.0 / Double(self.fps) // slot -1
        let dropsBefore = norm.cfrNormalizationDrops
        let lastBefore = norm.lastEmittedSlot
        let emission = norm.catchUpThenEncode(ptsSeconds: ptsBefore, anchorSeconds: self.anchor, fps: self.fps, cap: 10)
        #expect(emission.slots.isEmpty)
        #expect(!emission.cappedShort)
        #expect(norm.cfrNormalizationDrops == dropsBefore)
        #expect(norm.lastEmittedSlot == lastBefore)
    }

    @Test("cap: gap of 10 holds with cap=3 → exactly 3 holds, cappedShort, no real slot")
    func cap_limitsHolds_noRealSlot() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        let pts11 = self.anchor + 11.0 / Double(self.fps)
        let emission = norm.catchUpThenEncode(ptsSeconds: pts11, anchorSeconds: self.anchor, fps: self.fps, cap: 3)
        let expected: [CFREmittedSlot] = [
            CFREmittedSlot(slotIndex: 1, isHold: true),
            CFREmittedSlot(slotIndex: 2, isHold: true),
            CFREmittedSlot(slotIndex: 3, isHold: true),
        ]
        #expect(emission.slots == expected)
        #expect(emission.cappedShort)
        #expect(norm.lastEmittedSlot == 3)
    }

    @Test("cap exceeded then subsequent call continues from capped position")
    func cap_subsequentCallContinues() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        let pts11 = self.anchor + 11.0 / Double(self.fps)
        // First call: cap=3 → holds 1,2,3; lastEmittedSlot=3
        _ = norm.catchUpThenEncode(ptsSeconds: pts11, anchorSeconds: self.anchor, fps: self.fps, cap: 3)
        // Second call: same pts11, gap now 7; cap=3 again → holds 4,5,6.
        let emission2 = norm.catchUpThenEncode(ptsSeconds: pts11, anchorSeconds: self.anchor, fps: self.fps, cap: 3)
        let expected: [CFREmittedSlot] = [
            CFREmittedSlot(slotIndex: 4, isHold: true),
            CFREmittedSlot(slotIndex: 5, isHold: true),
            CFREmittedSlot(slotIndex: 6, isHold: true),
        ]
        #expect(emission2.slots == expected)
        #expect(emission2.cappedShort)
        #expect(norm.lastEmittedSlot == 6)
    }

    @Test("cfrNormalizationDrops is not touched by catchUpThenEncode")
    func catchUpThenEncode_doesNotTouchDropCounter() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps) // duplicate → drop
        let dropsBefore = norm.cfrNormalizationDrops
        let pts5 = self.anchor + 5.0 / Double(self.fps)
        _ = norm.catchUpThenEncode(ptsSeconds: pts5, anchorSeconds: self.anchor, fps: self.fps, cap: 10)
        #expect(norm.cfrNormalizationDrops == dropsBefore)
    }
}

// MARK: - CFREmittedSlot / CFREmission Equatable

@Suite("CFREmittedSlot + CFREmission — Equatable")
struct CFREmittedSlotEquatableTests {
    @Test("CFREmittedSlot: same slotIndex + isHold is equal")
    func emittedSlot_sameParams_equal() {
        let lhs = CFREmittedSlot(slotIndex: 3, isHold: true)
        let rhs = CFREmittedSlot(slotIndex: 3, isHold: true)
        #expect(lhs == rhs)
    }

    @Test("CFREmittedSlot: different isHold is not equal")
    func emittedSlot_differentIsHold_notEqual() {
        let lhs = CFREmittedSlot(slotIndex: 3, isHold: true)
        let rhs = CFREmittedSlot(slotIndex: 3, isHold: false)
        #expect(lhs != rhs)
    }

    @Test("CFREmission: same slots + cappedShort is equal")
    func emission_sameContent_equal() {
        let lhs = CFREmission(slots: [CFREmittedSlot(slotIndex: 1, isHold: true)], cappedShort: false)
        let rhs = CFREmission(slots: [CFREmittedSlot(slotIndex: 1, isHold: true)], cappedShort: false)
        #expect(lhs == rhs)
    }

    @Test("CFREmission: different cappedShort is not equal")
    func emission_differentCappedShort_notEqual() {
        let lhs = CFREmission(slots: [CFREmittedSlot(slotIndex: 1, isHold: true)], cappedShort: true)
        let rhs = CFREmission(slots: [CFREmittedSlot(slotIndex: 1, isHold: true)], cappedShort: false)
        #expect(lhs != rhs)
    }
}
