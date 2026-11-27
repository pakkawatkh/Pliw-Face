import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

public struct FaceMatchResult: Sendable {
    public let identity: FaceIdentity
    public let bestTemplateScore: Float
    public let centroidScore: Float

    /// Weighted consensus score combining peak template match (75%) and identity centroid consistency (25%).
    public var consensusScore: Float {
        0.75 * bestTemplateScore + 0.25 * centroidScore
    }
}

/// Accelerate (`vDSP`) vectorized linear algebra and luma statistics for sub-millisecond matching & liveness.
public enum VectorMath {

    /// Returns a unit-length (L2-normalized) copy of `vector` using `vDSP`.
    public nonisolated static func l2Normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > 1e-12 else { return vector }

        var divisor = norm
        var output = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &output, 1, vDSP_Length(vector.count))
        return output
    }

    /// Computes dot product between two L2-normalized vectors via `vDSP_dotpr`.
    public nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// Computes the L2-normalized centroid (mean direction) of an identity's enrolled templates via `vDSP`.
    public nonisolated static func computeCentroid(
        of templates: [EnrolledFaceTemplate],
        dimension: Int
    ) -> [Float]? {
        guard dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var count = 0
        for template in templates where template.vector.count == dimension {
            vDSP_vadd(sum, 1, template.vector, 1, &sum, 1, vDSP_Length(dimension))
            count += 1
        }
        guard count > 0 else { return nil }
        return l2Normalize(sum)
    }

    /// Finds the highest-scoring enabled identity along with its centroid consistency score.
    public nonisolated static func bestVerifiedMatch(
        query: [Float],
        identities: [FaceIdentity],
        modelIdentifier: String
    ) -> FaceMatchResult? {
        var bestResult: FaceMatchResult?

        for identity in identities where identity.isEnabled {
            guard identity.modelIdentifier == modelIdentifier,
                  identity.embeddingDimension == query.count else {
                continue
            }
            var peakScore: Float = -1
            for template in identity.templates where template.vector.count == query.count {
                let score = cosineSimilarity(query, template.vector)
                if score > peakScore {
                    peakScore = score
                }
            }
            guard peakScore > -1 else { continue }
            let centroidScore: Float
            if let centroid = computeCentroid(of: identity.templates, dimension: query.count) {
                centroidScore = cosineSimilarity(query, centroid)
            } else {
                centroidScore = peakScore
            }
            let candidate = FaceMatchResult(
                identity: identity,
                bestTemplateScore: peakScore,
                centroidScore: centroidScore
            )
            if bestResult == nil || candidate.consensusScore > bestResult!.consensusScore {
                bestResult = candidate
            }
        }

        return bestResult
    }

    /// Finds the highest-scoring enabled identity matching `query` (must already be L2-normalized).
    public nonisolated static func bestMatch(
        query: [Float],
        identities: [FaceIdentity],
        modelIdentifier: String
    ) -> (identity: FaceIdentity, score: Float)? {
        guard let verified = bestVerifiedMatch(
            query: query,
            identities: identities,
            modelIdentifier: modelIdentifier
        ) else {
            return nil
        }
        return (verified.identity, verified.bestTemplateScore)
    }

    /// Computes the fraction of clipped specular highlight pixels (luma >= 248) inside the normalized Vision face box
    /// directly from a `32BGRA` pixel buffer with zero image copies.
    public nonisolated static func computeSpecularGlareRatio(
        pixelBuffer: CVPixelBuffer,
        normalizedVisionBox: CGRect
    ) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return 0 }

        // Expand slightly around the face to catch phone-screen edge specular reflections
        let expanded = normalizedVisionBox.insetBy(dx: -normalizedVisionBox.width * 0.15, dy: -normalizedVisionBox.height * 0.15)
        let clampedX0 = max(0, Int(expanded.minX * CGFloat(width)))
        let clampedX1 = min(width - 1, Int(expanded.maxX * CGFloat(width)))
        // Vision Y origin is bottom-left; CVPixelBuffer row 0 is top-left
        let topY = Int((1.0 - expanded.maxY) * CGFloat(height))
        let bottomY = Int((1.0 - expanded.minY) * CGFloat(height))
        let clampedY0 = max(0, topY)
        let clampedY1 = min(height - 1, bottomY)

        guard clampedX1 > clampedX0, clampedY1 > clampedY0 else { return 0 }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var totalSamples = 0
        var brightSamples = 0
        let strideStep = 3 // Sample every 3rd pixel for < 0.15 ms runtime

        var y = clampedY0
        while y <= clampedY1 {
            let rowOffset = y * bytesPerRow
            var x = clampedX0
            while x <= clampedX1 {
                let px = rowOffset + x * 4
                let b = Int(ptr[px])
                let g = Int(ptr[px + 1])
                let r = Int(ptr[px + 2])
                // Fast integer Rec.709 luminance approximation
                let luma = (54 * r + 183 * g + 19 * b) >> 8
                if luma >= 248 && abs(r - g) < 12 && abs(g - b) < 12 {
                    brightSamples += 1
                }
                totalSamples += 1
                x += strideStep
            }
            y += strideStep
        }

        guard totalSamples > 0 else { return 0 }
        return Float(brightSamples) / Float(totalSamples)
    }
}
