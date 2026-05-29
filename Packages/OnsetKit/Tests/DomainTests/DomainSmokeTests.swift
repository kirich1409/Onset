import CoreMedia
import Foundation
import Testing
@testable import Domain

// MARK: - In-test fakes
//
// These fakes exist solely to demonstrate that the Domain protocols (#17) are
// sufficient to build test doubles without any Infrastructure dependency.

private final class FakeClock: ClockProviding {
    let referenceClock: CMClock = CMClockGetHostTimeClock()
    func now() -> CMTime { .zero }
    func convert(_ t: CMTime, from src: CMClock) -> CMTime { t }
}

private final class FakeCaptureSource: CaptureSource {
    let kind: SourceKind
    let sourceClock: CMClock = CMClockGetHostTimeClock()
    private(set) var configured = false
    private(set) var started = false

    init(kind: SourceKind) { self.kind = kind }

    func configure(_ c: SourceConfiguration) throws { configured = true }
    func start(emittingTo sink: any SampleSink) throws { started = true }
    func stop() { started = false }
}

private final class FakeSampleSink: SampleSink {
    private(set) var receivedKinds: [SourceKind] = []
    func receive(_ buf: CMSampleBuffer, kind: SourceKind) {
        receivedKinds.append(kind)
    }
}

private final class FakeEncodingWriter: EncodingWriter {
    private(set) var prepared = false
    private(set) var sessionBegan = false
    var health: WriterHealth = .alive
    var isAlive: Bool = true

    func prepare(_ d: OutputDescriptor) throws { prepared = true }
    func beginSession(atSourceTime t: CMTime) { sessionBegan = true }
    func append(_ buf: CMSampleBuffer, track: TrackKind) {}
    func finalize() async throws {}
}

// MARK: - Enum smoke tests

@Suite("Domain enums")
struct DomainEnumTests {
    @Test("SourceKind covers all cases")
    func sourceKindCases() {
        let all: [SourceKind] = [.screen, .camera, .audio]
        #expect(all.count == 3)
        #expect(SourceKind.screen != .audio)
    }

    @Test("TrackKind covers all cases")
    func trackKindCases() {
        let all: [TrackKind] = [.video, .audio]
        #expect(all.count == 2)
        #expect(TrackKind.video != .audio)
    }

    @Test("CodecKind covers all cases")
    func codecKindCases() {
        #expect(CodecKind.hevc != .h264)
    }

    @Test("ContainerKind covers all cases")
    func containerKindCases() {
        #expect(ContainerKind.mov != .mp4)
    }

    @Test("WriterHealth covers all cases")
    func writerHealthCases() {
        let all: [WriterHealth] = [.alive, .failed, .partial]
        #expect(all.count == 3)
        #expect(WriterHealth.alive != .failed)
    }

    @Test("ValidationIssue conforms to Error")
    func validationIssueIsError() {
        let issue: any Error = ValidationIssue.noVideoSource
        #expect(issue is ValidationIssue)
    }
}

// MARK: - Value type construction smoke tests

@Suite("Domain value types")
struct DomainValueTypeTests {
    @Test("SourceConfiguration round-trips its properties")
    func sourceConfigurationConstruction() {
        let config = SourceConfiguration(kind: .screen, width: 3456, height: 2160, fps: 60)
        #expect(config.kind == .screen)
        #expect(config.width == 3456)
        #expect(config.height == 2160)
        #expect(config.fps == 60)
    }

    @Test("OutputDescriptor round-trips its properties")
    func outputDescriptorConstruction() {
        let url = URL(fileURLWithPath: "/tmp/test.mov")
        let descriptor = OutputDescriptor(
            destination: url,
            codec: .hevc,
            container: .mov,
            tracks: [.video, .audio]
        )
        #expect(descriptor.destination == url)
        #expect(descriptor.codec == .hevc)
        #expect(descriptor.container == .mov)
        #expect(descriptor.tracks == [.video, .audio])
    }

    @Test("RecordingConfiguration is constructible from within the module")
    func recordingConfigurationConstruction() {
        let config = SourceConfiguration(kind: .screen, width: 1920, height: 1080, fps: 30)
        let output = OutputDescriptor(
            destination: URL(fileURLWithPath: "/tmp/out.mov"),
            codec: .hevc,
            container: .mov,
            tracks: [.video, .audio]
        )
        let recording = RecordingConfiguration(
            sources: [config],
            outputs: [output],
            codec: .hevc,
            container: .mov
        )
        #expect(recording.sources.count == 1)
        #expect(recording.outputs.count == 1)
        #expect(recording.codec == .hevc)
        #expect(recording.container == .mov)
    }
}

// MARK: - Protocol fake construction (proves issue #17 AC)

@Suite("Domain protocol fakes")
struct DomainProtocolFakeTests {
    @Test("FakeClock is constructible and conforms to ClockProviding")
    func clockFakeConforms() {
        let clock: any ClockProviding = FakeClock()
        let t = clock.now()
        #expect(t == .zero)
    }

    @Test("FakeCaptureSource is constructible and conforms to CaptureSource")
    func captureSourceFakeConforms() throws {
        let source: any CaptureSource = FakeCaptureSource(kind: .camera)
        let config = SourceConfiguration(kind: .camera, width: 1920, height: 1080, fps: 30)
        try source.configure(config)
        #expect(source.kind == .camera)
    }

    @Test("FakeSampleSink is constructible and conforms to SampleSink")
    func sampleSinkFakeConforms() {
        // Proves the fake can be built; actual receive() is tested via CaptureSource.
        let sink: any SampleSink = FakeSampleSink()
        #expect(sink is FakeSampleSink)
    }

    @Test("FakeEncodingWriter is constructible and conforms to EncodingWriter")
    func encodingWriterFakeConforms() throws {
        let writer: any EncodingWriter = FakeEncodingWriter()
        let output = OutputDescriptor(
            destination: URL(fileURLWithPath: "/tmp/out.mov"),
            codec: .hevc,
            container: .mov,
            tracks: [.video]
        )
        try writer.prepare(output)
        writer.beginSession(atSourceTime: .zero)
        #expect(writer.health == .alive)
        #expect(writer.isAlive == true)
    }
}
