@testable import Onset
import Testing

@Suite("resolveStartPlan — permission × device matrix (AC-11)")
struct RecordingStartPlanTests {
    /// Builds an `EffectivePermissions` from three granted flags.
    private func granted(screen: Bool, camera: Bool, mic: Bool) -> EffectivePermissions {
        EffectivePermissions(screenAvailable: screen, cameraAvailable: camera, microphoneAvailable: mic)
    }

    /// Resolves a plan from granted permissions + device-presence flags.
    private func resolve(
        _ permissions: EffectivePermissions,
        screenPresent: Bool,
        cameraPresent: Bool,
        micPresent: Bool
    )
    -> Result<RecordingStartPlan, RecordingError> {
        resolveStartPlan(
            permissions: permissions,
            screenDevicePresent: screenPresent,
            cameraDevicePresent: cameraPresent,
            micDevicePresent: micPresent
        )
    }

    /// Asserts a resolution matches an expected plan.
    private func expectPlan(
        _ result: Result<RecordingStartPlan, RecordingError>,
        screen: Bool,
        camera: Bool,
        audio: Bool,
        _ name: String
    ) {
        switch result {
        case let .success(got):
            #expect(got.includeScreen == screen, "\(name): includeScreen expected \(screen) got \(got.includeScreen)")
            #expect(got.includeCamera == camera, "\(name): includeCamera expected \(camera) got \(got.includeCamera)")
            #expect(got.includeAudio == audio, "\(name): includeAudio expected \(audio) got \(got.includeAudio)")

        case let .failure(error):
            Issue.record("\(name): expected plan, got failure \(String(describing: error))")
        }
    }

    @Test("full: all granted + present → screen+camera+audio")
    func full() {
        let permissions = self.granted(screen: true, camera: true, mic: true)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: true, micPresent: true)
        self.expectPlan(result, screen: true, camera: true, audio: true, "full")
    }

    @Test("screen-only: camera denied → screen, no camera, no audio")
    func screenOnly() {
        let permissions = self.granted(screen: true, camera: false, mic: true)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: true, micPresent: true)
        self.expectPlan(result, screen: true, camera: false, audio: false, "screen-only")
    }

    @Test("camera-only: screen denied → camera+audio, no screen")
    func cameraOnly() {
        let permissions = self.granted(screen: false, camera: true, mic: true)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: true, micPresent: true)
        self.expectPlan(result, screen: false, camera: true, audio: true, "camera-only")
    }

    @Test("no-audio: mic denied → screen+camera, no audio")
    func noAudio() {
        let permissions = self.granted(screen: true, camera: true, mic: false)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: true, micPresent: true)
        self.expectPlan(result, screen: true, camera: true, audio: false, "no-audio")
    }

    @Test("mic granted but absent → no audio (permission alone insufficient)")
    func micGrantedButAbsent() {
        let permissions = self.granted(screen: true, camera: true, mic: true)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: true, micPresent: false)
        self.expectPlan(result, screen: true, camera: true, audio: false, "mic-absent")
    }

    @Test("camera granted but absent → camera pipeline off (and audio off — mic rides camera)")
    func cameraGrantedButAbsent() {
        let permissions = self.granted(screen: true, camera: true, mic: true)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: false, micPresent: true)
        self.expectPlan(result, screen: true, camera: false, audio: false, "camera-absent")
    }

    @Test("screen granted but absent, camera ok → camera-only")
    func screenGrantedButAbsent() {
        let permissions = self.granted(screen: true, camera: true, mic: true)
        let result = self.resolve(permissions, screenPresent: false, cameraPresent: true, micPresent: true)
        self.expectPlan(result, screen: false, camera: true, audio: true, "screen-absent")
    }

    @Test("audio without camera: camera-off + mic ok → audio off (mic needs camera)")
    func audioWithoutCamera() {
        let permissions = self.granted(screen: true, camera: false, mic: true)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: true, micPresent: true)
        self.expectPlan(result, screen: true, camera: false, audio: false, "audio-without-camera")
    }

    @Test("no-video: neither granted → .noVideoSource (start blocked)")
    func noVideo_neitherGranted() {
        let permissions = self.granted(screen: false, camera: false, mic: true)
        let result = self.resolve(permissions, screenPresent: true, cameraPresent: true, micPresent: true)
        guard case .failure(.noVideoSource) = result else {
            Issue.record("expected .failure(.noVideoSource), got \(result)")
            return
        }
    }

    @Test("no-video: both granted but both absent → .noVideoSource (start blocked)")
    func noVideo_bothAbsent() {
        let permissions = self.granted(screen: true, camera: true, mic: true)
        let result = self.resolve(permissions, screenPresent: false, cameraPresent: false, micPresent: true)
        guard case .failure(.noVideoSource) = result else {
            Issue.record("expected .failure(.noVideoSource), got \(result)")
            return
        }
    }

    @Test("expectedPipelines counts running video pipelines")
    func expectedPipelines_count() {
        let both = RecordingStartPlan.both(includeAudio: true)
        let screenOnly = RecordingStartPlan.screenOnly
        let cameraOnly = RecordingStartPlan.cameraOnly(includeAudio: true)
        #expect(both.expectedPipelines == 2)
        #expect(screenOnly.expectedPipelines == 1)
        #expect(cameraOnly.expectedPipelines == 1)
    }
}
