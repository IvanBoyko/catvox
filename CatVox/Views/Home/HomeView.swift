import SwiftUI

struct HomeView: View {

    @State private var showRecording  = false
    @State private var showResult     = false
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

                // MARK: Primary CTA
                Button {
                    showRecording = true
                } label: {
                    Label("Start Scan", systemImage: "video.fill")
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

                Text("5 free scans remaining today")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 12)

                // MARK: Dev preview shortcut
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)

                VStack(spacing: 10) {
                    Text("DEV PREVIEW")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.25))
                        .tracking(2)

                    Picker("Persona", selection: $selectedSample) {
                        Text("Grumpy Boss").tag(0)
                        Text("Philosopher").tag(1)
                        Text("Chaotic Hunter").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)

                    Button("Preview Result") { showResult = true }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 2)
                }

                Spacer().frame(height: 56)
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showRecording) {
            RecordingView()
        }
        .fullScreenCover(isPresented: $showResult) {
            ResultView(analysis: MockAnalysisService.allSamples[selectedSample])
        }
    }
}

#Preview {
    HomeView()
}
