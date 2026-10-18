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
