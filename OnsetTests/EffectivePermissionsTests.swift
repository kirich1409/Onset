@testable import Onset
import Testing

// MARK: - EffectivePermissions tests

@Suite("EffectivePermissions")
struct EffectivePermissionsTests {
    // MARK: - canRecord

    @Test("No permissions — canRecord is false")
    func noPermissions_canRecordFalse() {
        let sut = EffectivePermissions.compute(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined
        )
        #expect(!sut.canRecord)
    }

    @Test("Screen only — canRecord is true")
    func screenOnly_canRecordTrue() {
        let sut = EffectivePermissions.compute(
            screen: .authorized,
            camera: .notDetermined,
            microphone: .notDetermined
        )
        #expect(sut.canRecord)
        #expect(sut.screenOnlyAvailable)
        #expect(!sut.cameraOnlyAvailable)
    }

    @Test("Camera only — canRecord is true")
    func cameraOnly_canRecordTrue() {
        let sut = EffectivePermissions.compute(
            screen: .denied,
            camera: .authorized,
            microphone: .notDetermined
        )
        #expect(sut.canRecord)
        #expect(sut.cameraOnlyAvailable)
        #expect(!sut.screenOnlyAvailable)
    }

    @Test("Screen denied, camera denied — canRecord is false (AC-11 blocked)")
    func bothVideoSourcesDenied_canRecordFalse() {
        let sut = EffectivePermissions.compute(
            screen: .denied,
            camera: .denied,
            microphone: .authorized
        )
        #expect(!sut.canRecord)
    }

    @Test("All authorized — fullModeAvailable")
    func allAuthorized_fullModeAvailable() {
        let sut = EffectivePermissions.compute(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized
        )
        #expect(sut.canRecord)
        #expect(sut.fullModeAvailable)
        #expect(!sut.videoWithoutAudioAvailable)
    }

    // MARK: - videoWithoutAudio (AC-7)

    @Test("Screen authorized, microphone denied — videoWithoutAudio (AC-7)")
    func screenOnlyNoMic_videoWithoutAudio() {
        let sut = EffectivePermissions.compute(
            screen: .authorized,
            camera: .denied,
            microphone: .denied
        )
        #expect(sut.canRecord)
        #expect(sut.videoWithoutAudioAvailable)
        #expect(!sut.microphoneAvailable)
    }

    @Test("Camera authorized, microphone not determined — videoWithoutAudio")
    func cameraNoMic_videoWithoutAudio() {
        let sut = EffectivePermissions.compute(
            screen: .notDetermined,
            camera: .authorized,
            microphone: .notDetermined
        )
        #expect(sut.canRecord)
        #expect(sut.videoWithoutAudioAvailable)
    }

    // MARK: - restricted status

    @Test("Screen restricted counts as not available")
    func screenRestricted_notAvailable() {
        let sut = EffectivePermissions.compute(
            screen: .restricted,
            camera: .authorized,
            microphone: .authorized
        )
        #expect(!sut.screenAvailable)
        #expect(sut.canRecord) // camera is available
        #expect(sut.cameraOnlyAvailable)
    }

    // MARK: - authorizedCount / progress (AC "N из 3")

    @Test("authorizedCount — 0 of 3")
    func progress_zero() {
        let sut = EffectivePermissions.compute(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined
        )
        #expect(sut.authorizedCount == 0)
    }

    @Test("authorizedCount — 1 of 3")
    func progress_one() {
        let sut = EffectivePermissions.compute(
            screen: .notDetermined,
            camera: .authorized,
            microphone: .denied
        )
        #expect(sut.authorizedCount == 1)
    }

    @Test("authorizedCount — 2 of 3")
    func progress_two() {
        let sut = EffectivePermissions.compute(
            screen: .authorized,
            camera: .authorized,
            microphone: .denied
        )
        #expect(sut.authorizedCount == 2)
    }

    @Test("authorizedCount — 3 of 3")
    func progress_three() {
        let sut = EffectivePermissions.compute(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized
        )
        #expect(sut.authorizedCount == 3)
    }
}

