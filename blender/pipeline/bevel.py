"""Pipeline step: rounded edges ("bevel") for the photoreal looks.

Real objects never have razor-sharp edges: a few millimetres of rounding catch
the light and are one of the strongest cues that separate a photo from a 3D
render. Cycles can fake that rounding at render time with the Bevel shader
node (no geometry change), so every material of the model gets one in its
normal chain. EEVEE passes the normal through unchanged, so it is harmless
there. Idempotent; re-applied after presets rebuild materials.
"""
import bpy

LIT_MODES = ("realistic", "specular")
RADIUS_M = 0.006
_NODE = "BIR_Bevel"


def apply_bevel(spec):
    mode = str((spec.get("render") or {}).get("mode", "realistic"))
    if mode not in LIT_MODES:
        return 0
    done = 0
    seen = set()
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.name.startswith("BIR_Ground"):
            continue
        for slot in obj.material_slots:
            mat = slot.material
            if mat is None or mat.name in seen:
                continue
            seen.add(mat.name)
            if _add(mat):
                done += 1
    return done


def _add(mat):
    if not mat.use_nodes or mat.node_tree is None:
        return False
    nt = mat.node_tree
    if _NODE in nt.nodes:
        return True
    bsdfs = [n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"]
    if not bsdfs:
        return False
    for i, bsdf in enumerate(bsdfs):
        bev = nt.nodes.new("ShaderNodeBevel")
        bev.name = _NODE if i == 0 else "%s.%d" % (_NODE, i)
        bev.location = (bsdf.location[0] - 220, bsdf.location[1] - 360)
        bev.inputs["Radius"].default_value = RADIUS_M
        if hasattr(bev, "samples"):
            bev.samples = 6
        normal_in = bsdf.inputs["Normal"]
        if normal_in.is_linked:                 # keep the bump / relief chain
            src = normal_in.links[0].from_socket
            nt.links.new(src, bev.inputs["Normal"])
        nt.links.new(bev.outputs["Normal"], normal_in)
    return True
