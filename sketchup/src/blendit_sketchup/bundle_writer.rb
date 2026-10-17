# encoding: UTF-8
# Blendit para SketchUp - escritor do "bundle" (scene_spec.json + scene.glb).
#
# Ruby puro, SEM dependência da API do SketchUp: recebe malhas já trianguladas
# (coordenadas do mundo, Z para cima, em polegadas) e grava o mesmo formato que o
# lado Revit grava (ver docs/contract.md). Por isso dá para testar fora do SketchUp.
#
# EIXOS: glTF é Y-up. Este é o ÚNICO lugar onde Z-up vira Y-up: (x, y, z) -> (x, z, -y).
# O importador glTF do Blender converte de volta para Z-up.
require 'json'
require 'fileutils'

module BlenditSU
  CONTRACT_VERSION = '0.3.0'.freeze

  # Uma malha por nó do glTF (um nó = um "elemento" do contrato).
  class MeshBucket
    attr_reader :node, :material_id, :positions, :normals, :indices, :uvs
    attr_accessor :category, :label

    def initialize(node, material_id)
      @node = node
      @material_id = material_id
      @positions = []   # x,y,z achatados (Z-up, polegadas)
      @normals = []
      @indices = []
      @uvs = []         # u,v achatados (unidades de textura); vazio = sem UV
      @uv_ok = true     # vira false se alguma face entrar sem UV
      @category = ''
      @label = ''
    end

    def vertex_count
      @positions.length / 3
    end

    # Acrescenta um polígono já triangulado: pts = [[x,y,z],...], tris = [[a,b,c],...]
    def add(pts, normal, tris)
      base = vertex_count
      pts.each do |p|
        @positions.push(p[0].to_f, p[1].to_f, p[2].to_f)
        @normals.push(normal[0].to_f, normal[1].to_f, normal[2].to_f)
      end
      tris.each { |t| @indices.push(base + t[0], base + t[1], base + t[2]) }
      @uv_ok = false            # faces planas antigas não trazem UV
      @uvs.push(*([0.0] * (pts.length * 2)))
    end

    # Igual a `add`, mas com uma normal por vértice (superfícies suavizadas) e,
    # opcionalmente, uma coordenada de textura por vértice.
    def add_smooth(pts, normals, tris, uvs = nil)
      base = vertex_count
      @uv_ok = false if uvs.nil? || uvs.length != pts.length
      pts.each_with_index do |p, i|
        n = normals[i]
        @positions.push(p[0].to_f, p[1].to_f, p[2].to_f)
        @normals.push(n[0].to_f, n[1].to_f, n[2].to_f)
        uv = uvs && uvs[i]
        @uvs.push(uv ? uv[0].to_f : 0.0, uv ? uv[1].to_f : 0.0)
      end
      tris.each { |t| @indices.push(base + t[0], base + t[1], base + t[2]) }
    end

    def empty?
      @indices.empty?
    end

    # Só vale UV se TODOS os vértices têm (senão o Blender recebe zeros).
    def uvs?
      @uv_ok && !@uvs.empty? && @uvs.length == vertex_count * 2
    end

    def drop_uvs!
      @uv_ok = false
    end
  end

  class BundleWriter
    GLB_MAGIC = 0x46546C67
    CHUNK_JSON = 0x4E4F534A
    CHUNK_BIN = 0x004E4942
    FLOAT = 5126
    UINT = 5125

    # buckets: [MeshBucket], spec: Hash (sem a parte de geometria), out_dir: pasta
    def write(buckets, spec, out_dir)
      FileUtils.mkdir_p(out_dir)
      buckets = buckets.reject(&:empty?)
      gltf, blob = build_gltf(buckets, spec['materials'] || [])
      File.binwrite(File.join(out_dir, 'scene.glb'), assemble_glb(gltf, blob))

      spec['geometry'] = {
        'transport' => 'gltf',
        'uri' => 'scene.glb',
        'elements' => buckets.map do |b|
          { 'node' => b.node, 'element_id' => b.node, 'category' => b.category.to_s,
            'family' => b.label.to_s, 'type_name' => '', 'level' => '',
            'material_id' => b.material_id }
        end
      }
      path = File.join(out_dir, 'scene_spec.json')
      File.open(path, 'w:UTF-8') { |f| f.write(JSON.pretty_generate(spec)) }
      path
    end

    private

    def build_gltf(buckets, materials)
      blob = String.new(encoding: Encoding::BINARY)
      accessors = []
      views = []
      meshes = []
      nodes = []
      mat_index = {}
      materials.each_with_index { |m, i| mat_index[m['id']] = i }

      buckets.each do |b|
        # POSITION (Z-up -> Y-up)
        pos = Array.new(b.positions.length)
        mn = [Float::INFINITY] * 3
        mx = [-Float::INFINITY] * 3
        i = 0
        while i < b.positions.length
          x = b.positions[i]; y = b.positions[i + 2]; z = -b.positions[i + 1]
          pos[i] = x; pos[i + 1] = y; pos[i + 2] = z
          mn[0] = x if x < mn[0]; mx[0] = x if x > mx[0]
          mn[1] = y if y < mn[1]; mx[1] = y if y > mx[1]
          mn[2] = z if z < mn[2]; mx[2] = z if z > mx[2]
          i += 3
        end
        prim = { 'mode' => 4, 'attributes' => {} }
        prim['attributes']['POSITION'] =
          push_view(blob, views, accessors, pos.pack('e*'), 34962,
                    'componentType' => FLOAT, 'count' => b.vertex_count,
                    'type' => 'VEC3', 'min' => mn, 'max' => mx)

        nrm = Array.new(b.normals.length)
        i = 0
        while i < b.normals.length
          nrm[i] = b.normals[i]; nrm[i + 1] = b.normals[i + 2]; nrm[i + 2] = -b.normals[i + 1]
          i += 3
        end
        prim['attributes']['NORMAL'] =
          push_view(blob, views, accessors, nrm.pack('e*'), 34962,
                    'componentType' => FLOAT, 'count' => b.vertex_count, 'type' => 'VEC3')

        if b.uvs?
          # glTF tem a origem da imagem no canto de CIMA (v para baixo); o
          # SketchUp e o Blender, no de baixo. O importador do Blender desfaz
          # este 1 - v.
          tc = Array.new(b.uvs.length)
          i = 0
          while i < b.uvs.length
            tc[i] = b.uvs[i]
            tc[i + 1] = 1.0 - b.uvs[i + 1]
            i += 2
          end
          prim['attributes']['TEXCOORD_0'] =
            push_view(blob, views, accessors, tc.pack('e*'), 34962,
                      'componentType' => FLOAT, 'count' => b.vertex_count, 'type' => 'VEC2')
        end

        prim['indices'] =
          push_view(blob, views, accessors, b.indices.pack('V*'), 34963,
                    'componentType' => UINT, 'count' => b.indices.length, 'type' => 'SCALAR')

        prim['material'] = mat_index[b.material_id] if mat_index.key?(b.material_id)
        meshes << { 'primitives' => [prim] }
        nodes << { 'name' => b.node, 'mesh' => meshes.length - 1 }
      end

      gltf = {
        'asset' => { 'version' => '2.0', 'generator' => 'Blendit para SketchUp' },
        'scene' => 0,
        'scenes' => [{ 'nodes' => (0...nodes.length).to_a }],
        'nodes' => nodes,
        'meshes' => meshes,
        'accessors' => accessors,
        'bufferViews' => views,
        'buffers' => [{ 'byteLength' => blob.bytesize }]
      }
      gltf['materials'] = materials.map { |m| gltf_material(m) } unless materials.empty?
      [gltf, blob]
    end

    def push_view(blob, views, accessors, bytes, target, accessor)
      offset = blob.bytesize
      blob << bytes
      views << { 'buffer' => 0, 'byteOffset' => offset, 'byteLength' => bytes.bytesize,
                 'target' => target }
      blob << ("\x00" * ((4 - blob.bytesize % 4) % 4))
      accessors << accessor.merge('bufferView' => views.length - 1)
      accessors.length - 1
    end

    def gltf_material(rec)
      c = rec['base_color'] || [0.8, 0.8, 0.8]
      t = (rec['transparency'] || 0.0).to_f
      m = { 'name' => rec['name'] || rec['id'],
            'pbrMetallicRoughness' => {
              'baseColorFactor' => [c[0].to_f, c[1].to_f, c[2].to_f, 1.0 - t],
              'metallicFactor' => (rec['metallic'] || 0.0).to_f,
              'roughnessFactor' => (rec['roughness'] || 0.5).to_f
            } }
      m['alphaMode'] = 'BLEND' if t > 0.0
      m
    end

    def assemble_glb(gltf, blob)
      json = JSON.generate(gltf).dup.force_encoding(Encoding::BINARY)
      json << (' ' * ((4 - json.bytesize % 4) % 4))
      bin = blob.dup
      bin << ("\x00" * ((4 - bin.bytesize % 4) % 4))
      total = 12 + 8 + json.bytesize + 8 + bin.bytesize
      out = String.new(encoding: Encoding::BINARY)
      out << [GLB_MAGIC, 2, total].pack('V3')
      out << [json.bytesize, CHUNK_JSON].pack('V2') << json
      out << [bin.bytesize, CHUNK_BIN].pack('V2') << bin
      out
    end
  end

  # sRGB (0-255) -> linear (0-1), como o contrato pede.
  def self.srgb_to_linear(v255)
    c = v255.to_f / 255.0
    c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
  end
end
