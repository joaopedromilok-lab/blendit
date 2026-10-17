# Sala vista de fora por uma janela de vidro (sem corte) - testa se o interior aparece.
require_relative 'cena_interior'
def build_vidro
  m = build_interior
  m.entities.active_section_plane = nil
  # tira a parede da frente e põe uma vidraça + caixilho
  paredes = m.entities.find { |e| e.respond_to?(:name) && e.name == 'Paredes' }
  ents = Sketchup::Entities.new
  paredes.definition.entities.each_with_index { |f, i| ents << f unless i < 6 }
  paredes.definition.instance_variable_set(:@entities, ents)
  vidro = Sketchup::Material.new('Vidro', [180, 210, 220], alpha: 0.3)
  esq = Sketchup::Material.new('Pintura acrílica branca', [236, 233, 226])
  grupo(m, 'Muro frontal', esq) do |e|
    caixa(e, -0.15, -0.15, 0, 0.6, 0, 2.8); caixa(e, 4.4, -0.15, 0, 5.15, 0, 2.8)
    caixa(e, 0.6, -0.15, 0, 4.4, 0, 0.5); caixa(e, 0.6, -0.15, 2.4, 4.4, 0, 2.8)
  end
  jan = Sketchup::ComponentDefinition.new('Janela vidro')
  jan.entities.add_face(mi(0.6, -0.08, 0.5).zip.flatten.then { [mi(0.6, -0.08, 0.5), mi(4.4, -0.08, 0.5), mi(4.4, -0.08, 2.4), mi(0.6, -0.08, 2.4)] }).material = vidro
  m.entities << Sketchup::ComponentInstance.new(jan, Geom::Transformation.new)
  m.active_view.instance_variable_set(:@camera, Sketchup::Camera.new(mi(2.5, -6.5, 1.6), mi(2.5, 2.0, 1.2), 40.0))
  m
end
if __FILE__ == $PROGRAM_NAME
  exp = BlenditSU::Exporter.new(build_vidro, mode: 'realistic', resolution: [960, 0])
  puts exp.export(ARGV[0] || 'bundle_vidro')
end
