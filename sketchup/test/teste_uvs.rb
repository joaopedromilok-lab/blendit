# encoding: UTF-8
# Testes automáticos das coordenadas de textura (UV) SketchUp -> pacote.
# Usa a API do SketchUp imitada (sketchup_fake.rb), que reproduz o que o
# SketchUp entrega em face.mesh(UVQ): UVs posicionadas, projeção padrão já em
# unidades de textura para o material da própria face e em polegadas para a
# face que herda o material do grupo.
#
#   ruby teste_uvs.rb          (sai com código 1 se algum teste falhar)
require 'json'
require 'zlib'
require 'tmpdir'
require 'fileutils'
require_relative 'sketchup_fake'
require_relative '../src/blendit_sketchup/exporter'

M = 1.0 / 0.0254 # metros -> polegadas
def mi(*v) = v.map { |x| x * M } unless defined?(mi)

$falhas = 0
$total = 0
def confere(nome, ok, extra = '')
  $total += 1
  $falhas += 1 unless ok
  puts "#{ok ? 'OK  ' : 'FALHOU'} #{nome}#{extra.empty? ? '' : " - #{extra}"}"
end

def perto(a, b, tol = 1e-4) = (a - b).abs <= tol

# PNG mínimo (sem dependências) para as texturas de teste.
def png(path, w = 4, h = 4)
  raw = (0...h).map { "\x00".b + ([200, 120, 60].pack('C*') * w) }.join
  chunk = ->(t, d) { [d.bytesize].pack('N') + t + d + [Zlib.crc32(t + d)].pack('N') }
  File.binwrite(path, "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', [w, h, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
                      chunk.call('IDAT', Zlib::Deflate.deflate(raw)) + chunk.call('IEND', ''))
  path
end

TMP = Dir.mktmpdir('blendit_uv')
def tex(nome, larg_m, alt_m) = Sketchup::Texture.new(png(File.join(TMP, "#{nome}.png")), larg_m * M, alt_m * M)
def mat(nome, t) = Sketchup::Material.new(nome, [200, 200, 200], texture: t)

def modelo
  cam = Sketchup::Camera.new(mi(1, -4, 1.5), mi(1, 0, 1), 50.0)
  Sketchup::Model.new('UV', cam, Geom::Vector3d.new(0.3, -0.4, 0.8),
                      Geom::BoundingBox.new(mi(-3, -3, -1), mi(6, 6, 4)))
end

# Lê o .glb: { nome_do_nó => { pos: [[x,y,z]...] (Z-up, pol.), uv: [[u,v]...] (convenção SketchUp) } }
def ler_glb(dir)
  b = File.binread(File.join(dir, 'scene.glb'))
  jl = b[12, 4].unpack1('V')
  j = JSON.parse(b[20, jl])
  bin = b[20 + jl + 8..]
  get = lambda do |ai, n|
    a = j['accessors'][ai]
    v = j['bufferViews'][a['bufferView']]
    bin[v['byteOffset'], v['byteLength']].unpack('e*').each_slice(n).to_a
  end
  out = {}
  j['nodes'].each do |nd|
    at = j['meshes'][nd['mesh']]['primitives'][0]['attributes']
    pos = get.call(at['POSITION'], 3).map { |x, y, z| [x, -z, y] }
    uv = at['TEXCOORD_0'] ? get.call(at['TEXCOORD_0'], 2).map { |u, v| [u, 1.0 - v] } : nil
    out[nd['name']] = { pos: pos, uv: uv }
  end
  out
end

def exportar(m, nome)
  dir = File.join(TMP, nome)
  exp = BlenditSU::Exporter.new(m, mode: 'realistic', resolution: [320, 0])
  spec = JSON.parse(File.read(exp.export(dir)))
  rotulo = spec['geometry']['elements'].to_h { |e| [e['node'], "#{e['family']} [#{e['node']}]"] }
  glb = ler_glb(dir).transform_keys { |k| rotulo[k] || k }
  [exp, spec, glb]
end

def uv_em(no, ponto_m)
  alvo = ponto_m.map { |c| c * M }
  i = no[:pos].index { |p| (0..2).all? { |k| perto(p[k], alvo[k], 1e-3) } }
  i && no[:uv] && no[:uv][i]
end

def grupo(m, nome, material = nil, tr = Geom::Transformation.new)
  d = Sketchup::ComponentDefinition.new(nome)
  yield d.entities
  i = Sketchup::ComponentInstance.new(d, tr, name: nome)
  i.material = material
  m.entities << i
  i
end

def no_de(glb, nome) = glb.find { |k, _| k.include?(nome) }&.last

# ----------------------------------------------------------------------------
# 1. Escala e orientação conhecidas
m = modelo
piso = mat('Porcelanato', tex('piso', 0.5, 0.25))
f = nil
grupo(m, 'Piso') { |e| f = e.add_face([mi(0, 0, 0), mi(2, 0, 0), mi(2, 1, 0), mi(0, 1, 0)]); f.material = piso }
rot = mat('Madeira girada', tex('madeira', 1.0, 0.2))
grupo(m, 'Painel') do |e|
  g = e.add_face([mi(3, 0, 0), mi(4, 0, 0), mi(4, 2, 0), mi(3, 2, 0)])
  g.material = rot
  # textura girada 90 graus pela arquiteta: o veio corre em Y
  g.uv_front = [[0.0, 0.0], [0.0, -1.0], [10.0, -1.0], [10.0, 0.0]]
end
_exp, spec, glb = exportar(m, 't1')
uv = uv_em(no_de(glb, 'Piso'), [2, 1, 0])
confere('1a escala real: canto (2 m, 1 m) com ladrilho 0,5 x 0,25 m = UV (4, 4)',
        uv && perto(uv[0], 4.0) && perto(uv[1], 4.0), uv.inspect)
uv = uv_em(no_de(glb, 'Painel'), [4, 2, 0])
confere('1b orientação posicionada (90 graus) preservada', uv && perto(uv[0], 10.0) && perto(uv[1], -1.0), uv.inspect)
md = spec['materials'].find { |x| x['name'] == 'Porcelanato' }
confere('1c material marcado para usar as UVs no Blender', md['maps']['diffuse']['uv'] == true)

# ----------------------------------------------------------------------------
# 2 e 6. Imagem esticada (mapeamento não uniforme) num quadro e numa TV: 0..1, sem repetir
m = modelo
foto = mat('Quadro foto', tex('foto', 0.3, 0.3))        # imagem "nominal" 30 cm
tela = mat('Tela TV', tex('tv', 0.5, 0.5))
grupo(m, 'Quadro') do |e|
  q = e.add_face([mi(1.37, 0, 1.1), mi(2.17, 0, 1.1), mi(2.17, 0, 1.7), mi(1.37, 0, 1.7)])
  q.material = foto
  q.uv_front = [[0, 0], [1, 0], [1, 1], [0, 1]]           # 80 x 60 cm esticada na imagem
end
grupo(m, 'TV 55') do |e|
  t = e.add_face([mi(3.1, 0, 0.9), mi(4.32, 0, 0.9), mi(4.32, 0, 1.6), mi(3.1, 0, 1.6)])
  t.material = tela
  t.uv_front = [[0, 0], [1, 0], [1, 1], [0, 1]]
end
_exp, _spec, glb = exportar(m, 't2')
%w[Quadro TV].each do |n|
  uvs = no_de(glb, n)[:uv]
  us = uvs.map(&:first)
  vs = uvs.map(&:last)
  confere("2/6 #{n}: imagem inteira uma vez só (UV de 0 a 1, sem repetir nem cortar)",
          perto(us.min, 0) && perto(us.max, 1) && perto(vs.min, 0) && perto(vs.max, 1),
          "u #{us.minmax.map { |x| x.round(3) }} v #{vs.minmax.map { |x| x.round(3) }}")
end
uv = uv_em(no_de(glb, 'Quadro'), [2.17, 0, 1.7])
confere('2b canto superior direito do quadro = UV (1, 1)', uv && perto(uv[0], 1) && perto(uv[1], 1), uv.inspect)

# ----------------------------------------------------------------------------
# 3. Componente rotacionado: a textura acompanha a peça
m = modelo
lam = mat('Lâmina freijó', tex('freijo', 0.6, 0.2))
d = Sketchup::ComponentDefinition.new('Tampo')
d.entities.add_face([mi(0, 0, 0.75), mi(1.2, 0, 0.75), mi(1.2, 0.6, 0.75), mi(0, 0.6, 0.75)]).material = lam
m.entities << Sketchup::ComponentInstance.new(d, Geom::Transformation.new, name: 'Tampo A')
m.entities << Sketchup::ComponentInstance.new(
  d, Geom::Transformation.translation(*mi(3, 1, 0)) * Geom::Transformation.rotation_z(37), name: 'Tampo B'
)
_exp, _spec, glb = exportar(m, 't3')
a = no_de(glb, 'Tampo A')
b = no_de(glb, 'Tampo B')
ua = a[:uv].map { |u| u.map { |x| x.round(5) } }.sort
ub = b[:uv].map { |u| u.map { |x| x.round(5) } }.sort
confere('3a peça girada 37 graus tem as MESMAS UVs da original', ua == ub)
confere('3b e a geometria de fato girou (posições diferentes)', a[:pos].map { |p| p.map { |x| x.round(3) } }.sort !=
                                                               b[:pos].map { |p| p.map { |x| x.round(3) } }.sort)
uv = uv_em(b, [3.0, 1.0, 0.75])
confere('3c canto de origem da peça girada continua em UV (0, 0)', uv && perto(uv[0], 0) && perto(uv[1], 0), uv.inspect)

# ----------------------------------------------------------------------------
# 4. Grupos aninhados, material herdado do grupo de fora e escala não uniforme
m = modelo
ext = mat('Tijolo do grupo', tex('tijolo', 0.25, 0.10))
outer = Sketchup::ComponentDefinition.new('Bloco externo')
inner = Sketchup::ComponentDefinition.new('Bloco interno')
inner.entities.add_face([mi(0, 0, 0), mi(0.5, 0, 0), mi(0.5, 0.5, 0), mi(0, 0.5, 0)]) # sem material
outer.entities << Sketchup::ComponentInstance.new(inner, Geom::Transformation.scaling(2, 1, 1), name: 'interno')
oi = Sketchup::ComponentInstance.new(outer, Geom::Transformation.translation(*mi(1, 1, 0)), name: 'Bloco externo')
oi.material = ext
m.entities << oi
_exp, spec, glb = exportar(m, 't4')
no = no_de(glb, 'Bloco externo')
uv = uv_em(no, [2.0, 1.5, 0])      # local (0,5 , 0,5) escalado 2x em X e movido (1,1)
confere('4a face sem material herda a textura do grupo de fora (UV saiu)', !no[:uv].nil?)
confere('4b UV em unidades de textura (0,5 m / 0,25 m = 2; 0,5 / 0,10 = 5) mesmo com escala 2x1x1',
        uv && perto(uv[0], 2.0) && perto(uv[1], 5.0), uv.inspect)

# ----------------------------------------------------------------------------
# 5. Frente e verso com texturas diferentes
m = modelo
frente = mat('Papel de parede', tex('papel', 0.5, 0.5))
verso = mat('Pedra do verso', tex('pedra', 0.4, 0.4))
grupo(m, 'Parede dupla') do |e|
  w = e.add_face([mi(0, 0, 0), mi(1, 0, 0), mi(1, 0, 1), mi(0, 0, 1)])
  w.material = frente
  w.back_material = verso
  w.uv_front = [[0, 0], [2, 0], [2, 2], [0, 2]]
  w.uv_back = [[5, 5], [7.5, 5], [7.5, 7.5], [5, 7.5]]
end
grupo(m, 'So verso') do |e|
  w = e.add_face([mi(2, 0, 0), mi(3, 0, 0), mi(3, 0, 1), mi(2, 0, 1)])
  w.back_material = verso
  w.uv_back = [[9, 9], [11.5, 9], [11.5, 11.5], [9, 11.5]]
end
_exp, _spec, glb = exportar(m, 't5')
uv = uv_em(no_de(glb, 'Parede dupla'), [1, 0, 1])
confere('5a face com frente pintada usa as UVs da FRENTE', uv && perto(uv[0], 2) && perto(uv[1], 2), uv.inspect)
uv = uv_em(no_de(glb, 'So verso'), [3, 0, 1])
confere('5b face pintada só no verso usa as UVs do VERSO', uv && perto(uv[0], 11.5) && perto(uv[1], 11.5), uv.inspect)

# ----------------------------------------------------------------------------
# 8. UVs inválidas: plano B sem falhar
m = modelo
ruim = mat('Mapeamento quebrado', tex('ruim', 0.5, 0.5))
parcial = mat('Metade boa', tex('parcial', 0.5, 0.5))
grupo(m, 'Quebrado') do |e|
  q = e.add_face([mi(0, 0, 0), mi(1, 0, 0), mi(1, 1, 0), mi(0, 1, 0)])
  q.material = ruim
  q.uv_front = [[Float::NAN, 0], [1, 0], [1, 1], [0, 1]]
  r = e.add_face([mi(0, 2, 0), mi(1, 2, 0), mi(1, 3, 0), mi(0, 3, 0)])
  r.material = ruim
  r.uv_front = [[3, 3], [3, 3], [3, 3], [3, 3]] # tudo no mesmo ponto: degenerado
end
grupo(m, 'Misto') do |e|
  q = e.add_face([mi(2, 0, 0), mi(3, 0, 0), mi(3, 1, 0), mi(2, 1, 0)])
  q.material = parcial
  r = e.add_face([mi(2, 2, 0), mi(3, 2, 0), mi(3, 3, 0), mi(2, 3, 0)])
  r.material = parcial
  r.uv_front = [[0, Float::NAN], [1, 0], [1, 1], [0, 1]]
end
ok = true
begin
  exp, spec, glb = exportar(m, 't8')
rescue StandardError => e
  ok = false
  puts e.full_message
end
confere('8a UVs inválidas não derrubam a exportação', ok)
if ok
  mq = spec['materials'].find { |x| x['name'] == 'Mapeamento quebrado' }
  confere('8b material sem nenhuma UV válida: sem marca de UV (Blender usa a projeção antiga)',
          mq['maps']['diffuse']['uv'].nil?)
  confere('8c ... e o pacote não leva TEXCOORD para ele', no_de(glb, 'Quebrado')[:uv].nil?)
  st = exp.uv_stats[spec['materials'].find { |x| x['name'] == 'Metade boa' }['id']]
  confere('8d face quebrada num material bom recebe UV de plano B (1 real + 1 plano B)',
          st == { real: 1, fallback: 1 }, st.inspect)
  uv = uv_em(no_de(glb, 'Misto'), [3, 3, 0])
  confere('8e plano B = projeção em escala real (3 m / 0,5 m = 6)', uv && perto(uv[0], 6) && perto(uv[1], 6), uv.inspect)
end

# ----------------------------------------------------------------------------
# 9. Corte de seção: UV interpolada no ponto cortado
m = modelo
cort = mat('Piso cortado', tex('cort', 0.5, 0.5))
grupo(m, 'Cortado') { |e| f = e.add_face([mi(0, 0, 0), mi(2, 0, 0), mi(2, 2, 0), mi(0, 2, 0)]); f.material = cort }
m.entities.active_section_plane = Sketchup::SectionPlane.new([1, 0, 0, -1.0 * M]) # fica x >= 1 m
_exp, _spec, glb = exportar(m, 't9')
no = no_de(glb, 'Cortado')
uv = uv_em(no, [1, 2, 0])
confere('9 vértice criado pelo corte tem UV interpolada (x = 1 m -> u = 2)', uv && perto(uv[0], 2) && perto(uv[1], 4), uv.inspect)
confere('9b uma UV por vértice depois do corte', no[:uv].length == no[:pos].length)

# ----------------------------------------------------------------------------
# 7. (no Python/Blender) Pacote antigo sem UVs - ver tests/headless_uvs.py
FileUtils.rm_rf(TMP)
puts "\n#{$total - $falhas} de #{$total} verificações passaram."
exit($falhas.zero? ? 0 : 1)
