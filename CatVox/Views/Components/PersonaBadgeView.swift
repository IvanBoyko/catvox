import SwiftUI

/// Compact pill showing the detected emotion label and an animated
/// confidence-score arc.  Lives at the top of the bottom panel in ResultView.
struct PersonaBadgeView: View {

    let emotion:    String
    let persona:    CatPersona
    let confidence: Double          // 0.0 – 1.0

    @State private var arcProgress: Double = 0

    var body: some View {
        HStack(spacing: 14) {

            // MARK: Emotion label
            VStack(alignment: .leading, spacing: 3) {
                Text("PRIMARY EMOTION")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(1.4)

                Text(emotion)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }

            Spacer()

            // MARK: Confidence arc
            ZStack {
                // Track
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 3.5)

                // Fill
                Circle()
                    .trim(from: 0, to: arcProgress)
                    .stroke(
                        persona.accentColor,
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Percentage label
                Text("\(Int(confidence * 100))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .onAppear {
            withAnimation(.spring(duration: 1.1, bounce: 0.15).delay(0.9)) {
                arcProgress = confidence
            }
        }
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.07).ignoresSafeArea()
        PersonaBadgeView(emotion: "Territorial Alertness",
                         persona: .grumpyBoss,
                         confidence: 0.87)
            .padding()
    }
    .preferredColorScheme(.dark)
}
