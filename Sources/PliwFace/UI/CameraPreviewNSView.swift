import AVFoundation
import AppKit
import SwiftUI

/// Hardware-accelerated `AVCaptureVideoPreviewLayer` wrapper for Enrollment & Live Face Lab.
/// Forces deterministic selfie mirroring via SwiftUI center-anchored horizontal flip while
/// disabling inconsistent AVFoundation per-camera auto-mirroring.
public struct CameraPreviewNSView: View {
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public var body: some View {
        RawCameraPreviewRepresentable(session: session)
            .scaleEffect(x: -1, y: 1)
    }
}

private struct RawCameraPreviewRepresentable: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        nsView.disableConnectionMirroring()
    }

    final class PreviewHostView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Layer-hosting order in AppKit: assign `layer` BEFORE setting `wantsLayer = true`
            layer = previewLayer
            wantsLayer = true
            previewLayer.frame = bounds
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            disableConnectionMirroring()
        }

        func disableConnectionMirroring() {
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
    }
}
