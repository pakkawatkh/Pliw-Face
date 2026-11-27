import Foundation

public enum EnrollmentPose: String, CaseIterable, Codable, Identifiable, Sendable {
    case center
    case slightLeft
    case slightRight
    case slightUp
    case slightDown
    case upLeft
    case upRight
    case downLeft
    case downRight

    public var id: String { rawValue }

    public var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .slightLeft: return "Turn your head slightly left"
        case .slightRight: return "Turn your head slightly right"
        case .slightUp: return "Tilt your chin slightly up"
        case .slightDown: return "Tilt your chin slightly down"
        case .upLeft: return "Look slightly up and left"
        case .upRight: return "Look slightly up and right"
        case .downLeft: return "Look slightly down and left"
        case .downRight: return "Look slightly down and right"
        }
    }

    public var shortLabel: String {
        switch self {
        case .center: return "Center"
        case .slightLeft: return "Left"
        case .slightRight: return "Right"
        case .slightUp: return "Up"
        case .slightDown: return "Down"
        case .upLeft: return "Up-Left"
        case .upRight: return "Up-Right"
        case .downLeft: return "Down-Left"
        case .downRight: return "Down-Right"
        }
    }

    /// Target clock-face angle in degrees (0° = top / 12 o'clock, clockwise) for UI directional guidance.
    public var directionAngleDegrees: Double? {
        switch self {
        case .center: return nil
        case .slightUp: return 0
        case .upRight: return 45
        case .slightRight: return 90
        case .downRight: return 135
        case .slightDown: return 180
        case .downLeft: return 225
        case .slightLeft: return 270
        case .upLeft: return 315
        }
    }

    /// Verifies whether Apple Vision `VNFaceObservation` head pose (`yaw` and `pitch` in radians)
    /// matches this target enrollment angle so enrollment waits for real 3D head turns.
    public func matches(yaw: Float, pitch: Float) -> Bool {
        switch self {
        case .center:
            return abs(yaw) <= 0.14 && abs(pitch) <= 0.14
        case .slightLeft:
            return yaw >= 0.17 && abs(pitch) <= 0.20
        case .slightRight:
            return yaw <= -0.17 && abs(pitch) <= 0.20
        case .slightUp:
            return pitch <= -0.10 && abs(yaw) <= 0.20
        case .slightDown:
            return pitch >= 0.10 && abs(yaw) <= 0.20
        case .upLeft:
            return yaw >= 0.14 && pitch <= -0.08
        case .upRight:
            return yaw <= -0.14 && pitch <= -0.08
        case .downLeft:
            return yaw >= 0.14 && pitch >= 0.08
        case .downRight:
            return yaw <= -0.14 && pitch >= 0.08
        }
    }
}

public struct EnrolledFaceTemplate: Codable, Equatable, Sendable {
    public let pose: EnrollmentPose
    /// L2-normalized embedding vector (512 floats for ArcFace FP16).
    public let vector: [Float]
    public let qualityScore: Float

    public init(pose: EnrollmentPose, vector: [Float], qualityScore: Float) {
        self.pose = pose
        self.vector = vector
        self.qualityScore = qualityScore
    }
}

public struct FaceIdentity: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public let modelIdentifier: String
    public let embeddingDimension: Int
    public var templates: [EnrolledFaceTemplate]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        modelIdentifier: String,
        embeddingDimension: Int,
        templates: [EnrolledFaceTemplate],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.modelIdentifier = modelIdentifier
        self.embeddingDimension = embeddingDimension
        self.templates = templates
        self.createdAt = createdAt
    }
}
