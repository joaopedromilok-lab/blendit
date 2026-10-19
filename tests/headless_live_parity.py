"""Live View 'Render Final' must match the headless render of the same interior.

Run: blender --background --python tests/headless_live_parity.py

The Live session opens in EEVEE (bir_config's default) and Render Final
switches to Cycles. apply_interior picks its exposure boost / white balance
per engine, and headless run._render meters the room (autoexpose.apply_auto)
right before the final render. The committed fixture, forced to be an
interior, is rendered at the same resolution and samples:

  * headless: run.build_scene(engine CYCLES) + run._render (production path);
  * Live:     live._deferred_build + live._render_still_at.

Scenario "auto" (render.auto_exposure on, Live built in EEVEE):
  * |exposure_live - exposure_headless| <= 0.1 EV;
  * |white_balance_live - white_balance_headless| <= 100 K;
  * relative difference of the mean luminance of the two PNGs <= 3 %
    (mean of 0.2126 R + 0.7152 G + 0.0722 B over img.pixels of each PNG -
    both images are read the same way, so the relative difference holds);
  * the Live session state (engine, exposure, white balance, samples,
    denoising) is restored after Render Final;
  * a +0.5 EV move of the Live Exposure slider is still +0.5 EV in Render
    Final (the slider keeps its meaning).

Scenarios "off EEVEE->Cycles" and "off Cycles->EEVEE" (render.auto_exposure
off; the Live session is built in one engine, then the Engine toggle switches
it, which does NOT re-run apply_interior):
  * exposure and white balance of the final within the same tolerances of the
    headless auto-off render;
  * session state restored. (No luminance check: the Engine toggle rebuilds
    the materials without the realism / bevel layers, a separate issue.)

The view settings of each FINAL render are captured by a render_pre handler
(the metering pre-render writes a temp .exr and is ignored). Works on temp
copies of tests/fixtures (the committed bundle is not touched). Exits 1 when
any check fails.
"""
import json
import os
import shutil
import sys
import tempfile

import bpy

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, ".."))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

RES = [192, 108]
SAMPLES = 16
EV_TOL = 0.1
K_TOL = 100.0
LUMA_TOL = 0.03

CHECKS = []
SNAPS = []


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok)))
    print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail))


@bpy.app.handlers.persistent
def _snap(scene, *_args):
    vs = scene.view_settings
    SNAPS.append({
        "path": bpy.path.abspath(scene.render.filepath),
        "engine": scene.render.engine,
        "exposure": round(float(vs.exposure), 4),
        "wb_on": bool(getattr(vs, "use_white_balance", False)),
        "wb_k": round(float(getattr(vs, "white_balance_temperature", 6500.0)), 1),
        "look": str(vs.look),
        "view": str(vs.view_transform),
    })


def _final_snap(out):
    want = os.path.normcase(os.path.abspath(out))
    hits = [s for s in SNAPS if os.path.normcase(os.path.abspath(s["path"])) == want]
    return hits[-1] if hits else None


def _wb(s):
    return s["wb_k"] if s["wb_on"] else 6500.0


def _mean_luma(path):
    img = bpy.data.images.load(path, check_existing=False)
    try:
        import numpy as np
        w, h = img.size
        px = np.empty(w * h * img.channels, dtype=np.float32)
        img.pixels.foreach_get(px)
        px = px.reshape(-1, img.channels)[:, :3]
        return float((px[:, 0] * 0.2126 + px[:, 1] * 0.7152 + px[:, 2] * 0.0722).mean())
    finally:
        bpy.data.images.remove(img)


def _bundle(tmp, name, auto_exposure):
    """Temp copy of the fixture, forced to be an interior, small + fast."""
    dst = os.path.join(tmp, name)
    shutil.copytree(os.path.join(_HERE, "fixtures"), dst)
    path = os.path.join(dst, "scene_spec.json")
    with open(path, "r", encoding="utf-8") as f:
        spec = json.load(f)
    r = spec.setdefault("render", {})
    r.update({"mode": "realistic", "interior": True, "resolution": RES,
              "samples": SAMPLES, "denoise": True, "auto_exposure": auto_exposure})
    with open(path, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=1)
    return dst


def _headless(bundle, out):
    from blender.pipeline import run
    loaded, spec = run.build_scene(bundle, overrides={"engine": "CYCLES",
                                                      "mode": "realistic"})
    check("headless: interior detected", bool(bpy.context.scene.get("bir_interior")))
    run._render(out, spec)
    return _final_snap(out)


def _session_state(sc):
    vs = sc.view_settings
    return {
        "engine": sc.render.engine,
        "exposure": round(float(vs.exposure), 4),
        "wb_on": bool(vs.use_white_balance),
        "wb_k": round(float(vs.white_balance_temperature), 1),
        "eevee_samples": sc.eevee.taa_render_samples,
        "cycles_samples": sc.cycles.samples,
        "cycles_denoise": bool(sc.cycles.use_denoising),
    }


def _live_session(bundle, engine):
    import blender.interactive.live as live

    class _NS(object):
        blend = None
        save_blend = None
        capture_dir = None
        mode = "realistic"
    _NS.bundle = bundle
    _NS.engine = engine

    live._register_ui()
    live._BUILD_ARGS = _NS()
    live._BUSY = True
    while live._deferred_build() is not None:
        pass
    # In the UI the viewport setup syncs the sliders from the scene once the
    # 3D view is ready; --background has no viewport, so do it here.
    live._sync_settings_from_scene()
    check("live (%s): interior detected" % engine,
          bool(bpy.context.scene.get("bir_interior")))
    return live


def scenario_auto(tmp):
    bundle = _bundle(tmp, "bundle_auto", True)
    out_h = os.path.join(tmp, "headless.png")
    out_l = os.path.join(tmp, "live_final.png")
    h = _headless(bundle, out_h)
    live = _live_session(bundle, "EEVEE")
    sc = bpy.context.scene
    before = _session_state(sc)
    live._render_still_at(out_l, SAMPLES)
    after = _session_state(sc)
    l = _final_snap(out_l)
    # The user's Exposure slider move (+0.5 EV over the pipeline's value) must
    # survive into Render Final, on top of whatever the final look is.
    sc.bir.exposure = float(sc.view_settings.exposure) + 0.5
    out_plus = out_l.replace(".png", "_plus05.png")
    live._render_still_at(out_plus, SAMPLES)
    l_plus = _final_snap(out_plus)

    check("[auto] headless final render captured", h is not None)
    check("[auto] live final render captured", l is not None)
    if h is None or l is None:
        return
    lh, ll = _mean_luma(out_h), _mean_luma(out_l)
    d_ev = l["exposure"] - h["exposure"]
    d_k = _wb(l) - _wb(h)
    d_luma = (ll - lh) / max(lh, 1e-6)
    print("PARITY auto " + json.dumps({
        "headless": h, "live": l, "live_session_before": before,
        "live_session_after": after, "luma_headless": round(lh, 4),
        "luma_live": round(ll, 4), "delta_ev": round(d_ev, 3),
        "delta_k": round(d_k, 1), "delta_luma_rel": round(d_luma, 4)}))
    check("[auto] both finals rendered by Cycles", h["engine"] == l["engine"] == "CYCLES",
          (h["engine"], l["engine"]))
    check("[auto] same view transform + look",
          (h["view"], h["look"]) == (l["view"], l["look"]),
          ((h["view"], h["look"]), (l["view"], l["look"])))
    check("[auto] exposure within %.2f EV" % EV_TOL, abs(d_ev) <= EV_TOL, "%+.3f EV" % d_ev)
    check("[auto] white balance within %.0f K" % K_TOL, abs(d_k) <= K_TOL, "%+.0f K" % d_k)
    check("[auto] mean luminance within %.0f %%" % (LUMA_TOL * 100),
          abs(d_luma) <= LUMA_TOL, "%+.2f %%" % (d_luma * 100))
    check("[auto] live session state restored after Render Final", before == after,
          "" if before == after else json.dumps({"before": before, "after": after}))
    if l_plus is not None:
        d_user = l_plus["exposure"] - l["exposure"]
        check("[auto] Exposure slider offset (+0.5 EV) kept in Render Final",
              abs(d_user - 0.5) <= 0.05, "%+.3f EV" % d_user)
    else:
        check("[auto] Exposure slider offset (+0.5 EV) kept in Render Final", False,
              "second final not captured")


def scenario_off(tmp):
    bundle = _bundle(tmp, "bundle_off", False)
    out_h = os.path.join(tmp, "headless_off.png")
    h = _headless(bundle, out_h)
    check("[off] headless final render captured", h is not None)
    for build, toggle in (("EEVEE", "CYCLES"), ("CYCLES", "EEVEE")):
        tag = "[off %s->%s]" % (build, toggle)
        live = _live_session(bundle, build)
        sc = bpy.context.scene
        built = str(sc.get("bir_interior_engine"))
        sc.bir.engine = toggle               # the N-panel Engine toggle
        check("%s interior look built for %s, session now %s" % (tag, build, toggle),
              built == build and (sc.render.engine == "CYCLES") == (toggle == "CYCLES"),
              (built, sc.render.engine))
        out_l = os.path.join(tmp, "live_off_%s_to_%s.png" % (build.lower(), toggle.lower()))
        before = _session_state(sc)
        live._render_still_at(out_l, SAMPLES)
        after = _session_state(sc)
        l = _final_snap(out_l)
        check("%s live final render captured" % tag, l is not None)
        if h is None or l is None:
            continue
        d_ev = l["exposure"] - h["exposure"]
        d_k = _wb(l) - _wb(h)
        print("PARITY %s %s" % (tag, json.dumps({
            "headless": h, "live": l, "live_session_before": before,
            "live_session_after": after, "delta_ev": round(d_ev, 3),
            "delta_k": round(d_k, 1)})))
        check("%s final rendered by Cycles" % tag, l["engine"] == "CYCLES", l["engine"])
        check("%s exposure within %.2f EV" % (tag, EV_TOL), abs(d_ev) <= EV_TOL,
              "%+.3f EV" % d_ev)
        check("%s white balance within %.0f K" % (tag, K_TOL), abs(d_k) <= K_TOL,
              "%+.0f K" % d_k)
        check("%s live session state restored after Render Final" % tag, before == after,
              "" if before == after else json.dumps({"before": before, "after": after}))


def main():
    tmp = tempfile.mkdtemp(prefix="blendit_parity_")
    bpy.app.handlers.render_pre.append(_snap)
    scenario_auto(tmp)
    scenario_off(tmp)
    failed = [n for n, ok in CHECKS if not ok]
    print("images kept in %s" % tmp)
    print("LIVE PARITY %s (%d/%d checks)" % ("OK" if not failed else "FAILED",
                                             len(CHECKS) - len(failed), len(CHECKS)))
    if failed:
        sys.exit(1)


main()
