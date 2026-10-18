# Bancada de comparação de materiais (Etapa 0)

Mede o comportamento **atual** do Blendit em quatro problemas confirmados na
auditoria de 18/10/2026, sem mudar nada no plugin nem no pipeline. Cada
correção futura roda a bancada antes e depois. Uma melhoria só conta quando a
métrica muda **e** o par de imagens confirma.

## Como rodar

```
# 1. rodada de referência (antes da correção)
blender --background --python tests/bancada/bancada.py -- --saida bancada_antes --rotulo "0.5.0" --res 400
# 2. aplicar UMA correção e rodar de novo, com os MESMOS pacotes
blender --background --python tests/bancada/bancada.py -- --saida bancada_depois --rotulo "etapa 1" --res 400 --pacotes bancada_antes/pacotes
# 3. comparar
python3 tests/bancada/comparar.py bancada_antes bancada_depois --saida comparacao.html
```

- Precisa do Ruby no PATH. As cenas saem do exportador real do plugin
  (`sketchup/test/bancada/bancada_cenas.rb`, com a imitação da API do SketchUp
  de `sketchup/test/sketchup_fake.rb`).
- Sem Blender instalado, `python3 tests/bancada/bancada.py -- ...` funciona com
  o módulo `bpy` do pip, na mesma versão do Blender.
- Usar `--pacotes` na rodada "depois" quando a correção é só do lado Blender:
  a geometria fica idêntica. Quando a correção é no exportador, deixe
  exportar de novo.
- Só a classificação: `ruby sketchup/test/bancada/bancada_classificador.rb [saida.json] [--estrito]`.
  `--estrito` retorna erro se houver troca errada com certeza alta (usar
  depois da correção do classificador).
- Tempo de referência: ~1,5 min em CPU com `--res 320`. Na RTX 3050 deve ser
  bem menos. As cenas usam 32 amostras (as do pacote) e o denoise de
  produção. Não aumente amostras para "melhorar" a bancada: as métricas medem
  regras do pipeline, não ruído.

Saída: `resultados.json`, `relatorio.html`, `imagens/` (inclui os pares lado
a lado) e `classificacao.json`.

## Os testes

### 1. Exposição e balanço de branco (`exposicao`)
- **Cena:** a sala dos testes do plugin (`cena_interior` + `cena_vidro` +
  câmera de `cena_quarto`: janela de 3,8 x 1,9 m, mesa, sofá, spots,
  pendente). Mesmo sol (0,4; -0,5; 0,75), céu simulado, dia. Só muda a cor das
  paredes (albedo linear): cinza 0,5 / azul 0,05-0,12-0,45 / terracota
  0,45-0,15-0,07.
- **Valores:** exposição (EV) e balanço (K) escolhidos pelo render de
  produção (`run._render` -> `autoexpose.apply_auto`), cor média da imagem.
  Também uma **referência**: as três salas com a exposição e o balanço FIXOS
  da sala cinza.
- **Esperado depois da correção:** a luz é a mesma, então
  `amplitude_ev <= 0,3` e `amplitude_k <= 300`. O `desvio_cor_auto_vs_ref`
  das salas azul e terracota deve cair perto de 0.
- **Imagem:** `salas_auto_x_referencia.png`. Linha de cima: automático. Linha
  de baixo: exposição e balanço fixos.
- **Controle embutido:** na sala cinza, automático e referência têm de dar a
  mesma cor média (dá 0,0). Isso confirma que a comparação é justa.

### 2. Relevo: pedra x tecido (`relevo`)
- **Cena:** painel de 1 x 1 m, material como a biblioteca grava (textura +
  atributos `relevo`/`rugosidade`), o MESMO mapa de altura sintético (8 x 8
  células com junta), sol rasante. Pedra = textura de 2 m; tecido = 0,5 m;
  liso = mesmo painel sem mapa (controle de ruído).
- **Valores:** força e distância do nó Bump lidos do shader final;
  inclinação que o Bump gera na borda da célula; contraste do render
  (desvio/média da luminância no centro) acima do painel liso.
- **Premissa declarada** (`cenas.json`): junta de pedra ~5 mm; trama de tecido ~0,5 mm.
- **Esperado depois da correção:** `razao_contraste_render_pedra_tecido >= 1`
  e a razão de inclinação no shader na mesma direção da física (~2,5).
- **Imagem:** `relevo_pedra_x_tecido.png` (liso | pedra | tecido).

### 3. Acabamento escrito no nome (`acabamento`)
- **Cena:** faixa de amostras com textura do SketchUp e acabamento no nome
  (POL, ACET, Fosco, alto brilho, escovado). Mais dois controles que NÃO podem
  mudar: material da biblioteca (rugosidade própria 0,12) e material PBR do
  SketchUp 2025 com "Fosco" no nome e rugosidade própria 0,2.
- **Valores:** rugosidade que chega ao BSDF, seguindo os nós (valor fixo,
  variação de `realism.py` ou mapa x fator).
- **Esperado depois da correção:** polido 0,12, acetinado 0,40, fosco 0,75
  (as mesmas constantes de `Texturas`), com tolerância de 0,05. Os controles
  ficam iguais. O alvo de "escovado" ainda não está definido (não conta).
- **Imagem:** `acabamentos.png`.

### 4. Classificação de nomes reais (`classificacao`)
- **Dados:** `sketchup/test/bancada/nomes_materiais.json`, com 54 nomes de
  projetos brasileiros, cor, uso (piso/parede/estofado), categorias aceitas,
  tipo de produto, acabamento e medida.
- **Valores:** acertos, **erros com certeza alta** (a métrica principal),
  erros com certeza média/baixa, falta de categoria, acabamento e medida lidos
  pelo leitor existente (`Texturas.analisar_nome`).
- **Esperado depois da correção:** `erros_com_certeza_alta == 0`, sem perder
  acertos.

## Limitações (o que esta bancada NÃO valida)
- Não usa o SketchUp real. Usa a mesma imitação dos outros testes. Materiais
  PBR reais do SketchUp 2025 e texturas reais dos projetos dela só no
  computador dela.
- O relevo usa um mapa de altura sintético. As texturas reais do Poly Haven e
  do ambientCG não baixam neste ambiente (rede bloqueada), então a
  comparação com os mapas de normal reais fica para quando a Etapa 4 rodar no
  computador dela (ou com os arquivos copiados para cá).
- As profundidades físicas (5 mm / 0,5 mm) são premissas, não medições.
- Em CPU as rodadas são idênticas bit a bit (verificado: duas rodadas, variação 0
  em todas as métricas). Em GPU (OptiX), espere variações pequenas de ruído.
  Compare antes e depois na mesma máquina.
- A cor média é da imagem inteira, não só da parede. Serve para comparar
  rodadas, não como medida absoluta de cor.
- A métrica de acabamento lê o valor do shader. Se a aparência ficou boa é
  coisa do par de imagens e do olho da arquiteta.
