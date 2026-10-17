# -*- coding: utf-8 -*-
u"""Variante Shift+Clique do Renderizar Vista: o mesmo render em qualidade
FINAL (Cycles, muitas amostras, sem ru\u00eddo). Sua configura\u00e7\u00e3o de Qualidade
salva n\u00e3o \u00e9 alterada."""

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
from bir_ui import (report as _report, launch_headless_render,
                    dismiss_output as _dismiss_output)


cfg = bir_config.load()
cfg.update(bir_config.QUALITY["Final"])   # engine + samples + denoise only
if launch_headless_render(cfg, _report,
                          banner=u"Renderizar Vista em qualidade FINAL"):
    _dismiss_output(12)     # render continues detached; the PNG opens itself
