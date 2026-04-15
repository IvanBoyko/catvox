import AudioToolbox
import AVFoundation
import Observation
import UIKit

/// Manages the full AVCaptureSession lifecycle for a fixed 10-second recording.
///
/// Design notes:
///   - CameraService is @Observable but must NOT subclass NSObject.
///     The AVFoundation delegate + CADisplayLink target are handled by
///     CaptureDelegate, a private NSObject shim stored as a `let` constant
///     (not `lazy var`, which conflicts with @Observable init-accessors).
///   - Owner reference is set post-init to break the circular init dependency.
///
/// Phase 2: replace the local-file handoff with a Cloud Storage upload.
@Observable
final class CameraService {

    // MARK: - State machine

    enum CaptureState: Equatable {
        case idle
        case recording
        case finished(URL)
        case failed(String)

        static func == (lhs: CaptureState, rhs: CaptureState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.recording, .recording): return true
            case let (.finished(a), .finished(b)):         return a == b
            case let (.failed(a),   .failed(b)):           return a == b
            default:                                       return false
            }
        }
    }

    // MARK: - Observable properties

    private(set) var captureState:    CaptureState = .idle
    private(set) var progress:        Double = 0       // 0.0 – 1.0
    private(set) var isSessionReady:  Bool   = false
    private(set) var permissionDenied: Bool  = false

    // MARK: - AVFoundation (not Observable — structural, not UI-state)

    /// Exposed so CameraPreviewView can attach its preview layer.
    let session      = AVCaptureSession()
    private let fileOutput   = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.kathelix.catvox.session",
                                             qos: .userInitiated)

    // MARK: - Countdown

    /// Fixed clip length per TRD §3.1.
    static let clipDuration: TimeInterval = 10

    private var displayLink: CADisplayLink?
    private var startTime:   CFTimeInterval = 0


    /// NSObject delegate shim stored as `let` (not lazy) to avoid
    /// the @Observable init-accessor conflict with lazy stored properties.
    private let captureDelegate: CaptureDelegate

    // MARK: - Init

    init() {
        // Phase 1: captureDelegate is the only stored property without a
        // default — initialise it first so Phase 1 is complete.
        captureDelegate = CaptureDelegate()
        // Phase 2: self is now fully initialised; safe to pass self.
        captureDelegate.owner = self
    }

    // MARK: - Setup

    func requestPermissionsAndConfigure() {
        // Simulator has no physical camera; mark ready so controls activate.
        #if targetEnvironment(simulator)
        DispatchQueue.main.async { self.isSessionReady = true }
        return
        #endif

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async {
                    self.configureSession()
                    // configureSession() has returned, so defer has fired and
                    // commitConfiguration() is complete. Safe to start now.
                    self.session.startRunning()
                    DispatchQueue.main.async { self.isSessionReady = true }
                }
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        // Video
        guard
            let cam     = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back),
            let videoIn = try? AVCaptureDeviceInput(device: cam),
            session.canAddInput(videoIn)
        else { return }
        session.addInput(videoIn)

        // Audio (best-effort)
        if let mic     = AVCaptureDevice.default(for: .audio),
           let audioIn = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioIn) {
            session.addInput(audioIn)
        }

        // File output
        guard session.canAddOutput(fileOutput) else { return }
        session.addOutput(fileOutput)
        // startRunning() is intentionally NOT called here.
        // The defer above commits the configuration when this function returns;
        // startRunning() must only be called after commitConfiguration() completes.
    }

    func stopSession() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    // MARK: - Recording

    func startRecording() {
        guard case .idle = captureState else { return }
        captureState = .recording
        progress     = 0
        startTime    = CACurrentMediaTime()

        #if targetEnvironment(simulator)
        attachDisplayLink()           // Simulated countdown, no real file
        #else
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        fileOutput.startRecording(to: url, recordingDelegate: captureDelegate)
        attachDisplayLink()
        #endif
    }

    private func attachDisplayLink() {
        let link = CADisplayLink(target: captureDelegate,
                                 selector: #selector(CaptureDelegate.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: - Internal callbacks from CaptureDelegate

    fileprivate func handleTick() {
        let elapsed = CACurrentMediaTime() - startTime
        progress = min(elapsed / Self.clipDuration, 1.0)

        guard progress >= 1.0 else { return }

        displayLink?.invalidate()
        displayLink = nil

        // TRD §3.1 — high-intensity haptic buzz + ping at exactly 10 s.
        //
        // Generator is created inline, NOT stored across the 10-second recording.
        // UIFeedbackGenerator.prepare() has a short expiry window (~2-3 s); a
        // generator prepared at startRecording() has long since returned to idle
        // by the time this fires, silently dropping the haptic request.
        // Creating it fresh here fires immediately without a prepare() window.
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        #if targetEnvironment(simulator)
        AudioServicesPlaySystemSound(1117)
        let stubURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("catvox_mock.mov")
        captureState = .finished(stubURL)
        #else
        fileOutput.stopRecording()          // releases audio session lock
        AudioServicesPlaySystemSound(1117)  // audible ping (ID 1117 — Alert tone)
        #endif
    }

    fileprivate func handleRecordingFinished(url: URL, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let error {
                captureState = .failed(error.localizedDescription)
            } else {
                captureState = .finished(url)
            }
        }
    }

    // MARK: - Reset

    /// Returns to `.idle` so the user can record again without
    /// dismissing RecordingView.
    func reset() {
        captureState = .idle
        progress     = 0
    }
}

// MARK: - CaptureDelegate (private NSObject shim)

/// Isolated NSObject that acts as AVFoundation delegate and CADisplayLink
/// target.  Holds a weak back-reference to CameraService so ARC doesn't
/// create a retain cycle, and the reference is set post-init to avoid
/// a circular initialisation dependency.
private final class CaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {

    weak var owner: CameraService?

    @objc func tick() { owner?.handleTick() }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo url: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        owner?.handleRecordingFinished(url: url, error: error)
    }
}
