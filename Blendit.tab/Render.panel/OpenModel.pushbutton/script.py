# -*- coding: utf-8 -*-
u"""Abre a vista carregada numa sess\u00e3o interativa do Blender (navega\u00e7\u00e3o em tempo real).

Abre a vista que voc\u00ea j\u00e1 carregou (use **Carregar Vista** antes). Navegue,
enquadre a cena, monte plantas / eleva\u00e7\u00f5es 2D e renderize pelo painel 'Blendit'
(tecla N no Blender) - Capturar para uma imagem r\u00e1pida, Render Final para alta qualidade.
Reabrir \u00e9 r\u00e1pido: usa o cache da cena j\u00e1 preparado, sem importar de novo.

N\u00e3o d\u00e1 para abrir uma vista que n\u00e3o foi carregada - nesse caso o Blendit avisa.
"""
__title__ = "Abrir\nVista"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
from bir_ui import (report as _report, active_doc as _active_doc,
                    require_loaded as _require_loaded,
                    launch_open_view as _launch_open_view,
                    dismiss_output as _dismiss_output)


def main():
    cfg = bir_config.load()
    doc = _active_doc()
    bundle_ref, blend_path = _require_loaded(doc)   # error popup if not loaded
    if bundle_ref is None:
        return
    if _launch_open_view(cfg, _report, bundle_ref, blend_path):
        _dismiss_output(10)     # info only - the window closes itself


main()
