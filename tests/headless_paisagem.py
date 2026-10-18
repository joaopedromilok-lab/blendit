"""Landscape skies (city / garden HDRIs with their own ground).

    blender --background --python tests/headless_paisagem.py

Uses the hand-written fixture bundle with a generated HDR and checks that with
world.hdri_ground the ground plane becomes a Cycles shadow catcher (and is
hidden from the camera in EEVEE), while plain HDRI skies keep the old ground.
"""
import json
import os
import shutil
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import bpy  # noqa: E402

CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok)))
    print("  %-62s %s %s" % (name, "OK" if ok else "FAIL", detail))


def make_hdr(path):
    img = bpy.data.images.new("ceu_teste", 64, 32, float_buffer=True)
    px = []
    for y in range(32):
        for x in range(64):
            v = 2.0 if y > 16 else 0.4          # bright sky, darker ground
            px += [v * 0.8, v * 0.9, v, 1.0]
    img.pixels[:] = px
    img.filepath_raw = path
    img.file_format = "HDR"
    img.save()
    bpy.data.images.remove(img)


def bundle(tmp, name, engine, ground):
    src = os.path.join(_HERE, "fixtures")
    dst = os.path.join(tmp, name)
    shutil.copytree(src, dst)
    os.makedirs(os.path.join(dst, "hdri"), exist_ok=True)
    make_hdr(os.path.join(dst, "hdri", "ceu.hdr"))
    sp = os.path.join(dst, "scene_spec.json")
    spec = json.load(open(sp, encoding="utf-8"))
    w = spec.setdefault("world", {})
    w.update({"sky_type": "hdri", "hdri_uri": "hdri/ceu.hdr", "hdri_strength": 1.5, "hdri_normalize": True,
              "has_site": False})
    if ground:
        w["hdri_ground"] = True
    else:
        w.pop("hdri_ground", None)
    spec.setdefault("render", {})["engine"] = engine
    json.dump(spec, open(sp, "w", encoding="utf-8"))
    return dst


def ground_after(path):
    from blender.pipeline import run
    bpy.ops.wm.read_factory_settings(use_empty=True)
    run.build_scene(path)
    return bpy.data.objects.get("BIR_Ground")


def main():
    tmp = tempfile.mkdtemp(prefix="blendit_paisagem_")
    g = ground_after(bundle(tmp, "cycles", "CYCLES", True))
    check("landscape + Cycles: ground is a shadow catcher", g is not None and g.is_shadow_catcher)
    check("landscape + Cycles: catcher stays visible to the camera (shows the photo + shadows)", g is not None and g.visible_camera)
    g = ground_after(bundle(tmp, "eevee", "EEVEE", True))
    check("landscape + EEVEE: ground hidden from the camera", g is not None and not g.visible_camera)
    g = ground_after(bundle(tmp, "normal", "CYCLES", False))
    check("plain HDRI sky: ground unchanged (not a catcher, visible)", g is not None and not g.is_shadow_catcher and g.visible_camera)
    shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in CHECKS if not ok]
    print("PAISAGEM: %d checks, %d failed%s" % (len(CHECKS), len(failed), "" if not failed else " -> " + "; ".join(failed)))
    if failed:
        sys.exit(1)


main()
