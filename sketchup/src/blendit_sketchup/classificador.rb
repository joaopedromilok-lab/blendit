# encoding: UTF-8
# Blendit para SketchUp - classificador de materiais (isolado, Ruby puro).
#
# Diz a que CATEGORIA um material do projeto provavelmente pertence (piso,
# parede, bancada, madeira, tecido, metal...), com um nível de confiança e o
# motivo. Não identifica produto comercial: "piso" quer dizer "superfície de
# piso", não "porcelanato X do fabricante Y".
#
# Entrada (hash de características - quem chama mede no modelo):
#   nome:          nome do material                      (String)
#   rgb:           cor em sRGB 0..255                    ([r, g, b])
#   alpha:         opacidade 0..1                        (Float, 1 = opaco)
#   tem_textura:   o material já tem imagem              (true/false)
#   area_m2:       área total em que é usado             (Float)
#   frac_piso:     fração da área em faces de piso       (0..1: horizontais para cima, no nível mais baixo)
#   frac_parede:   fração da área em faces verticais     (0..1)
#   frac_estofado: fração dentro de sofá/poltrona/cama   (0..1)
#
# Saída:
#   { categoria: 'piso' | ... | nil, confianca: :alta | :media | :baixa | :nenhuma,
#     motivo: 'texto', alternativas: ['madeira', ...] }
#
# Confiança:
#   alta   - o NOME diz o que é ("Porcelanato bege", "Freijó", "Linho");
#   media  - o USO diz ("Cor_M05" cobrindo o piso; dentro de um sofá);
#   baixa  - só um indício fraco (cor de madeira) - pedir confirmação;
#   nenhuma- não dá para dizer (ou não se deve mexer: já tem textura, vidro...).
module BlenditSU
  module Classificador
    NAO_MEXER = /vidro|glass|espelh|mirror|[aá]gua|water|grama|grass|\bc[eé]u\b|sky|lumin|l[aâ]mpada|\bled\b|\bluz\b/i.freeze
    METAL = /metal|inox|\ba[cç]o\b|alum[ií]n|cromad|chrome|steel|lat[aã]o|brass|cobre|copper|ferro\b|iron\b|bronze/i.freeze
    REGRAS = [
      [/couro|leather|courino|corino/i, 'couro'],
      [/tecido|(?<![a-z])linho|fabric|veludo|velvet|sof[aá]|almofad|estof|boucl|cortina|curtain|suede|camur|chenille|tapete|carpet|\brug\b/i, 'tecido'],
      [/granito|m[aá]rmore|marble|bancada|silestone|quartzo|travertin|pedra|stone|countertop/i, 'bancada'],
      [/cimento queimado|concreto|concrete|cimentici|microcimento/i, 'concreto'],
      [/tijol|brick/i, 'tijolo'],
      [/reboco|grafiato|textura|stucco|plaster/i, 'reboco'],
      [/assoalho|parquet|\btaco\b|piso.*madeira|vin[ií]lico|laminado|wood ?floor|flooring/i, 'piso_madeira'],
      [/porcelanato|cer[aâ]mic|\bpiso\b|floor|\btile|azulejo|revestimento/i, 'piso'],
      [/madeira|wood|\bmdf\b|freij|carvalho|nogueira|\boak\b|walnut|l[aâ]mina|marcenaria|amadeirad|cumaru|jatob|\bip[eê]\b|\bteca\b|pinus/i, 'madeira'],
      [/pintura|tinta|parede|wall|paint/i, 'parede']
    ].freeze
    AREA_PISO_MIN = 1.0       # m² - um piso de verdade, não um tapetinho
    AREA_PAREDE_MIN = 4.0     # m²

    def self.classificar(f, regras = {})
      nome = f[:nome].to_s
      rgb = f[:rgb] || [200, 200, 200]
      desativ = Array(regras['desativar']).map(&:to_s)
      return r(nil, :nenhuma, 'já tem textura (preservado)') if f[:tem_textura]
      return r(nil, :nenhuma, 'transparente (vidro)') if f[:alpha] && f[:alpha].to_f < 0.99
      return r(nil, :nenhuma, 'vidro, espelho, água, vegetação ou luz - não mexer') if nome =~ NAO_MEXER

      res = por_nome(nome, rgb, regras) || por_uso(f, rgb)
      return r(nil, :nenhuma, 'sem informação suficiente') unless res
      if desativ.include?(res[:categoria])
        return r(nil, :nenhuma, "categoria #{res[:categoria]} desativada nas regras")
      end
      res
    end

    # Nome: palavras das regras do usuário primeiro, depois as padrão.
    def self.por_nome(nome, rgb, regras)
      (regras['palavras'] || {}).each do |cat, palavras|
        Array(palavras).each do |p|
          next if p.to_s.strip.empty?
          return r(cat.to_s, :alta, "nome contém \"#{p}\" (regra do usuário)") if plano(nome).include?(plano(p))
        end
      end
      return r('metal', :alta, 'nome indica metal') if nome =~ METAL
      REGRAS.each do |re, cat|
        next unless nome =~ re
        if cat == 'piso' && amadeirado?(rgb)
          return r('piso_madeira', :alta, 'nome indica piso e a cor é de madeira', ['piso'])
        end
        alt = cat == 'bancada' ? ['piso'] : []
        return r(cat, :alta, "nome indica #{cat}", alt)
      end
      nil
    end

    def self.por_uso(f, rgb)
      area = f[:area_m2].to_f
      madeira = amadeirado?(rgb)
      if f[:frac_piso].to_f > 0.6 && area >= AREA_PISO_MIN
        return madeira ? r('piso_madeira', :media, 'cobre o piso e tem cor de madeira', ['piso']) :
                         r('piso', :media, 'cobre o piso do ambiente', ['piso_madeira'])
      end
      if f[:frac_estofado].to_f > 0.6 && !madeira
        return r('tecido', :media, 'usado em sofá/poltrona/almofada/cama', ['couro'])
      end
      if f[:frac_parede].to_f > 0.8 && area >= AREA_PAREDE_MIN && !madeira
        return r('parede', :media, 'cobre paredes (pintura - sem textura)', ['reboco'])
      end
      return r('madeira', :baixa, 'só a cor sugere madeira - confirmar', ['parede']) if madeira
      nil
    end

    # Tom de madeira: marrom/caramelo/bege-dourado, não cinza nem branco puro.
    def self.amadeirado?(rgb)
      r_, g, b = rgb.map { |v| v.to_f / 255.0 }
      mx = [r_, g, b].max
      mn = [r_, g, b].min
      return false if mx < 0.12 || mx - mn < 0.12
      s = (mx - mn) / mx
      h = if mx == r_ then 60.0 * (((g - b) / (mx - mn)) % 6)
          elsif mx == g then 60.0 * (((b - r_) / (mx - mn)) + 2)
          else 60.0 * (((r_ - g) / (mx - mn)) + 4)
          end
      h.between?(12.0, 48.0) && s.between?(0.2, 0.85)
    end

    def self.plano(t)
      t.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').downcase
    end

    def self.r(cat, conf, motivo, alt = [])
      { categoria: cat, confianca: conf, motivo: motivo, alternativas: alt }
    end
  end
end
