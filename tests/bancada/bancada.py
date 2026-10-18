"""Bancada de comparação de materiais / exposição (Etapa 0).

    blender --background --python tests/bancada/bancada.py -- --saida <pasta> [--rotulo 0.5.0]
            [--res 400] [--pacotes <pasta já exportada>]

(ou `python3 tests/bancada/bancada.py -- ...` com o módulo bpy instalado)

Mede o comportamento ATUAL do pipeline, sem mudar nada nele:
  1. EXPOSIÇÃO E BALANÇO: as três salas de bancada_cenas.rb (mesma luz, paredes
     cinza / azuis / terracota) passam pelo render de produção
     (run.build_scene + run._render, que chama autoexpose.apply_auto). Registra
     a exposição (EV) e o balanço (K) escolhidos e a cor média da imagem.
     Renderiza também uma REFERÊNCIA: as três salas com a exposição e o
     balanço FIXOS da sala cinza - o que a cor do projeto deveria parecer.
     Esperado depois da correção: com a mesma luz, EV e K quase iguais nas três.
  2. RELEVO: painéis "pedra" (textura de 2 m) e "tecido" (0,5 m) com o MESMO
     mapa de altura. Lê do shader final o Bump (força, distância) e calcula a
     inclinação que ele produz na borda das células; compara com a inclinação
     física declarada em cenas.json. Renderiza com sol rasante e mede o
     contraste do relevo (desvio/ média da luminância no centro do painel).
     Esperado: pedra com relevo pelo menos tão forte quanto o tecido.
  3. ACABAMENTO: rugosidade que chega ao shader final de cada material da
     faixa "acabamentos" (seguindo os nós até o BSDF) contra a esperada.
  4. CLASSIFICAÇÃO: roda sketchup/test/bancada/bancada_classificador.rb e
     guarda o resumo.

Grava <saida>/resultados.json, <saida>/imagens/*.png (inclui pares lado a
lado) e <saida>/relatorio.html. Para comparar antes x depois:
tests/bancada/comparar.py.
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time

_AQUI = os.path.dirname(os.path.abspath(__file__))
_RAIZ = os.path.abspath(os.path.join(_AQUI, "..", ".."))
if _RAIZ not in sys.path:
    sys.path.insert(0, _RAIZ)

import bpy  # noqa: E402

RUBY_DIR = os.path.join(_RAIZ, "sketchup", "test", "bancada")


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--saida", required=True)
    p.add_argument("--rotulo", default="atual")
    p.add_argument("--res", type=int, default=400, help="largura dos renders (px)")
    p.add_argument("--pacotes", help="pasta já exportada por bancada_cenas.rb (senão exporta agora)")
    return p.parse_args(argv)


# ------------------------------------------------------------------ utilidades
def _ruby():
    r = shutil.which("ruby")
    if r is None:
        raise SystemExit("bancada: precisa do Ruby no PATH (o exportador do SketchUp é Ruby).")
    return r


def exportar(pasta):
    r = subprocess.run([_ruby(), os.path.join(RUBY_DIR, "bancada_cenas.rb"), pasta],
                       cwd=RUBY_DIR, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        raise SystemExit("bancada: falha ao exportar as cenas")
    print(r.stdout.strip())


def pixels(path):
    """PNG -> array HxWx3 (valores do arquivo, 0..1, já com a transformação de vista)."""
    import numpy as np
    img = bpy.data.images.load(path, check_existing=False)
    try:
        w, h = img.size
        px = np.empty(w * h * img.channels, dtype=np.float32)
        img.pixels.foreach_get(px)
        a = px.reshape(h, w, img.channels)[::-1, :, :3].copy()
        if img.is_float:
            # PNG de 16 bits (o render de produção sai assim depois da medição
            # automática) é carregado em ponto flutuante LINEAR: volta para os
            # valores do arquivo (sRGB) para comparar com os PNG de 8 bits.
            a = np.clip(a, 0.0, 1.0)
            a = np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)
        return a
    finally:
        bpy.data.images.remove(img)


def lado_a_lado(caminhos, saida, linhas=1):
    """Junta imagens do mesmo tamanho em grade (linhas x colunas), com 6 px de separação."""
    import numpy as np
    ims = [pixels(c) for c in caminhos]
    h, w = ims[0].shape[:2]
    cols = int(math.ceil(len(ims) / float(linhas)))
    sep = 6
    tela = np.ones((linhas * h + (linhas - 1) * sep, cols * w + (cols - 1) * sep, 3), dtype=np.float32)
    for i, im in enumerate(ims):
        r, c = divmod(i, cols)
        tela[r * (h + sep):r * (h + sep) + h, c * (w + sep):c * (w + sep) + w] = im[:h, :w]
    H, W = tela.shape[:2]
    out = bpy.data.images.new("lado", W, H, alpha=True)
    rgba = np.ones((H, W, 4), dtype=np.float32)
    rgba[:, :, :3] = tela[::-1]
    out.pixels.foreach_set(rgba.ravel())
    out.filepath_raw = saida
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)
    return saida


def media_srgb(path, recorte=None):
    a = pixels(path)
    if recorte:
        h, w = a.shape[:2]
        y0, y1, x0, x1 = recorte
        a = a[int(h * y0):int(h * y1), int(w * x0):int(w * x1)]
    return [round(float(v), 4) for v in a.reshape(-1, 3).mean(axis=0)]


def construir(pacote, res):
    from blender.pipeline import run
    bpy.ops.wm.read_factory_settings(use_empty=True)
    return run.build_scene(pacote, overrides={"resolution": [res, res]})


def seed_fixa():
    sc = bpy.context.scene
    if hasattr(sc, "cycles"):
        sc.cycles.seed = 0
        if hasattr(sc.cycles, "use_animated_seed"):
            sc.cycles.use_animated_seed = False


# ------------------------------------------------------------------ 1. exposição / balanço
def teste_exposicao(pacotes, cenas, img_dir, res):
    from blender.pipeline import run
    out = {}
    for cor in ("cinza", "azul", "terracota"):
        nome = "sala_%s" % cor
        loaded, spec = construir(os.path.join(pacotes, nome), res)
        seed_fixa()
        png = os.path.join(img_dir, "%s_auto.png" % nome)
        t0 = time.time()
        run._render(png, spec)                      # caminho de produção (exposição automática)
        vs = bpy.context.scene.view_settings
        out[nome] = {
            "parede_linear": cenas[nome]["parede_linear"],
            "interior_detectado": bool(bpy.context.scene.get("bir_interior")),
            "exposicao_ev": round(float(vs.exposure), 3),
            "balanco_k": round(float(vs.white_balance_temperature), 0) if getattr(vs, "use_white_balance", False) else 6500.0,
            "cor_media_imagem": media_srgb(png),
            "tempo_s": round(time.time() - t0, 1),
            "imagem_auto": os.path.basename(png),
        }
    ref = out["sala_cinza"]
    for cor in ("cinza", "azul", "terracota"):
        nome = "sala_%s" % cor
        loaded, spec = construir(os.path.join(pacotes, nome), res)
        seed_fixa()
        sc = bpy.context.scene
        vs = sc.view_settings
        vs.exposure = ref["exposicao_ev"]
        if hasattr(vs, "use_white_balance"):
            vs.use_white_balance = True
            vs.white_balance_temperature = ref["balanco_k"]
        png = os.path.join(img_dir, "%s_referencia.png" % nome)
        sc.render.filepath = png
        sc.render.image_settings.file_format = "PNG"
        bpy.ops.render.render(write_still=True)     # mesma cena, exposição e balanço FIXOS
        out[nome]["imagem_referencia"] = os.path.basename(png)
        out[nome]["cor_media_referencia"] = media_srgb(png)
        out[nome]["desvio_cor_auto_vs_ref"] = round(sum(abs(a - b) for a, b in
                                                        zip(out[nome]["cor_media_imagem"], out[nome]["cor_media_referencia"])) / 3.0, 4)
    lado_a_lado([os.path.join(img_dir, "sala_%s_%s.png" % (c, k)) for k in ("auto", "referencia")
                 for c in ("cinza", "azul", "terracota")], os.path.join(img_dir, "salas_auto_x_referencia.png"), linhas=2)
    evs = [out[k]["exposicao_ev"] for k in out]
    ks = [out[k]["balanco_k"] for k in out]
    resumo = {"amplitude_ev": round(max(evs) - min(evs), 3), "amplitude_k": round(max(ks) - min(ks), 0),
              "criterio": "mesma luz nas três salas: amplitude_ev <= 0,3 e amplitude_k <= 300 indicam que a medição "
                          "independe da cor das paredes",
              "passa_criterio": (max(evs) - min(evs)) <= 0.3 and (max(ks) - min(ks)) <= 300,
              "lado_a_lado": "salas_auto_x_referencia.png (linha de cima: automático; de baixo: exposição e balanço fixos da sala cinza)"}
    return {"salas": out, "resumo": resumo}


# ------------------------------------------------------------------ 2. relevo
def _material_construido(prefixo):
    for m in bpy.data.materials:
        if m.name.startswith(prefixo) and m.get("bir_material_id") and m.node_tree:
            return m
    return None


def teste_relevo(pacotes, cenas, img_dir, res):
    import numpy as np
    out = {}
    for nome in ("liso", "pedra", "tecido"):
        chave = "relevo_%s" % nome
        info = cenas[chave]
        loaded, spec = construir(os.path.join(pacotes, chave), res)
        rotulo = {"pedra": "Pedra", "tecido": "Linho", "liso": "Liso"}[nome]
        mat = _material_construido(rotulo)
        bump = next((n for n in mat.node_tree.nodes if n.type == "BUMP" and n.inputs["Height"].is_linked), None) if mat else None
        forca = float(bump.inputs["Strength"].default_value) if bump else 0.0
        dist = float(bump.inputs["Distance"].default_value) if bump else 0.0
        # Inclinação que o Bump produz na rampa da borda da célula (mapa 0 -> 1
        # em 3/32 da célula), antes da mistura pela força.
        rampa_m = info["celula_mm"] / 1000.0 * 3.0 / 32.0
        incl_shader = math.degrees(math.atan(dist / rampa_m)) if rampa_m > 0 else 0.0
        seed_fixa()
        sc = bpy.context.scene
        vs = sc.view_settings
        vs.exposure = 0.0
        if hasattr(vs, "use_white_balance"):
            vs.use_white_balance = False
        png = os.path.join(img_dir, "%s.png" % chave)
        sc.render.filepath = png
        sc.render.image_settings.file_format = "PNG"
        bpy.ops.render.render(write_still=True)
        a = pixels(png)
        h, w = a.shape[:2]
        centro = a[int(h * 0.3):int(h * 0.7), int(w * 0.3):int(w * 0.7)]
        lum = centro[:, :, 0] * 0.2126 + centro[:, :, 1] * 0.7152 + centro[:, :, 2] * 0.0722
        contraste = float(np.std(lum) / max(1e-4, np.mean(lum)))
        out[chave] = {
            "tamanho_textura_m": info["tamanho_textura_m"], "celula_mm": info["celula_mm"],
            "bump_forca": round(forca, 3), "bump_distancia_m": round(dist, 5),
            "inclinacao_borda_shader_graus": round(incl_shader, 2),
            "inclinacao_borda_fisica_graus": info["inclinacao_fisica_borda_graus"],
            "profundidade_fisica_mm": info["profundidade_fisica_mm"],
            "contraste_relevo_render": round(contraste, 4),
            "imagem": os.path.basename(png),
        }
        if nome == "liso":
            out[chave]["nota"] = "sem mapa de altura: o Bump lido é o micro-relevo de realism.py"
    lado_a_lado([os.path.join(img_dir, "relevo_%s.png" % n) for n in ("liso", "pedra", "tecido")],
                os.path.join(img_dir, "relevo_pedra_x_tecido.png"))
    base = out["relevo_liso"]["contraste_relevo_render"]
    for k in ("relevo_pedra", "relevo_tecido"):
        # contraste que vem do relevo = acima do painel liso (luz, ruído, denoise)
        out[k]["contraste_acima_do_liso"] = round(max(0.0, out[k]["contraste_relevo_render"] - base), 4)
    p, t = out["relevo_pedra"], out["relevo_tecido"]
    resumo = {
        "contraste_painel_liso": base,
        "razao_inclinacao_shader_pedra_tecido": round(p["inclinacao_borda_shader_graus"] / max(1e-6, t["inclinacao_borda_shader_graus"]), 3),
        "razao_inclinacao_fisica_pedra_tecido": round(p["inclinacao_borda_fisica_graus"] / max(1e-6, t["inclinacao_borda_fisica_graus"]), 3),
        "razao_contraste_render_pedra_tecido": round(p["contraste_acima_do_liso"] / max(1e-6, t["contraste_acima_do_liso"]), 3),
        "criterio": "pedra (junta ~5 mm) deve ter relevo pelo menos tão marcado quanto tecido (trama ~0,5 mm): "
                    "razão de contraste pedra/tecido >= 1",
        "lado_a_lado": "relevo_pedra_x_tecido.png (liso de controle | pedra 2 m | tecido 0,5 m; mesmo mapa de altura, sol rasante)",
    }
    resumo["passa_criterio"] = resumo["razao_contraste_render_pedra_tecido"] >= 1.0
    return {"paineis": out, "resumo": resumo}


# ------------------------------------------------------------------ 3. acabamento
def rugosidade_efetiva(mat):
    """Segue os nós até a entrada Roughness do BSDF -> (valor efetivo, como foi obtido)."""
    from blender.pipeline import materials as M
    bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if bsdf is None:
        return None, "sem BSDF"
    s = bsdf.inputs["Roughness"]
    if not s.is_linked:
        return round(float(s.default_value), 3), "valor fixo"
    n = s.links[0].from_node
    if n.type == "MAP_RANGE":                       # variação leve de realism.py em torno do valor
        a, b = float(n.inputs["To Min"].default_value), float(n.inputs["To Max"].default_value)
        return round((a + b) / 2.0, 3), "valor fixo + variação (realism)"
    if n.type == "MATH" and n.operation == "MULTIPLY":
        fator = float(n.inputs[1].default_value)
        img = n.inputs[0].links[0].from_node if n.inputs[0].is_linked else None
        media = M._image_mean(img.image) if img is not None and getattr(img, "image", None) else None
        return (round(fator * media, 3) if media is not None else round(fator, 3)), "mapa x fator"
    return None, "nó %s" % n.type


def teste_acabamento(pacotes, cenas, img_dir, res):
    loaded, spec = construir(os.path.join(pacotes, "acabamentos"), res)
    esperados = cenas["acabamentos"]["materiais"]
    out = {}
    for nome, e in esperados.items():
        mat = _material_construido(nome)
        val, como = rugosidade_efetiva(mat) if mat else (None, "material não encontrado")
        alvo = e["rugosidade_esperada"]
        out[nome] = {"rugosidade_shader": val, "como": como, "rugosidade_esperada": alvo, "nota": e["nota"],
                     "ok": None if alvo is None or val is None else abs(val - alvo) <= 0.05}
    seed_fixa()
    sc = bpy.context.scene
    sc.view_settings.exposure = 0.0
    png = os.path.join(img_dir, "acabamentos.png")
    sc.render.filepath = png
    sc.render.image_settings.file_format = "PNG"
    bpy.ops.render.render(write_still=True)
    avaliados = [v for v in out.values() if v["ok"] is not None]
    resumo = {"avaliados": len(avaliados), "certos": sum(1 for v in avaliados if v["ok"]),
              "criterio": "rugosidade no shader a +/-0,05 da esperada (acabamento do nome; controles mantêm a própria)",
              "imagem": "acabamentos.png (da esquerda para a direita, na ordem da lista)"}
    resumo["passa_criterio"] = resumo["certos"] == resumo["avaliados"]
    return {"materiais": out, "resumo": resumo}


# ------------------------------------------------------------------ 4. classificação
def teste_classificacao(saida):
    arq = os.path.join(saida, "classificacao.json")
    r = subprocess.run([_ruby(), os.path.join(RUBY_DIR, "bancada_classificador.rb"), arq],
                       cwd=RUBY_DIR, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.isfile(arq):
        return {"erro": (r.stdout + r.stderr)[-500:]}
    dados = json.load(open(arq, encoding="utf-8"))
    res = dados["resumo"]
    res["criterio"] = "nenhuma troca errada com certeza alta (erros_com_certeza_alta == 0)"
    res["passa_criterio"] = res["erros_com_certeza_alta"] == 0
    erros = [i for i in dados["itens"] if i["situacao"] != "ok"]
    return {"resumo": res, "erros": erros, "arquivo": "classificacao.json"}


# ------------------------------------------------------------------ relatório
def relatorio_html(res, saida):
    def tab(d):
        return "<table>" + "".join("<tr><th>%s</th><td>%s</td></tr>" % (k, json.dumps(v, ensure_ascii=False))
                                   for k, v in d.items()) + "</table>"
    partes = ["<h1>Bancada Blendit - %s</h1><p>%s</p>" % (res["rotulo"], res["condicoes"])]
    for chave, titulo, imgs in (("exposicao", "1. Exposição e balanço de branco", ["salas_auto_x_referencia.png"]),
                                ("relevo", "2. Relevo: pedra x tecido", ["relevo_pedra_x_tecido.png"]),
                                ("acabamento", "3. Acabamento escrito no nome", ["acabamentos.png"]),
                                ("classificacao", "4. Classificação de nomes reais", [])):
        t = res.get(chave, {})
        partes.append("<h2>%s</h2>" % titulo)
        partes.append(tab(t.get("resumo", {})))
        for im in imgs:
            partes.append('<img src="imagens/%s">' % im)
        det = {k: v for k, v in t.items() if k != "resumo"}
        partes.append("<details><summary>detalhes</summary><pre>%s</pre></details>"
                      % json.dumps(det, ensure_ascii=False, indent=1))
    html = ("<!doctype html><meta charset='utf-8'><title>Bancada Blendit</title><style>"
            "body{font:14px system-ui,sans-serif;max-width:1100px;margin:20px auto;padding:0 16px}"
            "table{border-collapse:collapse;margin:8px 0}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}"
            "img{max-width:100%;border:1px solid #ccc;margin:6px 0}pre{white-space:pre-wrap;font-size:12px}</style>"
            + "\n".join(partes))
    with open(os.path.join(saida, "relatorio.html"), "w", encoding="utf-8") as f:
        f.write(html)


def main():
    a = _args()
    saida = os.path.abspath(a.saida)
    img_dir = os.path.join(saida, "imagens")
    os.makedirs(img_dir, exist_ok=True)
    pacotes = os.path.abspath(a.pacotes) if a.pacotes else os.path.join(saida, "pacotes")
    if not a.pacotes:
        exportar(pacotes)
    cenas = json.load(open(os.path.join(pacotes, "cenas.json"), encoding="utf-8"))
    t0 = time.time()
    res = {"rotulo": a.rotulo, "blender": bpy.app.version_string, "largura_px": a.res,
           "condicoes": "Blender %s; renders de produção (Cycles, amostras do pacote = 32, denoise ligado), "
                        "largura %d px, semente fixa 0; cenas exportadas pelo exportador real com a API do "
                        "SketchUp imitada." % (bpy.app.version_string, a.res)}
    res["exposicao"] = teste_exposicao(pacotes, cenas, img_dir, a.res)
    res["relevo"] = teste_relevo(pacotes, cenas, img_dir, a.res)
    res["acabamento"] = teste_acabamento(pacotes, cenas, img_dir, a.res)
    res["classificacao"] = teste_classificacao(saida)
    res["tempo_total_s"] = round(time.time() - t0, 1)
    with open(os.path.join(saida, "resultados.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    relatorio_html(res, saida)
    print("\nBANCADA (%s) - critério atendido?" % a.rotulo)
    for k in ("exposicao", "relevo", "acabamento", "classificacao"):
        r = res[k].get("resumo", {})
        print("  %-14s %s" % (k, "SIM" if r.get("passa_criterio") else "NAO"))
    print("resultados: %s" % os.path.join(saida, "resultados.json"))


main()
