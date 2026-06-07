@testable import Onset
import Testing

// MARK: - OnboardingFooterMapperTests

/// Tests the full permission-state matrix for ``OnboardingFooterMapper``.
///
/// Each test asserts the structural invariants of the returned descriptor:
/// - At most one graceful link.
/// - Exactly one primary button.
/// - No two enabled buttons share the same action (duplicate-action bug is impossible).
///
/// `nonisolated` — the mapper is a pure function; no actor context needed.
@Suite("OnboardingFooterMapper")
struct OnboardingFooterMapperTests {
    // MARK: - Helpers

    private func make(
        isAwaiting: Bool = false,
        screen: Bool,
        camera: Bool,
        mic: Bool
    ) -> OnboardingFooterDescriptor {
        let canRecord = screen || camera
        let cameraOnly = !screen && camera
        let noAudio = canRecord && !mic
        let fullMode = screen && camera && mic
        return OnboardingFooterMapper.descriptor(
            isAwaiting: isAwaiting,
            canRecord: canRecord,
            cameraOnly: cameraOnly,
            noAudio: noAudio,
            fullMode: fullMode
        )
    }

    // MARK: - Awaiting state

    @Test("Awaiting + camera granted → graceful link + Проверить снова primary (AC-7)")
    func awaiting_cameraGranted_continueWithoutScreen() {
        let desc = make(isAwaiting: true, screen: false, camera: true, mic: false)

        #expect(desc.gracefulLink?.label == "Продолжить без экрана")
        #expect(desc.gracefulLink?.action == .proceed)
        #expect(desc.primary.label == "Проверить снова")
        #expect(desc.primary.action == .recheck)
        #expect(desc.primary.isEnabled)
    }

    @Test("Awaiting + camera granted + mic granted → graceful link + Проверить снова (AC-7)")
    func awaiting_cameraAndMicGranted_continueWithoutScreen() {
        let desc = make(isAwaiting: true, screen: false, camera: true, mic: true)

        #expect(desc.gracefulLink?.label == "Продолжить без экрана")
        #expect(desc.primary.label == "Проверить снова")
        #expect(desc.primary.action == .recheck)
    }

    @Test("Awaiting + no camera → no graceful link, Проверить снова only")
    func awaiting_noCamera_noGracefulLink() {
        let desc = make(isAwaiting: true, screen: false, camera: false, mic: false)

        #expect(desc.gracefulLink == nil)
        #expect(desc.primary.label == "Проверить снова")
        #expect(desc.primary.action == .recheck)
        #expect(desc.primary.isEnabled)
    }

    @Test("Awaiting + no camera + mic granted → no graceful link, Проверить снова only")
    func awaiting_noCamera_micGranted_noGracefulLink() {
        let desc = make(isAwaiting: true, screen: false, camera: false, mic: true)

        #expect(desc.gracefulLink == nil)
        #expect(desc.primary.label == "Проверить снова")
    }

    // MARK: - Normal: full mode (S+C+M)

    @Test("Full mode → no graceful link, Перейти к записи enabled (AC-8)")
    func fullMode_goToRecording() {
        let desc = make(screen: true, camera: true, mic: true)

        #expect(desc.gracefulLink == nil)
        #expect(desc.primary.label == "Перейти к записи")
        #expect(desc.primary.action == .proceed)
        #expect(desc.primary.isEnabled)
    }

    // MARK: - Normal: no video source

    @Test("No video source (S=0, C=0, M=0) → Позже link + disabled Продолжить (AC-7)")
    func noVideoSource_nothingGranted() {
        let desc = make(screen: false, camera: false, mic: false)

        #expect(desc.gracefulLink?.label == "Позже")
        #expect(desc.gracefulLink?.action == .proceed)
        #expect(desc.primary.label == "Продолжить")
        #expect(desc.primary.action == .proceed)
        #expect(!desc.primary.isEnabled)
    }

    @Test("No video source (S=0, C=0, M=1) → Позже link + disabled Продолжить")
    func noVideoSource_onlyMicGranted() {
        let desc = make(screen: false, camera: false, mic: true)

        #expect(desc.gracefulLink?.label == "Позже")
        #expect(!desc.primary.isEnabled)
        #expect(desc.primary.label == "Продолжить")
    }

    // MARK: - Normal: camera-only path

    @Test("Camera only, no mic (S=0, C=1, M=0) → no link, Продолжить без экрана enabled (AC-7)")
    func cameraOnly_noMic_continueWithoutScreen() {
        // The overlap cell: both cameraOnly and noAudio are true.
        // cameraOnly is checked first → label reflects the camera-only recording mode.
        let desc = make(screen: false, camera: true, mic: false)

        #expect(desc.gracefulLink == nil)
        #expect(desc.primary.label == "Продолжить без экрана")
        #expect(desc.primary.action == .proceed)
        #expect(desc.primary.isEnabled)
    }

    @Test("Camera only + mic granted (S=0, C=1, M=1) → no link, Продолжить без экрана enabled (AC-7)")
    func cameraOnly_micGranted_continueWithoutScreen() {
        let desc = make(screen: false, camera: true, mic: true)

        #expect(desc.gracefulLink == nil)
        #expect(desc.primary.label == "Продолжить без экрана")
        #expect(desc.primary.isEnabled)
    }

    // MARK: - Normal: no-audio path (screen available, mic missing)

    @Test("Screen only, no mic (S=1, C=0, M=0) → Записать без звука link + disabled Продолжить (AC-7)")
    func screenOnly_noMic_recordWithoutAudio() {
        let desc = make(screen: true, camera: false, mic: false)

        #expect(desc.gracefulLink?.label == "Записать без звука")
        #expect(desc.gracefulLink?.action == .proceed)
        #expect(desc.primary.label == "Продолжить")
        #expect(!desc.primary.isEnabled)
    }

    @Test("Screen + camera, no mic (S=1, C=1, M=0) → Записать без звука link + disabled Продолжить (AC-7)")
    func screenAndCamera_noMic_recordWithoutAudio() {
        let desc = make(screen: true, camera: true, mic: false)

        #expect(desc.gracefulLink?.label == "Записать без звука")
        #expect(desc.primary.label == "Продолжить")
        #expect(!desc.primary.isEnabled)
    }

    // MARK: - Normal: partial-video + mic present (not full)

    @Test("Screen only + mic granted (S=1, C=0, M=1) → no link, Продолжить enabled")
    func screenAndMic_noCamera_proceed() {
        let desc = make(screen: true, camera: false, mic: true)

        #expect(desc.gracefulLink == nil)
        #expect(desc.primary.label == "Продолжить")
        #expect(desc.primary.action == .proceed)
        #expect(desc.primary.isEnabled)
    }

    // MARK: - Invariants: no two enabled proceed buttons

    @Test(
        "Invariant: at most one enabled proceed button across all non-awaiting states",
        arguments: [
            (false, false, false),
            (false, false, true),
            (false, true, false),
            (false, true, true),
            (true, false, false),
            (true, false, true),
            (true, true, false),
            (true, true, true),
        ]
    )
    func noTwoEnabledProceedButtons(screen: Bool, camera: Bool, mic: Bool) {
        let desc = make(isAwaiting: false, screen: screen, camera: camera, mic: mic)
        let enabledProceedCount = [
            desc.gracefulLink.map { $0.action == .proceed && true } ?? false,
            desc.primary.action == .proceed && desc.primary.isEnabled,
        ].filter { $0 }.count
        #expect(enabledProceedCount <= 1)
    }

    @Test(
        "Invariant: at most one enabled proceed button in awaiting state",
        arguments: [
            (false, false),
            (false, true),
            (true, false),
            (true, true),
        ]
    )
    func noTwoEnabledProceedButtons_awaiting(camera: Bool, mic: Bool) {
        let desc = make(isAwaiting: true, screen: false, camera: camera, mic: mic)
        let enabledProceedCount = [
            desc.gracefulLink.map { $0.action == .proceed && true } ?? false,
            desc.primary.action == .proceed && desc.primary.isEnabled,
        ].filter { $0 }.count
        #expect(enabledProceedCount <= 1)
    }

    @Test(
        "Invariant: graceful link action never duplicates primary action when both are enabled",
        arguments: [
            (false, false, false),
            (false, false, true),
            (false, true, false),
            (false, true, true),
            (true, false, false),
            (true, false, true),
            (true, true, false),
            (true, true, true),
        ]
    )
    func noDuplicateEnabledActions(screen: Bool, camera: Bool, mic: Bool) {
        let desc = make(isAwaiting: false, screen: screen, camera: camera, mic: mic)
        guard let link = desc.gracefulLink, desc.primary.isEnabled else { return }
        // If both are enabled, their actions must differ
        #expect(link.action != desc.primary.action)
    }
}
