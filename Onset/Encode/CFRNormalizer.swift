// CFRNormalizer.swift
// Onset
//
// U2 of VideoEncoder (#31) — pure CFR timestamp snapping state machine.
//
// Design: host-time domain choice
// ─────────────────────────────────────────────────────────────────────────────
// The project pipeline uses `CMTime` for all pts values (see `VideoFrame.ptsHostTime`,
// `HostTimeAnchor.anchorTime`). However, `CMTime` lives in CoreMedia, and this unit is
// required to be PURE — no `import VideoToolbox`, no `import CoreMedia`. Importing
// CoreMedia here would violate the seam design that keeps U2 testable without any Apple
// framework, and would match the explicit task contract.
//
// Resolution: the normalizer accepts `Double` seconds for all time values (both
// `ptsSeconds` and `anchorSeconds`). The caller (U3 actor) extracts seconds from CMTime
// via `CMTimeGetSeconds` at the boundary before handing values in, and reconstructs an
// exact `CMTime` from the returned `slotIndex` via `CMTime(value: slotIndex,
// timescale: Int32(fps))` — no lossy Double round-trip for the reconstructed pts.
//
// The slot index is the primary output (see CFRDecision.encode). This is an exact integer,
// so U3 can build a lossless rational CMTime for the snappedPTS. The Double seconds value
// in CFRDecision.encode is a convenience for callers that do not need CMTime exactness
// (e.g. tests). U3 must use the slotIndex directly for CMTime reconstruction.
//
// Isolation: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + NonisolatedNonsendingByDefault.
// All types are `nonisolated`; Equatable conformances are manual `nonisolated` witnesses
// declared on the primary type definition (not bare extensions) so the witness table
// inherits nonisolated isolation rather than @MainActor. Pattern mirrors VTEncoderSettings
// and RecordingConfiguration.

import Foundation

// MARK: - CFRDropReason

/// Drop reasons local to the CFR normalizer.
///
/// A CFR-normalizer-local type rather than extending the shared `DropReason`:
/// - The shared `DropReason` in `PipelineTypes.swift` maps 1-to-1 with the three
///   DropMonitor counters (#35/#36). `.preAnchor` is not a DropMonitor counter — pre-T0
///   frames are already gated at the source layer. Adding it there would widen the public
///   API invariant and require touching the `==` and `hash(into:)` witnesses in a Wave-0
///   foundation type.
/// - U2 is a leaf unit; its two-file commit scope does not include PipelineTypes.swift.
/// - A local enum is reversible; if #35/#36 later decide to track pre-T0 drops at the
///   monitor level, migration is a one-direction rename, not a rollback.
///
/// NOTE for the orchestrator: if the team wants a unified `DropReason` enum covering
/// `.preAnchor`, the correct change is to extend the shared type in PipelineTypes.swift
/// (Wave-0 file) in a separate task and re-export it here.
nonisolated enum CFRDropReason: Equatable {
    /// The frame's PTS is before the session anchor (T0). The normalizer has no valid
    /// slot for it. This should rarely occur in steady state — the source layer gates
    /// pre-T0 frames via `shouldKeepCameraFrame` / `shouldKeepScreenFrame`. The guard
    /// here is a defence-in-depth check.
    case preAnchor

    /// A second (or later) frame mapped to a slot that has already been emitted.
    ///
    /// This is the canonical duplicate-frame drop. The normalizer already emitted
    /// `encode` for this slot; any additional frame landing in the same slot is
    /// excess. The U3 actor increments `cfrNormalizationDrops` (mapped to the
    /// shared `DropReason.cfrNormalizationDrops`) when it observes this decision.
    case cfrNormalizationDrops
}

extension CFRDropReason {
    /// Manual `nonisolated` equality witness.
    ///
    /// Required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    /// `InferIsolatedConformances`. The conformance is on the primary `nonisolated`
    /// definition above; this extension provides the synthesised-replacement witness.
    nonisolated static func == (lhs: CFRDropReason, rhs: CFRDropReason) -> Bool {
        switch (lhs, rhs) {
        case (.preAnchor, .preAnchor),
             (.cfrNormalizationDrops, .cfrNormalizationDrops):
            true

        default:
            false
        }
    }
}

// MARK: - CFRDecision

/// The normalizer's decision for a single incoming event.
///
/// The `snappedPTS` in the `.encode` case is expressed in seconds (Double) so the type
/// remains CoreMedia-free. U3 MUST reconstruct the exact `CMTime` from the integer
/// `slotIndex` to avoid floating-point loss:
///
/// ```swift
/// // U3 (actor) — exact reconstruction, no Double round-trip:
/// let cmPTS = CMTime(value: CMTimeValue(slotIndex), timescale: CMTimeScale(fps))
/// ```
nonisolated enum CFRDecision: Equatable {
    /// The normalizer approves this slot for encoding.
    ///
    /// - Parameters:
    ///   - slotIndex: The integer CFR grid index. U3 uses this to reconstruct an exact
    ///     `CMTime`: `CMTime(value: CMTimeValue(slotIndex), timescale: CMTimeScale(fps))`.
    ///   - snappedPTS: The snapped presentation time in seconds from T0. Convenience value
    ///     for callers that do not need CMTime exactness (e.g. pure unit tests).
    ///   - isHold: `true` when this slot boundary elapsed with no new frame — the encoder
    ///     should re-use the previous compressed output. `false` for a genuine new frame.
    case encode(slotIndex: Int, snappedPTS: Double, isHold: Bool)

    /// The normalizer rejects this frame.
    case drop(reason: CFRDropReason)
}

extension CFRDecision {
    /// Manual `nonisolated` equality witness.
    ///
    /// Required under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` +
    /// `InferIsolatedConformances`. Associated-value enum equality would otherwise be
    /// synthesised as `@MainActor`, unusable from `nonisolated` contexts.
    nonisolated static func == (lhs: CFRDecision, rhs: CFRDecision) -> Bool {
        switch (lhs, rhs) {
        case let (.encode(leftSlot, leftPTS, leftHold), .encode(rightSlot, rightPTS, rightHold)):
            leftSlot == rightSlot && leftPTS == rightPTS && leftHold == rightHold

        case let (.drop(leftReason), .drop(rightReason)):
            leftReason == rightReason

        default:
            false
        }
    }
}

// MARK: - CFRNormalizer

/// A pure CFR (constant-frame-rate) timestamp snapping state machine.
///
/// Normalises incoming video frame timestamps onto a fixed clock grid of `1/fps` seconds,
/// anchored to a session T0. The normalizer is deliberately a value type (`struct`) with no
/// actor isolation, no CoreMedia/VideoToolbox imports, and no mach syscalls — it is safe to
/// use from any isolation domain, including synchronous nonisolated code and unit tests.
///
/// ## Slot arithmetic
///
/// All time values are expressed in seconds (Double) so the type stays CoreMedia-free.
/// The caller (U3 actor) converts `CMTime → Double` at the boundary before calling in.
///
/// ```
/// offset     = ptsSeconds − anchorSeconds
/// slotIndex  = Int(round(offset × fps))     // nearest integer slot
/// snappedPTS = Double(slotIndex) / Double(fps)  // relative to anchor (in seconds from T0)
/// ```
///
/// The absolute snappedPTS in host-time seconds is `anchorSeconds + snappedPTS`.
/// `FileWriter` rebases this via `PipelineClock.convert(hostTime:anchoredTo:)`.
///
/// ## Hold vs drop
///
/// | Event | Condition | Decision |
/// |---|---|---|
/// | Frame | `slotIndex < 0` | `drop(.preAnchor)` |
/// | Frame | `slotIndex <= lastEmittedSlot` | `drop(.cfrNormalizationDrops)` |
/// | Frame | `slotIndex > lastEmittedSlot` | `encode(..., isHold: false)` |
/// | Tick  | slot boundary, no frame | `encode(..., isHold: true)` |
///
/// A hold does NOT increment `cfrNormalizationDrops`. Slot monotonicity is enforced:
/// no `encode` is ever emitted for a slot ≤ the previously emitted slot.
///
/// ## Counters
///
/// `cfrNormalizationDrops` counts frames dropped by the normalizer for the duplicate-slot
/// reason. It is intentionally separate from any backpressure counter; U3 reads this to
/// populate the shared `DropMonitor` counter for `DropReason.cfrNormalizationDrops`.
nonisolated struct CFRNormalizer {
    // MARK: - State

    /// The last slot index that was emitted via `encode`. Initialised to `-1` so the
    /// first slot (index 0) is always considered a new slot.
    nonisolated private(set) var lastEmittedSlot: Int = -1

    /// Running count of frames dropped because their computed slot was already emitted.
    ///
    /// Incremented by `processFrame` for duplicate-slot frames. NOT incremented for holds
    /// or pre-T0 drops. U3 reads this to populate `DropMonitor`'s counter for
    /// `DropReason.cfrNormalizationDrops`. Must remain observably separate from any
    /// encoder-backpressure counter.
    nonisolated private(set) var cfrNormalizationDrops = 0

    // MARK: - Frame processing

    /// Processes an incoming video frame and returns the normalizer's decision.
    ///
    /// - Parameters:
    ///   - ptsSeconds: The frame's absolute host-clock PTS in seconds. The caller
    ///     extracts this from `VideoFrame.ptsHostTime` via `CMTimeGetSeconds`.
    ///   - anchorSeconds: The session T0 in seconds. The caller extracts this from
    ///     `HostTimeAnchor.anchorTime` via `CMTimeGetSeconds`. Must be the same value
    ///     across all calls for a given recording session.
    ///   - fps: The target frame rate (frames per second). Must be > 0.
    /// - Returns: A `CFRDecision` indicating whether to encode or drop this frame.
    ///
    /// - Important: `self` is mutated on `.encode` and on `.drop(.cfrNormalizationDrops)`.
    ///   The caller must hold a `var` reference and replace the struct after each call.
    nonisolated mutating func processFrame(
        ptsSeconds: Double,
        anchorSeconds: Double,
        fps: Int
    )
    -> CFRDecision {
        precondition(fps > 0, "fps must be positive")

        let offset = ptsSeconds - anchorSeconds
        let slotIndex = Int((offset * Double(fps)).rounded())

        if slotIndex < 0 {
            return .drop(reason: .preAnchor)
        }

        if slotIndex <= self.lastEmittedSlot {
            self.cfrNormalizationDrops += 1
            return .drop(reason: .cfrNormalizationDrops)
        }

        self.lastEmittedSlot = slotIndex
        let snappedPTS = Double(slotIndex) / Double(fps)
        return .encode(slotIndex: slotIndex, snappedPTS: snappedPTS, isHold: false)
    }

    // MARK: - Tick processing (hold)

    /// Processes a clock tick for a given slot index when no frame arrived for that slot.
    ///
    /// The tick event originates from the CFR clock driver in U3 (the encoder actor) when
    /// a slot boundary elapses with no frame in the queue. The normalizer emits a hold
    /// decision so the encoder can re-use the previous compressed output.
    ///
    /// A hold does NOT increment `cfrNormalizationDrops` — it is not a drop, it is a
    /// deliberate repetition to maintain the constant frame-rate contract.
    ///
    /// - Parameters:
    ///   - slotIndex: The slot index for which no frame was received. Must be > `lastEmittedSlot`.
    ///   - fps: The target frame rate (frames per second). Must be > 0.
    /// - Returns: An `encode(..., isHold: true)` decision, or `drop(.cfrNormalizationDrops)`
    ///   if the slot is already behind the current position (defensive guard).
    nonisolated mutating func processTick(
        slotIndex: Int,
        fps: Int
    )
    -> CFRDecision {
        precondition(fps > 0, "fps must be positive")

        if slotIndex <= self.lastEmittedSlot {
            // Defensive: tick for a past slot — treated as duplicate, not a hold.
            // This path should not occur under correct U3 driving.
            self.cfrNormalizationDrops += 1
            return .drop(reason: .cfrNormalizationDrops)
        }

        self.lastEmittedSlot = slotIndex
        let snappedPTS = Double(slotIndex) / Double(fps)
        return .encode(slotIndex: slotIndex, snappedPTS: snappedPTS, isHold: true)
    }
}
