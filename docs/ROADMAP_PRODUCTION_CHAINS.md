# Production chains, manufactured goods, and localised resources

Goal: ammunition, rifles and cannon must be *manufactured* from inputs; iron,
food and the other raw materials must come from the regions that actually
produce them.

This is a much larger feature than adding commodities, and it divides cleanly
into "what the engine already does", "what it refuses to do", and "what we
therefore have to simulate". Getting that division right is the whole plan —
building on the wrong side of it wastes weeks.

---

## STATUS — 2026-09-23

| phase | state |
|---|---|
| 1 — the goods exist | **DONE.** 23 commodities, startpos widened, all visible + scrollable |
| 2 — the buildings | **DONE.** 46 building levels, per-culture art, descriptions, slot-gated |
| 3 — the chain simulation | **code done, selftest passes; first real production run pending** |
| 4 — consequences | it is a treasury penalty |
| 5 — the AI | not started |
| + Stock Controls UI | **persistent toggle layout deployed; live click behavior and Trade-tab round trip still unverified** |

### Trade-tab crash and tab visibility correction (2026-09-23)

The fault at static `0x00A04B96` is inside the native trade-detail builder and
reads through a null `TRADE_DETAIL_RECORD`. The log records this fault before
the corrected startup later reports all 15 extra commodities wired into
`TradeInfo`. This supports a missing-config explanation for the earlier fault,
but the log does not prove the Trade tab was opened after the corrected
startup. Treat the fix as awaiting that live retest. The config drives ESE's
cloned `TradeInfo` blocks and the `raw_resources` count patch; it is required
runtime data. Its maintained source is `config/ese_commodities.txt`, which is
installed, synchronized, diagnosed, and released with ESE.

That corrected startup later logs a different fault at static `0x004DAE5D`,
inside a short-string copy routine. It is a separate fault address and has not
been tied to the Trade tab or the Stock Controls layout. Record it separately
if it reproduces; do not count it as evidence for or against the trade fix.

Retest attempt on 2026-09-23: ESE logged the config, wired 15 `TradeInfo`
entries, and patched `raw_resources` from 12 to 9. Windows then recorded an
`Empire.exe` heap-corruption exit (`0xC0000374`) at 15:33. Relaunching that same
installed build initialized ESE again, but the process exited before a game
window was available; no Trade-tab round trip occurred. The commodity fix is
therefore not yet runtime-verified.

The no-hide layout was deployed as an isolated UI change. The earlier 15:39
launch initialized ESE's config and D3D/DirectInput hooks, then exited before a
game window appeared; Windows logged no new crash event for that attempt.

The runtime hide button was retired because it hid the only control capable of
reopening Stock Controls and called UI wrappers without validating lookups. It
was replaced with a persistent header toggle built into the government-screen
layout. The toggle clones the Stock Controls tab artwork, removes the cloned
storage grid, and places the control under the panel root outside `tab_group`.
Its handler checks component lookups, returns to Trade before hiding the tab,
and can show the tab again.

The toggle layout passed structural checks and was packed with the existing
government-screen script. `zz_stocktab.pack` was deployed after Empire was
closed; the deployed SHA-256 matched the built pack. This confirms installation,
not runtime behavior. The toggle clicks and Trade-tab round trip still need a
live campaign check.

### What changed in the plan, and why

**Phase 0's premise was wrong.** `add_restricted_unit_record` and
`add_restricted_building_level_record` do not exist in this build — proven by
enumerating the API, not by failing to call them. Scarcity therefore cannot
block recruitment directly. Phase 4 is re-specified as an economic penalty via
`effect.adjust_treasury`, which is the only mutator that touches money.

**The whole scripting API is now enumerated statically** (`tools/engine/dump_conditions.ps1`,
`-Discover`), and it bounds everything this mod can ever do from script:

| registrar | entries | namespace |
|---|---|---|
| `00D1F870` | 279 | `conditions` — read-only queries |
| `00D210A0` | 111 found / 147 live | `events` — callbacks |
| `00D1FB60` | **12** | `effect` — every mutator in the game |

Conditions and effects match the live counts exactly; the event walk misses 36,
which are presumably registered with a different push pattern. **There is no
engine command layer.** The 12 effects are traits, ancillaries, advice, and
`adjust_treasury`. Nothing builds, moves, trades or withholds. Every
"consequence" this mod imposes must therefore be simulated and billed, not
commanded — that is a property of the engine, not a shortcut.

### Phase 3 — the production path is PROVEN (2026-09-20)

- `chain_sim.lua` is complete: allocation, obligations, imports, billing.
  `selftest` passes (`allocation, obligations and billing all hold`).
- The signature was never confirmed, so `accumulate_region` returned
  immediately and production was always zero. Fixed:
  `RegionSlotBuildingTypeCount(<building_levels key>, context)` at `0086E700`,
  recovered statically. `M.sig` is hard-coded to it.
- **Proven in a live campaign.** Across a full turn the accumulator made
  ~6,250 condition calls over 136 region turns with **no crash**, and a probe
  over all 201 vanilla building levels in one of our own regions returned
  `minor_magistrate x1` with **0 faults**. The condition reports real
  buildings; the mechanism works.
- Production reads zero because **no chain building has been built yet** —
  that is the correct answer, not a defect.
- `empire.ps1 sync`, `install`, and `launch` copy the complete Lua runtime into
  the install. The enabled `production-chains` manifest loads only in a newly
  created campaign state; a campaign already open keeps its existing state.

**Region filtering was wrong and is fixed.** `RegionTurnStart` fires for every
region in the world (136 between our turns) and the accumulator only resets on
the human `FactionTurnStart`, so it was walking AI regions too and would have
counted their output as ours. Now gated on `RegionIsLocal`, and the region
counter only increments when a region is actually accumulated.

"Region slot" means the NON-settlement slots. Probing with `basic_roads` or
`governors_residence` returns 0 in a region that plainly has them, which reads
as "the condition is broken" and is not.

### Next step: build one, and watch it produce

Slot requirements (`building_chain_to_slots`):

| chain | slot | chain | slot |
|---|---|---|---|
| naval_yard | `port` | foundry | `town-metal` |
| coal_mine | `iron` | musket_manufactory | `town-metal` |
| lead_mine | `silver` | weavers_mill | `town-textile` |
| saltpetre_works | `india_highlands` | uniform_works | `town-textile` |
| powder_mill / cartridge_works / cannon_works | `settlement_ordnance` | rum | `caribbean`, `cuba` |

For Britain the `port` slot is the most available, so a **Naval Yard** is the
cheapest thing to test with. Build it, let construction finish, then the
following turn should show non-zero `produced` and the stock targets start
holding goods back.

### Known open risk on the money path

`effect.adjust_treasury` is at `00874FD0` and has a **silent no-op path**:

```c
ppiStack_2c = 0;  FUN_00441250();
if ((*(code *)(*ppiStack_2c)[0xe])() != 0) { ...adjust... }
return 0;                       // otherwise nothing happens, no error
```

It has **no vanilla call sites anywhere**, so there is no reference for how to
call it correctly; the documented parameter is just `amount`, while we pass
`(amount, context)`. Treasury movement has never actually been observed. Until
it is, the economic consequence of holding stock is unproven — and it is what
Phase 4 rests on.

### Stock Controls UI — persistent toggle deployed, live retest pending

A fifth government-screen tab: full-panel 2x12 grid of all 23 commodities, each
row `icon · name · stock · typed target · checkbox`. The target field is
Empire's own `template.text_input.lua` cloned from the save-game screen;
the checkbox is the vanilla automanage checkbox. Targets live in
`chain_targets.lua`, written only by the UI state, re-read by the campaign
state each turn — one writer per file, because `flush()` rewrites
`chain_stock.lua` wholesale and would otherwise erase them.

The deployed government-screen layout includes a separate header toggle,
outside `tab_group`, so the control remains available while the tab is hidden.
The handler calls `ShowTrade` before hiding Stock Controls, and guards the
panel and tab lookups. The former `button_hide_stock` action is retired because
it hid its own route back into the panel. The new pack is deployed, but its
show/hide behavior has not yet been exercised in a live campaign.

### Next single step

Launch the deployed build into a campaign. Open the government screen and
verify the header toggle appears. Click it once to return to Trade and hide
Stock Controls; click it again and verify Stock Controls can be selected.
Then open Trade and Stock Controls in both directions, watching for
`0x00A04B96`. Record any `0x004DAE5D` occurrence separately. Startup logging
of the 15 extra commodities and `raw_resources=9` confirms configuration was
loaded, but does not substitute for this UI interaction check.

---

## 1. What the engine gives us for free

| capability | mechanism | status |
|---|---|---|
| Resources localised to regions | `resources_tables.slot_bed` → `slots_tables.slot`, placed per region by `campaign_map_slots` | **vanilla already works this way** |
| Buildings producing a commodity | `building_levels` → `building_effects_junction` → `effects` → `effect_bonus_value_commodity_junction` | proven with rum |
| Trade, prices, supply/demand | native price engine, `commodities_demand_junction` | proven |
| A commodity in the UI | `ese_commodities.txt` + a World Market slot | proven, scrollable |
| **Engine-enforced unit restrictions** | `add_restricted_unit_record` | listed in `LUA_API.md`, **DISPROVEN** — see status table |
| **Engine-enforced building restrictions** | `add_restricted_building_level_record` | listed in `LUA_API.md`, **DISPROVEN** — see status table |

The last two matter enormously: they are how "no rifles ⇒ cannot recruit line
infantry" becomes a *rule* rather than a suggestion, without touching the
recruitment UI.

**"Localised resources" is largely already true.** `res_iron` has
`slot_bed = iron`, `res_corn` has `corn`, and those slots exist only in
regions that have them. What vanilla does *not* do is make anything downstream
depend on them. That dependency is the actual work.

## 2. What the engine refuses to do

**There is no native concept of a building consuming a commodity.** Nothing in
`building_effects_junction` takes an input; effects only add.

**Demand drivers cannot be extended.** `commodities_demand_junction.driver` is
an FK to `commodities_demand_drivers_tables`, which looks like an open table —
it is not. The six driver names are hardcoded string literals constructed into
a fixed array at `0x014490E4` by the initialiser at `0x00420960`:

```
0x14490e4 <- "ddr_TW"                 0x14490f0 <- (4th)
0x14490e8 <- "ddr_cotton_production"  0x14490f4 <- "ddr_textile_production"
0x14490ec <- "ddr_GDP"                ...
```

Exactly the shape of the dead `"UnUsEd"` commodity table. Adding a
`ddr_iron_production` row would produce a key the engine has no code for. We
can *reuse* the existing six (e.g. drive a new good's demand from
`ddr_textile_production`), but we cannot add a seventh.

**Consequence: the chain logic must live in our script.** The engine stores,
prices, trades and displays; ESE computes what consumes what.

## 3. Architecture

```
  DB + startpos          →  goods exist, are produced, priced, traded, shown
  ESE Lua (per turn)     →  consumption, conversion, shortages
  add_restricted_*       →  shortages have teeth (no rifles ⇒ no recruitment)
```

Each turn, for each faction:

1. read production of every good (per region, from the arrays we already dump)
2. for each recipe, consume inputs and credit outputs, limited by the scarcer
3. write the result back — stockpiles persisted with
   `game_interface:save_value` / `load_value` (native, no external files)
4. apply `add_restricted_unit_record` for anything the faction cannot supply

Nothing here needs new natives. It needs the per-region arrays we already read
in the accumulator dump, plus the campaign API already enumerated.

## 4. The goods

Keep the count honest — every commodity costs DB rows, startpos array slots, a
UI slot, a `.loc` entry and an icon, and the startpos round trip is ~10
minutes, so they must be added in **one batch**, not one at a time.

| tier | goods | notes |
|---|---|---|
| raw | iron ore, coal, saltpetre, lead, timber, grain, horses | mostly exist as resources already; need promoting to commodities |
| intermediate | pig iron/steel, gunpowder, textiles | new; each is a recipe output and an input |
| finished | ammunition, muskets/rifles, cannon, uniforms | new; consumed by recruitment |

Vanilla ships 8 commodities and 20 resources. This proposes roughly 12–14 new
commodities — within the 21 already proven to run clean, but **verify the
ceiling again at the real number** before authoring content.

Recipes (a first cut, to be balanced not guessed):

```
saltpetre + coal            -> gunpowder
iron ore  + coal            -> steel
gunpowder + lead            -> ammunition
steel + timber              -> muskets
steel + timber (more)       -> cannon
textiles                    -> uniforms
```

## 5. Phases

### Phase 0 — prove the two untested levers (cheap, do first)

`add_restricted_unit_record` and `add_restricted_building_level_record` are the
load-bearing mechanisms and neither has ever been called. Test them from ESE in
a live campaign: restrict one unit, confirm it disappears from recruitment;
lift it, confirm it returns. **If these do not work, the whole design changes**
— scarcity would have no consequence and the feature becomes decorative.

One session, no content authored.

### Phase 1 — the goods exist

Add every new commodity/resource in one batch via the existing framework:
`dbgen.ps1` → `add_commodities.rb` → `extend_commodity_arrays.rb` →
`set_commodity_demand.rb` → one `xml2esf`. Then UI slots
(`add_market_slot.rb --cols 8 --no-grow`, the scrollbar handles the rest),
`.loc` entries, icons, and lines in `ese_commodities.txt`.

Verify: DB count, region arrays widened, no fault, all goods visible and
scrollable.

### Phase 2 — the buildings

Author the production buildings with the proven chain wiring, and place them
with `building_chain_to_slots` so a foundry needs an iron region, a powder mill
needs saltpetre, and so on. This is where "localised" becomes real: the slot
requirement *is* the localisation.

Verify: a building is offerable only in a region with the right slot, and
producing it raises that good's supply.

### Phase 3 — the chain simulation

The ESE script: per-turn consumption, conversion, stockpiles via
`save_value`/`load_value`. Start with **one** recipe end to end
(saltpetre + coal → gunpowder) and only generalise once it is correct.

Verify: stockpiles persist across save/load; a region losing its coal supply
visibly reduces gunpowder output next turn.

### Phase 4 — consequences

Wire shortages to `add_restricted_unit_record`. Surface it in the UI so the
player can see *why* a unit is unavailable — otherwise it reads as a bug.

### Phase 5 — the AI

The campaign AI knows nothing about any of this. It will not build foundries or
trade for saltpetre, so on current evidence it will fall behind badly. Options,
in order of realism: bias its behaviour via the decision DB already decoded
(`project-trade-mod-campaign-ai-decisions`), or have the script quietly supply
AI factions so they are not crippled. **Decide this before Phase 4**, because
"the player is strangled and the AI is not" is worse than not shipping it.

## 6. Risks, honestly

- **AI blindness (Phase 5) is the biggest threat to the feature being fun.**
  Everything else is mechanics; this is whether the game still plays well.
- **Per-turn script cost.** Iterating every faction × region × recipe each turn
  in Lua may be slow. Measure on a full campaign before committing to the
  design; the accumulator hook already shows how many regions are walked.
- **Save compatibility.** Startpos edits are not save-compatible — every batch
  of goods means a new campaign. Batch aggressively.
- **Balance.** Twelve new goods with invented prices and demands will not be
  balanced. Expect a tuning pass driven by real campaign data, not by guesses,
  and keep `rumtoggle.ps1`-style A/B so vanilla remains a reference.
- **Scope.** This is materially bigger than the commodity work. Phases 0–2 are
  well-understood and use proven tooling; Phase 3 onward is new ground.
