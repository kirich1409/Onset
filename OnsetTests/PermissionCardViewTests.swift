@testable import Onset
import Testing

// MARK: - PermissionCardView accessibility label tests

/// Tests for ``PermissionCardView/cardLabel(title:subtitle:status:)``.
@Suite("PermissionCardView — accessibilityCardLabel")
struct PermissionCardViewTests {
    // MARK: - Label composition

    @Test("required status — trailing period in subtitle produces single stop")
    func cardLabel_required_trailingPeriodNormalized() {
        let label = PermissionCardView.cardLabel(
            title: "Камера",
            subtitle: "Logitech MX Brio.",
            status: .required
        )
        #expect(label == "Камера. Logitech MX Brio. Требуется")
    }

    @Test("awaiting status — trailing period in subtitle produces single stop")
    func cardLabel_awaiting_trailingPeriodNormalized() {
        let label = PermissionCardView.cardLabel(
            title: "Запись экрана",
            subtitle: "Ожидаем включения в Настройках.",
            status: .awaiting
        )
        #expect(label == "Запись экрана. Ожидаем включения в Настройках. Ожидание")
    }

    @Test("denied status — trailing period in subtitle produces single stop")
    func cardLabel_denied_trailingPeriodNormalized() {
        let label = PermissionCardView.cardLabel(
            title: "Микрофон",
            subtitle: "Для записи вашего голоса.",
            status: .denied
        )
        #expect(label == "Микрофон. Для записи вашего голоса. Запрещён")
    }

    @Test("authorized status — subtitle without trailing period is unchanged")
    func cardLabel_authorized_noTrailingPeriodUnchanged() {
        let label = PermissionCardView.cardLabel(
            title: "Камера",
            subtitle: "Logitech MX Brio",
            status: .authorized
        )
        #expect(label == "Камера. Logitech MX Brio. Выдано")
    }

    @Test("empty subtitle — status appended directly to title without stray separator")
    func cardLabel_emptySubtitle_noStrayPeriod() {
        let label = PermissionCardView.cardLabel(
            title: "Камера",
            subtitle: "",
            status: .required
        )
        #expect(label == "Камера. Требуется")
    }

    @Test("subtitle is included in label — regression for issue #127")
    func cardLabel_subtitleIncluded_notEmptyAfterTitle() {
        let label = PermissionCardView.cardLabel(
            title: "Камера",
            subtitle: "Имя устройства",
            status: .required
        )
        #expect(label == "Камера. Имя устройства. Требуется")
    }
}
