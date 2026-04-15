import SwiftUI

/// The centrepiece of the CatVox experience.
///
/// Layout (bottom-to-top):
///   1. Full-screen looping video (Phase 1: animated gradient placeholder)
///   2. Soft vignette gradient over the video
///   3. ThoughtBubbleView — springs in after a short delay
///   4. Bottom panel (PersonaBadge + ExpertInsightsDrawer + Share CTA)
///   5. Minimal top bar with a dismiss control
///
/// See TRD §5.1 and PROMPT.md §2 for the full specification.
struct ResultView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ResultViewModel

    init(analysis: CatAnalysis) {
        _viewModel = State(initialValue: ResultViewModel(analysis: analysis))
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── 1. Background ──────────────────────────────────────────────
            AnimatedVideoBackground(persona: viewModel.persona)
                .ignoresSafeArea()

            // ── 2. Vignette ────────────────────────────────────────────────
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.0),  location: 0.0),
                    .init(color: .black.opacity(0.15), location: 0.35),
                    .init(color: .black.opacity(0.82), location: 0.75),
                    .init(color: .black.opacity(0.95), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // ── 3 + 4 + 5. Content stack ───────────────────────────────────
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)

                Spacer()

                // Thought bubble springs in over the video
                if viewModel.thoughtBubbleVisible {
                    ThoughtBubbleView(
                        analysis: viewModel.analysis,
                        persona: viewModel.persona
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.82, anchor: .bottom)
                                       .combined(with: .opacity),
                            removal:   .opacity
                        )
                    )
                }

                // Bottom panel slides up
                if viewModel.panelVisible {
                    bottomPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { viewModel.onAppear() }
    }

    // MARK: - Subviews

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(4)

            Spacer()

            Text("CAT VOX")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(3)

            Spacer()

            // Mirror the close button width for visual balance
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 20)
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            PersonaBadgeView(
                emotion:    viewModel.analysis.primaryEmotion,
                persona:    viewModel.persona,
                confidence: viewModel.analysis.confidenceScore
            )

            ExpertInsightsDrawer(
                analysis:   viewModel.analysis,
                isExpanded: $viewModel.isInsightsExpanded
            )

            shareButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
    }

    private var shareButton: some View {
        ShareLink(
            item: viewModel.shareText,
            subject: Text("My cat's inner monologue"),
            message: Text(viewModel.shareText)
        ) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .fontWeight(.semibold)
                Text("Share to Story")
                    .fontWeight(.bold)
            }
            .font(.subheadline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        viewModel.persona.accentColor,
                        viewModel.persona.accentColor.opacity(0.78),
                    ],
                    startPoint: .leading,
                    endPoint:   .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }
}

// MARK: - Previews

#Preview("Grumpy Boss") {
    ResultView(analysis: MockAnalysisService.sampleAnalysis)
}

#Preview("Existential Philosopher") {
    ResultView(analysis: MockAnalysisService.allSamples[1])
}

#Preview("Chaotic Hunter") {
    ResultView(analysis: MockAnalysisService.allSamples[2])
}
