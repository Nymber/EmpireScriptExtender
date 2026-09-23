# ESE toolkit index

Use [README.md](README.md) for installation and normal use. This file maps the
developer tools and research documents.

## Entry points

| File | Purpose |
|---|---|
| `ESE Manager.cmd` | Double-click install, check, launch, and uninstall menu |
| `empire.ps1` | Stable command-line interface for routine workflows |
| `shell.ps1` | Interactive catalogue of PowerShell helpers |
| `empire_paths.ps1` / `.rb` | Dynamic Empire, toolkit, and Steam path discovery |
| `cleanup.ps1` | Evidence-based obsolete-file audit; dry-run by default |

Common commands:

```powershell
.\empire.ps1 install
.\empire.ps1 doctor
.\empire.ps1 launch
.\empire.ps1 sync
.\empire.ps1 build
.\empire.ps1 deploy
.\empire.ps1 release
.\empire.ps1 mods
.\empire.ps1 enable fp
.\empire.ps1 disable fp
.\empire.ps1 hipoly -Only euro_line
.\empire.ps1 hipoly -Deploy
.\empire.ps1 lod 3.0 -Deploy
```

## Source and live trees

The toolkit containing this file is authoritative. Empire reads a mirror at
`<game>\EmpireScriptExtender` plus two loader files in the game root.

- Edit Lua and tools here.
- Run `empire.ps1 sync`, `install`, or `launch` to update the live mirror.
- Do not develop in the live mirror.
- Generated packs and `staged/` are local output and are not release source.

## Layout

```text
EmpireScriptExtender/
  ESE Manager.cmd
  empire.ps1
  empire_paths.ps1 / empire_paths.rb
  README.md / INDEX.md / cleanup.ps1 / shell.ps1
  src/        native ESE source, build, live console, battle launcher
  lua/        campaign, UI, and battle mods
  config/     runtime data copied beside Empire.exe
  docs/       reference, evidence, limitations, and roadmaps
  tools/
    behavior/ behavior-to-code analysis
    db/       database readers and checks
    engine/   engine scans, LOD tools, and research helpers
    game/     launch and UI-driving helpers
    mesh/     weighted and rigid mesh processing
    pack/     PFH pack build/extract
    texture/  texture conversion and upscaling
    trademod/ trade/economy generators
    ui/       shared UI pack helpers
  staged/     generated local output; ignored and never released
```

The parent `Total war empire tools` folder holds third-party tools such as
Ghidra and its project. `empire_paths` reports this as `ToolsDir`; it is distinct
from ESE's `KitDir`.

## Read by task

### Installation, safety, and extension

| Document | Use |
|---|---|
| `docs/INSTALLATION_AND_USAGE.md` | User journey, installer decisions, release checklist |
| `docs/MOD_SYSTEM.md` | Manifests, activation, dependencies, shared event and frame hooks |
| `docs/REVIEW_SECURITY_AND_MODDING.md` | Trust model, mod approaches, failure modes, limitations |
| `lua/README.md` | Add and load a Lua mod |
| `docs/NATIVE_FRAMEWORK_SKETCH.md` | Native Lua 5.1 binding model |

### First-person and battle work

| Document | Use |
|---|---|
| `docs/ROADMAP_FIRST_PERSON.md` | Current finish checklist and live verification |
| `docs/FPS_MOD_API_TREE.md` | Entity, unit, camera, terrain, order, and projectile graph |
| `docs/LUA_API.md` | Campaign, UI, and battle Lua surfaces |
| `docs/ESE_TRACING_AND_PATCHING.md` | Runtime tracing, register capture, scanning, patch limits |
| `docs/ROADMAP_VR.md` | Longer-range camera and rendering path |

### Asset work

| Document | Use |
|---|---|
| `docs/ROADMAP_HIGH_POLY_UNITS.md` | Reproducible mesh build and remaining work |
| `docs/SKINNING_AND_BONE_CEILING.md` | Measured shader/bone budget and options |

### Campaign and engine work

| Document | Use |
|---|---|
| `docs/ROADMAP_PRODUCTION_CHAINS.md` | Production-chain implementation status |
| `docs/ROADMAP_20_COMMODITIES.md` | Commodity-extension status |
| `docs/ENGINE_MAP.md` | General native engine map |
| `docs/FINDINGS.md` | Ghidra and runtime findings |
| `docs/HOOK_TARGETS.md` | Hookable database accessors |

### Behavior-to-code tools

| Document | Use |
|---|---|
| `docs/BEHAVIOR_TO_CODE.md` | Trace schema, dependency slicing, causal experiments, models |
| `docs/MEMORY_TOOLS_AND_SYNC_RULE.md` | Tool inventory and authoritative/live sync rule |

## Evidence labels

Engine documentation uses these meanings:

- **Verified:** observed in a live build or byte/hash checked.
- **Decompiled:** supported by static control/data flow but not yet exercised.
- **Candidate:** plausible and awaiting a discriminating experiment.
- **Retracted:** contradicted by later evidence; retained to prevent repetition.

Nearby memory, correlated motion, and a successful native call do not by
themselves prove a class field or gameplay meaning. Prefer controlled
interventions and record negative results.
