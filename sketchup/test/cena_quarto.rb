# Câmera DENTRO da sala com janela de vidro - testa o visual de interior.
require_relative 'cena_vidro'
if __FILE__ == $PROGRAM_NAME
  m = build_vidro
  m.active_view.instance_variable_set(:@camera, Sketchup::Camera.new(mi(4.3, 0.5, 1.45), mi(1.2, 3.4, 0.9), 50.0))
  puts BlenditSU::Exporter.new(m, mode: 'realistic', resolution: [960, 0]).export(ARGV[0] || 'bundle_quarto')
end
