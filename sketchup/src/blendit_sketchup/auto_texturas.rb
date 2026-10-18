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
require_relative 'classificador'
require_relative 'biblioteca_materiais'

module BlenditSU
  module AutoTexturas
    # A biblioteca (categoria -> texturas) e a classificação moram em
    # biblioteca_materiais.rb e classificador.rb (Ruby puro, com testes
    # próprios). Aqui fica só o que depende do SketchUp: medir o uso de cada
    # material no modelo, a janela de revisão e a aplicação.
    ESTOFADO = /sof[aá]|poltrona|almofad|puff|pufe|estofad|cabeceira|cama|colch|couch|armchair|cushion|pillow|bed\b/i.freeze
    MAX_FACES = 300_000
    POL2_M2 = 0.0254 * 0.0254

    # ------------------------------------------------------------ análise
    def self.analisar(model, regras = BibliotecaMateriais.carregar_regras)
      uso = {}          # material -> {area:, piso:, parede:, estofado:}
      z_min = model.bounds.min.z.to_f
      cont = [0]
      percorrer(model.entities, Geom::Transformation.new, nil, '', uso, z_min, cont)
      nomes = Texturas::CATALOGO.to_h { |e| [e[3], e[1]] }
      sugestoes = []
      model.materials.each do |m|
        u = uso[m]
        next unless u && u[:area] > 0
        nome = (m.respond_to?(:display_name) ? m.display_name : m.name).to_s
        rgb = [m.color.red, m.color.green, m.color.blue]
        cl = Classificador.classificar(caracteristicas(m, nome, rgb, u), regras)
        cat = cl[:categoria]
        next unless cat && BibliotecaMateriais.com_textura?(cat)
        sugestoes << { 'material' => m.name.to_s, 'nome' => nome, 'tipo' => cat,
                       'rotulo' => BibliotecaMateriais.rotulo(cat), 'cor' => cor_hex(m.color),
                       'confianca' => cl[:confianca].to_s, 'motivo' => cl[:motivo],
                       'textura' => BibliotecaMateriais.ordenar(cat, rgb, nome, nomes, regras).first }
      end
      sugestoes
    end

    def self.caracteristicas(m, nome, rgb, u)
      { nome: nome, rgb: rgb, alpha: m.respond_to?(:alpha) ? m.alpha.to_f : 1.0,
        tem_textura: !m.texture.nil?, area_m2: u[:area] * POL2_M2,
        frac_piso: u[:piso] / u[:area], frac_parede: u[:parede] / u[:area],
        frac_estofado: u[:estofado] / u[:area] }
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
          u = (uso[m] ||= { area: 0.0, piso: 0.0, parede: 0.0, estofado: 0.0 })
          a = e.area.to_f
          u[:area] += a
          n = e.normal.transform(tr)
          nz = n.length > 0 ? n.normalize.z : 0.0
          if nz > 0.95
            z = e.bounds.min.transform(tr).z.to_f
            u[:piso] += a if z - z_min < 20.0           # ~50 cm acima do ponto mais baixo
          elsif nz.abs < 0.1
            u[:parede] += a
          end
          u[:estofado] += a if contexto =~ ESTOFADO
        elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          d = e.definition
          nome = "#{contexto} #{e.name} #{d.name}"
          percorrer(d.entities, tr * e.transformation, e.material || herdado, nome, uso, z_min, cont)
        end
      end
    end

    def self.cor_hex(c)
      format('#%02x%02x%02x', c.red, c.green, c.blue)
    end

    def self.entrada(id)
      Texturas::CATALOGO.find { |e| e[3] == id }
    end

    # ------------------------------------------------------------ aplicar
    # escolhas: [{ 'material' => nome interno, 'textura' => id, 'tipo' => categoria }]
    # so_render: não troca nada no SketchUp - só guarda a escolha no material
    # (o modo "Automático" do render usa); rejeitados: materiais desmarcados.
    def self.aplicar(model, escolhas, manter_cor, so_render = false, rejeitados = [])
      return guardar_escolhas(model, escolhas, rejeitados) if so_render
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

    ATTRS_AUTO = %w[auto_textura auto_categoria auto_decisao].freeze

    def self.guardar_escolhas(model, escolhas, rejeitados)
      escolhas.each do |esc|                      # baixa já (avisa cedo se faltar internet)
        ent = entrada(esc['textura'].to_s)
        Texturas.fetch(ent) if ent
      end
      model.start_operation('Blendit: materiais automáticos no render', true)
      n = 0
      escolhas.each do |esc|
        mat = model.materials[esc['material'].to_s]
        next unless mat && entrada(esc['textura'].to_s)
        mat.set_attribute('blendit', 'auto_textura', esc['textura'].to_s)
        mat.set_attribute('blendit', 'auto_categoria', esc['tipo'].to_s)
        mat.set_attribute('blendit', 'auto_decisao', 'aprovado')
        n += 1
      end
      rejeitados.each do |nome|
        mat = model.materials[nome.to_s]
        next unless mat
        mat.set_attribute('blendit', 'auto_decisao', 'rejeitado')
      end
      model.commit_operation
      n
    rescue StandardError => e
      model.abort_operation rescue nil
      raise e
    end

    # Apaga todas as escolhas "só no render" do projeto (desfazível).
    def self.limpar_escolhas(model)
      model.start_operation('Blendit: limpar materiais automáticos', true)
      n = 0
      model.materials.each do |m|
        tinha = false
        ATTRS_AUTO.each do |k|
          next if m.get_attribute('blendit', k).nil?
          m.delete_attribute('blendit', k)
          tinha = true
        end
        n += 1 if tinha
      end
      model.commit_operation
      n
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
      opcoes = BibliotecaMateriais::CATEGORIAS.select { |k, _| BibliotecaMateriais.com_textura?(k) }.to_h do |k, c|
        [k, { 'rotulo' => c[:rotulo],
              'itens' => c[:texturas].keys.map { |id| e = entrada(id); e && { 'id' => id, 'nome' => e[1], 'thumb' => Texturas.thumb(e) } }.compact }]
      end
      dlg = UI::HtmlDialog.new(dialog_title: 'Blendit - Texturas automáticas', width: 860, height: 640,
                               preferences_key: 'BlenditAutoTexturas', style: UI::HtmlDialog::STYLE_DIALOG)
      dlg.set_html(html(sug, opcoes))
      dlg.add_action_callback('aplicar') do |_c, dados|
        d = JSON.parse(dados.to_s)
        begin
          so = d['so_render'] ? true : false
          n = aplicar(model, d['escolhas'], d['manter_cor'], so, d['rejeitados'] || [])
          dlg.close
          if so
            BlenditSU.set_pref('materiais', 'automatico') if BlenditSU.respond_to?(:set_pref)
            UI.messagebox("#{n} escolhas guardadas para o render (o SketchUp não mudou).\n\n" \
                          'Materiais no render ficou em "Automático". Para desfazer: Ctrl+Z ou ' \
                          'Blendit > Materiais no render > Limpar escolhas automáticas.')
          else
            UI.messagebox("#{n} materiais receberam textura real.\n\nPara desfazer: Editar > Desfazer (Ctrl+Z).")
          end
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
        .c{font-size:11px;padding:2px 7px;border-radius:9px;white-space:nowrap}
        .alta{background:#d9f2df;color:#185c2a}.media{background:#fff1c9;color:#6b4e00}.baixa{background:#fde0dc;color:#8a1f12}
        select{max-width:280px} .bar{margin-top:12px;display:flex;gap:10px;align-items:center}
        button{padding:7px 16px;border:0;border-radius:6px;background:#1f6feb;color:#fff;cursor:pointer}
        button.sec{background:#ddd;color:#222} #err{color:#b00}
        </style></head><body>
        <h2>Texturas automáticas</h2>
        <p>Sugestões de textura real para os materiais que hoje são só cor. A <b>certeza</b> diz de onde veio a
        sugestão: <b>alta</b> = o nome do material; <b>média</b> = onde ele é usado (piso, sofá); <b>baixa</b> = só a cor
        (vem desmarcada). É a categoria da superfície, não o produto exato. Pinturas lisas, vidros e metais ficam como estão.</p>
        <table id="t"><tr><th></th><th>Cor</th><th>Material</th><th>Certeza</th><th>Tipo</th><th>Textura</th><th></th></tr></table>
        <div class="bar"><label><input type="radio" name="modo" id="so" checked> Só no render (o SketchUp não muda - recomendado)</label>
        <label><input type="radio" name="modo" id="sk"> Trocar a textura no SketchUp também</label></div>
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
          var cf={alta:'alta',media:'média',baixa:'baixa'}[s.confianca]||s.confianca;
          tr.innerHTML='<td><input type="checkbox" id="c'+i+'"'+(s.confianca=='baixa'?'':' checked')+'></td><td><div class="sw" style="background:'+s.cor+'"></div></td>'+
            '<td>'+esc(s.nome)+'</td><td><span class="c '+esc(s.confianca)+'" title="'+esc(s.motivo)+'">'+esc(cf)+'</span></td>'+
            '<td><select id="k'+i+'" onchange="tipo('+i+')">'+tipos+'</select></td>'+
            '<td><select id="x'+i+'" onchange="img('+i+')"></select></td><td><img id="i'+i+'"></td>';
          t.appendChild(tr); preencher(i,s.tipo,s.textura);
        });
        function preencher(i,tipo,sel){var x=document.getElementById('x'+i);
          x.innerHTML=O[tipo].itens.map(function(it){return '<option value="'+it.id+'"'+(it.id==sel?' selected':'')+'>'+esc(it.nome)+'</option>'}).join('');img(i)}
        function tipo(i){preencher(i,document.getElementById('k'+i).value,null)}
        function img(i){document.getElementById('i'+i).src=thumb(document.getElementById('k'+i).value,document.getElementById('x'+i).value)}
        function erro(m){document.getElementById('err').textContent=m}
        function ok(){var e=[],r=[];S.forEach(function(s,i){if(document.getElementById('c'+i).checked)e.push({material:s.material,tipo:document.getElementById('k'+i).value,textura:document.getElementById('x'+i).value});else r.push(s.material)});
          if(!e.length){erro('Nenhum material marcado.');return}
          erro('Baixando e aplicando... aguarde.');
          sketchup.aplicar(JSON.stringify({escolhas:e,rejeitados:r,manter_cor:document.getElementById('cor').checked,so_render:document.getElementById('so').checked}))}
        </script></body></html>
      HTML
    end
  end
end
