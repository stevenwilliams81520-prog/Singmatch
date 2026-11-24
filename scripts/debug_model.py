"""Find the first Core ML operation whose output differs from a reference.

Usage: python debug_model.py <in.onnx>
Converts the model, runs every op with a plain PyTorch reference implementation,
then binary-searches with Core ML sub-models (cut at an op) to find where Core ML
first diverges. Prints a short report. Only meaningful on a Mac.
"""
import sys, platform, gc
import numpy as np, torch, onnx
import torch.nn.functional as Fn
from onnx2torch import convert
import coremltools as ct
from coremltools.converters.mil.debugging_utils import extract_submodel

SRC = sys.argv[1]
SHAPE = (1, 4, 3072, 256)
torch.set_grad_enabled(False)
sys.setrecursionlimit(1_000_000)
import threading; threading.stack_size(512 * 1024 * 1024)

def main():
    model = convert(onnx.load(SRC)).eval()
    traced = torch.jit.trace(model, torch.zeros(1, 4, 3072, 32))
    del model
    ml = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=SHAPE, dtype=np.float32)],
                    outputs=[ct.TensorType(name="output", dtype=np.float32)], convert_to="mlprogram",
                    compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.iOS16)
    prog = ml._mil_program
    fn = prog.functions["main"]
    ops = [op for op in fn.operations if op.op_type != "const"]
    print("non-const ops:", len(ops))

    x = (np.random.default_rng(0).standard_normal(SHAPE) * 3).astype(np.float32)
    in_name = list(fn.inputs.keys())[0]

    def run_reference(target):
        env = {in_name: torch.from_numpy(x)}
        all_ops = list(fn.operations)
        last = {}
        for i, op in enumerate(all_ops):
            for v in op.inputs.values():
                for vv in (v if isinstance(v, (list, tuple)) else [v]):
                    last[vv.name] = i
        def V(var):
            return env[var.name] if var.name in env else torch.as_tensor(np.array(var.val))
        for i, op in enumerate(all_ops):
            t = op.op_type
            if t == "const":
                continue
            if t == "relu": y = torch.relu(V(op.x))
            elif t == "add": y = V(op.x) + V(op.y)
            elif t == "mul": y = V(op.x) * V(op.y)
            elif t == "transpose": y = V(op.x).permute(*[int(k) for k in op.perm.val])
            elif t == "matmul":
                a, b = V(op.x), V(op.y)
                if op.transpose_x.val: a = a.transpose(-1, -2)
                if op.transpose_y.val: b = b.transpose(-1, -2)
                y = a @ b
            elif t == "batch_norm":
                xx = V(op.x); sh = [1, -1] + [1] * (xx.dim() - 2)
                y = (xx - V(op.mean).reshape(sh)) / torch.sqrt(V(op.variance).reshape(sh) + float(op.epsilon.val))
                if op.gamma is not None: y = y * V(op.gamma).reshape(sh)
                if op.beta is not None: y = y + V(op.beta).reshape(sh)
            elif t == "conv":
                p = [int(k) for k in op.pad.val] if op.pad is not None else [0, 0, 0, 0]
                xx = Fn.pad(V(op.x), (p[2], p[3], p[0], p[1]))
                y = Fn.conv2d(xx, V(op.weight), V(op.bias) if op.bias is not None else None,
                              stride=[int(s) for s in op.strides.val], dilation=[int(d) for d in op.dilations.val],
                              groups=int(op.groups.val))
            elif t == "conv_transpose":
                p = [int(k) for k in op.pad.val] if op.pad is not None else [0, 0, 0, 0]
                y = Fn.conv_transpose2d(V(op.x), V(op.weight), V(op.bias) if op.bias is not None else None,
                                        stride=[int(s) for s in op.strides.val],
                                        dilation=[int(d) for d in op.dilations.val], groups=int(op.groups.val))
                if any(p): y = y[:, :, p[0]:y.shape[2] - p[1], p[2]:y.shape[3] - p[3]]
            else:
                raise SystemExit("reference can't run op type " + t)
            name = op.outputs[0].name
            env[name] = y
            if name == target:
                return y.numpy()
            for v in op.inputs.values():
                for vv in (v if isinstance(v, (list, tuple)) else [v]):
                    if last.get(vv.name) == i and vv.name in env and vv.name != in_name:
                        del env[vv.name]
        raise SystemExit('target not found')

    def coreml_err(idx):
        name = ops[idx].outputs[0].name
        sub = extract_submodel(ml, outputs=[name])
        got = sub.predict({"input": x})
        out = list(got.values())[0]
        r = run_reference(name)
        err = float(np.abs(out - r).max()); scale = float(np.abs(r).max()) + 1e-6
        bad = float((np.abs(out - r) > 1e-2 * scale).mean())
        return err, scale, bad, out.shape

    if platform.system() != "Darwin":
        r = run_reference(ops[-1].outputs[0].name)
        import onnxruntime as ort
        o = ort.InferenceSession(SRC).run(None, {"input": x})[0]
        print("Not a Mac: reference vs onnx", float(np.abs(r - o).max()))
        sub = extract_submodel(ml, outputs=[ops[len(ops) // 2].outputs[0].name])
        print("extracted sub-model OK")
        return

    err, scale, bad, _ = coreml_err(len(ops) - 1)
    print(f"final output: max diff {err:.3g}, scale {scale:.3g}, fraction bad {bad:.4f}")
    lo, hi = 0, len(ops) - 1          # find first idx where Core ML is wrong
    while lo < hi:
        mid = (lo + hi) // 2
        e, s, b, shp = coreml_err(mid)
        print(f"  op {mid:3d} {ops[mid].op_type:15s} {list(shp)}: max diff {e:.3g} / scale {s:.3g}, bad {b:.4f}", flush=True)
        if e > 1e-2 * s: hi = mid
        else: lo = mid + 1
    op = ops[lo]
    print("FIRST DIVERGING OP:", lo, op.op_type)
    print("  inputs:", {k: (v.name if not isinstance(v, (list, tuple)) else [w.name for w in v]) for k, v in op.inputs.items()})
    for k, v in op.inputs.items():
        if not isinstance(v, (list, tuple)) and v.val is not None and np.size(v.val) < 20:
            print(f"  {k} = {v.val}")
        elif not isinstance(v, (list, tuple)):
            print(f"  {k} shape {v.shape}")
    print("  output shape", op.outputs[0].shape)
    e, s, b, shp = coreml_err(lo)
    print(f"  diff {e:.3g} scale {s:.3g} bad fraction {b:.4f}")


t = threading.Thread(target=main)
t.start()
t.join()
