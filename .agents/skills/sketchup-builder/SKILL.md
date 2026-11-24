---
name: sketchup-builder
description: Rules and conventions for developing and packaging the QuickDraft SketchUp & LayOut Ruby extension.
---

# QuickDraft SketchUp Extension Rules

When writing or modifying code in this repository, strictly follow these SketchUp Ruby API rules:

1. **Namespace Isolation:** All code MUST live inside the `QuickDraft` top-level module (e.g., `module QuickDraft; module SurveyImporter; ...`). Never define global methods or constants outside `QuickDraft`.
2. **File Loading:** Use `Sketchup.require` (without `.rb` extensions) instead of Ruby's standard `require` so files work properly when encrypted/packaged into `.rbz`.
3. **Root Loader Purity:** `src/quick_draft.rb` must ONLY register the `SketchupExtension` object and call `Sketchup.register_extension`. Never put geometry, UI, or LayOut logic in `src/quick_draft.rb`.
4. **Undo Operations:** Wrap all model-modifying actions inside `model.start_operation('Action Name', true)` and `model.commit_operation` with a `rescue` block calling `model.abort_operation`.
5. **Units & Coordinates:** SketchUp's internal database unit is ALWAYS inches. Convert user-facing metric/imperial inputs using SketchUp's `Numeric` methods (e.g., `1.2.m`, `4.feet`).
6. **LayOut API Quirks:** When creating `Layout::SketchUpModel` viewports, ALWAYS add the viewport to the `Layout::Document` via `doc.add_entity` BEFORE setting `.current_scene=`, `.scale=`, or `.render_mode=`.
7. **Packaging:** Run `python build.py` to generate `dist/quick_draft.rbz`. The archive root must contain `quick_draft.rb` and the `quick_draft/` directory directly (no wrapping `src/` folder).

---

## Architectural Permit Pipeline Domain Rules

### Phase 1: Site & Survey Setup (`survey_importer.rb`)
- **Site Normalization:** Always isolate imported CAD geometry in a `Site_Survey` group and translate its bounding box XY center to `[0, 0, 0]` while keeping true Z elevation. Store original Easting, Northing, and Z offsets in the `QuickDraft_SiteData` attribute dictionary on the model root.
- **TIN Terrain Generation:** Contour edges on mapped layers must be sampled and triangulated into a continuous 3D terrain surface under a `Site_Terrain` group tagged `SITE-TERRAIN`. Soften and smooth mesh edges to provide clean contours.
- **Boundary Draping:** Property / lot lines from mapped boundary layers must be projected onto the terrain surface and assigned to the `SITE-PROPERTY-LINE` tag.
- **Proxy Trees:** Survey tree markers/blocks must be replaced with lightweight 3D architectural tree proxy components placed at survey marker coordinates on the `SITE-TREES-EXISTING` tag.

### Phase 2: Permit Set Scene Cutting (`scene_cutter.rb`)
- **Camera Standards:** Architectural permit scenes must use parallel projection (`camera.perspective = false`) aligned with cardinal axes.
- **Section Cut Heights:** Horizontal plan sections must be cut 48" (`4.feet` / `1.2.m`) above each finished floor level with section cut display enabled and section plane outlines hidden.
- **Scene Naming Standards:**
  - `A1.0 - Site Plan` (Top view showing roof plan, lot lines, setbacks, and existing trees)
  - `A2.1 - Level 1 Floor Plan`, `A2.2 - Level 2 Floor Plan`, etc.
  - `A3.1 - North Elevation`, `A3.2 - South Elevation`, `A3.3 - East Elevation`, `A3.4 - West Elevation`
  - `A4.1 - Longitudinal Section`, `A4.2 - Transverse Section`

### Phase 3: LayOut Document Generation (`layout_generator.rb`)
- **Template Fallback:** If `templates/titleblock.layout` is absent, programmatically construct a standard Arch D (36" x 24") sheet document.
- **Viewport Binding Sequence:** Always attach viewport entities to the page/document before modifying scale, scene, or rendering mode.
- **Render Modes:** Use `Layout::SketchUpModel::HYBRID_RENDER_MODE` or `VECTOR_RENDER_MODE` for crisp architectural linework.
- **Municipal Sea-Level Datums:** Elevation annotations on sheets must retrieve the `QuickDraft_SiteData` dictionary to display true sea-level heights alongside relative building heights.
