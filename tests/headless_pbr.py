"""SketchUp 2025 PBR maps (normal / roughness / metallic / AO), Blender side.

    blender --background --python tests/headless_pbr.py

Exports sketchup/test/cena_pbr.rb with the plugin's own exporter (imitation
SketchUp API) and checks the node graph the pipeline builds:
  * textured wall: normal map (tangent, UVMap, DirectX green flipped, strength
    1.5), roughness = factor x map (no mean rescaling), metallic = factor x map,
    AO multiplying the colour by its strength;
  * colour-only plate: roughness + metallic maps without a colour image;
  * a plain material stays a flat colour; a render completes.
Needs `ruby` on PATH; SKIPs cleanly otherwise.
"""
import os
import shutil
import subprocess
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


def material(prefix):
    for o in bpy.context.scene.objects:
        if o.type == "MESH" and o.data.materials:
            for m in o.data.materials:
                if m and m.name.startswith(prefix) and m.node_tree:
                    return m
    return None


def feeds(mat, socket_name):
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    s = bsdf.inputs[socket_name]
    return s.links[0].from_node if s.is_linked else None


def upstream(mat, socket_name):
    """Names of every node feeding a BSDF input (the pipeline adds bevel /
    micro-bump nodes in front of Normal, so look through the whole chain)."""
    bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    seen, todo = set(), [l.from_node for l in bsdf.inputs[socket_name].links]
    while todo:
        n = todo.pop()
        if n.name in seen:
            continue
        seen.add(n.name)
        for i in n.inputs:
            todo.extend(l.from_node for l in i.links)
    return seen


def main():
    ruby = shutil.which("ruby")
    if ruby is None:
        print("SKIP headless_pbr: ruby not available.")
        return
    tmp = tempfile.mkdtemp(prefix="blendit_pbr_")
    out = os.path.join(tmp, "pacote")
    script = os.path.join(_ROOT, "sketchup", "test", "cena_pbr.rb")
    r = subprocess.run([ruby, script, out], cwd=os.path.dirname(script), capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        check("export", False)
        return
    from blender.pipeline import run
    bpy.ops.wm.read_factory_settings(use_empty=True)
    run.build_scene(out)

    wall = material("Revestimento PBR")
    check("wall material built", wall is not None)
    nodes = {n.name: n for n in wall.node_tree.nodes}
    nm = nodes.get("BIR_NormalMap")
    check("normal map node: tangent space on the UVMap layer", nm is not None and nm.space == "TANGENT" and nm.uv_map == "UVMap")
    check("normal strength = 1.5", nm is not None and abs(nm.inputs["Strength"].default_value - 1.5) < 1e-4)
    flip = any(n.type == "SEPARATE_COLOR" for n in wall.node_tree.nodes)
    check("DirectX normal: green channel flipped", flip)
    check("Normal input fed by the normal map (through bevel/bump)", "BIR_NormalMap" in upstream(wall, "Normal"))
    rough = feeds(wall, "Roughness")
    check("roughness = factor (0.8) x map", rough is not None and rough.type == "MATH" and abs(rough.inputs[1].default_value - 0.8) < 1e-4,
          rough and rough.inputs[1].default_value)
    met = feeds(wall, "Metallic")
    check("metallic = factor (0.5) x map", met is not None and met.name == "BIR_Metallic" and abs(met.inputs[1].default_value - 0.5) < 1e-4)
    base = feeds(wall, "Base Color")
    check("AO multiplies the colour (strength 0.7)", base is not None and base.name == "BIR_AO" and abs(base.inputs[0].default_value - 0.7) < 1e-4,
          base and base.name)

    plate = material("Chapa met")
    check("plate (no colour image) built", plate is not None)
    check("plate: metallic map wired", plate is not None and feeds(plate, "Metallic") is not None)
    check("plate: roughness map wired", plate is not None and feeds(plate, "Roughness") is not None)
    check("plate: colour stays the flat colour", plate is not None and feeds(plate, "Base Color") is None)
    check("plate: no normal map (none given)", plate is not None and "BIR_NormalMap" not in upstream(plate, "Normal"))

    plain = material("Pintura comum")
    check("plain material unaffected (no image nodes)", plain is not None and
          not any(n.type == "TEX_IMAGE" for n in plain.node_tree.nodes))

    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 4
    sc.cycles.device = "CPU"
    sc.render.resolution_x, sc.render.resolution_y = 120, 80
    sc.render.filepath = os.path.join(tmp, "pbr.png")
    try:
        bpy.ops.render.render(write_still=True)
        check("render completes", os.path.isfile(sc.render.filepath))
    except Exception as e:
        check("render completes", False, str(e))
    shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in CHECKS if not ok]
    print("PBR: %d checks, %d failed%s" % (len(CHECKS), len(failed), "" if not failed else " -> " + "; ".join(failed)))
    if failed:
        sys.exit(1)


main()
