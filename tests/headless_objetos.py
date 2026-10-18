"""Decor models: the SketchUp proxy is replaced by the real glTF model.

    blender --background --python tests/headless_objetos.py

Writes a small glTF "vase" (0.8 x 0.3 x 1.0 m, deliberately off-centre in its
own file), exports sketchup/test/cena_objetos.rb (proxy turned 90 deg, at
x=2 m, y=1 m) with the plugin's exporter, builds the scene and checks the
model's base centre lands on the proxy origin with the proxy's rotation, that
it keeps its own material in the realistic mode, that clay overrides it, and
that re-running prepare_scene does not duplicate it.
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
import bmesh  # noqa: E402

CHECKS = []


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok)))
    print("  %-62s %s %s" % (name, "OK" if ok else "FAIL", detail))


def make_vase(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    me = bpy.data.meshes.new("vaso")
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= 0.8
        v.co.y *= 0.3
        v.co.z = (v.co.z + 0.5) * 1.0
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("vaso", me)
    ob.location = (5.0, 5.0, 0.3)              # off-centre + floating in its own file
    bpy.context.scene.collection.objects.link(ob)
    m = bpy.data.materials.new("Ceramica_scan")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.7, 0.2, 0.1, 1)
    me.materials.append(m)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE")


def asset_meshes():
    return [o for o in bpy.context.scene.objects if o.get("bir_asset") and o.type == "MESH"]


def bbox(objs):
    from mathutils import Vector
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    return ([min(p[i] for p in pts) for i in range(3)], [max(p[i] for p in pts) for i in range(3)])


def main():
    ruby = shutil.which("ruby")
    if ruby is None:
        print("SKIP headless_objetos: ruby not available.")
        return
    tmp = tempfile.mkdtemp(prefix="blendit_obj_")
    od = os.path.join(tmp, "objetos")
    make_vase(os.path.join(od, "vaso_teste", "vaso_teste.gltf"))
    script = os.path.join(_ROOT, "sketchup", "test", "cena_objetos.rb")
    for modo in ("realistic", "white"):
        r = subprocess.run([ruby, script, os.path.join(tmp, modo), od, modo], cwd=os.path.dirname(script),
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout, r.stderr)
    from blender.pipeline import run
    bpy.ops.wm.read_factory_settings(use_empty=True)
    loaded, spec = run.build_scene(os.path.join(tmp, "realistic"))
    objs = asset_meshes()
    check("real model imported in place of the proxy", len(objs) == 1, str([o.name for o in objs]))
    if objs:
        mn, mx = bbox(objs)
        cx, cy = (mn[0] + mx[0]) / 2, (mn[1] + mx[1]) / 2
        check("base centre on the proxy origin (2, 1, 0)", abs(cx - 2.0) < 0.01 and abs(cy - 1.0) < 0.01 and abs(mn[2]) < 0.01,
              "centre (%.3f, %.3f), base z %.3f" % (cx, cy, mn[2]))
        check("proxy rotation applied (0.8 m side now along Y)", abs((mx[0] - mn[0]) - 0.3) < 0.01 and abs((mx[1] - mn[1]) - 0.8) < 0.01,
              "size %.3f x %.3f" % (mx[0] - mn[0], mx[1] - mn[1]))
        check("real height kept (1.0 m)", abs((mx[2] - mn[2]) - 1.0) < 0.01)
        mats = [m.name for m in objs[0].data.materials if m]
        check("keeps its own scanned material (realistic)", any(n.startswith("Ceramica_scan") for n in mats), str(mats))
    run.prepare_scene(loaded, spec)
    check("re-running prepare_scene does not duplicate it", len(asset_meshes()) == 1)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    run.build_scene(os.path.join(tmp, "white"))
    objs = asset_meshes()
    mats = [m.name for o in objs for m in o.data.materials if m]
    check("white (clay) mode overrides it like the rest of the model", objs and not any(n.startswith("Ceramica_scan") for n in mats), str(mats))
    shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in CHECKS if not ok]
    print("OBJETOS: %d checks, %d failed%s" % (len(CHECKS), len(failed), "" if not failed else " -> " + "; ".join(failed)))
    if failed:
        sys.exit(1)


main()
