import SwiftUI

// MARK: - AllSetView

/// The one-time "Всё готово · 3 из 3" confirmation screen shown after the screen-recording
/// relaunch (`--post-screen-grant` arg + preflight confirmed).
///
/// Displayed once per screen-recording grant cycle; tapping «Перейти к записи» navigates
/// to the main screen and clears the transient allSet route so subsequent launches go
/// directly to main (AC-8 / AC-9).
struct AllSetView: View {
    // MARK: - Metrics

    private enum Metrics {
        static let windowWidth: CGFloat = 460
        static let checkCircleSize: CGFloat = 72
        static let checkIconSize: CGFloat = 32
        static let contentVSpacing: CGFloat = 16
        static let headerVSpacing: CGFloat = 8
        static let cardStackSpacing: CGFloat = 8
        static let contentPadding: CGFloat = 20
        static let progressBarHeight: CGFloat = 4
        static let progressBarCornerRadius: CGFloat = 2
        static let headerTopPadding: CGFloat = 8
        static let footerTextSpacing: CGFloat = 4
    }

    // MARK: - Inputs

    let permissions: any PermissionsProviding
    let onProceedToMain: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: Metrics.contentVSpacing) {
                    self.allSetHeader
                    self.permissionRows
                }
                .padding(Metrics.contentPadding)
            }

            Divider()
            self.footerSection
        }
        .frame(width: Metrics.windowWidth)
    }

    // MARK: - Header

    private var allSetHeader: some View {
        VStack(spacing: Metrics.headerVSpacing) {
            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: Metrics.checkCircleSize, height: Metrics.checkCircleSize)
                Image(systemName: "checkmark")
                    .font(.system(size: Metrics.checkIconSize, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .padding(.top, Metrics.headerTopPadding)

            Text("Всё готово")
                .font(.title2)
                .fontWeight(.bold)

            Text(
                "Доступ к экрану, камере и микрофону выдан. " +
                    "Этот экран больше не появится — Onset открывается сразу к записи."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Всё готово. Доступ к экрану, камере и микрофону выдан.")
    }

    // MARK: - Permission rows (all authorized)

    private var permissionRows: some View {
        VStack(spacing: Metrics.cardStackSpacing) {
            self.screenRow
            self.cameraRow
            self.microphoneRow
        }
    }

    private var screenRow: some View {
        PermissionCardView(
            iconSymbol: "display",
            iconColor: .purple,
            title: "Запись экрана",
            subtitle: self.permissions.primaryDisplayDescription.map { "Дисплей \($0)." }
                ?? "Захват вашего дисплея.",
            status: .authorized,
            actionButton: nil,
            instructions: nil,
            instructionsHeader: nil,
            showInstructions: .constant(false)
        )
    }

    private var cameraRow: some View {
        PermissionCardView(
            iconSymbol: "camera.fill",
            iconColor: PermissionIconColor.camera,
            title: "Камера",
            subtitle: self.permissions.defaultCameraName.map { "\($0)." } ?? "Камера готова.",
            status: .authorized,
            actionButton: nil,
            instructions: nil,
            instructionsHeader: nil,
            showInstructions: .constant(false)
        )
    }

    private var microphoneRow: some View {
        PermissionCardView(
            iconSymbol: "mic.fill",
            iconColor: PermissionIconColor.microphone,
            title: "Микрофон",
            subtitle: self.permissions.defaultMicrophoneName.map { "\($0)." } ?? "Микрофон готов.",
            status: .authorized,
            actionButton: nil,
            instructions: nil,
            instructionsHeader: nil,
            showInstructions: .constant(false)
        )
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.footerTextSpacing) {
                self.fullProgressBar
                HStack(spacing: Metrics.footerTextSpacing) {
                    Text("3 из 3")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("все разрешения активны")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Перейти к записи") {
                self.onProceedToMain()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Metrics.contentPadding)
    }

    private var fullProgressBar: some View {
        RoundedRectangle(cornerRadius: Metrics.progressBarCornerRadius)
            .fill(Color.accentColor)
            .frame(height: Metrics.progressBarHeight)
            .accessibilityLabel("Прогресс: 3 из 3 разрешений выдано")
    }
}

// MARK: - Previews

#if DEBUG
    @MainActor
    private final class PreviewPermissionsServiceAllSet: PermissionsProviding {
        var screenStatus: PermissionStatus {
            .authorized
        }

        var cameraStatus: PermissionStatus {
            .authorized
        }

        var microphoneStatus: PermissionStatus {
            .authorized
        }

        var effectivePermissions: EffectivePermissions {
            EffectivePermissions.compute(screen: .authorized, camera: .authorized, microphone: .authorized)
        }

        var progress: Int {
            3 // swiftlint:disable:this no_magic_numbers
        }

        var allGranted: Bool {
            true
        }

        var defaultCameraName: String? {
            "Preview Camera"
        }

        var defaultMicrophoneName: String? {
            "Preview Microphone"
        }

        var primaryDisplayDescription: String? {
            "1920×1080"
        }

        func refresh() {}
        func requestCamera() async {}
        func requestMicrophone() async {}
        func requestScreenRecording() {}
        func openScreenRecordingSettings() {}
        func openCameraSettings() {}
        func openMicrophoneSettings() {}

        func startScreenPolling() -> Task<Void, Never> {
            Task {}
        }

        func checkScreenStatusNow() {}
    }
#endif

#Preview("All set") {
    AllSetView(permissions: PreviewPermissionsServiceAllSet()) {}
}
