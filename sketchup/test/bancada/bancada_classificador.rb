# encoding: UTF-8
# Bancada de comparação - CLASSIFICAÇÃO E LEITURA DO NOME (Ruby puro, sem SketchUp).
#
# Passa os nomes reais de nomes_materiais.json pelo classificador ATUAL do
# plugin (classificador.rb) e pelo leitor de nome que já existe para a
# importação em lote (Texturas.analisar_nome: acabamento e medida), e mede:
#   * acertos de categoria; ERROS COM CERTEZA ALTA (a métrica principal: troca
#     errada que o modo Automático aplicaria sem pedir confirmação); erros com
#     certeza média/baixa; categorias que faltam; texturização indevida;
#   * acabamento lido do nome (polido / acetinado / fosco / escovado);
#   * medida lida do nome (60x60, 7,5x15...).
# NÃO muda nada: é a foto do comportamento de hoje, para comparar depois.
#
#   ruby bancada_classificador.rb [saida.json] [--estrito]
#     saida.json  grava os resultados (para comparar_classificador / bancada.py)
#     --estrito   código de saída 1 se houver erro com certeza alta (usar
#                 DEPOIS da correção; hoje o esperado é falhar)
require 'json'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative '../../src/blendit_sketchup/classificador'
require_relative '../../src/blendit_sketchup/texturas'

AQUI = __dir__
DADOS = JSON.parse(File.read(File.join(AQUI, 'nomes_materiais.json'), encoding: 'UTF-8'))
ACAB_ESPERADO = { 'polido' => 'Polido / brilhante', 'acetinado' => 'Acetinado', 'fosco' => 'Fosco',
                  'escovado' => 'Escovado' }.freeze

# Uso no modelo -> as mesmas características que o exportador mede.
def caracteristicas(it)
  uso = it['uso']
  area = { 'piso' => 12.0, 'parede' => 10.0, 'estofado' => 2.0 }.fetch(uso, 2.0)
  { nome: it['nome'], rgb: it['cor'], alpha: 1.0, tem_textura: false, area_m2: area,
    frac_piso: uso == 'piso' ? 0.9 : 0.0, frac_parede: uso == 'parede' ? 0.9 : 0.0,
    frac_estofado: uso == 'estofado' ? 0.9 : 0.0 }
end

def avaliar(it)
  cl = BlenditSU::Classificador.classificar(caracteristicas(it), {})
  cat = cl[:categoria]
  conf = cl[:confianca].to_s
  aceitas = it['aceitas']
  ok = aceitas.include?(cat)
  situacao = if ok then 'ok'
             elsif cat.nil? then 'faltou'                       # devia texturizar e não sugeriu nada
             elsif aceitas == [nil] then "indevido_#{conf}"     # não devia texturizar
             else "erro_#{conf}"
             end
  lido = BlenditSU::Texturas.analisar_nome(it['nome'])
  acab_esp = it['acabamento'] && ACAB_ESPERADO[it['acabamento']]
  acab_lido = lido['acabamento_lido'] ? lido['acabamento'] : nil
  med = lido['medida_lida'] ? [lido['largura_cm'], lido['altura_cm']] : nil
  { 'nome' => it['nome'], 'uso' => it['uso'], 'categoria' => cat, 'confianca' => conf, 'motivo' => cl[:motivo],
    'aceitas' => aceitas, 'situacao' => situacao,
    'acabamento_esperado' => acab_esp, 'acabamento_lido' => acab_lido,
    'acabamento_ok' => acab_esp.nil? ? (acab_lido.nil? || nil) : acab_lido == acab_esp,
    'medida_esperada' => it['medida_cm'], 'medida_lida' => med,
    'medida_ok' => it['medida_cm'].nil? ? nil : med == it['medida_cm'].map(&:to_f) }
end

res = DADOS['itens'].map { |it| avaliar(it) }
cont = Hash.new(0)
res.each { |r| cont[r['situacao'].sub(/_(alta|media|baixa|nenhuma)\z/) { "_#{$1}" }] += 1 }
erros_alta = res.count { |r| %w[erro_alta indevido_alta].include?(r['situacao']) }
acab = res.reject { |r| r['acabamento_esperado'].nil? }
med = res.reject { |r| r['medida_esperada'].nil? }
resumo = {
  'total' => res.length,
  'acertos' => res.count { |r| r['situacao'] == 'ok' },
  'erros_com_certeza_alta' => erros_alta,
  'erros_com_certeza_media' => res.count { |r| r['situacao'] =~ /_media\z/ },
  'erros_com_certeza_baixa' => res.count { |r| r['situacao'] =~ /_baixa\z/ },
  'faltou_categoria' => cont['faltou'],
  'acabamento_esperado' => acab.length,
  'acabamento_lido_certo' => acab.count { |r| r['acabamento_ok'] },
  'acabamento_falso_positivo' => res.count { |r| r['acabamento_esperado'].nil? && r['acabamento_lido'] },
  'medida_esperada' => med.length,
  'medida_lida_certa' => med.count { |r| r['medida_ok'] }
}

puts 'Classificação dos nomes reais (classificador atual):'
res.each do |r|
  marca = r['situacao'] == 'ok' ? '  ok ' : ' XX  '
  printf("%s%-42s -> %-13s %-7s aceitas %-28s %s\n", marca, r['nome'], r['categoria'].inspect, r['confianca'],
         r['aceitas'].inspect, r['situacao'] == 'ok' ? '' : r['situacao'])
end
puts
puts 'Acabamento e medida (leitor existente da importação em lote):'
acab.each { |r| printf("  %-42s esperado %-20s lido %s\n", r['nome'], r['acabamento_esperado'], r['acabamento_lido'].inspect) }
res.select { |r| r['acabamento_esperado'].nil? && r['acabamento_lido'] }.each do |r|
  printf("  %-42s esperado %-20s lido %s  (falso positivo)\n", r['nome'], '-', r['acabamento_lido'].inspect)
end
med.each { |r| printf("  %-42s medida esperada %-12s lida %s\n", r['nome'], r['medida_esperada'].inspect, r['medida_lida'].inspect) }
puts
puts 'RESUMO ' + JSON.generate(resumo)

if (saida = ARGV.find { |a| a.end_with?('.json') })
  File.write(saida, JSON.pretty_generate('resumo' => resumo, 'itens' => res))
  puts "gravado: #{saida}"
end
exit(ARGV.include?('--estrito') && erros_alta.positive? ? 1 : 0)
