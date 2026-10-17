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
_EXPOSURE_BOOST_CYCLES = 1.25
_WHITE_BALANCE_K_CYCLES = 7000.0   # daytime: lamps dimmed, the sky dominates
_WHITE_BALANCE_K_CYCLES_NIGHT = 5800.0
# Photographed (HDRI) skies: near neutral.
_WHITE_BALANCE_K_HDRI = 7500.0
_WHITE_BALANCE_K_HDRI_CYCLES = 6500.0
# Fixture power during the day, relative to the extracted value.
_DAY_LAMPS = 0.35


_CEILING = "BIR_AutoCeiling"


def _probe(max_up=8.0, max_side=25.0):
    """-> (is there a ceiling above the camera?, how many of 8 horizontal rays
    hit a wall). The ceiling test casts 5 rays up (at the camera and 0.8 m
    around it) so a pendant lamp or a beam right above the camera does not
    count as a ceiling."""
    scene = bpy.context.scene
    cam = scene.camera
    if cam is None:
        return False, 0
    deps = bpy.context.evaluated_depsgraph_get()
    origin = cam.matrix_world.translation.copy()

    def hit(direction, limit):
        ok, loc, _n, _i, obj, _m = scene.ray_cast(deps, origin, direction, distance=limit)
        return ok and obj is not None and not obj.name.startswith(("BIR_Ground", _CEILING))

    ups = 0
    zdir = mathutils.Vector((0.0, 0.0, 1.0))
    for dx, dy in ((0, 0), (0.8, 0), (-0.8, 0), (0, 0.8), (0, -0.8)):
        o = origin + mathutils.Vector((dx, dy, 0.0))
        ok, _l, _n, _i, obj, _m = scene.ray_cast(deps, o, zdir, distance=max_up)
        if ok and obj is not None and not obj.name.startswith(("BIR_Ground", _CEILING)):
            ups += 1
    up = ups >= 3
    walls = 0
    for k in range(8):
        a = math.radians(45.0 * k)
        if hit(mathutils.Vector((math.cos(a), math.sin(a), 0.0)), max_side):
            walls += 1
    return up, walls


def camera_is_inside(max_up=8.0, max_side=25.0):
    up, walls = _probe(max_up, max_side)
    return up and walls >= 6


def add_hidden_ceiling():
    """Interior models are often drawn WITHOUT a ceiling (so the designer can
    look in from above). Rendered from inside, the open top floods the room with
    sky light: flat, blue, overexposed. A ceiling the camera does not see (it
    still blocks the sky and the sun and bounces light like white plaster) gives
    the light of a real closed room while the image stays as framed in SketchUp.
    Returns True when added."""
    scene = bpy.context.scene
    cam = scene.camera
    old = bpy.data.objects.get(_CEILING)
    if old is not None:
        bpy.data.objects.remove(old, do_unlink=True)
    lo = [math.inf, math.inf]
    hi = [-math.inf, -math.inf]
    ztop = -math.inf
    for obj in scene.objects:
        if obj.type != "MESH" or obj.name.startswith(("BIR_Ground", _CEILING)):
            continue
        for c in obj.bound_box:
            w = obj.matrix_world @ mathutils.Vector(c)
            lo[0] = min(lo[0], w.x); lo[1] = min(lo[1], w.y)
            hi[0] = max(hi[0], w.x); hi[1] = max(hi[1], w.y)
            ztop = max(ztop, w.z)
    if cam is None or not math.isfinite(ztop) or cam.matrix_world.translation.z >= ztop - 0.05:
        return False
    z = ztop + 0.005
    pad = 1.0
    verts = [(lo[0] - pad, lo[1] - pad, z), (hi[0] + pad, lo[1] - pad, z),
             (hi[0] + pad, hi[1] + pad, z), (lo[0] - pad, hi[1] + pad, z)]
    mesh = bpy.data.meshes.new(_CEILING)
    mesh.from_pydata(verts, [], [(3, 2, 1, 0)])          # faces down, into the room
    mesh.update()
    obj = bpy.data.objects.new(_CEILING, mesh)
    scene.collection.objects.link(obj)
    mat = bpy.data.materials.get(_CEILING) or bpy.data.materials.new(_CEILING)
    mat.use_nodes = True
    bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is not None:
        bsdf.inputs["Base Color"].default_value = (0.85, 0.85, 0.83, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.9
    mesh.materials.append(mat)
    if hasattr(obj, "visible_camera"):
        obj.visible_camera = False
    try:
        obj.hide_select = True
    except Exception:
        pass
    return True


def apply_interior(spec):
    rspec = spec.get("render", {}) or {}
    mode = str(rspec.get("mode", "realistic"))
    want = rspec.get("interior", "auto")
    scene = bpy.context.scene
    for k in ("bir_wb_base", "bir_interior"):
        if k in scene:
            del scene[k]
    if mode not in LIT_MODES or want is False or str(want).lower() in ("false", "off", "0"):
        return False
    try:
        bpy.context.view_layer.update()
    except Exception:
        pass
    forced = want is True or str(want).lower() in ("true", "on", "1")
    up, walls = _probe()
    inside = forced or (up and walls >= 6)
    if not up and not forced:
        # No ceiling: only call it a room when walls are close all around (an
        # open courtyard or a street between buildings must stay an exterior).
        # Open-plan rooms leak a ray or two through doors, so 5 of 8 is enough.
        walls = _probe(max_side=12.0)[1]
        print("[Blendit] no ceiling above the camera; walls around: %d of 8" % walls)
    if not up and (forced or walls >= 5) and add_hidden_ceiling():
        inside = True
        print("[Blendit] room without a ceiling: added a hidden one so the light "
              "comes in through the windows")
    if not inside:
        return False
    scene = bpy.context.scene
    view = scene.view_settings
    cycles = scene.render.engine == "CYCLES"
    boost = _EXPOSURE_BOOST_CYCLES if cycles else _EXPOSURE_BOOST
    wb = _WHITE_BALANCE_K_CYCLES if cycles else _WHITE_BALANCE_K
    if str((spec.get("world") or {}).get("sky_type")) == "hdri":
        # A photographed sky is far less blue than the simulated one: keep the
        # white point close to neutral or the room turns pink/orange.
        wb = _WHITE_BALANCE_K_HDRI_CYCLES if cycles else _WHITE_BALANCE_K_HDRI
    # Daytime: the window is the key light, the fixtures only fill in (as in an
    # interior photo). Lamps at full power made day shots look like evenings,
    # orange and flat. At night (sun off) they stay at full power.
    day = float((spec.get("sun") or {}).get("strength", 1.0) or 0.0) > 0.0 \
        or float((spec.get("world") or {}).get("strength", 1.0) or 0.0) > 0.2
    if cycles and not day:
        wb = _WHITE_BALANCE_K_CYCLES_NIGHT      # lamp-lit: keep some warmth
    view.exposure = float(view.exposure) + boost
    # EEVEE lights a room mostly with the blue sky probe -> warm it to neutral;
    # Cycles bounces the warm lamps physically -> cool it slightly.
    if hasattr(view, "use_white_balance"):
        view.use_white_balance = True
        view.white_balance_temperature = wb
        scene["bir_wb_base"] = float(wb)
    try:
        from .lights import set_lights_strength, has_lights
        if has_lights():
            set_lights_strength(_DAY_LAMPS if day else 1.0)
    except Exception:
        pass
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
    scene["bir_interior"] = 1
    print("[Blendit] interior detected: exposure +%.2f, white balance %dK, GI on"
          % (boost, wb))
    return True
