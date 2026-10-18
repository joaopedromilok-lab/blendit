# encoding: UTF-8
# Blendit para SketchUp - objetos de decoração realistas (Poly Haven, CC0).
#
# Plantas, vasos, livros, luminárias de mesa, móveis pequenos... escaneados de
# verdade e muito pesados para o SketchUp. Aqui eles entram como um SUBSTITUTO
# LEVE: um componente com a caixa do tamanho real do objeto e uma foto dele em
# pé no meio, para posicionar, girar e escalar à vontade. No render o Blendit
# troca o substituto pelo modelo 3D de verdade, no mesmo lugar.
#
# Fonte (documentação consultada em 18/10/2026, api.polyhaven.com):
#   GET /assets?type=models -> { id => { name, categories, tags, ... } }
#   GET /info/{id}          -> dimensions [x, y, z] em mm (z = altura)
#   GET /files/{id}         -> gltf -> '1k' -> 'gltf' -> { url, include: { caminho => { url, size } } }
# Termos da API: User-Agent próprio; modelos CC0; indicar a origem (Poly Haven).
require 'json'
require 'fileutils'
require 'uri'

module BlenditSU
  module Objetos
    PH_API = 'https://api.polyhaven.com'.freeze
    LISTA_URL = "#{PH_API}/assets?type=models".freeze
    MINIATURA = 'https://cdn.polyhaven.com/asset_img/thumbs/%s.png?width=256&height=256'.freeze
    RESOLUCAO = '1k'.freeze     # texturas 1K: leves e nítidas o bastante para objetos de decoração
    ATTR = 'objeto_ph'.freeze
    MM = 1.0 / 25.4             # mm -> polegadas (unidade interna do SketchUp)
    ID_OK = /\A[a-z0-9_\-]+\z/i.freeze

    def self.dir
      base = ENV['LOCALAPPDATA'] || Dir.tmpdir
      File.join(base, 'BlenditSketchUp', 'objetos')
    end

    def self.pasta(id)
      File.join(dir, id.to_s)
    end

    # ------------------------------------------------------------ lista
    # Lista de modelos do Poly Haven (cacheada; 'atualizar' busca de novo).
    def self.lista(atualizar = false)
      cache = File.join(dir, 'lista.json')
      File.delete(cache) if atualizar && File.exist?(cache)
      dados = Texturas.json(LISTA_URL, cache)
      raise 'resposta inesperada do Poly Haven' unless dados.is_a?(Hash)
      itens(dados)
    end

    # Ruby puro (testável): resposta de /assets -> [{ id, nome, categorias, tags, miniatura }]
    def self.itens(dados)
      dados.map do |id, a|
        next unless id.is_a?(String) && id =~ ID_OK && a.is_a?(Hash) && a['type'] == 2
        nome = a['name'].to_s.strip
        next if nome.empty?
        { 'id' => id, 'nome' => nome, 'categorias' => Array(a['categories']).grep(String),
          'tags' => Array(a['tags']).grep(String), 'miniatura' => format(MINIATURA, id),
          'grupo' => grupo(Array(a['categories'])) }
      end.compact.sort_by { |x| [x['grupo'] == 'Outros' ? 1 : 0, x['grupo'], x['nome']] }
    end

    GRUPOS = [
      ['Plantas', %w[plants potted\ plants flowers]],
      ['Luminárias', %w[lighting lamps]],
      ['Móveis', %w[furniture seating tables chairs shelves]],
      ['Decoração', %w[decorative decor vases books ornaments]],
      ['Cozinha e mesa', %w[kitchen food tableware]],
      ['Banheiro', %w[bathroom]]
    ].freeze

    def self.grupo(cats)
      c = cats.map { |x| x.to_s.downcase }
      g = GRUPOS.find { |_n, ks| (ks & c).any? }
      g ? g[0] : 'Outros'
    end

    # ------------------------------------------------------------ download
    # Baixa o modelo (glTF + .bin + texturas 1K) uma vez. -> caminho do .gltf
    def self.gltf_local(id)
      Dir.glob(File.join(pasta(id), '*.gltf')).first
    end

    def self.pronto?(id)
      g = gltf_local(id)
      g && File.exist?(File.join(pasta(id), 'ok'))
    end

    def self.garantir(id)
      raise ArgumentError, 'id inválido' unless id.to_s =~ ID_OK
      return gltf_local(id) if pronto?(id)
      d = pasta(id)
      files = Texturas.json("#{PH_API}/files/#{id}", File.join(d, 'files.json'))
      pacote = arquivos_gltf(files)
      raise "o objeto #{id} não tem versão glTF" unless pacote
      destino = File.join(d, File.basename(URI(pacote[:url]).path))
      Texturas.download(pacote[:url], destino) unless File.size?(destino)
      pacote[:include].each do |rel, url|
        alvo = File.join(d, rel)
        Texturas.download(url, alvo) unless File.size?(alvo)
      end
      File.write(File.join(d, 'ok'), Time.now.to_s)
      destino
    end

    # Ruby puro: /files/{id} -> { url:, include: { caminho_relativo => url } } (1K, ou a menor).
    # Caminhos fora da pasta do objeto ('..', absolutos) são recusados.
    def self.arquivos_gltf(files)
      g = files.is_a?(Hash) ? files['gltf'] : nil
      return nil unless g.is_a?(Hash)
      res = g.key?(RESOLUCAO) ? RESOLUCAO : g.keys.min_by { |k| k.to_i }
      pk = g[res].is_a?(Hash) ? g[res]['gltf'] : nil
      return nil unless pk.is_a?(Hash) && pk['url'].to_s.start_with?('https://')
      inc = {}
      (pk['include'].is_a?(Hash) ? pk['include'] : {}).each do |rel, v|
        next unless v.is_a?(Hash) && v['url'].to_s.start_with?('https://')
        r = rel.to_s.tr('\\', '/')
        next if r.start_with?('/') || r.split('/').include?('..') || r =~ /\A[a-z]:/i
        inc[r] = v['url']
      end
      { url: pk['url'], include: inc }
    end

    # Tamanho real [larg, prof, alt] em metros (Poly Haven: mm, z = altura).
    def self.dimensoes(id)
      info = Texturas.json("#{PH_API}/info/#{id}", File.join(pasta(id), 'info.json'))
      d = info['dimensions']
      return [0.5, 0.5, 0.5] unless d.is_a?(Array) && d.length >= 3 && d.all? { |v| v.is_a?(Numeric) && v > 0 }
      d.first(3).map { |v| v.to_f / 1000.0 }
    end

    # ------------------------------------------------------------ substituto no SketchUp
    def self.nome_definicao(nome)
      "Blendit objeto - #{nome}"
    end

    # Cria (ou reaproveita) o componente substituto: caixa do tamanho real (só
    # arestas) + a foto do objeto em pé no meio. Origem no centro da base.
    def self.substituto(model, item)
      id = item['id']
      nome = nome_definicao(item['nome'])
      defn = model.definitions.find { |d| d.get_attribute('blendit', ATTR) == id }
      return defn if defn
      w, p, h = dimensoes(id).map { |v| v / 0.0254 }
      thumb = File.join(pasta(id), 'miniatura.png')
      begin
        Texturas.download(item['miniatura'] || format(MINIATURA, id), thumb) unless File.size?(thumb)
      rescue StandardError
        thumb = nil
      end
      model.start_operation('Blendit: objeto de decoração', true)
      defn = model.definitions.add(nome)
      ents = defn.entities
      x0, x1, y0, y1 = -w / 2, w / 2, -p / 2, p / 2
      base = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]
      4.times do |i|
        a, b = base[i], base[(i + 1) % 4]
        ents.add_line([a[0], a[1], 0], [b[0], b[1], 0])
        ents.add_line([a[0], a[1], h], [b[0], b[1], h])
        ents.add_line([a[0], a[1], 0], [a[0], a[1], h])
      end
      face = ents.add_face([x0, 0, 0], [x1, 0, 0], [x1, 0, h], [x0, 0, h])
      if face && thumb && File.file?(thumb)
        mat = model.materials.add("Blendit objeto - #{id}")
        mat.texture = thumb
        face.material = mat
        face.back_material = mat
        pts = [Geom::Point3d.new(x0, 0, 0), Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(x1, 0, 0), Geom::Point3d.new(1, 0, 0),
               Geom::Point3d.new(x1, 0, h), Geom::Point3d.new(1, 1, 0), Geom::Point3d.new(x0, 0, h), Geom::Point3d.new(0, 1, 0)]
        [true, false].each { |frente| face.position_material(mat, pts, frente) rescue nil }
      end
      defn.set_attribute('blendit', ATTR, id)
      defn.set_attribute('blendit', 'objeto_nome', item['nome'])
      defn.description = "Substituto leve: no render do Blendit vira o modelo 3D real (#{item['nome']}, Poly Haven, CC0)."
      model.commit_operation
      defn
    rescue StandardError
      model.abort_operation rescue nil
      raise
    end

    def self.inserir(item)
      model = Sketchup.active_model
      Sketchup.status_text = "Blendit: baixando \"#{item['nome']}\" (só na primeira vez)..."
      garantir(item['id'])
      defn = substituto(model, item)
      Sketchup.status_text = ''
      model.place_component(defn)
    end

    # ------------------------------------------------------------ janela
    def self.show
      dlg = UI::HtmlDialog.new(dialog_title: 'Blendit - Objetos de decoração', preferences_key: 'BlenditObjetos',
                               width: 860, height: 680, style: UI::HtmlDialog::STYLE_DIALOG)
      dlg.set_html(html)
      enviar = lambda do |atualizar|
        begin
          dlg.execute_script("mostrar(#{JSON.generate(lista(atualizar))})")
        rescue StandardError => e
          dlg.execute_script("status(#{JSON.generate("Não deu para carregar a lista: #{e.message}. Confira a internet.")})")
        end
      end
      dlg.add_action_callback('pronto') { |_c| UI.start_timer(0.05, false) { enviar.call(false) } }
      dlg.add_action_callback('atualizar') { |_c| enviar.call(true) }
      dlg.add_action_callback('inserir') do |_c, dados|
        item = JSON.parse(dados.to_s)
        dlg.execute_script("status(#{JSON.generate("Baixando \"#{item['nome']}\"... (só na primeira vez)")})")
        UI.start_timer(0.05, false) do
          begin
            inserir(item)
            dlg.execute_script("status(#{JSON.generate("\"#{item['nome']}\": clique no modelo para posicionar.")}, true)")
          rescue StandardError => e
            dlg.execute_script("status(#{JSON.generate("Não deu para baixar: #{e.message}")})")
          end
        end
      end
      dlg.show
    end

    def self.html
      <<~HTML
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><style>
        :root{--bg:#f6f5f2;--fg:#222;--mut:#6b6b6b;--card:#fff;--line:#dedbd4;--acc:#2d6a4f}
        *{box-sizing:border-box} body{margin:0;font:14px/1.4 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--fg)}
        header{position:sticky;top:0;background:var(--bg);padding:12px 18px 10px;border-bottom:1px solid var(--line)}
        .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
        input,select{font:inherit;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:#fff}
        input{flex:1;min-width:180px}
        .btn{font:inherit;padding:6px 12px;border-radius:6px;border:1px solid var(--acc);background:#fff;color:var(--acc);cursor:pointer}
        #st{color:var(--mut);min-height:20px;margin-top:6px} #st.ok{color:var(--acc);font-weight:600}
        main{padding:10px 18px 24px}
        .g{display:grid;grid-template-columns:repeat(auto-fill,minmax(128px,1fr));gap:10px}
        .c{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:0;cursor:pointer;text-align:left;overflow:hidden;font:inherit;color:inherit}
        .c:hover{border-color:var(--acc)} .c img{display:block;width:100%;aspect-ratio:1;object-fit:contain;background:#ecebe6}
        .c span{display:block;padding:6px 8px 2px;font-size:12px} .c small{display:block;color:var(--mut);font-size:11px;padding:0 8px 8px}
        .pag{display:flex;gap:8px;justify-content:center;align-items:center;margin-top:12px}
        footer{color:var(--mut);font-size:11px;padding:0 18px 16px}
        </style></head><body>
        <header>
          <div class="row"><input type="search" id="q" placeholder="Buscar (nomes em inglês): plant, vase, book, lamp, chair..." oninput="pag=0;listar()">
          <select id="gr" onchange="pag=0;listar()"><option value="">Todos</option></select>
          <button class="btn" onclick="sketchup.atualizar()">Atualizar lista</button></div>
          <div id="st">Carregando a lista do Poly Haven...</div>
        </header>
        <main><div class="g" id="grid"></div><div class="pag" id="pags"></div></main>
        <footer>Modelos 3D escaneados do Poly Haven (polyhaven.com), licença CC0 - uso livre, inclusive comercial.
        No SketchUp entra só uma caixa leve com a foto; no render do Blendit entra o modelo real.</footer>
        <script>
        var L = [], pag = 0, POR = 48;
        function esc(s){ return String(s).replace(/[&<>"]/g, function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];}); }
        function norm(s){ return s.normalize('NFD').replace(/[\\u0300-\\u036f]/g,'').toLowerCase(); }
        function status(t, ok){ var s=document.getElementById('st'); s.textContent=t; s.className=ok?'ok':''; }
        function mostrar(l){
          L = l || []; var gs = {};
          L.forEach(function(x){ gs[x.grupo] = (gs[x.grupo]||0) + 1; });
          document.getElementById('gr').innerHTML = '<option value="">Todos (' + L.length + ')</option>' +
            Object.keys(gs).sort().map(function(g){ return '<option value="' + esc(g) + '">' + esc(g) + ' (' + gs[g] + ')</option>'; }).join('');
          status(L.length + ' objetos. Clique para baixar (só na primeira vez) e posicionar no modelo.', true);
          listar();
        }
        function listar(){
          var q = norm(document.getElementById('q').value.trim()), g = document.getElementById('gr').value;
          var l = L.filter(function(x){ return (!g || x.grupo === g) && (!q || norm(x.nome + ' ' + x.tags.join(' ') + ' ' + x.categorias.join(' ')).indexOf(q) >= 0); });
          var n = Math.max(1, Math.ceil(l.length / POR)); if (pag >= n) pag = n - 1;
          document.getElementById('grid').innerHTML = l.slice(pag * POR, (pag + 1) * POR).map(function(x){
            return '<button class="c" onclick=\\'inserir(' + JSON.stringify(x.id) + ')\\'><img loading="lazy" src="' + esc(x.miniatura) + '" alt="">' +
              '<span>' + esc(x.nome) + '</span><small>' + esc(x.grupo) + '</small></button>'; }).join('');
          document.getElementById('pags').innerHTML = n > 1 ? '<button class="btn" ' + (pag===0?'disabled':'') + ' onclick="pag--;listar()">&lsaquo;</button>' +
            '<span>' + (pag + 1) + ' / ' + n + '</span><button class="btn" ' + (pag>=n-1?'disabled':'') + ' onclick="pag++;listar()">&rsaquo;</button>' : '';
        }
        function inserir(id){ var x = L.filter(function(i){ return i.id === id; })[0]; if (x) sketchup.inserir(JSON.stringify(x)); }
        window.addEventListener('load', function(){ if (window.sketchup) sketchup.pronto(); });
        </script></body></html>
      HTML
    end
  end
end
