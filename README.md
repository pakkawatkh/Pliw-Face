# Tiffy Face

Ultra-fast, on-device macOS Face Unlock utility built from scratch in Swift 5.9, SwiftUI, Apple Vision, Accelerate (`vDSP` / `vImage`), and quantized FP16 ArcFace Core ML.

## Highlights
- **Zero-Idle Footprint:** Pure menu bar accessory (`LSUIElement = true`) — camera, Vision, and Core ML stay completely powered down whenever your Mac is unlocked.
- **Sub-Second Wake-to-Unlock:** `640×480` fast-start capture, `VNDetectFaceCaptureQualityRequest` frame gatekeeper, pre-allocated `CVPixelBufferPool` + `vImage` 5-point Umeyama alignment, FP16 ArcFace on the Apple Neural Engine, and vectorized `vDSP` cosine matching (< 0.01 ms).
- **Streaming Anti-Spoofing (Liveness):** Multi-cue glare/bezel deny checks + 3D nose-parallax and eye-blink confirm checks (`Fast`, `Balanced`, `Strict`).
- **2-Tier Keychain + AES-256-GCM Security:** Touch-ID-gated AES-256 session key (`SecAccessControl` `.userPresence`) encrypts both your Mac password and 512-dim face embeddings on disk. Plaintext password bytes are zeroed immediately after unlock, with configurable session auto-lock.
- **100% Documented Apple APIs:** Zero undocumented private frameworks, zero SIP modifications, zero network traffic.

## Build & Test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build_app.sh
./scripts/run.sh
```
