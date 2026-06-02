import os
import ScreenCaptureKit
import SwiftUI

// MARK: - Diagnostic view

/// Diagnostic view for the screen-recording permission spike.
///
/// Polls both TCC signals every ``DiagnosticView/pollInterval`` seconds so that
/// live grant / revoke events are observable without restarting the app.
/// The tick counter makes it visually obvious the loop is running.
struct DiagnosticView: View {

    // MARK: - Poll interval

    /// 1-second refresh interval. Named constant to satisfy `no_magic_numbers`.
    private static let pollInterval: Duration = .seconds(1)

    // MARK: - State

    @State private var preflightResult: Bool = false
    @State private var shareableContentResult: Bool = false
    @State private var tickCount: UInt64 = 0
    @State private var accessRequestFired: Bool = false

    private let probe = ScreenRecordingProbe()

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Screen Recording Permission Probe")
                .font(.headline)

            Divider()

            // Signals
            LabeledContent("CGPreflightScreenCaptureAccess()") {
                self.signalBadge(self.preflightResult)
            }
            LabeledContent("SCShareableContent displays available") {
                self.signalBadge(self.shareableContentResult)
            }

            Divider()

            // Tick counter to confirm live refresh
            LabeledContent("Poll tick") {
                Text("\(self.tickCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Bundle identity
            LabeledContent("Bundle path") {
                Text(Bundle.main.bundlePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Divider()

            // One-shot access request button
            Button(self.accessRequestFired ? "Access request already sent" : "Request access (one-shot)") {
                guard !self.accessRequestFired else { return }
                self.accessRequestFired = true
                self.probe.requestAccess()
            }
            .disabled(self.accessRequestFired)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280)
        .task {
            await self.runPollingLoop()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func signalBadge(_ value: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(value ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(value ? "true" : "false")
                .monospacedDigit()
                .foregroundStyle(value ? .primary : .secondary)
        }
    }

    // MARK: - Polling

    private func runPollingLoop() async {
        while !Task.isCancelled {
            // Re-invoke both APIs fresh on every tick — the whole point of the spike
            // is to observe the exact tick when a live grant becomes visible.
            self.preflightResult = self.probe.preflight()
            self.shareableContentResult = await self.probe.hasDisplaysViaShareableContent()
            self.tickCount &+= 1

            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                // CancellationError from Task.sleep — exit cleanly.
                break
            }
        }
    }
}

#Preview {
    DiagnosticView()
}
