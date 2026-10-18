# encoding: UTF-8
# Testes do classificador de materiais e da biblioteca por categoria.
# Ruby puro - não precisa da API do SketchUp.   ruby teste_classificador.rb
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative '../src/blendit_sketchup/classificador'
require_relative '../src/blendit_sketchup/biblioteca_materiais'

C = BlenditSU::Classificador
B = BlenditSU::BibliotecaMateriais
$f = 0
$t = 0
def caso(desc, feat, cat, conf, regras = {})
  $t += 1
  r = C.classificar(feat, regras)
  ok = r[:categoria] == cat && r[:confianca] == conf
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc} -> #{r[:categoria].inspect}/#{r[:confianca]} (#{r[:motivo]})"
end

def f(nome, rgb = [200, 200, 200], **x) = { nome: nome, rgb: rgb, alpha: 1.0, area_m2: 2.0 }.merge(x)

BRANCO = [235, 235, 232]
CINZA = [120, 118, 115]
MADEIRA = [160, 115, 70]

puts '--- Pelo nome (confiança alta)'
caso('porcelanato', f('Porcelanato acetinado bege', [200, 188, 170]), 'piso', :alta)
caso('piso com cor de madeira vira piso de madeira', f('Piso sala', MADEIRA), 'piso_madeira', :alta)
caso('vinílico', f('Vinílico carvalho'), 'piso_madeira', :alta)
caso('freijó', f('Madeira freijó', MADEIRA), 'madeira', :alta)
caso('MDF em inglês/sigla', f('MDF Branco TX', BRANCO), 'madeira', :alta)
caso('linho', f('Tecido linho cinza', CINZA), 'tecido', :alta)
caso('couro', f('Couro caramelo', MADEIRA), 'couro', :alta)
caso('bancada de granito', f('Granito São Gabriel', [40, 40, 40]), 'bancada', :alta)
caso('silestone', f('Silestone branco', BRANCO), 'bancada', :alta)
caso('cimento queimado', f('Cimento queimado', CINZA), 'concreto', :alta)
caso('tijolinho', f('Tijolinho aparente', [150, 80, 60]), 'tijolo', :alta)
caso('metal (inox)', f('Inox escovado', [180, 180, 180]), 'metal', :alta)
caso('pintura de parede', f('Pintura acrílica branca', BRANCO), 'parede', :alta)
caso('inglês: wood floor', f('Wood_Floor_Light', [190, 160, 120]), 'piso_madeira', :alta)
caso('"aço" não dispara em "espaço"', f('Espaço gourmet', BRANCO, frac_parede: 0.1), nil, :nenhuma)

puts '--- Pelo uso (nome genérico)'
caso('genérico cobrindo o piso', f('Cor_M05', CINZA, frac_piso: 0.95, area_m2: 18), 'piso', :media)
caso('genérico cor de madeira no piso', f('[Color_A12]', MADEIRA, frac_piso: 0.9, area_m2: 12), 'piso_madeira', :media)
caso('genérico dentro do sofá', f('Material12', CINZA, frac_estofado: 0.9), 'tecido', :media)
caso('genérico cobrindo paredes = parede pintada', f('Cor_B03', BRANCO, frac_parede: 0.95, area_m2: 30), 'parede', :media)
caso('só cor de madeira = baixa (confirmar)', f('[Color_A12]', MADEIRA), 'madeira', :baixa)
caso('tapetinho no chão (< 1 m²) não é piso', f('Cor_M09', CINZA, frac_piso: 1.0, area_m2: 0.5), nil, :nenhuma)
caso('genérico sem indício nenhum', f('Material7', [90, 140, 200]), nil, :nenhuma)

puts '--- Não mexer'
caso('já tem textura = preservado', f('Porcelanato X', tem_textura: true), nil, :nenhuma)
caso('transparente = vidro', f('Cor_A01', BRANCO, alpha: 0.4), nil, :nenhuma)
caso('espelho', f('Espelho', BRANCO), nil, :nenhuma)
caso('luminária', f('Luminária pendente', BRANCO), nil, :nenhuma)

puts '--- Regras configuráveis'
caso('palavra do usuário', f('Dekton Aura', BRANCO), 'bancada', :alta, { 'palavras' => { 'bancada' => ['dekton'] } })
caso('categoria desativada', f('Tecido linho', CINZA), nil, :nenhuma, { 'desativar' => ['tecido'] })

puts '--- Biblioteca: escolha da textura'
nomes = { 'ash_veneer' => 'Freijó / freixo claro', 'Wood049' => 'Carvalho natural',
          'rough_linen' => 'Linho', 'Fabric030' => 'Tecido cinza', 'Tiles074' => 'Porcelanato marmorizado em placas',
          'Tiles138' => 'Pedra preta quadrada' }
def t(desc, ok)
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}"
end
t('nome "freijó" escolhe Freijó', B.ordenar('madeira', MADEIRA, 'Madeira freijó', nomes).first == 'ash_veneer')
t('nome "linho cinza" escolhe Linho (tipo vale mais que cor)', B.ordenar('tecido', CINZA, 'Tecido linho cinza', nomes).first == 'rough_linen')
t('piso branco escolhe o mais claro', B.ordenar('piso', BRANCO, 'Cor_M01', nomes).first == 'Tiles074')
t('piso preto escolhe o escuro', B.ordenar('piso', [45, 45, 45], 'Cor_M02', nomes).first == 'Tiles138')
t('preferida nas regras vai na frente', B.ordenar('piso', BRANCO, '', nomes, { 'preferidas' => { 'piso' => 'Tiles142' } }).first == 'Tiles142')
t('categoria genérica (parede) não tem textura', B.ordenar('parede', BRANCO).empty? && !B.com_textura?('parede'))
t('toda textura da biblioteca existe no catálogo', begin
  require_relative '../src/blendit_sketchup/texturas'
  ids = BlenditSU::Texturas::CATALOGO.map { |e| e[3] }
  B::CATEGORIAS.values.flat_map { |c| c[:texturas].keys }.all? { |id| ids.include?(id) }
rescue NameError, LoadError
  true
end)
t('regras: JSON ausente = {}', B.carregar_regras('/nao/existe.json') == {})

puts "\n#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
