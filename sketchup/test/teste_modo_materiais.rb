# encoding: UTF-8
# Testes dos modos "Materiais no render" no exportador (API do SketchUp imitada).
#   ruby teste_modo_materiais.rb      (código 1 se algo falhar)
require 'json'
require 'zlib'
require 'tmpdir'
require 'fileutils'
module UI; class HtmlDialog; STYLE_DIALOG = 0; end; end unless defined?(UI::HtmlDialog)
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'
require_relative '../src/blendit_sketchup/texturas'

M = 1.0 / 0.0254
def mi(*v) = v.map { |x| x * M } unless defined?(mi)
$f = 0
$t = 0
def confere(desc, ok, extra = '')
  $t += 1
  $f += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{desc}#{extra.to_s.empty? ? '' : " - #{extra}"}"
end

# ruby teste_modo_materiais.rb [pasta]  -> com pasta, os pacotes ficam lá (usado por tests/headless_modos_materiais.py)
TMP = ARGV[0] ? File.expand_path(ARGV[0]).tap { |d| FileUtils.mkdir_p(d) } : Dir.mktmpdir('blendit_modos')
def png(path)
  raw = (0...4).map { "\x00".b + ([150, 120, 90].pack('C*') * 4) }.join
  ch = ->(t, d) { [d.bytesize].pack('N') + t + d + [Zlib.crc32(t + d)].pack('N') }
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b + ch.call('IHDR', [4, 4, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
                      ch.call('IDAT', Zlib::Deflate.deflate(raw)) + ch.call('IEND', ''))
  path
end
# Catálogo sem internet: cada textura vira um PNG local (cor + relevo + brilho).
$baixadas = []
BlenditSU::Texturas.define_singleton_method(:fetch) do |ent|
  $baixadas << ent[3]
  d = File.join(TMP, 'cat', ent[3])
  FileUtils.mkdir_p(d)
  [png(File.join(d, 'cor.png')), png(File.join(d, 'relevo.png')), [0.6, 0.6], png(File.join(d, 'rugo.png'))]
end

def caixa(ents, x0, y0, z0, x1, y1, z1, mat)
  fs = [ents.add_face([mi(x0, y0, z0), mi(x0, y1, z0), mi(x1, y1, z0), mi(x1, y0, z0)]),
        ents.add_face([mi(x0, y0, z1), mi(x1, y0, z1), mi(x1, y1, z1), mi(x0, y1, z1)]),
        ents.add_face([mi(x0, y0, z0), mi(x1, y0, z0), mi(x1, y0, z1), mi(x0, y0, z1)]),
        ents.add_face([mi(x1, y1, z0), mi(x0, y1, z0), mi(x0, y1, z1), mi(x1, y1, z1)])]
  fs.each { |f| f.material = mat }
end

def cena
  cam = Sketchup::Camera.new(mi(2, -4, 1.5), mi(2, 2, 1), 50.0)
  m = Sketchup::Model.new('Modos', cam, Geom::Vector3d.new(0.3, -0.5, 0.8),
                          Geom::BoundingBox.new(mi(-0.2, -0.2, -0.05), mi(5, 5, 3)))
  mats = {
    piso: Sketchup::Material.new('Cor_M05', [128, 126, 122]),
    freijo: Sketchup::Material.new('Madeira freijó', [170, 125, 80]),
    so_cor: Sketchup::Material.new('[Color_A12]', [160, 115, 70]),
    vidro: Sketchup::Material.new('Cor_A01', [200, 220, 225], alpha: 0.3),
    textura: Sketchup::Material.new('Porcelanato X', [200, 200, 200],
                                    texture: Sketchup::Texture.new(png(File.join(TMP, 'px.png')), 0.6 * M, 0.6 * M)),
    inox: Sketchup::Material.new('Inox escovado', [180, 180, 182]),
    sofa: Sketchup::Material.new('Material12', [110, 112, 118]),
    rejeitado: Sketchup::Material.new('Granito rejeitado', [60, 60, 60]),
    aprovado: Sketchup::Material.new('Cor_Z9', [210, 205, 200])
  }
  mats[:rejeitado].set_attribute('blendit', 'auto_decisao', 'rejeitado')
  mats[:aprovado].set_attribute('blendit', 'auto_decisao', 'aprovado')
  mats[:aprovado].set_attribute('blendit', 'auto_textura', 'Marble012')
  mats[:aprovado].set_attribute('blendit', 'auto_categoria', 'bancada')
  add = lambda do |nome, mat, &blk|
    d = Sketchup::ComponentDefinition.new(nome)
    blk.call(d.entities, mat)
    m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: nome)
  end
  add.call('Piso', mats[:piso]) { |e, mt| e.add_face([mi(0, 0, 0), mi(5, 0, 0), mi(5, 5, 0), mi(0, 5, 0)]).material = mt }
  add.call('Armário', mats[:freijo]) { |e, mt| caixa(e, 0.2, 4.0, 0, 1.4, 4.6, 2.2, mt) }
  add.call('Prateleira', mats[:so_cor]) { |e, mt| caixa(e, 3.0, 4.6, 1.2, 4.0, 4.9, 1.25, mt) }
  add.call('Janela', mats[:vidro]) { |e, mt| e.add_face([mi(1, 0, 1), mi(2, 0, 1), mi(2, 0, 2), mi(1, 0, 2)]).material = mt }
  add.call('Revestimento', mats[:textura]) { |e, mt| e.add_face([mi(4.9, 1, 0.1), mi(4.9, 2, 0.1), mi(4.9, 2, 1.1), mi(4.9, 1, 1.1)]).material = mt }
  add.call('Puxador', mats[:inox]) { |e, mt| caixa(e, 0.5, 3.95, 1.0, 0.7, 4.0, 1.02, mt) }
  add.call('Sofá 3 lugares', mats[:sofa]) { |e, mt| caixa(e, 2.0, 1.0, 0.1, 4.0, 1.9, 0.45, mt) }
  add.call('Bancada', mats[:rejeitado]) { |e, mt| caixa(e, 3.0, 3.0, 0.9, 4.0, 3.6, 0.93, mt) }
  add.call('Mesa', mats[:aprovado]) { |e, mt| caixa(e, 1.0, 2.0, 0.75, 2.0, 2.8, 0.78, mt) }
  m
end

def exportar(modo)
  dir = File.join(TMP, modo)
  exp = BlenditSU::Exporter.new(cena, mode: 'realistic', resolution: [320, 0], materiais: modo)
  spec = JSON.parse(File.read(exp.export(dir)))
  [exp, spec, dir]
end

def por_nome(spec, nome) = spec['materials'].select { |x| x['name'].start_with?(nome) }
def posicoes(dir)
  b = File.binread(File.join(dir, 'scene.glb'))
  jl = b[12, 4].unpack1('V')
  j = JSON.parse(b[20, jl])
  bin = b[20 + jl + 8..]
  j['meshes'].map do |mm|
    a = j['accessors'][mm['primitives'][0]['attributes']['POSITION']]
    v = j['bufferViews'][a['bufferView']]
    bin[v['byteOffset'], v['byteLength']].unpack('e*')
  end.flatten.map { |x| x.round(4) }.sort
end

# ---------------------------------------------------------------- preservar
_e, sp, dp = exportar('preservar')
confere('preservar: modo e ajustes por nome ligados no pacote',
        sp['render']['materials_mode'] == 'preservar' && sp['render']['procedural_by_name'] == true)
auto = sp['materials'].select { |x| x['auto'] }
confere('preservar: nenhum material recebe textura automática', auto.empty?)
confere('preservar: nada é baixado', $baixadas.empty?)
confere('preservar: material com textura segue com as UVs do SketchUp',
        por_nome(sp, 'Porcelanato X')[0]['maps']['diffuse']['uv'] == true)

# ---------------------------------------------------------------- estrito
_e, se, de = exportar('estrito')
confere('estrito: desliga os ajustes por nome no Blender', se['render']['procedural_by_name'] == false)
confere('estrito: sem pistas de estofado/cortina pelo nome do componente',
        se['materials'].none? { |x| %w[estofado cortina cortina_voil].include?(x['appearance_class']) })
confere('estrito: nenhuma textura automática', se['materials'].none? { |x| x['auto'] })

# ---------------------------------------------------------------- automático
exp, sa, da = exportar('automatico')
info = ->(nome) { (por_nome(sa, nome)[0] || {})['auto'] }
confere('auto: piso genérico (média) recebe piso do catálogo',
        info.call('Cor_M05') && info.call('Cor_M05')['categoria'] == 'piso' && info.call('Cor_M05')['confianca'] == 'media',
        info.call('Cor_M05').inspect)
confere('auto: "Madeira freijó" (alta) recebe Freijó', info.call('Madeira freijó') &&
        info.call('Madeira freijó')['textura'] == 'ash_veneer', info.call('Madeira freijó').inspect)
confere('auto: só a cor de madeira (baixa) NÃO recebe textura', info.call('[Color_A12]').nil?)
confere('auto: vidro não é tocado', info.call('Cor_A01').nil? && por_nome(sa, 'Cor_A01')[0]['maps'].nil?)
px = por_nome(sa, 'Porcelanato X')[0]
confere('auto: material com textura do SketchUp é preservado (mesma imagem, UV)',
        px['auto'].nil? && px['maps']['diffuse']['uri'] == 'textures/m5.png' || (px['auto'].nil? && px['maps']['diffuse']['uv'] == true),
        px['maps'].inspect)
confere('auto: inox vira metal genérico, sem textura inventada',
        info.call('Inox escovado') && info.call('Inox escovado')['categoria'] == 'metal' &&
        por_nome(sa, 'Inox escovado')[0]['maps'].nil?)
confere('auto: tecido do sofá (pelo uso) recebe tecido', por_nome(sa, 'Material12').any? { |x| x['auto'] && x['auto']['categoria'] == 'tecido' })
confere('auto: material rejeitado pela arquiteta não muda', info.call('Granito rejeitado').nil?)
confere('auto: escolha aprovada é usada como foi aprovada',
        info.call('Cor_Z9') && info.call('Cor_Z9')['textura'] == 'Marble012' && info.call('Cor_Z9')['origem'] == 'aprovado')
pm = por_nome(sa, 'Cor_M05')[0]
confere('auto: textura tingida com a cor do projeto (tint = base_color)', pm['maps']['diffuse']['tint'] == pm['base_color'])
confere('auto: leva relevo e mapa de brilho do catálogo, mesma escala', pm['maps']['bump'] && pm['maps']['roughness'] &&
        pm['maps']['bump']['scale_m'] == pm['maps']['diffuse']['scale_m'])
confere('auto: textura automática não tem UV (projeção em escala real)', pm['maps']['diffuse']['uv'].nil?)
confere('auto: arquivos copiados para o pacote', File.file?(File.join(da, pm['maps']['diffuse']['uri'])))
confere('auto: geometria idêntica ao modo preservar', posicoes(da) == posicoes(dp))
confere('auto: a cena do SketchUp não foi alterada (material segue sem textura)',
        cena.materials.find { |x| x.name == 'Cor_M05' }.texture.nil?)

FileUtils.rm_rf(TMP) unless ARGV[0]
puts "\n#{$t - $f} de #{$t} verificações passaram."
exit($f.zero? ? 0 : 1)
