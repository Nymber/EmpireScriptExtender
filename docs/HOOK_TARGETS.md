# Hookable function catalogue (2026-09-18)

Companion to `FINDINGS.md`. Produced by exploiting the fact that **every
`UTILITYLIB::DATABASE_TABLE` accessor in this engine embeds its own
self-identifying error string**:

```
"In table %S: '%S' is not a valid key for this table
 (UTILITYLIB::DATABASE_TABLE<struct EMPIREUTILITY::<TYPE>_RECORD,...>::record_index"
```

That makes the whole data layer enumerable without guesswork.

## Scale of the surface

- **451** `DATABASE_TABLE` template strings in `Empire.exe`
- **~450** distinct record types (the engine's full table schema, self-documented)
- **151** types have a `record_index` accessor -> 151 individually hookable
  table lookup functions

## How to resolve any of them (repeatable)

1. Scan `Empire.exe` for `In table %S...::record_index` and capture the record
   type inside each match (`scratchpad\find_table_strings.ps1`).
2. Convert the match's file offset to a static address via the PE section table
   (`SizeOfOptionalHeader` at `peOff+20`, section table at `peOff+24+optSize`;
   static = `0x00400000 + VAddr + (fileOff - RawPtr)`).
3. Feed those addresses to `GhidraToolkit.java` in **`callers`** mode to get the
   referencing functions.

Note: `GhidraToolkit`'s `xrefs` mode does **not** work for these - it matches
defined strings by *exact full equality*, and these error strings are hundreds
of characters long and mostly undefined bytes in `.rdata`. Use the address
route above instead.

## Resolved accessor strings (static addresses)

| record type | error-string address |
|---|---|
| COMMODITY_RECORD | `0x012604D8` |
| COMMODITIES_DEMAND_DRIVER_RECORD | `0x012C2398` |
| TRADE_DETAIL_RECORD | `0x012610A0` |
| TRADE_THEATRE_COMMODITY_RECORD | `0x01261200` |
| RESOURCE_RECORD | `0x01248A40` |
| REGION_RECORD | `0x01249E00` |
| REGION_UNIT_RESOURCE_RECORD | `0x012589A8` |
| REGION_WEALTH_FACTOR_RECORD | `0x01258CD0` |
| FACTION_RECORD | `0x0120C150` |
| SLOT_RECORD | `0x01257FB0` |
| CAMPAIGN_MAP_SLOT_RECORD | `0x01258FD0` |
| BUILDING_CHAIN_RECORD | `0x01258550` |
| BUILDING_LEVEL_RECORD | `0x01249110` |
| DIPLOMACY_ATTITUDE_RECORD | `0x012607A0` |
| GOVERNORSHIP_RECORD | `0x012BB468` |
| PUBLIC_ORDER_FACTOR_RECORD | `0x01249F50` |
| TAXES_LEVEL_RECORD | `0x0124A220` |

## Ranked hook targets

### Tier 1 - trade/economy core (most valuable to this mod)

| function | touches | why it matters |
|---|---|---|
| `FUN_00ec7680` | COMMODITIES_DEMAND_DRIVER + COMMODITY | the demand-model resolver - the live counterpart to the `ddr_GDP`/`ddr_TW` weights decoded from the DB |
| `FUN_00ec7750` | COMMODITY + SLOT | commodity<->slot junction; governs **where a commodity may be produced**, directly relevant to the rum-distillery slot question |
| `FUN_00a043d0` | TRADE_DETAIL + RESOURCE (4 refs) | trade detail//resource builder, likely what feeds the trade UI |
| `FUN_009b0860` | TRADE_THEATRE_COMMODITY (sole ref) | trade theatres; clean single owner, easy to interpret |
| `FUN_009f4300` | COMMODITY | `record_index` itself - **already hooked successfully**, see `ce_commodity_hook.lua` |

There is a whole `FUN_00ec7xxx` cluster (`7680`, `7750`, `7bb0`, `7c30`, `7ec0`,
`8170`) referencing commodity/resource/slot/building-chain/region strings. That
cluster appears to be the economy data layer and is worth mapping as a unit.

### Tier 2 - region/faction (the long-standing gap)

| function | touches | why it matters |
|---|---|---|
| `FUN_008e8f60` | **FACTION + REGION + REGION_UNIT_RESOURCE** | the only function seen touching all three. Prime candidate for the faction<->region<->resource mapping that [[global world pointer]] work could not resolve, and for answering which regions carry which resource without parsing `startpos.esf` |
| `FUN_00e69a60`, `FUN_00e29ee0` | REGION_UNIT_RESOURCE | per-region resource assignment |
| `FUN_008ed7c0` | SLOT + CAMPAIGN_MAP_SLOT | the slot system core - which slots a region actually has |

### Tier 3 - cross-validation (already known)

`FUN_00a2cdf0` owns **all 29** references to DIPLOMACY_ATTITUDE_RECORD, and
`FINDINGS.md` §5 had already identified it independently as a config
deserializer (string-compare chain writing into fixed struct offsets). The two
methods agreeing on the same function is a good check that this catalogue is
sound.

## Still the single highest-value target overall

`FUN_00a65a70` - the per-turn trade/price engine (`FINDINGS.md` §3/§7). Hooking
its **exit** dumps real per-turn prices, global supply and global demand into
the mod. Unlike the table accessors above, it yields live simulation output
rather than static lookups.
