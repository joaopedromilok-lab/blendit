# -*- coding: utf-8 -*-
u"""Carrega a vista ativa no cache do Blendit.

Funciona numa **vista 3D** OU numa **planta / corte / eleva\u00e7\u00e3o** - a vista 2D entra
como desenho ortogr\u00e1fico em escala (enquadrado pela regi\u00e3o de recorte, cortado na
faixa da vista), que voc\u00ea pode renderizar direto ou ajustar no Abrir Vista.

\u00c9 o \u00fanico passo demorado (ele triangula a vista inteira), por isso \u00e9 expl\u00edcito e
mostra uma barra de progresso. N\u00c3O abre o Blender; depois de carregar, use
**Abrir Vista** para trabalhar interativamente ou **Renderizar Vista** para gerar
a imagem direto. Carregue de novo depois de alterar o modelo.
"""
__title__ = "Carregar\nVista"
__author__ = "Blendit"

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config
import bir_export
from bir_ui import (report as _report, active_doc as _active_doc,
                    ensure_loadable_view as _ensure_loadable_view,
                    dismiss_output as _dismiss_output,
                    launch_cache_build as _launch_cache_build)


def main():
    cfg = bir_config.load()
    doc = _active_doc()
    if not _ensure_loadable_view(doc, _report):   # 3D view or a 2D plan/section/elev
        return
    _report(u"**Blendit - Carregar Vista** - extraindo a vista ativa. Pode demorar "
            u"num modelo grande; a barra de progresso mostra o andamento.")

    bundle_ref, blend_path = bir_export.refresh_cache(doc, cfg, _report)

    msg = (u"- **vista carregada.** Agora use **Abrir Vista** para trabalhar no Blender, "
           u"ou **Renderizar Vista** para gerar a imagem como est\u00e1.\n- cache: `%s`" % bundle_ref)
    # Build the fast-open scene cache NOW, in the background - the import +
    # merge is Open View's slow step, so it's usually done before the user is.
    if _launch_cache_build(cfg, bundle_ref, blend_path):
        msg += (u"\n- preparando a cena de abertura r\u00e1pida em segundo plano - "
                u"o **Abrir Vista** fica r\u00e1pido quando estiver pronta (a lista "
                u"**Vistas** mostra *preparando cena...* at\u00e9 l\u00e1).")
    _report(msg)
    _dismiss_output(10)     # info only - the window closes itself


main()
