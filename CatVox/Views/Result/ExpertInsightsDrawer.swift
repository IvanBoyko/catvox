import SwiftUI

/// Collapsible glassmorphic drawer that reveals the behaviour analysis
/// and owner tip.  Tap the header to expand/collapse with a spring animation.
struct ExpertInsightsDrawer: View {

    let analysis:   CatAnalysis
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Toggle header
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.white.opacity(0.75))
                        .font(.subheadline)

                    Text("Expert Insights")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    Spacer()

                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white.opacity(0.55))
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                        .animation(.spring(response: 0.3, dampingFraction: 0.7),
                                   value: isExpanded)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // MARK: Expanded content
            if isExpanded {
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 16) {
                    InsightRow(icon: "waveform.path.ecg",
                               title: "Behavioural Analysis",
                               text: analysis.analysis)

                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)

                    InsightRow(icon: "lightbulb.fill",
                               title: "Owner Tip",
                               text: analysis.ownerTip)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.11), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - InsightRow

private struct InsightRow: View {

    let icon:  String
    let title: String
    let text:  String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(1.4)

                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.07).ignoresSafeArea()
        ExpertInsightsDrawer(analysis: MockAnalysisService.sampleAnalysis,
                             isExpanded: .constant(true))
            .padding(24)
    }
    .preferredColorScheme(.dark)
}
