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

                Text(persona.displayName.uppercased())
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
                .accessibilityIdentifier("result.catThoughtText")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        // Frosted glass backing
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        // Subtle 1px white border (spec: TRD §5.1 / PROMPT.md §3)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
        // Soft glow — provides depth without a visible drop shadow on the card face
        .shadow(color: persona.accentColor.opacity(0.30), radius: 22, x: 0, y: 10)
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
