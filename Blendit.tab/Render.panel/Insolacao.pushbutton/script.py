# -*- coding: utf-8 -*-
u"""Estudo de insola\u00e7\u00e3o da vista carregada: 9 imagens no estilo Estudo de sombras
(21/06, 21/03 e 21/12, \u00e0s 9h, 12h e 15h) e uma prancha em PDF com carimbo.

Usa a localiza\u00e7\u00e3o e o fuso do projeto (Gerenciar > Localiza\u00e7\u00e3o) e o carimbo vem
das Informa\u00e7\u00f5es do projeto. Roda em segundo plano; o Revit fica livre.
"""
__title__ = u"Insola\u00e7\u00e3o"
__author__ = "Blendit"

import os

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_board
import bir_config
from bir_ui import (report as _report, active_doc as _active_doc,
                    require_loaded as _require_loaded, ensure_blender as _ensure_blender,
                    dismiss_output as _dismiss_output)

_NO_BOARD = u"S\u00f3 as imagens (sem prancha)"


def main():
    from pyrevit import forms
    cfg = bir_config.load()
    blender = _ensure_blender(cfg, _report)
    if not blender:
        return
    doc = _active_doc()
    bundle_ref, _blend = _require_loaded(doc)
    if bundle_ref is None:
        return
    choice = forms.CommandSwitchWindow.show(
        bir_board.PAPERS + [_NO_BOARD],
        message=u"Estudo de insola\u00e7\u00e3o: 9 imagens. Papel da prancha:")
    if not choice:
        return
    out_dir = cfg.get("output_dir") or bir_bootstrap.default_output_dir()
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    base = u"insolacao_" + bir_board._stamp()
    cmds, items = bir_board.sun_study_jobs(blender, bundle_ref, out_dir, base, cfg)
    if choice != _NO_BOARD:
        man = {"out": os.path.join(out_dir, base + u".pdf"), "format": choice, "cols": 3,
               "title": u"Estudo de insola\u00e7\u00e3o", "fields": bir_board.title_fields(doc),
               "row_labels": [r[2] for r in bir_board.SUN_DATES], "items": items,
               "note": u"Hor\u00e1rios locais do terreno (localiza\u00e7\u00e3o do projeto no Revit).",
               "open": True}
        cmds.append(bir_board.board_cmd(blender, bir_board.write_manifest(out_dir, man)))
    bir_board.run_queue(cmds, os.path.join(out_dir, base + u".log"), open_dir=out_dir)
    _report(u"**Blendit - Estudo de insola\u00e7\u00e3o** - 9 renders na fila%s.\n"
            u"- leva alguns minutos; **o Revit fica livre.** A pasta abre quando terminar.\n"
            u"- pasta: `%s`" % (u" + prancha em PDF" if choice != _NO_BOARD else u"", out_dir))
    _dismiss_output(12)


main()
