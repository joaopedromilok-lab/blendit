# encoding: UTF-8
# Variações de proposta (regras) + JavaScript das janelas novas (sintaxe).
#   ruby teste_variacoes_janelas.rb        (código 1 se algo falhar)
require 'json'
require 'tmpdir'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative '../src/blendit_sketchup/texturas'
require_relative '../src/blendit_sketchup/objetos'
require_relative '../src/blendit_sketchup/variacoes'
require_relative '../src/blendit_sketchup/auto_texturas'

$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end
V = BlenditSU::Variacoes
nomes = ['Piso', 'Carvalho', 'Porcelanato 90x90', 'Parede']
c = V.limpar({ 'opcoes' => [{ 'nome' => '', 'trocas' => { 'Piso' => 'Carvalho', 'Fantasma' => 'Piso', 'Parede' => 'Parede' } },
                            { 'nome' => 'Porcelanato', 'trocas' => { 'Piso' => 'Porcelanato 90x90' } },
                            { 'nome' => 'Original', 'trocas' => {} },
                            { 'nome' => 'Quarta', 'trocas' => { 'Piso' => 'Carvalho' } }] }, nomes)
confere('no máximo 3 opções', c['opcoes'].length == 3)
confere('opção sem nome vira "Opção A"', c['opcoes'][0]['nome'] == 'Opção A')
confere('troca com material inexistente ou igual é descartada', c['opcoes'][0]['trocas'] == { 'Piso' => 'Carvalho' })
confere('opção sem troca é mantida (o projeto como está)', c['opcoes'][2] == { 'nome' => 'Original', 'trocas' => {} })
confere('config inválida vira vazia', V.limpar(nil, nomes) == { 'opcoes' => [] } && V.limpar({ 'opcoes' => ['x', 3] }, nomes) == { 'opcoes' => [] })

tmp = Dir.mktmpdir('blendit_js')
checar = lambda do |nome, html|
  js = html.scan(%r{<script>(.*?)</script>}m).map(&:first).join("\n")
  arq = File.join(tmp, "#{nome}.js")
  File.write(arq, "var document={getElementById:function(){return {classList:{toggle:function(){}},style:{},appendChild:function(){}}},createElement:function(){return {}},querySelectorAll:function(){return []}},window={addEventListener:function(){}},sketchup={};\n#{js}")
  confere("JavaScript da janela #{nome} é válido", system('node', '--check', arq))
end
mats = nomes.map { |n| { 'nome' => n, 'rotulo' => n, 'cor' => '#cccccc', 'textura' => false } }
checar.call('Variações', V.html(mats, c))
checar.call('Objetos', BlenditSU::Objetos.html)
checar.call('Biblioteca', BlenditSU::Texturas.html)
sug = [{ 'material' => 'Piso', 'nome' => 'Piso', 'tipo' => 'piso', 'rotulo' => 'Piso', 'cor' => '#ccc', 'confianca' => 'alta', 'motivo' => 'x', 'textura' => 'Tiles074' }]
op = { 'piso' => { 'rotulo' => 'Piso', 'itens' => [{ 'id' => 'Tiles074', 'nome' => 'P', 'thumb' => '' }, { 'id' => 'ph:x', 'nome' => "Online: d'água", 'thumb' => '' }] } }
checar.call('Texturas automáticas', BlenditSU::AutoTexturas.html(sug, op))
FileUtils.rm_rf(tmp)
puts
puts "#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
