"""pt-BR material names map to the curated library (and stop words stay flat).

    blender --background --python tests/headless_material_pt.py
"""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from blender.pipeline import material_library as LIB  # noqa: E402

CASES = [
    (u"Tijolo aparente", "brick"),
    (u"Telha Cerâmica", "roof_tile"),
    (u"Telha trapezoidal galvanizada", "corrugated"),
    (u"Porcelanato 60x60 acetinado", "tile"),
    (u"Piso laminado carvalho", "planks"),
    (u"Tacos de madeira", "planks"),
    (u"Madeira Ipê", "wood"),
    (u"Água - piscina", "water"),
    (u"Concreto aparente", "concrete"),
    (u"Brita 1", "gravel"),
    (u"Aço escovado", "metal"),
    (u"Reboco pintado", "plaster"),
    (u"Grama esmeralda", "grass"),
    (u"Mármore Carrara", "stone"),
    (u"Pedras São Tomé", "stone"),
    # whole-word matching: no false hits inside other words
    (u"Espaço gourmet", None),          # "aco" inside "espaco"
    (u"Acolchoado", None),
    (u"Manta asfáltica", None),         # stop word: stays flat
    (u"Vidro incolor", None),
    # SketchUp-style English names with underscores
    ("Brick_Antique", "brick"),
    ("Roofing_Tile_Spanish", "roof_tile"),
]

bad = []
for name, want in CASES:
    got = LIB.category_for(name)
    if got != want:
        bad.append("%r -> %r (want %r)" % (name, got, want))
for b in bad:
    print("FAIL", b)
assert not bad, "%d pt-BR material mapping(s) wrong" % len(bad)
print("MATERIAL PT OK (%d names)" % len(CASES))
