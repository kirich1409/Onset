import CoreGraphics

// MARK: - DisplaySelectionOutcome

/// The result of reconciling a previously-selected display ID against a fresh display list.
///
/// Produced by `DisplaySelectionReconciler.reconcile(selected:newDisplays:)` and consumed
/// by `MainViewModel` after a display-configuration change or cold-start load.
///
/// Display selection is ephemeral (not persisted), so there is no `.disconnected` notice
/// case — unlike camera/mic, losing the display triggers an immediate silent fallback.
nonisolated enum DisplaySelectionOutcome: Equatable {
    /// The previously-selected display is still present — keep `selectedDisplayID` unchanged.
    case keepExisting(CGDirectDisplayID)

    /// The previously-selected display disappeared — fall back to the first available display.
    case fallbackToFirst(CGDirectDisplayID)

    /// No display was previously selected AND exactly one is now available — auto-select it
    /// (mirrors the AC-1 cold-start rule).
    case autoSelectSingle(CGDirectDisplayID)

    /// No selection possible: either no displays found, or no prior selection with multiple
    /// available (user must choose explicitly, same as cold-start with 2+ displays).
    case noSelection
}

// MARK: - DisplaySelectionReconciler

/// Pure reconciler for display selection after a display-configuration change.
///
/// Contains no side effects, no hardware calls, and no `MainActor` dependencies —
/// the function operates solely on the values passed in, making it directly testable
/// without an actor context.
///
/// `nonisolated` avoids a MainActor hop under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
///
/// ### Design intent
/// Mirrors `DeviceSelectionResolver` but for the display-selection case, which has
/// different semantics: no persistence and an immediate fallback rather than a
/// disconnected notice.
nonisolated enum DisplaySelectionReconciler {
    /// Reconciles a display selection against a fresh display list after a configuration change.
    ///
    /// Four outcomes, in priority order:
    /// 1. **Prior selection still present** → `.keepExisting` (ID is stable).
    /// 2. **Prior selection gone** → `.fallbackToFirst` (first in the new list).
    /// 3. **No prior selection, exactly one display** → `.autoSelectSingle` (AC-1).
    /// 4. **No prior selection, zero or 2+ displays** → `.noSelection`.
    ///
    /// The reconciler keys on `CGDirectDisplayID` only — it does NOT retain old `Display`
    /// objects. This ensures the caller always derives resolution (pixel width/height) from
    /// the freshly-discovered `Display`, so a 4K→5K HiDPI-mode change is reflected
    /// automatically after reload.
    ///
    /// - Parameters:
    ///   - selected: The `CGDirectDisplayID` that was selected before the change, or `nil`.
    ///   - newDisplays: The freshly-discovered display list (may be empty).
    /// - Returns: A `DisplaySelectionOutcome` telling the caller how to update its state.
    static func reconcile(
        selected: CGDirectDisplayID?,
        newDisplays: [Display]
    )
    -> DisplaySelectionOutcome {
        let newIDs = newDisplays.map(\.displayID)

        if let currentID = selected {
            // Prior selection — check if it survived the configuration change.
            if newIDs.contains(currentID) {
                return .keepExisting(currentID)
            }
            // Selected display disappeared — fall back to first available.
            if let firstID = newIDs.first {
                return .fallbackToFirst(firstID)
            }
            // No displays left at all.
            return .noSelection
        }

        // No prior selection — apply AC-1: auto-select only when exactly one display.
        if newDisplays.count == 1, let onlyID = newIDs.first {
            return .autoSelectSingle(onlyID)
        }
        return .noSelection
    }
}
