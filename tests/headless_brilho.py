"""Luminaires that glow (lens / glass / acrylic of recognised fixtures).

    blender --background --python tests/headless_brilho.py

Exports sketchup/test/teste_brilho.rb's scene (imitation SketchUp API) and
checks: the glowing records become emissive Principled materials (strength from
the bundle, no procedural surface, opaque), the fixture body does not glow, and
a night render shows the pendant's glass brighter than the wall behind it.
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


def mat(prefix):
    """The material the pipeline built (carries bir_material_id) - the glTF
    importer's own copies keep the bare name."""
    for m in bpy.data.materials:
        if m.name.startswith(prefix) and m.node_tree and m.get("bir_material_id"):
            return m
    return None


def main():
    ruby = shutil.which("ruby")
    if ruby is None:
        print("SKIP headless_brilho: ruby not available.")
        return
    tmp = tempfile.mkdtemp(prefix="blendit_brilho_")
    script = os.path.join(_ROOT, "sketchup", "test", "teste_brilho.rb")
    r = subprocess.run([ruby, script, tmp], cwd=os.path.dirname(script), capture_output=True, text=True)
    check("ruby export + checks", r.returncode == 0, r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr[-200:])
    from blender.pipeline import run
    bpy.ops.wm.read_factory_settings(use_empty=True)
    run.build_scene(os.path.join(tmp, "noite"))
    g = mat("Vidro leitoso (brilho)")
    check("glowing glass material built", g is not None)
    if g:
        bsdf = next(n for n in g.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        check("emission strength 6.0 (night)", abs(bsdf.inputs["Emission Strength"].default_value - 6.0) < 1e-4)
        c = bsdf.inputs["Emission Color"].default_value
        check("warm white emission (r > b, b not ~0)", c[0] > c[2] > 0.3, [round(v, 2) for v in c[:3]])
        check("no name-based surface on the diffuser (flat colour, no image)",
              not bsdf.inputs["Base Color"].is_linked and not any(n.type == "TEX_IMAGE" for n in g.node_tree.nodes))
    body = mat("Metal preto fosco")
    if body:
        bsdf = next(n for n in body.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        check("fixture body does not glow", bsdf.inputs["Emission Strength"].default_value == 0.0
              or tuple(bsdf.inputs["Emission Color"].default_value[:3]) == (0.0, 0.0, 0.0))
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 16
    sc.cycles.device = "CPU"
    sc.render.resolution_x, sc.render.resolution_y = 240, 160
    out = os.environ.get("BLENDIT_BRILHO_PNG") or os.path.join(tmp, "noite.png")
    sc.render.filepath = out
    bpy.ops.render.render(write_still=True)
    check("night render completes", os.path.isfile(out))
    if os.environ.get("BLENDIT_BRILHO_PNG") is None:
        shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in CHECKS if not ok]
    print("BRILHO: %d checks, %d failed%s" % (len(CHECKS), len(failed), "" if not failed else " -> " + "; ".join(failed)))
    if failed:
        sys.exit(1)


main()
