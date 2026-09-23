# Empire: Total War — object & function tree for the first-person mod

Still researching....

Status tags: **[V]** verified live · **[D]** from a decompile, not yet exercised ·
**[?]** unknown / unproven. The tags matter — several earlier notes in this repo
were confident and wrong.

---

## 0. Root access chain  **[V]**

Everything hangs off one static global. All addresses below are LIVE; subtract
`ESE_Delta()` for Ghidra.

```
DAT_0137D488                        static global  (use "s:137D488")
 |
 +-- +0x31C  -> M        battle manager          e.g. 3451C6E8
 |    |
 |    +-- +0x0008 -> A   world/scene root        2622F478
 |    |    |
 |    |    +-- +0x009C -> HeightField            21589B38   (terrain, sec. 2)
 |    |    +-- +0x00B0 -> B   entity container   347D1B68
 |    |    |    +-- +0x008C  int   entity count  3438
 |    |    |    +-- +0x0090 -> D  entity array   276431C8   D[i] = entity*
 |    |    +-- +0x00EC -> projectile system      3A86DD90   [D] not yet used
 |    |
 |    +-- +0x28140 -> camera controller          3B38E410
 |    |    +-- +0x0250 -> camera                 24B03048   (sec. 4)
 |    +-- +0x28048 -> selection container        [D] object w/ vtable, not a list
 |    +-- +0x2815C -> (checked by order dispatch)
 |
 +-- +0x3D4  -> selection manager                2157F538
 +-- +0x37C  int  land(0) / naval(1) mode        [D]
```

Lua helper (`FPAA` = hex address add, `FPP` = deref; Empire's Lua is float32 so
pointer maths MUST use hex strings — see [[project_empire_lua_is_float32]]):

```lua
local base = FPP("s:137D488")
local M    = FPP(FPAA(base, 0x31C))
local A    = FPP(FPAA(M, 8))
local B    = FPP(FPAA(A, 0xB0))
local D    = FPP(FPAA(B, 0x90))          -- entity array
local n    = tonumber(ESE_ReadInt(FPAA(B, 0x8C)))
```

**The whole chain is rebuilt per battle.** Re-derive it (`FPSYNC()`) rather than
caching across battles.

---

## 1. ENTITY (a soldier, horse, or marker) — `D[i]`  **[V]**

| offset | type | meaning |
|---|---|---|
| `+0x00` | ptr | **vtable** — identifies the kind. Derive at runtime (ASLR moves it); the men are simply the most common vtable |
| `+0x34`, `+0x38` | int | pose/state enum; `0x10` for on-field men **including corpses** |
| `+0x48` | float | **world X** |
| `+0x4C` | float | **world Y** (height) — equals `GROUND(x,z)` exactly for a man on foot |
| `+0x50` | float | **world Z** |
| `+0xF0` | int | 0 = on field, 1 = parked at map edge. **NOT alive/dead** |
| `+0x114` | bits | flags (bit 0, bit 0x800 used by collision) **[D]** |
| `+0x1A0` | float | **forward X** } unit vector, the man's facing |
| `+0x1A4` | float | forward Y } |
| `+0x1A8` | float | **forward Z** } verified `(0,0,1)` = due north |
| `+0x1BC` | int | state enum, `0x2A` for the normal on-field cluster |
| `+0x1EC` | ptr | **-> UNIT** he belongs to |
| `+0x348` | int | **[?] NOT liveness** — retracted, see sec. 8 |

**Position is a vec3 at `+0x48`.** Reading it one field late (treating `+0x4C`
as X) silently uses terrain height as an X coordinate and looks plausible,
because the height range resembles map coordinates. That cost a long detour.

**Mounted flag:** `lift = manY - GROUND(x,z)` is **exactly 1.00 for a rider and
0.00 on foot** — a free, live mounted test that updates the instant a dragoon
dismounts.

---

## 2. HeightField (terrain) — `*(A + 0x9C)`  **[V]**

| offset | value (test map) | meaning |
|---|---|---|
| `+0x00` | ptr | grid data, **8-byte stride**, height is the float at offset 0 |
| `+0x08` | 10 | row shift (row stride = 1<<10) |
| `+0x0C` | 1024 | grid dimension |
| `+0x10` | 512 | index origin, added after flooring |
| `+0x14` | 1023 | index clamp |
| `+0x1C` | 1024.0 | world origin offset |
| `+0x20` | 2.0 | cell size |
| `+0x24` | 0.5 | 1 / cell size |
| `+0x38`,`+0x3C` | 105.8, 275.9 | min / max height — a good sanity range |

The engine's own query is `FUN_007192A0(this /*ECX*/, float* xz)`, a pure
bilinear interpolation with no side effects, so **reimplement it in Lua rather
than calling it** (`FPGROUND(x,z)`) — no ABI risk. Water height is
`FUN_00730810`, same shape, unexplored.

---

## 3. UNIT — `entity+0x1EC`  **[V]**

| offset | meaning |
|---|---|
| `+0x160` | **army object** — identical across one side, different between sides. This is the team test |
| `+0x178` | **current strength** — confirmed twice (8 in a dying army; 1005 exactly matching the player's card total in a full one) |
| `+0x18C` | **[?] NOT max strength** — reads 0 in a healthy battle. Retracted |
| `+0xA0..0xD0` | formation spacing constants, identical for same-type units |
| `+0xB0` | 3D position per `FUN_005293D0` — **reads 0 here**; the `D` array holds men, not `EMPIREBATTLE::UNIT` |

```lua
function FPFRIENDLY()                      -- never puppet an enemy
  local e = FPP(FPAA(FPD, FPI*4))
  local u = FPP(FPAA(e, 0x1EC))
  return FPP(FPAA(u, 0x160)) == FPARMY
end
```

---

## 4. CAMERA — `*( *(M+0x28140) + 0x250 )`  **[V]**

**Full 6-DOF control. Writes stick; nothing recomputes them per frame.**

| offset | meaning | writable |
|---|---|---|
| `+0x08` | **eye XYZ** | yes |
| `+0x14` | look-at target XYZ | derived = `eye + 200*forward`, rewritten by the engine |
| `+0x24` | FOV radians (1.2217 = 70 deg) | yes — this is how "aim" is done |
| `+0x28` | near plane (0.010) | yes |
| `+0x38` | far plane (8000) | yes |
| `+0x60` | **forward unit vector** | yes — aim through THIS, not `+0x14` |
| `+0x150`, `+0x15C` | mirrors of the eye | follow `+0x08` automatically |

Writing `+0x14` alone appears to work then silently reverts. Write `+0x60` and
set `+0x14 = eye + 200*fwd` to avoid a one-frame flash.

`yaw/pitch -> forward`: `fx=sin(yaw)cos(pitch)`, `fy=sin(pitch)`,
`fz=cos(yaw)cos(pitch)`; yaw 0 = +Z, pitch 0 = level.

**Do NOT use `CameraZoomTo`** for first person: it only sets the TARGET and the
engine keeps its own ~46-unit orbit radius, so the view stays a wide overhead
shot no matter how precisely the target is placed.

---

## 5. ORDERS — unit level  **[V for arity, D for opcodes]**

All act on the **current selection**, so the player must have the unit selected.

| native | static | args |
|---|---|---|
| `Current_Selection_Move_Forwards` | `5F6E40` | none |
| `Current_Selection_Move_Backwards` | `5F6DD0` | none |
| `Current_Selection_Halt` | `5F52B0` | none |
| `Current_Selection_Runs` / `_Walks` | `5F7050` / `5F7180` | none |
| `Current_Selection_Turn_Left` / `_Right` | `5F7070` / `5F70F0` | (bool, number) |
| `Fire_At_Will` | `5F7D50` | (bool) |
| `Current_Selection_Enable_Melee` | `5F6900` | optional bool |
| `CancelOrderForSelection` | `5F5DF0` | none |

Call them as wrapped Lua C functions (`ESE_WrapFn("s:5F6E40")`) — **not**
`ESE_Call`, which shares a guard with `ESE_Tick` and returns "guard busy" inside
the tick.

All funnel into **`FUN_005B3E00(opcode, amount)`** -> `FUN_00606DB0`.
Known opcodes: `4` toggle fire-at-will, `5`/`6` fire on/off, `7` halt,
`0x12` walk, `0x13` run, `0x14`/`0x15` melee, `0` rotate.
**Tracing `5B3E00` (steal 7) while issuing orders names the rest of the table.**

---

## 6. PER-ENTITY commands (the real FPS lever)  **[D]**

Empire's Battle Command Queue has **103** commands, and some are per-ENTITY —
the Lua API only exposes unit-level orders, but the engine does not stop there.

| command | handler | note |
|---|---|---|
| `BCQ_ENTITY_ORDER_MOVE` | `5D02F0` | **move ONE entity** |
| `BCQ_FIRE_PROJECTILE` | `5D0560` | fire one projectile; takes a `projectiles_table` index + position |

Single shot: **`FUN_00718930`** — a pending-shot object, one man one round:
`+0x74` already-fired flag, `+0x7C` start time, `+0x80` weapon descriptor,
`+0x28` owner, `+0x04` weapon (vt `0xC4` = muzzle, `0xCC` = recoil). Reached via
an adjustor thunk, so it is a **virtual update()** — the engine ticks pending
shots and each fires itself when its delay expires.

Spawn pair: `FUN_00746F80` (build launch params) + `FUN_00746EC0` (construct
projectile). **Any function calling BOTH is a launch site.**

---

## 7. ESE primitives

| native | use |
|---|---|
| `ESE_ReadInt/Float/Bytes/Str` | reads; `ReadBytes` now up to 256 bytes |
| `ESE_WriteFloat / WriteInt / WriteBytes` | writes; `WriteBytes` NOPs instructions live |
| `ESE_WrapFn(addr)` | wrap an engine `lua_CFunction` — safe inside the tick |
| `ESE_Call(conv, addr, ...)` | arbitrary call — **NOT usable inside `ESE_Tick`** |
| `ESE_Tick("on", src)` | per-frame Lua; source buffer only **2048 bytes** |
| `ESE_Input()` / `ESE_Input("11")` | mouse buttons+delta / DIK key state |
| `ESE_Trace(addr,"on",nargs,steal)` | code tracer — **steal must be computed from a disasm** |
| `ESE_TraceVT(obj,index,"on",nargs)` | **vtable tracer — prefer this, nothing stolen** |
| `ESE_TraceLog(addr)` | drain the 64-entry call ring |
| `ESE_Scan("8B 41 ?? 85")` | pattern search -> static addresses |
| `ESE_Caps()` | `MaxVertexShaderConst=256` (measured — no driver headroom) |

`ese_battle_autoexec.lua` (game root) runs on every battle-state acquisition,
loads `ese_core.lua`, and asks the manifest loader for battle-compatible mods.
The first-person entry loads each part independently, so a top-level `return`
leaves that part. Do not strip those returns: several are multi-line.

---

## 8. Known unknowns — do not assume these

- **[?] Per-man liveness.** `+0x348` was retracted: it counted 18 in a
  full 1005-man army. `+0x34`/`+0x38`/`+0xF0`/`+0x1BC` are corpse decoys —
  corpses lie on the field with entirely normal state. Currently the only solid
  test is `unit+0x178 > 0` (unit alive), not per-man.
- **[?] Does the engine upload >41 bone matrices?** The shader has room at 59
  bones, but that does not mean the skeleton loader fills the slots.
- **[?] Is `dip_batch` geometry replicated in the VB?** Decides whether stream
  instancing is a medium or large job.
- **[?] Reading the current selection.** `FUN_0056BED0` turned out to be a Lua
  ARG reader for `EMPIREBATTLE::UNIT`, not a selection getter.
- **[?] Directly driving one man.** A position write to `entity+0x48` is visible
  on the immediate read, but the formation/controller pass restores the old
  coordinates about one second later in an active battle. `FPDRIVE=true` sees
  synthetic W input and increments its movement counter, but the final entity
  position still snaps back. The useful target is now the engine-owned movement
  path, likely per-entity BCQ or the formation controller, not raw vec3 writes.
- **[?] Driving a man's animation.** Still unknown. The current direct-write
  path is not durable enough to evaluate animation state.

See [[project_empire_camera_6dof]], [[project_empire_terrain_height]],
[[project_empire_entity_position_vec3]], [[project_empire_firing_a_shot]],
[[project_empire_bone_ceiling]], [[project_empire_ese_tracing]].

### Selection gate and diagnostics [V]

`Current_Selection_Move_Forwards` (`005F6E40`) stores order code `0x0c` and calls
`005B3E50`. `005B3E50` only calls the real order router `005B3E00` when
`DAT_0137D488+0x3C0` is non-zero. In the live automated battle, a friendly,
strength-valid hooked man still had `gate3C0=0` and `ctx3D4=0`, so calling the
wrapped `Current_Selection_*` functions returned but submitted no order.

Use `FPSELSTATE()` before movement tests. A meaningful selected-unit order test
needs `gate3C0 != 0` and a valid context pointer. If those are zero, pursue the
UI selection arming path or the per-entity BCQ path instead of repeating
`Current_Selection_*` calls.
