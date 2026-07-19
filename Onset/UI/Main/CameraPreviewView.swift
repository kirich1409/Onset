import AppKit
import AVFoundation

// MARK: - CameraPreviewView

/// A minimal `NSView` that hosts an `AVCaptureVideoPreviewLayer`.
///
/// This is a smoke-level placeholder for Epic 4's full preview UI. Constructed on
/// `@MainActor` from a `SessionHandle` — no actor-isolation crossing of the non-Sendable
/// `CALayer` or `AVCaptureVideoPreviewLayer` occurs because both are created on `MainActor`.
///
/// When `sessionHandle` is `nil` (permission denied / no device), the view shows a
/// dark placeholder background with no preview layer.
@MainActor
final class CameraPreviewView: NSView {
    /// The hosted preview layer, or `nil` when constructed without a session (placeholder).
    ///
    /// Exposed (with a private setter) so `CameraPreviewRepresentable.updateNSView` — the SOLE
    /// writer — can set `connection?.isVideoMirrored` reactively. The connection's
    /// `automaticallyAdjustsVideoMirroring` is disabled here at wiring time so that reactive set
    /// is authoritative (some cameras auto-mirror the preview by default otherwise).
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    init(sessionHandle: SessionHandle?) {
        super.init(frame: .zero)
        self.wantsLayer = true
        if let handle = sessionHandle {
            let layer = AVCaptureVideoPreviewLayer(session: handle.session)
            layer.videoGravity = .resizeAspectFill
            layer.connection?.automaticallyAdjustsVideoMirroring = false
            self.layer?.addSublayer(layer)
            self.previewLayer = layer
        } else {
            self.layer?.backgroundColor = NSColor.black.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        self.previewLayer?.frame = self.bounds
    }
}
