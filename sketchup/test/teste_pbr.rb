# encoding: UTF-8
# Mapas PBR do SketchUp 2025 no pacote (API do SketchUp imitada).
#   ruby teste_pbr.rb        (código 1 se algo falhar)
require 'json'
require 'tmpdir'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative 'cena_pbr'

$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end

tmp = Dir.mktmpdir('blendit_pbr')
out = File.join(tmp, 'pacote')
spec = JSON.parse(File.read(cena_pbr(out)))
mats = spec['materials'].to_h { |x| [x['name'], x] }
p1 = mats['Revestimento PBR']
mp = p1['maps'] || {}
confere('parede: cor + normal + rugosidade + metálico + oclusão', %w[diffuse normal roughness metallic ao].all? { |k| mp[k] }, mp.keys.inspect)
confere('mapas PBR marcados pbr=true e na escala da cor', %w[normal roughness metallic ao].all? { |k| mp[k]['pbr'] && mp[k]['scale_m'] == mp['diffuse']['scale_m'] })
confere('arquivos dos mapas estão no pacote', %w[normal roughness metallic ao].all? { |k| File.file?(File.join(out, mp[k]['uri'])) })
confere('normal: força 1.5 e padrão DirectX', mp['normal']['strength'] == 1.5 && mp['normal']['directx'] == true)
confere('oclusão: força 0.7', mp['ao']['strength'] == 0.7)
confere('fatores do material: rugosidade 0.8, metálico 0.5', p1['roughness'] == 0.8 && p1['metallic'] == 0.5)
confere('parede usa as UVs do SketchUp', mp['diffuse']['uv'] == true)
c = mats['Chapa metálica']
confere('chapa só-cor: rugosidade e metálico sem imagem de cor', c['maps'] && c['maps']['roughness'] && c['maps']['metallic'] && !c['maps']['diffuse'], c['maps'].inspect[0, 160])
confere('chapa: escala do próprio mapa (0.5 m)', c['maps']['metallic']['scale_m'].map { |v| v.round(3) } == [0.5, 0.5])
confere('material clássico continua sem mapas', mats['Pintura comum']['maps'].nil?)
FileUtils.rm_rf(tmp)
puts
puts "#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
