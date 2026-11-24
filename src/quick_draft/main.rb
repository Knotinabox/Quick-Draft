require 'sketchup.rb'

Sketchup.require(File.join(__dir__, 'survey_importer'))
Sketchup.require(File.join(__dir__, 'scene_cutter'))
Sketchup.require(File.join(__dir__, 'layout_generator'))

module ::Kernel
  def reload
    QuickDraft::Main.reload
  end
end

module QuickDraft
  def self.reload
    Main.reload
  end

  module Main
    def self.reload
      original_verbose = $VERBOSE
      $VERBOSE = nil
      begin
        load File.join(__dir__, 'survey_importer.rb')
        load File.join(__dir__, 'scene_cutter.rb')
        load File.join(__dir__, 'layout_generator.rb')
        puts 'QuickDraft: Worker modules reloaded successfully.'
        UI.messagebox('QuickDraft: Core modules reloaded successfully.')
      rescue Exception => e
        UI.messagebox("QuickDraft Reload Error:\n\n#{e.class}: #{e.message}\n\n#{e.backtrace.first(5).join("\n")}")
      ensure
        $VERBOSE = original_verbose
      end
    end
    module_function :reload

    unless file_loaded?(__FILE__)
      icons_dir = File.join(__dir__, 'icons')

      # -----------------------------------------------------------------------
      # Shared Commands
      # -----------------------------------------------------------------------
      cmd_import = UI::Command.new('1. Import Surveyor DWG & Build Terrain') do
        QuickDraft::SurveyImporter.run
      end
      cmd_import.small_icon = File.join(icons_dir, 'survey_24.png')
      cmd_import.large_icon = File.join(icons_dir, 'survey_32.png')
      cmd_import.tooltip = '1. Import Surveyor DWG & Build Terrain'
      cmd_import.status_bar_text = 'Import CAD survey, generate 3D TIN terrain, drape lot lines, and place tree proxies'

      cmd_scenes = UI::Command.new('2. Cut Architectural Scenes') do
        QuickDraft::SceneCutter.run
      end
      cmd_scenes.small_icon = File.join(icons_dir, 'scenes_24.png')
      cmd_scenes.large_icon = File.join(icons_dir, 'scenes_32.png')
      cmd_scenes.tooltip = '2. Cut Architectural Scenes'
      cmd_scenes.status_bar_text = 'Generate standard municipal permit scenes with orthographic cameras and 48" section cuts'

      cmd_layout = UI::Command.new('3. Generate LayOut Sheets') do
        QuickDraft::LayoutGenerator.run
      end
      cmd_layout.small_icon = File.join(icons_dir, 'layout_24.png')
      cmd_layout.large_icon = File.join(icons_dir, 'layout_32.png')
      cmd_layout.tooltip = '3. Generate LayOut Sheets'
      cmd_layout.status_bar_text = 'Construct LayOut document, scale viewports, add datum tags, and export PDF'

      cmd_reload = UI::Command.new('Reload QuickDraft (Dev)') do
        QuickDraft::Main.reload
      end
      cmd_reload.small_icon = File.join(icons_dir, 'reload_24.png')
      cmd_reload.large_icon = File.join(icons_dir, 'reload_32.png')
      cmd_reload.tooltip = 'Reload QuickDraft (Dev)'
      cmd_reload.status_bar_text = 'Hot reload all QuickDraft Ruby files'

      # -----------------------------------------------------------------------
      # Menu Items
      # -----------------------------------------------------------------------
      menu = UI.menu('Extensions').add_submenu('QuickDraft')
      menu.add_item(cmd_import)
      menu.add_item(cmd_scenes)
      menu.add_item(cmd_layout)
      menu.add_separator
      menu.add_item(cmd_reload)

      # -----------------------------------------------------------------------
      # Toolbar
      # -----------------------------------------------------------------------
      toolbar = UI::Toolbar.new('QuickDraft')
      toolbar.add_item(cmd_import)
      toolbar.add_item(cmd_scenes)
      toolbar.add_item(cmd_layout)
      toolbar.add_separator
      toolbar.add_item(cmd_reload)

      state = toolbar.get_last_state
      if state == 1 || state == -1
        toolbar.show
      end

      file_loaded(__FILE__)
    end
  end
end
