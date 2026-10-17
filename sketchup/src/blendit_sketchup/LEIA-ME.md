# Blendit para SketchUp

Leva a vista atual do SketchUp para o Blender e renderiza com um clique, nos mesmos
16 estilos do Blendit para Revit: realista, maquete branca, estudo de sombras,
showroom, traço, caneta, croqui, cartoon, hachura, hachura cruzada, papel manteiga,
papel kraft, blueprint, diagrama, aquarela e risografia.

## Requisitos

- SketchUp 2021 ou mais novo (Windows; no Mac deve funcionar, mas não foi testado).
- [Blender](https://www.blender.org/download/) 4.2 ou mais novo, gratuito.

## Instalação

1. No SketchUp: **Extensões > Gerenciador de extensões > Instalar extensão**.
2. Escolha o arquivo `blendit_sketchup.rbz` e confirme.
3. Aparece a barra **Blendit** e o menu **Extensões > Blendit**.

Na primeira vez, se o Blender não for encontrado sozinho, o plugin pergunta onde
está o `blender.exe`.

## Uso

| Comando | O que faz |
|---|---|
| **Renderizar vista** | Exporta a vista atual e renderiza em segundo plano. O SketchUp fica livre; a imagem abre sozinha quando termina. |
| **Abrir no Blender** | Abre a cena no Blender para compor o enquadramento e trocar o estilo ao vivo (tecla **N** mostra o painel, **Enter** captura, **F10** mostra a interface completa). |
| **Renderizar todas as cenas** | Uma imagem por cena (aba) do modelo, uma de cada vez. Respeita as etiquetas visíveis de cada cena. |
| **Estilo / Qualidade** | Submenus para escolher o visual e o esforço do render (Rascunho, Boa, Alta, Final). |
| **Configurações** | Estilo e qualidade padrão, pasta dos renders e caminho do Blender. |

As imagens ficam em `Documentos\Blendit Renders` (dá para trocar em Configurações).

## O que vai do SketchUp para o Blender

- Toda a geometria visível: respeita objetos ocultos, etiquetas (tags) e pastas de
  etiquetas desligadas; grupos e componentes (inclusive espelhados) com suas
  transformações.
- Materiais: cor, transparência (vira vidro), textura em tamanho real e, no
  SketchUp 2025+, metálico/rugosidade dos materiais PBR. Pintura feita no grupo ou
  componente também vale para as faces sem material.
- Superfícies suavizadas (cilindros, curvas, terreno) saem lisas.
- Câmera exatamente como na tela: perspectiva ou paralela, campo de visão e
  proporção da janela.
- Sol: a mesma direção das sombras do SketchUp (Janela > Sombras).
- Terreno: se o modelo já tem um terreno grande, o Blendit não cria o chão
  artificial por cima dele - só um plano logo abaixo, para o horizonte não ficar vazio.

Materiais com nomes em português (Tijolo, Telha, Porcelanato, Madeira, Concreto,
Mármore, Grama...) ganham textura procedural automática quando não têm imagem própria.

## Limitações conhecidas

- Planos de corte (seções) ativos não são aplicados.
- O deslocamento da imagem em perspectiva de duas pontas não é reproduzido; o
  enquadramento pode diferir um pouco - ajuste no "Abrir no Blender".
- Luzes artificiais: o SketchUp não tem luzes nativas, então só há sol e céu.

## Para desenvolvedores

- `src/` - o plugin (Ruby). `bundle_writer.rb` é Ruby puro e grava o mesmo pacote
  (`scene_spec.json` + `scene.glb`) que o lado Revit; `exporter.rb` lê o modelo do SketchUp.
- `build.py` - monta `dist/blendit_sketchup.rbz` com o núcleo Python do Blendit dentro.
- `test/` - uma imitação mínima da API do SketchUp para testar fora dele:

```
python sketchup/build.py
ruby sketchup/test/cena_teste.rb /tmp/bundle /caminho/textura.png
blender --background --python blender/headless/render.py -- --bundle /tmp/bundle --out casa.png --mode realistic
ruby -I sketchup/test/stub sketchup/test/teste_main.rb /tmp/cache /caminho/textura.png
```
