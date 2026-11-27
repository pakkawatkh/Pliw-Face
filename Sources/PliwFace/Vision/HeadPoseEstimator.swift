import CoreGraphics
import Foundation
import Vision

/// Raw or smoothed 3D head pose expressed in **mirrored screen space**:
/// - `yaw < 0`: turning head physically left (left side of mirrored preview, 270°)
/// - `yaw > 0`: turning head physically right (right side of mirrored preview, 90°)
/// - `pitch < 0`: tilting chin up (top of preview, 0°)
/// - `pitch > 0`: tilting chin down (bottom of preview, 180°)
public struct HeadPoseSample: Equatable, Sendable {
    public let yaw: Float
    public let pitch: Float

    public static let zero = HeadPoseSample(yaw: 0, pitch: 0)

    public init(yaw: Float, pitch: Float) {
        self.yaw = yaw
        self.pitch = pitch
    }
}

/// Fuses Apple Vision `VNDetectFaceRectanglesRequest` (Rev 3) 3D pose with continuous facial landmark
/// geometry, calibrates against the user's neutral center posture, applies EMA smoothing, and maps
/// head direction into the 8 outer clock-face enrollment sectors.
public struct HeadPoseEstimator: Sendable {
    /// Comfortable gentle head-turn radii in screen-aligned radians/units.
    public let yawSpan: Float
    public let pitchSpan: Float
    public let smoothingAlpha: Float

    public private(set) var baseline: HeadPoseSample?
    public private(set) var smoothed: HeadPoseSample = .zero
    private var hasSmoothedSample = false

    public init(
        yawSpan: Float = 0.14,
        pitchSpan: Float = 0.095,
        smoothingAlpha: Float = 0.45
    ) {
        self.yawSpan = yawSpan
        self.pitchSpan = pitchSpan
        self.smoothingAlpha = smoothingAlpha
    }

    public mutating func reset() {
        baseline = nil
        smoothed = .zero
        hasSmoothedSample = false
    }

    /// Sets the neutral "looking straight at camera" baseline so laptop screen tilt cancels out.
    public mutating func calibrateCenter(_ sample: HeadPoseSample) {
        baseline = sample
        smoothed = sample
        hasSmoothedSample = true
    }

    /// Feeds a new raw `HeadPoseSample` and returns the baseline-relative, EMA-smoothed pose.
    @discardableResult
    public mutating func update(raw: HeadPoseSample) -> HeadPoseSample {
        if !hasSmoothedSample {
            smoothed = raw
            hasSmoothedSample = true
        } else {
            let a = smoothingAlpha
            smoothed = HeadPoseSample(
                yaw: smoothed.yaw + a * (raw.yaw - smoothed.yaw),
                pitch: smoothed.pitch + a * (raw.pitch - smoothed.pitch)
            )
        }
        return relativePose()
    }

    /// Current smoothed pose relative to the calibrated center baseline.
    public func relativePose() -> HeadPoseSample {
        guard let base = baseline else { return smoothed }
        return HeadPoseSample(
            yaw: smoothed.yaw - base.yaw,
            pitch: smoothed.pitch - base.pitch
        )
    }

    /// Normalized 2D vector in `[-1, 1]` (clamped to unit circle) for driving the live UI ring pointer.
    /// `-x` = left, `+x` = right, `-y` = up, `+y` = down.
    public func normalizedPointer(for relative: HeadPoseSample) -> CGPoint {
        let nx = Double(relative.yaw / max(yawSpan, 0.01))
        let ny = Double(relative.pitch / max(pitchSpan, 0.01))
        let mag = hypot(nx, ny)
        if mag > 1.0 {
            return CGPoint(x: nx / mag, y: ny / mag)
        }
        return CGPoint(x: nx, y: ny)
    }

    /// Returns the outer ring `EnrollmentPose` if the user's relative head turn exceeds the comfortable
    /// activation radius (`r >= 1.0`), or `nil` while still near center.
    public func matchedOuterPose(for relative: HeadPoseSample) -> EnrollmentPose? {
        let nx = Double(relative.yaw / max(yawSpan, 0.01))
        let ny = Double(relative.pitch / max(pitchSpan, 0.01))
        let radius = hypot(nx, ny)
        guard radius >= 1.0 else { return nil }

        // Clock degrees: 0° = Up (ny < 0), 90° = Right (nx > 0), 180° = Down (ny > 0), 270° = Left (nx < 0)
        var degrees = atan2(nx, -ny) * 180.0 / .pi
        if degrees < 0 { degrees += 360.0 }
        return EnrollmentPose.outerPose(forClockDegrees: degrees)
    }

    // MARK: - Vision + Landmark Fusion

    /// Extracts continuous screen-mirrored `(yaw, pitch)` from Vision observations.
    /// Guarantees smooth non-zero pitch even when `VNFaceObservation.pitch` is `nil` by fusing
    /// with normalized nose-to-eye/mouth landmark geometry.
    public nonisolated static func extractRawPose(
        landmarksFace: VNFaceObservation,
        rectanglesFace: VNFaceObservation?
    ) -> HeadPoseSample {
        let visionYaw = (rectanglesFace?.yaw ?? landmarksFace.yaw)?.floatValue
        let visionPitch = (rectanglesFace?.pitch ?? landmarksFace.pitch)?.floatValue

        let landmarkPose = extractLandmarkPose(from: landmarksFace)

        // In the unmirrored camera frame, turning physically left produces positive Vision yaw
        // and positive (noseTip.x - eyeMid.x); negate both to match the mirrored preview (-x = left, +x = right).
        let rawYaw: Float
        switch (visionYaw, landmarkPose?.yaw) {
        case let (v?, l?):
            rawYaw = -(0.65 * v + 0.35 * l)
        case let (v?, nil):
            rawYaw = -v
        case let (nil, l?):
            rawYaw = -l
        default:
            rawYaw = 0
        }

        // Raw Vision pitch is negative when tilting chin up, positive when tilting down —
        // already aligned with screen-Y (-y = up, +y = down).
        let rawPitch: Float
        switch (visionPitch, landmarkPose?.pitch) {
        case let (v?, l?):
            rawPitch = 0.60 * v + 0.40 * l
        case let (v?, nil):
            rawPitch = v
        case let (nil, l?):
            rawPitch = l
        default:
            rawPitch = 0
        }

        return HeadPoseSample(yaw: rawYaw, pitch: rawPitch)
    }

    /// Pure geometric yaw & pitch proxy computed from 2D facial landmarks (Vision bottom-left origin).
    /// - `yaw` proxy: positive when nose shifts right of eye midpoint in unmirrored frame (physical left turn).
    /// - `pitch` proxy: negative when nose shifts up toward eyes (chin up), positive when nose shifts down toward mouth (chin down).
    public nonisolated static func extractLandmarkPose(from face: VNFaceObservation) -> HeadPoseSample? {
        guard let landmarks = face.landmarks,
              let leftEyePts = landmarks.leftEye?.normalizedPoints, !leftEyePts.isEmpty,
              let rightEyePts = landmarks.rightEye?.normalizedPoints, !rightEyePts.isEmpty,
              let nosePts = (landmarks.noseCrest?.normalizedPoints ?? landmarks.nose?.normalizedPoints), !nosePts.isEmpty else {
            return nil
        }

        let le = centroid(leftEyePts)
        let re = centroid(rightEyePts)
        let eyeMid = CGPoint(x: (le.x + re.x) * 0.5, y: (le.y + re.y) * 0.5)
        let interOcular = max(hypot(re.x - le.x, re.y - le.y), 0.02)

        let noseTip = landmarks.noseCrest?.normalizedPoints.last ?? centroid(nosePts)

        // Horizontal offset normalized by inter-ocular distance (unmirrored frame: physical left -> +x)
        let yawProxy = Float((noseTip.x - eyeMid.x) / interOcular) * 0.85

        // Vertical pitch proxy: ratio of eye-to-nose vs eye-to-mouth vertical span
        let pitchProxy: Float
        if let mouthPts = landmarks.outerLips?.normalizedPoints, !mouthPts.isEmpty {
            let mouthMid = centroid(mouthPts)
            let eyeToMouth = max(eyeMid.y - mouthMid.y, 0.05)
            let eyeToNose = eyeMid.y - noseTip.y
            let ratio = Float(eyeToNose / eyeToMouth)
            // Straight ahead ratio ≈ 0.52; chin up -> smaller ratio (negative); chin down -> larger ratio (positive)
            pitchProxy = (ratio - 0.52) * 1.45
        } else {
            // Fallback using nose offset relative to inter-ocular distance
            let eyeToNoseNorm = Float((eyeMid.y - noseTip.y) / interOcular)
            pitchProxy = (eyeToNoseNorm - 0.45) * 0.85
        }

        return HeadPoseSample(yaw: yawProxy, pitch: pitchProxy)
    }

    private nonisolated static func centroid(_ points: [CGPoint]) -> CGPoint {
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for p in points {
            sx += p.x
            sy += p.y
        }
        let n = CGFloat(points.count)
        return CGPoint(x: sx / n, y: sy / n)
    }
}
