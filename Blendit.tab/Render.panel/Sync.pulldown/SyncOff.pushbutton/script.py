# -*- coding: utf-8 -*-
u"""Para de escutar as mudan\u00e7as do modelo - zero custo, sem surpresas.
\u00c9 o padr\u00e3o; Carregar / Abrir / Renderizar continuam funcionando normalmente."""
__title__ = "Sinc.\nDesligado"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_sync
import bir_ui

bir_sync.set_mode(__revit__, "off", report=bir_ui.report)
