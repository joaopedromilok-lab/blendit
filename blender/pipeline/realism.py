"""Pipeline step: the small imperfections that make a render read as a photo.

  * surfaces: real paint, lacquer, plastic or stone is never perfectly even -
    its shine varies a little across the surface and it has a faint micro
    texture. Flat CG materials (one roughness value everywhere) are a big
    "this is 3D" cue. Every material whose roughness / normal is still a plain
    value gets a subtle, large-scale roughness variation and a very faint
    micro bump (millimetres, barely visible - it breaks up reflections);
  * camera: a soft bloom around very bright spots (lamps, sunlit windows),
    as every real lens does.

Photoreal modes only; idempotent (tagged nodes / a named compositor group).
"""
import bpy

LIT_MODES = ("realistic", "specular")
_TAG = "BIR_Imperfeicao"
_COMP = "BIR_Fotografia"


def apply_realism(spec):
    rspec = spec.get("render", {}) or {}
    if str(rspec.get("mode", "realistic")) not in LIT_MODES:
        _remove_bloom()
        return 0
    n = 0
    seen = set()
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.name.startswith(("BIR_Ground", "BIR_AutoCeiling")):
            continue
        for slot in obj.material_slots:
            mat = slot.material
            if mat is None or mat.name in seen:
                continue
            seen.add(mat.name)
            if _imperfect(mat):
                n += 1
    try:
        _bloom(bpy.context.scene)
    except Exception as e:                    # compositor API changes between versions
        print("[Blendit] bloom skipped: %s" % e)
    return n


def _imperfect(mat):
    if not mat.use_nodes or mat.node_tree is None:
        return False
    nt = mat.node_tree
    if _TAG in nt.nodes:
        return True
    bsdf = next((x for x in nt.nodes if x.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None or float(bsdf.inputs["Metallic"].default_value) > 0.9 \
            and float(bsdf.inputs["Roughness"].default_value) < 0.08:
        return False                          # mirrors stay perfect
    tc = nt.nodes.new("ShaderNodeTexCoord")
    tc.name = _TAG
    tc.location = (-1300, -700)
    rough = bsdf.inputs["Roughness"]
    if not rough.is_linked:
        base = float(rough.default_value)
        big = nt.nodes.new("ShaderNodeTexNoise")
        big.location = (-1100, -700)
        big.inputs["Scale"].default_value = 1.6           # ~60 cm smudges
        big.inputs["Detail"].default_value = 3.0
        nt.links.new(tc.outputs["Object"], big.inputs["Vector"])
        mr = nt.nodes.new("ShaderNodeMapRange")
        mr.location = (-900, -700)
        spread = 0.06 + 0.12 * base                       # matte varies more
        mr.inputs["To Min"].default_value = max(0.02, base - spread)
        mr.inputs["To Max"].default_value = min(1.0, base + spread)
        nt.links.new(big.outputs["Fac"], mr.inputs["Value"])
        nt.links.new(mr.outputs["Result"], rough)
    normal = bsdf.inputs["Normal"]
    if not normal.is_linked:
        fine = nt.nodes.new("ShaderNodeTexNoise")
        fine.location = (-1100, -950)
        fine.inputs["Scale"].default_value = 180.0        # ~5 mm grain
        fine.inputs["Detail"].default_value = 2.0
        nt.links.new(tc.outputs["Object"], fine.inputs["Vector"])
        bump = nt.nodes.new("ShaderNodeBump")
        bump.location = (-850, -950)
        bump.inputs["Strength"].default_value = 0.03
        bump.inputs["Distance"].default_value = 0.0005
        nt.links.new(fine.outputs["Fac"], bump.inputs["Height"])
        nt.links.new(bump.outputs["Normal"], normal)
    return True


def _remove_bloom():
    scene = bpy.context.scene
    try:
        if getattr(scene, "compositing_node_group", None) is not None \
                and scene.compositing_node_group.name.startswith(_COMP):
            scene.compositing_node_group = None
    except Exception:
        pass


def _bloom(scene):
    """Soft glow around highlights. Blender 5 compositor (node group)."""
    if not hasattr(scene, "compositing_node_group"):
        return False
    ng = bpy.data.node_groups.get(_COMP)
    if ng is None:
        ng = bpy.data.node_groups.new(_COMP, "CompositorNodeTree")
        ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        rl = ng.nodes.new("CompositorNodeRLayers")
        rl.location = (-300, 0)
        gl = ng.nodes.new("CompositorNodeGlare")
        gl.location = (0, 0)
        _set(gl, "Type", "Bloom")
        _set(gl, "Quality", "High")
        _set(gl, "Threshold", 1.2)
        _set(gl, "Strength", 0.25)
        _set(gl, "Size", 0.5)
        out = ng.nodes.new("NodeGroupOutput")
        out.location = (300, 0)
        ng.links.new(rl.outputs["Image"], gl.inputs["Image"])
        ng.links.new(gl.outputs["Image"], out.inputs[0])
    scene.compositing_node_group = ng
    return True


def _set(node, name, value):
    sock = node.inputs.get(name)
    if sock is not None:
        try:
            sock.default_value = value
        except Exception:
            pass
