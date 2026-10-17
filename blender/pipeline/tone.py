"""Pipeline step: final look of the photoreal modes.

  * contrast: AgX "Medium High Contrast" - the base AgX curve is deliberately
    flat (good for grading); straight out of the box it reads washed out next
    to a photo;
  * render.tone: "natural" (default) | "neutro" (whiter whites, less orange
    from warm lamps) | "quente" (cosier);
  * render.brightness: exposure stops added on top (e.g. -1 .. +1).

Runs after interior.py (which may have set its own white balance) and is
idempotent: presets reset the view on every mode switch.
"""
import bpy

LIT_MODES = ("realistic", "specular")
_LOOKS = ("AgX - Medium High Contrast", "Medium High Contrast")
_TONE_SHIFT_K = {"neutro": -1100.0, "quente": 800.0}


def apply_tone(spec):
    rspec = spec.get("render", {}) or {}
    if str(rspec.get("mode", "realistic")) not in LIT_MODES:
        return False
    scene = bpy.context.scene
    vs = scene.view_settings
    if str(vs.view_transform).startswith("AgX"):
        for look in _LOOKS:
            try:
                vs.look = look
                break
            except Exception:
                continue
    base = float(scene.get("bir_wb_base", 6500.0))
    shift = _TONE_SHIFT_K.get(str(rspec.get("tone", "natural")).lower(), 0.0)
    if hasattr(vs, "use_white_balance") and (shift or base != 6500.0):
        vs.use_white_balance = True
        vs.white_balance_temperature = base + shift
    try:
        vs.exposure = float(vs.exposure) + float(rspec.get("brightness", 0.0) or 0.0)
    except (TypeError, ValueError):
        pass
    return True
