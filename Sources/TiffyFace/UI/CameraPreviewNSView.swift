import AVFoundation
import AppKit
import SwiftUI

/// Hardware-accelerated `AVCaptureVideoPreviewLayer` wrapper for Enrollment & Live Face Lab.
public struct CameraPreviewNSView: NSViewRepresentable {
    public let session: AVCaptureSession

    public init(session: AVCaptureSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateNSView(_ nsView: PreviewHostView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        nsView.updateMirroring()
    }

    public final class PreviewHostView: NSView {
        public let previewLayer = AVCaptureVideoPreviewLayer()

        public override init(frame frameRect: NSRect) {
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

        public override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            updateMirroring()
        }

        public func updateMirroring() {
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}
