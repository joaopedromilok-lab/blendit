# encoding: UTF-8
# Blendit para SketchUp - menus, barra de ferramentas e integração com o Blender.
require 'sketchup.rb'
require 'fileutils'
require 'tmpdir'
require 'json'
require_relative 'exporter'
require_relative 'texturas'
require_relative 'atualizacao'
require_relative 'ceus'
require_relative 'auto_texturas'
require_relative 'catalogo_online'

module BlenditSU
  PLUGIN_DIR = File.dirname(__FILE__).freeze
  CORE_DIR = File.join(PLUGIN_DIR, 'core').freeze   # código Python do Blendit (lado Blender)
  PREFS = 'BlenditSketchUp'.freeze

  # [chave interna, nome em português, descrição]
  MODES = [
    ['realistic',   'Realista',              'Fotorrealista, com materiais e sol'],
    ['white',       'Maquete branca',        'Volume branco / argila - estudo de massa'],
    ['shadow',      'Estudo de sombras',     'Sombras do sol com precisão'],
    ['specular',    'Showroom escuro',       'Fundo escuro com reflexos'],
    ['linework',    'Traço',                 'Só as linhas do desenho'],
    ['pen',         'Caneta',                'Traço de caneta nanquim'],
    ['sketch',      'Croqui',                'Esboço à mão'],
    ['cel',         'Cartoon',               'Estilo anime / cel shading'],
    ['hatch',       'Hachura',               'Sombreamento por hachuras'],
    ['crosshatch',  'Hachura cruzada',       'Hachuras cruzadas, estilo gravura'],
    ['yellowtrace', 'Papel manteiga',        'Croqui em papel amarelo'],
    ['kraft',       'Papel kraft',           'Desenho sobre papel pardo'],
    ['blueprint',   'Blueprint',             'Cópia heliográfica azul'],
    ['diagram',     'Diagrama',              'Diagrama gráfico limpo'],
    ['watercolor',  'Aquarela',              'Pintura em aquarela'],
    ['risograph',   'Risografia',            'Impressão risográfica']
  ].freeze

  QUALITY = {
    'Rascunho' => { engine: 'EEVEE',  samples: 16,  width: 1280, denoise: false },
    'Boa'      => { engine: 'EEVEE',  samples: 64,  width: 1920, denoise: true },
    'Alta'     => { engine: 'CYCLES', samples: 128, width: 1920, denoise: true },
    'Final'    => { engine: 'CYCLES', samples: 300, width: 2560, denoise: true }
  }.freeze

  # ------------------------------------------------------------- preferências
  def self.pref(key, default = nil)
    v = Sketchup.read_default(PREFS, key, nil)
    v.nil? || v == '' ? default : v
  end

  def self.set_pref(key, value)
    Sketchup.write_default(PREFS, key, value)
  end

  def self.mode
    pref('mode', 'realistic')
  end

  def self.quality
    q = pref('quality', 'Boa')
    QUALITY.key?(q) ? q : 'Boa'
  end

  def self.windows?
    Sketchup.platform == :platform_win
  end

  def self.output_dir
    d = pref('output_dir')
    unless d
      base = ENV['USERPROFILE'] || ENV['HOME'] || Dir.home
      docs = File.join(base, 'Documents')
      d = File.join(File.directory?(docs) ? docs : base, 'Blendit Renders')
    end
    FileUtils.mkdir_p(d)
    d
  end

  def self.cache_dir
    base = ENV['LOCALAPPDATA'] || Dir.tmpdir
    File.join(base, 'BlenditSketchUp', 'cenas')
  end

  # ------------------------------------------------------------- Blender
  def self.find_blender
    saved = pref('blender_exe')
    return saved if saved && File.file?(saved)
    env = ENV['BLENDIT_BLENDER_EXE']
    return env if env && File.file?(env)
    candidates = if windows?
                   roots = [ENV['ProgramFiles'], ENV['ProgramW6432'], 'C:/Program Files'].compact.uniq
                   list = roots.flat_map do |r|
                     Dir.glob(File.join(r.tr('\\', '/'), 'Blender Foundation', '*', 'blender.exe'))
                   end
                   # Steam e Microsoft Store também são comuns
                   list += Dir.glob('C:/Program Files (x86)/Steam/steamapps/common/Blender/blender.exe')
                   list
                 else
                   ['/Applications/Blender.app/Contents/MacOS/Blender']
                 end
    candidates.select { |c| File.file?(c) }.max_by { |c| version_of(c) }
  end

  def self.version_of(path)
    m = path.match(/Blender (\d+)\.(\d+)/i)
    m ? [m[1].to_i, m[2].to_i] : [0, 0]
  end

  def self.ensure_blender
    exe = find_blender
    return exe if exe
    ok = UI.messagebox("Não encontrei o Blender neste computador.\n\n" \
                       "O Blendit usa o Blender (gratuito, versão 4.2 ou mais nova) " \
                       "para renderizar. Quer indicar onde está o blender.exe agora?\n\n" \
                       "Se ainda não tem, baixe em blender.org.", MB_YESNO)
    return nil unless ok == IDYES
    pick_blender
  end

  def self.pick_blender
    path = UI.openpanel('Onde está o blender.exe?', nil,
                        windows? ? 'Blender|blender.exe||' : 'Blender|*||')
    return nil unless path && File.file?(path)
    set_pref('blender_exe', path)
    path
  end

  def self.windowed(exe)
    return exe unless windows?
    launcher = File.join(File.dirname(exe), 'blender-launcher.exe')
    File.file?(launcher) ? launcher : exe
  end

  def self.q(s)
    "\"#{s}\""
  end

  # Roda um comando sem abrir janela preta (Windows) e sem travar o SketchUp.
  def self.shell_run(line, window_style)
    require 'win32ole'
    begin
      WIN32OLE.codepage = WIN32OLE::CP_UTF8
    rescue StandardError
      nil
    end
    WIN32OLE.new('WScript.Shell').Run(line, window_style, false)
  end

  def self.spawn_hidden(args, log_path = nil)
    if windows?
      line = args.map { |a| q(a) }.join(' ')
      line = "cmd /c \"#{line} > #{q(log_path)} 2>&1\"" if log_path
      shell_run(line, 0)
    else
      opts = log_path ? { [:out, :err] => [log_path, 'w'] } : {}
      Process.detach(Process.spawn(*args, opts))
    end
  end

  def self.spawn_window(args)
    if windows?
      shell_run(args.map { |a| q(a) }.join(' '), 1)
    else
      Process.detach(Process.spawn(*args))
    end
  end

  # ------------------------------------------------------------- exportação
  def self.safe_name(s)
    n = s.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, '').gsub(/[^A-Za-z0-9_-]+/, '_')
    n = n.gsub(/^_+|_+$/, '')
    n.empty? ? 'modelo' : n[0, 40]
  end

  def self.stamp
    Time.now.strftime('%Y%m%d_%H%M%S')
  end

  def self.night?
    pref('noite', '0') == '1'
  end

  def self.flip_section?
    pref('flip_section', '0') == '1'
  end

  # Exporta a vista atual. Devolve [spec_path, opts] ou nil se falhar.
  # extra: :mode, :width, :noite para forçar algo só nesta exportação.
  def self.export_current(model, folder_name, extra = {})
    qcfg = QUALITY[quality]
    width = extra[:width] ? [qcfg[:width], extra[:width]].min : qcfg[:width]
    opts = { mode: extra[:mode] || mode, engine: qcfg[:engine], samples: qcfg[:samples],
             resolution: [width, 0], denoise: qcfg[:denoise],
             noite: extra.key?(:noite) ? extra[:noite] : night?,
             flip_section: flip_section?, interior: pref('interior', 'auto'),
             dois_pontos: pref('dois_pontos', '1') == '1',
             tom: pref('tom', 'natural'), brilho: pref('brilho', '0').to_f,
             materiais: pref('materiais', 'preservar') }
    m = opts[:mode].to_s
    if !opts[:noite] && %w[realistic specular].include?(m) && Ceus.escolhido != 'simulado'
      opts[:ceu] = Ceus.opcoes
    end
    dir = File.join(cache_dir, folder_name)
    clean_cache
    Sketchup.status_text = 'Blendit: preparando a cena para o Blender...'
    t0 = Time.now
    exp = Exporter.new(model, opts)
    spec = exp.export(dir)
    Sketchup.status_text = format('Blendit: %d faces exportadas em %.1fs',
                                  exp.faces, Time.now - t0)
    [spec, opts]
  rescue StandardError => e
    UI.messagebox("Blendit: não foi possível exportar a cena.\n\n#{e.message}")
    puts e.full_message if e.respond_to?(:full_message)
    nil
  end

  # Apaga exportações com mais de 7 dias (a pasta de cache não cresce para sempre).
  def self.clean_cache
    limit = Time.now - 7 * 24 * 3600
    Dir.glob(File.join(cache_dir, '*')).each do |d|
      FileUtils.rm_rf(d) if File.mtime(d) < limit
    end
  rescue StandardError
    nil
  end

  def self.render_args(blender, spec, png, opts)
    [blender, '--background', '--python', File.join(CORE_DIR, 'blender', 'headless', 'render.py'),
     '--', '--bundle', spec, '--out', png,
     '--mode', opts[:mode], '--engine', opts[:engine], '--samples', opts[:samples].to_s,
     '--resolution', opts[:resolution][0].to_s, opts[:resolution][1].to_s,
     '--denoise', opts[:denoise] ? 'on' : 'off']
  end

  def self.check_model
    model = Sketchup.active_model
    unless model
      UI.messagebox('Abra um modelo primeiro.')
      return nil
    end
    unless File.file?(File.join(CORE_DIR, 'blender', 'headless', 'render.py'))
      UI.messagebox("Arquivos do Blendit incompletos (pasta core). Reinstale a extensão.")
      return nil
    end
    model
  end

  # ------------------------------------------------------------- comandos
  def self.render_view
    model = check_model or return
    blender = ensure_blender or return
    name = "#{safe_name(model.title)}_#{stamp}"
    spec, opts = export_current(model, name)
    return unless spec
    png = File.join(output_dir, "#{name}_#{mode}.png")
    log = png.sub(/\.png\z/, '.log')
    spawn_hidden(render_args(blender, spec, png, opts) + ['--open'], log)
    label = MODES.find { |m| m[0] == mode }&.at(1) || mode
    UI.messagebox("Renderizando no Blender (#{label}, qualidade #{quality}).\n\n" \
                  "Pode continuar usando o SketchUp - a imagem abre sozinha quando ficar pronta.\n\n" \
                  "Arquivo: #{png}")
  end

  def self.open_in_blender
    model = check_model or return
    blender = ensure_blender or return
    name = "#{safe_name(model.title)}_#{stamp}_aberto"
    spec, opts = export_current(model, name)
    return unless spec
    args = [windowed(blender), '--python', File.join(CORE_DIR, 'blender', 'interactive', 'live.py'),
            '--', '--bundle', spec, '--capture-dir', output_dir,
            '--engine', 'EEVEE', '--mode', opts[:mode]]
    spawn_window(args)
    Sketchup.status_text = 'Blendit: abrindo no Blender. Navegue para compor; Enter captura; ' \
                           'N mostra o painel; F10 alterna a interface completa.'
  end

  # ------------------------------------------------------------- prancha
  BOARD_DICT = 'blendit_prancha'.freeze

  # Pergunta os dados do carimbo (lembra por modelo). -> manifesto parcial ou nil.
  def self.board_info(model, title)
    get = ->(k, d) { model.get_attribute(BOARD_DICT, k, d).to_s }
    prompts = ['Projeto', 'Cliente', 'Endereço', 'Responsável', 'Título da prancha', 'Papel']
    defaults = [get['projeto', model.title], get['cliente', ''], get['endereco', ''],
                get['responsavel', pref('responsavel', '')], title, get['formato', 'A3']]
    lists = ['', '', '', '', '', 'A4|A3|A2|A1']
    res = UI.inputbox(prompts, defaults, lists, 'Blendit - Prancha (carimbo)')
    return nil unless res
    %w[projeto cliente endereco responsavel].each_with_index do |k, i|
      model.set_attribute(BOARD_DICT, k, res[i].to_s)
    end
    model.set_attribute(BOARD_DICT, 'formato', res[5].to_s)
    set_pref('responsavel', res[3].to_s)
    fields = { 'Projeto' => res[0], 'Cliente' => res[1], 'Endereço' => res[2],
               'Responsável' => res[3], 'Data' => Time.now.strftime('%d/%m/%Y'), 'Folha' => '01/01' }
    { 'format' => res[5].to_s, 'title' => res[4].to_s,
      'fields' => fields.reject { |_k, v| v.to_s.strip.empty? },
      'note' => 'Imagens ilustrativas. Renders gerados com Blendit.', 'open' => true }
  end

  # Grava o manifesto e devolve o comando do Blender que monta a prancha.
  def self.board_job(blender, manifest, items, pdf_path)
    data = manifest.merge('items' => items, 'out' => pdf_path)
    path = File.join(cache_dir, "prancha_#{stamp}_#{rand(1000)}.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'w:UTF-8') { |f| f.write(JSON.pretty_generate(data)) }
    [blender, '--background', '--python', File.join(CORE_DIR, 'blender', 'headless', 'prancha.py'),
     '--', '--manifest', path]
  end

  # Monta uma prancha com as imagens (PNG/JPG) de uma pasta.
  def self.board_from_folder
    model = check_model or return
    blender = ensure_blender or return
    dir = UI.respond_to?(:select_directory) ? UI.select_directory(title: 'Pasta com as imagens', directory: output_dir) : nil
    return unless dir
    imgs = Dir.glob(File.join(dir, '*.{png,PNG,jpg,JPG,jpeg,JPEG}'))
              .reject { |f| File.basename(f) =~ /prancha/i }.sort
    if imgs.empty?
      UI.messagebox('Não achei imagens PNG ou JPG nessa pasta.')
      return
    end
    if imgs.length > 12
      UI.messagebox("A pasta tem #{imgs.length} imagens; a prancha usa as 12 primeiras (em ordem de nome).")
      imgs = imgs.first(12)
    end
    man = board_info(model, 'Perspectivas') or return
    items = imgs.map { |f| { 'image' => f, 'label' => File.basename(f, '.*').tr('_', ' ') } }
    pdf = File.join(output_dir, "#{safe_name(model.title)}_prancha_#{stamp}.pdf")
    spawn_hidden(board_job(blender, man, items, pdf), pdf.sub(/\.pdf\z/, '.log'))
    UI.messagebox("Montando a prancha (#{items.length} imagens). O PDF abre sozinho quando ficar pronto.\n\n#{pdf}")
  end

  # Renderiza todas as cenas (abas) do modelo, uma depois da outra, em segundo plano.
  def self.render_all_scenes
    model = check_model or return
    pages = model.pages.to_a
    if pages.empty?
      UI.messagebox('Este modelo não tem cenas. Crie cenas em Janela > Cenas, ou use "Renderizar vista".')
      return
    end
    blender = ensure_blender or return
    ok = UI.messagebox("Renderizar #{pages.length} cena(s) no estilo atual, uma de cada vez?\n\n" \
                       'Enquanto prepara, o SketchUp vai passar por cada cena.', MB_OKCANCEL)
    return unless ok == IDOK
    man = nil
    if UI.messagebox('Montar também uma prancha em PDF com as cenas, com carimbo?', MB_YESNO) == IDYES
      man = board_info(model, 'Perspectivas')
    end

    popts = model.options['PageOptions']
    old_transition = popts['ShowTransition']
    original = model.pages.selected_page
    base = "#{safe_name(model.title)}_#{stamp}"
    jobs = []
    items = []
    begin
      popts['ShowTransition'] = false
      pages.each_with_index do |page, i|
        model.pages.selected_page = page
        model.active_view.refresh if model.active_view.respond_to?(:refresh)
        spec, opts = export_current(model, "#{base}_cena#{i + 1}")
        next unless spec
        png = File.join(output_dir, "#{base}_#{format('%02d', i + 1)}_#{safe_name(page.name)}.png")
        jobs << render_args(blender, spec, png, opts)
        items << { 'image' => png, 'label' => page.name.to_s }
      end
    ensure
      model.pages.selected_page = original if original
      popts['ShowTransition'] = old_transition
    end
    return if jobs.empty?
    if man
      jobs << board_job(blender, man, items.first(12), File.join(output_dir, "#{base}_prancha.pdf"))
    end
    run_sequence(jobs, File.join(output_dir, "#{base}_cenas.log"))
    UI.messagebox("#{items.length} cena(s) na fila do Blender#{man ? ' + a prancha' : ''}.\n\n" \
                  "As imagens vão aparecendo em:\n#{output_dir}\n\n" \
                  'A pasta abre sozinha quando tudo terminar.')
  end

  # ------------------------------------------------------------- insolação
  SUN_DATES = [[6, 21, '21/06', 'Inverno (21/06)'], [3, 21, '21/03', 'Equinócio (21/03)'],
               [12, 21, '21/12', 'Verão (21/12)']].freeze
  SUN_HOURS = [9, 12, 15].freeze

  # Pergunta ao próprio SketchUp a direção do sol em cada data/hora (mesma
  # localização, fuso e norte do modelo) e desfaz a mudança de horário depois.
  def self.sun_vectors(model)
    si = model.shadow_info
    original = si['ShadowTime']
    year = Time.now.year
    out = {}
    model.start_operation('Blendit - insolação', true)
    begin
      SUN_DATES.each do |mo, d, _l, _r|
        SUN_HOURS.each do |h|
          si['ShadowTime'] = Time.gm(year, mo, d, h, 0)
          v = si['SunDirection']
          out[[mo, h]] = [v.x.to_f, v.y.to_f, v.z.to_f]
        end
      end
    ensure
      si['ShadowTime'] = original if original
      model.abort_operation
    end
    out
  end

  def self.sun_study
    model = check_model or return
    blender = ensure_blender or return
    si = model.shadow_info
    place = [si['City'], si['Country']].map(&:to_s).reject(&:empty?).join(', ')
    place = 'sem nome' if place.empty?
    lat = si['Latitude'].to_f.round(4)
    lon = si['Longitude'].to_f.round(4)
    ok = UI.messagebox("Estudo de insolação - 9 imagens (estilo Estudo de sombras):\n" \
                       "21/06, 21/03 e 21/12, às 9h, 12h e 15h, na vista atual.\n\n" \
                       "Local do modelo: #{place} (lat #{lat}, long #{lon}).\n" \
                       "Se não for o terreno certo, ajuste em Janela > Informações do modelo > " \
                       "Geolocalização antes.\n\nContinuar?", MB_OKCANCEL)
    return unless ok == IDOK
    man = board_info(model, 'Estudo de insolação')
    base = "#{safe_name(model.title)}_#{stamp}"
    spec, opts = export_current(model, "#{base}_insolacao", mode: 'shadow', width: 1600, noite: false)
    return unless spec
    data = JSON.parse(File.read(spec, encoding: 'UTF-8'))
    vecs = sun_vectors(model)
    jobs = []
    items = []
    SUN_DATES.each do |mo, _d, short, _row|
      SUN_HOURS.each do |h|
        v = vecs[[mo, h]]
        one = JSON.parse(JSON.generate(data))
        one['sun'] = one['sun'].merge('mode' => 'vector', 'direction' => v.map { |x| -x },
                                      'strength' => 1.0, 'azimuth_degrees' => nil,
                                      'altitude_degrees' => nil, 'latitude' => nil, 'longitude' => nil)
        one['render']['mode'] = 'shadow'
        path = File.join(File.dirname(spec), format('scene_spec_%02d_%02dh.json', mo, h))
        File.open(path, 'w:UTF-8') { |f| f.write(JSON.pretty_generate(one)) }
        png = File.join(output_dir, format('%s_insolacao_%02d-21_%02dh.png', base, mo, h))
        jobs << render_args(blender, path, png, opts.merge(mode: 'shadow'))
        items << { 'image' => png, 'label' => "#{short} - #{h}h" + (v[2] <= 0 ? ' (sol abaixo do horizonte)' : '') }
      end
    end
    if man
      man = man.merge('cols' => 3, 'row_labels' => SUN_DATES.map { |x| x[3] },
                      'note' => "Local: #{place} (lat #{lat}, long #{lon}). Horários locais do modelo.")
      jobs << board_job(blender, man, items, File.join(output_dir, "#{base}_insolacao.pdf"))
    end
    run_sequence(jobs, File.join(output_dir, "#{base}_insolacao.log"))
    UI.messagebox("Estudo de insolação na fila: 9 imagens#{man ? ' + a prancha em PDF' : ''}.\n\n" \
                  "Leva alguns minutos. A pasta abre sozinha quando terminar:\n#{output_dir}")
  end

  # Uma fila: um Blender por vez, para não sobrecarregar o computador.
  def self.run_sequence(jobs, log)
    dir = File.dirname(log)
    if windows?
      script = File.join(cache_dir, "fila_#{stamp}.cmd")
      FileUtils.mkdir_p(File.dirname(script))
      lines = ['@echo off', 'chcp 65001 >nul']
      jobs.each { |a| lines << "#{a.map { |x| q(x) }.join(' ')} >> #{q(log)} 2>&1" }
      lines << "start \"\" #{q(dir.tr('/', '\\'))}"
      File.open(script, 'w:UTF-8') { |f| f.write(lines.join("\r\n") + "\r\n") }
      shell_run("cmd /c #{q(script)}", 0)
    else
      script = File.join(cache_dir, "fila_#{stamp}.sh")
      FileUtils.mkdir_p(File.dirname(script))
      lines = jobs.map { |a| "#{a.map { |x| q(x) }.join(' ')} >> #{q(log)} 2>&1" }
      lines << "open #{q(dir)}"
      File.write(script, lines.join("\n") + "\n")
      Process.detach(Process.spawn('/bin/sh', script))
    end
  end

  def self.open_renders
    if windows?
      shell_run("explorer.exe #{q(output_dir.tr('/', '\\'))}", 1)
    else
      Process.detach(Process.spawn('open', output_dir))
    end
  end

  def self.settings
    qualities = QUALITY.keys
    labels = MODES.map { |m| m[1] }
    current = MODES.find { |m| m[0] == mode }
    prompts = ['Estilo padrão', 'Qualidade', 'Pasta dos renders', 'Blender (deixe vazio para procurar)']
    defaults = [current ? current[1] : labels[0], quality, output_dir, pref('blender_exe', find_blender.to_s)]
    lists = [labels.join('|'), qualities.join('|'), '', '']
    res = UI.inputbox(prompts, defaults, lists, 'Blendit - Configurações')
    return unless res
    m = MODES.find { |x| x[1] == res[0] }
    set_pref('mode', m[0]) if m
    set_pref('quality', res[1]) if QUALITY.key?(res[1])
    set_pref('output_dir', res[2].to_s.strip) unless res[2].to_s.strip.empty?
    exe = res[3].to_s.strip.delete('"')
    if exe.empty?
      set_pref('blender_exe', '')
    elsif File.file?(exe)
      set_pref('blender_exe', exe)
    else
      UI.messagebox("Não achei o Blender em:\n#{exe}\n\nVou procurar automaticamente.")
      set_pref('blender_exe', '')
    end
  end

  def self.about
    UI.messagebox("Blendit para SketchUp - versão #{VERSION}\n\n" \
                  "Leva a vista do SketchUp para o Blender e renderiza em 16 estilos.\n\n" \
                  "• Renderizar vista / Abrir no Blender / Renderizar todas as cenas (com prancha).\n" \
                  "• Estudo de insolação: 9 imagens + prancha em PDF.\n" \
                  "• Biblioteca de materiais: texturas reais em tamanho real (Poly Haven, CC0).\n" \
                  "• Luminárias viram luzes (pelo nome: spot, pendente, plafon, arandela, fita LED...).\n" \
                  "• Plano de corte ativo vira corte no render, com o corte preenchido.\n" \
                  "• Iluminação Dia ou Noite.\n\n" \
                  "Precisa do Blender 4.2 ou mais novo (gratuito, blender.org).\n\n" \
                  "Baseado no Blendit de lewismconte (licença MIT): github.com/lewismconte/blendit")
  end

  # ------------------------------------------------------------- interface
  def self.icon(name, size)
    File.join(PLUGIN_DIR, 'icons', "#{name}_#{size}.png")
  end

  def self.command(title, tip, icon_name, &block)
    cmd = UI::Command.new(title, &block)
    cmd.tooltip = title
    cmd.status_bar_text = tip
    if icon_name
      cmd.small_icon = icon(icon_name, 16)
      cmd.large_icon = icon(icon_name, 24)
    end
    cmd
  end

  # Descoberta de texturas no Poly Haven e no ambientCG: baixa só a LISTA
  # (nomes, categorias, miniaturas, mapas, licença), nenhuma textura.
  def self.atualizar_catalogo_online
    st = CatalogoOnline.estado
    msg = "Procurar texturas novas no Poly Haven e no ambientCG?\n\n" \
          "Baixa só a lista de materiais (alguns MB, até 1-2 minutos) - nenhuma textura.\n" \
          "Hoje: #{st[:total]} materiais no catálogo (#{st[:legados]} da biblioteca fixa)."
    msg += "\nÚltima atualização: #{st[:atualizado_em]}" if st[:atualizado_em]
    return unless UI.messagebox(msg, MB_YESNO) == IDYES
    Sketchup.status_text = 'Blendit: consultando Poly Haven e ambientCG...'
    r = CatalogoOnline.atualizar
    st = CatalogoOnline.estado
    linhas = r.map do |fonte, x|
      nome = fonte == 'polyhaven' ? 'Poly Haven' : 'ambientCG'
      x[:ok] ? "#{nome}: #{x[:total]} materiais (#{x[:novos]} novos desde a última vez)" :
               "#{nome}: não deu para atualizar (#{x[:erro]}) - mantidos #{x[:total]} já catalogados"
    end
    UI.messagebox("Catálogo: #{st[:total]} materiais.\n\n#{linhas.join("\n")}\n\n" \
                  "Licença: CC0 nas duas fontes (Poly Haven ToS; docs.ambientcg.com/license).\n" \
                  "Texturas da API Poly Haven (polyhaven.com) e do ambientCG (ambientcg.com).\n\n" \
                  'Nesta versão os materiais novos ficam catalogados; a galeria e o modo ' \
                  'Automático continuam usando a biblioteca fixa.')
  rescue StandardError => e
    UI.messagebox("Não foi possível atualizar o catálogo: #{e.message}")
  ensure
    Sketchup.status_text = ''
  end

  def self.toggle(key, padrao = '0')
    set_pref(key, pref(key, padrao) == '1' ? '0' : '1')
  end

  unless file_loaded?(__FILE__)
    c_render = command('Renderizar vista', 'Renderiza a vista atual no Blender com o estilo escolhido',
                       'render') { render_view }
    c_open = command('Abrir no Blender', 'Abre a vista no Blender para compor e ajustar ao vivo',
                     'abrir') { open_in_blender }
    c_scenes = command('Renderizar todas as cenas', 'Uma imagem por cena do modelo, em fila (e prancha em PDF)',
                       'cenas') { render_all_scenes }
    c_sun = command('Estudo de insolação', '9 imagens: 21/06, 21/03 e 21/12 às 9h, 12h e 15h, com prancha',
                    'sol') { sun_study }
    c_lib = command('Biblioteca de materiais', 'Texturas reais em tamanho real: porcelanatos, madeiras, pedras...',
                    'materiais') { Texturas.show }
    c_folder = command('Abrir pasta dos renders', 'Abre a pasta onde as imagens são salvas',
                       'pasta') { open_renders }
    c_settings = command('Configurações...', 'Estilo, qualidade, pasta e caminho do Blender',
                         'config') { settings }

    menu = UI.menu('Extensions').add_submenu('Blendit')
    menu.add_item(c_render)
    menu.add_item(c_open)
    menu.add_item(c_scenes)
    menu.add_item(c_sun)
    menu.add_item(c_lib)
    mats = menu.add_submenu('Materiais no render')
    [['preservar', 'Preservar (como no SketchUp - padrão)'],
     ['estrito', 'Preservar estritamente (sem nenhum ajuste automático)'],
     ['automatico', 'Automático (textura real para materiais só-cor, só no render)']].each do |k, nome|
      id = mats.add_item(nome) { set_pref('materiais', k) }
      mats.set_validation_proc(id) { pref('materiais', 'preservar') == k ? MF_CHECKED : MF_UNCHECKED }
    end
    mats.add_separator
    mats.add_item('Revisar sugestões...') { AutoTexturas.show }
    mats.add_item('Limpar escolhas automáticas') do
      m = Sketchup.active_model
      n = m ? AutoTexturas.limpar_escolhas(m) : 0
      UI.messagebox("Escolhas automáticas removidas de #{n} materiais (Ctrl+Z desfaz).")
    end
    menu.add_item('Texturas automáticas...') { AutoTexturas.show }
    menu.add_item('Atualizar catálogo online de texturas...') { atualizar_catalogo_online }
    menu.add_item('Montar prancha com imagens de uma pasta...') { board_from_folder }
    menu.add_separator
    styles = menu.add_submenu('Estilo')
    MODES.each do |key, label, _desc|
      id = styles.add_item(label) { set_pref('mode', key) }
      styles.set_validation_proc(id) { mode == key ? MF_CHECKED : MF_UNCHECKED }
    end
    quals = menu.add_submenu('Qualidade')
    QUALITY.each_key do |qk|
      id = quals.add_item(qk) { set_pref('quality', qk) }
      quals.set_validation_proc(id) { quality == qk ? MF_CHECKED : MF_UNCHECKED }
    end
    luz = menu.add_submenu('Iluminação')
    id = luz.add_item('Dia (sol e céu + luminárias)') { set_pref('noite', '0') }
    luz.set_validation_proc(id) { night? ? MF_UNCHECKED : MF_CHECKED }
    id = luz.add_item('Noite (só as luminárias)') { set_pref('noite', '1') }
    luz.set_validation_proc(id) { night? ? MF_CHECKED : MF_UNCHECKED }
    tom = menu.add_submenu('Tom da imagem')
    [['natural', 'Natural'], ['neutro', 'Branco mais neutro (menos amarelado)'],
     ['quente', 'Mais aconchegante (mais quente)']].each do |k, nome|
      id = tom.add_item(nome) { set_pref('tom', k) }
      tom.set_validation_proc(id) { pref('tom', 'natural') == k ? MF_CHECKED : MF_UNCHECKED }
    end
    bri = menu.add_submenu('Brilho')
    [['-1', 'Bem mais escuro'], ['-0.5', 'Mais escuro'], ['0', 'Normal'],
     ['0.5', 'Mais claro'], ['1', 'Bem mais claro']].each do |k, nome|
      id = bri.add_item(nome) { set_pref('brilho', k) }
      bri.set_validation_proc(id) { pref('brilho', '0') == k ? MF_CHECKED : MF_UNCHECKED }
    end
    amb = menu.add_submenu('Ambiente interno')
    [['auto', 'Automático'],
     ['sim', 'Sim - é um ambiente interno (fecha o forro se faltar)'],
     ['nao', 'Não - é uma cena externa']].each do |k, nome|
      id = amb.add_item(nome) { set_pref('interior', k) }
      amb.set_validation_proc(id) { pref('interior', 'auto') == k ? MF_CHECKED : MF_UNCHECKED }
    end
    ceu = menu.add_submenu('Céu')
    Ceus::LISTA.each do |k, c|
      id = ceu.add_item(c[:nome]) { set_pref('ceu', k) }
      ceu.set_validation_proc(id) { Ceus.escolhido == k ? MF_CHECKED : MF_UNCHECKED }
    end
    id = menu.add_item('Paredes retas (perspectiva de 2 pontos)') { toggle('dois_pontos', '1') }
    menu.set_validation_proc(id) { pref('dois_pontos', '1') == '1' ? MF_CHECKED : MF_UNCHECKED }
    id = menu.add_item('Inverter lado do corte') { toggle('flip_section') }
    menu.set_validation_proc(id) { flip_section? ? MF_CHECKED : MF_UNCHECKED }
    menu.add_separator
    menu.add_item(c_folder)
    menu.add_item(c_settings)
    menu.add_item('Procurar atualização') { Atualizacao.verificar }
    menu.add_item('Sobre o Blendit') { about }

    tb = UI::Toolbar.new('Blendit')
    [c_render, c_open, c_scenes, c_sun, c_lib, c_folder, c_settings].each { |c| tb.add_item(c) }
    tb.restore if tb.get_last_state != TB_HIDDEN

    # Checagem diária de versão nova, sem atrapalhar a abertura do SketchUp.
    UI.start_timer(10, false) { Atualizacao.verificar(silencioso: true) }

    file_loaded(__FILE__)
  end
end
