"""SketchUp texture coordinates (UVs), end to end on the Blender side.

    blender --background --python tests/headless_uvs.py

Exports a small SketchUp scene with the plugin's own exporter (Ruby, against
the imitation SketchUp API in sketchup/test) - a TV whose picture (left half
red, right half blue) is stretched over the screen, the way an architect fits
an image with "Texture position" - and checks:
  * the bundle's TEXCOORD_0 arrives as the "UVMap" layer with SketchUp's own
    (u, v) - the glTF v flip is undone exactly once;
  * the material samples the image through those UVs (FLAT), not the
    real-world box projection;
  * a render shows the picture ONCE: red on the left half of the screen, blue
    on the right (the old box projection tiled it);
  * an OLD bundle (no TEXCOORD, no `uv` flag) still imports and renders with
    the box projection - backward compatibility / fallback.

Needs `ruby` on PATH (to run the exporter); SKIPs cleanly otherwise.
"""
import json
import os
import shutil
import struct
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
    print("  %-60s %s %s" % (name, "OK" if ok else "FAIL", detail))


def export_bundle(out_dir):
    ruby = shutil.which("ruby")
    if ruby is None:
        return False
    script = os.path.join(_ROOT, "sketchup", "test", "cena_uvs.rb")
    r = subprocess.run([ruby, script, out_dir], cwd=os.path.dirname(script),
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
    return r.returncode == 0


def make_old_bundle(src, dst):
    """Same scene as a pre-UV bundle: TEXCOORD_0 and the `uv` flag removed."""
    shutil.copytree(src, dst)
    p = os.path.join(dst, "scene.glb")
    b = open(p, "rb").read()
    jl = struct.unpack("<I", b[12:16])[0]
    j = json.loads(b[20:20 + jl])
    rest = b[20 + jl:]
    for m in j["meshes"]:
        for prim in m["primitives"]:
            prim["attributes"].pop("TEXCOORD_0", None)
    js = json.dumps(j).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js + rest
    open(p, "wb").write(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)
    sp = os.path.join(dst, "scene_spec.json")
    spec = json.load(open(sp, encoding="utf-8"))
    for mat in spec["materials"]:
        for entry in (mat.get("maps") or {}).values():
            if isinstance(entry, dict):
                entry.pop("uv", None)
    json.dump(spec, open(sp, "w", encoding="utf-8"))


def tv_material():
    """The material the pipeline actually assigned to the screen object."""
    for o in bpy.context.scene.objects:
        if o.type == "MESH" and o.name.startswith("BIR_Mat") and o.data.materials:
            m = o.data.materials[0]
            if m and m.name.startswith("Tela TV") and m.node_tree:
                return m
    return None


def image_vector_source(mat):
    img = next((n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE"), None)
    if img is None or not img.inputs["Vector"].is_linked:
        return None, None
    return img.inputs["Vector"].links[0].from_node.type, img.projection


def build(bundle):
    from blender.pipeline import run
    bpy.ops.wm.read_factory_settings(use_empty=True)
    return run.build_scene(bundle)


def render_halves(path):
    """Render small with Cycles; -> (mean rgb of the screen's left half, right half)."""
    import numpy as np
    sc = bpy.context.scene
    sc.cycles.samples = 8
    sc.cycles.device = "CPU"
    sc.render.resolution_x, sc.render.resolution_y = 160, 90
    sc.render.filepath = path
    sc.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(write_still=True)
    im = bpy.data.images.load(path)
    px = np.array(im.pixels[:], dtype=np.float32).reshape(im.size[1], im.size[0], 4)[:, :, :3]
    bpy.data.images.remove(im)
    h, w = px.shape[:2]
    band = px[int(h * 0.40):int(h * 0.60)]           # screen sits mid-frame
    return band[:, int(w * 0.18):int(w * 0.40)].mean(axis=(0, 1)), \
        band[:, int(w * 0.60):int(w * 0.82)].mean(axis=(0, 1))


def main():
    tmp = tempfile.mkdtemp(prefix="blendit_uvs_")
    new_b = os.path.join(tmp, "novo")
    old_b = os.path.join(tmp, "antigo")
    if not export_bundle(new_b):
        print("SKIP headless_uvs: ruby not available (the SketchUp exporter is Ruby).")
        return
    make_old_bundle(new_b, old_b)

    # ---- new bundle: UVs
    build(new_b)
    obj = next((o for o in bpy.context.scene.objects
                if o.type == "MESH" and not o.name.startswith("BIR_")
                or o.name.startswith("BIR_Mat")), None)
    mesh = obj.data if obj else None
    has_uv = bool(mesh and "UVMap" in mesh.uv_layers)
    check("7/new: bundle UVs imported as the 'UVMap' layer", has_uv)
    if has_uv:
        layer = mesh.uv_layers["UVMap"].data
        corners = {}
        for loop in mesh.loops:
            co = obj.matrix_world @ mesh.vertices[loop.vertex_index].co
            corners[(round(co.x, 2), round(co.z, 2))] = tuple(round(v, 4) for v in layer[loop.index].uv)
        # screen corners: x 0..1.2 m, z 0.55..1.25 m -> SketchUp UV (0,0)..(1,1)
        bl = corners.get((0.0, 0.55))
        tr_ = corners.get((1.2, 1.25))
        check("UV at screen bottom-left == (0, 0)", bl == (0.0, 0.0), str(bl))
        check("UV at screen top-right == (1, 1)  (v flip undone once)", tr_ == (1.0, 1.0), str(tr_))
    mat = tv_material()
    src, proj = image_vector_source(mat) if mat else (None, None)
    check("material samples the picture through the UVs (FLAT)", src == "UVMAP" and proj == "FLAT",
          "%s/%s" % (src, proj))
    left, right = render_halves(os.path.join(tmp, "novo.png"))
    check("render: left half of the screen is RED (picture not tiled)", left[0] - left[2] > 0.05,
          "rgb %s" % [round(float(v), 3) for v in left])
    check("render: right half of the screen is BLUE", right[2] - right[0] > 0.05,
          "rgb %s" % [round(float(v), 3) for v in right])

    # ---- old bundle: no UVs -> box projection, no failure
    ok = True
    try:
        build(old_b)
    except Exception as e:  # pragma: no cover - reported as a failed check
        ok = False
        print(e)
    check("8/old bundle (no TEXCOORD, no flag) imports without error", ok)
    if ok:
        mesh = next((o.data for o in bpy.context.scene.objects
                     if o.type == "MESH" and o.name.startswith("BIR_Mat")), None)
        check("old bundle: no UV layer", mesh is not None and "UVMap" not in mesh.uv_layers)
        mat = tv_material()
        src, proj = image_vector_source(mat) if mat else (None, None)
        check("old bundle: falls back to the real-world BOX projection", src == "MAPPING" and proj == "BOX",
              "%s/%s" % (src, proj))
        try:
            render_halves(os.path.join(tmp, "antigo.png"))
            check("old bundle renders", True)
        except Exception as e:
            check("old bundle renders", False, str(e))

    shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in CHECKS if not ok]
    print("UVS: %d checks, %d failed%s" % (len(CHECKS), len(failed),
                                            "" if not failed else " -> " + "; ".join(failed)))
    if failed:
        sys.exit(1)


main()
