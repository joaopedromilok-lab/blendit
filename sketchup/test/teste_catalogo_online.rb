# encoding: UTF-8
# Testes do catálogo online (Poly Haven + ambientCG) com respostas SIMULADAS -
# nenhum acesso à internet.      ruby teste_catalogo_online.rb
require 'json'
require 'tmpdir'
require 'fileutils'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative '../src/blendit_sketchup/texturas'
require_relative '../src/blendit_sketchup/catalogo_online'

CO = BlenditSU::CatalogoOnline
$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end

# ------------------------------------------------------------------ respostas simuladas
PH = {
  'oak_veneer_01' => { 'name' => 'Oak Veneer 01', 'type' => 1, 'categories' => %w[wood natural],
                       'category' => 'Wood/Veneer/Oak Veneer', 'tags' => %w[veneer oak],
                       'dimensions' => [1830.0, 1830.0], 'max_resolution' => [16_384, 16_384],
                       'thumbnail_url' => 'https://cdn.polyhaven.com/asset_img/thumbs/oak_veneer_01.png?width=256',
                       'authors' => { 'Jenelle van Heerden' => 'All' }, 'date_published' => 1_709_856_000 },
  'rusty_metal_99' => { 'name' => 'Rusty Metal 99', 'type' => 1, 'categories' => ['metal'], 'tags' => ['rust'],
                        'dimensions' => [2000, 2000], 'max_resolution' => [4096, 4096],
                        'thumbnail_url' => 'https://cdn.polyhaven.com/asset_img/thumbs/rusty_metal_99.png' },
  'Wood049' => { 'name' => 'Wood 049', 'type' => 1, 'tags' => [], 'dimensions' => [1000, 1000] }, # mesmo nome que no ACG
  'some_hdri' => { 'name' => 'Sky', 'type' => 0 },                              # não é textura
  'sem_nome' => { 'type' => 1 },                                                # incompleto
  'bad id!' => { 'name' => 'x', 'type' => 1 }                                   # id inválido
}.freeze
PH_FILES = {
  'Diffuse' => { '1k' => { 'jpg' => { 'url' => 'https://dl.polyhaven.org/a_diff_1k.jpg', 'size' => 10, 'md5' => 'x' } },
                 '2k' => { 'jpg' => { 'url' => 'https://dl.polyhaven.org/a_diff_2k.jpg', 'size' => 40, 'md5' => 'y' } } },
  'Rough' => { '1k' => { 'jpg' => { 'url' => 'https://dl.polyhaven.org/a_rough_1k.jpg', 'size' => 5 } } },
  'blend' => { '1k' => { 'blend' => { 'url' => 'https://dl.polyhaven.org/a.blend', 'size' => 1 } } },
  'gltf' => {}
}.freeze

def acg_asset(id, nome = nil, tipo: 'Material')
  { 'assetId' => id, 'displayName' => nome || id, 'displayCategory' => id.sub(/\d+\z/, ''), 'dataType' => tipo,
    'tags' => %w[a b], 'maps' => %w[color roughness displacement normal],
    'previewImage' => { '256-PNG' => "https://acg-media.struffelproductions.com/thumbnail/256-PNG/#{id}.png" },
    'dimensionX' => 100, 'dimensionY' => 100, 'releaseDate' => '2020-01-01 00:00:00',
    'downloadFolders' => { 'default' => { 'downloadFiletypeCategories' => { 'zip' => { 'downloads' => [
      { 'attribute' => '1K-JPG', 'size' => 5_000_000, 'downloadLink' => "https://ambientcg.com/get?file=#{id}_1K-JPG.zip" },
      { 'attribute' => '2K-JPG', 'size' => 20_000_000, 'downloadLink' => "https://ambientcg.com/get?file=#{id}_2K-JPG.zip" }
    ] } } } } }
end
ACG_TODOS = [acg_asset('AcousticFoam001', 'Acoustic Foam 001'), acg_asset('Bricks001'), acg_asset('Wood049', 'Wood 049'),
             acg_asset('Plastic001'), acg_asset('Tiles074'), acg_asset('Sky01', tipo: 'HDRI'),
             { 'assetId' => 'semtipo' }].freeze

$pedidos = []
$falha = nil
def servidor(pagina_dup: false)
  lambda do |url|
    $pedidos << url
    raise $falha if $falha.is_a?(Exception)
    return $falha if $falha.is_a?(String)
    if url.start_with?('https://api.polyhaven.com/assets')
      JSON.generate(PH)
    elsif url.start_with?('https://api.polyhaven.com/files/')
      JSON.generate(PH_FILES)
    elsif url.start_with?('https://ambientcg.com/api/v2/full_json')
      lim = url[/limit=(\d+)/, 1].to_i
      off = url[/offset=(\d+)/, 1].to_i
      pag = ACG_TODOS[off, lim] || []
      pag += [ACG_TODOS[0]] if pagina_dup && off.positive? # mesmo asset repetido noutra página
      JSON.generate('numberOfResults' => ACG_TODOS.length, 'foundAssets' => pag,
                    'nextPageHttp' => "https://ambientcg.com/api/v2/full_json?limit=#{lim}&offset=#{off + lim}")
    else
      raise "URL inesperada no teste: #{url}"
    end
  end
end

DIR = Dir.mktmpdir('blendit_catalogo')
at_exit { FileUtils.rm_rf(DIR) }

# ------------------------------------------------------------------ 1. compatibilidade sem cache
CO.http = ->(_u) { raise 'não deveria acessar a rede' }
base = CO.unificado(DIR)
leg = base.select { |x| x['legado'] }
confere('sem cache: os 157 materiais atuais estão no catálogo', leg.length == 157 && base.length == 157)
ids_cat = BlenditSU::Texturas::CATALOGO.map { |e| [e[2] == :acg ? 'acg' : 'ph', e[3]] }
confere('mesmos ids e fontes da biblioteca fixa', leg.map { |x| x['chave'].split(':', 2) }.sort == ids_cat.sort)
e0 = BlenditSU::Texturas::CATALOGO.first
l0 = leg.find { |x| x['id'] == e0[3] }
confere('legado mantém nome, grupo, tamanho e brilho', l0['nome'] == e0[1] && l0['grupo'] == e0[0] &&
                                                     l0['tamanho_m'] == e0[4] && l0['rugosidade'] == e0[5])
confere('Texturas::CATALOGO intocado (157, congelado)', BlenditSU::Texturas::CATALOGO.length == 157 &&
                                                      BlenditSU::Texturas::CATALOGO.frozen?)

# ------------------------------------------------------------------ 2. atualização com paginação
CO.http = servidor
$pedidos.clear
r = CO.atualizar(DIR, 2) # 2 por página para exercitar a paginação
confere('Poly Haven ok, 3 texturas válidas (HDRI, sem nome e id inválido descartados)',
        r['polyhaven'][:ok] && r['polyhaven'][:total] == 3 && r['polyhaven'][:descartados] == 3, r['polyhaven'].inspect)
pags = $pedidos.count { |u| u.include?('ambientcg.com/api/v2/full_json') }
confere('ambientCG percorre todas as páginas (7 itens / 2 por página = 4 pedidos)', pags == 4, "pedidos: #{pags}")
confere('ambientCG ok, 5 materiais (HDRI e registro inválido descartados)',
        r['ambientcg'][:ok] && r['ambientcg'][:total] == 5 && r['ambientcg'][:descartados] == 2, r['ambientcg'].inspect)
confere('nenhuma textura/miniatura baixada (só metadados)',
        $pedidos.none? { |u| u =~ /\.(jpg|png|zip|exr|hdr|blend)\b|get\?file=/i }, $pedidos.join(' '))
confere('Poly Haven: só UM pedido (a API entrega tudo sem paginação)', $pedidos.count { |u| u.include?('polyhaven.com/assets') } == 1)

u = CO.unificado(DIR)
confere('catálogo unificado: 157 + novos, sem duplicar (oak_veneer_01, Wood049, Tiles074 já eram legados)',
        u.length == 157 + 2 + 3, "total #{u.length}")
confere('chaves únicas', u.map { |x| x['chave'] }.uniq.length == u.length)
oak = u.find { |x| x['chave'] == 'ph:oak_veneer_01' }
confere('legado encontrado online mantém o nome em português e ganha tags/categoria/miniatura',
        oak['legado'] && oak['nome'] == 'Lâmina de carvalho' && oak['tags'] == %w[veneer oak] &&
        oak['categoria'] == 'Wood/Veneer/Oak Veneer' && oak['nome_original'] == 'Oak Veneer 01', oak.slice('nome', 'tags').inspect)
novo = u.find { |x| x['chave'] == 'ph:rusty_metal_99' }
confere('novo item Poly Haven completo (dimensões em m, resolução, licença e origem da licença)',
        novo && novo['dimensoes_m'] == [2.0, 2.0] && novo['resolucao_max'] == [4096, 4096] &&
        novo['licenca'] == 'CC0-1.0' && novo['licenca_origem'].include?('ToS') && !novo['legado'])
acg = u.find { |x| x['chave'] == 'acg:Bricks001' }
confere('novo item ambientCG com mapas, resoluções (1K/2K) e miniatura',
        acg && acg['mapas'].include?('roughness') && acg['resolucoes'].keys == %w[1K-JPG 2K-JPG] &&
        acg['miniatura'].include?('256-PNG') && acg['licenca'] == 'CC0-1.0')
w = u.select { |x| x['id'] == 'Wood049' }
confere('mesmo nome nas duas fontes: dois itens, sinalizados como possível duplicata (não fundidos)',
        w.length == 2 && w.all? { |x| x['possivel_duplicata'] } && w.map { |x| x['fonte'] }.sort == %w[ambientcg polyhaven])

# ------------------------------------------------------------------ 3. item repetido entre páginas
d2 = File.join(DIR, 'dup')
CO.http = servidor(pagina_dup: true)
r2 = CO.atualizar(d2, 2)
confere('asset repetido em páginas diferentes entra uma vez só', r2['ambientcg'][:total] == 5, r2['ambientcg'].inspect)

# ------------------------------------------------------------------ 4. sem internet: cache continua valendo
$falha = Errno::ECONNREFUSED.new('sem rede')
CO.http = servidor
r3 = CO.atualizar(DIR, 2)
confere('falha de rede: as duas fontes reportam erro sem derrubar', !r3['polyhaven'][:ok] && !r3['ambientcg'][:ok])
u3 = CO.unificado(DIR)
confere('falha de rede: itens já catalogados continuam disponíveis', u3.length == u.length, "#{u3.length}")
st = CO.estado(DIR)
confere('estado registra o erro por fonte', st[:fontes]['polyhaven']['ok'] == false && st[:fontes]['polyhaven']['erro'].to_s.include?('sem rede'))

# ------------------------------------------------------------------ 5. erros de API
$falha = 'isto não é json {'
r4 = CO.atualizar(File.join(DIR, 'e1'), 2)
confere('JSON inválido vira erro da fonte (não exceção)', !r4['polyhaven'][:ok] && r4['polyhaven'][:erro].include?('JSON inválido'))
$falha = BlenditSU::CatalogoOnline::ErroFonte.new('HTTP 500 em https://api.polyhaven.com/assets')
r5 = CO.atualizar(File.join(DIR, 'e2'), 2)
confere('HTTP 500 vira erro da fonte', r5['polyhaven'][:erro].include?('HTTP 500'))
$falha = JSON.generate('foundAssets' => 'quebrado')
r6 = CO.atualizar(File.join(DIR, 'e3'), 2)
confere('resposta incompleta do ambientCG é recusada', !r6['ambientcg'][:ok] && r6['ambientcg'][:erro].include?('incompleta'))
$falha = JSON.generate({})
r7 = CO.atualizar(File.join(DIR, 'e4'), 2)
confere('Poly Haven sem assets é recusado', !r7['polyhaven'][:ok])
require 'net/http'
$falha = Net::ReadTimeout.new
r8 = CO.atualizar(File.join(DIR, 'e5'), 2)
confere('tempo esgotado vira erro da fonte', !r8['polyhaven'][:ok] && !r8['ambientcg'][:ok])
confere('com erro e sem cache anterior: sobram os 157 legados', CO.unificado(File.join(DIR, 'e5')).length == 157)
$falha = nil

# ------------------------------------------------------------------ 6. cache corrompido
File.write(CO.arquivo(File.join(DIR, 'e1')), '{ corrompido')
confere('cache corrompido é ignorado (legados continuam)', CO.unificado(File.join(DIR, 'e1')).length == 157)
File.write(CO.arquivo(File.join(DIR, 'e1')), JSON.generate('formato' => 99, 'fontes' => {}))
confere('cache de formato desconhecido é ignorado', CO.ler_cache(File.join(DIR, 'e1')) == {})

# ------------------------------------------------------------------ 7. atualização de uma fonte só
$falha = nil
contador = 0
CO.http = lambda do |url|
  contador += 1
  raise BlenditSU::CatalogoOnline::ErroFonte, 'HTTP 503' if url.include?('ambientcg')
  servidor.call(url)
end
r9 = CO.atualizar(DIR, 2)
u9 = CO.unificado(DIR)
confere('ambientCG fora do ar: Poly Haven atualiza e os itens antigos do ambientCG ficam',
        r9['polyhaven'][:ok] && !r9['ambientcg'][:ok] && u9.any? { |x| x['chave'] == 'acg:Bricks001' })

# ------------------------------------------------------------------ 8. detalhes Poly Haven sob demanda
$pedidos.clear
CO.http = servidor
det = CO.detalhes_polyhaven('rusty_metal_99', DIR)
confere('detalhes: mapas de imagem (sem blend/gltf) e resoluções', det['mapas'] == %w[Diffuse Rough] &&
                                                                   det['resolucoes']['Diffuse'].keys == %w[1k 2k])
CO.http = ->(_u) { raise 'sem rede' }
det2 = CO.detalhes_polyhaven('rusty_metal_99', DIR)
confere('detalhes ficam em cache (funciona offline depois)', det2 == det)
confere('detalhes: id inválido recusado', begin
  CO.detalhes_polyhaven('../etc', DIR)
  false
rescue ArgumentError
  true
end)

# ------------------------------------------------------------------ 8b. formatos inesperados do ambientCG (achado no teste real)
# A API (PHP) devolve [] no lugar de {} vazio; um registro estranho não pode derrubar a fonte.
estranhos = [acg_asset('Ok001'),
             acg_asset('SemDownloads001').merge('downloadFolders' => [], 'previewImage' => []),
             acg_asset('TagsTexto001').merge('tags' => 'a,b', 'maps' => nil),
             acg_asset('DimEstranha001').merge('dimensionX' => {}, 'dimensionY' => []),
             acg_asset('PastaVazia001').merge('downloadFolders' => { 'default' => [] })]
CO.http = lambda do |url|
  next JSON.generate(PH) if url.include?('polyhaven')
  off = url[/offset=(\d+)/, 1].to_i
  JSON.generate('numberOfResults' => estranhos.length.to_s, 'foundAssets' => off.zero? ? estranhos : [])
end
r10 = CO.atualizar(File.join(DIR, 'estranho'), 250)
confere('ambientCG com [] no lugar de {} e campos de tipo errado: a fonte não falha',
        r10['ambientcg'][:ok], r10['ambientcg'].inspect)
u10 = CO.unificado(File.join(DIR, 'estranho')).select { |x| x['fonte'] == 'ambientcg' && !x['legado'] }
confere('... e os registros aproveitáveis entram (sem downloads/miniatura = campos vazios)',
        %w[Ok001 SemDownloads001 TagsTexto001 DimEstranha001 PastaVazia001].all? { |i| u10.any? { |x| x['id'] == i } },
        u10.map { |x| x['id'] }.inspect)
sd = u10.find { |x| x['id'] == 'SemDownloads001' }
confere('... registro sem downloads fica com resoluções vazias e miniatura padrão',
        sd && sd['resolucoes'] == {} && sd['miniatura'].include?('SemDownloads001'))
confere('numberOfResults como texto ("5") é aceito', r10['ambientcg'][:total] >= 4)

# ------------------------------------------------------------------ 9. consulta
CO.http = servidor
CO.atualizar(DIR, 2)
confere('busca por texto acha legado (carvalho) e novo (rust)', CO.buscar(texto: 'carvalho', cache_dir: DIR).any? &&
                                                                CO.buscar(texto: 'rust', cache_dir: DIR).map { |x| x['id'] } == ['rusty_metal_99'])
confere('busca filtra por fonte e por novos', CO.buscar(fonte: 'ambientcg', legado: false, limite: 99, cache_dir: DIR)
                                                 .map { |x| x['id'] }.sort == %w[AcousticFoam001 Bricks001 Plastic001]) # Wood049 e Tiles074 do ACG são legados
confere('o download das texturas (Texturas.fetch) não foi tocado', BlenditSU::Texturas.method(:fetch).source_location[0].end_with?('texturas.rb'))

puts "\n#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
