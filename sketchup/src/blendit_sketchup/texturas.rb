# encoding: UTF-8
# Blendit para SketchUp - biblioteca de materiais com texturas reais.
#
# As texturas são do Poly Haven (polyhaven.com), licença CC0 (uso livre, inclusive
# comercial, sem precisar dar crédito). Nada vem dentro do plugin: cada textura é
# baixada só quando for usada pela primeira vez e fica guardada no computador.
#
# Cada material criado já sai no TAMANHO REAL da amostra (ex.: porcelanato de
# 1,5 m), com rugosidade adequada e mapa de relevo para o render.
require 'json'
require 'fileutils'

module BlenditSU
  module Texturas
    API = 'https://api.polyhaven.com'.freeze
    THUMB = 'https://cdn.polyhaven.com/asset_img/thumbs/%s.png?width=256&height=256'.freeze
    UA = 'BlenditSketchUp/0.2 (plugin SketchUp; github.com/lewismconte/blendit)'.freeze

    # [grupo, nome em português, id no Poly Haven, rugosidade]
    CATALOGO = [
      ['Pisos e porcelanatos', 'Porcelanato marmorizado branco', 'marble_01', 0.12],
      ['Pisos e porcelanatos', 'Porcelanato cimentício', 'concrete_tiles', 0.45],
      ['Pisos e porcelanatos', 'Cimento queimado', 'smooth_concrete_floor', 0.35],
      ['Pisos e porcelanatos', 'Granilite / terrazzo', 'terrazzo_tiles', 0.25],
      ['Pisos e porcelanatos', 'Granito em placas', 'granite_tile_03', 0.2],
      ['Pisos e porcelanatos', 'Pedra cinza em placas', 'grey_cartago_01', 0.5],
      ['Pisos e porcelanatos', 'Revestimento cerâmico claro', 'interior_tiles', 0.2],
      ['Pisos e porcelanatos', 'Ladrilho de terracota', 'terracotta_floor_tiles', 0.6],
      ['Madeiras', 'Piso laminado', 'laminate_floor_02', 0.4],
      ['Madeiras', 'Assoalho de carvalho', 'oak_wood_planks', 0.45],
      ['Madeiras', 'Taco espinha de peixe', 'herringbone_parquet', 0.4],
      ['Madeiras', 'Deck / tábuas de madeira', 'brown_planks_05', 0.7],
      ['Madeiras', 'Lâmina de carvalho (marcenaria)', 'oak_veneer_01', 0.35],
      ['Madeiras', 'Lâmina de nogueira (marcenaria)', 'natural_walnut_veneer', 0.35],
      ['Madeiras', 'Madeira clara (marcenaria)', 'ash_veneer', 0.35],
      ['Madeiras', 'Bambu', 'bamboo_veneer', 0.4],
      ['Paredes', 'Tijolinho aparente', 'red_brick', 0.85],
      ['Paredes', 'Tijolo pintado de branco', 'painted_brick', 0.8],
      ['Paredes', 'Concreto aparente', 'concrete_slab_wall', 0.75],
      ['Paredes', 'Bloco de concreto aparente', 'concrete_block_wall', 0.85],
      ['Paredes', 'Reboco / textura branca', 'white_stucco', 0.9],
      ['Paredes', 'Parede pintada bege', 'beige_wall_001', 0.85],
      ['Paredes', 'Reboco cinza', 'grey_plaster', 0.9],
      ['Área externa', 'Piso intertravado (paver)', 'interlocking_concrete_pavers', 0.8],
      ['Área externa', 'Calçada de concreto', 'concrete_pavement', 0.8],
      ['Área externa', 'Paralelepípedo', 'cobblestone_floor_01', 0.85],
      ['Área externa', 'Brita', 'gravel_ground_01', 0.95],
      ['Área externa', 'Seixo rolado', 'floor_pebbles_01', 0.7],
      ['Área externa', 'Grama', 'grass_ground', 1.0],
      ['Área externa', 'Areia', 'coast_sand_01', 0.95],
      ['Tecidos e couro', 'Linho', 'rough_linen', 0.95],
      ['Tecidos e couro', 'Bouclê', 'wool_boucle', 1.0],
      ['Tecidos e couro', 'Veludo', 'velour_velvet', 0.9],
      ['Tecidos e couro', 'Couro caramelo', 'brown_leather', 0.55],
      ['Tecidos e couro', 'Couro branco', 'leather_white', 0.5]
    ].freeze

    def self.dir
      base = ENV['LOCALAPPDATA'] || Dir.tmpdir
      File.join(base, 'BlenditSketchUp', 'texturas')
    end

    # ------------------------------------------------------------- download
    # Net::HTTP primeiro (sem janela); se o SSL do Ruby falhar, curl.exe do Windows.
    def self.download(url, path)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = path + '.parte'
      ok = begin
        net_get(url, tmp)
      rescue StandardError
        false
      end
      ok ||= curl_get(url, tmp)
      raise "Falha ao baixar #{url}" unless ok && File.size?(tmp)
      FileUtils.mv(tmp, path)
      path
    end

    def self.net_get(url, path, limit = 5)
      require 'net/http'
      require 'openssl'
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                open_timeout: 15, read_timeout: 60) do |http|
        http.request(Net::HTTP::Get.new(uri, 'User-Agent' => UA))
      end
      if res.is_a?(Net::HTTPRedirection) && limit > 0
        return net_get(URI.join(url, res['location']).to_s, path, limit - 1)
      end
      return false unless res.is_a?(Net::HTTPSuccess)
      File.binwrite(path, res.body)
      true
    end

    def self.curl_get(url, path)
      curl = File.join(ENV['SystemRoot'] || 'C:/Windows', 'System32', 'curl.exe')
      curl = 'curl' unless File.file?(curl)
      system(curl, '-L', '-s', '-f', '-A', UA, '-o', path, url)
    end

    def self.json(url, cache)
      download(url, cache) unless File.size?(cache)
      JSON.parse(File.read(cache, encoding: 'UTF-8'))
    end

    # Baixa (uma vez) a cor e o relevo de uma textura. -> [cor, relevo|nil, [larg_m, alt_m]]
    def self.fetch(id)
      d = File.join(dir, id)
      info = json("#{API}/info/#{id}", File.join(d, 'info.json'))
      files = json("#{API}/files/#{id}", File.join(d, 'files.json'))
      diff_url = pick(files, 'Diffuse', %w[2k 1k 4k])
      raise "Textura #{id} sem imagem de cor." unless diff_url
      diff = File.join(d, 'cor.jpg')
      download(diff_url, diff) unless File.size?(diff)
      bump = nil
      disp_url = pick(files, 'Displacement', %w[1k 2k])
      if disp_url
        bump = File.join(d, 'relevo.jpg')
        begin
          download(disp_url, bump) unless File.size?(bump)
        rescue StandardError
          bump = nil
        end
      end
      dims = info['dimensions'] || [1000, 1000]
      [diff, bump, [dims[0].to_f / 1000.0, dims[1].to_f / 1000.0]]
    end

    def self.pick(files, key, sizes)
      m = files[key] || {}
      sizes.each do |s|
        u = m.dig(s, 'jpg', 'url')
        return u if u
      end
      nil
    end

    # ------------------------------------------------------------- material
    def self.create_material(model, entry)
      _grupo, nome, id, rough = entry
      diff, bump, (wm, hm) = fetch(id)
      full = "#{nome} (Blendit)"
      mat = model.materials[full] || model.materials.add(full)
      mat.texture = diff
      inch = 1.0 / 0.0254
      mat.texture.size = [wm * inch, hm * inch] if mat.texture
      mat.set_attribute('blendit', 'textura', id)
      mat.set_attribute('blendit', 'rugosidade', rough)
      mat.set_attribute('blendit', 'relevo', bump) if bump
      mat
    end

    # ------------------------------------------------------------- galeria
    def self.show
      @dialog ||= nil
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end
      dlg = UI::HtmlDialog.new(dialog_title: 'Blendit - Biblioteca de materiais',
                               preferences_key: 'BlenditTexturas', width: 760, height: 640,
                               resizable: true, style: UI::HtmlDialog::STYLE_DIALOG)
      dlg.set_html(html)
      dlg.add_action_callback('aplicar') do |_ctx, idx|
        entry = CATALOGO[idx.to_i]
        next unless entry
        model = Sketchup.active_model
        dlg.execute_script("status(#{JSON.generate("Baixando \"#{entry[1]}\"... (só na primeira vez)")})")
        UI.start_timer(0.05, false) do
          begin
            mat = create_material(model, entry)
            model.materials.current = mat
            Sketchup.send_action('selectPaintTool:')
            dlg.execute_script("status(#{JSON.generate("\"#{entry[1]}\" pronto - clique nas faces com o balde de tinta.")}, true)")
          rescue StandardError => e
            dlg.execute_script("status(#{JSON.generate("Não deu para baixar: #{e.message}. Confira a internet e tente de novo.")})")
          end
        end
      end
      dlg.show
      @dialog = dlg
    end

    def self.html
      grupos = CATALOGO.each_with_index.group_by { |e, _i| e[0] }
      secoes = grupos.map do |g, list|
        cards = list.map do |(_, nome, id, _), i|
          %(<button class="c" onclick="pick(#{i})"><img loading="lazy" src="#{format(THUMB, id)}" alt=""><span>#{nome}</span></button>)
        end.join
        %(<h2>#{g}</h2><div class="g">#{cards}</div>)
      end.join
      <<~HTML
        <!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
        <style>
          :root{--bg:#f6f5f2;--fg:#222;--mut:#6b6b6b;--card:#fff;--line:#dedbd4;--acc:#2d6a4f}
          body{margin:0;font:14px/1.4 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--fg)}
          header{position:sticky;top:0;background:var(--bg);padding:14px 18px 10px;border-bottom:1px solid var(--line)}
          h1{font-size:16px;margin:0 0 4px}
          #st{color:var(--mut);min-height:20px}
          #st.ok{color:var(--acc);font-weight:600}
          main{padding:4px 18px 24px}
          h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:18px 0 8px}
          .g{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:10px}
          .c{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:0;cursor:pointer;
             text-align:left;overflow:hidden;font:inherit;color:inherit}
          .c:hover{border-color:var(--acc)}
          .c img{display:block;width:100%;aspect-ratio:1;object-fit:cover;background:#e9e6df}
          .c span{display:block;padding:6px 8px 8px;font-size:12px}
          footer{color:var(--mut);font-size:11px;padding:0 18px 16px}
        </style></head><body>
        <header><h1>Escolha um material e pinte as faces</h1>
        <div id="st">As texturas saem no tamanho real e com relevo no render. Baixa só na primeira vez (precisa de internet).</div></header>
        <main>#{secoes}</main>
        <footer>Texturas do Poly Haven (polyhaven.com), licença CC0 - uso livre, inclusive comercial.</footer>
        <script>
          function pick(i){ sketchup.aplicar(i); }
          function status(t, ok){ var s=document.getElementById('st'); s.textContent=t; s.className=ok?'ok':''; }
        </script></body></html>
      HTML
    end
  end
end
