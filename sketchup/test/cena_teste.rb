# Monta uma casinha "de SketchUp" (com a API imitada) e exporta com o exportador
# REAL do plugin. Uso: ruby cena_teste.rb <pasta_saida> <textura.png>
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter' unless defined?(BlenditSU::Exporter)

M = 39.3700787 # polegadas por metro
def m(*v) = v.map { |x| x * M }


def box(ents, x0, y0, z0, x1, y1, z1, skip_bottom: false)
  a = m(x0, y0, z0); b = m(x1, y1, z1)
  x0, y0, z0 = a; x1, y1, z1 = b
  faces = []
  faces << ents.add_face([[x0, y0, z0], [x0, y1, z0], [x1, y1, z0], [x1, y0, z0]]) unless skip_bottom
  faces << ents.add_face([[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]])
  faces << ents.add_face([[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]])
  faces << ents.add_face([[x1, y1, z0], [x0, y1, z0], [x0, y1, z1], [x1, y1, z1]])
  faces << ents.add_face([[x0, y1, z0], [x0, y0, z0], [x0, y0, z1], [x0, y1, z1]])
  faces << ents.add_face([[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]])
  faces
end

def build_model(tex_png)
sun = Geom::Vector3d.new(*[300, 35].then do |az, alt|
  a = az * Math::PI / 180; h = alt * Math::PI / 180
  [Math.sin(a) * Math.cos(h), Math.cos(a) * Math.cos(h), Math.sin(h)]
end)
cam = Sketchup::Camera.new(m(-9, -11, 5.5), m(4, 3, 1.4), 35.0)
model = Sketchup::Model.new('Casa Teste', cam, sun, Geom::BoundingBox.new(m(-10, -10, 0), m(10, 10, 4)))

grama = Sketchup::Material.new('Grama', [96, 140, 70])
tijolo = Sketchup::Material.new('Tijolo aparente', [170, 92, 66])
reboco = Sketchup::Material.new('Reboco branco', [238, 236, 228])
vidro = Sketchup::Material.new('Vidro', [180, 210, 220], alpha: 0.35)
concreto = Sketchup::Material.new('Concreto', [150, 150, 145])
telha = Sketchup::Material.new('Telha cerâmica', [160, 80, 50],
                               texture: tex_png && Sketchup::Texture.new(tex_png, 0.6 * M, 0.6 * M))
madeira = Sketchup::Material.new('Madeira deck', [140, 100, 60])

# Terreno próprio (grupo)
terreno = Sketchup::ComponentDefinition.new('Terreno')
terreno.entities.add_face([m(-10, -10, 0), m(10, -10, 0), m(10, 10, 0), m(-10, 10, 0)]).material = grama
model.entities << Sketchup::Group.new(terreno, Geom::Transformation.new, name: 'Terreno')

# Casa: paredes herdam o material do GRUPO (faces sem pintura)
casa = Sketchup::ComponentDefinition.new('Casa')
box(casa.entities, 0, 0, 0, 8, 6, 3, skip_bottom: true)
g_casa = Sketchup::Group.new(casa, Geom::Transformation.new, name: 'Casa')
g_casa.material = tijolo
model.entities << g_casa

# Uma parede rebocada, pintada direto na face, dentro de um grupo rotacionado e deslocado
anexo = Sketchup::ComponentDefinition.new('Anexo')
box(anexo.entities, 0, 0, 0, 3, 3, 2.6).each { |f| f.material = reboco }
model.entities << Sketchup::Group.new(anexo, Geom::Transformation.translation(*m(8, 1.5, 0)) *
                                             Geom::Transformation.rotation_z(0), name: 'Anexo')

# Laje/telhado com textura
laje = Sketchup::ComponentDefinition.new('Telhado')
box(laje.entities, -0.4, -0.4, 3.0, 8.4, 6.4, 3.25).each { |f| f.material = telha }
model.entities << Sketchup::Group.new(laje, Geom::Transformation.new, name: 'Telhado')

# Janela como COMPONENTE, duas cópias - uma ESPELHADA (escala -1)
jan = Sketchup::ComponentDefinition.new('Janela 1.5x1.2')
jan.entities.add_face([m(0, 0, 0), m(1.5, 0, 0), m(1.5, 0, 1.2), m(0, 0, 1.2)]).material = vidro
model.entities << Sketchup::ComponentInstance.new(jan, Geom::Transformation.translation(*m(1, -0.02, 1)))
model.entities << Sketchup::ComponentInstance.new(
  jan, Geom::Transformation.translation(*m(7, -0.02, 1)) * Geom::Transformation.scaling(-1, 1, 1)
)

# Pilar cilíndrico com arestas SUAVIZADAS
pilar = Sketchup::ComponentDefinition.new('Pilar')
segs = 24; r = 0.18; hgt = 3.0
pts = (0...segs).map { |i| a = 2 * Math::PI * i / segs; [r * Math.cos(a), r * Math.sin(a)] }
side = []
segs.times do |i|
  a = pts[i]; b = pts[(i + 1) % segs]
  side << pilar.entities.add_face([m(a[0], a[1], 0), m(b[0], b[1], 0), m(b[0], b[1], hgt), m(a[0], a[1], hgt)])
end
pilar.entities.add_face(pts.map { |p| m(p[0], p[1], hgt) })
side.each { |f| f.material = concreto }
# arestas verticais entre faces laterais = suaves
side.each { |f| f.edges.each { |e| e.smooth = true if e.faces.length == 2 && e.faces.all? { |g| side.include?(g) } } }
[[-1.2, -1.2], [-1.2, 2.0]].each do |x, y|
  model.entities << Sketchup::ComponentInstance.new(pilar, Geom::Transformation.translation(*m(x, y, 0)))
end

# Deck de madeira
deck = Sketchup::ComponentDefinition.new('Deck')
box(deck.entities, -2.2, -2.2, 0, 0, 3.0, 0.12).each { |f| f.material = madeira }
model.entities << Sketchup::Group.new(deck, Geom::Transformation.new, name: 'Deck')

# Objeto numa TAG OCULTA - não pode aparecer
oculto = Sketchup::ComponentDefinition.new('Oculto')
box(oculto.entities, 2, -5, 0, 4, -3, 2).each { |f| f.material = vidro }
g_oc = Sketchup::Group.new(oculto, Geom::Transformation.new, name: 'Não deve aparecer')
g_oc.layer = Sketchup::Layer.new('Mobiliário (oculto)', false)
model.entities << g_oc

# Objeto OCULTO direto - também não
g_h = Sketchup::Group.new(oculto, Geom::Transformation.translation(*m(-6, 0, 0)))
g_h.hidden = true
model.entities << g_h

model
end

if __FILE__ == $PROGRAM_NAME
out = ARGV[0] || 'bundle_teste'
model = build_model(ARGV[1])
exp = BlenditSU::Exporter.new(model, mode: 'realistic', engine: 'EEVEE', samples: 32,
                                     resolution: [1280, 0], denoise: true)
spec = exp.export(out)
puts "faces exportadas: #{exp.faces}"
puts "spec: #{spec}"
end
