# Writing an ESE Lua mod

The toolkit tree is authoritative. Run empire.ps1 sync after editing; Empire
loads the mirrored tree under its installation directory.

## Files

Create a folder containing manifest.lua and mod.lua, then add one record to
ese_mods.lua:

    { id='my-mod', path='my mod', enabled=true },

Manifest:

    return {
      id='my-mod', name='My Mod', version='1.0',
      states={'campaign'}, entry='mod.lua', priority=100, depends={},
    }

Use campaign, battle, ui, or all in states. The loader skips incompatible
states before compiling the entry.

## Hooks

Register a named engine event:

    ESE.on_event('FactionTurnStart', 'my-mod.turn', function(context)
      if not conditions.FactionIsHuman(LocalFaction, context) then return end
      ESE_Log('my mod turn')
    end, 100)

Register battle frame work:

    ESE.on_tick('my-mod.frame', function()
      -- per-frame work
    end, 100)

Lower priority numbers run first. Reusing the same id replaces that handler.
Use ESE.off(event, id) to unregister. Do not append directly to events or call
ESE_Tick directly; the shared runtime owns those engine bridges.

The loader sets ESE.mod_dir and ESE.loading_mod while mod.lua runs. Read sibling
files from ESE.mod_dir. Windows paths written in Lua should use long brackets.

## Activation

    .\empire.ps1 mods
    .\empire.ps1 enable my-mod
    .\empire.ps1 disable my-mod

Activation changes apply on the next Lua state. Hot unload is unsupported.
Inspect ese_log.txt and ESE.mod_status for load results.

Full behavior, dependencies, failure isolation, and limitations are documented
in docs/MOD_SYSTEM.md.
