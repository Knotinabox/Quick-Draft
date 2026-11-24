require 'sketchup.rb'
require 'extensions.rb'

module QuickDraft
  PLUGIN_ID = 'quick_draft'.freeze
  PLUGIN_NAME = 'QuickDraft'.freeze
  PLUGIN_VERSION = '0.1.0'.freeze

  unless file_loaded?(__FILE__)
    loader_path = File.join(__dir__, 'quick_draft', 'main')
    ex = SketchupExtension.new(PLUGIN_NAME, loader_path)
    ex.description = 'Automates surveyor DWG terrain import, architectural section cuts, and LayOut sheet generation.'
    ex.version     = PLUGIN_VERSION
    ex.copyright   = "Studio Internal #{Time.now.year}"
    ex.creator     = 'Studio Automation'

    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end
end
