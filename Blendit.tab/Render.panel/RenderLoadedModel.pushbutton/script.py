# -*- coding: utf-8 -*-
u"""Renderiza a vista CARREGADA como est\u00e1, em segundo plano (sem abrir o Blender).

Renderiza a vista inteira que voc\u00ea j\u00e1 carregou, no Estilo / Qualidade / Resolu\u00e7\u00e3o
configurados. Use quando quiser s\u00f3 a imagem da vista atual, sem compor no Blender;
para escolher o enquadramento, use **Abrir Vista** e renderize pelo painel N.

Pode demorar num modelo grande (principalmente no Cycles), mas o Revit fica livre
e a imagem abre sozinha quando terminar. Carregue a vista antes (**Carregar Vista**).

Shift+Clique: o mesmo render em qualidade FINAL (Cycles, muitas amostras, sem ru\u00eddo)
- gostou do rascunho? Um clique gera a vers\u00e3o definitiva, sem mudar sua Qualidade.
"""
__title__ = "Renderizar\nVista"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
from bir_ui import (report as _report, launch_headless_render,
                    dismiss_output as _dismiss_output)


if launch_headless_render(bir_config.load(), _report):
    _dismiss_output(12)     # render continues detached; the PNG opens itself
