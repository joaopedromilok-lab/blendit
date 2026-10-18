# encoding: UTF-8
# Luminárias que brilham: lente / vidro / acrílico / lâmpada das luminárias
# reconhecidas viram material emissivo no pacote (só no render).
#   ruby teste_brilho.rb [pasta]      (código 1 se algo falhar)
require 'json'
require 'tmpdir'
require 'fileutils'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'

M = 1.0 / 0.0254 unless defined?(M)
def mi(*v) = v.map { |x| x * M } unless defined?(mi)
$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end

def caixa(ents, x0, y0, z0, x1, y1, z1, mat)
  [[mi(x0, y0, z0), mi(x0, y1, z0), mi(x1, y1, z0), mi(x1, y0, z0)],
   [mi(x0, y0, z1), mi(x1, y0, z1), mi(x1, y1, z1), mi(x0, y1, z1)],
   [mi(x0, y0, z0), mi(x1, y0, z0), mi(x1, y0, z1), mi(x0, y0, z1)],
   [mi(x1, y1, z0), mi(x0, y1, z0), mi(x0, y1, z1), mi(x1, y1, z1)],
   [mi(x0, y1, z0), mi(x0, y0, z0), mi(x0, y0, z1), mi(x0, y1, z1)],
   [mi(x1, y0, z0), mi(x1, y1, z0), mi(x1, y1, z1), mi(x1, y0, z1)]].each { |p| ents.add_face(p).material = mat }
end

def cena(noite: false, brilho_attr: nil)
  cam = Sketchup::Camera.new(mi(2, -2.5, 1.4), mi(2, 2, 1.6), 60.0)
  m = Sketchup::Model.new('Brilho', cam, Geom::Vector3d.new(0.3, -0.5, 0.8),
                          Geom::BoundingBox.new(mi(0, 0, 0), mi(4, 4, 2.8)))
  vidro = Sketchup::Material.new('Vidro leitoso', [240, 240, 235], alpha: 0.6)
  corpo = Sketchup::Material.new('Metal preto fosco', [20, 20, 20])
  lente = Sketchup::Material.new('Lente', [250, 250, 250])
  generico = Sketchup::Material.new('Color_A01', [245, 245, 245])
  tecido = Sketchup::Material.new('Tecido cinza', [150, 150, 150])
  piso = Sketchup::Material.new('Piso', [180, 170, 160])
  add = lambda do |nome, &blk|
    d = Sketchup::ComponentDefinition.new(nome)
    blk.call(d.entities)
    inst = Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: nome)
    m.entities << inst
    inst
  end
  add.call('Piso') { |e| e.add_face([mi(0, 0, 0), mi(4, 0, 0), mi(4, 4, 0), mi(0, 4, 0)]).material = piso }
  add.call('Pendente globo') do |e|
    caixa(e, 1.9, 1.9, 1.9, 2.1, 2.1, 2.0, corpo)
    caixa(e, 1.8, 1.8, 1.6, 2.2, 2.2, 1.9, vidro)
  end
  add.call('Spot embutido') { |e| caixa(e, 3.0, 3.0, 2.70, 3.1, 3.1, 2.75, corpo); caixa(e, 3.01, 3.01, 2.69, 3.09, 3.09, 2.70, lente) }
  pl = add.call('Plafon quarto') { |e| caixa(e, 0.8, 0.8, 2.7, 1.2, 1.2, 2.75, generico) }
  pl.set_attribute('blendit', 'brilho', brilho_attr) if brilho_attr
  add.call('Sofa light grey') { |e| caixa(e, 0.5, 3.0, 0, 2.5, 3.8, 0.8, tecido) }
  add.call('Arandela sala') { |e| caixa(e, 3.9, 1.0, 1.7, 4.0, 1.2, 1.9, vidro) }.set_attribute('blendit', 'brilho', 'nao')
  m
end

tmp = ARGV[0] ? File.expand_path(ARGV[0]).tap { |d| FileUtils.mkdir_p(d) } : Dir.mktmpdir('blendit_brilho')
exp = BlenditSU::Exporter.new(cena, mode: 'realistic', resolution: [200, 0])
spec = JSON.parse(File.read(exp.export(File.join(tmp, 'dia'))))
br = spec['materials'].select { |x| x['name'].end_with?('(brilho)') }
nomes = br.map { |x| x['name'] }
confere('vidro do pendente brilha', nomes.include?('Vidro leitoso (brilho)'), nomes.inspect)
confere('lente do spot brilha', nomes.include?('Lente (brilho)'))
confere('corpo de metal preto não brilha', nomes.none? { |n| n.start_with?('Metal') })
confere('material genérico do plafon não brilha (sem pista)', nomes.none? { |n| n.start_with?('Color_A01') })
confere('arandela com brilho=nao não brilha (mas acende)', spec['lights'].length >= 3 && br.length == 2, "luzes=#{spec['lights'].length}")
v = br.find { |x| x['name'].start_with?('Vidro') }
confere('brilho: cor quente (2700 K), força de dia, opaco, classe emissive',
        v && v['emissive'][0] > v['emissive'][2] && v['emissive_strength'] == 2.5 && v['transparency'] == 0.0 && v['appearance_class'] == 'emissive',
        v.inspect[0, 220])
confere('"Sofa light grey" não virou luminária', spec['lights'].none? { |l| l['position'][1] > 3.0 * M - 1 && l['position'][2] < 1.0 * M })
confere('tecido do sofá não brilha', nomes.none? { |n| n.start_with?('Tecido') })
spec_a = JSON.parse(File.read(BlenditSU::Exporter.new(cena, mode: 'realistic', materiais: 'automatico', resolution: [200, 0]).export(File.join(tmp, 'auto'))))
confere('no modo Automático o difusor aceso não ganha textura', spec_a['materials'].select { |x| x['emissive'] }.all? { |x| x['maps'].nil? })

spec2 = JSON.parse(File.read(BlenditSU::Exporter.new(cena(noite: true), mode: 'realistic', noite: true, resolution: [200, 0]).export(File.join(tmp, 'noite'))))
v2 = spec2['materials'].find { |x| x['name'] == 'Vidro leitoso (brilho)' }
confere('à noite o difusor brilha mais (6.0)', v2 && v2['emissive_strength'] == 6.0)
spec3 = JSON.parse(File.read(BlenditSU::Exporter.new(cena(brilho_attr: 'sim'), mode: 'realistic', resolution: [200, 0]).export(File.join(tmp, 'sim'))))
confere('brilho=sim faz brilhar a parte clara genérica do plafon', spec3['materials'].any? { |x| x['name'] == 'Color_A01 (brilho)' })
spec4 = JSON.parse(File.read(BlenditSU::Exporter.new(cena, mode: 'white', resolution: [200, 0], lights: false).export(File.join(tmp, 'sem'))))
confere('sem luminárias (estilos de desenho) nada brilha', spec4['materials'].none? { |x| x['emissive'] })
confere('cor por temperatura: 6500 K quase branco', BlenditSU::Exporter.kelvin_rgb(6500).all? { |c| c > 0.85 })
FileUtils.rm_rf(tmp) unless ARGV[0]
puts
puts "#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
