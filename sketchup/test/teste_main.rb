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
    def messagebox(msg, *_) = (@log << msg; 6)
    def menu(_n) = Menu.new
    def openpanel(*) = nil
    def inputbox(*) = nil
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

puts '--- Fila de cenas (gera o .cmd)'
BlenditSU.run_sequence([['C:/b/blender.exe', '--background', 'x y.py'], ['C:/b/blender.exe', 'z']],
                       File.join(ENV['LOCALAPPDATA'], 'renders', 'fila.log'))
line = BlenditSU.spawned.last[1]
puts line
script = line[/"(.*)"/, 1]
puts File.read(script)

puts '--- Sem cenas'
BlenditSU.render_all_scenes
puts UI.log.last
