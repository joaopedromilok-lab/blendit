# encoding: UTF-8
# Blendit para SketchUp - céus fotografados (HDRI).
#
# Um HDRI é uma foto 360° do céu com a luz real dele. No render ele vira o fundo
# das janelas e a luz ambiente (reflexos, sombras suaves). O sol continua vindo
# de Janela > Sombras do SketchUp - o sol do HDRI é cortado, para não haver duas
# sombras. Fonte: Poly Haven (CC0, livre para uso comercial). Cada céu é baixado
# uma vez (~6 MB) e fica guardado no computador.
require 'json'
require 'fileutils'

module BlenditSU
  module Ceus
    # chave => nome no menu, id Poly Haven, luz do céu, força do sol, cor do sol
    LISTA = {
      'simulado' => { nome: 'Céu simulado (padrão, não baixa nada)' },
      'limpo' => { nome: 'Céu limpo, meio-dia', id: 'qwantani_noon_puresky',
                   ceu: 1.5, sol: 1.6 },
      'parcial' => { nome: 'Parcialmente nublado', id: 'kloofendal_48d_partly_cloudy_puresky',
                     ceu: 2.0, sol: 1.2 },
      'nublado' => { nome: 'Nublado (luz suave, sem sombra marcada)', id: 'kloofendal_overcast_puresky',
                     ceu: 4.5, sol: 0.0 },
      'tarde' => { nome: 'Fim de tarde (luz dourada)', id: 'belfast_sunset_puresky',
                   ceu: 1.0, sol: 1.2, cor: [1.0, 0.62, 0.38] },
      # Com PAISAGEM (vista pela janela): a foto tem chão, prédios, árvores. O
      # chão do render vira só "pega-sombra" e some da câmera. 4K (mais nítido
      # pela janela, ~25 MB, baixado uma vez). Fotos de Poly Haven (CC0).
      'cidade' => { nome: 'Paisagem: cidade com prédios (vista de apartamento)', id: 'canary_wharf',
                    ceu: 2.2, sol: 0.9, paisagem: true },
      'bairro' => { nome: 'Paisagem: bairro com casas e árvores', id: 'balcony',
                    ceu: 2.0, sol: 1.1, paisagem: true },
      'jardim' => { nome: 'Paisagem: jardim / área verde', id: 'symmetrical_garden',
                    ceu: 1.6, sol: 1.3, paisagem: true }
    }.freeze

    URL_DIRETA = 'https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/%s/%s_%s.hdr'.freeze

    def self.resolucao(c)
      c && c[:paisagem] ? '4k' : '2k'
    end

    def self.dir
      base = ENV['LOCALAPPDATA'] || Dir.tmpdir
      File.join(base, 'BlenditSketchUp', 'ceus')
    end

    def self.escolhido
      k = BlenditSU.pref('ceu', 'simulado')
      LISTA.key?(k) ? k : 'simulado'
    end

    def self.arquivo(id, res = '2k')
      File.join(dir, "#{id}_#{res}.hdr")
    end

    # Caminho do .hdr no computador, baixando na primeira vez. Erro se não der.
    def self.garantir(chave)
      c = LISTA[chave]
      return nil unless c && c[:id]
      res = resolucao(c)
      path = arquivo(c[:id], res)
      return path if File.size?(path).to_i > 100_000
      Sketchup.status_text = "Blendit: baixando o céu \"#{c[:nome]}\" (só na primeira vez)..."
      url = begin
        files = Texturas.json("#{Texturas::PH_API}/files/#{c[:id]}",
                              File.join(dir, "#{c[:id]}_files.json"))
        files.dig('hdri', res, 'hdr', 'url')
      rescue StandardError
        nil
      end
      Texturas.download(url || format(URL_DIRETA, res, c[:id], res), path)
      raise 'arquivo do céu veio vazio' unless File.size?(path).to_i > 100_000
      path
    end

    # Opções do exportador para o céu escolhido; nil = céu simulado.
    # Avisa (uma vez por sessão) e cai no céu simulado se o download falhar.
    def self.opcoes(chave = escolhido)
      c = LISTA[chave]
      return nil unless c && c[:id]
      { path: garantir(chave), ceu: c[:ceu], sol: c[:sol], cor: c[:cor], paisagem: c[:paisagem] ? true : false }
    rescue StandardError => e
      unless @avisado
        @avisado = true
        UI.messagebox("Não consegui baixar o céu \"#{c[:nome]}\" (#{e.message}).\n\n" \
                      'Este render vai usar o céu simulado. Confira a internet e tente de novo.')
      end
      nil
    end
  end
end
