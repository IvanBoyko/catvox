import SwiftUI
import AVFoundation

/// Full-screen live viewfinder backed by AVCaptureVideoPreviewLayer.
///
/// The trick is overriding `layerClass` so UIKit automatically creates an
/// AVCaptureVideoPreviewLayer as the view's backing layer — no manual layer
/// management required.
///
/// Required by TRD §3.1 and §5.1 (Recording Screen viewfinder).
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session      = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    // MARK: - Backing UIView

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe: layerClass guarantees this cast.
            layer as! AVCaptureVideoPreviewLayer  // swiftlint:disable:this force_cast
        }
    }
}
