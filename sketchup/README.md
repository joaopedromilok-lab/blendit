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
| **Renderizar todas as cenas** | Uma imagem por cena (aba) do modelo, uma de cada vez, e (se quiser) uma prancha em PDF com carimbo. Respeita as etiquetas visíveis de cada cena. |
| **Estudo de insolação** | 9 imagens no estilo Estudo de sombras (21/06, 21/03 e 21/12 às 9h, 12h e 15h) + prancha em PDF. Usa a geolocalização do modelo. |
| **Biblioteca de materiais** | Galeria com 157 materiais de textura real (mármores, travertinos, granitos, porcelanatos, pastilhas, granilite, pisos de madeira, MDF e lâminas, palhinha, paredes, área externa, tecidos e couro), com busca, no tamanho real e com relevo no render. Baixa cada textura só na primeira vez, ou todas de uma vez com **Baixar tudo**. Texturas do Poly Haven e do ambientCG (CC0). |
| **Texturas automáticas** | Acha os materiais que são só cor (piso, madeira, tecido, couro, pedra de bancada, concreto, tijolo) - pelo nome ou por onde são usados - e sugere uma textura real da biblioteca para cada um, na cor do projeto. Lista de revisão antes de aplicar; Ctrl+Z desfaz. Pinturas lisas, vidros e metais ficam como estão. |
| **Minhas texturas** | Aba da biblioteca para adicionar imagens de catálogos de fabricantes ou fotos de amostras, informando o tamanho real da peça (cm) e o acabamento. Ficam só no computador (`%APPDATA%\BlenditSketchUp\minhas_texturas`). |
| **Importar catálogo (pasta ou .zip)** | Em Minhas texturas: importa de uma vez o pacote de texturas de um fabricante. Nome, medida e acabamento saem do nome de cada arquivo (`CALACATA ORO 90X90 POL.jpg` → Calacata Oro, 90 × 90 cm, polido; medidas em mm como `1200x1200` viram cm). Também aceita catálogos em arquivo do SketchUp (`.skp` com a peça aplicada, ou `.skm`): o Blendit lê a textura e o tamanho real de cada material, sem mexer no modelo aberto. Subpastas viram coleções. Uma lista de revisão aparece antes: linhas sem medida ficam em laranja e as já importadas vêm desmarcadas. Até 500 imagens por vez. |
| **Montar prancha com imagens de uma pasta** | Prancha em PDF (A4 a A1) com até 12 imagens de uma pasta. |
| **Iluminação: Dia / Noite** | Noite apaga o sol e o céu - só as luminárias iluminam. |
| **Céu** | Céu simulado (padrão) ou um céu fotografado em HDRI: limpo ao meio-dia, parcialmente nublado, nublado (luz suave, sem sombra marcada) ou fim de tarde. O céu aparece nas janelas e ilumina o ambiente; o sol continua vindo de Janela > Sombras. Cada céu é baixado uma vez (~6 MB, Poly Haven, CC0). Vale para os estilos Realista e Realista brilhante, de dia. |
| **Ambiente interno** | Automático, Sim ou Não. Em ambientes sem forro/laje o render fecha a sala com um forro invisível, para a luz entrar pelas janelas. |
| **Paredes retas** | Perspectiva de 2 pontos: linhas verticais retas, mantendo o enquadramento (ligado por padrão; vistas muito inclinadas ficam como estão). |
| **Tom da imagem / Brilho** | Natural, branco mais neutro ou mais aconchegante; e brilho de bem mais escuro a bem mais claro. Valem para Realista e Realista brilhante. |
| **Inverter lado do corte** | Se o corte sair do lado errado, marque esta opção. |
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
- Materiais da biblioteca levam também o mapa de brilho (rugosidade): o reflexo
  varia pela superfície, mantendo o acabamento escolhido (polido, acetinado, fosco).
- Nos renders Alta e Final (Cycles), as quinas saem levemente arredondadas (6 mm)
  e pegam luz como num objeto real - sem mudar o modelo.
- Terreno: se o modelo já tem um terreno grande, o Blendit não cria o chão
  artificial por cima dele - só um plano logo abaixo, para o horizonte não ficar vazio.

Luminárias viram luzes de verdade, reconhecidas pelo nome do componente: spot,
embutido, dicroica, pendente, lustre, plafon, painel LED, arandela, abajur, fita LED.
Para ajustar uma luminária, use o atributo `blendit` do componente: `luz = nao`
(não acender), `kelvin = 2700`, `candela = 1500`.

Cortinas: grupos ou componentes com "cortina", "curtain", "voil", "voal" ou "tule" no
nome viram tecido translúcido (voil/voal/tule também semitransparente). Varão e trilho
continuam rígidos; "blackout" e "persiana" continuam opacos.

O plano de corte ativo (inclusive dentro de grupos) vira um corte no render, com
o corte das paredes e lajes preenchido em cinza escuro, como no SketchUp.

Materiais com nomes em português (Tijolo, Telha, Porcelanato, Madeira, Concreto,
Mármore, Grama...) ganham textura procedural automática quando não têm imagem própria.

## Limitações conhecidas

- O preenchimento do corte usa o lado de trás das faces: faces invertidas no
  modelo (lado azul para fora) podem aparecer escuras no render.
- O deslocamento da imagem em perspectiva de duas pontas não é reproduzido; o
  enquadramento pode diferir um pouco - ajuste no "Abrir no Blender".
- As luminárias são reconhecidas pelo nome; um componente com nome genérico
  ("Componente#12") não acende.
- A biblioteca de materiais precisa de internet na primeira vez de cada textura (ou use **Baixar tudo** uma vez).
- Nas texturas do ambientCG o tamanho real é estimado (ex.: mármore 2 m, pastilha 60 cm); ajuste em Materiais > Editar se precisar.

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
