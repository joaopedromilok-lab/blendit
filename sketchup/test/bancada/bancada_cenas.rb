# encoding: UTF-8
# Bancada de comparação - CENAS (exportadas pelo exportador REAL do plugin,
# com a imitação da API do SketchUp que os outros testes já usam).
#
#   ruby bancada_cenas.rb <pasta_saida>
#
# Grava, dentro da pasta, um pacote Blendit por cena + cenas.json (condições
# de cada cena: câmera, sol, cores, valores esperados). O lado Blender
# (tests/bancada/bancada.py) renderiza e mede. Nada aqui muda o plugin.
#
# Cenas:
#   sala_cinza / sala_azul / sala_terracota
#       A sala de teste de sempre (cena_interior + cena_vidro + câmera de
#       cena_quarto: janela de 3,8 x 1,9 m, mesa, sofá, spots, pendente), a
#       MESMA luz (sol do modelo + céu simulado), mudando SÓ a cor das paredes.
#   relevo_pedra / relevo_tecido / relevo_liso
#       Um painel de 1 x 1 m com um material "da biblioteca" (como
#       Texturas.material_from grava: textura + atributos relevo/rugosidade),
#       com o MESMO mapa de altura e tamanho real diferente: pedra 2,0 m,
#       tecido 0,5 m. Sol rasante. Mede quanto o relevo inclina a superfície.
#       relevo_liso é o mesmo painel sem mapa de altura (controle de ruído).
#   acabamentos
#       Faixa de materiais com o acabamento escrito no nome (POL, ACET,
#       Fosco, escovado, alto brilho) + controles: material da biblioteca
#       (rugosidade própria) e material PBR do SketchUp 2025 (rugosidade
#       própria). Mede a rugosidade que chega ao shader final.
require 'json'
require 'zlib'
require 'fileutils'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative '../cena_quarto'        # build_vidro (cena_vidro) + build_interior (cena_interior)

INCH = 1.0 / 0.0254

def png_px(path, w, h)
  raw = (0...h).map { |y| "\x00".b + (0...w).map { |x| yield(x, y).pack('C*') }.join }.join
  ch = ->(t, d) { [d.bytesize].pack('N') + t + d + [Zlib.crc32(t + d)].pack('N') }
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b + ch.call('IHDR', [w, h, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
                      ch.call('IDAT', Zlib::Deflate.deflate(raw)) + ch.call('IEND', ''))
  path
end

def srgb(v) = v <= 0.0031308 ? (12.92 * v * 255).round : ((1.055 * v**(1 / 2.4) - 0.055) * 255).round

def exportar(model, dir, extra = {})
  opts = { mode: 'realistic', engine: 'CYCLES', samples: 32, resolution: [400, 0], denoise: true,
           interior: 'auto', dois_pontos: true, tom: 'natural', brilho: 0.0, materiais: 'preservar' }.merge(extra)
  BlenditSU::Exporter.new(model, opts).export(dir)
end

saida = File.expand_path(ARGV[0] || 'bancada_pacotes')
FileUtils.mkdir_p(saida)
cenas = {}

# ------------------------------------------------------------------ salas (exposição / balanço)
# Albedos lineares das paredes (a cor do SketchUp é sRGB): cinza 0,5; azul de
# marcenaria/parede 0,05/0,12/0,45; terracota 0,45/0,15/0,07.
CORES = { 'cinza' => [0.5, 0.5, 0.5], 'azul' => [0.05, 0.12, 0.45], 'terracota' => [0.45, 0.15, 0.07] }.freeze
CORES.each do |nome, lin|
  m = build_vidro
  m.active_view.instance_variable_set(:@camera, Sketchup::Camera.new(mi(4.3, 0.5, 1.45), mi(1.2, 3.4, 0.9), 50.0))
  cor = Sketchup::Color.new(*lin.map { |v| srgb(v) })
  %w[Paredes Muro\ frontal].each do |g|
    ent = m.entities.find { |e| e.respond_to?(:name) && e.name == g }
    next unless ent && ent.material
    ent.material.instance_variable_set(:@color, cor)
    ent.material.instance_variable_set(:@name, "Pintura acrílica #{nome}")
  end
  exportar(m, File.join(saida, "sala_#{nome}"))
  cenas["sala_#{nome}"] = { 'grupo' => 'exposicao', 'parede_srgb' => [cor.red, cor.green, cor.blue], 'parede_linear' => lin,
                            'luz' => 'sol do modelo (0,4, -0,5, 0,75) + céu simulado, dia; spots/pendente do modelo',
                            'camera' => 'dentro da sala, (4,3; 0,5; 1,45) -> (1,2; 3,4; 0,9), 50°' }
end

# ------------------------------------------------------------------ relevo (pedra x tecido)
pasta_img = File.join(saida, '_imagens')
FileUtils.mkdir_p(pasta_img)
cinza = png_px(File.join(pasta_img, 'cor_cinza.png'), 16, 16) { [150, 150, 150] }
# Mapa de altura: 8 x 8 "pedras/tramas" por textura, cantos arredondados,
# junta de 1/8 da célula (0 = fundo da junta, 255 = topo).
altura = png_px(File.join(pasta_img, 'altura_celulas.png'), 256, 256) do |x, y|
  cx = (x % 32) - 15.5
  cy = (y % 32) - 15.5
  d = [cx.abs, cy.abs].max
  v = d > 13 ? 0 : (d > 10 ? ((13 - d) / 3.0 * 255).round : 255)
  [v, v, v]
end
# 'liso' = controle sem mapa de altura (mede o piso de ruído do contraste).
{ 'pedra' => [2.0, 'Pedra (biblioteca Blendit)', 5.0], 'tecido' => [0.5, 'Linho (biblioteca Blendit)', 0.5],
  'liso' => [2.0, 'Liso (controle)', 0.0] }.each do |nome, (tam, rotulo, prof_mm)|
  cam = Sketchup::Camera.new(mi(0.5, -1.6, 0.5), mi(0.5, 0, 0.5), 40.0)
  m = Sketchup::Model.new("Relevo #{nome}", cam, Geom::Vector3d.new(-0.97, -0.17, 0.17),   # sol rasante, da esquerda
                          Geom::BoundingBox.new(mi(-0.2, -0.2, -0.05), mi(1.2, 0.2, 1.1)))
  mat = Sketchup::Material.new(rotulo, [150, 150, 150], texture: Sketchup::Texture.new(cinza, tam * INCH, tam * INCH))
  mat.set_attribute('blendit', 'textura', "bancada_#{nome}")
  mat.set_attribute('blendit', 'rugosidade', 0.75)
  mat.set_attribute('blendit', 'relevo', altura) if prof_mm > 0
  d = Sketchup::ComponentDefinition.new('Painel')
  f = d.entities.add_face([mi(0, 0, 0), mi(1, 0, 0), mi(1, 0, 1), mi(0, 0, 1)])
  f.material = mat
  f.uv_front = [[0, 0], [1.0 / tam, 0], [1.0 / tam, 1.0 / tam], [0, 1.0 / tam]]      # textura em tamanho real
  m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: 'Painel')
  exportar(m, File.join(saida, "relevo_#{nome}"), interior: 'nao')
  celula_mm = tam * 1000.0 / 8.0
  cenas["relevo_#{nome}"] = {
    'grupo' => 'relevo', 'tamanho_textura_m' => tam, 'celula_mm' => celula_mm,
    'profundidade_fisica_mm' => prof_mm,
    'premissa' => 'profundidade típica: pedra/tijolo ~5 mm de junta, trama de tecido ~0,5 mm',
    # Inclinação física média da rampa da borda: a rampa ocupa 3/32 da célula de cada lado.
    'inclinacao_fisica_borda_graus' => (Math.atan(prof_mm / (celula_mm * 3.0 / 32.0)) * 180 / Math::PI).round(2),
    'luz' => 'sol rasante vindo da esquerda (-0,97; -0,17; 0,17)', 'camera' => 'frontal, 40°'
  }
end

# ------------------------------------------------------------------ acabamentos escritos no nome
tex = png_px(File.join(pasta_img, 'cor_marmore.png'), 16, 16) { |x, y| (x + y).even? ? [225, 222, 218] : [205, 202, 198] }
t = ->(s = 0.6) { Sketchup::Texture.new(tex, s * INCH, s * INCH) }
lista = [
  ['Porcelanato Calacata Oro POL 120x120', t.call(1.2), nil, nil, 0.12, 'polido (nome)'],
  ['Porcelanato Cimenticio ACET 60x60', t.call, nil, nil, 0.4, 'acetinado (nome)'],
  ['Porcelanato Grafite Fosco 60x60', t.call, nil, nil, 0.75, 'fosco (nome)'],
  ['Laca azul alto brilho', nil, nil, nil, 0.12, 'alto brilho (nome), só cor'],
  ['Inox escovado', t.call, nil, nil, nil, 'escovado (nome) - valor alvo a definir na etapa 3'],
  ['Mármore da biblioteca (Blendit)', t.call(2.0), 0.12, nil, 0.12, 'controle: rugosidade própria da biblioteca'],
  ['Porcelanato Fosco PBR', t.call, nil, 0.2, 0.2, 'controle: PBR do SketchUp 2025 (0,2) manda, mesmo com "Fosco" no nome']
]
cam = Sketchup::Camera.new(mi(3.5, -4.0, 2.0), mi(3.5, 0.5, 0.0), 50.0)
m = Sketchup::Model.new('Acabamentos', cam, Geom::Vector3d.new(0.3, -0.6, 0.7),
                        Geom::BoundingBox.new(mi(-0.1, -0.1, -0.05), mi(7.1, 1.1, 0.1)))
esperado = {}
lista.each_with_index do |(nome, tx, rug_attr, pbr, alvo, nota), i|
  mat = Sketchup::Material.new(nome, [200, 198, 195], texture: tx)
  mat.set_attribute('blendit', 'rugosidade', rug_attr) if rug_attr
  if pbr
    alvo_tex = Sketchup::Texture.new(png_px(File.join(pasta_img, 'rugo_branco.png'), 4, 4) { [255, 255, 255] }, 0.6 * INCH, 0.6 * INCH)
    mat.com_pbr(roughness: alvo_tex, roughness_factor: pbr)
  end
  d = Sketchup::ComponentDefinition.new("Amostra #{i + 1}")
  f = d.entities.add_face([mi(i, 0, 0), mi(i + 0.9, 0, 0), mi(i + 0.9, 1, 0), mi(i, 1, 0)])
  f.material = mat
  m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: "Amostra #{i + 1}")
  esperado[nome] = { 'rugosidade_esperada' => alvo, 'nota' => nota }
end
exportar(m, File.join(saida, 'acabamentos'), interior: 'nao')
cenas['acabamentos'] = { 'grupo' => 'acabamento', 'materiais' => esperado,
                         'regra' => 'acabamento do nome só quando o material não tem rugosidade própria (biblioteca ou PBR 2025)' }

File.write(File.join(saida, 'cenas.json'), JSON.pretty_generate(cenas))
puts "cenas exportadas em #{saida}: #{cenas.keys.join(', ')}"
