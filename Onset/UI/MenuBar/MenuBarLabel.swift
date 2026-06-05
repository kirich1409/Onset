import SwiftUI

// MARK: - MenuBarLabel

/// Reactive status-item label for the menu bar (#38).
///
/// Three visual states driven by `RecordingCoordinator`:
/// - **Idle** — hollow circle `○`.
/// - **Recording / normal** — red filled circle `●` + elapsed timer (e.g. `04:17`).
/// - **Recording / degraded** — yellow filled circle `●` + warning triangle `⚠` + elapsed timer.
///
/// Reads only `coordinator.phase`, `coordinator.recordingState`, and `coordinator.elapsed`
/// so the per-property `@Observable` tracking fires only on those changes.
@MainActor
struct MenuBarLabel: View {
    // MARK: - Metrics

    private enum Metrics {
        /// Horizontal spacing between status-item elements (dot / warning / timer).
        static let elementSpacing: CGFloat = 4
    }

    let coordinator: RecordingCoordinator

    var body: some View {
        // Resolve once per render so body reads exactly three coordinator properties.
        let desc = MenuBarLabelMapper.descriptor(
            phase: self.coordinator.phase,
            recordingState: self.coordinator.recordingState,
            elapsed: self.coordinator.elapsed
        )

        HStack(spacing: Metrics.elementSpacing) {
            Image(systemName: desc.dotSymbol)
                .foregroundStyle(self.dotColor(for: desc))

            if desc.showWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.yellow)
            }

            if let elapsed = desc.elapsed {
                Text(ElapsedFormatter.string(from: elapsed))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Private helpers

    private func dotColor(for desc: MenuBarLabelDescriptor) -> Color {
        guard desc.elapsed != nil else { return .primary }
        // elapsed non-nil ↔ recording phase; differentiate normal vs degraded by warning flag.
        return desc.showWarning ? .yellow : .red
    }
}
