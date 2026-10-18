"""'Materials in the render' modes, Blender side.

    blender --background --python tests/headless_modos_materiais.py

Exports one scene in the three modes with the SketchUp plugin's exporter (Ruby,
imitation SketchUp API, offline catalogue) and checks how Blender builds the
materials:
  * automatico: the catalogue texture is TINTED to the material's own colour
    (BIR_Tint node; the rendered average stays close to the project colour),
    with relief + roughness maps; the architect's own textured material keeps
    its UVs; glass is untouched;
  * preservar: no catalogue textures; name-based surfaces still on (as 0.4.3);
  * estrito: no name-based surfaces at all (the "Madeira freijo" colour stays a
    plain colour, nothing procedural).
SKIPs when `ruby` is not available.
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


def build(bundle):
    from blender.pipeline import run
    bpy.ops.wm.read_factory_settings(use_empty=True)
    run.build_scene(bundle)


def mat_of(prefix):
    for o in bpy.context.scene.objects:
        if o.type == "MESH" and o.data.materials:
            m = o.data.materials[0]
            if m and m.name.startswith(prefix):
                return m
    return None


def kinds(m):
    return {n.type for n in m.node_tree.nodes} if m and m.node_tree else set()


def main():
    ruby = shutil.which("ruby")
    if ruby is None:
        print("SKIP headless_modos_materiais: ruby not available.")
        return
    tmp = tempfile.mkdtemp(prefix="blendit_modos_")
    r = subprocess.run([ruby, os.path.join(_ROOT, "sketchup", "test", "teste_modo_materiais.rb"), tmp],
                       cwd=os.path.join(_ROOT, "sketchup", "test"), capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
        check("exporter produced the three bundles", False)
        return

    # ---- automatico
    build(os.path.join(tmp, "automatico"))
    piso = mat_of("Cor_M05")
    names = {n.name for n in piso.node_tree.nodes} if piso else set()
    check("auto: floor uses a catalogue texture, tinted (BIR_Tint)", "BIR_Tint" in names)
    k = kinds(piso)
    check("auto: relief (BUMP) and roughness map wired", "BUMP" in k and
          sum(1 for n in piso.node_tree.nodes if n.type == "TEX_IMAGE") >= 3)
    tint = next((n for n in piso.node_tree.nodes if n.name == "BIR_Tint"), None)
    if tint is not None:
        from blender.pipeline.materials import _image_mean_rgb_linear
        img = next(n for n in piso.node_tree.nodes if n.type == "TEX_IMAGE"
                   and n.outputs["Color"].is_linked and n.outputs["Color"].links[0].to_node == tint)
        mean = _image_mean_rgb_linear(img.image)
        fac = list(tint.inputs[7].default_value)[:3]
        res = [m * f for m, f in zip(mean, fac)]
        import json
        spec = json.load(open(os.path.join(tmp, "automatico", "scene_spec.json"), encoding="utf-8"))
        base = next(x for x in spec["materials"] if x["name"] == "Cor_M05")["base_color"]
        check("auto: tinted texture averages to the project colour",
              all(abs(a - b) < 1e-3 for a, b in zip(res, base)), "%s vs %s" % (
                  [round(v, 4) for v in res], [round(v, 4) for v in base]))
    px = mat_of("Porcelanato X")
    uvn = any(n.type == "UVMAP" for n in px.node_tree.nodes) if px else False
    check("auto: architect's own texture keeps the SketchUp UVs", uvn)
    check("auto: own texture is NOT tinted", px is not None and "BIR_Tint" not in {n.name for n in px.node_tree.nodes})

    # ---- preservar
    build(os.path.join(tmp, "preservar"))
    piso = mat_of("Cor_M05")
    check("preservar: no catalogue texture on colour-only materials",
          piso is not None and "BIR_Tint" not in {n.name for n in piso.node_tree.nodes}
          and not any(n.type == "TEX_IMAGE" for n in piso.node_tree.nodes))
    wood = mat_of("Madeira freij")
    check("preservar: name-based procedural surface kept (as in 0.4.3)",
          wood is not None and any(n.type in ("TEX_WAVE", "TEX_NOISE", "TEX_VORONOI") for n in wood.node_tree.nodes))

    # ---- estrito
    build(os.path.join(tmp, "estrito"))
    wood = mat_of("Madeira freij")
    # realism.py adds its own subtle imperfection noise far left of the tree
    # (x < -1000) in every photoreal mode - that is not a material choice; ignore it
    proc = [n.type for n in wood.node_tree.nodes if n.type.startswith("TEX_")
            and not n.location.x < -1000] if wood else ["?"]
    check("estrito: no name-based surface (plain project colour)", wood is not None and not proc, str(proc))
    shutil.rmtree(tmp, ignore_errors=True)

    failed = [n for n, ok in CHECKS if not ok]
    print("MODOS: %d checks, %d failed%s" % (len(CHECKS), len(failed),
                                              "" if not failed else " -> " + "; ".join(failed)))
    if failed:
        sys.exit(1)


main()
