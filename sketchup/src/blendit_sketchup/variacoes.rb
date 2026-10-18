# encoding: UTF-8
# Blendit para SketchUp - variações de proposta (opções lado a lado).
#
# O mesmo ambiente, na vista atual, com 2 ou 3 opções de acabamento: em cada
# opção, alguns materiais do projeto são trocados por outros (ex.: "Piso" vira
# "Porcelanato 90x90" na opção A e "Carvalho" na opção B). Sai um render por
# opção e uma prancha com as opções lado a lado. A troca vale SÓ no render: o
# modelo do SketchUp não muda. As opções ficam guardadas no próprio modelo.
require 'json'

module BlenditSU
  module Variacoes
    DICT = 'blendit_variacoes'.freeze
    MAX_OPCOES = 3
    LETRAS = %w[A B C].freeze

    # ------------------------------------------------------------ dados (Ruby puro)
    # config: { 'opcoes' => [{ 'nome' => 'Opção A', 'trocas' => { 'Piso' => 'Carvalho' } }, ...] }
    def self.ler(model)
      txt = model.get_attribute(DICT, 'config', nil)
      c = txt ? JSON.parse(txt.to_s) : nil
      c.is_a?(Hash) && c['opcoes'].is_a?(Array) ? c : { 'opcoes' => [] }
    rescue StandardError
      { 'opcoes' => [] }
    end

    def self.gravar(model, config)
      model.set_attribute(DICT, 'config', JSON.generate(limpar(config, nomes_materiais(model))))
    end

    def self.nomes_materiais(model)
      model.materials.map { |m| m.name.to_s }
    end

    # Só opções com nome e pelo menos uma troca válida (material que existe,
    # trocado por outro que existe), no máximo 3.
    def self.limpar(config, nomes)
      ops = Array((config || {})['opcoes']).first(MAX_OPCOES).each_with_index.map do |o, i|
        next nil unless o.is_a?(Hash)
        tr = (o['trocas'].is_a?(Hash) ? o['trocas'] : {}).each_with_object({}) do |(de, para), h|
          de = de.to_s
          para = para.to_s
          h[de] = para if nomes.include?(de) && nomes.include?(para) && de != para
        end
        nome = o['nome'].to_s.strip
        nome = "Opção #{LETRAS[i]}" if nome.empty?
        { 'nome' => nome, 'trocas' => tr }
      end.compact
      { 'opcoes' => ops }
    end

    # ------------------------------------------------------------ render
    # Exporta a vista atual uma vez por opção (com as trocas), põe tudo na fila
    # do Blender e, se pedido, a prancha comparativa no fim.
    def self.renderizar(model, config, prancha = true)
      blender = BlenditSU.ensure_blender or return
      cfg = limpar(config, nomes_materiais(model))
      ops = cfg['opcoes']
      if ops.none? { |o| !o['trocas'].empty? }
        UI.messagebox('Nenhuma opção com troca de material. Escolha pelo menos uma troca.')
        return
      end
      man = nil
      man = BlenditSU.board_info(model, 'Opções de acabamento') if prancha
      base = "#{BlenditSU.safe_name(model.title)}_#{BlenditSU.stamp}"
      jobs = []
      items = []
      ops.each_with_index do |o, i|
        spec, opts = BlenditSU.export_current(model, "#{base}_opcao#{LETRAS[i]}", trocas: o['trocas'])
        next unless spec
        png = File.join(BlenditSU.output_dir, "#{base}_opcao_#{LETRAS[i]}_#{BlenditSU.safe_name(o['nome'])}.png")
        jobs << BlenditSU.render_args(blender, spec, png, opts)
        items << { 'image' => png, 'label' => o['nome'] }
      end
      return if jobs.empty?
      jobs << BlenditSU.board_job(blender, man, items, File.join(BlenditSU.output_dir, "#{base}_opcoes.pdf")) if man
      BlenditSU.run_sequence(jobs, File.join(BlenditSU.output_dir, "#{base}_opcoes.log"))
      UI.messagebox("#{items.length} opção(ões) na fila do Blender#{man ? ' + a prancha lado a lado' : ''}.\n\n" \
                    "As imagens vão aparecendo em:\n#{BlenditSU.output_dir}\n\nO modelo do SketchUp não foi alterado.")
      items.length
    end

    # ------------------------------------------------------------ janela
    def self.show
      model = Sketchup.active_model
      return unless model
      mats = model.materials.map do |m|
        c = m.color
        { 'nome' => m.name.to_s, 'rotulo' => (m.respond_to?(:display_name) ? m.display_name : m.name).to_s,
          'cor' => format('#%02x%02x%02x', c.red, c.green, c.blue), 'textura' => !m.texture.nil? }
      end.sort_by { |x| x['rotulo'].downcase }
      if mats.length < 2
        UI.messagebox('O modelo precisa ter pelo menos dois materiais para montar variações.')
        return
      end
      dlg = UI::HtmlDialog.new(dialog_title: 'Blendit - Variações de proposta', preferences_key: 'BlenditVariacoes',
                               width: 900, height: 560, style: UI::HtmlDialog::STYLE_DIALOG)
      dlg.set_html(html(mats, ler(model)))
      dlg.add_action_callback('salvar') do |_c, dados|
        gravar(model, JSON.parse(dados.to_s))
        dlg.execute_script("status('Opções guardadas no modelo.')")
      end
      dlg.add_action_callback('renderizar') do |_c, dados|
        d = JSON.parse(dados.to_s)
        gravar(model, d)
        dlg.close
        renderizar(model, d, d['prancha'] != false)
      end
      dlg.add_action_callback('cancelar') { |_c| dlg.close }
      dlg.show
    end

    def self.html(mats, config)
      <<~HTML
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><style>
        body{font:13px "Segoe UI",Arial,sans-serif;margin:0;padding:14px 16px;background:#fafafa;color:#222}
        h2{font-size:16px;margin:0 0 4px} p{margin:0 0 10px;color:#555}
        table{width:100%;border-collapse:collapse;background:#fff}
        td,th{padding:6px;border-bottom:1px solid #e5e5e5;text-align:left;vertical-align:middle}
        th input{width:100%;font:inherit;font-weight:600;padding:4px 6px;border:1px solid #ccc;border-radius:4px}
        select{width:100%;font:inherit;padding:3px} .sw{display:inline-block;width:14px;height:14px;border-radius:3px;border:1px solid #bbb;vertical-align:-2px;margin-right:4px}
        .bar{margin-top:12px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
        button{padding:7px 16px;border:0;border-radius:6px;background:#2d6a4f;color:#fff;cursor:pointer;font:inherit}
        button.sec{background:#ddd;color:#222} .x{background:none;color:#a33;padding:2px 6px;font-weight:700}
        #st{color:#2d6a4f;font-weight:600}
        </style></head><body>
        <h2>Variações de proposta</h2>
        <p>Cada linha é um material do projeto que muda entre as opções. Em cada coluna, escolha o que entra no lugar dele
        (deixe "como está" para manter). Sai um render da vista atual por opção, mais uma prancha com as opções lado a lado.
        <b>O modelo do SketchUp não muda.</b> Dica: traga antes os materiais novos para o modelo (Biblioteca de materiais).</p>
        <table id="t"></table>
        <div class="bar"><button class="sec" onclick="linha()">+ Material que muda</button>
        <button class="sec" id="mais" onclick="coluna()">+ Opção</button></div>
        <div class="bar"><label><input type="checkbox" id="pr" checked> Montar a prancha com as opções lado a lado (pede o carimbo)</label></div>
        <div class="bar"><button onclick="enviar('renderizar')">Renderizar as opções</button>
        <button class="sec" onclick="enviar('salvar')">Só guardar</button>
        <button class="sec" onclick="sketchup.cancelar()">Fechar</button><span id="st"></span></div>
        <script>
        var M = #{JSON.generate(mats)}, C = #{JSON.generate(config)};
        var nomes = (C.opcoes.length ? C.opcoes : [{nome:'Opção A',trocas:{}},{nome:'Opção B',trocas:{}}]).map(function(o){return o.nome;});
        var linhas = [];
        C.opcoes.forEach(function(o){ Object.keys(o.trocas).forEach(function(k){ if (linhas.indexOf(k) < 0) linhas.push(k); }); });
        if (!linhas.length) linhas.push('');
        var sel = {};   // sel[linha][coluna] = material
        C.opcoes.forEach(function(o, c){ Object.keys(o.trocas).forEach(function(k){ (sel[k] = sel[k] || {})[c] = o.trocas[k]; }); });
        function esc(s){ return String(s).replace(/[&<>"]/g, function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];}); }
        function opts(v, vazio){ return '<option value="">' + vazio + '</option>' + M.map(function(m){
          return '<option value="' + esc(m.nome) + '"' + (m.nome === v ? ' selected' : '') + '>' + esc(m.rotulo) + (m.textura ? ' (textura)' : '') + '</option>'; }).join(''); }
        function cor(n){ var m = M.filter(function(x){ return x.nome === n; })[0]; return m ? '<span class="sw" style="background:' + m.cor + '"></span>' : ''; }
        function desenhar(){
          var h = '<tr><th style="width:26%">Material do projeto</th>' + nomes.map(function(n, c){
            return '<th><input value="' + esc(n) + '" oninput="nomes[' + c + ']=this.value"></th>'; }).join('') + '<th></th></tr>';
          linhas.forEach(function(l, r){
            h += '<tr><td>' + cor(l) + '<select onchange="trocaLinha(' + r + ',this.value)">' + opts(l, 'escolha...') + '</select></td>' +
              nomes.map(function(_n, c){ var v = (sel[l] || {})[c] || '';
                return '<td>' + cor(v) + '<select onchange="troca(' + r + ',' + c + ',this.value)">' + opts(v, 'como está') + '</select></td>'; }).join('') +
              '<td><button class="x" title="Remover" onclick="linhas.splice(' + r + ',1);if(!linhas.length)linhas.push(\\'\\');desenhar()">&times;</button></td></tr>';
          });
          document.getElementById('t').innerHTML = h;
          document.getElementById('mais').disabled = nomes.length >= #{MAX_OPCOES};
        }
        function trocaLinha(r, v){ var antigo = linhas[r]; sel[v] = sel[antigo] || {}; linhas[r] = v; desenhar(); }
        function troca(r, c, v){ var l = linhas[r]; (sel[l] = sel[l] || {})[c] = v; desenhar(); }
        function linha(){ linhas.push(''); desenhar(); }
        function coluna(){ if (nomes.length < #{MAX_OPCOES}) { nomes.push('Opção ' + 'ABC'[nomes.length]); desenhar(); } }
        function status(t){ document.getElementById('st').textContent = t; }
        function enviar(acao){
          var ops = nomes.map(function(n, c){ var t = {};
            linhas.forEach(function(l){ var v = (sel[l] || {})[c]; if (l && v && v !== l) t[l] = v; });
            return {nome: n, trocas: t}; });
          if (acao === 'renderizar' && !ops.some(function(o){ return Object.keys(o.trocas).length; })) { status('Escolha pelo menos uma troca.'); return; }
          sketchup[acao](JSON.stringify({opcoes: ops, prancha: document.getElementById('pr').checked}));
        }
        desenhar();
        </script></body></html>
      HTML
    end
  end
end
