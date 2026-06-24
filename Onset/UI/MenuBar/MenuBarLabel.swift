import SwiftUI

// MARK: - MenuBarLabel

/// Reactive status-item label for the menu bar (#38).
///
/// Visual states driven by `RecordingCoordinator`:
/// - **Idle** — hollow circle `○`.
/// - **Recording / normal** — red filled circle `●` + elapsed timer (e.g. `04:17`).
/// - **Recording / degraded** — yellow filled circle `●` + warning triangle `⚠` + elapsed timer.
/// - **Recording / hard critical** — red filled octagon `⛔` + elapsed timer (spec: hard incident).
///
/// Reads `coordinator.phase`, `coordinator.recordingState`, `coordinator.elapsed`, and
/// `coordinator.liveCriticalView` (the de-escalating windowed-hard view); per-property `@Observable`
/// tracking fires only on those changes.
@MainActor
struct MenuBarLabel: View {
    // MARK: - Metrics

    private enum Metrics {
        /// Horizontal spacing between status-item elements (dot / warning / timer).
        static let elementSpacing: CGFloat = 4
    }

    let coordinator: RecordingCoordinator

    var body: some View {
        // Resolve once per render so body reads exactly the coordinator properties the mapper needs.
        let desc = MenuBarLabelMapper.descriptor(
            phase: self.coordinator.phase,
            recordingState: self.coordinator.recordingState,
            elapsed: self.coordinator.elapsed,
            liveCriticalView: self.coordinator.liveCriticalView
        )

        HStack(spacing: Metrics.elementSpacing) {
            Image(systemName: desc.dot.systemName)
                .foregroundStyle(desc.dot.color)

            if desc.dot.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.yellow)
            }

            if let elapsed = desc.elapsed {
                Text(ElapsedFormatter.string(from: elapsed))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(desc.accessibilityLabel)
    }
}
