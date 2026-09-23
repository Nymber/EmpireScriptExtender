# High-poly units for Empire: Total War — plan

Goal: replace unit geometry with higher-density meshes, so units can be
"fantastically modelled" rather than 2009-budget.

---

## STATE AS OF 2026-09-21 — SHIPPED AND CONFIRMED IN GAME

**Everything below this section is the historical phase log. Where it
disagrees with this section, this section is right.** In particular the log
repeatedly says "nothing has been rendered in game yet" and "textures >1024
UNVERIFIED"; both are now false.

### Update, same day, later: warships and buildings — SOLVED and DEPLOYED, unconfirmed in game

`.rigid_naval_model` (the format the `empire-unit-meshes` skill previously
called "STILL BLOCKED, one layer deeper") is now fully solved: the blocker
was two literal fixed-size fields (`pre2`: 8 bytes, `gap`: 16 bytes) around
the vertex array, not a stride puzzle. `rigid_model.rb`'s `:naval` variant
handles it, and the SAME variant-agnostic `subdiv_rigid.rb` Phong pass used
for buildings ran over every named ship (all deck classes, `victory`,
`razee44`, `steam_frigate`, galleons, sloops, etc.) plus buildings, trees,
flags and naval cannons. `victory/britain_ship.rigid_naval_model` grew from
6,503,350 (vanilla) to 16,339,990 bytes (~2.5x).

**Deployed in `data/zz_rigid.pack`** (2.0 GB), verified by SHA1 hash against
the staged copy, not by timestamp. **This is geometry correctness only** —
no naval battle has been observed since it shipped, so treat it the way the
project treats any unconfirmed change: real until looked at, not yet proven
in motion. Watch for cracked hull/deck seams and torn sailcloth, the same
failure class the infantry work had at part joints.

### What is deployed

| pack | contents |
|---|---|
| `data/zz_hipoly.pack` | **196 units + 72 mounts + `euro_equipment`** — 465 files, 700 MB, type 4 |
| `data/zz_chain.pack` | the trade mod only; all `unitmodels\` removed from it |

**Coverage: 464 of 586 battle-unit lod1/lod2 paths = 79.2%**, verified by
indexing every pack and asking which one wins each path. lod3/lod4 stay vanilla
by design (only drawn past 400 units). Every file was byte-verified against its
staged source after deployment.

Confirmed in game: infantry, cavalry at a gallop (which exercises the skinning,
not just the bind pose), weapons, and worn kit. No tearing, no cracked seams,
no ballooned barrels.

### The 122 paths not upgraded

- **112 are ENCRYPTED DLC** — 56 units x 2 LODs in patch/patch2/patch3/patch4.
  Unreadable by any tool. Mostly elite and guard troops; note that
  `austrian_hungarian_grenadiers` is among them.
- **10 are refusals**: `euro_pirate`, `euro_pirate_officer`, `euro_able_seamen`,
  `euro_african_infantry` (bones the family pose does not cover) and
  `euro_king_and_courtiers` (the campaign-map second container).
  `subdiv_local.rb` post-dates those refusals and does not need a full pose, so
  the first four may now work. **Untried.**

### Three things solved today that the log below does not mention

1. **`tools/mesh/subdiv_local.rb`** — subdivides in shared BONE frames with no global
   pose, which is the only reason the 72 mounts exist. `subdiv_vwm.rb` refused
   all of them over 0.3% of their geometry.
2. **`tools/mesh/equip_vwm.rb`** — the weapon container. `euro_equipment` is not an
   empty file, it holds **all 134 weapons and worn kit**; the old reader was
   dumping 1,610,160 of its 1,610,592 bytes into an uninterpreted `trailer`.
3. **The 41-bone ceiling is DATA** — `fx\fxconfig.h`
   (`#define FX_MAX_ANIMATION_NODES 41`) inside a pack, and Empire compiles its
   shaders at runtime via `d3dx9_40.dll`. A 1.5 KB type-4 pack raises it; 45
   renders correctly.

### Phase 7 — textures: RESOLVED, 2048 works

There is no size ceiling on unit diffuse textures. A 2048 DDS loads and **its
top mip is genuinely sampled** on close geometry. Proven with a per-resolution
colour ladder (`tools/texture/gen_test_dds.rb`) and measured off the screenshot rather
than eyeballed: the nearest geometry rendered a green+red blend at RGB
(123,205,41), and green exists only in the 2048 mip.

**And it is worth doing, but ONLY with a negative mip bias.** Unbiased, the
2048 level reaches just 3.39% of the frame; adding `MIPMAPLODBIAS = -1.0f` to
the unit diffuse sampler in `weighted.fx` takes that to **42.95% at 160 fps**.
That one line is the difference between a 2048 texture being inert and being
the thing you actually see. Superseded note follows: The same ladder data shows the 2048 level
reached exactly ONE surface - the nearest geometry in frame - while soldiers
filling much of the screen stayed on 1024/512. A Lanczos 2048 shipped on line
infantry produced no visible difference. `tools/texture/dds_resample.rb` now provides
the DXT1 encoder (48.8 dB) should anyone revisit, but the better target would
be the NORMAL maps, which are DXT5 and need the encoder extending first.

### The traps that cost the most, all now in the skill

- **`gfx_unit_quality` was 2** for an entire day of playtesting, so the engine
  started at lod2 and **never loaded lod1**. Every visual verdict before
  ~15:00 describes lod2. Check this file before judging any art work.
- **`fx_cache`** silently reuses compiled shaders; evict `weighted.fxc` or a
  shader test proves nothing.
- **A byte-identical round-trip through an uninterpreted field is free** — it
  is what hid the entire weapon container.
- **Never probe textures by swapping one faction's for another's.** The coat
  colour comes from the faction, not the texture.
- **Re-run the same build before bisecting.** A spurious failure nearly sent us
  hunting a bone ceiling that does not exist.

### Open, in rough value order

1. **Real texture detail** — genuine upscaling of ~26 texture sets. Textures,
   not geometry, are now the limiting factor.
2. **Authoring new geometry.** `vwm_json.rb` refuses a changed vertex count,
   because new vertices need UVs, weights and influences invented. Until that
   is lifted, the pipeline can smooth what CA made but cannot add a button.
3. **The 4 refused units**, via `subdiv_local.rb`.
4. **A frame-rate number** on the current build: lod1, 196 units, 72 mounts.
   The 150 fps on record predates mounts, predates the 141-unit batch, and was
   measured at lod2.
5. **Extra bones.** Proven possible and poor value: 3,208 animation files to
   rewrite, and the renderer blends only 2 bones per vertex, so it buys
   attachment points rather than better deformation.

---

"fantastically modelled" rather than 2009-budget.

## The situation, stated honestly

**The engine is not the obstacle.** Investigated in Ghidra 2026-09-20:

- The only geometry-limit diagnostics in `Empire.exe` are SpeedTree's
  (`frond vertices exceed %d`, `too many leaf lod levels`) and
  `collision object index (%d) exceeds maximum index (%d)`. There is **no**
  "too many vertices/triangles" string for unit meshes.
- The mesh container stores **indices as `u4` (32-bit)**, proven by exact
  arithmetic, so the 65,535-vertex ceiling of 16-bit index buffers is absent.
- `LARGE_ADDRESS_AWARE` is **set**, so ~4 GB of address space, not 2 GB.

Absence of a limit string is not proof of no limit, but nothing found caps
polygon count.

**That obstacle is GONE as of 2026-09-20/21.** `.variant_weighted_mesh` is
solved: `tools/mesh/vwm.rb` reads and repacks **1026/1026 meshes byte-identically**,
the 41-bone skeleton is recovered, a modified mesh has been **confirmed
rendering in game** (Phase 5), and `tools/mesh/vwm_json.rb` + `vwm_blender.py` carry
it in and out of Blender without losing a byte.

The pose is recovered too (Phase 4b, 2026-09-21) — **from the shipped meshes
rather than the `.anim`** — so a vertex moved in Blender is written back into
every bone's frame. The reverse engineering is finished.

Adding geometry works too (Phase 6, 2026-09-21): `tools/mesh/subdiv_vwm.rb` Loop-
subdivides a unit to **4x triangles** with valid influences, watertight joints
and intact UV seams.

What remains is not reverse engineering:

- **performance**, which is the real ceiling — and is now bounded, because LOD
  is distance-driven off an editable 185-byte table (lod1 covers 0–200);
- **an in-game look** at the 4x unit — nothing has been rendered yet;  **(SUPERSEDED - done and confirmed in game; see the top section)**
- **art**, if the goal is beyond what subdivision alone gives: subdivision
  smooths a silhouette, it does not add new detail such as buttons or folds;
- **adding geometry in BLENDER**, which still needs UVs, weights and influences
  invented for new vertices. The exporter refuses a changed vertex count rather
  than guess; `subdiv_vwm.rb` sidesteps this by deriving all of it itself.

(Existing community tooling still does not cover this format: `variant_part_mesh`
is decode-only and is the NAPOLEON format; `unit_variant` is Napoleon/Shogun 2.)

## What is already proven

From `tools/mesh/decode_vwm.rb` against `african_slaver_musketeers_lod1`:

```
magic 78 56 34 12                        same container as rigid_model
u4 = 1
13 x (name, f4)                          scalar shader params
2  x (name, f4 x 4)                      vec4 params
9  x (name, u4 vcount, u4 icount)        PART TABLE
geometry, parts back to back:
   [u4 vcount][vertices, VARIABLE][u4 icount][indices u4]
```

- **Indices are 32-bit**: `26846 + 4 + 1452*4 = 32658`, exactly where part 1
  begins.
- **The part chain is right**: all nine parts consume 586,538 of 586,542 bytes.
- **A single-influence vertex is 84 bytes / 21 slots**, influence count at
  `[8]`, bone index at `[9]`, weight at `[16]`.

> Two claims that were once written here turned out to be WRONG, and both are
> corrected below: the vertex head's first floats are **atlas UVs, not
> position**, and the multi-influence size rule is `52 + 32 * influences`, not
> `84 + (count-1)*8`. Read Phase 1 and the skill's FORMAT section, not this
> summary.

## Ground truth that shapes the plan

| fact | consequence |
|---|---|
| **1,269** `variant_weighted_mesh` entries | a decoder must be validated at corpus scale, not on one file |
| LODs are **lod1..lod4** (334/329/299/298) | a high-poly unit must ship **four** LODs, not one |
| LOD choice is a **graphics setting** (`FUN_010307f0`) | you cannot force lod1; the player's detail setting picks it |
| skeletons are `.anim`, and `etwng/anim` has **`anim2json_etw` + `json2anim_etw` with tests** | bone names/hierarchy are recoverable, so weighting against the real skeleton is feasible |
| bone indices reference that fixed skeleton | **re-mesh, do not re-rig** — new geometry must weight to existing bones |

## Phases

### Phase 0 — Validate the layout across the whole corpus — **DONE 2026-09-20**

`tools/mesh/validate_vwm.rb` walked all 1,269 meshes straight out of the packs.

| group | count | what it is |
|---|---|---|
| **decoded container** | **1021** (80.5%) | the layout holds, chains to EOF |
| encrypted | 224 (17.6%) | entropy **7.95**, 0.3% nulls, all in patch1-4 |
| second container | 14 | entropy 5.4-5.9, ~35% nulls — readable, different shape |
| testdata oddities | 9 | dev assets (`musketman`, `ranger_test`) |
| empty stub | 1 | `euro_equipment` — valid magic, 0 parts |

**Excluding DLC and testdata, coverage is 1021/1032 = 98.9%.** The container is
uniform across normal battle units, so the one-sample risk is retired and
Phases 1-2 can proceed on a firm base.

**The 224 are DLC, not a format variant.** `british_horse_guards`,
`france_swiss_guards`, `netherlands_blue_guards`,
`austrian_hungarian_grenadiers` — the Elite Units packs. Entropy 7.95-7.96
with 0.4% null bytes is encrypted/compressed data, and it was confirmed NOT to
be a reader bug: `packtool.ps1` extracts byte-identical bytes.

> **Consequence for the whole project: DLC units cannot be remodelled.** Any
> high-poly work covers base-game units only. Say so up front rather than
> discovering it when a commissioned model will not load.

**A second container exists for campaign-map models** — `campaign_soldier_base`,
`euro_king_and_courtiers`, `horse_base`, campaign generals and commodores. It
opens `[u4 count][u2 len][UTF-16LE name]` with no magic, is low-entropy and
plainly readable. That is a separate, smaller decode, needed only if campaign
models are in scope as well as battle units.

Corpus totals for the files that parse: **2,585,140 vertices, 3,224,380
triangles** — useful as the baseline any "high-poly" claim is measured against.

### Phase 1 — Finish the vertex encoding — **DONE 2026-09-20**

**`vertex_size = 52 + 32 * influence_count`**

```
 8 floats                                   32 B   position at [0..2]
 u4 influence_count                          4 B
 influence_count x [u4 bone][6 f4][f4 w]    32 B each
 4 x u4 tail                                16 B
```

count 1 -> 84 bytes, count 2 -> 116. The earlier guess of `84 + (c-1)*8` was
wrong by 4x: an influence is a 32-byte block, not 8.

Found by isolating the first multi-influence vertex in `legs02` (vertices 0-41
are all single-influence, so vertex 42 starts at a known offset) and solving
for the size that puts a plausible influence count on the next vertex. The
32-byte block structure was then visible directly: bone, six floats, weight.

Verified by switching `validate_vwm.rb` from SEARCHING for each part's index
block to walking vertices EXACTLY and requiring it to land on the index count.
Same 1021 files pass, now with no searching anywhere — across **2,585,140
vertices**.

### Phase 2 — Prove the WRITER byte-identically — **DONE 2026-09-20**

`tools/mesh/vwm.rb` is a symmetric reader/writer.

```
round-tripped 1022/1022 meshes BYTE-IDENTICALLY
influence distribution: 1:1443646  2:1130790  3:7070  4:2385
                        5:1046  6:183  7:16  8:4
```

Every non-DLC unit mesh in the game reads and repacks to the identical byte.
**The format is solved and writable.**

- Max influences per vertex is **8**, so 4 bits would not have sufficed and a
  fixed 4-influence assumption would have corrupted 1,249 vertices.
- Floats are carried as **raw 32-bit patterns**, never decoded to Ruby Float
  and back. NaN payloads and negative zero do not survive a naive round-trip,
  and the whole gate here is bit-exactness.
- `euro_equipment.variant_weighted_mesh` has valid magic and **0 parts** — a
  legal empty mesh. `validate_vwm.rb` originally called that malformed; that
  was the validator's bug, now fixed. Hence 1022 rather than 1021.

### Phase 1 (original text, superseded)

The single blocker. Approach, in order of cheapness:

1. **Use constrained parts as controls.** A part whose bytes divide exactly by
   84 is all single-influence (`teeth01` is). Those confirm the base vertex.
2. **Solve rather than guess.** Each part gives an exact equation: the sum of
   its vertex sizes must equal a known byte span. Walk with backtracking and
   let the arithmetic reject wrong rules — the same discipline that identified
   32-bit indices.
3. **Identify all 21 slots** by the method that cracked `rigid_model`: match
   each slot's value range against the part's bounding box to separate
   position / normal / UV / tangent / bitangent.

*Deliverable:* a reader that decodes every vertex of every file in the corpus.

### Phase 2 — Prove the WRITER, byte-identically

Repack every one of the 1,269 meshes and require **byte-identical** output.

This is the non-negotiable gate, and the standard this project already holds
for `rigid_model`, `startpos.esf` and `.loc`. A reader that is subtly wrong
produces plausible geometry that crashes or renders as garbage; only a
byte-identical round-trip proves the encoding is understood rather than
approximated.

*Deliverable:* `pack_vwm.rb`, and a corpus round-trip report with zero
mismatches.

### Phase 3 — Recover the skeleton — **DONE 2026-09-20**

`etwng/anim/anim2json_etw` converts `.anim` to JSON, and its bone list is
`[name, parent_index]` — the full hierarchy. Extracted from
`animations/aaa_warscapeframe/_default_standing_anim_warscapeframe.anim`:
**41 bones**, saved as `docs/warscape_skeleton.txt`.

```
 0 Hips <- ROOT      6 Spine       16 Neck        19 Head     24 Jaw
 1-3 Weapon1..3      13 Spine2     22 Brow        23 Eyes
 4/5 Left/RightUpLeg 11/12 Feet    15/18 ToeBase  29/30 Hands  31-40 fingers
```

The tool needs `-rpathname` on modern Ruby (`Pathname()` without the require
is an old-Ruby assumption); no edit to their code is necessary.

**Validated SEMANTICALLY, not just numerically.** Resolving the reference
mesh's bone indices against this table:

| part | bones it weights to |
|---|---|
| head01/02/03 | Head, **Jaw**, Neck, Brow |
| teeth01 | **Jaw**, Head |
| crossbelt01 | Spine, Spine2, Spine1, RightShoulder |
| legs01 | RightFoot, LeftFoot, **RightToeBase, LeftToeBase** |
| body01/02 | Spine2, RightHand, LeftHand, fingers |

Teeth on the jaw, boots on the toes, a crossbelt across torso and shoulder.
Highest index used is 40 against 41 bones. "In range" would only have shown
the indices were plausible; anatomical correctness shows the vertex influence
parsing, the influence-block layout and the skeleton mapping are ALL right.

*Deliverable:* `docs/warscape_skeleton.txt`.

### Phase 4 — Interchange with a real 3D tool — **PARTLY DONE 2026-09-21**

```
.variant_weighted_mesh  <->  JSON  <->  Blender
      vwm_json.rb              vwm_blender.py
```

**The chain round-trips BYTE-IDENTICALLY**, verified end to end through
Blender 5.2.2 headless:

```
ruby vwm_json.rb tojson eli.vwm eli.json
blender --background --python vwm_blender.py -- roundtrip eli.json out.json
ruby vwm_json.rb tovwm out.json back.vwm
-> 545602 bytes, byte-identical to the original
```

JSON layer alone: **1026/1026 meshes byte-identical** across every pack.
(1026 rather than 1022 because our own modified big-head meshes now ship in
`zz_chain.pack` and are picked up by the scan - they round-trip too, which is
a useful check that generated meshes are structurally indistinguishable from
CA's.)

**Floats are written with `%.9g`**, which is exactly the precision that
uniquely determines an IEEE-754 single - so decimal round-trips a float32
without loss, while staying readable and usable by a 3D tool. Fewer digits
would quietly perturb vertices; raw hex would be exact but useless to Blender.
The encoder VERIFIES each value re-encodes to the same bits and falls back to
`{"hex": ...}` for NaN/Infinity rather than mangling them.

**What Blender shows:** all parts as real meshes in TRUE OBJECT SPACE,
triangles, atlas UVs, and one vertex group per influencing bone with the true
weights.

### Phase 4b — the pose, so edits survive — **DONE 2026-09-21**

Geometry edits now survive the round trip. `.variant_weighted_mesh` → JSON →
Blender → JSON → `.variant_weighted_mesh` is byte-identical when nothing
changes, and a vertex moved in Blender is rewritten in every bone's frame.

#### The pose came from the MESHES, not the `.anim`

The plan was to read the bind pose out of `_default_standing_anim`. That was
abandoned on evidence: the community anim parser splits fields by byte count
rather than meaning, and a near-constant `0.483` repeated across unrelated
spine bones gave it away. (What *was* confirmed there: `flt[1..4]` is a unit
quaternion in 5617/5617 bone-frames, and `fix2[0..3]` + `flt[0]` are constant
per bone for 39/41 bones.)

The mesh turned out to contain the answer already. Empire stores a vertex once
per influencing bone, and **every copy is the same world point** in a different
frame. So for two bones and the vertices they share, the two point sets are
related by a rigid transform — which is exactly the bones' relative pose.

Checked before any solver was written: across every bone pair of every part,
pairwise distances agree to `0.000000`. The data is EXACT, not noisy, so no
SVD/Kabsch is needed — three spread-out points determine the rotation outright
(`tools/mesh/vwm_pose.rb`).

#### One pose per SKELETON FAMILY, pooled across the corpus

Solving each mesh alone works but has two defects:

- **Coverage.** `euro_line_infantry_lod1` cannot place bone 23 (Eyes) — all its
  eye vertices are single-influence. Lower LODs are far worse: lod3 places 32
  of the 35 bones it uses, because simplification removes exactly the blended
  vertices.
- **LOD drift.** Solved separately, each mesh's pose differs by ~1e-6, so the
  four LODs that must ship together would disagree about where the bones are.

Pooling fixes both — but **not across the whole corpus at once**. That produces
nonsense (worst residual 0.63, every mesh disagreeing with itself by up to
2.4 units), because the corpus is not one skeleton: campaign map models, horses
and camels have their own rigs and bone 19 does not mean the same thing in each.

`tools/mesh/vwm_pose_global.rb` therefore clusters meshes into families first, and
writes `docs/warscape_pose.json`:

| family | meshes | bones placed | seeded by |
|---|---|---|---|
| 0 | 795 | 38 of 41 | `horse_grenadier_guards_lod1` (human rig) |
| 1 | 136 | 37 of 40 | `horse_eastern_lod1` (horses) |
| 2 | 44 | 37 of 39 | `campaign_native_american_colonel_lod2` |
| 3 | 16 | 12 of 40 | `euro_pirate_officer_lod1` |
| 4–7 | 4/4/4/3 | — | elephants, camels, natives, campaign ships |

**1006 of 1009 meshes covered, 8/8 families fit, worst vertex disagreement
1e-6** over ~1.1 million multi-bone vertices.

#### Four things that looked right and were not

Each cost a rebuild, and each is a trap for anyone redoing this:

1. **A near-zero residual does not mean a correct transform.** Finger bones
   share five nearly-collinear vertices; any roll about the finger's axis fits
   them to ~0. Composing a chain through such a bone threw the pose 0.61 units
   out while every edge reported a 4.6e-7 residual. Fixed by scoring each edge
   with a scale-free confidence (`triangle area / span²`) and building the pose
   as a **maximum spanning tree** by confidence — the maximum-bottleneck tree,
   so every bone is reached by the path whose weakest link is strongest.
2. **Pooling by "first N correspondences" silently tests nothing.** The quota
   filled from the first mesh alphabetically, so the residual only ever re-tested
   that one mesh. Fixed with a small per-mesh quota.
3. **Sampling the first N vertices samples one part.** A probe built that way
   let `campaign_native_american_colonel` into the human family, whose pose is
   wrong for it by 0.16. Fixed by sampling per distinct BONE COMBINATION —
   every relationship the mesh asserts gets tested.
4. **Iterating "solve, reassign, repeat" does not converge.** It went
   85 → 9 → 161 → 8 families, because re-solving MOVES the pose. Replaced with
   a single pass that only ever EXTENDS a family's pose onto new bones and never
   moves a placed one, so an accepted mesh stays accepted. Family choice goes to
   the pose with the MOST testable evidence, which makes it order-independent
   (the merge pass now converges with zero moves).

### Phase 4 (original text, superseded)

Convert mesh + weights + skeleton to something Blender reads, and back.

glTF or Collada carry skinning; **OBJ does not** and is useless here. Simplest
credible route is a JSON intermediate plus a small Blender import/export
script, since we already control both ends.

*Deliverable:* mesh → Blender → mesh, byte-identical when nothing is changed.
Same gate as Phase 2, because a lossy interchange is a silent corruption.

### Phase 5 — First modified mesh, one variable

Do **not** start with new art. Take a shipped unit and make the smallest
possible change — move one vertex, or subdivide one part — then look at it in
a battle.

This separates "our encoder is correct" from "our art is wrong", which is
impossible to untangle if both change at once.

*Deliverable:* a visibly altered vanilla unit, in game.

### Phase 6 - An actual high-poly unit - **DONE 2026-09-21, CONFIRMED IN GAME**

`tools/mesh/subdiv_vwm.rb` adds geometry by Loop subdivision, producing valid
influences for every new vertex. Measured on `euro_line_infantry`:

```
             file                    assembled soldier
lod1   4,980 ->  16,600 verts        2,181 ->  7,347 verts
       6,596 ->  26,384 tris  x4.00  2,970 -> 11,880 tris  x4.00
lod2   3,283 ->  10,549 verts
       3,974 ->  15,896 tris  x4.00
```

Vertices grow ~3.3x, not 4x — they grow by the EDGE count, and these parts are
open shells. File size goes 545 KB -> 1.93 MB for lod1.

**Target chosen: 4x uniform.** Subdivision is quantised at x4 per step, so an
exact 5x is not reachable; the alternatives were 4.0x (one step everywhere) or
5.5x (one step plus a second on the head). 4x is the lower performance risk.

Decompiling
`FUN_010307f0` shows it is a **load** loop, not a per-frame chooser:

```c
if (param_11 == 0xffffffff) {                      // no explicit LOD asked for
    iVar4 = *(int *)(DAT_016aede4 + 0x5e0b4);      // graphics setting
    if (iVar4 == 0 || iVar4 == 1) uVar10 = 2;      // low    -> start at index 2
    else if (iVar4 == 2)          uVar10 = 1;      // medium -> start at index 1
    else                          uVar10 = 0;      // high   -> start at index 0
}
do { ...load LOD uVar9... uVar9++; } while (uVar9 < *(uint *)(param_6 + 0x24));
```

It loads **every** LOD from that index onward into an array. The setting decides
which LODs are *available* — low settings skip loading the detailed ones — and
distance picks among them per draw. Confirmed by the format string
`Model LOD %d: range %f verts %d` and by the table below.

**The distance bands are DB data**, in `db/warscape_rigid_lod_range_tables`
(185 bytes, parses byte-exact). For a 4-LOD model the stored value is each
LOD's far limit, the last being 0 for "unbounded":

| LOD | used at distance |
|---|---|
| lod1 | 0 – 200 |
| lod2 | 200 – 400 |
| lod3 | 400 – 750 |
| lod4 | 750+ |

So subdividing lod1 and lod2 costs only men within 400 units, lod3/lod4 stay
vanilla, and if the near band is still too expensive, **pulling lod1's range in
is a one-line data edit, not an art redo**. There are also
`rigid_lod_distance_scaler` and `lod_addition` knobs in the binary.

#### Boundary vertices are PINNED, and finding out why took two bad metrics

The textbook Loop boundary rule (`3/4 v + 1/8 (prev + next)`) smooths *along* a
border curve. That is right for one surface and wrong here: parts abut each
other (arms to body, body to legs) and do not share vertex spacing along the
ring, so each side computes a different position and **the joint opens**.
Measured: gaps up to 0.049 on a figure 1.98 tall — about 4 cm on a man, at
exactly the range lod1 is drawn.

Two ways of checking for this DO NOT WORK:

- **Counting shared positions.** Subdivision adds midpoints on both sides at
  identical places, so the shared count goes *up* (73 → 122) while the original
  vertices drift apart. It reported "ALL PART JOINTS STILL MEET" while ten
  joints were open.
- **"Nearest neighbour within a threshold, then take the max."** That returns
  the threshold. Every reading came back 0.049 for a cutoff of 0.05 — the
  metric measuring itself.

What works: subdivision preserves original vertex indices, so a pair of
vertices that occupied the same point before can be followed by index and
measured after. No threshold, no search. With boundaries pinned, real joints
read **1e-8, unchanged from vanilla**.

Four pairs still diverge — `body01/body02`, `legs01/legs02`, `arms01/arms02`,
`head_nohair01/02`. Those are not joints: they share 74–197 coincident vertices
where a real joint shares 8–20, and their UVs occupy **different atlas regions**
(the four heads sit in disjoint v bands). They are mutually exclusive variants,
one drawn per man, so divergence is harmless.

#### The six unknown floats are two unit directions — and the space does not matter

Measured on all 4,980 vertices: `|(f2,f3,f4)| = 1.0000` and `|(f5,f6,f7)| =
1.0000` exactly. They are directions, stored ONCE per vertex.

- **Not bone space** — that is per-influence by construction.
- **Not object space** — neither triple matches the object-space normal for any
  vertex.
- **Not an orthonormal frame** — `|dot|` between them averages 0.32 and reaches
  0.9999. A dot product is rotation-invariant, so non-orthogonality holds in
  *every* space; no frame can make them a tangent/binormal basis.
- **Tangent-like**: they correlate with the UV-derived tangent/binormal at
  r = 0.68 (median difference 0.035), which is what raw un-orthogonalised UV
  derivatives look like.

Their exact frame is still unknown — and does not need to be. Interpolating two
directions and renormalising stays in whatever frame they were already in, so
new vertices get them without identifying it. The 16-byte tail takes exactly one
value ever (all zeros), so new vertices copy it.

#### Gates met

```
shared-point check        6,347 multi-bone vertices, worst 0.00000003
weights                   all sum to 1
normals                   all unit length
influence budget          max union across any edge = 4, limit is 8
seam integrity            1,018 coincident groups, worst separation 0.00000000
part joints               1e-8, unchanged from vanilla
self-consistency          accepted by vwm_pose_global.rb (38 of 38 bones)
JSON round trip           byte-identical at 1,928,610 bytes
```

Staged at `staged/unitmodels_hipoly/` (lod1, lod2). **Not yet seen in game** —
that is the remaining step, and the things to look for are cracks at the neck,
cuffs and waist, and the frame rate in a large battle.

*Deliverable:* one unit at 4x density, correct at the LODs that matter.

### Phase 7 - Textures - **RESOLVED 2026-09-21: 2048 works, top mip sampled**

Unit diffuse is **1024x1024 DXT1, 10 mips** today.

1. **First, test whether >1024 is accepted at all.** Swap one unit diffuse for
   a 2048 version and look. This is cheap and decisive, and it gates
   everything else in this track. It is currently UNVERIFIED.
2. If accepted, upgrade **selectively**. 4K is 16x the pixels (~11 MB vs
   0.7 MB per texture with mips); LAA makes that arguable for some units, not
   for every unit in a large battle.

## Risks, honestly

- **The skeleton is fixed.** This is a re-mesh, not a re-rig. New bones are not
  on the table without far deeper work.
- **Four LODs multiply the authoring cost**, and the player's setting decides
  which is seen — so quality cannot be guaranteed by making lod1 beautiful.
- **Performance is the real ceiling, not the format.** Empire draws thousands
  of men; a 10x vertex count per soldier is a different proposition from a
  hero model in an RPG. Expect to benchmark a full battle, not a diorama.
- **One-sample bias.** Everything decoded so far comes from a single mesh.
  Phase 0 exists precisely to attack that before it becomes load-bearing.
- **Scope.** Phases 0–2 are well-understood work with a clear finish line.
  Phases 4–6 are a content pipeline, which is a different and larger kind of
  project than everything this repo has done so far.

## Verification standard

Byte-identical round-trips at Phase 2 and Phase 4. No exceptions — "it loaded"
is not evidence, and this project has twice been burned by output that looked
plausible and was wrong (`EsfLibrary` writing a byte-different 65 MB file; the
stale `corn`/`grain` tables that shipped silently).

## Key files

- `tools/mesh/decode_vwm.rb` — the incremental decoder
- `scratchpad/mesh/walk.rb`, `parts.rb`, `vsize.rb` — layout proofs
- `etwng/etwconv/lib/rigid_mesh.rb` — the solved sibling format
- `etwng/anim/anim2json_etw` — skeleton recovery
- `SKILL.md` → "UNIT ART — what the engine allows, and where the real blocker is"
