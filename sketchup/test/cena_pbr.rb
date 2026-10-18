# encoding: UTF-8
# Cena de teste dos mapas PBR do SketchUp 2025 (normal, rugosidade, metálico,
# oclusão): uma parede com textura + mapas (normal no padrão DirectX) e uma
# chapa só-cor com mapas de rugosidade e metálico (sem imagem de cor).
#   ruby cena_pbr.rb <pasta_de_saida>        (usado por teste_pbr.rb e tests/headless_pbr.py)
require 'zlib'
require 'fileutils'
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'

M = 1.0 / 0.0254 unless defined?(M)
def mi(*v) = v.map { |x| x * M } unless defined?(mi)

# PNG RGB w x h; bloco(x, y) -> [r, g, b]
def png_px(path, w, h, &bloco)
  raw = (0...h).map { |y| "\x00".b + (0...w).map { |x| bloco.call(x, y).pack('C*') }.join }.join
  ch = ->(t, d) { [d.bytesize].pack('N') + t + d + [Zlib.crc32(t + d)].pack('N') }
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b + ch.call('IHDR', [w, h, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
                      ch.call('IDAT', Zlib::Deflate.deflate(raw)) + ch.call('IEND', ''))
  path
end

def cena_pbr(out)
  FileUtils.mkdir_p(out)
  src = File.join(File.dirname(File.expand_path(out)), 'pbr_src')
  FileUtils.mkdir_p(src)
  cor = png_px(File.join(src, 'cor.png'), 32, 32) { |x, y| ((x / 8 + y / 8).even? ? [200, 190, 170] : [170, 160, 140]) }
  # normal: ondas em X (o canal vermelho varia), azul alto = superfície para fora
  normal = png_px(File.join(src, 'normal.png'), 32, 32) { |x, _y| [128 + (90 * Math.sin(x * Math::PI / 4)).round, 128, 230] }
  rugo = png_px(File.join(src, 'rugo.png'), 32, 32) { |x, _y| x < 16 ? [40, 40, 40] : [230, 230, 230] }
  metal = png_px(File.join(src, 'metal.png'), 32, 32) { |_x, y| y < 16 ? [255, 255, 255] : [0, 0, 0] }
  ao = png_px(File.join(src, 'ao.png'), 32, 32) { |x, y| (x % 8).zero? || (y % 8).zero? ? [60, 60, 60] : [255, 255, 255] }
  t = ->(p) { Sketchup::Texture.new(p, 0.5 * M, 0.5 * M) }

  cam = Sketchup::Camera.new(mi(1.0, -2.6, 1.0), mi(1.0, 0, 0.8), 50.0)
  m = Sketchup::Model.new('PBR', cam, Geom::Vector3d.new(0.4, -0.7, 0.6),
                          Geom::BoundingBox.new(mi(-0.2, -0.2, -0.05), mi(2.2, 0.5, 2)))
  parede = Sketchup::Material.new('Revestimento PBR', [255, 255, 255], texture: t.call(cor))
  parede.com_pbr(normal: t.call(normal), roughness: t.call(rugo), metallic: t.call(metal), ao: t.call(ao),
                 roughness_factor: 0.8, metallic_factor: 0.5, normal_scale: 1.5, ao_strength: 0.7, directx: true)
  chapa = Sketchup::Material.new('Chapa metálica', [150, 150, 155])
  chapa.com_pbr(roughness: t.call(rugo), metallic: t.call(metal), roughness_factor: 0.6, metallic_factor: 1.0)
  classico = Sketchup::Material.new('Pintura comum', [230, 225, 215])

  d = Sketchup::ComponentDefinition.new('Parede')
  f = d.entities.add_face([mi(0, 0, 0), mi(1, 0, 0), mi(1, 0, 1.6), mi(0, 0, 1.6)])
  f.material = parede
  f.uv_front = [[0, 0], [2, 0], [2, 3.2], [0, 3.2]]         # mesma escala do ladrilho (0,5 m)
  m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: 'Parede')
  d2 = Sketchup::ComponentDefinition.new('Chapa')
  d2.entities.add_face([mi(1.1, 0, 0), mi(2, 0, 0), mi(2, 0, 1.6), mi(1.1, 0, 1.6)]).material = chapa
  m.entities << Sketchup::ComponentInstance.new(d2, Geom::Transformation.new, name: 'Chapa')
  d3 = Sketchup::ComponentDefinition.new('Piso')
  d3.entities.add_face([mi(-0.2, -1, 0), mi(2.2, -1, 0), mi(2.2, 0.4, 0), mi(-0.2, 0.4, 0)]).material = classico
  m.entities << Sketchup::ComponentInstance.new(d3, Geom::Transformation.new, name: 'Piso')
  BlenditSU::Exporter.new(m, mode: 'realistic', engine: 'CYCLES', samples: 8, resolution: [200, 0]).export(out)
end

puts cena_pbr(ARGV[0] || 'bundle_pbr') if $PROGRAM_NAME == __FILE__
