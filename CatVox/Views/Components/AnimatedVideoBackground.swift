import SwiftUI

/// Phase-1 placeholder for the full-screen looping video.
///
/// Renders three organic colour blobs that drift slowly across a dark
/// background, giving the impression of a moody bokeh cat video.
/// Replace with an `AVPlayerLayer`-backed `UIViewRepresentable` in Phase 2
/// once the camera recording pipeline is in place.
struct AnimatedVideoBackground: View {

    let persona: CatPersona

    @State private var animating = false

    // (offsetWhenFalse, offsetWhenTrue, diameter)
    private let blobs: [(CGSize, CGSize, CGFloat)] = [
        (CGSize(width: -80, height: -180), CGSize(width:  70, height:  90), 340),
        (CGSize(width: 110, height:  60),  CGSize(width: -100, height: -120), 280),
        (CGSize(width: -30, height: 190),  CGSize(width:  50, height: -170), 260),
    ]

    private let durations: [Double] = [8.5, 10.0, 7.0]

    var body: some View {
        ZStack {
            // Near-black base — feels like a dimly lit room
            Color(red: 0.04, green: 0.04, blue: 0.07)

            ForEach(blobs.indices, id: \.self) { i in
                let (offA, offB, size) = blobs[i]

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [persona.accentColor.opacity(0.38), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: size / 2
                        )
                    )
                    .frame(width: size, height: size)
                    .blur(radius: 50)
                    .offset(animating ? offB : offA)
                    .animation(
                        .easeInOut(duration: durations[i])
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 1.2),
                        value: animating
                    )
            }

            // Subtle film-grain feel via a very faint noise overlay
            Rectangle()
                .fill(.black.opacity(0.12))
        }
        .onAppear { animating = true }
    }
}

#Preview("Grumpy Boss") {
    AnimatedVideoBackground(persona: .grumpyBoss)
        .ignoresSafeArea()
}

#Preview("Secret Agent") {
    AnimatedVideoBackground(persona: .secretAgent)
        .ignoresSafeArea()
}
