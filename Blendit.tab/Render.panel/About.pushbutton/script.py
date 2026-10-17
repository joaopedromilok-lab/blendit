# -*- coding: utf-8 -*-
u"""Sobre o Blendit - o que \u00e9, o reposit\u00f3rio e o portf\u00f3lio do autor."""
__title__ = "Sobre"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
from bir_ui import report as _report, open_path as _open_path

_GITHUB = "https://github.com/lewismconte/blendit"
_PORTFOLIO = "https://lewismconte.github.io/portfolio"

_ABOUT_MD = (
    "# Blendit\n"
    u"Um clique no Revit -> a vista 3D ativa, renderizada no Blender.\n\n"
    u"Uma **ponte** de c\u00f3digo aberto (MIT) entre o Revit e o Blender: aperte um bot\u00e3o "
    u"e tenha um render de alta qualidade da vista atual, com bons padr\u00f5es j\u00e1 "
    u"prontos e **dezesseis estilos** - fotorrealista, maquete branca, estudo de "
    u"sombras, showroom e uma fam\u00edlia de desenho/impress\u00e3o: tra\u00e7o, caneta, croqui, "
    u"cartoon, hachura, hachura cruzada, papel manteiga, papel kraft, blueprint, "
    u"diagrama, aquarela e risografia - al\u00e9m da sess\u00e3o interativa **Abrir Vista**, "
    u"**plantas / eleva\u00e7\u00f5es / cortes 2D** em escala, vistas salvas com render em "
    u"lote, folha de contato com os 16 estilos e exporta\u00e7\u00e3o vetorial **SVG / PDF**.\n\n"
    u"- **C\u00f3digo + documenta\u00e7\u00e3o:** %s\n"
    u"- **Portf\u00f3lio:** %s\n"
    u"- Tradu\u00e7\u00e3o para portugu\u00eas: adapta\u00e7\u00e3o local.\n" % (_GITHUB, _PORTFOLIO))


def main():
    _report(_ABOUT_MD)                       # full blurb + clickable links in output
    try:
        from pyrevit import forms
        choice = forms.alert(
            u"Blendit\n\nUm clique no Revit, renderizado no Blender.\n"
            u"C\u00f3digo aberto, licen\u00e7a MIT.",
            title=u"Sobre o Blendit",
            options=[u"Abrir GitHub", u"Abrir Portf\u00f3lio", u"Fechar"])
        if choice == u"Abrir GitHub":
            _open_path(_GITHUB)
        elif choice == u"Abrir Portf\u00f3lio":
            _open_path(_PORTFOLIO)
    except Exception:
        pass                                 # headless: the report() above stands


main()
