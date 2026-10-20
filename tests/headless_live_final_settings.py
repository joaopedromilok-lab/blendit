"""Live View Render Final must render with the same Cycles setup and the same
photoreal material layers as the headless render.

Run: blender --background --python tests/headless_live_final_settings.py

Two checks on the committed fixture (temp copy, realistic mode):

1. Cycles settings of the FINAL render. Headless builds in Cycles, so
   engine.setup_engine -> _speed_up_cycles + enable_gpu configure it. Live
   View builds in EEVEE (the default) and Render Final only flips the engine
   to Cycles. A render_pre handler records the Cycles settings that matter
   for noise / fireflies / look at the moment of each final render, and the
   Live final must match the headless one. The session's own Cycles setup
   must be back to what it was once the final is done.

2. Photoreal material layers after the Engine toggle. prepare_scene adds the
   imperfections (realism.py, node "BIR_Imperfeicao") and the rounded edges
   (bevel.py, node "BIR_Bevel") to every material. The N-panel Engine toggle
   rebuilds the materials (materials.apply_materials); the layers must still
   be there afterwards, in both directions.

Exits 1 when any check fails.
"""
import json
import os
import shutil
import sys
import tempfile

import bpy

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

RES = [160, 90]
SAMPLES = 8
# Cycles settings that change the image (noise, fireflies, caustics, texture
# detail) or the device it renders on.
_KEYS = ("use_adaptive_sampling", "adaptive_threshold", "caustics_reflective",
         "caustics_refractive", "blur_glossy", "sample_clamp_indirect",
         "use_light_tree", "denoiser", "denoising_input_passes",
         "denoising_prefilter", "texture_limit_render", "device")

CHECKS = []
SNAPS = []


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok)))
    print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail))


def _cycles_settings(scene):
    cy = scene.cycles
    out = {k: (round(getattr(cy, k), 4) if isinstance(getattr(cy, k, None), float)
               else getattr(cy, k, None)) for k in _KEYS}
    out["use_simplify"] = bool(scene.render.use_simplify)
    return out


@bpy.app.handlers.persistent
def _snap(scene, *_args):
    SNAPS.append({"path": bpy.path.abspath(scene.render.filepath),
                  "engine": scene.render.engine,
                  "cycles": _cycles_settings(scene)})


def _final_snap(out):
    want = os.path.normcase(os.path.abspath(out))
    hits = [s for s in SNAPS if os.path.normcase(os.path.abspath(s["path"])) == want]
    return hits[-1] if hits else None


def _bundle(tmp):
    dst = os.path.join(tmp, "bundle")
    shutil.copytree(os.path.join(_HERE, "fixtures"), dst)
    path = os.path.join(dst, "scene_spec.json")
    with open(path, "r", encoding="utf-8") as f:
        spec = json.load(f)
    spec.setdefault("render", {}).update({"mode": "realistic", "resolution": RES,
                                          "samples": SAMPLES, "denoise": True})
    with open(path, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=1)
    return dst


def _live_session(bundle, engine):
    import blender.interactive.live as live

    class _NS(object):
        blend = None
        save_blend = None
        capture_dir = None
        mode = "realistic"
    _NS.bundle = bundle
    _NS.engine = engine
    live._register_ui()
    live._BUILD_ARGS = _NS()
    live._BUSY = True
    while live._deferred_build() is not None:
        pass
    live._sync_settings_from_scene()
    return live


def _layers():
    """-> (materials on meshes, with imperfections, with bevel)."""
    mats = set()
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.name.startswith(("BIR_Ground", "BIR_AutoCeiling")):
            continue
        for slot in obj.material_slots:
            if slot.material is not None and slot.material.node_tree is not None:
                mats.add(slot.material)
    imp = sum(1 for m in mats if "BIR_Imperfeicao" in m.node_tree.nodes)
    bev = sum(1 for m in mats if any(n.name.startswith("BIR_Bevel")
                                     for n in m.node_tree.nodes))
    return len(mats), imp, bev


def test_cycles_settings(tmp, bundle):
    from blender.pipeline import run
    out_h = os.path.join(tmp, "headless.png")
    loaded, spec = run.build_scene(bundle, overrides={"engine": "CYCLES",
                                                      "mode": "realistic"})
    run._render(out_h, spec)
    live = _live_session(bundle, "EEVEE")
    out_l = os.path.join(tmp, "live_final.png")
    sc = bpy.context.scene
    before = dict(_cycles_settings(sc), engine=sc.render.engine)
    live._render_still_at(out_l, SAMPLES)
    after = dict(_cycles_settings(sc), engine=sc.render.engine)
    changed = {k: (before[k], after[k]) for k in before if before[k] != after[k]}
    check("[cycles] Live session's own Cycles setup restored after Render Final",
          not changed, json.dumps(changed))
    h, l = _final_snap(out_h), _final_snap(out_l)
    check("[cycles] both finals captured", h is not None and l is not None)
    if h is None or l is None:
        return
    diff = {k: (h["cycles"][k], l["cycles"][k]) for k in h["cycles"]
            if h["cycles"][k] != l["cycles"][k]}
    print("CYCLES headless " + json.dumps(h["cycles"]))
    print("CYCLES live     " + json.dumps(l["cycles"]))
    check("[cycles] Live Render Final uses the headless Cycles settings", not diff,
          json.dumps({k: {"headless": v[0], "live": v[1]} for k, v in diff.items()}))


def test_layers_after_toggle(bundle):
    for build, toggle in (("EEVEE", "CYCLES"), ("CYCLES", "EEVEE")):
        tag = "[layers %s->%s]" % (build, toggle)
        _live_session(bundle, build)
        n0, imp0, bev0 = _layers()
        check("%s built with imperfections + bevel on every material" % tag,
              n0 > 0 and imp0 == n0 and bev0 == n0,
              "materials=%d imperfections=%d bevel=%d" % (n0, imp0, bev0))
        bpy.context.scene.bir.engine = toggle    # the N-panel Engine toggle
        n1, imp1, bev1 = _layers()
        check("%s layers kept after the Engine toggle" % tag,
              n1 > 0 and imp1 == n1 and bev1 == n1,
              "materials=%d imperfections=%d bevel=%d" % (n1, imp1, bev1))


def main():
    tmp = tempfile.mkdtemp(prefix="blendit_final_settings_")
    bundle = _bundle(tmp)
    bpy.app.handlers.render_pre.append(_snap)
    test_cycles_settings(tmp, bundle)
    test_layers_after_toggle(bundle)
    failed = [n for n, ok in CHECKS if not ok]
    print("images kept in %s" % tmp)
    print("LIVE FINAL SETTINGS %s (%d/%d checks)" % ("OK" if not failed else "FAILED",
                                                    len(CHECKS) - len(failed), len(CHECKS)))
    if failed:
        sys.exit(1)


main()
