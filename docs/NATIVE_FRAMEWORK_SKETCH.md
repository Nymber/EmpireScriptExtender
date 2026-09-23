# Sketch: a native script-extender for Empire (the "SKSE model")

This is the track that shipped. The parallel plan (`HOOK_API_ROADMAP.md`) made
WALI a better *external reader*; that file is archived outside the game folder
because ESE already reads from inside the process. This document is how the
game's **own Lua** gained new native functions. Written 2026-09-18 after
verifying the keystone below — this is not speculative architecture.

## The keystone, verified 2026-09-18

**Empire.exe statically links Lua 5.1** — exact string
`"Lua 5.1 Copyright (C) 1994-2006 Lua.org,"` at file offset `0xECE0BE`. The
standard library's `luaL_Reg` arrays are intact in `.rdata` (name pointer
immediately followed by the `lua_CFunction` pointer), e.g. `collectgarbage`
→ `0x011A1B90`, `pcall` → `0x011A1F20`, `rawget` → `0x011A1AF0`,
`setmetatable` → `0x011A1940`.

More importantly, the game's own module registration was located and decoded
at **`0x00AB0220`** (found by scanning for a pointer to the
`"EpisodicScripting"` string at VA `0x0126CB08`, which landed in `.text` as a
`PUSH` operand — i.e. registered imperatively, not via a static table):

```
00ab022a:  CALL 0x00f77880     ; -> EAX = lua_State*        <-- the state getter
00ab022f:  PUSH 0x126cb08      ; "EpisodicScripting"
00ab0236:  PUSH 0xffffd8ee     ; -10002 == LUA_GLOBALSINDEX
00ab023c:  CALL 0x00f07420     ; lua_getfield(L, idx, name)
00ab0244:  CALL 0x00f08230     ; lua_type / lua_istable(L, -1)
00ab0271:  CALL 0x00f070b0     ; lua_call(L, nargs, nresults)
00ab027c:  CALL 0x00f07f60     ; lua_settop(L, 0)
```

`0xffffd8ee` = **−10002 = `LUA_GLOBALSINDEX`**, Lua 5.1's pseudo-index for the
globals table — the most conclusive possible confirmation. Every cdecl stack
cleanup (`ADD ESP,0x14`, `0xC`, `0x8`) matches those argument counts exactly.

**Why this is the keystone:** we do not have to reverse-engineer Lua. Lua 5.1
is the most documented Lua ever shipped and its source is public. We only have
to *locate* functions we already know the exact semantics of.

The natives are in the DLL. The Lua that calls them is not: ESE reads
`ese_autoexec.lua` from the game root and mod folders from
`EmpireScriptExtender\lua`. `empire.ps1 launch` creates that folder and
`EmpireScriptExtender\tools`, then copies both from the toolkit tree. Editing
the toolkit copy does nothing until the next launch.

## The Lua C API, fully mapped (2026-09-18) — step 1 COMPLETE

Found by locating the base-library `luaL_Reg` array (VA `0x01323980`, the
complete 24-entry `base_funcs[]` from `lbaselib.c`), scanning for the one code
reference to it (`PUSH 0x1323980` at `0x011A23E0`, inside `luaopen_base`), and
decompiling the chain from there. Every one is cdecl.

| VA | function | args | how confirmed |
|---|---|---|---|
| `0x00F77880` | **game's `lua_State*` getter** | — | returns EAX at the `EpisodicScripting` reg site |
| `0x00F09090` | **`luaL_register(L, name, l)`** | 3 | body is exactly `luaI_openlib(L,name,l,0)` |
| `0x00F08DB0` | `luaI_openlib(L, name, l, nup)` | 4 | full `lauxlib.c` body match |
| `0x00F078F0` | **`lua_pushcclosure(L, fn, nup)`** | 3 | the openlib registration loop |
| `0x00F07E20` | **`lua_setfield(L, idx, k)`** | 3 | `"_G"`/`"_VERSION"`, + openlib loop |
| `0x00F07420` | `lua_getfield(L, idx, k)` | 3 | used with `LUA_GLOBALSINDEX` + name |
| `0x00F07AD0` | `lua_pushvalue(L, idx)` | 2 | `lua_pushvalue(L, LUA_GLOBALSINDEX)` |
| `0x00F07F60` | `lua_settop(L, idx)` | 2 | `lua_settop(L, ~nup)` |
| `0x00F070B0` | `lua_call(L, nargs, nres)` | 3 | `EpisodicScripting` site |
| `0x00F08230` | `lua_type(L, idx)` | 2 | compared `!= 5` (`LUA_TTABLE`) |
| `0x00F079F0` | `lua_pushlstring(L, s, len)` | 3 | `(L, "Lua 5.1", 7)` |
| `0x00F07CB0` | `lua_remove(L, idx)` | 2 | `lua_remove(L, -2)` |
| `0x00F07560` | `lua_insert(L, idx)` | 2 | `lua_insert(L, ~nup)` |
| `0x00F08950` | `luaL_findtable(L, idx, fname, szhint)` | 4 | `REGISTRYINDEX` + `"_LOADED"` |
| `0x00F08920` | `luaL_error(L, fmt, ...)` | varargs | `"name conflict for module '%s'"` |

Constants confirmed live in the binary: `LUA_GLOBALSINDEX` = −10002
(`0xFFFFD8EE`), `LUA_REGISTRYINDEX` = −10000 (`0xFFFFD8F0`), `LUA_TTABLE` = 5.
`luaL_Reg` is 8 bytes on this 32-bit build (`{const char *name; lua_CFunction func;}`),
confirmed by the loop's `param_3 + 2` on an `int*`.

**`luaL_register` is a better primitive than the pushcclosure/setfield pair
originally planned** — it creates-or-reuses a named global table and fills it
from a `luaL_Reg[]` in ONE call, exactly as the game registers its own stdlib:

```
L = call 0x00F77880
luaL_register(L, "ESE", our_reg_array)     ; -> global table ESE with all our fns
```

So the whole registration step is: build a `luaL_Reg[]` (pairs of
string-pointer + function-pointer, NULL-terminated) in memory we allocate in
the target process, then make one call. **The gap between today and "campaign
Lua can call our native code" is now only the payload and the thread-safe call
site — no unknown Lua plumbing remains.**

## Architecture: three layers

**1. Loader — C#, no C++ toolchain needed.**
There is no C/C++ compiler on this machine (`cl.exe`/`gcc`/MSBuild all absent),
which blocks the classic SKSE approach of a C++ DLL. But it does not block the
project, because `VirtualAllocEx` + `WriteProcessMemory` + `CreateRemoteThread`
are all reachable via P/Invoke from C#, and WALI is *already* a C# process that
opens Empire.exe and writes to its memory. So WALI grows into the loader. The
"native payload" is machine-code bytes C# writes into the target — which we can
produce without a compiler for small stubs.

**2. Payload — hand-built stubs now, a real DLL later.**
A `lua_CFunction` has the signature `int (*)(lua_State *L)` — it reads args off
the Lua stack and pushes results back. For a getter like "return the commodity
price array", the stub is short enough to hand-assemble, and everything it needs
(`lua_pushnumber`, `lua_createtable`, `lua_rawseti`) is in the same API block.
For anything genuinely complex, installing MSVC Build Tools and writing a
proper DLL is the clean answer — treat that as the eventual unblock, not a
prerequisite to starting.

**3. API surface — new globals in the game's own Lua.**
The payoff: `scripting.lua` campaign scripts call our functions directly, with
no WALI round-trip, no file-based IPC, no external process required at runtime.
This is what the roadmap's Phase 4 wants, but done properly — the function
lives *inside* the Lua state rather than being faked through a command file.

## The constraint everyone glosses over: thread affinity

`CreateRemoteThread` gets code running, but **you cannot safely call into the
game's Lua from an arbitrary thread.** The Lua state is almost certainly owned
by the main/simulation thread, `lua_State` is not thread-safe, and the engine's
allocator and GC assume single-threaded access. Calling in from a remote thread
is a crash waiting to happen — probably an intermittent one, which is the worst
kind to debug, and this project has already spent enough sessions on
intermittent crashes.

The correct pattern is the one SKSE and M2TWEOP both use: **use the remote
thread only to install hooks, then do all real work from a hook that the game
itself calls on its own thread** (a per-frame or per-turn function). Registration
itself must happen on the game's thread too, and after Lua is initialised —
hooking `0x00AB0220`'s own caller, or any function known to run once per turn,
gives a correctly-timed, correctly-threaded place to register.

## What this unlocks

- **Call the game's own functions**, rather than reimplementing their logic.
  The native price engine (`FUN_00A65A70`) could be invoked or its results
  read in-place, instead of the mod maintaining a parallel synthetic model.
- **React to engine events** the Lua API never exposed, by hooking them and
  calling into Lua — the thing `AddEventCallBack`'s narrow event list has
  limited this project on since the beginning.
- **Return real data structures to Lua** (tables, nested values) rather than
  the current file-based text IPC between the mod and its dashboard.

## Concrete next steps, in order

1. ~~Find `lua_pushcclosure` and `lua_setfield`.~~ **DONE 2026-09-18** — see the
   table above; `luaL_register` found too, which is a better primitive.
2. ~~Find a thread-correct call site.~~ **DONE 2026-09-18 — `0x00AB0220`.**
   The selection rule that removes the guesswork: **any function that itself
   calls into Lua is by definition on the Lua-owning thread and after Lua
   init.** So instead of reasoning about which function runs on which thread,
   run `callers` on the `lua_State*` getter `0x00F77880` — all 15 hits are
   self-proving sites. The chosen one, `FUN_00AB0220`, is the dispatcher for
   `EpisodicScripting.ClearEventCallbacks()` (confirmed by reading its two
   pushed strings), so it fires at campaign-script (re)initialisation —
   exactly when a fresh Lua state needs our globals re-added.

   Hook site verified: 10-byte steal
   `56 57 8B F9 C7 07 A8 78 26 01` = `PUSH ESI; PUSH EDI; MOV EDI,ECX;
   MOV [EDI],0x012678A8` — all whole, all position-independent. **Byte 10 is
   `E8` (CALL rel32) and must NOT be stolen**, a textbook case of the
   no-relative-branch rule.

   Useful property of this site: at hook entry `ECX` still holds the original
   `this`, identical to what the real code holds when it calls the state getter
   ten bytes later — so calling the getter from the cave is safe whether it is
   cdecl or thiscall.
3. ~~Prove the concept.~~ **DONE — PROVEN END-TO-END 2026-09-18.**
   `eseStatus()` returned:
   ```
   guard=1  L=0x220601D8
   typeAfterPush=6  luaType(_G.ESE_Ping)=6  callCount=150  returnType=4
   ```
   `6` = `LUA_TFUNCTION` (registered), `callCount>0` from an `inc [callcount]`
   as the stub's first instruction (uses no Lua API, so it is unfalsifiable
   proof our x86 ran), `4` = `LUA_TSTRING` returned through `lua_call`.
   **Hand-written native code is registered into, and executed by, Empire's own
   Lua 5.1 VM.** Script: `EmpireTradeMod\tools\ce_lua_register.lua`.

   **Hook site that works: `luaL_register` (`0x00F09090`), 6-byte steal
   `6A 00 FF 74 24 10`.** `L` arrives as the first stack arg (at `[esp+28]`
   after `pushfd`+`pushad`), no state-getter call needed, no absolute addresses
   in the stolen bytes. Register by primitives — `lua_pushcclosure` then
   `lua_setfield(L, LUA_GLOBALSINDEX, name)` — NOT via `luaI_openlib`, which
   went through `_LOADED`/`luaL_findtable` and produced a nil global.

   **MAJOR FINDING — Empire uses MANY `lua_State`s, not one.** The guard only
   re-registers when `L` differs from the last seen value, yet the counter
   reached 150. So registration is not a one-time act against a single global
   state: states are created repeatedly (and/or alternate), and anything we
   expose must be (re)registered per state as it appears. The L-keyed guard
   already does this correctly; a boolean "have I registered yet" flag would
   have silently covered only the first state. This also reframes the earlier
   v1 failure — hooking a site that fires for one particular script context is
   fragile, whereas `luaL_register` catches every state by construction.

3b. **CAMPAIGN SCRIPTS REACHED — the real goal, 2026-09-18.**
   `tools\ce_ese_campaign.lua`. Vanilla `data\campaigns\main\scripting.lua`
   called our hand-written native function and received its value:
   `ESE_Ping VISIBLE, returned: pong`, with `callCount=1` incremented by the
   game's own script rather than by us.

   - **Locating the campaign state:** hook `lua_setfield`, filter to
     `LUA_GLOBALSINDEX`, log `(L, key)`. The state receiving the globals
     **`conditions` and `effect`** is it. That address is a heap pointer and
     differs every launch, so match it by signature at runtime (first dword of
     the key == `"cond"` == `0x646E6F63`) and register in that moment.
   - **`_G` is NOT the campaign globals table.** The bare name `ESE_Ping`
     resolves and runs, while `rawget(_G,"ESE_Ping")` is nil — Empire gives the
     campaign state its own globals table and leaves the `_G` variable pointing
     elsewhere. **Write via `LUA_GLOBALSINDEX`; never verify via `_G`**, or a
     working registration looks like a failure.
   - **Adding a probe to a vanilla script:** put it INSIDE an existing handler.
     `AddEventCallBack` is not additive here, so registering `FactionTurnStart`
     a second time silently replaces vanilla's handler.

4. **Prior attempt, kept as a lesson:**
   `EmpireTradeMod\tools\ce_lua_register.lua` — allocates a `luaL_Reg[]`, a
   hand-written x86 `lua_CFunction`, and a one-shot cave; calls
   `luaL_register(L, "ESE", ...)` on first fire. Verify from any campaign Lua
   with `if ESE then print(ESE.Ping()) end` → `pong`. The stub deliberately
   uses `lua_pushlstring` rather than `lua_pushnumber`, because `lua_Number` is
   a **double** in stock Lua 5.1 and pushing one from hand-written asm is
   needlessly fiddly, whereas `pushlstring` takes only a pointer and a length
   and its address is already confirmed.
4. Only then port a real getter (commodity prices) to this path.
5. Decide on MSVC Build Tools once stub complexity justifies it.

**Remaining unknowns are now only these:** a thread-correct call site (step 2),
`lua_pushnumber`/`lua_pushinteger`'s address (same block, same method — trivial
to find when needed), and the loader mechanics. No Lua plumbing is unknown.

## Relationship to the external-reader plan

That plan is archived outside the game folder. Its external C#
`ReadProcessMemory` getters are strictly lower risk, need no injection, and
deliver the trade mod's actual feature goals sooner. This track is the higher
ceiling. **Recommended: ship the external-reader path first, pursue this in
parallel as research, and only migrate once step 3 above round-trips.** Do not
block the trade mod on this.
