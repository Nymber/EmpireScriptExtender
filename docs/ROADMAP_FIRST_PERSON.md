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
loads the shared runtime. The enabled `fp` manifest then loads `lua/fp/mod.lua`.
The shared 16 ms dispatcher calls the `fp.main` handler: `FPHOT`, `FPMOVE`,
`FPSTEP`, `FPCTL`.

The camera does not take over on load. `FPOFF` starts true, so the RTS camera
stays until `=` (DIK `0x0D`). `-` (DIK `0x0C`) hooks the living man nearest the
crosshair. Orders stay behind `FPCTLON` and left alt. Personal movement stays
behind `FPDRIVE`. Both are left false by the loader.

## Current live result (2026-09-23)

Fullscreen battle entry is automated and verified. In a live battle, the FP rig
loads and `FPSTEP=function`. `FPCMP()` identifies the nearest player-side unit
under the camera, and `FPCLAIMARMY()` records `FPARMY` from `unit+0x160` so
`FPFRIENDLY()` can gate control and direct movement against enemy units.

The camera follower works from a friendly man: setting `FPI=FPCMP_MAN`,
claiming `FPARMY`, then clearing `FPOFF` puts the camera at the man's eye and
the tick keeps it there. Mounted state is derived from
`entityY - FPGROUND(x,z)`.

Direct soldier movement is **not solved**. A direct `ESE_WriteFloat` to
`entity+0x48` is readable immediately, but the formation/controller pass restores
the original position about one second later. A synthetic W-key pulse with
`FPDRIVE=true` incremented `FPMOVED`, proving input and the tick fired, but the
entity position stayed at the formation-owned coordinates afterward. Treat
`FPDRIVE` as a probe until the engine-owned movement path or per-entity BCQ path
is found.

Current selection is still independent from camera possession. A
`Current_Selection_Move_Forwards` probe did not move the hooked man, which means
the selected unit and `FPI` were not the same unit in that test.

## Key files

- `lua/fp/mod.lua` — the folder the battle loader runs
- `tools/engine/dump_lua_api.ps1` — recovers this API (registrar `0058BD60`)
- `docs/battle_lua_api.csv` — all 208 functions with descriptions
- `ESE/ese_proxy.c` — where a battle-state binding would go
- `SKILL.md` (empire-trade-mod) — "NEVER probe a condition's signature by
  calling it", which applies verbatim to `SquadInfoByPointer`

### Current selection gate finding (2026-09-23)

`Current_Selection_Move_Forwards` reaches the real order router only if the
transient battle selection gate at `DAT_0137D488+0x3C0` is non-zero. In the
current automated battle test, `FPSELSTATE()` reports a clean friendly hook
(`FPI=1812`, unit strength `66`, `unitArmy == FPARMY`) but:

- `gate3C0 = 00 00 00 00`
- `ctx3D4 = 0`
- tracing `00606DB0` while calling `FPFN.fwd()` records `0` hits
- `WDSNAP/WDDIFF` records `0.00 m` movement for the hooked man

So the blocker is not the camera hook or player-team filter. The blocker is
arming or discovering the engine's current-selection context. Do **not** force
`+0x3C0` by write: the paired context pointer can be zero, which would make the
router call through a null selection manager. The next useful work is to find
what UI/button path sets `+0x3C0` and `+0x3D4`, or bypass selection entirely via
the per-entity BCQ path.

New helper: `FPSELSTATE()` in `lua/fp/fpselect.lua` prints the gate, context,
current hooked entity, unit, army, friendliness, and strength in one line.

`FPPICK()` now defaults to player-side unit-strength-valid targets only after
`FPARMY` is claimed. `FPPICKENEMY=true` intentionally restores enemy picking for
research. `FPREHOOKFRIEND(true)` recovers from enemy/corpse hooks by attaching
to the nearest strength-valid friendly man regardless of crosshair direction.

## Finish checklist

- [x] Automated 10 minute screen-check heartbeat created for unattended testing.
- [x] Friendly hook recovery exists: `FPREHOOKFRIEND(true)`.
- [x] Selection gate diagnostic exists: `FPSELSTATE()`.
- [x] Player-side pick condition added: `FPPICK()` defaults to claimed army only.
- [x] First-person entry and continued possession require the claimed player army and positive owning-unit strength (`FPCANENTER`/`FPTRYENTER`).
- [ ] Add exact per-man fallen/dead and routed-state checks after those fields are identified; unit strength is not proof that one particular entity is standing.
- [x] Crosshair dot drawn in first person.
- [x] Mouse cursor hidden in first person and restored outside first person.
- [ ] Shooting: left click causes the possessed man or his engine-owned command path to fire.
- [ ] Melee: melee input reaches the possessed man or selected valid friendly unit path.
- [ ] Proper 3D control: movement/turning uses engine-owned movement, not raw position writes that snap back.
- [ ] Mark verified live after each test pass in this file.

### Live verification: crosshair and cursor (2026-09-23)

- `ESE_View("on")` reacquires the active post-reset swapchain and draws into
  backbuffer zero during Present. Verified at viewport centre `960,540` in
  fullscreen `1920x1080`; 2,540 consecutive calls reported successful viewport,
  render-target and clear results (`00000000`).
- The visible result is a three-pixel white dot with a black rim. A centre crop
  confirmed the dot appears only while first person is active.
- `ESE_View("off")` removed the dot on the following frame and returned the
  balanced Win32 cursor-hide count from 32 decrements to zero. The Lua toggle,
  stale-manager path and invalid-entity path all call the same restoration.
- Battle automation was hardened during this pass: every click is now sent
  directly to Empire's window, and the default animated-screen settle is eight
  seconds. The five-Escape recovery remains the preflight from an unknown UI.

### Activation guard implementation (2026-09-23)

- `=` and crosshair picking now enter through `FPTRYENTER()` rather than setting
  `FPOFF=false` directly.
- `FPCANENTER()` re-resolves the battle state, requires a claimed `FPARMY`, a
  live entity-array entry, an owning unit, `unit+0x160 == FPARMY`, and positive
  `unit+0x178` strength.
- The per-frame follower repeats the army and strength checks. Failure disables
  first person and individual controls and restores the native view/cursor
  state. This deliberately does not claim to identify an individual corpse or
  a routed man; both still need traced engine fields.

### Shot-path slice (2026-09-23)

- Static caller/decompiler slicing separated `BCQ_FIRE_PROJECTILE` (`005D0560`)
  from the soldier path. The BCQ function reads a projectile-table index and
  position for a cinematic/queued projectile command.
- The engine-owned musket path is the ammo-state interface at vtable
  `0122F74C`: start/update/reset thunks lead to `007178A0`, `00718930`, and
  `00718420`. The update waits for the weapon delay, asks the weapon object for
  launch data, constructs the projectile, records the shot, and marks `+0x74`
  fired.
- The generic tracer now records `ECX`, `EAX`, `EDX`, and `EBX` beside its four
  existing stack words. This is needed to map `00718930`'s `ECX` ammo-state
  object back to the possessed entity before any call is attempted.
- Fixed a pre-existing `TRACE_MAX` macro collision found by the clean build:
  the eight-slot call tracer and 400,000-step instruction tracer now have
  separate limits, preventing out-of-bounds slot scans.
