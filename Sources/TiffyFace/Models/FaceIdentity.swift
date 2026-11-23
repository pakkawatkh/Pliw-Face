import Foundation

public enum EnrollmentPose: String, CaseIterable, Codable, Identifiable, Sendable {
    case center
    case slightLeft
    case slightRight
    case slightUp
    case slightDown

    public var id: String { rawValue }

    public var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .slightLeft: return "Turn your head slightly left"
        case .slightRight: return "Turn your head slightly right"
        case .slightUp: return "Tilt your chin slightly up"
        case .slightDown: return "Tilt your chin slightly down"
        }
    }

    public var shortLabel: String {
        switch self {
        case .center: return "Center"
        case .slightLeft: return "Left"
        case .slightRight: return "Right"
        case .slightUp: return "Up"
        case .slightDown: return "Down"
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
