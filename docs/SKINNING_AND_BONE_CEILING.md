# Empire: Total War — skinning, the bone ceiling, and what is actually possible

Status of every claim below is marked **PROVEN**, **MEASURED**, **INFERRED** or
**UNTESTED**. Several earlier notes in this repo were none of those and turned
out wrong, so the distinction is the point of this document.

---

## 1. The constraint, stated exactly

**PROVEN (read from the shader).** `fx/weighted.fx` declares:

```hlsl
float4 animation_matrix_stack[FX_MAX_ANIMATION_NODES * 3];   // 3 float4 per BONE
struct INSTANCE_DATA { float4 row0, row1, row2, row3, faction_colour; };  // 5 float4
INSTANCE_DATA vs20_instance_data[FX_WEIGHTED_MAX_INSTANCES]; // 5 float4 per INSTANCE
```

Both live in the same vertex-shader constant file. `vs_3_0` guarantees **256
float4 constant registers**. So:

```
bones x 3  +  instances x 5  +  (world, material, lighting)  <=  256
```

**MEASURED.** Vanilla is `41 bones, 19 instances`:
`41*3 + 19*5 = 218`, leaving 38 for everything else — i.e. CA tuned this to sit
exactly on the limit, which is what their own comment says:
`// sm2.0 instancing, limited by shader constants available...`

### Observed results

| config | registers (bones+inst) | result |
|---|---|---|
| 41 / 19 (vanilla) | 218 | works |
| 45 / 19 | 230 | roadmap claims works — **UNVERIFIED**, and the budget model says it should not |
| 64 / 19 | 287 | **PROVEN BROKEN** — bodies vanish, weighted meshes collapse to a flat grey blob; muskets and packs (rigid, unskinned) still render |

**Key diagnostic:** at 64 the shader still **compiled** — `weighted.fxc` grew from
67,834 to 75,562 bytes. So the failure is NOT the HLSL compiler. It is the
runtime constant upload exceeding the device limit, after which the bone
matrices never arrive and every skinned vertex transforms to the same point.
That is exactly the grey-blob symptom.

---

## 2. Constraints 

None of these are settings; they are architectural choices Empire predates.

| approach | ceiling | why Empire cannot |
|---|---|---|
| D3D10/11 constant buffers | ~4096 float4 | engine is D3D9 |
| Vertex texture fetch (matrices in a texture) | thousands | engine uploads to a *named constant array* |
| Hardware instancing from a vertex stream | frees all instance registers | engine packs instances into constants |
| Dual-quaternion skinning (2 float4/bone) | +50% | engine uploads matrices, not quaternions |
| Bone-palette partitioning (per-draw subsets) | 200+ | mesh influences store ABSOLUTE bone indices; no per-part remap |

**The 256 limit itself cannot be patched.** It is a `vs_3_0` / driver cap, not a
value in Empire.exe. Patching can only change the *mechanism* so fewer registers are needed.

---

## 3. What IS reachable, and the numbers

Trading instancing for bones needs no code at all — it is two `#define`s in
`fx/fxconfig.h`, overridden by a ~1.5 KB type-4 pack (Empire compiles shaders at
runtime via `d3dx9_40.dll`, so the header inside a pack is live).

```
bones x3 + instances x5 + 38 <= 256
   48 bones, 14 instances -> 252   FITS
   52 bones, 12 instances -> 254   FITS
   59 bones,  8 instances -> 255   FITS   <- full hand anatomy
   71 bones,  1 instance  -> 256   FITS   <- theoretical max without engine work
   72 bones,  0 instances -> 254   (instancing cannot be 0)
```

**Cost:** fewer instances per draw = more draw calls. 19 -> 8 is ~2.4x the
weighted draw calls. Unmeasured; needs a frame-rate reading with ~2000 men.

---

## 4. The open questions, and the cheapest test for each

### Q1. Does the engine respect the shader's declared array size?
**UNTESTED — and it gates everything else.**
The engine binds `animation_matrix_stack` and `vs20_instance_data` **by name**
through the effect framework (`FUN_010485D0` binds world / animation_matrix_stack
/ mesh_data / faction_colour; handles land at `+0x08`, `+0x1C`, `+0x30`, `+0x44`
of the parameter block). Binding by name means there is no hardcoded register
layout to desync. But the *batch count* may still be a C++ constant.

- If the engine reads `Elements` from the effect -> shrinking the array is safe,
  and **71 bones is reachable with zero code**.
- If 19 is baked in C++ -> it writes 95 registers into a 40-register array,
  corrupting the bone stack. Then the immediate must be patched.

**Test:** deploy `59 bones / 8 instances` and look. Renders = data-driven.
Broken = baked, and that is when to hunt the immediate.

### Q2. Does the engine upload more than 41 matrices?
**UNTESTED.** The shader having 59 slots does not mean the skeleton loader fills
them. A mesh weighted to bone 41+ with a matching `.anim` would settle it.
Until then, "45 renders correctly" only means *nothing broke* — the extra slots
may simply be unused.

### Q3. Is `dip_batch` geometry replicated in the vertex buffer?
**UNTESTED.** Each vertex carries `instance_index : TEXCOORD0` and the shader
does `get_instance_data(v.instance_index.r)`. If the mesh is duplicated N times
in the VB with a baked index, then converting to hardware instancing means
rebuilding those buffers — substantially more than patching a draw call. This
decides whether "stream instancing" is a medium or a large job.

### Q4. What does the GPU actually report for `MaxVertexShaderConst`?
**UNTESTED.** 256 is the *minimum* guaranteed; some drivers report more. We
already hook D3D9, so logging `D3DCAPS9.MaxVertexShaderConst` is a few lines.
Unlikely to exceed 256, but it is the only way to know rather than assume.

---

## 5. Relevant addresses found

| what | address |
|---|---|
| binds `animation_matrix_stack` (+ world, mesh_data, faction_colour) | `FUN_010485D0` |
| second binder referencing the same name | `FUN_01045390` |
| `weighted_dip_batch` renderer constructor | `FUN_010486A0` (vtable `0x012F6484`, param block at `+0xC`) |
| effect/technique registration table | `FUN_0103EDA0` |
| string `animation_matrix_stack` | VA `0x012EE364` |
| string `vs20_instance_data` | VA `0x012EE2F4` |

Note `0x012F6568` is **not** a vtable — it is UTF-16 string data that looks like
one in a pointer dump.

---

## 6. Verdict

For **hand/knuckle anatomy** the ceiling is not the obstacle: 59 bones is needed
and 59 fits today via `fxconfig.h` alone. The real work is data:

1. add the bones to the skeleton in **3,789 `.anim` files**
   (round-trip is **PROVEN** byte-exact: `camel_gallop.anim` -> JSON -> `.anim`, `cmp` identical)
2. re-weight fingertip vertices across **232 lod1 + 232 lod2** meshes
   (hi-poly already carries **2,899 finger-weighted vertices** per unit, 3.6x vanilla)
3. author distal-joint motion (distal follows proximal at roughly 2/3 flexion)

Engine surgery (stream instancing, VTF, palette partitioning) buys head-room
beyond that, but is not required to get fingers.

---

## 7. PROVEN: bones can be added to an animation

`tools/mesh/anim_addbone.rb` (new) extends the skeleton in a `.anim`:

```
ruby -rpathname etwng/anim/anim2json_etw in.anim in.json
ruby tools/mesh/anim_addbone.rb in.json out.json "RightHandIndex3:39" "RightHandMiddle3:40"
ruby -rpathname etwng/anim/json2anim_etw out.json out.anim
```

**Verified on the reference human skeleton**
(`animations/aaa_warscapeframe/_default_standing_anim_warscapeframe.anim`):

```
41 bones, 137 frames  ->  45 bones, 137 frames
225,744 bytes         ->  247,808 bytes
re-parsed: names match, frame count matches, every frame has 45 entries
```

A new bone is seeded by **copying its parent's frame entry**, so it sits exactly
on the parent joint and nothing moves. That is deliberate - it separates "the
skeleton changed" from "the motion changed", so the two can be tested
independently.

Both etwng tools need `ruby -rpathname` on modern Ruby (`Pathname()` without the
require is an old-Ruby assumption). Worth patching the two scripts rather than
remembering the flag.

**Still unproven:** that the ENGINE uploads matrices for bones past 40. A 45-bone
anim parsing correctly says nothing about whether the renderer feeds slots 41-44.
That needs a mesh weighted to bone 41+ plus this anim, under a shader config with
room (e.g. 59/8).
