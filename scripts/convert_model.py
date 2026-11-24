"""Convert the UVR MDX-Net Voc_FT vocal model from ONNX to Core ML and verify it.

Usage: python convert_model.py <in.onnx> <out.mlpackage>
Runs on the Codemagic Mac during the build. Fails the build if the Core ML
output doesn't match the original ONNX model.
"""
import sys, platform
import numpy as np, torch, onnx
from onnx2torch import convert
import coremltools as ct

src, dst = sys.argv[1], sys.argv[2]
torch.set_grad_enabled(False)

model = convert(onnx.load(src)).eval()
# The network is time-length agnostic; trace small to save memory, then fix the shape at 256 frames.
traced = torch.jit.trace(model, torch.zeros(1, 4, 3072, 32))
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 4, 3072, 256), dtype=np.float32)],
    outputs=[ct.TensorType(name="output", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.iOS16,
)
ml.short_description = "UVR MDX-Net Voc_FT vocal separation"
ml.save(dst)
print("Saved", dst)

if platform.system() == "Darwin":
    import onnxruntime as ort
    rng = np.random.default_rng(0)
    x = (rng.standard_normal((1, 4, 3072, 256)) * 3).astype(np.float32)
    ref = ort.InferenceSession(src).run(None, {"input": x})[0]
    loaded = ct.models.MLModel(dst, compute_units=ct.ComputeUnit.CPU_ONLY)
    got = loaded.predict({"input": x})["output"]
    err = float(np.abs(got - ref).max()); scale = float(np.abs(ref).max())
    print(f"Core ML vs ONNX: max diff {err:.2e} (output scale {scale:.2f})")
    if err > 1e-2 * max(scale, 1.0):
        sys.exit("Converted model does not match the original")
