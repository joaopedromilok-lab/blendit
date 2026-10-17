# -*- coding: utf-8 -*-
u"""Qualidade r\u00e1pida: um clique define motor + amostras + redu\u00e7\u00e3o de ru\u00eddo juntos.

Rascunho = EEVEE, poucas amostras, sem redu\u00e7\u00e3o de ru\u00eddo   (pr\u00e9vias r\u00e1pidas)
Padr\u00e3o   = EEVEE, com redu\u00e7\u00e3o de ru\u00eddo                    (o dia a dia)
Alta     = Cycles, com redu\u00e7\u00e3o de ru\u00eddo                   (boas imagens finais)
Final    = Cycles, muitas amostras, sem ru\u00eddo              (melhor qualidade, lento)
"""
__title__ = "Qualidade"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
import bir_ui


def main():
    from pyrevit import forms
    order = bir_config.QUALITY_ORDER
    labels = [bir_config.QUALITY_LABELS[k] for k in order]
    cur = bir_config.load()
    picked = forms.CommandSwitchWindow.show(
        labels, message=u"Qualidade do render (motor + amostras + ru\u00eddo) - atual: %s / %s amostras"
        % (cur.get("engine"), cur.get("samples")))
    if not picked:
        return
    choice = order[labels.index(picked)]
    preset = bir_config.QUALITY[choice]
    cfg = bir_config.load()
    cfg.update(preset)
    if bir_config.save(cfg):
        # The user just chose from a dialog; don't make them dismiss another.
        bir_ui.toast(u"Qualidade: %s  -  %s, %s amostras, redu\u00e7\u00e3o de ru\u00eddo %s"
                     % (picked, preset["engine"], preset["samples"],
                        u"ligada" if preset["denoise"] else u"desligada"))
    else:
        forms.alert(u"N\u00e3o foi poss\u00edvel salvar a qualidade (o arquivo de "
                    u"configura\u00e7\u00e3o est\u00e1 bloqueado?). Nada foi alterado.",
                    title=u"Blendit - Qualidade")


main()
