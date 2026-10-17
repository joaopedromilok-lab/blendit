"""Pipeline step: automatic exposure + white balance, like a camera.

Fixed exposure/colour boosts can't fit every model: a room with big windows,
one lit only by lamps, an exterior at noon - each needs its own setting (the
lamp-only room came out dark orange, the open-plan one washed out). Before the
real render, a tiny quick render (about a second on a GPU) measures the scene:

  * exposure: brings the average brightness (log-average, like a camera's
    meter) to a fixed photographic target;
  * white balance: estimates the colour of the light (grey-world) and corrects
    most of it, keeping a little warmth/coolness so mood survives.

Then render.tone and render.brightness (tone.py) are applied on top.
Photoreal modes only. render.auto_exposure = false turns it off.
"""
import math
import os
import tempfile

import bpy

LIT_MODES = ("realistic", "specular")
# Log-average scene luminance an interior is exposed for (AgX, exposure 0) -
# calibrated on the interiors that looked right with hand-set exposure.
TARGET = 0.23
MAX_EV = 3.0
WB_KEEP = 0.3          # share of the light's colour cast that is kept (mood)
WB_KEEP_NIGHT = 0.55   # lamp-lit night scenes keep more of their warmth


def measure(scene):
    """-> (log-average luminance, mean linear rgb) from a tiny render."""
    r = scene.render
    keep = dict(x=r.resolution_x, y=r.resolution_y, pct=r.resolution_percentage,
                path=r.filepath, fmt=r.image_settings.file_format)
    cy = getattr(scene, "cycles", None)
    ck = (cy.samples, cy.use_denoising, getattr(cy, "use_adaptive_sampling", None)) if cy else None
    ee = getattr(scene, "eevee", None)
    ek = ee.taa_render_samples if ee is not None else None
    comp = getattr(scene, "compositing_node_group", None)
    tmp = os.path.join(tempfile.gettempdir(), "blendit_medicao_%d.exr" % os.getpid())
    try:
        aspect = keep["y"] / float(max(1, keep["x"]))
        r.resolution_x = 160
        r.resolution_y = max(16, int(160 * aspect))
        r.resolution_percentage = 100
        r.image_settings.file_format = "OPEN_EXR"
        r.filepath = tmp
        if cy is not None:
            cy.samples = 24
            cy.use_denoising = True
        if ee is not None:
            ee.taa_render_samples = 8
        if comp is not None:
            scene.compositing_node_group = None
        bpy.ops.render.render(write_still=True)
        img = bpy.data.images.load(tmp, check_existing=False)
        try:
            import numpy as np
            px = np.empty(img.size[0] * img.size[1] * img.channels, dtype=np.float32)
            img.pixels.foreach_get(px)
            px = px.reshape(-1, img.channels)[:, :3]
            px = np.clip(px, 0.0, 64.0)
            lum = px[:, 0] * 0.2126 + px[:, 1] * 0.7152 + px[:, 2] * 0.0722
            logavg = float(np.exp(np.mean(np.log(lum + 1e-4))))
            mean = [float(v) for v in px.mean(axis=0)]
        finally:
            bpy.data.images.remove(img)
    finally:
        r.resolution_x, r.resolution_y = keep["x"], keep["y"]
        r.resolution_percentage = keep["pct"]
        r.filepath, r.image_settings.file_format = keep["path"], keep["fmt"]
        if cy is not None:
            cy.samples, cy.use_denoising = ck[0], ck[1]
        if ee is not None:
            ee.taa_render_samples = ek
        if comp is not None:
            scene.compositing_node_group = comp
        try:
            os.remove(tmp)
        except OSError:
            pass
    return logavg, mean


def cct_of(rgb):
    """Correlated colour temperature (K) of a linear sRGB colour (McCamy)."""
    R, G, B = rgb
    X = 0.4124 * R + 0.3576 * G + 0.1805 * B
    Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
    Z = 0.0193 * R + 0.1192 * G + 0.9505 * B
    s = X + Y + Z
    if s <= 1e-6:
        return 6500.0
    x, y = X / s, Y / s
    n = (x - 0.3320) / (0.1858 - y)
    return max(1500.0, min(20000.0, 449.0 * n ** 3 + 3525.0 * n ** 2 + 6823.3 * n + 5520.33))


def apply_auto(spec):
    rspec = spec.get("render", {}) or {}
    if str(rspec.get("mode", "realistic")) not in LIT_MODES:
        return False
    if rspec.get("auto_exposure") is False:
        return False
    scene = bpy.context.scene
    vs = scene.view_settings
    # Measure with the look but WITHOUT the earlier fixed boosts / white balance.
    if hasattr(vs, "use_white_balance"):
        vs.use_white_balance = False
    vs.exposure = 0.0
    logavg, mean = measure(scene)
    if logavg <= 1e-5:
        return False
    ev = max(-MAX_EV, min(MAX_EV, math.log2(TARGET / logavg)))
    vs.exposure = ev + float(rspec.get("brightness", 0.0) or 0.0)
    cct = cct_of(mean)
    night = float((spec.get("sun") or {}).get("strength", 1.0) or 0.0) <= 0.0 \
        and float((spec.get("world") or {}).get("strength", 1.0) or 0.0) <= 0.2
    wb = 6500.0 + (cct - 6500.0) * (1.0 - (WB_KEEP_NIGHT if night else WB_KEEP))
    wb = max(3500.0, min(10000.0, wb))
    try:
        from .tone import _TONE_SHIFT_K
        wb += _TONE_SHIFT_K.get(str(rspec.get("tone", "natural")).lower(), 0.0)
    except Exception:
        pass
    if hasattr(vs, "use_white_balance"):
        vs.use_white_balance = True
        vs.white_balance_temperature = wb
    print("[Blendit] auto exposure: scene %.3f -> %+.2f EV; light %.0fK -> white balance %.0fK"
          % (logavg, ev, cct, wb))
    return True
