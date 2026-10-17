# -*- coding: utf-8 -*-
"""Define o estilo de render: Showroom / lookdev (destaca reflexos e rugosidade)."""
__title__ = "Showroom"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_ui

bir_ui.set_mode("specular")
