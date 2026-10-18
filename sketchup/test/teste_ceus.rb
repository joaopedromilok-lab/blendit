# encoding: UTF-8
# Céus com paisagem: lista, resolução e o pacote (API do SketchUp imitada).
#   ruby teste_ceus.rb        (código 1 se algo falhar)
require 'json'
require 'tmpdir'
require 'fileutils'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'
require_relative '../src/blendit_sketchup/ceus'

$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end
M = 1.0 / 0.0254
C = BlenditSU::Ceus
pais = C::LISTA.select { |_k, c| c[:paisagem] }
confere('3 céus com paisagem (cidade, bairro, jardim)', pais.keys.sort == %w[bairro cidade jardim])
confere('paisagem baixa em 4K, céus limpos continuam 2K', C.resolucao(C::LISTA['cidade']) == '4k' && C.resolucao(C::LISTA['limpo']) == '2k')
confere('arquivo por resolução', C.arquivo('canary_wharf', '4k').end_with?('canary_wharf_4k.hdr') && C.arquivo('x').end_with?('x_2k.hdr'))
confere('céus antigos sem mudança', C::LISTA['limpo'][:id] == 'qwantani_noon_puresky' && C::LISTA['nublado'][:ceu] == 4.5)

tmp = Dir.mktmpdir('blendit_ceus')
hdr = File.join(tmp, 'canary_wharf_4k.hdr')
File.binwrite(hdr, '#?RADIANCE' + "\x00" * 200_000)
cam = Sketchup::Camera.new([0, -3 * M, 1.5 * M], [0, 0, 1.5 * M], 50.0)
mk = lambda do
  m = Sketchup::Model.new('Ceu', cam, Geom::Vector3d.new(0.3, -0.5, 0.8), Geom::BoundingBox.new([-M, -M, 0], [M, M, 2 * M]))
  d = Sketchup::ComponentDefinition.new('Parede')
  d.entities.add_face([[-M, 0, 0], [M, 0, 0], [M, 0, 2 * M], [-M, 0, 2 * M]]).material = Sketchup::Material.new('Parede', [220, 220, 220])
  m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: 'Parede')
  m
end
w = JSON.parse(File.read(BlenditSU::Exporter.new(mk.call, mode: 'realistic', ceu: { path: hdr, ceu: 2.2, sol: 0.9, paisagem: true })
                                    .export(File.join(tmp, 'a'))))['world']
confere('pacote: HDRI com paisagem marca hdri_ground', w['sky_type'] == 'hdri' && w['hdri_ground'] == true && w['hdri_strength'] == 2.2)
confere('pacote: o .hdr foi copiado', File.file?(File.join(tmp, 'a', w['hdri_uri'])))
w2 = JSON.parse(File.read(BlenditSU::Exporter.new(mk.call, mode: 'realistic', ceu: { path: hdr, ceu: 1.5, sol: 1.6 })
                                     .export(File.join(tmp, 'b'))))['world']
confere('céu sem paisagem não marca hdri_ground', w2['sky_type'] == 'hdri' && !w2.key?('hdri_ground'))
FileUtils.rm_rf(tmp)
puts
puts "#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
