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
      @opts = opts
      @buckets = {}          # [chave, material_id] -> MeshBucket
      @materials = {}        # Sketchup::Material (ou :default) -> registro do contrato
      @mat_order = []
      @faces = 0
      @tex_dir = nil
      @tex_names = {}
      @ground_area = 0.0
      @min_z = Float::INFINITY
      @bounds = nil
    end

    attr_reader :faces

    # Exporta para out_dir e devolve o caminho do scene_spec.json.
    def export(out_dir)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      @tex_dir = File.join(out_dir, 'textures')

      @bounds = @model.bounds
      walk(@model.entities, Geom::Transformation.new, nil, ['Soltos', 'Geometria solta', ''], 0)
      raise 'Nada visível para exportar nesta vista.' if @buckets.empty?

      spec = build_spec
      BundleWriter.new.write(@buckets.values, spec, out_dir)
    end

    private

    # ---------------------------------------------------------------- visibilidade
    def visible?(e)
      return false if e.respond_to?(:hidden?) && e.hidden?
      layer = e.respond_to?(:layer) ? e.layer : nil
      return true if layer.nil?
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
    # key = [nó, rótulo, categoria] do objeto de nível superior que contém a face
    def walk(entities, tr, inherited, key, depth)
      entities.each do |e|
        next unless visible?(e)
        case e
        when Sketchup::Face
          add_face(e, tr, inherited, key)
        when Sketchup::Group, Sketchup::ComponentInstance
          defn = e.definition
          next if defn.nil?
          child_key = key
          if depth.zero?
            label = e.name.to_s.empty? ? defn.name.to_s : e.name.to_s
            tag = e.layer ? e.layer.name.to_s : ''
            child_key = ["E#{e.entityID}", label, tag]
          end
          child_mat = e.material || inherited
          walk(defn.entities, tr * e.transformation, child_mat, child_key, depth + 1)
        end
      end
    end

    def add_face(face, tr, inherited, key)
      mat = face.material || inherited || face.back_material
      mid = material_id(mat)
      bkey = [key[0], mid]
      bucket = @buckets[bkey]
      unless bucket
        node = "#{key[0]}_#{mid}"
        bucket = MeshBucket.new(node, mid)
        bucket.label = key[1]
        bucket.category = key[2]
        @buckets[bkey] = bucket
      end

      mesh = face.mesh(0)
      pts = mesh.points.map { |p| p.transform(tr) }
      return if pts.empty?

      mirrored = mirrored?(tr)
      n = xform_normal(face.normal, tr, mirrored)

      # Arestas suavizadas (cilindros, curvas, terreno): normal média por vértice,
      # para a superfície sair lisa no render em vez de facetada.
      normals = nil
      if face.edges.any? { |ed| ed.smooth? || ed.soft? }
        by_pos = {}
        face.vertices.each { |vx| by_pos[pos_key(vx.position)] = vx }
        normals = mesh.points.map do |p|
          vx = by_pos[pos_key(p)]
          vx ? xform_normal(smooth_normal(face, vx), tr, mirrored) : n
        end
      end

      tris = []
      mesh.polygons.each do |poly|
        idx = poly.map { |i| i.abs - 1 }
        # A face.mesh já entrega triângulos; por segurança, abre em leque.
        (1...(idx.length - 1)).each do |k|
          tri = [idx[0], idx[k], idx[k + 1]]
          tri = [tri[0], tri[2], tri[1]] if mirrored
          tris << tri
        end
      end
      flat = pts.map { |p| [p.x.to_f, p.y.to_f, p.z.to_f] }
      if normals
        bucket.add_smooth(flat, normals.map { |m| [m.x.to_f, m.y.to_f, m.z.to_f] }, tris)
      else
        bucket.add(flat, [n.x, n.y, n.z], tris)
      end
      @faces += 1
      track_ground(face, pts, n)
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

    def pos_key(p)
      [(p.x * 1000).round, (p.y * 1000).round, (p.z * 1000).round]
    end

    # Média das normais das faces ligadas a `face` por arestas suaves que tocam o
    # vértice - o mesmo critério visual do SketchUp.
    def smooth_normal(face, vertex)
      seen = { face => true }
      queue = [face]
      sum = Geom::Vector3d.new(0, 0, 0)
      until queue.empty?
        f = queue.pop
        sum += f.normal
        vertex.edges.each do |ed|
          next unless (ed.smooth? || ed.soft?) && ed.used_by?(f)
          ed.faces.each do |g|
            next if seen[g]
            seen[g] = true
            queue << g
          end
        end
      end
      sum.length > 0 ? sum.normalize : face.normal
    end

    # Heurística de "terreno próprio": faces horizontais grandes na cota mais baixa.
    # Se o modelo já tem terreno, o Blendit não cria o chão artificial (evita
    # duas superfícies brigando no mesmo lugar).
    def track_ground(face, pts, n)
      return unless n.z.abs > 0.98
      z = pts.map(&:z).min.to_f
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
    def material_id(mat)
      k = mat || :default
      rec = @materials[k]
      return rec['id'] if rec
      rec = mat ? material_record(mat, "m#{@mat_order.length + 1}") : default_record
      @materials[k] = rec
      @mat_order << rec
      rec['id']
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
      tex = texture_map(mat, id)
      rec['maps'] = { 'diffuse' => tex } if tex
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
      { 'uri' => "textures/#{fname}", 'scale_m' => [w > 0 ? w : 1.0, h > 0 ? h : 1.0] }
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
        'frame' => 'view' # reproduz o enquadramento exato do SketchUp
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
        camera['two_point_perspective'] = cam.respond_to?(:is_2d?) && cam.is_2d? ? true : false
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
        'lights' => [],
        'world' => { 'sky_type' => 'nishita', 'hdri_uri' => nil, 'strength' => 1.0,
                     'ground_albedo' => [0.3, 0.3, 0.3], 'has_site' => has_site?,
                     'ground_under_site' => true },
        'render' => {
          'mode' => (@opts[:mode] || 'realistic').to_s,
          'engine' => (@opts[:engine] || 'EEVEE').to_s,
          'resolution' => [width, height],
          'samples' => (@opts[:samples] || 64).to_i,
          'denoise' => @opts.key?(:denoise) ? !!@opts[:denoise] : true,
          'film_transparent' => false,
          'view_transform' => 'AgX',
          'exposure' => 0.0
        }
      }
    end

    # Sol: a mesma direção que gera as sombras do SketchUp (Janela > Sombras).
    def sun_spec
      si = @model.shadow_info
      d = si['SunDirection'] # aponta PARA o sol, nos eixos do modelo
      base = { 'strength' => 1.0, 'angle_degrees' => 0.526, 'color' => nil,
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
