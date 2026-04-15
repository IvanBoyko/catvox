import SwiftUI

/// Camera viewfinder with a 10-second recording countdown.
///
/// Lifecycle:
///   1. onAppear   → requests camera + mic permissions, starts AVCaptureSession
///   2. Tap record → 10-second countdown begins (progress ring + integer timer)
///   3. Progress reaches 1.0 → recording stops, temp file URL saved
///   4. captureState == .finished → fullScreenCover presents ResultView
///      (Phase 1: always uses mock data; Phase 2: passes real video URL)
///
/// Simulator note: no physical camera is available so the preview is black,
/// but the countdown and handoff simulation run identically to a real device.
///
/// See TRD §3.1 and §5.1.
struct RecordingView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var service       = CameraService()
    @State private var showResult    = false
    @State private var errorMessage  = ""
    @State private var showError     = false

    // Integer countdown derived from continuous progress (0 – 10).
    private var countdown: Int {
        max(0, 10 - Int(service.progress * CameraService.clipDuration))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Background ─────────────────────────────────────────────────
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: service.session)
                .ignoresSafeArea()

            // Show while camera is initialising or if permission is denied.
            if !service.isSessionReady || service.permissionDenied {
                cameraPlaceholder
            }

            // Vignette — darkens bottom half for control legibility.
            LinearGradient(
                stops: [
                    .init(color: .clear,                location: 0.0),
                    .init(color: .clear,                location: 0.42),
                    .init(color: .black.opacity(0.92),  location: 1.0),
                ],
                startPoint: .top,
                endPoint:   .bottom
            )
            .ignoresSafeArea()

            // ── Controls ────────────────────────────────────────────────────
            VStack(spacing: 0) {
                topBar
                Spacer()
                captureControl
                    .padding(.bottom, 60)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear  { service.requestPermissionsAndConfigure() }
        .onDisappear { service.stopSession() }
        .onChange(of: service.captureState) { _, state in
            switch state {
            case .finished(_):
                showResult = true
            case .failed(let msg):
                errorMessage = msg
                showError    = true
            default:
                break
            }
        }
        // When ResultView is dismissed, reset so the user can record again.
        .onChange(of: showResult) { _, showing in
            if !showing { service.reset() }
        }
        .fullScreenCover(isPresented: $showResult) {
            // Phase 1: always mock. Phase 2: pass recorded URL to the backend.
            ResultView(analysis: MockAnalysisService.sampleAnalysis)
        }
        .alert("Recording Failed", isPresented: $showError) {
            Button("Retry",  role: .none)   { service.reset() }
            Button("Cancel", role: .cancel) { dismiss() }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.80))
            }
            .padding(4)

            Spacer()

            // Recording indicator
            HStack(spacing: 7) {
                if isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .opacity(0.9)
                }
                Text(isRecording ? "REC" : "10 SEC")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
                    .tracking(2.5)
                    .animation(.default, value: isRecording)
            }

            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Capture control

    private var captureControl: some View {
        VStack(spacing: 18) {
            ZStack {
                // ── Track ring ──────────────────────────────────────────
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 4)

                // ── Progress fill ───────────────────────────────────────
                Circle()
                    .trim(from: 0, to: service.progress)
                    .stroke(
                        Color.red,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    // Linear so the ring speed perfectly matches real time.
                    .animation(.linear(duration: 0.05), value: service.progress)

                // ── Centre content ──────────────────────────────────────
                centreContent
            }
            .frame(width: 128, height: 128)

            Text(statusLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(2.2)
                .animation(.default, value: statusLabel)
        }
    }

    // The content inside the ring changes depending on capture state.
    @ViewBuilder
    private var centreContent: some View {
        switch service.captureState {

        case .idle:
            Button { service.startRecording() } label: {
                Circle()
                    .fill(Color.red)
                    .frame(width: 80, height: 80)
                    .shadow(color: .red.opacity(0.45), radius: 16, x: 0, y: 0)
            }
            .disabled(!service.isSessionReady)

        case .recording:
            Text("\(countdown)")
                .font(.system(size: 46, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.spring(response: 0.3, dampingFraction: 0.7),
                           value: countdown)

        case .finished(_), .failed(_):
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
        }
    }

    // MARK: - Camera placeholder

    private var cameraPlaceholder: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)

            VStack(spacing: 14) {
                Image(systemName: service.permissionDenied
                      ? "video.slash.fill" : "camera.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.white.opacity(0.16))

                Text(service.permissionDenied
                     ? "Camera Access\nDenied in Settings."
                     : "Initialising Camera...")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        if case .recording = service.captureState { return true }
        return false
    }

    private var statusLabel: String {
        switch service.captureState {
        case .idle:         return "TAP TO START"
        case .recording:    return "RECORDING"
        case .finished(_):  return "PROCESSING"
        case .failed(_):    return "FAILED"
        }
    }
}

#Preview {
    RecordingView()
}
