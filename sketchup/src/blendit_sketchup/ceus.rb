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
                   ceu: 1.0, sol: 1.2, cor: [1.0, 0.62, 0.38] }
    }.freeze

    URL_DIRETA = 'https://dl.polyhaven.org/file/ph-assets/HDRIs/hdr/2k/%s_2k.hdr'.freeze

    def self.dir
      base = ENV['LOCALAPPDATA'] || Dir.tmpdir
      File.join(base, 'BlenditSketchUp', 'ceus')
    end

    def self.escolhido
      k = BlenditSU.pref('ceu', 'simulado')
      LISTA.key?(k) ? k : 'simulado'
    end

    def self.arquivo(id)
      File.join(dir, "#{id}_2k.hdr")
    end

    # Caminho do .hdr no computador, baixando na primeira vez. Erro se não der.
    def self.garantir(chave)
      c = LISTA[chave]
      return nil unless c && c[:id]
      path = arquivo(c[:id])
      return path if File.size?(path).to_i > 100_000
      Sketchup.status_text = "Blendit: baixando o céu \"#{c[:nome]}\" (só na primeira vez)..."
      url = begin
        files = Texturas.json("#{Texturas::PH_API}/files/#{c[:id]}",
                              File.join(dir, "#{c[:id]}_files.json"))
        files.dig('hdri', '2k', 'hdr', 'url')
      rescue StandardError
        nil
      end
      Texturas.download(url || format(URL_DIRETA, c[:id]), path)
      raise 'arquivo do céu veio vazio' unless File.size?(path).to_i > 100_000
      path
    end

    # Opções do exportador para o céu escolhido; nil = céu simulado.
    # Avisa (uma vez por sessão) e cai no céu simulado se o download falhar.
    def self.opcoes(chave = escolhido)
      c = LISTA[chave]
      return nil unless c && c[:id]
      { path: garantir(chave), ceu: c[:ceu], sol: c[:sol], cor: c[:cor] }
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
