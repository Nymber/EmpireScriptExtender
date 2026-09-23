# ESE installation and usage design

This document records the questions used to design the public workflow and the
answers implemented in `empire.ps1` and `ESE Manager.cmd`.

## Questions that constrain the design

### Who is installing ESE?

There are two users:

1. A player who wants to run ESE and should not need a compiler.
2. A developer who edits `src/ese_proxy.c` and must rebuild deliberately.

Therefore `install` consumes a prebuilt, validated DLL while `deploy` rebuilds
from source. If a release accidentally omits the DLL, `install` attempts a build
and reports the missing prerequisite rather than copying nothing.

### What is the smallest successful path?

The public path is one double-click and one menu choice:

```text
ESE Manager.cmd -> Install or repair -> Check installation -> Launch
```

The command-line equivalent is:

```powershell
.\empire.ps1 install
.\empire.ps1 doctor
.\empire.ps1 launch
```

### Can installation be repeated safely?

Yes. `install` synchronizes the live Lua/tool mirror, installs the same DLL,
and verifies its hash. It writes an informational `install.json` in the live
mirror. Repeating it is the repair and update workflow.

### What if another mod already uses `dinput8.dll`?

The installer identifies ESE by its embedded marker and 32-bit PE header. An
unknown DLL is backed up once. If an unknown DLL and a different backup both
exist, installation refuses to choose a winner automatically. This avoids
destroying another proxy chain.

### What can uninstall safely remove?

Only artifacts whose ownership can be established:

- An ESE-marked `dinput8.dll`, restoring `dinput8_original.dll` when present.
- Root loader files only when their hashes still match the toolkit copies.
- ESE's informational install manifest.

The live mirror, generated packs, and user mods stay in place. Without the DLL
they are inert, and deleting them would create more risk than benefit.

### How does a user know what failed?

`doctor` reports required checks as `PASS`, `WARN`, or `FAIL`:

- detected Empire install;
- valid toolkit artifact;
- installed ESE DLL and whether it matches;
- campaign and battle loaders;
- mod list and first-person Lua mirror;
- live ESE connection when the game is running.

Every failure points to `install`, `sync`, or a specific proxy conflict.

### What belongs in a release?

The release contains source, scripts, Lua, docs, and a validated prebuilt
`src/dinput8.dll`. It excludes `staged/`, generated `zz_*.pack` files, memory
dumps, build symbols, and local logs. High-poly output is rebuilt from vanilla
packs on the user's machine.

## Implemented command model

| Command | Audience | Effect |
|---|---|---|
| `install` | player | sync, install/repair prebuilt DLL, hash verify |
| `update` | player | alias of idempotent `install` |
| `doctor` | everyone | read-only health check |
| `launch` | player | require ESE, sync, start Empire |
| `mods` | player/mod author | list activation state and source folders |
| `enable <id>` | player/mod author | enable a mod on the next state load |
| `disable <id>` | player/mod author | disable a mod on the next state load |
| `uninstall` | player | safely disable ESE and restore proxy backup |
| `sync` | mod author | mirror runtime config, Lua, tools, and docs |
| `build` | native developer | compile the 32-bit DLL |
| `deploy` | native developer | build and install the DLL |
| `release [zip]` | release maintainer | package source, tools, docs, and prebuilt DLL; exclude generated packs |

## Current limits exposed to users

- Windows and Empire 1.5.0.0 are the supported target.
- Only one `dinput8.dll` can occupy the application-directory proxy slot unless
  proxy chaining is designed explicitly.
- Campaign, UI, and battle Lua are separate states.
- Activation changes apply to newly created Lua states; hot unload is not supported.
- Native engine calls can fault outside Lua's error model.
- First-person camera, crosshair, cursor capture, player-army gating, and
  strength gating work. Individual fire, melee, exact corpse/routing detection,
  and engine-owned locomotion remain unfinished.
- Generated packs are local products and are not part of the ESE release.

## Release checklist

- [x] One double-click manager.
- [x] One idempotent install/repair command.
- [x] Dynamic Steam/install discovery with `EMPIRE_DIR` override.
- [x] No compiler required when the release DLL is present.
- [x] Hash verification after install.
- [x] Read-only doctor command.
- [x] Conservative proxy backup and uninstall.
- [x] Generated packs excluded from source releases.
- [x] `empire.ps1 release` produces a public archive with the current validated
  `src/dinput8.dll`, a SHA-256 manifest, and no generated `.pack` files.
