import AVFoundation
import AppKit
import SwiftUI

// MARK: - CameraPreviewNSView

/// An `NSView` whose backing layer is an `AVCaptureVideoPreviewLayer`.
///
/// Hosted by `CameraPreviewView` via `NSViewRepresentable`. Extracted as a named
/// type so the construction path (layer type, `wantsLayer`) is unit-testable without
/// an `NSViewRepresentableContext`.
///
/// - Note: The `AVCaptureSession` is provided externally; this view does not own,
///   create, or start any session. See `CameraPreviewView` for the origin note.
final class CameraPreviewNSView: NSView {

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? {
        String(localized: "camera.preview.accessibilityLabel", bundle: .module)
    }

    // MARK: - Layer

    override var wantsLayer: Bool {
        get { true }
        set {}  // Always layer-backed — setter ignored.
    }

    /// The `AVCaptureVideoPreviewLayer` that backs this view.
    ///
    /// Created eagerly in `init` (before AppKit calls `makeBackingLayer()`) so that
    /// `update(session:)` and unit tests can reference it without triggering a display
    /// pass. `makeBackingLayer()` returns this same instance, so AppKit adopts it as
    /// `self.layer` — no duplication occurs.
    let previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer()
        // .resizeAspect: letterboxes the preview to preserve the camera's native aspect
        // ratio without cropping. Correct for a settings preview where the user must see
        // the true field of view. Matches AC-4 intent ("live preview of the selected camera").
        layer.videoGravity = .resizeAspect
        return layer
    }()

    /// Returns the pre-created `AVCaptureVideoPreviewLayer` as the view's backing layer.
    ///
    /// AppKit calls this once when it first needs the layer. Returning `previewLayer`
    /// here makes it `self.layer` — no sublayer sizing or layout pass needed.
    override func makeBackingLayer() -> CALayer {
        previewLayer
    }

    // MARK: - Session

    /// Updates the preview layer's session without recreating the layer.
    ///
    /// Reassigning `previewLayer.session` is the correct — and only — way to switch
    /// sessions without glitch. Recreating the layer would produce a flash/blank frame;
    /// setting `session = nil` detaches cleanly. AVFoundation manages attachment and
    /// teardown internally.
    ///
    /// - Parameter session: The `AVCaptureSession` to display, or `nil` to stop preview.
    func update(session: AVCaptureSession?) {
        // Guard: skip the AVFoundation assignment if the session is already the same
        // object, avoiding a redundant teardown-reattach cycle on identical SwiftUI
        // state updates (e.g. view body re-evaluation with no actual camera change).
        guard previewLayer.session !== session else { return }
        previewLayer.session = session
    }
}

// MARK: - CameraPreviewView

/// A SwiftUI view that displays a live preview of an `AVCaptureSession`.
///
/// Wraps `AVCaptureVideoPreviewLayer` inside an `NSViewRepresentable` for use in the
/// settings UI. Video gravity is `.resizeAspect` — the camera's native aspect ratio is
/// preserved with letterboxing; no distortion or cropping occurs.
///
/// ## Session origin
///
/// The `session` parameter is owned by `CameraCaptureSource` (Infrastructure). The
/// Settings / coordinator layer wires it into this view via `#32` and `#36` —
/// `CameraPreviewView` only displays what it is given and does not start, stop, or
/// own any session. Integration into `SettingsView` is tracked by **#32**.
///
/// ## AC-4 behaviour
///
/// - **Non-nil session:** the preview layer shows live camera video immediately.
/// - **Session change:** `updateNSView` reassigns `previewLayer.session`; AVFoundation
///   handles the transition. No glitch, no layer recreation, no reference leak.
/// - **Nil session** ("No camera" selection): shows a localized placeholder label
///   (`"camera.preview.placeholder"` from the String Catalog). The preview layer's
///   session is detached (`nil`) so no stale frames appear.
///
/// ## L5 / visual-acceptance boundary
///
/// The following behaviours require a running app with a physical camera:
/// - Live video is visible and correctly aspect-ratio-letterboxed.
/// - Preview switches instantly when the user picks a different camera (no blank frame
///   or glitch between sessions).
/// Verify against `docs/spec/testing.md` on the reference hardware (MacBook Pro 14" M3 Max
/// + external 4K60 + Logitech MX Brio). Nil/non-nil session toggle and placeholder visibility
/// are covered by L2 unit tests.
public struct CameraPreviewView: NSViewRepresentable {

    // MARK: - Input

    /// The capture session whose output is rendered in the preview layer.
    ///
    /// `nil` means "No camera" is selected; the view shows a localized placeholder.
    public var session: AVCaptureSession?

    // MARK: - Initializer

    /// - Parameter session: The `AVCaptureSession` to preview, or `nil` for no camera.
    public init(session: AVCaptureSession?) {
        self.session = session
    }

    // MARK: - NSViewRepresentable: Coordinator

    /// Holds strong references to the subviews created in `makeNSView` so that
    /// `updateNSView` can reach them without relying on view traversal or tag lookups.
    public final class Coordinator {
        let previewView: CameraPreviewNSView
        let placeholderLabel: NSTextField

        init(previewView: CameraPreviewNSView, placeholderLabel: NSTextField) {
            self.previewView = previewView
            self.placeholderLabel = placeholderLabel
        }
    }

    public func makeCoordinator() -> Coordinator {
        // Constructed with placeholder values; the views are populated in makeNSView
        // and the same Coordinator instance is passed to updateNSView via context.
        Coordinator(
            previewView: CameraPreviewNSView(),
            placeholderLabel: NSTextField(labelWithString: "")
        )
    }

    // MARK: - NSViewRepresentable: view lifecycle

    public func makeNSView(context: Context) -> NSView {
        // Container holds both preview and placeholder so we never toggle
        // layer-backed state after the view is in the hierarchy (not supported).
        // isAccessibilityElement = false: let VoiceOver traverse into children directly;
        // the container has no meaningful semantic role of its own.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.setAccessibilityElement(false)

        // Preview — fills container.
        let preview = context.coordinator.previewView
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Placeholder label — centered, shown when session is nil.
        let placeholder = context.coordinator.placeholderLabel
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        // Prevent overflow with long localized strings: truncate at tail and constrain
        // width to container with ~16pt margins. Lower compression resistance so truncation
        // actually engages (default 750 would push the container wider instead).
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // NFR-I18N: localized string from the String Catalog via Bundle.module.
        placeholder.stringValue = String(
            localized: "camera.preview.placeholder",
            bundle: .module
        )
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        updateSubviews(coordinator: context.coordinator, session: session)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        updateSubviews(coordinator: context.coordinator, session: session)
    }

    // MARK: - Private helpers

    /// Applies the current `session` state to the coordinator's subviews.
    ///
    /// - When `session` is non-nil: attach the session to the preview layer and hide
    ///   the placeholder.
    /// - When `session` is nil: detach the session from the preview layer and show
    ///   the placeholder.
    ///
    /// `internal` (not `private`) so that `@testable import Presentation` can drive
    /// the nil/non-nil branches in L2 unit tests without a physical camera.
    func updateSubviews(coordinator: Coordinator, session: AVCaptureSession?) {
        if let activeSession = session {
            coordinator.previewView.update(session: activeSession)
            coordinator.previewView.isHidden = false
            coordinator.placeholderLabel.isHidden = true
        } else {
            coordinator.previewView.update(session: nil)
            coordinator.previewView.isHidden = true
            coordinator.placeholderLabel.isHidden = false
        }
    }
}
