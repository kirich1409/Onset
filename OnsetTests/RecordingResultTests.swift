import Foundation
@testable import Onset
import Testing

// MARK: - SessionOutput init? case mapping

/// Verifies that `SessionOutput.init?(screen:camera:)` maps all four input combinations
/// to the correct enum case (or `nil`), locking the exhaustive-case contract.
@Suite("SessionOutput — failable init case mapping")
struct SessionOutputInitTests {
    private let screenResult: FinishResult = .completed(url: URL(filePath: "/tmp/screen.mp4"))
    private let cameraResult: FinishResult = .completed(url: URL(filePath: "/tmp/camera.mp4"))

    @Test("screenOnly: non-nil screen + nil camera")
    func screenOnly() throws {
        let output = try #require(SessionOutput(screen: screenResult, camera: nil))
        guard case .screenOnly = output else {
            Issue.record("Expected .screenOnly, got \(output)")
            return
        }
    }

    @Test("cameraOnly: nil screen + non-nil camera")
    func cameraOnly() throws {
        let output = try #require(SessionOutput(screen: nil, camera: cameraResult))
        guard case .cameraOnly = output else {
            Issue.record("Expected .cameraOnly, got \(output)")
            return
        }
    }

    @Test("both: non-nil screen + non-nil camera")
    func both() throws {
        let output = try #require(SessionOutput(screen: screenResult, camera: cameraResult))
        guard case .both = output else {
            Issue.record("Expected .both, got \(output)")
            return
        }
    }

    @Test("nil: nil screen + nil camera → init? returns nil")
    func nilBothReturnsNil() {
        #expect(SessionOutput(screen: nil, camera: nil) == nil)
    }
}
