# encoding: UTF-8
# Blendit para SketchUp - biblioteca de materiais com texturas reais.
#
# Duas partes:
#   * BIBLIOTECA - texturas de uso livre (licença CC0: uso livre, inclusive
#     comercial, sem precisar dar crédito) do Poly Haven (polyhaven.com) e do
#     ambientCG (ambientcg.com). Nada vem dentro do plugin: cada textura é
#     baixada só quando for usada pela primeira vez e fica guardada no computador.
#   * MINHAS TEXTURAS - imagens que a própria usuária adiciona (catálogos de
#     fabricantes, fotos de amostras), com o tamanho real da peça. Ficam SÓ no
#     computador dela, nunca no plugin nem no GitHub.
#
# Todo material criado já sai no TAMANHO REAL (ex.: porcelanato 90x90 cm), com
# rugosidade adequada e, quando a fonte tem, mapa de relevo para o render.
require 'json'
require 'fileutils'
require 'zlib'

module BlenditSU
  module Texturas
    PH_API = 'https://api.polyhaven.com'.freeze
    PH_THUMB = 'https://cdn.polyhaven.com/asset_img/thumbs/%s.png?width=256&height=256'.freeze
    ACG_GET = 'https://ambientcg.com/get?file=%s_1K-JPG.zip'.freeze
    ACG_THUMB = 'https://acg-media.struffelproductions.com/file/ambientCG-Web/media/thumbnail/256-PNG/%s.png'.freeze
    UA = 'BlenditSketchUp/0.3 (plugin SketchUp; github.com/joaopedromilok-lab/blendit)'.freeze

    POLIDO = 0.12
    ACETINADO = 0.4
    FOSCO = 0.75

    # [grupo, nome, fonte (:ph | :acg), id, tamanho_m (só :acg; :ph usa o real da fonte), rugosidade]
    CATALOGO = [
      # ----- Mármores, granitos e pedras
      ['Mármores e pedras', 'Mármore Carrara (veios cinza)', :acg, 'Marble012', 2.0, POLIDO],
      ['Mármores e pedras', 'Mármore branco polido', :acg, 'Marble021', 2.0, POLIDO],
      ['Mármores e pedras', 'Mármore branco fosco', :acg, 'Marble019', 2.0, FOSCO],
      ['Mármores e pedras', 'Mármore Nero Marquina (preto)', :acg, 'Marble016', 2.0, POLIDO],
      ['Mármores e pedras', 'Mármore preto fosco', :acg, 'Marble006', 2.0, FOSCO],
      ['Mármores e pedras', 'Mármore bege (Crema)', :acg, 'Marble014', 2.0, ACETINADO],
      ['Mármores e pedras', 'Mármore bege polido', :acg, 'Marble020', 2.0, POLIDO],
      ['Mármores e pedras', 'Mármore verde escuro', :acg, 'Marble009', 2.0, POLIDO],
      ['Mármores e pedras', 'Mármore marrom', :acg, 'Marble024', 2.0, POLIDO],
      ['Mármores e pedras', 'Mármore azul escuro', :acg, 'Marble023', 2.0, POLIDO],
      ['Mármores e pedras', 'Travertino claro', :acg, 'Travertine009', 2.0, ACETINADO],
      ['Mármores e pedras', 'Travertino bege', :acg, 'Travertine001', 2.0, ACETINADO],
      ['Mármores e pedras', 'Travertino cinza', :acg, 'Travertine014', 2.0, FOSCO],
      ['Mármores e pedras', 'Travertino marrom', :acg, 'Travertine003', 2.0, ACETINADO],
      ['Mármores e pedras', 'Granito (bancada) 1', :acg, 'Granite001A', 1.0, POLIDO],
      ['Mármores e pedras', 'Granito (bancada) 2', :acg, 'Granite002A', 1.0, POLIDO],
      ['Mármores e pedras', 'Granito (bancada) 3', :acg, 'Granite003A', 1.0, POLIDO],
      ['Mármores e pedras', 'Granito bege (bancada)', :acg, 'Granite004B', 1.0, POLIDO],
      ['Mármores e pedras', 'Granito (bancada) 5', :acg, 'Granite005A', 1.0, POLIDO],
      ['Mármores e pedras', 'Granito em placas', :ph, 'granite_tile_03', nil, 0.2],
      ['Mármores e pedras', 'Pedra cinza em placas', :ph, 'grey_cartago_01', nil, 0.5],
      ['Mármores e pedras', 'Pedra cinza em placas 2', :ph, 'grey_cartago_03', nil, 0.5],
      ['Mármores e pedras', 'Marmorizado branco em placas', :ph, 'marble_01', nil, POLIDO],

      # ----- Porcelanatos, cerâmicas e revestimentos
      ['Porcelanatos e revestimentos', 'Porcelanato cimentício', :ph, 'concrete_tiles', nil, 0.45],
      ['Porcelanatos e revestimentos', 'Porcelanato cimentício 2', :ph, 'concrete_tiles_02', nil, 0.45],
      ['Porcelanatos e revestimentos', 'Porcelanato pedra bege (retangular)', :acg, 'Tiles143', 2.0, FOSCO],
      ['Porcelanatos e revestimentos', 'Porcelanato pedra creme', :acg, 'Tiles142', 2.0, FOSCO],
      ['Porcelanatos e revestimentos', 'Porcelanato pedra areia', :acg, 'Tiles144', 2.0, FOSCO],
      ['Porcelanatos e revestimentos', 'Porcelanato marmorizado em placas', :acg, 'Tiles074', 2.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Porcelanato marmorizado em placas 2', :acg, 'Tiles075', 2.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Porcelanato marmorizado em placas 3', :acg, 'Tiles078', 2.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Piso pedra calcária xadrez', :acg, 'Tiles139', 2.0, ACETINADO],
      ['Porcelanatos e revestimentos', 'Revestimento branco (banheiro)', :acg, 'Tiles133A', 1.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Revestimento branco 2', :acg, 'Tiles107', 1.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Revestimento branco 3', :acg, 'Tiles105', 1.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Revestimento metrô branco (subway)', :acg, 'Tiles036', 1.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Revestimento preto quadrado', :acg, 'Tiles052', 1.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Revestimento preto', :acg, 'Tiles108', 1.0, POLIDO],
      ['Porcelanatos e revestimentos', 'Pedra preta quadrada', :acg, 'Tiles138', 1.0, ACETINADO],
      ['Porcelanatos e revestimentos', 'Revestimento cerâmico claro', :ph, 'interior_tiles', nil, 0.2],
      ['Porcelanatos e revestimentos', 'Ladrilho de terracota', :ph, 'terracotta_floor_tiles', nil, 0.6],
      ['Porcelanatos e revestimentos', 'Ladrilho marrom', :ph, 'brown_floor_tiles', nil, 0.5],
      ['Porcelanatos e revestimentos', 'Piso antiderrapante', :ph, 'anti_skid_tiles', nil, 0.8],

      # ----- Pastilhas e mosaicos
      ['Pastilhas e mosaicos', 'Pastilha hexagonal branca', :acg, 'Tiles071', 0.6, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha hexagonal preta', :acg, 'Tiles072', 0.6, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha hexagonal azul (piscina)', :acg, 'Tiles069', 0.6, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha hexagonal azul e preta', :acg, 'Tiles070', 0.6, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha hexagonal ciano', :acg, 'Tiles067', 0.6, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha hexagonal terracota', :acg, 'Tiles066', 0.6, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha hexagonal amarela', :acg, 'Tiles065', 0.6, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha redonda (penny)', :acg, 'Tiles129B', 0.5, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha azul (piscina)', :acg, 'Tiles132A', 1.0, POLIDO],
      ['Pastilhas e mosaicos', 'Pastilha azul escura (piscina)', :acg, 'Tiles135A', 1.0, POLIDO],
      ['Pastilhas e mosaicos', 'Mosaico de pedra amarelo', :acg, 'Tiles131', 1.0, ACETINADO],

      # ----- Granilite / terrazzo
      ['Granilite (terrazzo)', 'Granilite branco clássico', :acg, 'Terrazzo001', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite branco e preto', :acg, 'Terrazzo005', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite branco', :acg, 'Terrazzo004', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite preto', :acg, 'Terrazzo003', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite colorido', :acg, 'Terrazzo013', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite colorido 2', :acg, 'Terrazzo011', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite escuro colorido', :acg, 'Terrazzo015', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite bege (pedras grandes)', :acg, 'Terrazzo019L', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite bege (pedras pequenas)', :acg, 'Terrazzo019S', 1.0, ACETINADO],
      ['Granilite (terrazzo)', 'Granilite em placas', :ph, 'terrazzo_tiles', nil, 0.25],

      # ----- Pisos de madeira
      ['Pisos de madeira', 'Piso laminado', :ph, 'laminate_floor_02', nil, 0.4],
      ['Pisos de madeira', 'Piso laminado claro', :ph, 'laminate_floor', nil, 0.4],
      ['Pisos de madeira', 'Piso laminado 3', :ph, 'laminate_floor_03', nil, 0.4],
      ['Pisos de madeira', 'Assoalho de carvalho', :ph, 'oak_wood_planks', nil, 0.45],
      ['Pisos de madeira', 'Assoalho escuro', :ph, 'dark_wooden_planks', nil, 0.45],
      ['Pisos de madeira', 'Assoalho de réguas', :ph, 'plank_flooring', nil, 0.45],
      ['Pisos de madeira', 'Assoalho de réguas 2', :ph, 'plank_flooring_02', nil, 0.45],
      ['Pisos de madeira', 'Taco espinha de peixe', :ph, 'herringbone_parquet', nil, 0.4],
      ['Pisos de madeira', 'Taco retangular', :ph, 'rectangular_parquet', nil, 0.4],
      ['Pisos de madeira', 'Taco diagonal', :ph, 'diagonal_parquet', nil, 0.4],
      ['Pisos de madeira', 'Vinílico madeira clara', :acg, 'WoodFloor051', 2.0, ACETINADO],
      ['Pisos de madeira', 'Vinílico madeira natural', :acg, 'WoodFloor070', 2.0, ACETINADO],
      ['Pisos de madeira', 'Vinílico madeira natural 2', :acg, 'WoodFloor071', 2.0, ACETINADO],
      ['Pisos de madeira', 'Piso madeira escura', :acg, 'WoodFloor064', 2.0, ACETINADO],
      ['Pisos de madeira', 'Piso madeira bege', :acg, 'WoodFloor062', 2.0, ACETINADO],
      ['Pisos de madeira', 'Piso madeira clara', :acg, 'WoodFloor007', 2.0, ACETINADO],
      ['Pisos de madeira', 'Deck / tábuas de madeira', :ph, 'brown_planks_05', nil, 0.7],

      # ----- Madeiras para marcenaria (MDF, lâminas)
      ['Marcenaria (MDF e lâminas)', 'Lâmina de carvalho', :ph, 'oak_veneer_01', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Lâmina de carvalho 2', :ph, 'oak_veneer_02', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Carvalho cinza (grey oak)', :ph, 'grey_oak_veneer_01', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Carvalho mocha', :ph, 'mocha_oak_veneer', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Carvalho prata', :ph, 'silver_oak_veneer_01', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Carvalho preto', :ph, 'black_oak_veneer', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Nogueira natural', :ph, 'natural_walnut_veneer', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Nogueira americana', :ph, 'american_walnut_veneer', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Nogueira escura', :ph, 'black_walnut_veneer_01', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Freijó / freixo claro', :ph, 'ash_veneer', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Cerejeira', :ph, 'cherry_veneer', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Jacarandá (rosewood)', :ph, 'rosewood_veneer1', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Sapele (tipo mogno)', :ph, 'sapele_veneer', nil, 0.35],
      ['Marcenaria (MDF e lâminas)', 'Bambu', :ph, 'bamboo_veneer', nil, 0.4],
      ['Marcenaria (MDF e lâminas)', 'Madeira clara lisa', :acg, 'Wood095', 1.0, ACETINADO],
      ['Marcenaria (MDF e lâminas)', 'Madeira clara com nós (pinus)', :acg, 'Wood096', 1.0, ACETINADO],
      ['Marcenaria (MDF e lâminas)', 'Madeira escura (café)', :acg, 'Wood051', 1.0, ACETINADO],
      ['Marcenaria (MDF e lâminas)', 'Carvalho natural', :acg, 'Wood049', 1.0, ACETINADO],
      ['Marcenaria (MDF e lâminas)', 'Madeira castanha', :acg, 'Wood092', 1.0, ACETINADO],
      ['Marcenaria (MDF e lâminas)', 'Compensado', :ph, 'plywood', nil, 0.6],
      ['Marcenaria (MDF e lâminas)', 'OSB', :ph, 'oriented_strand_board', nil, 0.8],
      ['Marcenaria (MDF e lâminas)', 'Painel ripado de madeira', :ph, 'dark_paneled_wood', nil, 0.5],

      # ----- Palhinha e fibras
      ['Palhinha e fibras naturais', 'Palhinha clara', :acg, 'Wicker010A', 0.5, 0.7],
      ['Palhinha e fibras naturais', 'Palhinha natural', :acg, 'Wicker009A', 0.5, 0.7],
      ['Palhinha e fibras naturais', 'Palhinha trançada', :acg, 'Wicker008A', 0.5, 0.7],
      ['Palhinha e fibras naturais', 'Palhinha escura', :acg, 'Wicker007B', 0.5, 0.7],
      ['Palhinha e fibras naturais', 'Rattan / vime', :acg, 'Wicker011A', 0.5, 0.7],
      ['Palhinha e fibras naturais', 'Trama de bambu', :acg, 'Wicker013', 0.5, 0.7],
      ['Palhinha e fibras naturais', 'Juta / sisal', :ph, 'hessian_230', nil, 1.0],

      # ----- Paredes, concreto e tijolos
      ['Paredes, concreto e tijolos', 'Tijolinho aparente', :ph, 'red_brick', nil, 0.85],
      ['Paredes, concreto e tijolos', 'Tijolinho aparente 2', :ph, 'red_bricks_04', nil, 0.85],
      ['Paredes, concreto e tijolos', 'Tijolo pintado de branco', :ph, 'painted_brick', nil, 0.8],
      ['Paredes, concreto e tijolos', 'Tijolo branco', :ph, 'castle_brick_02_white', nil, 0.8],
      ['Paredes, concreto e tijolos', 'Tijolo em espinha de peixe', :ph, 'herringbone_brick', nil, 0.85],
      ['Paredes, concreto e tijolos', 'Concreto aparente (placas)', :ph, 'concrete_slab_wall', nil, 0.75],
      ['Paredes, concreto e tijolos', 'Concreto aparente com marcas de fôrma', :ph, 'wood_textured_concrete', nil, 0.75],
      ['Paredes, concreto e tijolos', 'Concreto liso', :ph, 'concrete_wall_008', nil, 0.75],
      ['Paredes, concreto e tijolos', 'Bloco de concreto aparente', :ph, 'concrete_block_wall', nil, 0.85],
      ['Paredes, concreto e tijolos', 'Concreto ripado', :ph, 'ribbed_concrete_wall', nil, 0.8],
      ['Paredes, concreto e tijolos', 'Cimento queimado', :ph, 'smooth_concrete_floor', nil, 0.35],
      ['Paredes, concreto e tijolos', 'Reboco / textura branca', :ph, 'white_stucco', nil, 0.9],
      ['Paredes, concreto e tijolos', 'Reboco branco 2', :ph, 'white_stucco_02', nil, 0.9],
      ['Paredes, concreto e tijolos', 'Parede pintada bege', :ph, 'beige_wall_001', nil, 0.85],
      ['Paredes, concreto e tijolos', 'Parede pintada bege 2', :ph, 'beige_wall_002', nil, 0.85],
      ['Paredes, concreto e tijolos', 'Reboco cinza', :ph, 'grey_plaster', nil, 0.9],
      ['Paredes, concreto e tijolos', 'Reboco cinza 2', :ph, 'grey_plaster_02', nil, 0.9],
      ['Paredes, concreto e tijolos', 'Parede rebocada', :ph, 'plastered_wall', nil, 0.9],
      ['Paredes, concreto e tijolos', 'Revestimento de fachada', :ph, 'rectangular_facade_tiles', nil, 0.6],

      # ----- Área externa
      ['Área externa', 'Piso intertravado (paver)', :ph, 'interlocking_concrete_pavers', nil, 0.8],
      ['Área externa', 'Paver quadrado', :ph, 'square_concrete_pavers', nil, 0.8],
      ['Área externa', 'Paver sextavado', :ph, 'hexagonal_concrete_paving', nil, 0.8],
      ['Área externa', 'Calçada de concreto', :ph, 'concrete_pavement', nil, 0.8],
      ['Área externa', 'Concreto vassourado', :ph, 'brushed_concrete', nil, 0.85],
      ['Área externa', 'Paralelepípedo', :ph, 'cobblestone_floor_01', nil, 0.85],
      ['Área externa', 'Tijolo no piso', :ph, 'brick_floor', nil, 0.85],
      ['Área externa', 'Brita', :ph, 'gravel_ground_01', nil, 0.95],
      ['Área externa', 'Seixo rolado', :ph, 'floor_pebbles_01', nil, 0.7],
      ['Área externa', 'Grama', :ph, 'grass_ground', nil, 1.0],
      ['Área externa', 'Grama com caminho', :ph, 'grass_path_2', nil, 1.0],
      ['Área externa', 'Areia', :ph, 'coast_sand_01', nil, 0.95],
      ['Área externa', 'Asfalto', :ph, 'asphalt_02', nil, 0.9],

      # ----- Tecidos e couro
      ['Tecidos e couro', 'Linho', :ph, 'rough_linen', nil, 0.95],
      ['Tecidos e couro', 'Bouclê', :ph, 'wool_boucle', nil, 1.0],
      ['Tecidos e couro', 'Veludo', :ph, 'velour_velvet', nil, 0.9],
      ['Tecidos e couro', 'Algodão (jersey)', :ph, 'cotton_jersey', nil, 0.95],
      ['Tecidos e couro', 'Veludo cotelê', :ph, 'ribbed_corduroy', nil, 0.9],
      ['Tecidos e couro', 'Tecido espinha de peixe', :ph, 'poly_wool_herringbone', nil, 0.95],
      ['Tecidos e couro', 'Jacquard floral', :ph, 'floral_jacquard', nil, 0.85],
      ['Tecidos e couro', 'Suede', :ph, 'scuba_suede', nil, 0.9],
      ['Tecidos e couro', 'Tecido cinza', :acg, 'Fabric030', 0.5, 0.95],
      ['Tecidos e couro', 'Tecido liso trançado', :acg, 'Fabric036', 0.5, 0.95],
      ['Tecidos e couro', 'Tecido cinza fino', :acg, 'Fabric082A', 0.5, 0.95],
      ['Tecidos e couro', 'Tapete cinza e branco', :acg, 'Fabric045', 1.0, 1.0],
      ['Tecidos e couro', 'Couro caramelo', :ph, 'brown_leather', nil, 0.55],
      ['Tecidos e couro', 'Couro branco', :ph, 'leather_white', nil, 0.5],
      ['Tecidos e couro', 'Couro vermelho', :ph, 'leather_red_02', nil, 0.55]
    ].freeze

    ACABAMENTOS = { 'Fosco' => FOSCO, 'Acetinado' => ACETINADO, 'Polido / brilhante' => POLIDO }.freeze

    def self.dir
      base = ENV['LOCALAPPDATA'] || Dir.tmpdir
      File.join(base, 'BlenditSketchUp', 'texturas')
    end

    # Minhas texturas: em APPDATA (Roaming), junto das configurações do usuário,
    # para não sumir com limpezas de cache.
    def self.meu_dir
      base = ENV['APPDATA'] || ENV['LOCALAPPDATA'] || Dir.tmpdir
      File.join(base, 'BlenditSketchUp', 'minhas_texturas')
    end

    # ------------------------------------------------------------- download
    # Net::HTTP primeiro (sem janela); se o SSL do Ruby falhar, curl.exe do Windows.
    def self.download(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = path + '.parte'
      ok = begin
        net_get(url, tmp)
      rescue StandardError
        false
      end
      ok ||= curl_get(url, tmp)
      raise "Falha ao baixar #{url}" unless ok && File.size?(tmp)
      FileUtils.mv(tmp, path)
      path
    end

    def self.net_get(url, path, limit = 5)
      require 'net/http'
      require 'openssl'
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                open_timeout: 15, read_timeout: 90) do |http|
        http.request(Net::HTTP::Get.new(uri, 'User-Agent' => UA))
      end
      if res.is_a?(Net::HTTPRedirection) && limit > 0
        return net_get(URI.join(url, res['location']).to_s, path, limit - 1)
      end
      return false unless res.is_a?(Net::HTTPSuccess)
      File.binwrite(path, res.body)
      true
    end

    def self.curl_get(url, path)
      curl = File.join(ENV['SystemRoot'] || 'C:/Windows', 'System32', 'curl.exe')
      curl = 'curl' unless File.file?(curl)
      system(curl, '-L', '-s', '-f', '-A', UA, '-o', path, url)
    end

    def self.json(url, cache)
      download(url, cache) unless File.size?(cache)
      JSON.parse(File.read(cache, encoding: 'UTF-8'))
    end

    # ------------------------------------------------------------- zip (Ruby puro)
    # Extrai do .zip só os arquivos cujo nome bate com os padrões dados.
    # patterns: { 'cor' => /_Color\.(jpe?g|png)\z/i, ... } -> { 'cor' => caminho }
    def self.unzip_pick(zip_path, dest, patterns)
      FileUtils.mkdir_p(dest)
      data = File.binread(zip_path)
      eocd = data.rindex("PK\x05\x06".b)
      raise 'Arquivo .zip inválido.' unless eocd
      count = data[eocd + 10, 2].unpack1('v')
      pos = data[eocd + 16, 4].unpack1('V')
      out = {}
      count.times do
        f = data[pos, 46].unpack('VvvvvvvVVVvvvvvVV')
        raise 'Arquivo .zip corrompido.' unless f[0] == 0x02014b50
        method, csize, nlen, xlen, clen, lho = f[4], f[8], f[10], f[11], f[12], f[16]
        name = data[pos + 46, nlen].force_encoding('UTF-8')
        pos += 46 + nlen + xlen + clen
        key, = patterns.find { |k, rx| !out.key?(k) && name =~ rx }
        next unless key
        lnlen, lxlen = data[lho + 26, 4].unpack('vv')
        raw = data[lho + 30 + lnlen + lxlen, csize]
        body = case method
               when 0 then raw
               when 8 then Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw)
               else next
               end
        path = File.join(dest, "#{key}#{File.extname(name).downcase}")
        File.binwrite(path, body)
        out[key] = path
      end
      out
    end

    # ------------------------------------------------------------- buscar textura
    # -> [cor, relevo|nil, [larg_m, alt_m], rugosidade|nil]
    def self.fetch(entry)
      _g, _n, src, id, size_m, _r = entry
      src == :acg ? fetch_acg(id, size_m) : fetch_ph(id)
    end

    def self.fetch_ph(id)
      d = File.join(dir, id)
      info = json("#{PH_API}/info/#{id}", File.join(d, 'info.json'))
      files = json("#{PH_API}/files/#{id}", File.join(d, 'files.json'))
      diff_url = pick(files, 'Diffuse', %w[2k 1k 4k])
      raise "Textura #{id} sem imagem de cor." unless diff_url
      diff = File.join(d, 'cor.jpg')
      download(diff_url, diff) unless File.size?(diff)
      bump = nil
      disp_url = pick(files, 'Displacement', %w[1k 2k])
      if disp_url
        bump = File.join(d, 'relevo.jpg')
        begin
          download(disp_url, bump) unless File.size?(bump)
        rescue StandardError
          bump = nil
        end
      end
      rugo = nil
      rough_url = pick(files, 'Rough', %w[1k 2k])
      if rough_url
        rugo = File.join(d, 'rugo.jpg')
        begin
          download(rough_url, rugo) unless File.size?(rugo)
        rescue StandardError
          rugo = nil
        end
      end
      dims = info['dimensions'] || [1000, 1000]
      [diff, bump, [dims[0].to_f / 1000.0, dims[1].to_f / 1000.0], rugo]
    end

    def self.fetch_acg(id, size_m)
      d = File.join(dir, "acg_#{id}")
      cor = Dir.glob(File.join(d, 'cor.*')).first
      # Baixadas antes da versão 0.3.4 não têm o mapa de rugosidade: busca de novo
      # uma vez (a marca 'v2' evita repetir quando a textura não tem esse mapa).
      marca = File.join(d, 'v2')
      if cor.nil? || !File.exist?(marca)
        begin
          zip = File.join(d, 'pacote.zip')
          download(format(ACG_GET, id), zip)
          got = unzip_pick(zip, d, 'cor' => /_Color\.(jpe?g|png)\z/i,
                                   'relevo' => /_Displacement\.(jpe?g|png)\z/i,
                                   'rugo' => /_Roughness\.(jpe?g|png)\z/i)
          File.delete(zip) if File.exist?(zip)
          File.write(marca, '1')
          cor ||= got['cor']
        rescue StandardError
          raise unless cor            # sem internet: segue com o que já tem
        end
        raise "Textura #{id} sem imagem de cor." unless cor
      end
      bump = Dir.glob(File.join(d, 'relevo.*')).first
      rugo = Dir.glob(File.join(d, 'rugo.*')).first
      s = (size_m || 1.0).to_f
      [cor, bump, [s, s], rugo]
    end

    # Mapa de rugosidade já baixado de uma textura da biblioteca (pelo id), para
    # materiais criados antes da versão 0.3.4.
    def self.rugo_em_cache(id)
      return nil if id.to_s.empty?
      [File.join(dir, id.to_s), File.join(dir, "acg_#{id}")].each do |d|
        f = Dir.glob(File.join(d, 'rugo.*')).first
        return f if f
      end
      nil
    end

    def self.pick(files, key, sizes)
      m = files[key] || {}
      sizes.each do |s|
        u = m.dig(s, 'jpg', 'url')
        return u if u
      end
      nil
    end

    def self.thumb(entry)
      entry[2] == :acg ? format(ACG_THUMB, entry[3]) : format(PH_THUMB, entry[3])
    end

    # ------------------------------------------------------------- material
    INCH = 1.0 / 0.0254

    def self.material_from(model, name, img, bump, wm, hm, rough, tag, rugo = nil)
      mat = model.materials[name] || model.materials.add(name)
      mat.texture = img
      mat.texture.size = [wm * INCH, hm * INCH] if mat.texture
      mat.set_attribute('blendit', 'textura', tag)
      mat.set_attribute('blendit', 'rugosidade', rough)
      mat.set_attribute('blendit', 'relevo', bump) if bump
      mat.set_attribute('blendit', 'rugosidade_mapa', rugo) if rugo
      mat
    end

    def self.create_material(model, entry)
      _g, nome, _src, id, _s, rough = entry
      diff, bump, (wm, hm), rugo = fetch(entry)
      material_from(model, "#{nome} (Blendit)", diff, bump, wm, hm, rough, id, rugo)
    end

    # ------------------------------------------------------------- minhas texturas
    def self.meu_index_path
      File.join(meu_dir, 'indice.json')
    end

    def self.minhas
      return [] unless File.file?(meu_index_path)
      JSON.parse(File.read(meu_index_path, encoding: 'UTF-8'))
    rescue StandardError
      []
    end

    def self.salvar_minhas(list)
      FileUtils.mkdir_p(meu_dir)
      File.open(meu_index_path, 'w:UTF-8') { |f| f.write(JSON.pretty_generate(list)) }
    end

    def self.slug(s)
      t = s.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').downcase.gsub(/[^a-z0-9]+/, '_')
      t = t.gsub(/^_+|_+$/, '')
      t.empty? ? 'textura' : t[0, 40]
    end

    # dados: nome, fabricante, largura_cm, altura_cm, acabamento, origem (caminho da imagem)
    def self.adicionar_minha(dados)
      src = dados['origem'].to_s
      raise 'Escolha a imagem da textura.' unless File.file?(src)
      nome = dados['nome'].to_s.strip
      raise 'Dê um nome para a textura.' if nome.empty?
      w = dados['largura_cm'].to_s.tr(',', '.').to_f
      h = dados['altura_cm'].to_s.tr(',', '.').to_f
      raise 'Informe largura e altura da peça em centímetros.' if w <= 0 || h <= 0
      fab = dados['fabricante'].to_s.strip
      id = "#{slug(fab.empty? ? 'minhas' : fab)}__#{slug(nome)}_#{Time.now.strftime('%Y%m%d%H%M%S')}"
      FileUtils.mkdir_p(meu_dir)
      dest = File.join(meu_dir, "#{id}#{File.extname(src).downcase}")
      FileUtils.cp(src, dest)
      item = { 'id' => id, 'nome' => nome, 'fabricante' => fab, 'largura_cm' => w, 'altura_cm' => h,
               'acabamento' => dados['acabamento'].to_s, 'arquivo' => File.basename(dest) }
      salvar_minhas(minhas + [item])
      item
    end

    def self.remover_minha(id)
      list = minhas
      item = list.find { |x| x['id'] == id }
      return unless item
      f = File.join(meu_dir, item['arquivo'].to_s)
      File.delete(f) if File.file?(f)
      salvar_minhas(list.reject { |x| x['id'] == id })
    end

    def self.material_minha(model, item)
      img = File.join(meu_dir, item['arquivo'].to_s)
      raise 'Imagem não encontrada.' unless File.file?(img)
      rough = ACABAMENTOS[item['acabamento']] || ACETINADO
      fab = item['fabricante'].to_s.empty? ? '' : " - #{item['fabricante']}"
      material_from(model, "#{item['nome']}#{fab}", img, nil,
                    item['largura_cm'].to_f / 100.0, item['altura_cm'].to_f / 100.0, rough,
                    "minha:#{item['id']}")
    end


    # ------------------------------------------------------------- importação em lote
    IMG_EXT = %w[.jpg .jpeg .png .bmp .tif .tiff].freeze
    MODELO_EXT = %w[.skp .skm].freeze   # catálogos que vêm como arquivo do SketchUp
    MAX_LOTE = 500

    # Palavras de acabamento no nome do arquivo (sem acento, minúsculas).
    ACAB_PALAVRAS = [
      ['Polido / brilhante', %w[pol polido polida polish polished lux lustrado brilhante gloss glossy lap lappato]],
      ['Acetinado', %w[acet acetinado acetinada satin satinado sat soft]],
      ['Fosco', %w[nat natural fosco fosca mate matte mat ext externo externa ad antiderrapante rustico rustica bold]]
    ].freeze

    # Lê nome, medida e acabamento do nome do arquivo.
    #   "CALACATA ORO 90X90 POL.jpg"  -> Calacata Oro, 90 x 90 cm, Polido
    #   "cimenticio_60x120_nat.png"   -> Cimenticio, 60 x 120 cm, Fosco
    #   "Freijo Puro.jpg"             -> Freijo Puro, sem medida (fica para revisar)
    # Medidas acima de 300 nos dois lados são lidas como milímetros (1200x1200 -> 120 x 120 cm).
    def self.analisar_nome(arquivo)
      base = File.basename(arquivo, '.*')
      txt = base.tr('_', ' ').gsub(/\s+/, ' ').strip
      w = h = nil
      if (m = txt.match(/(\d+(?:[.,]\d+)?)\s*(?:cm|mm)?\s*[xX×*]\s*(\d+(?:[.,]\d+)?)\s*(cm|mm)?/))
        w = m[1].tr(',', '.').to_f
        h = m[2].tr(',', '.').to_f
        mm = m[3].to_s.downcase == 'mm' || m[0].downcase.include?('mm') || (w > 300 && h > 300)
        w /= 10.0 if mm
        h /= 10.0 if mm
        txt = txt.sub(m[0], ' ')
      end
      plain = txt.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').downcase
      acab = nil
      ACAB_PALAVRAS.each do |nome_acab, palavras|
        palavras.each do |pw|
          next unless plain =~ /(?<![a-z0-9])#{Regexp.escape(pw)}(?![a-z0-9])/
          acab ||= nome_acab
          # "natural" também é nome de cor/padrão (Carvalho Natural): marca o
          # acabamento mas fica no nome.
          next if pw == 'natural'
          txt = txt.gsub(/(?<![[:alnum:]])#{Regexp.escape(pw)}(?![[:alnum:]])/i, ' ')
        end
      end
      nome = txt.gsub(/[-.]+/, ' ').gsub(/\s+/, ' ').strip
      siglas = %w[HD MDF MDP PVC SPC LVT LED UV]
      todo_maiusculo = nome !~ /[[:lower:]]/
      nome = nome.split(' ').map do |p|
        next p if siglas.include?(p.upcase) && p == p.upcase
        todo_maiusculo || (p =~ /\A[[:upper:]\d]+\z/ && p.length > 3) ? p.capitalize : p
      end.join(' ')
      nome = nome.sub(/\A[[:lower:]]/) { |c| c.upcase }
      nome = base if nome.empty?
      ok = w && h && w > 0 && h > 0 && w <= 2000 && h <= 2000
      { 'nome' => nome, 'largura_cm' => ok ? w.round(1) : nil, 'altura_cm' => ok ? h.round(1) : nil,
        'acabamento' => acab || 'Acetinado', 'acabamento_lido' => !acab.nil?, 'medida_lida' => !!ok }
    end

    # Todas as imagens de uma pasta (com subpastas). -> [[caminho, subpasta_relativa], ...]
    def self.imagens_da_pasta(raiz)
      raiz = raiz.tr('\\', '/')
      Dir.glob(File.join(raiz, '**', '*')).select do |f|
        File.file?(f) && IMG_EXT.include?(File.extname(f).downcase) && File.basename(f) !~ /\A[._]/
      end.sort.first(MAX_LOTE).map do |f|
        rel = File.dirname(f)[raiz.length..-1].to_s.sub(%r{\A/}, '')
        [f, rel]
      end
    end

    # Extrai as imagens de um .zip (mantendo as subpastas). -> pasta onde ficaram
    def self.extrair_zip(zip_path)
      dest = File.join(meu_dir, '_importando', Time.now.strftime('%Y%m%d%H%M%S'))
      FileUtils.mkdir_p(dest)
      data = File.binread(zip_path)
      eocd = data.rindex("PK\x05\x06".b)
      raise 'Arquivo .zip inválido.' unless eocd
      count = data[eocd + 10, 2].unpack1('v')
      pos = data[eocd + 16, 4].unpack1('V')
      n = 0
      count.times do
        f = data[pos, 46].unpack('VvvvvvvVVVvvvvvVV')
        raise 'Arquivo .zip corrompido.' unless f[0] == 0x02014b50
        flags, method, csize, nlen, xlen, clen, lho = f[3], f[4], f[8], f[10], f[11], f[12], f[16]
        name = data[pos + 46, nlen]
        name = flags & 0x800 != 0 ? name.force_encoding('UTF-8') : name.force_encoding('IBM437').encode('UTF-8')
        pos += 46 + nlen + xlen + clen
        next if name.end_with?('/') || name.include?('__MACOSX')
        next unless (IMG_EXT + MODELO_EXT).include?(File.extname(name).downcase)
        break if n >= MAX_LOTE
        rel = name.split('/').reject { |x| x.empty? || x == '..' || x == '.' }
        next if rel.empty?
        lnlen, lxlen = data[lho + 26, 4].unpack('vv')
        raw = data[lho + 30 + lnlen + lxlen, csize]
        body = case method
               when 0 then raw
               when 8 then Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(raw)
               else next
               end
        out = File.join(dest, *rel)
        FileUtils.mkdir_p(File.dirname(out))
        File.binwrite(out, body)
        n += 1
      end
      dest
    end

    # Arquivos do SketchUp (.skp com a peça aplicada, .skm de material) de uma pasta.
    def self.modelos_da_pasta(raiz)
      raiz = raiz.tr('\\', '/')
      Dir.glob(File.join(raiz, '**', '*')).select do |f|
        File.file?(f) && MODELO_EXT.include?(File.extname(f).downcase) && File.basename(f) !~ /\A[._]/
      end.sort.first(MAX_LOTE).map do |f|
        rel = File.dirname(f)[raiz.length..-1].to_s.sub(%r{\A/}, '')
        [f, rel]
      end
    end

    # Lê os materiais com textura de cada .skp/.skm do catálogo: a imagem e o
    # tamanho real que o fabricante já configurou. O modelo aberto não muda
    # (tudo é desfeito no fim). -> itens no mesmo formato de analisar_nome.
    def self.texturas_de_modelos(raiz, model)
      lista = modelos_da_pasta(raiz)
      return [] if lista.empty? || model.nil?
      dest = File.join(meu_dir, '_importando', "modelos_#{Time.now.strftime('%Y%m%d%H%M%S')}")
      itens = []
      lista.each_with_index do |(arquivo, rel), i|
        Sketchup.status_text = "Blendit: lendo o catálogo #{i + 1} de #{lista.length} - #{File.basename(arquivo)}"
        begin
          itens.concat(extrair_de_modelo(model, arquivo, rel, dest))
        rescue StandardError => e
          puts "Blendit: não deu para ler #{arquivo}: #{e.message}"
        end
      end
      itens
    end

    MAT_GENERICO = /\A\s*(\[?(material|mat|color|cor|default|padr[aã]o)(?![[:alpha:]])|<|\d+\s*\z)/i.freeze

    def self.extrair_de_modelo(model, arquivo, rel, dest)
      antes = model.materials.to_a
      defn = nil
      itens = []
      model.start_operation('Blendit: ler catálogo', true)
      begin
        if File.extname(arquivo).downcase == '.skm'
          return [] unless model.materials.respond_to?(:load)   # SketchUp 2021.1+
          model.materials.load(arquivo)
        else
          defn = model.definitions.load(arquivo)
        end
        novos = (model.materials.to_a - antes).select(&:texture)
        base = File.basename(arquivo, '.*')
        novos.each_with_index do |m, k|
          tex = m.texture
          nome_mat = (m.respond_to?(:display_name) ? m.display_name : m.name).to_s
          # Um material só no arquivo: o nome do arquivo costuma ser o melhor
          # ("CALACATA ORO 90X90 POL.skp"); vários: o nome de cada material.
          nome = novos.length == 1 || nome_mat =~ MAT_GENERICO ? base : nome_mat
          nome = "#{base} #{k + 1}" if novos.length > 1 && nome_mat =~ MAT_GENERICO
          a = analisar_nome("#{nome}.x")
          ext = File.extname(tex.filename.to_s).downcase
          ext = '.png' unless IMG_EXT.include?(ext)
          out = File.join(dest, rel, "#{slug(base)}_#{k}#{ext}")
          FileUtils.mkdir_p(File.dirname(out))
          ok = begin
            tex.write(out, true)
          rescue StandardError
            false
          end
          next unless ok && File.file?(out)
          w = (tex.width.to_f * 2.54).round(1)
          h = (tex.height.to_f * 2.54).round(1)
          if w > 0 && h > 0 && w <= 2000 && h <= 2000
            a = a.merge('largura_cm' => w, 'altura_cm' => h, 'medida_lida' => true)
          end
          itens << a.merge('origem' => out, 'arquivo_origem' => File.basename(arquivo))
        end
      ensure
        model.abort_operation
        limpar_restos(model, defn, antes)
      end
      itens
    end

    # Se o desfazer não levar tudo embora, remove o que o catálogo trouxe.
    def self.limpar_restos(model, defn, antes)
      if defn && defn.respond_to?(:valid?) && defn.valid? && model.definitions.respond_to?(:remove)
        model.definitions.remove(defn) if defn.instances.empty?
      end
      (model.materials.to_a - antes).each do |m|
        model.materials.remove(m) if model.materials.respond_to?(:remove)
      end
    rescue StandardError
      nil
    end

    # Monta a lista de revisão. -> { 'fabricante' => ..., 'itens' => [...] }
    def self.preparar_lote(raiz, fabricante, de_modelos = [])
      existentes = minhas.map { |x| [x['fabricante'].to_s.downcase, x['nome'].to_s.downcase] }
      imgs = imagens_da_pasta(raiz).reject { |c, _s| c.include?('/_importando/modelos_') }
      itens = imgs.map { |caminho, sub| analisar_nome(caminho).merge('origem' => caminho, 'sub' => sub) }
      de_modelos.each do |a|
        sub = File.dirname(a['origem']).split('/modelos_', 2).last.to_s.split('/', 2)[1].to_s
        itens << a.merge('sub' => sub)
      end
      itens = itens.first(MAX_LOTE).map do |a|
        caminho = a['origem']
        colecao = a.delete('sub').to_s.split('/').last.to_s
        fab_item = colecao.empty? ? fabricante : "#{fabricante} / #{colecao}"
        a.merge('colecao' => colecao,
                'arquivo' => a.delete('arquivo_origem') || File.basename(caminho),
                'repetida' => existentes.include?([fab_item.downcase, a['nome'].downcase]),
                'tamanho_kb' => (File.size(caminho) / 1024.0).round)
      end
      { 'fabricante' => fabricante, 'itens' => itens }
    end

    # Importa os itens revisados. -> quantidade importada
    def self.importar_lote(fabricante, itens)
      FileUtils.mkdir_p(meu_dir)
      lista = minhas
      novos = 0
      itens.each_with_index do |it, i|
        next unless it['incluir']
        w = it['largura_cm'].to_s.tr(',', '.').to_f
        h = it['altura_cm'].to_s.tr(',', '.').to_f
        next if w <= 0 || h <= 0 || !File.file?(it['origem'].to_s)
        fab = fabricante.to_s.strip
        fab = "#{fab} / #{it['colecao']}" unless it['colecao'].to_s.empty?
        id = "#{slug(fab.empty? ? 'minhas' : fab)}__#{slug(it['nome'])}_#{Time.now.strftime('%Y%m%d%H%M%S')}#{i}"
        dest = File.join(meu_dir, "#{id}#{File.extname(it['origem']).downcase}")
        FileUtils.cp(it['origem'], dest)
        lista << { 'id' => id, 'nome' => it['nome'].to_s.strip, 'fabricante' => fab, 'largura_cm' => w,
                   'altura_cm' => h, 'acabamento' => it['acabamento'].to_s, 'arquivo' => File.basename(dest) }
        novos += 1
      end
      salvar_minhas(lista)
      FileUtils.rm_rf(File.join(meu_dir, '_importando'))
      novos
    end

    def self.lote_iniciar(dlg, raiz, sugestao)
      fab = UI.inputbox(['Fabricante (vale para todo o lote)'], [sugestao], 'Blendit - Importar catálogo')
      return unless fab
      unless modelos_da_pasta(raiz).empty?
        dlg.execute_script("status(#{JSON.generate('Lendo os arquivos do SketchUp do catálogo... pode levar alguns minutos.')})")
      end
      de_modelos = texturas_de_modelos(raiz, Sketchup.active_model)
      lote = preparar_lote(raiz, fab[0].to_s.strip, de_modelos)
      Sketchup.status_text = ''
      if lote['itens'].empty?
        dlg.execute_script("status(#{JSON.generate('Não achei imagens (JPG, PNG, BMP, TIF) nem arquivos do SketchUp (.skp, .skm) aí.')})")
        return
      end
      lote['itens'].each { |it| it['src'] = 'file:///' + it['origem'].tr('\\', '/') }
      dlg.execute_script("mostrarLote(#{JSON.generate(lote)})")
    end

    # ------------------------------------------------------------- galeria
    def self.aplicar(dlg, model, mat, nome)
      model.materials.current = mat
      Sketchup.send_action('selectPaintTool:')
      dlg.execute_script("status(#{JSON.generate("\"#{nome}\" pronto - clique nas faces com o balde de tinta.")}, true)")
    end

    def self.show
      @dialog ||= nil
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end
      dlg = UI::HtmlDialog.new(dialog_title: 'Blendit - Biblioteca de materiais',
                               preferences_key: 'BlenditTexturas', width: 860, height: 700,
                               resizable: true, style: UI::HtmlDialog::STYLE_DIALOG)
      page = File.join(meu_dir, '..', 'galeria.html')
      FileUtils.mkdir_p(meu_dir)
      File.open(page, 'w:UTF-8') { |f| f.write(html) }
      dlg.set_file(File.expand_path(page))

      dlg.add_action_callback('pronto') { |_c| enviar_minhas(dlg) }
      dlg.add_action_callback('aplicar') do |_ctx, idx|
        entry = CATALOGO[idx.to_i]
        next unless entry
        dlg.execute_script("status(#{JSON.generate("Baixando \"#{entry[1]}\"... (só na primeira vez)")})")
        UI.start_timer(0.05, false) do
          begin
            aplicar(dlg, Sketchup.active_model, create_material(Sketchup.active_model, entry), entry[1])
          rescue StandardError => e
            dlg.execute_script("status(#{JSON.generate("Não deu para baixar: #{e.message}. Confira a internet e tente de novo.")})")
          end
        end
      end
      dlg.add_action_callback('aplicar_minha') do |_ctx, id|
        item = minhas.find { |x| x['id'] == id }
        next unless item
        begin
          aplicar(dlg, Sketchup.active_model, material_minha(Sketchup.active_model, item), item['nome'])
        rescue StandardError => e
          dlg.execute_script("status(#{JSON.generate(e.message)})")
        end
      end
      dlg.add_action_callback('escolher_imagem') do |_ctx|
        path = UI.openpanel('Imagem da textura', nil, 'Imagens|*.jpg;*.jpeg;*.png;*.bmp;*.tif;*.tiff||')
        dlg.execute_script("imagemEscolhida(#{JSON.generate(path.to_s.tr('\\', '/'))})") if path
      end
      dlg.add_action_callback('adicionar') do |_ctx, dados|
        begin
          item = adicionar_minha(dados.is_a?(String) ? JSON.parse(dados) : dados)
          enviar_minhas(dlg)
          dlg.execute_script("status(#{JSON.generate("\"#{item['nome']}\" adicionada às suas texturas.")}, true); limparForm()")
        rescue StandardError => e
          dlg.execute_script("status(#{JSON.generate(e.message)})")
        end
      end
      dlg.add_action_callback('remover') do |_ctx, id|
        if UI.messagebox('Remover esta textura das suas texturas?', MB_YESNO) == IDYES
          remover_minha(id)
          enviar_minhas(dlg)
        end
      end
      dlg.add_action_callback('baixar_tudo') { |_c| baixar_tudo(dlg) }
      dlg.add_action_callback('lote_pasta') do |_c|
        dir = UI.select_directory(title: 'Pasta com as texturas do fabricante')
        lote_iniciar(dlg, dir, File.basename(dir).tr('_', ' ')) if dir
      end
      dlg.add_action_callback('lote_zip') do |_c|
        zip = UI.openpanel('Pacote de texturas (.zip)', nil, 'Arquivo ZIP|*.zip||')
        if zip
          begin
            dlg.execute_script("status(#{JSON.generate('Abrindo o .zip...')})")
            lote_iniciar(dlg, extrair_zip(zip), File.basename(zip, '.*').tr('_-', '  ').strip)
          rescue StandardError => e
            dlg.execute_script("status(#{JSON.generate("Não deu para abrir o .zip: #{e.message}")})")
          end
        end
      end
      dlg.add_action_callback('lote_confirmar') do |_c, dados|
        begin
          d = dados.is_a?(String) ? JSON.parse(dados) : dados
          n = importar_lote(d['fabricante'], d['itens'])
          enviar_minhas(dlg)
          dlg.execute_script("fecharLote(); status(#{JSON.generate("#{n} textura(s) importada(s) para Minhas texturas.")}, true)")
        rescue StandardError => e
          dlg.execute_script("status(#{JSON.generate("Erro ao importar: #{e.message}")})")
        end
      end
      dlg.show
      @dialog = dlg
    end

    def self.enviar_minhas(dlg)
      list = minhas.map do |x|
        x.merge('src' => "minhas_texturas/#{x['arquivo']}")
      end
      dlg.execute_script("mostrarMinhas(#{JSON.generate(list)})")
    end

    # Baixa a biblioteca inteira de uma vez (para usar sem internet depois).
    def self.baixar_tudo(dlg)
      fila = CATALOGO.dup
      total = fila.length
      falhas = 0
      passo = lambda do
        entry = fila.shift
        unless entry
          msg = "Biblioteca baixada: #{total - falhas} de #{total} texturas prontas para usar sem internet."
          msg += " (#{falhas} falharam; tente de novo depois)" if falhas > 0
          dlg.execute_script("status(#{JSON.generate(msg)}, true)")
          next
        end
        begin
          fetch(entry)
        rescue StandardError
          falhas += 1
        end
        feito = total - fila.length
        dlg.execute_script("status(#{JSON.generate("Baixando a biblioteca: #{feito} de #{total}...")})")
        UI.start_timer(0.01, false) { passo.call }
      end
      passo.call
    end

    def self.html
      grupos = CATALOGO.each_with_index.group_by { |e, _i| e[0] }
      secoes = grupos.map do |g, list|
        cards = list.map do |e, i|
          nome = e[1]
          %(<button class="c" data-n="#{nome.downcase} #{g.downcase}" onclick="pick(#{i})"><img loading="lazy" src="#{thumb(e)}" alt=""><span>#{nome}</span></button>)
        end.join
        %(<section><h2>#{g}</h2><div class="g">#{cards}</div></section>)
      end.join
      acab = ACABAMENTOS.keys.map { |k| %(<option#{k == 'Acetinado' ? ' selected' : ''}>#{k}</option>) }.join
      <<~HTML
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
        <style>
          :root{--bg:#f6f5f2;--fg:#222;--mut:#6b6b6b;--card:#fff;--line:#dedbd4;--acc:#2d6a4f}
          *{box-sizing:border-box}
          body{margin:0;font:14px/1.4 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--fg)}
          header{position:sticky;top:0;z-index:2;background:var(--bg);padding:12px 18px 10px;border-bottom:1px solid var(--line)}
          .tabs{display:flex;gap:6px;margin-bottom:8px}
          .tab{border:1px solid var(--line);background:var(--card);border-radius:6px;padding:6px 12px;cursor:pointer;font:inherit}
          .tab.on{border-color:var(--acc);color:var(--acc);font-weight:600}
          .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
          input[type=search],input[type=text],select{font:inherit;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:#fff}
          input[type=search]{flex:1;min-width:180px}
          .btn{font:inherit;padding:6px 12px;border-radius:6px;border:1px solid var(--acc);background:var(--acc);color:#fff;cursor:pointer}
          .btn.sec{background:#fff;color:var(--acc)}
          #st{color:var(--mut);min-height:20px;margin-top:6px}
          #st.ok{color:var(--acc);font-weight:600}
          main{padding:4px 18px 24px}
          h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:18px 0 8px}
          .g{display:grid;grid-template-columns:repeat(auto-fill,minmax(128px,1fr));gap:10px}
          .c{position:relative;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:0;cursor:pointer;
             text-align:left;overflow:hidden;font:inherit;color:inherit}
          .c:hover{border-color:var(--acc)}
          .c img{display:block;width:100%;aspect-ratio:1;object-fit:cover;background:#e9e6df}
          .c span{display:block;padding:6px 8px 8px;font-size:12px}
          .c small{display:block;color:var(--mut);font-size:11px;padding:0 8px 8px;margin-top:-6px}
          .x{position:absolute;top:4px;right:4px;width:22px;height:22px;border-radius:11px;border:0;background:#fff;
             color:#a33;cursor:pointer;font-weight:700;line-height:22px;opacity:.85}
          .form{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin:12px 0}
          .form label{display:block;font-size:12px;color:var(--mut);margin-bottom:2px}
          .form .grid{display:grid;grid-template-columns:2fr 2fr 1fr 1fr 1.4fr;gap:8px;align-items:end}
          .form input,.form select{width:100%}
          #img{font-size:12px;color:var(--mut);word-break:break-all}
          .vazio{color:var(--mut);padding:18px 0}
          footer{color:var(--mut);font-size:11px;padding:0 18px 16px}
          .hide{display:none}
          .lote{background:var(--card);border:1px solid var(--acc);border-radius:8px;padding:12px;margin:12px 0}
          .lote table{width:100%;border-collapse:collapse;font-size:12px}
          .lote th{text-align:left;color:var(--mut);font-weight:600;padding:4px;border-bottom:1px solid var(--line)}
          .lote td{padding:4px;border-bottom:1px solid var(--line);vertical-align:middle}
          .lote td img{width:44px;height:44px;object-fit:cover;border-radius:4px;background:#e9e6df;display:block}
          .lote input[type=text]{width:100%;padding:4px 6px}
          .lote input.n{width:64px}
          .lote tr.falta td{background:#fff4e5}
          .lote tr.falta input.n{border-color:#d9822b}
          .lote .tag{font-size:11px;color:#a35c00}
          .lote .sc{max-height:46vh;overflow:auto;border:1px solid var(--line);border-radius:6px;margin:8px 0}
        </style></head><body>
        <header>
          <div class="tabs"><button class="tab on" id="t1" onclick="aba(1)">Biblioteca (#{CATALOGO.length})</button>
          <button class="tab" id="t2" onclick="aba(2)">Minhas texturas</button></div>
          <div class="row" id="busca"><input type="search" id="q" placeholder="Buscar: mármore, carvalho, pastilha, granilite..." oninput="filtrar()">
          <button class="btn sec" onclick="sketchup.baixar_tudo()" title="Baixa todas as texturas para usar sem internet">Baixar tudo</button></div>
          <div id="st">Clique num material e pinte as faces. Sai no tamanho real e com relevo no render. Baixa só na primeira vez.</div>
        </header>
        <main id="p1">#{secoes}</main>
        <main id="p2" class="hide">
          <div class="form">
            <div class="row" style="margin-bottom:8px"><button class="btn sec" onclick="sketchup.escolher_imagem()">Escolher imagem...</button>
            <span id="img">Imagem do catálogo do fabricante ou foto da amostra (JPG ou PNG).</span></div>
            <div class="grid">
              <div><label>Nome</label><input type="text" id="f_nome" placeholder="Ex.: Calacata Oro 90x90"></div>
              <div><label>Fabricante / coleção</label><input type="text" id="f_fab" placeholder="Ex.: Portobello"></div>
              <div><label>Largura (cm)</label><input type="text" id="f_w" placeholder="90"></div>
              <div><label>Altura (cm)</label><input type="text" id="f_h" placeholder="90"></div>
              <div><label>Acabamento</label><select id="f_ac">#{acab}</select></div>
            </div>
            <div class="row" style="margin-top:10px"><button class="btn" onclick="adicionar()">Adicionar às minhas texturas</button>
            <span style="color:var(--mut);font-size:12px">Largura e altura = o tamanho que a imagem representa (uma peça, ou o trecho da foto).</span></div>
          </div>
          <div class="row" style="margin:4px 0 0">
            <button class="btn sec" onclick="sketchup.lote_pasta()">Importar catálogo (pasta)...</button>
            <button class="btn sec" onclick="sketchup.lote_zip()">Importar catálogo (.zip)...</button>
            <span style="color:var(--mut);font-size:12px">Aceita imagens e arquivos do SketchUp (.skp, .skm). Nome, medida e acabamento vêm do nome do arquivo (ex.: CALACATA 90X90 POL.jpg); nos .skp a medida vem do próprio material.</span>
          </div>
          <div id="lote" class="lote hide"></div>
          <div id="minhas"></div>
        </main>
        <footer id="rod">Biblioteca: texturas do Poly Haven e do ambientCG, licença CC0 - uso livre, inclusive comercial. Minhas texturas ficam só neste computador.</footer>
        <script>
          var origem = '';
          function pick(i){ sketchup.aplicar(i); }
          function status(t, ok){ var s=document.getElementById('st'); s.textContent=t; s.className=ok?'ok':''; }
          function aba(n){
            document.getElementById('p1').classList.toggle('hide', n!==1);
            document.getElementById('p2').classList.toggle('hide', n!==2);
            document.getElementById('busca').classList.toggle('hide', n!==1);
            document.getElementById('t1').classList.toggle('on', n===1);
            document.getElementById('t2').classList.toggle('on', n===2);
          }
          function norm(s){ return s.normalize('NFD').replace(/[\\u0300-\\u036f]/g,'').toLowerCase(); }
          function filtrar(){
            var q = norm(document.getElementById('q').value.trim());
            document.querySelectorAll('#p1 section').forEach(function(sec){
              var vis = 0;
              sec.querySelectorAll('.c').forEach(function(c){
                var ok = !q || norm(c.dataset.n).indexOf(q) >= 0;
                c.classList.toggle('hide', !ok); if (ok) vis++;
              });
              sec.classList.toggle('hide', vis === 0);
            });
          }
          function imagemEscolhida(p){ origem = p; document.getElementById('img').textContent = p; }
          function limparForm(){ origem=''; ['f_nome','f_w','f_h'].forEach(function(i){document.getElementById(i).value='';});
            document.getElementById('img').textContent='Imagem do catálogo do fabricante ou foto da amostra (JPG ou PNG).'; }
          function adicionar(){
            sketchup.adicionar(JSON.stringify({origem: origem, nome: document.getElementById('f_nome').value,
              fabricante: document.getElementById('f_fab').value, largura_cm: document.getElementById('f_w').value,
              altura_cm: document.getElementById('f_h').value, acabamento: document.getElementById('f_ac').value}));
          }
          function esc(s){ return String(s).replace(/[&<>"]/g, function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];}); }
          function mostrarMinhas(list){
            var box = document.getElementById('minhas');
            document.getElementById('t2').textContent = 'Minhas texturas (' + list.length + ')';
            if (!list.length){ box.innerHTML = '<div class="vazio">Nenhuma textura sua ainda. Adicione a primeira acima.</div>'; return; }
            var grupos = {};
            list.forEach(function(x){ var g = x.fabricante || 'Sem fabricante'; (grupos[g] = grupos[g] || []).push(x); });
            var html = '';
            Object.keys(grupos).sort().forEach(function(g){
              html += '<section><h2>' + esc(g) + '</h2><div class="g">';
              grupos[g].forEach(function(x){
                html += '<div class="c" onclick="sketchup.aplicar_minha(\\'' + x.id + '\\')">' +
                  '<button class="x" title="Remover" onclick="event.stopPropagation();sketchup.remover(\\'' + x.id + '\\')">&times;</button>' +
                  '<img src="' + encodeURI(x.src) + '" alt=""><span>' + esc(x.nome) + '</span>' +
                  '<small>' + x.largura_cm + ' x ' + x.altura_cm + ' cm - ' + esc(x.acabamento) + '</small></div>';
              });
              html += '</div></section>';
            });
            box.innerHTML = html;
          }
          var LOTE = null;
          function mostrarLote(l){
            LOTE = l; aba(2);
            var falta = l.itens.filter(function(i){ return !i.medida_lida; }).length;
            var rep = l.itens.filter(function(i){ return i.repetida; }).length;
            var acs = ['Fosco','Acetinado','Polido / brilhante'];
            var h = '<div class="row"><b>' + l.itens.length + ' imagens encontradas</b> &nbsp; Fabricante: <input type="text" id="l_fab" value="' + esc(l.fabricante) + '" style="width:220px">' +
              (falta ? ' <span class="tag">' + falta + ' sem medida no nome - preencha as linhas em laranja</span>' : ' <span style="color:var(--acc)">todas com medida</span>') +
              (rep ? ' <span class="tag">&middot; ' + rep + ' já existem (desmarcadas)</span>' : '') + '</div>' +
              '<div class="row" style="margin-top:6px;font-size:12px;color:var(--mut)">Preencher vazios: <input type="text" class="n" id="l_w" placeholder="larg"> x <input type="text" class="n" id="l_h" placeholder="alt"> cm ' +
              '<button class="btn sec" onclick="preencher()">Aplicar</button></div>' +
              '<div class="sc"><table><tr><th></th><th>Importar</th><th>Nome</th><th>Coleção</th><th>Larg. (cm)</th><th>Alt. (cm)</th><th>Acabamento</th><th>Arquivo</th></tr>';
            l.itens.forEach(function(it, i){
              if (it.incluir === undefined) it.incluir = !it.repetida;
              var opts = acs.map(function(a){ return '<option' + (a === it.acabamento ? ' selected' : '') + '>' + a + '</option>'; }).join('');
              h += '<tr id="lr' + i + '" class="' + (it.medida_lida ? '' : 'falta') + '">' +
                '<td><img loading="lazy" src="' + encodeURI(it.src) + '"></td>' +
                '<td><input type="checkbox" ' + (it.incluir ? 'checked' : '') + ' onchange="LOTE.itens[' + i + '].incluir=this.checked"></td>' +
                '<td><input type="text" value="' + esc(it.nome) + '" oninput="LOTE.itens[' + i + '].nome=this.value"></td>' +
                '<td>' + esc(it.colecao || '') + '</td>' +
                '<td><input type="text" class="n" value="' + (it.largura_cm || '') + '" oninput="setW(' + i + ',this.value)"></td>' +
                '<td><input type="text" class="n" value="' + (it.altura_cm || '') + '" oninput="setH(' + i + ',this.value)"></td>' +
                '<td><select onchange="LOTE.itens[' + i + '].acabamento=this.value">' + opts + '</select></td>' +
                '<td style="color:var(--mut)">' + esc(it.arquivo) + '</td></tr>';
            });
            h += '</table></div><div class="row"><button class="btn" onclick="confirmarLote()">Importar selecionadas</button>' +
                 '<button class="btn sec" onclick="fecharLote()">Cancelar</button>' +
                 '<span style="color:var(--mut);font-size:12px">Linhas sem medida não são importadas.</span></div>';
            var box = document.getElementById('lote'); box.innerHTML = h; box.classList.remove('hide');
            status(l.itens.length + ' imagens prontas para revisar.', true);
          }
          function marca(i){ var it = LOTE.itens[i]; var ok = parseFloat(String(it.largura_cm).replace(',','.')) > 0 && parseFloat(String(it.altura_cm).replace(',','.')) > 0;
            document.getElementById('lr' + i).className = ok ? '' : 'falta'; }
          function setW(i, v){ LOTE.itens[i].largura_cm = v; marca(i); }
          function setH(i, v){ LOTE.itens[i].altura_cm = v; marca(i); }
          function preencher(){
            var w = document.getElementById('l_w').value, h = document.getElementById('l_h').value;
            LOTE.itens.forEach(function(it){ if (!it.largura_cm) it.largura_cm = w; if (!it.altura_cm) it.altura_cm = h; });
            LOTE.fabricante = document.getElementById('l_fab').value; mostrarLote(LOTE);
          }
          function confirmarLote(){
            LOTE.fabricante = document.getElementById('l_fab').value;
            var n = LOTE.itens.filter(function(it){ return it.incluir && parseFloat(String(it.largura_cm).replace(',','.')) > 0 && parseFloat(String(it.altura_cm).replace(',','.')) > 0; }).length;
            if (!n){ status('Nenhuma linha marcada com medida preenchida.'); return; }
            status('Importando ' + n + ' textura(s)...');
            sketchup.lote_confirmar(JSON.stringify({fabricante: LOTE.fabricante, itens: LOTE.itens}));
          }
          function fecharLote(){ LOTE = null; var b = document.getElementById('lote'); b.innerHTML = ''; b.classList.add('hide'); }
          window.addEventListener('load', function(){ if (window.sketchup) sketchup.pronto(); });
        </script></body></html>
      HTML
    end
  end
end
