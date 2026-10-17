# encoding: UTF-8
# Cena de teste das UVs para o lado Blender (tests/headless_uvs.py):
# uma TV com uma imagem metade vermelha / metade azul esticada na tela (como a
# arquiteta faz com "Posição da textura") e um piso com ladrilho em escala real.
#   ruby cena_uvs.rb <pasta_de_saida>
require 'zlib'
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'

M = 1.0 / 0.0254
def mi(*v) = v.map { |x| x * M } unless defined?(mi)

def png_metades(path, w = 64, h = 32)
  linha = "\x00".b + ([230, 20, 20].pack('C*') * (w / 2)) + ([20, 40, 230].pack('C*') * (w / 2))
  chunk = ->(t, d) { [d.bytesize].pack('N') + t + d + [Zlib.crc32(t + d)].pack('N') }
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', [w, h, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
                      chunk.call('IDAT', Zlib::Deflate.deflate(linha * h)) + chunk.call('IEND', ''))
  path
end

out = ARGV[0] || 'bundle_uvs'
FileUtils.mkdir_p(out)
img = png_metades(File.join(File.dirname(File.expand_path(out)), 'tv_metades.png'))
cam = Sketchup::Camera.new(mi(0.6, -2.2, 0.9), mi(0.6, 0, 0.9), 45.0)
m = Sketchup::Model.new('UV', cam, Geom::Vector3d.new(0.3, -0.6, 0.7),
                        Geom::BoundingBox.new(mi(-1, -1, -0.1), mi(2, 2, 2)))
tela = Sketchup::Material.new('Tela TV', [255, 255, 255], texture: Sketchup::Texture.new(img, 0.3 * M, 0.3 * M))
d = Sketchup::ComponentDefinition.new('TV')
f = d.entities.add_face([mi(0, 0, 0.55), mi(1.2, 0, 0.55), mi(1.2, 0, 1.25), mi(0, 0, 1.25)])
f.material = tela
f.uv_front = [[0, 0], [1, 0], [1, 1], [0, 1]]
m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: 'TV')
puts BlenditSU::Exporter.new(m, mode: 'realistic', engine: 'CYCLES', samples: 8,
                             resolution: [160, 0]).export(out)
