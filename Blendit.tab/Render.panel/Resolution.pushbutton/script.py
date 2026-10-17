# -*- coding: utf-8 -*-
u"""Resolu\u00e7\u00e3o r\u00e1pida: 720p / 1080p / 1440p / 4K (tamanho livre fica em Configura\u00e7\u00f5es)."""
__title__ = u"Resolu\u00e7\u00e3o"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
import bir_ui


def main():
    from pyrevit import forms
    cur = bir_config.get_value("resolution", [1600, 900])
    labels = [r[0] for r in bir_config.RESOLUTIONS]
    choice = forms.CommandSwitchWindow.show(
        labels, message=u"Resolu\u00e7\u00e3o da imagem (atual: %sx%s)" % (cur[0], cur[1]))
    if not choice:
        return
    for label, res in bir_config.RESOLUTIONS:
        if label == choice:
            if bir_config.set_value("resolution", res):
                # The user just chose from a dialog; no second one to dismiss.
                bir_ui.toast(u"Resolu\u00e7\u00e3o: %s  (%sx%s)" % (label, res[0], res[1]))
            else:
                forms.alert(u"N\u00e3o foi poss\u00edvel salvar a resolu\u00e7\u00e3o (o arquivo de "
                            u"configura\u00e7\u00e3o est\u00e1 bloqueado?). Nada foi alterado.",
                            title=u"Blendit - Resolu\u00e7\u00e3o")
            break


main()
