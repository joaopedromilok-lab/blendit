"""Pipeline step: interior look.

A camera INSIDE a room sees mostly indirect light (sky through windows, light
bouncing off walls). With the exterior defaults that reads dark, flat and blue
(the sky is the dominant light). When the camera is detected inside - geometry
above it and walls around it - the photoreal looks get what interior
renderers use by default:

  * +exposure, so walls read white instead of grey;
  * white balance to the sky's colour, so whites stop looking blue;
  * EEVEE: screen-space global illumination (light bounces off the walls);
  * Cycles: more diffuse bounces.

`render.interior` in the spec forces it: true / false / "auto" (default).
"""
import math

import bpy
import mathutils

LIT_MODES = ("realistic", "specular")
_EXPOSURE_BOOST = 0.4
# White point = the sky's colour temperature: Blender treats this as "white", so
# the blue cast of sky-lit rooms is neutralised (calibrated: 9000 K -> neutral).
_WHITE_BALANCE_K = 9000.0
# Cycles: indirect light is physically weaker than EEVEE's probe and the warm
# lamps dominate, so it needs more exposure and a slightly COOLER white point.
_EXPOSURE_BOOST_CYCLES = 1.0
_WHITE_BALANCE_K_CYCLES = 5800.0


def camera_is_inside(max_up=8.0, max_side=25.0):
    scene = bpy.context.scene
    cam = scene.camera
    if cam is None:
        return False
    deps = bpy.context.evaluated_depsgraph_get()
    origin = cam.matrix_world.translation.copy()

    def hit(direction, limit):
        ok, loc, _n, _i, obj, _m = scene.ray_cast(deps, origin, direction, distance=limit)
        return ok and obj is not None and not obj.name.startswith("BIR_Ground")

    if not hit(mathutils.Vector((0.0, 0.0, 1.0)), max_up):
        return False
    walls = 0
    for k in range(8):
        a = math.radians(45.0 * k)
        if hit(mathutils.Vector((math.cos(a), math.sin(a), 0.0)), max_side):
            walls += 1
    return walls >= 6


def apply_interior(spec):
    rspec = spec.get("render", {}) or {}
    mode = str(rspec.get("mode", "realistic"))
    want = rspec.get("interior", "auto")
    if mode not in LIT_MODES or want is False or str(want).lower() in ("false", "off", "0"):
        return False
    try:
        bpy.context.view_layer.update()
    except Exception:
        pass
    inside = True if want is True or str(want).lower() in ("true", "on", "1") else camera_is_inside()
    if not inside:
        return False
    scene = bpy.context.scene
    view = scene.view_settings
    cycles = scene.render.engine == "CYCLES"
    boost = _EXPOSURE_BOOST_CYCLES if cycles else _EXPOSURE_BOOST
    wb = _WHITE_BALANCE_K_CYCLES if cycles else _WHITE_BALANCE_K
    view.exposure = float(view.exposure) + boost
    # EEVEE lights a room mostly with the blue sky probe -> warm it to neutral;
    # Cycles bounces the warm lamps physically -> cool it slightly.
    if hasattr(view, "use_white_balance"):
        view.use_white_balance = True
        view.white_balance_temperature = wb
    ee = scene.eevee
    for attr, val in (("use_raytracing", True), ("use_fast_gi", True),
                      ("fast_gi_distance", 3.0), ("fast_gi_ray_count", 4),
                      ("gi_diffuse_bounces", 3)):
        if hasattr(ee, attr):
            try:
                setattr(ee, attr, val)
            except Exception:
                pass
    cy = getattr(scene, "cycles", None)
    if cy is not None:
        for attr, val in (("diffuse_bounces", 6), ("max_bounces", 12),
                          ("transparent_max_bounces", 16)):
            if hasattr(cy, attr):
                setattr(cy, attr, max(getattr(cy, attr), val))
    print("[Blendit] interior detected: exposure +%.2f, white balance %dK, GI on"
          % (boost, wb))
    return True
