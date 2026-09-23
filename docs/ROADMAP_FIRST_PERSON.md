# First / third-person unit command — plan

Goal: play a battle from a soldier's viewpoint instead of the RTS camera —
look around from behind or through the eyes of a man on the field, and command
from there.

## The key discovery that makes this plausible

Empire has a **battle Lua API of 208 functions** that nothing in this project
had touched. It is registered by a FOURTH registrar at `0058BD60`, in a
different shape from the campaign ones (`push desc, push name, push func`),
which is why the earlier `dump_conditions.ps1` never saw it.

Recovered with `tools/engine/dump_lua_api.ps1`; full list in `docs/battle_lua_api.csv`.
The load-bearing ones:

| function | documentation, verbatim from the binary |
|---|---|
| `CameraZoomTo` | **"In: Position (x,y,z), facing"** |
| `EnableShortcutHandler` | "In: true/false to enable/disable all keyboard shortcuts" |
| `ElapsedBattleTime` | "Returns the current time in seconds" |
| `ScreenSize` | "Retrieve the current width and height of the screen" |
| `SquadInfoByPointer` | (description is a copy-paste error; name says it takes a pointer) |
| `SetSelectionProxy` | "Takes the address of the entity (ship/unit) and a boolean flag" |
| `CameraFocusOnSelection` / `ZoomToUnit` | "Zooms the camera over to look at the unit specified" |

Movement and stance are fully scriptable:
`Current_Selection_Move_Forwards` / `_Backwards`, `_Turn_Left` / `_Right`,
`_Rotate_Left` / `_Right`, `_Runs`, `_Walks`, `_Halt`,
`CancelOrderForSelection`, plus every formation and ability
(`Current_Selection_Enable_Fire_At_Will`, `_Melee`, `_Square_Formation`, …).

There is also a **built-in debug camera**: the config string reads
`default battle camera: 0-totalwar 1-rts 2-debug`, exposed as
`default_battle_camera <card32>`. Worth trying before writing any code.

## The honest constraint, stated first

**Empire has no concept of controlling one soldier.** Every order in that API
is unit-level (`Current_Selection_*`). There is no "move this man" call, and
the men within a unit are driven by formation logic.

So there are two very different projects here:

- **First/third-person VIEW + command** — camera at a soldier's head, orders
  issued to his unit from that viewpoint. Well supported by the API above.
  This is the achievable one.
- **Being an individual soldier** with independent movement — NOT supported.
  The only honest route is a **one-man unit**: mod a unit to a single soldier,
  then unit orders become individual control. That is a real technique and it
  keeps every engine system (collision, animation, morale) intact, rather than
  fighting them by writing positions into memory.

Writing a man's position directly each frame is the obvious-looking third
option and should be resisted: it fights the animation and collision systems
every frame and will look and behave wrong.

## Phases

### Phase 0 — Reach the battle Lua state from ESE

ESE currently binds the **campaign** state and the **UI** states; it has no
battle binding at all (no `battle` anywhere in `ese_proxy.c`). Everything here
depends on evaluating Lua inside a live battle.

Method is the one already proven for the campaign state: hook `lua_setfield`
(`0x00F07E20`), watch for a state receiving a battle-only global, and bind it
by signature at runtime — never by a hardcoded pointer, since the `lua_State`
is a heap address that changes every launch.

*Deliverable:* `.\ese.ps1 -Battle "return ElapsedBattleTime()"` returns a
number during a battle.

### Phase 1 — Prove `CameraZoomTo` moves the camera

One call, from script, in a live battle. Either the camera jumps or it does
not, and the whole plan rests on it.

Try `default_battle_camera 2` (the debug camera) first — if the engine already
has a free camera, some of this may be unnecessary.

*Deliverable:* the camera demonstrably repositioned from Lua.

### Phase 2 — A per-frame tick

A camera that updates once is a screenshot. Battle UI components receive
update pulses (`dialogue_box.lua` has `OnUpdatePulse(time_ms)`), so a battle
panel is the natural driver. `TickPeriod` and `ElapsedBattleTime` give timing.

*Deliverable:* a counter visibly incrementing every frame in a battle.

### Phase 3 — Read a live soldier position

**A better lead than `SquadInfoByPointer`: the projectile impact path.**

The engine already traces shots and resolves them against something concrete.
`FUN_00D0C5B0`, found from the debug string `"\nPROJECTILE IMPACT: Target"`,
receives that something on every hit:

```c
FUN_00D0C5B0(p1, p2, p3, p4, p5, p6)
    (**(code **)*p3)()  ->  unit class (0 Fixed Artillery … 0x1c 1st Rate)
```

`p3` is a live target with a vtable — the per-entity handle the 208-function
API does not contain. **Built and awaiting one battle:** `ESE_Impact("on")`,
fire a volley into a single enemy unit, `ESE_Impact("report")`.

- many distinct pointers from one unit -> they are individual MEN, and this is
  the soldier handle the whole feature needs
- one pointer -> they are UNITS, and possession needs another source

Either answer is worth a volley. Log-only, off by default, capped at 48
entries, 6-byte steal (a 5-byte steal splits `and esp,-64`).

### Phase 3b — Read a live soldier position (fallback)

Needed to put the camera on a man. Two routes, cheapest first:

1. `SquadInfoByPointer` — the name promises exactly this; its description is a
   copy-paste error, so it must be probed. **Probe it the safe way**: recover
   its signature statically first. The campaign project killed a campaign by
   calling `FactionBuildingExists` with the wrong ARITY.
2. Failing that, the memory route — ESE already has `ESE_ReadFloat` and the
   verified world-pointer technique.

*Deliverable:* x/y/z of a selected unit, updating as it moves.

### Phase 4 — Third-person camera

Each tick: `CameraZoomTo(x - back*cos(f), y + height, z - back*sin(f), f)`.
Third person before first person, deliberately — you can SEE the soldier, so
when the camera is wrong it is obvious rather than merely disorienting.

*Deliverable:* camera follows a unit smoothly from behind.

### Phase 5 — Input

`EnableShortcutHandler(false)` hands us the keyboard. Mouse look needs raw
mouse deltas, which Lua does not have — ESE is the natural place, since it is
already an in-process DLL and can read input state and expose it as a native
function (the `ESE_Read*` family is the precedent).

*Deliverable:* mouse moves the camera facing; WASD read as state.

### Phase 6 — Movement

Map keys onto the existing order functions: W `Current_Selection_Move_Forwards`,
S `_Move_Backwards`, A/D `_Turn_Left`/`_Right`, shift `_Runs`/`_Walks`.

These are ORDERS, not direct motion, so expect order-queue latency and
formation behaviour rather than crisp WASD. Tuning that feel is the real work
of this phase, and it may be the point at which the one-man-unit approach
becomes necessary.

*Deliverable:* a unit driven around the field from the third-person camera.

### Phase 7 — First person, and a toggle

Camera to head height with zero offset, and a key to switch back to the RTS
camera. The toggle matters: this should be a mode you enter and leave, not a
replacement for the game.

## Risks, honestly

- **Orders are not controls.** Unit-level orders with formation logic will not
  feel like an FPS. Setting that expectation early is more useful than any
  amount of camera polish.
- **The battle state may be harder to reach** than the campaign one, and the
  whole plan is gated on Phase 0.
- **`SquadInfoByPointer` is undocumented in practice** — its description is
  wrong in the binary. Recover its signature statically before calling it.
- **Frame-rate coupling.** Anything driven from a UI update pulse inherits the
  UI's cadence; a camera that stutters at 30 Hz will feel bad even if correct.
- **Multiplayer and replays** should be left alone — `IsMultiplayer`,
  `IsReplay` and `IsSpectator` exist and should gate the whole feature off.

## Where it stands (2026-09-22)

Phases 0-2 are done. The battle state is bound, and `ese_battle_autoexec.lua`
loads `lua/fp/mod.lua` when `fp` is listed in `ese_mods.lua`. The tick is armed
at 16 ms: `FPHOT`, `FPMOVE`, `FPSTEP`, `FPCTL`.

The camera does not take over on load. `FPOFF` starts true, so the RTS camera
stays until `=` (DIK `0x0D`). `-` (DIK `0x0C`) hooks the living man nearest the
crosshair. Orders stay behind `FPCTLON` and left alt. Personal movement stays
behind `FPDRIVE`. Both are left false by the loader.

## Key files

- `lua/fp/mod.lua` — the folder the battle loader runs
- `tools/engine/dump_lua_api.ps1` — recovers this API (registrar `0058BD60`)
- `docs/battle_lua_api.csv` — all 208 functions with descriptions
- `ESE/ese_proxy.c` — where a battle-state binding would go
- `SKILL.md` (empire-trade-mod) — "NEVER probe a condition's signature by
  calling it", which applies verbatim to `SquadInfoByPointer`
