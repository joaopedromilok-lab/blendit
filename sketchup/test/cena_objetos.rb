# encoding: UTF-8
# Cena de teste dos objetos de decoração: um substituto (atributo blendit
# objeto_ph) girado 90° e deslocado, sobre um piso.
#   ruby cena_objetos.rb <pasta_de_saida> <pasta_dos_objetos>
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'

M = 1.0 / 0.0254 unless defined?(M)
def mi(*v) = v.map { |x| x * M } unless defined?(mi)

def cena_objetos(out, objetos_dir, modo = 'realistic')
  cam = Sketchup::Camera.new(mi(2, -2, 1.5), mi(2, 1, 0.4), 55.0)
  m = Sketchup::Model.new('Objetos', cam, Geom::Vector3d.new(0.3, -0.5, 0.8),
                          Geom::BoundingBox.new(mi(0, -0.5, 0), mi(4, 3, 1.5)))
  piso = Sketchup::ComponentDefinition.new('Piso')
  piso.entities.add_face([mi(0, -0.5, 0), mi(4, -0.5, 0), mi(4, 3, 0), mi(0, 3, 0)]).material =
    Sketchup::Material.new('Piso', [190, 180, 170])
  m.entities << Sketchup::ComponentInstance.new(piso, Geom::Transformation.new, name: 'Piso')
  # Substituto: caixa 0,8 x 0,3 x 1,0 m com a "foto" em pé (como Objetos.substituto)
  prox = Sketchup::ComponentDefinition.new('Blendit objeto - Vaso teste')
  prox.entities.add_face([mi(-0.4, 0, 0), mi(0.4, 0, 0), mi(0.4, 0, 1.0), mi(-0.4, 0, 1.0)]).material =
    Sketchup::Material.new('Blendit objeto - vaso_teste', [255, 255, 255])
  prox.set_attribute('blendit', 'objeto_ph', 'vaso_teste')
  prox.set_attribute('blendit', 'objeto_nome', 'Vaso teste')
  tr = Geom::Transformation.translation(*mi(2, 1, 0)) * Geom::Transformation.rotation_z(90)
  m.entities << Sketchup::ComponentInstance.new(prox, tr, name: '')
  BlenditSU::Exporter.new(m, mode: modo, engine: 'CYCLES', samples: 8, resolution: [200, 0],
                          objetos_dir: objetos_dir).export(out)
end

puts cena_objetos(ARGV[0] || 'bundle_objetos', ARGV[1] || 'objetos', ARGV[2] || 'realistic') if $PROGRAM_NAME == __FILE__
