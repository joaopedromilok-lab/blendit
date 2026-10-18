# encoding: UTF-8
# Objetos de decoração: lista do Poly Haven, pacote glTF seguro, substituto ->
# modelo real no pacote (sem internet; API do SketchUp imitada).
#   ruby teste_objetos.rb        (código 1 se algo falhar)
require 'json'
require 'tmpdir'
require 'fileutils'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative 'cena_objetos'
require_relative '../src/blendit_sketchup/texturas'
require_relative '../src/blendit_sketchup/objetos'

$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end
OB = BlenditSU::Objetos
OB.define_singleton_method(:garantir) { |_id| raise 'sem rede no teste' }   # nada de internet aqui

puts '--- lista'
lista = OB.itens('potted_plant_01' => { 'name' => 'Potted Plant 01', 'type' => 2, 'categories' => ['decorative', 'plants', 'potted plants'], 'tags' => %w[plant pot] },
                 'book_set' => { 'name' => 'Book Set', 'type' => 2, 'categories' => ['decorative'], 'tags' => %w[book] },
                 'sky_x' => { 'name' => 'Sky', 'type' => 0 },
                 'bad id' => { 'name' => 'x', 'type' => 2 },
                 'sem_nome' => { 'type' => 2 })
confere('só modelos válidos (type 2, id e nome)', lista.map { |x| x['id'] }.sort == %w[book_set potted_plant_01])
confere('grupo em português', lista.find { |x| x['id'] == 'potted_plant_01' }['grupo'] == 'Plantas' &&
                              lista.find { |x| x['id'] == 'book_set' }['grupo'] == 'Decoração')
confere('miniatura do CDN do Poly Haven', lista.all? { |x| x['miniatura'].start_with?('https://cdn.polyhaven.com/') })

puts '--- pacote glTF'
files = { 'gltf' => {
  '1k' => { 'gltf' => { 'url' => 'https://dl.polyhaven.org/a/p_1k.gltf', 'include' => {
    'textures/p_diff_1k.jpg' => { 'url' => 'https://dl.polyhaven.org/a/p_diff_1k.jpg' },
    'p.bin' => { 'url' => 'https://dl.polyhaven.org/a/p.bin' },
    '../../fora.txt' => { 'url' => 'https://dl.polyhaven.org/x' },
    '/abs.bin' => { 'url' => 'https://dl.polyhaven.org/y' },
    'semurl.jpg' => { 'url' => 'http://inseguro' } } } },
  '4k' => { 'gltf' => { 'url' => 'https://dl.polyhaven.org/a/p_4k.gltf', 'include' => {} } } } }
pk = OB.arquivos_gltf(files)
confere('escolhe a versão 1K', pk[:url].end_with?('p_1k.gltf'))
confere('inclui texturas e .bin', pk[:include].keys.sort == ['p.bin', 'textures/p_diff_1k.jpg'], pk[:include].keys.inspect)
confere('recusa caminhos fora da pasta e links sem https', !pk[:include].key?('../../fora.txt') && !pk[:include].key?('/abs.bin') && !pk[:include].key?('semurl.jpg'))
confere('sem glTF = nil', OB.arquivos_gltf('blend' => {}).nil? && OB.arquivos_gltf(nil).nil?)
f2 = { 'gltf' => { '2k' => { 'gltf' => { 'url' => 'https://a/b_2k.gltf' } }, '4k' => { 'gltf' => { 'url' => 'https://a/b_4k.gltf' } } } }
confere('sem 1K usa a menor', OB.arquivos_gltf(f2)[:url].end_with?('_2k.gltf'))

puts '--- substituto -> modelo real no pacote'
tmp = Dir.mktmpdir('blendit_obj')
od = File.join(tmp, 'objetos')
FileUtils.mkdir_p(File.join(od, 'vaso_teste', 'textures'))
File.write(File.join(od, 'vaso_teste', 'vaso_teste.gltf'), '{}')
File.write(File.join(od, 'vaso_teste', 'vaso_teste.bin'), 'bin')
File.write(File.join(od, 'vaso_teste', 'textures', 't.jpg'), 'jpg')
File.write(File.join(od, 'vaso_teste', 'files.json'), '{}')
out = File.join(tmp, 'pacote')
spec = JSON.parse(File.read(cena_objetos(out, od)))
a = (spec['assets'] || [])[0]
confere('pacote tem 1 objeto (vaso_teste)', spec['assets'] && spec['assets'].length == 1 && a['id'] == 'vaso_teste', spec['assets'].inspect[0, 200])
confere('uri do glTF dentro do pacote', a && a['uri'] == 'assets/vaso_teste/vaso_teste.gltf' && File.file?(File.join(out, a['uri'])))
confere('.bin e texturas copiados; json de cache não', File.file?(File.join(out, 'assets/vaso_teste/vaso_teste.bin')) &&
        File.file?(File.join(out, 'assets/vaso_teste/textures/t.jpg')) && !File.exist?(File.join(out, 'assets/vaso_teste/files.json')))
mt = a && a['matrix']
confere('matriz por coluna com translação (2 m, 1 m, 0) e giro de 90°',
        mt && (mt[12] - 2 * M).abs < 1e-6 && (mt[13] - 1 * M).abs < 1e-6 && mt[2].abs < 1e-9 && mt[1].round(6) == 1.0, mt.inspect[0, 120])
confere('a geometria leve do substituto não vai para o render', spec['materials'].none? { |x| x['name'].start_with?('Blendit objeto') })
confere('o resto da cena continua', spec['materials'].any? { |x| x['name'] == 'Piso' })
out2 = File.join(tmp, 'sem')
spec2 = JSON.parse(File.read(cena_objetos(out2, File.join(tmp, 'vazio'))))
confere('objeto não baixado: fica de fora sem quebrar o render', spec2['assets'].nil? && spec2['materials'].any? { |x| x['name'] == 'Piso' })
FileUtils.rm_rf(tmp)
puts
puts "#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
