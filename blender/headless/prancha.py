"""Prancha (presentation board): lay out finished renders on a paper sheet with a
Brazilian-style title block (carimbo), and save it as PNG + PDF.

    blender --background --python blender/headless/prancha.py -- --manifest board.json

board.json (UTF-8):
    {
      "out": "C:/.../prancha.pdf",          # a .png with the same name is written too
      "format": "A3",                        # A4 | A3 | A2 | A1 | A0 (landscape)
      "dpi": 150,                            # optional
      "cols": 3,                             # optional; auto when absent
      "title": "Estudo de insolação",        # big line in the title block
      "fields": {"Projeto": "...", "Cliente": "...", "Endereço": "...",
                 "Responsável": "...", "Data": "16/10/2026", "Folha": "01/01"},
      "note": "Imagens ilustrativas.",       # optional, bottom-left
      "row_labels": ["21/06", "21/03", "21/12"],   # optional, a label per row
      "items": [{"image": "a.png", "label": "21/06 - 09:00"}, ...]
    }

Everything is laid out in MILLIMETRES (1 Blender unit = 1 mm) and rendered by an
orthographic camera with EEVEE + the Standard view transform, so image colours
come through untouched. The PDF is one page holding the rendered sheet at its
real paper size (text is part of the image).
"""
import argparse
import json
import math
import os
import sys
import zlib

import bpy

PAPER_MM = {"A4": (297.0, 210.0), "A3": (420.0, 297.0), "A2": (594.0, 420.0),
            "A1": (841.0, 594.0), "A0": (1189.0, 841.0)}
MARGIN = 10.0          # sheet edge -> frame (left margin 25 mm is for binding;
LEFT_MARGIN = 20.0     # boards are rarely bound, 20 mm keeps the look)
STAMP_W = 175.0        # carimbo width (NBR 10068 / 13142 use 175-178 mm)
STAMP_H = 46.0
LINE = 0.35            # line weight, mm
GAP = 5.0              # gap between images


def _args():
    argv = sys.argv
    args = argv[argv.index("--") + 1:] if "--" in argv else []
    p = argparse.ArgumentParser(prog="blendit-prancha")
    p.add_argument("--manifest", required=True)
    return p.parse_args(args)


# ---------------------------------------------------------------- scene helpers
def _reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = ("BLENDER_EEVEE_NEXT"
                           if "BLENDER_EEVEE_NEXT" in _engines() else "BLENDER_EEVEE")
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    world = bpy.data.worlds.new("Papel")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (1, 1, 1, 1)
    bg.inputs["Strength"].default_value = 1.0
    scene.world = world
    try:
        scene.eevee.taa_render_samples = 16
    except Exception:
        pass
    return scene


def _engines():
    try:
        return [e.identifier for e in
                bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items]
    except Exception:
        return []


_MATS = {}


def _flat(rgb, name):
    key = (name, tuple(rgb))
    if key in _MATS:
        return _MATS[key]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    _MATS[key] = m
    return m


def _rect(x, y, w, h, mat, z=0.0, name="ret"):
    """Axis-aligned rectangle, bottom-left at (x, y), in mm."""
    me = bpy.data.meshes.new(name)
    me.from_pydata([(x, y, z), (x + w, y, z), (x + w, y + h, z), (x, y + h, z)],
                   [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new(name, me)
    ob.data.materials.append(mat)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def _frame(x, y, w, h, mat, t=LINE):
    _rect(x, y, w, t, mat, 0.2, "linha")
    _rect(x, y + h - t, w, t, mat, 0.2, "linha")
    _rect(x, y, t, h, mat, 0.2, "linha")
    _rect(x + w - t, y, t, h, mat, 0.2, "linha")


def _text(body, x, y, size, mat, align="LEFT", max_w=None, bold=False):
    """Text with its BASELINE at y. Shrinks to fit `max_w` (mm) when given."""
    cu = bpy.data.curves.new("texto", type="FONT")
    cu.body = body or ""
    cu.size = size
    cu.align_x = align
    if bold:
        cu.space_character = 1.03      # the default font has no bold face here
    ob = bpy.data.objects.new("texto", cu)
    ob.location = (x, y, 0.3)
    ob.data.materials.append(mat)
    bpy.context.scene.collection.objects.link(ob)
    if max_w:
        bpy.context.view_layer.update()
        w = ob.dimensions.x
        if w > max_w > 0:
            cu.size = size * max_w / w
    return ob


def _image_plane(path, x, y, w, h):
    """Fit the image inside the w x h cell (contain), centred. -> drawn rect."""
    img = bpy.data.images.load(path, check_existing=True)
    iw, ih = img.size[0] or 1, img.size[1] or 1
    s = min(w / iw, h / ih)
    dw, dh = iw * s, ih * s
    dx, dy = x + (w - dw) / 2.0, y + (h - dh) / 2.0
    m = bpy.data.materials.new("img")
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Cubic"
    em = nt.nodes.new("ShaderNodeEmission")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(tex.outputs["Color"], em.inputs["Color"])
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    me = bpy.data.meshes.new("img")
    me.from_pydata([(dx, dy, 0.1), (dx + dw, dy, 0.1), (dx + dw, dy + dh, 0.1),
                    (dx, dy + dh, 0.1)], [], [(0, 1, 2, 3)])
    uv = me.uv_layers.new()
    for li, (u, v) in enumerate([(0, 0), (1, 0), (1, 1), (0, 1)]):
        uv.data[li].uv = (u, v)
    ob = bpy.data.objects.new("img", me)
    ob.data.materials.append(m)
    bpy.context.scene.collection.objects.link(ob)
    return dx, dy, dw, dh


# ---------------------------------------------------------------- layout
def _grid(n, area_w, area_h, aspect, cols=None):
    """Pick the column count that makes the images biggest. -> (cols, rows)."""
    if cols:
        return cols, int(math.ceil(n / float(cols)))
    best = None
    for c in range(1, n + 1):
        r = int(math.ceil(n / float(c)))
        cw = (area_w - GAP * (c - 1)) / c
        ch = (area_h - GAP * (r - 1)) / r - 6.0     # 6 mm for the label
        if cw <= 0 or ch <= 0:
            continue
        s = min(cw, ch * aspect)                     # image width that fits
        if best is None or s > best[0]:
            best = (s, c, r)
    return (best[1], best[2]) if best else (1, n)


def build(man):
    scene = _reset()
    pw, ph = PAPER_MM.get(str(man.get("format", "A3")).upper(), PAPER_MM["A3"])
    dpi = float(man.get("dpi") or (200 if pw <= 420 else 150))
    black = _flat((0.0, 0.0, 0.0), "preto")
    grey = _flat((0.35, 0.35, 0.35), "cinza")

    # sheet frame
    fx, fy = LEFT_MARGIN, MARGIN
    fw, fh = pw - LEFT_MARGIN - MARGIN, ph - 2 * MARGIN
    _frame(fx, fy, fw, fh, black, LINE * 1.6)

    # carimbo (bottom-right)
    sw = min(STAMP_W, fw * 0.6)
    sx, sy = fx + fw - sw, fy
    _frame(sx, sy, sw, STAMP_H, black)
    fields = man.get("fields") or {}
    title = man.get("title") or ""
    # row 1: title (full width)
    _rect(sx, sy + STAMP_H - 14.0, sw, LINE, black, 0.2, "linha")
    _text(u"CONTEÚDO", sx + 2.0, sy + STAMP_H - 4.2, 2.2, grey)
    _text(title, sx + 2.0, sy + STAMP_H - 11.0, 5.0, black, max_w=sw - 4.0, bold=True)
    # rows 2-4: label/value pairs in two columns
    order = [k for k in (u"Projeto", u"Cliente", u"Endereço", u"Responsável",
                         u"Data", u"Folha") if k in fields]
    order += [k for k in fields if k not in order]
    order = order[:8]
    rows = int(math.ceil(len(order) / 2.0)) or 1
    rh = (STAMP_H - 14.0) / rows
    colw = sw / 2.0
    _rect(sx + colw, sy, LINE, STAMP_H - 14.0, black, 0.2, "linha")
    for i, key in enumerate(order):
        r, c = divmod(i, 2)
        cx = sx + c * colw
        cy = sy + STAMP_H - 14.0 - (r + 1) * rh
        if r > 0 and c == 0:
            _rect(sx, cy + rh, sw, LINE, black, 0.2, "linha")
        _text(key.upper(), cx + 2.0, cy + rh - 3.8, 2.2, grey)
        _text(str(fields[key]), cx + 2.0, cy + 2.4, 3.4, black, max_w=colw - 4.0)

    note = man.get("note")
    if note:
        _text(note, fx + 3.0, fy + 4.0, 2.4, grey, max_w=fw - sw - 6.0)

    # image area (above the carimbo strip)
    items = [it for it in (man.get("items") or []) if os.path.isfile(it.get("image", ""))]
    ax, ay = fx + 6.0, fy + STAMP_H + 6.0
    aw, ah = fw - 12.0, fh - STAMP_H - 12.0
    row_labels = man.get("row_labels") or []
    label_w = 18.0 if row_labels else 0.0
    ax += label_w
    aw -= label_w
    if items:
        first = bpy.data.images.load(items[0]["image"], check_existing=True)
        aspect = (first.size[0] or 16) / float(first.size[1] or 9)
        cols, nrows = _grid(len(items), aw, ah, aspect, man.get("cols"))
        cw = (aw - GAP * (cols - 1)) / cols
        ch = (ah - GAP * (nrows - 1)) / nrows
        has_labels = any(it.get("label") for it in items)
        for i, it in enumerate(items):
            r, c = divmod(i, cols)
            x = ax + c * (cw + GAP)
            y = ay + ah - (r + 1) * ch - r * GAP
            img_h = ch - (6.0 if has_labels else 0.0)
            dx, dy, dw, dh = _image_plane(it["image"], x, y + (6.0 if has_labels else 0.0),
                                          cw, img_h)
            if it.get("label"):
                _text(it["label"], dx, dy - 4.2, 3.0, black, max_w=dw)
        for r, lab in enumerate(row_labels[:nrows]):
            y = ay + ah - (r + 1) * ch - r * GAP
            # vertical label, reading bottom-to-top, centred on the row
            t = _text(lab, 0.0, 0.0, 4.2, black, align="CENTER", max_w=ch - 6.0, bold=True)
            t.rotation_euler = (0.0, 0.0, math.pi / 2.0)
            t.location = (ax - label_w / 2.0 + 1.5, y + ch / 2.0 + (3.0 if has_labels else 0.0), 0.3)

    # camera over the whole sheet
    cam_data = bpy.data.cameras.new("folha")
    cam_data.type = "ORTHO"
    cam_data.sensor_fit = "HORIZONTAL"
    cam_data.ortho_scale = pw
    cam_data.clip_start = 0.1
    cam_data.clip_end = 100.0
    cam = bpy.data.objects.new("folha", cam_data)
    cam.location = (pw / 2.0, ph / 2.0, 10.0)
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.resolution_x = int(round(pw / 25.4 * dpi))
    scene.render.resolution_y = int(round(ph / 25.4 * dpi))
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    return pw, ph


def _write_pdf(png_path, pdf_path, pw_mm, ph_mm):
    """One-page PDF at the real paper size holding the rendered sheet."""
    img = bpy.data.images.load(png_path)
    w, h = img.size
    try:
        import numpy as np
        px = np.empty(w * h * 4, dtype=np.float32)
        img.pixels.foreach_get(px)
        px = (np.clip(px.reshape(h, w, 4)[::-1, :, :3], 0, 1) * 255.0 + 0.5).astype(np.uint8)
        raw = px.tobytes()
    except Exception:                               # no numpy: slow path
        p = list(img.pixels)
        rows = []
        for yy in range(h - 1, -1, -1):
            row = bytearray()
            for xx in range(w):
                i = (yy * w + xx) * 4
                row += bytes(int(max(0, min(1, p[i + k])) * 255 + 0.5) for k in range(3))
            rows.append(bytes(row))
        raw = b"".join(rows)
    data = zlib.compress(raw, 6)
    W, H = pw_mm / 25.4 * 72.0, ph_mm / 25.4 * 72.0
    content = ("q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q" % (W, H)).encode("ascii")
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] "
         "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>" % (W, H)).encode("ascii"),
        ("<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB "
         "/BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n"
         % (w, h, len(data))).encode("ascii") + data + b"\nendstream",
        ("<< /Length %d >>\nstream\n" % len(content)).encode("ascii") + content + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += ("%d 0 obj\n" % i).encode("ascii") + body + b"\nendobj\n"
    xref = len(out)
    out += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode("ascii")
    for off in offsets:
        out += ("%010d 00000 n \n" % off).encode("ascii")
    out += ("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objs) + 1, xref)).encode("ascii")
    with open(pdf_path, "wb") as f:
        f.write(out)


def main():
    ns = _args()
    with open(ns.manifest, encoding="utf-8") as f:
        man = json.load(f)
    pdf = os.path.abspath(man["out"])
    if not pdf.lower().endswith(".pdf"):
        pdf += ".pdf"
    png = os.path.splitext(pdf)[0] + ".png"
    pw, ph = build(man)
    bpy.context.scene.render.filepath = png
    bpy.ops.render.render(write_still=True)
    _write_pdf(png, pdf, pw, ph)
    print("Blendit: prancha ->", pdf)
    if man.get("open"):
        try:
            os.startfile(pdf)
        except Exception:
            pass


if __name__ == "__main__":
    main()
