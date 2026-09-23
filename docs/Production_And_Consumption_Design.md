# Chain balance: production sized against what units actually cost

# Researching, not built yet

## The requirement that drives everything

- a firearm unit costs **one musket per man**
- every unit above militia costs **one uniform per man**
- artillery costs **one cannon per gun**
- firearm units cost **ammunition per man**

Taken from real data, not class names: `unit_stats_land.primary_missile_weapon`
decides "firearm" (musket 143, carbine 28, rifle 8, plus musket_double,
rifle_screw_breech, rifle_air — against bow 23, tomahawk 16, chakkar 1), and
`unit_stats_land.men` / `.guns` give the counts. 336 of 518 units carry a cost.

A **Line Infantry regiment of 200 men therefore costs 200 muskets, 200
ammunition and 200 uniforms.** That single number is what forced everything
below: the chain originally produced 8–15 of a good per turn, so one regiment
was nine turns of a grand musket manufactory.

## Design target

> A developed major power — roughly 3 musket manufactories, 3 foundries,
> 3 ordnance sites, 3 textile towns, all at grand level — should be able to
> raise about **two line regiments per turn**, i.e. ~400 muskets, 400 uniforms
> and 400 ammunition per turn.

## Output per building (base → small / large / grand)

Levels scale ×1 / ×1.7 / ×2.7.

| building | base | small | large | grand | ×3 grand |
|---|---|---|---|---|---|
| Musket Manufactory | 50 | 50 | 85 | 135 | **405 muskets** |
| Uniform Works | 50 | 50 | 85 | 135 | **405 uniforms** |
| Cartridge Works | 50 | 50 | 85 | 135 | **405 ammunition** |
| Foundry | 50 | 50 | 85 | 135 | 405 steel |
| Powder Mill | 50 | 50 | 85 | 135 | 405 gunpowder |
| Weavers Mill | 50 | 50 | 85 | 135 | 405 textiles |
| Coal Mine | 50 | 50 | 85 | 135 | 405 coal |
| Saltpetre Works | 40 | 40 | 68 | 108 | 324 saltpetre |
| Lead Mine | 40 | 40 | 68 | 108 | 324 lead |
| Cannon Works | 4 | 4 | 7 | 11 | 33 cannon (~5 batteries) |
| Naval Supply Yard | 25 | 25 | 43 | 68 | 204 naval supplies |
| Rum Distillery | 15 | 15 | 26 | 40 | (trade good, not military) |

## Why the recipes are batched

A recipe's second field is **how many are produced** from the inputs that
follow. At 1 musket per 1 timber, a single 200-man regiment would eat 200
timber — more than the entire map produces. Batching keeps the raw tier on a
scale the map can actually supply:

```
4 steel          <- 2 iron      + 3 coal
4 gunpowder      <- 3 saltpetre + 1 coal
4 ammunition     <- 2 gunpowder + 1 lead
4 muskets        <- 4 steel     + 1 timber
1 cannon         <- 6 steel     + 2 coal
4 textiles       <- 2 cotton    + 1 coal
4 uniforms       <- 4 textiles
4 naval supplies <- 3 timber    + 1 iron
```

Checking the target through the chain, for 405 muskets + 405 uniforms a turn:

| need | derived from | per turn | supplied by |
|---|---|---|---|
| 405 steel | 405 muskets × 4/4 | 405 | 3 grand foundries = 405 |
| 405 textiles | 405 uniforms × 4/4 | 405 | 3 grand weavers = 405 |
| ~101 timber | 405 muskets × 1/4 | 101 | 2 lumber mills = 110 |
| ~203 iron | 405 steel × 2/4 | 203 | 3 industrial iron complexes = 270 |
| ~304 coal | 405 steel × 3/4 | 304 | 3 grand coal mines = 405 |
| ~203 cotton | 405 textiles × 2/4 | 203 | vanilla cotton plantations |
| ~304 saltpetre | 405 gunpowder × 3/4 | 304 | 3 grand saltpetre works = 324 |
| ~101 lead | 405 ammunition × 1/4 | 101 | 1 grand lead mine = 108 |

Every tier has a small margin over the tier above it, which is deliberate:
losses, trade and partial development should bite before the chain deadlocks.

## The raw tier had no producer at all

`res_iron`, `res_timber` and `res_corn` were promoted from plain resources to
tradeable commodities, but vanilla ships `commodity_prod_` effects for only
seven goods (coffee, cotton, furs, spices, sugar, tea, tobacco) and **none for
iron, timber or corn**. Steel's input therefore did not exist and the chain
could never have run. `PROD` lines now attach a `commodity_prod_` effect to the
vanilla buildings already standing on those slots:

```
iron_mine 30   steam-pumped_iron_mine 55   industrial_iron_mining_complex 90
timber_logging_camp 30                      timber_lumber_mill 55
corn_peasant_farms 20 … corn_great_royal_palace 110
```

All additive: a junction row against an existing building level, never a
modified vanilla row.

## Scarcity is geographic, and deliberate

The three extractive buildings sit on slots that already exist on the map, so
they are buildable without editing the startpos:

| building | slot | map-wide slots | why |
|---|---|---|---|
| Coal Mine | `iron` | 38 | coal and iron fields coincide — Birmingham, Rhineland, Pennsylvania, Ostrau, Saxony |
| Saltpetre Works | `india_highlands` | 13 | India was the world's saltpetre source — Bengal, Carnatica, Hyderabad |
| Lead Mine | `silver` | 9 | galena *is* the silver ore — Sweden, Sardinia, New Spain |

Each competes with the vanilla building on the same slot (a region mines iron
**or** coal), and the manufacturing tiers compete with each other: foundry vs
musket manufactory on `town-metal` (286 town slots map-wide), powder mill vs
cartridge works vs cannon works on `settlement_ordnance` (**only 44 on the
whole map**), weavers vs uniform works on `town-textile`.

Saltpetre is the sharpest constraint — 13 sites, almost all in India — which is
historically right and makes gunpowder a reason to trade or to take Bengal.

## Enforcement: the intended lever does not exist

Tested live in a loaded campaign on 2026-09-20:
**`add_restricted_unit_record` is nil**, as are `remove_restricted_unit_record`,
`add_restricted_building_level_record`, `restrict_unit`, `lock_unit`,
`disable_unit` and `add_unit_restriction` — probed via
`loadstring("return "..name)` with `events` and `effect` as controls, both of
which correctly resolve as tables. `effect` has twelve members and none of them
touch units.

So the mechanism this project assumed for "you need muskets in stock to
recruit" was never going to work. `building_units_allowed.conditions` is dead
too (all 3,260 vanilla rows read `(none)`). Right now **buildings gate
recruitment and stock does not**, and the costs above are bookkeeping.

Three ways forward:

1. **Native hook via ESE** — intercept the recruitment path in `Empire.exe` and
   refuse when stock is short. The proper answer; the project already has
   working x86 detours. Most work.
2. **Treasury penalty** — `effect.adjust_treasury` is real. Charge a premium per
   missing musket or uniform at recruitment: you *can* raise the regiment, you
   just pay through the nose to buy its kit abroad. Implementable today with
   what exists, and it makes scarcity bite without blocking the player.
3. **Accept building-only gating** — a Musket Manufactory is required to raise
   line infantry, but quantity is unlimited.

Note `building_levels.condition` IS live (51 vanilla rows use it, e.g.
`hasRegionResource(res_iron) OR hasRegionResource(res_coal)`), but it gates
buildings, not units, and has no stock predicate.
