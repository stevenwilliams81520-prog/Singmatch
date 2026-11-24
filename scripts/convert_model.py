"""Convert the UVR MDX-Net Voc_FT vocal model from ONNX to Core ML and verify it.

Usage: python convert_model.py <in.onnx> <out.mlpackage>

Runs on the Codemagic Mac during the build. Tries several equivalent conversions
(some Core ML runtimes mis-run certain fused ops) and keeps the first whose
Core ML output matches the original ONNX model. Fails the build if none match.
"""
import sys, platform, shutil, gc
import numpy as np, torch, onnx
import torch.nn as nn
import torch.nn.functional as F
from onnx2torch import convert
import coremltools as ct

SRC, DST = sys.argv[1], sys.argv[2]
SHAPE = (1, 4, 3072, 256)
torch.set_grad_enabled(False)
ON_MAC = platform.system() == "Darwin"


class Affine(nn.Module):
    """BatchNorm (inference) written as plain multiply + add."""
    def __init__(self, bn):
        super().__init__()
        s = bn.weight / torch.sqrt(bn.running_var + bn.eps)
        self.register_buffer("scale", s.reshape(1, -1, 1, 1).clone())
        self.register_buffer("shift", (bn.bias - bn.running_mean * s).reshape(1, -1, 1, 1).clone())

    def forward(self, x):
        return x * self.scale + self.shift


class Upsample2x(nn.Module):
    """ConvTranspose2d(kernel 2, stride 2, no padding) as a 1x1 conv + rearrange (exactly equivalent)."""
    def __init__(self, ct2d):
        super().__init__()
        w = ct2d.weight                      # (Cin, Cout, 2, 2)
        cin, cout = w.shape[0], w.shape[1]
        self.cout = cout
        self.register_buffer("w", w.permute(1, 2, 3, 0).reshape(cout * 4, cin, 1, 1).clone())
        self.register_buffer("b", ct2d.bias.reshape(1, cout, 1, 1).clone() if ct2d.bias is not None
                             else torch.zeros(1, cout, 1, 1))

    def forward(self, x):
        z = F.conv2d(x, self.w)                 # (N, Cout*4, H, W), channels ordered (co, a, b)
        return F.pixel_shuffle(z, 2) + self.b   # -> (N, Cout, 2H, 2W)


def rewrite(model):
    for name, mod in list(model.named_modules()):
        if not name:
            continue
        new = None
        if isinstance(mod, nn.modules.batchnorm._BatchNorm):
            new = Affine(mod)
        elif isinstance(mod, nn.ConvTranspose2d) and tuple(mod.kernel_size) == (2, 2) \
                and tuple(mod.stride) == (2, 2) and tuple(mod.padding) == (0, 0) \
                and tuple(mod.output_padding) == (0, 0) and mod.groups == 1:
            new = Upsample2x(mod)
        if new is not None:
            parent_name, _, attr = name.rpartition(".")
            parent = model.get_submodule(parent_name) if parent_name else model
            setattr(parent, attr, new)
    return model


def build(variant):
    model = convert(onnx.load(SRC)).eval()
    pipeline = ct.PassPipeline.DEFAULT
    if variant in ("rewritten", "rewritten-nofuse"):
        model = rewrite(model)
    if variant in ("nofuse", "rewritten-nofuse"):
        pipeline = ct.PassPipeline.DEFAULT
        pipeline.remove_passes({
            "common::fuse_conv_batchnorm", "common::fuse_conv_bias", "common::fuse_conv_scale",
            "common::fuse_elementwise_to_batchnorm", "common::fuse_matmul_weight_bias",
            "common::fuse_linear_bias", "common::fuse_transpose_matmul",
        })
    if variant == "rewritten":
        pipeline = ct.PassPipeline.DEFAULT
        # keep the multiply/add from being turned back into batch_norm
        pipeline.remove_passes({"common::fuse_elementwise_to_batchnorm"})
    traced = torch.jit.trace(model, torch.zeros(1, 4, 3072, 32))   # time-length agnostic
    del model
    gc.collect()
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=SHAPE, dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS16,
        pass_pipeline=pipeline,
    )
    ml.short_description = "UVR MDX-Net Voc_FT vocal separation"
    return ml


def reference():
    import onnxruntime as ort
    x = (np.random.default_rng(0).standard_normal(SHAPE) * 3).astype(np.float32)
    return x, ort.InferenceSession(SRC).run(None, {"input": x})[0]


variants = ["rewritten", "rewritten-nofuse", "default", "nofuse"]
x, ref = reference() if ON_MAC else (None, None)
scale = float(np.abs(ref).max()) if ON_MAC else 1.0

for v in variants:
    print(f"--- variant: {v}", flush=True)
    ml = build(v)
    tmp = f"/tmp/candidate-{v}.mlpackage"
    shutil.rmtree(tmp, ignore_errors=True)
    ml.save(tmp)
    del ml
    gc.collect()
    if not ON_MAC:
        print("Not on a Mac, can't run Core ML to verify; keeping", v)
        shutil.rmtree(DST, ignore_errors=True)
        shutil.move(tmp, DST)
        sys.exit(0)
    ok = True
    for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_GPU):
        got = ct.models.MLModel(tmp, compute_units=units).predict({"input": x})["output"]
        err = float(np.abs(got - ref).max())
        print(f"    {units.name}: max diff {err:.2e} (output scale {scale:.2f})", flush=True)
        if err > 2e-2 * max(scale, 1.0):
            ok = False
            break
    if ok:
        shutil.rmtree(DST, ignore_errors=True)
        shutil.move(tmp, DST)
        print(f"Using variant '{v}', saved {DST}")
        sys.exit(0)
    shutil.rmtree(tmp, ignore_errors=True)

sys.exit("No conversion of the model matched the original")
