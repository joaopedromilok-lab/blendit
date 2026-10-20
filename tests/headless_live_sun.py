"""Live View must light the scene with the same sun as the headless render.

Run: blender --background --python tests/headless_live_sun.py

The SketchUp exporter sends the sun as a direction vector only (sun.mode
"vector": no latitude / longitude, no azimuth / altitude). world.setup_world
(headless and Live build) turns it into the sun lamp + sky, but Live View's
_init_sun then re-applies the Sun panel - and with no location and no angles
it applied the panel defaults (azimuth 150, altitude 45), moving the sun lamp
and the sky's sun. A real SketchUp room came out with a different sunlight,
so the auto exposure metered a different light (257 K warmer).

For each sun spec, on a temp copy of the fixture, the sun lamp direction and
the sky texture's sun (elevation, rotation) of a headless build are compared
with a Live session after its build + _init_sun:
  * "vector" (SketchUp shape)                       -> CHECK within 0.5 deg
  * "geographic" (latitude/longitude/date/time)     -> CHECK within 0.5 deg
Exits 1 when a CHECK fails.
"""
import json
import math
import os
import shutil
import sys
import tempfile

import bpy

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

TOL_DEG = 0.5
CHECKS = []

SUNS = {
    "vector": {"mode": "vector", "latitude": None, "longitude": None, "date": None,
               "time": None, "timezone": None, "azimuth_degrees": None,
               "altitude_degrees": None, "strength": 1.0, "angle_degrees": 0.526,
               "direction": [0.3839375, 0.0380071, -0.9225765]},
    "geographic": None,          # the fixture's own sun (London, 21 June 16:30)
}


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok)))
    print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail))


def _bundle(tmp, name, sun):
    dst = os.path.join(tmp, name)
    shutil.copytree(os.path.join(_HERE, "fixtures"), dst)
    path = os.path.join(dst, "scene_spec.json")
    with open(path, "r", encoding="utf-8") as f:
        spec = json.load(f)
    spec.setdefault("render", {}).update({"mode": "realistic", "resolution": [160, 90]})
    if sun is not None:
        spec["sun"] = sun
    with open(path, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=1)
    return dst


def _sun_state():
    """-> (lamp altitude, lamp azimuth, sky elevation, sky rotation), degrees."""
    bpy.context.view_layer.update()
    lamp = bpy.data.objects.get("Sun")
    to_sun = lamp.matrix_world.to_3x3() @ __import__("mathutils").Vector((0.0, 0.0, 1.0))
    alt = math.degrees(math.asin(max(-1.0, min(1.0, to_sun.z))))
    az = math.degrees(math.atan2(to_sun.x, to_sun.y)) % 360.0
    sky = next((n for n in bpy.context.scene.world.node_tree.nodes if n.type == "TEX_SKY"), None)
    if sky is None:
        return alt, az, None, None
    return alt, az, math.degrees(sky.sun_elevation), math.degrees(sky.sun_rotation) % 360.0


def _ang(a, b):
    return abs((a - b + 180.0) % 360.0 - 180.0)


def _headless(bundle):
    from blender.pipeline import run
    run.build_scene(bundle, overrides={"engine": "CYCLES", "mode": "realistic"})
    return _sun_state()


def _live(bundle):
    import blender.interactive.live as live

    class _NS(object):
        blend = None
        save_blend = None
        capture_dir = None
        engine = "EEVEE"
        mode = "realistic"
    _NS.bundle = bundle
    live._register_ui()
    live._BUILD_ARGS = _NS()
    live._BUSY = True
    while live._deferred_build() is not None:     # includes _init_sun
        pass
    live._sync_settings_from_scene()
    return _sun_state()


def main():
    tmp = tempfile.mkdtemp(prefix="blendit_live_sun_")
    for name, sun in SUNS.items():
        bundle = _bundle(tmp, "bundle_" + name, sun)
        h = _headless(bundle)
        l = _live(bundle)
        print("SUN %s headless lamp alt %.1f az %.1f sky %s | live lamp alt %.1f az %.1f sky %s"
              % (name, h[0], h[1], "%.1f/%.1f" % h[2:] if h[2] is not None else "-",
                 l[0], l[1], "%.1f/%.1f" % l[2:] if l[2] is not None else "-"))
        lamp = max(abs(h[0] - l[0]), _ang(h[1], l[1]))
        check("[%s] Live sun lamp = headless sun lamp" % name, lamp <= TOL_DEG,
              "max %.2f deg" % lamp)
        if h[2] is not None and l[2] is not None:
            sky = max(abs(h[2] - l[2]), _ang(h[3], l[3]))
            check("[%s] Live sky sun = headless sky sun" % name, sky <= TOL_DEG,
                  "max %.2f deg" % sky)
    failed = [n for n, ok in CHECKS if not ok]
    print("LIVE SUN %s (%d/%d checks)" % ("OK" if not failed else "FAILED",
                                         len(CHECKS) - len(failed), len(CHECKS)))
    if failed:
        sys.exit(1)


main()
