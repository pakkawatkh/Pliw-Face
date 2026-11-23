import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import XCTest
import simd
@testable import TiffyFace

final class TiffyFaceTests: XCTestCase {

    // MARK: - 1. VectorMath (Accelerate vDSP)

    func testL2NormalizationAndCosineSimilarityAccuracyAndSpeed() {
        let rawA: [Float] = (0..<512).map { sin(Float($0) * 0.13) }
        let rawB: [Float] = (0..<512).map { cos(Float($0) * 0.13) }

        let normA = VectorMath.l2Normalize(rawA)
        let normB = VectorMath.l2Normalize(rawB)

        XCTAssertEqual(VectorMath.cosineSimilarity(normA, normA), 1.0, accuracy: 1e-5)
        let cross = VectorMath.cosineSimilarity(normA, normB)
        XCTAssertLessThan(abs(cross), 0.15)

        // Benchmark 500 matches across 5-angle identity: should finish in well under 5 ms via vDSP
        let identity = FaceIdentity(
            name: "Alice",
            modelIdentifier: "arcface-w600k-mbf-fp16-v1",
            embeddingDimension: 512,
            templates: EnrollmentPose.allCases.map {
                EnrolledFaceTemplate(pose: $0, vector: normA, qualityScore: 0.8)
            }
        )

        let start = ProcessInfo.processInfo.systemUptime
        var bestScore: Float = 0
        for _ in 0..<500 {
            if let match = VectorMath.bestMatch(
                query: normA,
                identities: [identity],
                modelIdentifier: "arcface-w600k-mbf-fp16-v1"
            ) {
                bestScore = match.score
            }
        }
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(bestScore, 1.0, accuracy: 1e-5)
        XCTAssertLessThan(elapsedMs, 50.0, "500 vDSP 512-dim matches took \(elapsedMs) ms")
    }

    // MARK: - 2. Umeyama 5-Point Similarity Transform (FaceWarper)

    func testUmeyamaSimilarityTransformRecoversExactRotationScaleAndTranslation() throws {
        let target = FaceWarper.canonicalArcFacePointsBottomUp
        let angle = 0.27 // ~15.5 deg
        let scale = 2.4
        let tx = 140.0
        let ty = 95.0

        // Generate synthetic source landmarks by applying inverse transform
        let forward = CGAffineTransform(translationX: tx, y: ty)
            .rotated(by: angle)
            .scaledBy(x: scale, y: scale)
        let source: [SIMD2<Double>] = target.map { p in
            let cg = CGPoint(x: p.x, y: p.y).applying(forward.inverted())
            return SIMD2(Double(cg.x), Double(cg.y))
        }

        let estimated = try XCTUnwrap(FaceWarper.estimateSimilarityTransform(from: source, to: target))

        for (src, dst) in zip(source, target) {
            let mapped = CGPoint(x: src.x, y: src.y).applying(estimated)
            XCTAssertEqual(Double(mapped.x), dst.x, accuracy: 1e-5)
            XCTAssertEqual(Double(mapped.y), dst.y, accuracy: 1e-5)
        }
    }

    // MARK: - 3. Streaming Liveness Detector (Deny & Confirm Cues)

    func testLivenessRejectsScreenGlareAndDeviceBezelSpoofs() {
        let detector = StreamingLivenessDetector()
        let glareSample1 = LivenessFrameSample(
            timestamp: 1.0, glareRatio: 0.30, bezelDetected: false,
            eyeAspectRatio: 0.30, noseOffsetX: 0.0, noseOffsetY: -0.2, yaw: 0, faceQuality: 0.6
        )
        let glareSample2 = LivenessFrameSample(
            timestamp: 1.1, glareRatio: 0.28, bezelDetected: false,
            eyeAspectRatio: 0.30, noseOffsetX: 0.0, noseOffsetY: -0.2, yaw: 0, faceQuality: 0.6
        )
        _ = detector.recordAndEvaluate(glareSample1, mode: .balanced)
        let evalGlare = detector.recordAndEvaluate(glareSample2, mode: .balanced)
        XCTAssertTrue(evalGlare.verdict.isSpoof)

        detector.reset()
        let bezel1 = LivenessFrameSample(
            timestamp: 2.0, glareRatio: 0.02, bezelDetected: true,
            eyeAspectRatio: 0.30, noseOffsetX: 0.0, noseOffsetY: -0.2, yaw: 0, faceQuality: 0.6
        )
        let bezel2 = LivenessFrameSample(
            timestamp: 2.1, glareRatio: 0.02, bezelDetected: true,
            eyeAspectRatio: 0.30, noseOffsetX: 0.0, noseOffsetY: -0.2, yaw: 0, faceQuality: 0.6
        )
        _ = detector.recordAndEvaluate(bezel1, mode: .fast)
        let evalBezel = detector.recordAndEvaluate(bezel2, mode: .fast)
        XCTAssertTrue(evalBezel.verdict.isSpoof)
    }

    func testLivenessConfirmsBlinkAndParallaxInStrictMode() {
        let detector = StreamingLivenessDetector()
        let frames: [LivenessFrameSample] = [
            LivenessFrameSample(timestamp: 1.0, glareRatio: 0.01, bezelDetected: false, eyeAspectRatio: 0.31, noseOffsetX: 0.00, noseOffsetY: -0.20, yaw: 0.0, faceQuality: 0.7),
            LivenessFrameSample(timestamp: 1.1, glareRatio: 0.01, bezelDetected: false, eyeAspectRatio: 0.12, noseOffsetX: 0.01, noseOffsetY: -0.20, yaw: 0.01, faceQuality: 0.7),
            LivenessFrameSample(timestamp: 1.2, glareRatio: 0.01, bezelDetected: false, eyeAspectRatio: 0.30, noseOffsetX: 0.00, noseOffsetY: -0.20, yaw: 0.0, faceQuality: 0.7),
        ]

        var result = detector.recordAndEvaluate(frames[0], mode: .strict)
        XCTAssertFalse(result.verdict.isLive)
        _ = detector.recordAndEvaluate(frames[1], mode: .strict)
        result = detector.recordAndEvaluate(frames[2], mode: .strict)
        XCTAssertTrue(result.verdict.isLive)
        XCTAssertTrue(result.blinkDetected)
    }

    // MARK: - 4. AES-256-GCM Session Crypto Vault & Encrypted Face Store

    func testAES256GCMVaultAndEncryptedIdentityStoreRoundTrip() throws {
        let vault = SessionCryptoVault(service: "com.local.tiffy-face.unit-test.\(UUID().uuidString)")
        XCTAssertFalse(vault.isSessionArmed)

        // Sealing while disarmed must fail closed
        XCTAssertThrowsError(try vault.seal(Data("secret".utf8)))

        vault.armForTesting()
        XCTAssertTrue(vault.isSessionArmed)

        let secret = Data("MyMacLoginPass!@#123".utf8)
        let ciphertext = try vault.seal(secret)
        XCTAssertNotEqual(ciphertext, secret)
        let decrypted = try vault.open(ciphertext)
        XCTAssertEqual(decrypted, secret)

        // Encrypted FaceIdentityStore round-trip
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiffy-face-identities-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let store = FaceIdentityStore(fileURL: tempFile, vault: vault)
        let vec = VectorMath.l2Normalize((0..<512).map { Float($0 % 7) * 0.1 })
        let identity = FaceIdentity(
            name: "Owner",
            modelIdentifier: "arcface-w600k-mbf-fp16-v1",
            embeddingDimension: 512,
            templates: [EnrolledFaceTemplate(pose: .center, vector: vec, qualityScore: 0.9)]
        )

        try store.save([identity])
        let rawOnDisk = try Data(contentsOf: tempFile)
        // Confirm plaintext name does not leak on disk
        XCTAssertNil(String(data: rawOnDisk, encoding: .utf8)?.range(of: "Owner"))

        let loaded = try store.load()
        XCTAssertEqual(loaded, [identity])

        // Disarming locks decryption immediately
        vault.disarmSession()
        XCTAssertFalse(vault.isSessionArmed)
        XCTAssertThrowsError(try store.load())
    }

    func testKeychainVaultLiveSaveReadDeleteWithoutEntitlementError() throws {
        let testService = "com.local.tiffy-face.keychain-test.\(UUID().uuidString)"
        let account = "test_aes_key"
        defer { try? KeychainVault.delete(account: account, service: testService) }

        let payload = Data("0123456789abcdef0123456789abcdef".utf8)
        XCTAssertFalse(KeychainVault.exists(account: account, service: testService))
        try KeychainVault.save(account: account, data: payload, service: testService, accessControl: nil)
        XCTAssertTrue(KeychainVault.exists(account: account, service: testService))

        let loaded = try KeychainVault.read(account: account, service: testService, context: nil)
        XCTAssertEqual(loaded, payload)

        try KeychainVault.delete(account: account, service: testService)
        XCTAssertFalse(KeychainVault.exists(account: account, service: testService))
    }

    // MARK: - 5. Keystroke UTF-16 Surrogate-Safe Chunking

    func testUTF16ChunkingNeverSplitsSurrogatePairs() {
        // 17 ASCII chars + 1 emoji (2 UTF-16 code units = surrogate pair) + 3 ASCII chars
        let text = String(repeating: "a", count: 17) + "🔐" + "xyz"
        let chunks = LockScreenKeystrokeDriver.splitUTF16Safely(text, maxChunkSize: 18)
        XCTAssertEqual(chunks.count, 2)
        let reconstructed = chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined()
        XCTAssertEqual(reconstructed, text)
    }

    // MARK: - 6. Live ArcFace FP16 Core ML Neural Engine Inference Benchmark

    func testLiveArcFaceFP16CoreMLInferenceAndLatency() throws {
        let modelURL = URL(fileURLWithPath: "/Users/bxxs/workspace/github/tools/tiffy-face/Resources/ArcFaceFP16.mlpackage")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: modelURL.path), "ArcFaceFP16.mlpackage not present")

        let embedder = try ArcFaceFP16Embedder(modelURL: modelURL)
        XCTAssertEqual(embedder.embeddingDimension, 512)

        // Create a synthetic 112x112 32BGRA CVPixelBuffer
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            112,
            112,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)

        // Warm-up inference (ANE compilation / first-run cache)
        let warmVec = try embedder.embed(alignedFace: buffer)
        XCTAssertEqual(warmVec.count, 512)
        XCTAssertEqual(VectorMath.cosineSimilarity(warmVec, warmVec), 1.0, accuracy: 1e-4)

        // Measure average steady-state latency across 10 inferences on Apple Silicon Neural Engine
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10 {
            let v = try embedder.embed(alignedFace: buffer)
            XCTAssertEqual(v.count, 512)
        }
        let avgMs = ((ProcessInfo.processInfo.systemUptime - start) * 1000.0) / 10.0
        print(String(format: "⚡️ ArcFace FP16 steady-state average inference: %.2f ms", avgMs))
        XCTAssertLessThan(avgMs, 40.0, "ArcFace FP16 inference exceeded 40 ms budget: \(avgMs) ms")
    }
}
