import CoreGraphics
import Foundation
import Vision

public struct LivenessFrameSample: Sendable {
    public let timestamp: TimeInterval
    public let glareRatio: Float
    public let bezelDetected: Bool
    public let eyeAspectRatio: Float?
    public let noseOffsetX: Float?
    public let noseOffsetY: Float?
    public let yaw: Float
    public let faceQuality: Float

    public init(
        timestamp: TimeInterval,
        glareRatio: Float,
        bezelDetected: Bool,
        eyeAspectRatio: Float?,
        noseOffsetX: Float?,
        noseOffsetY: Float?,
        yaw: Float,
        faceQuality: Float
    ) {
        self.timestamp = timestamp
        self.glareRatio = glareRatio
        self.bezelDetected = bezelDetected
        self.eyeAspectRatio = eyeAspectRatio
        self.noseOffsetX = noseOffsetX
        self.noseOffsetY = noseOffsetY
        self.yaw = yaw
        self.faceQuality = faceQuality
    }
}

public struct LivenessEvaluation: Equatable, Sendable {
    public let verdict: LivenessVerdict
    public let blinkDetected: Bool
    public let parallaxScore: Float
    public let maxGlareRatio: Float
    public let bezelDetected: Bool

    public init(
        verdict: LivenessVerdict,
        blinkDetected: Bool,
        parallaxScore: Float,
        maxGlareRatio: Float,
        bezelDetected: Bool
    ) {
        self.verdict = verdict
        self.blinkDetected = blinkDetected
        self.parallaxScore = parallaxScore
        self.maxGlareRatio = maxGlareRatio
        self.bezelDetected = bezelDetected
    }
}

/// Zero-allocation sliding-window anti-spoofing detector combining Deny cues (screen glare + device bezel)
/// and Confirm cues (eye blink EAR delta + 3D nose-to-eye parallax + multi-frame natural variance).
public final class StreamingLivenessDetector {
    private var samples: [LivenessFrameSample] = []
    private let windowSeconds: TimeInterval

    public init(windowSeconds: TimeInterval = 1.4) {
        self.windowSeconds = windowSeconds
        self.samples.reserveCapacity(48)
    }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Extracts pure geometric eye aspect ratio and normalized nose offset from `VNFaceObservation`.
    public nonisolated static func extractGeometryCues(
        from face: VNFaceObservation
    ) -> (ear: Float?, noseOffsetX: Float?, noseOffsetY: Float?) {
        guard let landmarks = face.landmarks else {
            return (nil, nil, nil)
        }

        let leftEAR = computeEyeAspectRatio(landmarks.leftEye?.normalizedPoints)
        let rightEAR = computeEyeAspectRatio(landmarks.rightEye?.normalizedPoints)
        let avgEAR: Float?
        switch (leftEAR, rightEAR) {
        case let (l?, r?): avgEAR = (l + r) * 0.5
        case let (l?, nil): avgEAR = l
        case let (nil, r?): avgEAR = r
        default: avgEAR = nil
        }

        var noseOffsetX: Float?
        var noseOffsetY: Float?
        if let le = landmarks.leftEye?.normalizedPoints, !le.isEmpty,
           let re = landmarks.rightEye?.normalizedPoints, !re.isEmpty,
           let nosePts = (landmarks.noseCrest?.normalizedPoints ?? landmarks.nose?.normalizedPoints), !nosePts.isEmpty {
            let leCenter = centroid(le)
            let reCenter = centroid(re)
            let eyeMid = CGPoint(x: (leCenter.x + reCenter.x) * 0.5, y: (leCenter.y + reCenter.y) * 0.5)
            let interOcular = max(hypot(reCenter.x - leCenter.x, reCenter.y - leCenter.y), 0.01)
            let tip = nosePts.last ?? centroid(nosePts)
            noseOffsetX = Float((tip.x - eyeMid.x) / interOcular)
            noseOffsetY = Float((tip.y - eyeMid.y) / interOcular)
        }

        return (avgEAR, noseOffsetX, noseOffsetY)
    }

    /// Checks whether any detected rectangle strongly frames the detected face (indicative of a phone/tablet spoof).
    public nonisolated static func detectFramingBezel(
        rectangles: [VNRectangleObservation],
        faceBox: CGRect
    ) -> Bool {
        let faceArea = faceBox.width * faceBox.height
        guard faceArea > 0.005 else { return false }

        for rect in rectangles {
            let rBox = rect.boundingBox
            let rArea = rBox.width * rBox.height
            // Device screen framing a face is larger than the face (1.2x..6.5x) and encloses > 80% of the face box
            guard rArea >= faceArea * 1.25, rArea <= faceArea * 6.5 else { continue }
            let intersection = rBox.intersection(faceBox)
            guard !intersection.isNull else { continue }
            let overlap = (intersection.width * intersection.height) / faceArea
            if overlap >= 0.80 {
                return true
            }
        }
        return false
    }

    public func recordAndEvaluate(
        _ sample: LivenessFrameSample,
        mode: LivenessMode
    ) -> LivenessEvaluation {
        samples.append(sample)
        let cutoff = sample.timestamp - windowSeconds
        while let first = samples.first, first.timestamp < cutoff {
            samples.removeFirst()
        }

        // --- 1. Deny Cues (override everything) ---
        let bezelCount = samples.filter { $0.bezelDetected }.count
        let highGlareCount = samples.filter { $0.glareRatio >= 0.24 }.count
        let maxGlare = samples.map(\.glareRatio).max() ?? 0
        let hasBezel = bezelCount >= 1

        if bezelCount >= 2 || (hasBezel && samples.count >= 2 && sample.bezelDetected) {
            return LivenessEvaluation(
                verdict: .spoofDetected(reason: "Device bezel framing face"),
                blinkDetected: false,
                parallaxScore: 0,
                maxGlareRatio: maxGlare,
                bezelDetected: true
            )
        }

        if highGlareCount >= 2 {
            return LivenessEvaluation(
                verdict: .spoofDetected(reason: "Screen specular glare detected"),
                blinkDetected: false,
                parallaxScore: 0,
                maxGlareRatio: maxGlare,
                bezelDetected: hasBezel
            )
        }

        // --- 2. Confirm Cues ---
        let ears = samples.compactMap(\.eyeAspectRatio)
        let blinkDetected: Bool
        if ears.count >= 3, let maxEAR = ears.max(), let minEAR = ears.min(), maxEAR > 0.14 {
            blinkDetected = ((maxEAR - minEAR) / maxEAR) >= 0.26
        } else {
            blinkDetected = false
        }

        let noseXs = samples.compactMap(\.noseOffsetX)
        let noseYs = samples.compactMap(\.noseOffsetY)
        let noseRangeX = (noseXs.max() ?? 0) - (noseXs.min() ?? 0)
        let noseRangeY = (noseYs.max() ?? 0) - (noseYs.min() ?? 0)
        let yawRange = (samples.map(\.yaw).max() ?? 0) - (samples.map(\.yaw).min() ?? 0)
        let parallaxScore = hypot(noseRangeX, noseRangeY) + yawRange * 0.25

        let hasParallax = parallaxScore >= 0.032
        let hasNaturalMicroMotion = parallaxScore >= 0.008

        // --- 3. Mode Decision ---
        switch mode {
        case .fast:
            if samples.count >= 2 {
                return LivenessEvaluation(
                    verdict: .live(reason: "Fast anti-spoof passed"),
                    blinkDetected: blinkDetected,
                    parallaxScore: parallaxScore,
                    maxGlareRatio: maxGlare,
                    bezelDetected: hasBezel
                )
            }
        case .balanced:
            if blinkDetected {
                return LivenessEvaluation(
                    verdict: .live(reason: "Eye blink confirmed"),
                    blinkDetected: true,
                    parallaxScore: parallaxScore,
                    maxGlareRatio: maxGlare,
                    bezelDetected: hasBezel
                )
            }
            if hasParallax && samples.count >= 3 {
                return LivenessEvaluation(
                    verdict: .live(reason: "3D nose parallax confirmed"),
                    blinkDetected: false,
                    parallaxScore: parallaxScore,
                    maxGlareRatio: maxGlare,
                    bezelDetected: hasBezel
                )
            }
            // If sitting naturally still without any spoof cues for >= 4 sharp frames, accept live
            if samples.count >= 4 && (hasNaturalMicroMotion || sample.faceQuality >= 0.35) {
                return LivenessEvaluation(
                    verdict: .live(reason: "3D geometry & clean optics verified"),
                    blinkDetected: false,
                    parallaxScore: parallaxScore,
                    maxGlareRatio: maxGlare,
                    bezelDetected: hasBezel
                )
            }
        case .strict:
            if highGlareCount >= 1 && hasBezel {
                return LivenessEvaluation(
                    verdict: .spoofDetected(reason: "Screen reflection & bezel detected"),
                    blinkDetected: false,
                    parallaxScore: parallaxScore,
                    maxGlareRatio: maxGlare,
                    bezelDetected: true
                )
            }
            if blinkDetected {
                return LivenessEvaluation(
                    verdict: .live(reason: "Eye blink confirmed"),
                    blinkDetected: true,
                    parallaxScore: parallaxScore,
                    maxGlareRatio: maxGlare,
                    bezelDetected: hasBezel
                )
            }
            if parallaxScore >= 0.042 && samples.count >= 5 {
                return LivenessEvaluation(
                    verdict: .live(reason: "3D head-turn parallax confirmed"),
                    blinkDetected: false,
                    parallaxScore: parallaxScore,
                    maxGlareRatio: maxGlare,
                    bezelDetected: hasBezel
                )
            }
        }

        return LivenessEvaluation(
            verdict: .pending,
            blinkDetected: blinkDetected,
            parallaxScore: parallaxScore,
            maxGlareRatio: maxGlare,
            bezelDetected: hasBezel
        )
    }

    private nonisolated static func computeEyeAspectRatio(_ points: [CGPoint]?) -> Float? {
        guard let points, points.count >= 4 else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX
        guard width > 0.005 else { return nil }
        return Float((maxY - minY) / width)
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
