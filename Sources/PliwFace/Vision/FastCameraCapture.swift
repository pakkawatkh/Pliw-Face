import AVFoundation
import CoreVideo
import Foundation

public enum CameraAccessState: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied

    public var isAuthorized: Bool { self == .authorized }
}

/// Low-latency, 640×480 fast-start camera capture controller.
/// Completely tears down the AVCaptureSession when idle so background CPU and camera LED usage stay strictly zero.
public final class FastCameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.local.pliw-face.camera.session", qos: .userInteractive)
    private let frameQueue = DispatchQueue(label: "com.local.pliw-face.camera.frames", qos: .userInteractive)

    private var isConfigured = false
    private let callbackLock = NSLock()
    private var frameHandler: ((CVPixelBuffer, TimeInterval) -> Void)?

    public nonisolated static func authorizationState() -> CameraAccessState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    public nonisolated static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public func start(
        onFrame: @escaping (CVPixelBuffer, TimeInterval) -> Void,
        onError: ((String) -> Void)? = nil
    ) {
        callbackLock.lock()
        frameHandler = onFrame
        callbackLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                if let errorMsg = self.configureSessionLocked() {
                    onError?(errorMsg)
                    return
                }
            }
            if self.isConfigured && !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    public func stop() {
        callbackLock.lock()
        frameHandler = nil
        callbackLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureSessionLocked() -> String? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 640×480 transfers 4–9× fewer pixels than 1080p/720p while exceeding 112×112 ArcFace input needs
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            return "No webcam found on this Mac."
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            return "Unable to open camera: \(error.localizedDescription)"
        }

        guard session.canAddInput(input) else {
            return "Unable to attach camera input."
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(output) else {
            return "Unable to attach camera video output."
        }
        session.addOutput(output)
        isConfigured = true
        return nil
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        callbackLock.lock()
        let handler = frameHandler
        callbackLock.unlock()
        guard let handler else { return }

        let timestamp = ProcessInfo.processInfo.systemUptime
        handler(pixelBuffer, timestamp)
    }
}
