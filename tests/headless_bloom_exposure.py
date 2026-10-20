"""The lens bloom must not depend on how bright the scene is in absolute terms,
only on how bright things look in the final (exposed) photo.

Run: blender --background --python tests/headless_bloom_exposure.py

realism._bloom adds a Glare (Bloom) node with a FIXED threshold (1.2) to the
compositor, which works on scene-linear light; the view exposure (set by
autoexpose.apply_auto per room) is applied after it. A camera with an
exposure meter gives the same photo of a scene lit 4x stronger.

Synthetic scene (no bundle): an ortho camera looks at a mid-grey emissive
wall (0.18) with a small bright emissive panel (6.0) - a lamp diffuser. Every
emission is multiplied by k and the exposure is set to -log2(k), so without
bloom the final PNGs are identical for every k (CONTROL). Rendered through
run._render (the production path) with the pipeline's view (AgX, Medium High
Contrast) and realism._bloom on / off.

Metrics, on the PNG pixels (display values 0..1, Rec.709 luma):
  * halo(k) = mean(luma_on - luma_off) over a ring around the panel
    (1.3x .. 3x its half size);
  * diff(k) = mean |luma_on(k) - luma_on(1)| over the whole image.
CHECKS: control diff_off(k) <= 0.004 (the setup is fair), and with bloom
halo(k) / halo(1) within 1 +/- 0.15 and diff_on(k) <= 0.004.

Exits 1 when a CHECK fails.
"""
import math
import os
import sys
import tempfile

import bpy
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

RES = 240
WALL = 0.18
PANEL = 6.0
PANEL_HALF = 0.08          # of the frame's half width
KS = (0.25, 1.0, 4.0, 8.0)
DIFF_TOL = 0.004
HALO_TOL = 0.15
CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok)))
    print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail))


def _emissive(name, strength):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = strength
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    return mat


def _quad(name, half, z, mat):
    me = bpy.data.meshes.new(name)
    me.from_pydata([(-half, -half, z), (half, -half, z), (half, half, z), (-half, half, z)],
                   [], [(0, 1, 2, 3)])
    me.materials.append(mat)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)


def _render(k, bloom, out):
    from blender.pipeline import realism
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 4
    sc.cycles.use_denoising = False
    sc.cycles.seed = 0
    sc.render.resolution_x = sc.render.resolution_y = RES
    sc.render.resolution_percentage = 100
    sc.render.image_settings.file_format = "PNG"
    sc.render.filepath = out
    _quad("wall", 1.0, 0.0, _emissive("wall", WALL * k))
    _quad("panel", PANEL_HALF, 0.01, _emissive("panel", PANEL * k))
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 2.0
    cam = bpy.data.objects.new("cam", cam_data)
    cam.location = (0.0, 0.0, 5.0)
    sc.collection.objects.link(cam)
    sc.camera = cam
    vs = sc.view_settings
    vs.view_transform = "AgX"
    try:
        vs.look = "AgX - Medium High Contrast"
    except TypeError:
        pass
    vs.exposure = -math.log2(k)
    if bloom:
        check_ok = realism._bloom(sc)
        if not check_ok:
            raise RuntimeError("realism._bloom did not build the compositor")
    # The production render path ("Renderizar vista"): whatever the pipeline
    # does to the look right before rendering happens here too.
    from blender.pipeline import run
    run._render(out, {"render": {"mode": "realistic"}})


def _luma(path):
    img = bpy.data.images.load(path, check_existing=False)
    try:
        px = np.empty(img.size[0] * img.size[1] * img.channels, dtype=np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(img.size[1], img.size[0], img.channels)[:, :, :3]
        return px[:, :, 0] * 0.2126 + px[:, :, 1] * 0.7152 + px[:, :, 2] * 0.0722
    finally:
        bpy.data.images.remove(img)


def main():
    tmp = tempfile.mkdtemp(prefix="blendit_bloom_")
    ys, xs = np.mgrid[0:RES, 0:RES]
    r = np.maximum(np.abs(xs - (RES - 1) / 2.0), np.abs(ys - (RES - 1) / 2.0)) / (RES / 2.0)
    ring = (r >= PANEL_HALF * 1.3) & (r <= PANEL_HALF * 3.0)
    on, off = {}, {}
    for k in KS:
        for bloom, store in ((True, on), (False, off)):
            out = os.path.join(tmp, "k%s_%s.png" % (k, "bloom" if bloom else "plain"))
            _render(k, bloom, out)
            store[k] = _luma(out)
    halo = {k: float((on[k] - off[k])[ring].mean()) for k in KS}
    print("halo per k: " + ", ".join("k=%s %.4f" % (k, halo[k]) for k in KS))
    for k in KS:
        if k == 1.0:
            continue
        d_off = float(np.abs(off[k] - off[1.0]).mean())
        d_on = float(np.abs(on[k] - on[1.0]).mean())
        ratio = halo[k] / halo[1.0] if halo[1.0] > 1e-6 else float("inf")
        check("control k=%s: same photo without bloom" % k, d_off <= DIFF_TOL,
              "mean |diff| %.4f" % d_off)
        check("k=%s: bloom halo same as k=1" % k, abs(ratio - 1.0) <= HALO_TOL,
              "halo ratio %.2f (k=1: %.4f, k=%s: %.4f)" % (ratio, halo[1.0], k, halo[k]))
        check("k=%s: same photo with bloom" % k, d_on <= DIFF_TOL,
              "mean |diff| %.4f" % d_on)
    failed = [n for n, ok in CHECKS if not ok]
    print("images kept in %s" % tmp)
    print("BLOOM EXPOSURE %s (%d/%d checks)" % ("OK" if not failed else "FAILED",
                                               len(CHECKS) - len(failed), len(CHECKS)))
    if failed:
        sys.exit(1)


main()
