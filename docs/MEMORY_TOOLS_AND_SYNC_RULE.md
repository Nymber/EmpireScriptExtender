# Memory: behavior tools and ESE mirror rule

Date: 2026-09-23

## New behavior-to-code tools

The behavior research toolkit lives under:

- Dev/kit copy: `Total war empire tools\EmpireScriptExtender\tools\behavior`
- Live/game mirror: `EmpireScriptExtender\tools\behavior`

Tool files:

- `trace.rb` — shared JSONL trace loader and numeric helpers.
- `sysid.rb` — fits small candidate models for observed fields: static,
  counter, movement/turn integrators, proportional response, decay, cycles, and
  two-input integration.
- `active.rb` — ranks the next controlled experiment by expected model
  separation.
- `graph.rb` — dependency graph slicing plus CFG dominators and natural loops.
- `automata.rb` — categorical state transition summaries and ambiguous
  same-state/same-input futures.
- `constraints.rb` — cyclic counter checks with optional SMT-LIB/Z3 output for
  bit-vector wrap.
- `groups.rb` — candidate field grouping by co-observation, correlation, and
  optional shared read/write graph evidence.
- `capture.ps1` — live ESE collector that writes JSONL traces from battle
  memory using `ESE_ReadFloat` and `ESE_ReadInt`.

The workflow and limits are documented in `docs/BEHAVIOR_TO_CODE.md`.

Live validation done 2026-09-23:

- All Ruby analyzers passed syntax checks.
- Synthetic traces exercised sysid, active ranking, constraints, automata,
  graph slicing, dominators, and grouping with expected outputs.
- `capture.ps1` was live-tested in an active battle through the ESE pipe.
- A single-field capture bug was fixed by forcing `$parsed` and the unique key
  list to stay arrays.

## Rule: every new tool or Lua file must exist in both ESE trees

The editable source of truth is the kit/dev tree:

`Total war empire tools\EmpireScriptExtender`

The game reads a separate live mirror under the Empire install:

`EmpireScriptExtender`

Rule:

Any new file under `tools\...` or `lua\...`, and any edit to an existing tool or
Lua file, must be present in both trees before testing or handing off.

Default method:

```powershell
.\empire.ps1 sync
```

After syncing important changes, verify with hashes when practical:

```powershell
Get-FileHash '.\Total war empire tools\EmpireScriptExtender\path\file'
Get-FileHash '.\EmpireScriptExtender\path\file'
```

This rule applies to first-person mod Lua, behavior tools, game automation
scripts, pack helpers, UI helpers, and future tool categories. Generated packs
and staged output are not release source and do not belong in the release tree.
