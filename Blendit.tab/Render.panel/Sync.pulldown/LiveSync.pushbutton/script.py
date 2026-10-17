# -*- coding: utf-8 -*-
u"""Envia as edi\u00e7\u00f5es para a sess\u00e3o aberta do Blender automaticamente: as mudan\u00e7as
s\u00e3o juntadas enquanto voc\u00ea trabalha e enviadas sempre que o Revit fica ocioso.
Abra a vista com Abrir Vista antes, para ter uma sess\u00e3o escutando."""
__title__ = "Sinc. ao\nVivo"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_sync
import bir_ui

bir_sync.set_mode(__revit__, "live", report=bir_ui.report)
