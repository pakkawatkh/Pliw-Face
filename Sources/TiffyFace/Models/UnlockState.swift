import Foundation

public enum UnlockPhase: Equatable, Sendable {
    case idle
    case warmingCamera
    case scanning
    case unlocked(identityName: String, latencyMs: Int)
    case rejected(String)
    case failed(String)

    public var isScanning: Bool {
        switch self {
        case .warmingCamera, .scanning:
            return true
        default:
            return false
        }
    }
}

public enum LivenessVerdict: Equatable, Sendable {
    case pending
    case live(reason: String)
    case spoofDetected(reason: String)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    public var isSpoof: Bool {
        if case .spoofDetected = self { return true }
        return false
    }
}

public struct ScanTelemetry: Equatable, Sendable {
    public var engineName: String
    public var faceDetected: Bool
    public var faceQuality: Float
    public var bestIdentityName: String?
    public var similarityScore: Float
    public var inferenceMs: Double
    public var totalElapsedMs: Double
    public var livenessVerdict: LivenessVerdict
    public var glareRatio: Float
    public var bezelDetected: Bool
    public var blinkDetected: Bool
    public var parallaxScore: Float
    public var framesProcessed: Int

    public static let empty = ScanTelemetry(
        engineName: "Not Loaded",
        faceDetected: false,
        faceQuality: 0,
        bestIdentityName: nil,
        similarityScore: 0,
        inferenceMs: 0,
        totalElapsedMs: 0,
        livenessVerdict: .pending,
        glareRatio: 0,
        bezelDetected: false,
        blinkDetected: false,
        parallaxScore: 0,
        framesProcessed: 0
    )
}
