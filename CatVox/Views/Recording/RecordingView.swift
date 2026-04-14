import SwiftUI

/// Phase 2 stub — will be implemented with AVFoundation.
///
/// Final feature set per TRD §3.1:
///   - AVCaptureSession viewfinder
///   - Fixed 10-second recording window
///   - Circular countdown progress ring
///   - Automatic upload trigger on completion
struct RecordingView: View {

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "video.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.25))

                Text("Camera — Phase 2")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    RecordingView()
}
