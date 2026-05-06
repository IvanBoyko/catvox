import SwiftUI

/// Glassmorphic card shown when the user has exhausted their daily free scan quota (HTTP 429).
/// Mirrors the visual style of UploadProgressView.
///
/// Actions:
///   "Upgrade to Pro"  — stub; shows a "Coming soon" alert (StoreKit 2 wiring in TRD §8).
///   "Maybe Later"     — calls onDismiss to close the Result screen.
struct QuotaExceededView: View {

    let onDismiss: () -> Void

    @State private var showComingSoon = false

    var body: some View {
        VStack(spacing: 20) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("quota.card")

            // ── Icon ──────────────────────────────────────────────────────
            ZStack {
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 52, height: 52)
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }

            // ── Text ──────────────────────────────────────────────────────
            VStack(spacing: 6) {
                Text("DAILY LIMIT REACHED")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(1.6)

                Text("You've used your 5 free scans today.")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Come back tomorrow for more.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            }

            // ── Actions ───────────────────────────────────────────────────
            VStack(spacing: 10) {
                Button {
                    AnalyticsService.capture(.upgradeToProTapped)
                    showComingSoon = true
                } label: {
                    Text("Upgrade to Pro")
                        .font(.subheadline.bold())
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            CatVoxTheme.brandGradient,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .accessibilityIdentifier("quota.upgradeButton")

                Button("Maybe Later", action: onDismiss)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("quota.maybeLaterButton")
            }
        }
        .padding(24)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .alert("Coming Soon", isPresented: $showComingSoon) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Pro tier with unlimited scans is coming soon. Stay tuned!")
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.07).ignoresSafeArea()
        QuotaExceededView { }
            .padding(24)
    }
    .preferredColorScheme(.dark)
}
