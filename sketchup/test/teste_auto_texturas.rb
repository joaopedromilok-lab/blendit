require_relative 'sketchup_fake'
module Sketchup; class << self; attr_accessor :status_text; end; end
require_relative 'cena_interior'
module UI; class HtmlDialog; STYLE_DIALOG=0; end; end
require_relative '../src/blendit_sketchup/texturas'
require_relative '../src/blendit_sketchup/auto_texturas'
m = build_interior
# um material genérico no piso e um genérico cor de madeira num armário
g = Sketchup::Material.new('Cor_M05', [120, 118, 115])
d = Sketchup::ComponentDefinition.new('Sofá 3 lugares'); caixa(d.entities, 0.3, 2.9, 0.1, 2.3, 3.8, 0.45); d.entities.each { |f| f.material = g }
m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new)
w = Sketchup::Material.new('[Color_A12]', [160, 115, 70])
a = Sketchup::ComponentDefinition.new('Armário'); caixa(a.entities, 4.0, 0.2, 0, 4.6, 1.0, 2.2); a.entities.each { |f| f.material = w }
m.entities << Sketchup::ComponentInstance.new(a, Geom::Transformation.new)
BlenditSU::AutoTexturas.analisar(m).each { |s| p s.slice('nome', 'rotulo', 'textura', 'cor') }
class Sketchup::Material
  def texture=(p); @texture = Struct.new(:path, :size).new(p, nil); end
  def color=(c); @color_set = c; end
  attr_accessor :colorize_type
end
class Sketchup::Model
  def materials_by_name = materials
end
mats = m.materials
def mats.[](n) = find { |x| x.name == n }
m.define_singleton_method(:materials) { mats }
m.define_singleton_method(:commit_operation) { true }
BlenditSU::Texturas.define_singleton_method(:fetch) { |e| ["/tmp/#{e[3]}.jpg", nil, [0.6, 0.6], "/tmp/#{e[3]}_r.jpg"] }
n = BlenditSU::AutoTexturas.aplicar(m, [{ 'material' => 'Cor_M05', 'textura' => 'rough_linen' }, { 'material' => '[Color_A12]', 'textura' => 'Wood049' }], true)
x = mats['Cor_M05']
puts "aplicados #{n}: #{x.texture.path} attrs=#{x.get_attribute('blendit', 'textura')} #{x.get_attribute('blendit', 'rugosidade_mapa')}"
