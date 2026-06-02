import SwiftUI

// MARK: - Card status

/// The displayable status of a single permission card.
enum PermissionCardStatus {
    /// The user has not been asked for this permission yet.
    case required
    /// Requested / polling in-flight — "Ожидание…".
    case awaiting
    /// Explicitly denied or restricted — "Запрещён".
    case denied
    /// Fully granted — checkmark.
    case authorized
}

// MARK: - PermissionCardActionButton

/// Describes an action button displayed in a `PermissionCardView`.
struct PermissionCardActionButton {
    let label: String
    let action: () -> Void
    let style: Style

    enum Style {
        case primary // blue filled
        case secondary // outlined / tinted
    }
}

// MARK: - PermissionCardView

/// A reusable permission card matching the mockup design.
///
/// Renders a coloured-tile SF Symbol icon, title, subtitle (device name or static copy),
/// a trailing status chip, and an optional action button. An expandable numbered
/// instructions block (1-2-3) is toggled via `showInstructions`.
///
/// Status is conveyed by **text + icon**, never by color alone (a11y AC per product overview #13).
struct PermissionCardView: View {
    // MARK: - Metrics

    private enum Metrics {
        static let iconSize: CGFloat = 36
        static let iconCornerRadius: CGFloat = 8
        static let cardCornerRadius: CGFloat = 12
        static let cardPadding: CGFloat = 12
        static let iconSymbolSize: CGFloat = 18
        static let instructionNumberSize: CGFloat = 22
        static let instructionSpacing: CGFloat = 8
        static let dividerTopPadding: CGFloat = 8
        static let titleSpacing: CGFloat = 2
        static let chipSpacing: CGFloat = 4
        static let subtitleLineLimit = 2
    }

    // MARK: - Inputs

    let iconSymbol: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let status: PermissionCardStatus
    let actionButton: PermissionCardActionButton?
    let instructions: [String]?
    /// Optional uppercase caption shown above the instruction steps.
    let instructionsHeader: String?

    @Binding var showInstructions: Bool

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Metrics.cardPadding) {
                // Card info combined into a single accessibility element so VoiceOver
                // reads icon + title + subtitle + chip as one unit.
                HStack(alignment: .center, spacing: Metrics.cardPadding) {
                    self.iconTile
                    self.titleAndSubtitle
                    Spacer(minLength: 0)
                    self.statusChip
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(self.accessibilityCardLabel)

                // Action button stays as a sibling — independently focusable in VoiceOver.
                if let button = actionButton {
                    self.actionButtonView(button)
                }
            }
            .padding(Metrics.cardPadding)
            .contentShape(Rectangle())

            self.instructionsSection
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
    }

    @ViewBuilder
    private var instructionsSection: some View {
        if let steps = instructions, showInstructions {
            Divider()
                .padding(.top, Metrics.dividerTopPadding)
            if let header = instructionsHeader {
                Text(header)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.top, Metrics.instructionSpacing)
            }
            self.instructionsList(steps)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.bottom, Metrics.cardPadding)
        }
    }

    // MARK: - Sub-views

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.iconCornerRadius)
                .fill(self.iconColor)
                .frame(width: Metrics.iconSize, height: Metrics.iconSize)
            Image(systemName: self.iconSymbol)
                .font(.system(size: Metrics.iconSymbolSize, weight: .medium))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var titleAndSubtitle: some View {
        VStack(alignment: .leading, spacing: Metrics.titleSpacing) {
            Text(self.title)
                .font(.body)
                .fontWeight(.semibold)
            if !self.subtitle.isEmpty {
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(Metrics.subtitleLineLimit)
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch self.status {
        case .required:
            Text("Требуется")
                .chipStyle(.secondary)

        case .awaiting:
            HStack(spacing: Metrics.chipSpacing) {
                ProgressView()
                    .controlSize(.mini)
                Text("Ожидание…")
            }
            .chipStyle(.secondary)

        case .denied:
            HStack(spacing: Metrics.chipSpacing) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Запрещён")
                    .foregroundStyle(.red)
            }
            .chipStyle(.destructive)

        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
                .accessibilityLabel("Выдано")
        }
    }

    @ViewBuilder
    private func actionButtonView(_ button: PermissionCardActionButton) -> some View {
        switch button.style {
        case .primary:
            Button(button.label, action: button.action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

        case .secondary:
            Button(button.label, action: button.action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func instructionsList(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.instructionSpacing) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: Metrics.instructionSpacing) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(
                                width: Metrics.instructionNumberSize,
                                height: Metrics.instructionNumberSize
                            )
                        Text("\(index + 1)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                    Text(.init(step)) // AttributedString from markdown so **bold** renders
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, Metrics.instructionSpacing)
    }

    // MARK: - Accessibility

    private var accessibilityCardLabel: String {
        let statusText = switch self.status {
        case .required: "Требуется"
        case .awaiting: "Ожидание"
        case .denied: "Запрещён"
        case .authorized: "Выдано"
        }
        return "\(self.title): \(statusText)"
    }
}

// MARK: - Chip modifier

struct PermissionChipModifier: ViewModifier {
    enum ChipStyle { case secondary, destructive }

    private enum Metrics {
        static let hPadding: CGFloat = 8
        static let vPadding: CGFloat = 4
        static let cornerRadius: CGFloat = 6
        static let destructiveFillOpacity: CGFloat = 0.12
    }

    let style: ChipStyle

    func body(content: Content) -> some View {
        content
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, Metrics.hPadding)
            .padding(.vertical, Metrics.vPadding)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                    .fill(self.chipBackground)
            )
            .foregroundStyle(self.chipForeground)
    }

    private var chipBackground: Color {
        switch self.style {
        case .secondary:
            Color(nsColor: .quaternaryLabelColor)

        case .destructive:
            Color.red.opacity(Metrics.destructiveFillOpacity)
        }
    }

    private var chipForeground: Color {
        switch self.style {
        case .secondary:
            Color(nsColor: .secondaryLabelColor)

        case .destructive:
            .red
        }
    }
}

extension View {
    func chipStyle(_ style: PermissionChipModifier.ChipStyle) -> some View {
        modifier(PermissionChipModifier(style: style))
    }
}

// MARK: - Previews

#Preview("Required", traits: .fixedLayout(width: 440, height: 80)) {
    PermissionCardView(
        iconSymbol: "display",
        iconColor: .purple,
        title: "Запись экрана",
        subtitle: "Чтобы захватывать ваш дисплей.",
        status: .required,
        actionButton: .init(label: "Открыть настройки", action: {}, style: .secondary),
        instructions: nil,
        instructionsHeader: nil,
        showInstructions: .constant(false)
    )
    .padding()
}

#Preview("Awaiting + instructions", traits: .fixedLayout(width: 440, height: 220)) {
    PermissionCardView(
        iconSymbol: "display",
        iconColor: .purple,
        title: "Запись экрана",
        subtitle: "Ожидаем включения в Системных настройках.",
        status: .awaiting,
        actionButton: nil,
        instructions: [
            "Открыт раздел **Конфиденциальность → Запись экрана**.",
            "Включите переключатель напротив **Onset** в списке приложений.",
            "Можно не возвращаться вручную — статус обновится сам.",
        ],
        instructionsHeader: "ЖДЁМ РАЗРЕШЕНИЕ",
        showInstructions: .constant(true)
    )
    .padding()
}

#Preview("Denied — camera (camera/mic keep real denied state)", traits: .fixedLayout(width: 440, height: 80)) {
    PermissionCardView(
        iconSymbol: "camera.fill",
        iconColor: Color(nsColor: .systemGray),
        title: "Камера",
        subtitle: "Доступ запрещён. Откройте настройки.",
        status: .denied,
        actionButton: .init(label: "Открыть настройки", action: {}, style: .secondary),
        instructions: nil,
        instructionsHeader: nil,
        showInstructions: .constant(false)
    )
    .padding()
}

#Preview("Authorized", traits: .fixedLayout(width: 440, height: 80)) {
    // Preview teal color components — not reused elsewhere so inline is acceptable.
    let previewTeal = Color(red: 0.2, green: 0.7, blue: 0.7)
    return PermissionCardView(
        iconSymbol: "camera.fill",
        iconColor: previewTeal,
        title: "Камера",
        subtitle: "Logitech MX Brio.",
        status: .authorized,
        actionButton: nil,
        instructions: nil,
        instructionsHeader: nil,
        showInstructions: .constant(false)
    )
    .padding()
}
