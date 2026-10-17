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
      @in_light = nil
      @section_used = false
    end

    attr_reader :faces, :lights, :section_used

    # Exporta para out_dir e devolve o caminho do scene_spec.json.
    def export(out_dir)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      @tex_dir = File.join(out_dir, 'textures')
      copy_hdri(out_dir)

      @bounds = @model.bounds
      walk(@model.entities, Geom::Transformation.new, nil, ['Soltos', 'Geometria solta', ''], 0)
      raise 'Nada visível para exportar nesta vista.' if @buckets.empty?

      @geom_cache = @vnorm_cache = nil       # libera a memória antes de gravar
      spec = build_spec
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
          @in_light ||= light_kind(e, defn)
          was_c = @in_curtain
          @in_curtain ||= curtain_kind(e, defn)
          child_mat = e.material || inherited
          walk(defn.entities, child_tr, child_mat, child_key, depth + 1, clips)
          @in_light = was
          @in_curtain = was_c
        end
      end
    end

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
      pa, na = a
      pb, nb = b
      pos = (0..2).map { |k| pa[k] + (pb[k] - pa[k]) * t }
      nrm = (0..2).map { |k| na[k] + (nb[k] - na[k]) * t }
      l = Math.sqrt(nrm.sum { |x| x * x })
      nrm = nrm.map { |x| x / l } if l > 0
      [pos, nrm]
    end

    # ---------------------------------------------------------------- luzes
    # Luminárias viram luzes de verdade no Blender, reconhecidas pelo NOME do
    # componente/grupo (ou da definição). Dá para ajustar uma luminária pelo
    # dicionário de atributos "blendit": luz=nao, kelvin=2700, candela=1200.
    LIGHT_RULES = [
      [:fita,     ['fita led', 'fita de led', 'led strip', 'perfil led', 'perfil de led']],
      [:pendente, ['pendente', 'pendant', 'lustre', 'chandelier']],
      [:spot,     ['spot', 'embutido', 'downlight', 'dicroica', 'dicroico', 'ar70', 'ar111',
                   'par20', 'par30', 'balizador']],
      [:plafon,   ['plafon', 'plafom', 'plafonier', 'ceiling light', 'painel led', 'painel de led']],
      [:arandela, ['arandela', 'sconce', 'wall light']],
      [:abajur,   ['abajur', 'luminaria de mesa', 'luminaria de piso', 'luminaria de chao',
                   'luminaria de coluna', 'table lamp', 'floor lamp']],
      [:generica, ['luminaria', 'lampada', 'lamp', 'light', 'luz']]
    ].freeze

    # [kelvin, candela, tipo]
    LIGHT_DEFAULTS = {
      spot: [3000, 2500, 'spot'], pendente: [2700, 1300, 'point'], plafon: [3000, 2000, 'point'],
      arandela: [2700, 800, 'point'], abajur: [2700, 700, 'point'], generica: [3000, 1300, 'point'],
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
              when :arandela, :abajur
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
          'spot_beam_deg' => type == 'spot' ? 36.0 : nil,
          'spot_field_deg' => type == 'spot' ? 60.0 : nil,
          'radius_m' => kind == :plafon ? 0.12 : (kind == :fita ? 0.01 : 0.04),
          'on' => true
        }
      end
    end

    # ---------------------------------------------------------------- faces
    def add_face(face, tr, inherited, key, clips = [])
      mat = face.material || inherited || face.back_material
      mid = material_id(mat, @in_curtain && !mat_rigid?(mat) ? @in_curtain : nil)

      lpts, lnormal, lnormals, ltris = local_geom(face)
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

      unless clips.empty?
        vp = []
        vn = []
        out_tris = []
        tris.each do |t|
          poly = t.map { |i| [flat[i], nrms[i]] }
          clips.each { |c| poly = clip_poly(poly, c) if poly.length >= 3 }
          next if poly.length < 3
          base = vp.length
          poly.each { |pos, nr| vp << pos; vn << nr }
          (1...(poly.length - 1)).each { |k| out_tris << [base, base + k, base + k + 1] }
        end
        return if out_tris.empty?
        flat, nrms, tris = vp, vn, out_tris
      end

      bucket_for(key, mid).add_smooth(flat, nrms, tris)
      @faces += 1
      track_ground(face, flat, n)
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
        mesh = face.mesh(0)
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
        [mpts.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] }, vec3(face.normal), lnormals, tris]
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
        rec['name'] = "#{rec['name']} (cortina)"
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
      rec
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
      w.merge('sky_type' => 'hdri', 'hdri_uri' => c[:uri], 'hdri_strength' => c[:ceu].to_f,
              'hdri_normalize' => true)
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
