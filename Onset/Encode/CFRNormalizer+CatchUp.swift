// CFRNormalizer+CatchUp.swift
// Onset
//
// Catch-up emission API for CFRNormalizer — Stage (a) of fix #102.
//
// Adds the batch-emission types and methods needed by the revised CFR clock driver (Stage b).
// All types remain CoreMedia-free and nonisolated; see CFRNormalizer.swift for the design rationale.
//
// New surface:
//   CFREmittedSlot  — a single slot in a CFREmission batch
//   CFREmission     — batch result of a catch-up call
//   CFRNormalizer.slotFor(ptsSeconds:anchorSeconds:fps:)         — non-mutating slot mapping
//   CFRNormalizer.catchUpThenEncode(ptsSeconds:anchorSeconds:fps:cap:) — ingest driver
//   CFRNormalizer.catchUpHolds(nowSeconds:anchorSeconds:fps:graceSeconds:cap:) — clock driver
//   CFRNormalizer.nextDeadlineSeconds(anchorSeconds:fps:graceSeconds:)  — scheduler helper

import Foundation

// MARK: - CFREmittedSlot

/// A single slot emitted by the catch-up API.
///
/// - `slotIndex`: The integer CFR grid index. Slots within a single `CFREmission` are
///   strictly ascending; the terminal (non-hold) slot, if present, is always last.
/// - `isHold`: `true` when this slot is a synthetic hold (no real frame available);
///   `false` only for the terminal slot carrying a real frame.
///
/// At most one non-hold slot exists in any `CFREmission`, and it is always the final
/// element in `CFREmission.slots`.
nonisolated struct CFREmittedSlot: Equatable {
    let slotIndex: Int
    let isHold: Bool
}

// swiftformat:disable:next redundantEquatable
extension CFREmittedSlot {
    /// Manual `nonisolated` equality witness.
    ///
    /// Required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    /// `InferIsolatedConformances`. The conformance is on the primary `nonisolated`
    /// definition above; this extension provides the synthesised-replacement witness.
    nonisolated static func == (lhs: CFREmittedSlot, rhs: CFREmittedSlot) -> Bool {
        lhs.slotIndex == rhs.slotIndex && lhs.isHold == rhs.isHold
    }
}

// MARK: - CFREmission

/// The batch result of a catch-up API call.
///
/// - `slots`: The slots emitted in this call, strictly ascending by `slotIndex`.
///   At most one element has `isHold == false` (the terminal real-frame slot, always last).
/// - `cappedShort`: `true` when the number of leading holds exceeded `cap`; the real
///   frame's slot was NOT included in this emission. The frame content for that slot is
///   consciously deferred (or lost on pathological lag) — the caller must route accordingly.
nonisolated struct CFREmission: Equatable {
    let slots: [CFREmittedSlot]
    let cappedShort: Bool
}

// swiftformat:disable:next redundantEquatable
extension CFREmission {
    /// Manual `nonisolated` equality witness.
    ///
    /// Delegates array equality to `[CFREmittedSlot].==`, which in turn uses the manual
    /// `CFREmittedSlot.==` witness, keeping the full chain nonisolated.
    nonisolated static func == (lhs: CFREmission, rhs: CFREmission) -> Bool {
        lhs.slots == rhs.slots && lhs.cappedShort == rhs.cappedShort
    }
}

// MARK: - CFRNormalizer catch-up extension

extension CFRNormalizer {
    // MARK: - Catch-up emission (ingest driver)

    /// Emits holds to catch up to `ptsSeconds` and then encodes the real frame.
    ///
    /// Called by the ingest driver (U3 actor) when a real frame arrives. The caller MUST
    /// have already routed duplicates and pre-anchor frames through `processFrame` for
    /// accounting before calling this method. This method assumes the frame is valid (its
    /// slot S is positive and beyond `lastEmittedSlot`).
    ///
    /// ## Behaviour
    ///
    /// 1. Compute `S = slotFor(ptsSeconds:anchorSeconds:fps:)`.
    /// 2. **Defensive guards:** if `S < 0` or `S <= lastEmittedSlot` → return an empty
    ///    emission (`cappedShort: false`) without mutating state. These cases should have
    ///    been handled by the caller via `processFrame`.
    /// 3. **Leading holds:** slots `[lastEmittedSlot+1 ..< S]` emitted as `isHold: true`,
    ///    but ONLY when `lastEmittedSlot >= 0`. When `lastEmittedSlot == -1` (the grid has
    ///    never been opened; no previous compressed frame exists to hold), there is no prior
    ///    output to repeat, so the batch contains only the real frame at `S`.
    /// 4. **Cap enforcement:** if the number of leading holds exceeds `cap`, emit exactly
    ///    `cap` holds (`cappedShort: true`), advance `lastEmittedSlot` by `cap`, and return
    ///    WITHOUT including the real frame. The frame's content is consciously deferred (or
    ///    lost on pathological lag) on this path — the caller must decide how to handle the
    ///    uncovered gap.
    /// 5. **Normal path:** holds + terminal `CFREmittedSlot(S, isHold: false)`;
    ///    `lastEmittedSlot` is updated to `S`.
    ///
    /// - Parameters:
    ///   - ptsSeconds: The frame's absolute PTS in seconds.
    ///   - anchorSeconds: Session T0 in seconds.
    ///   - fps: Target frame rate. Must be > 0.
    ///   - cap: Maximum number of leading holds allowed in this batch. Pass `Int.max` for
    ///     unlimited. Must be ≥ 0.
    /// - Returns: A `CFREmission` whose `slots` are strictly ascending.
    nonisolated mutating func catchUpThenEncode(
        ptsSeconds: Double,
        anchorSeconds: Double,
        fps: Int,
        cap: Int
    )
    -> CFREmission {
        precondition(fps > 0, "fps must be positive")
        precondition(cap >= 0, "cap must be non-negative")

        let slotS = Self.slotFor(ptsSeconds: ptsSeconds, anchorSeconds: anchorSeconds, fps: fps)

        // Defensive guard: pre-anchor or already-emitted — caller should have handled via processFrame.
        if slotS < 0 || slotS <= self.lastEmittedSlot {
            return CFREmission(slots: [], cappedShort: false)
        }

        // When the grid has never been opened (lastEmittedSlot == -1), there is no prior
        // compressed frame in the encoder's buffer to hold. Emitting holds here would instruct
        // the encoder to repeat a frame that does not exist yet. Skip directly to the real slot.
        let holdStart = self.lastEmittedSlot + 1
        let holdCount = self.lastEmittedSlot >= 0 ? slotS - holdStart : 0

        if holdCount > cap {
            // Cap exceeded: emit exactly `cap` holds and stop. The real frame is not included.
            // Its content is consciously deferred (or lost on pathological lag) on this path.
            var slots: [CFREmittedSlot] = []
            slots.reserveCapacity(cap)
            for idx in holdStart..<holdStart + cap {
                slots.append(CFREmittedSlot(slotIndex: idx, isHold: true))
            }
            self.lastEmittedSlot = holdStart + cap - 1
            return CFREmission(slots: slots, cappedShort: true)
        }

        // Normal path: holds (if any) followed by the real frame.
        // Emit holds only when the grid was already open (lastEmittedSlot >= 0); when the grid
        // has never been opened holdCount == 0 and we skip directly to the real frame.
        var slots: [CFREmittedSlot] = []
        slots.reserveCapacity(holdCount + 1)
        if holdCount > 0 {
            for idx in holdStart..<slotS {
                slots.append(CFREmittedSlot(slotIndex: idx, isHold: true))
            }
        }
        slots.append(CFREmittedSlot(slotIndex: slotS, isHold: false))
        self.lastEmittedSlot = slotS
        return CFREmission(slots: slots, cappedShort: false)
    }

    // MARK: - Catch-up holds (clock driver)

    /// Emits synthetic holds for all slots whose window has closed by `nowSeconds`.
    ///
    /// Called by the clock driver (U3 actor) on a timer tick. The eligibility formula
    /// is derived from the nearest-integer mapping: slot N's window under `round()` is
    /// `[(N−0.5)/fps, (N+0.5)/fps)`. A slot is hold-eligible only after its window has
    /// fully closed plus an additional `graceSeconds` allowance for late-arriving frames:
    ///
    /// ```
    /// eligibleThrough = floor((nowSeconds − anchorSeconds − graceSeconds) × fps − 0.5)
    /// ```
    ///
    /// ## Behaviour
    ///
    /// - `lastEmittedSlot == -1`: grid not yet open — return empty (nothing to hold).
    /// - `eligibleThrough <= lastEmittedSlot`: no new slots are hold-eligible — return empty.
    /// - Otherwise: emit holds for `[lastEmittedSlot+1 .. min(eligibleThrough, lastEmittedSlot+cap)]`.
    ///   If truncated by `cap`, `cappedShort` is `true`; `lastEmittedSlot` is advanced to the
    ///   last emitted hold.
    ///
    /// - Parameters:
    ///   - nowSeconds: Current wall-clock time in seconds (same domain as `anchorSeconds`).
    ///   - anchorSeconds: Session T0 in seconds.
    ///   - fps: Target frame rate. Must be > 0.
    ///   - graceSeconds: Extra delay beyond a slot's window close before it becomes hold-eligible.
    ///     Allows late real frames to arrive before a hold is synthesised. Must be ≥ 0.
    ///   - cap: Maximum number of holds to emit in a single call. Must be ≥ 1.
    /// - Returns: A `CFREmission` whose `slots` are all `isHold: true` and strictly ascending.
    nonisolated mutating func catchUpHolds(
        nowSeconds: Double,
        anchorSeconds: Double,
        fps: Int,
        graceSeconds: Double,
        cap: Int
    )
    -> CFREmission {
        precondition(fps > 0, "fps must be positive")
        precondition(graceSeconds >= 0, "graceSeconds must be non-negative")
        precondition(cap >= 1, "cap must be at least 1")

        // Grid not open yet — no prior compressed frame to hold.
        guard self.lastEmittedSlot >= 0 else {
            return CFREmission(slots: [], cappedShort: false)
        }

        // Slot N is hold-eligible once nowSeconds >= anchorSeconds + (N + 0.5)/fps + graceSeconds.
        // Solving for N: N <= (nowSeconds - anchorSeconds - graceSeconds) * fps - 0.5
        // Using floor() for the integer bound.
        // The 0.5 offset is the lower half-slot boundary from the round() mapping; it is not a
        // magic number but a structural constant of the nearest-integer grid.
        // swiftlint:disable:next no_magic_numbers
        let eligibleThrough = Int(floor((nowSeconds - anchorSeconds - graceSeconds) * Double(fps) - 0.5))

        guard eligibleThrough > self.lastEmittedSlot else {
            return CFREmission(slots: [], cappedShort: false)
        }

        let holdStart = self.lastEmittedSlot + 1
        let uncappedEnd = eligibleThrough // inclusive
        let cappedEnd = min(uncappedEnd, self.lastEmittedSlot + cap) // inclusive, capped
        let wasCapped = cappedEnd < uncappedEnd

        var slots: [CFREmittedSlot] = []
        let count = cappedEnd - holdStart + 1
        slots.reserveCapacity(count)
        for idx in holdStart...cappedEnd {
            slots.append(CFREmittedSlot(slotIndex: idx, isHold: true))
        }
        self.lastEmittedSlot = cappedEnd
        return CFREmission(slots: slots, cappedShort: wasCapped)
    }

    // MARK: - Next deadline (non-mutating)

    /// The earliest wall-clock time at which `catchUpHolds` would emit at least one hold.
    ///
    /// Derived from the eligibility formula in `catchUpHolds`: the clock must reach
    /// `anchorSeconds + (lastEmittedSlot + 1 + 0.5) / fps + graceSeconds` before slot
    /// `lastEmittedSlot + 1` becomes hold-eligible.
    ///
    /// Callers schedule their next timer fire at this value. When `lastEmittedSlot == -1`
    /// (grid not open), the returned deadline is for slot 0; the caller should wait until
    /// at least one real frame opens the grid before relying on hold emission.
    ///
    /// - Parameters:
    ///   - anchorSeconds: Session T0 in seconds.
    ///   - fps: Target frame rate. Must be > 0.
    ///   - graceSeconds: The same grace allowance passed to `catchUpHolds`. Must be ≥ 0.
    /// - Returns: The absolute time (in seconds, same domain as `anchorSeconds`) at which
    ///   the next hold becomes eligible.
    nonisolated func nextDeadlineSeconds(anchorSeconds: Double, fps: Int, graceSeconds: Double) -> Double {
        precondition(fps > 0, "fps must be positive")
        precondition(graceSeconds >= 0, "graceSeconds must be non-negative")
        // 1.5 = (next slot index offset 1) + (upper half-slot boundary 0.5) from the round() mapping.
        // This is not a magic number but a structural constant: the deadline is when the centre of
        // the next slot plus half a slot width (the slot's upper boundary) elapses.
        // swiftlint:disable:next no_magic_numbers
        return anchorSeconds + (Double(self.lastEmittedSlot) + 1.5) / Double(fps) + graceSeconds
    }
}
