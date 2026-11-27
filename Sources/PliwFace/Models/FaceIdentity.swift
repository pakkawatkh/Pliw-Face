import Foundation

public enum EnrollmentPose: String, CaseIterable, Codable, Identifiable, Sendable {
    case center
    case slightUp
    case upUpRight
    case upRight
    case rightUpRight
    case slightRight
    case rightDownRight
    case downRight
    case downDownRight
    case slightDown
    case downDownLeft
    case downLeft
    case leftDownLeft
    case slightLeft
    case leftUpLeft
    case upLeft
    case upUpLeft

    public var id: String { rawValue }

    public var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .slightLeft, .leftUpLeft, .leftDownLeft: return "Turn your head slightly left"
        case .slightRight, .rightUpRight, .rightDownRight: return "Turn your head slightly right"
        case .slightUp, .upUpLeft, .upUpRight: return "Tilt your chin slightly up"
        case .slightDown, .downDownLeft, .downDownRight: return "Tilt your chin slightly down"
        case .upLeft: return "Look slightly up and left"
        case .upRight: return "Look slightly up and right"
        case .downLeft: return "Look slightly down and left"
        case .downRight: return "Look slightly down and right"
        }
    }

    public var shortLabel: String {
        switch self {
        case .center: return "Center"
        case .slightUp: return "Up"
        case .upUpRight: return "Up-NE"
        case .upRight: return "Up-Right"
        case .rightUpRight: return "Right-NE"
        case .slightRight: return "Right"
        case .rightDownRight: return "Right-SE"
        case .downRight: return "Down-Right"
        case .downDownRight: return "Down-SE"
        case .slightDown: return "Down"
        case .downDownLeft: return "Down-SW"
        case .downLeft: return "Down-Left"
        case .leftDownLeft: return "Left-SW"
        case .slightLeft: return "Left"
        case .leftUpLeft: return "Left-NW"
        case .upLeft: return "Up-Left"
        case .upUpLeft: return "Up-NW"
        }
    }

    /// The 16 directional outer-ring poses in clockwise order starting at 12 o'clock (0°, every 22.5°).
    public static let outerRingPoses: [EnrollmentPose] = [
        .slightUp,
        .upUpRight,
        .upRight,
        .rightUpRight,
        .slightRight,
        .rightDownRight,
        .downRight,
        .downDownRight,
        .slightDown,
        .downDownLeft,
        .downLeft,
        .leftDownLeft,
        .slightLeft,
        .leftUpLeft,
        .upLeft,
        .upUpLeft,
    ]

    /// Maps a clock-face angle in degrees (`0°` = Up, `90°` = Right, `180°` = Down, `270°` = Left)
    /// into its corresponding 22.5° outer-ring enrollment pose.
    public static func outerPose(forClockDegrees degrees: Double) -> EnrollmentPose {
        let normalized = ((degrees.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let sector = Int(((normalized + 11.25) / 22.5).truncatingRemainder(dividingBy: 16.0))
        return outerRingPoses[sector]
    }

    /// Target clock-face angle in degrees (0° = top / 12 o'clock, clockwise) for UI directional guidance.
    public var directionAngleDegrees: Double? {
        switch self {
        case .center: return nil
        case .slightUp: return 0
        case .upUpRight: return 22.5
        case .upRight: return 45
        case .rightUpRight: return 67.5
        case .slightRight: return 90
        case .rightDownRight: return 112.5
        case .downRight: return 135
        case .downDownRight: return 157.5
        case .slightDown: return 180
        case .downDownLeft: return 202.5
        case .downLeft: return 225
        case .leftDownLeft: return 247.5
        case .slightLeft: return 270
        case .leftUpLeft: return 292.5
        case .upLeft: return 315
        case .upUpLeft: return 337.5
        }
    }

    /// Verifies whether screen-aligned head pose (`yaw < 0` left, `yaw > 0` right, `pitch < 0` up, `pitch > 0` down)
    /// matches this target enrollment angle.
    public func matches(yaw: Float, pitch: Float) -> Bool {
        if self == .center {
            return abs(yaw) <= 0.14 && abs(pitch) <= 0.12
        }
        let nx = Double(yaw / 0.14)
        let ny = Double(pitch / 0.095)
        guard hypot(nx, ny) >= 1.0 else { return false }
        var deg = atan2(nx, -ny) * 180.0 / .pi
        if deg < 0 { deg += 360.0 }
        return Self.outerPose(forClockDegrees: deg) == self
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
