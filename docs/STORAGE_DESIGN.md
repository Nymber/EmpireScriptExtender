# Commodity storage: keep it, or sell it

A design for per-faction stockpiles with player control over what is released
to trade and what is held back for war industry and recruitment.

Every mechanism below uses an API or a technique already **verified in this
project**. Where something is not yet proven, it is marked — the design does
not rest on it.

---

## 1. The constraint that shapes everything

**The engine owns production, pricing, trade and display. We own conversion,
storage and policy.** That division is forced, not chosen:

- `commodity_prod_<x>` effects on buildings already produce goods, and the
  engine already trades them and pays for them.
- Prices, supply and demand are computed natively (`FUN_00a65a70`).
- Empire's diplomacy UI has no concept of a resource at all, so goods cannot
  be bargained over there.
- No Lua condition returns a commodity *quantity* — all five are boolean.

So a storage system must not try to be the economy. It must sit beside the
engine's economy and change the player's incentives.

### The double-counting trap

A Foundry produces steel through `commodity_prod_steel`. If the simulation
*also* turned iron+coal into steel, every foundry would create steel twice —
once in the engine's trade figures and once in our stockpile.

**Therefore recipes are not production. They are a CONSUMPTION OBLIGATION
attached to production the engine has already performed.** A foundry that
produced 135 steel this turn owes 68 iron and 102 coal, taken from the
stockpile. Chains become a supply problem, which is the point, and the
engine's economy is left untouched.

---

## 2. Data model

Per faction, per commodity:

| field | meaning |
|---|---|
| `stock` | units currently held |
| `target` | how many units to hold back before releasing any to trade |

One number per good is the whole control surface. `target = 0` means "sell
everything", which is vanilla behaviour and the default.

Derived each turn, per good:

```
produced   from buildings we own (see §4)
reserve  = min(produced, max(0, target - stock))
export   = produced - reserve
```

Below target you keep what you make; at or above it, everything flows to
trade. It is one number, it is obvious on screen, and it does not need a
percentage slider or a queue.

---

## 3. What reserving COSTS — and why we never write to the engine

The engine has already paid for the full production. If the player holds some
back, they should not have been paid for it.

```
treasury -= reserve x current_price      via effect.adjust_treasury (CONFIRMED)
```

That is the opportunity cost of stockpiling, and it is exactly right: iron in
a warehouse is iron you did not sell. Crucially it needs **no write into the
engine's trade arrays** — nothing to find, nothing to corrupt, nothing that
breaks when a patch moves a structure.

Shortfall works the same way in reverse. If a factory produced goods whose
recipe inputs are not in stock, the inputs were bought abroad:

```
treasury -= missing x price x IMPORT_MARKUP      (markup ~1.5)
```

A musket manufactory with no steel supply still makes muskets — it just
bleeds money every turn. That is a legible, self-explaining penalty, and it
never blocks the player with an error they cannot act on.

---

## 4. Where production comes from

Not from the engine — no Lua condition returns a quantity. We compute it from
buildings we own, using the same manifest that defined them:

```
for each region we own                (RegionTurnStart already collects these)
  for each chain building level       (from chain_manifest.txt)
    if RegionSlotBuildingTypeExists(level, context)
      produced[commodity] += output(level)
```

`RegionSlotBuildingTypeCount`, `RegionSlotBuildingTypeExists`,
`BuildingTypeExistsAtSettlement` and `FactionBuildingExists` all exist in the
campaign API. Outputs per level are ours already (base x1 / x1.7 / x2.7).

This is better than reading engine memory: it needs no addresses, survives a
patch, and cannot desynchronise from the manifest that generated the
buildings.

**Caveat to verify:** these are native functions that fault on wrong arity or
a wrongly-scoped context, so each must be called through `ESE_Protect` with
its signature confirmed one at a time, exactly as the existing samplers were.

---

## 5. The turn sequence

On `FactionTurnStart` (human faction; AI is §8):

1. `produced = derive_production(context)`
2. For each good: split into `reserve` / `export` by `target`
3. `treasury -= sum(reserve x price)` — the goods you kept
4. `stock += reserve`
5. **Recipe obligations**: for each produced good with a recipe, consume
   `inputs x (produced / batch)` from stock; bill any shortfall at the import
   markup
6. **Recruitment draw** (when enforcement lands): subtract muskets, uniforms,
   ammunition and cannon for units raised this turn
7. Persist, and report what was made, kept, sold and missing

Order matters: reserve before consume, so this turn's production can feed this
turn's factories.

---

## 6. Player control

The World Market panel is already ours — 23 slots, a working scrollbar, live
tooltips. The control fits there with no new screen:

- each commodity slot gains a second line: `stock / target`
- clicking the slot cycles the target through presets —
  **0 (sell all) → 100 → 500 → 2000 → 0**
- the tooltip already lists what a good is made from and what it feeds; it
  gains "in store: N" and "reserving until N"

Presets rather than free entry: Empire's UI has no text-input component we
have found, and a click-to-cycle needs only the component and handler pattern
already proven for the scrollbar.

### 6a. TWO FILES, ONE WRITER EACH (settled 2026-09-20)

This is a correctness requirement, not tidiness. Targets are written by the
**UI** lua_State (the Stock Controls tab); stock is written by the **campaign**
state. The two cannot call each other, so they share through files — but
`M.flush()` rewrites `chain_stock.lua` **wholesale** from `M.store.data`, a
copy loaded once at campaign start. A target written into that file from the UI
would therefore be silently erased at the next end of turn: the click appears
to work, and quietly undoes itself a turn later.

    chain_stock.lua     campaign writes, UI + target.ps1 read
    chain_targets.lua   UI + target.ps1 write, campaign re-reads each turn

Enforced in three places, so no single mistake reintroduces the race:

- `M.run_turn` calls `M.reload_targets()` first, so a click lands next turn.
- `M.flush` **skips any `target_` key** — which also migrates an older
  `chain_stock.lua` the first time it is written.
- `M.set_target` writes through immediately rather than deferring to flush.

Verified against the live game: chain_sim reads the exact bytes the panel's
serialiser emits, chain_sim's own writer produces something the panel parses,
`set_target` preserves neighbouring keys, and `flush` provably writes no
`target_` key even when one is planted in its store.

### 6b. Click handling

The slots were already interactive — flag block `[1,1,0,1,0,0,0]`, identical to
`arrow_L`/`arrow_R`, and their tooltips already worked, so they were in the
hit-test. They only lacked a script. `add_stock_click.rb` attaches the vanilla
idiom, walking up by **name** rather than a `Parent.Parent.Parent` chain:

```lua
local this = UIComponent(Address)
local parent = UIComponent(this:Parent("government_screens"))
function OnLeftClickUp()
    parent:LuaCall("CycleStockTargetUp", "coffee")
end
```

Two things this had to work around:

- **`SelectTab` returns false when its tab is already selected**, and
  `ShowStockControls`' whole body sat inside `if SelectTab("stock") then`. A
  click handler calling it would refresh nothing, so the redraw is split into
  `RefreshStockControls`.
- **Only `OnLeftClickUp` has precedent in this panel** (7 uses; no right-click
  anywhere). So the left click *wraps* the full ladder and is a complete
  control alone. An `OnRightClickUp` handler is emitted too — if the engine
  never dispatches it, the function is simply never called.

A reasonable default policy ships with the mod — 0 for the eight vanilla
trade goods (they exist to be sold), a modest target for military inputs —
so a player who never touches it sees vanilla behaviour plus working chains.

---

## 7. Persistence

Today: `chain_stock.lua`, written by `chain_sim.M.flush()`.

**This is a real weakness.** The file does not rewind when the player loads an
earlier save, so stock can be out of step with the campaign. It is acceptable
only because nothing in the campaign Lua state provides `save_value` —
`effect` has twelve members and none of them persist.

If a `game_interface` is ever found, `M.use_engine_store(gi)` already exists
and switching is one line. Until then the limitation belongs in the mod's
release notes, not hidden.

---

## 8. AI factions

Phase 1 ships human-only: the tick already checks `FactionIsHuman`.

Doing this for the AI means running the same derivation for ~40 factions every
turn, and the AI cannot be taught to value a stockpile — its behaviour comes
from `campaign_ai_manager_behaviour_junctions`, which has no concept of one.
The honest options are:

- **leave the AI on vanilla trade** (it sells everything, as now), and accept
  that stockpiling is a player mechanic; or
- give the AI a flat implicit reserve so it is not strictly disadvantaged,
  applied as a cheap per-faction constant rather than a simulation.

The first is recommended until the player-facing loop is proven.

---

## 9. Build order

| phase | work | blocked by |
|---|---|---|
| 1 | `derive_production()` from building counts; verify each condition's arity live | needs a loaded campaign |
| 2 | reserve/export split + `adjust_treasury` opportunity cost | nothing |
| 3 | recipe obligations + import markup for shortfalls | phase 1 |
| 4 | World Market stock/target display and click-to-cycle | nothing |
| 5 | recruitment draw | unit-cost enforcement (no `add_restricted_unit_record`) |
| 6 | move persistence into the save | finding `save_value` |

Phases 2 and 4 can proceed immediately. Phase 1 is the gate for the rest and
needs one campaign session to confirm the condition signatures.

---

## 10. What this deliberately does NOT do

- **No writes into the engine's trade arrays.** Reserving is modelled through
  the treasury instead. Nothing to find, nothing to break.
- **No new UI screen.** The World Market panel already exists and is ours.
- **No blocking of the player.** Shortages cost money; they never produce an
  error the player cannot act on.
- **No second economy.** The engine's prices, demand and trade routes remain
  authoritative; storage changes only what the player chooses to sell.
