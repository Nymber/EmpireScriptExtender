# Empire Script Extender

ESE is a native script extender and modding toolkit for **Empire: Total War
1.5.0.0 on Windows**. It loads through `dinput8.dll`, exposes live campaign,
UI, and battle Lua states, and provides tools for first-person research,
high-poly assets, packs, databases, and engine tracing.

## Install in one minute

1. Extract the ESE release anywhere. It does not need to be inside Steam.
2. Close Empire: Total War.
3. Double-click **`ESE Manager.cmd`**.
4. Choose **Install or repair ESE**.
5. Choose **Check installation**. Every required line should say `PASS`.
6. Choose **Launch Empire**.

The installer finds Empire through Steam automatically. If it cannot, set
`EMPIRE_DIR` to the folder containing `Empire.exe`, then run the manager again.

Installation is idempotent: running it again repairs the live Lua/tool mirror
and updates the DLL. It verifies the installed DLL by SHA-256.

## Command-line use

Run these from this folder:

```powershell
.\empire.ps1 install       # install or repair; no compiler needed with a release DLL
.\empire.ps1 doctor        # read-only health check and repair guidance
.\empire.ps1 launch        # synchronize Lua/tools and start Empire
.\empire.ps1 status        # concise runtime and deployed-pack status
.\empire.ps1 mods          # show enabled and disabled Lua mods
.\empire.ps1 enable fp     # enable for the next battle state
.\empire.ps1 disable fp    # disable for the next battle state
.\empire.ps1 uninstall     # disable ESE and restore a previous proxy backup
.\empire.ps1 release       # developer: clean release zip, no generated packs
```

`install` uses the verified prebuilt `src\dinput8.dll`. If it is absent, ESE
tries to build it from source and explains which compiler is missing.

## First-person mode

The first-person rig loads automatically in land battles.

- `=` toggles first person.
- `-` hooks the friendly, strength-valid soldier nearest the crosshair.
- Mouse movement controls the view while first person is active.
- The center dot and cursor capture are handled by the native DLL.

The camera and presentation layer work. Individual shooting, melee, exact
per-man death/routing state, and engine-owned 3D locomotion remain research
work. See [the first-person roadmap](docs/ROADMAP_FIRST_PERSON.md) for measured
status rather than assumptions.

## Live scripting

With a campaign or battle loaded:

```powershell
.\src\ese.ps1 "return ESE_Version()"
.\src\ese.ps1 -Probe
.\src\ese.ps1 -Repl
.\src\ese.ps1 -Say "Hello from ESE"
.\src\ese.ps1 -UI "return type(Component)"
.\src\ese.ps1 -Battle "return type(CameraZoomTo)"
```

Campaign, UI, and battle code run in different Lua states. A function available
in one state may be absent in another. [LUA_API.md](docs/LUA_API.md) records the
known surfaces and their required states.

## Making a Lua mod

1. Add `lua\my-mod\manifest.lua` and `mod.lua` in this toolkit.
2. Add its id, path, and enabled state to `lua\ese_mods.lua`.
3. Register events with `ESE.on_event` and frame work with `ESE.on_tick`.
4. Run `.\empire.ps1 sync`.
5. Reload the campaign or battle state that owns the API you use.

Always edit this toolkit tree. The game reads a mirrored tree at
`<Empire>\EmpireScriptExtender`. `sync`, `install`, and `launch` update that
mirror. New Lua and tool files must exist in both trees after synchronization.
See [the mod and hook system](docs/MOD_SYSTEM.md) for manifests, dependencies,
callback ordering, failure isolation, and current lifecycle limits.

## Developer workflow

Players use `install`. Native developers use:

```powershell
.\empire.ps1 build         # build src\ese_proxy.c as a 32-bit DLL
.\empire.ps1 deploy        # build, install, and verify the DLL
.\empire.ps1 sync          # mirror Lua and helper tools only
```

Empire is a 32-bit process. The build supports a portable Zig toolchain,
32-bit MinGW, or an x86 MSVC prompt. The build refuses a DLL with the wrong PE
machine or missing DirectInput exports.

## High-poly tools

Generated packs and staging trees are excluded from releases. The toolkit
rebuilds them from vanilla data:

```powershell
.\empire.ps1 hipoly -Only euro_line       # quick unit subset
.\empire.ps1 hipoly                       # build the full staged corpus
.\empire.ps1 hipoly -Deploy               # build, pack, and install locally
.\empire.ps1 lod 3.0 -Deploy              # extend model LOD distances
```

The builder excludes every `zz_*` pack so it cannot consume its own generated
output and recursively subdivide it. It also treats each unit as all-or-nothing
across LODs. See [ROADMAP_HIGH_POLY_UNITS.md](docs/ROADMAP_HIGH_POLY_UNITS.md).

## Safe uninstall and proxy conflicts

ESE uses the game's `dinput8.dll` proxy slot. If installation finds another
DLL there, it backs it up as `dinput8_original.dll`. If both an unknown DLL and
a different backup already exist, installation refuses to choose a winner
automatically. Developers can pass `-Force` only after deciding which proxy
must load first.

`uninstall` removes only an ESE-owned DLL and restores that backup when present.
It removes unmodified ESE loader files, leaves modified files in place, and
never deletes generated packs, user mods, or the inert live mirror.

## Troubleshooting

Start with:

```powershell
.\empire.ps1 doctor
```

Common results:

- **Empire not found:** set `EMPIRE_DIR` to the directory containing
  `Empire.exe`.
- **Empire is running:** close it before install, update, deploy, or uninstall.
- **Installed DLL belongs to something else:** decide which proxy must load;
  ESE will not silently delete another mod.
- **Mirror out of date:** run `install` or `sync`.
- **Trade tab crashes:** run `doctor`; the production-chain pack requires the
  matching `ese_commodities.txt` runtime configuration.
- **Game launches but ESE is unavailable:** inspect `ese_log.txt` beside
  `Empire.exe`.

## What ESE changes

- Installs `dinput8.dll` beside `Empire.exe`.
- Installs `ese_autoexec.lua` and `ese_battle_autoexec.lua` beside the game.
- Installs required runtime data such as `ese_commodities.txt` beside the game.
- Mirrors the complete Lua runtime and supported helper-tool folders under
  `<Empire>\EmpireScriptExtender`.
- Does not patch `Empire.exe` or vanilla pack files on disk.

ESE is native code loaded inside the game. Only install builds from a source
you trust. Engine calls can still crash the process when given invalid native
pointers; Lua `pcall` cannot catch a native access violation.

## Documentation map

- [Installation and usage design](docs/INSTALLATION_AND_USAGE.md)
- [Mod activation and shared hooks](docs/MOD_SYSTEM.md)
- [Security, modding approaches, and current limits](docs/REVIEW_SECURITY_AND_MODDING.md)
- [Lua API](docs/LUA_API.md)
- [First-person API tree](docs/FPS_MOD_API_TREE.md)
- [Tracing and patching](docs/ESE_TRACING_AND_PATCHING.md)
- [Toolkit index](INDEX.md)
