import CoreML
import CoreVideo
import Foundation
import Vision

public enum FaceEmbedderError: LocalizedError, Sendable {
    case modelNotFound
    case inferenceFailed(String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "ArcFace FP16 Core ML model not found in app bundle."
        case .inferenceFailed(let reason):
            return "Face embedding inference failed: \(reason)"
        case .emptyOutput:
            return "Face embedding model returned an empty vector."
        }
    }
}

public protocol FaceEmbeddingEngine: Sendable {
    var displayName: String { get }
    var modelIdentifier: String { get }
    var embeddingDimension: Int { get }
    func embed(alignedFace: CVPixelBuffer) throws -> [Float]
}

/// Primary high-accuracy engine: FP16 quantized InsightFace `w600k_mbf` ArcFace running on Apple Neural Engine / GPU.
public final class ArcFaceFP16Embedder: FaceEmbeddingEngine, @unchecked Sendable {
    public let displayName = "ArcFace FP16 • Neural Engine"
    public let modelIdentifier = "arcface-w600k-mbf-fp16-v1"
    public let embeddingDimension = 512

    private let model: MLModel
    private let inputFeatureName: String
    private let outputFeatureName: String

    public init(modelURL: URL? = nil) throws {
        guard let resolvedURL = try Self.resolveCompiledModelURL(explicitURL: modelURL) else {
            throw FaceEmbedderError.modelNotFound
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all

        do {
            self.model = try MLModel(contentsOf: resolvedURL, configuration: config)
        } catch {
            throw FaceEmbedderError.inferenceFailed(error.localizedDescription)
        }

        let inputNames = Array(model.modelDescription.inputDescriptionsByName.keys)
        let outputNames = Array(model.modelDescription.outputDescriptionsByName.keys)
        self.inputFeatureName = inputNames.contains("face_image") ? "face_image" : (inputNames.first ?? "face_image")
        self.outputFeatureName = outputNames.contains("embedding") ? "embedding" : (outputNames.first ?? "embedding")
    }

    public func embed(alignedFace: CVPixelBuffer) throws -> [Float] {
        let inputValue = MLFeatureValue(pixelBuffer: alignedFace)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputFeatureName: inputValue])
        let result = try model.prediction(from: provider)

        guard let multiArray = result.featureValue(for: outputFeatureName)?.multiArrayValue else {
            throw FaceEmbedderError.emptyOutput
        }

        let count = multiArray.count
        guard count > 0 else { throw FaceEmbedderError.emptyOutput }

        var floats = [Float](repeating: 0, count: count)
        switch multiArray.dataType {
        case .float32:
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                floats[i] = ptr[i]
            }
        case .float16:
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<count {
                floats[i] = Float(ptr[i])
            }
        default:
            for i in 0..<count {
                floats[i] = multiArray[i].floatValue
            }
        }

        return VectorMath.l2Normalize(floats)
    }

    private static func resolveCompiledModelURL(explicitURL: URL?) throws -> URL? {
        if let explicitURL, FileManager.default.fileExists(atPath: explicitURL.path) {
            if explicitURL.pathExtension == "mlmodelc" {
                return explicitURL
            }
            return try MLModel.compileModel(at: explicitURL)
        }

        // 1. Compiled .mlmodelc bundled inside .app/Contents/Resources/
        for name in ["ArcFaceFP16", "ArcFace"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                return url
            }
        }

        // 2. Uncompiled .mlpackage in Bundle or workspace Resources/ (for SwiftPM debug runs)
        let candidatePaths: [URL?] = [
            Bundle.main.url(forResource: "ArcFaceFP16", withExtension: "mlpackage"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/ArcFaceFP16.mlpackage"),
        ]
        for candidate in candidatePaths.compactMap({ $0 }) where FileManager.default.fileExists(atPath: candidate.path) {
            return try MLModel.compileModel(at: candidate)
        }

        return nil
    }
}

/// Built-in zero-dependency fallback using Apple Vision FeaturePrint if ArcFace Core ML is absent.
public final class VisionFeaturePrintEmbedder: FaceEmbeddingEngine, @unchecked Sendable {
    public let displayName = "Apple Vision FeaturePrint"
    public let modelIdentifier = "apple-vision-featureprint-v1"
    public let embeddingDimension = 2048

    public init() {}

    public func embed(alignedFace: CVPixelBuffer) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: alignedFace, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceEmbedderError.emptyOutput
        }

        let count = observation.elementCount
        guard count > 0 else { throw FaceEmbedderError.emptyOutput }

        var floats = [Float](repeating: 0, count: count)
        observation.data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<count {
                floats[i] = ptr[i]
            }
        }
        return VectorMath.l2Normalize(floats)
    }
}

public enum FaceEmbedderFactory {
    public static func makeBestAvailable(explicitModelURL: URL? = nil) -> any FaceEmbeddingEngine {
        if let arcFace = try? ArcFaceFP16Embedder(modelURL: explicitModelURL) {
            return arcFace
        }
        return VisionFeaturePrintEmbedder()
    }
}
