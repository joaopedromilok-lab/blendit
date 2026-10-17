# -*- coding: utf-8 -*-
u"""Junta as edi\u00e7\u00f5es em sil\u00eancio e s\u00f3 envia quando voc\u00ea aperta Sincronizar Agora -
o modo controlado: fa\u00e7a v\u00e1rias edi\u00e7\u00f5es e sincronize uma vez."""
__title__ = "Sinc. por\nComando"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_sync
import bir_ui

bir_sync.set_mode(__revit__, "trigger", report=bir_ui.report)
