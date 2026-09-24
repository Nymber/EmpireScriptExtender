# ESE mod and hook system

## User model

The toolkit copy is authoritative. The game copy is a synchronized runtime.

    .\empire.ps1 mods
    .\empire.ps1 enable fp
    .\empire.ps1 disable production-chains
    .\empire.ps1 launch

Activation changes apply when Empire creates the next campaign or battle Lua
state. Disabling a loaded mod does not attempt to erase Lua functions or undo
engine callbacks. ESE Manager provides the same actions without requiring
PowerShell use.

## What is a mod?

Every mod has three pieces:

1. A record in lua/ese_mods.lua, which controls path and activation.
2. A manifest.lua, which declares identity, version, supported states,
   priority, entry file, and dependencies.
3. An entry file, normally mod.lua.

Example registry record:

    { id='my-mod', path='my mod', enabled=true },

Example manifest:

    return {
      id='my-mod', name='My Mod', version='1.0',
      states={'campaign'}, entry='mod.lua', priority=100, depends={},
    }

Supported state names are campaign, battle, ui, and all. A state that does not
match is recorded as skipped and its entry file is not executed. Dependencies
load before dependants. Missing dependencies and dependency cycles reject the
load plan and are logged.

## Shared hook bus

Mods register named callbacks. They do not replace the engine event table or
the native frame callback.

    ESE.on_event('FactionTurnStart', 'my-mod.turn', function(context)
      if not conditions.FactionIsHuman(LocalFaction, context) then return end
      ESE_Log('human turn')
    end, 100)

    ESE.on_tick('my-mod.frame', function()
      -- battle frame work
    end, 100)

Lower priority values run first. Equal priorities preserve registration order.
Registering the same id again replaces that handler. Remove one with:

    ESE.off('FactionTurnStart', 'my-mod.turn')

The runtime installs one bridge into each engine event array and one ESE_Tick
callback. It then dispatches to all registered handlers. Every handler runs
through the native crash guard when available. A handler that faults three
consecutive times is quarantined for the rest of that Lua state.

## Loader lifecycle

1. The campaign or battle autoexec loads ese_core.lua.
2. The core reads ese_mods.lua.
3. It reads each listed manifest, validates dependencies, and sorts the plan.
4. Disabled and state-incompatible mods are skipped.
5. Each eligible entry runs with ESE.mod_dir and ESE.loading_mod set.
6. Results appear in ESE.mod_status; diagnostics go to ese_log.txt.

Useful live values:

    return ESE.state
    return ESE.mod_status['fp'].state
    return #ESE.handlers.tick

## Failure boundaries

- Lua compilation or entry errors fail one mod and allow the plan to continue.
- Repeated callback failures quarantine that callback.
- A native function can still corrupt engine state before the guard catches
  the access violation. Restart Empire after any native fault.
- Hot unload is unsupported. A future lifecycle can add shutdown, but it must
  unregister callbacks and restore every mutation made by the mod.
- The ui manifest records UI ownership, but ESE does not yet have a general
  UI-state mod autoexec. UI assets continue through their existing panel paths.

## Native Lua hook re-entry

The native ESE hooks observe Lua field access and protected calls. While ESE
itself registers natives or executes an autoexec file, those same Lua API calls
must not trigger the hook-side pumps or state discovery again. The native
runtime suppresses observer work for the duration of those ESE-owned Lua API
batches, while the detours still pass through to the original Lua functions.
This prevents recursive Lua entry during registration and autoexec execution.

## Adding a mod

Create the folder, manifest, and entry in the toolkit tree; add one registry
record; then run empire.ps1 sync. New Lua and tool files must be copied to both
the toolkit and live game trees through that command. Generated packs and
staging outputs are not part of this system or a release.
