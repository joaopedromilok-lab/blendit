# -*- coding: utf-8 -*-
u"""Suas vistas carregadas, numa lista s\u00f3.

Cada vista em que voc\u00ea usou **Carregar Vista** guarda a pr\u00f3pria c\u00f3pia, ent\u00e3o
plantas, cortes, eleva\u00e7\u00f5es e vistas 3D podem ficar carregadas lado a lado. Aqui
aparecem - as mais novas primeiro, marcadas **desatualizada** quando o modelo mudou
desde o carregamento (ou a vista foi apagada) - e voc\u00ea pode **Abrir** no Blender,
**Renderizar**, **Recarregar** (extrair de novo, mesmo sem ser a vista ativa)
ou **Remover** o cache.
"""
__title__ = "Vistas"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
import bir_export
from bir_ui import (report as _report, active_doc as _active_doc,
                    pick_loaded_view as _pick, toast as _toast,
                    launch_open_view as _open, launch_headless_render as _render,
                    dismiss_output as _dismiss_output,
                    launch_cache_build as _launch_cache_build)


_OPEN = u"Abrir no Blender"
_RENDER = u"Renderizar"
_RELOAD = u"Recarregar"
_REMOVE = u"Remover"


def _alert(msg, title=u"Blendit - Vistas"):
    try:
        from pyrevit import forms
        forms.alert(msg, title=title)
    except Exception:
        _report(msg)


def main():
    cfg = bir_config.load()
    doc = _active_doc()
    slots = bir_export.loaded_views(doc)
    if not slots:
        _alert(u"Nenhuma vista carregada ainda.\n\nUse 'Carregar Vista' numa vista 3D, "
               u"planta, corte ou eleva\u00e7\u00e3o - cada vista carregada guarda a pr\u00f3pria "
               u"c\u00f3pia e aparece aqui.")
        return

    slot = _pick(doc, slots, u"Escolha uma vista carregada:")
    if slot is None:
        return

    try:
        from pyrevit import forms
        action = forms.CommandSwitchWindow.show(
            [_OPEN, _RENDER, _RELOAD, _REMOVE],
            message=u"'%s' - o que voc\u00ea quer fazer?" % slot["view_name"])
    except Exception:
        action = None
    if not action:
        return

    if action == _OPEN:
        _open(cfg, _report, slot["bundle_ref"], slot["blend_path"])
    elif action == _RENDER:
        _render(cfg, _report, banner=u"Renderizar '%s'" % slot["view_name"],
                bundle_ref=slot["bundle_ref"])
    elif action == _RELOAD:
        view = bir_export.resolve_view(doc, slot.get("view_uid"))
        if view is None:
            _alert(u"'%s' n\u00e3o existe mais no modelo - o cache s\u00f3 pode ser "
                   u"aberto ou removido." % slot["view_name"])
            return
        _report(u"**Blendit - recarregando '%s'**" % slot["view_name"])
        bundle_ref, blend_path = bir_export.refresh_cache(doc, cfg, _report,
                                                          view=view)
        _launch_cache_build(cfg, bundle_ref, blend_path)
        _toast(u"Recarregada: %s" % slot["view_name"])
    elif action == _REMOVE:
        if bir_export.remove_slot(slot):
            _toast(u"Removida: %s" % slot["view_name"])
        else:
            _alert(u"N\u00e3o foi poss\u00edvel remover '%s' - os arquivos podem estar abertos "
                   u"num Blender em execu\u00e7\u00e3o." % slot["view_name"])
    _dismiss_output(10)     # info only - the window closes itself


main()
