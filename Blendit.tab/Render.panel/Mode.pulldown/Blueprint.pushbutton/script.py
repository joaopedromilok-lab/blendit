# -*- coding: utf-8 -*-
u"""Define o estilo de render: Blueprint (tra\u00e7o branco sobre azul de c\u00f3pia heliogr\u00e1fica)."""
__title__ = "Blueprint"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_ui

bir_ui.set_mode("blueprint")
