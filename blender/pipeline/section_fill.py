"""Section fill ("poché") for a cut model in perspective.

When the host cut the model with a section plane (the SketchUp adapter clips
the geometry and sets render.section_fill), walls and slabs are left open along
the cut: looking through the cut you see the INSIDE (back faces) of each solid.
Painting every back face one flat colour makes the cut read as a solid fill -
the same trick SketchUp itself uses for its section fill.

Applied after the preset (presets rebuild materials), on every material of the
imported model; the ground and line-art objects are left alone. Idempotent.
"""
import bpy

_TAG = "bir_section_fill"
_NODE = "BIR_SectionFill"


def apply_section_fill(loaded, spec):
    rgb = (spec.get("render") or {}).get("section_fill")
    if not rgb:
        return 0
    col = (float(rgb[0]), float(rgb[1]), float(rgb[2]), 1.0)
    mats = set()
    for obj in (loaded.node_to_object or {}).values():
        try:                    # merged-away objects are dead references
            if obj.type != "MESH" or obj.name.startswith("BIR_Ground"):
                continue
            for slot in obj.material_slots:
                if slot.material is not None:
                    mats.add(slot.material)
        except ReferenceError:
            continue
    # merged objects (merge.py) are new objects: catch them by scanning the scene
    for obj in bpy.context.scene.objects:
        # merged objects are "BIR_Mat_<id>"; only the ground plane is skipped
        if obj.type == "MESH" and not obj.name.startswith("BIR_Ground"):
            for slot in obj.material_slots:
                if slot.material is not None:
                    mats.add(slot.material)
    done = 0
    for mat in mats:
        if _wrap(mat, col):
            done += 1
    return done


def _wrap(mat, col):
    if not mat.use_nodes or mat.node_tree is None:
        return False
    nt = mat.node_tree
    if _NODE in nt.nodes:                       # already wrapped: refresh colour
        nt.nodes[_NODE + "_Col"].inputs["Color"].default_value = col
        return True
    out = None
    for n in nt.nodes:
        if n.type == "OUTPUT_MATERIAL" and getattr(n, "is_active_output", True):
            out = n
            break
    if out is None or not out.inputs["Surface"].is_linked:
        return False
    src = out.inputs["Surface"].links[0].from_socket
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    geo.name = _NODE + "_Geo"
    fill = nt.nodes.new("ShaderNodeEmission")
    fill.name = _NODE + "_Col"
    fill.inputs["Color"].default_value = col
    fill.inputs["Strength"].default_value = 1.0
    mix = nt.nodes.new("ShaderNodeMixShader")
    mix.name = _NODE
    x, y = out.location
    geo.location = (x - 260, y + 260)
    fill.location = (x - 260, y - 160)
    mix.location = (x - 80, y)
    out.location = (x + 160, y)
    nt.links.new(geo.outputs["Backfacing"], mix.inputs["Fac"])
    nt.links.new(src, mix.inputs[1])
    nt.links.new(fill.outputs["Emission"], mix.inputs[2])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])
    try:
        mat.use_backface_culling = False
    except Exception:
        pass
    mat[_TAG] = True
    return True
