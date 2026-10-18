# encoding: UTF-8
# Blendit para SketchUp - extrai a vista ativa do SketchUp para um bundle Blendit.
#
# O que vai junto:
#   * geometria visível (respeita objetos ocultos, etiquetas/tags e pastas de tags),
#     com as transformações de grupos/componentes aplicadas;
#   * materiais (cor, transparência, textura em escala real e, no SketchUp 2025+,
#     metálico/rugosidade dos materiais PBR) - inclusive o material "herdado"
#     quando a pintura está no grupo/componente;
#   * câmera da vista (perspectiva ou paralela, campo de visão, duas pontas);
#   * direção do sol exatamente como as sombras do SketchUp.
require 'fileutils'
require_relative 'bundle_writer'
require_relative 'classificador'
require_relative 'biblioteca_materiais'

module BlenditSU
  class Exporter
    INCH_TO_M = 0.0254

    # opts: :mode, :engine, :samples, :resolution ([w,h]), :denoise, :name
    def initialize(model, opts = {})
      @model = model
      @opts = opts.dup
      # Noite só faz sentido nos estilos com luz (nos de desenho as luminárias
      # ficam apagadas e a imagem sairia preta).
      @opts[:noite] = false unless %w[realistic specular].include?(@opts[:mode].to_s)
      @buckets = {}          # [chave, material_id] -> MeshBucket
      @materials = {}        # Sketchup::Material (ou :default) -> registro do contrato
      @mat_order = []
      @faces = 0
      @tex_dir = nil
      @tex_names = {}
      @ground_area = 0.0
      @min_z = Float::INFINITY
      @bounds = nil
      @lights = []
      @objetos = []          # objetos de decoração (substitutos -> modelo real)
      @in_light = nil
      @section_used = false
      @uv_stats = {}         # material_id -> { real:, fallback: } faces
      @uso = {}              # material -> { area:, piso:, parede:, estofado: } (modo automático)
      @modo = %w[preservar estrito automatico].include?(@opts[:materiais].to_s) ? @opts[:materiais].to_s : 'preservar'
    end

    # Materiais no render: 'preservar' (padrão - como no SketchUp, com os
    # ajustes por nome que já existiam), 'estrito' (nenhum ajuste automático) ou
    # 'automatico' (materiais só-cor ganham textura do catálogo, só no render).
    attr_reader :modo

    def estrito?
      @modo == 'estrito'
    end

    attr_reader :faces, :lights, :section_used
    attr_reader :uv_stats   # material_id -> { real:, fallback: } (diagnóstico/testes)

    # Exporta para out_dir e devolve o caminho do scene_spec.json.
    def export(out_dir)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      @tex_dir = File.join(out_dir, 'textures')
      copy_hdri(out_dir)

      @bounds = @model.bounds
      walk(@model.entities, Geom::Transformation.new, nil, ['Soltos', 'Geometria solta', ''], 0)
      raise 'Nada visível para exportar nesta vista.' if @buckets.empty? && @objetos.empty?

      @geom_cache = @vnorm_cache = nil       # libera a memória antes de gravar
      marcar_uvs
      aplicar_automaticos if @modo == 'automatico'
      spec = build_spec
      assets = copiar_objetos(out_dir)
      spec['assets'] = assets unless assets.empty?
      BundleWriter.new.write(@buckets.values, spec, out_dir)
    end

    private

    # ---------------------------------------------------------------- visibilidade
    def visible?(e)
      return false if e.respond_to?(:hidden?) && e.hidden?
      layer = e.respond_to?(:layer) ? e.layer : nil
      return true if layer.nil?
      @layer_vis ||= {}
      k = ent_key(layer)
      return @layer_vis[k] if @layer_vis.key?(k)
      @layer_vis[k] = layer_visible?(layer)
    end

    def layer_visible?(layer)
      return false unless layer.visible?
      # Pastas de tags (SketchUp 2021+): uma pasta oculta esconde as tags de dentro.
      folder = layer.respond_to?(:folder) ? layer.folder : nil
      while folder
        return false if folder.respond_to?(:visible?) && !folder.visible?
        folder = folder.respond_to?(:folder) ? folder.folder : nil
      end
      true
    end

    # ---------------------------------------------------------------- percurso
    # key = [nó, rótulo, categoria] do objeto de nível superior que contém a face.
    # clips = planos de corte ativos que valem para estas entidades: [[n, d], ...]
    # no espaço do mundo; fica o lado com n·p + d >= 0.
    def walk(entities, tr, inherited, key, depth, clips = [])
      clips = clips + section_clips(entities, tr)
      entities.each do |e|
        next unless visible?(e)
        case e
        when Sketchup::Face
          add_face(e, tr, inherited, key, clips)
        when Sketchup::Group, Sketchup::ComponentInstance
          defn = e.definition
          next if defn.nil?
          # Objeto de decoração (substituto leve): no render entra o modelo real.
          next if add_objeto(e, defn, tr * e.transformation, clips)
          child_key = key
          if depth.zero?
            label = e.name.to_s.empty? ? defn.name.to_s : e.name.to_s
            tag = e.layer ? e.layer.name.to_s : ''
            child_key = ["E#{e.entityID}", label, tag]
          end
          child_tr = tr * e.transformation
          add_light(e, defn, child_tr, clips) unless @in_light
          # Uma luminária detectada: as peças de dentro não viram outra luz.
          was = @in_light
          was_g = @in_glow
          unless @in_light
            @in_light = light_kind(e, defn)
            @in_glow = glow_info(e, defn, @in_light) if @in_light
          end
          was_c = @in_curtain
          @in_curtain ||= curtain_kind(e, defn) || upholstery_kind(e, defn) unless estrito?
          child_mat = e.material || inherited
          walk(defn.entities, child_tr, child_mat, child_key, depth + 1, clips)
          @in_light = was
          @in_glow = was_g
          @in_curtain = was_c
        end
      end
    end

    # ---------------------------------------------------------------- objetos de decoração
    # Componente substituto (Objetos.substituto): atributo blendit 'objeto_ph'
    # na definição. A geometria leve dele NÃO vai para o render; vai o modelo
    # 3D real (glTF do Poly Haven, baixado ao inserir), copiado para assets/.
    def add_objeto(e, defn, tr, clips)
      id = defn.respond_to?(:get_attribute) ? defn.get_attribute('blendit', 'objeto_ph').to_s : ''
      return false if id.empty?
      return true unless id =~ /\A[a-z0-9_\-]+\z/i && @opts.fetch(:objetos, true)
      mn, mx = world_bbox(defn, tr)
      centro = (0..2).map { |i| (mn[i] + mx[i]) / 2.0 }
      return true if clips.any? { |c| side(c, centro) < 0 }
      @objetos << { 'id' => id, 'source' => 'polyhaven',
                    'name' => defn.get_attribute('blendit', 'objeto_nome').to_s,
                    'matrix' => tr.to_a.map(&:to_f) }
      true
    end

    # Copia o glTF de cada objeto usado para o pacote; sem o arquivo (não
    # baixado e sem internet) o objeto fica de fora e o log avisa.
    def copiar_objetos(out_dir)
      return [] if @objetos.empty?
      prontos = {}
      @objetos.map { |o| o['id'] }.uniq.each do |id|
        src = nil
        if defined?(Objetos)
          begin
            Objetos.garantir(id)
            src = Objetos.pasta(id)
          rescue StandardError => e
            puts "Blendit: objeto #{id} indisponível (#{e.message}) - fica de fora do render."
          end
        end
        src ||= @opts[:objetos_dir] && File.join(@opts[:objetos_dir], id)
        gltf = src && Dir.glob(File.join(src, '*.gltf')).first
        next unless gltf
        dest = File.join(out_dir, 'assets', id)
        FileUtils.mkdir_p(dest)
        Dir.glob('**/*', base: src).each do |rel|
          f = File.join(src, rel)
          next unless File.file?(f) && rel !~ /\.json\z|\Aminiatura\.png\z|\Aok\z/
          FileUtils.mkdir_p(File.dirname(File.join(dest, rel)))
          FileUtils.cp(f, File.join(dest, rel))
        end
        prontos[id] = "assets/#{id}/#{File.basename(gltf)}"
      end
      @objetos.select { |o| prontos[o['id']] }.map { |o| o.merge('uri' => prontos[o['id']]) }
    end

    attr_reader :objetos

    # ---------------------------------------------------------------- corte
    # Plano de corte ativo destas entidades (no modelo ou dentro de um grupo).
    # A seta do plano aponta para o que FICA visível (é para onde se olha ao
    # "Alinhar vista"); se sair invertido, há a opção "Inverter lado do corte".
    def section_clips(entities, tr)
      return [] unless @opts.fetch(:section, true)
      return [] if @model.rendering_options['DisplaySectionCuts'] == false
      sp = entities.respond_to?(:active_section_plane) ? entities.active_section_plane : nil
      return [] unless sp && sp.respond_to?(:get_plane)
      a, b, c, d = sp.get_plane.map(&:to_f)
      nl = Geom::Vector3d.new(a, b, c)
      len2 = nl.dot(nl)
      return [] if len2 <= 0
      p0 = Geom::Point3d.new(-d * a / len2, -d * b / len2, -d * c / len2).transform(tr)
      n = xform_normal(nl, tr, mirrored?(tr))
      n.reverse! if @opts[:flip_section]
      dw = -(n.x * p0.x + n.y * p0.y + n.z * p0.z)
      @section_used = true
      [[[n.x, n.y, n.z], dw]]
    end

    def side(clip, p)
      n, d = clip
      n[0] * p[0] + n[1] * p[1] + n[2] * p[2] + d
    end

    # Sutherland-Hodgman: recorta um polígono [[pos, normal], ...] por um plano.
    def clip_poly(poly, clip)
      out = []
      poly.each_with_index do |cur, i|
        prev = poly[i - 1]
        sc = side(clip, cur[0])
        sp = side(clip, prev[0])
        if sc >= 0
          out << lerp_vert(prev, cur, sp / (sp - sc)) if sp < 0
          out << cur
        elsif sp >= 0
          out << lerp_vert(prev, cur, sp / (sp - sc))
        end
      end
      out
    end

    def lerp_vert(a, b, t)
      pa, na, ua = a
      pb, nb, ub = b
      pos = (0..2).map { |k| pa[k] + (pb[k] - pa[k]) * t }
      nrm = (0..2).map { |k| na[k] + (nb[k] - na[k]) * t }
      l = Math.sqrt(nrm.sum { |x| x * x })
      nrm = nrm.map { |x| x / l } if l > 0
      uv = ua && ub ? [ua[0] + (ub[0] - ua[0]) * t, ua[1] + (ub[1] - ua[1]) * t] : nil
      [pos, nrm, uv]
    end

    # ---------------------------------------------------------------- luzes
    # Luminárias viram luzes de verdade no Blender, reconhecidas pelo NOME do
    # componente/grupo (ou da definição). Dá para ajustar uma luminária pelo
    # dicionário de atributos "blendit": luz=nao, kelvin=2700, candela=1200.
    LIGHT_RULES = [
      [:fita,     ['fita led', 'fita de led', 'led strip', 'perfil led', 'perfil de led']],
      [:pendente, ['pendente', 'pendant', 'lustre', 'chandelier']],
      [:arandela, ['arandela', 'sconce', 'wall light', 'wall lamp', 'picture light', 'luz de quadro',
                   'luminaria de quadro', 'iluminacao de quadro']],
      [:spot,     ['spot', 'embutido', 'downlight', 'dicroica', 'dicroico', 'ar70', 'ar111',
                   'par20', 'par30', 'balizador', 'trilho', 'track light']],
      [:plafon,   ['plafon', 'plafom', 'plafonier', 'ceiling light', 'painel led', 'painel de led']],
      [:abajur,   ['abajur', 'luminaria de mesa', 'luminaria de piso', 'luminaria de chao',
                   'luminaria de coluna', 'table lamp', 'floor lamp']],
      [:generica, ['luminaria', 'lampada', 'lamp', 'light', 'luz', 'iluminacao']]
    ].freeze

    LIGHT_COR = /(?<![a-z0-9])light (grey|gray|blue|green|brown|beige|pink|yellow|red|wood|oak|walnut|ash|cream|white|black|tan|teal|purple|orange)/.freeze

    # [kelvin, candela, tipo]
    LIGHT_DEFAULTS = {
      spot: [3000, 2500, 'spot'], pendente: [2700, 1300, 'point'], plafon: [3000, 2000, 'point'],
      arandela: [2700, 800, 'spot'], abajur: [2700, 700, 'point'], generica: [3000, 1300, 'point'],
      fita: [3000, 300, 'point']
    }.freeze

    def self.plain(s)
      s.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').downcase.gsub(/[^a-z0-9]+/, ' ')
    end

    def attr(e, defn, key)
      [e, defn].each do |o|
        next unless o.respond_to?(:get_attribute)
        v = o.get_attribute('blendit', key)
        return v unless v.nil?
      end
      nil
    end

    def light_kind(e, defn)
      return nil unless @opts.fetch(:lights, true)
      off = attr(e, defn, 'luz')
      return nil if off == false || %w[nao não no off false 0].include?(off.to_s.downcase)
      forced = attr(e, defn, 'tipo')
      return forced.to_s.to_sym if forced && LIGHT_DEFAULTS.key?(forced.to_s.to_sym)
      text = " #{Exporter.plain(e.name)} #{Exporter.plain(defn.name)} "
      # "Sofa light grey", "Light oak": 'light' seguido de cor/madeira é cor clara, não luminária.
      text = text.gsub(LIGHT_COR, ' ')
      LIGHT_RULES.each do |kind, keys|
        keys.each do |k|
          return kind if text =~ /(?<![a-z0-9])#{Regexp.escape(k)}/
        end
      end
      nil
    end

    def world_bbox(defn, tr)
      bb = defn.bounds
      pts = (0..7).map { |i| bb.corner(i).transform(tr) }
      mn = [pts.map(&:x).min, pts.map(&:y).min, pts.map(&:z).min].map(&:to_f)
      mx = [pts.map(&:x).max, pts.map(&:y).max, pts.map(&:z).max].map(&:to_f)
      [mn, mx]
    end

    def add_light(e, defn, tr, clips)
      kind = light_kind(e, defn)
      return unless kind
      return if @lights.length >= 500 # proteção para modelos enormes
      mn, mx = world_bbox(defn, tr)
      cx = (mn[0] + mx[0]) / 2.0
      cy = (mn[1] + mx[1]) / 2.0
      cz = (mn[2] + mx[2]) / 2.0
      kelvin, cd, type = LIGHT_DEFAULTS[kind]
      kelvin = attr(e, defn, 'kelvin').to_f if attr(e, defn, 'kelvin').to_f > 0
      cd = attr(e, defn, 'candela').to_f if attr(e, defn, 'candela').to_f > 0
      below = 1.0 / INCH_TO_M * 0.02 # 2 cm abaixo da peça, fora da carcaça
      spots = case kind
              when :spot
                down = tr.zaxis.reverse
                down.normalize! if down.length > 0
                down = Geom::Vector3d.new(0, 0, -1) if down.length == 0 || down.z > -0.2
                [[[cx, cy, mn[2] - below], [down.x, down.y, down.z]]]
              when :arandela
                # Arandela / luz de quadro: a luz sai por BAIXO da peça (antes
                # ficava no centro, dentro da carcaça, e a própria peça a
                # bloqueava). Atributo blendit 'facho' = 'duplo' acende também
                # para cima (arandela de facho duplo).
                l = [[[cx, cy, mn[2] - below], [0, 0, -1]]]
                l << [[cx, cy, mx[2] + below], [0, 0, 1]] if attr(e, defn, 'facho').to_s.downcase == 'duplo'
                l
              when :abajur
                [[[cx, cy, cz], [0, 0, -1]]]
              when :fita
                along = (mx[0] - mn[0]) >= (mx[1] - mn[1]) ? 0 : 1
                len = mx[along] - mn[along]
                step = 0.3 / INCH_TO_M
                n = [[(len / step).round, 1].max, 40].min
                (0...n).map do |i|
                  p = [cx, cy, cz]
                  p[along] = mn[along] + (i + 0.5) * len / n
                  [p, [0, 0, -1]]
                end
              else
                [[[cx, cy, mn[2] - below], [0, 0, -1]]]
              end
      spots.each do |pos, dir|
        next if clips.any? { |c| side(c, pos) < 0 }
        @lights << {
          'id' => "luz#{@lights.length + 1}", 'type' => type,
          'position' => pos, 'direction' => dir,
          'intensity' => cd, 'intensity_unit' => 'cd', 'color_kelvin' => kelvin, 'color' => nil,
          'spot_beam_deg' => type == 'spot' ? (kind == :arandela ? 60.0 : 36.0) : nil,
          'spot_field_deg' => type == 'spot' ? (kind == :arandela ? 110.0 : 60.0) : nil,
          'radius_m' => kind == :plafon ? 0.12 : (kind == :fita ? 0.01 : 0.04),
          'on' => true
        }
      end
    end

    # ---------------------------------------------------------------- luminárias que brilham
    # Dentro de uma luminária reconhecida, a lente / vidro / acrílico / difusor /
    # lâmpada brilha na imagem (material emissivo, só no render). Pelo nome do
    # material ou por ser transparente. Atributo blendit 'brilho' na luminária:
    # 'nao' desliga; 'sim' faz brilhar também as partes claras sem nome claro.
    GLOW_RE = /vidro|glass|acr[ií]lic|acrylic|policarbonat|leitos|opal|difus|lente|\blens|l[aâ]mpada|bulbo|bulb|\bled\b|emiss|neon|\bluz\b|light|lumin|cristal|crystal|vela\b|chama|flame/i.freeze
    GLOW_NAO_RE = /metal|alum[ií]n|inox|a[cç]o\b|steel|chrome|cromad|ferro|madeira|wood|preto|black|lat[aã]o|brass|cobre|copper/i.freeze
    GLOW_FORCA = { dia: 2.5, noite: 6.0 }.freeze

    def glow_info(e, defn, kind)
      v = attr(e, defn, 'brilho').to_s.downcase
      return nil if %w[nao não no off false 0].include?(v) || kind.nil?
      kelvin = attr(e, defn, 'kelvin').to_f
      kelvin = LIGHT_DEFAULTS[kind][0] unless kelvin > 0
      { kind: kind, kelvin: kelvin, forcar: %w[sim yes on true 1].include?(v) }
    end

    def glows?(mat, info)
      return false unless info && mat
      nome = (mat.respond_to?(:display_name) ? mat.display_name : mat.name).to_s
      return false if nome =~ GLOW_NAO_RE
      alpha = mat.respond_to?(:alpha) ? mat.alpha.to_f : 1.0
      return true if nome =~ GLOW_RE || alpha < 0.99
      return false unless info[:forcar]
      c = mat.color
      (0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue) > 150
    rescue StandardError
      false
    end

    # Cor de uma lâmpada pela temperatura (K), linear (aprox. de Tanner Helland).
    def self.kelvin_rgb(k)
      t = [[k.to_f, 1000.0].max, 12_000.0].min / 100.0
      r = t <= 66 ? 255.0 : 329.698727446 * ((t - 60)**-0.1332047592)
      g = t <= 66 ? 99.4708025861 * Math.log(t) - 161.1195681661 : 288.1221695283 * ((t - 60)**-0.0755148492)
      b = if t >= 66 then 255.0
          elsif t <= 19 then 0.0
          else 138.5177312231 * Math.log(t - 10) - 305.0447927307
          end
      [r, g, b].map { |v| BlenditSU.srgb_to_linear([[v, 0.0].max, 255.0].min.round) }
    end

    def material_brilho_id(mat, info)
      k = [mat, 'brilho', info[:kelvin].round]
      rec = @materials[k]
      return rec['id'] if rec
      id = "m#{@mat_order.length + 1}"
      rec = material_record(mat, id)
      rec['name'] = "#{rec['name']} (brilho)"
      # Metade branco: lâmpada quente aparece branco-quente na foto, não laranja.
      rec['emissive'] = Exporter.kelvin_rgb(info[:kelvin]).map { |c| 0.5 + 0.5 * c }
      rec['emissive_strength'] = @opts[:noite] ? GLOW_FORCA[:noite] : GLOW_FORCA[:dia]
      rec['transparency'] = 0.0                     # difusor aceso parece opaco
      rec['appearance_class'] = 'emissive'
      rec['base_color'] = rec['base_color'].map { |v| [v, 0.8].min }
      @materials[k] = rec
      @mat_order << rec
      @brilhos = (@brilhos || 0) + 1
      id
    end

    attr_reader :brilhos

    # ---------------------------------------------------------------- variações de proposta
    # opts[:trocas] = { 'nome do material' => 'nome do material que entra no lugar' }:
    # só no render (o modelo não muda). Materiais que não existem são ignorados.
    def trocas
      return @trocas if @trocas
      @trocas = {}
      pedidos = @opts[:trocas]
      return @trocas unless pedidos.is_a?(Hash) && !pedidos.empty?
      por_nome = {}
      @model.materials.each { |m| por_nome[m.name.to_s] = m }
      pedidos.each do |de, para|
        a = por_nome[de.to_s]
        b = por_nome[para.to_s]
        @trocas[a] = b if a && b && a != b
      end
      @trocas
    end

    # ---------------------------------------------------------------- faces
    def add_face(face, tr, inherited, key, clips = [])
      mat = face.material || inherited || face.back_material
      trocado = false
      if !trocas.empty? && trocas[mat]
        mat = trocas[mat]
        trocado = true        # posição da textura original não vale para a nova: escala real
      end
      mid = if @in_glow && glows?(mat, @in_glow) && @opts.fetch(:brilho_luminarias, true)
              material_brilho_id(mat, @in_glow)
            else
              material_id(mat, @in_curtain && !mat_rigid?(mat) ? @in_curtain : nil)
            end

      lpts, lnormal, lnormals, ltris, uvf, uvb = local_geom(face)
      return if lpts.empty?
      xf = xform_of(tr)
      mirrored = xf[:mirrored]
      # Só contas em Ruby puro daqui para baixo: nada de criar objetos da API
      # do SketchUp por vértice (é o que deixava a exportação lenta).
      flat = lpts.map { |p| xf_point(xf, p) }
      n = xf_normal(xf, lnormal)
      nrms = if lnormals
               lnormals.map { |v| v ? xf_normal(xf, v) : n }
             else
               Array.new(flat.length, n)
             end
      tris = mirrored ? ltris.map { |t| [t[0], t[2], t[1]] } : ltris
      uvs, origem = face_uvs(face, mat, inherited, lpts, uvf, uvb, flat, trocado)
      if uvs
        st = (@uv_stats[mid] ||= { real: 0, fallback: 0 })
        st[origem] += 1
      end

      unless clips.empty?
        vp = []
        vn = []
        vt = uvs ? [] : nil
        out_tris = []
        tris.each do |t|
          poly = t.map { |i| [flat[i], nrms[i], uvs && uvs[i]] }
          clips.each { |c| poly = clip_poly(poly, c) if poly.length >= 3 }
          next if poly.length < 3
          base = vp.length
          poly.each { |pos, nr, uv| vp << pos; vn << nr; vt << uv if vt }
          (1...(poly.length - 1)).each { |k| out_tris << [base, base + k, base + k + 1] }
        end
        return if out_tris.empty?
        flat, nrms, tris, uvs = vp, vn, out_tris, vt
      end

      bucket_for(key, mid).add_smooth(flat, nrms, tris, uvs)
      medir_uso(mat, flat, tris, n) if @modo == 'automatico' && mat
      @faces += 1
      track_ground(face, flat, n)
    end

    # Materiais com textura em que alguma face trouxe UV real passam a usar o
    # mapeamento do SketchUp no Blender ('uv' => true no mapa de cor). Sem
    # nenhuma UV real, as UVs saem do pacote e o Blender usa a projeção antiga.
    def marcar_uvs
      com_uv = {}
      @mat_order.each do |rec|
        st = @uv_stats[rec['id']]
        dif = rec['maps'] && rec['maps']['diffuse']
        next unless dif && st && st[:real] > 0
        dif['uv'] = true
        com_uv[rec['id']] = true
      end
      @buckets.each_value { |b| b.drop_uvs! unless com_uv[b.material_id] }
    end

    def bucket_for(key, mid)
      bkey = [key[0], mid]
      @buckets[bkey] ||= begin
        b = MeshBucket.new("#{key[0]}_#{mid}", mid)
        b.label = key[1]
        b.category = key[2]
        b
      end
    end

    def mirrored?(tr)
      tr.xaxis.cross(tr.yaxis).dot(tr.zaxis) < 0
    end

    # Normal transformada corretamente para qualquer transformação (inclusive
    # escala não uniforme e espelhamento): transforma dois vetores do plano
    # perpendicular à normal e faz o produto vetorial.
    def xform_normal(normal, tr, mirrored)
      return Geom::Vector3d.new(0, 0, 1) if normal.length == 0
      axes = normal.axes
      u = axes[0].transform(tr)
      v = axes[1].transform(tr)
      n = u.cross(v)
      n.reverse! if mirrored
      n.normalize! if n.length > 0
      n
    end

    # Geometria local de uma face, calculada uma vez e reaproveitada em todas as
    # cópias do mesmo componente (cada vaso, cada ripa do berço...). Inclui as
    # normais suavizadas: arestas suaves (cilindros, cortinas, almofadas) saem
    # lisas no render em vez de facetadas.
    def local_geom(face)
      @geom_cache ||= {}
      @geom_cache[ent_key(face)] ||= begin
        mesh = face.mesh(MESH_UVQ_FRONT | MESH_UVQ_BACK)
        mpts = mesh.points
        tris = []
        mesh.polygons.each do |poly|
          idx = poly.map { |i| i.abs - 1 }
          # A face.mesh já entrega triângulos; por segurança, abre em leque.
          (1...(idx.length - 1)).each { |k| tris << [idx[0], idx[k], idx[k + 1]] }
        end
        lnormals = nil
        if face.edges.any? { |ed| ed.smooth? || ed.soft? }
          by_pos = {}
          face.vertices.each { |vx| by_pos[pos_key(vx.position)] = vx }
          lnormals = mpts.map do |p|
            vx = by_pos[pos_key(p)]
            vx ? vec3(vertex_normal(vx, face)) : nil
          end
        end
        [mpts.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] }, vec3(face.normal), lnormals, tris,
         mesh_uvs(mesh, mpts.length, true), mesh_uvs(mesh, mpts.length, false)]
      end
    end

    # ---------------------------------------------------------------- modo automático
    PISO_ALTURA = 0.5 / INCH_TO_M      # até 50 cm acima do ponto mais baixo = piso

    def medir_uso(mat, flat, tris, n)
      u = (@uso[mat] ||= { area: 0.0, piso: 0.0, parede: 0.0, estofado: 0.0 })
      a = 0.0
      tris.each do |i, j, k|
        e1 = (0..2).map { |c| flat[j][c] - flat[i][c] }
        e2 = (0..2).map { |c| flat[k][c] - flat[i][c] }
        cr = cross3(e1, e2)
        a += 0.5 * Math.sqrt(cr[0]**2 + cr[1]**2 + cr[2]**2)
      end
      a *= INCH_TO_M * INCH_TO_M
      u[:area] += a
      @z_piso ||= @bounds ? @bounds.min.z.to_f : 0.0
      if n[2] > 0.95 && flat.map { |q| q[2] }.min - @z_piso < PISO_ALTURA
        u[:piso] += a
      elsif n[2].abs < 0.1
        u[:parede] += a
      end
      u[:estofado] += a if @in_curtain == 'estofado'
    end

    # Materiais só-cor ganham uma textura PBR do catálogo local - só no pacote
    # do render; o modelo do SketchUp não muda. Ordem de decisão:
    #   1. escolha guardada pela arquiteta ('auto_decisao' aprovado/rejeitado);
    #   2. classificador com certeza alta ou média;
    #   3. certeza baixa / sem informação: nada (cor + realismo do render).
    # A textura é tingida com a cor do material (a cor do projeto não muda).
    def aplicar_automaticos
      return unless defined?(Texturas)
      regras = BibliotecaMateriais.carregar_regras(@opts[:regras_materiais])
      nomes = Texturas::CATALOGO.to_h { |e| [e[3], e[1]] }
      @extras_auto = Texturas.respond_to?(:extras_auto) ? (Texturas.extras_auto(regras) rescue {}) : {}
      @auto_resumo = []
      @materials.each do |chave, rec|
        mat = chave.is_a?(Array) ? chave[0] : chave
        next if mat == :default || mat.nil? || rec['maps'] || rec['transparency'].to_f > 0.0 || rec['emissive']
        decisao = attr_of(mat, 'auto_decisao').to_s
        next if decisao == 'rejeitado'
        nome = (mat.respond_to?(:display_name) ? mat.display_name : mat.name).to_s
        rgb = [mat.color.red, mat.color.green, mat.color.blue]
        cat, id, conf, motivo = decidir(mat, nome, rgb, decisao, regras, nomes)
        next unless cat
        if cat == 'metal'
          rec['appearance_class'] = 'metal' if rec['appearance_class'].to_s.empty?
          rec['auto'] = { 'categoria' => cat, 'confianca' => conf, 'origem' => 'automatico', 'motivo' => motivo }
          next
        end
        next unless id
        maps = mapas_do_catalogo(id, rec)
        next unless maps
        rec['maps'] = maps
        ent = Texturas.resolver(id)
        rec['roughness'] = ent['rugosidade'].to_f if ent && ent['rugosidade']
        rec['auto'] = { 'categoria' => cat, 'confianca' => conf, 'textura' => id,
                        'origem' => decisao == 'aprovado' ? 'aprovado' : 'automatico', 'motivo' => motivo }
        @auto_resumo << [nome, cat, id, conf]
      end
    end

    attr_reader :auto_resumo

    def decidir(mat, nome, rgb, decisao, regras, nomes)
      if decisao == 'aprovado'
        id = attr_of(mat, 'auto_textura').to_s
        cat = attr_of(mat, 'auto_categoria').to_s
        return [cat, id, 'aprovado', 'escolha revisada pela arquiteta'] unless id.empty?
      end
      u = @uso[mat] || { area: 0.0, piso: 0.0, parede: 0.0, estofado: 0.0 }
      ar = [u[:area], 1e-9].max
      cl = Classificador.classificar({ nome: nome, rgb: rgb, alpha: 1.0, tem_textura: false,
                                       area_m2: u[:area], frac_piso: u[:piso] / ar,
                                       frac_parede: u[:parede] / ar, frac_estofado: u[:estofado] / ar }, regras)
      return nil unless cl[:categoria] && %i[alta media].include?(cl[:confianca])
      id = BibliotecaMateriais.ordenar_com_extras(cl[:categoria], rgb, nome, nomes, regras,
                                                  (@extras_auto || {})[cl[:categoria]] || []).first
      [cl[:categoria], id, cl[:confianca].to_s, cl[:motivo]]
    end

    # Copia cor / relevo / mapa de brilho do catálogo (baixa na 1a vez) para o
    # pacote. nil se não der (sem internet e fora do cache): fica a cor.
    def mapas_do_catalogo(id, rec)
      return nil unless Texturas.resolver(id)
      diff, bump, (wm, hm), rugo = Texturas.fetch_chave(id)
      return nil unless diff && File.file?(diff.to_s)
      FileUtils.mkdir_p(@tex_dir)
      escala = [wm.to_f > 0 ? wm.to_f : 1.0, hm.to_f > 0 ? hm.to_f : 1.0]
      copia = lambda do |src, sufixo|
        nome = "#{rec['id']}_auto#{sufixo}#{File.extname(src.to_s).downcase}"
        FileUtils.cp(src, File.join(@tex_dir, nome))
        "textures/#{nome}"
      end
      maps = { 'diffuse' => { 'uri' => copia.call(diff, ''), 'scale_m' => escala,
                              'tint' => rec['base_color'], 'auto' => true } }
      maps['bump'] = { 'uri' => copia.call(bump, '_relevo'), 'scale_m' => escala, 'amount' => 0.35 } if bump && File.file?(bump.to_s)
      maps['roughness'] = { 'uri' => copia.call(rugo, '_rugosidade'), 'scale_m' => escala } if rugo && File.file?(rugo.to_s)
      maps
    rescue StandardError => e
      puts "Blendit: textura automática #{id} indisponível (#{e.message}) - fica a cor."
      nil
    end

    # ---------------------------------------------------------------- UVs
    # face.mesh com as flags de UVQ entrega uma coordenada de textura por
    # vértice da malha (mesma ordem de mesh.points), já com a posição, rotação,
    # escala e distorção que a arquiteta deu à textura no SketchUp. UVQ é
    # homogêneo: u = U/Q, v = V/Q.
    MESH_UVQ_FRONT = 1
    MESH_UVQ_BACK = 2

    def mesh_uvs(mesh, n, front)
      return nil unless mesh.respond_to?(:uv_at)
      (1..n).map do |i|
        q = mesh.uv_at(i, front)
        return nil if q.nil?
        w = q.z.to_f
        w = 1.0 if w.abs < 1e-12
        u = q.x.to_f / w
        v = q.y.to_f / w
        return nil unless u.finite? && v.finite?
        [u, v]
      end
    rescue StandardError
      nil
    end

    # UVs da face no lado cujo material é usado, em unidades de textura
    # (1 = a imagem inteira). nil = sem textura (não precisa de UV).
    # -> [uvs, :real | :fallback]
    def face_uvs(face, mat, inherited, lpts, uvf, uvb, flat, caixa = false)
      tex = mat && mat.texture
      return nil unless tex
      tw = tex.width.to_f
      th = tex.height.to_f
      return [box_uvs(flat, tw, th), :fallback] if caixa
      raw, own = if face.material then [uvf, true]          # frente pintada
                 elsif inherited then [uvf, false]          # cor do grupo/componente
                 else [uvb, true]                           # só o verso pintado
                 end
      uv = raw && normalize_uvs(raw, lpts, tw, th, own)
      return [uv, :real] if uv
      [box_uvs(flat, tw, th), :fallback]
    end

    # O SketchUp entrega as UVs de um material da própria face já em unidades
    # de textura; numa face sem material (que herda a cor do grupo), em
    # polegadas. A razão |dUV| / |dP| diz qual é o caso, sem depender disso:
    # ~1 = polegadas (divide pelo tamanho da textura).
    def normalize_uvs(raw, lpts, tw, th, own)
      return nil if raw.length != lpts.length || raw.length < 3
      r = uv_ratio(raw, lpts)
      return nil if r.nil? || r <= 0
      if (r - 1.0).abs < 0.2 && tw > 4.0 && th > 0.0
        raw.map { |u, v| [u / tw, v / th] }          # polegadas -> unidades de textura
      elsif own || (r * tw - 1.0).abs < 0.2
        raw                                          # já em unidades de textura
      end                                            # senão: nil -> plano B
    end

    def uv_ratio(raw, lpts)
      rs = []
      (0...raw.length).each do |i|
        j = (i + 1) % raw.length
        dp = Math.sqrt((0..2).sum { |k| (lpts[j][k] - lpts[i][k])**2 })
        next if dp < 1e-6
        du = Math.hypot(raw[j][0] - raw[i][0], raw[j][1] - raw[i][1])
        rs << du / dp
      end
      return nil if rs.empty?
      rs.sort[rs.length / 2]
    end

    # Plano B (sem UV válida): projeção pelo eixo dominante, em metros, na
    # escala real da textura - o mesmo que o Blender faz hoje sem UV.
    def box_uvs(flat, tw, th)
      sx = [tw * INCH_TO_M, 1e-6].max
      sy = [th * INCH_TO_M, 1e-6].max
      e1 = flat[1] ? (0..2).map { |k| flat[1][k] - flat[0][k] } : [1, 0, 0]
      e2 = flat[2] ? (0..2).map { |k| flat[2][k] - flat[0][k] } : [0, 1, 0]
      n = cross3(e1, e2).map(&:abs)
      flat.map do |p|
        x, y, z = p.map { |c| c * INCH_TO_M }
        if n[2] >= n[0] && n[2] >= n[1] then [x / sx, y / sx]
        elsif n[0] >= n[1] then [y / sx, z / sy]
        else [x / sx, z / sy]
        end
      end
    end

    def vec3(v)
      [v.x.to_f, v.y.to_f, v.z.to_f]
    end

    # Parte linear (colunas a, b, c) + translação t de uma transformação, e a
    # matriz de cofatores para as normais (vale com escala não uniforme e
    # espelhamento - igual a transformar dois vetores do plano e cruzar).
    # Guarda a última: as faces de um mesmo grupo vêm em sequência.
    def xform_of(tr)
      return @xf_last if @xf_tr.equal?(tr)
      o = Geom::Point3d.new(0, 0, 0).transform(tr)
      t = vec3(o)
      a = vec3(Geom::Point3d.new(1, 0, 0).transform(tr)).each_with_index.map { |v, i| v - t[i] }
      b = vec3(Geom::Point3d.new(0, 1, 0).transform(tr)).each_with_index.map { |v, i| v - t[i] }
      c = vec3(Geom::Point3d.new(0, 0, 1).transform(tr)).each_with_index.map { |v, i| v - t[i] }
      bc = cross3(b, c)
      ca = cross3(c, a)
      ab = cross3(a, b)
      det = a[0] * bc[0] + a[1] * bc[1] + a[2] * bc[2]
      @xf_tr = tr
      @xf_last = { a: a, b: b, c: c, t: t, bc: bc, ca: ca, ab: ab, mirrored: det < 0 }
    end

    def cross3(u, v)
      [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
    end

    def xf_point(xf, p)
      a = xf[:a]; b = xf[:b]; c = xf[:c]; t = xf[:t]
      x = p[0]; y = p[1]; z = p[2]
      [a[0] * x + b[0] * y + c[0] * z + t[0],
       a[1] * x + b[1] * y + c[1] * z + t[1],
       a[2] * x + b[2] * y + c[2] * z + t[2]]
    end

    def xf_normal(xf, nv)
      p = xf[:bc]; q = xf[:ca]; r = xf[:ab]
      x = nv[0]; y = nv[1]; z = nv[2]
      v = [p[0] * x + q[0] * y + r[0] * z,
           p[1] * x + q[1] * y + r[1] * z,
           p[2] * x + q[2] * y + r[2] * z]
      v = v.map(&:-@) if xf[:mirrored]
      l = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
      l > 0 ? [v[0] / l, v[1] / l, v[2] / l] : [0.0, 0.0, 1.0]
    end

    def ent_key(e)
      e.respond_to?(:entityID) ? e.entityID : e.object_id
    end

    # Normal suavizada de `face` no vértice `vx`: média das faces ligadas a ela
    # por arestas suaves em volta do vértice (o mesmo critério do SketchUp).
    # Calculada uma vez por vértice para todas as faces em volta dele.
    def vertex_normal(vx, face)
      @vnorm_cache ||= {}
      table = (@vnorm_cache[ent_key(vx)] ||= smooth_groups(vx))
      table[ent_key(face)] || face.normal
    end

    def smooth_groups(vx)
      edges = vx.edges
      faces = edges.flat_map(&:faces).uniq
      group_of = {}
      out = {}
      faces.each do |f0|
        next if group_of[ent_key(f0)]
        group = []
        queue = [f0]
        group_of[ent_key(f0)] = true
        until queue.empty?
          f = queue.pop
          group << f
          edges.each do |ed|
            next unless (ed.smooth? || ed.soft?) && ed.used_by?(f)
            ed.faces.each do |g|
              next if group_of[ent_key(g)]
              group_of[ent_key(g)] = true
              queue << g
            end
          end
        end
        sum = Geom::Vector3d.new(0, 0, 0)
        group.each { |g| sum += g.normal }
        nn = sum.length > 0 ? sum.normalize : f0.normal
        group.each { |g| out[ent_key(g)] = nn }
      end
      out
    end

    def pos_key(p)
      [(p.x * 1000).round, (p.y * 1000).round, (p.z * 1000).round]
    end

    # Heurística de "terreno próprio": faces horizontais grandes na cota mais baixa.
    # Se o modelo já tem terreno, o Blendit não cria o chão artificial (evita
    # duas superfícies brigando no mesmo lugar).
    def track_ground(face, pts, n)
      return unless n[2].abs > 0.98
      z = pts.map { |q| q[2] }.min.to_f
      area = face.area.to_f # área local; boa o bastante para a heurística
      if z < @min_z - 1.0
        @min_z = z
        @ground_area = area
      elsif (z - @min_z).abs <= 1.0
        @ground_area += area
      end
    end

    def has_site?
      w = @bounds.width.to_f
      h = @bounds.height.to_f
      return false if w <= 0 || h <= 0
      @ground_area >= 0.6 * w * h
    end

    # ---------------------------------------------------------------- materiais
    # cortina: nil, 'cortina' ou 'cortina_voil' - o mesmo material usado dentro
    # de uma cortina vira um registro à parte, com tecido translúcido no render.
    def material_id(mat, cortina = nil)
      k = cortina ? [mat || :default, cortina] : (mat || :default)
      rec = @materials[k]
      return rec['id'] if rec
      id = "m#{@mat_order.length + 1}"
      rec = if mat then material_record(mat, id)
            elsif cortina then default_record.merge('id' => id)
            else default_record
            end
      if cortina
        rec['appearance_class'] = cortina
        rec['name'] = "#{rec['name']} (#{cortina == 'estofado' ? 'estofado' : 'cortina'})"
      end
      @materials[k] = rec
      @mat_order << rec
      rec['id']
    end

    # Componentes/grupos de cortina, pelo nome. Blackout e persiana ficam de fora.
    CURTAIN_RE = /cortin|curtain|drape|voil|voal|vual|sheer|\btule\b|organza/i.freeze
    SHEER_RE = /voil|voal|vual|sheer|\btule\b|organza|gaze/i.freeze
    NOT_CURTAIN_RE = /blackout|black out|persiana|blind/i.freeze

    def curtain_kind(inst, defn)
      names = [inst.name.to_s, defn.name.to_s].join(' ')
      return nil if names !~ CURTAIN_RE || names =~ NOT_CURTAIN_RE
      names =~ SHEER_RE ? 'cortina_voil' : 'cortina'
    end

    # Sofás, poltronas, almofadas, puffs, cabeceiras: o tecido ganha o brilho
    # suave de tecido de verdade no render (mesmo com nome de material genérico).
    ESTOFADO_RE = /sof[aá]|poltrona|almofad|puff|pufe|estofad|cabeceira|couch|armchair|cushion|pillow/i.freeze

    def upholstery_kind(inst, defn)
      names = [inst.name.to_s, defn.name.to_s].join(' ')
      names =~ ESTOFADO_RE ? 'estofado' : nil
    end

    # Peças rígidas dentro da cortina (varão, trilho, argolas) não viram tecido.
    def mat_rigid?(mat)
      return false unless mat
      n = (mat.respond_to?(:display_name) ? mat.display_name : mat.name).to_s.downcase
      return true if n =~ /metal|alumin|inox|a[cç]o\b|ferro|cromad|trilho|var[aã]o|madeira|wood|chrome|steel/
      c = mat.color
      (0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue) < 30
    rescue StandardError
      false
    end

    def default_record
      c = @model.rendering_options['FaceFrontColor']
      color = c ? [c.red, c.green, c.blue].map { |v| BlenditSU.srgb_to_linear(v) } : [0.8, 0.8, 0.8]
      { 'id' => 'm0', 'name' => 'Padrão', 'base_color' => color, 'metallic' => 0.0,
        'roughness' => 0.6, 'transparency' => 0.0, 'ior' => 1.45, 'emissive' => nil,
        'emissive_strength' => 0.0, 'appearance_class' => '', 'glossiness' => nil, 'maps' => nil }
    end

    def material_record(mat, id)
      name = mat.respond_to?(:display_name) ? mat.display_name.to_s : mat.name.to_s
      c = mat.color
      alpha = mat.respond_to?(:alpha) ? mat.alpha.to_f : 1.0
      alpha = 1.0 if mat.respond_to?(:use_alpha?) && !mat.use_alpha? && alpha >= 0.999
      transparency = [[1.0 - alpha, 0.0].max, 1.0].min
      low = name.downcase
      glassy = transparency > 0.0 || low.include?('vidro') || low.include?('glass')
      roughness = glassy ? 0.05 : 0.5
      metallic = 0.0

      # Materiais PBR do SketchUp 2025+ (metálico/rugosidade).
      begin
        if mat.respond_to?(:roughness_enabled?) && mat.roughness_enabled?
          roughness = mat.roughness_factor.to_f
        end
        if mat.respond_to?(:metalness_enabled?) && mat.metalness_enabled?
          metallic = mat.metallic_factor.to_f
        end
      rescue StandardError
        nil
      end

      rec = { 'id' => id, 'name' => name,
              'base_color' => [c.red, c.green, c.blue].map { |v| BlenditSU.srgb_to_linear(v) },
              'metallic' => metallic, 'roughness' => [[roughness, 0.0].max, 1.0].min,
              'transparency' => transparency, 'ior' => glassy ? 1.52 : 1.45,
              'emissive' => nil, 'emissive_strength' => 0.0, 'appearance_class' => '',
              'glossiness' => nil, 'maps' => nil }
      # Materiais da biblioteca Blendit trazem rugosidade e relevo próprios.
      r = attr_of(mat, 'rugosidade')
      rec['roughness'] = [[r.to_f, 0.0].max, 1.0].min if r
      tex = texture_map(mat, id)
      if tex
        rec['maps'] = { 'diffuse' => tex }
        bump = bump_map(mat, id, tex)
        rec['maps']['bump'] = bump if bump
        rugo = rough_map(mat, id, tex)
        rec['maps']['roughness'] = rugo if rugo
      end
      pbr = pbr_maps(mat, id, tex)
      unless pbr.empty?
        rec['maps'] ||= {}
        pbr.each { |k, v| rec['maps'][k] ||= v }   # mapa da biblioteca Blendit tem preferência
      end
      rec
    end

    # Mapas PBR do SketchUp 2025+ (Material > fluxo "PBR metálico/rugosidade"):
    # relevo (normal), rugosidade, metálico e oclusão de ambiente. Só leitura -
    # o material do modelo não muda. Usam o mesmo posicionamento da textura de
    # cor (as mesmas UVs); sem textura de cor, o tamanho do próprio mapa.
    # No SketchUp o fator multiplica o mapa ('pbr' => true no pacote).
    def pbr_maps(mat, id, diffuse)
      return {} unless mat.respond_to?(:workflow) && defined?(Sketchup::Material::WORKFLOW_PBR_METALLIC_ROUGHNESS)
      return {} unless mat.workflow == Sketchup::Material::WORKFLOW_PBR_METALLIC_ROUGHNESS
      out = {}
      grava = lambda do |tex, sufixo|
        next nil unless tex && tex.respond_to?(:write)
        FileUtils.mkdir_p(@tex_dir)
        ext = File.extname(tex.filename.to_s).downcase
        ext = '.png' unless %w[.png .jpg .jpeg .bmp .tif .tiff].include?(ext)
        path = File.join(@tex_dir, "#{id}_#{sufixo}#{ext}")
        ok = (tex.write(path, false) rescue false)
        next nil unless ok && File.file?(path)
        escala = if diffuse then diffuse['scale_m']
                 else
                   w = tex.width.to_f * INCH_TO_M
                   h = tex.height.to_f * INCH_TO_M
                   [w > 0 ? w : 1.0, h > 0 ? h : 1.0]
                 end
        { 'uri' => "textures/#{File.basename(path)}", 'scale_m' => escala, 'pbr' => true }
      end
      habilitado = ->(m) { !mat.respond_to?(m) || mat.public_send(m) }
      if habilitado.call(:normal_enabled?) && (e = grava.call(mat.normal_texture, 'normal'))
        e['strength'] = [mat.normal_scale.to_f, 0.0].max if mat.respond_to?(:normal_scale)
        if mat.respond_to?(:normal_style) && defined?(Sketchup::Material::NORMAL_STYLE_DIRECTX)
          e['directx'] = true if mat.normal_style == Sketchup::Material::NORMAL_STYLE_DIRECTX
        end
        out['normal'] = e
      end
      if mat.respond_to?(:roughness_texture) && habilitado.call(:roughness_enabled?) &&
         (e = grava.call(mat.roughness_texture, 'rugosidade_pbr'))
        out['roughness'] = e
      end
      if mat.respond_to?(:metallic_texture) && habilitado.call(:metalness_enabled?) &&
         (e = grava.call(mat.metallic_texture, 'metalico'))
        out['metallic'] = e
      end
      if mat.respond_to?(:ao_texture) && habilitado.call(:ao_enabled?) && (e = grava.call(mat.ao_texture, 'ao'))
        e['strength'] = mat.ao_strength.to_f if mat.respond_to?(:ao_strength)
        out['ao'] = e
      end
      out
    rescue StandardError => e
      puts "Blendit: mapas PBR de #{id} ignorados (#{e.message})"
      {}
    end

    # Grava a textura (já colorizada, se o material foi ajustado no SketchUp) e
    # informa o tamanho real do ladrilho em metros - o Blendit projeta a imagem
    # nessa escala.
    def texture_map(mat, id)
      tex = mat.texture
      return nil unless tex && tex.respond_to?(:write)
      FileUtils.mkdir_p(@tex_dir)
      ext = File.extname(tex.filename.to_s).downcase
      ext = '.png' unless %w[.png .jpg .jpeg .bmp .tif .tiff].include?(ext)
      fname = "#{id}#{ext}"
      path = File.join(@tex_dir, fname)
      ok = begin
        tex.write(path, true)
      rescue StandardError
        false
      end
      return nil unless ok && File.file?(path)
      w = tex.width.to_f * INCH_TO_M
      h = tex.height.to_f * INCH_TO_M
      entry = { 'uri' => "textures/#{fname}", 'scale_m' => [w > 0 ? w : 1.0, h > 0 ? h : 1.0] }
      entry['alpha'] = true if png_com_transparencia?(path)
      entry
    end

    def attr_of(mat, key)
      mat.respond_to?(:get_attribute) ? mat.get_attribute('blendit', key) : nil
    end

    # Relevo (mapa de altura) de um material da biblioteca, na mesma escala da cor.
    def bump_map(mat, id, diffuse)
      src = attr_of(mat, 'relevo').to_s
      return nil if src.empty? || !File.file?(src)
      FileUtils.mkdir_p(@tex_dir)
      fname = "#{id}_relevo#{File.extname(src)}"
      FileUtils.cp(src, File.join(@tex_dir, fname))
      { 'uri' => "textures/#{fname}", 'scale_m' => diffuse['scale_m'], 'amount' => 0.35 }
    rescue StandardError
      nil
    end

    # Mapa de rugosidade (onde a superfície brilha mais ou menos), mesma escala.
    def rough_map(mat, id, diffuse)
      src = attr_of(mat, 'rugosidade_mapa').to_s
      if src.empty? || !File.file?(src)
        tag = attr_of(mat, 'textura')
        src = (defined?(Texturas) && tag ? Texturas.rugo_em_cache(tag) : nil).to_s
      end
      return nil if src.empty? || !File.file?(src)
      FileUtils.mkdir_p(@tex_dir)
      fname = "#{id}_rugosidade#{File.extname(src)}"
      FileUtils.cp(src, File.join(@tex_dir, fname))
      { 'uri' => "textures/#{fname}", 'scale_m' => diffuse['scale_m'] }
    rescue StandardError
      nil
    end

    # PNG com canal alfa (tipo de cor 4 ou 6) - plantas, cortinas, pessoas 2D.
    def png_com_transparencia?(path)
      head = File.binread(path, 26)
      return false unless head && head.bytesize >= 26 && head[0, 8] == "\x89PNG\r\n\x1a\n".b
      [4, 6].include?(head.getbyte(25)) || File.binread(path).include?('tRNS')
    rescue StandardError
      false
    end

    # ---------------------------------------------------------------- spec
    def build_spec
      view = @model.active_view
      cam = view.camera
      vw = [view.vpwidth.to_f, 1.0].max
      vh = [view.vpheight.to_f, 1.0].max
      aspect = vw / vh

      camera = {
        'name' => scene_name,
        'position' => cam.eye.to_a.map(&:to_f),
        'target' => cam.target.to_a.map(&:to_f),
        'up' => cam.up.to_a.map(&:to_f),
        'sensor_mm' => 36.0,
        'clip_start' => 1.0,
        'clip_end' => 1.0e7,
        'framing_margin' => 1.0,
        'shift_x' => 0.0,
        'shift_y' => 0.0,
        'frame' => 'view', # reproduz o enquadramento exato do SketchUp
        'crop_aspect' => aspect
      }
      if cam.perspective?
        fov = cam.fov.to_f
        fov_is_height = cam.respond_to?(:fov_is_height?) ? cam.fov_is_height? : true
        hfov = if fov_is_height
                 2.0 * Math.atan(Math.tan(fov * Math::PI / 360.0) * aspect) * 180.0 / Math::PI
               else
                 fov
               end
        camera['type'] = 'perspective'
        camera['fov_degrees'] = hfov
        camera['ortho_scale'] = nil
        camera['two_point_perspective'] = @opts[:dois_pontos] || (cam.respond_to?(:is_2d?) && cam.is_2d?) ? true : false
      else
        camera['type'] = 'orthographic'
        camera['fov_degrees'] = 45.0
        camera['ortho_scale'] = cam.height.to_f * aspect # largura do quadro
        camera['two_point_perspective'] = false
      end

      res = @opts[:resolution] || [1600, 900]
      width = res[0].to_i
      height = (width / aspect).round
      @opts[:resolution] = [width, height]

      {
        'contract_version' => CONTRACT_VERSION,
        'source' => {
          'app' => 'SketchUp',
          'app_version' => Sketchup.version.to_s,
          'document' => @model.title.to_s,
          'active_view' => scene_name,
          'exported_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
        },
        'units' => { 'source_unit' => 'inches', 'scale_to_meters' => INCH_TO_M, 'up_axis' => 'Z' },
        'coordinate_system' => {
          'project_base_point' => [0.0, 0.0, 0.0],
          # 0: a direção do sol abaixo já está nos eixos do modelo.
          'true_north_degrees' => 0.0
        },
        'materials' => @mat_order,
        'camera' => camera,
        'sun' => sun_spec,
        'lights' => @lights,
        'world' => world_spec,
        'render' => {
          'mode' => (@opts[:mode] || 'realistic').to_s,
          'engine' => (@opts[:engine] || 'EEVEE').to_s,
          'resolution' => [width, height],
          'samples' => (@opts[:samples] || 64).to_i,
          'denoise' => @opts.key?(:denoise) ? !!@opts[:denoise] : true,
          'film_transparent' => false,
          'view_transform' => 'AgX',
          'exposure' => 0.0,
          'interior' => interior_flag,
          'materials_mode' => @modo,
          'procedural_by_name' => !estrito?,
          'tone' => (@opts[:tom] || 'natural').to_s,
          'brightness' => (@opts[:brilho] || 0).to_f
        }.merge(@section_used ? { 'section_fill' => [0.06, 0.06, 0.06] } : {})
      }
    end

    # Ambiente interno: 'auto' (o Blendit descobre), true (força: fecha o forro
    # se faltar) ou false (cena externa).
    def interior_flag
      case @opts[:interior].to_s
      when 'sim' then true
      when 'nao' then false
      else 'auto'
      end
    end

    def world_spec
      w = { 'sky_type' => 'nishita', 'hdri_uri' => nil,
            'strength' => @opts[:noite] ? 0.02 : 1.0,
            'ground_albedo' => [0.3, 0.3, 0.3], 'has_site' => has_site?,
            'ground_under_site' => true }
      c = @hdri
      return w unless c
      w = w.merge('sky_type' => 'hdri', 'hdri_uri' => c[:uri], 'hdri_strength' => c[:ceu].to_f,
                  'hdri_normalize' => true)
      w['hdri_ground'] = true if c[:paisagem]
      w
    end

    # Céu fotografado (HDRI): copia o .hdr para o pacote. Só de dia e nos
    # estilos com luz; nos outros o céu simulado/neutro continua.
    def copy_hdri(out_dir)
      c = @opts[:ceu]
      return unless c && c[:path] && File.file?(c[:path].to_s)
      return if @opts[:noite] || !%w[realistic specular].include?(@opts[:mode].to_s)
      d = File.join(out_dir, 'hdri')
      FileUtils.mkdir_p(d)
      name = File.basename(c[:path])
      FileUtils.cp(c[:path], File.join(d, name))
      @hdri = c.merge(uri: "hdri/#{name}")
    rescue StandardError
      @hdri = nil
    end

    # Sol: a mesma direção que gera as sombras do SketchUp (Janela > Sombras).
    def sun_spec
      si = @model.shadow_info
      d = si['SunDirection'] # aponta PARA o sol, nos eixos do modelo
      # Cena noturna: sol apagado e céu quase escuro - só as luminárias iluminam.
      forca = @opts[:noite] ? 0.0 : (@hdri ? @hdri[:sol].to_f : 1.0)
      base = { 'strength' => forca, 'angle_degrees' => 0.526, 'color' => @hdri ? @hdri[:cor] : nil,
               'daylight_saving' => false, 'latitude' => nil, 'longitude' => nil,
               'date' => nil, 'time' => nil, 'timezone' => nil,
               'azimuth_degrees' => nil, 'altitude_degrees' => nil }
      if d && d.length > 0
        base.merge('mode' => 'vector', 'direction' => [-d.x.to_f, -d.y.to_f, -d.z.to_f])
      else
        base.merge('mode' => 'direct', 'direction' => nil,
                   'azimuth_degrees' => 135.0, 'altitude_degrees' => 40.0)
      end
    end

    def scene_name
      page = @model.pages.selected_page
      page ? page.name.to_s : 'Vista atual'
    end
  end
end
