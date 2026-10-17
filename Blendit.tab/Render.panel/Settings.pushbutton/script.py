# -*- coding: utf-8 -*-
u"""Configura todo o processo de render do Blendit.

Um pequeno painel de ajustes: caminho do Blender, pasta de sa\u00edda, resolu\u00e7\u00e3o,
amostras, redu\u00e7\u00e3o de ru\u00eddo, motor e o estilo padr\u00e3o. Fica salvo em
%APPDATA%\\blendit\\config.json e vale para todos os bot\u00f5es.
"""
__title__ = u"Configura\u00e7\u00f5es"
__author__ = "Blendit"

import os
import subprocess

import bir_bootstrap
bir_bootstrap.ensure_paths()
import bir_config


_CUSTOM = u"Personalizada..."
_BLENDER = u"Caminho do blender.exe"
_FOLDER = u"Pasta dos renders"
_TEST = u"Render de teste (cena de demonstra\u00e7\u00e3o)"
_CLEAR = u"Limpar cache dos modelos"
_SHOW = u"Mostrar todas as configura\u00e7\u00f5es"


def _set_resolution(cfg):
    from pyrevit import forms
    labels = [r[0] for r in bir_config.RESOLUTIONS] + [_CUSTOM]
    choice = forms.CommandSwitchWindow.show(labels, message=u"Resolu\u00e7\u00e3o da imagem")
    if not choice:
        return
    if choice == _CUSTOM:
        cur = cfg.get("resolution", [1600, 900])
        w = forms.ask_for_string(default=str(cur[0]), prompt=u"Largura (px):",
                                 title=u"Resolu\u00e7\u00e3o")
        if w is None:                       # cancelled - not an input error
            return
        h = forms.ask_for_string(default=str(cur[1]), prompt=u"Altura (px):",
                                 title=u"Resolu\u00e7\u00e3o")
        if h is None:
            return
        try:
            res = [int(w), int(h)]
        except Exception:
            forms.alert(u"Informe dois n\u00fameros inteiros.", title=u"Resolu\u00e7\u00e3o")
            return
        if not bir_config.set_value("resolution", res):
            forms.alert(u"N\u00e3o foi poss\u00edvel salvar a resolu\u00e7\u00e3o (o arquivo de "
                        u"configura\u00e7\u00e3o est\u00e1 bloqueado?).", title=u"Resolu\u00e7\u00e3o")
        return
    for label, res in bir_config.RESOLUTIONS:
        if label == choice:
            bir_config.set_value("resolution", res)
            return


def _set_samples(cfg):
    from pyrevit import forms
    s = forms.ask_for_string(default=str(cfg.get("samples", 64)),
                             prompt=u"Amostras do render (mais = mais limpo, mais lento):",
                             title=u"Amostras")
    if s:
        try:
            bir_config.set_value("samples", max(1, int(s)))
        except Exception:
            forms.alert(u"Informe um n\u00famero inteiro.", title=u"Amostras")


def _set_default_mode(cfg):
    from pyrevit import forms
    import bir_ui
    labels = [bir_config.MODE_LABELS[k] for k in bir_config.MODES]
    choice = forms.CommandSwitchWindow.show(labels, message=u"Estilo padr\u00e3o do render")
    if not choice:
        return
    for key in bir_config.MODES:
        if bir_config.MODE_LABELS[key] == choice:
            bir_ui.set_mode(key)    # same toast + tooltip refresh as the ribbon
            return


def _test_render():
    """Prove the whole pipeline with the built-in demo scene - no model, no
    Load, about half a minute. The new-user 'does my install work?' answer."""
    from pyrevit import forms
    import bir_ui
    import bir_export
    from bir_contract.transport import stamped_name
    cfg = bir_config.load()
    blender = bir_ui.ensure_blender(cfg, bir_ui.report)
    if not blender:
        return
    bir_ui.report(u"**Blendit - render de teste** - renderizando a cena de demonstra\u00e7\u00e3o "
                  u"(n\u00e3o precisa de modelo) para testar todo o processo...")
    cdir = bir_bootstrap.cache_dir_for("demo")
    bundle_ref, _ = bir_export.export_bundle(None, cfg, bir_ui.report,
                                             out_dir=cdir)
    out_dir = cfg.get("output_dir") or bir_bootstrap.default_output_dir()
    if not os.path.isdir(out_dir):
        try:
            os.makedirs(out_dir)
        except Exception:
            pass
    png = os.path.join(out_dir, stamped_name("test_render", "png"))
    log_path = os.path.splitext(png)[0] + ".log"
    # Fixed fast settings (not the user's config): the point is a quick,
    # predictable proof that Blender + the pipeline work end to end.
    cmd = [blender, "--background", "--python",
           bir_bootstrap.render_script_path(), "--",
           "--bundle", bundle_ref, "--out", png, "--open",
           "--mode", "realistic", "--engine", "CYCLES", "--samples", "32",
           "--resolution", "960", "540"]
    try:
        logf = open(log_path, "wb")
        try:
            subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT)
        finally:
            logf.close()
    except OSError as ex:
        forms.alert(u"N\u00e3o foi poss\u00edvel abrir o Blender: %s" % ex,
                    title=u"Blendit - Render de teste")
        return
    bir_ui.report(u"- render de teste iniciado (cerca de meio minuto). **A imagem "
                  u"abre quando terminar.**\n- arquivo: `%s`\n- log (se der "
                  u"erro): `%s`" % (png, log_path))


def _clear_cache():
    from pyrevit import forms
    choice = forms.alert(
        u"Apagar todas as extra\u00e7\u00f5es de modelo e cenas preparadas em cache?\n\n"
        u"O pr\u00f3ximo Carregar Vista extrai tudo de novo. Feche antes as sess\u00f5es "
        u"do Blender abertas pelo Blendit.",
        title=u"Blendit - Limpar cache",
        options=[u"Limpar cache", u"Cancelar"])
    if choice != u"Limpar cache":
        return
    removed, failed = bir_bootstrap.clear_cache()
    msg = u"%d modelo(s) removido(s) do cache." % removed
    if failed:
        msg += (u"\n%d n\u00e3o puderam ser removidos (ainda em uso?) - feche o Blender e "
                u"tente de novo." % failed)
    forms.alert(msg, title=u"Blendit - Limpar cache")


def _show_all(cfg):
    from pyrevit import forms
    res = cfg.get("resolution", [1600, 900])
    forms.alert(
        u"Blender:    %s\nPasta:      %s\n\nEstilo:     %s\nMotor:      %s\n"
        u"Amostras:   %s\nSem ru\u00eddo:  %s\nResolu\u00e7\u00e3o:  %sx%s"
        % (cfg.get("blender_exe") or u"(detec\u00e7\u00e3o autom\u00e1tica)",
           cfg.get("output_dir") or u"(pasta padr\u00e3o)",
           bir_config.MODE_LABELS.get(cfg.get("mode"), cfg.get("mode")),
           cfg.get("engine"), cfg.get("samples"),
           u"sim" if cfg.get("denoise") else u"n\u00e3o", res[0], res[1]),
        title=u"Blendit - Configura\u00e7\u00f5es atuais")


def main():
    from pyrevit import forms
    while True:
        cfg = bir_config.load()
        res = cfg.get("resolution", [1600, 900])
        options = [
            _BLENDER,
            _FOLDER,
            u"Resolu\u00e7\u00e3o  (%sx%s)" % (res[0], res[1]),
            u"Amostras  (%s)" % cfg.get("samples"),
            u"Redu\u00e7\u00e3o de ru\u00eddo  (%s)" % (u"ligada" if cfg.get("denoise") else u"desligada"),
            u"Motor  (%s)" % cfg.get("engine"),
            u"Estilo padr\u00e3o  (%s)" % bir_config.MODE_LABELS.get(cfg.get("mode"),
                                                                cfg.get("mode")),
            _TEST,
            _CLEAR,
            _SHOW,
        ]
        choice = forms.CommandSwitchWindow.show(
            options, message=u"Blendit - Configura\u00e7\u00f5es")
        if not choice:
            return
        if choice == _BLENDER:
            p = forms.pick_file(file_ext="exe")
            if p:
                bir_config.set_value("blender_exe", p)
        elif choice == _FOLDER:
            p = forms.pick_folder()
            if p:
                bir_config.set_value("output_dir", p)
        elif choice.startswith(u"Resolu\u00e7\u00e3o"):
            _set_resolution(cfg)
        elif choice.startswith(u"Amostras"):
            _set_samples(cfg)
        elif choice.startswith(u"Redu\u00e7\u00e3o de ru\u00eddo"):
            bir_config.set_value("denoise", not cfg.get("denoise"))
        elif choice.startswith(u"Motor"):
            new = "CYCLES" if str(cfg.get("engine")).upper() == "EEVEE" else "EEVEE"
            bir_config.set_value("engine", new)
        elif choice.startswith(u"Estilo padr\u00e3o"):
            _set_default_mode(cfg)
        elif choice == _TEST:
            _test_render()
            return                      # leave the loop; the report is on screen
        elif choice == _CLEAR:
            _clear_cache()
        elif choice == _SHOW:
            _show_all(cfg)


main()
