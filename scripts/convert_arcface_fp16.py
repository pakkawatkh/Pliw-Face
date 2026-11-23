#!/usr/bin/env python3
"""
Converts InsightFace w600k_mbf (MobileFaceNet ArcFace) ONNX weights into an
Apple Neural Engine-optimized FP16 Core ML package (`Resources/ArcFaceFP16.mlpackage`)
with RGB normalization `(pixel - 127.5) / 127.5` baked directly into the model input,
and verifies numerical parity (cosine similarity > 0.995) against ONNX Runtime.
"""

import argparse
import os
import sys
import urllib.request
import zipfile
from pathlib import Path

import numpy as np

BUFFALO_S_URLS = [
    "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_s.zip",
]


def download_w600k_mbf(cache_dir: Path) -> Path:
    onnx_path = cache_dir / "w600k_mbf.onnx"
    if onnx_path.exists() and onnx_path.stat().st_size > 1_000_000:
        print(f"Using cached ONNX model: {onnx_path}")
        return onnx_path

    cache_dir.mkdir(parents=True, exist_ok=True)
    zip_path = cache_dir / "buffalo_s.zip"

    for url in BUFFALO_S_URLS:
        try:
            print(f"Downloading InsightFace buffalo_s pack from {url}...")
            urllib.request.urlretrieve(url, zip_path)
            break
        except Exception as exc:
            print(f"Download failed from {url}: {exc}", file=sys.stderr)

    if not zip_path.exists():
        raise RuntimeError("Could not download buffalo_s.zip; pass --onnx-path manually.")

    with zipfile.ZipFile(zip_path, "r") as zf:
        matches = [n for n in zf.namelist() if n.endswith("w600k_mbf.onnx")]
        if not matches:
            raise RuntimeError("w600k_mbf.onnx not found inside buffalo_s.zip")
        with zf.open(matches[0]) as src, open(onnx_path, "wb") as dst:
            dst.write(src.read())

    zip_path.unlink(missing_ok=True)
    print(f"Extracted ONNX weights to {onnx_path} ({onnx_path.stat().st_size / 1e6:.2f} MB)")
    return onnx_path


def convert_to_coreml_fp16(onnx_path: Path, output_path: Path) -> None:
    import coremltools as ct
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert as onnx_to_torch

    print("Loading ONNX graph and converting to PyTorch...")
    onnx_model = onnx.load(str(onnx_path))
    torch_model = onnx_to_torch(onnx_model).eval()

    example_input = torch.randn(1, 3, 112, 112)
    traced = torch.jit.trace(torch_model, example_input)

    print("Converting traced PyTorch model to Core ML MLProgram (Float16 for Apple Neural Engine)...")
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS13,
        inputs=[
            ct.ImageType(
                name="face_image",
                shape=(1, 3, 112, 112),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    )

    mlmodel.short_description = "ArcFace w600k_mbf (FP16) 512-dim face embedder for Tiffy Face"
    mlmodel.author = "Tiffy Face (converted from InsightFace w600k_mbf)"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        import shutil
        shutil.rmtree(output_path)
    mlmodel.save(str(output_path))
    print(f"Saved Core ML FP16 package to {output_path}")

    # Numerical parity verification against ONNX Runtime
    print("Verifying numerical parity (ONNX Runtime vs Core ML FP16)...")
    from PIL import Image

    rng = np.random.default_rng(42)
    rand_rgb = rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)
    pil_img = Image.fromarray(rand_rgb, mode="RGB")

    # ONNX reference: NCHW float32 normalized to [-1, 1]
    nchw = ((rand_rgb.astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None, ...]
    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    input_name = sess.get_inputs()[0].name
    ort_out = sess.run(None, {input_name: nchw})[0].reshape(-1).astype(np.float64)

    # Core ML prediction
    cm_pred = mlmodel.predict({"face_image": pil_img})["embedding"].reshape(-1).astype(np.float64)

    cosine = float(np.dot(ort_out, cm_pred) / (np.linalg.norm(ort_out) * np.linalg.norm(cm_pred)))
    print(f"Parity cosine similarity (ONNX FP32 vs Core ML FP16): {cosine:.6f}")
    if cosine < 0.995:
        raise RuntimeError(f"Parity check failed: cosine={cosine:.6f} < 0.995")
    print("Parity check PASSED!")


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert InsightFace ArcFace to Core ML FP16")
    parser.add_argument("--onnx-path", type=Path, default=None, help="Optional local path to w600k_mbf.onnx")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "Resources" / "ArcFaceFP16.mlpackage",
        help="Destination .mlpackage path",
    )
    args = parser.parse_args()

    cache_dir = Path.home() / ".cache" / "tiffy-face"
    onnx_path = args.onnx_path if args.onnx_path else download_w600k_mbf(cache_dir)
    convert_to_coreml_fp16(onnx_path, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
