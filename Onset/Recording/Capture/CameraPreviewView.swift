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
/// The `AVCaptureVideoPreviewLayer` is used as the view's **own backing layer** (via
/// `makeBackingLayer()`) rather than as a sublayer. This avoids the AppKit timing issue
/// where `self.layer` is `nil` at `init` time — `wantsLayer = true` creates the backing
/// layer lazily during view mounting, so `addSublayer` called in `init` is a silent no-op.
/// A backing layer returned from `makeBackingLayer()` is wired immediately and tracks
/// the view's bounds automatically.
///
/// `makeBackingLayer()` always returns an `AVCaptureVideoPreviewLayer` regardless of
/// whether a `SessionHandle` is available at construction time. This guarantees a single
/// code path in `update(sessionHandle:)`: reassign `session` on the existing backing layer.
/// No sublayer path is needed, eliminating compositing ambiguity when the session arrives
/// after initial layout.
///
/// Callers must gate instantiation on `previewHandle != nil`: `AVCaptureVideoPreviewLayer`
/// only starts delivering frames when the session it receives at first connection is already
/// running. Creating the view with `sessionHandle: nil` and later calling
/// `update(sessionHandle:)` with a real session does not reliably start preview delivery.
/// The SwiftUI layer (`CameraPreviewRepresentable`) enforces this by showing a `Color.black`
/// placeholder until the handle is available, then instantiating this view.
///
/// `AVCaptureVideoPreviewLayer.session` is a nullable settable property. Setting it to `nil`
/// shows a black placeholder; setting it to a running session starts live preview immediately.
///
/// The session can be swapped live via `update(sessionHandle:)` without recreating the view
/// when the same camera is reused across sessions.
@MainActor
final class CameraPreviewView: NSView {
    /// The session handle supplied at construction time.
    ///
    /// Stored before `super.init` so `makeBackingLayer()` (which AppKit may call synchronously
    /// when `wantsLayer = true` is set) can read the handle to attach the session.
    private let initialSessionHandle: SessionHandle?

    /// The preview layer used as the view's backing layer.
    ///
    /// Always non-nil after `makeBackingLayer()` fires (i.e., after the view mounts).
    /// Created unconditionally so `update(sessionHandle:)` always has a layer to reassign.
    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// Initialises the view with an optional live camera session.
    ///
    /// - Parameter sessionHandle: Wraps the running `AVCaptureSession` to attach to the
    ///   preview layer. Pass `nil` for a dark placeholder; however, callers should prefer
    ///   gating instantiation on a non-nil handle so `makeBackingLayer()` always receives
    ///   a real running session (see type documentation).
    init(sessionHandle: SessionHandle?) {
        // Store the handle BEFORE calling super.init / setting wantsLayer.
        // Setting wantsLayer = true can trigger makeBackingLayer() synchronously;
        // the stored handle must already be set so the layer is built with the session.
        self.initialSessionHandle = sessionHandle
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Returns the view's backing layer — always an `AVCaptureVideoPreviewLayer`.
    ///
    /// A non-started `AVCaptureSession` placeholder is used to satisfy the required
    /// `session` parameter of `AVCaptureVideoPreviewLayer(session:)` when no real session
    /// is available yet. The session is immediately replaced with the real one (or kept as
    /// the placeholder and shown as black) by setting the nullable `session` property.
    ///
    /// Using a single layer type regardless of handle availability means `update(sessionHandle:)`
    /// always takes the same branch (reassign on existing layer) — no sublayer path, no
    /// compositing ambiguity.
    override func makeBackingLayer() -> CALayer {
        // AVCaptureVideoPreviewLayer has no no-arg init; a session object is required.
        // Use a placeholder AVCaptureSession (never started) so the layer allocates,
        // then immediately replace session with the real one (or nil for the dark placeholder).
        let placeholderSession = AVCaptureSession()
        let layer = AVCaptureVideoPreviewLayer(session: placeholderSession)
        layer.videoGravity = .resizeAspectFill
        // Replace the placeholder with the real session — or nil (black) if none available yet.
        // Replacing it here rather than in init keeps makeBackingLayer as the single source of truth.
        layer.session = self.initialSessionHandle?.session
        self.previewLayer = layer
        cameraPreviewLogger.debug(
            "makeBackingLayer — session=\(self.initialSessionHandle != nil ? "real" : "nil(placeholder)")"
        )
        return layer
    }

    /// Updates the live preview session without recreating the view.
    ///
    /// Called from `NSViewRepresentable.updateNSView(_:context:)` whenever the session
    /// handle changes. Reassigns `session` on the backing `AVCaptureVideoPreviewLayer` —
    /// the layer was always created as a preview layer in `makeBackingLayer()`, so this
    /// path is always available regardless of handle-arrival timing.
    ///
    /// - When `sessionHandle` is non-nil: attaches the running session to start live preview.
    /// - When `sessionHandle` is `nil`: detaches the session to show a black placeholder.
    func update(sessionHandle: SessionHandle?) {
        guard let existing = self.previewLayer else {
            // makeBackingLayer has not fired yet — the view is not mounted.
            // This is benign: updateNSView fires after makeNSView, so makeBackingLayer
            // will have fired before any update call arrives.
            cameraPreviewLogger.debug("update called before makeBackingLayer — no-op")
            return
        }
        existing.session = sessionHandle?.session
    }

    /// Keeps the preview layer sized to the view's bounds on layout.
    ///
    /// The preview layer is the backing layer (not a sublayer), so AppKit auto-sizes it
    /// when `autoresizingMask` or Auto Layout drives the view. This override is a safety
    /// net for any edge case where the automatic sizing lags.
    override func layout() {
        super.layout()
        self.previewLayer?.frame = self.bounds
    }
}
