import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import XCTest
import simd
@testable import PliwFace

final class PliwFaceTests: XCTestCase {

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
        let vault = SessionCryptoVault(service: "com.local.pliw-face.unit-test.\(UUID().uuidString)")
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
            .appendingPathComponent("pliw-face-identities-\(UUID().uuidString).enc")
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
        let testService = "com.local.pliw-face.keychain-test.\(UUID().uuidString)"
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
        let modelURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/ArcFaceFP16.mlpackage")
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

    // MARK: - 7. Notch HUD Geometry & Settings Backward Compatibility

    func testNotchHUDGeometryForNotchedAndNonNotchedDisplays() {
        let notched = NotchHUDGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeTop: 38,
            leftAuxWidth: 660,
            rightAuxWidth: 660
        )
        XCTAssertTrue(notched.hasHardwareNotch)
        XCTAssertEqual(notched.notchWidth, 192, accuracy: 0.1)
        XCTAssertEqual(notched.notchHeight, 38, accuracy: 0.1)
        XCTAssertEqual(notched.panelFrame.maxY, 982, accuracy: 0.1)
        XCTAssertEqual(notched.panelFrame.midX, 756, accuracy: 0.1)

        let external = NotchHUDGeometry.compute(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            safeTop: 0,
            leftAuxWidth: 0,
            rightAuxWidth: 0
        )
        XCTAssertFalse(external.hasHardwareNotch)
        XCTAssertLessThan(external.panelFrame.maxY, 1055)
        XCTAssertEqual(external.panelFrame.midX, 960, accuracy: 0.1)
    }

    func testFaceSettingsBackwardCompatibleDecodeDefaultsShowNotchHUDToTrue() throws {
        let legacyJSON = """
        {
          "isEnabled": true,
          "unlockOnWake": true,
          "unlockOnLock": false,
          "unlockOnSpacebar": true,
          "livenessMode": "balanced",
          "similarityThreshold": 0.46,
          "sessionTimeout": 14400,
          "hapticFeedback": true,
          "scanTimeoutSeconds": 7.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(FaceSettings.self, from: legacyJSON)
        XCTAssertTrue(decoded.showNotchHUD)
        XCTAssertEqual(decoded.hudStyle, .notchWings)
        XCTAssertTrue(decoded.unlockOnNotchHover)
        XCTAssertTrue(decoded.autoArmOnLaunch)
        XCTAssertTrue(decoded.launchAtLoginPreferred)
    }

    func testSeventeenAngleEnrollmentPosesAndCentroidConsensus() {
        XCTAssertEqual(EnrollmentPose.allCases.count, 17)
        XCTAssertEqual(Set(EnrollmentPose.allCases.map(\.rawValue)).count, 17)
        XCTAssertEqual(EnrollmentPose.outerRingPoses.count, 16)

        // Looking straight ahead must ONLY match .center (never auto-advance outer sectors)
        XCTAssertTrue(EnrollmentPose.center.matches(yaw: 0.0, pitch: 0.0))
        for nonCenter in EnrollmentPose.allCases where nonCenter != .center {
            XCTAssertFalse(nonCenter.matches(yaw: 0.0, pitch: 0.0), "\(nonCenter) should not match neutral gaze")
        }

        // Screen-aligned coordinates: yaw < 0 = left, yaw > 0 = right, pitch < 0 = up, pitch > 0 = down
        XCTAssertTrue(EnrollmentPose.slightLeft.matches(yaw: -0.20, pitch: 0.0))
        XCTAssertTrue(EnrollmentPose.slightRight.matches(yaw: 0.20, pitch: 0.0))
        XCTAssertTrue(EnrollmentPose.slightUp.matches(yaw: 0.0, pitch: -0.14))
        XCTAssertTrue(EnrollmentPose.slightDown.matches(yaw: 0.0, pitch: 0.14))
        XCTAssertTrue(EnrollmentPose.upLeft.matches(yaw: -0.16, pitch: -0.11))
        XCTAssertTrue(EnrollmentPose.upRight.matches(yaw: 0.16, pitch: -0.11))
        XCTAssertTrue(EnrollmentPose.downLeft.matches(yaw: -0.16, pitch: 0.11))
        XCTAssertTrue(EnrollmentPose.downRight.matches(yaw: 0.16, pitch: 0.11))

        // Clock-face degree mapping covers all 16 outer 22.5° sectors cleanly
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 0), .slightUp)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 22.5), .upUpRight)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 45), .upRight)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 67.5), .rightUpRight)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 90), .slightRight)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 180), .slightDown)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 270), .slightLeft)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 337.5), .upUpLeft)
        XCTAssertEqual(EnrollmentPose.outerPose(forClockDegrees: 358), .slightUp)

        // Centroid consistency verification via VectorMath.bestVerifiedMatch
        let vec = VectorMath.l2Normalize((0..<512).map { sin(Float($0) * 0.21) })
        let identity = FaceIdentity(
            name: "Owner",
            modelIdentifier: "arcface-w600k-mbf-fp16-v1",
            embeddingDimension: 512,
            templates: EnrollmentPose.allCases.map {
                EnrolledFaceTemplate(pose: $0, vector: vec, qualityScore: 0.75)
            }
        )
        let verified = VectorMath.bestVerifiedMatch(
            query: vec,
            identities: [identity],
            modelIdentifier: "arcface-w600k-mbf-fp16-v1"
        )
        XCTAssertNotNil(verified)
        XCTAssertEqual(verified?.bestTemplateScore ?? 0, 1.0, accuracy: 1e-4)
        XCTAssertEqual(verified?.centroidScore ?? 0, 1.0, accuracy: 1e-4)
    }

    func testHeadPoseEstimatorCalibrationAndFreeFlowSectors() {
        var estimator = HeadPoseEstimator(yawSpan: 0.14, pitchSpan: 0.095, smoothingAlpha: 1.0)

        // Simulate a tilted MacBook screen where neutral posture has pitch = +0.18, yaw = -0.05
        estimator.calibrateCenter(HeadPoseSample(yaw: -0.05, pitch: 0.18))
        let neutralRel = estimator.update(raw: HeadPoseSample(yaw: -0.05, pitch: 0.18))
        XCTAssertEqual(neutralRel.yaw, 0.0, accuracy: 1e-5)
        XCTAssertEqual(neutralRel.pitch, 0.0, accuracy: 1e-5)
        XCTAssertNil(estimator.matchedOuterPose(for: neutralRel))

        // Turning left from calibrated center should match .slightLeft and point toward -x
        let leftRel = estimator.update(raw: HeadPoseSample(yaw: -0.22, pitch: 0.18))
        XCTAssertEqual(estimator.matchedOuterPose(for: leftRel), .slightLeft)
        let leftPtr = estimator.normalizedPointer(for: leftRel)
        XCTAssertLessThan(leftPtr.x, -0.9)

        // Turning right from calibrated center should match .slightRight
        let rightRel = estimator.update(raw: HeadPoseSample(yaw: 0.12, pitch: 0.18))
        XCTAssertEqual(estimator.matchedOuterPose(for: rightRel), .slightRight)

        // Tilting chin up relative to tilted MacBook baseline should match .slightUp
        let upRel = estimator.update(raw: HeadPoseSample(yaw: -0.05, pitch: 0.05))
        XCTAssertEqual(estimator.matchedOuterPose(for: upRel), .slightUp)

        // Tilting chin down + right should match .downRight
        let downRightRel = estimator.update(raw: HeadPoseSample(yaw: 0.11, pitch: 0.30))
        XCTAssertEqual(estimator.matchedOuterPose(for: downRightRel), .downRight)
    }

    func testAutoArmFromKeychainIfAvailableLoadsStoredKey() throws {
        let testService = "com.local.pliw-face.autoarm-test.\(UUID().uuidString)"
        let vault = SessionCryptoVault(service: testService)
        defer { try? vault.deleteAllCredentials() }

        // No key stored yet -> returns false
        XCTAssertFalse(vault.autoArmFromKeychainIfAvailable())

        // Save a key directly via KeychainVault as armSession() does on first setup
        let key = SymmetricKey(size: .bits256)
        let keyBytes = key.withUnsafeBytes { Data($0) }
        try KeychainVault.save(account: "session_aes256_key", data: keyBytes, service: testService)

        // Fresh vault instance (simulating app relaunch) should auto-arm silently
        let relaunchedVault = SessionCryptoVault(service: testService)
        XCTAssertFalse(relaunchedVault.isSessionArmed)
        XCTAssertTrue(relaunchedVault.autoArmFromKeychainIfAvailable())
        XCTAssertTrue(relaunchedVault.isSessionArmed)

        // Verify sealed data round-trips with the auto-armed key
        let sealed = try relaunchedVault.seal(Data("hello-pliw".utf8))
        let opened = try relaunchedVault.open(sealed)
        XCTAssertEqual(String(data: opened, encoding: .utf8), "hello-pliw")
    }

    func testNotchHoverTriggerHitZoneGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Inside top-center notch
        XCTAssertTrue(
            NotchHoverTrigger.isPointInsideNotchZone(
                pointQuartz: CGPoint(x: 756, y: 18),
                screenFrame: screen,
                safeTop: 38,
                leftAuxWidth: 660,
                rightAuxWidth: 660
            )
        )
        // Outside (far left menu bar)
        XCTAssertFalse(
            NotchHoverTrigger.isPointInsideNotchZone(
                pointQuartz: CGPoint(x: 120, y: 18),
                screenFrame: screen,
                safeTop: 38,
                leftAuxWidth: 660,
                rightAuxWidth: 660
            )
        )
        // Converted AppKit bottom-left coordinate near top center of screen
        let converted = NotchHoverTrigger.convertAppKitToQuartz(
            pointAppKit: CGPoint(x: 756, y: 970),
            screenFrame: screen
        )
        XCTAssertTrue(
            NotchHoverTrigger.isPointInsideNotchZone(
                pointQuartz: converted,
                screenFrame: screen,
                safeTop: 38,
                leftAuxWidth: 660,
                rightAuxWidth: 660
            )
        )
        // Below notch hit zone
        XCTAssertFalse(
            NotchHoverTrigger.isPointInsideNotchZone(
                pointQuartz: CGPoint(x: 756, y: 120),
                screenFrame: screen,
                safeTop: 38,
                leftAuxWidth: 660,
                rightAuxWidth: 660
            )
        )
    }

    @MainActor
    func testSkyLightOverlaySpaceLoadsSafely() {
        let overlay = SkyLightOverlaySpace()
        XCTAssertTrue(overlay.isAvailable, "SkyLight overlay symbols should resolve on macOS")
        overlay.teardown()
    }

    func testSubmitPasswordAbortsAndZeroesBytesWhenScreenIsNotLocked() {
        var secret = Data("super-secret-pw".utf8)
        XCTAssertThrowsError(
            try LockScreenKeystrokeDriver.submitPassword(&secret, isLockedCheck: { false })
        ) { error in
            XCTAssertEqual(error as? KeystrokeDriverError, .screenNoLongerLocked)
        }
        XCTAssertTrue(secret.allSatisfy { $0 == 0 }, "Password bytes must be zeroed even when aborted")
    }
}
