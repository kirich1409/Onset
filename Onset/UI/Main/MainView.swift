import SwiftUI

// MARK: - MainView

/// Placeholder main recording screen.
///
/// - Note: This is a **stub** intentionally left incomplete. The real recording UI
///   is implemented in the `onset-recording-mvp` feature. This view satisfies the
///   composition-root requirement from Stage 4+5 so `RootView` has a valid destination
///   for the `.main` route.
///
///   Replace this file entirely when landing `onset-recording-mvp`.
struct MainView: View {
    // MARK: - Metrics

    private enum Metrics {
        static let contentSpacing: CGFloat = 16
        static let windowMinWidth: CGFloat = 460
        static let windowMinHeight: CGFloat = 320
        static let iconSize: CGFloat = 48
        static let cardCornerRadius: CGFloat = 10
        static let outerPadding: CGFloat = 24
        static let cardPadding: CGFloat = 16
        static let iconColumnWidth: CGFloat = 20
        static let rowSpacing: CGFloat = 10
        static let rowIconSpacing: CGFloat = 10
        static let stubNotePadding: CGFloat = 4
    }

    // MARK: - Inputs

    let effectivePermissions: EffectivePermissions
    /// Called when the user wants to return to onboarding (e.g. no recording possible).
    let onReturnToOnboarding: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: Metrics.contentSpacing) {
            if self.effectivePermissions.canRecord {
                self.recordingReadyContent
            } else {
                self.noPermissionsContent
            }
        }
        .frame(
            minWidth: Metrics.windowMinWidth,
            minHeight: Metrics.windowMinHeight
        )
        .padding(Metrics.outerPadding)
    }

    // MARK: - Sub-views

    private var recordingReadyContent: some View {
        VStack(spacing: Metrics.rowSpacing) {
            Image(systemName: "record.circle")
                .font(.system(size: Metrics.iconSize))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text("Готово к записи")
                .font(.title2)
                .fontWeight(.semibold)

            self.availabilityCard

            Text("Заглушка — реализация записи в onset-recording-mvp")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Metrics.stubNotePadding)
        }
    }

    private var availabilityCard: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            self.availabilityRow(
                icon: "display",
                label: "Запись экрана",
                available: self.effectivePermissions.screenAvailable
            )
            self.availabilityRow(
                icon: "camera.fill",
                label: "Камера",
                available: self.effectivePermissions.cameraAvailable
            )
            self.availabilityRow(
                icon: "mic.fill",
                label: "Микрофон",
                available: self.effectivePermissions.microphoneAvailable
            )
        }
        .padding(Metrics.cardPadding)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
    }

    private var noPermissionsContent: some View {
        VStack(spacing: Metrics.rowSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Metrics.iconSize))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Запись недоступна")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Выдайте разрешения, чтобы начать запись.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Выдать разрешения") {
                self.onReturnToOnboarding()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func availabilityRow(icon: String, label: String, available: Bool) -> some View {
        HStack(spacing: Metrics.rowIconSpacing) {
            Image(systemName: icon)
                .frame(width: Metrics.iconColumnWidth)
                .foregroundStyle(available ? .primary : Color(nsColor: .tertiaryLabelColor))
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(available ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(available ? Color.green : Color(nsColor: .tertiaryLabelColor))
                .accessibilityLabel(available ? "\(label): доступно" : "\(label): недоступно")
        }
    }
}

// MARK: - Previews

#Preview("Recording ready — full") {
    MainView(
        effectivePermissions: EffectivePermissions.compute(
            screen: .authorized,
            camera: .authorized,
            microphone: .authorized
        )
    ) {}
}

#Preview("Recording ready — no mic") {
    MainView(
        effectivePermissions: EffectivePermissions.compute(
            screen: .authorized,
            camera: .authorized,
            microphone: .notDetermined
        )
    ) {}
}

#Preview("No permissions") {
    MainView(
        effectivePermissions: EffectivePermissions.compute(
            screen: .notDetermined,
            camera: .notDetermined,
            microphone: .notDetermined
        )
    ) {}
}
