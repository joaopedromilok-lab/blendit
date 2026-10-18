# encoding: UTF-8
# Catálogo online na galeria + candidatos extras do modo Automático
# (catálogo online e Minhas texturas). Sem internet: downloads simulados.
#   ruby teste_catalogo_galeria.rb       (código 1 se algo falhar)
require 'json'
require 'tmpdir'
require 'fileutils'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'
require_relative '../src/blendit_sketchup/texturas'
require_relative '../src/blendit_sketchup/catalogo_online'

$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end

BM = BlenditSU::BibliotecaMateriais
TX = BlenditSU::Texturas
CO = BlenditSU::CatalogoOnline
TMP = Dir.mktmpdir('blendit_galeria')
ENV['LOCALAPPDATA'] = File.join(TMP, 'local')
ENV['APPDATA'] = File.join(TMP, 'roaming')

# ------------------------------------------------------------------ tipo dos itens
puts '--- tipo / categoria dos itens do catálogo'
casos = [
  [{ 'fonte' => 'ambientcg', 'categoria' => 'WoodFloor', 'nome' => 'Wood Floor 090' }, 'piso_madeira'],
  [{ 'fonte' => 'ambientcg', 'categoria' => 'Marble', 'nome' => 'Marble 030' }, 'bancada'],
  [{ 'fonte' => 'ambientcg', 'categoria' => 'Tiles', 'nome' => 'Tiles 150' }, 'piso'],
  [{ 'fonte' => 'ambientcg', 'categoria' => 'Fabric', 'nome' => 'Fabric 090' }, 'tecido'],
  [{ 'fonte' => 'ambientcg', 'categoria' => 'Metal', 'nome' => 'Metal 050' }, nil],
  [{ 'fonte' => 'ambientcg', 'categoria' => 'Gravel', 'nome' => 'Gravel 030' }, nil],
  [{ 'fonte' => 'polyhaven', 'id' => 'walnut_floor', 'nome' => 'Walnut Floor', 'categorias' => %w[wood floor indoor] }, 'piso_madeira'],
  [{ 'fonte' => 'polyhaven', 'id' => 'teak_veneer', 'nome' => 'Teak Veneer', 'categorias' => %w[wood man\ made] }, 'madeira'],
  [{ 'fonte' => 'polyhaven', 'id' => 'calacatta_marble', 'nome' => 'Calacatta Marble', 'categorias' => %w[rock floor] }, 'bancada'],
  [{ 'fonte' => 'polyhaven', 'id' => 'green_velvet', 'nome' => 'Green Velvet', 'categorias' => %w[fabric velvet] }, 'tecido'],
  [{ 'fonte' => 'polyhaven', 'id' => 'tan_leather', 'nome' => 'Tan Leather', 'categorias' => %w[fabric leather] }, 'couro'],
  [{ 'fonte' => 'polyhaven', 'id' => 'forest_ground', 'nome' => 'Forest Ground', 'categorias' => %w[terrain outdoor] }, nil]
]
casos.each do |it, cat|
  tipo, c = BM.classificar_item(it)
  confere("#{it['nome']} -> #{cat.inspect}", c == cat, "#{tipo} / #{c.inspect}")
end
confere('Minha textura "Calacata Oro 90x90" é bancada', BM.categoria_minha('nome' => 'Mármore Calacata Oro') == 'bancada')
confere('Minha textura "Freijó Puro" é madeira', BM.categoria_minha('nome' => 'Freijó Puro', 'fabricante' => 'Duratex') == 'madeira')
confere('Minha textura sem pista fica sem categoria', BM.categoria_minha('nome' => 'XPTO 123').nil?)
confere('tamanho ACG estimado pelo tipo', BM.tamanho_acg('Marble') == 2.0 && BM.tamanho_acg('Fabric') == 0.5 && BM.tamanho_acg('?') == 1.0)

# ------------------------------------------------------------------ ordem com extras
puts '--- ordem das sugestões (fixas x extras)'
nomes = TX::CATALOGO.to_h { |e| [e[3], e[1]] }
rgb = [200, 200, 200]
['Mármore branco', 'Cor_M05', 'Granito bege'].each do |n|
  confere("sem extras = ordem antiga (#{n})", BM.ordenar_com_extras('bancada', rgb, n, nomes, {}, []) == BM.ordenar('bancada', rgb, n, nomes, {}))
end
online = [{ 'chave' => 'ph:calacatta_marble', 'nome' => 'Calacatta Marble', 'tags' => %w[marble white] },
          { 'chave' => 'acg:Onyx010', 'nome' => 'Onyx 010', 'tags' => %w[onyx] }]
r = BM.ordenar_com_extras('bancada', rgb, 'Cor_M05', nomes, {}, online)
confere('extra sem casar o nome não passa na frente', r.first == BM.ordenar('bancada', rgb, 'Cor_M05', nomes, {}).first, r.first(3).inspect)
confere('extras sem casar ficam no fim', r.last(2).sort == %w[acg:Onyx010 ph:calacatta_marble])
r = BM.ordenar_com_extras('bancada', rgb, 'Mármore Calacatta', nomes, {}, online)
confere('nome "Calacatta" escolhe o item online Calacatta', r.first == 'ph:calacatta_marble', r.first(3).inspect)
r = BM.ordenar_com_extras('bancada', rgb, 'Ônix iluminado', nomes, {}, online)
confere('"Ônix" (pt) casa com "Onyx" (en)', r.first == 'acg:Onyx010', r.first(2).inspect)
r = BM.ordenar_com_extras('bancada', [210, 195, 170], 'Travertino Romano', nomes, {}, online)
confere('fixa com nome igual (Travertino) continua na frente do online', r.first == 'Travertine009', r.first(2).inspect)
minha = online + [{ 'chave' => 'minha:portobello__travertino', 'nome' => 'Travertino Romano', 'tags' => ['Portobello'], 'minha' => true }]
r = BM.ordenar_com_extras('bancada', [210, 195, 170], 'Travertino Romano', nomes, {}, minha)
confere('Minha textura com o mesmo nome vem antes de tudo', r.first == 'minha:portobello__travertino', r.first(2).inspect)
r = BM.ordenar_com_extras('bancada', rgb, 'Travertino Romano', nomes, { 'preferidas' => { 'bancada' => 'acg:Onyx010' } }, minha)
confere('preferida nas regras ainda manda', r.first == 'acg:Onyx010')
ex = BM.extras([{ 'chave' => 'acg:Marble030', 'nome' => 'Marble 030', 'categoria_auto' => 'bancada' },
                { 'chave' => 'acg:Metal01', 'nome' => 'Metal 01', 'categoria_auto' => nil }],
               [{ 'id' => 'x1', 'nome' => 'Carvalho Hanover', 'fabricante' => 'Guararapes' }])
confere('extras: online por categoria, metal sem textura fica fora', ex['bancada'].map { |x| x['chave'] } == ['acg:Marble030'] && !ex.key?(nil))
confere('extras: Minha textura de madeira entra em madeira', ex['madeira'] && ex['madeira'].first['chave'] == 'minha:x1')
ex2 = BM.extras([{ 'chave' => 'acg:Marble030', 'nome' => 'Marble 030', 'categoria_auto' => 'bancada' }],
                [{ 'id' => 'x1', 'nome' => 'Carvalho Hanover' }], 'catalogo_online' => false, 'minhas_texturas' => false)
confere('regras desligam as duas fontes', ex2.empty?)

# ------------------------------------------------------------------ catálogo em cache + resolver
puts '--- resolver chaves (sem internet)'
cache = { 'formato' => CO::FORMATO, 'atualizado_em' => '2026-10-18T00:00:00Z', 'fontes' => {
  'polyhaven' => { 'ok' => true, 'itens' => [
    CO.item('polyhaven', 'calacatta_marble', 'nome' => 'Calacatta Marble', 'categorias' => %w[rock floor], 'tags' => %w[marble],
                                               'miniatura' => 'https://cdn.polyhaven.com/asset_img/thumbs/calacatta_marble.png'),
    CO.item('polyhaven', 'oak_veneer_01', 'nome' => 'Oak Veneer 01', 'categorias' => %w[wood], 'tags' => [], 'miniatura' => 'https://x/y.png')
  ] },
  'ambientcg' => { 'ok' => true, 'itens' => [
    CO.item('ambientcg', 'Onyx010', 'nome' => 'Onyx 010', 'categoria' => 'Onyx', 'tags' => %w[onyx], 'miniatura' => 'https://x/o.png'),
    CO.item('ambientcg', 'Fabric090', 'nome' => 'Fabric 090', 'categoria' => 'Fabric', 'tags' => [], 'miniatura' => 'https://x/f.png')
  ] }
} }
CO.gravar_atomico(CO.arquivo, JSON.generate(cache))
novos = CO.novos
confere('novos = só fora da biblioteca fixa (oak_veneer_01 já é legado)', novos.map { |x| x['chave'] }.sort == %w[acg:Fabric090 acg:Onyx010 ph:calacatta_marble], novos.map { |x| x['chave'] }.inspect)
confere('novos têm tipo em português', novos.find { |x| x['id'] == 'Onyx010' }['tipo'] == 'Mármores e pedras')
r = TX.resolver('ph:calacatta_marble')
confere('resolver ph:', r && r['nome'] == 'Calacatta Marble' && r['categoria'] == 'bancada' && r['rugosidade'] == 0.15, r.inspect)
r = TX.resolver('ph:oak_veneer_01')
confere('resolver ph: de item da biblioteca usa o nome em português', r && r['nome'] == 'Lâmina de carvalho' && r['chave'] == 'oak_veneer_01')
confere('resolver chave antiga (Marble012)', TX.resolver('Marble012')['nome'].start_with?('Mármore Carrara'))
confere('resolver chave desconhecida = nil', TX.resolver('ph:nao_existe').nil? && TX.resolver('xx:1').nil?)

baixados = []
IMG = File.join(TMP, 'img.jpg').tap { |p| File.binwrite(p, 'jpg') }
TX.define_singleton_method(:fetch_ph) { |id| baixados << [:ph, id]; [IMG, nil, [1.5, 1.5], nil] }
TX.define_singleton_method(:fetch_acg) { |id, s| baixados << [:acg, id, s]; [IMG, nil, [s, s], nil] }
TX.fetch_chave('ph:calacatta_marble')
TX.fetch_chave('acg:Onyx010')
TX.fetch_chave('acg:Fabric090')
confere('fetch_chave usa a fonte certa e o tamanho estimado do ambientCG',
        baixados == [[:ph, 'calacatta_marble'], [:acg, 'Onyx010', 2.0], [:acg, 'Fabric090', 0.5]], baixados.inspect)
FileUtils.mkdir_p(TX.meu_dir)
File.binwrite(File.join(TX.meu_dir, 'm1.jpg'), 'x')
TX.salvar_minhas([{ 'id' => 'm1', 'nome' => 'Travertino Romano', 'fabricante' => 'Portobello', 'largura_cm' => 120,
                    'altura_cm' => 60, 'acabamento' => 'Polido / brilhante', 'arquivo' => 'm1.jpg' }])
f = TX.fetch_chave('minha:m1')
confere('fetch_chave minha: usa a imagem e o tamanho dela', f[0].end_with?('m1.jpg') && f[2] == [1.2, 0.6], f.inspect)
r = TX.resolver('minha:m1')
confere('resolver minha:', r['categoria'] == 'bancada' && r['rugosidade'] == TX::POLIDO)
ex = TX.extras_auto
confere('extras_auto junta catálogo + Minhas texturas', ex['bancada'].map { |x| x['chave'] }.sort == %w[acg:Onyx010 minha:m1 ph:calacatta_marble], ex['bancada'].inspect)

# ------------------------------------------------------------------ exportador no modo Automático
puts '--- exportador: Automático escolhe o item online pelo nome'
I = 1.0 / 0.0254
cam = Sketchup::Camera.new([1 * I, -3 * I, 1.5 * I], [1 * I, 0.5 * I, 0], 50.0)
model = Sketchup::Model.new('Galeria', cam, Geom::Vector3d.new(0.3, -0.5, 0.8),
                            Geom::BoundingBox.new([-0.1 * I, -0.1 * I, -0.05 * I], [2.1 * I, 1.1 * I, 1 * I]))
m = Sketchup::Material.new('Mármore Calacatta', [230, 230, 228])
d = Sketchup::ComponentDefinition.new('Bancada')
d.entities.add_face([[0, 0, 0.9 * I], [2 * I, 0, 0.9 * I], [2 * I, 1 * I, 0.9 * I], [0, 1 * I, 0.9 * I]]).material = m
model.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: 'Bancada')
out = File.join(TMP, 'pacote')
spec_path = BlenditSU::Exporter.new(model, mode: 'realistic', materiais: 'automatico').export(out)
spec = JSON.parse(File.read(spec_path))
rec = spec['materials'].find { |x| x['name'] == 'Mármore Calacatta' }
confere('material ganhou textura automática', rec && rec['maps'] && rec['maps']['diffuse']['auto'] == true, rec.inspect[0, 200])
confere('a textura escolhida foi a do catálogo online (ph:calacatta_marble)', rec && rec['auto'] && rec['auto']['textura'] == 'ph:calacatta_marble', rec && rec['auto'].inspect)

# ------------------------------------------------------------------ galeria (HTML)
puts '--- galeria'
html = TX.html
confere('galeria tem a aba Catálogo online', html.include?('id="t3"') && html.include?('mostrarOnline'))
js = html[/<script>(.*)<\/script>/m, 1]
File.write(File.join(TMP, 'g.js'), "var document={getElementById:function(){return {classList:{toggle:function(){}},style:{}}}},window={addEventListener:function(){}};\n#{js}")
if system('node', '--check', File.join(TMP, 'g.js'), out: File::NULL, err: File::NULL).nil?
  puts '(node não instalado: sintaxe do JavaScript não conferida)'
else
  confere('JavaScript da galeria é válido', system('node', '--check', File.join(TMP, 'g.js')))
end
class DlgFake
  attr_reader :js
  def execute_script(s) = (@js ||= []) << s
end
d = DlgFake.new
TX.enviar_online(d)
lista = JSON.parse(d.js.last[/mostrarOnline\((.*)\)\z/m, 1])
confere('galeria recebe os itens novos com tipo, fonte e miniatura', lista.length == 3 && lista.all? { |x| x.length == 5 && x[4].start_with?('https://') }, lista.inspect[0, 200])

FileUtils.rm_rf(TMP)
puts
puts "#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
