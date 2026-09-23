# Empire: Total War in VR — plan

Goal: 6DOF VR with motion controls, playing as a soldier in the line. Head
tracking, stereo, a musket you aim with your hands.

This is the most ambitious thing in this repo by a wide margin. It is not a
mod; it is an engine project. The plan is therefore built around **gates with
explicit kill criteria**, because a project this size fails by drifting, not
by hitting a wall.

## What is already true (2026-09-20)

| fact | consequence |
|---|---|
| `Empire.exe` is **PE32 (x86)**, DirectX 9, SM3 vertex shaders | every VR piece must work in 32-bit |
| **`d3d9.dll` is a static import** | the proxy-DLL trick already proven for `dinput8.dll` gives full render interception, free |
| **A 32-bit OpenXR runtime exists** — the `WOW6432Node\Khronos\OpenXR\1` key points at `virtualdesktop-openxr-32.json` | a 32-bit process CAN open an XR session. This was the single biggest "impossible" risk and it is retired. (Virtual Desktop Streamer is not currently installed here — the key is a leftover.) |
| No stereo/NVAPI/VR code anywhere in the binary | clean slate, nothing to fight |
| ESE already injects, hooks, reads memory, calls natives, registers Lua functions | the plumbing exists |
| Battle Lua API: `CameraZoomTo(x,y,z,facing)`, `EnableShortcutHandler` | camera and input control without touching the renderer |
| **No per-man control, no aimed fire, no stereo, no XR integration** | the actual work |

## The dependency stack

```
6DOF motion-controlled musket
  +- aimed fire from an arbitrary origin and direction
  |    +- per-man control              <- gated on the impact probe
  |    +- projectile spawn we can aim  <- NOT FOUND YET
  +- stereo rendering in DX9           <- the big one
  +- OpenXR session from a 32-bit host <- shown possible, unproven here
  +- 72-90 fps in stereo               <- the likeliest killer
```

Note what is NOT on the critical path: mesh work, the trade mod, the UI work.
This project reuses the injection pipeline and nothing else.

---

## STAGE 0 — Facts that can kill the project cheaply (days)

Each gate is a few hours and each can end the project before any real cost.
**Do all of Stage 0 before writing a line of renderer code.**

### G0.1 — Performance budget  *(tooling BUILT 2026-09-20)*

`ESE_FPS("on")` then read `ese_log.txt` — one `[fps] X (min Y max Z)` line per
second, measured at `IDirect3DDevice9::Present`, which is where the number
actually lives. `ESE_FPS("report")` for a summary.

**Render interception is in and needs no second proxy DLL.** `d3d9.dll` is a
static import of Empire.exe, so ESE patches the IMPORT TABLE entry for
`Direct3DCreate9` (a pointer swap - nothing to steal, no prologue to match, no
interaction with the crash guard), then patches COM vtables:
`IDirect3D9::CreateDevice` = 16, `IDirect3DDevice9::Present` = 17.

> This also de-risks STAGE 4: the render path is now reachable and proven
> before any stereo work begins.

**UNRESOLVED, and do not guess it:** stereo needs the view/projection
matrices, which on this engine arrive as VERTEX SHADER CONSTANTS
(`SetVertexShaderConstantF`) because it uses SM3 - not `SetTransform`. There
is **no DirectX SDK header on this machine** to confirm that method's vtable
index, and a wrong index corrupts an unrelated call.
**Safe way to settle it:** anchor on `Present` = 17 (confirmed once FPS
numbers appear), then probe with the read-only **getter**
`GetVertexShaderConstantF` rather than the setter - a getter that returns
`D3D_OK` with plausible data proves the index with no side effects.

Measure in (a) a 2-unit skirmish, (b) a 20,000-man battle, at your VR
headset's native resolution.

VR needs **72-90 fps in stereo**, which roughly doubles GPU cost and adds CPU
overhead. Empire is 32-bit and largely CPU-bound.

> **KILL CRITERION.** If a small skirmish cannot hold ~90 fps flat, the full
> vision is not reachable on this engine and the project should be re-scoped
> to head-tracked flat play. Knowing this costs half an hour; discovering it
> after building a stereo renderer costs months.

### G0.2 — Do individual soldiers exist as addressable things?

`ESE_Impact("on")`, fire one volley into a single enemy unit,
`ESE_Impact("report")`. Already built.

- many distinct pointers from one unit -> individual MEN, and the playable
  soldier is reachable
- one pointer -> UNITS only, and "be a soldier" needs a different source
  entirely (or becomes "possess a unit")

### G0.3 — Camera control from script

`.\ese.ps1 -Battle "return ElapsedBattleTime()"`, then prove `CameraZoomTo`
moves the camera. Already built, untested.

### G0.4 — A 32-bit OpenXR session  *(core risk RETIRED 2026-09-20)*

**Nothing needs installing** if SteamVR is already in a Steam library. It ships
a 32-bit OpenXR runtime. Find it the same way as the game (Steam registry,
then `libraryfolders.vdf`), not by assuming a drive letter:

```
<steam-library>\steamapps\common\SteamVR\steamxr_win32.json  ->  bin\vrclient.dll
<steam-library>\steamapps\common\SteamVR\bin\vrclient.dll
    machine = 0x014C (x86, 32-bit)
    exports: xrNegotiateLoaderRuntimeInterface
```

That export IS the runtime negotiation entry point, so a 32-bit process can
negotiate an OpenXR runtime here **today**. This was the single biggest
"impossible" risk in the whole plan and it is gone.

(An earlier check missed it by looking only at
`%ProgramFiles(x86)%\Steam`. SteamVR often lives in a secondary library. The
`WOW6432Node\Khronos\OpenXR\1` key may still point at a Virtual Desktop runtime
that is NOT installed — a leftover. Ignore the key.)

**No official loader is needed.** SteamVR ships `openxr_loader.dll` only in
`bin/win64`. That does not matter: the loader is just a discovery shim, so a
32-bit host can read `steamxr_win32.json`, `LoadLibrary` the runtime directly
and call `xrNegotiateLoaderRuntimeInterface` itself. Bypassing the registry
also sidesteps the stale Virtual Desktop entry.

**Still to prove:** an actual session with the Quest 3 attached (SteamVR needs
the headset presented to it via Link / Steam Link / Virtual Desktop). Write a
**minimal 32-bit C program** for this — no Empire involved. Never debug a
runtime through a game.

---

## STAGE 1 — The experience, flat (weeks)

Answer "is this fun?" before "is this stereo?".

1. Possession camera: attach to a soldier, cycle through the unit, exit to the
   commander view. (Roadmap: `ROADMAP_FIRST_PERSON.md`.)
2. Head tracking with **no stereo**: feed the Quest's yaw into
   `CameraZoomTo`'s `facing`. Only yaw - no pitch or roll - but it is days of
   work and needs no renderer changes.

> **GATE.** If standing in the line and looking around is not compelling flat,
> stereo will not rescue it. This is the cheapest possible test of the core
> idea and it should be taken seriously as a decision point.

## STAGE 2 — Stereo, borrowed (days)

Try **vorpX** on the flat game. It is a commercial generic DX9 injector and
Empire is squarely its era.

If it delivers acceptable stereo, the single largest piece of work in this
plan is skipped. Try it before building anything.

## STAGE 3 — The playable soldier (months)

Gated on G0.2.

1. Per-man control: hook the soldier update, drive one entity from input while
   the rest stay on formation AI.
2. Movement, then melee.
3. **Aimed fire**, which needs a projectile spawned with OUR origin and
   vector. `BCQ_FIRE_PROJECTILE` is a battle *cinematic* command, not this -
   the real spawn site still has to be found, most likely from the impact
   handler `FUN_00D0C5B0` backwards along its callers.

> The prize here: if the engine's own projectile can be spawned along an
> arbitrary ray, aimed fire is the ENGINE'S mechanic with a different origin,
> not a mechanic we invent - and the trace, impact, damage and death animation
> all come free. That is the difference between a plausible feature and a
> permanent fight with the engine.

## STAGE 4 — Custom stereo (months)

Only if Stage 2 is inadequate and Stage 1 proved the experience.

1. Proxy `d3d9.dll` (same pattern as `dinput8.dll`).
2. Intercept view/projection. Empire uses **SM3 vertex shaders**, so these
   arrive as shader constants (`SetVertexShaderConstantF`), not `SetTransform`
   - harder than a fixed-function game and the first real research task.
3. Render the scene per eye. The engine submits its draws once, assuming one
   view; getting two is the core difficulty of this entire stage.
4. Submit to OpenXR, 32-bit.

## STAGE 5 — Motion controls (months)

Controller pose -> aim ray -> the Stage 3 projectile spawn. Trigger to fire,
reload gesture, melee. Meaningless without Stages 3 and 4.

---

## Risks, honestly

- **Performance is the most likely cause of death**, and it is knowable in
  Stage 0 for the cost of an afternoon.
- **Empire has no aimed-fire concept.** Soldiers volley on order; melee is
  paired animation between engine-driven entities. Stage 3 either finds a
  spawnable projectile or invents a mechanic the engine will resist.
- **Nothing amortises.** UEVR works because Unreal is a shared, documented
  engine across thousands of titles. Every piece here is hand-rolled for one
  2009 game.
- **32-bit constrains every dependency** - runtime, loader, any library.
- **The animation system was built for formation soldiers**, not player-driven
  ones. "It works and feels wrong" is a real and unfixable outcome.

## What success could reasonably look like

Being honest about the target matters as much as the plan:

- **Likely reachable:** head-tracked, possessed first-person view of a battle,
  flat or with injector stereo, commanding your unit from the line.
- **Plausible with real work:** a playable single soldier who moves, fires
  using the engine's own projectiles, and melees, in stereo VR, in SMALL
  battles.
- **Probably not reachable:** full 6DOF room-scale motion controls at
  20,000-man battle scale at 90 fps on a 32-bit 2009 CPU-bound engine.

The middle outcome would still be the first VR first-person Total War, and
nobody has done it.

## Key files

- `ESE/ese_proxy.c` — proxy DLL, hooks, native registration
- `ESE/build.ps1` — 32-bit Zig build, already proven for a proxy DLL
- `docs/battle_lua_api.csv` — 208 battle functions
- `docs/ROADMAP_FIRST_PERSON.md` — Stages 1 and 3 in detail
- `SKILL.md` (empire-battle-control) — the API constraint and the impact hook
