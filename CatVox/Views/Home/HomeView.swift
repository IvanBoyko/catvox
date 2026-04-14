import SwiftUI

/// Placeholder home screen.
///
/// Phase 2 will add: latest mood card, credit counter, and
/// a navigation push to RecordingView.
/// For now this provides a quick launchpad into the ResultView preview.
struct HomeView: View {

    @State private var showResult = false
    @State private var selectedSample = 0

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.07).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // MARK: Logo
                VStack(spacing: 10) {
                    Text("🐱")
                        .font(.system(size: 72))

                    Text("CatVox")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Text("Powered by Kathelix")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(2)
                }

                Spacer()

                // MARK: Sample picker (dev convenience)
                VStack(spacing: 8) {
                    Text("Preview mock persona:")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))

                    Picker("Persona", selection: $selectedSample) {
                        Text("Grumpy Boss").tag(0)
                        Text("Philosopher").tag(1)
                        Text("Chaotic Hunter").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 20)

                // MARK: CTA
                Button {
                    showResult = true
                } label: {
                    Label("Preview Result Screen", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(
                            Color(red: 0.90, green: 0.22, blue: 0.22),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .padding(.horizontal, 24)

                Text("2 free scans remaining today")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 12)

                Spacer().frame(height: 56)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showResult) {
            ResultView(analysis: MockAnalysisService.allSamples[selectedSample])
        }
    }
}

#Preview {
    HomeView()
}
