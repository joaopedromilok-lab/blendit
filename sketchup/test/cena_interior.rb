# Ambiente interno "de SketchUp" com plano de corte ativo e luminárias.
# Uso: ruby cena_interior.rb <pasta_saida> [inverter]
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter' unless defined?(BlenditSU::Exporter)

M = 39.3700787 unless defined?(M)
def mi(*v) = v.map { |x| x * M }

def caixa(ents, x0, y0, z0, x1, y1, z1)
  a = mi(x0, y0, z0); b = mi(x1, y1, z1)
  x0, y0, z0 = a; x1, y1, z1 = b
  [ents.add_face([[x0, y0, z0], [x0, y1, z0], [x1, y1, z0], [x1, y0, z0]]),
   ents.add_face([[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]]),
   ents.add_face([[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]]),
   ents.add_face([[x1, y1, z0], [x0, y1, z0], [x0, y1, z1], [x1, y1, z1]]),
   ents.add_face([[x0, y1, z0], [x0, y0, z0], [x0, y0, z1], [x0, y1, z1]]),
   ents.add_face([[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]])]
end

def grupo(model, nome, mat, tr = Geom::Transformation.new)
  d = Sketchup::ComponentDefinition.new(nome)
  yield d.entities
  g = Sketchup::Group.new(d, tr, name: nome)
  g.material = mat
  model.entities << g
  g
end

def build_interior(flip: false)
  sun = Geom::Vector3d.new(0.4, -0.5, 0.75)
  cam = Sketchup::Camera.new(mi(2.5, -3.2, 1.5), mi(2.5, 3.0, 1.25), 45.0)
  model = Sketchup::Model.new('Sala Teste', cam, sun, Geom::BoundingBox.new(mi(-0.2, -0.2, -0.2), mi(5.2, 4.2, 3.0)))

  parede = Sketchup::Material.new('Pintura acrílica branca', [236, 233, 226])
  piso = Sketchup::Material.new('Porcelanato acetinado bege', [200, 188, 170])
  laje = Sketchup::Material.new('Gesso liso', [245, 245, 242])
  madeira = Sketchup::Material.new('Madeira freijó', [170, 125, 80])
  metal = Sketchup::Material.new('Metal preto', [25, 25, 25])
  tecido = Sketchup::Material.new('Tecido linho cinza', [130, 128, 122])

  grupo(model, 'Piso', piso) { |e| caixa(e, -0.15, -0.15, -0.15, 5.15, 4.15, 0) }
  grupo(model, 'Forro', laje) { |e| caixa(e, -0.15, -0.15, 2.8, 5.15, 4.15, 2.95) }
  grupo(model, 'Paredes', parede) do |e|
    caixa(e, -0.15, -0.15, 0, 5.15, 0, 2.8)       # frente (vai sumir no corte)
    caixa(e, -0.15, 4.0, 0, 5.15, 4.15, 2.8)      # fundo
    caixa(e, -0.15, 0, 0, 0, 4.0, 2.8)            # esquerda
    caixa(e, 5.0, 0, 0, 5.15, 4.0, 2.8)           # direita
  end
  grupo(model, 'Mesa jantar', madeira) do |e|
    caixa(e, 1.6, 2.0, 0.72, 3.4, 3.0, 0.76)
    [[1.7, 2.1], [3.25, 2.1], [1.7, 2.85], [3.25, 2.85]].each { |x, y| caixa(e, x, y, 0, x + 0.05, y + 0.05, 0.72) }
  end
  grupo(model, 'Sofá', tecido) { |e| caixa(e, 0.2, 0.6, 0, 0.95, 2.6, 0.45); caixa(e, 0.2, 0.6, 0.45, 0.4, 2.6, 0.85) }

  # Spots embutidos no forro (componente repetido)
  spot = Sketchup::ComponentDefinition.new('Spot embutido quadrado AR70')
  caixa(spot.entities, -0.05, -0.05, -0.02, 0.05, 0.05, 0)
  [[1.0, 1.4], [4.0, 1.4], [1.0, 3.4], [4.0, 3.4], [2.5, 1.4], [0.6, 3.4]].each do |x, y|
    i = Sketchup::ComponentInstance.new(spot, Geom::Transformation.translation(*mi(x, y, 2.8)))
    i.material = metal
    model.entities << i
  end
  # Pendente sobre a mesa
  pend = Sketchup::ComponentDefinition.new('Pendente cúpula')
  caixa(pend.entities, -0.18, -0.18, -0.25, 0.18, 0.18, 0)
  caixa(pend.entities, -0.005, -0.005, 0, 0.005, 0.005, 1.2)
  pi_ = Sketchup::ComponentInstance.new(pend, Geom::Transformation.translation(*mi(2.5, 2.5, 1.6)))
  pi_.material = metal
  model.entities << pi_
  # Uma luminária desligada pelo atributo
  apagada = Sketchup::ComponentInstance.new(spot, Geom::Transformation.translation(*mi(4.5, 3.8, 2.8)))
  apagada.set_attribute('blendit', 'luz', 'nao')
  model.entities << apagada

  # Corte em y = 1,0 m; a seta (+Y) aponta para o que fica
  model.entities.active_section_plane = Sketchup::SectionPlane.new([0, 1, 0, -1.0 * M])
  model
end

if __FILE__ == $PROGRAM_NAME
  model = build_interior
  exp = BlenditSU::Exporter.new(model, mode: 'realistic', engine: 'EEVEE', samples: 32,
                                       resolution: [1280, 0], flip_section: ARGV[1] == 'inverter', noite: ARGV[1] == 'noite')
  spec = exp.export(ARGV[0] || 'bundle_interior')
  puts "faces: #{exp.faces}  luzes: #{exp.lights.length}  corte: #{exp.section_used}"
  puts spec
end
