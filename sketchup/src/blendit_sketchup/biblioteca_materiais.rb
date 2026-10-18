# encoding: UTF-8
# Blendit para SketchUp - biblioteca de materiais por CATEGORIA.
#
# Liga cada categoria (piso, madeira, tecido, bancada...) às texturas PBR do
# catálogo local (Texturas::CATALOGO: cor + relevo + mapa de brilho, CC0), com a
# cor média aproximada de cada uma para escolher a mais parecida com a cor do
# projeto. Ruby puro (sem a API do SketchUp) - testável fora dele.
#
# Categoria SEM texturas (parede pintada, metal) = solução genérica: o render
# mantém a cor e só ganha o acabamento (sem inventar uma textura).
#
# Regras configuráveis: um JSON opcional (ver carregar_regras) pode trocar a
# textura preferida de uma categoria, acrescentar palavras e desativar
# categorias.
require 'json'
require_relative 'classificador'

module BlenditSU
  module BibliotecaMateriais
    # categoria => { rotulo:, texturas: { id_do_catalogo => [r,g,b] (sRGB aprox.) } }
    CATEGORIAS = {
      'piso_madeira' => { rotulo: 'Piso de madeira', texturas: {
        'laminate_floor' => [190, 160, 120], 'laminate_floor_02' => [150, 110, 75],
        'oak_wood_planks' => [165, 125, 85], 'dark_wooden_planks' => [80, 55, 40],
        'WoodFloor051' => [200, 175, 140], 'WoodFloor070' => [160, 120, 80],
        'WoodFloor064' => [90, 60, 40], 'WoodFloor062' => [185, 160, 125],
        'WoodFloor007' => [210, 180, 140], 'herringbone_parquet' => [150, 105, 65] } },
      'piso' => { rotulo: 'Piso (porcelanato)', texturas: {
        'Tiles074' => [225, 222, 218], 'interior_tiles' => [220, 215, 205],
        'Tiles142' => [215, 205, 185], 'Tiles144' => [200, 185, 160],
        'Tiles143' => [190, 175, 150], 'concrete_tiles_02' => [165, 160, 150],
        'concrete_tiles' => [140, 140, 135], 'Terrazzo004' => [215, 212, 205],
        'Tiles138' => [50, 50, 50] } },
      'madeira' => { rotulo: 'Madeira / marcenaria', texturas: {
        'Wood095' => [215, 185, 145], 'ash_veneer' => [200, 170, 130],
        'oak_veneer_01' => [185, 145, 100], 'Wood049' => [170, 125, 80],
        'grey_oak_veneer_01' => [150, 140, 125], 'cherry_veneer' => [150, 85, 50],
        'natural_walnut_veneer' => [120, 80, 50], 'mocha_oak_veneer' => [110, 80, 60],
        'american_walnut_veneer' => [95, 65, 45], 'Wood051' => [70, 45, 30],
        'black_walnut_veneer_01' => [60, 40, 30] } },
      'tecido' => { rotulo: 'Tecido', texturas: {
        'wool_boucle' => [225, 220, 210], 'rough_linen' => [200, 190, 170],
        'cotton_jersey' => [180, 180, 180], 'Fabric082A' => [160, 160, 158],
        'Fabric030' => [130, 130, 130], 'velour_velvet' => [110, 100, 95] } },
      'couro' => { rotulo: 'Couro', texturas: {
        'leather_white' => [225, 220, 210], 'brown_leather' => [140, 90, 55],
        'leather_red_02' => [130, 40, 35] } },
      'bancada' => { rotulo: 'Pedra / bancada', texturas: {
        'Marble012' => [220, 220, 220], 'Marble014' => [215, 200, 175],
        'Granite004B' => [190, 170, 145], 'Travertine009' => [210, 195, 170],
        'Granite001A' => [90, 90, 90], 'Marble016' => [30, 30, 30] } },
      'concreto' => { rotulo: 'Concreto / cimento queimado', texturas: {
        'smooth_concrete_floor' => [130, 128, 125], 'concrete_wall_008' => [150, 150, 145],
        'concrete_slab_wall' => [160, 158, 150] } },
      'tijolo' => { rotulo: 'Tijolo', texturas: {
        'red_brick' => [150, 75, 55], 'painted_brick' => [220, 218, 210],
        'castle_brick_02_white' => [210, 205, 195] } },
      'reboco' => { rotulo: 'Reboco / textura', texturas: {
        'white_stucco' => [225, 222, 215], 'grey_plaster' => [170, 168, 160],
        'beige_wall_001' => [205, 190, 165] } },
      # Soluções genéricas: sem textura, só o acabamento certo no render.
      'parede' => { rotulo: 'Parede pintada (genérico)', texturas: {} },
      'metal' => { rotulo: 'Metal (genérico)', texturas: {} }
    }.freeze

    GENERICAS = %w[tecido madeira piso porcelanato revestimento pedra placas bancada parede
                   concreto tijolo reboco assoalho laminado vinilico lamina].freeze
    CORES = %w[cinza branco branca preto preta bege claro clara escuro escura natural marrom
               creme areia verde azul vermelho].freeze

    def self.rotulo(cat)
      (CATEGORIAS[cat] || {})[:rotulo] || cat.to_s
    end

    def self.com_textura?(cat)
      !(CATEGORIAS[cat] || {})[:texturas].to_h.empty?
    end

    # Texturas da categoria, da mais indicada para a menos: palavra do nome em
    # comum ("freijó", "linho", "carrara"...) primeiro, depois a cor mais
    # parecida. Uma preferida nas regras vai na frente de tudo.
    # nomes: { id => nome legível } (do catálogo) para casar palavras.
    def self.ordenar(cat, rgb, nome = '', nomes = {}, regras = {})
      tex = (CATEGORIAS[cat] || {})[:texturas].to_h
      return [] if tex.empty?
      txt = plano(nome)
      pref = ((regras['preferidas'] || {})[cat]).to_s
      tex.sort_by do |id, cor|
        d = 2 * (cor[0] - rgb[0])**2 + 4 * (cor[1] - rgb[1])**2 + 3 * (cor[2] - rgb[2])**2
        palavras = plano(nomes[id]).split(/[^a-z]+/).select { |w| w.length >= 4 } - GENERICAS
        d -= palavras.select { |w| txt =~ /(?<![a-z])#{w}/ }.sum { |w| CORES.include?(w) ? 300_000 : 1_000_000 }
        d -= 10_000_000 if id == pref
        d
      end.map(&:first)
    end

    def self.plano(t)
      t.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').downcase
    end

    # ------------------------------------------------------------ candidatos extras
    # Além das texturas fixas acima, o modo Automático pode sugerir itens do
    # catálogo online (Poly Haven / ambientCG) e das Minhas texturas. Eles não
    # têm cor média conhecida (não se baixa nada para medir), então só passam
    # na frente quando o NOME do material casa com o nome/tags do item:
    #   preferida nas regras > Minha textura com nome igual > fixa com nome
    #   igual > online com nome igual > fixa pela cor > Minha / online sem casar.
    # Sem nenhum nome casando, o resultado é exatamente o de antes.
    # extras: [{ 'chave' => 'ph:x' | 'acg:x' | 'minha:x', 'nome' =>, 'tags' => [], 'minha' => bool }]
    SINONIMOS = {
      'carvalho' => %w[oak], 'nogueira' => %w[walnut], 'freijo' => %w[ash], 'freixo' => %w[ash],
      'cerejeira' => %w[cherry], 'pinus' => %w[pine], 'pinho' => %w[pine], 'bambu' => %w[bamboo],
      'marmore' => %w[marble], 'granito' => %w[granite], 'travertino' => %w[travertine],
      'onix' => %w[onyx], 'granilite' => %w[terrazzo], 'linho' => %w[linen], 'veludo' => %w[velvet velour],
      'couro' => %w[leather], 'tijolo' => %w[brick bricks], 'tijolinho' => %w[brick bricks],
      'concreto' => %w[concrete], 'cimento' => %w[concrete cement], 'taco' => %w[parquet],
      'espinha' => %w[herringbone], 'ladrilho' => %w[tiles], 'terracota' => %w[terracotta],
      'palhinha' => %w[wicker rattan], 'vime' => %w[wicker rattan], 'juta' => %w[jute hessian],
      'carpete' => %w[carpet], 'tapete' => %w[carpet rug], 'reboco' => %w[plaster stucco],
      'grafiato' => %w[stucco plaster], 'laminado' => %w[laminate], 'compensado' => %w[plywood],
      'algodao' => %w[cotton], 'la' => %w[wool], 'jeans' => %w[denim], 'camurca' => %w[suede],
      'boucle' => %w[boucle], 'cotele' => %w[corduroy], 'hexagonal' => %w[hexagonal],
      'escuro' => %w[dark], 'escura' => %w[dark], 'claro' => %w[light], 'clara' => %w[light],
      'branco' => %w[white], 'branca' => %w[white], 'preto' => %w[black], 'preta' => %w[black],
      'cinza' => %w[grey gray], 'bege' => %w[beige], 'vermelho' => %w[red], 'verde' => %w[green],
      'azul' => %w[blue], 'marrom' => %w[brown]
    }.freeze
    # Palavras que não identificam nada sozinhas (nome de item em inglês).
    VAZIAS = %w[floor flooring wood wooden tiles tile wall walls fabric texture seamless
                material planks plank pattern surface clean dirty painted rough smooth light dark
                white black grey gray beige brown green blue red].freeze

    def self.palavras_material(nome)
      base = plano(nome).split(/[^a-z]+/).reject(&:empty?)
      (base + base.flat_map { |w| SINONIMOS[w] || [] }).uniq
    end

    def self.casamentos(item, palavras)
      alvo = plano([item['nome'], *Array(item['tags'])].join(' ')).split(/[^a-z]+/).uniq
      alvo = alvo.select { |w| w.length >= 4 } - GENERICAS - VAZIAS
      alvo.count { |w| palavras.include?(w) }
    end

    def self.ordenar_com_extras(cat, rgb, nome = '', nomes = {}, regras = {}, extras = [])
      fixas = ordenar(cat, rgb, nome, nomes, regras)
      return fixas if extras.empty?
      pal = palavras_material(nome)
      pref = ((regras['preferidas'] || {})[cat]).to_s
      txt = plano(nome)
      # Quantas palavras do nome casam: cada palavra vale 1000 pontos (cor
      # vale 300, como em ordenar). Empate entre fixa e online: fica a fixa.
      casa_fixa = lambda do |id|
        ws = (plano(nomes[id]).split(/[^a-z]+/).select { |w| w.length >= 4 } - GENERICAS).uniq
        ws.select { |w| txt =~ /(?<![a-z])#{w}/ }.sum { |w| CORES.include?(w) ? 300 : 1000 }
      end
      pontos = {}
      fixas.each_with_index do |id, i|
        pontos[id] = id == pref ? -1_000_000 + i : -casa_fixa.call(id) + i
      end
      extras.each do |it|
        ch = it['chave'].to_s
        next if ch.empty? || pontos.key?(ch)
        n = casamentos(it, pal)
        pontos[ch] = if ch == pref then -1_000_000
                     elsif n > 0 && it['minha'] then -100_000 - n
                     elsif n > 0 then -1000 * n + 500
                     else (it['minha'] ? 50_000 : 60_000)
                     end
      end
      pontos.sort_by { |ch, p| [p, ch] }.map(&:first)
    end

    # Candidatos extras por categoria, a partir dos itens do catálogo online
    # (já com 'categoria_auto') e das Minhas texturas. Regras do usuário podem
    # desligar cada fonte: "catalogo_online": false / "minhas_texturas": false.
    def self.extras(online, minhas, regras = {})
      por = Hash.new { |h, k| h[k] = [] }
      unless regras['catalogo_online'] == false
        Array(online).each do |it|
          cat = it['categoria_auto']
          next unless cat && com_textura?(cat) && it['chave'].to_s =~ /\A(ph|acg):/
          por[cat] << { 'chave' => it['chave'], 'nome' => it['nome'].to_s, 'tags' => Array(it['tags']) }
        end
      end
      unless regras['minhas_texturas'] == false
        Array(minhas).each do |it|
          cat = categoria_minha(it)
          next unless cat && it['id']
          por[cat] << { 'chave' => "minha:#{it['id']}", 'nome' => it['nome'].to_s,
                        'tags' => [it['fabricante'], it['colecao']].compact, 'minha' => true }
        end
      end
      Hash[por]
    end

    # ------------------------------------------------------------ tipo dos itens do catálogo
    # Tipo (para o filtro da galeria, em português) e categoria do modo
    # Automático de um item do catálogo online, pelos metadados da fonte
    # (categoria do ambientCG; categorias/tags do Poly Haven) e pelo nome.
    # -> [rótulo do tipo, categoria do Automático ou nil]
    TIPOS_ACG = {
      'WoodFloor' => ['Pisos de madeira', 'piso_madeira'],
      'Wood' => ['Madeiras', 'madeira'], 'PaintedWood' => ['Madeiras', 'madeira'],
      'Bamboo' => ['Madeiras', 'madeira'], 'Chipboard' => ['Madeiras', 'madeira'],
      'WoodSiding' => ['Madeiras', 'madeira'], 'Planks' => ['Madeiras', 'madeira'],
      'Tiles' => ['Porcelanatos e revestimentos', 'piso'], 'Terrazzo' => ['Porcelanatos e revestimentos', 'piso'],
      'Porcelain' => ['Porcelanatos e revestimentos', 'piso'],
      'GlazedTerracotta' => ['Porcelanatos e revestimentos', 'piso'],
      'Marble' => ['Mármores e pedras', 'bancada'], 'Granite' => ['Mármores e pedras', 'bancada'],
      'Travertine' => ['Mármores e pedras', 'bancada'], 'Onyx' => ['Mármores e pedras', 'bancada'],
      'Fabric' => ['Tecidos', 'tecido'], 'Carpet' => ['Tecidos', 'tecido'],
      'Leather' => ['Couro', 'couro'],
      'Bricks' => ['Tijolos', 'tijolo'], 'PaintedBricks' => ['Tijolos', 'tijolo'],
      'Concrete' => ['Concreto', 'concreto'],
      'Plaster' => ['Paredes e reboco', 'reboco'], 'PaintedPlaster' => ['Paredes e reboco', 'reboco'],
      'Paint' => ['Paredes e reboco', nil], 'Wallpaper' => ['Paredes e reboco', nil],
      'Metal' => ['Metais', nil], 'PaintedMetal' => ['Metais', nil], 'MetalPlates' => ['Metais', nil],
      'SheetMetal' => ['Metais', nil], 'CorrugatedSteel' => ['Metais', nil], 'DiamondPlate' => ['Metais', nil],
      'Wicker' => ['Palhinha e fibras', nil], 'Rope' => ['Palhinha e fibras', nil],
      'RoofingTiles' => ['Telhados', nil], 'Facade' => ['Fachadas', nil]
    }.freeze
    EXTERNA = /\A(PavingStones|Ground|Gravel|Asphalt|Rock|Rocks|Grass|Road|Snow|Terrain|Moss|Pathway|Bark)\z/.freeze
    PH_TECIDO = %w[fabric cotton wool fleece knitted denim jacquard velvet corduroy suede satin
                   crepe woven carpet hessian stretchy fur].freeze
    PH_EXTERNA = %w[terrain sand gravel road asphalt cobblestone snow aerial bark].freeze

    def self.classificar_item(it)
      return TIPOS_ACG[it['categoria']] || (it['categoria'].to_s =~ EXTERNA ? ['Área externa', nil] : por_nome_item(it)) if it['fonte'] == 'ambientcg'
      cats = Array(it['categorias']).map { |c| c.to_s.downcase }
      n = plano("#{it['nome']} #{it['id']}")
      return ['Couro', 'couro'] if cats.include?('leather') || n =~ /leather/
      return ['Tecidos', 'tecido'] if (cats & PH_TECIDO).any?
      return ['Mármores e pedras', 'bancada'] if n =~ /marble|granite|travertine|onyx/
      return ['Porcelanatos e revestimentos', 'piso'] if cats.include?('tiles') || n =~ /terrazzo|tiles?\b/
      if cats.include?('wood') || cats.include?('raw wood')
        return ['Pisos de madeira', 'piso_madeira'] if cats.include?('floor') || n =~ /floor|parquet|planks/
        return ['Madeiras', 'madeira']
      end
      return ['Tijolos', 'tijolo'] if cats.include?('brick')
      return ['Concreto', 'concreto'] if cats.include?('concrete')
      return ['Paredes e reboco', 'reboco'] if cats.include?('plaster') || cats.include?('plaster-concrete')
      return ['Metais', nil] if cats.include?('metal')
      return ['Telhados', nil] if cats.include?('roofing')
      return ['Área externa', nil] if (cats & PH_EXTERNA).any? || cats.include?('rock')
      por_nome_item(it)
    end

    def self.por_nome_item(it)
      n = plano("#{it['nome']} #{it['id']}")
      case n
      when /parquet|laminate|wood ?floor/ then ['Pisos de madeira', 'piso_madeira']
      when /veneer|wood|plywood/ then ['Madeiras', 'madeira']
      when /marble|granite|travertine/ then ['Mármores e pedras', 'bancada']
      when /tile|terrazzo/ then ['Porcelanatos e revestimentos', 'piso']
      when /leather/ then ['Couro', 'couro']
      when /fabric|linen|velvet|cotton|wool/ then ['Tecidos', 'tecido']
      when /brick/ then ['Tijolos', 'tijolo']
      when /concrete/ then ['Concreto', 'concreto']
      when /plaster|stucco/ then ['Paredes e reboco', 'reboco']
      else ['Outros', nil]
      end
    end

    # Categoria de uma das Minhas texturas, pelo nome / fabricante / coleção
    # (as mesmas palavras do classificador de materiais).
    def self.categoria_minha(it)
      txt = [it['nome'], it['colecao'], it['fabricante']].join(' ')
      Classificador::REGRAS.each { |re, cat| return cat if txt =~ re && com_textura?(cat) }
      nil
    end

    # Tamanho real estimado de uma textura do ambientCG (a API não informa a
    # unidade das dimensões) e rugosidade nominal por categoria.
    TAMANHO_ACG = { 'Marble' => 2.0, 'Travertine' => 2.0, 'Onyx' => 2.0, 'Granite' => 1.0,
                    'Tiles' => 1.5, 'Terrazzo' => 1.0, 'WoodFloor' => 2.0, 'Wood' => 1.0,
                    'Planks' => 2.0, 'Fabric' => 0.5, 'Carpet' => 1.0, 'Leather' => 0.5,
                    'Wicker' => 0.5, 'Bricks' => 2.0, 'Concrete' => 2.0, 'Plaster' => 2.0,
                    'PavingStones' => 2.0, 'Ground' => 2.0 }.freeze
    RUGOSIDADE = { 'piso_madeira' => 0.45, 'madeira' => 0.4, 'piso' => 0.35, 'bancada' => 0.15,
                   'tecido' => 0.95, 'couro' => 0.55, 'tijolo' => 0.85, 'concreto' => 0.75,
                   'reboco' => 0.9 }.freeze

    def self.tamanho_acg(categoria)
      TAMANHO_ACG[categoria.to_s] || 1.0
    end

    def self.rugosidade_de(cat)
      RUGOSIDADE[cat.to_s] || 0.6
    end

    # Regras do usuário (opcionais), em %APPDATA%\BlenditSketchUp\regras_materiais.json:
    #   { "preferidas": { "piso": "Tiles142" },
    #     "palavras":   { "bancada": ["silestone", "dekton"] },
    #     "desativar":  ["tecido"] }
    def self.carregar_regras(path = nil)
      path ||= File.join(ENV['APPDATA'] || ENV['LOCALAPPDATA'] || Dir.tmpdir,
                         'BlenditSketchUp', 'regras_materiais.json')
      return {} unless File.file?(path)
      r = JSON.parse(File.read(path, encoding: 'UTF-8'))
      r.is_a?(Hash) ? r : {}
    rescue StandardError
      {}
    end
  end
end
