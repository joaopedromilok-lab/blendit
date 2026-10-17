# -*- coding: utf-8 -*-
"""Revit-side sun study + presentation board (IronPython 2.7 safe, pure ASCII:
user-facing pt-BR text uses \\u escapes).

Both reuse the Blender core: blender/headless/render.py (with --sun-date /
--sun-time for the study) and blender/headless/prancha.py (the board). The
title block (carimbo) is filled from Revit's own Project Information, so there
is nothing to type: Project Name, Client Name, Project Address, Author.
"""
import io
import json
import os
import subprocess
import time

import bir_bootstrap

SUN_DATES = [("06-21", u"21/06", u"Inverno (21/06)"),
             ("03-21", u"21/03", u"Equin\u00f3cio (21/03)"),
             ("12-21", u"21/12", u"Ver\u00e3o (21/12)")]
SUN_HOURS = [9, 12, 15]
PAPERS = ["A3", "A2", "A1", "A4"]


def prancha_script_path():
    return os.path.join(bir_bootstrap.REPO_ROOT, "blender", "headless", "prancha.py")


def _stamp():
    return time.strftime("%Y%m%d_%H%M%S")


def _param(info, name):
    try:
        v = getattr(info, name)
        return u"%s" % v if v else u""
    except Exception:
        return u""


def title_fields(doc):
    """Carimbo fields from Revit's Project Information (empty ones skipped)."""
    fields = {}
    try:
        info = doc.ProjectInformation
        pairs = [(u"Projeto", _param(info, "Name") or _param(info, "BuildingName")),
                 (u"Cliente", _param(info, "ClientName")),
                 (u"Endere\u00e7o", _param(info, "Address")),
                 (u"Respons\u00e1vel", _param(info, "Author")),
                 (u"N\u00ba do projeto", _param(info, "Number"))]
        for k, v in pairs:
            if v.strip():
                fields[k] = v.strip()
    except Exception:
        pass
    fields[u"Data"] = time.strftime("%d/%m/%Y")
    fields[u"Folha"] = u"01/01"
    return fields


def write_manifest(out_dir, data):
    path = os.path.join(out_dir, "prancha_%s.json" % _stamp())
    f = io.open(path, "w", encoding="utf-8")
    try:
        text = json.dumps(data, indent=2, ensure_ascii=True)
        if not isinstance(text, type(u"")):
            text = text.decode("ascii")
        f.write(text)
    finally:
        f.close()
    return path


def board_cmd(blender, manifest_path):
    return [blender, "--background", "--python", prancha_script_path(), "--",
            "--manifest", manifest_path]


def _q(s):
    return u'"%s"' % s


def run_queue(cmds, log_path, open_dir=None):
    """Run the Blender jobs ONE AFTER ANOTHER, detached and windowless, via a
    small .cmd file - Revit stays free while the study renders."""
    lines = [u"@echo off", u"chcp 65001 >nul"]
    for c in cmds:
        lines.append(u" ".join(_q(x) for x in c) + u" >> " + _q(log_path) + u" 2>&1")
    if open_dir:
        lines.append(u'start "" ' + _q(open_dir))
    script = os.path.splitext(log_path)[0] + u".cmd"
    f = io.open(script, "w", encoding="utf-8")
    try:
        f.write(u"\r\n".join(lines) + u"\r\n")
    finally:
        f.close()
    try:
        subprocess.Popen(["cmd", "/c", script], creationflags=0x08000000)
    except (TypeError, ValueError):
        subprocess.Popen(["cmd", "/c", script])
    return script


def sun_study_jobs(blender, bundle_ref, out_dir, base, cfg):
    """-> (render commands, board items). Shadow-study look, the view's own
    framing, the site's location/timezone from the loaded bundle."""
    year = time.localtime().tm_year
    res = cfg.get("resolution", [1600, 900])
    cmds, items = [], []
    for mmdd, short, _row in SUN_DATES:
        for h in SUN_HOURS:
            png = os.path.join(out_dir, u"%s_%s_%02dh.png" % (base, mmdd, h))
            cmds.append([blender, "--background", "--python",
                         bir_bootstrap.render_script_path(), "--",
                         "--bundle", bundle_ref, "--out", png,
                         "--mode", "shadow",
                         "--engine", str(cfg.get("engine") or "EEVEE"),
                         "--samples", str(min(int(cfg.get("samples") or 64), 128)),
                         "--resolution", str(min(res[0], 1600)), str(min(res[1], 900)),
                         "--sun-date", "%d-%s" % (year, mmdd),
                         "--sun-time", "%02d:00" % h])
            items.append({"image": png, "label": u"%s - %dh" % (short, h)})
    return cmds, items
