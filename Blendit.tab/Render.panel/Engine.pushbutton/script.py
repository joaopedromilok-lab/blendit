# -*- coding: utf-8 -*-
u"""Alterna o motor de render do pr\u00f3ximo render: EEVEE <-> CYCLES.

EEVEE = r\u00e1pido, quase em tempo real; CYCLES = render final preciso.
"""
__title__ = "Motor"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
import bir_ui


def main():
    cur = str(bir_config.get_value("engine", "EEVEE")).upper()
    new = "CYCLES" if cur == "EEVEE" else "EEVEE"
    if bir_config.set_value("engine", new):
        # Passive toast, no modal: a toggle shouldn't demand a click to dismiss.
        bir_ui.toast(u"Motor de render: %s  (EEVEE = r\u00e1pido, Cycles = qualidade final)"
                     % new)
        return
    msg = (u"N\u00e3o foi poss\u00edvel salvar o motor (o arquivo de configura\u00e7\u00e3o est\u00e1 "
           u"bloqueado?). Nada foi alterado.")
    try:
        from pyrevit import forms
        forms.alert(msg, title=u"Blendit - Motor")
    except Exception:
        print(msg)


main()
