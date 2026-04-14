import SwiftUI

/// The central glassmorphic card — the "magic reveal" moment described
/// in PROMPT.md §2.  Shows the persona badge and the AI-generated
/// first-person cat monologue.
struct ThoughtBubbleView: View {

    let analysis: CatAnalysis
    let persona:  CatPersona

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // MARK: Persona chip
            HStack(spacing: 7) {
                Text(persona.emoji)
                    .font(.callout)

                Text(persona.rawValue.uppercased())
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(persona.accentColor)
                    .tracking(2.0)
            }

            // MARK: Cat monologue
            Text("\u{201C}\(analysis.catThought)\u{201D}")
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        // Frosted glass backing
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        // Gradient border — accent bleeds from top-left, fades to subtle white
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            persona.accentColor.opacity(0.75),
                            .white.opacity(0.08),
                            persona.accentColor.opacity(0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        // Soft glow behind the card
        .shadow(color: persona.accentColor.opacity(0.25), radius: 20, x: 0, y: 8)
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.07).ignoresSafeArea()
        ThoughtBubbleView(analysis: MockAnalysisService.sampleAnalysis,
                          persona: .grumpyBoss)
            .padding(24)
    }
    .preferredColorScheme(.dark)
}
