# -*- coding: utf-8 -*-
u"""Envia as mudan\u00e7as juntadas desde a \u00faltima sincroniza\u00e7\u00e3o (o envio do Sinc. por
Comando; tamb\u00e9m serve de empurr\u00e3o manual com o Sinc. ao Vivo ligado)."""
__title__ = "Sincronizar\nAgora"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_sync
import bir_ui

bir_sync.sync_now(__revit__, report=bir_ui.report)
