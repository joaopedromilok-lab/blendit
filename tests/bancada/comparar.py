"""Compara duas rodadas da bancada (antes x depois). Python 3 comum, sem Blender.

    python3 tests/bancada/comparar.py <pasta_antes> <pasta_depois> [--saida comparacao.html]

Lê <pasta>/resultados.json de cada rodada, imprime as métricas lado a lado
com a variação e se o critério de cada teste passou, e grava um HTML com as
imagens das duas rodadas lado a lado (mesmo nome de arquivo, mesma cena).
Só faz sentido comparar rodadas com a MESMA largura de render e o mesmo
Blender (o script avisa quando não batem).
"""
import json
import os
import sys

METRICAS = [
    ("exposicao", "resumo.amplitude_ev", "amplitude de exposição entre as 3 salas (EV) - menor é melhor"),
    ("exposicao", "resumo.amplitude_k", "amplitude de balanço entre as 3 salas (K) - menor é melhor"),
    ("exposicao", "salas.sala_cinza.exposicao_ev", "sala cinza: exposição (EV)"),
    ("exposicao", "salas.sala_azul.exposicao_ev", "sala azul: exposição (EV)"),
    ("exposicao", "salas.sala_terracota.exposicao_ev", "sala terracota: exposição (EV)"),
    ("exposicao", "salas.sala_cinza.balanco_k", "sala cinza: balanço (K)"),
    ("exposicao", "salas.sala_azul.balanco_k", "sala azul: balanço (K)"),
    ("exposicao", "salas.sala_terracota.balanco_k", "sala terracota: balanço (K)"),
    ("exposicao", "salas.sala_azul.desvio_cor_auto_vs_ref", "sala azul: desvio de cor do automático (0..1) - menor é melhor"),
    ("exposicao", "salas.sala_terracota.desvio_cor_auto_vs_ref", "sala terracota: desvio de cor do automático - menor é melhor"),
    ("relevo", "resumo.razao_contraste_render_pedra_tecido", "relevo: contraste pedra / tecido (>= 1 esperado)"),
    ("relevo", "resumo.razao_inclinacao_shader_pedra_tecido", "relevo: inclinação no shader pedra / tecido"),
    ("relevo", "resumo.razao_inclinacao_fisica_pedra_tecido", "relevo: inclinação física pedra / tecido (premissa)"),
    ("relevo", "paineis.relevo_pedra.contraste_acima_do_liso", "relevo: contraste da pedra acima do liso"),
    ("relevo", "paineis.relevo_tecido.contraste_acima_do_liso", "relevo: contraste do tecido acima do liso"),
    ("acabamento", "resumo.certos", "acabamento: materiais com a rugosidade esperada"),
    ("acabamento", "resumo.avaliados", "acabamento: materiais avaliados"),
    ("classificacao", "resumo.erros_com_certeza_alta", "classificação: erros com certeza alta - menor é melhor"),
    ("classificacao", "resumo.acertos", "classificação: acertos"),
    ("classificacao", "resumo.faltou_categoria", "classificação: sem categoria quando devia ter"),
    ("classificacao", "resumo.acabamento_lido_certo", "nome: acabamentos lidos certo"),
]
IMAGENS = ["salas_auto_x_referencia.png", "relevo_pedra_x_tecido.png", "acabamentos.png"]


def pega(d, caminho):
    for k in caminho.split("."):
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2:
        raise SystemExit(__doc__)
    saida = sys.argv[sys.argv.index("--saida") + 1] if "--saida" in sys.argv else "comparacao.html"
    a, b = (json.load(open(os.path.join(p, "resultados.json"), encoding="utf-8")) for p in args[:2])
    if a.get("largura_px") != b.get("largura_px") or a.get("blender") != b.get("blender"):
        print("AVISO: rodadas com largura ou Blender diferentes - a comparação de imagens não é controlada.")
    linhas = []
    print("%-62s %12s %12s %10s" % ("métrica", a["rotulo"][:12], b["rotulo"][:12], "variação"))
    for grupo, caminho, nome in METRICAS:
        va, vb = pega(a.get(grupo, {}), caminho), pega(b.get(grupo, {}), caminho)
        dv = (vb - va) if isinstance(va, (int, float)) and isinstance(vb, (int, float)) else None
        print("%-62s %12s %12s %10s" % (nome[:62], va, vb, "" if dv is None else round(dv, 4)))
        linhas.append((nome, va, vb, dv))
    print()
    for grupo in ("exposicao", "relevo", "acabamento", "classificacao"):
        pa = pega(a.get(grupo, {}), "resumo.passa_criterio")
        pb = pega(b.get(grupo, {}), "resumo.passa_criterio")
        print("critério %-14s antes: %-5s depois: %s" % (grupo, pa, pb))
    rel = lambda p: os.path.relpath(p, os.path.dirname(os.path.abspath(saida)))
    html = ["<!doctype html><meta charset='utf-8'><title>Bancada: antes x depois</title><style>"
            "body{font:14px system-ui,sans-serif;max-width:1300px;margin:20px auto;padding:0 16px}"
            "table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px}"
            ".par{display:flex;gap:8px}.par div{flex:1}img{width:100%;border:1px solid #ccc}</style>",
            "<h1>Bancada: %s x %s</h1><table><tr><th>métrica</th><th>%s</th><th>%s</th><th>variação</th></tr>"
            % (a["rotulo"], b["rotulo"], a["rotulo"], b["rotulo"])]
    for nome, va, vb, dv in linhas:
        html.append("<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (nome, va, vb, "" if dv is None else round(dv, 4)))
    html.append("</table>")
    for im in IMAGENS:
        html.append("<h2>%s</h2><div class='par'><div>%s<img src='%s'></div><div>%s<img src='%s'></div></div>"
                    % (im, a["rotulo"], rel(os.path.join(args[0], "imagens", im)),
                       b["rotulo"], rel(os.path.join(args[1], "imagens", im))))
    with open(saida, "w", encoding="utf-8") as f:
        f.write("\n".join(html))
    print("comparação: %s" % saida)


main()
