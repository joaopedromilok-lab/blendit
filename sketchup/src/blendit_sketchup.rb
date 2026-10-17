# encoding: UTF-8
# Blendit para SketchUp - carregador da extensão.
require 'sketchup.rb'
require 'extensions.rb'

module BlenditSU
  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('Blendit para SketchUp', 'blendit_sketchup/main')
    ext.description = 'Renderiza a vista do SketchUp no Blender com um clique: ' \
                      'realista, maquete branca, estudo de sombras, croqui, aquarela e mais 11 estilos. ' \
                      'Baseado no Blendit (MIT) de lewismconte.'
    ext.version = '0.2.0'
    ext.creator = 'Blendit (lewismconte) - adaptação para SketchUp'
    ext.copyright = 'Licença MIT'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
