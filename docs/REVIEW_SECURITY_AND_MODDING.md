# Review: documentation audit, security, modding guide, limitations

Written 2026-09-22 after a long session that produced several confident claims
which turned out to be wrong. The point of this document is to be the sceptical
counterweight to the rest of the docs.

---

# PART 1 — Documentation audit ()

## 1.1 Claims corrected in this pass

| doc | claim | reality |
|---|---|---|
| `empire-battle-control/SKILL.md` | "`+0x4C`, `+0x50` \| position X, Y" | **WRONG.** Position is a **vec3 at `+0x48`**; `+0x4C` is the HEIGHT. Corrected in place with the cross-checks. |
| `empire-unit-meshes/SKILL.md` | "the 41-bone ceiling … 45 renders fine" | **Never verified**, and the measured budget says 45/19 = 268 > 256 should *not* fit. Corrected with the proven 64/19-fails, 59/8-works data. |

## 1.2 The failure pattern, honestly

Every expensive mistake this session had the same shape: **a claim validated in
exactly one state, then treated as settled.**

- `entity+0x348` was declared the liveness flag because it counted **8** in an
  army the UI showed as 8 men. In the *next* battle it counted 18 in a
  full 1,005-man army. One sample, wrong conclusion, hours of downstream damage.
- `+0x4C` as X survived for hours because this map's terrain heights (189–196)
  *look* like plausible X coordinates. The army appeared to sit in a believable
  blob. Nothing contradicted it until a human said "I am standing on the
  general" and the data disagreed by 189 m.
- "45 bones renders correctly" was recorded as fact from a single launch where
  *nothing visibly broke* — which is not the same as the extra slots working.

**The tell in all three cases was available and ignored.** A 150-man line
measuring 1.6 m wide with men 3 cm apart is absurd. 828 of 1,068 men matching a
"normal" state while the UI showed 8 survivors is absurd. Neither was checked
against a second, independent quantity.

### Socratic questions to ask before recording a finding

1. **What would this look like if it were false?** If you cannot answer, the
   test is not a test.
2. **What second, independent quantity should agree?** (Unit strength vs. flag
   count. Formation width vs. man spacing. Heightfield vs. stored Y.)
3. **Was this validated in more than one state?** A dying army and a healthy one
   disagree — `+0x348` and `+0x18C` both looked right in exactly one of them.
4. **Does "nothing broke" prove the feature worked,** or only that it did not
   crash? (45 bones.)
5. **Is the sample the same thing I will use it on?** (Man 595 was a *corpse* at
   the map edge; the "position writes stick" conclusion drawn from him was void.)

## 1.3 Confidence tagging

`FPS_MOD_API_TREE.md` and `SKINNING_AND_BONE_CEILING.md` tag every entry
**[V]** verified live / **[D]** decompiled but unexercised / **[?]** unknown.
**Adopt this everywhere.** The cost of an untagged wrong claim is not the claim,
it is everything built on top of it before anyone checks.

---

# PART 2 — Security review

None of this is a reason to stop; it is a reason to know what you are running.

## 2.1 The ESE pipe is an unauthenticated code-execution channel — HIGHEST RISK

```c
CreateNamedPipeA("\\\\.\\pipe\\ese", PIPE_ACCESS_DUPLEX, ..., NULL);
                                                              ^^^^
                                            no SECURITY_ATTRIBUTES
```

The pipe accepts **arbitrary Lua** and runs it inside Empire. Since ESE now
exposes `ESE_WriteBytes`, `ESE_WriteInt`, `ESE_Call` and `ESE_Trace`, that is not
sandboxed Lua — it is **arbitrary native code execution in the game process**,
plus filesystem access as your user.

- With `NULL` security attributes the pipe gets the default DACL: the creating
  user, SYSTEM and Administrators. A *different* non-admin user on the same
  machine normally cannot reach it, and remote access would additionally need
  SMB/IPC$ to allow it.
- **But there is no application-level authentication whatsoever.** Anything
  running as you — any script, any program you launch — can drive it.

**Practical guidance:** treat a machine running ESE as one where any local
process you run can fully control the game process. Do not run ESE on a shared
or untrusted machine. If this ever needs hardening, pass a real
`SECURITY_ATTRIBUTES` restricting the DACL to the current user, and add a shared
secret to the request format.

## 2.2 Auto-executed scripts

`ese_autoexec.lua` and `ese_battle_autoexec.lua` are read from the **game folder**
and executed with no validation. Anything able to write to that folder gets code
execution next launch. Game install folders are frequently user-writable.
`empire.ps1 launch` writes both of those files, plus `EmpireScriptExtender\lua`
and `EmpireScriptExtender\tools`, from the toolkit tree on every start.
`shell.ps1` is a prompt over the same scripts. It reads their comment headers
for usage and does not add a second way to run them.

## 2.3 RWX memory and code patching

`make_tramp` / `make_trace_tramp` allocate `PAGE_EXECUTE_READWRITE` and
`mem_write` temporarily makes code pages writable. This is normal for hooking,
but it is also exactly the signature of malware and cheats:

- **Antivirus / EDR will flag it.** Expect false positives.
- A `dinput8.dll` proxy that hooks D3D9 and DirectInput is structurally
  indistinguishable from a cheat loader.

## 2.4 Multiplayer — do not

This toolkit reads and writes arbitrary game memory, drives unit orders
programmatically, and can move soldiers. **Using it in multiplayer is
cheating**, and Empire's MP has no protection against it. Keep it to
single-player and to your own machine.

## 2.5 Lower-risk items

- `ESE_Scan` walks `base .. base+0x1000000` with a `VirtualQuery` per page —
  bounded and read-only.
- `launch_battle.ps1` edits `preferences.empire_script.txt` and backs it up
  first; `-Restore` reverts. It refuses to run while Empire is up.
- `empire_paths.*` only reads the registry and the filesystem.
- Mod packs affect only the game.

## 2.6 Input validation in the new natives (reviewed)

`ese_writebytes` bounds at `buf[256]`; `ese_scan` bounds pattern at 64 bytes and
tracks `used` against `sizeof(out)`; `ese_tracelog` uses a fixed 4 KB buffer with
a length check; `trace_handler` writes at most 4 ring slots and 6 args into
`args[6]`. `ESE_Trace` clamps `steal` to 5..15 against `orig[16]`, and
`make_trace_tramp` emits at most `30 + steal` bytes into a 96-byte allocation.
**No unbounded writes found.**

The real risk in `ESE_Trace` is not memory safety, it is **correctness**: a steal
that ends mid-instruction corrupts the function, and the guard only detects
relative branches. See PART 4.

---

# PART 3 — How to build a mod with this

Four routes, cheapest first. **Prefer the highest one that can do the job** —
every step down costs robustness.

## 3.1 Data-only mod — a pack (no code, survives patches best)

The DB and most content are plain files inside `.pack` archives. Override one by
shipping your own pack that sorts later (`zz_` prefix).

```
stage/db/<table_name_tables>/<table>      # edited DB table
stage/fx/fxconfig.h                       # shader config
stage/unitmodels/....variant_weighted_mesh
ruby EmpireScriptExtender/tools/pack/build_pack_stream.rb stage out.pack
copy out.pack "<install>/data/zz_mymod.pack"
```

Proven examples in this repo: `zz_lod.pack` (LOD distance bands, a 185-byte
table), `zz_b59i8.pack` (shader config, 1.4 KB), `zz_tex2048.pack` (2,016
upscaled textures, 2.98 GB), `zz_hipoly.pack` (subdivided meshes).

Use **type 4 ("movie")** packs — type 3 sat inert through three test launches.
Internal paths must be **lowercase with backslashes** or they will not override.

## 3.2 Script mod — Lua, no native code

Do not edit `ese_autoexec.lua`. It is the loader. A campaign mod is a folder
under `EmpireScriptExtender/lua/` containing `mod.lua`, named in `ese_mods.lua`.
Adding a mod is a new folder plus one line in that list; removing one is
deleting both. The worked example, and the short version of this, is
`lua/README.md`.

`ese_autoexec.lua` (game root) and `ese_battle_autoexec.lua` (game root) are the
only two files ESE runs itself. The first loads every folder in `ese_mods.lua`.
The second sets `ESE.battle` and loads `fp/mod.lua` if that folder is listed.
`fp/mod.lua` returns immediately when `ESE.battle` is unset, so the campaign
pass of the same list does not install the rig. The part scripts stay in
`lua/fp/`; `tools/game/build_autoexec.rb` only copies the thin loader, it no
longer concatenates them. `empire.ps1 sync` (also run by `launch`) is what
puts that tree into the install: it creates `EmpireScriptExtender\lua` and
`EmpireScriptExtender\tools` and copies the autoexec pair, every folder named
in `ese_mods.lua`, `lua/ui`, and the `game`, `pack`, `ui`, and `trademod`
tool folders.

The campaign API is real and large (`docs/LUA_API.md`); the battle state
exposes 208 natives. The functions ESE adds on top of both — `ESE_Log`,
`ESE_Protect`, `ESE_Call`, `ESE_Trace` and the rest — are the `kNatives[]` table
in `ESE/ese_proxy.c`. The two detours that make any of this possible are
`A_lua_getfield` and `A_lua_setfield` in the same file. The engine's own
table-lookup functions, if a mod has to go below the scripting API, are
catalogued in `docs/HOOK_TARGETS.md`.

Append to `events`, do not replace. A top-level `return` ends the chunk, so a
script that is concatenated into another file (the battle rig is) must be
wrapped in `(function() ... end)()`. A `mod.lua` is loaded on its own, so a
`return` there only ends that mod.

## 3.3 Live memory mod — read/write the object graph

Use `FPS_MOD_API_TREE.md`. Read the chain fresh each battle (`FPSYNC()`); it is
rebuilt per battle and stale pointers fail *silently*.

```lua
local base = FPP("s:137D488")
local M    = FPP(FPAA(base, 0x31C))
local A    = FPP(FPAA(M, 8))
local D    = FPP(FPAA(FPP(FPAA(A, 0xB0)), 0x90))   -- entity array
```

Per-frame work goes in `ESE_Tick` (source capped at **2048 bytes**, so derive
addresses once in a setup pass). `ESE_Call` **cannot** be used inside the tick —
it shares a guard and returns "guard busy". Use `ESE_WrapFn` instead.

## 3.4 Native mod — hooks and patches (last resort)

`ESE_Trace` / `ESE_TraceVT` to observe, `ESE_WriteBytes` to patch.
**Prefer `ESE_TraceVT`**: a vtable entry is a pointer, so nothing is stolen and
no prologue needs decoding.

### The workflow that actually works

1. Find it statically (`ghidra.ps1 xrefs` on a string is the best entry point —
   debug strings and effect parameter names are the map).
2. Confirm the address is live (`ESE_Scan` a pattern so it survives rebuilds).
3. **Observe before acting** — trace it, read the args, check the call count.
4. Change one variable, relaunch, verify visually AND numerically.

---

# PART 4 — Current limitations (what does NOT work)

## 4.1 Hard engine limits — not patchable

| limit | value | why |
|---|---|---|
| vertex shader constants | **256 float4** (measured via `ESE_Caps`) | `vs_3_0` / driver cap. Not in Empire.exe. |
| bones | `(256 - 38 - instances*5) / 3` | bones and instancing share the budget. 59 bones needs instancing down to 8. **71 is the max** (at 1 instance). |
| bone blending | 2 bones per vertex | a knuckle competing with its parent creases rather than rolls |
| encrypted DLC units | 56 units | cannot be read at all personally|

## 4.2 Things that work but are not what they sound like

- **"First person"** is a *camera*, plus optional position writes on a soldier.
  It is not a player character: no walk cycle, no jump animation, no weapon
  handling. Driving a man's position moves the model the renderer draws; the
  animation state is untouched, so he **slides**.
- **Unit orders** act on the **current selection**, not on the man you are
  looking through. The player must have the unit selected.
- **High-poly units** are *smoothed*, not remodelled. Subdivision cannot add a
  button, a lapel or a strap. `vwm_json.rb` refuses a changed vertex count, so
  new geometry cannot be authored yet.
- **Upscaled textures** contain no information the 1024 source lacked, and
  without `MIPMAPLODBIAS = -1.0f` the 2048 mip reaches ~3.4% of the frame.

## 4.3 Known unknowns — do not build on these

- **Per-man liveness.** `+0x348` retracted. `+0x34`/`+0x38`/`+0xF0`/`+0x1BC` are
  corpse decoys. Only `unit+0x178 > 0` (unit alive) is solid.
- **Does the engine upload >41 bone matrices?** Shader room ≠ engine support.
- **Reading the current selection** from memory. `FUN_0056BED0` was a Lua *arg
  reader*, not a selection getter.
- **Per-entity commands.** `BCQ_ENTITY_ORDER_MOVE` (`5D02F0`) and
  `BCQ_FIRE_PROJECTILE` (`5D0560`) exist in the command queue but have never
  been invoked. This is the most promising unexplored lever.
- **Whether `dip_batch` geometry is replicated in the vertex buffer**, which
  decides if stream instancing is a medium or a large job.

## 4.4 Tooling limitations

- `ESE_Trace`'s **steal length must be computed by hand** from a disassembly.
  The default of 5 splits the prologue of almost every real function, and the
  guard cannot detect a mid-instruction cut — only relative branches.
- `ESE_Tick` source is capped at **2048 bytes**.
- CA's ~100 bundled `testdata` battles **all crash**: they reference unit keys
  from an older build, and the "invalid key" error path dereferences null.
- Empire **rewrites `preferences.empire_script.txt` on exit**, so any edit must
  be re-applied per launch.
- The battle Lua state is **rebuilt per battle**, wiping all globals, and the
  tick keeps reporting healthy while doing nothing because `pcall` swallows the
  nil-call.

## 4.5 Process limitations, stated plainly

- This is **not a git repository**. A bulk edit was applied to 33 files with no
  backup this session. `git init` would make the next one reversible.
- Several results depend on **one machine's GPU and one install**. `ESE_Caps`
  reporting 256 is this card; another may differ (it cannot be lower).
