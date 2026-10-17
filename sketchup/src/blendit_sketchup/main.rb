# encoding: UTF-8
# Blendit para SketchUp - menus, barra de ferramentas e integração com o Blender.
require 'sketchup.rb'
require 'fileutils'
require 'tmpdir'
require_relative 'exporter'

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
    'Final'    => { engine: 'CYCLES', samples: 512, width: 2560, denoise: true }
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

  # Exporta a vista atual. Devolve [spec_path, opts] ou nil se falhar.
  def self.export_current(model, folder_name)
    qcfg = QUALITY[quality]
    opts = { mode: mode, engine: qcfg[:engine], samples: qcfg[:samples],
             resolution: [qcfg[:width], 0], denoise: qcfg[:denoise] }
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

    popts = model.options['PageOptions']
    old_transition = popts['ShowTransition']
    original = model.pages.selected_page
    base = "#{safe_name(model.title)}_#{stamp}"
    jobs = []
    begin
      popts['ShowTransition'] = false
      pages.each_with_index do |page, i|
        model.pages.selected_page = page
        model.active_view.refresh if model.active_view.respond_to?(:refresh)
        spec, opts = export_current(model, "#{base}_cena#{i + 1}")
        next unless spec
        png = File.join(output_dir, "#{base}_#{format('%02d', i + 1)}_#{safe_name(page.name)}.png")
        jobs << render_args(blender, spec, png, opts)
      end
    ensure
      model.pages.selected_page = original if original
      popts['ShowTransition'] = old_transition
    end
    return if jobs.empty?
    run_sequence(jobs, File.join(output_dir, "#{base}_cenas.log"))
    UI.messagebox("#{jobs.length} cena(s) na fila do Blender.\n\nAs imagens vão aparecendo em:\n#{output_dir}\n\n" \
                  'A pasta abre sozinha quando todas terminarem.')
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
    UI.messagebox("Blendit para SketchUp\n\n" \
                  "Leva a vista do SketchUp para o Blender e renderiza em 16 estilos.\n\n" \
                  "• Renderizar vista: gera a imagem em segundo plano.\n" \
                  "• Abrir no Blender: para compor o enquadramento, trocar o estilo ao vivo (tecla N) " \
                  "e capturar com Enter.\n" \
                  "• Renderizar todas as cenas: uma imagem por cena do modelo.\n\n" \
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

  unless file_loaded?(__FILE__)
    c_render = command('Renderizar vista', 'Renderiza a vista atual no Blender com o estilo escolhido',
                       'render') { render_view }
    c_open = command('Abrir no Blender', 'Abre a vista no Blender para compor e ajustar ao vivo',
                     'abrir') { open_in_blender }
    c_scenes = command('Renderizar todas as cenas', 'Uma imagem por cena do modelo, em fila',
                       'cenas') { render_all_scenes }
    c_folder = command('Abrir pasta dos renders', 'Abre a pasta onde as imagens são salvas',
                       'pasta') { open_renders }
    c_settings = command('Configurações...', 'Estilo, qualidade, pasta e caminho do Blender',
                         'config') { settings }

    menu = UI.menu('Extensions').add_submenu('Blendit')
    menu.add_item(c_render)
    menu.add_item(c_open)
    menu.add_item(c_scenes)
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
    menu.add_separator
    menu.add_item(c_folder)
    menu.add_item(c_settings)
    menu.add_item('Sobre o Blendit') { about }

    tb = UI::Toolbar.new('Blendit')
    [c_render, c_open, c_scenes, c_folder, c_settings].each { |c| tb.add_item(c) }
    tb.restore if tb.get_last_state != TB_HIDDEN

    file_loaded(__FILE__)
  end
end
