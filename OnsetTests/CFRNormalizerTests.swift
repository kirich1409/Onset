// CFRNormalizerTests.swift
// OnsetTests
//
// Swift Testing suite for CFRNormalizer (U2 of VideoEncoder #31).
//
// Time values are passed as Double seconds — no CoreMedia types needed.
// Synthetic sequences are constructed by arithmetic on a base anchor.
//
// swiftlint:disable no_magic_numbers
// no_magic_numbers is disabled for the whole file: these are Swift Testing structs
// (no XCTest parent class), so the rule's `test_parent_classes` exclusion in
// .swiftlint.yml does not apply; the numeric literals here are expected test data,
// not magic numbers.

@testable import Onset
import Testing

// MARK: - Even cadence

@Suite("CFRNormalizer — even cadence")
struct CFRNormalizerEvenCadenceTests {
    // Anchor at t=10s; 30fps → slot width = 1/30 s.
    private let anchor = 10.0
    private let fps = 30

    @Test("frame exactly on slot 0 snaps to slot 0, no drops")
    func frameOnSlot0() {
        var norm = CFRNormalizer()
        let pts = self.anchor // slot 0
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .encode(slotIndex: 0, snappedPTS: 0.0, isHold: false))
        #expect(norm.cfrNormalizationDrops == 0)
        #expect(norm.lastEmittedSlot == 0)
    }

    @Test("frames on consecutive grid points each produce encode, no drops")
    func consecutiveGridFrames_noDrops() {
        var norm = CFRNormalizer()
        for idx in 0..<5 {
            let pts = self.anchor + Double(idx) / Double(self.fps)
            let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
            let expected = CFRDecision.encode(slotIndex: idx, snappedPTS: Double(idx) / Double(self.fps), isHold: false)
            #expect(decision == expected)
        }
        #expect(norm.cfrNormalizationDrops == 0)
        #expect(norm.lastEmittedSlot == 4)
    }

    @Test("snappedPTS for slot N equals N/fps")
    func snappedPTSMatchesGrid() {
        var norm = CFRNormalizer()
        let slot = 3
        let pts = self.anchor + Double(slot) / Double(self.fps)
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        if case let .encode(slotIndex, snappedPTS, isHold) = decision {
            #expect(slotIndex == slot)
            #expect(snappedPTS == Double(slot) / Double(self.fps))
            #expect(!isHold)
        } else {
            Issue.record("Expected .encode, got \(decision)")
        }
    }
}

// MARK: - Skipped slot (hold)

@Suite("CFRNormalizer — hold (skipped slot)")
struct CFRNormalizerHoldTests {
    private let anchor = 0.0
    private let fps = 30

    @Test("tick for a gap slot emits encode(isHold:true), no drop increment")
    func tick_missedSlot_emitsHold() {
        var norm = CFRNormalizer()

        // Establish slot 0 via a real frame
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)

        // Slot 1 has no frame — clock drives a tick
        let decision = norm.processTick(slotIndex: 1, fps: self.fps)
        #expect(decision == .encode(slotIndex: 1, snappedPTS: 1.0 / Double(self.fps), isHold: true))
        #expect(norm.cfrNormalizationDrops == 0)
        #expect(norm.lastEmittedSlot == 1)
    }

    @Test("hold does NOT increment cfrNormalizationDrops")
    func hold_doesNotIncrementDropCounter() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        _ = norm.processTick(slotIndex: 1, fps: self.fps)
        _ = norm.processTick(slotIndex: 2, fps: self.fps)
        #expect(norm.cfrNormalizationDrops == 0)
    }

    @Test("after hold, next real frame continues from next slot")
    func afterHold_nextFrameEncodesCorrectly() {
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps) // slot 0
        _ = norm.processTick(slotIndex: 1, fps: self.fps) // hold slot 1
        let pts2 = self.anchor + 2.0 / Double(self.fps)
        let decision = norm.processFrame(ptsSeconds: pts2, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .encode(slotIndex: 2, snappedPTS: 2.0 / Double(self.fps), isHold: false))
        #expect(norm.cfrNormalizationDrops == 0)
    }
}

// MARK: - Two frames into one slot (drop)

@Suite("CFRNormalizer — duplicate slot drop")
struct CFRNormalizerDuplicateDropTests {
    private let anchor = 0.0
    private let fps = 30

    @Test("second frame in the same slot produces drop(.cfrNormalizationDrops)")
    func secondFrameInSameSlot_isDrop() {
        var norm = CFRNormalizer()
        let pts = self.anchor // slot 0
        _ = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps) // first: encode
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps) // second: drop
        #expect(decision == .drop(reason: .cfrNormalizationDrops))
        #expect(norm.cfrNormalizationDrops == 1)
    }

    @Test("cfrNormalizationDrops increments per duplicate, not per backpressure")
    func duplicateDrop_incrementsCFRCounter_notBackpressure() {
        // U3 assertion companion: cfrNormalizationDrops++ means encoderBackpressureDrops stays 0.
        // Here we verify the normalizer itself does not set any backpressure state —
        // cfrNormalizationDrops is the only counter the normalizer owns.
        var norm = CFRNormalizer()
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        _ = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        #expect(norm.cfrNormalizationDrops == 2)
        // The normalizer has no backpressure counter — the test asserts by exhaustion
        // (only cfrNormalizationDrops exists as a counter property).
    }

    @Test("slot boundary already passed: nearby-earlier frame is dropped")
    func frameMappingToAlreadyEmittedSlot_isDropped() {
        var norm = CFRNormalizer()
        // Emit slot 2 first (via a frame slightly ahead)
        let pts2 = self.anchor + 2.0 / Double(self.fps)
        _ = norm.processFrame(ptsSeconds: pts2, anchorSeconds: self.anchor, fps: self.fps)
        // Now a frame that maps to slot 1 arrives (out of order)
        let pts1 = self.anchor + 1.0 / Double(self.fps)
        let decision = norm.processFrame(ptsSeconds: pts1, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .drop(reason: .cfrNormalizationDrops))
        #expect(norm.cfrNormalizationDrops == 1)
        #expect(norm.lastEmittedSlot == 2) // unchanged
    }
}

// MARK: - Jitter around slot boundaries

@Suite("CFRNormalizer — jitter")
struct CFRNormalizerJitterTests {
    private let anchor = 0.0
    private let fps = 30

    @Test("frame slightly before slot boundary snaps to nearest slot")
    func frameBeforeSlotBoundary_snapsToNearestSlot() {
        var norm = CFRNormalizer()
        // Slot 1 centre = 1/30 s ≈ 0.03333s. A frame at 0.030s is 0.003s before centre,
        // still closer to slot 1 than slot 0.
        let pts = self.anchor + 1.0 / Double(self.fps) - 0.003
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        if case let .encode(slotIndex, _, _) = decision {
            #expect(slotIndex == 1)
        } else {
            Issue.record("Expected encode for slot 1, got \(decision)")
        }
    }

    @Test("frame slightly after slot boundary snaps to nearest slot")
    func frameAfterSlotBoundary_snapsToNearestSlot() {
        var norm = CFRNormalizer()
        // Slot 1 centre = 1/30s. A frame at 1/30s + 0.003s is closer to slot 1 than slot 2.
        let pts = self.anchor + 1.0 / Double(self.fps) + 0.003
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        if case let .encode(slotIndex, _, _) = decision {
            #expect(slotIndex == 1)
        } else {
            Issue.record("Expected encode for slot 1, got \(decision)")
        }
    }

    @Test("frame exactly halfway between two slots snaps to the later slot (round-half-away-from-zero)")
    func frameMidwayBetweenSlots() {
        var norm = CFRNormalizer()
        // Midpoint between slot 0 and slot 1 = 0.5/fps.
        // Swift's `rounded()` uses .toNearestOrAwayFromZero; a positive midpoint (0.5)
        // deterministically rounds up to slot 1, not "either 0 or 1".
        let pts = self.anchor + 0.5 / Double(self.fps)
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        if case let .encode(slotIndex, _, _) = decision {
            #expect(slotIndex == 1)
        } else {
            Issue.record("Expected encode, got \(decision)")
        }
    }
}

// MARK: - Pre-T0

@Suite("CFRNormalizer — pre-T0 guard")
struct CFRNormalizerPreAnchorTests {
    private let anchor = 10.0
    private let fps = 30

    @Test("frame before anchor produces drop(.preAnchor), no slot emitted")
    func frameBefore_anchor_isDropped() {
        var norm = CFRNormalizer()
        let pts = self.anchor - 0.5 // 0.5s before T0
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .drop(reason: .preAnchor))
        #expect(norm.lastEmittedSlot == -1) // no slot emitted
        #expect(norm.cfrNormalizationDrops == 0)
    }

    // Snap-to-nearest: a frame within half a slot of the anchor rounds to slot 0 and encodes.
    // 1 ms before anchor at 30 fps: slotIndex = round(-0.001 / (1/30)) = round(-0.03) = 0 → encode.
    @Test("frame within half a slot before anchor snaps to slot 0")
    func frameWithinHalfSlot_beforeAnchor_snapsToSlot0() {
        var norm = CFRNormalizer()
        let pts = self.anchor - 0.001 // 1 ms before anchor; well within the 16.67 ms half-slot at 30 fps
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .encode(slotIndex: 0, snappedPTS: 0.0, isHold: false))
    }

    /// A frame more than half a slot before the anchor computes slotIndex ≤ -1 and must be dropped.
    /// At 30 fps one slot is ~33.33 ms; one full frame duration before anchor → slotIndex = round(-1.0) = -1 → drop.
    @Test("frame more than half a slot before anchor is dropped")
    func frameMoreThanHalfSlot_beforeAnchor_isDropped() {
        var norm = CFRNormalizer()
        let frameDuration = 1.0 / Double(self.fps) // ~33.33 ms at 30 fps
        let pts = self.anchor - frameDuration // exactly one frame before anchor → slotIndex = -1
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .drop(reason: .preAnchor))
    }

    @Test("frame exactly at anchor maps to slot 0")
    func frameAt_anchor_isSlot0() {
        var norm = CFRNormalizer()
        let decision = norm.processFrame(ptsSeconds: self.anchor, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .encode(slotIndex: 0, snappedPTS: 0.0, isHold: false))
    }
}

// MARK: - Slot monotonicity

@Suite("CFRNormalizer — slot monotonicity")
struct CFRNormalizerMonotonicityTests {
    private let anchor = 0.0
    private let fps = 30

    @Test("out-of-order frame with earlier slot index is dropped")
    func outOfOrder_earlierSlot_isDropped() {
        var norm = CFRNormalizer()
        // Process slot 5 first
        let pts5 = self.anchor + 5.0 / Double(self.fps)
        _ = norm.processFrame(ptsSeconds: pts5, anchorSeconds: self.anchor, fps: self.fps)

        // Now an earlier-slot frame arrives (slot 3)
        let pts3 = self.anchor + 3.0 / Double(self.fps)
        let decision = norm.processFrame(ptsSeconds: pts3, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .drop(reason: .cfrNormalizationDrops))
        #expect(norm.lastEmittedSlot == 5) // did not go backwards
    }

    @Test("slot index never decreases after a sequence of frames")
    func slotNeverDecreases_overSequence() {
        var norm = CFRNormalizer()
        var previousSlot = -1

        let ptsList: [Double] = [
            anchor + 0.0 / Double(self.fps),
            self.anchor + 1.0 / Double(self.fps),
            self.anchor + 3.0 / Double(self.fps), // skip slot 2
            self.anchor + 2.0 / Double(self.fps), // out-of-order slot 2 → drop
            self.anchor + 4.0 / Double(self.fps),
        ]

        for pts in ptsList {
            let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
            if case .encode = decision {
                #expect(norm.lastEmittedSlot > previousSlot)
                previousSlot = norm.lastEmittedSlot
            }
        }
        #expect(norm.lastEmittedSlot == 4)
        #expect(norm.cfrNormalizationDrops == 1) // slot 2 was already past
    }

    @Test("emitting a slot equal to the last emitted slot is not permitted")
    func sameSlot_isDropped() {
        var norm = CFRNormalizer()
        let pts = self.anchor // slot 0
        _ = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        let decision = norm.processFrame(ptsSeconds: pts, anchorSeconds: self.anchor, fps: self.fps)
        #expect(decision == .drop(reason: .cfrNormalizationDrops))
    }
}

// MARK: - Decision Equatable

@Suite("CFRDecision — Equatable")
struct CFRDecisionEquatableTests {
    @Test("encode with same parameters is equal")
    func encode_sameParams_isEqual() {
        let lhs = CFRDecision.encode(slotIndex: 3, snappedPTS: 0.1, isHold: false)
        let rhs = CFRDecision.encode(slotIndex: 3, snappedPTS: 0.1, isHold: false)
        #expect(lhs == rhs)
    }

    @Test("encode with different isHold is not equal")
    func encode_differentIsHold_notEqual() {
        let lhs = CFRDecision.encode(slotIndex: 3, snappedPTS: 0.1, isHold: false)
        let rhs = CFRDecision.encode(slotIndex: 3, snappedPTS: 0.1, isHold: true)
        #expect(lhs != rhs)
    }

    @Test("drop with same reason is equal")
    func drop_sameReason_isEqual() {
        let lhs = CFRDecision.drop(reason: .cfrNormalizationDrops)
        let rhs = CFRDecision.drop(reason: .cfrNormalizationDrops)
        #expect(lhs == rhs)
    }

    @Test("drop with different reasons is not equal")
    func drop_differentReasons_notEqual() {
        let lhs = CFRDecision.drop(reason: .preAnchor)
        let rhs = CFRDecision.drop(reason: .cfrNormalizationDrops)
        #expect(lhs != rhs)
    }

    @Test("encode and drop are not equal")
    func encode_and_drop_notEqual() {
        let enc = CFRDecision.encode(slotIndex: 0, snappedPTS: 0.0, isHold: false)
        let drp = CFRDecision.drop(reason: .preAnchor)
        #expect(enc != drp)
    }
}

// swiftlint:enable no_magic_numbers
