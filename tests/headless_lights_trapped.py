"""A fixture's light must not end up sealed inside a solid part of the model.

Run: blender --background --python tests/headless_lights_trapped.py

The SketchUp exporter places a table lamp's light at the centre of the lamp's
bounding box. On a lamp with a tall solid base (a real SketchUp model), that
centre is INSIDE the closed base: every ray from the light hits the base a few
centimetres away, no light reaches the room, and the night render is lit only
by the sky (auto exposure maxed at +3 EV, blue).

Synthetic room (no bundle): floor + ceiling, a closed lamp base (box,
0.2 x 0.2 x 0.4 m) with an open shade (tube) above it and a garment from the
rack crossing the lamp just above the base (as in the real model), plus a
pendant inside a closed glass globe. lights.setup_lights builds from a spec:
  * "lamp": at the centre of the base (sealed in)   -> CHECK it ends above the
    base and the garment (z > 0.50), inside the shade's height (z < 0.60),
    same x / y;
  * "room": in the middle of the room (free)        -> CHECK it did not move;
  * "globe": inside the glass globe                 -> CHECK it did not move
    (glass lets the light out).
Exits 1 when a CHECK fails.
"""
import math
import os
import sys

import bpy

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok)))
    print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail))


def _mesh(name, verts, faces):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _box(name, x0, y0, z0, x1, y1, z1):
    v = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
         (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return _mesh(name, v, f)


def _tube(name, r, z0, z1, n=24):
    v, f = [], []
    for i in range(n):
        a = 2 * math.pi * i / n
        v += [(r * math.cos(a), r * math.sin(a), z0), (r * math.cos(a), r * math.sin(a), z1)]
    for i in range(n):
        j = (i + 1) % n
        f.append((2 * i, 2 * j, 2 * j + 1, 2 * i + 1))
    return _mesh(name, v, f)


def main():
    from blender.pipeline import lights
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _box("floor", -3, -3, -0.1, 3, 3, 0.0)
    _box("ceiling", -3, -3, 2.6, 3, 3, 2.7)
    _box("lamp_base", -0.1, -0.1, 0.0, 0.1, 0.1, 0.4)        # solid ceramic body
    _tube("lamp_shade", 0.18, 0.42, 0.60)                   # open at top and bottom
    # A garment from the rack next to it crossing the lamp just above the base
    # (as in the real model): two DIFFERENT objects around the light.
    _box("cloth", -0.05, -0.02, 0.38, 0.30, 0.02, 0.50)
    # A pendant inside a closed glass globe: glass lets the light out.
    globe = _box("globe", -1.65, -1.15, 2.05, -1.35, -0.85, 2.35)
    glass = bpy.data.materials.new("Vidro.001")
    globe.data.materials.append(glass)
    spec = {"lights": [
        {"id": "lamp", "type": "point", "position": [0.0, 0.0, 0.2], "intensity": 700,
         "intensity_unit": "cd", "color_kelvin": 2700, "radius_m": 0.04},
        {"id": "room", "type": "point", "position": [1.5, 1.0, 1.4], "intensity": 700,
         "intensity_unit": "cd", "color_kelvin": 2700, "radius_m": 0.04},
        {"id": "globe", "type": "point", "position": [-1.5, -1.0, 2.2], "intensity": 1300,
         "intensity_unit": "cd", "color_kelvin": 2700, "radius_m": 0.04},
    ], "materials": [{"id": "m1", "name": "Vidro", "transparency": 0.9}]}
    lights.setup_lights(spec, 1.0)
    lamp = bpy.data.objects.get("BIR_Lights_lamp")
    room = bpy.data.objects.get("BIR_Lights_room")
    check("both lights built", lamp is not None and room is not None)
    if lamp is None or room is None:
        return _finish()
    p, q = lamp.location, room.location
    print("lamp light at (%.3f, %.3f, %.3f); room light at (%.3f, %.3f, %.3f)"
          % (p.x, p.y, p.z, q.x, q.y, q.z))
    check("lamp light freed above the solid base and the garment", p.z > 0.50,
          "z = %.3f" % p.z)
    check("lamp light still inside the shade's height", p.z < 0.60, "z = %.3f" % p.z)
    check("lamp light kept its x / y", abs(p.x) < 1e-6 and abs(p.y) < 1e-6,
          "x = %.4f, y = %.4f" % (p.x, p.y))
    check("free room light not moved",
          (q - __import__("mathutils").Vector((1.5, 1.0, 1.4))).length < 1e-6,
          "moved %.4f m" % (q - __import__("mathutils").Vector((1.5, 1.0, 1.4))).length)
    g = bpy.data.objects.get("BIR_Lights_globe")
    gm = (g.location - __import__("mathutils").Vector((-1.5, -1.0, 2.2))).length if g else 9.9
    check("light inside a glass globe not moved", gm < 1e-6, "moved %.4f m" % gm)
    return _finish()


def _finish():
    failed = [n for n, ok in CHECKS if not ok]
    print("LIGHTS TRAPPED %s (%d/%d checks)" % ("OK" if not failed else "FAILED",
                                               len(CHECKS) - len(failed), len(CHECKS)))
    if failed:
        sys.exit(1)


main()
