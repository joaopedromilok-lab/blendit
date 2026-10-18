"""Pipeline step: SceneSpec materials -> Principled BSDF, assigned by element.

Contract 0.1.0 numeric mapping (base_color, metallic, roughness, transparency,
ior, emissive) drives the Principled BSDF. Transparency routes to physical
transmission (glass), not flat alpha.

SURFACE TEXTURE, in precedence order:
  1. an explicit per-material override from the N-panel ("plain" or a library key),
  2. REAL Revit textures - the record's `maps` block (contract 0.2.0: the
     appearance-asset bitmaps bundled under textures/), box-projected at their
     real-world scale on Object coordinates (== world metres; Revit gives no UVs,
     and real-world box mapping is exactly how Revit maps them itself),
  3. the curated `material_library` surface matched on the Revit material *name*,
     tinted by the Revit base colour.

The richer category-aware mapping from the brief's Appendix D (mirror / water
distinct, Bevel edge highlights) keys off a deferred `appearance_class` field.

The SceneSpec is the source of truth, so this REPLACES whatever materials the
glTF importer created.
"""
import json
import os

import bpy

from . import material_library

# Principled v2 (Blender 4.x) socket names.
_TRANSMISSION = "Transmission Weight"

# Per-material surface overrides chosen in the interactive N-panel persist here, next
# to the bundle, so every path (live re-apply, mode switch, Render Final, headless
# Render View) agrees. {material_id: "auto"|"plain"|"brick"|"wood"|...}.
OVERRIDES_FILENAME = "material_overrides.json"


def load_overrides(dirpath):
    if not dirpath:
        return {}
    try:
        with open(os.path.join(dirpath, OVERRIDES_FILENAME)) as f:
            return json.load(f) or {}
    except Exception:
        return {}


def save_overrides(dirpath, mapping):
    if not dirpath:
        return
    try:
        with open(os.path.join(dirpath, OVERRIDES_FILENAME), "w") as f:
            json.dump(mapping, f, indent=2)
    except Exception:
        pass


def _overrides_for(spec):
    # `_override_dir` is a Blender-side runtime annotation (set by run.import_scene /
    # the live session), NOT a contract field.
    return load_overrides((spec or {}).get("_override_dir"))


def _rgba(rgb, a=1.0):
    return (float(rgb[0]), float(rgb[1]), float(rgb[2]), float(a))


def build_material(rec, engine="CYCLES", surface="auto", base_dir=None, automatic=True):
    """`surface` selects the texture source: "auto" prefers the record's real Revit
    maps (falling back to the name-matched library), "plain" forces flat colour, any
    other value forces that specific library surface (the N-panel override).
    `base_dir` is the bundle dir map uris resolve against."""
    mat = bpy.data.materials.new(rec.get("name") or rec.get("id") or "RevitMaterial")
    # The contract material id, queryable after the by-id build dict is gone -
    # the live-sync applier assigns materials to patched-in objects by this.
    mat["bir_material_id"] = rec.get("id") or ""
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (400, 0)
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    bsdf.inputs["Base Color"].default_value = _rgba(rec.get("base_color", [0.8, 0.8, 0.8]))
    bsdf.inputs["Metallic"].default_value = float(rec.get("metallic", 0.0))
    bsdf.inputs["IOR"].default_value = float(rec.get("ior", 1.45))

    transparency = float(rec.get("transparency", 0.0))
    roughness = max(0.03, min(1.0, float(rec.get("roughness", 0.5))))
    # automatic=False ("preservar estritamente"): the material exactly as the
    # source app defined it - no name-based surfaces, curtain or upholstery cues.
    if not automatic and surface == "auto":
        surface = "auto_maps_only"
    if surface == "auto" and str(rec.get("appearance_class") or "") == "emissive":
        # Lit luminaire diffuser (lens / glass / acrylic): its own maps at most,
        # never a name-based procedural surface.
        surface = "auto_maps_only"
    fabric = curtain_kind(rec) if automatic else None
    if fabric:
        # Curtains are fabric, never glass - even when the source material is
        # semi-transparent.
        transparency = 0.0
        roughness = max(roughness, 0.8)
    if transparency > 0.0:
        # THIN glass (architectural panes): see-through with a Fresnel
        # reflection, no refraction. Physical transmission made window panes
        # read as sky mirrors in EEVEE (screen-space refraction can't see the
        # room behind the pane) and hid every interior seen through a window.
        bsdf.inputs["Roughness"].default_value = min(roughness, 0.1)
        _build_thin_glass(nt, bsdf, out, rec, transparency)
        _setup_eevee_glass(mat, engine)
    else:
        bsdf.inputs["Roughness"].default_value = roughness
        # Texture source (precedence in the module docstring): explicit override >
        # real Revit maps > name-matched library > flat colour.
        tint = rec.get("base_color", [0.8, 0.8, 0.8])
        if surface == "plain":
            pass
        elif surface == "auto_maps_only":
            _build_revit_maps(nt, bsdf, rec, base_dir)
        elif surface and surface != "auto":
            material_library.build_surface(nt, bsdf, surface, tint, roughness)
        elif not _build_revit_maps(nt, bsdf, rec, base_dir):
            material_library.decorate(nt, bsdf, rec.get("name", ""), tint, roughness)

    if fabric:
        _build_curtain(mat, nt, bsdf, out, fabric, float(rec.get("transparency", 0.0)))
    if automatic and str(rec.get("appearance_class") or "") == "metal" \
            and not (rec.get("maps") or {}).get("diffuse") and transparency <= 0.0:
        material_library.build_surface(nt, bsdf, "metal", rec.get("base_color", [0.8, 0.8, 0.8]),
                                       roughness)
    if automatic and str(rec.get("appearance_class") or "") == "estofado" and transparency <= 0.0:
        # Upholstery (SketchUp component named sofa/poltrona/almofada...): the
        # soft grazing-angle sheen of cloth; untextured ones also get a weave.
        if not bsdf.inputs["Normal"].is_linked and not (rec.get("maps") or {}).get("diffuse") \
                and float(rec.get("metallic", 0.0)) < 0.5:
            material_library.build_surface(nt, bsdf, "upholstery",
                                           rec.get("base_color", [0.8, 0.8, 0.8]), roughness)
        for name, val in (("Sheen Weight", 0.6), ("Sheen Roughness", 0.45)):
            if name in bsdf.inputs:
                bsdf.inputs[name].default_value = val
        if not bsdf.inputs["Roughness"].is_linked:
            bsdf.inputs["Roughness"].default_value = max(roughness, 0.75)

    emissive = rec.get("emissive")
    if emissive:
        bsdf.inputs["Emission Color"].default_value = _rgba(emissive)
        bsdf.inputs["Emission Strength"].default_value = float(
            rec.get("emissive_strength") or 1.0)
    return mat


def _map_path(entry, base_dir):
    uri = (entry or {}).get("uri")
    if not uri or not base_dir:
        return None
    path = os.path.join(base_dir, uri.replace("/", os.sep))
    return path if os.path.isfile(path) else None


def _image_mean(img):
    """Average of the first channel (roughness maps are grey). None on failure."""
    try:
        import numpy as np
        n = img.size[0] * img.size[1]
        if n <= 0:
            return None
        px = np.empty(n * img.channels, dtype=np.float32)
        img.pixels.foreach_get(px)
        return float(px[0::img.channels].mean())
    except Exception:
        return None


def _build_revit_maps(nt, bsdf, rec, base_dir):
    """Real Revit appearance textures (contract 0.2.0 `maps`): the diffuse bitmap
    box-projected at its real-world scale, plus the bump map when present. Returns
    False when there's no resolvable diffuse map, so the caller can fall back to
    the curated library. Object coords == world metres (merge bakes the matrix),
    so a 0.6 m brick tile is 0.6 m on the wall - the same real-world mapping
    Revit uses, no UVs needed."""
    maps = rec.get("maps") or {}
    diffuse = maps.get("diffuse") or {}
    dpath = _map_path(diffuse, base_dir)
    if dpath is None:
        # SketchUp 2025 PBR maps can exist on a material without a colour
        # image (colour + relief / roughness / metal): build just those.
        if not any(_map_path(maps.get(k), base_dir) for k in ("normal", "metallic", "ao")) \
                and not (_map_path(maps.get("roughness"), base_dir) and (maps.get("roughness") or {}).get("pbr")):
            return False

    tc = nt.nodes.new("ShaderNodeTexCoord")
    tc.location = (-900, 0)
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.location = (-700, 0)
    nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
    sx, sy = _scale_m(diffuse)
    # Box projection samples the XY/XZ/YZ planes: walls read U from world X or Y
    # and V from Z. 1/sx on both horizontals + 1/sy on Z keeps every wall's tile
    # sx wide and sy tall (floors get sx x sx - square tiles, the common case).
    mp.inputs["Scale"].default_value = (1.0 / sx, 1.0 / sx, 1.0 / sy)
    off = diffuse.get("offset_m") or [0.0, 0.0]
    mp.inputs["Location"].default_value = (float(off[0]), float(off[1]), 0.0)
    rot = float(diffuse.get("rotation_deg") or 0.0)
    if rot:
        import math
        mp.inputs["Rotation"].default_value = (0.0, 0.0, math.radians(rot))

    # SketchUp bundles carry the architect's own texture placement as mesh UVs
    # (maps.diffuse.uv). Use them for the colour map and for every map drawn at
    # the same scale (the library's relief / roughness images); anything else -
    # and every bundle without UVs - keeps the real-world box projection.
    uvnode = None
    if diffuse.get("uv"):
        uvnode = nt.nodes.new("ShaderNodeUVMap")
        uvnode.location = (-700, 220)
        uvnode.uv_map = UV_LAYER

    def _wire(tex_node, entry):
        if uvnode is not None and _same_scale(entry, diffuse):
            tex_node.projection = "FLAT"
            nt.links.new(uvnode.outputs["UV"], tex_node.inputs["Vector"])
        else:
            tex_node.projection = "BOX"
            tex_node.projection_blend = 0.25
            nt.links.new(mp.outputs["Vector"], tex_node.inputs["Vector"])

    img = None
    color_out = None
    if dpath is not None:
        img = nt.nodes.new("ShaderNodeTexImage")
        img.location = (-460, 60)
        img.image = bpy.data.images.load(dpath, check_existing=True)
        _wire(img, diffuse)
        color_out = img.outputs["Color"]
        tint = diffuse.get("tint")
        if tint:
            # Library texture picked automatically for a colour-only material: keep
            # the project's colour, take only the pattern/relief from the texture.
            color_out = _tint(nt, img, tint)
    color_out = _apply_ao(nt, bsdf, maps, base_dir, _wire, color_out)
    if color_out is not None:
        nt.links.new(color_out, bsdf.inputs["Base Color"])
    _apply_metallic(nt, bsdf, rec, maps, base_dir, _wire)
    if img is not None and diffuse.get("alpha"):
        # Cut-out texture (PNG with transparency: plants, curtains, people from
        # SketchUp): the image alpha drives the surface's own alpha.
        nt.links.new(img.outputs["Alpha"], bsdf.inputs["Alpha"])
        mat = nt.id_data
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "DITHERED"
        elif hasattr(mat, "blend_method"):
            mat.blend_method = "HASHED"
        if hasattr(mat, "use_transparent_shadow"):
            mat.use_transparent_shadow = True

    rpath = _map_path(maps.get("roughness"), base_dir)
    if rpath is not None:
        # Roughness map: the surface's shine varies across it (worn spots,
        # grout, wood grain) - a big part of what reads as a real material.
        rimg = nt.nodes.new("ShaderNodeTexImage")
        rimg.location = (-460, -560)
        rimg.image = bpy.data.images.load(rpath, check_existing=True)
        rimg.image.colorspace_settings.name = "Non-Color"
        _wire(rimg, maps.get("roughness") or {})
        # Keep the finish the user picked (polished / satin / matte): the map
        # only adds variation around it, scaled so its average lands on the
        # material's roughness value.
        target = float(rec.get("roughness", 0.5) or 0.5)
        if (maps.get("roughness") or {}).get("pbr"):
            # SketchUp 2025 PBR map: the material's factor multiplies the map.
            factor = target
        else:
            mean = _image_mean(rimg.image)
            factor = target / mean if mean and mean > 0.02 else 1.0
        mul = nt.nodes.new("ShaderNodeMath")
        mul.operation = "MULTIPLY"
        mul.use_clamp = True
        mul.location = (-220, -560)
        mul.inputs[1].default_value = max(0.05, min(factor, 4.0))
        nt.links.new(rimg.outputs["Color"], mul.inputs[0])
        nt.links.new(mul.outputs["Value"], bsdf.inputs["Roughness"])

    normal_out = _apply_normal(nt, maps, base_dir, uvnode, diffuse)
    if normal_out is not None:
        nt.links.new(normal_out, bsdf.inputs["Normal"])
    bpath = _map_path(maps.get("bump"), base_dir)
    if bpath is not None:
        bimg = nt.nodes.new("ShaderNodeTexImage")
        bimg.location = (-460, -280)
        bimg.image = bpy.data.images.load(bpath, check_existing=True)
        bimg.image.colorspace_settings.name = "Non-Color"
        _wire(bimg, maps.get("bump") or {})
        bump = nt.nodes.new("ShaderNodeBump")
        bump.location = (-200, -280)
        amount = float((maps.get("bump") or {}).get("amount") or 0.3)
        bump.inputs["Strength"].default_value = max(0.0, min(1.0, amount))
        nt.links.new(bimg.outputs["Color"], bump.inputs["Height"])
        if normal_out is not None:
            nt.links.new(normal_out, bump.inputs["Normal"])
        nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return True


def _apply_normal(nt, maps, base_dir, uvnode, diffuse):
    """SketchUp 2025 normal map (tangent space). Tangents need the mesh UVs, so
    it is used only when the bundle carries them for this material at the same
    scale; otherwise it is skipped (a box-projected normal map would light the
    surface wrongly). Returns the Normal socket or None."""
    entry = maps.get("normal") or {}
    path = _map_path(entry, base_dir)
    if path is None or uvnode is None or not _same_scale(entry, diffuse):
        return None
    nimg = nt.nodes.new("ShaderNodeTexImage")
    nimg.location = (-460, -840)
    nimg.image = bpy.data.images.load(path, check_existing=True)
    nimg.image.colorspace_settings.name = "Non-Color"
    nimg.projection = "FLAT"
    nt.links.new(uvnode.outputs["UV"], nimg.inputs["Vector"])
    col = nimg.outputs["Color"]
    if entry.get("directx"):
        # DirectX normal maps have green pointing down: flip it to OpenGL.
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        sep.location = (-300, -840)
        inv = nt.nodes.new("ShaderNodeMath")
        inv.operation = "SUBTRACT"
        inv.inputs[0].default_value = 1.0
        inv.location = (-160, -900)
        comb = nt.nodes.new("ShaderNodeCombineColor")
        comb.location = (-60, -840)
        nt.links.new(col, sep.inputs["Color"])
        nt.links.new(sep.outputs["Red"], comb.inputs["Red"])
        nt.links.new(sep.outputs["Green"], inv.inputs[1])
        nt.links.new(inv.outputs["Value"], comb.inputs["Green"])
        nt.links.new(sep.outputs["Blue"], comb.inputs["Blue"])
        col = comb.outputs["Color"]
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nm.name = "BIR_NormalMap"
    nm.location = (-120, -760)
    nm.space = "TANGENT"
    nm.uv_map = UV_LAYER
    nm.inputs["Strength"].default_value = max(0.0, min(4.0, float(entry.get("strength", 1.0) or 0.0)))
    nt.links.new(col, nm.inputs["Color"])
    return nm.outputs["Normal"]


def _apply_metallic(nt, bsdf, rec, maps, base_dir, wire):
    """SketchUp 2025 metallic map x the material's metallic factor."""
    entry = maps.get("metallic") or {}
    path = _map_path(entry, base_dir)
    if path is None:
        return
    mimg = nt.nodes.new("ShaderNodeTexImage")
    mimg.location = (-460, -1100)
    mimg.image = bpy.data.images.load(path, check_existing=True)
    mimg.image.colorspace_settings.name = "Non-Color"
    wire(mimg, entry)
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    mul.use_clamp = True
    mul.name = "BIR_Metallic"
    mul.location = (-220, -1100)
    mul.inputs[1].default_value = float(rec.get("metallic", 1.0))
    nt.links.new(mimg.outputs["Color"], mul.inputs[0])
    nt.links.new(mul.outputs["Value"], bsdf.inputs["Metallic"])


def _apply_ao(nt, bsdf, maps, base_dir, wire, color_out):
    """SketchUp 2025 ambient-occlusion map: darkens the colour in the crevices,
    by its strength. Works on the colour image or on the flat colour."""
    entry = maps.get("ao") or {}
    path = _map_path(entry, base_dir)
    if path is None:
        return color_out
    strength = max(0.0, min(1.0, float(entry.get("strength", 1.0) or 0.0)))
    if strength <= 0.0:
        return color_out
    aimg = nt.nodes.new("ShaderNodeTexImage")
    aimg.location = (-460, 340)
    aimg.image = bpy.data.images.load(path, check_existing=True)
    aimg.image.colorspace_settings.name = "Non-Color"
    wire(aimg, entry)
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.name = "BIR_AO"
    mix.location = (-120, 200)
    mix.inputs[0].default_value = strength
    if color_out is not None:
        nt.links.new(color_out, mix.inputs[6])
    else:
        mix.inputs[6].default_value = tuple(bsdf.inputs["Base Color"].default_value)
    nt.links.new(aimg.outputs["Color"], mix.inputs[7])
    return mix.outputs[2]


UV_LAYER = "UVMap"    # the glTF importer's name for TEXCOORD_0


def _image_mean_rgb_linear(img):
    """Average colour of an image, linear. Byte images report sRGB-encoded
    pixels, so they are linearised here. None on failure."""
    try:
        import numpy as np
        n = img.size[0] * img.size[1]
        if n <= 0:
            return None
        px = np.empty(n * img.channels, dtype=np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(-1, img.channels)[:, :3]
        if not img.is_float:
            px = np.where(px <= 0.04045, px / 12.92, ((px + 0.055) / 1.055) ** 2.4)
        return [float(v) for v in px.mean(axis=0)]
    except Exception:
        return None


def _tint(nt, img, tint):
    """texture x (tint / texture average): the result averages to `tint` (the
    material's own colour) while keeping the texture's light/dark pattern."""
    mean = _image_mean_rgb_linear(img.image) or [0.5, 0.5, 0.5]
    fac = [max(0.0, min(8.0, float(t) / max(m, 1e-3))) for t, m in zip(tint[:3], mean)]
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.location = (-220, 60)
    mix.name = "BIR_Tint"
    mix.inputs[0].default_value = 1.0                       # Factor
    nt.links.new(img.outputs["Color"], mix.inputs[6])        # A (color)
    mix.inputs[7].default_value = (fac[0], fac[1], fac[2], 1.0)   # B (color)
    return mix.outputs[2]                                    # Result (color)


def _same_scale(entry, diffuse):
    """A map drawn at the colour map's scale lines up with it under the same UVs."""
    a, b = _scale_m(entry), _scale_m(diffuse)
    return abs(a[0] - b[0]) < 1e-4 * max(1.0, b[0]) and abs(a[1] - b[1]) < 1e-4 * max(1.0, b[1])


def _scale_m(entry):
    scale = entry.get("scale_m") or [0.3, 0.3]
    sx = max(1e-4, float(scale[0]))
    sy = max(1e-4, float(scale[1] if len(scale) > 1 else scale[0]))
    return sx, sy


_SHEER_WORDS = ("voil", "voal", "vual", "sheer", "tule", "organza", "gaze")
_CURTAIN_WORDS = ("cortina", "curtain", "drape", "cortinado") + _SHEER_WORDS
_NOT_CURTAIN = ("blackout", "black out", "persiana", "blind", "trilho", "varao",
                "varão", "rod", "rail")


def curtain_kind(rec):
    """'sheer' (voil: light passes AND you half see through), 'fabric' (a
    normal curtain: glows with the window light behind it) or None. From the
    material name or the exporter's appearance_class (SketchUp marks the
    materials used inside a component named 'Cortina ...')."""
    name = str(rec.get("name") or "").lower()
    cls = str(rec.get("appearance_class") or "").lower()
    if any(w in name for w in _NOT_CURTAIN):
        return None
    if any(w in name for w in _SHEER_WORDS) or cls == "cortina_voil":
        return "sheer"
    if any(w in name for w in _CURTAIN_WORDS) or cls == "cortina":
        return "fabric"
    return None


def _build_curtain(mat, nt, bsdf, out, kind, transparency):
    """Fabric lit from behind: a share of Translucent BSDF (light coming
    through the cloth, tinted by its colour), plus real see-through for voil."""
    trl = nt.nodes.new("ShaderNodeBsdfTranslucent")
    trl.location = (40, -300)
    base_in = bsdf.inputs["Base Color"]
    if base_in.is_linked:
        nt.links.new(base_in.links[0].from_socket, trl.inputs["Color"])
    else:
        trl.inputs["Color"].default_value = base_in.default_value
    mix = nt.nodes.new("ShaderNodeMixShader")
    mix.location = (240, -120)
    mix.inputs["Fac"].default_value = 0.5 if kind == "sheer" else 0.3
    nt.links.new(bsdf.outputs["BSDF"], mix.inputs[1])
    nt.links.new(trl.outputs["BSDF"], mix.inputs[2])
    final = mix.outputs["Shader"]
    see = max(0.35, min(0.7, transparency)) if kind == "sheer" else min(transparency, 0.15)
    if see > 0.0:
        tr = nt.nodes.new("ShaderNodeBsdfTransparent")
        tr.location = (240, -320)
        mix2 = nt.nodes.new("ShaderNodeMixShader")
        mix2.location = (420, -120)
        mix2.inputs["Fac"].default_value = see
        nt.links.new(final, mix2.inputs[1])
        nt.links.new(tr.outputs["BSDF"], mix2.inputs[2])
        final = mix2.outputs["Shader"]
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "DITHERED"
        if hasattr(mat, "use_transparent_shadow"):
            mat.use_transparent_shadow = True
    out.location = (620, 0)
    nt.links.new(final, out.inputs["Surface"])


def _build_thin_glass(nt, bsdf, out, rec, transparency):
    """Surface = mix(opaque principled, glass) by `transparency`, where
    glass = mix(transparent tinted lightly by the base colour, glossy) by a
    Fresnel term - head-on you see through, at grazing angles it reflects."""
    base = rec.get("base_color", [0.85, 0.9, 0.9])
    # Clear glass barely tints; keep the hue but lift it toward white.
    tint = [0.75 + 0.25 * float(c) for c in base[:3]]
    trans = nt.nodes.new("ShaderNodeBsdfTransparent")
    trans.location = (-200, -260)
    trans.inputs["Color"].default_value = _rgba(tint)
    gloss = nt.nodes.new("ShaderNodeBsdfGlossy") if "ShaderNodeBsdfGlossy" in dir(bpy.types) \
        else nt.nodes.new("ShaderNodeBsdfAnisotropic")
    gloss.location = (-200, -420)
    gloss.inputs["Roughness"].default_value = 0.02
    fres = nt.nodes.new("ShaderNodeFresnel")
    fres.location = (-200, -120)
    fres.inputs["IOR"].default_value = float(rec.get("ior", 1.52) or 1.52)
    glass = nt.nodes.new("ShaderNodeMixShader")
    glass.location = (40, -260)
    nt.links.new(fres.outputs["Fac"], glass.inputs["Fac"])
    nt.links.new(trans.outputs["BSDF"], glass.inputs[1])
    nt.links.new(gloss.outputs["BSDF"], glass.inputs[2])
    mix = nt.nodes.new("ShaderNodeMixShader")
    mix.location = (220, 0)
    mix.inputs["Fac"].default_value = max(0.0, min(1.0, transparency))
    nt.links.new(bsdf.outputs["BSDF"], mix.inputs[1])
    nt.links.new(glass.outputs["Shader"], mix.inputs[2])
    nt.links.new(mix.outputs["Shader"], out.inputs["Surface"])


def _setup_eevee_glass(mat, engine):
    if engine != "EEVEE":
        return
    # EEVEE Next needs raytraced refraction per-material (+ raytracing on in the
    # render settings) or glass renders opaque. Attribute names churned across
    # 4.2-4.4, so guard each.
    for attr in ("use_raytrace_refraction", "use_screen_refraction"):
        if hasattr(mat, attr):
            setattr(mat, attr, True)
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "BLENDED"
    # Let the sun through the pane (EEVEE Next; Cycles does this natively).
    if hasattr(mat, "use_transparent_shadow"):
        mat.use_transparent_shadow = True


def apply_materials(loaded, engine="CYCLES"):
    overrides = _overrides_for(loaded.spec)
    base_dir = (loaded.spec or {}).get("_override_dir")  # == the bundle dir
    automatic = (loaded.spec.get("render") or {}).get("procedural_by_name", True) is not False
    by_id = {rec["id"]: build_material(rec, engine, overrides.get(rec["id"], "auto"),
                                       base_dir=base_dir, automatic=automatic)
             for rec in loaded.spec.get("materials", [])}
    elems = {e["node"]: e
             for e in loaded.spec.get("geometry", {}).get("elements", [])}
    for node, obj in loaded.node_to_object.items():
        if getattr(obj, "type", None) != "MESH":
            continue
        mid = (elems.get(node) or {}).get("material_id")
        mat = by_id.get(mid)
        if mat is not None:
            obj.data.materials.clear()
            obj.data.materials.append(mat)


# --- override helpers for the white / shadow presets ------------------------
def make_clay_material(name="Clay", value=0.8, roughness=0.6):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    out.location = (400, 0)
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Base Color"].default_value = (value, value, value, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def override_all(loaded, mat):
    for obj in loaded.node_to_object.values():
        if getattr(obj, "type", None) == "MESH":
            obj.data.materials.clear()
            obj.data.materials.append(mat)
