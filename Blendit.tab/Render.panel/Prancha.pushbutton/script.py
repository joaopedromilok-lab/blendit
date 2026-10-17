# -*- coding: utf-8 -*-
u"""Monta uma prancha em PDF (A4 a A1) com as imagens que voc\u00ea escolher, com
carimbo preenchido pelas Informa\u00e7\u00f5es do projeto do Revit.

Escolha os renders (at\u00e9 12), o papel e um t\u00edtulo. Roda em segundo plano e o PDF
abre sozinho quando fica pronto.
"""
__title__ = u"Prancha"
__author__ = "Blendit"

import os

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_board
import bir_config
from bir_ui import (report as _report, active_doc as _active_doc,
                    ensure_blender as _ensure_blender, dismiss_output as _dismiss_output)


def main():
    from pyrevit import forms
    cfg = bir_config.load()
    blender = _ensure_blender(cfg, _report)
    if not blender:
        return
    out_dir = cfg.get("output_dir") or bir_bootstrap.default_output_dir()
    files = forms.pick_file(file_ext="png", multi_file=True, init_dir=out_dir,
                            title=u"Escolha os renders da prancha")
    if not files:
        return
    files = sorted(files)[:12]
    paper = forms.CommandSwitchWindow.show(bir_board.PAPERS, message=u"Papel da prancha:")
    if not paper:
        return
    title = forms.ask_for_string(default=u"Perspectivas", prompt=u"T\u00edtulo da prancha:",
                                 title=u"Blendit - Prancha")
    if title is None:
        return
    base = u"prancha_" + bir_board._stamp()
    items = [{"image": f, "label": os.path.splitext(os.path.basename(f))[0].replace(u"_", u" ")}
             for f in files]
    man = {"out": os.path.join(out_dir, base + u".pdf"), "format": paper, "title": title,
           "fields": bir_board.title_fields(_active_doc()), "items": items,
           "note": u"Imagens ilustrativas. Renders gerados com Blendit.", "open": True}
    bir_board.run_queue([bir_board.board_cmd(blender, bir_board.write_manifest(out_dir, man))],
                        os.path.join(out_dir, base + u".log"))
    _report(u"**Blendit - Prancha** - montando %d imagem(ns) em %s. O PDF abre sozinho.\n"
            u"- arquivo: `%s`" % (len(items), paper, man["out"]))
    _dismiss_output(10)


main()
