import AVFoundation
import AppKit
import Testing

@testable import Presentation

// MARK: - CameraPreviewNSView unit smoke tests

/// Verifies the construction-time invariants of `CameraPreviewNSView` without a live
/// camera session. These tests cover the layer-backing contract only.
///
/// ## L5 / visual-acceptance boundary
///
/// The following behaviours are NOT covered here — they require a running app with a
/// physical camera and must be verified per `docs/spec/testing.md` Appendix A on the
/// reference hardware (MacBook Pro 14" M3 Max + Logitech MX Brio):
///
/// - Live video is visible and correctly aspect-ratio-letterboxed (`.resizeAspect`).
/// - Preview switches without glitch when a different `AVCaptureSession` is assigned.
@MainActor
@Suite("CameraPreviewNSView construction")
struct CameraPreviewViewTests {

    // MARK: - Backing layer

    @Test("CameraPreviewNSView is layer-backed")
    func backingViewWantsLayer() {
        let view = CameraPreviewNSView()
        #expect(view.wantsLayer == true)
    }

    @Test("CameraPreviewNSView pre-creates an AVCaptureVideoPreviewLayer")
    func previewLayerIsAVCaptureVideoPreviewLayer() {
        let view = CameraPreviewNSView()
        // previewLayer is stored eagerly — accessible without a display pass or window.
        #expect(view.previewLayer is AVCaptureVideoPreviewLayer)
    }

    @Test("CameraPreviewNSView videoGravity is resizeAspect")
    func videoGravityIsResizeAspect() {
        let view = CameraPreviewNSView()
        #expect(view.previewLayer.videoGravity == .resizeAspect)
    }

    // MARK: - Session assignment

    @Test("update(session:nil) sets previewLayer.session to nil")
    func updateNilSessionDetachesLayer() {
        let view = CameraPreviewNSView()
        view.update(session: nil)
        #expect(view.previewLayer.session == nil)
    }
}

// MARK: - AC-4 visibility toggle (L2)

/// Tests for the nil/non-nil session branches of `updateSubviews`.
///
/// `AVCaptureSession()` constructs without a physical camera — these are pure L2 tests.
/// The `@testable import Presentation` reaches internal `updateSubviews` directly.
@MainActor
@Suite("CameraPreviewView AC-4 visibility toggle")
struct CameraPreviewViewToggleTests {

    // MARK: - Non-nil branch

    @Test("Non-nil session: previewView shown, placeholder hidden, layer session set")
    func nonNilSessionShowsPreviewHidesPlaceholder() {
        let view = CameraPreviewView(session: nil)
        let coord = view.makeCoordinator()
        let session = AVCaptureSession()

        view.updateSubviews(coordinator: coord, session: session)

        #expect(coord.previewView.isHidden == false)
        #expect(coord.placeholderLabel.isHidden == true)
        #expect(coord.previewView.previewLayer.session === session)
    }

    // MARK: - Nil-transition branch

    @Test("Nil session after non-nil: previewView hidden, placeholder shown, layer detached")
    func nilTransitionHidesPreviewShowsPlaceholder() {
        let view = CameraPreviewView(session: nil)
        let coord = view.makeCoordinator()

        // First set a non-nil session, then transition to nil.
        view.updateSubviews(coordinator: coord, session: AVCaptureSession())
        view.updateSubviews(coordinator: coord, session: nil)

        #expect(coord.previewView.isHidden == true)
        #expect(coord.placeholderLabel.isHidden == false)
        #expect(coord.previewView.previewLayer.session == nil)
    }

    // MARK: - Idempotency guard

    @Test("Same session assigned twice: layer session unchanged, no crash")
    func sameSessionTwiceIsIdempotent() {
        let view = CameraPreviewView(session: nil)
        let coord = view.makeCoordinator()
        let session = AVCaptureSession()

        // Both calls must complete without crash; the guard prevents a redundant
        // teardown-reattach cycle on the second call.
        view.updateSubviews(coordinator: coord, session: session)
        view.updateSubviews(coordinator: coord, session: session)

        #expect(coord.previewView.previewLayer.session === session)
    }
}
