# Empire: Total War — engine map and hook inventory

Everything here is **verified against the running game or the binary**, not
inferred. Addresses are static VAs with ImageBase `0x400000`; the process is
ASLR'd, so at runtime add `g_delta` (`ESE_Delta()`).

---

## 1. The path from a file on disk to a number on screen

```
  EmpireScriptExtender\lua\     campaign mods, copied by empire.ps1 launch
  EmpireScriptExtender\tools\   Ruby/PowerShell helpers, same copy
  ese_autoexec.lua              game root, same copy
  ese_battle_autoexec.lua       game root, same copy

  data\*.pack   PFH0 = header + DEPENDENCY BLOCK + index + blobs
  │             type 4 ("movie") auto-loads and overrides patch2.pack
  │
  ├─ db\<table>_tables\<file>
  │     additive WITHIN a folder; a full replacement is needed only to
  │     CHANGE a vanilla row. Strings are UTF-16LE.
  │     Versioned tables begin fc fd fe ff + int32 version (units v2,
  │     unit_stats_land v1) — dbdump.ps1 cannot read those, dbread.rb can.
  │
  ├─ text\localisation.loc          ◄── ONLY THIS AND ui.loc ARE READ
  │     Empire.exe holds exactly two .loc path strings:
  │       text/ui.loc            @ 0127EAE8
  │       text/localisation.loc  @ 0128ADCC
  │     There is NO text/*.loc enumeration. A pack shipping text\chain.loc
  │     or text\rum.loc is never opened and every string in it is blank.
  │
  └─ ui\campaign ui\<layout>        .ui via etwng ui2xml/xml2ui (byte-exact)
     ui\campaign ui\..._scripts\*.luac   unluac out, game's own Lua back in

  data\campaigns\main\startpos.esf   (esf2xml / xml2esf, byte-exact)
     campaign_env\trade_manager.xml   commodities_order, resources_order
     region_slot\<type>:<area>:<region>   ◄── THE CAMPAIGN'S SLOTS
        The DB's campaign_map_slots does NOT create slots in a campaign.
     region\<region>.xml              includes its slots
```

---

## 2. Engine subsystems we have mapped

### DB table registry → in-memory records

```
FUN_00ddc770   registers "unit_stats_land_tables", vtable PTR_LAB_01214a18,
               row handler LAB_00e2a4b0
   └─► FUN_00e2a4b0  (thunk)
         └─► FUN_00ddae30   THE ROW BINDER
               125 × LEA [EBX+off] + per-type reader call
```

**Records are grouped BY TYPE in memory — string pointers, then floats, then
ints — NOT in schema order.** Aligning "schema field #N → binder's Nth
offset" therefore fails: `armour` and `man_health` are adjacent in memory
though a string separates them in the schema.

`unit_stats_land` int block, anchored on `core_marksmanship` = **M**:

| offset | field |
|---|---|
| M−0x08 | armour |
| M−0x04 | man_health |
| M+0x00 | core_marksmanship (card: Accuracy) |
| M+0x04 | core_loading_skill (card: Reloading Skill) |
| M+0x10 | melee_attack |
| M+0x14 | charge_bonus |
| M+0x18 | melee_defence |
| **M+0x40** | **ammo** (card: Ammunition — rounds per man) |

Verified by a six-field match on `euro_line_infantry_britain`
(40, 30, 6, 9, 12, ammo 15) returning **exactly one** record, with the same
scan at ammo=99 returning **zero**. Records are separately allocated, not a
contiguous array.

### Resources and commodities

```
FUN_00D54B10   the resources_table accessor      (37 call sites)
  ├─ 00A04B96  raw-resource scan. Collects resources whose unit is null and
  │            wants EXACTLY TWELVE (00A04BB5 `cmp ebx,0x0C`). The loop's
  │            back-edge is unconditional and the bounds check yields NULL
  │            which is then dereferenced anyway → 0xC0000005.
  └─ 009EB6B4  per-resource loop, `div dword [ecx+esi*4]`. A zero divisor is
               0xC0000094 minutes into a campaign, with NOTHING in any log
               (the VEH guard does not catch integer divide).

00B1E4BC  CampaignUI.TradeInfo()'s eight inline price blocks, 181 bytes each,
          splice point 00B1E9A0. The native does NOT iterate the commodity
          table, so no data edit can add a ninth price to the UI.
009153A0 / 0098A040 / 00972440   the 9th-commodity accumulator chain; a dead
          "UnUsEd" table makes a lookup always return 14 and four unchecked
          stores then hit the return address.
00A54682  trade UI null-deref when a commodity has no unit.
00A04B96  trade-detail record dereference. EAX=0 was observed in a log that
          also reported the required commodity config missing. A later startup
          wired the config entries; opening Trade afterward remains unverified.
014490E4  the SIX hardcoded demand drivers — a seventh cannot be added.
```

### The campaign world

```
DAT_01473A78 ─► +0x924 ─► +0x8 = manager table
                            ├─ +0xC50  regions manager
                            └─ +0xC84  trade manager
                                          └─ +0xB8 commodity count
```

### Battle

```
FUN_005f1d60   builds the unit property bag the battle script layer sees:
               num_men, num_starting_men, num_cannons, num_starting_cannons,
               has_ammo, is_artillery, AmmoRemaining, PercentAmmoRemaining
               — the READ path. The write path is the stats record above.
limitless_ammo (@01203C5C) is a GAME OPTION, registered at 00403857 beside
               CPU_moves, city_management, battle_difficulty. Not a unit field.
```

### Lua — two separate states

| state | holds | notes |
|---|---|---|
| campaign | `events` (147), `conditions` (279), `effect` (12) | where the mod's logic lives |
| UI | `UIComponent`, `Component`, `panelmanager` | anything that draws |

`effect` in full: adjust_treasury, advice, ancillary, remove_ancillary, trait,
remove_trait, historical_character, historical_event,
advance_contextual_advice_thread, advance_scripted_advice_thread,
rewind_scripted_advice, suspend_contextual_advice.

---

## 3. WHERE WE ATTACH — the hook inventory

```
  ESE = dinput8.dll proxy (Zig, x86 detours, VEH guard, named pipe)

  ┌ ACTIVE PATCHES ────────────────────────────────────────────────────────┐
  │                                                                        │
  │  apply_commodity_fix()                                                 │
  │    NOP × 4 @ 009158BC, 009158EA, 00915920, 00915952                    │
  │    kills the out-of-bounds stores that corrupt the return address.     │
  │    WHY: the 9th commodity. Live-proven.                                │
  │                                                                        │
  │  apply_tradeinfo_extras()                                              │
  │    clones the 181-byte block at 00B1E4BC once per line of              │
  │    the installed ese_commodities.txt into a code cave, splices at      │
  │    00B1E9A0. Its maintained source is config/ese_commodities.txt;      │
  │    empire.ps1 sync installs it beside Empire.exe.                     │
  │    WHY: the UI's prices are eight inline blocks, not a loop.           │
  │    GATE: a ui_name with no matching component breaks the whole tab.    │
  │                                                                        │
  │  apply_raw_resource_count()                                            │
  │    writes imm8 @ 00A04BB7 (vanilla 0x0C → `raw_resources N`)           │
  │    WHY: the engine demands exactly 12 unit-less resources; promoting   │
  │    iron/timber/corn to commodities left 9.                             │
  │                                                                        │
  │  install_hook  lua_setfield / lua_getfield                             │
  │    WHY: discover the campaign and UI lua_States as they appear.        │
  │                                                                        │
  │  10 native functions registered into the campaign Lua state            │
  │  VEH crash guard (access violations only)                              │
  │  named pipe \\.\pipe\ese → live eval AND the in-game Lua compiler      │
  └────────────────────────────────────────────────────────────────────────┘

  ┌ PLANNED / NOT YET WIRED ───────────────────────────────────────────────┐
  │                                                                        │
  │  BATTLE AMMO           write unit_stats_land record M+0x40 from the    │
  │                        campaign's res_ammunition stock.                │
  │                        This is the STATS TEMPLATE, so it needs no      │
  │                        per-soldier counter and no campaign→battle      │
  │                        state transfer. Remaining: resolve the record   │
  │                        at runtime (table registry, or scan once and    │
  │                        cache).                                         │
  │                                                                        │
  │  UNIT COSTS            336 units costed in lua\unit_costs.lua.         │
  │                        add_restricted_unit_record DOES NOT EXIST, so   │
  │                        enforcement must be either a native hook on the │
  │                        recruitment path, or effect.adjust_treasury     │
  │                        charging a premium for missing kit.             │
  │                                                                        │
  │  RECIPE CONSUMPTION    WIRED AND RUNNING. Loaded by the 'production  │
  │                        chains' mod folder (mod.lua), not by hand.      │
  │                        ticks on FactionTurnStart; selftest PASSES      │
  │                        (ordering, conservation, non-negativity).       │
  │                        Recipes from generated chain_recipes.lua, with  │
  │                        BATCH quantities.                               │
  │                                                                        │
  │    MISSING: per-faction production QUANTITIES. All 279 conditions      │
  │    touching commodities/resources are BOOLEAN - none returns an        │
  │    amount - so the input must come from a native reader. Until then    │
  │    ESE.chain_production is nil and the tick logs "NO production        │
  │    source". Swapping it in is one line.                                │
  │                                                                        │
  │    Stock persists to chain_stock.lua, NOT into the save (nothing in    │
  │    the campaign state provides game_interface/save_value), so it does  │
  │    not rewind when the player loads an earlier save.                   │
  │                                                                        │
  │    Ordering is PRIORITY-STABLE deliberately: recipes share raw         │
  │    materials and allocation is greedy, so an arbitrary-but-valid       │
  │    topological order let naval supplies eat 48 of 50 timber and the    │
  │    musket works made 8 muskets beside 88 unused steel. Manifest order  │
  │    is the tie-break now; muskets went 8 -> 132.                        │
  └────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Instruments

| tool | use |
|---|---|
| `ghidra.ps1 <mode> <out> <args>` | headless Ghidra on the analysed project. **`callers` finds "who references this string"**; `xrefs` returns nothing and `decompile` on a mid-function address says COULD NOT DEFINE |
| `scanmem.ps1` | `-First/-Next` (width 1/2/4), `-Snapshot/-Diff` for unknown values, `-Read/-Dump/-Watch`. Compiled C#: ~1 s a pass, vs 190 s in PowerShell |
| `readdump.ps1` | crash dumps without a debugger |
| `dbread.rb` | versioned DB tables; tries every schema candidate and accepts only one that consumes the file EXACTLY |
| `dbdump.ps1`, `dbgen.ps1`, `dbfk.ps1`, `packtool.ps1` | version-0 tables, generation, FK sweep, pack extraction |

**Scanning discipline.** A running battle changes ~350k bytes by exactly 1 per
volley, dominated by float exponent bytes (0x3E–0x46, 0xBD–0xC5). Identify a
record by matching **four or more** fields at once, and always run a
deliberately-wrong control: a two-field match gave 6 hits for the right answer
and 6 for a wrong one.
