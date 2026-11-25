require 'sketchup.rb'

Sketchup.require(File.join(__dir__, 'survey_importer'))
Sketchup.require(File.join(__dir__, 'scene_cutter'))
Sketchup.require(File.join(__dir__, 'layout_generator'))

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
        puts 'QuickDraft: Core modules reloaded successfully.'

        # Check if an existing site has already been imported in the active model
        model = Sketchup.active_model
        site_dict = model ? model.attribute_dictionary('QuickDraft_SiteData') : nil
        has_site = site_dict && site_dict['dwg_path'] && File.exist?(site_dict['dwg_path'].to_s)

        if has_site
          dwg_name = File.basename(site_dict['dwg_path'].to_s)
          res = UI.messagebox("QuickDraft core modules reloaded successfully!\n\nWould you like to re-run the 3D Site Pipeline on '#{dwg_name}' now to update your terrain and building footprints?", MB_YESNO)
          if res == IDYES
            QuickDraft::SurveyImporter.rebuild_current_site(model)
          end
        else
          UI.messagebox("QuickDraft: Core modules reloaded successfully.\n\nClick '1. Import Surveyor DWG & Build Terrain' to generate your 3D site.")
        end
      rescue Exception => e
        bt = (e.backtrace || []).first(5).join("\n")
        UI.messagebox("QuickDraft Reload Error:\n\n#{e.class}: #{e.message}\n\n#{bt}")
      ensure
        $VERBOSE = original_verbose
      end
    end

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

      cmd_import_csv = UI::Command.new('Import Survey Points (CSV)...') do
        QuickDraft::SurveyImporter.import_csv_points_dialog
      end
      cmd_import_csv.small_icon = File.join(icons_dir, 'survey_24.png')
      cmd_import_csv.large_icon = File.join(icons_dir, 'survey_32.png')
      cmd_import_csv.tooltip = 'Import Separate Surveyor Points CSV/TXT & Rebuild Terrain'
      cmd_import_csv.status_bar_text = 'Attach a PNEZD/PENZD survey points CSV file and merge into 3D terrain'

      cmd_rebuild = UI::Command.new('Rebuild 3D Site Pipeline') do
        begin
          load File.join(__dir__, 'survey_importer.rb')
          QuickDraft::SurveyImporter.rebuild_current_site
        rescue Exception => e
          bt = (e.backtrace || []).first(5).join("\n")
          UI.messagebox("QuickDraft Rebuild Error:\n\n#{e.class}: #{e.message}\n\n#{bt}")
        end
      end
      cmd_rebuild.small_icon = File.join(icons_dir, 'survey_24.png')
      cmd_rebuild.large_icon = File.join(icons_dir, 'survey_32.png')
      cmd_rebuild.tooltip = 'Rebuild 3D Site Pipeline (Heal Linework & Drape)'
      cmd_rebuild.status_bar_text = 'Rebuild 3D terrain and draped building footprints with latest healed geometry'

      cmd_aerial = UI::Command.new('Skin Terrain with Aerial Photo (JPG/PNG)...') do
        QuickDraft::SurveyImporter.apply_aerial_photo_dialog
      end
      cmd_aerial.small_icon = File.join(icons_dir, 'aerial_24.png')
      cmd_aerial.large_icon = File.join(icons_dir, 'aerial_32.png')
      cmd_aerial.tooltip = 'Skin 3D Terrain with Aerial / Satellite Photo (JPG/PNG)'
      cmd_aerial.status_bar_text = 'Project high-resolution aerial or drone photo onto 3D terrain mesh'

      cmd_adjust_aerial = UI::Command.new('Adjust Aerial Photo Position / Scale...') do
        QuickDraft::SurveyImporter.open_aerial_adjuster_dialog_from_menu
      end
      cmd_adjust_aerial.small_icon = File.join(icons_dir, 'aerial_24.png')
      cmd_adjust_aerial.large_icon = File.join(icons_dir, 'aerial_32.png')
      cmd_adjust_aerial.tooltip = 'Adjust Aerial Photo Position, Scale & Rotation'
      cmd_adjust_aerial.status_bar_text = 'Open interactive live alignment panel to nudge scale, offset and rotation'

      cmd_reset_terrain = UI::Command.new('Reset Terrain to Architectural Tint') do
        QuickDraft::SurveyImporter.reset_terrain_material_dialog
      end
      cmd_reset_terrain.small_icon = File.join(icons_dir, 'aerial_24.png')
      cmd_reset_terrain.large_icon = File.join(icons_dir, 'aerial_32.png')
      cmd_reset_terrain.tooltip = 'Reset Terrain to clean architectural green tint'
      cmd_reset_terrain.status_bar_text = 'Restore uniform QD_Site_Terrain material across 3D terrain'

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
      menu.add_item(cmd_import_csv)
      menu.add_item(cmd_rebuild)
      menu.add_item(cmd_aerial)
      menu.add_item(cmd_adjust_aerial)
      menu.add_item(cmd_reset_terrain)
      menu.add_separator
      menu.add_item(cmd_scenes)
      menu.add_item(cmd_layout)
      menu.add_separator
      menu.add_item(cmd_reload)

      # -----------------------------------------------------------------------
      # Toolbar
      # -----------------------------------------------------------------------
      toolbar = UI::Toolbar.new('QuickDraft')
      toolbar.add_item(cmd_import)
      toolbar.add_item(cmd_rebuild)
      toolbar.add_item(cmd_aerial)
      toolbar.add_item(cmd_adjust_aerial)
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

def qd_reload
  QuickDraft::Main.reload
end
