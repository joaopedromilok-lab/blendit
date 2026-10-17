# -*- coding: utf-8 -*-
"""Shared Revit-side button helpers (IronPython 2.7 safe; user-facing text in pt-BR,
so the file is UTF-8 with the coding line above and u"" literals).

The pushbuttons were each re-defining report() / active_doc() / tail(); this is the
one copy. Uses pyRevit's own `revit.doc` instead of the raw `__revit__` builtin so
these work from a lib module (the builtin is only injected into the script scope).
"""


def dismiss_output(seconds=8):
    """Auto-close this command's pyRevit output window after `seconds` - the
    info reports shouldn't need manual dismissal. Call it LAST in a button
    script (the countdown starts immediately). No-op without pyRevit."""
    try:
        from pyrevit import script
        script.get_output().self_destruct(int(seconds))
    except Exception:
        pass


def report(msg):
    """Print markdown to the pyRevit output window (falls back to stdout)."""
    try:
        from pyrevit import script
        script.get_output().print_md(msg)
    except Exception:
        print(msg)


def active_doc():
    """The active Revit document, or None outside Revit."""
    try:
        from pyrevit import revit
        return revit.doc
    except Exception:
        return None


def tail(data, n=2000):
    """Last `n` chars of subprocess output (bytes or str), for error reports."""
    if not data:
        return ""
    try:
        text = data.decode("utf-8", "replace")
    except Exception:
        text = str(data)
    return text[-n:]


_BLENDER_DOWNLOAD_URL = "https://www.blender.org/download/"


def open_path(target):
    """Open a folder / file / URL with the OS default handler. Returns True on
    success.

    Robust on .NET Core / .NET 8 (Revit 2025+), where `Process.Start(path)` defaults
    UseShellExecute=False and THROWS for folders/URLs/non-exe paths (and IronPython's
    os.startfile can hit the same). We explicitly request a shell-execute first, then
    fall back to os.startfile for older .NET Framework hosts. Blendit ships its own
    copy so it never depends on the Luitools shared lib."""
    try:
        from System.Diagnostics import Process, ProcessStartInfo
        psi = ProcessStartInfo(target)
        psi.UseShellExecute = True            # the .NET-8-safe shell open
        Process.Start(psi)
        return True
    except Exception:
        pass
    try:
        import os
        os.startfile(target)                  # .NET Framework / non-Revit fallback
        return True
    except Exception:
        return False


def ensure_blender(cfg, report=None):
    """Return a usable blender.exe path, or None after telling the user how to fix it.

    Checks the configured path, then auto-detect (bir_bootstrap.find_blender_exe).
    If neither resolves, shows an actionable dialog - Download Blender (opens the
    download page) / Set Blender path... (file picker, saved to config) / Cancel -
    and returns None. Call this at the TOP of a launch button so a user without
    Blender is told immediately, before any slow extraction runs."""
    import os
    import bir_bootstrap
    configured = (cfg or {}).get("blender_exe")
    if configured and os.path.isfile(configured):
        return configured
    found = bir_bootstrap.find_blender_exe()
    if found:
        return found

    try:
        from pyrevit import forms
    except Exception:                       # headless / no pyRevit - just report
        if report:
            report(u"**Blender n\u00e3o encontrado.** Instale o Blender "
                   u"(%s) ou indique o caminho em Configura\u00e7\u00f5es."
                   % _BLENDER_DOWNLOAD_URL)
        return None

    choice = forms.alert(
        u"O Blender n\u00e3o foi encontrado neste computador.\n\n"
        u"O Blendit renderiza no Blender - um programa gratuito e separado. Instale-o "
        u"ou indique um blender.exe que j\u00e1 exista.",
        title=u"Blendit - Blender n\u00e3o encontrado",
        options=[u"Baixar o Blender", u"Indicar o caminho do Blender...", u"Cancelar"])
    if choice == u"Baixar o Blender":
        open_path(_BLENDER_DOWNLOAD_URL)
        if report:
            report(u"Abrindo a p\u00e1gina de download do Blender. Instale e depois aperte "
                   u"o bot\u00e3o de novo (ou indique o caminho em Configura\u00e7\u00f5es).")
    elif choice == u"Indicar o caminho do Blender...":
        p = forms.pick_file(file_ext="exe")
        if p and os.path.isfile(p):
            import bir_config
            bir_config.set_value("blender_exe", p)
            return p
    return None


def pick_loaded_view(doc, slots, message):
    """Offer the loaded-views list (newest first, with per-slot staleness) and
    return the chosen slot dict, or None (cancel / no pyRevit)."""
    import bir_export
    try:
        from pyrevit import forms
    except Exception:
        return None
    labels = []
    by_label = {}
    _cache_words = {"ready": u"cena pronta", "building": u"preparando cena...",
                    "none": u"cena n\u00e3o preparada"}
    for slot in slots:
        kind = slot.get("view_kind") or ""
        try:
            reason = bir_export.slot_staleness(doc, slot)
        except Exception:
            reason = None
        status = (u"  --  desatualizada: %s" % reason) if reason else ""
        try:
            cache_word = _cache_words[bir_export.cache_state(slot["blend_path"])]
        except Exception:
            cache_word = ""
        label = u"%s%s  (carregada %s%s)%s" % (
            slot["view_name"], ("  [%s]" % kind) if kind else "",
            slot.get("loaded_at") or "?",
            (", %s" % cache_word) if cache_word else "", status)
        labels.append(label)
        by_label[label] = slot
    picked = forms.SelectFromList.show(labels,
                                       title="Blendit - %s" % message,
                                       button_name=u"Selecionar", multiselect=False)
    if not picked:
        return None
    return by_label.get(picked)


def require_loaded(doc):
    """-> (bundle_ref, blend_path) if the ACTIVE view is already loaded (cached),
    else offer the list of other loaded views, else tell the user to Load View
    first and return (None, None).

    Open View / Render View consume a loaded view; loading (the slow Revit
    extraction) is the explicit, clearly-labelled Load View step - nothing else
    surprises the user with a long operation."""
    import bir_export
    bundle_ref, blend_path = bir_export.cached_bundle(doc)
    if bundle_ref is None:
        # The active view isn't loaded - other views might be.
        slots = bir_export.loaded_views(doc)
        if slots:
            slot = pick_loaded_view(
                doc, slots, u"A vista ativa n\u00e3o est\u00e1 carregada - escolha uma vista carregada:")
            if slot is not None:
                return slot["bundle_ref"], slot["blend_path"]
            return None, None
    if bundle_ref is not None:
        # Soft staleness check: warn (never block) when the model looks different
        # from what Load View extracted - the "why is my new wall missing?" fix.
        try:
            reason = bir_export.staleness(doc)
        except Exception:
            reason = None
        if reason:
            try:
                from pyrevit import forms
                choice = forms.alert(
                    u"A vista carregada pode estar desatualizada: %s.\n\n"
                    u"Use a vers\u00e3o em cache mesmo assim, ou cancele e aperte "
                    u"'Carregar Vista' para extrair de novo." % reason,
                    title=u"Blendit - a vista mudou desde o carregamento",
                    options=[u"Usar a vista em cache", u"Cancelar"])
                if choice != u"Usar a vista em cache":
                    return None, None
            except Exception:
                pass
        return bundle_ref, blend_path
    try:
        from pyrevit import forms
        forms.alert(u"Nenhuma vista carregada ainda.\n\nAperte 'Carregar Vista' para "
                    u"extrair a vista ativa e tente de novo.",
                    title=u"Blendit - nenhuma vista carregada")
    except Exception:
        pass
    return None, None


def ensure_loadable_view(doc, report=None):
    """True if the active view is one Blendit can extract - a 3D view OR a 2D plan /
    section / elevation - else show an alert and return False.

    Pressing a button from a sheet / schedule / drafting view would otherwise extract
    nothing and fall back to a confusing demo box. doc is None only headless/in dev,
    where the demo box is wanted - so allow that."""
    if doc is None:
        return True
    try:
        from bir_extract import revit_extract
        if revit_extract.active_view(doc) is not None:
            return True
    except Exception:
        return True            # don't block on an import hiccup; extraction reports
    try:
        from pyrevit import forms
        forms.alert(u"Abra uma vista que o Blendit consiga carregar.\n\nCarregar Vista "
                    u"funciona numa vista 3D ou numa planta / corte / eleva\u00e7\u00e3o - mude "
                    u"para uma delas (n\u00e3o folha nem tabela) e aperte o bot\u00e3o de novo.",
                    title=u"Blendit - esta vista n\u00e3o pode ser carregada")
    except Exception:
        if report:
            report(u"**Esta vista n\u00e3o pode ser carregada.** Abra uma vista 3D, planta, "
                   u"corte ou eleva\u00e7\u00e3o e tente de novo.")
    return False


# Back-compat alias (older name; now accepts 2D views too).
ensure_3d_view = ensure_loadable_view


def launch_cache_build(cfg, bundle_ref, blend_path):
    """Start the DETACHED, windowless background build of the fast-open .blend
    cache (import + merge are the slow part of Open View - do them while the
    user is still in Revit). Silent best-effort: no Blender configured, or a
    cache already present, just means Open View behaves as before. Returns
    True when a build was started."""
    import os
    import subprocess
    import bir_bootstrap

    if os.path.isfile(blend_path):
        return False                        # cache already exists
    blender = cfg.get("blender_exe") or bir_bootstrap.find_blender_exe()
    if not blender or not os.path.isfile(blender):
        return False                        # no popups here - Open View prompts
    cmd = [blender, "--background", "--python",
           bir_bootstrap.prepare_cache_script_path(), "--",
           "--bundle", bundle_ref, "--save-blend", blend_path]
    try:
        # Sentinel FIRST: Open View + the Views list read it to say
        # "scene building..." (prepare_cache removes it when done).
        try:
            f = open(blend_path + ".busy", "w")
            f.write("building")
            f.close()
        except Exception:
            pass
        logf = open(os.path.join(os.path.dirname(blend_path),
                                 "cache_build.log"), "wb")
        try:
            try:
                subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT,
                                 creationflags=0x08000000)  # CREATE_NO_WINDOW
            except (TypeError, ValueError):
                subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT)
        finally:
            logf.close()
        return True
    except Exception:
        try:
            os.remove(blend_path + ".busy")
        except Exception:
            pass
        return False


def launch_open_view(cfg, report, bundle_ref, blend_path):
    """Launch the interactive Open View session for a loaded bundle (shared by
    the Open View button and the Views list). Returns True when launched."""
    import os
    import subprocess
    import bir_bootstrap

    blender = ensure_blender(cfg, report)
    if not blender:
        return False
    live_py = bir_bootstrap.live_script_path()
    cap_dir = cfg.get("output_dir") or bir_bootstrap.default_output_dir()
    # Force EEVEE for a responsive realtime viewport. --save-blend builds/refreshes
    # the fast-open cache; --blend opens it directly when it already exists.
    # Open in White/Clay (fast, robust for composing) - switch modes live from
    # the N-panel. The render-mode config drives Render View finals.
    # blender-launcher.exe = no black console window alongside the app.
    cmd = [bir_bootstrap.windowed_blender_exe(blender), "--python", live_py, "--",
           "--bundle", bundle_ref, "--save-blend", blend_path,
           "--capture-dir", cap_dir,
           "--engine", "EEVEE", "--mode", "white"]
    # Live/Trigger sync on -> the session must watch the patch spool. --watch
    # forces an un-merged fresh import (per-element deltas), so the session
    # skips the merged .blend cache both ways for this launch.
    try:
        import bir_sync
        if bir_sync.get_state() != "off":
            cmd.append("--watch")
            report(u"**Sinc. ao vivo** - abrindo sem mesclar para as edi\u00e7\u00f5es do Revit "
                   u"chegarem (importa\u00e7\u00e3o nova; o cache r\u00e1pido n\u00e3o \u00e9 usado).")
    except Exception:
        pass
    import bir_export
    state = bir_export.cache_state(blend_path)
    if state == "building":
        # The background build from Load View is still running - opening now
        # means a slow fresh import. Let the user choose.
        try:
            from pyrevit import forms
            choice = forms.alert(
                u"A cena de abertura r\u00e1pida ainda est\u00e1 sendo preparada em "
                u"segundo plano.\n\nEspere alguns minutos e o Abrir Vista ser\u00e1 "
                u"r\u00e1pido - ou abra agora com uma importa\u00e7\u00e3o nova (mais lenta; o "
                u"Blender pode mostrar 'N\u00e3o est\u00e1 respondendo' enquanto trabalha).",
                title=u"Blendit - cache da cena ainda em preparo",
                options=[u"Abrir agora (importa\u00e7\u00e3o nova)", u"Cancelar - vou esperar"])
            if choice != u"Abrir agora (importa\u00e7\u00e3o nova)":
                return False
        except Exception:
            pass
    if os.path.isfile(blend_path):
        cmd += ["--blend", blend_path]
        report(u"**Blendit** - abrindo a vista carregada (r\u00e1pido: cena em cache)")
    else:
        report(u"**Blendit** - abrindo a vista carregada (a primeira abertura prepara o "
               u"cache r\u00e1pido - modelos grandes com v\u00ednculos podem levar alguns minutos; "
               u"o Blender pode mostrar 'N\u00e3o est\u00e1 respondendo' enquanto trabalha)")
    report(u"- abrindo o Blender... Navegue para compor, **Enter** captura, "
           u"**N** mostra o painel, **F10** alterna a interface completa do Blender.")
    try:
        # Detached: do NOT wait. Blender stays open; Revit is not blocked.
        subprocess.Popen(cmd)
        return True
    except OSError as ex:
        report(u"**ERRO** ao abrir o Blender: %s\n\n"
               u"Indique o caminho do Blender em Configura\u00e7\u00f5es (ou BLENDIT_BLENDER_EXE)." % ex)
        return False


def launch_headless_render(cfg, report, banner=u"Renderizar Vista", bundle_ref=None):
    """The Render View launch, shared with its Shift+Click 'at Final
    quality' variant and the Views list: pre-flight Blender, require a loaded
    view (or take an explicit `bundle_ref`), then start a DETACHED headless
    render of the cached bundle with cfg's settings as CLI overrides (the
    bundle is a pure geometry cache). Returns True when a render was launched."""
    import os
    import subprocess
    import bir_bootstrap
    from bir_contract.transport import stamped_name

    blender = ensure_blender(cfg, report)
    if not blender:
        return False
    if bundle_ref is None:
        doc = active_doc()
        bundle_ref, _blend = require_loaded(doc)    # error popup if not loaded
    if bundle_ref is None:
        return False

    res = cfg.get("resolution", [1600, 900])
    import bir_config
    report(u"**Blendit - %s**  \n"
           u"estilo **%s** | motor **%s** | %sx%s | %s amostras%s"
           % (banner, bir_config.MODE_LABELS.get(cfg.get("mode"), cfg.get("mode")),
              cfg.get("engine"), res[0], res[1],
              cfg.get("samples"), u" | sem ru\u00eddo" if cfg.get("denoise") else ""))

    out_dir = cfg.get("output_dir") or bir_bootstrap.default_output_dir()
    if not os.path.isdir(out_dir):
        try:
            os.makedirs(out_dir)
        except Exception:
            pass
    png = os.path.join(out_dir, stamped_name("render", "png"))
    # Log shares the PNG's stamp: concurrent renders never fight over one file.
    log_path = os.path.splitext(png)[0] + ".log"
    render_py = bir_bootstrap.render_script_path()
    # --open: Blender opens the PNG itself when done, so Revit isn't blocked.
    cmd = [blender, "--background", "--python", render_py, "--",
           "--bundle", bundle_ref, "--out", png, "--open",
           "--mode", str(cfg.get("mode") or "realistic"),
           "--engine", str(cfg.get("engine") or "EEVEE"),
           "--samples", str(cfg.get("samples") or 64),
           "--resolution", str(res[0]), str(res[1]),
           "--denoise", "on" if cfg.get("denoise") else "off"]
    try:
        logf = open(log_path, "wb")
        try:
            # CREATE_NO_WINDOW: a headless render needs no console flashing up;
            # its output already goes to the log file.
            try:
                subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT,
                                 creationflags=0x08000000)
            except (TypeError, ValueError):
                subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT)
        finally:
            logf.close()      # the child holds its own handle; don't leak ours
    except OSError as ex:
        report(u"**ERRO** ao abrir o Blender: %s\n\n"
               u"Indique o caminho do Blender em Configura\u00e7\u00f5es (ou BLENDIT_BLENDER_EXE)." % ex)
        return False

    report(u"- renderizando em segundo plano (pode demorar num modelo grande) - "
           u"**o Revit fica livre para usar.** A imagem abre quando terminar."
           u"\n- arquivo: `%s`\n- log (se der erro): `%s`" % (png, log_path))
    return True


def set_mode(key):
    """Set the render mode (shared by the Mode buttons). Deliberately
    popup-free: picking a mode is a one-click action, not a dialog
    conversation - feedback is a passive toast (auto-dismisses, steals no
    focus, stacks no windows) carrying the mode's preview image, plus a
    refreshed Mode-pulldown tooltip. Only a FAILED save interrupts."""
    import bir_config
    ok = bir_config.set_value("mode", key)
    label = bir_config.MODE_LABELS.get(key, key)
    if not ok:
        msg = (u"N\u00e3o foi poss\u00edvel salvar o estilo (o arquivo de configura\u00e7\u00e3o est\u00e1 "
               u"bloqueado ou somente leitura?). Nada foi alterado.")
        try:
            from pyrevit import forms
            forms.alert(msg, title="Blendit")
        except Exception:
            print(msg)
        return
    ensure_mode_tooltips()          # in case startup ran before the ribbon existed
    toast(u"Estilo do render: %s" % label, image=mode_preview_path(key))
    update_mode_tooltip(label)


def mode_preview_path(key):
    """Path to the shipped demo-scene preview image for a render mode."""
    import os
    import bir_bootstrap
    return os.path.join(bir_bootstrap.REPO_ROOT, "media", "modes",
                        "%s.png" % key)


# --- passive feedback: Windows toast ----------------------------------------
def _xml_escape(s):
    s = str(s)
    for a, b in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
                 ('"', "&quot;"), ("'", "&apos;")):
        s = s.replace(a, b)
    return s


def _toast_icon():
    """A PNG to brand the Blendit toasts with, or None."""
    import os
    import bir_bootstrap
    p = os.path.join(bir_bootstrap.REPO_ROOT, "Blendit.tab", "Render.panel",
                     "About.pushbutton", "icon.png")
    return p if os.path.isfile(p) else None


def toast(message, title="Blendit", image=None):
    """Fire-and-forget Windows toast via a hidden PowerShell (WinRT). The
    polite alternative to a modal alert. `image` (a PNG path) becomes the
    toast's hero image. Returns True if launched; never raises - missing
    toast support must never break a button.

    Windows only DELIVERS toasts for a registered AppUserModelID - an
    unknown id fails silently (Show() succeeds, nothing appears). So the
    script first (idempotently) registers 'Blendit' under
    HKCU\\Software\\Classes\\AppUserModelId (user-writable, no admin), the
    documented route for unpackaged apps."""
    try:
        import base64
        import os
        img = ""
        if image and os.path.isfile(image):
            img = ('<image placement="hero" src="'
                   + _xml_escape("file:///" + image.replace("\\", "/"))
                   + '"/>')
        xml = ('<toast><visual><binding template="ToastGeneric"><text>'
               + _xml_escape(title) + "</text><text>" + _xml_escape(message)
               + "</text>" + img + "</binding></visual></toast>")
        reg = ("$k='HKCU:\\SOFTWARE\\Classes\\AppUserModelId\\Blendit';"
               "if (-not (Test-Path $k)) { New-Item -Path $k -Force "
               "| Out-Null };"
               "Set-ItemProperty -Path $k -Name DisplayName -Value 'Blendit';")
        icon = _toast_icon()
        if icon:
            reg += ("Set-ItemProperty -Path $k -Name IconUri -Value '"
                    + icon.replace("'", "''") + "';")
        # -EncodedCommand sidesteps every quoting pitfall; the XML is safe
        # inside PS single quotes because _xml_escape removed the apostrophes.
        ps = (reg
              + "[Windows.UI.Notifications.ToastNotificationManager, "
              "Windows.UI.Notifications, ContentType=WindowsRuntime] "
              "| Out-Null;"
              "[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom."
              "XmlDocument, ContentType=WindowsRuntime] | Out-Null;"
              "$x = New-Object Windows.Data.Xml.Dom.XmlDocument;"
              "$x.LoadXml('" + xml + "');"
              "$t = New-Object Windows.UI.Notifications.ToastNotification $x;"
              "[Windows.UI.Notifications.ToastNotificationManager]::"
              "CreateToastNotifier('Blendit').Show($t)")
        b64 = base64.b64encode(ps.encode("utf-16-le"))
        if not isinstance(b64, str):
            b64 = b64.decode("ascii")
        from System.Diagnostics import Process, ProcessStartInfo
        psi = ProcessStartInfo(
            "powershell.exe",
            "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand "
            + b64)
        psi.CreateNoWindow = True
        psi.UseShellExecute = False
        Process.Start(psi)
        return True
    except Exception:
        return False


# --- ribbon hover tooltips (previews live on hover, not in popups) ----------
# The mode key -> the ribbon button label (each Mode script's __title__).
# Line breaks in a __title__ count as spaces here (see find_ribbon_item).
MODE_BUTTON_TEXT = {
    "realistic": u"Realista", "white": u"Maquete Branca", "shadow": u"Estudo de Sombras",
    "specular": u"Showroom", "linework": u"Tra\u00e7o", "pen": u"Caneta",
    "sketch": u"Croqui", "cel": u"Cartoon", "hatch": u"Hachura",
    "crosshatch": u"Hachura Cruzada", "yellowtrace": u"Papel Manteiga",
    "kraft": u"Papel Kraft", "blueprint": u"Blueprint",
    "diagram": u"Diagrama", "watercolor": u"Aquarela",
    "risograph": u"Risografia",
}

_TOOLTIPS_DONE = [False]


def find_ribbon_item(text, tab_title="Blendit"):
    """The AdWindows RibbonItem on our tab whose label equals `text`, or None.
    Raw AdWindows walk (stable API, no pyRevit-version coupling); callers
    guard the import."""
    import Autodesk.Windows as adw

    def _walk(items):
        for it in items:
            t = getattr(it, "Text", None)
            if t and str(t).replace("\r", " ").replace("\n", " ") == text:
                return it
            kids = getattr(it, "Items", None)
            if kids:
                found = _walk(kids)
                if found is not None:
                    return found
        return None

    for tab in adw.ComponentManager.Ribbon.Tabs:
        if tab.Title == tab_title:
            for panel in tab.Panels:
                found = _walk(panel.Source.Items)
                if found is not None:
                    return found
    return None


def set_ribbon_tooltip_image(text, image_path):
    """Attach a preview image to a ribbon item's extended (hover) tooltip."""
    try:
        import os
        if not os.path.isfile(image_path):
            return False
        import Autodesk.Windows as adw
        from System import Uri
        from System.Windows.Media.Imaging import BitmapImage, BitmapCacheOption
        item = find_ribbon_item(text)
        if item is None:
            return False
        tip = item.ToolTip
        if not isinstance(tip, adw.RibbonToolTip):
            new_tip = adw.RibbonToolTip()
            new_tip.Title = text
            if tip:
                new_tip.Content = str(tip)
            tip = new_tip
        # OnLoad is LOAD-BEARING: the default (lazy) BitmapImage keeps the PNG's
        # file handle open for the ribbon's lifetime, LOCKING the preview files
        # against regeneration for as long as Revit runs. Load now, release.
        img = BitmapImage()
        img.BeginInit()
        img.UriSource = Uri(image_path)
        img.CacheOption = BitmapCacheOption.OnLoad
        img.EndInit()
        try:
            img.Freeze()
        except Exception:
            pass
        tip.ExpandedImage = img
        item.ToolTip = tip
        return True
    except Exception:
        return False


def set_ribbon_tooltip_text(text, tooltip):
    """Set / refresh a ribbon item's hover tooltip text."""
    try:
        import Autodesk.Windows as adw
        item = find_ribbon_item(text)
        if item is None:
            return False
        tip = item.ToolTip
        if isinstance(tip, adw.RibbonToolTip):
            tip.Content = tooltip
        else:
            item.ToolTip = tooltip
        return True
    except Exception:
        return False


def update_mode_tooltip(label):
    """Hovering the Mode pulldown answers 'what is it set to right now?'."""
    set_ribbon_tooltip_text(
        u"Estilo", u"Estilo do pr\u00f3ximo render.\nAtual: %s" % label)


def ensure_mode_tooltips(force=False):
    """Attach every mode's preview image to its button tooltip + reflect the
    current mode on the pulldown. Idempotent and cheap; called from startup.py
    AND on first mode use, because startup may run before the ribbon exists."""
    if _TOOLTIPS_DONE[0] and not force:
        return
    import bir_config
    ok_any = False
    for key, text in MODE_BUTTON_TEXT.items():
        if set_ribbon_tooltip_image(text, mode_preview_path(key)):
            ok_any = True
    try:
        cur = bir_config.get_value("mode")
        update_mode_tooltip(bir_config.MODE_LABELS.get(cur, cur))
    except Exception:
        pass
    if ok_any:
        _TOOLTIPS_DONE[0] = True
