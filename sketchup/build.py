"""Monta a extensão do SketchUp (.rbz) a partir de sketchup/src + o núcleo Python
do Blendit (bir_contract/ e blender/), que o Blender executa.

    python sketchup/build.py            -> sketchup/dist/blendit_sketchup.rbz

O .rbz é só um .zip com o carregador na raiz e a pasta do plugin ao lado.
"""
import os
import shutil
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(HERE, "src")
DIST = os.path.join(HERE, "dist")
STAGE = os.path.join(DIST, "stage")
IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store")


def main():
    shutil.rmtree(STAGE, ignore_errors=True)
    shutil.copytree(SRC, STAGE, ignore=IGNORE)
    core = os.path.join(STAGE, "blendit_sketchup", "core")
    for name in ("bir_contract", "blender"):
        shutil.copytree(os.path.join(ROOT, name), os.path.join(core, name), ignore=IGNORE)
    shutil.copy(os.path.join(ROOT, "LICENSE"), os.path.join(STAGE, "blendit_sketchup", "LICENSE"))

    out = os.path.join(DIST, "blendit_sketchup.rbz")
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _dirs, files in os.walk(STAGE):
            for f in sorted(files):
                full = os.path.join(dirpath, f)
                z.write(full, os.path.relpath(full, STAGE).replace(os.sep, "/"))
    print("ok:", out, "(%d KB)" % (os.path.getsize(out) // 1024))

    # Publicação: o .rbz vai para sketchup/release/ (versionado no git) e o
    # versao.json diz ao plugin instalado qual é a versão mais nova.
    import json
    import re
    src = open(os.path.join(SRC, "blendit_sketchup", "atualizacao.rb"), encoding="utf-8").read()
    ver = re.search(r"VERSION = '([0-9.]+)'", src).group(1)
    rel = os.path.join(HERE, "release")
    os.makedirs(rel, exist_ok=True)
    shutil.copy(out, os.path.join(rel, "blendit_sketchup.rbz"))
    notes_path = os.path.join(HERE, "NOVIDADES.txt")
    notes = open(notes_path, encoding="utf-8").read().strip() if os.path.isfile(notes_path) else ""
    info = {"versao": ver,
            "rbz": "https://raw.githubusercontent.com/joaopedromilok-lab/blendit/main/"
                   "sketchup/release/blendit_sketchup.rbz",
            "novidades": notes}
    with open(os.path.join(HERE, "versao.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=2)
    print("versao.json ->", ver)


if __name__ == "__main__":
    main()
