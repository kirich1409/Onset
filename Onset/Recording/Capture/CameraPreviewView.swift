import AppKit
import AVFoundation
import os
import QuartzCore

// MARK: - Logger

private let cameraPreviewLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "CameraPreviewView"
)

// MARK: - CameraPreviewView

/// An `NSView` that renders a live camera feed via `AVCaptureVideoPreviewLayer`.
///
/// Constructed on `@MainActor` from a `SessionHandle` — no actor-isolation crossing of the
/// non-Sendable `CALayer` or `AVCaptureVideoPreviewLayer` occurs because both are created on
/// `MainActor`.
///
/// Uses **sublayer composition**: `init` creates `AVCaptureVideoPreviewLayer` and stores it as
/// `previewLayer`; `wantsLayer = true` makes AppKit create (and own) a generic backing layer;
/// `viewDidMoveToWindow()` adds `previewLayer` as a sublayer of that backing layer.
///
/// Layer-**hosting** (assigning `self.layer = previewLayer` before `wantsLayer = true`) is
/// incompatible with `NSViewRepresentable`: SwiftUI's hosting infrastructure applies clip shapes
/// and size constraints by owning/masking the hosted NSView's backing layer. Assigning the
/// `AVCaptureVideoPreviewLayer` as `self.layer` causes SwiftUI to shadow or detach it from the
/// compositing tree — the layer has a valid session, connection, and bounds but is never
/// rendered, producing a permanently black frame.
///
/// With the sublayer approach the SwiftUI-managed backing layer remains the compositing root
/// (clip and frame constraints apply correctly); `previewLayer` as a sublayer receives rendered
/// frames and is clipped by the backing layer — matching the visual intent.
///
/// `AVCaptureVideoPreviewLayer.session` is a nullable settable property. Setting it to `nil`
/// shows a black frame; setting it to a running session starts live preview immediately.
///
/// The session can be swapped live via `update(sessionHandle:)` without recreating the view
/// when the same camera is reused across sessions. The view is created once by `makeNSView`
/// and persists; `updateNSView` calls `update(sessionHandle:)` as the handle becomes available.
@MainActor
final class CameraPreviewView: NSView {
    /// The `AVCaptureVideoPreviewLayer` added as a sublayer of the SwiftUI-managed backing layer.
    ///
    /// Created in `init`, attached in `viewDidMoveToWindow()` (when `self.layer` is available),
    /// and sized to `self.bounds` in `layout()`. Non-nil for the lifetime of the view.
    private let previewLayer: AVCaptureVideoPreviewLayer

    /// Initialises the view with an optional live camera session.
    ///
    /// Creates the `AVCaptureVideoPreviewLayer` and sets `wantsLayer = true` so AppKit allocates
    /// a generic backing layer that SwiftUI will manage. Does **not** assign `self.layer = previewLayer`
    /// — that causes the layer-hosting incompatibility described in the type doc. The preview layer
    /// is attached as a sublayer in `viewDidMoveToWindow()` when `self.layer` is available.
    ///
    /// - Parameter sessionHandle: Wraps the running `AVCaptureSession` to attach to the
    ///   preview layer. May be `nil`; the session is attached via `update(sessionHandle:)`
    ///   when it becomes available.
    init(sessionHandle: SessionHandle?) {
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        layer.session = sessionHandle?.session
        self.previewLayer = layer

        super.init(frame: .zero)

        // wantsLayer = true without self.layer assignment: AppKit creates a generic backing
        // layer that SwiftUI manages. The preview layer attaches as a sublayer in
        // viewDidMoveToWindow(), once self.layer is realized.
        self.wantsLayer = true

        cameraPreviewLogger.debug(
            "preview view init — session=\(sessionHandle != nil ? "real" : "nil", privacy: .public)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Attaches `previewLayer` as a sublayer of the SwiftUI-managed backing layer.
    ///
    /// Called when the view enters a window, at which point `self.layer` is realized.
    /// The add is idempotent: the check `previewLayer.superlayer == nil` prevents double-adding
    /// if `viewDidMoveToWindow()` is called more than once (e.g. moving between windows).
    ///
    /// Sets `previewLayer.frame = self.bounds` immediately after attaching so the first
    /// render does not show a zero-sized frame before `layout()` fires.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if self.previewLayer.superlayer == nil {
            self.layer?.addSublayer(self.previewLayer)
            // Size the sublayer immediately — layout() may not fire before the first frame is
            // composited, and a zero frame on first attach would show black.
            self.previewLayer.frame = self.bounds
        }

        cameraPreviewLogger.debug(
            """
            preview attached — \
            selfLayerIsPreview=\(self.layer === self.previewLayer, privacy: .public) \
            superlayerSet=\(self.previewLayer.superlayer != nil, privacy: .public) \
            layerType=\(String(describing: type(of: self.layer)), privacy: .public)
            """
        )
    }

    /// Updates the live preview session without recreating the view.
    ///
    /// Called from `NSViewRepresentable.updateNSView(_:context:)` whenever the session
    /// handle changes. Reassigns `session` on the `AVCaptureVideoPreviewLayer` — the
    /// layer is always available because it is created in `init`.
    ///
    /// - When `sessionHandle` is non-nil: attaches the running session to start live preview.
    /// - When `sessionHandle` is `nil`: detaches the session to show a black frame.
    func update(sessionHandle: SessionHandle?) {
        self.previewLayer.session = sessionHandle?.session
        cameraPreviewLogger.debug(
            "preview session updated — session=\(sessionHandle != nil ? "real" : "nil", privacy: .public)"
        )
    }

    /// Keeps the preview sublayer sized to the view's bounds on every layout pass.
    ///
    /// AppKit does not auto-size manually-added sublayers — only backing layers managed by
    /// `makeBackingLayer` are auto-sized. This override is required to keep `previewLayer`
    /// filling the view after every bounds change.
    override func layout() {
        super.layout()
        self.previewLayer.frame = self.bounds
        cameraPreviewLogger.debug(
            "preview layout — bounds=\(NSStringFromRect(self.bounds), privacy: .public)"
        )
    }
}
