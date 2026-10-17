# Carrega o main.rb do plugin com uma interface do SketchUp imitada e confere os
# comandos que seriam enviados ao Blender (sem abrir nada).
require_relative 'sketchup_fake'

MF_CHECKED = 8; MF_UNCHECKED = 0; MB_YESNO = 4; MB_OKCANCEL = 1; IDYES = 6; IDOK = 1; TB_HIDDEN = 0
$loaded = {}
def file_loaded?(f) = $loaded[f]
def file_loaded(f) = ($loaded[f] = true)

module Sketchup
  @prefs = {}
  @platform = :platform_win
  class << self
    attr_accessor :platform, :status_text, :model
    def read_default(_s, k, d) = @prefs.fetch(k, d)
    def write_default(_s, k, v) = (@prefs[k] = v)
    def active_model = @model
  end
end

module UI
  @log = []
  class << self
    attr_reader :log
    def messagebox(msg, type = 0) = (@log << msg; type == 1 ? 1 : 6)
    def menu(_n) = Menu.new
    def openpanel(*) = nil
    def inputbox(_p, defaults, *_) = defaults
    attr_reader :timers
    def start_timer(_s, _r = false, &b) = ((@timers ||= []) << b; 1)
  end
  class Menu
    def add_submenu(_n) = Menu.new
    def add_item(_c, &_b) = 1
    def add_separator; end
    def set_validation_proc(_i, &_b); end
  end
  class Command
    attr_accessor :tooltip, :status_bar_text, :small_icon, :large_icon
    def initialize(_t, &_b); end
  end
  class Toolbar
    def initialize(_n); end
    def add_item(_c); end
    def get_last_state = 1
    def restore; end
  end
end

require File.join(ENV.fetch('BLENDIT_PLUGIN', File.expand_path('../dist/stage', __dir__)), 'blendit_sketchup', 'main')

# Não roda nada de verdade: guarda os comandos.
module BlenditSU
  @spawned = []
  class << self
    attr_reader :spawned
    def spawn_hidden(args, log = nil) = @spawned << [:hidden, args, log]
    def spawn_window(args) = @spawned << [:window, args]
    def shell_run(line, style) = @spawned << [:shell, line, style]
    def find_blender = 'C:/Program Files/Blender Foundation/Blender 5.1/blender.exe'
    attr_reader :queues
    alias_method :real_run_sequence, :run_sequence
    def run_sequence(jobs, log) = ((@queues ||= []) << [jobs, log])
  end
end

ENV['LOCALAPPDATA'] = ARGV[0] || '/tmp/su_cache'
ENV['USERPROFILE'] = ARGV[0] || '/tmp/su_cache'
require_relative 'cena_teste'
Sketchup.model = build_model(ARGV[1])

puts '--- Renderizar vista'
BlenditSU.render_view
k, args, log = BlenditSU.spawned.last
puts "#{k}: #{args.inspect}"
puts "log: #{log}"
puts "msg: #{UI.log.last}"

puts '--- Abrir no Blender'
BlenditSU.open_in_blender
p BlenditSU.spawned.last

puts '--- Estilo/qualidade trocados'
Sketchup.write_default('BlenditSketchUp', 'mode', 'watercolor')
Sketchup.write_default('BlenditSketchUp', 'quality', 'Final')
BlenditSU.render_view
p BlenditSU.spawned.last[1].each_slice(1).to_a.flatten.last(14)

puts '--- Estudo de insolação'
BlenditSU.sun_study
jobs, _log = BlenditSU.queues.last
puts "jobs: #{jobs.length}"
File.write(File.join(ENV['LOCALAPPDATA'], 'jobs_insolacao.json'), JSON.generate(jobs))
puts UI.log.last

puts '--- Fila de cenas (gera o .cmd)'
BlenditSU.real_run_sequence([['C:/b/blender.exe', '--background', 'x y.py'], ['C:/b/blender.exe', 'z']],
                       File.join(ENV['LOCALAPPDATA'], 'renders', 'fila.log'))
line = BlenditSU.spawned.last[1]
puts line
script = line[/"(.*)"/, 1]
puts File.read(script)

puts '--- Sem cenas'
BlenditSU.render_all_scenes
puts UI.log.last

puts '--- Atualização'
MB_YESNO = 4 unless defined?(MB_YESNO)
module Sketchup
  class << self
    attr_reader :installed
    def install_from_archive(path, _ask = true) = (@installed = path; true)
  end
end
remote = { 'versao' => '9.9.0', 'rbz' => 'https://exemplo/x.rbz', 'novidades' => '- teste' }
BlenditSU::Texturas.define_singleton_method(:download) do |url, path|
  File.write(path, url.include?('versao.json') ? JSON.generate(remote) : 'rbz')
  path
end
BlenditSU::Atualizacao.verificar
puts "instalado: #{Sketchup.installed}"
puts UI.log.last
remote['versao'] = '0.3.7'
BlenditSU::Atualizacao.verificar
puts UI.log.last
puts "timer agendado: #{UI.timers.length}"


puts '--- Céu fotografado'
Sketchup.write_default('BlenditSketchUp', 'mode', 'realistic')
Sketchup.write_default('BlenditSketchUp', 'ceu', 'limpo')
BlenditSU::Texturas.define_singleton_method(:download) do |url, path|
  FileUtils.mkdir_p(File.dirname(path))
  if url.include?('/files/')
    File.write(path, JSON.generate('hdri' => { '2k' => { 'hdr' => { 'url' => 'https://exemplo/ceu.hdr' } } }))
  else
    File.binwrite(path, 'x' * 200_000)
  end
  path
end
BlenditSU.render_view
spec_dir = File.join(ENV['LOCALAPPDATA'], 'BlenditSketchUp', 'cache')
spec = Dir.glob(File.join(ENV['LOCALAPPDATA'], '**', 'scene_spec.json')).max_by { |f| File.mtime(f) }
j = JSON.parse(File.read(spec))
puts "céu: #{j['world'].slice('sky_type', 'hdri_uri', 'hdri_strength', 'hdri_normalize')} sol: #{j['sun']['strength']}"
puts "hdr no pacote: #{File.size?(File.join(File.dirname(spec), j['world']['hdri_uri'].to_s)).inspect}"
Sketchup.write_default('BlenditSketchUp', 'noite', '1')
BlenditSU.render_view
spec = Dir.glob(File.join(ENV['LOCALAPPDATA'], '**', 'scene_spec.json')).max_by { |f| File.mtime(f) }
puts "noite: #{JSON.parse(File.read(spec))['world']['sky_type']}"
