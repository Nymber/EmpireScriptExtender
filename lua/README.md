# Writing a campaign mod

A mod is a folder next to this file that contains `mod.lua`. The loader is
`ese_autoexec.lua`. It does not name any mod, so adding one is a new folder and
removing one is deleting the folder. `production chains/` is a working example;
`fp/` is not one of these — it is the battle rig and is assembled separately.

## Make one

1. Create `EmpireScriptExtender/lua/<name>/mod.lua`. The name can contain spaces.
2. Add a line to `ese_mods.lua`:

```lua
return {
  'production chains',
  'my mod',
}
```

3. Launch with `empire.ps1 launch` (or `empire.ps1 sync` if the game is already
   about to be started by hand). That creates the game's `EmpireScriptExtender\lua`
   and `EmpireScriptExtender\tools` folders if they are missing, then copies
   `ese_autoexec.lua` and `ese_battle_autoexec.lua` to the game root, every
   folder named in `ese_mods.lua`, and `lua/ui`. Relative `loadfile` resolves
   against the install root, not this toolkit.

There are two of these trees. Edit here. The next launch copies. A campaign
already running does not see the copy until it is loaded again.

`ESE_MODS_DIR` overrides the folder the list is read from. `ESE_CHAIN_DIR` is
the old name and still works as a fallback.

Lua 5.1 in the game cannot list a directory, which is why the list is a file
rather than a scan. Deleting a folder does nothing until its line is removed
from `ese_mods.lua`; the loader logs the miss and continues.

## What a mod.lua may assume

The loader sets `ESE.mod_dir` to this folder, with a trailing backslash, before
the file runs, and clears it afterwards. Read your own files from there:

```lua
local base = ESE.mod_dir
local f = loadfile(base .. 'data.lua')
```

Use long brackets for a Windows path you write yourself (`[[a\b]]`). A quoted
string drops unknown backslash escapes, so `"a\\b"` compiles and then names the
wrong file.

Also already in place, from the loader: `ESE.safe(label, fn)`, `ESE.notes`,
`ESE.faults`, and the engine tables `events`, `conditions`, `effect`. One mod
failing does not stop the next — the loader runs each `mod.lua` inside `pcall`
and logs the error as `[mods]`.

Order is the order of the list. A mod that must run first goes first in
`ese_mods.lua`.

## The smallest useful mod

```lua
-- EmpireScriptExtender/lua/my mod/mod.lua
if type(events) ~= 'table' or type(events.FactionTurnStart) ~= 'table' then
  return
end

events.FactionTurnStart[#events.FactionTurnStart+1] = function(context)
  ESE.safe('my-mod', function()
    if not conditions.FactionIsHuman(LocalFaction, context) then return end
    local turn = conditions.TurnNumber(context)
    ESE_Log('my mod: turn ' .. tostring(turn))
  end)
end
```

Append to `events`, never replace. `AddEventCallBack` overwrites the previous
handler. `FactionTurnStart` fires for every faction, so filter on
`FactionIsHuman`. Call conditions only from inside the handler — a stored
`context` is dead, and the wrong scope returns zeros with no error.

`ESE.safe` is not optional around a condition call. Those functions are native
C that dereference their arguments without checking, so a wrong arity is an
access violation, and `pcall` does not catch it.

Confirm it loaded by reading `ese_log.txt` in the game root for
`[mods] my mod: loaded`. A Lua syntax error is reported there as `FAILED` and
does not take the campaign down.

## Where the hooks are

A mod should not need any of these. They are how the loader exists at all, and
where to look when a mod has to go below the scripting API.

| what | where |
|---|---|
| The two hooks ESE installs itself | `ESE/ese_proxy.c`, `A_lua_getfield` (`0x00F07420`) and `A_lua_setfield` (`0x00F07E20`). Five-byte detours; the prologue is checked and a mismatch is refused. |
| The functions a mod can call | same file, the `kNatives[]` table: `ESE_Log`, `ESE_Protect`, `ESE_Say`, `ESE_Call`, `ESE_WrapFn`, `ESE_ReadInt` / `ReadFloat` / `ReadBytes` / `ReadStr`, `ESE_WriteInt` / `WriteFloat` / `WriteBytes`, `ESE_Scan`, `ESE_Trace`, `ESE_TraceVT`, `ESE_TraceLog`, `ESE_Tick`, `ESE_Delta`. |
| The campaign and battle scripting API | `docs/LUA_API.md`. 279 conditions, 147 events, the `effect` and `game_interface` write API, 208 battle natives. |
| The engine's own table-lookup functions | `docs/HOOK_TARGETS.md`. 151 `DATABASE_TABLE` accessors, each self-identified by its error string. Ranked; the economy ones are tier 1. |
| How to observe one before patching it | `docs/ESE_TRACING_AND_PATCHING.md`. `ESE_TraceVT` over `ESE_Trace` — a vtable slot is a pointer, so nothing is stolen. |
| The battle object graph | `docs/FPS_MOD_API_TREE.md`. Rebuilt every battle; read it fresh. |

`ESE_Call` and `ESE_Trace` are the last resort, not the first. A caught fault
has already run halfway through an engine function. Restart after one.

## What this loader does not cover

- **Battle.** `ese_battle_autoexec.lua` (game root) is still a separate entry
  point: ESE runs it when a battle state is acquired, and a campaign `mod.lua`
  is not run there by itself. The first-person rig is the `fp` folder, listed
  in `ese_mods.lua` like any other mod. Its `mod.lua` returns unless
  `ESE.battle` is set, which only the battle entry sets, so a campaign load of
  the same folder is a no-op. Remove `'fp'` from the list to disable it.
- **Data.** DB rows, meshes and textures ship as a pack, not as Lua. See
  `docs/REVIEW_SECURITY_AND_MODDING.md`, section 3.1.
- **The UI state.** `panelmanager` exists only there. From a campaign mod, talk
  to the player with `ESE_Say`; do not call `OpenPanel` yourself.
