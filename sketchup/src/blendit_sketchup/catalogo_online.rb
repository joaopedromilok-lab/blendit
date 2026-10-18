# encoding: UTF-8
# Blendit para SketchUp - catálogo online de texturas (Poly Haven + ambientCG).
#
# DESCOBERTA de materiais nas fontes oficiais, sem baixar texturas: só
# metadados (id, nome, categoria, tags, miniatura, mapas, resoluções, licença).
# A biblioteca fixa (Texturas::CATALOGO, 157 itens) continua intacta e é a base
# do catálogo unificado; os itens online se somam a ela.
#
# Fontes (documentação consultada em 17/10/2026):
#   Poly Haven - api.polyhaven.com (swagger.json oficial):
#     GET /assets?type=textures  -> { id => {name, type, categories, category,
#                                    tags, dimensions(mm), max_resolution,
#                                    thumbnail_url, authors, date_published...} }
#                                   (sem paginação - tudo numa resposta)
#     GET /files/{id}            -> mapas por resolução/formato {url, md5, size}
#                                   (só sob demanda, item a item)
#     Termos de uso da API (Public-API/ToS.md): cabeçalho User-Agent único
#     (2.4); os assets são CC0; indicar a origem do conteúdo vindo da API (2.5).
#   ambientCG - ambientcg.com/api/v2/full_json (docs.ambientcg.com/api/v2):
#     type=Material, limit (1..250), offset, sort, include=tagData,displayData,
#     dimensionsData,downloadData,previewData,mapData
#     -> {numberOfResults, nextPageHttp, foundAssets: [{assetId, displayName,
#        displayCategory, tags, maps, previewImage{"256-PNG"...},
#        downloadFolders.default.downloadFiletypeCategories.zip.downloads
#        [{attribute "1K-JPG", size, downloadLink}], dataType, ...}]}
#     Licença (docs.ambientcg.com/license): todos os assets CC0 1.0.
#
# Nenhuma das duas APIs devolve a licença ITEM A ITEM: a licença registrada é a
# política declarada pela fonte (com o documento de origem), não um palpite.
require 'json'
require 'fileutils'
require 'tmpdir'

module BlenditSU
  module CatalogoOnline
    FORMATO = 1
    UA = 'BlenditSketchUp-catalogo/0.4 (plugin SketchUp; github.com/joaopedromilok-lab/blendit)'.freeze
    PH_ASSETS = 'https://api.polyhaven.com/assets?type=textures'.freeze
    PH_FILES = 'https://api.polyhaven.com/files/%s'.freeze
    PH_PAGINA = 'https://polyhaven.com/a/%s'.freeze
    ACG_LISTA = 'https://ambientcg.com/api/v2/full_json?type=Material&sort=Alphabet' \
                '&include=tagData,displayData,dimensionsData,downloadData,previewData,mapData' \
                '&limit=%d&offset=%d'.freeze
    ACG_PAGINA = 'https://ambientcg.com/a/%s'.freeze
    ACG_POR_PAGINA = 250            # máximo permitido pela API
    MAX_PAGINAS = 60                # trava de segurança (15 000 itens)
    MAX_BYTES = 60 * 1024 * 1024    # resposta maior que isso é recusada
    LICENCAS = {
      'polyhaven' => { 'licenca' => 'CC0-1.0',
                       'fonte' => 'Poly Haven API ToS (github.com/Poly-Haven/Public-API/blob/master/ToS.md): ' \
                                  '"published under the CC0 license"',
                       'credito' => 'Texturas da API Poly Haven (polyhaven.com)' },
      'ambientcg' => { 'licenca' => 'CC0-1.0',
                       'fonte' => 'docs.ambientcg.com/license: Creative Commons CC0 1.0 Universal',
                       'credito' => 'Texturas do ambientCG (ambientcg.com)' }
    }.freeze
    NAO_MAPAS = %w[blend gltf mtlx fbx usd].freeze

    class ErroFonte < StandardError; end

    # --------------------------------------------------------------- HTTP
    # Substituível nos testes: CatalogoOnline.http = ->(url) { '...json...' }
    class << self
      attr_writer :http
    end

    def self.http
      @http ||= method(:http_get)
    end

    def self.http_get(url)
      require 'net/http'
      require 'openssl'
      corpo = begin
        net_get(url, 3)
      rescue StandardError => e
        curl_get(url) || raise(ErroFonte, "falha de rede em #{url}: #{e.class}: #{e.message}")
      end
      raise ErroFonte, "resposta grande demais de #{url}" if corpo.bytesize > MAX_BYTES
      corpo
    end

    def self.net_get(url, redirecionamentos)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                open_timeout: 15, read_timeout: 60) do |h|
        h.request(Net::HTTP::Get.new(uri, 'User-Agent' => UA, 'Accept' => 'application/json'))
      end
      if res.is_a?(Net::HTTPRedirection) && redirecionamentos > 0
        return net_get(URI.join(url, res['location']).to_s, redirecionamentos - 1)
      end
      raise ErroFonte, "HTTP #{res.code} em #{url}" unless res.is_a?(Net::HTTPSuccess)
      res.body.to_s
    end

    # SketchUp no Windows às vezes não valida o SSL do Ruby; o curl.exe do Windows valida.
    def self.curl_get(url)
      curl = File.join(ENV['SystemRoot'] || 'C:/Windows', 'System32', 'curl.exe')
      curl = 'curl' unless File.file?(curl)
      tmp = File.join(Dir.tmpdir, "blendit_cat_#{Process.pid}_#{rand(1 << 30)}.json")
      ok = system(curl, '-L', '-s', '-f', '--max-time', '90', '-A', UA, '-o', tmp, url)
      ok && File.size?(tmp) ? File.binread(tmp) : nil
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def self.json(url)
      txt = http.call(url).to_s
      raise ErroFonte, "resposta vazia de #{url}" if txt.strip.empty?
      JSON.parse(txt)
    rescue JSON::ParserError => e
      raise ErroFonte, "JSON inválido de #{url}: #{e.message[0, 120]}"
    end

    # --------------------------------------------------------------- Poly Haven
    # -> [itens, descartados(motivos)]
    def self.descobrir_polyhaven
      dados = json(PH_ASSETS)
      raise ErroFonte, 'Poly Haven: resposta não é um objeto de assets' unless dados.is_a?(Hash)
      raise ErroFonte, 'Poly Haven: nenhum asset na resposta' if dados.empty?
      itens = []
      fora = []
      dados.each do |id, a|
        unless id.is_a?(String) && id =~ /\A[a-z0-9_\-]+\z/i && a.is_a?(Hash)
          fora << "#{id}: id ou registro inválido"
          next
        end
        next fora << "#{id}: não é textura (type=#{a['type'].inspect})" unless a['type'] == 1
        next fora << "#{id}: sem nome" unless a['name'].is_a?(String) && !a['name'].strip.empty?
        dim = a['dimensions']
        dim_m = dim.is_a?(Array) && dim.length >= 2 && dim[0].to_f > 0 && dim[1].to_f > 0 ?
                  [dim[0].to_f / 1000.0, dim[1].to_f / 1000.0] : nil
        mx = a['max_resolution'].is_a?(Array) ? a['max_resolution'].first(2).map(&:to_i) : nil
        itens << item('polyhaven', id,
                      'nome' => a['name'].strip,
                      'categoria' => a['category'].is_a?(String) ? a['category'] : nil,
                      'categorias' => Array(a['categories']).grep(String),
                      'tags' => Array(a['tags']).grep(String),
                      'miniatura' => url_ok(a['thumbnail_url']) || format(Texturas::PH_THUMB, id),
                      'dimensoes_m' => dim_m,
                      'resolucao_max' => mx,
                      'mapas' => nil,              # detalhes(): /files/{id}, sob demanda
                      'resolucoes' => nil,
                      'autores' => a['authors'].is_a?(Hash) ? a['authors'].keys.grep(String) : [],
                      'publicado' => a['date_published'].is_a?(Integer) ? a['date_published'] : nil,
                      'pagina' => format(PH_PAGINA, id))
      end
      [itens, fora]
    end

    # Mapas e resoluções de UM item Poly Haven (GET /files/{id}); guarda em cache.
    def self.detalhes_polyhaven(id, cache_dir = dir)
      raise ArgumentError, 'id inválido' unless id.to_s =~ /\A[a-z0-9_\-]+\z/i
      arq = File.join(cache_dir, 'ph_files', "#{id}.json")
      bruto = File.file?(arq) ? (JSON.parse(File.read(arq)) rescue nil) : nil
      unless bruto.is_a?(Hash)
        bruto = json(format(PH_FILES, id))
        raise ErroFonte, "Poly Haven: /files/#{id} sem mapas" unless bruto.is_a?(Hash) && !bruto.empty?
        gravar_atomico(arq, JSON.generate(bruto))
      end
      mapas = {}
      bruto.each do |mapa, res|
        next if NAO_MAPAS.include?(mapa) || !res.is_a?(Hash)
        mapas[mapa] = res.select { |_r, fmts| fmts.is_a?(Hash) }.transform_values do |fmts|
          fmts.select { |_f, v| v.is_a?(Hash) && url_ok(v['url']) }.transform_values { |v| v['size'].to_i }
        end
      end
      { 'mapas' => mapas.keys.sort, 'resolucoes' => mapas }
    end

    # --------------------------------------------------------------- ambientCG
    def self.descobrir_ambientcg(por_pagina = ACG_POR_PAGINA)
      itens = {}
      fora = []
      offset = 0
      total = nil
      MAX_PAGINAS.times do
        dados = json(format(ACG_LISTA, por_pagina, offset))
        n = dados.is_a?(Hash) ? dados['numberOfResults'] : nil
        n = n.to_i if n.is_a?(String) && n =~ /\A\d+\z/
        unless dados.is_a?(Hash) && dados['foundAssets'].is_a?(Array) && n.is_a?(Integer)
          raise ErroFonte, "ambientCG: resposta incompleta (offset #{offset})"
        end
        total ||= n
        pagina = dados['foundAssets']
        pagina.each do |a|
          # Um registro com formato inesperado é descartado sozinho - nunca
          # derruba a fonte inteira (a API PHP devolve [] no lugar de {} vazio).
          begin
            acg_item(a, itens, fora)
          rescue StandardError => e
            fora << "#{(a.is_a?(Hash) ? a['assetId'] : nil).inspect}: formato inesperado (#{e.class})"
          end
        end
        offset += por_pagina
        break if pagina.empty? || offset >= total
      end
      [itens.values, fora, total]
    end

    def self.acg_item(a, itens, fora)
      id = a.is_a?(Hash) ? a['assetId'] : nil
      return fora << "#{id.inspect}: registro inválido" unless id.is_a?(String) && id =~ /\A[A-Za-z0-9_\-]+\z/
      return fora << "#{id}: não é Material (#{a['dataType'].inspect})" unless a['dataType'] == 'Material'
      return if itens.key?(id)                       # repetido entre páginas
      dl = acg_downloads(a)
      prev = a['previewImage'].is_a?(Hash) ? a['previewImage'] : {}
      dx = a['dimensionX'].is_a?(Numeric) ? a['dimensionX'].to_f : 0.0
      dy = a['dimensionY'].is_a?(Numeric) ? a['dimensionY'].to_f : 0.0
      itens[id] = item('ambientcg', id,
                       'nome' => (a['displayName'].to_s.strip.empty? ? id : a['displayName'].to_s.strip),
                       'categoria' => a['displayCategory'].is_a?(String) ? a['displayCategory'] : nil,
                       'categorias' => [a['displayCategory']].grep(String),
                       'tags' => Array(a['tags']).grep(String),
                       'miniatura' => url_ok(prev['256-PNG']) || format(Texturas::ACG_THUMB, id),
                       # dimensionX/Y: a documentação não informa a unidade - guardado cru.
                       'dimensoes_brutas' => dx > 0 && dy > 0 ? [dx, dy] : nil,
                       'mapas' => Array(a['maps']).grep(String),
                       'resolucoes' => dl,
                       'metodo' => a['creationMethod'].is_a?(String) ? a['creationMethod'] : nil,
                       'publicado' => a['releaseDate'].is_a?(String) ? a['releaseDate'] : nil,
                       'pagina' => format(ACG_PAGINA, id))
    end

    def self.acg_downloads(a)
      lista = cavar(a, 'downloadFolders', 'default', 'downloadFiletypeCategories', 'zip', 'downloads')
      return {} unless lista.is_a?(Array)
      lista.each_with_object({}) do |d, h|
        next unless d.is_a?(Hash) && d['attribute'].is_a?(String) && url_ok(d['downloadLink'])
        h[d['attribute']] = d['size'].to_i
      end
    end

    # --------------------------------------------------------------- itens
    def self.item(fonte, id, campos)
      lic = LICENCAS[fonte]
      { 'chave' => "#{fonte == 'polyhaven' ? 'ph' : 'acg'}:#{id}", 'fonte' => fonte, 'id' => id,
        'licenca' => lic['licenca'], 'licenca_origem' => lic['fonte'], 'credito' => lic['credito'],
        'legado' => false }.merge(campos)
    end

    # dig tolerante: um nível que não é Hash (ex.: [] vazio) devolve nil.
    def self.cavar(obj, *chaves)
      chaves.each do |k|
        return nil unless obj.is_a?(Hash)
        obj = obj[k]
      end
      obj
    end

    def self.url_ok(u)
      u.is_a?(String) && u =~ %r{\Ahttps://[^\s]+\z} ? u : nil
    end

    # Os 157 itens fixos, no mesmo formato (sem perder os campos de hoje).
    def self.legados
      Texturas::CATALOGO.map do |grupo, nome, src, id, tam, rug|
        fonte = src == :acg ? 'ambientcg' : 'polyhaven'
        item(fonte, id, 'nome' => nome, 'grupo' => grupo, 'legado' => true,
                        'tamanho_m' => tam, 'rugosidade' => rug,
                        'miniatura' => Texturas.thumb([grupo, nome, src, id, tam, rug]),
                        'pagina' => format(src == :acg ? ACG_PAGINA : PH_PAGINA, id))
      end
    end

    # --------------------------------------------------------------- cache
    def self.dir
      base = ENV['LOCALAPPDATA'] || Dir.tmpdir
      File.join(base, 'BlenditSketchUp', 'catalogo')
    end

    def self.arquivo(cache_dir = dir)
      File.join(cache_dir, 'catalogo.json')
    end

    def self.gravar_atomico(path, texto)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, 'wb') { |f| f.write(texto) }
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    # Cache lido; {} se não existe ou está corrompido (aí só os legados valem).
    def self.ler_cache(cache_dir = dir)
      return {} unless File.file?(arquivo(cache_dir))
      c = JSON.parse(File.read(arquivo(cache_dir), encoding: 'UTF-8'))
      c.is_a?(Hash) && c['formato'] == FORMATO && c['fontes'].is_a?(Hash) ? c : {}
    rescue StandardError
      {}
    end

    # Atualiza as duas fontes. Uma fonte que falhar mantém os itens do cache
    # anterior (e registra o erro). Não baixa nenhuma textura nem miniatura.
    # -> resumo { fonte => { ok:, total:, novos:, erro:, descartados: } }
    def self.atualizar(cache_dir = dir, acg_por_pagina = ACG_POR_PAGINA)
      antigo = ler_cache(cache_dir)
      fontes = {}
      resumo = {}
      { 'polyhaven' => -> { descobrir_polyhaven.first(2) },
        'ambientcg' => -> { descobrir_ambientcg(acg_por_pagina).first(2) } }.each do |fonte, descobre|
        ant = (antigo['fontes'] || {})[fonte] || {}
        begin
          itens, fora = descobre.call
          raise ErroFonte, "#{fonte}: nenhum item válido" if itens.empty?
          ids_ant = Array(ant['itens']).map { |x| x['id'] }
          fontes[fonte] = { 'ok' => true, 'quando' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                            'erro' => nil, 'descartados' => fora.length, 'itens' => itens }
          resumo[fonte] = { ok: true, total: itens.length, novos: (itens.map { |x| x['id'] } - ids_ant).length,
                            descartados: fora.length, erro: nil }
        rescue StandardError => e
          fontes[fonte] = ant.merge('ok' => false, 'erro' => e.message[0, 300])
          fontes[fonte]['itens'] ||= []
          resumo[fonte] = { ok: false, total: fontes[fonte]['itens'].length, novos: 0, descartados: 0,
                            erro: e.message[0, 300] }
        end
      end
      gravar_atomico(arquivo(cache_dir), JSON.generate('formato' => FORMATO,
                                                       'atualizado_em' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                                                       'fontes' => fontes))
      resumo
    end

    # --------------------------------------------------------------- catálogo unificado
    # Legados + cache, sem duplicar (chave fonte:id). Um legado também
    # encontrado online fica com o nome/grupo em português e ganha os
    # metadados online. Mesmo nome nas duas fontes = 'possivel_duplicata'
    # (sinalizado, não fundido: são imagens diferentes).
    def self.unificado(cache_dir = dir)
      por_chave = {}
      legados.each { |it| por_chave[it['chave']] = it }
      (ler_cache(cache_dir)['fontes'] || {}).each_value do |f|
        Array(f['itens']).each do |it|
          next unless it.is_a?(Hash) && it['chave'].is_a?(String) && it['id'].is_a?(String)
          if (leg = por_chave[it['chave']]) && leg['legado']
            por_chave[it['chave']] = it.merge(leg.slice('nome', 'grupo', 'legado', 'tamanho_m', 'rugosidade'))
                                       .merge('nome_original' => it['nome'])
          else
            por_chave[it['chave']] ||= it
          end
        end
      end
      itens = por_chave.values
      por_nome = itens.group_by { |it| plano(it['nome_original'] || it['nome']) }
      por_nome.each_value do |grupo|
        fontes = grupo.map { |x| x['fonte'] }.uniq
        next if grupo.length < 2 || fontes.length < 2
        grupo.each { |x| x['possivel_duplicata'] = (grupo - [x]).map { |y| y['chave'] } }
      end
      itens
    end

    def self.plano(t)
      t.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').downcase.gsub(/[^a-z0-9]+/, ' ').strip
    end

    # Consulta: texto (nome/tags/categoria), fonte, só legados, limite.
    def self.buscar(texto: '', fonte: nil, legado: nil, limite: 50, cache_dir: dir)
      termos = plano(texto).split
      unificado(cache_dir).select do |it|
        next false if fonte && it['fonte'] != fonte
        next false if !legado.nil? && it['legado'] != legado
        alvo = plano([it['nome'], it['nome_original'], it['categoria'], it['grupo'], *Array(it['tags'])].join(' '))
        termos.all? { |t| alvo.include?(t) }
      end.first(limite)
    end

    # Resumo para mostrar: totais por fonte, legados, última atualização.
    def self.estado(cache_dir = dir)
      c = ler_cache(cache_dir)
      itens = unificado(cache_dir)
      { total: itens.length, legados: itens.count { |x| x['legado'] },
        por_fonte: itens.group_by { |x| x['fonte'] }.transform_values(&:length),
        atualizado_em: c['atualizado_em'],
        fontes: (c['fontes'] || {}).transform_values { |f| f.slice('ok', 'quando', 'erro') } }
    end
  end
end
