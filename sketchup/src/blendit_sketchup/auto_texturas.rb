# encoding: UTF-8
# Blendit para SketchUp - texturas automáticas.
#
# Procura os materiais do projeto que são só cor (sem textura) e sugere, para
# cada um, uma textura real da biblioteca: piso, madeira, tecido, couro, pedra
# de bancada, concreto, tijolo. O tipo vem do nome do material e, quando o nome
# é genérico ("Cor_M05", "Material12"), de onde ele é usado (piso do ambiente,
# dentro de um sofá, cor de madeira...). Ela revisa numa lista e aplica; as
# cores do projeto são mantidas (a textura é tingida com a cor que ela
# escolheu). Tudo vira uma única ação - Ctrl+Z desfaz.
require 'json'

module BlenditSU
  module AutoTexturas
    # Tipo -> [rótulo, ids candidatos da biblioteca com a cor média aproximada (sRGB)]
    TIPOS = {
      'piso_madeira' => ['Piso de madeira', {
        'laminate_floor' => [190, 160, 120], 'laminate_floor_02' => [150, 110, 75],
        'oak_wood_planks' => [165, 125, 85], 'dark_wooden_planks' => [80, 55, 40],
        'WoodFloor051' => [200, 175, 140], 'WoodFloor070' => [160, 120, 80],
        'WoodFloor064' => [90, 60, 40], 'WoodFloor062' => [185, 160, 125],
        'WoodFloor007' => [210, 180, 140], 'herringbone_parquet' => [150, 105, 65] }],
      'piso' => ['Piso (porcelanato)', {
        'Tiles074' => [225, 222, 218], 'interior_tiles' => [220, 215, 205],
        'Tiles142' => [215, 205, 185], 'Tiles144' => [200, 185, 160],
        'Tiles143' => [190, 175, 150], 'concrete_tiles_02' => [165, 160, 150],
        'concrete_tiles' => [140, 140, 135], 'Terrazzo004' => [215, 212, 205],
        'Tiles138' => [50, 50, 50] }],
      'madeira' => ['Madeira / marcenaria', {
        'Wood095' => [215, 185, 145], 'ash_veneer' => [200, 170, 130],
        'oak_veneer_01' => [185, 145, 100], 'Wood049' => [170, 125, 80],
        'grey_oak_veneer_01' => [150, 140, 125], 'cherry_veneer' => [150, 85, 50],
        'natural_walnut_veneer' => [120, 80, 50], 'mocha_oak_veneer' => [110, 80, 60],
        'american_walnut_veneer' => [95, 65, 45], 'Wood051' => [70, 45, 30],
        'black_walnut_veneer_01' => [60, 40, 30] }],
      'tecido' => ['Tecido', {
        'wool_boucle' => [225, 220, 210], 'rough_linen' => [200, 190, 170],
        'cotton_jersey' => [180, 180, 180], 'Fabric082A' => [160, 160, 158],
        'Fabric030' => [130, 130, 130], 'velour_velvet' => [110, 100, 95] }],
      'couro' => ['Couro', { 'leather_white' => [225, 220, 210], 'brown_leather' => [140, 90, 55],
                             'leather_red_02' => [130, 40, 35] }],
      'bancada' => ['Pedra / bancada', {
        'Marble012' => [220, 220, 220], 'Marble014' => [215, 200, 175],
        'Granite004B' => [190, 170, 145], 'Travertine009' => [210, 195, 170],
        'Granite001A' => [90, 90, 90], 'Marble016' => [30, 30, 30] }],
      'concreto' => ['Concreto / cimento queimado', {
        'smooth_concrete_floor' => [130, 128, 125], 'concrete_wall_008' => [150, 150, 145],
        'concrete_slab_wall' => [160, 158, 150] }],
      'tijolo' => ['Tijolo', { 'red_brick' => [150, 75, 55], 'painted_brick' => [220, 218, 210],
                               'castle_brick_02_white' => [210, 205, 195] }],
      'reboco' => ['Reboco / textura', { 'white_stucco' => [225, 222, 215], 'grey_plaster' => [170, 168, 160],
                                         'beige_wall_001' => [205, 190, 165] }]
    }.freeze

    NAO_MEXER = /vidro|glass|espelh|mirror|metal|inox|a[cç]o\b|alum|cromad|chrome|steel|lumin|l[aâ]mpada|\bled\b|\bluz\b|[aá]gua|water|grama|grass|ceu|sky/i.freeze
    REGRAS = [
      [/couro|leather|courino|corino/i, 'couro'],
      [/tecido|linho|fabric|veludo|velvet|sof[aá]|almofad|estof|boucl|cortina|curtain|suede|camur|chenille|tapete|carpet|rug\b/i, 'tecido'],
      [/granito|m[aá]rmore|marble|bancada|silestone|quartzo|travertin|pedra|stone|countertop/i, 'bancada'],
      [/cimento queimado|concreto|concrete|cimentici|microcimento/i, 'concreto'],
      [/tijol|brick/i, 'tijolo'],
      [/reboco|grafiato|textura|stucco|plaster/i, 'reboco'],
      [/assoalho|parquet|taco|piso.*madeira|vin[ií]lico|laminado|wood ?floor|flooring/i, 'piso_madeira'],
      [/porcelanato|cer[aâ]mic|piso|floor|tile|azulejo|revestimento/i, 'piso'],
      [/madeira|wood|mdf|freij|carvalho|nogueira|oak|walnut|l[aâ]mina|marcenaria|amadeirad|cumaru|jatob|ip[eê]\b|teca|pinus/i, 'madeira']
    ].freeze
    GENERICO = /\A\s*(\[?(material|mat|color|cor|default|padr[aã]o)(?![[:alpha:]])|<|\d+\s*\z)/i.freeze
    ESTOFADO = /sof[aá]|poltrona|almofad|puff|pufe|estofad|cabeceira|cama|colch|couch|armchair|cushion|pillow|bed\b/i.freeze
    MAX_FACES = 300_000

    # ------------------------------------------------------------ análise
    def self.analisar(model)
      uso = {}          # material -> {area:, piso:, estofado:}
      z_min = model.bounds.min.z.to_f
      cont = [0]
      percorrer(model.entities, Geom::Transformation.new, nil, '', uso, z_min, cont)
      sugestoes = []
      model.materials.each do |m|
        next if m.texture
        next if m.respond_to?(:alpha) && m.alpha.to_f < 0.99
        u = uso[m]
        next unless u && u[:area] > 0
        nome = (m.respond_to?(:display_name) ? m.display_name : m.name).to_s
        next if nome =~ NAO_MEXER
        tipo = classificar(m, nome, u)
        next unless tipo
        sugestoes << { 'material' => m.name.to_s, 'nome' => nome, 'tipo' => tipo,
                       'rotulo' => TIPOS[tipo][0], 'cor' => cor_hex(m.color),
                       'textura' => mais_parecida(tipo, m.color, nome) }
      end
      sugestoes
    end

    def self.percorrer(ents, tr, herdado, contexto, uso, z_min, cont)
      ents.each do |e|
        return if cont[0] > MAX_FACES
        next if e.respond_to?(:hidden?) && e.hidden?
        next if e.respond_to?(:layer) && e.layer && !e.layer.visible?
        if e.is_a?(Sketchup::Face)
          cont[0] += 1
          m = e.material || herdado || e.back_material
          next unless m
          u = (uso[m] ||= { area: 0.0, piso: 0.0, estofado: 0.0 })
          a = e.area.to_f
          u[:area] += a
          n = e.normal.transform(tr)
          if n.length > 0 && n.normalize.z > 0.95
            z = e.bounds.min.transform(tr).z.to_f
            u[:piso] += a if z - z_min < 20.0           # ~50 cm acima do ponto mais baixo
          end
          u[:estofado] += a if contexto =~ ESTOFADO
        elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          d = e.definition
          nome = "#{contexto} #{e.name} #{d.name}"
          percorrer(d.entities, tr * e.transformation, e.material || herdado, nome, uso, z_min, cont)
        end
      end
    end

    def self.classificar(m, nome, u)
      REGRAS.each do |re, tipo|
        next unless nome =~ re
        return tipo == 'piso' && amadeirado?(m.color) ? 'piso_madeira' : tipo
      end
      piso = u[:piso] / u[:area]
      return(amadeirado?(m.color) ? 'piso_madeira' : 'piso') if piso > 0.6 && u[:area] > 1500.0 # > ~1 m²
      return 'tecido' if u[:estofado] / u[:area] > 0.6 && !amadeirado?(m.color)
      return 'madeira' if amadeirado?(m.color)
      nil
    end

    # Tom de madeira: marrom/caramelo/bege-dourado, não cinza nem branco puro.
    def self.amadeirado?(c)
      r, g, b = c.red / 255.0, c.green / 255.0, c.blue / 255.0
      mx = [r, g, b].max
      mn = [r, g, b].min
      return false if mx < 0.12 || mx - mn < 0.12
      s = (mx - mn) / mx
      h = if mx == r then 60.0 * (((g - b) / (mx - mn)) % 6)
          elsif mx == g then 60.0 * (((b - r) / (mx - mn)) + 2)
          else 60.0 * (((r - g) / (mx - mn)) + 4)
          end
      h.between?(12.0, 48.0) && s.between?(0.2, 0.85)
    end

    # A mais parecida na cor; um nome em comum ("freijó", "nogueira",
    # "carvalho", "linho", "carrara"...) tem prioridade.
    def self.mais_parecida(tipo, c, nome = '')
      alvo = [c.red, c.green, c.blue]
      txt = plano(nome)
      TIPOS[tipo][1].min_by do |id, rgb|
        dr, dg, db = rgb[0] - alvo[0], rgb[1] - alvo[1], rgb[2] - alvo[2]
        d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
        e = entrada(id)
        palavras = e ? plano(e[1]).split(/[^a-z]+/).select { |w| w.length >= 4 } - GENERICAS : []
        bonus = palavras.select { |w| txt =~ /(?<![a-z])#{w}/ }.sum { |w| CORES.include?(w) ? 300_000 : 1_000_000 }
        d - bonus
      end[0]
    end

    GENERICAS = %w[tecido madeira piso porcelanato revestimento pedra placas bancada parede
                   concreto tijolo reboco assoalho laminado vinilico lamina].freeze
    CORES = %w[cinza branco branca preto preta bege claro clara escuro escura natural marrom
               creme areia verde azul vermelho].freeze

    def self.plano(t)
      t.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').downcase
    end

    def self.cor_hex(c)
      format('#%02x%02x%02x', c.red, c.green, c.blue)
    end

    def self.entrada(id)
      Texturas::CATALOGO.find { |e| e[3] == id }
    end

    # ------------------------------------------------------------ aplicar
    # escolhas: [{ 'material' => nome interno, 'textura' => id }]
    def self.aplicar(model, escolhas, manter_cor)
      prontos = []
      escolhas.each_with_index do |esc, i|
        ent = entrada(esc['textura'].to_s)
        mat = model.materials[esc['material'].to_s]
        next unless ent && mat
        Sketchup.status_text = "Blendit: baixando textura #{i + 1} de #{escolhas.length} (#{ent[1]})..."
        diff, bump, (wm, hm), rugo = Texturas.fetch(ent)
        prontos << [mat, ent, diff, bump, wm, hm, rugo]
      end
      model.start_operation('Blendit: texturas automáticas', true)
      prontos.each do |mat, ent, diff, bump, wm, hm, rugo|
        cor = mat.color
        mat.texture = diff
        mat.texture.size = [wm * Texturas::INCH, hm * Texturas::INCH] if mat.texture
        if manter_cor
          if mat.respond_to?(:colorize_type=) && defined?(Sketchup::Material::COLORIZE_TINT)
            mat.colorize_type = Sketchup::Material::COLORIZE_TINT
          end
          mat.color = cor
        end
        mat.set_attribute('blendit', 'textura', ent[3])
        mat.set_attribute('blendit', 'rugosidade', ent[5])
        mat.set_attribute('blendit', 'relevo', bump) if bump
        mat.set_attribute('blendit', 'rugosidade_mapa', rugo) if rugo
      end
      model.commit_operation
      Sketchup.status_text = ''
      prontos.length
    rescue StandardError => e
      model.abort_operation rescue nil
      raise e
    end

    # ------------------------------------------------------------ janela
    def self.show
      model = Sketchup.active_model
      return unless model
      Sketchup.status_text = 'Blendit: analisando os materiais do projeto...'
      sug = analisar(model)
      Sketchup.status_text = ''
      if sug.empty?
        UI.messagebox("Não achei materiais para texturizar.\n\nOs materiais que já têm textura, vidros, " \
                      'metais e cores de pintura ficam como estão.')
        return
      end
      opcoes = TIPOS.transform_values do |(rotulo, ids)|
        { 'rotulo' => rotulo,
          'itens' => ids.keys.map { |id| e = entrada(id); e && { 'id' => id, 'nome' => e[1], 'thumb' => Texturas.thumb(e) } }.compact }
      end
      dlg = UI::HtmlDialog.new(dialog_title: 'Blendit - Texturas automáticas', width: 860, height: 640,
                               preferences_key: 'BlenditAutoTexturas', style: UI::HtmlDialog::STYLE_DIALOG)
      dlg.set_html(html(sug, opcoes))
      dlg.add_action_callback('aplicar') do |_c, dados|
        d = JSON.parse(dados.to_s)
        begin
          n = aplicar(model, d['escolhas'], d['manter_cor'])
          dlg.close
          UI.messagebox("#{n} materiais receberam textura real.\n\nPara desfazer: Editar > Desfazer (Ctrl+Z).")
        rescue StandardError => e
          dlg.execute_script("erro(#{JSON.generate("Não deu certo: #{e.message}")})")
        end
      end
      dlg.add_action_callback('cancelar') { |_c| dlg.close }
      dlg.show
    end

    def self.html(sug, opcoes)
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{font:13px Segoe UI,Arial,sans-serif;margin:0;padding:14px;background:#fafafa;color:#222}
        h2{font-size:16px;margin:0 0 4px} p{margin:0 0 10px;color:#555}
        table{width:100%;border-collapse:collapse;background:#fff}
        td,th{padding:6px;border-bottom:1px solid #e5e5e5;text-align:left;vertical-align:middle}
        .sw{width:28px;height:28px;border-radius:4px;border:1px solid #ccc}
        img{width:44px;height:44px;border-radius:4px;object-fit:cover;background:#eee}
        select{max-width:280px} .bar{margin-top:12px;display:flex;gap:10px;align-items:center}
        button{padding:7px 16px;border:0;border-radius:6px;background:#1f6feb;color:#fff;cursor:pointer}
        button.sec{background:#ddd;color:#222} #err{color:#b00}
        </style></head><body>
        <h2>Texturas automáticas</h2>
        <p>Sugestões de textura real para os materiais que hoje são só cor. Confira, troque o que quiser e aplique.
        Pinturas lisas, vidros e metais ficam como estão. A textura baixa só na primeira vez.</p>
        <table id="t"><tr><th></th><th>Cor</th><th>Material</th><th>Tipo</th><th>Textura</th><th></th></tr></table>
        <div class="bar"><label><input type="checkbox" id="cor" checked> Manter as cores do projeto (a textura é tingida com a cor do material)</label></div>
        <div class="bar"><button onclick="ok()">Aplicar texturas</button><button class="sec" onclick="sketchup.cancelar()">Cancelar</button><span id="err"></span></div>
        <script>
        var S=#{JSON.generate(sug)}, O=#{JSON.generate(opcoes)};
        function esc(s){return String(s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
        function thumb(tipo,id){var it=O[tipo].itens.filter(function(x){return x.id==id})[0];return it?it.thumb:''}
        var t=document.getElementById('t');
        S.forEach(function(s,i){
          var tipos=Object.keys(O).map(function(k){return '<option value="'+k+'"'+(k==s.tipo?' selected':'')+'>'+esc(O[k].rotulo)+'</option>'}).join('');
          var tr=document.createElement('tr');
          tr.innerHTML='<td><input type="checkbox" id="c'+i+'" checked></td><td><div class="sw" style="background:'+s.cor+'"></div></td>'+
            '<td>'+esc(s.nome)+'</td><td><select id="k'+i+'" onchange="tipo('+i+')">'+tipos+'</select></td>'+
            '<td><select id="x'+i+'" onchange="img('+i+')"></select></td><td><img id="i'+i+'"></td>';
          t.appendChild(tr); preencher(i,s.tipo,s.textura);
        });
        function preencher(i,tipo,sel){var x=document.getElementById('x'+i);
          x.innerHTML=O[tipo].itens.map(function(it){return '<option value="'+it.id+'"'+(it.id==sel?' selected':'')+'>'+esc(it.nome)+'</option>'}).join('');img(i)}
        function tipo(i){preencher(i,document.getElementById('k'+i).value,null)}
        function img(i){document.getElementById('i'+i).src=thumb(document.getElementById('k'+i).value,document.getElementById('x'+i).value)}
        function erro(m){document.getElementById('err').textContent=m}
        function ok(){var e=[];S.forEach(function(s,i){if(document.getElementById('c'+i).checked)e.push({material:s.material,textura:document.getElementById('x'+i).value})});
          if(!e.length){erro('Nenhum material marcado.');return}
          erro('Baixando e aplicando... aguarde.');
          sketchup.aplicar(JSON.stringify({escolhas:e,manter_cor:document.getElementById('cor').checked}))}
        </script></body></html>
      HTML
    end
  end
end
