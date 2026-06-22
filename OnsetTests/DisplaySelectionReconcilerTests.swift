import CoreGraphics
import Foundation
@testable import Onset
import Testing

// MARK: - DisplaySelectionReconcilerTests

/// L2 unit tests for `DisplaySelectionReconciler` — pure, no hardware, no MainActor required.
///
/// Covers all four `DisplaySelectionOutcome` branches and the critical invariant that
/// the reconciler keys on `CGDirectDisplayID` only, so a resolution change on a display
/// that is still present results in `.keepExisting` — allowing the caller to pick up
/// fresh pixel dimensions from the new `Display` object in `self.displays`.
@Suite("DisplaySelectionReconciler — pure reconciler outcomes")
struct DisplaySelectionReconcilerTests {
    // MARK: - Helpers

    private func makeDisplay(id: CGDirectDisplayID, width: Int = 1920, height: Int = 1080) -> Display {
        Display(displayID: id, name: "Test Display", pixelWidth: width, pixelHeight: height, refreshHz: 60)
    }

    // MARK: - keepExisting

    /// When the selected display ID is in the new list, the outcome is `.keepExisting`.
    @Test("selected display still present → keepExisting")
    func selectedDisplayPresent_returnsKeepExisting() {
        let displays = [makeDisplay(id: 1), makeDisplay(id: 2)]
        let outcome = DisplaySelectionReconciler.reconcile(selected: 1, newDisplays: displays)
        #expect(outcome == .keepExisting(1))
    }

    /// `.keepExisting` is returned even when the resolution of the selected display changed.
    ///
    /// The key invariant: caller must re-read `selectedDisplay` from `self.displays` after
    /// `applyDisplays(_:)` to get the fresh `Display` object with the updated pixel dims.
    @Test("selected display present with changed resolution → keepExisting (ID stable)")
    func selectedDisplayResolutionChanged_returnsKeepExisting() {
        let updatedDisplay = self.makeDisplay(id: 1, width: 5120, height: 2880)
        let outcome = DisplaySelectionReconciler.reconcile(
            selected: 1,
            newDisplays: [updatedDisplay]
        )
        #expect(outcome == .keepExisting(1))
    }

    // MARK: - fallbackToFirst

    /// When the selected display is gone, the outcome is `.fallbackToFirst` with the first
    /// remaining display's ID.
    @Test("selected display gone, others remain → fallbackToFirst")
    func selectedDisplayGone_returnsFirstFallback() {
        let displays = [makeDisplay(id: 2), makeDisplay(id: 3)]
        let outcome = DisplaySelectionReconciler.reconcile(selected: 1, newDisplays: displays)
        #expect(outcome == .fallbackToFirst(2))
    }

    // MARK: - autoSelectSingle

    /// When there was no prior selection and exactly one display is available, the reconciler
    /// auto-selects it (mirrors the AC-1 cold-start rule).
    @Test("no prior selection, exactly one display → autoSelectSingle")
    func noPriorSelection_singleDisplay_autoSelects() {
        let displays = [makeDisplay(id: 5)]
        let outcome = DisplaySelectionReconciler.reconcile(selected: nil, newDisplays: displays)
        #expect(outcome == .autoSelectSingle(5))
    }

    // MARK: - noSelection

    /// When the selected display is gone and no displays remain, the outcome is `.noSelection`.
    @Test("selected display gone, no displays left → noSelection")
    func selectedDisplayGone_noDisplaysLeft_returnsNoSelection() {
        let outcome = DisplaySelectionReconciler.reconcile(selected: 1, newDisplays: [])
        #expect(outcome == .noSelection)
    }

    /// When there was no prior selection and zero displays are available, the outcome is
    /// `.noSelection`.
    @Test("no prior selection, no displays → noSelection")
    func noPriorSelection_noDisplays_returnsNoSelection() {
        let outcome = DisplaySelectionReconciler.reconcile(selected: nil, newDisplays: [])
        #expect(outcome == .noSelection)
    }

    /// When there was no prior selection and two or more displays are available, the
    /// reconciler does NOT auto-select (user must choose explicitly, same as cold start with
    /// 2+ displays).
    @Test("no prior selection, multiple displays → noSelection")
    func noPriorSelection_multipleDisplays_returnsNoSelection() {
        let displays = [makeDisplay(id: 1), makeDisplay(id: 2)]
        let outcome = DisplaySelectionReconciler.reconcile(selected: nil, newDisplays: displays)
        #expect(outcome == .noSelection)
    }
}

// MARK: - DisplaySelectionReconcilerTests — applyDisplays integration

/// L2 tests for `MainViewModel.applyDisplays(_:)` exercising the reconciler via the view model.
///
/// Uses injected `discoverDisplays` seam so no hardware is involved.
/// `@MainActor` is required because `MainViewModel` is `@Observable @MainActor`.
@Suite("MainViewModel.applyDisplays — reconciler wired into view model")
@MainActor
struct MainViewModelApplyDisplaysTests {
    private func makeDisplay(id: CGDirectDisplayID, width: Int = 1920, height: Int = 1080) -> Display {
        Display(displayID: id, name: "Test Display", pixelWidth: width, pixelHeight: height, refreshHz: 60)
    }

    private func makeViewModel() -> MainViewModel {
        // Both persistence stores are backed by a per-SUT InMemoryUserDefaults so tests never
        // touch the real ~/Library/Preferences/ domain (the .standard guard would otherwise trap).
        let defaults = InMemoryUserDefaults()
        return MainViewModel(
            permissions: FakePermissionsService(),
            coordinator: RecordingCoordinator {
                UserDefaultsBackendSelectionStore(defaults: defaults)
            },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: defaults) }
        )
    }

    /// When the selected display is still in the new list, `selectedDisplayID` is unchanged.
    @Test("applyDisplays: selected display still present → ID kept")
    func applyDisplays_selectedPresent_idKept() {
        let sut = self.makeViewModel()
        sut.selectedDisplayID = 1
        sut.applyDisplays([self.makeDisplay(id: 1), self.makeDisplay(id: 2)])
        #expect(sut.selectedDisplayID == 1)
    }

    /// When the selected display disappears, `selectedDisplayID` falls back to the first
    /// remaining display.
    @Test("applyDisplays: selected display gone → fallback to first")
    func applyDisplays_selectedGone_fallsBackToFirst() {
        let sut = self.makeViewModel()
        sut.selectedDisplayID = 99
        sut.applyDisplays([self.makeDisplay(id: 1), self.makeDisplay(id: 2)])
        #expect(sut.selectedDisplayID == 1)
    }

    /// When a display is still present but its resolution changed, `displays` is updated
    /// so `selectedDisplay` reflects the new pixel dimensions.
    @Test("applyDisplays: resolution change on kept display → selectedDisplay reflects new dims")
    func applyDisplays_resolutionChanged_selectedDisplayUpdated() {
        let sut = self.makeViewModel()
        sut.selectedDisplayID = 1
        sut.applyDisplays([self.makeDisplay(id: 1, width: 5120, height: 2880)])
        #expect(sut.selectedDisplay?.pixelWidth == 5120)
    }

    /// When a new display is plugged in and no display was previously selected, and there
    /// is now exactly one display, `selectedDisplayID` is auto-set (AC-1).
    @Test("applyDisplays: no prior selection, new single display → auto-selected")
    func applyDisplays_noPriorSelection_singleNew_autoSelected() {
        let sut = self.makeViewModel()
        sut.selectedDisplayID = nil
        sut.applyDisplays([self.makeDisplay(id: 7)])
        #expect(sut.selectedDisplayID == 7)
    }

    /// When a new display is plugged in alongside an existing one (2 total) and no display
    /// was previously selected, `selectedDisplayID` remains nil — user must choose.
    @Test("applyDisplays: no prior selection, two displays → no auto-selection")
    func applyDisplays_noPriorSelection_multipleDisplays_noAutoSelection() {
        let sut = self.makeViewModel()
        sut.selectedDisplayID = nil
        sut.applyDisplays([self.makeDisplay(id: 1), self.makeDisplay(id: 2)])
        #expect(sut.selectedDisplayID == nil)
    }
}

// MARK: - MainViewModel subscribe-path integration

/// L2 test for `MainViewModel.subscribeToDisplayChanges()` — verifies that a single
/// event from the `screenChangeEvents` seam triggers `loadDisplays()` and applies the result.
///
/// Uses the yield-then-finish pattern: `continuation.yield()` then `continuation.finish()`
/// makes the `for await` loop process exactly one event and return deterministically — no
/// polling, no race.
///
/// `@MainActor` is required because `MainViewModel` is `@Observable @MainActor`.
@Suite("MainViewModel.subscribeToDisplayChanges — stream wiring")
@MainActor
struct MainViewModelSubscribeTests {
    /// When `screenChangeEvents` fires once, `loadDisplays()` runs and `applyDisplays(_:)`
    /// reconciles the result — verifying the subscribe→reload→reconcile chain end-to-end.
    @Test("subscribeToDisplayChanges: one event → loadDisplays fires, displays and selection updated")
    func subscribeToDisplayChanges_singleEvent_displaysAndSelectionUpdated() async {
        let newDisplay = Display(
            displayID: 42,
            name: "Test Display",
            pixelWidth: 1920,
            pixelHeight: 1080,
            refreshHz: 60
        )
        let (stream, continuation) = AsyncStream<Void>.makeStream()

        // Both persistence stores are backed by a per-SUT InMemoryUserDefaults so the
        // .standard guard does not trap (the suite never exercises persistence directly).
        let defaults = InMemoryUserDefaults()
        let sut = MainViewModel(
            permissions: FakePermissionsService(),
            coordinator: RecordingCoordinator {
                UserDefaultsBackendSelectionStore(defaults: defaults)
            },
            discoverDisplays: { _ in [newDisplay] },
            makeStore: { UserDefaultsDeviceSelectionStore(defaults: defaults) },
            makeOutputFolderStore: { UserDefaultsOutputFolderStore(defaults: defaults) },
            screenChangeEvents: { stream }
        )
        // Pre-condition: no prior selection; stream event will trigger AC-1 auto-select.
        sut.selectedDisplayID = nil

        // Enqueue exactly one event then terminate the stream. The for-await loop in
        // subscribeToDisplayChanges() processes the yield (→ loadDisplays → applyDisplays),
        // then encounters finish and returns — no polling required.
        continuation.yield()
        continuation.finish()

        await sut.subscribeToDisplayChanges()

        #expect(sut.displays.count == 1)
        #expect(sut.selectedDisplayID == 42)
    }
}
