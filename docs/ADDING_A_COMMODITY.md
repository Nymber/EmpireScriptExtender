# Adding a trade commodity to Empire: Total War

Empire ships with 8 commodities. Adding a 9th touches five separate places, and
missing any one of them fails in a way that looks unrelated to what you changed.
This is the whole recipe, in the order it must be done.

It also documents a genuine **engine bug** that makes any added commodity crash
the campaign, which ESE patches at runtime. Without that patch none of the rest
matters.

---

## 0. The engine bug you must know about

`FUN_00972440` classifies a commodity by scanning a 14-entry table at
`0x01448254` and returning the matching slot, or **14** on a miss. That table is
dead content: all 14 slots are built at `0x00422DE0` from the same literal
`"UnUsEd"`, and a Ghidra xref sweep of every slot address shows exactly one
reference each - that constructor. So the scan never matches and it returns 14
every time, in vanilla too.

Its caller accumulates through that index into 14-pair buffers with no bounds
check, writing one pair PAST the end:

| address | instruction | writes |
|---|---|---|
| `009158bc` | `ADD [EDI+EAX*8],ESI` | `param_2[28]` |
| `009158ea` | `ADD [EDI+EAX*8+4],ECX` | `param_2[29]` |
| `00915920` | `ADD [EAX],ECX` | `param_3[28]` |
| `00915952` | `ADD [EAX+4],ECX` | `param_3[29]` |

`FUN_0098A040` calls it twice. The first call passes object members, where the
overflow lands in padding - which is why vanilla survives. The second passes
**stack** buffers, and there `param_2[28]` is the caller's **return address**.
Live proof: it held `0x00951A65`, and the engine added 12 to it, returning into
the middle of the instruction at `0x00951A71` - exactly the observed crash.

**ESE NOPs all four stores.** They never write a real accumulator slot (the
index is always 14), and the genuine totals come from `00915963` / `00915969`
which are untouched. Verified: vanilla runs clean with the patch applied.

---

## 1. Database rows

Pack files inside a `db\<table>_tables\` folder are **additive** - Empire merges
every file in the folder, so ship only your new rows and never restate base ones.
Prefix filenames `zzz_` so they sort last and win collisions.

| table | what to add |
|---|---|
| `commodities_tables` | the commodity: key, base price, elasticity |
| `resources_tables` | the matching resource - **with a `unit`, see below** |
| `commodities_demand_junction_tables` | 2 rows linking it to demand drivers, weights summing to 1.0 |
| `building_chains` / `building_levels` / `building_culture_variants` / `building_effects_junction` / `effects` / `effect_bonus_value_commodity_junction` / `building_chain_to_slots` / `building_upgrades_junction` / `building_description_texts` | the building chain that produces it |

You do **not** need rows in `trade_theatre_commodities` (that is for goods
gathered at overseas trade nodes, not produced in regions) or in
`commodities_demand_drivers` (that is the list of drivers, not per-commodity).

### A commodity's resource MUST have a `unit`

`resources_tables.unit` is an **optstring**, so the schema happily accepts an
absent value - but the trade UI dereferences that pointer unconditionally.
Leave it empty on something that is also a commodity and the Trade tab dies
with a null read:

```
FAULT C0000005 at static 0x00A54682   READ from 00000004
bytes: 8B 41 04   = MOV EAX,[ECX+4]   with ECX = 0
```

The vanilla data states the rule without documenting it - every commodity has
one, and only non-commodity resources are null:

| | `unit` |
|---|---|
| all 8 commodities | `sacks` `bales` `pelts` `tusks` `pounds` `loaves` `chests` `barrels` |
| all 12 non-commodity resources (cattle, corn, fish, gems, gold, iron, rice, sheep, silver, timber, wheat, wine) | `(none)` |

`unit` is an FK into `commodity_unit_names_tables`, so reuse an existing value.

### Generating the table files

Hand-encoding a table is how a field ends up the wrong type - note that
`baseline_price_per_unit` is a **float** despite printing as a whole number.

```
.\dbgen.ps1 -Table commodities_tables -In rows.txt -Out zzz_x_commodities
.\dbgen.ps1 -Table resources_tables   -In rows.txt -Verify <existing file>
```

Rows are pipe-separated; an empty field or `(none)` means an absent optstring.
`-Verify` regenerates an existing file and compares byte for byte - use it
whenever you touch a table you have not written before, since round-tripping a
known-good file is the only real proof the encoder matches the engine.

Validate before launching - a dangling foreign key makes the game **exit
cleanly before the main menu**, with no crash record at all:

```
.\dbcheck.ps1 -Path <staged\db>      # does every table parse exactly?
.\dbfk.ps1    -Path <staged\db>      # does every foreign key resolve?
```

**Internal pack paths must be lowercase.** Every vanilla entry is
(`ui\campaign ui\skins\tobacco.tga`), and a file only overrides a base-game one
when the path matches. `build_pack.ps1` lowercases them for you.

---

## 2. The startpos

`startpos.esf` carries the runtime commodity order and a per-record array for
every commodity. Convert it, edit, convert back:

```
cd <tools>\etwng\esfxml
ruby esf2xml --verbose "<game>\data\campaigns\main\startpos.esf" %TEMP%\etw_xml\work
```

### 2a. Append to the order

In `campaign_env/trade_manager.xml`, add your key to the **end** of
`<commodities_order>` and `<resources_order>`, and extend the manager's own
arrays (5 `u4_ary`, 1 `flt_ary` for Demand, 1 `u4_ary` of 21 for Resources Trade
Value) by one entry each.

Appending matters: position **is** the index, so a new entry on the end shifts
nothing. Check it by reading the manager's price array against the order -
`16 11 12 24 11 12 8 9 10` maps entry-for-entry onto
`spices tobacco sugar ivory tea cotton coffee furs rum`.

### 2b. Widen every other per-commodity array

```
ruby extend_commodity_arrays.rb %TEMP%\etw_xml\work            # dry run
ruby extend_commodity_arrays.rb %TEMP%\etw_xml\work --apply
```

This widens regions, factions and both trade-route types. It detects the
current widths from `commodities_order`, so it keeps working at 9→10 and
beyond, and it checks its tally against a survey rather than trusting itself.

**Do not skip this.** The manager at 9 with these at 8 means anything iterating
by the manager's count reads one past the end - which shows up as a float bit
pattern in an integer total (`-1046798592` is `-19.39f`) and later as a UI crash
when a panel sizes a buffer from the garbage.

### 2c. Give it demand

```
ruby set_commodity_demand.rb %TEMP%\etw_xml\work --commodity res_rum --mirror res_sugar --apply
```

Mirrors an existing commodity's per-region demand, which inherits a believable
spread. It auto-detects the demand slot (populated in ~124/137 regions) versus
the production slot (~44/137) and never touches production - mirroring into
that would make every source-commodity region produce yours for free.

### 2d. Rebuild

```
ruby xml2esf %TEMP%\etw_xml\work %TEMP%\etw_xml\startpos_new.esf
```

Sanity-check the size delta. Widening arrays for one commodity should add
exactly `548*4 + 137 + 56 + 72*4 + 72*4 + 3*4 = 2973` bytes on the Grand
Campaign - if the number is not what the element count predicts, something else
changed too.

**Startpos edits are not save-compatible. Start a new campaign.**

---

## 3. The World Market slot

`CampaignUI.TradeInfo()` hands the panel a table of prices, and
`government_screens.lua` does:

```lua
for k, v in pairs(trade_info.prices) do
  UIComponent(UIComponent(window:Find(k)):Find("dy_value")):SetStateText(v)
end
```

`k` is the **short** key (`rum`, not `res_rum`), so the layout needs a child of
exactly that name under `world market`.

```
cd <tools>\etwng\ui
ruby bin\ui2xml "<extracted>\government_screens" gs.xml
ruby add_market_slot.rb gs.xml --name rum --tooltip Rum --apply
ruby bin\xml2ui gs.xml government_screens
```

`add_market_slot.rb` discovers the existing slots (a direct child of
`world market` whose subtree contains a `dy_value`), clones the right-most one,
shifts every ID by a constant so internal image↔image_use links stay intact, and
re-spaces the whole row to fit the pane. Re-running only re-spaces.

Verify the converter round-trips byte-identically on the unmodified file before
trusting any edit.

---

## 4. The tooltip

The node carries both an inline tooltip string and a tooltip **id**, and the
game resolves the id through `.loc`, ignoring the inline text. Vanilla has
`tobacco_NewState_Tooltip_6d003a = "Tobacco"`, so a clone needs the matching
key or the tooltip is simply blank.

```
ruby loctool.rb add <staged>\text\your.loc rum_NewState_Tooltip_6d003a Rum --apply
```

`loctool.rb` verifies by consuming the file exactly. Note real entries use
**flag 1**.

Also ship `ui\campaign ui\skins\<name>.tga` - the layout references it.

---

## 5. Tell ESE

`CampaignUI.TradeInfo()` is hardcoded: eight inline blocks, each looking up a
literal `res_<key>` and storing under a short `<name>`. It does **not** iterate
the commodity table, so nothing above makes a 9th price reach the UI. ESE clones
that 181-byte block once per line in `ese_commodities.txt`:

```
res_rum   rum
```

The maintained source is `config/ese_commodities.txt` in the ESE development
tree. Run `empire.ps1 sync` (or install ESE) to copy it beside `Empire.exe`.
Do not maintain the game-root copy by hand; the doctor compares the two files
and verifies that their keys match the production-chain manifest.

Restart the game; no DLL rebuild is needed. Confirm in `ese_log.txt`:

```
[ti] ese_commodities.txt: 1 extra commodity
[ti]   block 0: res_rum -> UI key 'rum'
```

> **The config line and the layout slot must ship together.** A price whose
> name has no component makes `Find` return nil, and `UIComponent(nil)` raises
> inside a loop that runs *before* the Supply and Exports sections - so a typo
> does not hide one commodity, it breaks the entire Trade tab. To disable one,
> comment out its line and restart.

> **The game-root file is required runtime data when an extended commodity
> pack is active.** If it is missing, ESE cannot clone the additional
> `TradeInfo` blocks or apply the matching raw-resource count. A log captured
> without the file contains a null `TRADE_DETAIL_RECORD` dereference at static
> `0x00A04B96`; a later startup confirms the config loaded, but still needs an
> in game Trade-tab round trip to verify the fix.

Done in memory rather than as an on-disk exe patch because the cloned block
contains three absolute addresses that the loader rebases through the relocation
table. A copy written into a file cave would have no `.reloc` entries and would
point at the wrong addresses under ASLR. At runtime the delta is known and every
address can just be written correctly.

---

## Verifying

| check | how |
|---|---|
| DB sees it | `ese_log.txt` → `THE DB SAYS N COMMODITIES` |
| arrays widened | accumulator dump → region counts match the new width |
| return address intact | `param_2[28]` holds a code address, not garbage |
| UI receives it | `.\ese.ps1 -UI "…CampaignUI.TradeInfo()…"` → N prices |
| runtime contract | `.\empire.ps1 doctor` → `Trade UI config` and `Trade config data` pass |
| no regression | `.\rumtoggle.ps1 -State vanilla` and compare |

## Tools

| tool | does |
|---|---|
| `game.ps1` | stop/start/restart, deploy the DLL, rotate the log |
| `rumtoggle.ps1` | swap vanilla ↔ modded startpos, hash-verified |
| `packtool.ps1` | find/extract from `.pack` (handles the dependency block) |
| `dbcheck.ps1` / `dbdump.ps1` / `dbfk.ps1` | parse, print, FK-validate tables |
| `loctool.rb` | read/add/verify `.loc` entries |
| `extend_commodity_arrays.rb` | widen every per-commodity startpos array |
| `set_commodity_demand.rb` | mirror one commodity's regional demand onto another |
| `add_market_slot.rb` | add + re-space a World Market slot |
