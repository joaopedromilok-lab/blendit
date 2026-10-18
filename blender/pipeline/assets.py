"""Pipeline step: ready-made 3D models placed in the scene (`spec.assets`).

The SketchUp side lets the architect drop a LIGHT proxy (a box the size of the
real object with its photo) for decor models from Poly Haven - plants, vases,
books, lamps. The bundle carries the real model (glTF, under assets/<id>/) and
the proxy's placement; here the real model is imported and put exactly where
the proxy was: its base centre on the proxy origin, with the proxy's rotation
and scale.

The models keep their own (scanned, PBR) materials in the lit modes; they are
registered in loaded.node_to_object so the clay / white presets override them
like the rest of the model. Idempotent: re-running prepare_scene replaces them.
"""
import os

import bpy
from mathutils import Matrix, Vector

ASSET_TAG = "bir_asset"


def _remove_existing():
    for o in [o for o in bpy.data.objects if o.get(ASSET_TAG)]:
        data = o.data
        bpy.data.objects.remove(o, do_unlink=True)
        if data is not None and getattr(data, "users", 1) == 0:
            try:
                bpy.data.meshes.remove(data)
            except Exception:
                pass


def _placement(values, scale):
    """Column-major 4x4 (source units) -> Blender Matrix (metres)."""
    m = Matrix([[float(values[c * 4 + r]) for c in range(4)] for r in range(4)])
    for r in range(3):
        m[r][3] *= scale
    return m


def _bbox(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs if o.type == "MESH" for c in o.bound_box]
    if not pts:
        return None
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


def import_assets(loaded, spec, scale):
    """Import every asset of the spec. Returns the number placed."""
    _remove_existing()
    assets = spec.get("assets") or []
    base_dir = spec.get("_override_dir")
    if not assets or not base_dir:
        return 0
    placed = 0
    for i, a in enumerate(assets):
        path = os.path.join(base_dir, str(a.get("uri") or "").replace("/", os.sep))
        if not os.path.isfile(path) or len(a.get("matrix") or []) != 16:
            print("[Blendit] asset %s skipped (file or placement missing)" % a.get("id"))
            continue
        before = set(bpy.data.objects)
        try:
            bpy.ops.import_scene.gltf(filepath=path)
        except Exception as e:
            print("[Blendit] asset %s failed to import: %s" % (a.get("id"), e))
            continue
        new = [o for o in bpy.data.objects if o not in before]
        if not new:
            continue
        bb = _bbox(new)
        offset = Matrix.Identity(4)
        if bb is not None:
            mn, mx = bb
            offset = Matrix.Translation(Vector((-(mn.x + mx.x) / 2.0, -(mn.y + mx.y) / 2.0, -mn.z)))
        root = bpy.data.objects.new("BIR_Asset_%s_%d" % (a.get("id"), i), None)
        bpy.context.scene.collection.objects.link(root)
        for o in new:
            if o.parent is None:
                o.matrix_world = offset @ o.matrix_world
                o.parent = root
            o[ASSET_TAG] = str(a.get("id"))
        root[ASSET_TAG] = str(a.get("id"))
        root.matrix_world = _placement(a["matrix"], scale)
        for o in new:
            if o.type == "MESH":
                loaded.node_to_object["asset:%d:%s" % (i, o.name)] = o
        placed += 1
    if placed:
        print("[Blendit] %d decor model(s) placed" % placed)
    return placed
