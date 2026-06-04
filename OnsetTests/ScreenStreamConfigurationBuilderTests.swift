import CoreGraphics
import CoreMedia
import CoreVideo
@testable import Onset
import ScreenCaptureKit
import Testing

// MARK: - Helpers

private func makeTestPlan(
    screenWidth: Int = 1920,
    screenHeight: Int = 1080,
    screenFps: Int = 60
)
-> ResolvedRecordingPlan {
    ResolvedRecordingPlan(
        displayID: 1,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        screenFps: screenFps,
        cameraPlan: nil
    )
}

// MARK: - ScreenStreamConfigurationBuilder tests

@Suite("ScreenStreamConfigurationBuilder.makeConfiguration")
struct ScreenStreamConfigurationBuilderTests {
    private let config = RecordingConfiguration.mvpDefault

    // MARK: - Dimensions

    @Test("width and height are taken directly from the plan")
    func makeConfiguration_dimensions_matchPlan() {
        let plan = makeTestPlan(screenWidth: 2560, screenHeight: 1440)
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        #expect(streamConfig.width == 2560)
        #expect(streamConfig.height == 1440)
    }

    // MARK: - minimumFrameInterval

    @Test("minimumFrameInterval encodes 1/60 for screenFps = 60")
    func makeConfiguration_minimumFrameInterval_60fps() {
        let plan = makeTestPlan(screenFps: 60)
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        let expected = CMTime(value: 1, timescale: 60)
        #expect(streamConfig.minimumFrameInterval == expected)
    }

    @Test("minimumFrameInterval encodes 1/30 for screenFps = 30")
    func makeConfiguration_minimumFrameInterval_30fps() {
        let plan = makeTestPlan(screenFps: 30)
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        let expected = CMTime(value: 1, timescale: 30)
        #expect(streamConfig.minimumFrameInterval == expected)
    }

    // MARK: - pixelFormat

    @Test("pixelFormat is video-range biplanar (420v) when preference is [.biPlanar420v]")
    func makeConfiguration_pixelFormat_biPlanar420v() {
        let plan = makeTestPlan()
        // mvpDefault has [.biPlanar420v, .biPlanar420f] — first is 420v
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        #expect(streamConfig.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test("pixelFormat is full-range biplanar (420f) when preference leads with .biPlanar420f")
    func makeConfiguration_pixelFormat_biPlanar420f() {
        let plan = makeTestPlan()
        let customConfig = RecordingConfiguration(
            container: self.config.container,
            codec: self.config.codec,
            sampleEntry: self.config.sampleEntry,
            profileLevel: self.config.profileLevel,
            colorPrimaries: self.config.colorPrimaries,
            transferFunction: self.config.transferFunction,
            yCbCrMatrix: self.config.yCbCrMatrix,
            bitDepth: self.config.bitDepth,
            maxScreenFps: self.config.maxScreenFps,
            minCameraFps: self.config.minCameraFps,
            bitrateTable: self.config.bitrateTable,
            dataRateLimitsPeakMultiplier: self.config.dataRateLimitsPeakMultiplier,
            keyFrameIntervalSeconds: self.config.keyFrameIntervalSeconds,
            allowFrameReordering: self.config.allowFrameReordering,
            pixelFormatPreference: [.biPlanar420f, .biPlanar420v],
            movieFragmentInterval: self.config.movieFragmentInterval,
            budgetCap: self.config.budgetCap,
            outputDirectory: self.config.outputDirectory
        )
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: customConfig)

        #expect(streamConfig.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }

    @Test("pixelFormat falls back to video-range biplanar (420v) when preference list is empty")
    func makeConfiguration_pixelFormat_emptyPreference_fallsBackToBiPlanar420v() {
        let plan = makeTestPlan()
        let emptyConfig = RecordingConfiguration(
            container: self.config.container,
            codec: self.config.codec,
            sampleEntry: self.config.sampleEntry,
            profileLevel: self.config.profileLevel,
            colorPrimaries: self.config.colorPrimaries,
            transferFunction: self.config.transferFunction,
            yCbCrMatrix: self.config.yCbCrMatrix,
            bitDepth: self.config.bitDepth,
            maxScreenFps: self.config.maxScreenFps,
            minCameraFps: self.config.minCameraFps,
            bitrateTable: self.config.bitrateTable,
            dataRateLimitsPeakMultiplier: self.config.dataRateLimitsPeakMultiplier,
            keyFrameIntervalSeconds: self.config.keyFrameIntervalSeconds,
            allowFrameReordering: self.config.allowFrameReordering,
            pixelFormatPreference: [],
            movieFragmentInterval: self.config.movieFragmentInterval,
            budgetCap: self.config.budgetCap,
            outputDirectory: self.config.outputDirectory
        )
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: emptyConfig)

        #expect(streamConfig.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    // MARK: - queueDepth

    @Test("queueDepth is 8 — the header-documented default and maximum")
    func makeConfiguration_queueDepth_is8() {
        let plan = makeTestPlan()
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        #expect(streamConfig.queueDepth == 8)
    }

    // MARK: - Audio

    @Test("capturesAudio is false — mic is captured via AVCapture, not SCStream system audio")
    func makeConfiguration_capturesAudio_isFalse() {
        let plan = makeTestPlan()
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        #expect(streamConfig.capturesAudio == false)
    }

    // MARK: - Cursor

    @Test("showsCursor is true — explicit per spec")
    func makeConfiguration_showsCursor_isTrue() {
        let plan = makeTestPlan()
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        #expect(streamConfig.showsCursor == true)
    }

    // MARK: - Color

    @Test("colorSpaceName is Rec.709 — SDR as required by spec AC-4")
    func makeConfiguration_colorSpaceName_isRec709() {
        let plan = makeTestPlan()
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        // colorSpaceName is typed CFStringRef; compare via bridged String to avoid unretained-CFString issues.
        #expect(streamConfig.colorSpaceName as String? == CGColorSpace.itur_709 as String)
    }

    @Test("colorMatrix is ITU-R 709-2 — non-deprecated CoreVideo constant")
    func makeConfiguration_colorMatrix_isITU_R_709_2() {
        let plan = makeTestPlan()
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        #expect(streamConfig.colorMatrix as String? == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    // MARK: - Independent dimensions

    @Test("4K plan produces 3840x2160 configuration")
    func makeConfiguration_4K_dimensions() {
        let plan = makeTestPlan(screenWidth: 3840, screenHeight: 2160, screenFps: 60)
        let streamConfig = ScreenStreamConfigurationBuilder.makeConfiguration(plan: plan, config: self.config)

        #expect(streamConfig.width == 3840)
        #expect(streamConfig.height == 2160)
    }
}

