# encoding: UTF-8
# Blendit para SketchUp - atualização automática.
#
# Uma vez por dia (alguns segundos depois de abrir o SketchUp) o plugin lê o
# arquivo de versão publicado no GitHub. Se houver versão nova, pergunta se pode
# atualizar, baixa o .rbz e instala sozinho; as configurações são mantidas.
require 'json'
require 'tmpdir'

module BlenditSU
  VERSION = '0.3.0'.freeze

  module Atualizacao
    REPO_RAW = 'https://raw.githubusercontent.com/joaopedromilok-lab/blendit/main'.freeze
    VERSAO_URL = "#{REPO_RAW}/sketchup/versao.json".freeze
    INTERVALO = 24 * 3600

    def self.cmp(a, b)
      pa = a.to_s.split('.').map(&:to_i)
      pb = b.to_s.split('.').map(&:to_i)
      n = [pa.length, pb.length].max
      (pa + [0] * (n - pa.length)) <=> (pb + [0] * (n - pb.length))
    end

    def self.remota
      path = File.join(Dir.tmpdir, "blendit_versao_#{Process.pid}.json")
      Texturas.download("#{VERSAO_URL}?t=#{Time.now.to_i}", path)
      JSON.parse(File.read(path, encoding: 'UTF-8'))
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    # silencioso: sem avisos quando não há novidade ou quando falta internet.
    def self.verificar(silencioso: false)
      if silencioso
        ultima = BlenditSU.pref('ultima_verificacao', '0').to_i
        return if Time.now.to_i - ultima < INTERVALO
      end
      BlenditSU.set_pref('ultima_verificacao', Time.now.to_i.to_s)
      info = remota
      nova = info['versao'].to_s
      if cmp(nova, VERSION) <= 0
        UI.messagebox("O Blendit está atualizado (versão #{VERSION}).") unless silencioso
        return
      end
      return if silencioso && BlenditSU.pref('ignorar_versao') == nova
      texto = "Tem uma versão nova do Blendit: #{nova} (você usa a #{VERSION}).\n\n"
      texto += "Novidades:\n#{info['novidades']}\n\n" unless info['novidades'].to_s.empty?
      texto += 'Atualizar agora? Leva alguns segundos e suas configurações continuam.'
      resp = UI.messagebox(texto, MB_YESNO)
      if resp == IDYES
        instalar(info['rbz'].to_s, nova)
      else
        BlenditSU.set_pref('ignorar_versao', nova)
      end
    rescue StandardError => e
      UI.messagebox("Não consegui verificar atualizações agora.\n\n#{e.message}") unless silencioso
    end

    def self.instalar(url, nova)
      raise 'Endereço do pacote não informado.' if url.empty?
      Sketchup.status_text = "Blendit: baixando a versão #{nova}..."
      rbz = File.join(Dir.tmpdir, "blendit_sketchup_#{nova}.rbz")
      Texturas.download("#{url}?t=#{Time.now.to_i}", rbz)
      Sketchup.install_from_archive(rbz, false)
      UI.messagebox("Blendit atualizado para a versão #{nova}.\n\n" \
                    'Feche e abra o SketchUp para usar a versão nova.')
    rescue Interrupt
      nil
    rescue StandardError => e
      UI.messagebox("A atualização não deu certo: #{e.message}\n\n" \
                    'Dá para atualizar à mão: baixe o blendit_sketchup.rbz em ' \
                    "github.com/joaopedromilok-lab/blendit (pasta sketchup/release) e instale pelo Gerenciador de extensões.")
    end
  end
end
