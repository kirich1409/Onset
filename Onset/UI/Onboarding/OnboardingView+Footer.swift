import SwiftUI

// MARK: - Footer sub-views

/// Footer section (progress bar + graceful buttons) extracted to keep `OnboardingView`
/// struct body under the `type_body_length` lint limit.
extension OnboardingView {
    // MARK: - Footer container

    var footerSection: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.footerTextSpacing) {
                self.progressBar
                HStack(spacing: Metrics.footerTextSpacing) {
                    Text("\(viewModel.progress) из 3")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.progressHintText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: Metrics.footerHSpacing)

            self.footerButtons
        }
        .padding(Metrics.contentPadding)
    }

    // MARK: - Progress bar

    var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Metrics.progressBarCornerRadius)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: Metrics.progressBarHeight)
                RoundedRectangle(cornerRadius: Metrics.progressBarCornerRadius)
                    .fill(Color.accentColor)
                    .frame(
                        width: proxy.size.width * self.progressFraction,
                        height: Metrics.progressBarHeight
                    )
                    .animation(.easeInOut, value: viewModel.progress)
            }
        }
        .frame(height: Metrics.progressBarHeight)
        .accessibilityLabel("Прогресс: \(viewModel.progress) из 3 разрешений выдано")
        .accessibilityValue("\(viewModel.progress) из 3")
    }

    var progressFraction: CGFloat {
        guard viewModel.progress > 0 else { return 0 }
        return CGFloat(viewModel.progress) / Metrics.progressTotalCount
    }

    // MARK: - Footer buttons

    /// Computes the footer descriptor for the current VM state.
    var footerDescriptor: OnboardingFooterDescriptor {
        OnboardingFooterMapper.descriptor(
            isAwaiting: viewModel.isAwaitingScreen,
            effective: viewModel.effectivePermissions
        )
    }

    /// Renders the footer button row from the ``OnboardingFooterDescriptor``.
    ///
    /// Exactly one primary button is always shown; an optional graceful link appears to
    /// its left. The mapper guarantees no two enabled buttons share the same action,
    /// so duplicate-action buttons are structurally impossible.
    var footerButtons: some View {
        HStack(spacing: Metrics.footerHSpacing) {
            let descriptor = self.footerDescriptor
            if let link = descriptor.gracefulLink {
                Button(link.label) {
                    self.perform(link.action)
                }
                .buttonStyle(.plain)
                .foregroundStyle(link.action == .proceed ? Color.accentColor : Color.secondary)
            }
            self.primaryButton(descriptor.primary)
        }
    }

    /// Renders the primary button, applying the correct button style per action.
    ///
    /// `buttonStyle` is a generic modifier — the style is fixed at compile time and cannot
    /// be selected via a runtime conditional on a single button instance. Two branches are
    /// used instead to keep the style statically typed.
    @ViewBuilder
    private func primaryButton(_ primary: OnboardingFooterDescriptor.PrimaryButton) -> some View {
        if primary.action == .recheck {
            Button(primary.label) {
                self.perform(primary.action)
            }
            .buttonStyle(.bordered)
            .disabled(!primary.isEnabled)
        } else {
            Button(primary.label) {
                self.perform(primary.action)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!primary.isEnabled)
        }
    }

    /// Dispatches a footer action to the correct handler.
    private func perform(_ action: OnboardingFooterDescriptor.Action) {
        switch action {
        case .proceed:
            onProceedToMain()

        case .recheck:
            viewModel.checkNow()
        }
    }
}
