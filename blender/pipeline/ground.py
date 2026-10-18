"""Pipeline step: a ground plane so the model is grounded and casts shadows.

Sized to the model footprint and placed at its base Z. Receives the sun's shadow
(the single biggest "it's floating in space" fix). Added AFTER camera framing so
it doesn't enlarge the framed bounding box, and it's not in node_to_object so the
material presets (realistic / white / shadow) never override it.
"""
import bpy
import bmesh

from .camera import _scene_bbox

_GROUND_NAME = "BIR_Ground"


def add_ground(spec=None):
    # A model that brings its OWN site (a site link / toposolid - the Revit side
    # sets world.has_site) needs no artificial ground: a flat plane would
    # z-fight the real terrain and read as a flood plane on any sloped site.
    world = (spec or {}).get("world") or {}
    under_site = False
    if world.get("has_site"):
        _remove_existing()
        # Opt-in (SketchUp adapter): the model's own terrain is usually a small lot,
        # so without a ground the horizon renders as a void. `ground_under_site`
        # keeps a plane just BELOW the lowest point - out of the terrain's way (no
        # z-fight), but it fills the view past the lot's edge.
        if not world.get("ground_under_site"):
            return None
        under_site = True
    bb = _scene_bbox()
    if bb is None:
        return None
    mn, mx = bb
    cx = (mn.x + mx.x) / 2.0
    cy = (mn.y + mx.y) / 2.0
    base_z = mn.z - (0.03 if under_site else 0.0)
    footprint = max(mx.x - mn.x, mx.y - mn.y, 1.0)
    half = footprint * 5.0  # plane spans footprint*10 - reads as an infinite ground

    _remove_existing()       # idempotent: never stack two grounds

    # Build the plane via the DATA API (bmesh), not bpy.ops.mesh.primitive_plane_add
    # + bpy.context.active_object: the operator path needs a real window/area context
    # and is unreliable in the live session's startup-timer context (the same trap
    # that silently broke object.join). A missing ground = the model floats with no
    # shadow catcher, so this matters for the live look.
    me = bpy.data.meshes.new(_GROUND_NAME)
    bm = bmesh.new()
    v1 = bm.verts.new((-half, -half, 0.0))
    v2 = bm.verts.new((half, -half, 0.0))
    v3 = bm.verts.new((half, half, 0.0))
    v4 = bm.verts.new((-half, half, 0.0))
    bm.faces.new((v1, v2, v3, v4))
    bm.to_mesh(me)
    bm.free()

    plane = bpy.data.objects.new(_GROUND_NAME, me)
    plane.location = (cx, cy, base_z)
    bpy.context.scene.collection.objects.link(plane)
    plane.data.materials.append(_ground_material())
    if world.get("hdri_ground") and world.get("sky_type") == "hdri":
        # Landscape sky (city / garden photographed at eye level): the photo
        # carries its own ground and buildings. The plane stays only to catch
        # the model's shadows (Cycles) and is hidden from the camera, so the
        # landscape shows through windows and past the model.
        plane.is_shadow_catcher = True
        engine = str(((spec or {}).get("render") or {}).get("engine") or "").upper()
        if engine != "CYCLES":
            plane.visible_camera = False
        plane["bir_hdri_ground"] = True
    return plane


def _remove_existing():
    obj = bpy.data.objects.get(_GROUND_NAME)
    if obj is None:
        return
    me = obj.data
    try:
        bpy.data.objects.remove(obj, do_unlink=True)
        if me is not None and me.users == 0:
            bpy.data.meshes.remove(me)
    except Exception:
        pass


def _ground_material():
    mat = bpy.data.materials.new("BIR_Ground")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (400, 0)
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Base Color"].default_value = (0.40, 0.40, 0.40, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.75
    return mat
