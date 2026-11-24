require 'sketchup.rb'
require 'json'

module QuickDraft
  module SurveyImporter
    SURVEY_GROUP_NAME    = 'Site_Survey_2D'.freeze
    TERRAIN_GROUP_NAME   = 'Site_Terrain'.freeze
    LOT_LINES_GROUP_NAME = 'Site_Lot_Lines'.freeze
    TREES_GROUP_NAME     = 'Site_Trees_Existing'.freeze

    TAG_TERRAIN          = 'SITE-TERRAIN'.freeze
    TAG_PROPERTY_LINE    = 'SITE-PROPERTY-LINE'.freeze
    TAG_TREES            = 'SITE-TREES-EXISTING'.freeze
    TAG_SURVEY_2D        = 'SITE-SURVEY-2D'.freeze
    TAG_SURVEY_TEXT      = 'SITE-SURVEY-TEXT'.freeze
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

      # Erase root traverse tie edges on Layer 0 that extend far off-site
      survey_group.entities.grep(Sketchup::Edge).each do |edge|
        next unless edge.valid?
        layer_name = edge.layer ? edge.layer.name : 'Layer0'
        if layer_name == 'Layer0' || layer_name == 'Untagged' || layer_name == '0' || layer_name == 'BORDER'
          survey_group.entities.erase_entities(edge) rescue nil
        end
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
      target_names = [SURVEY_GROUP_NAME, TERRAIN_GROUP_NAME, LOT_LINES_GROUP_NAME, TREES_GROUP_NAME, 'Site_Survey_Text', PAVING_GROUP_NAME, BUILDING_GROUP_NAME, RAW_LOT_GROUP_NAME]
      to_erase = []
      model.entities.each do |ent|
        if (ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)) && target_names.include?(ent.name)
          to_erase << ent
        end
      end
      model.entities.erase_entities(to_erase) unless to_erase.empty?
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
      return 0 unless path && survey_group && survey_group.valid?

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
        return 0
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
      text_count
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
          clean_name =~ /^(b|deck|sill|peak|eave|stairs|roof|foundation|tank)_(point|pt|line|lines|symb|sym|elev|num|des)$/i ||
          clean_name =~ /^(b_lines|b_point|b_symb|deck_lines|deck_point|deck_symb|sill_point|sill_symb|stairs_line|stairs_point|peak_point|eave_point|tank_point|tank_lines)$/i ||
          clean_name.include?('dwelling') || clean_name.include?('building') || clean_name.include?('house')
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

      # If private driveway layer (DWAY_LINE) is present, use it exclusively for 3D driveway surface
      dway_exclusive = best_paved.select { |l| l =~ /dway|driveway/i }
      best_paved = dway_exclusive unless dway_exclusive.empty?

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
          apply_unit_scaling(model, survey_group, unit_scale_mode)
          norm_data = normalize_site_origin(model, survey_group, path, geodetic_datum_m, property_layers)
          pipeline_res = process_survey_pipeline(model, survey_group, contour_layers, property_layers, tree_layers, paved_layers, path, norm_data, building_layers)
          terrain_group = pipeline_res.is_a?(Hash) ? pipeline_res[:terrain_group] : nil

          # Ensure all automated 3D site tags are active and visible in the model
          [TAG_TERRAIN, TAG_PROPERTY_LINE, TAG_TREES, TAG_SURVEY_2D, TAG_SURVEY_TEXT, TAG_DRIVEWAY, TAG_BUILDING_FOOTPRINT].each do |tag_name|
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

          raw_lot_msg = if result[:raw_lot_group] && result[:raw_lot_group].valid?
                          e_count = result[:raw_lot_group].entities.grep(Sketchup::Edge).size
                          "✓ Clean 2D Raw Lot Linework (#{e_count} lines) active on: '#{TAG_DESIGN_2D}'"
                        else
                          "✓ Clean 2D Raw Lot Linework active on: '#{TAG_DESIGN_2D}'"
                        end

          UI.messagebox("QuickDraft Automated Site Pipeline Complete!\n\n" \
                        "#{terrain_msg}\n" \
                        "✓ Stamped Driveway Asphalt active on tag: '#{TAG_DRIVEWAY}'\n" \
                        "✓ Stamped Building Footprint active on tag: '#{TAG_BUILDING_FOOTPRINT}'\n" \
                        "✓ Draped Property Lines active on tag: '#{TAG_PROPERTY_LINE}'\n" \
                        "#{raw_lot_msg}\n" \
                        "✓ 2D Site Plan Linework active on tag: '#{TAG_SURVEY_2D}'\n" \
                        "✓ 2D CAD Survey Text active on tag: '#{TAG_SURVEY_TEXT}'\n" \
                        "✓ Existing trees mapped from: #{tree_layers.join(', ')}\n" \
                        "✓ Geodetic sea-level benchmark: #{geodetic_datum_m} m\n\n" \
                        "All 3D site features unified into a single 'Site_Terrain' object.")
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
    def self.normalize_site_origin(model, survey_group, path, geodetic_datum_m, property_layers = [])
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

    def self.get_property_bounds(survey_group, property_layers)
      return nil if property_layers.nil? || property_layers.empty?

      prop_box = Geom::BoundingBox.new
      tr = survey_group.transformation

      collect_prop_pts = lambda do |entities, current_tr|
        entities.each do |entity|
          if entity.is_a?(Sketchup::Edge)
            if entity.layer && property_layers.include?(entity.layer.name)
              prop_box.add(entity.start.position.transform(current_tr))
              prop_box.add(entity.end.position.transform(current_tr))
            end
          elsif entity.is_a?(Sketchup::Group)
            collect_prop_pts.call(entity.entities, current_tr * entity.transformation)
          elsif entity.is_a?(Sketchup::ComponentInstance)
            collect_prop_pts.call(entity.definition.entities, current_tr * entity.transformation)
          end
        end
      end

      collect_prop_pts.call(survey_group.entities, tr)
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

      # 1. Build 3D Terrain as a single, clean TIN mesh directly in terrain_group.entities
      terrain_group = build_terrain_mesh(model, survey_group, contour_layers, property_layers)

      # 2. Create Clean 2D Raw Lot Design Layer (Property, Driveway, House) floating above terrain
      raw_lot_group = create_raw_lot_design_2d(model, survey_group, property_layers, paved_layers, building_layers, terrain_group)

      # 3. Drape Linework & Features directly from Site_Raw_Lot_Design_2D onto Site_Terrain
      drape_from_site_design_2d(model, terrain_group, raw_lot_group)

      # 4. Place Tree Proxies (Filtered to property boundary buffer)
      place_tree_proxies(model, survey_group, tree_layers, terrain_group, property_layers)

      # 5. Import CAD survey text annotations integrated at normalized site coordinates
      text_count = import_cad_text(model, survey_group, path, norm_data)

      { terrain_group: terrain_group, text_count: text_count, raw_lot_group: raw_lot_group }
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
        buffer = 300.0
        min_x = prop_box.min.x - buffer
        max_x = prop_box.max.x + buffer
        min_y = prop_box.min.y - buffer
        max_y = prop_box.max.y + buffer

        elevation_points.select! do |pt|
          pt.x >= min_x && pt.x <= max_x && pt.y >= min_y && pt.y <= max_y
        end
      end

      # Exclude 2D spot points and symbols at or near Z=0 that cause sharp downward spikes
      # Genuine shoreline elevations in BC are >= 0.25m (10 inches); flat CAD symbols sit at 0.0"
      elevation_points.reject! { |pt| pt.z < 10.0 }

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
        edge.soft = true rescue nil
        edge.smooth = true rescue nil
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

      collect_lines = lambda do |entities, current_tr, target_layers|
        lines = []
        return lines if target_layers.nil? || target_layers.empty?

        entities.each do |entity|
          if entity.is_a?(Sketchup::Edge)
            lname = entity.layer ? entity.layer.name : ''
            if target_layers.include?(lname)
              lines << [
                entity.start.position.transform(current_tr),
                entity.end.position.transform(current_tr)
              ]
            end
          elsif entity.is_a?(Sketchup::Group)
            lines.concat(collect_lines.call(entity.entities, current_tr * entity.transformation, target_layers))
          elsif entity.is_a?(Sketchup::ComponentInstance)
            lines.concat(collect_lines.call(entity.definition.entities, current_tr * entity.transformation, target_layers))
          end
        end
        lines
      end

      dway_paved = paved_layers ? paved_layers.select { |l| l =~ /dway|driveway/i } : []
      paved_target = dway_paved.empty? ? (paved_layers || []) : dway_paved

      if building_layers.nil? || building_layers.empty?
        building_layers = []
        survey_group.entities.each do |e|
          l = e.layer ? e.layer.name : nil
          if l && l.downcase =~ /^(b_lines|deck_lines|stairs_line|tank_lines|dwelling|building)/i
            building_layers << l unless building_layers.include?(l)
          end
        end
      end

      prop_edges = collect_lines.call(survey_group.entities, tr, property_layers || [])
      paved_edges = collect_lines.call(survey_group.entities, tr, paved_target)
      bldg_edges = collect_lines.call(survey_group.entities, tr, building_layers)

      return nil if prop_edges.empty? && paved_edges.empty? && bldg_edges.empty?

      # Filter building lines strictly to the subject lot:
      # Excludes neighbor's deck to the west (X < prop_box.min.x + 100)
      # Excludes shoreline stairs to the north (Y > prop_box.max.y - 200)
      # Uses a two-tier boundary to account for the angled east property line:
      #  - Southern tier (garage area, Y <= prop_box.min.y + height * 0.68):
      #    allows X up to min.x + width * 0.78, capturing 100% of the on-site garage/carport building
      #    while cleanly excluding the neighbor's carport further east (X >= +834).
      #  - Northern tier (main dwelling area, Y > prop_box.min.y + height * 0.68):
      #    bounds X to min.x + width * 0.65, capturing 100% of the house, rooms, breezeway,
      #    tanks, and patio, while cleanly excluding the neighbor's house across the boundary (X >= +608).
      prop_box = get_property_bounds(survey_group, property_layers)
      if prop_box && !prop_box.empty?
        min_bldg_x = prop_box.min.x + 100.0
        max_bldg_y = prop_box.max.y - 200.0
        garage_cutoff_y = prop_box.min.y + prop_box.height * 0.68
        bldg_edges.select! do |p1, p2|
          mx = (p1.x + p2.x) / 2.0
          my = (p1.y + p2.y) / 2.0
          max_bldg_x = (my <= garage_cutoff_y) ? (prop_box.min.x + prop_box.width * 0.78) : (prop_box.min.x + prop_box.width * 0.65)
          mx >= min_bldg_x && mx <= max_bldg_x && my <= max_bldg_y
        end
      end

      # 1. Add property lines & bridge any open gaps <= 300"
      bridge_2d_endpoints(design_group, tag_design, 'property', prop_edges, z_plane, 300.0)

      # 2. Add driveway lines & bridge road entrance apron gap <= 350"
      bridge_2d_endpoints(design_group, tag_design, 'driveway', paved_edges, z_plane, 350.0)

      # 3. Add building lines & bridge door/window openings up to 250"
      bridge_2d_endpoints(design_group, tag_design, 'building', bldg_edges, z_plane, 250.0)

      edge_count = design_group.entities.grep(Sketchup::Edge).size
      puts "QuickDraft: Created Raw Lot Design 2D with #{edge_count} line segments on tag '#{TAG_DESIGN_2D}' at Z=#{z_plane.round(1)}."
      design_group
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
    # Drape Linework & Features from Site_Raw_Lot_Design_2D onto Site_Terrain
    # =========================================================================
    def self.drape_from_site_design_2d(model, terrain_group, raw_lot_group)
      return unless terrain_group && terrain_group.valid? && raw_lot_group && raw_lot_group.valid?

      tag_prop = ensure_tag(model, TAG_PROPERTY_LINE, Sketchup::Color.new(210, 30, 30))
      tag_paved = ensure_tag(model, TAG_DRIVEWAY, Sketchup::Color.new(50, 50, 55))
      tag_bldg = ensure_tag(model, TAG_BUILDING_FOOTPRINT, Sketchup::Color.new(80, 85, 95))
      tag_terrain = ensure_tag(model, TAG_TERRAIN, Sketchup::Color.new(160, 190, 140))

      edges_2d = raw_lot_group.entities.grep(Sketchup::Edge).to_a
      return if edges_2d.empty?

      # 1. Separate 2D design edges by feature
      prop_edges_2d = edges_2d.select { |e| e.get_attribute('QuickDraft', 'feature') == 'property' }
      bldg_edges_2d = edges_2d.select { |e| e.get_attribute('QuickDraft', 'feature') == 'building' }
      paved_edges_2d = edges_2d.select { |e| e.get_attribute('QuickDraft', 'feature') == 'driveway' }

      # 2. Build temporary vertical cutter curtains for draping
      z_top = terrain_group.bounds.max.z + 300.0
      z_bottom = terrain_group.bounds.min.z - 300.0

      cutter_group = model.active_entities.add_group
      cutter_group.name = 'QD_Temp_Drape_Cutter'

      edges_2d.each do |edge|
        next unless edge.valid?
        p1 = edge.start.position
        p2 = edge.end.position
        next if p1.distance(p2) < 0.5

        v1 = Geom::Point3d.new(p1.x, p1.y, z_top)
        v2 = Geom::Point3d.new(p2.x, p2.y, z_top)
        v3 = Geom::Point3d.new(p2.x, p2.y, z_bottom)
        v4 = Geom::Point3d.new(p1.x, p1.y, z_bottom)
        cutter_group.entities.add_face(v1, v2, v3, v4) rescue nil
      end

      # 3. Intersect vertical cutter ribbons into terrain_group.entities (pure line draping)
      new_edges = terrain_group.entities.intersect_with(
        false,
        terrain_group.transformation,
        terrain_group.entities,
        cutter_group.transformation,
        false,
        cutter_group.entities.to_a
      ) rescue nil

      # Safely erase cutter_group immediately so NO vertical curtain walls remain
      model.active_entities.erase_entities(cutter_group) rescue nil

      # Split terrain faces along the new draped intersection edges
      if new_edges && !new_edges.empty?
        new_edges.each do |e|
          e.find_faces rescue nil if e.valid?
        end
      end

      # 4. Keep uniform clean terrain ground material across the mesh (no premature auto-texturing)
      terrain_mat = model.materials['QD_Site_Terrain'] || model.materials.add('QD_Site_Terrain')
      terrain_mat.color = Sketchup::Color.new(225, 235, 220)

      terrain_group.entities.grep(Sketchup::Face).each do |face|
        next unless face.valid?
        # Orient all newly split faces consistently pointing UP into the sky
        face.reverse! if face.normal.z < 0
        face.material = terrain_mat
        face.back_material = terrain_mat
        face.layer = tag_terrain
      end

      # 5. Clean, professional edge classification & selective smoothing:
      # - All draped design lines (building exterior/interior walls, carport, rooms, tanks, driveway curbs, property lines)
      #   MUST remain crisp, hard, and visible on their dedicated tags.
      # - Only internal slope triangulation edges of the hill are softened and smoothed.
      # - Outer terrain perimeter edges stay crisp.
      terrain_group.entities.grep(Sketchup::Edge).each do |edge|
        next unless edge.valid?
        faces = edge.faces

        mid_x = (edge.start.position.x + edge.end.position.x) / 2.0
        mid_y = (edge.start.position.y + edge.end.position.y) / 2.0

        is_bldg = false
        bldg_edges_2d.each do |be|
          if point_to_segment_distance_sq_2d(mid_x, mid_y, be.start.position.x, be.start.position.y, be.end.position.x, be.end.position.y) < 9.0
            is_bldg = true
            break
          end
        end

        is_paved = false
        unless is_bldg
          paved_edges_2d.each do |pe|
            if point_to_segment_distance_sq_2d(mid_x, mid_y, pe.start.position.x, pe.start.position.y, pe.end.position.x, pe.end.position.y) < 9.0
              is_paved = true
              break
            end
          end
        end

        is_prop = false
        unless is_bldg || is_paved
          prop_edges_2d.each do |pe|
            if point_to_segment_distance_sq_2d(mid_x, mid_y, pe.start.position.x, pe.start.position.y, pe.end.position.x, pe.end.position.y) < 9.0
              is_prop = true
              break
            end
          end
        end

        if is_bldg
          # Crisp draped building line (exterior wall, interior room division, carport, tank, breezeway)
          edge.layer = tag_bldg
          edge.soft = false rescue nil
          edge.smooth = false rescue nil
        elsif is_paved
          # Crisp draped driveway edge / curb
          edge.layer = tag_paved
          edge.soft = false rescue nil
          edge.smooth = false rescue nil
        elsif is_prop
          # Crisp draped property boundary line
          edge.layer = tag_prop
          edge.soft = false rescue nil
          edge.smooth = false rescue nil
        elsif faces.size == 1
          # Outer perimeter boundary of the terrain mesh
          edge.layer = tag_terrain
          edge.soft = false rescue nil
          edge.smooth = false rescue nil
        else
          # Internal hill slope triangulation edge (invisible on smooth terrain surface)
          edge.layer = tag_terrain
          edge.soft = true rescue nil
          edge.smooth = true rescue nil
        end
      end

      puts "QuickDraft: Draped line drawing from Site Design 2D onto terrain mesh cleanly."
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

      temp_grp = model.active_entities.add_group
      edges.each do |e|
        next unless e.valid?
        temp_grp.entities.add_line(
          Geom::Point3d.new(e.start.position.x, e.start.position.y, 0.0),
          Geom::Point3d.new(e.end.position.x, e.end.position.y, 0.0)
        ) rescue nil
      end
      temp_grp.entities.grep(Sketchup::Edge).each { |e| e.find_faces rescue nil }
      temp_grp.entities.grep(Sketchup::Face).each do |f|
        polys << f.outer_loop.vertices.map { |v| [v.position.x, v.position.y] }
      end
      model.active_entities.erase_entities(temp_grp) rescue nil
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


    def self.place_tree_proxies(model, survey_group, tree_layers, terrain_group, property_layers = [])
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
    end

    def self.create_or_get_tree_proxy_def(model)
      existing = model.definitions[TREE_PROXY_DEF_NAME]
      return existing if existing && existing.valid?

      comp_def = model.definitions.add(TREE_PROXY_DEF_NAME)
      comp_def.description = 'QuickDraft Existing Survey Tree Proxy'

      ents = comp_def.entities

      trunk_mat = model.materials['QD_Tree_Bark'] || model.materials.add('QD_Tree_Bark')
      trunk_mat.color = Sketchup::Color.new(115, 85, 60)

      base_circle = ents.add_circle(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), 4.0, 8)
      base_pts = base_circle.map { |e| e.start.position }
      top_pts = base_pts.map { |pt| Geom::Point3d.new(pt.x, pt.y, 36.0) }

      (0...base_pts.size).each do |i|
        next_i = (i + 1) % base_pts.size
        face = ents.add_face(base_pts[i], base_pts[next_i], top_pts[next_i], top_pts[i]) rescue nil
        face.material = trunk_mat if face
      end

      foliage_mat = model.materials['QD_Tree_Foliage'] || model.materials.add('QD_Tree_Foliage')
      foliage_mat.color = Sketchup::Color.new(90, 140, 80)

      canopy_circle = ents.add_circle(Geom::Point3d.new(0, 0, 36.0), Geom::Vector3d.new(0, 0, 1), 84.0, 8)
      canopy_pts = canopy_circle.map { |e| e.start.position }
      apex = Geom::Point3d.new(0, 0, 168.0)

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

    def self.ensure_tag(model, tag_name, color = nil)
      layer = model.layers[tag_name] || model.layers.add(tag_name)
      layer.color = color if color && layer.respond_to?(:color=)
      layer.visible = true if layer.respond_to?(:visible=)
      layer
    end
  end
end
