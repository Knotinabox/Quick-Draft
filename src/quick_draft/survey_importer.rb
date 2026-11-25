require 'sketchup.rb'
require 'json'

module QuickDraft
  module SurveyImporter
    TAG_SITE_ALL         = 'Site-All'.freeze
    MASTER_GROUP_NAME    = 'Site_All'.freeze

    SURVEY_GROUP_NAME    = 'Site_Survey_2D'.freeze
    TERRAIN_GROUP_NAME   = 'Site_Terrain'.freeze
    LOT_LINES_GROUP_NAME = 'Site_Lot_Lines'.freeze
    TREES_GROUP_NAME     = 'Site_Trees_Existing'.freeze

    TAG_TERRAIN          = 'SITE-TERRAIN'.freeze
    TAG_PROPERTY_LINE    = 'SITE-PROPERTY-LINE'.freeze
    TAG_TREES            = 'SITE-TREES-EXISTING'.freeze
    TAG_SURVEY_2D        = 'SITE-SURVEY-2D'.freeze
    TAG_SURVEY_TEXT      = 'SITE-SURVEY-TEXT'.freeze
    TAG_SURVEY_POINTS    = 'SITE-SURVEY-POINTS'.freeze
    TAG_DRIVEWAY         = 'SITE-DRIVEWAY-ASPHALT'.freeze
    PAVING_GROUP_NAME    = 'Site_Paved_Surfaces_3D'.freeze

    TAG_BUILDING_FOOTPRINT = 'SITE-BUILDING-FOOTPRINT'.freeze
    BUILDING_GROUP_NAME    = 'Site_Building_Footprint_3D'.freeze

    TAG_DESIGN_2D        = 'SITE-DESIGN-2D'.freeze
    RAW_LOT_GROUP_NAME   = 'Site_Raw_Lot_Design_2D'.freeze

    DICT_SITE_DATA       = 'QuickDraft_SiteData'.freeze
    TREE_PROXY_DEF_NAME  = 'QuickDraft_Tree_Proxy'.freeze

    # =========================================================================
    # Fast 2.5D Delaunay Triangulation (Bowyer-Watson with Integer Indexing)
    # =========================================================================
    module Delaunay
      class IndexedTriangle
        attr_reader :i1, :i2, :i3, :cx, :cy, :r_sq

        def initialize(i1, i2, i3, pt_lookup)
          @i1 = i1
          @i2 = i2
          @i3 = i3

          p1 = pt_lookup.call(i1)
          p2 = pt_lookup.call(i2)
          p3 = pt_lookup.call(i3)

          ax = p1.x; ay = p1.y
          bx = p2.x; by = p2.y
          cx = p3.x; cy = p3.y

          d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
          if d.abs < 1e-10
            @cx = (ax + bx + cx) / 3.0
            @cy = (ay + by + cy) / 3.0
            @r_sq = 1e14
          else
            a_sq = ax * ax + ay * ay
            b_sq = bx * bx + by * by
            c_sq = cx * cx + cy * cy

            @cx = (a_sq * (by - cy) + b_sq * (cy - ay) + c_sq * (ay - by)) / d
            @cy = (a_sq * (cx - bx) + b_sq * (ax - cx) + c_sq * (bx - ax)) / d

            dx = ax - @cx
            dy = ay - @cy
            @r_sq = dx * dx + dy * dy
          end
        end

        def in_circumcircle?(px, py)
          dx = px - @cx
          dy = py - @cy
          (dx * dx + dy * dy) <= (@r_sq + 1e-9)
        end
      end

      def self.triangulate(points)
        return [] if points.nil? || points.size < 3

        pts = deduplicate_points(points, 2.0)
        return [] if pts.size < 3

        min_x = pts.map(&:x).min
        max_x = pts.map(&:x).max
        min_y = pts.map(&:y).min
        max_y = pts.map(&:y).max
        min_z = pts.map(&:z).min

        dx = max_x - min_x
        dy = max_y - min_y
        delta_max = [dx, dy, 1.0].max
        mid_x = (min_x + max_x) / 2.0
        mid_y = (min_y + max_y) / 2.0

        st_points = [
          Geom::Point3d.new(mid_x - 25.0 * delta_max, mid_y - delta_max, min_z),
          Geom::Point3d.new(mid_x, mid_y + 25.0 * delta_max, min_z),
          Geom::Point3d.new(mid_x + 25.0 * delta_max, mid_y - delta_max, min_z)
        ]

        pt_lookup = lambda do |idx|
          idx < 0 ? st_points[-idx - 1] : pts[idx]
        end

        triangles = [IndexedTriangle.new(-1, -2, -3, pt_lookup)]

        pts.each_with_index do |pt, pt_idx|
          bad_triangles = []
          triangles.each do |tri|
            bad_triangles << tri if tri.in_circumcircle?(pt.x, pt.y)
          end

          edge_count = {}
          bad_triangles.each do |tri|
            [[tri.i1, tri.i2], [tri.i2, tri.i3], [tri.i3, tri.i1]].each do |u, v|
              edge = u < v ? [u, v] : [v, u]
              edge_count[edge] = (edge_count[edge] || 0) + 1
            end
          end

          boundary_edges = edge_count.select { |_e, count| count == 1 }.keys
          triangles -= bad_triangles

          boundary_edges.each do |u, v|
            triangles << IndexedTriangle.new(u, v, pt_idx, pt_lookup)
          end
        end

        valid_triangles = triangles.reject do |tri|
          tri.i1 < 0 || tri.i2 < 0 || tri.i3 < 0
        end

        valid_triangles.map do |tri|
          [pts[tri.i1], pts[tri.i2], pts[tri.i3]]
        end
      end

      def self.deduplicate_points(points, tolerance = 2.0)
        grid = {}
        unique = []
        points.each do |pt|
          key = "#{(pt.x / tolerance).round}_#{(pt.y / tolerance).round}"
          unless grid[key]
            grid[key] = true
            unique << pt
          end
        end
        unique
      end
    end

    # =========================================================================
    # Main Pipeline Runner
    # =========================================================================
    def self.run
      model = Sketchup.active_model
      unless model
        UI.messagebox('QuickDraft: No active SketchUp model open.')
        return
      end

      path = UI.openpanel(
        'Select Surveyor DWG or DXF (B.C. Land Survey / Geodetic)',
        '',
        'CAD Files (*.dwg;*.dxf)|*.dwg;*.dxf;*.DWG;*.DXF;*.cad|All Files (*.*)|*.*||'
      )
      return unless path && File.exist?(path)

      begin
        # Clean up any existing QuickDraft site groups from a previous run to avoid overlapping geometry
        cleanup_previous_run(model)

        # Note: model.import manages its own undo transaction in SketchUp; do not wrap it in start_operation
        survey_group = import_and_isolate_cad(model, path)
        unless survey_group && survey_group.valid?
          raise 'Failed to import CAD survey data into model.'
        end

        # Comprehensive layer analysis with entity inspection & classification
        analysis = analyze_survey_entities(survey_group)
        if analysis[:layers].empty?
          model.layers.each do |l|
            next if l.name == 'Layer0' || l.name == 'Untagged' || l.name == TAG_SURVEY_2D || l.name == TAG_SURVEY_TEXT
            analysis[:layers] << { name: l.name, points: 0, edges: 0, texts: 0, numeric_texts: 0, instances: 0, circles: 0, score: 0 }
          end
        end

        bbox = survey_group.bounds
        raw_width = bbox.width.to_f
        raw_height = bbox.height.to_f
        min_z = bbox.min.z.to_f
        max_z = bbox.max.z.to_f

        # Show automated intelligence dialog
        show_mapping_dialog(model, survey_group, analysis, path, raw_width, raw_height, min_z, max_z)
      rescue StandardError => e
        UI.messagebox("QuickDraft Survey Import Error:\n\n#{e.message}\n\n#{e.backtrace.first(3).join("\n")}")
      end
    end

    # =========================================================================
    # CAD Import, Isolation & DXF Text Preservation
    # =========================================================================
    def self.import_and_isolate_cad(model, path)
      # Ensure model is at root editing level to prevent parent mismatch errors
      while model.active_path
        model.close_active
      end

      clean_path = path.to_s.tr('\\', '/')
      import_path = clean_path

      # If user selected a DWG, convert to DXF via ODA for 100% SketchUp compatibility
      if clean_path.downcase.end_with?('.dwg')
        puts "QuickDraft: Selected file is DWG. Checking for companion or auto-converting to DXF..."
        comp1 = clean_path.sub(/\.dwg$/i, '.dxf')
        if File.exist?(comp1)
          import_path = comp1
        else
          dxf_converted = convert_dwg_to_dxf(clean_path)
          if dxf_converted && File.exist?(dxf_converted)
            import_path = dxf_converted
          end
        end
      end

      puts "QuickDraft: Importing CAD file into SketchUp: '#{import_path}'..."
      entities_before = model.entities.to_a

      status = model.import(import_path, false)
      status = model.import(import_path, true) unless status

      # If direct import failed and file was DWG, convert to DXF via ODA and re-attempt
      if !status && import_path.downcase.end_with?('.dwg')
        puts "QuickDraft: Direct DWG import failed. Attempting automated ODA DXF conversion..."
        dxf_path = convert_dwg_to_dxf(import_path)
        if dxf_path && File.exist?(dxf_path)
          import_path = dxf_path
          status = model.import(import_path, false)
          status = model.import(import_path, true) unless status
        end
      end

      unless status
        puts "QuickDraft: model.import returned false for '#{import_path}'"
        return nil
      end

      new_entities = (model.entities.to_a - entities_before).select { |e| e.valid? }
      if new_entities.empty?
        new_entities = (model.active_entities.to_a - entities_before).select { |e| e.valid? }
      end

      if new_entities.empty?
        puts "QuickDraft: No new entities found after import of '#{import_path}'"
        return nil
      end

      # Wrap the imported CAD entities directly into survey_group first
      survey_group = model.entities.add_group(new_entities)
      survey_group.name = SURVEY_GROUP_NAME

      # Explode any top-level ComponentInstances inside survey_group so all layers & edges are direct children
      survey_group.entities.grep(Sketchup::ComponentInstance).each do |inst|
        next unless inst.valid?
        inst.explode rescue nil
      end

      # Ensure no imported CAD entity is marked hidden (AutoCAD frozen/off layer artifact)
      survey_group.entities.each do |e|
        e.hidden = false if e.respond_to?(:hidden=) && e.hidden?
      end

      tag_survey = ensure_tag(model, TAG_SURVEY_2D, Sketchup::Color.new(120, 130, 140))
      tag_survey.visible = true if tag_survey.respond_to?(:visible=)
      survey_group.layer = tag_survey

      survey_group
    end

    def self.cleanup_previous_run(model)
      @terrain_triangles = nil
      @terrain_points = nil
      @terrain_vertex_cache = {}
      target_names = [MASTER_GROUP_NAME, 'Site_All', 'Site-All', 'Terrain', SURVEY_GROUP_NAME, TERRAIN_GROUP_NAME, LOT_LINES_GROUP_NAME, TREES_GROUP_NAME, 'Site_Survey_Text', PAVING_GROUP_NAME, BUILDING_GROUP_NAME, RAW_LOT_GROUP_NAME, 'QD_Temp_Drape_Cutter']
      to_erase = []
      (model.entities.to_a + model.active_entities.to_a).uniq.each do |ent|
        next unless ent.valid?
        if (ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)) && target_names.include?(ent.name)
          to_erase << ent
        end
      end
      to_erase.each { |e| e.erase! if e.valid? rescue nil }
    end

    def self.clear_previous_generated_site(model)
      cleanup_previous_run(model)
    end

    def self.convert_dwg_to_dxf(dwg_path)
      return nil unless dwg_path && File.exist?(dwg_path) && dwg_path.downcase.end_with?('.dwg')

      # Check standard installation locations for ODA File Converter
      possible_paths = Dir.glob('C:/Program Files/ODA/ODAFileConverter*/**/ODAFileConverter.exe') +
                       Dir.glob('C:/Program Files (x86)/ODA/ODAFileConverter*/**/ODAFileConverter.exe') +
                       Dir.glob('C:/Program Files/ODA/*/ODAFileConverter.exe')

      oda_exe = possible_paths.find { |p| File.exist?(p) }
      unless oda_exe
        puts 'QuickDraft: ODA File Converter not found for automated DWG conversion.'
        return nil
      end

      require 'tmpdir'
      require 'fileutils'

      in_dir = File.dirname(dwg_path).tr('/', '\\')
      dwg_name = File.basename(dwg_path)
      out_dir = File.join(Dir.tmpdir, 'QuickDraft_DWG_AutoConvert').tr('/', '\\')
      FileUtils.mkdir_p(out_dir)

      puts "QuickDraft: Running automated DWG-to-DXF background conversion via ODA..."
      # ODA CLI format: ODAFileConverter <InFolder> <OutFolder> <Version> <Type> <Recurse> <Audit> <Filter>
      # Passing separate arguments bypasses cmd.exe shell escaping for paths with spaces and parentheses
      clean_oda = oda_exe.tr('/', '\\')
      system(clean_oda, in_dir, out_dir, 'ACAD2013', 'DXF', '0', '0', dwg_name)

      expected_dxf = File.join(out_dir, dwg_name.sub(/\.dwg$/i, '.dxf')).tr('\\', '/')
      if File.exist?(expected_dxf)
        puts "QuickDraft: Automated DWG conversion succeeded: '#{expected_dxf}'"
        return expected_dxf
      end

      # Fallback: check most recently modified DXF in out_dir
      recent = Dir.glob("#{out_dir.tr('\\', '/')}/*.dxf").max_by { |f| File.mtime(f) rescue Time.at(0) }
      if recent && File.exist?(recent)
        return recent
      end

      nil
    end

    def self.import_cad_text(model, survey_group, path, norm_data = nil)
      return [nil, 0] unless path && survey_group && survey_group.valid?

      clean_path = path.to_s.tr('\\', '/')
      dxf_path = nil

      if clean_path.downcase.end_with?('.dxf') && File.exist?(clean_path)
        dxf_path = clean_path
      else
        dir = File.dirname(clean_path)
        base = File.basename(clean_path, '.*')
        clean_base = base.sub(/\s*\(\d+\)$/, '').strip
        proj_code = clean_base.split(/[\s_\-]/).first.to_s.downcase

        candidate1 = clean_path.sub(/\.dwg$/i, '.dxf')
        candidate2 = "#{dir}/#{clean_base}.dxf"

        if File.exist?(candidate1)
          dxf_path = candidate1
        elsif File.exist?(candidate2)
          dxf_path = candidate2
        else
          dxf_candidates = Dir.glob("#{dir}/*.dxf").reject { |f| File.basename(f).start_with?('~') }
          user_home = ENV['USERPROFILE'] || ENV['HOME'] || ''
          downloads_dir = File.join(user_home, 'Downloads').tr('\\', '/')
          if File.directory?(downloads_dir)
            dxf_candidates += Dir.glob("#{downloads_dir}/*.dxf").reject { |f| File.basename(f).start_with?('~') }
          end

          scored = dxf_candidates.map do |f|
            fname = File.basename(f).downcase
            score = 0
            score -= 100 if fname.include?('explode')
            score -= 50 if fname.include?('test')
            score += 50 if proj_code.length > 1 && fname.include?(proj_code)
            score += 40 if clean_base.length > 3 && fname.include?(clean_base.downcase[0..10])
            score += 20 if fname.include?('ascii') || fname.include?('2010')
            score += 10 if (File.size(f) < 5 * 1024 * 1024 rescue false)
            [score, f]
          end

          best = scored.max_by { |s, _f| s }
          dxf_path = best[1] if best && best[0] > 0
        end

        # 3. If no existing companion DXF was found, attempt automated background DWG-to-DXF conversion
        if dxf_path.nil? || !File.exist?(dxf_path)
          dxf_path = convert_dwg_to_dxf(clean_path)
        end
      end

      if dxf_path && File.exist?(dxf_path)
        puts "QuickDraft: Using CAD survey text source: '#{dxf_path}'"
      else
        puts "QuickDraft: No DXF text source file found for '#{clean_path}'"
        return 0
      end

      text_items = []
      reading_text = false
      in_entities = false
      layer = '0'
      text = ''
      x10 = 0.0; y10 = 0.0; z10 = 0.0
      x11 = 0.0; y11 = 0.0; z11 = 0.0
      height = 0.0
      rotation = 0.0
      has_11 = false
      h_align = 0
      v_align = 0
      code = nil

      File.open(dxf_path, 'r:latin1') do |f|
        f.each_line do |line|
          line = line.strip
          if code.nil?
            code = line
          else
            val = line
            if code == '2' && val == 'ENTITIES'
              in_entities = true
            elsif code == '0' && val == 'ENDSEC'
              in_entities = false
            end

            if in_entities
              if code == '0'
                if reading_text && !text.empty?
                  text_items << {
                    layer: layer,
                    text: text,
                    x: x10,
                    y: y10,
                    z: z10,
                    height: height,
                    rotation: rotation
                  }
                end
                reading_text = (val == 'TEXT' || val == 'MTEXT')
                layer = '0'
                text = ''
                x10 = 0.0; y10 = 0.0; z10 = 0.0
                x11 = 0.0; y11 = 0.0; z11 = 0.0
                height = 0.0
                rotation = 0.0
                has_11 = false
                h_align = 0
                v_align = 0
              elsif reading_text
                case code
                when '8'  then layer = val
                when '3'  then text = text + val
                when '1'  then text = text + val
                when '10' then x10 = val.to_f
                when '20' then y10 = val.to_f
                when '30' then z10 = val.to_f
                when '11' then x11 = val.to_f; has_11 = true
                when '21' then y11 = val.to_f; has_11 = true
                when '31' then z11 = val.to_f
                when '40' then height = val.to_f
                when '50' then rotation = val.to_f
                when '72' then h_align = val.to_i
                when '73' then v_align = val.to_i
                end
              end
            end
            code = nil
          end
        end
      end

      if reading_text && !text.empty? && in_entities
        text_items << {
          layer: layer,
          text: text,
          x: x10,
          y: y10,
          z: z10,
          height: height,
          rotation: rotation
        }
      end

      if text_items.empty?
        puts 'QuickDraft: No TEXT/MTEXT entities found in DXF.'
        return [nil, 0]
      end

      # Determine scale factor: if DXF coordinates span meters (~500m), scale by 39.37007874
      dxf_xs = text_items.map { |i| i[:x] }
      dxf_span = [(dxf_xs.max - dxf_xs.min).abs, 1.0].max
      scale_factor = (dxf_span < 2000.0) ? 39.37007874015748 : 1.0

      tag_survey = ensure_tag(model, TAG_SURVEY_2D, Sketchup::Color.new(120, 130, 140))
      tag_text   = ensure_tag(model, TAG_SURVEY_TEXT, Sketchup::Color.new(120, 130, 140))
      tag_text.visible = true if tag_text.respond_to?(:visible=)

      cad_text_mat = model.materials['QD_CAD_Text'] || model.materials.add('QD_CAD_Text')
      cad_text_mat.color = Sketchup::Color.new(45, 50, 55)

      # Dedicated text group flat on the 2D site survey layer (Z = 0.0)
      text_group = model.active_entities.add_group
      text_group.name = 'Site_Survey_Text'
      text_group.layer = tag_survey # Assigned to 2D survey tag so it stays strictly on the 2D layer

      text_count = 0
      text_items.each do |item|
        lay = item[:layer].to_s.upcase
        # Keep all CAD survey text: road names, water channel, adjacent lots, dwelling labels,
        # tree table, spot elevations, and legend. Only skip raw numeric surveyor point IDs.
        next if lay.end_with?('_NUM') || lay == 'POINTNUMBER' || lay == 'BORDER' || lay == '0'

        # Filter out survey points/elevations that fall geographically under the Tree Table
        # (In CAD, monument 214 / 22.31 OCM sits at (926.3, 376.5) which falls inside the Tree Table sheet area)
        if item[:x] >= 914.0 && item[:x] <= 928.5 && item[:y] >= 374.0 && item[:y] <= 445.0 && lay != 'TEXT'
          next
        end

        raw_txt = item[:text].to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        raw_txt = raw_txt.gsub(/%%[uU]/, '')
        raw_txt = raw_txt.gsub(/%%[pP]/, '+/-')
        raw_txt = raw_txt.gsub(/%%[dD]/, "\u00B0")
        raw_txt = raw_txt.gsub(/%%[cC]/, "\u00D8")
        raw_txt = raw_txt.gsub(/\\[Pp]/, ' ')
        raw_txt = raw_txt.gsub(/\\A\d+;/, '')
        raw_txt = raw_txt.gsub(/\\H[\d\.]+x;/, '')
        raw_txt = raw_txt.gsub(/\\W[\d\.]+;/, '')
        raw_txt = raw_txt.gsub(/\\Q[\d\.]+;/, '')
        raw_txt = raw_txt.gsub(/\\C\d+;/, '')
        raw_txt = raw_txt.gsub(/\\f[^\;]+;/, '')
        raw_txt = raw_txt.gsub(/\{|\}/, '')
        raw_txt = raw_txt.strip
        next if raw_txt.empty?

        x_scaled = item[:x] * scale_factor
        y_scaled = item[:y] * scale_factor

        # Filter out distant off-site surveyor tie shots (>45m / 1,772" outside property boundary)
        # Keeps all drawing sheet content (Tree Table, Title Block, adjacent lots, Lands End Road, Satellite Channel)
        # while cleanly excluding neighbour's house eaves/peaks 120m away
        if norm_data && norm_data[:prop_box]
          pb = norm_data[:prop_box]
          margin = (45.respond_to?(:m) ? 45.m : 1771.65)
          next if x_scaled < (pb.min.x - margin) || x_scaled > (pb.max.x + margin) ||
                  y_scaled < (pb.min.y - margin) || y_scaled > (pb.max.y + margin)
        end

        shift_x = norm_data ? (norm_data[:center_x] || 0.0) : 0.0
        shift_y = norm_data ? (norm_data[:center_y] || 0.0) : 0.0

        target_x = x_scaled - shift_x
        target_y = y_scaled - shift_y

        # Flat 2D CAD text height in inches
        letter_h = (item[:height] && item[:height] > 0.01) ? (item[:height] * scale_factor) : 10.0
        letter_h = [[letter_h, 6.0].max, 36.0].min

        rot_deg = item[:rotation] || 0.0
        rot_rad = rot_deg * Math::PI / 180.0

        # Create flat 2D geometry text lying flat on the Z = 0 plane
        # Unlike Sketchup::Text billboards, add_3d_text with extrusion=0.0 stays strictly flat on the 2D CAD layer
        # Signature: add_3d_text(string, align, font, bold, italic, height, tolerance, z, filled, extrusion)
        begin
          sub = text_group.entities.add_group
          sub.name = raw_txt
          sub.layer = tag_survey
          sub.material = cad_text_mat

          sub.entities.add_3d_text(raw_txt, 0, 'Arial', false, false, letter_h, 0.0, 0.0, true, 0.0)

          tr_rot = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), rot_rad)
          tr_pos = Geom::Transformation.translation(Geom::Vector3d.new(target_x, target_y, 0.0))
          sub.transformation = tr_pos * tr_rot

          text_count += 1
        rescue StandardError => _e
          # Fallback to sanitized ASCII
          begin
            ascii_txt = raw_txt.encode('ASCII', invalid: :replace, undef: :replace, replace: '')
            next if ascii_txt.empty?
            sub = text_group.entities.add_group
            sub.name = ascii_txt
            sub.layer = tag_survey
            sub.material = cad_text_mat
            sub.entities.add_3d_text(ascii_txt, 0, 'Arial', false, false, letter_h, 0.0, 0.0, true, 0.0)
            tr_rot = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), rot_rad)
            tr_pos = Geom::Transformation.translation(Geom::Vector3d.new(target_x, target_y, 0.0))
            sub.transformation = tr_pos * tr_rot
            text_count += 1
          rescue StandardError => e2
            puts "QuickDraft Text Error on '#{raw_txt}': #{e2.message}"
          end
        end
      end

      puts "QuickDraft: Successfully imported #{text_count} CAD survey text annotations on '#{TAG_SURVEY_2D}'"
      [text_group, text_count]
    end

    def self.analyze_survey_entities(survey_group)
      stats = {}

      inspect_entities = lambda do |entities, current_tr|
        entities.each do |ent|
          layer_name = (ent.respond_to?(:layer) && ent.layer) ? ent.layer.name : nil
          next if layer_name.nil? || layer_name.empty? || layer_name == 'Layer0' || layer_name == 'Untagged' || layer_name == TAG_SURVEY_2D || layer_name == TAG_SURVEY_TEXT

          stats[layer_name] ||= {
            name: layer_name,
            points: 0,
            edges: 0,
            texts: 0,
            numeric_texts: 0,
            instances: 0,
            circles: 0,
            sample_text: nil,
            min_z: 1e12,
            max_z: -1e12,
            min_pos_z: 1e12
          }

          item = stats[layer_name]

          if ent.is_a?(Sketchup::ConstructionPoint)
            item[:points] += 1
            z = ent.position.transform(current_tr).z
            item[:min_z] = [item[:min_z], z].min
            item[:max_z] = [item[:max_z], z].max
            item[:min_pos_z] = [item[:min_pos_z], z].min if z > 0.1
          elsif ent.is_a?(Sketchup::Edge)
            if ent.curve.is_a?(Sketchup::ArcCurve)
              item[:circles] += 1
            else
              item[:edges] += 1
            end
            z1 = ent.start.position.transform(current_tr).z
            z2 = ent.end.position.transform(current_tr).z
            item[:min_z] = [item[:min_z], z1, z2].min
            item[:max_z] = [item[:max_z], z1, z2].max
            item[:min_pos_z] = [item[:min_pos_z], z1].min if z1 > 0.1
            item[:min_pos_z] = [item[:min_pos_z], z2].min if z2 > 0.1
          elsif ent.is_a?(Sketchup::Text)
            item[:texts] += 1
            item[:sample_text] ||= ent.text
            item[:numeric_texts] += 1 if ent.text =~ /^[0-9]+(\.[0-9]+)?$/
          elsif ent.is_a?(Sketchup::ComponentInstance)
            item[:instances] += 1
            z = ent.bounds.center.transform(current_tr).z
            item[:min_z] = [item[:min_z], z].min
            item[:max_z] = [item[:max_z], z].max
            item[:min_pos_z] = [item[:min_pos_z], z].min if z > 0.1
          elsif ent.is_a?(Sketchup::Group)
            if ent.bounds.diagonal < 36.0
              item[:instances] += 1
              z = ent.bounds.center.transform(current_tr).z
              item[:min_z] = [item[:min_z], z].min
              item[:max_z] = [item[:max_z], z].max
              item[:min_pos_z] = [item[:min_pos_z], z].min if z > 0.1
            end
            inspect_entities.call(ent.entities, current_tr * ent.transformation)
          end
        end
      end

      inspect_entities.call(survey_group.entities, survey_group.transformation)

      utility_patterns = %w[
        gas hydro water sewer drain storm util fhyd valve meter pole cb
        fence bdr border title text legend note arrow vport defpoints grid
      ]

      classified_layers = []
      best_contours = []
      best_property = []
      best_trees    = []
      best_paved    = []
      best_building = []
      ignored_utilities = []

      stats.each_value do |info|
        raw_name = info[:name]
        lname = raw_name.downcase.strip
        clean_name = lname.sub(/^[._\-]+/, '')

        is_building_layer = (
          (clean_name =~ /^(b_lines|deck_lines|stairs_line|dwelling|building|house)$/i ||
           clean_name =~ /^(b|dwelling|building|house)(_lines?|_line)?$/i) &&
          clean_name !~ /(symb|sym|point|pt|elev|num|des|text|tank)/i
        )

        is_elevation_layer = !is_building_layer && (
          (clean_name =~ /(^|_|\.)elev/i && clean_name !~ /(symb|sym|text|desc|des|num|line)/i) ||
          (clean_name =~ /(^|_|\.)spot/i && clean_name !~ /(symb|sym|text|desc|des|num|line)/i) ||
          clean_name =~ /^(s|dway|tbank|tslope|asph|th|ms)_(point|pt)$/i ||
          clean_name == 'mspoint' || clean_name == 'ms_point' ||
          clean_name == 's_point' || clean_name == 'dway_point' ||
          clean_name == 'tbank_point' || clean_name == 'tslope_pt' ||
          clean_name == 'asph_point' || clean_name == 'th_point'
        )
        is_tree_layer = (
          clean_name =~ /^tr(arb|ced|fir|fruit|map|willow|yew|tree|oak|pine|alder|plum|cherry)/i ||
          clean_name.start_with?('tree') ||
          clean_name.start_with?('arbor')
        )
        is_prop_layer  = !is_building_layer && (clean_name =~ /^oip(_lines)?/i || clean_name.include?('nbound') || clean_name.include?('nb plan') || clean_name.include?('adj lot'))
        is_paved_layer = clean_name =~ /(^|_|\.)(dway|driveway|asph|asphalt|pave|paving|road)/i && clean_name !~ /elev|point|num|pt|symb|sym/i

        is_utility = utility_patterns.any? { |pat| clean_name.include?(pat) || lname.include?(pat) }
        is_utility = false if is_elevation_layer || is_tree_layer || is_prop_layer || is_paved_layer || is_building_layer

        if is_building_layer
          if info[:edges] > 0 || clean_name =~ /lines?$/
            best_building << info[:name]
          end
          info[:category] = 'building'
          info[:score] = 100
          classified_layers << info
          next
        end

        if is_utility
          ignored_utilities << info[:name]
          info[:category] = 'utility'
          info[:score] = -100
          classified_layers << info
          next
        end

        # Scoring for Topo & Spot Elevations
        topo_score = 0
        if is_elevation_layer
          topo_score += 200
        elsif clean_name =~ /^(spot|topo|contour|gnd|ground|tin)/
          topo_score += 90
        elsif clean_name.include?('elev') || clean_name.include?('spot') || clean_name.include?('topo')
          topo_score += 70
        end
        topo_score += 35 if info[:numeric_texts] > 5
        topo_score += 25 if info[:points] > 5
        topo_score += 20 if (info[:max_z] - info[:min_z]).abs > 5.0

        # Scoring for Trees & Arborist Inventory (Strictly restricted to actual tree species layers)
        tree_score = 0
        if is_tree_layer
          tree_score += 200
          tree_score += 40 if (info[:instances] + info[:circles]) > 0
          tree_score += 30 if info[:sample_text] =~ /tag/i
        end

        # Scoring for Legal Property Boundary
        prop_score = 0
        if clean_name == 'oip_lines' || clean_name =~ /^oip_line/i
          prop_score += 200
        elsif clean_name == 'nbound_line' || clean_name =~ /^nbound/i
          prop_score += 190
        elsif clean_name.include?('nb plan') || clean_name.include?('natural bound') || clean_name.include?('bdy')
          prop_score += 180
        elsif clean_name == 'prop' || lname == '.prop' || clean_name.start_with?('prop_') || clean_name == 'property'
          prop_score += 150
        elsif clean_name =~ /^(lot_line|bnd|bound|legal|pin)/
          prop_score += 80
        elsif clean_name.include?('property') || clean_name == 'lot'
          prop_score += 60
        end
        prop_score += 20 if info[:edges] > 3 && info[:points] == 0

        # Scoring for Driveway & Asphalt Linework (prioritize private DWAY_LINE over public road ASPH_LINE)
        paved_score = 0
        if clean_name =~ /(^|_|\.)(dway|driveway)/i
          paved_score += 260
        elsif clean_name =~ /(^|_|\.)(asph|asphalt|road|pave|curb)/i
          paved_score += 140
        end

        if paved_score > 50 && info[:edges] > 0
          best_paved << info[:name]
        end

        # Assign best match
        max_s = [topo_score, tree_score, prop_score].max
        if max_s > 30
          if max_s == topo_score
            best_contours << info[:name]
            info[:category] = 'topo'
          elsif max_s == tree_score
            best_trees << info[:name]
            info[:category] = 'tree'
          elsif max_s == prop_score
            best_property << info[:name]
            info[:category] = 'property'
          end
        else
          info[:category] = 'other'
        end

        info[:score] = [max_s, paved_score].max
        classified_layers << info
      end

      # Fallbacks
      if best_contours.empty?
        candidate = classified_layers.find { |l| l[:category] != 'utility' && (l[:points] > 0 || l[:numeric_texts] > 0) }
        best_contours << candidate[:name] if candidate
      end
      if best_property.empty?
        candidate = classified_layers.find { |l| l[:name].downcase =~ /line/ && l[:category] != 'utility' }
        best_property << candidate[:name] if candidate
      end
      if best_trees.empty?
        candidate = classified_layers.find { |l| l[:name].downcase =~ /^tr/ || l[:name].downcase.include?('tree') }
        best_trees << candidate[:name] if candidate
      end

      # Include all detected paved/asphalt/driveway layers (e.g. DWAY_LINE, ASPH_LINE)

      {
        layers: classified_layers.sort_by { |l| -l[:score] },
        all_layer_names: stats.keys.sort,
        best_contours: best_contours,
        best_property: best_property,
        best_trees: best_trees,
        best_paved: best_paved,
        best_building: best_building,
        ignored_utilities: ignored_utilities.sort
      }
    end

    def self.show_mapping_dialog(model, survey_group, analysis, path, raw_w, raw_h, min_z, _max_z)
      guessed_contours = analysis[:best_contours]
      guessed_property = analysis[:best_property]
      guessed_trees    = analysis[:best_trees]
      guessed_paved    = analysis[:best_paved] || []
      guessed_building = analysis[:best_building] || []

      needs_metric = (raw_w < 500.0 && raw_h < 500.0)

      # Dynamically compute geodetic benchmark datum from real positive 3D survey points (excluding flat 2D lines at Z=0)
      topo_layers = analysis[:layers].select { |l| (l[:category] == 'topo' || l[:name] =~ /point|pt|spot/i) && l[:min_pos_z] && l[:min_pos_z] < 1e11 }
      min_topo_z_in = topo_layers.map { |l| l[:min_pos_z] }.min

      if min_topo_z_in && min_topo_z_in < 1e11
        # Model units in SketchUp are always inches; convert lowest 3D topo point to meters
        benchmark_m = (min_topo_z_in / 39.37007874015748).round(2)
      else
        benchmark_m = (min_z > 0 && min_z < 100) ? min_z.round(2) : 0.0
      end

      dialog = UI::HtmlDialog.new(
        dialog_title: 'QuickDraft: Automated Survey Intelligence',
        preferences_key: 'QuickDraft_Survey_Mapping',
        scrollable: true,
        resizable: true,
        width: 660,
        height: 780,
        min_width: 520,
        min_height: 560
      )

      html = generate_mapping_html(
        analysis,
        guessed_contours,
        guessed_property,
        guessed_trees,
        guessed_paved,
        guessed_building,
        needs_metric,
        benchmark_m,
        raw_w.round(1),
        raw_h.round(1)
      )
      dialog.set_html(html)

      dialog.add_action_callback('process_mapping') do |_context, data|
        dialog.close

        contour_layers  = data['contours'] || []
        property_layers = data['property'] || []
        tree_layers     = data['trees'] || []
        paved_layers    = data['paved'] || []
        building_layers = data['building'] || guessed_building || []
        unit_scale_mode = data['unit_scale_mode'] || 'as_imported'
        geodetic_datum_m = (data['geodetic_datum_m'] || benchmark_m).to_f

        model.start_operation('Build Automated 3D Site Pipeline', true)
        begin
          # Ensure all existing model layers are visible to avoid hidden geometry collision warnings
          model.layers.each { |l| l.visible = true if l.respond_to?(:visible=) }

          apply_unit_scaling(model, survey_group, unit_scale_mode)
          norm_data = normalize_site_origin(model, survey_group, path, geodetic_datum_m, property_layers)
          pipeline_res = process_survey_pipeline(model, survey_group, contour_layers, property_layers, tree_layers, paved_layers, path, norm_data, building_layers)
          terrain_group = pipeline_res.is_a?(Hash) ? pipeline_res[:terrain_group] : nil
          raw_lot_group = pipeline_res.is_a?(Hash) ? pipeline_res[:raw_lot_group] : nil
          trees_group   = pipeline_res.is_a?(Hash) ? pipeline_res[:trees_group] : nil
          text_group    = pipeline_res.is_a?(Hash) ? pipeline_res[:text_group] : nil

          # Ensure the master 'Site-All' and 'Terrain' tags exist
          tag_site_all = ensure_tag(model, TAG_SITE_ALL, Sketchup::Color.new(30, 110, 180))
          tag_site_all.visible = true if tag_site_all.respond_to?(:visible=)

          tag_terrain = ensure_tag(model, 'Terrain', Sketchup::Color.new(160, 190, 140))
          tag_terrain.visible = true if tag_terrain.respond_to?(:visible=)

          # Nest all generated site groups into the master container group 'Site_All' on tag 'Site-All'
          valid_groups = [survey_group, terrain_group, raw_lot_group, trees_group, text_group].compact.select(&:valid?)
          if valid_groups.size >= 1
            master_group = model.active_entities.add_group(valid_groups)
            master_group.name = MASTER_GROUP_NAME
            master_group.layer = tag_site_all
          end

          # Ensure all automated 3D site tags are active and visible in the model
          [TAG_SITE_ALL, 'Terrain', TAG_TERRAIN, TAG_PROPERTY_LINE, TAG_TREES, TAG_SURVEY_2D, TAG_SURVEY_TEXT, TAG_DRIVEWAY, TAG_BUILDING_FOOTPRINT, TAG_DESIGN_2D].each do |tag_name|
            tag = model.layers[tag_name]
            tag.visible = true if tag && tag.respond_to?(:visible=)
          end

          # Ensure all imported surveyor CAD layers are also visible so linework is never hidden
          model.layers.each do |l|
            l.visible = true if l.respond_to?(:visible=)
          end

          model.commit_operation
          model.active_view.zoom_extents if model.active_view

          terrain_msg = if terrain_group && terrain_group.valid?
                          "✓ 3D Unified Site Terrain (TIN, Stamped Driveway & Foundation) active on: '#{TAG_TERRAIN}'"
                        else
                          "⚠ 3D TIN Terrain could not be generated from: #{contour_layers.join(', ')}"
                        end

          raw_lot_msg = if raw_lot_group && raw_lot_group.valid?
                          e_count = raw_lot_group.entities.grep(Sketchup::Edge).size
                          "✓ Clean 2D Raw Lot Linework (#{e_count} lines) active on: '#{TAG_DESIGN_2D}'"
                        else
                          "✓ Clean 2D Raw Lot Linework active on: '#{TAG_DESIGN_2D}'"
                        end

          UI.messagebox("QuickDraft Automated Site Pipeline Complete!\n\n" \
                        "✓ Combined Site Model active on master tag: '#{TAG_SITE_ALL}' (or 'Terrain')\n" \
                        "#{terrain_msg}\n" \
                        "✓ Stamped Driveway Asphalt active on tag: '#{TAG_DRIVEWAY}'\n" \
                        "✓ Stamped Building Footprint active on tag: '#{TAG_BUILDING_FOOTPRINT}'\n" \
                        "✓ Draped Property Lines active on tag: '#{TAG_PROPERTY_LINE}'\n" \
                        "#{raw_lot_msg}\n" \
                        "✓ 2D Site Plan Linework active on tag: '#{TAG_SURVEY_2D}'\n" \
                        "✓ 2D CAD Survey Text active on tag: '#{TAG_SURVEY_TEXT}'\n" \
                        "✓ Existing trees mapped from: #{tree_layers.join(', ')}\n" \
                        "✓ Geodetic sea-level benchmark: #{geodetic_datum_m} m\n\n" \
                        "All site elements combined into '#{MASTER_GROUP_NAME}' on tag '#{TAG_SITE_ALL}'.")
        rescue StandardError => e
          model.abort_operation
          UI.messagebox("Error processing survey layers:\n\n#{e.message}\n\n#{e.backtrace.first(3).join("\n")}")
        end
      end

      dialog.add_action_callback('cancel_mapping') do |_context|
        dialog.close
      end

      dialog.center
      dialog.show
    end

    def self.rebuild_current_site(model = Sketchup.active_model)
      return unless model

      # Exit any open group editing session to avoid merging into parent context
      model.close_active while model.active_path

      dict = model.attribute_dictionary(DICT_SITE_DATA)
      path = dict ? dict['dwg_path'] : nil
      unless path && File.exist?(path.to_s)
        run
        return
      end

      contour_layers  = (dict['contour_layers']  || '').split(';').reject(&:empty?)
      property_layers = (dict['property_layers'] || '').split(';').reject(&:empty?)
      tree_layers     = (dict['tree_layers']     || '').split(';').reject(&:empty?)
      paved_layers    = (dict['paved_layers']    || '').split(';').reject(&:empty?)
      building_layers = (dict['building_layers'] || '').split(';').reject(&:empty?)
      unit_scale_mode = dict['unit_scale_mode']  || 'as_imported'
      geodetic_datum_m = (dict['geodetic_datum_m'] || 0.0).to_f

      clear_previous_generated_site(model)
      survey_group = import_and_isolate_cad(model, path)
      unless survey_group && survey_group.valid?
        UI.messagebox("Failed to re-import CAD survey from:\n#{path}")
        return
      end

      model.start_operation('Rebuild 3D Site Pipeline', true)
      begin
        model.layers.each { |l| l.visible = true if l.respond_to?(:visible=) }
        apply_unit_scaling(model, survey_group, unit_scale_mode)
        norm_data = normalize_site_origin(model, survey_group, path, geodetic_datum_m, property_layers)
        pipeline_res = process_survey_pipeline(model, survey_group, contour_layers, property_layers, tree_layers, paved_layers, path, norm_data, building_layers)

        terrain_group = pipeline_res.is_a?(Hash) ? pipeline_res[:terrain_group] : nil
        raw_lot_group = pipeline_res.is_a?(Hash) ? pipeline_res[:raw_lot_group] : nil
        trees_group   = pipeline_res.is_a?(Hash) ? pipeline_res[:trees_group] : nil
        text_group    = pipeline_res.is_a?(Hash) ? pipeline_res[:text_group] : nil

        tag_site_all = ensure_tag(model, TAG_SITE_ALL, Sketchup::Color.new(30, 110, 180))
        valid_groups = [survey_group, terrain_group, raw_lot_group, trees_group, text_group].compact.select(&:valid?)
        if valid_groups.size >= 1
          master_group = model.active_entities.add_group(valid_groups)
          master_group.name = MASTER_GROUP_NAME
          master_group.layer = tag_site_all
        end

        [TAG_SITE_ALL, 'Terrain', TAG_TERRAIN, TAG_PROPERTY_LINE, TAG_TREES, TAG_SURVEY_2D, TAG_SURVEY_TEXT, TAG_DRIVEWAY, TAG_BUILDING_FOOTPRINT, TAG_DESIGN_2D].each do |tag_name|
          tag = model.layers[tag_name]
          tag.visible = true if tag && tag.respond_to?(:visible=)
        end

        aerial_dict = model.attribute_dictionary('QuickDraft_Aerial')
        if aerial_dict && aerial_dict['image_path'] && File.exist?(aerial_dict['image_path'].to_s)
          w  = aerial_dict['world_width_ft'].to_f
          ox = aerial_dict['offset_x_ft'].to_f
          oy = aerial_dict['offset_y_ft'].to_f
          r  = aerial_dict['rot_deg'].to_f
          reproject_aerial_texture(model, terrain_group, aerial_dict['image_path'].to_s, w, ox, oy, r)
        end

        model.commit_operation
        UI.messagebox("QuickDraft Site Rebuild Complete!\n\nAll building footprints, driveway, and 3D terrain have been re-generated with clean closed geometry.")
      rescue StandardError => e
        model.abort_operation
        UI.messagebox("QuickDraft Rebuild Error:\n\n#{e.message}\n\n#{e.backtrace.first(5).join("\n")}")
      end
    end

    def self.generate_mapping_html(analysis, guessed_contours, guessed_property, guessed_trees, guessed_paved, guessed_building, needs_metric, benchmark_m, w, h)
      layers = analysis[:layers]
      ignored = analysis[:ignored_utilities]

      render_layer_checkboxes = lambda do |selected_list|
        layers.map do |info|
          name = info[:name]
          is_checked = selected_list.include?(name) ? 'checked' : ''
          badge = ''
          if info[:points] > 0
            badge = "<span class='meta-tag'>#{info[:points]} pts</span>"
          elsif info[:instances] > 0 || info[:circles] > 0
            badge = "<span class='meta-tag'>#{info[:instances] + info[:circles]} symbols</span>"
          elsif info[:edges] > 0
            badge = "<span class='meta-tag'>#{info[:edges]} lines</span>"
          elsif info[:numeric_texts] > 0
            badge = "<span class='meta-tag'>#{info[:numeric_texts]} elev labels</span>"
          end

          %(<label class="layer-item"><input type="checkbox" value="#{escape_html(name)}" #{is_checked}> <span>#{escape_html(name)}</span> #{badge}</label>)
        end.join("\n")
      end

      rec_topo     = guessed_contours.empty? ? 'None detected' : guessed_contours.join(', ')
      rec_building = guessed_building.empty? ? 'None detected' : guessed_building.join(', ')
      rec_prop     = guessed_property.empty? ? 'None detected' : guessed_property.join(', ')
      rec_tree     = guessed_trees.empty? ? 'None detected' : guessed_trees.join(', ')
      rec_paved    = guessed_paved.empty? ? 'None detected' : guessed_paved.join(', ')

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
            body { margin: 0; padding: 18px; background: #f8fafc; color: #1e293b; font-size: 13px; }
            h2 { margin-top: 0; margin-bottom: 4px; font-size: 17px; color: #0f172a; font-weight: 600; display: flex; align-items: center; gap: 8px; }
            p.sub { margin-top: 0; margin-bottom: 12px; color: #64748b; font-size: 12px; line-height: 1.4; }

            /* One-Click Banner */
            .rec-banner { background: linear-gradient(135deg, #1e40af, #2563eb); color: #fff; border-radius: 8px; padding: 14px 16px; margin-bottom: 14px; box-shadow: 0 4px 6px -1px rgba(37, 99, 235, 0.2); }
            .rec-header { font-size: 14px; font-weight: 600; margin-bottom: 6px; display: flex; align-items: center; justify-content: space-between; }
            .rec-details { font-size: 12px; line-height: 1.6; opacity: 0.95; }
            .rec-details strong { color: #fef08a; }
            .btn-fast { background: #facc15; color: #854d0e; font-weight: 600; border: none; padding: 9px 16px; border-radius: 6px; cursor: pointer; font-size: 13px; margin-top: 10px; width: 100%; transition: background 0.15s; }
            .btn-fast:hover { background: #eab308; }

            .card { background: #fff; border: 1px solid #e2e8f0; border-radius: 8px; padding: 12px 14px; margin-bottom: 12px; box-shadow: 0 1px 2px rgba(0,0,0,0.03); }
            .card-title { font-weight: 600; font-size: 13px; margin-bottom: 3px; color: #1d4ed8; display: flex; align-items: center; justify-content: space-between; }
            .card-desc { font-size: 11px; color: #64748b; margin-bottom: 8px; }
            .badge { background: #eff6ff; color: #2563eb; font-size: 10px; padding: 2px 7px; border-radius: 999px; font-weight: 500; }
            .meta-tag { background: #f1f5f9; color: #475569; font-size: 10px; padding: 1px 5px; border-radius: 4px; margin-left: auto; }
            .layer-box { max-height: 95px; overflow-y: auto; border: 1px solid #f1f5f9; border-radius: 5px; padding: 6px; background: #f8fafc; }
            .layer-item { display: flex; align-items: center; padding: 3px 4px; font-size: 12px; cursor: pointer; border-radius: 4px; }
            .layer-item:hover { background: #e2e8f0; }
            .layer-item input { margin-right: 8px; }
            .row { display: flex; gap: 12px; align-items: center; }
            .input-group { flex: 1; }
            label.field-lbl { display: block; font-weight: 500; font-size: 11px; color: #334155; margin-bottom: 4px; }
            select, input[type="number"] { width: 100%; padding: 7px 10px; border: 1px solid #cbd5e1; border-radius: 5px; font-size: 12px; background: #fff; }
            .ignored-tag { display: inline-block; background: #f1f5f9; color: #64748b; font-size: 10px; padding: 2px 6px; border-radius: 4px; margin: 2px; }
            .footer { display: flex; justify-content: flex-end; gap: 10px; margin-top: 18px; }
            button.secondary { padding: 9px 18px; border-radius: 6px; font-size: 13px; font-weight: 500; cursor: pointer; border: 1px solid #cbd5e1; background: #fff; color: #334155; }
            button.primary { padding: 9px 18px; border-radius: 6px; font-size: 13px; font-weight: 500; cursor: pointer; border: none; background: #2563eb; color: #fff; }
          </style>
        </head>
        <body>
          <h2>⚡ Automated Survey Intelligence</h2>
          <p class="sub">QuickDraft analyzed your CAD file, filtered out #{ignored.size} non-site utilities (hydrants, gas, water, fences, text borders), and mapped the essential site layers.</p>

          <!-- One-Click Fast Execution Banner -->
          <div class="rec-banner">
            <div class="rec-header">
              <span>Automated Best Recommendation</span>
              <span style="font-size: 11px; background: rgba(255,255,255,0.2); padding: 2px 8px; border-radius: 4px;">100% Match</span>
            </div>
            <div class="rec-details">
              <div>▲ <strong>Elevation / Topo:</strong> #{rec_topo}</div>
              <div>⌂ <strong>Dwelling / Building:</strong> #{rec_building}</div>
              <div>☖ <strong>Property Boundary:</strong> #{rec_prop}</div>
              <div>🌲 <strong>Arborist Trees:</strong> #{rec_tree}</div>
              <div>🛣️ <strong>Paved Surfaces:</strong> #{rec_paved}</div>
            </div>
            <button class="btn-fast" onclick="submitMapping()">⚡ One-Click Build 3D Site Pipeline</button>
          </div>

          <div class="card">
            <div class="card-title">
              <span>Drawing Units & Geodetic Sea-Level Datum</span>
              <span class="badge">CAD span: #{w} × #{h}</span>
            </div>
            <div class="row">
              <div class="input-group">
                <label class="field-lbl">CAD Units Scale</label>
                <select id="unit-scale-mode">
                  <option value="as_imported" selected>As-Imported 1:1 (Matches Full CAD Coordinates)</option>
                  <option value="scale_metric" #{needs_metric ? 'selected' : ''}>Scale CAD Meters → Inches (× 39.37)</option>
                  <option value="scale_feet">Scale CAD Feet → Inches (× 12.0)</option>
                </select>
              </div>
              <div class="input-group">
                <label class="field-lbl">Geodetic Datum (m)</label>
                <input type="number" id="geodetic-datum" step="0.01" value="#{benchmark_m}">
              </div>
            </div>
          </div>

          <!-- Layer Overrides -->
          <div class="card">
            <div class="card-title">1. Topo & Spot Elevations</div>
            <div class="card-desc">Detected elevation points, contour curves, and numeric spot tags.</div>
            <div class="layer-box" id="box-contours">
              #{render_layer_checkboxes.call(guessed_contours)}
            </div>
          </div>

          <div class="card">
            <div class="card-title">2. Property / Lot Boundary Lines</div>
            <div class="card-desc">Detected legal boundary lines, iron post pins, and parcel limits.</div>
            <div class="layer-box" id="box-property">
              #{render_layer_checkboxes.call(guessed_property)}
            </div>
          </div>

          <div class="card">
            <div class="card-title">3. Existing Arborist Trees</div>
            <div class="card-desc">Detected survey tree symbols, trunk circles, and arborist tag markers.</div>
            <div class="layer-box" id="box-trees">
              #{render_layer_checkboxes.call(guessed_trees)}
            </div>
          </div>

          <div class="card">
            <div class="card-title">4. Driveway & Road Linework (3D Paved Asphalt)</div>
            <div class="card-desc">Detected driveway and road edge lines; drapes onto 3D terrain and textures with dark asphalt.</div>
            <div class="layer-box" id="box-paved">
              #{render_layer_checkboxes.call(guessed_paved)}
            </div>
          </div>

          <div class="card">
            <div class="card-title">5. Dwelling / Building Footprint</div>
            <div class="card-desc">Detected existing house walls, bays, decks, and stairs; drapes 3D foundation outlines onto terrain.</div>
            <div class="layer-box" id="box-building">
              #{render_layer_checkboxes.call(guessed_building)}
            </div>
          </div>

          <!-- Ignored Utilities List -->
          <div class="card" style="background: #fafafa;">
            <div class="card-title" style="color: #64748b; font-size: 11px;">
              <span>Filtered Non-Site Utilities (#{ignored.size} layers ignored)</span>
            </div>
            <div style="max-height: 45px; overflow-y: auto;">
              #{ignored.map { |l| %(<span class="ignored-tag">#{escape_html(l)}</span>) }.join(' ')}
            </div>
          </div>

          <div class="footer">
            <button class="secondary" onclick="sketchup.cancel_mapping()">Cancel</button>
            <button class="primary" onclick="submitMapping()">Generate 3D Site Pipeline</button>
          </div>

          <script>
            function getChecked(boxId) {
              const box = document.getElementById(boxId);
              const inputs = box.querySelectorAll('input[type="checkbox"]:checked');
              return Array.from(inputs).map(i => i.value);
            }

            function submitMapping() {
              const data = {
                contours: getChecked('box-contours'),
                property: getChecked('box-property'),
                trees: getChecked('box-trees'),
                paved: getChecked('box-paved'),
                building: getChecked('box-building'),
                unit_scale_mode: document.getElementById('unit-scale-mode').value,
                geodetic_datum_m: parseFloat(document.getElementById('geodetic-datum').value) || 0.0
              };
              sketchup.process_mapping(data);
            }
          </script>
        </body>
        </html>
      HTML
    end

    def self.escape_html(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
    end

    # =========================================================================
    # Unit Scaling
    # =========================================================================
    def self.apply_unit_scaling(model, survey_group, unit_scale_mode)
      case unit_scale_mode
      when 'scale_metric'
        scale_factor = (1.respond_to?(:m) ? 1.m.to_f : 39.37007874015748)
        scale_tr = Geom::Transformation.scaling(scale_factor)
        survey_group.transform!(scale_tr)
      when 'scale_feet'
        scale_tr = Geom::Transformation.scaling(12.0)
        survey_group.transform!(scale_tr)
      end
    end

    # =========================================================================
    # Site Normalization & Real-World Geodetic Datum Storage
    # =========================================================================
    def self.normalize_site_origin(model, survey_group, path, geodetic_datum_m, property_layers = [], protected_layers = [])
      prop_box = get_property_bounds(survey_group, property_layers)
      target_box = (prop_box && !prop_box.empty?) ? prop_box : survey_group.bounds

      if target_box.empty?
        raise 'Imported survey contains an empty bounding box.'
      end

      # Flatten any drafting scale bar lines or text blocks erroneously placed at 419m elevation down to Z = 0.0
      to_flatten = []
      survey_group.entities.grep(Sketchup::Edge).each do |edge|
        next unless edge.valid?
        begin
          if edge.start.position.z > 3000.0 || edge.end.position.z > 3000.0
            p1 = Geom::Point3d.new(edge.start.position.x, edge.start.position.y, 0.0)
            p2 = Geom::Point3d.new(edge.end.position.x, edge.end.position.y, 0.0)
            to_flatten << [edge, p1, p2]
          end
        rescue StandardError
          # Ignore if edge reference became invalid
        end
      end

      to_flatten.each do |edge, p1, p2|
        survey_group.entities.add_line(p1, p2) rescue nil
        edge.erase! if edge.valid? rescue nil
      end

      center_x = (target_box.min.x + target_box.max.x) / 2.0
      center_y = (target_box.min.y + target_box.max.y) / 2.0

      translation = Geom::Transformation.translation(Geom::Vector3d.new(-center_x, -center_y, 0))
      survey_group.transform!(translation)

      # Cull distant off-site surveyor regional traverse tie lines, monuments, and shots
      # so the bounding box of Site_Survey_2D tightly frames the actual drawing sheet.
      # NEVER cull lines on protected property or design layers.
      half_w = target_box.width * 0.5
      half_h = target_box.height * 0.5
      sheet_min_x = -[half_w + 1500.0, 3000.0].max
      sheet_max_x =  [half_w + 1500.0, 3000.0].max
      sheet_min_y = -[half_h + 2000.0, 4000.0].max
      sheet_max_y =  [half_h + 1500.0, 3500.0].max
      cull_offsite_survey_entities(survey_group, sheet_min_x, sheet_max_x, sheet_min_y, sheet_max_y, property_layers)

      dict = model.attribute_dictionary(DICT_SITE_DATA, true)
      dict['easting_offset']    = center_x.to_f
      dict['northing_offset']   = center_y.to_f
      dict['datum_z_min']       = target_box.min.z.to_f
      dict['datum_z_max']       = target_box.max.z.to_f
      dict['geodetic_datum_m']  = geodetic_datum_m
      dict['geodetic_datum_ft'] = (geodetic_datum_m * 3.280839895).round(3)
      dict['is_geodetic']       = true
      dict['dwg_path']          = path
      dict['dwg_filename']      = File.basename(path)
      dict['imported_at']       = Time.now.to_s
      dict['unit']              = 'inches'

      buffer = (prop_box && !prop_box.empty?) ? [[prop_box.width, prop_box.height].max * 0.5, 1575.0].max : 1575.0

      {
        center_x: center_x,
        center_y: center_y,
        prop_box: prop_box,
        buffer: buffer
      }
    end

    def self.cull_offsite_survey_entities(survey_group, min_x, max_x, min_y, max_y, property_layers = [])
      return unless survey_group && survey_group.valid?

      # Explode any nested ComponentInstances so all entities become accessible
      loop do
        instances = survey_group.entities.grep(Sketchup::ComponentInstance)
        break if instances.empty?
        instances.each do |inst|
          next unless inst.valid?
          inst.explode rescue nil
        end
      end

      tr = survey_group.transformation
      to_erase = []

      is_property_layer = lambda do |layer_name|
        return false if layer_name.nil? || layer_name.empty?
        return true if property_layers && property_layers.include?(layer_name)
        return true if layer_name =~ /oip|nbound|bound.*line/i
        false
      end

      check_entities = lambda do |entities, current_tr, parent_layer_name|
        entities.each do |e|
          next unless e.valid?
          ent_layer = (e.respond_to?(:layer) && e.layer) ? e.layer.name.to_s : nil
          eff_layer = (ent_layer && ent_layer != '0' && ent_layer.downcase != 'layer0') ? ent_layer : parent_layer_name

          # NEVER erase genuine property boundary lines
          next if is_property_layer.call(eff_layer)

          if e.is_a?(Sketchup::Edge)
            p1 = e.start.position.transform(current_tr)
            p2 = e.end.position.transform(current_tr)
            if (p1.x < min_x || p1.x > max_x || p1.y < min_y || p1.y > max_y) ||
               (p2.x < min_x || p2.x > max_x || p2.y < min_y || p2.y > max_y)
              to_erase << e
            end
          elsif e.is_a?(Sketchup::ConstructionPoint)
            p = e.position.transform(current_tr)
            if p.x < min_x || p.x > max_x || p.y < min_y || p.y > max_y
              to_erase << e
            end
          elsif e.is_a?(Sketchup::Text)
            p = e.point.transform(current_tr) rescue nil
            if p && (p.x < min_x || p.x > max_x || p.y < min_y || p.y > max_y)
              to_erase << e
            end
          elsif e.is_a?(Sketchup::ComponentInstance)
            p = e.transformation.origin.transform(current_tr)
            if p.x < min_x || p.x > max_x || p.y < min_y || p.y > max_y
              to_erase << e
            else
              inst_layer = (e.layer && e.layer.name != '0' && e.layer.name.downcase != 'layer0') ? e.layer.name.to_s : parent_layer_name
              check_entities.call(e.definition.entities, current_tr * e.transformation, inst_layer)
            end
          elsif e.is_a?(Sketchup::Group)
            grp_layer = (e.layer && e.layer.name != '0' && e.layer.name.downcase != 'layer0') ? e.layer.name.to_s : parent_layer_name
            check_entities.call(e.entities, current_tr * e.transformation, grp_layer)
          end
        end
      end

      check_entities.call(survey_group.entities, tr, nil)

      to_erase.uniq.each do |ent|
        ent.erase! if ent.valid? rescue nil
      end

      # Clean up any empty groups left behind
      survey_group.entities.grep(Sketchup::Group).each do |grp|
        grp.erase! if grp.valid? && grp.entities.empty? rescue nil
      end

      puts "QuickDraft: Culled #{to_erase.size} distant off-site entities. Site_Survey_2D bounding box tightly framed to drawing sheet."
    end

    def self.get_property_bounds(survey_group, property_layers)
      return nil if property_layers.nil? || property_layers.empty?

      prop_box = Geom::BoundingBox.new
      tr = survey_group.transformation

      collect_prop_pts = lambda do |entities, current_tr, parent_layer|
        entities.each do |entity|
          if entity.is_a?(Sketchup::Edge)
            lname = (entity.layer && entity.layer.name != '0' && entity.layer.name.downcase != 'layer0') ? entity.layer.name : parent_layer
            if lname && property_layers.include?(lname)
              prop_box.add(entity.start.position.transform(current_tr))
              prop_box.add(entity.end.position.transform(current_tr))
            end
          elsif entity.is_a?(Sketchup::Group)
            grp_layer = (entity.layer && entity.layer.name != '0' && entity.layer.name.downcase != 'layer0') ? entity.layer.name : parent_layer
            collect_prop_pts.call(entity.entities, current_tr * entity.transformation, grp_layer)
          elsif entity.is_a?(Sketchup::ComponentInstance)
            inst_layer = (entity.layer && entity.layer.name != '0' && entity.layer.name.downcase != 'layer0') ? entity.layer.name : parent_layer
            collect_prop_pts.call(entity.definition.entities, current_tr * entity.transformation, inst_layer)
          end
        end
      end

      collect_prop_pts.call(survey_group.entities, tr, nil)
      prop_box.empty? ? nil : prop_box
    end

    # =========================================================================
    # Pipeline Execution: Terrain, Lot Lines, Trees, Driveway, Building Footprint
    # =========================================================================
    def self.process_survey_pipeline(model, survey_group, contour_layers, property_layers, tree_layers, paved_layers = [], path = nil, norm_data = nil, building_layers = [])
      dict = model.attribute_dictionary(DICT_SITE_DATA, true)
      dict['contour_layers']  = contour_layers.join(';')
      dict['property_layers'] = property_layers.join(';')
      dict['tree_layers']     = tree_layers.join(';')
      dict['paved_layers']    = paved_layers.join(';')
      dict['building_layers'] = building_layers.join(';')
      dict['unit_scale_mode'] ||= 'as_imported'

      # 1. Build 3D Terrain as a single, clean TIN mesh directly in terrain_group.entities
      terrain_group = build_terrain_mesh(model, survey_group, contour_layers, property_layers)

      # 2. Create Clean 2D Raw Lot Design Layer (Property, Driveway, House) floating above terrain
      raw_lot_group = create_raw_lot_design_2d(model, survey_group, property_layers, paved_layers, building_layers, terrain_group)

      # 3. Drape Linework & Features directly from Site_Raw_Lot_Design_2D onto Site_Terrain
      bldg_polys = drape_from_site_design_2d(model, terrain_group, raw_lot_group)

      # 4. Place Tree Proxies (Filtered to property boundary buffer and excluding building footprints)
      trees_group = place_tree_proxies(model, survey_group, tree_layers, terrain_group, property_layers, bldg_polys)

      # 5. Import CAD survey text annotations integrated at normalized site coordinates
      text_res = import_cad_text(model, survey_group, path, norm_data)
      text_group = text_res.is_a?(Array) ? text_res[0] : nil
      text_count = text_res.is_a?(Array) ? text_res[1] : text_res.to_i

      # 6. Move all floating 3D CAD ConstructionPoints onto a dedicated hidden tag for clean LayOut 2D views
      tag_pts = ensure_tag(model, TAG_SURVEY_POINTS, Sketchup::Color.new(150, 150, 150))
      move_cpoints = lambda do |ents, visited_defs = {}|
        ents.each do |ent|
          if ent.is_a?(Sketchup::ConstructionPoint)
            ent.layer = tag_pts
          elsif ent.is_a?(Sketchup::Group)
            move_cpoints.call(ent.entities, visited_defs)
          elsif ent.is_a?(Sketchup::ComponentInstance) && ent.definition && !visited_defs[ent.definition.object_id]
            visited_defs[ent.definition.object_id] = true
            move_cpoints.call(ent.definition.entities, visited_defs)
          end
        end
      end
      move_cpoints.call(survey_group.entities)
      tag_pts.visible = false if tag_pts.respond_to?(:visible=)

      {
        terrain_group: terrain_group,
        text_count: text_count,
        raw_lot_group: raw_lot_group,
        trees_group: trees_group,
        text_group: text_group
      }
    end

    def self.build_terrain_mesh(model, survey_group, contour_layers, property_layers = [])
      return nil if contour_layers.empty?

      elevation_points = []
      tr = survey_group.transformation

      collect_elevation_points = lambda do |entities, current_tr|
        entities.each do |entity|
          layer_name = (entity.respond_to?(:layer) && entity.layer) ? entity.layer.name : nil
          on_elevation_layer = layer_name && contour_layers.include?(layer_name)

          # Strictly reject any building, window sill, deck, roof, or foundation points even if passed in contour_layers
          next if layer_name && (
            layer_name.downcase =~ /^(b|deck|sill|peak|eave|stairs|roof|foundation|dwelling|house|tank)_(point|pt|line|lines|symb|sym|elev|num|des)$/i ||
            layer_name.downcase =~ /^(b_lines|b_point|b_symb|deck_lines|deck_point|deck_symb|sill_point|sill_symb|stairs_line|stairs_point|peak_point|eave_point|tank_point|tank_lines)$/i ||
            layer_name.downcase.include?('dwelling') || layer_name.downcase.include?('building') || layer_name.downcase.include?('house')
          )

          if entity.is_a?(Sketchup::ConstructionPoint)
            if on_elevation_layer
              elevation_points << entity.position.transform(current_tr)
            end

          elsif entity.is_a?(Sketchup::Edge)
            if on_elevation_layer
              p1 = entity.start.position.transform(current_tr)
              p2 = entity.end.position.transform(current_tr)
              elevation_points << p1
              elevation_points << p2

              if entity.length < 24.0
                mid_pt = Geom::Point3d.new(
                  (p1.x + p2.x) / 2.0,
                  (p1.y + p2.y) / 2.0,
                  (p1.z + p2.z) / 2.0
                )
                elevation_points << mid_pt
              end
            end

          elsif entity.is_a?(Sketchup::Text)
            if on_elevation_layer
              pt = entity.point.transform(current_tr)
              if pt.z.abs < 0.1 && entity.text =~ /^[\+x]?\s*([0-9]+\.?[0-9]*)$/i
                val = $1.to_f
                val_inches = (val.respond_to?(:m) ? val.m : val * 39.37007874015748)
                pt = Geom::Point3d.new(pt.x, pt.y, val_inches)
              end
              elevation_points << pt
            end

          elsif entity.is_a?(Sketchup::Group)
            if on_elevation_layer && entity.bounds.diagonal < 36.0
              elevation_points << entity.bounds.center.transform(current_tr)
            end
            collect_elevation_points.call(entity.entities, current_tr * entity.transformation)

          elsif entity.is_a?(Sketchup::ComponentInstance)
            if on_elevation_layer && entity.bounds.diagonal < 36.0
              elevation_points << entity.bounds.center.transform(current_tr)
            end
            collect_elevation_points.call(entity.definition.entities, current_tr * entity.transformation)
          end
        end
      end

      collect_elevation_points.call(survey_group.entities, tr)

      # Filter elevation points to a 25 ft (300") perimeter buffer around property boundaries.
      # Captures all perimeter points, road frontage, trees, and top-of-bank,
      # while cleanly omitting off-site traverse hubs (e.g. MSPOINT at X=2000), distant driveways, and off-site manholes.
      prop_box = get_property_bounds(survey_group, property_layers)
      if prop_box && !prop_box.empty?
        min_x = prop_box.min.x - 50.0
        min_y = prop_box.min.y - 600.0
        max_y = prop_box.max.y + 300.0
        road_zone_y = prop_box.min.y + 600.0

        elevation_points.select! do |pt|
          cur_max_x = (pt.y <= road_zone_y) ? (prop_box.max.x + 600.0) : (prop_box.max.x + 150.0)
          pt.x >= min_x && pt.x <= cur_max_x && pt.y >= min_y && pt.y <= max_y
        end
      end

      # Exclude 2D spot points and symbols at or near Z=0 that cause sharp downward spikes
      # Genuine shoreline elevations in BC are >= 0.25m (10 inches); flat CAD symbols sit at 0.0"
      elevation_points.reject! { |pt| pt.z < 10.0 }

      # Extend terrain mesh straight along the West & East side lot lines to meet the front road line
      if prop_box && !prop_box.empty? && elevation_points.size >= 3
        all_prop_segs = []
        collect_prop_segs = lambda do |ents, cur_tr, p_lay = nil|
          ents.each do |ent|
            if ent.is_a?(Sketchup::Edge)
              el = (ent.layer && ent.layer.name != '0' && ent.layer.name.downcase != 'layer0') ? ent.layer.name : p_lay
              if el && property_layers && property_layers.include?(el)
                q1 = ent.start.position.transform(cur_tr)
                q2 = ent.end.position.transform(cur_tr)
                all_prop_segs << [q1, q2] if q1.distance(q2) > 300.0
              end
            elsif ent.is_a?(Sketchup::Group)
              gl = (ent.layer && ent.layer.name != '0' && ent.layer.name.downcase != 'layer0') ? ent.layer.name : p_lay
              collect_prop_segs.call(ent.entities, cur_tr * ent.transformation, gl)
            elsif ent.is_a?(Sketchup::ComponentInstance)
              il = (ent.layer && ent.layer.name != '0' && ent.layer.name.downcase != 'layer0') ? ent.layer.name : p_lay
              collect_prop_segs.call(ent.definition.entities, cur_tr * ent.transformation, il)
            end
          end
        end
        collect_prop_segs.call(survey_group.entities, tr)

        front_segs = all_prop_segs.select { |q1, q2| (q2.x - q1.x).abs > 300.0 }
        front_line = front_segs.min_by { |q1, q2| (q1.y + q2.y) * 0.5 }
        if front_line
          fp1, fp2 = (front_line[0].x <= front_line[1].x) ? [front_line[0], front_line[1]] : [front_line[1], front_line[0]]
          dx = fp2.x - fp1.x
          dy = fp2.y - fp1.y
          len = Math.hypot(dx, dy)
          ux = dx / len; uy = dy / len

          road_depth = 420.0
          nx = uy; ny = -ux
          if ny > 0
            nx = -nx; ny = -ny
          end

          s_pt = Geom::Point3d.new(fp1.x - ux * 250.0 + nx * road_depth, fp1.y - uy * 250.0 + ny * road_depth, 0.0)

          # Build a straight angled East boundary that captures any neighboring front-east driveway
          # and intersect it cleanly with the straight parallel front road line (s_pt -> e_pt).
          east_segs = all_prop_segs.select { |q1, q2| (q2.y - q1.y).abs > 300.0 }
          east_seg = east_segs.max_by { |q1, q2| (q1.x + q2.x) * 0.5 }
          y_top = fp2.y + 600.0
          if east_seg && (east_seg[1].y - east_seg[0].y).abs > 1.0
            t_top = (y_top - east_seg[0].y) / (east_seg[1].y - east_seg[0].y)
            x_top_lot = east_seg[0].x + t_top * (east_seg[1].x - east_seg[0].x)
          else
            x_top_lot = fp2.x
          end
          p_top = Geom::Point3d.new(x_top_lot + 150.0, y_top, 0.0)

          # Find Eastmost front-east driveway point (e.g. DWAY_LINE) if present, else default +600"
          dway_east_pt = nil
          collect_dway_east = lambda do |ents, cur_tr, p_lay = nil|
            ents.each do |ent|
              if ent.is_a?(Sketchup::Edge)
                el = (ent.layer && ent.layer.name != '0' && ent.layer.name.downcase != 'layer0') ? ent.layer.name : p_lay
                if el && el.downcase.include?('dway')
                  [ent.start.position, ent.end.position].each do |vp|
                    wp = vp.transform(cur_tr)
                    if wp.x > fp2.x && wp.y <= fp2.y + 200.0 && wp.y >= fp2.y - 400.0
                      dway_east_pt = wp if dway_east_pt.nil? || wp.x > dway_east_pt.x
                    end
                  end
                end
              elsif ent.is_a?(Sketchup::Group)
                gl = (ent.layer && ent.layer.name != '0' && ent.layer.name.downcase != 'layer0') ? ent.layer.name : p_lay
                collect_dway_east.call(ent.entities, cur_tr * ent.transformation, gl)
              elsif ent.is_a?(Sketchup::ComponentInstance)
                il = (ent.layer && ent.layer.name != '0' && ent.layer.name.downcase != 'layer0') ? ent.layer.name : p_lay
                collect_dway_east.call(ent.definition.entities, cur_tr * ent.transformation, il)
              end
            end
          end
          collect_dway_east.call(survey_group.entities, tr)

          p_mid = if dway_east_pt
            Geom::Point3d.new(dway_east_pt.x + 75.0, dway_east_pt.y, 0.0)
          else
            Geom::Point3d.new(fp2.x + 600.0, fp2.y - 65.0, 0.0)
          end

          # Intersect East angled line (p_top -> p_mid) with front road line (s_pt + t * u)
          ex_dir = p_mid.x - p_top.x
          ey_dir = p_mid.y - p_top.y
          det = ex_dir * (-uy) - ey_dir * (-ux)
          if det.abs > 1e-6
            rhs_x = s_pt.x - p_top.x
            rhs_y = s_pt.y - p_top.y
            s_param = (rhs_x * (-uy) - rhs_y * (-ux)) / det
            e_pt = Geom::Point3d.new(p_top.x + s_param * ex_dir, p_top.y + s_param * ey_dir, 0.0)
          else
            e_pt = Geom::Point3d.new(fp2.x + ux * 650.0 + nx * road_depth, fp2.y + uy * 650.0 + ny * road_depth, 0.0)
          end

          # Clip any existing elevation points below y_top that lie East of the straight angled East line
          if e_pt.y < p_top.y - 1.0
            elevation_points.reject! do |pt|
              if pt.y <= p_top.y
                t_clip = (pt.y - p_top.y) / (e_pt.y - p_top.y)
                max_x_line = p_top.x + t_clip * (e_pt.x - p_top.x)
                pt.x > max_x_line + 1.0
              else
                false
              end
            end
          end

          (0..7).each do |i|
            t = i / 7.0
            ex = s_pt.x + (e_pt.x - s_pt.x) * t
            ey = s_pt.y + (e_pt.y - s_pt.y) * t
            nearest = elevation_points.min_by { |pt| (pt.x - ex)**2 + (pt.y - ey)**2 }
            elevation_points << Geom::Point3d.new(ex, ey, nearest.z) if nearest
          end

          # Anchor West front-lot corner and East angled-line points
          [
            [fp1.x - ux * 250.0, fp1.y - uy * 250.0],
            [p_top.x, p_top.y],
            [p_mid.x, p_mid.y]
          ].each do |ax, ay|
            nearest_a = elevation_points.min_by { |pt| (pt.x - ax)**2 + (pt.y - ay)**2 }
            elevation_points << Geom::Point3d.new(ax, ay, nearest_a.z) if nearest_a
          end
        end
      end

      if elevation_points.size < 3
        puts 'QuickDraft: Insufficient elevation points to triangulate terrain.'
        return nil
      end

      puts "QuickDraft: Triangulating #{elevation_points.size} terrain elevation points..."
      triangles = Delaunay.triangulate(elevation_points)
      if triangles.empty?
        puts 'QuickDraft: Delaunay triangulation returned 0 triangles.'
        return nil
      end
      puts "QuickDraft: Triangulated #{triangles.size} terrain triangles."

      # Cache triangles and points for instant mathematical elevation stamping from above
      @terrain_triangles = triangles
      @terrain_points = elevation_points

      terrain_group = model.active_entities.add_group
      terrain_group.name = TERRAIN_GROUP_NAME
      tag_terrain = ensure_tag(model, TAG_TERRAIN, Sketchup::Color.new(160, 190, 140))
      tag_terrain.visible = true if tag_terrain.respond_to?(:visible=)
      terrain_group.layer = tag_terrain
      terrain_group.visible = true if terrain_group.respond_to?(:visible=)
      terrain_group.hidden = false if terrain_group.respond_to?(:hidden=)

      # Fill 3D TIN mesh directly into terrain_group.entities (single, cohesive mesh)
      # Ensure counter-clockwise winding order for all triangles so normals strictly face UPWARDS (+Z)
      mesh = Geom::PolygonMesh.new(elevation_points.size, triangles.size)
      triangles.each do |tri|
        p1, p2, p3 = tri[0], tri[1], tri[2]
        cross_z = (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x)
        if cross_z < 0
          # Clockwise in XY -> normal points down. Flip winding to ensure upward normal!
          mesh.add_polygon(p1, p3, p2)
        else
          # Counter-clockwise in XY -> normal points up!
          mesh.add_polygon(p1, p2, p3)
        end
      end

      terrain_group.entities.fill_from_mesh(mesh, true, 12)

      mat = model.materials['QD_Site_Terrain'] || model.materials.add('QD_Site_Terrain')
      mat.color = Sketchup::Color.new(225, 235, 220)
      terrain_group.entities.grep(Sketchup::Face).each do |face|
        next unless face.valid?
        # Orient all faces consistently pointing UP into the sky
        face.reverse! if face.normal.z < 0
        face.material = mat
        face.back_material = mat
        face.layer = tag_terrain
      end
      terrain_group.material = nil
      terrain_group.casts_shadows = false if terrain_group.respond_to?(:casts_shadows=)

      terrain_group.entities.grep(Sketchup::Edge).each do |edge|
        next unless edge.valid?
        edge.layer = tag_terrain
        edge.soft = false rescue nil
        edge.smooth = false rescue nil
      end

      terrain_group
    end

    # =========================================================================
    # Clean 2D Raw Lot Design Layer (Floating 10 ft above terrain for drafting)
    # =========================================================================
    def self.create_raw_lot_design_2d(model, survey_group, property_layers, paved_layers, building_layers, terrain_group)
      tag_design = ensure_tag(model, TAG_DESIGN_2D, Sketchup::Color.new(30, 90, 180))
      tag_design.visible = true if tag_design.respond_to?(:visible=)

      design_group = model.active_entities.add_group
      design_group.name = RAW_LOT_GROUP_NAME
      design_group.layer = tag_design
      design_group.visible = true if design_group.respond_to?(:visible=)

      max_z = (terrain_group ? terrain_group.bounds.max.z : 12000.0)
      z_plane = max_z + 120.0 # 10 ft above highest terrain point

      tr = survey_group.transformation

      collect_lines_by_layer = lambda do |entities, current_tr, target_layers, parent_layer_name = nil|
        by_layer = Hash.new { |h, k| h[k] = [] }
        return by_layer if target_layers.nil? || target_layers.empty?

        entities.each do |entity|
          if entity.is_a?(Sketchup::Edge)
            ent_layer = (entity.respond_to?(:layer) && entity.layer) ? entity.layer.name.to_s : nil
            eff_layer = (ent_layer && ent_layer != '0' && ent_layer.downcase != 'layer0') ? ent_layer : parent_layer_name
            # Strictly exclude symbol, elevation point, description, distance, bearing, leader, and text layers
            next if eff_layer =~ /(symb|sym|point|pt|elev|num|des|text|distance|dist|bearing|dim|leader|arrow|label|anno|note)/i
            if eff_layer && target_layers.include?(eff_layer)
              by_layer[eff_layer] << [
                entity.start.position.transform(current_tr),
                entity.end.position.transform(current_tr)
              ]
            end
          elsif entity.is_a?(Sketchup::Group)
            grp_layer = (entity.layer && entity.layer.name != '0' && entity.layer.name.downcase != 'layer0') ? entity.layer.name.to_s : parent_layer_name
            next if grp_layer =~ /(symb|sym|point|pt|elev|num|des|text|cross|mark|tick|distance|dist|bearing|dim|leader|arrow|label|anno|note)/i
            next if entity.bounds.diagonal < 36.0
            sub = collect_lines_by_layer.call(entity.entities, current_tr * entity.transformation, target_layers, grp_layer)
            sub.each { |k, v| by_layer[k].concat(v) }
          elsif entity.is_a?(Sketchup::ComponentInstance)
            inst_layer = (entity.layer && entity.layer.name != '0' && entity.layer.name.downcase != 'layer0') ? entity.layer.name.to_s : parent_layer_name
            def_name = entity.definition.name.to_s.downcase
            # Strictly skip any survey symbol, crosshair, or point marker (e.g. B_SYMB, ICM_UMP, + hash points)
            next if inst_layer =~ /(symb|sym|point|pt|elev|num|des|text|cross|mark|tick|distance|dist|bearing|dim|leader|arrow|label|anno|note)/i || def_name =~ /(symb|sym|point|pt|icm_|ump|marker|cross|tick|arrow|leader)/i
            next if entity.bounds.diagonal < 36.0
            sub = collect_lines_by_layer.call(entity.definition.entities, current_tr * entity.transformation, target_layers, inst_layer)
            sub.each { |k, v| by_layer[k].concat(v) }
          end
        end
        by_layer
      end

      paved_target = paved_layers || []

      if building_layers.nil? || building_layers.empty?
        building_layers = []
        survey_group.entities.each do |e|
          l = e.layer ? e.layer.name : nil
          if l && l.downcase =~ /^(b_lines|deck_lines|stairs_line|dwelling|building)/i && l.downcase !~ /(symb|sym|point|pt|elev|num|des|text|tank)/i
            building_layers << l unless building_layers.include?(l)
          end
        end
      end

      prop_by_layer = collect_lines_by_layer.call(survey_group.entities, tr, property_layers || [], nil)
      paved_by_layer = collect_lines_by_layer.call(survey_group.entities, tr, paved_target, nil)
      bldg_by_layer = collect_lines_by_layer.call(survey_group.entities, tr, building_layers, nil)

      prop_edges = prop_by_layer.values.flatten(1)
      paved_edges = paved_by_layer.values.flatten(1)
      return nil if prop_edges.empty? && paved_edges.empty? && bldg_by_layer.values.flatten(1).empty?

      # Filter building & driveway lines per CAD layer strictly to the subject lot:
      prop_box = get_property_bounds(survey_group, property_layers)
      if prop_box && !prop_box.empty?
        min_bldg_x = prop_box.min.x + 100.0
        max_bldg_y = prop_box.max.y - 200.0
        garage_cutoff_y = prop_box.min.y + prop_box.height * 0.68
        bldg_by_layer.each do |_lname, edges|
          edges.select! do |p1, p2|
            mx = (p1.x + p2.x) / 2.0
            my = (p1.y + p2.y) / 2.0
            max_bldg_x = (my <= garage_cutoff_y) ? (prop_box.min.x + prop_box.width * 0.78) : (prop_box.min.x + prop_box.width * 0.65)
            mx >= min_bldg_x && mx <= max_bldg_x && my <= max_bldg_y
          end
        end

        paved_by_layer.each do |lname, edges|
          if lname =~ /asph/i
            edges.select! do |p1, p2|
              mx = (p1.x + p2.x) / 2.0
              my = (p1.y + p2.y) / 2.0
              mx >= (prop_box.min.x - 300.0) && mx <= (prop_box.max.x + 300.0) &&
              my >= (prop_box.min.y - 600.0) && my <= (prop_box.min.y + 200.0)
            end
            # Extend leftmost & rightmost asphalt road endpoints parallel to the front lot line across terrain width
            if terrain_group && !edges.empty?
              t_min_x = terrain_group.bounds.min.x - 50.0
              t_max_x = terrain_group.bounds.max.x + 50.0

              # Compute true front lot line slope (using long horizontal/angled lot edge, dx > 300")
              long_props = prop_edges.select { |p1, p2| (p2.x - p1.x).abs > 300.0 }
              front_seg = (long_props.empty? ? prop_edges : long_props).min_by { |p1, p2| (p1.y + p2.y) * 0.5 }
              if front_seg && (front_seg[1].x - front_seg[0].x).abs > 10.0
                slope = (front_seg[1].y - front_seg[0].y) / (front_seg[1].x - front_seg[0].x)
              else
                slope = 0.0
              end

              all_pts = edges.flatten(1)
              left_pt = all_pts.min_by(&:x)
              right_pt = all_pts.max_by(&:x)
              if left_pt && left_pt.x > t_min_x + 1.0
                ly = left_pt.y + slope * (t_min_x - left_pt.x)
                edges << [Geom::Point3d.new(t_min_x, ly, left_pt.z), left_pt.clone]
              end
              if right_pt && right_pt.x < t_max_x - 1.0
                ry = right_pt.y + slope * (t_max_x - right_pt.x)
                edges << [right_pt.clone, Geom::Point3d.new(t_max_x, ry, right_pt.z)]
              end
            end
          else
            # Private driveway + neighboring road apron (DWAY_LINE)
            edges.select! do |p1, p2|
              mx = (p1.x + p2.x) / 2.0
              my = (p1.y + p2.y) / 2.0
              mx >= (prop_box.min.x - 600.0) && mx <= (prop_box.max.x + 600.0) &&
              my >= (prop_box.min.y - 600.0) && my <= (prop_box.max.y + 300.0)
            end
          end
        end
      end

      # 1. Isolate Property Lines in their own sub-group (unfilled crisp 2D linework)
      if !prop_edges.empty?
        prop_sub = design_group.entities.add_group
        prop_sub.name = '2D_Property'
        prop_sub.layer = tag_design
        bridge_2d_endpoints(prop_sub, tag_design, 'property', prop_edges, z_plane, 300.0)
        prop_sub.entities.grep(Sketchup::Edge).each do |e|
          e.soft = false rescue nil
          e.smooth = false rescue nil
          e.layer = tag_design
        end
      end

      # 2. Isolate Driveway / Asphalt Lines per CAD layer (unfilled crisp 2D linework)
      if !paved_by_layer.values.flatten(1).empty?
        paved_parent = design_group.entities.add_group
        paved_parent.name = '2D_Driveway'
        paved_parent.layer = tag_design
        paved_by_layer.each do |cad_layer, layer_edges|
          next if layer_edges.empty?
          p_sub = paved_parent.entities.add_group
          p_sub.name = "2D_#{cad_layer}"
          p_sub.layer = tag_design
          bridge_2d_endpoints(p_sub, tag_design, 'driveway', layer_edges, z_plane, 350.0)
          p_sub.entities.grep(Sketchup::Edge).each do |e|
            next unless e.valid?
            e.soft = false rescue nil
            e.smooth = false rescue nil
            e.layer = tag_design
          end
        end
      end

      # 3. Isolate Building Lines per CAD layer (unfilled crisp 2D linework)
      bldg_parent = design_group.entities.add_group
      bldg_parent.name = '2D_Buildings'
      bldg_parent.layer = tag_design

      total_edges = 0
      bldg_by_layer.each do |cad_layer, layer_edges|
        next if layer_edges.empty?
        layer_sub = bldg_parent.entities.add_group
        layer_sub.name = "2D_#{cad_layer}"
        layer_sub.layer = tag_design

        add_building_edges_to_design(layer_sub, tag_design, layer_edges, z_plane)
        layer_sub.entities.grep(Sketchup::Edge).each do |e|
          next unless e.valid?
          e.soft = false rescue nil
          e.smooth = false rescue nil
          e.layer = tag_design
        end
        total_edges += layer_sub.entities.grep(Sketchup::Edge).size
      end

      puts "QuickDraft: Created unfilled Raw Lot Design 2D (isolated by layer) with #{total_edges} building edges on tag '#{TAG_DESIGN_2D}' at Z=#{z_plane.round(1)}."
      design_group
    end

    def self.heal_and_split_building_edges(bldg_edges, corner_tolerance = 12.0, t_junction_tolerance = 6.0)
      return [] if bldg_edges.nil? || bldg_edges.empty?

      # 1. Split crossing segments at 2D intersections (X-intersections from CAD overlaps)
      split_cross = bldg_edges.map { |p1, p2| [p1.clone, p2.clone] }
      5.times do
        changed = false
        new_list = []
        found_split = false
        (0...split_cross.size).each do |i|
          if found_split
            new_list << split_cross[i]
            next
          end
          p1, p2 = split_cross[i]
          ipt = nil
          other_j = -1
          ((i + 1)...split_cross.size).each do |j|
            p3, p4 = split_cross[j]
            denom = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
            if denom.abs > 1e-6
              t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / denom
              u = -((p1.x - p2.x) * (p1.y - p3.y) - (p1.y - p2.y) * (p1.x - p3.x)) / denom
              if t >= 0.005 && t <= 0.995 && u >= 0.005 && u <= 0.995
                ipt = Geom::Point3d.new(p1.x + t * (p2.x - p1.x), p1.y + t * (p2.y - p1.y), p1.z)
                other_j = j
                break
              end
            end
          end
          if ipt
            p3, p4 = split_cross[other_j]
            new_list << [p1, ipt]
            new_list << [ipt, p2]
            split_cross[other_j] = [p3, ipt]
            split_cross << [ipt, p4]
            found_split = true
            changed = true
          else
            new_list << split_cross[i]
          end
        end
        split_cross = new_list.select { |p1, p2| Math.hypot(p1.x - p2.x, p1.y - p2.y) > 0.5 }
        break unless changed
      end

      # 2. Snap near-miss corner vertices (gaps <= corner_tolerance inches)
      snapped = split_cross.map { |p1, p2| [p1.clone, p2.clone] }
      5.times do
        changed = false
        (0...snapped.size).each do |i|
          ((i + 1)...snapped.size).each do |j|
            [0, 1].each do |ei|
              [0, 1].each do |ej|
                d = Math.hypot(snapped[i][ei].x - snapped[j][ej].x, snapped[i][ei].y - snapped[j][ej].y)
                if d > 0.0005 && d <= corner_tolerance
                  mx = (snapped[i][ei].x + snapped[j][ej].x) * 0.5
                  my = (snapped[i][ei].y + snapped[j][ej].y) * 0.5
                  snapped[i][ei] = Geom::Point3d.new(mx, my, snapped[i][ei].z)
                  snapped[j][ej] = Geom::Point3d.new(mx, my, snapped[j][ej].z)
                  changed = true
                end
              end
            end
          end
        end
        break unless changed
      end

      valid_edges = snapped.select { |p1, p2| Math.hypot(p1.x - p2.x, p1.y - p2.y) > 0.5 }

      # 3. Detect and split segments at T-junctions, AND snap incoming endpoints
      endpoints = []
      valid_edges.each do |p1, p2|
        endpoints << p1 unless endpoints.any? { |pt| Math.hypot(pt.x - p1.x, pt.y - p1.y) < 0.01 }
        endpoints << p2 unless endpoints.any? { |pt| Math.hypot(pt.x - p2.x, pt.y - p2.y) < 0.01 }
      end

      split_map = {}
      split_edges = []
      valid_edges.each do |p1, p2|
        dx = p2.x - p1.x
        dy = p2.y - p1.y
        len_sq = dx * dx + dy * dy
        if len_sq < 1e-4
          split_edges << [p1, p2]
          next
        end

        splits = []
        endpoints.each do |pt|
          d1 = Math.hypot(pt.x - p1.x, pt.y - p1.y)
          d2 = Math.hypot(pt.x - p2.x, pt.y - p2.y)
          next if d1 < 0.01 || d2 < 0.01

          t = ((pt.x - p1.x) * dx + (pt.y - p1.y) * dy) / len_sq
          next if t <= 0.005 || t >= 0.995

          proj_x = p1.x + t * dx
          proj_y = p1.y + t * dy
          dist = Math.hypot(pt.x - proj_x, pt.y - proj_y)

          if dist <= t_junction_tolerance
            s_pt = Geom::Point3d.new(proj_x, proj_y, p1.z)
            splits << [t, s_pt]
            split_map[[pt.x.round(2), pt.y.round(2)]] = s_pt
          end
        end

        if splits.empty?
          split_edges << [p1, p2]
        else
          splits.sort_by! { |item| item[0] }
          curr = p1
          splits.each do |_t_val, split_pt|
            split_edges << [curr, split_pt] if Math.hypot(curr.x - split_pt.x, curr.y - split_pt.y) > 0.1
            curr = split_pt
          end
          split_edges << [curr, p2] if Math.hypot(curr.x - p2.x, curr.y - p2.y) > 0.1
        end
      end

      # Snap incoming T-stem endpoints directly to the newly split vertices
      t_healed = []
      split_edges.each do |p1, p2|
        k1 = [p1.x.round(2), p1.y.round(2)]
        k2 = [p2.x.round(2), p2.y.round(2)]
        np1 = split_map[k1] || p1
        np2 = split_map[k2] || p2
        if Math.hypot(np1.x - np2.x, np1.y - np2.y) > 0.5
          t_healed << [np1, np2]
        end
      end

      # 4. Prune tiny < 6" dead-end CAD ticks (like 5.91" stubs) while preserving all >= 6" architectural walls
      clean_edges = t_healed
      loop do
        deg = Hash.new(0)
        clean_edges.each do |p1, p2|
          k1 = [p1.x.round(1), p1.y.round(1)]
          k2 = [p2.x.round(1), p2.y.round(1)]
          deg[k1] += 1
          deg[k2] += 1
        end

        changed = false
        new_list = []
        clean_edges.each do |p1, p2|
          k1 = [p1.x.round(1), p1.y.round(1)]
          k2 = [p2.x.round(1), p2.y.round(1)]
          len = Math.hypot(p1.x - p2.x, p1.y - p2.y)
          if (deg[k1] == 1 || deg[k2] == 1) && len < 6.0
            changed = true
            next
          end
          new_list << [p1, p2]
        end
        clean_edges = new_list
        break unless changed
      end

      # 5. Final exact vertex unification (merge any vertices within 0.1" so SketchUp sees 0.000000" shared endpoints)
      unified_verts = []
      unify = lambda do |pt|
        found = unified_verts.find { |u| Math.hypot(u.x - pt.x, u.y - pt.y) < 0.1 }
        return found if found
        c = pt.clone
        unified_verts << c
        c
      end

      final_edges = []
      clean_edges.each do |p1, p2|
        u1 = unify.call(p1)
        u2 = unify.call(p2)
        final_edges << [u1, u2] if Math.hypot(u1.x - u2.x, u1.y - u2.y) > 0.5
      end

      # 6. Bridge any remaining open degree-1 vertices within 12" so deck/porch loops close 100%
      deg_final = Hash.new(0)
      final_edges.each { |p1, p2| deg_final[p1.object_id] += 1; deg_final[p2.object_id] += 1 }
      open_pts = []
      final_edges.each do |p1, p2|
        open_pts << p1 if deg_final[p1.object_id] == 1 && !open_pts.include?(p1)
        open_pts << p2 if deg_final[p2.object_id] == 1 && !open_pts.include?(p2)
      end

      while open_pts.size >= 2
        best_i = -1; best_j = -1; min_d = 12.0
        (0...open_pts.size).each do |i|
          ((i + 1)...open_pts.size).each do |j|
            d = Math.hypot(open_pts[i].x - open_pts[j].x, open_pts[i].y - open_pts[j].y)
            if d < min_d
              min_d = d; best_i = i; best_j = j
            end
          end
        end
        break if best_i < 0
        p_a = open_pts[best_i]; p_b = open_pts[best_j]
        open_pts.delete_at(best_j); open_pts.delete_at(best_i)
        final_edges << [p_a, p_b] if min_d > 0.5
      end

      final_edges
    end

    def self.add_building_edges_to_design(design_group, tag_design, bldg_edges, z_plane)
      return if bldg_edges.nil? || bldg_edges.empty?

      healed_edges = heal_and_split_building_edges(bldg_edges, 2.0, 2.0)

      healed_edges.each do |p1, p2|
        next if Math.hypot(p1.x - p2.x, p1.y - p2.y) < 0.5
        pt1 = Geom::Point3d.new(p1.x, p1.y, z_plane)
        pt2 = Geom::Point3d.new(p2.x, p2.y, z_plane)
        e = design_group.entities.add_line(pt1, pt2) rescue nil
        if e
          e.layer = tag_design
          e.set_attribute('QuickDraft', 'feature', 'building')
        end
      end
    end

    def self.bridge_2d_endpoints(design_group, tag, feature_name, edge_list, z_plane, max_gap)
      return if edge_list.nil? || edge_list.empty?

      created_edges = []
      edge_list.each do |p1, p2|
        next if p1.distance(p2) < 0.5
        pt1 = Geom::Point3d.new(p1.x, p1.y, z_plane)
        pt2 = Geom::Point3d.new(p2.x, p2.y, z_plane)
        e = design_group.entities.add_line(pt1, pt2) rescue nil
        if e
          e.layer = tag
          e.set_attribute('QuickDraft', 'feature', feature_name)
          created_edges << e
        end
      end

      # Find open vertices among created_edges
      open_verts = created_edges.map(&:vertices).flatten.uniq.select do |v|
        v.valid? && (v.edges & created_edges).size == 1
      end

      while open_verts.size >= 2
        best_pair = nil
        min_d = 1e12
        open_verts.each_with_index do |v1, i|
          ((i + 1)...open_verts.size).each do |j|
            v2 = open_verts[j]
            d = v1.position.distance(v2.position)
            if d < min_d
              min_d = d
              best_pair = [v1, v2]
            end
          end
        end

        break if min_d > max_gap || best_pair.nil?

        v1, v2 = best_pair
        open_verts.delete(v1)
        open_verts.delete(v2)

        be = design_group.entities.add_line(v1.position, v2.position) rescue nil
        if be
          be.layer = tag
          be.set_attribute('QuickDraft', 'feature', feature_name)
          created_edges << be
        end
      end

      # Snap any remaining open vertices that abut an existing wall segment (T-junctions)
      open_verts.each do |v|
        next unless v.valid?
        created_edges.each do |e|
          next unless e.valid?
          next if e.vertices.include?(v)
          p1 = e.start.position
          p2 = e.end.position
          d_sq = point_to_segment_distance_sq_2d(v.position.x, v.position.y, p1.x, p1.y, p2.x, p2.y)
          if d_sq < 9.0 # Within 3 inches of abutting wall
            len = p1.distance(p2)
            next if len < 1e-4
            t = ((v.position.x - p1.x) * (p2.x - p1.x) + (v.position.y - p1.y) * (p2.y - p1.y)) / (len * len)
            t = [[t, 0.0].max, 1.0].min
            proj_pt = Geom::Point3d.new(p1.x + t * (p2.x - p1.x), p1.y + t * (p2.y - p1.y), z_plane)
            be = design_group.entities.add_line(v.position, proj_pt) rescue nil
            if be
              be.layer = tag
              be.set_attribute('QuickDraft', 'feature', feature_name)
            end
            break
          end
        end
      end
    end

    # =========================================================================
    # Direct 2D-to-Slope Stamping Pipeline
    # Casts verified 2D design plan straight down (-Z) onto terrain slope
    # =========================================================================
    def self.drape_from_site_design_2d(model, terrain_group, raw_lot_group)
      return unless terrain_group && terrain_group.valid? && raw_lot_group && raw_lot_group.valid?

      tag_prop = ensure_tag(model, TAG_PROPERTY_LINE, Sketchup::Color.new(210, 30, 30))
      tag_paved = ensure_tag(model, TAG_DRIVEWAY, Sketchup::Color.new(50, 50, 55))
      tag_bldg = ensure_tag(model, TAG_BUILDING_FOOTPRINT, Sketchup::Color.new(80, 85, 95))
      tag_terrain = ensure_tag(model, TAG_TERRAIN, Sketchup::Color.new(160, 190, 140))

      collect_edges_recursive = lambda do |entities|
        list = entities.grep(Sketchup::Edge).to_a
        entities.grep(Sketchup::Group).each { |g| list.concat(collect_edges_recursive.call(g.entities)) }
        list
      end

      edges_2d = collect_edges_recursive.call(raw_lot_group.entities)
      return if edges_2d.empty?

      # 1. Separate 2D design edges by feature
      prop_edges_2d = edges_2d.select { |e| e.get_attribute('QuickDraft', 'feature') == 'property' }
      bldg_edges_2d = edges_2d.select { |e| e.get_attribute('QuickDraft', 'feature') == 'building' }
      paved_edges_2d = edges_2d.select { |e| e.get_attribute('QuickDraft', 'feature') == 'driveway' }

      # 2. Extract clean closed boundary polygons per isolated building layer sub-group & driveway
      bldg_polys = []
      bldg_parent = raw_lot_group.entities.grep(Sketchup::Group).find { |g| g.name == '2D_Buildings' }
      if bldg_parent
        bldg_parent.entities.grep(Sketchup::Group).each do |layer_sub|
          layer_faces = layer_sub.entities.grep(Sketchup::Face).select { |f| f.valid? && f.area >= 1440.0 }
          if !layer_faces.empty?
            layer_faces.each do |f|
              bldg_polys << f.outer_loop.vertices.map { |v| [v.position.x, v.position.y] }
            end
          else
            bldg_polys.concat(extract_2d_polygons(model, layer_sub.entities.grep(Sketchup::Edge).to_a))
          end
        end
      else
        bldg_polys = extract_2d_polygons(model, bldg_edges_2d)
      end

      paved_outer = []
      paved_islands = []
      paved_parent = raw_lot_group.entities.grep(Sketchup::Group).find { |g| g.name == '2D_Driveway' }
      if paved_parent && !paved_parent.entities.grep(Sketchup::Group).empty?
        paved_parent.entities.grep(Sketchup::Group).each do |p_sub|
          sub_edges = p_sub.entities.grep(Sketchup::Edge).to_a
          po, pi = extract_driveway_polygons(model, sub_edges)
          if po.empty? && p_sub.name =~ /asph|road/i && !sub_edges.empty?
            # Open road-edge polyline (e.g. ASPH_LINE): close Southward past terrain bounds so the road strip gets asphalt_mat
            adj = Hash.new { |h, k| h[k] = [] }
            sub_edges.each do |e|
              next unless e.valid?
              adj[e.start] << e
              adj[e.end] << e
            end
            start_v = adj.keys.min_by { |v| v.position.x }
            if start_v
              visited = {}
              chain_pts = [start_v.position]
              cur_v = start_v
              loop do
                nxt_e = adj[cur_v].find { |e| !visited[e] }
                if nxt_e
                  visited[nxt_e] = true
                  cur_v = nxt_e.other_vertex(cur_v)
                  chain_pts << cur_v.position
                else
                  rem = sub_edges.reject { |e| visited[e] }
                  break if rem.empty?
                  cur_p = cur_v.position
                  best_e = rem.min_by { |e| [e.start.position.distance(cur_p), e.end.position.distance(cur_p)].min }
                  visited[best_e] = true
                  if best_e.start.position.distance(cur_p) <= best_e.end.position.distance(cur_p)
                    chain_pts << best_e.start.position
                    cur_v = best_e.end
                  else
                    chain_pts << best_e.end.position
                    cur_v = best_e.start
                  end
                  chain_pts << cur_v.position
                end
              end
              if chain_pts.size >= 2
                road_south_y = terrain_group.bounds.min.y - 500.0
                poly = chain_pts.map { |p| [p.x, p.y] }
                poly << [chain_pts.last.x + 500.0, chain_pts.last.y]
                poly << [chain_pts.last.x + 500.0, road_south_y]
                poly << [chain_pts.first.x - 500.0, road_south_y]
                poly << [chain_pts.first.x - 500.0, chain_pts.first.y]
                po << poly
              end
            end
          end
          paved_outer.concat(po)
          paved_islands.concat(pi)
        end
      else
        paved_outer, paved_islands = extract_driveway_polygons(model, paved_edges_2d)
      end

      # 3. Stamp 2D features directly INTO the single Site_Terrain mesh in-place (NO nested groups!)
      z_top = terrain_group.bounds.max.z + 300.0
      z_bottom = terrain_group.bounds.min.z - 300.0

      cutter_group = model.active_entities.add_group
      cutter_group.name = 'QD_Temp_Drape_Cutter'

      # Build unique, watertight vertical cutter curtains from extracted polygons + property lines
      added_cutter_segs = {}
      add_cutter_seg = lambda do |x1, y1, x2, y2|
        return if Math.hypot(x2 - x1, y2 - y1) < 0.5
        k1 = [x1.round(1), y1.round(1)]
        k2 = [x2.round(1), y2.round(1)]
        seg_key = (k1[0] < k2[0] || (k1[0] == k2[0] && k1[1] < k2[1])) ? [k1, k2] : [k2, k1]
        return if added_cutter_segs[seg_key]
        added_cutter_segs[seg_key] = true

        v1 = Geom::Point3d.new(x1, y1, z_top)
        v2 = Geom::Point3d.new(x2, y2, z_top)
        v3 = Geom::Point3d.new(x2, y2, z_bottom)
        v4 = Geom::Point3d.new(x1, y1, z_bottom)
        cutter_group.entities.add_face(v1, v2, v3, v4) rescue nil
      end

      (bldg_polys + paved_outer + paved_islands).each do |poly|
        next if poly.nil? || poly.size < 3
        poly.each_with_index do |p1, i|
          p2 = poly[(i + 1) % poly.size]
          add_cutter_seg.call(p1[0], p1[1], p2[0], p2[1])
        end
      end

      (prop_edges_2d + bldg_edges_2d + paved_edges_2d).each do |edge|
        next unless edge.valid?
        add_cutter_seg.call(edge.start.position.x, edge.start.position.y, edge.end.position.x, edge.end.position.y)
      end

      terrain_group.entities.intersect_with(
        false,
        terrain_group.transformation,
        terrain_group.entities,
        cutter_group.transformation,
        false,
        cutter_group.entities.to_a
      ) rescue nil

      model.active_entities.erase_entities(cutter_group) rescue nil

      # 4. Paint all faces in the single Site_Terrain mesh
      terrain_mat = model.materials['QD_Site_Terrain'] || model.materials.add('QD_Site_Terrain')
      terrain_mat.color = Sketchup::Color.new(225, 235, 220)

      asphalt_mat = model.materials['QD_Driveway_Asphalt'] || model.materials.add('QD_Driveway_Asphalt')
      asphalt_mat.color = Sketchup::Color.new(70, 72, 75)

      bldg_mat = model.materials['0131_Silver'] || model.materials['QD_Building_Footprint'] || model.materials.add('QD_Building_Footprint')
      bldg_mat.color = Sketchup::Color.new(192, 192, 192) unless bldg_mat.name == '0131_Silver'

      terrain_group.entities.grep(Sketchup::Face).each do |face|
        next unless face.valid?
        face.reverse! if face.normal.z < 0

        mesh = face.mesh rescue nil
        if mesh && mesh.count_polygons > 0
          pts = mesh.polygon_points_at(1)
          cx = (pts[0].x + pts[1].x + pts[2].x) / 3.0
          cy = (pts[0].y + pts[1].y + pts[2].y) / 3.0
        else
          cx = face.bounds.center.x
          cy = face.bounds.center.y
        end

        is_in_bldg = bldg_polys.any? { |poly| point_in_polygon?(cx, cy, poly) }
        is_in_paved = !is_in_bldg && paved_outer.any? do |poly|
          in_out = point_in_polygon?(cx, cy, poly)
          in_isl = paved_islands.any? { |ip| point_in_polygon?(cx, cy, ip) }
          in_out && !in_isl
        end

        if is_in_bldg
          face.material = bldg_mat
          face.back_material = bldg_mat
        elsif is_in_paved
          face.material = asphalt_mat
          face.back_material = asphalt_mat
        else
          face.material = terrain_mat
          face.back_material = terrain_mat
        end
        face.layer = tag_terrain
      end

      # 5. Guarantee crisp hard boundaries around every material region (zero selection leaks!)
      edge_on_2d_line = lambda do |edge, list|
        sx = edge.start.position.x
        sy = edge.start.position.y
        ex = edge.end.position.x
        ey = edge.end.position.y
        mx = (sx + ex) * 0.5
        my = (sy + ey) * 0.5
        list.any? do |le|
          next false unless le.valid?
          x1 = le.start.position.x; y1 = le.start.position.y
          x2 = le.end.position.x;   y2 = le.end.position.y
          point_to_segment_distance_sq_2d(sx, sy, x1, y1, x2, y2) < 1.0 &&
            point_to_segment_distance_sq_2d(ex, ey, x1, y1, x2, y2) < 1.0 &&
            point_to_segment_distance_sq_2d(mx, my, x1, y1, x2, y2) < 1.0
        end
      end

      terrain_group.entities.grep(Sketchup::Edge).each do |edge|
        next unless edge.valid?
        faces = edge.faces

        # Any edge separating two different materials (e.g. driveway vs terrain, building vs terrain) MUST be hard
        is_mat_boundary = faces.size == 2 && faces[0].material != faces[1].material
        is_design_edge = is_mat_boundary || faces.size == 1 ||
                         edge_on_2d_line.call(edge, bldg_edges_2d) ||
                         edge_on_2d_line.call(edge, paved_edges_2d) ||
                         edge_on_2d_line.call(edge, prop_edges_2d)

        if is_design_edge
          edge.soft = false rescue nil
          edge.smooth = false rescue nil
        else
          edge.soft = true rescue nil
          edge.smooth = true rescue nil
        end
        edge.layer = tag_terrain
      end

      # 6. Explode temporary isolation sub-groups inside Site_Raw_Lot_Design_2D into one clean 2D group
      loop do
        sub_groups = raw_lot_group.entities.grep(Sketchup::Group).select(&:valid?)
        break if sub_groups.empty?
        sub_groups.each { |g| g.explode rescue nil }
      end

      puts "QuickDraft: Stamped all 2D areas into single unified Site_Terrain mesh on '#{TAG_TERRAIN}'."
      bldg_polys
    end

    def self.subdivide_polygon_2d(poly, max_len = 48.0)
      return poly if poly.nil? || poly.size < 3
      new_poly = []
      n = poly.size
      (0...n).each do |i|
        p1 = poly[i]
        p2 = poly[(i + 1) % n]
        x1 = p1.respond_to?(:x) ? p1.x : p1[0]
        y1 = p1.respond_to?(:y) ? p1.y : p1[1]
        x2 = p2.respond_to?(:x) ? p2.x : p2[0]
        y2 = p2.respond_to?(:y) ? p2.y : p2[1]

        new_poly << [x1, y1]
        dx = x2 - x1
        dy = y2 - y1
        dist = Math.hypot(dx, dy)
        if dist > max_len
          steps = (dist / max_len).ceil
          (1...steps).each do |s|
            t = s / steps.to_f
            new_poly << [x1 + t * dx, y1 + t * dy]
          end
        end
      end
      new_poly
    end

    def self.triangulate_ear_clipping(poly)
      return [] if poly.nil? || poly.size < 3
      n = poly.size

      area = 0.0
      (0...n).each do |i|
        x1, y1 = poly[i][0], poly[i][1]
        x2, y2 = poly[(i + 1) % n][0], poly[(i + 1) % n][1]
        area += (x1 * y2 - x2 * y1)
      end
      verts = (area < 0) ? poly.reverse : poly.clone

      is_convex = lambda do |p1, p2, p3|
        ((p2[0] - p1[0]) * (p3[1] - p2[1]) - (p2[1] - p1[1]) * (p3[0] - p2[0])) > 1e-7
      end

      in_triangle = lambda do |pt, a, b, c|
        sign = lambda do |p1, p2, p3|
          (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
        end
        d1 = sign.call(pt, a, b)
        d2 = sign.call(pt, b, c)
        d3 = sign.call(pt, c, a)
        has_neg = (d1 < -1e-7) || (d2 < -1e-7) || (d3 < -1e-7)
        has_pos = (d1 > 1e-7) || (d2 > 1e-7) || (d3 > 1e-7)
        !(has_neg && has_pos)
      end

      triangles = []
      max_iter = verts.size * 4
      iter_count = 0

      while verts.size > 3 && iter_count < max_iter
        iter_count += 1
        ear_found = false
        m = verts.size
        (0...m).each do |i|
          p_prev = verts[(i - 1) % m]
          p_curr = verts[i]
          p_next = verts[(i + 1) % m]
          next unless is_convex.call(p_prev, p_curr, p_next)

          has_inside = false
          (0...m).each do |j|
            next if j == ((i - 1) % m) || j == i || j == ((i + 1) % m)
            if in_triangle.call(verts[j], p_prev, p_curr, p_next)
              has_inside = true
              break
            end
          end

          unless has_inside
            triangles << [p_prev, p_curr, p_next]
            verts.delete_at(i)
            ear_found = true
            break
          end
        end

        unless ear_found
          (0...m).each do |i|
            p_prev = verts[(i - 1) % m]
            p_curr = verts[i]
            p_next = verts[(i + 1) % m]
            if is_convex.call(p_prev, p_curr, p_next)
              triangles << [p_prev, p_curr, p_next]
              verts.delete_at(i)
              ear_found = true
              break
            end
          end
          break unless ear_found
        end
      end

      if verts.size == 3
        triangles << [verts[0], verts[1], verts[2]]
      end

      triangles
    end

    def self.stamp_polygon_to_slope(model, target_group, poly, material, tag, z_offset = 1.5, islands = [])
      return if poly.nil? || poly.size < 3

      # Collect all boundary segments for edge softening check & grid clearance
      boundary_segments = []
      poly.each_with_index do |pt, i|
        nxt = poly[(i + 1) % poly.size]
        boundary_segments << [pt, nxt]
      end
      if islands
        islands.each do |isl|
          isl.each_with_index do |pt, i|
            nxt = isl[(i + 1) % isl.size]
            boundary_segments << [pt, nxt]
          end
        end
      end

      # Subdivide outer and island perimeters to 48" and add a 48" interior grid
      # so every triangle hugs every hillside ridge/valley with zero terrain poke-through
      sub_outer = subdivide_polygon_2d(poly, 48.0)
      pts = sub_outer.map { |p| Geom::Point3d.new(p[0], p[1], 0.0) }

      if islands
        islands.each do |isl|
          sub_isl = subdivide_polygon_2d(isl, 48.0)
          sub_isl.each { |p| pts << Geom::Point3d.new(p[0], p[1], 0.0) }
        end
      end

      xs = sub_outer.map { |p| p[0] }
      ys = sub_outer.map { |p| p[1] }
      min_x, max_x = xs.min, xs.max
      min_y, max_y = ys.min, ys.max

      step = 48.0
      gx = min_x + step * 0.5
      while gx < max_x
        gy = min_y + step * 0.5
        while gy < max_y
          in_out = point_in_polygon?(gx, gy, poly)
          in_isl = islands && islands.any? { |ip| point_in_polygon?(gx, gy, ip) }
          if in_out && !in_isl
            too_close = boundary_segments.any? do |bp1, bp2|
              point_to_segment_distance_sq_2d(gx, gy, bp1[0], bp1[1], bp2[0], bp2[1]) < 144.0 # < 12"
            end
            pts << Geom::Point3d.new(gx, gy, 0.0) unless too_close
          end
          gy += step
        end
        gx += step
      end

      raw_tris = Delaunay.triangulate(pts)
      triangles = []
      raw_tris.each do |p1, p2, p3|
        cx = (p1.x + p2.x + p3.x) / 3.0
        cy = (p1.y + p2.y + p3.y) / 3.0
        in_out = point_in_polygon?(cx, cy, poly)
        in_isl = islands && islands.any? { |ip| point_in_polygon?(cx, cy, ip) }
        if in_out && !in_isl
          triangles << [[p1.x, p1.y], [p2.x, p2.y], [p3.x, p3.y]]
        end
      end

      if triangles.empty?
        triangles = triangulate_ear_clipping(sub_outer)
      end

      return if triangles.empty?

      new_faces = []
      triangles.each do |t|
        p1, p2, p3 = t[0], t[1], t[2]
        z1 = (sample_terrain_elevation(p1[0], p1[1]) || 0.0) + z_offset
        z2 = (sample_terrain_elevation(p2[0], p2[1]) || 0.0) + z_offset
        z3 = (sample_terrain_elevation(p3[0], p3[1]) || 0.0) + z_offset

        v1 = Geom::Point3d.new(p1[0], p1[1], z1)
        v2 = Geom::Point3d.new(p2[0], p2[1], z2)
        v3 = Geom::Point3d.new(p3[0], p3[1], z3)

        face = target_group.entities.add_face(v1, v2, v3) rescue nil
        if face
          face.reverse! if face.normal.z < 0
          face.material = material
          face.back_material = material
          face.layer = tag
          new_faces << face
        end
      end

      # Soften internal triangle edges while keeping perimeter boundary edges crisp
      new_faces.each do |face|
        face.edges.each do |edge|
          next unless edge.valid?
          edge.layer = tag
          mx = (edge.start.position.x + edge.end.position.x) / 2.0
          my = (edge.start.position.y + edge.end.position.y) / 2.0

          is_boundary = boundary_segments.any? do |bp1, bp2|
            point_to_segment_distance_sq_2d(mx, my, bp1[0], bp1[1], bp2[0], bp2[1]) < 9.0 # within 3"
          end

          if is_boundary
            edge.soft = false rescue nil
            edge.smooth = false rescue nil
          else
            edge.soft = true rescue nil
            edge.smooth = true rescue nil
          end
        end
      end
    end

    def self.point_in_polygon?(x, y, pts)
      inside = false
      n = pts.size
      return false if n < 3

      (0...n).each do |i|
        j = (i - 1) % n
        p1 = pts[i]
        p2 = pts[j]
        xi = p1.respond_to?(:x) ? p1.x : p1[0]
        yi = p1.respond_to?(:y) ? p1.y : p1[1]
        xj = p2.respond_to?(:x) ? p2.x : p2[0]
        yj = p2.respond_to?(:y) ? p2.y : p2[1]
        if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
          inside = !inside
        end
      end
      inside
    end

    def self.point_to_segment_distance_sq_2d(px, py, x1, y1, x2, y2)
      dx = x2 - x1
      dy = y2 - y1
      len_sq = dx * dx + dy * dy
      return (px - x1)**2 + (py - y1)**2 if len_sq < 1e-6

      t = ((px - x1) * dx + (py - y1) * dy) / len_sq
      t = 0.0 if t < 0.0
      t = 1.0 if t > 1.0

      proj_x = x1 + t * dx
      proj_y = y1 + t * dy
      (px - proj_x)**2 + (py - proj_y)**2
    end

    def self.find_nearest_feature_type(x, y, edges_2d)
      best_type = 'property'
      min_dist_sq = 1e12

      edges_2d.each do |e|
        next unless e.valid?
        p1 = e.start.position
        p2 = e.end.position
        d_sq = point_to_segment_distance_sq_2d(x, y, p1.x, p1.y, p2.x, p2.y)
        if d_sq < min_dist_sq
          min_dist_sq = d_sq
          best_type = e.get_attribute('QuickDraft', 'feature')
        end
      end

      best_type || 'property'
    end

    def self.extract_2d_polygons(model, edges)
      polys = []
      return polys if edges.nil? || edges.empty?

      # Exact planar directed half-edge face tracer (finds all minimal closed loops >= 10 sq ft,
      # including concave deck/ramp/porch regions, without relying on SketchUp temp_grp.find_faces)
      # Distance-based vertex clustering (< 0.5") so floating-point rounding boundaries never break a loop
      cluster_pts = []
      cluster_key = lambda do |x, y|
        found = cluster_pts.find { |cx, cy| Math.hypot(cx - x, cy - y) < 0.5 }
        return found if found
        pt = [x.to_f, y.to_f]
        cluster_pts << pt
        pt
      end

      directed = {}
      edges.each do |e|
        next unless e.valid?
        k1 = cluster_key.call(e.start.position.x, e.start.position.y)
        k2 = cluster_key.call(e.end.position.x, e.end.position.y)
        next if k1 == k2
        directed[[k1, k2]] = true
        directed[[k2, k1]] = true
      end

      out_edges = Hash.new { |h, k| h[k] = [] }
      directed.keys.each do |u, v|
        ang = Math.atan2(v[1] - u[1], v[0] - u[0])
        out_edges[u] << [ang, v]
      end
      out_edges.each_value { |list| list.sort_by! { |item| item[0] } }

      used = {}
      directed.keys.each do |u, v|
        next if used[[u, v]]
        face = [u]
        curr_u = u
        curr_v = v
        loop do
          used[[curr_u, curr_v]] = true
          face << curr_v
          in_ang = Math.atan2(curr_u[1] - curr_v[1], curr_u[0] - curr_v[0])
          cands = out_edges[curr_v]
          break if cands.nil? || cands.empty?

          idx = -1
          (cands.size - 1).downto(0) do |i|
            if cands[i][0] < in_ang - 1e-6
              idx = i
              break
            end
          end
          idx = cands.size - 1 if idx == -1
          next_v = cands[idx][1]
          break if [curr_v, next_v] == [u, v] || face.size > 200
          curr_u = curr_v
          curr_v = next_v
        end

        next if face.size < 4
        area = 0.0
        (0...(face.size - 1)).each do |i|
          area += face[i][0] * face[i + 1][1] - face[i + 1][0] * face[i][1]
        end
        area *= 0.5
        if area >= 144.0 # >= 1 sq ft (captures small chimneys & eave returns)
          polys << face[0...-1]
        end
      end

      polys
    end

    def self.extract_driveway_polygons(model, edges)
      outer_polys = []
      island_polys = []
      return [outer_polys, island_polys] if edges.nil? || edges.empty?

      temp_grp = model.active_entities.add_group
      edges.each do |e|
        next unless e.valid?
        temp_grp.entities.add_line(
          Geom::Point3d.new(e.start.position.x, e.start.position.y, 0.0),
          Geom::Point3d.new(e.end.position.x, e.end.position.y, 0.0)
        ) rescue nil
      end
      temp_grp.entities.grep(Sketchup::Edge).each { |e| e.find_faces rescue nil }

      faces = temp_grp.entities.grep(Sketchup::Face)

      # 1. Collect all inner hole loops from multi-loop faces (like the turnaround island hole)
      faces.each do |f|
        if f.loops.size > 1
          f.loops.each do |l|
            next if l == f.outer_loop
            island_polys << l.vertices.map { |v| [v.position.x, v.position.y] }
          end
        end
      end

      # 2. Categorize outer loops and island faces
      faces.each do |f|
        poly = f.outer_loop.vertices.map { |v| [v.position.x, v.position.y] }

        if f.loops.size > 1
          # Multi-loop face: its outer loop IS the driveway boundary (with island hole)
          outer_polys << poly
        else
          # Single loop face: check if it represents the inner island or a paved apron
          mesh = f.mesh rescue nil
          test_pt = if mesh && mesh.count_polygons > 0
                      pts = mesh.polygon_points_at(1)
                      Geom::Point3d.new((pts[0].x + pts[1].x + pts[2].x) / 3.0, (pts[0].y + pts[1].y + pts[2].y) / 3.0, 0.0)
                    else
                      f.bounds.center
                    end

          if island_polys.any? { |ip| point_in_polygon?(test_pt.x, test_pt.y, ip) }
            island_polys << poly unless island_polys.include?(poly)
          else
            # Only include genuine paved areas (> 150 sq ft), excluding stray CAD corner marks
            if f.area > 20000.0
              outer_polys << poly
            end
          end
        end
      end

      model.active_entities.erase_entities(temp_grp) rescue nil
      [outer_polys, island_polys]
    end


    def self.place_tree_proxies(model, survey_group, tree_layers, terrain_group, property_layers = [], bldg_polys = [])
      return if tree_layers.empty?

      tag_trees = ensure_tag(model, TAG_TREES, Sketchup::Color.new(45, 125, 65))
      tree_def = create_or_get_tree_proxy_def(model)

      trees_group = model.active_entities.add_group
      trees_group.name = TREES_GROUP_NAME
      trees_group.layer = tag_trees

      tree_records = []
      tr = survey_group.transformation

      species_map = {
        'arb'    => 'Arbutus',
        'ced'    => 'Cedar',
        'fir'    => 'Fir',
        'fruit'  => 'Fruit Tree',
        'map'    => 'Maple',
        'willow' => 'Willow',
        'yew'    => 'Yew'
      }

      collect_trees = lambda do |entities, current_tr|
        entities.each do |entity|
          layer_name = (entity.respond_to?(:layer) && entity.layer) ? entity.layer.name : nil
          if layer_name && tree_layers.include?(layer_name)
            lname = layer_name.downcase
            # Guard: strictly ensure only genuine tree layers are placed as tree proxies
            next unless lname =~ /^tr(arb|ced|fir|fruit|map|willow|yew|tree|oak|pine|alder|plum|cherry)/i || lname.start_with?('tree') || lname.start_with?('arbor')

            detected_species = 'Tree'
            lname = layer_name.downcase
            species_map.each do |k, v|
              if lname.include?(k)
                detected_species = v
                break
              end
            end

            pos = nil
            if entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
              pos = entity.bounds.center.transform(current_tr)
            elsif entity.is_a?(Sketchup::ConstructionPoint)
              pos = entity.position.transform(current_tr)
            elsif entity.is_a?(Sketchup::Edge) && entity.curve.is_a?(Sketchup::ArcCurve)
              pos = entity.curve.center.transform(current_tr)
            end

            if pos
              tree_records << { pos: pos, species: detected_species, layer: layer_name }
            end
          end

          if entity.is_a?(Sketchup::Group)
            collect_trees.call(entity.entities, current_tr * entity.transformation)
          elsif entity.is_a?(Sketchup::ComponentInstance)
            collect_trees.call(entity.definition.entities, current_tr * entity.transformation)
          end
        end
      end

      collect_trees.call(survey_group.entities, tr)
      return if tree_records.empty?

      # Filter trees within property boundary buffer, and strictly exclude sample tree in sheet legend
      prop_box = get_property_bounds(survey_group, property_layers)
      if prop_box && !prop_box.empty?
        min_x = prop_box.min.x - 100.0
        max_x = prop_box.max.x + 50.0 # Cleanly excludes legend symbol at prop_box.max.x + 326"
        min_y = prop_box.min.y - 100.0
        max_y = prop_box.max.y + 100.0

        tree_records.select! do |rec|
          p = rec[:pos]
          p.x >= min_x && p.x <= max_x && p.y >= min_y && p.y <= max_y
        end
      end

      # Exclude any trees that fall geographically inside building footprints
      if bldg_polys && !bldg_polys.empty?
        tree_records.reject! do |rec|
          p = rec[:pos]
          bldg_polys.any? { |poly| point_in_polygon?(p.x, p.y, poly) }
        end
      end

      # Deduplicate trees within 24 inches to avoid placing duplicates for both _POINT and _SYMB
      unique_trees = []
      grid = {}
      tree_records.each do |rec|
        p = rec[:pos]
        key = "#{(p.x / 24.0).round}_#{(p.y / 24.0).round}"
        unless grid[key]
          grid[key] = true
          unique_trees << rec
        end
      end

      max_z = (terrain_group ? terrain_group.bounds.max.z : 12000.0) + 600.0
      fallback_z = terrain_group ? terrain_group.bounds.min.z : 0.0

      unique_trees.each do |rec|
        p = rec[:pos]
        z = sample_elevation(model, p.x, p.y, max_z, fallback_z, terrain_group)

        inst = trees_group.entities.add_instance(tree_def, Geom::Transformation.translation(Geom::Vector3d.new(p.x, p.y, z)))
        if inst
          inst.layer = tag_trees
          inst.set_attribute(DICT_SITE_DATA, 'species', rec[:species])
          inst.set_attribute(DICT_SITE_DATA, 'cad_layer', rec[:layer])
          inst.name = "#{rec[:species]} (Existing)"
        end
      end
      trees_group
    end

    def self.create_or_get_tree_proxy_def(model)
      comp_def = model.definitions[TREE_PROXY_DEF_NAME]
      if comp_def && comp_def.valid?
        comp_def.entities.clear!
      else
        comp_def = model.definitions.add(TREE_PROXY_DEF_NAME)
      end
      comp_def.description = 'QuickDraft Existing Survey Tree Proxy'

      ents = comp_def.entities

      # Tree dimensions: 10 ft tall trunk, slender 42" radius canopy (reduced in half from 84")
      trunk_h  = 120.0 # 10 feet tall trunk in inches
      canopy_r = 42.0  # Reduced in half (3.5 ft radius, 7 ft diameter)
      canopy_h = 180.0 # 15 feet tall canopy cone
      apex_z   = trunk_h + canopy_h # 300.0" (25 ft total height)

      trunk_mat = model.materials['QD_Tree_Bark'] || model.materials.add('QD_Tree_Bark')
      trunk_mat.color = Sketchup::Color.new(115, 85, 60)

      # 8-sided trunk cylinder (5" radius = 10" diameter trunk)
      base_circle = ents.add_circle(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), 5.0, 8)
      base_pts = base_circle.map { |e| e.start.position }
      top_pts = base_pts.map { |pt| Geom::Point3d.new(pt.x, pt.y, trunk_h) }

      (0...base_pts.size).each do |i|
        next_i = (i + 1) % base_pts.size
        face = ents.add_face(base_pts[i], base_pts[next_i], top_pts[next_i], top_pts[i]) rescue nil
        face.material = trunk_mat if face
      end

      foliage_mat = model.materials['QD_Tree_Foliage'] || model.materials.add('QD_Tree_Foliage')
      foliage_mat.color = Sketchup::Color.new(90, 140, 80)

      # 8-sided canopy cone starting at top of trunk (Z = 120.0")
      canopy_circle = ents.add_circle(Geom::Point3d.new(0, 0, trunk_h), Geom::Vector3d.new(0, 0, 1), canopy_r, 8)
      canopy_pts = canopy_circle.map { |e| e.start.position }
      apex = Geom::Point3d.new(0, 0, apex_z)

      (0...canopy_pts.size).each do |i|
        next_i = (i + 1) % canopy_pts.size
        face = ents.add_face(canopy_pts[i], canopy_pts[next_i], apex) rescue nil
        face.material = foliage_mat if face
      end

      bot_face = ents.add_face(canopy_pts) rescue nil
      bot_face.material = foliage_mat if bot_face

      comp_def
    end

    # =========================================================================
    # Helpers & Precise Terrain Elevation Stamping
    # =========================================================================
    def self.sample_terrain_elevation(x, y)
      if @terrain_triangles && !@terrain_triangles.empty?
        @terrain_triangles.each do |p1, p2, p3|
          min_x = (p1.x < p2.x ? (p1.x < p3.x ? p1.x : p3.x) : (p2.x < p3.x ? p2.x : p3.x)) - 2.0
          max_x = (p1.x > p2.x ? (p1.x > p3.x ? p1.x : p3.x) : (p2.x > p3.x ? p2.x : p3.x)) + 2.0
          next if x < min_x || x > max_x
          min_y = (p1.y < p2.y ? (p1.y < p3.y ? p1.y : p3.y) : (p2.y < p3.y ? p2.y : p3.y)) - 2.0
          max_y = (p1.y > p2.y ? (p1.y > p3.y ? p1.y : p3.y) : (p2.y > p3.y ? p2.y : p3.y)) + 2.0
          next if y < min_y || y > max_y

          det = (p2.y - p3.y) * (p1.x - p3.x) + (p3.x - p2.x) * (p1.y - p3.y)
          next if det.abs < 1e-9

          w1 = ((p2.y - p3.y) * (x - p3.x) + (p3.x - p2.x) * (y - p3.y)) / det
          next if w1 < -1e-4 || w1 > 1.0001
          w2 = ((p3.y - p1.y) * (x - p3.x) + (p1.x - p3.x) * (y - p3.y)) / det
          next if w2 < -1e-4 || w2 > 1.0001
          w3 = 1.0 - w1 - w2
          next if w3 < -1e-4 || w3 > 1.0001

          return w1 * p1.z + w2 * p2.z + w3 * p3.z
        end
      end

      # Fallback for points slightly outside the terrain mesh boundary (e.g. road edge or curb cuts):
      # Clamp to the elevation of the nearest genuine ground point
      if @terrain_points && !@terrain_points.empty?
        nearest = @terrain_points.min_by { |pt| (pt.x - x)**2 + (pt.y - y)**2 }
        return nearest.z if nearest
      end

      nil
    end

    def self.sample_elevation(_model, x, y, _max_z = nil, fallback_z = nil, _target_group = nil)
      z = sample_terrain_elevation(x, y)
      return z if z

      fallback_z || 0.0
    end

    # =========================================================================
    # Aerial / Satellite Photo Projection on 3D Terrain
    # =========================================================================
    MAT_AERIAL_TEXTURE = 'QD_Aerial_Photo'.freeze

    def self.find_terrain_group(model)
      (model.active_entities.to_a + model.entities.to_a).uniq.each do |e|
        next unless e.valid? && e.is_a?(Sketchup::Group)
        return e if e.name == TERRAIN_GROUP_NAME
        if e.name == MASTER_GROUP_NAME || e.name == 'Site_All'
          sub = e.entities.grep(Sketchup::Group).find { |g| g.name == TERRAIN_GROUP_NAME }
          return sub if sub
        end
      end
      nil
    end

    def self.find_raw_lot_group(model)
      (model.active_entities.to_a + model.entities.to_a).uniq.each do |e|
        next unless e.valid? && e.is_a?(Sketchup::Group)
        return e if e.name == RAW_LOT_GROUP_NAME
        if e.name == MASTER_GROUP_NAME || e.name == 'Site_All'
          sub = e.entities.grep(Sketchup::Group).find { |g| g.name == RAW_LOT_GROUP_NAME }
          return sub if sub
        end
      end
      nil
    end

    @aerial_adjuster_dialog = nil

    def self.find_aerial_target_box(model, terrain_group)
      raw_lot = find_raw_lot_group(model)
      if raw_lot && raw_lot.valid?
        prop_sub = raw_lot.entities.grep(Sketchup::Group).find { |g| g.name == '2D_Property' }
        prop_ents = prop_sub ? prop_sub.entities : raw_lot.entities
        prop_edges = prop_ents.grep(Sketchup::Edge).select { |e| e.get_attribute('QuickDraft', 'feature') == 'property' }
        unless prop_edges.empty?
          box = Geom::BoundingBox.new
          prop_edges.each do |e|
            box.add(e.start.position)
            box.add(e.end.position)
          end
          return box unless box.empty?
        end
      end
      terrain_group.bounds
    end

    def self.reproject_aerial_texture(model, terrain_group, image_path, world_width_ft, offset_x_ft, offset_y_ft, rot_deg)
      terrain_group = find_terrain_group(model) unless terrain_group && terrain_group.valid?
      return unless model && terrain_group && terrain_group.valid? && image_path && File.exist?(image_path)

      target_box = find_aerial_target_box(model, terrain_group)
      cx = (target_box.min.x + target_box.max.x) * 0.5
      cy = (target_box.min.y + target_box.max.y) * 0.5

      width_in  = [world_width_ft.to_f * 12.0, 12.0].max
      ox_in     = offset_x_ft.to_f * 12.0
      oy_in     = offset_y_ft.to_f * 12.0
      rot_angle = rot_deg.to_f

      mat = model.materials[MAT_AERIAL_TEXTURE] || model.materials.add(MAT_AERIAL_TEXTURE)
      mat.texture = image_path unless mat.texture && mat.texture.filename == image_path

      img_w = (mat.texture && mat.texture.image_width > 0) ? mat.texture.image_width.to_f : 1.0
      img_h = (mat.texture && mat.texture.image_height > 0) ? mat.texture.image_height.to_f : 1.0
      aspect = (img_h > 0) ? (img_w / img_h) : 1.0
      height_in = width_in / aspect
      mat.texture.size = [width_in, height_in]

      center_x = cx + ox_in
      center_y = cy + oy_in
      half_w = width_in * 0.5
      half_h = height_in * 0.5

      rad = rot_angle * Math::PI / 180.0
      cos_a = Math.cos(rad)
      sin_a = Math.sin(rad)

      corners = [
        [-half_w, -half_h], # SW (0, 0)
        [ half_w, -half_h], # SE (1, 0)
        [ half_w,  half_h], # NE (1, 1)
        [-half_w,  half_h]  # NW (0, 1)
      ]

      pts = corners.map do |x, y|
        xr = x * cos_a - y * sin_a + center_x
        yr = x * sin_a + y * cos_a + center_y
        Geom::Point3d.new(xr, yr, 0.0)
      end

      pt_array = [
        pts[0], Geom::Point3d.new(0.0, 0.0, 0.0),
        pts[1], Geom::Point3d.new(1.0, 0.0, 0.0),
        pts[2], Geom::Point3d.new(1.0, 1.0, 0.0),
        pts[3], Geom::Point3d.new(0.0, 1.0, 0.0)
      ]

      model.start_operation('Adjust Aerial Texture', true, false, true)
      faces = terrain_group.entities.grep(Sketchup::Face)
      faces.each do |face|
        next unless face.valid?
        face.position_material(mat, pt_array, true)
        face.back_material = mat
      end
      model.commit_operation

      dict = model.attribute_dictionary('QuickDraft_Aerial', true)
      dict['image_path']     = image_path
      dict['world_width_ft'] = world_width_ft.to_f
      dict['offset_x_ft']    = offset_x_ft.to_f
      dict['offset_y_ft']    = offset_y_ft.to_f
      dict['rot_deg']        = rot_angle
    end

    def self.generate_aerial_adjuster_html(img_name, img_w, img_h, width_ft, ox_ft, oy_ft, rot_deg, lot_w_ft, lot_h_ft)
      aspect = (img_h > 0) ? (img_w.to_f / img_h.to_f) : 1.0
      <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>QuickDraft Aerial Adjuster</title>
        <style>
          * { box-sizing: border-box; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            margin: 0; padding: 12px; background: #f8fafc; color: #1e293b; font-size: 13px; user-select: none;
          }
          .header {
            margin-bottom: 12px; padding-bottom: 8px; border-bottom: 1px solid #e2e8f0;
          }
          .title { font-size: 15px; font-weight: 700; color: #0f172a; display: flex; align-items: center; justify-content: space-between; }
          .subtitle { font-size: 11px; color: #64748b; margin-top: 2px; }
          .card {
            background: #ffffff; border: 1px solid #e2e8f0; border-radius: 8px;
            padding: 10px 12px; margin-bottom: 10px; box-shadow: 0 1px 2px rgba(0,0,0,0.04);
          }
          .row-header {
            display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;
          }
          .row-title { font-weight: 600; font-size: 12px; color: #334155; text-transform: uppercase; letter-spacing: 0.5px; }
          .badge {
            background: #e0f2fe; color: #0284c7; padding: 2px 7px; border-radius: 4px;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; font-weight: 600;
          }
          .slider-row { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
          input[type=range] {
            flex: 1; height: 6px; border-radius: 3px; background: #cbd5e1; outline: none; cursor: pointer;
          }
          .btn-group { display: flex; gap: 4px; justify-content: center; }
          button {
            background: #f1f5f9; border: 1px solid #cbd5e1; border-radius: 5px;
            padding: 6px 10px; font-size: 11px; font-weight: 600; color: #334155; cursor: pointer;
            transition: all 0.15s ease;
          }
          button:hover { background: #e2e8f0; color: #0f172a; border-color: #94a3b8; }
          button:active { background: #cbd5e1; }
          .btn-primary { background: #0284c7; color: #ffffff; border-color: #0284c7; }
          .btn-primary:hover { background: #0369a1; color: #ffffff; border-color: #0369a1; }
          .btn-preset { background: #f0fdf4; color: #166534; border-color: #bbf7d0; font-weight: 700; }
          .btn-preset:hover { background: #dcfce7; color: #14532d; border-color: #86efac; }
          .dpad {
            display: grid; grid-template-columns: repeat(3, 44px); grid-template-rows: repeat(3, 34px);
            gap: 5px; justify-content: center; margin: 8px 0;
          }
          .dpad button {
            font-size: 14px; padding: 0; display: flex; align-items: center; justify-content: center;
          }
          .step-row {
            display: flex; justify-content: center; align-items: center; gap: 6px; margin-top: 6px;
          }
          .step-btn { padding: 3px 8px; font-size: 10px; border-radius: 3px; }
          .step-btn.active { background: #0f172a; color: #fff; border-color: #0f172a; }
          .preset-grid {
            display: grid; grid-template-columns: 1fr 1fr; gap: 6px; margin-top: 4px;
          }
          .footer-actions {
            display: flex; gap: 6px; margin-top: 14px;
          }
          .footer-actions button { flex: 1; padding: 8px 6px; font-size: 11px; }
        </style>
      </head>
      <body>
        <div class="header">
          <div class="title">
            <span>Aerial Photo Skinning</span>
            <span style="font-size:11px; font-weight:normal; color:#0284c7;">QuickDraft</span>
          </div>
          <div class="subtitle" id="img-name">#{img_name} (#{img_w.to_i} &times; #{img_h.to_i} px)</div>
        </div>

        <!-- 1. SCALE CONTROLS -->
        <div class="card">
          <div class="row-header">
            <span class="row-title">Scale / Width</span>
            <span class="badge" id="width-badge">#{width_ft.round(1)} ft</span>
          </div>
          <div class="slider-row">
            <input type="range" id="width-slider" min="50" max="800" step="1" value="#{width_ft.round(1)}">
          </div>
          <div class="btn-group">
            <button onclick="scaleBy(0.90)">-10%</button>
            <button onclick="scaleBy(0.98)">-2%</button>
            <button onclick="scaleBy(1.02)">+2%</button>
            <button onclick="scaleBy(1.10)">+10%</button>
          </div>
        </div>

        <!-- 2. POSITION CONTROLS -->
        <div class="card">
          <div class="row-header">
            <span class="row-title">Position (Nudge)</span>
            <span class="badge" id="pos-badge">X: #{ox_ft >= 0 ? '+' : ''}#{ox_ft.round(1)} | Y: #{oy_ft >= 0 ? '+' : ''}#{oy_ft.round(1)} ft</span>
          </div>
          <div class="dpad">
            <div></div>
            <button onclick="nudge(0, 1)">&#9650;</button>
            <div></div>
            <button onclick="nudge(-1, 0)">&#9664;</button>
            <button onclick="resetPos()" style="font-size:10px;">&#8226;</button>
            <button onclick="nudge(1, 0)">&#9654;</button>
            <div></div>
            <button onclick="nudge(0, -1)">&#9660;</button>
            <div></div>
          </div>
          <div class="step-row">
            <span style="font-size:10px; color:#64748b; font-weight:600;">STEP:</span>
            <button class="step-btn" onclick="setStep(20, this)">20 ft</button>
            <button class="step-btn active" onclick="setStep(5, this)">5 ft</button>
            <button class="step-btn" onclick="setStep(1, this)">1 ft</button>
            <button class="step-btn" onclick="setStep(0.2, this)">0.2 ft</button>
          </div>
        </div>

        <!-- 3. ROTATION CONTROLS -->
        <div class="card">
          <div class="row-header">
            <span class="row-title">Rotation</span>
            <span class="badge" id="rot-badge">#{rot_deg.round(1)}&deg;</span>
          </div>
          <div class="slider-row">
            <input type="range" id="rot-slider" min="-180" max="180" step="0.5" value="#{rot_deg.round(1)}">
          </div>
          <div class="btn-group">
            <button onclick="rotateBy(-5)">&#8634; 5&deg;</button>
            <button onclick="rotateBy(-0.5)">&#8634; 0.5&deg;</button>
            <button onclick="rotateBy(0.5)">&#8635; 0.5&deg;</button>
            <button onclick="rotateBy(5)">&#8635; 5&deg;</button>
          </div>
        </div>

        <!-- 4. QUICK PRESETS -->
        <div class="card">
          <div class="row-title" style="margin-bottom:6px;">Smart Alignment Presets</div>
          <div class="preset-grid">
            <button class="btn-preset" onclick="presetLandsEndGIS()" style="grid-column: span 2;">
              &#10024; Lands End 618 GIS Calibrated (321.5 ft)
            </button>
            <button onclick="presetLotWidth()">Fit Lot Width (#{lot_w_ft.round(0)} ft)</button>
            <button onclick="presetLotHeight()">Fit Lot Height (#{lot_h_ft.round(0)} ft)</button>
          </div>
        </div>

        <!-- 5. FOOTER ACTIONS -->
        <div class="footer-actions">
          <button onclick="pickNewImage()">&#128194; Pick Image...</button>
          <button onclick="resetTint()">&#127912; Reset Tint</button>
          <button class="btn-primary" onclick="closeDialog()">Done</button>
        </div>

        <script>
          let state = {
            width_ft: #{width_ft.to_f},
            ox_ft:    #{ox_ft.to_f},
            oy_ft:    #{oy_ft.to_f},
            rot_deg:  #{rot_deg.to_f},
            step_ft:  5.0,
            lot_w:    #{lot_w_ft.to_f},
            lot_h:    #{lot_h_ft.to_f}
          };

          function sendUpdate() {
            document.getElementById('width-badge').textContent = state.width_ft.toFixed(1) + ' ft';
            document.getElementById('width-slider').value = state.width_ft;

            let xSign = state.ox_ft >= 0 ? '+' : '';
            let ySign = state.oy_ft >= 0 ? '+' : '';
            document.getElementById('pos-badge').textContent = 'X: ' + xSign + state.ox_ft.toFixed(1) + ' | Y: ' + ySign + state.oy_ft.toFixed(1) + ' ft';

            document.getElementById('rot-badge').innerHTML = state.rot_deg.toFixed(1) + '&deg;';
            document.getElementById('rot-slider').value = state.rot_deg;

            if (window.sketchup && window.sketchup.update_aerial) {
              sketchup.update_aerial(state);
            }
          }

          document.getElementById('width-slider').addEventListener('input', function(e) {
            state.width_ft = parseFloat(e.target.value);
            sendUpdate();
          });

          document.getElementById('rot-slider').addEventListener('input', function(e) {
            state.rot_deg = parseFloat(e.target.value);
            sendUpdate();
          });

          function scaleBy(factor) {
            state.width_ft = Math.max(10.0, state.width_ft * factor);
            sendUpdate();
          }

          function nudge(dx, dy) {
            state.ox_ft += dx * state.step_ft;
            state.oy_ft += dy * state.step_ft;
            sendUpdate();
          }

          function resetPos() {
            state.ox_ft = 0.0;
            state.oy_ft = 0.0;
            sendUpdate();
          }

          function setStep(val, btn) {
            state.step_ft = parseFloat(val);
            document.querySelectorAll('.step-btn').forEach(b => b.classList.remove('active'));
            if (btn) btn.classList.add('active');
          }

          function rotateBy(deg) {
            state.rot_deg = Math.round((state.rot_deg + deg) * 10) / 10;
            if (state.rot_deg > 180) state.rot_deg -= 360;
            if (state.rot_deg < -180) state.rot_deg += 360;
            sendUpdate();
          }

          function presetLandsEndGIS() {
            state.width_ft = 321.5;
            state.ox_ft    = 17.8;
            state.oy_ft    = -4.1;
            state.rot_deg  = -0.5;
            sendUpdate();
          }

          function presetLotWidth() {
            state.width_ft = state.lot_w > 10 ? state.lot_w : 220.0;
            state.ox_ft    = 0.0;
            state.oy_ft    = 0.0;
            sendUpdate();
          }

          function presetLotHeight() {
            state.width_ft = (state.lot_h > 10 ? state.lot_h : 350.0) * (#{aspect});
            state.ox_ft    = 0.0;
            state.oy_ft    = 0.0;
            sendUpdate();
          }

          function pickNewImage() {
            if (window.sketchup && window.sketchup.pick_new_image) {
              sketchup.pick_new_image();
            }
          }

          function resetTint() {
            if (window.sketchup && window.sketchup.reset_tint) {
              sketchup.reset_tint();
            }
          }

          function closeDialog() {
            if (window.sketchup && window.sketchup.close_dialog) {
              sketchup.close_dialog();
            }
          }
        </script>
      </body>
      </html>
      HTML
    end

    def self.open_aerial_adjuster_dialog_from_menu
      model = Sketchup.active_model
      terrain_group = find_terrain_group(model)
      unless terrain_group && terrain_group.valid?
        UI.messagebox("No 'Site_Terrain' object found in the model.\nPlease import a survey or build terrain first.")
        return
      end

      dict = model.attribute_dictionary('QuickDraft_Aerial')
      image_path = dict ? dict['image_path'] : nil
      if image_path && File.exist?(image_path)
        open_aerial_adjuster_dialog(model, terrain_group, image_path)
      else
        apply_aerial_photo_dialog(true)
      end
    end

    def self.open_aerial_adjuster_dialog(model, terrain_group, image_path, initial_params = nil)
      if @aerial_adjuster_dialog && @aerial_adjuster_dialog.visible?
        @aerial_adjuster_dialog.bring_to_front
        return
      end

      dict = model.attribute_dictionary('QuickDraft_Aerial') || {}
      target_box = find_aerial_target_box(model, terrain_group)
      lot_w_ft = target_box.width / 12.0
      lot_h_ft = target_box.height / 12.0

      mat = model.materials[MAT_AERIAL_TEXTURE]
      img_w = (mat && mat.texture && mat.texture.image_width > 0) ? mat.texture.image_width.to_f : 1.0
      img_h = (mat && mat.texture && mat.texture.image_height > 0) ? mat.texture.image_height.to_f : 1.0

      is_lands_end = File.basename(image_path) =~ /Capture GIS/i || (dict['image_path'] && dict['image_path'] =~ /Lands end/i)
      width_ft = (dict['world_width_ft'] || (initial_params ? initial_params[:width_ft] : nil) || (is_lands_end ? 321.5 : (lot_w_ft * 1.5))).to_f
      ox_ft    = (dict['offset_x_ft']    || (initial_params ? initial_params[:ox_ft] : nil)    || (is_lands_end ? 17.8 : 0.0)).to_f
      oy_ft    = (dict['offset_y_ft']    || (initial_params ? initial_params[:oy_ft] : nil)    || (is_lands_end ? -4.1 : 0.0)).to_f
      rot_deg  = (dict['rot_deg']        || (initial_params ? initial_params[:rot_deg] : nil)  || (is_lands_end ? -0.5 : 0.0)).to_f

      dialog = UI::HtmlDialog.new(
        dialog_title: 'QuickDraft: Aerial Photo Adjuster',
        preferences_key: 'QuickDraft_Aerial_Adjuster',
        scrollable: false,
        resizable: true,
        width: 380,
        height: 620,
        min_width: 320,
        min_height: 520
      )

      html = generate_aerial_adjuster_html(
        File.basename(image_path),
        img_w,
        img_h,
        width_ft,
        ox_ft,
        oy_ft,
        rot_deg,
        lot_w_ft,
        lot_h_ft
      )
      dialog.set_html(html)

      dialog.add_action_callback('update_aerial') do |_action_context, data|
        w  = data['width_ft'].to_f
        ox = data['ox_ft'].to_f
        oy = data['oy_ft'].to_f
        r  = data['rot_deg'].to_f
        reproject_aerial_texture(model, terrain_group, image_path, w, ox, oy, r)
      end

      dialog.add_action_callback('pick_new_image') do |_action_context|
        dialog.close rescue nil
        @aerial_adjuster_dialog = nil
        apply_aerial_photo_dialog(true)
      end

      dialog.add_action_callback('reset_tint') do |_action_context|
        reset_terrain_material_dialog
      end

      dialog.add_action_callback('close_dialog') do |_action_context|
        dialog.close rescue nil
        @aerial_adjuster_dialog = nil
      end

      @aerial_adjuster_dialog = dialog
      dialog.show
    end

    def self.apply_aerial_photo_dialog(force_picker = false)
      model = Sketchup.active_model
      terrain_group = find_terrain_group(model)
      unless terrain_group && terrain_group.valid?
        UI.messagebox("No 'Site_Terrain' object found in the model.\nPlease import a survey or build terrain first.")
        return
      end

      dict = model.attribute_dictionary('QuickDraft_Aerial')
      existing_img = dict ? dict['image_path'] : nil

      if !force_picker && existing_img && File.exist?(existing_img)
        open_aerial_adjuster_dialog(model, terrain_group, existing_img)
        return
      end

      default_dir = ''
      site_dict = model.attribute_dictionary(DICT_SITE_DATA)
      if site_dict && site_dict['dwg_path'] && File.exist?(site_dict['dwg_path'].to_s)
        default_dir = File.dirname(site_dict['dwg_path'].to_s)
      end

      image_path = UI.openpanel("Select Aerial / Satellite Photo (JPG or PNG)", default_dir, "Image Files|*.jpg;*.jpeg;*.png;*.tif;*.tiff;*.bmp;*.webp||")
      return if image_path.nil? || !File.exist?(image_path)

      target_box = find_aerial_target_box(model, terrain_group)
      lot_w_ft = target_box.width / 12.0

      is_lands_end = File.basename(image_path) =~ /Capture GIS/i || (default_dir =~ /Lands end/i)
      initial_w   = is_lands_end ? 321.5 : (lot_w_ft * 1.5)
      initial_ox  = is_lands_end ? 17.8 : 0.0
      initial_oy  = is_lands_end ? -4.1 : 0.0
      initial_rot = is_lands_end ? -0.5 : 0.0

      reproject_aerial_texture(model, terrain_group, image_path, initial_w, initial_ox, initial_oy, initial_rot)

      open_aerial_adjuster_dialog(model, terrain_group, image_path, {
        width_ft: initial_w,
        ox_ft:    initial_ox,
        oy_ft:    initial_oy,
        rot_deg:  initial_rot
      })
    end

    def self.reset_terrain_material_dialog
      model = Sketchup.active_model
      terrain_group = find_terrain_group(model)
      unless terrain_group && terrain_group.valid?
        UI.messagebox("No 'Site_Terrain' object found in the model.")
        return
      end

      model.start_operation('Reset Terrain to Architectural Tint', true)
      mat = model.materials['QD_Site_Terrain'] || model.materials.add('QD_Site_Terrain')
      mat.color = Sketchup::Color.new(225, 235, 220)

      faces = terrain_group.entities.grep(Sketchup::Face)
      faces.each do |face|
        next unless face.valid?
        face.material = mat
        face.back_material = mat
      end
      model.commit_operation
      UI.messagebox("Terrain reset to clean architectural tint (QD_Site_Terrain).")
    end

    def self.ensure_tag(model, tag_name, color = nil)
      layer = model.layers[tag_name] || model.layers.add(tag_name)
      layer.color = color if color && layer.respond_to?(:color=)
      layer.visible = true if layer.respond_to?(:visible=)
      layer
    end
  end
end
