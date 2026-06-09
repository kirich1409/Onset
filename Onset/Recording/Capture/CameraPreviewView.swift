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
/// Uses layer-**hosting**: `init` creates the `AVCaptureVideoPreviewLayer`, assigns it directly
/// to `self.layer`, then sets `wantsLayer = true`. Order matters — assign `self.layer` first,
/// then `wantsLayer = true`; the reverse order causes AppKit to create a generic backing layer
/// that shadows the preview layer.
///
/// Layer-hosting is robust in an `NSViewRepresentable` context because `makeNSView` returns
/// a fully-configured view; AppKit does not preempt or replace the hosted layer. The
/// `makeBackingLayer()` override approach is unreliable here because SwiftUI's hosting
/// infrastructure may install a backing layer before `makeBackingLayer()` fires, silently
/// discarding the preview layer.
///
/// `AVCaptureVideoPreviewLayer.session` is a nullable settable property. Setting it to `nil`
/// shows a black frame; setting it to a running session starts live preview immediately.
///
/// The session can be swapped live via `update(sessionHandle:)` without recreating the view
/// when the same camera is reused across sessions. The view is created once by `makeNSView`
/// and persists; `updateNSView` calls `update(sessionHandle:)` as the handle becomes available.
@MainActor
final class CameraPreviewView: NSView {
    /// The `AVCaptureVideoPreviewLayer` hosted as this view's layer.
    ///
    /// Assigned in `init` before `wantsLayer = true`. Non-nil for the lifetime of the view.
    private let previewLayer: AVCaptureVideoPreviewLayer

    /// Initialises the view with an optional live camera session.
    ///
    /// Creates the `AVCaptureVideoPreviewLayer`, attaches `sessionHandle.session` if provided,
    /// then hosts it as the view's own layer. If `sessionHandle` is nil the layer renders black
    /// until `update(sessionHandle:)` is called with a live session.
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

        // Layer-hosting: assign self.layer BEFORE wantsLayer = true.
        // Reversing the order causes AppKit to allocate a generic CALayer and host
        // the preview layer as a sublayer, which does not receive automatic layout.
        self.layer = self.previewLayer
        self.wantsLayer = true

        cameraPreviewLogger.debug(
            "preview view init — session=\(sessionHandle != nil ? "real" : "nil")"
        )
        cameraPreviewLogger.debug("preview layer hosted")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Updates the live preview session without recreating the view.
    ///
    /// Called from `NSViewRepresentable.updateNSView(_:context:)` whenever the session
    /// handle changes. Reassigns `session` on the hosted `AVCaptureVideoPreviewLayer` — the
    /// layer is always available because it is created in `init`.
    ///
    /// - When `sessionHandle` is non-nil: attaches the running session to start live preview.
    /// - When `sessionHandle` is `nil`: detaches the session to show a black frame.
    func update(sessionHandle: SessionHandle?) {
        self.previewLayer.session = sessionHandle?.session
        cameraPreviewLogger.debug(
            "preview session updated — session=\(sessionHandle != nil ? "real" : "nil")"
        )
    }

    /// Keeps the preview layer sized to the view's bounds on layout.
    ///
    /// Layer-hosting does not auto-size the hosted layer — AppKit only auto-sizes
    /// backing layers managed by `makeBackingLayer`. This override is therefore required
    /// (not merely a safety net) to keep the preview layer filling the view.
    override func layout() {
        super.layout()
        self.previewLayer.frame = self.bounds
    }
}
