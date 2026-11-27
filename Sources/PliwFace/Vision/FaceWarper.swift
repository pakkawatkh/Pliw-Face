import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision
import simd

public enum FaceAlignmentMode: String, Sendable {
    case fivePointUmeyama = "5-point"
    case twoPointEyes = "2-point"
    case boundingBoxCrop = "crop"
}

/// Zero-allocation face aligner warping detected faces into the canonical 112×112 ArcFace coordinate frame
/// using closed-form Umeyama 2D similarity transform + Metal-backed `CIContext` + reusable `CVPixelBufferPool`.
public final class FaceWarper: @unchecked Sendable {
    public static let outputSize: Int = 112

    /// Standard InsightFace 112×112 top-down reference landmarks:
    /// [leftEye, rightEye, noseTip, leftMouth, rightMouth] (in image-space, origin top-left).
    public nonisolated static let canonicalArcFacePointsTopDown: [SIMD2<Double>] = [
        SIMD2(38.2946, 51.6963),
        SIMD2(73.5318, 51.5014),
        SIMD2(56.0252, 71.7366),
        SIMD2(41.5493, 92.3655),
        SIMD2(70.7299, 92.2041),
    ]

    /// Same canonical coordinates expressed in Core Image bottom-left origin (`y' = 112 - y`).
    public nonisolated static let canonicalArcFacePointsBottomUp: [SIMD2<Double>] =
        canonicalArcFacePointsTopDown.map { SIMD2($0.x, Double(outputSize) - $0.y) }

    private let ciContext: CIContext
    private let pixelBufferPool: CVPixelBufferPool?
    private let renderLock = NSLock()

    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext(options: [.cacheIntermediates: false])
        }

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.outputSize,
            kCVPixelBufferHeightKey as String: Self.outputSize,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
        self.pixelBufferPool = pool
    }

    /// Computes the exact 2D similarity transform (`scale * R * p + t`, no shear) minimizing least-squares error
    /// between `source` and `target` points using the closed-form Umeyama solution.
    public nonisolated static func estimateSimilarityTransform(
        from source: [SIMD2<Double>],
        to target: [SIMD2<Double>]
    ) -> CGAffineTransform? {
        let n = source.count
        guard n >= 2, n == target.count else { return nil }

        let invN = 1.0 / Double(n)
        var srcMean = SIMD2<Double>(0, 0)
        var dstMean = SIMD2<Double>(0, 0)
        for i in 0..<n {
            srcMean += source[i]
            dstMean += target[i]
        }
        srcMean *= invN
        dstMean *= invN

        // In 2D, a rotation+scale matrix has form [[a, -b], [b, a]].
        // Closed-form least-squares solution directly minimizes sum || [[a,-b],[b,a]]*p_i - q_i ||^2:
        var denom = 0.0
        var numA = 0.0
        var numB = 0.0

        for i in 0..<n {
            let p = source[i] - srcMean
            let q = target[i] - dstMean
            denom += p.x * p.x + p.y * p.y
            numA += p.x * q.x + p.y * q.y
            numB += p.x * q.y - p.y * q.x
        }

        guard denom > 1e-9 else { return nil }
        let a = numA / denom
        let b = numB / denom

        // Check scale sanity
        let scale = hypot(a, b)
        guard scale.isFinite, scale > 1e-4, scale < 1e4 else { return nil }

        let tx = dstMean.x - (a * srcMean.x - b * srcMean.y)
        let ty = dstMean.y - (b * srcMean.x + a * srcMean.y)

        // CoreGraphics CGAffineTransform applies: x' = a*x + c*y + tx, y' = b*x + d*y + ty
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// Extracts 5 canonical landmarks in CoreImage pixel coordinates (bottom-left origin) from a `VNFaceObservation`.
    public nonisolated static func extractFiveLandmarksBottomUp(
        from face: VNFaceObservation,
        imageSize: CGSize
    ) -> [SIMD2<Double>]? {
        guard let landmarks = face.landmarks,
              let leftEyePts = landmarks.leftEye?.normalizedPoints, !leftEyePts.isEmpty,
              let rightEyePts = landmarks.rightEye?.normalizedPoints, !rightEyePts.isEmpty,
              let nosePts = (landmarks.noseCrest?.normalizedPoints ?? landmarks.nose?.normalizedPoints), !nosePts.isEmpty,
              let mouthPts = landmarks.outerLips?.normalizedPoints, !mouthPts.isEmpty else {
            return nil
        }

        func toImagePoint(_ normInBox: CGPoint) -> SIMD2<Double> {
            let nx = face.boundingBox.origin.x + normInBox.x * face.boundingBox.size.width
            let ny = face.boundingBox.origin.y + normInBox.y * face.boundingBox.size.height
            return SIMD2(Double(nx * imageSize.width), Double(ny * imageSize.height))
        }

        func centroid(_ pts: [CGPoint]) -> SIMD2<Double> {
            var sum = SIMD2<Double>(0, 0)
            for p in pts {
                sum += toImagePoint(p)
            }
            return sum / Double(pts.count)
        }

        var eyeA = centroid(leftEyePts)
        var eyeB = centroid(rightEyePts)
        // Enforce screen-left / screen-right ordering regardless of anatomical flip
        if eyeA.x > eyeB.x {
            swap(&eyeA, &eyeB)
        }

        // Nose tip: lowest Y in bottom-up space (or last point of nose crest)
        let noseTip: SIMD2<Double>
        if let crest = landmarks.noseCrest?.normalizedPoints, let tip = crest.last {
            noseTip = toImagePoint(tip)
        } else {
            noseTip = centroid(nosePts)
        }

        // Mouth corners: minimum X and maximum X on outerLips
        let mouthImagePts = mouthPts.map { toImagePoint($0) }
        guard let leftMouth = mouthImagePts.min(by: { $0.x < $1.x }),
              let rightMouth = mouthImagePts.max(by: { $0.x < $1.x }) else {
            return nil
        }

        return [eyeA, eyeB, noseTip, leftMouth, rightMouth]
    }

    /// Warps the detected face inside `sourceBuffer` into a reusable 112×112 `CVPixelBuffer`.
    public func warpFace(
        from sourceBuffer: CVPixelBuffer,
        observation: VNFaceObservation
    ) -> (buffer: CVPixelBuffer, mode: FaceAlignmentMode)? {
        let width = CGFloat(CVPixelBufferGetWidth(sourceBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(sourceBuffer))
        let imageSize = CGSize(width: width, height: height)

        let ciSource = CIImage(cvPixelBuffer: sourceBuffer)
        let targetRect = CGRect(x: 0, y: 0, width: Self.outputSize, height: Self.outputSize)

        let warpedImage: CIImage
        let mode: FaceAlignmentMode

        if let fivePts = Self.extractFiveLandmarksBottomUp(from: observation, imageSize: imageSize),
           let transform = Self.estimateSimilarityTransform(from: fivePts, to: Self.canonicalArcFacePointsBottomUp) {
            warpedImage = ciSource.transformed(by: transform).cropped(to: targetRect)
            mode = .fivePointUmeyama
        } else if let landmarks = observation.landmarks,
                  let le = landmarks.leftEye?.normalizedPoints, !le.isEmpty,
                  let re = landmarks.rightEye?.normalizedPoints, !re.isEmpty {
            func toImg(_ p: CGPoint) -> SIMD2<Double> {
                let nx = observation.boundingBox.origin.x + p.x * observation.boundingBox.size.width
                let ny = observation.boundingBox.origin.y + p.y * observation.boundingBox.size.height
                return SIMD2(Double(nx * width), Double(ny * height))
            }
            var p1 = le.reduce(SIMD2<Double>(0, 0)) { $0 + toImg($1) } / Double(le.count)
            var p2 = re.reduce(SIMD2<Double>(0, 0)) { $0 + toImg($1) } / Double(re.count)
            if p1.x > p2.x { swap(&p1, &p2) }
            if let transform = Self.estimateSimilarityTransform(
                from: [p1, p2],
                to: Array(Self.canonicalArcFacePointsBottomUp.prefix(2))
            ) {
                warpedImage = ciSource.transformed(by: transform).cropped(to: targetRect)
                mode = .twoPointEyes
            } else {
                warpedImage = fallbackCrop(ciSource: ciSource, box: observation.boundingBox, imageSize: imageSize)
                mode = .boundingBoxCrop
            }
        } else {
            warpedImage = fallbackCrop(ciSource: ciSource, box: observation.boundingBox, imageSize: imageSize)
            mode = .boundingBoxCrop
        }

        guard let destination = dequeueOutputBuffer() else { return nil }

        renderLock.lock()
        ciContext.render(warpedImage, to: destination, bounds: targetRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        renderLock.unlock()

        return (destination, mode)
    }

    private func fallbackCrop(ciSource: CIImage, box: CGRect, imageSize: CGSize) -> CIImage {
        let rect = CGRect(
            x: box.origin.x * imageSize.width,
            y: box.origin.y * imageSize.height,
            width: box.size.width * imageSize.width,
            height: box.size.height * imageSize.height
        ).insetBy(dx: -box.size.width * imageSize.width * 0.12, dy: -box.size.height * imageSize.height * 0.12)
            .intersection(CGRect(origin: .zero, size: imageSize))

        guard rect.width > 4, rect.height > 4 else { return ciSource }
        let cropped = ciSource.cropped(to: rect)
        let sx = CGFloat(Self.outputSize) / rect.width
        let sy = CGFloat(Self.outputSize) / rect.height
        let translated = cropped.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return translated.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    private func dequeueOutputBuffer() -> CVPixelBuffer? {
        if let pool = pixelBufferPool {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            if status == kCVReturnSuccess, let buffer {
                return buffer
            }
        }
        var fallback: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.outputSize,
            Self.outputSize,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &fallback
        )
        return fallback
    }
}
