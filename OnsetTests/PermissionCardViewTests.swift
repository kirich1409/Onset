@testable import Onset
import Testing

// MARK: - PermissionCardView accessibility label tests

/// Tests for ``PermissionCardView/cardLabel(title:subtitle:status:)``.
@Suite("PermissionCardView — accessibilityCardLabel")
struct PermissionCardViewTests {
    // MARK: - Label composition

    @Test("required status — label contains title, subtitle, and status text")
    func cardLabel_required_containsTitleSubtitleStatus() {
        let label = PermissionCardView.cardLabel(
            title: "Камера",
            subtitle: "Logitech MX Brio",
            status: .required
        )
        #expect(label == "Камера. Logitech MX Brio. Требуется")
    }

    @Test("awaiting status — label contains title, subtitle, and status text")
    func cardLabel_awaiting_containsTitleSubtitleStatus() {
        let label = PermissionCardView.cardLabel(
            title: "Запись экрана",
            subtitle: "Ожидаем включения в Настройках.",
            status: .awaiting
        )
        #expect(label == "Запись экрана. Ожидаем включения в Настройках.. Ожидание")
    }

    @Test("denied status — label contains title, subtitle, and status text")
    func cardLabel_denied_containsTitleSubtitleStatus() {
        let label = PermissionCardView.cardLabel(
            title: "Микрофон",
            subtitle: "Для записи вашего голоса.",
            status: .denied
        )
        #expect(label == "Микрофон. Для записи вашего голоса.. Запрещён")
    }

    @Test("authorized status — label contains title, subtitle, and status text")
    func cardLabel_authorized_containsTitleSubtitleStatus() {
        let label = PermissionCardView.cardLabel(
            title: "Камера",
            subtitle: "Logitech MX Brio",
            status: .authorized
        )
        #expect(label == "Камера. Logitech MX Brio. Выдано")
    }

    @Test("subtitle is not omitted from label — regression for issue #127")
    func cardLabel_subtitleIncluded_notEmptyAfterTitle() {
        let subtitle = "Имя устройства"
        let label = PermissionCardView.cardLabel(
            title: "Камера",
            subtitle: subtitle,
            status: .required
        )
        #expect(label.contains(subtitle))
    }
}
