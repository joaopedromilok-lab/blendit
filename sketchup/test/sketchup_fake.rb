# Uma imitação mínima da API do SketchUp, só para testar o exportador fora do
# SketchUp (aqui não existe SketchUp). Cobre exatamente o que exporter.rb usa.
module Geom
  class Vector3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f; @y = y.to_f; @z = z.to_f
    end
    def +(o) = Vector3d.new(x + o.x, y + o.y, z + o.z)
    def -(o) = Vector3d.new(x - o.x, y - o.y, z - o.z)
    def *(s) = Vector3d.new(x * s, y * s, z * s)
    def dot(o) = x * o.x + y * o.y + z * o.z
    def cross(o) = Vector3d.new(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    def length = Math.sqrt(dot(self))
    def normalize
      l = length
      l > 0 ? Vector3d.new(x / l, y / l, z / l) : Vector3d.new
    end
    def normalize!
      n = normalize; @x, @y, @z = n.x, n.y, n.z; self
    end
    def reverse!
      @x, @y, @z = -x, -y, -z; self
    end
    # Mesmo algoritmo de eixo arbitrário do SketchUp (destro: x * y = z).
    def axes
      zz = normalize
      xx = if zz.x.abs < 1.0 / 64 && zz.y.abs < 1.0 / 64
             Vector3d.new(0, 1, 0).cross(zz)
           else
             Vector3d.new(0, 0, 1).cross(zz)
           end.normalize
      [xx, zz.cross(xx).normalize, zz]
    end
    def transform(t) = t.apply_vector(self)
    def to_a = [x, y, z]
    def reverse = Vector3d.new(-x, -y, -z)
  end

  class Point3d
    attr_reader :x, :y, :z
    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f; @y = y.to_f; @z = z.to_f
    end
    def transform(t) = t.apply_point(self)
    def to_a = [x, y, z]
    def -(o) = Vector3d.new(x - o.x, y - o.y, z - o.z)
  end

  class Transformation
    attr_reader :m
    def initialize(m = nil)
      @m = m || [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]].map { |r| r.map(&:to_f) }
    end
    def self.translation(x, y, z)
      new([[1, 0, 0, x], [0, 1, 0, y], [0, 0, 1, z], [0, 0, 0, 1]].map { |r| r.map(&:to_f) })
    end
    def self.scaling(sx, sy, sz)
      new([[sx, 0, 0, 0], [0, sy, 0, 0], [0, 0, sz, 0], [0, 0, 0, 1]].map { |r| r.map(&:to_f) })
    end
    def self.rotation_z(deg)
      a = deg * Math::PI / 180; c = Math.cos(a); s = Math.sin(a)
      new([[c, -s, 0, 0], [s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
    end
    def *(o)
      r = Array.new(4) { Array.new(4, 0.0) }
      4.times { |i| 4.times { |j| r[i][j] = (0..3).sum { |k| m[i][k] * o.m[k][j] } } }
      Transformation.new(r)
    end
    def apply_point(p)
      Point3d.new(*(0..2).map { |i| m[i][0] * p.x + m[i][1] * p.y + m[i][2] * p.z + m[i][3] })
    end
    def apply_vector(v)
      Vector3d.new(*(0..2).map { |i| m[i][0] * v.x + m[i][1] * v.y + m[i][2] * v.z })
    end
    def xaxis = Vector3d.new(m[0][0], m[1][0], m[2][0])
    def yaxis = Vector3d.new(m[0][1], m[1][1], m[2][1])
    def zaxis = Vector3d.new(m[0][2], m[1][2], m[2][2])
  end

  class PolygonMesh
    attr_reader :points, :polygons
    def initialize(points, polygons)
      @points = points; @polygons = polygons
    end
  end

  class BoundingBox
    def initialize(mn, mx)
      @mn = mn; @mx = mx
    end
    def min = Geom::Point3d.new(*@mn)
    def max = Geom::Point3d.new(*@mx)
    def width = @mx[0] - @mn[0]
    def height = @mx[1] - @mn[1]
    def corner(i)
      Point3d.new(i & 1 == 0 ? @mn[0] : @mx[0], i & 2 == 0 ? @mn[1] : @mx[1],
                  i & 4 == 0 ? @mn[2] : @mx[2])
    end
  end
end

module Sketchup
  module Attrs
    def set_attribute(dict, k, v) = ((@attrs ||= {})[[dict, k]] = v)
    def get_attribute(dict, k, d = nil) = (@attrs || {}).fetch([dict, k], d)
  end

  @next_id = 0
  def self.next_id = (@next_id += 1)
  def self.version = '25.0.fake'

  class Color
    attr_reader :red, :green, :blue
    def initialize(r, g, b)
      @red = r; @green = g; @blue = b
    end
  end

  class Texture
    attr_reader :filename, :width, :height
    def initialize(src, width_in, height_in)
      @filename = src; @width = width_in; @height = height_in
    end
    def write(path, _colorize = false)
      File.binwrite(path, File.binread(@filename)); true
    end
  end

  class Material
    include Attrs
    attr_reader :name, :color, :alpha, :texture
    def initialize(name, rgb, alpha: 1.0, texture: nil)
      @name = name; @color = Color.new(*rgb); @alpha = alpha; @texture = texture
    end
    def display_name = name
    def use_alpha? = alpha < 1.0
  end

  class Layer
    attr_reader :name
    def initialize(name, visible = true)
      @name = name; @visible = visible
    end
    def visible? = @visible
    def folder = nil
  end

  class Vertex
    attr_reader :position, :edges
    def initialize(p)
      @position = p; @edges = []
    end
  end

  class Edge
    attr_reader :faces, :vertices
    attr_accessor :smooth
    def initialize(a, b)
      @vertices = [a, b]; @faces = []; @smooth = false
      a.edges << self; b.edges << self
    end
    def smooth? = @smooth
    def soft? = @smooth
    def used_by?(f) = @faces.include?(f)
  end

  class Face
    attr_accessor :material, :back_material, :layer, :hidden
    attr_reader :vertices, :edges, :normal
    def initialize(verts, edges)
      @vertices = verts; @edges = edges
      p = verts.map(&:position)
      @normal = (p[1] - p[0]).cross(p[2] - p[0]).normalize
      @layer = DEFAULT_LAYER
    end
    def hidden? = !!@hidden
    def area
      p = @vertices.map(&:position)
      s = Geom::Vector3d.new
      (1...(p.length - 1)).each { |k| s += (p[k] - p[0]).cross(p[k + 1] - p[0]) }
      s.length / 2
    end
    def bounds
      ps = @vertices.map(&:position)
      Geom::BoundingBox.new([ps.map(&:x).min, ps.map(&:y).min, ps.map(&:z).min],
                            [ps.map(&:x).max, ps.map(&:y).max, ps.map(&:z).max])
    end
    def mesh(_flags = 0)
      n = @vertices.length
      Geom::PolygonMesh.new(@vertices.map(&:position), (1...(n - 1)).map { |k| [1, k + 1, k + 2] })
    end
  end

  class SectionPlane
    def initialize(plane) = (@plane = plane)
    def get_plane = @plane
  end

  class Entities
    include Enumerable
    attr_accessor :active_section_plane
    def initialize
      @list = []; @verts = {}; @edges = {}
    end
    def each(&b) = @list.each(&b)
    def <<(e) = (@list << e; e)
    def vertex(p)
      k = [p.x.round(3), p.y.round(3), p.z.round(3)]
      @verts[k] ||= Vertex.new(p)
    end
    def edge(a, b)
      k = [a.object_id, b.object_id].sort
      @edges[k] ||= Edge.new(a, b)
    end
    # pts = [[x,y,z],...] em polegadas, sentido anti-horário visto de fora
    def add_face(pts)
      vs = pts.map { |c| vertex(Geom::Point3d.new(*c)) }
      es = vs.each_with_index.map { |v, i| edge(v, vs[(i + 1) % vs.length]) }
      f = Face.new(vs, es)
      es.each { |e| e.faces << f }
      self << f
      f
    end
  end

  class ComponentDefinition
    include Attrs
    attr_reader :name, :entities
    def initialize(name)
      @name = name; @entities = Entities.new
    end
    def bounds
      ps = @entities.flat_map { |f| f.respond_to?(:vertices) ? f.vertices.map(&:position) : [] }
      mn = [ps.map(&:x).min, ps.map(&:y).min, ps.map(&:z).min]
      mx = [ps.map(&:x).max, ps.map(&:y).max, ps.map(&:z).max]
      Geom::BoundingBox.new(mn, mx)
    end
  end

  class ComponentInstance
    include Attrs
    attr_accessor :material, :layer, :hidden, :name
    attr_reader :definition, :transformation, :entityID
    def initialize(defn, tr, name: '')
      @definition = defn; @transformation = tr; @name = name
      @layer = DEFAULT_LAYER; @entityID = Sketchup.next_id
    end
    def hidden? = !!@hidden
  end

  class Group < ComponentInstance; end

  DEFAULT_LAYER = Layer.new('Untagged')

  class Camera
    attr_reader :eye, :target, :up, :fov, :height
    def initialize(eye, target, fov)
      @eye = Geom::Point3d.new(*eye); @target = Geom::Point3d.new(*target)
      @up = Geom::Vector3d.new(0, 0, 1); @fov = fov; @height = 500
    end
    def perspective? = true
    def fov_is_height? = true
    def is_2d? = false
  end

  class View
    attr_reader :camera
    def initialize(cam)
      @camera = cam
    end
    def vpwidth = 1600
    def vpheight = 900
  end

  class Pages
    def selected_page = nil
    def to_a = []
  end

  # Sol aproximado (só para teste): horário local = componentes "UTC" do Time.
  class ShadowInfo
    def initialize(dir)
      @h = { 'Latitude' => -22.78, 'Longitude' => -47.29, 'TZOffset' => -3.0,
             'City' => 'Nova Odessa', 'Country' => 'Brasil', 'NorthAngle' => 0.0,
             'ShadowTime' => Time.gm(2026, 10, 17, 15, 0) }
      @fixed = dir
    end
    def [](k)
      return (@fixed || sun_dir) if k == 'SunDirection'
      @h[k]
    end
    def []=(k, v)
      @fixed = nil if k == 'ShadowTime'
      @h[k] = v
    end
    def sun_dir
      t = @h['ShadowTime']; lat = @h['Latitude'] * Math::PI / 180
      doy = t.yday
      decl = 23.44 * Math.sin(2 * Math::PI * (284 + doy) / 365.0) * Math::PI / 180
      solar = t.hour + t.min / 60.0 + (@h['Longitude'] - 15 * @h['TZOffset']) / 15.0
      ha = (solar - 12) * 15 * Math::PI / 180
      alt = Math.asin(Math.sin(lat) * Math.sin(decl) + Math.cos(lat) * Math.cos(decl) * Math.cos(ha))
      az = Math.atan2(-Math.sin(ha), Math.tan(decl) * Math.cos(lat) - Math.sin(lat) * Math.cos(ha))
      Geom::Vector3d.new(Math.sin(az) * Math.cos(alt), Math.cos(az) * Math.cos(alt), Math.sin(alt))
    end
  end

  class Model
    include Attrs
    def start_operation(*) = true
    def abort_operation = true
    attr_reader :entities, :active_view, :shadow_info, :rendering_options, :pages, :title
    def initialize(title, cam, sun_dir, bounds)
      @title = title; @entities = Entities.new; @active_view = View.new(cam)
      @shadow_info = ShadowInfo.new(sun_dir)
      @rendering_options = { 'FaceFrontColor' => Color.new(235, 235, 230) }
      @pages = Pages.new; @bounds = bounds
    end
    def bounds = @bounds
    # Materiais usados nas faces (para as ferramentas que listam model.materials).
    def materials
      found = []
      walk = lambda do |ents, inh|
        ents.each do |e|
          if e.respond_to?(:definition)
            found << e.material if e.material
            walk.call(e.definition.entities, e.material || inh)
          elsif e.respond_to?(:material)
            found << e.material if e.material
          end
        end
      end
      walk.call(@entities, nil)
      found.compact.uniq
    end
  end
end
