# Scaling to 20 commodities

Empire ships 8. We run 9. This is the plan to reach 20 with nothing
commodity-specific left in the toolchain.

## What is already proven, and must not be re-derived

| finding | evidence |
|---|---|
| The commodity containers are **growing vectors, not fixed arrays** | vanilla reads capacity 8 / count 8; with rum it reads capacity **16** / count 9. The engine reallocated by doubling. 17 should take it to 32. |
| The crash on any added commodity is a **vanilla bug**, already patched | `FUN_00972440` always returns 14; four unchecked `+=` stores write one pair past a 14-pair buffer, and on the stack call that pair is the return address. ESE NOPs them. |
| The **DB, startpos and trade-route wiring scale linearly** | 9 works end to end; nothing in them is sized by a constant |
| The **UI price table is hardcoded**, and cloned per config line | `CampaignUI.TradeInfo()` has 8 inline blocks; ESE clones the 181-byte block per entry in `ese_commodities.txt` |
| Type-4 packs override `patch2.pack`, including UI layouts | the rum layout took effect |

## The one hard wall

**The World Market row cannot hold 20 icons.** The pane measures 566px and the
icons are 26px:

| count | pitch available | gap between icons |
|---|---|---|
| 8 (vanilla) | 70 | 44 |
| 9 (now) | 63 | 37 |
| 14 | 41 | 15 |
| **20** | **28** | **2** — icons touching, prices unreadable |

Prices sit *under* each icon and are ~20px wide, so they collide well before the
icons do — realistically the row breaks around **12**. This is the only part of
the job that needs new design rather than more of the same.

---

## Phase 0 — DONE (2026-09-19). There is no engine ceiling.

Ran 21 commodities (8 vanilla + rum + 12 throwaway `res_testNN`), data-only,
with the extras deliberately absent from `ese_commodities.txt` so the UI stayed
at 9 and could not break.

| check | result |
|---|---|
| campaign loads | **yes** |
| DB count | **21** |
| trade manager count | **21** |
| vector capacity | **32** (`+94=32 +98=21`) - doubled 8→16→32 as predicted |
| region arrays | **21** commodities / **33** resources |
| accumulator return address | intact, no fault |
| Trade tab | opens cleanly |

**So 14 and 16 were not boundaries after all.** The dead `"UnUsEd"` table and
the 14-pair accumulator buffers are genuinely independent of commodity count -
previously reasoned, now measured. The containers are growing vectors and the
engine reallocates them correctly. Nothing in Phases 1-4 needs to work around
an engine limit.

**One real trap found**, and it cost only a 3KB pack rebuild rather than a
10-minute startpos cycle precisely because DB and ESF were kept separable:
a commodity's resource row **must** carry a `unit`, or the Trade tab null-derefs
at `0x00A54682`. See ADDING_A_COMMODITY.md.

Two tool bugs were also caught by the tools' own count checks rather than in
game: a UTF-8 BOM from PowerShell corrupting the first key, and an
order-dependent double-widening where `international_trade_routes` holds a
commodities array and a resources array under the same tag.

The original Phase 0 plan follows, kept for the method.

---

## Phase 0 (as planned) — find the real engine ceiling, before building any content

The highest-value step, and it is cheap because **the engine question can be
separated from the UI question entirely**: a commodity that is in the DB and
startpos but *not* listed in `ese_commodities.txt` never reaches the panel. The
Trade tab keeps showing 8 and cannot break, while the engine runs 20.

So: generate 12 throwaway commodities (`res_test01`…`res_test12`) with minimal
DB rows and no art, no building chain, no UI. One startpos build. Load a
campaign.

Watch for:

- does the campaign load at all
- trade income still a sane integer (a float bit pattern means an array was
  missed — `0xC19B1F00` is `-19.39f`)
- `THE DB SAYS 20 COMMODITIES` in `ese_log.txt`
- trade manager capacity reads **32**, confirming the doubling continued
- accumulator dump: region arrays read 20, resources 21+
- no `!!! FAULT`, no `VECTOR PUSH SUSPECT`

If it crashes, bisect — 12, then 16, then 18. The suspicious boundary is **16**,
where the vectors must double again, and **14**, where the dead `"UnUsEd"` table
and the 14-pair accumulator buffers live. Those buffers are a fixed 14-category
breakdown indexed only through `FUN_00972440` (which always returns 14, hence
the NOP), so they *should* be independent of commodity count — but that is
reasoning, not measurement, and 20 > 14 is exactly where a second indexing path
would show itself.

**Deliverable:** a known-good ceiling, or a named function to fix.

## Phase 1 — make the data tooling N-at-a-time

Today's tools add *one* commodity per run and the order/manager arrays are hand
edited. Replace with a single manifest:

```yaml
# commodities.yml
- key: res_rum
  ui_name: rum
  price: 10
  elasticity: 1.2
  demand: { mirror: res_sugar, scale: 1.0 }
  drivers: [[ddr_GDP, 0.5], [ddr_TW, 0.5]]
  icon: rum.tga
  tooltip: Rum
```

One tool reads it and does every data step:

1. append all keys to `commodities_order` / `resources_order`
2. widen the trade manager's 5 `u4_ary` + `flt_ary` + resource array, filling
   price/elasticity/demand from the manifest
3. widen every per-record array (`extend_commodity_arrays.rb` already detects
   widths — change it to take a **target** width and add N in one pass)
4. set demand per entry (`set_commodity_demand.rb` already parameterised)
5. emit the DB table files
6. emit `.loc` entries
7. emit `ese_commodities.txt`

`extend_commodity_arrays.rb` and `set_commodity_demand.rb` already detect widths
and resolve indices from `commodities_order`, so they need extending, not
rewriting. The genuinely new piece is **DB row emission**, which today is hand
authored.

**Cost driver to respect:** each `esf2xml` → edit → `xml2esf` cycle is ~10
minutes on the 65MB startpos. The manifest exists so 12 commodities cost *one*
cycle, not twelve.

## Phase 2 — redesign the World Market panel

The row must become a grid. Options, in order of preference:

**A. Multi-row grid (recommended).** Keep the existing per-commodity component
wholesale and lay them out in rows of 8 within the pane, growing the pane's
height instead of squeezing its width. 20 commodities = 3 rows. The pane is 94px
tall inside a much taller parent, so there is room, and `add_market_slot.rb`
already computes positions — it changes from `x = start + i*pitch` to
`x = start + (i%cols)*pitch, y = top + (i/cols)*rowheight`. Smallest change,
nothing new to learn, no scroll state to manage.

**B. Scrollable row.** The panel already has sliders for Imports/Exports
(`exports_slider`, `UpdateExportsSlider`) that could be copied. But a scrollbar
on a handful of icons is poor UX, and it adds state the Lua must track.

**C. Two fixed rows of 10.** Simplest of all, but wastes space at low counts and
breaks again at 21.

Go with **A**, parameterised by `cols`, defaulting to 8 so the vanilla look is
preserved at low counts.

Note the Supply and Exports sections already scale on their own — they build
pips dynamically via `CreateComponentFromTemplate` and have overlap handling
(`available_space`, `amount_over`, `overlap`). No work needed there.

## Phase 3 — content

Only now author the real commodities: DB rows, building chains, art, tooltips.
This is deliberately last because it is the only irreversible effort — Phases
0–2 de-risk it, and a ceiling discovered in Phase 0 would change what gets
authored.

Per commodity: a `commodities` row, a `resources` row, 2 demand-junction rows, a
building chain (chain / levels / culture variants / effects / junctions /
chain_to_slots), `.loc` strings, and a 26px icon. Reusing existing art is fine
and already proven.

## Phase 4 — raise the DLL cap

`TI_MAX_EXTRA` is currently **16**. For 20 total that is 12 extras and fits, but
raise it to 32 with the cave sized from the count (it already is) so the config
is the only limit.

---

## Validation at each step

Run after every batch, not just at the end:

```
.\game.ps1 -Action restart -Deploy -RotateLog -Tag N<count>
```

| check | where |
|---|---|
| DB count | `ese_log.txt` → `THE DB SAYS N COMMODITIES` |
| vector growth | accumulator dump → capacity doubling as expected |
| arrays widened | region counts == commodity count |
| return address intact | `param_2[28]` holds a code address |
| UI count | `.\ese.ps1 -UI "…TradeInfo()…"` → N prices |
| no regression | `.\rumtoggle.ps1 -State vanilla` |

Add in **batches with a test between** — 9 → 12 → 16 → 20. The risk is
non-linear: 14 and 16 are the interesting boundaries, and finding a wall at 16
after authoring 12 commodities' worth of art and building chains would be an
expensive way to learn it.

## Honest unknowns

- Whether anything besides `FUN_00972440` indexes the 14-pair buffers by
  commodity index. Reasoning says no; Phase 0 at 20 is the measurement.
- Whether the AI's trade evaluation has its own per-commodity limit. Nothing
  found, but `cai_*` startpos records were never examined for commodity arrays
  — the survey only matched 8- and 20-element ones, which at 20 commodities
  would alias with genuinely unrelated data.
- Whether 20 commodities is *good play*. Rum already ties for top demand
  because it mirrors sugar; 20 goods on one map may dilute trade to noise. Worth
  a balance pass once it runs.
