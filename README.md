# Quick-Draft

QuickDraft is a Trimble SketchUp & LayOut extension designed to automate architectural site modeling and construction documentation workflows directly from surveyor CAD data (DWG/DXF).

## Features
- **Automated Survey CAD Setup:** Auto-detects topo contours, property boundaries, tree inventories, asphalt driveways, and building footprints from surveyor DWG layers.
- **3D Terrain Generation:** Generates a clean 3D TIN terrain mesh using constrained Delaunay triangulation with automatic geodetic origin normalization.
- **2D Linework Draping:** Drapes site design linework (property lines, paved driveways, and building footprints) with crisp unsoftened edges directly onto the 3D terrain.
- **Arborist Tree Proxies:** Automatically places 3D tree proxies positioned at surveyed elevations with trunk diameter and canopy dimensions based on CAD tags.
- **2D Site Drafting Layer:** Retains clean, bridged 2D CAD drafting linework on a dedicated floating design tag.

## Repository Structure
```
QuickDraft/
├── .agents/skills/    # Agent skills & development conventions
├── src/               # Extension source code
│   ├── quick_draft.rb # Root extension loader
│   └── quick_draft/   # Core modules, icons & utilities
├── templates/         # Drawing and title block templates
├── build.py           # RBZ packaging & auto-deploy script
├── README.md
└── .gitignore
```

## Building & Installation
Run the build script to package the extension into an `.rbz` file:
```bash
python build.py
```
This builds `dist/quick_draft.rbz` and auto-deploys the live extension files to the Trimble SketchUp 2020 Plugins directory if installed.
