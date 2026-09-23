# ESE: tracing, patching and scanning

Five natives added to `ese_proxy.c`. They exist because ESE could read memory
freely but could only *write* a float — so NOPing an instruction or poking an
int meant leaving the game and going to Cheat Engine, and the trampoline
machinery that was already in the DLL was wired to exactly one fixed hook.

## The natives

| native | use |
|---|---|
| `ESE_WriteInt(addr, value)` | 4-byte write; value decimal or `0x`-prefixed |
| `ESE_WriteBytes(addr, "90 90 90")` | hex byte patch — this is how an instruction gets NOPed live |
| `ESE_Scan("8B 41 ?? 85 C0")` | byte-pattern search of Empire's image; returns up to 8 **static** addresses |
| `ESE_Trace(addr [,"on"\|"off"] [,nargs] [,steal])` | code tracer — patches a JMP into the prologue |
| **`ESE_TraceVT(obj, index [,"on"\|"off"] [,nargs])`** | **vtable tracer — prefer this, no bytes stolen** |
| `ESE_TraceLog(addr [,max])` | drain the call ring: one line per call, oldest first |
| `ESE_Caps()` | real `D3DCAPS9` numbers off the live device |

`ESE_ReadBytes` also went from a 64-byte cap to **256**, so a struct dump no
longer has to be chunked.

## Prefer ESE_TraceVT where you can

A vtable entry is a **pointer**. Replacing it steals no bytes, so there is no
instruction-boundary hazard and no prologue to decode — the entire class of
bug that makes `ESE_Trace` require a hand-computed steal simply does not exist.
Many interesting engine calls are virtual (camera controller `vt[0x128]`,
entity vtables, D3D and effect interfaces), so reach for this first.

```lua
ESE_TraceVT("0x334A0C08", "74", "on", "3")   -- ctl vt[0x128] = index 74
ESE_TraceLog("s:639230")                      -- keyed by the ORIGINAL function
ESE_TraceVT("0x334A0C08", "74", "off")
```

Both tracer kinds share one slot array and one ring, keyed by the original
function address, so `ESE_Trace(addr)` reporting and `ESE_TraceLog(addr)`
draining work for either.

## The call ring

Keeping only the *last* args is useless for the job these tracers exist for —
mapping an opcode table needs the **sequence**. Each slot keeps a 64-entry ring;
`ESE_TraceLog` returns records oldest-first and advances a drain cursor, so each
call is reported exactly once. If the ring wrapped before you drained it, the
reply starts with `[lost N]` rather than silently skipping — a gap would corrupt
any sequence built from it.

The handler runs on the **game thread inside the hooked function**, so it does
nothing but stamp the ring: no allocation, no locks, no Lua. Drain it from
`ESE_Tick` or a pipe eval.

All addresses accept the usual `s:` prefix for static (Ghidra) addresses, so
`ESE_Trace("s:5F6E40", "on", "4")` works directly from a decompile.

`ESE_Scan` returns **static** addresses (delta already subtracted) so a hit
pastes straight back into Ghidra. Wildcards are `??`. A pattern is what makes a
find survive a patch or a different build instead of being hardcoded forever.

## How the tracer works

Each traced site gets its **own** trampoline carrying its slot id, so one
handler serves all eight slots:

```
pushfd / pushad
lea eax,[esp+0x24]      ; -> {retaddr, arg1, arg2, ...}
push <slot>             ; arg2
push eax                ; arg1
call trace_handler
add esp,8
popad / popfd
<stolen 5 bytes>
push <site+5> / ret
```

`ESE_Trace(addr)` with no command then reports `hits=` and the last captured
args. `"off"` restores the original bytes from the slot's saved copy.

### Deliberate limits

- **Steal MUST end on an instruction boundary — pass it explicitly.**
  `ESE_Trace(addr, "on", nargs, steal)`. The default of 5 is almost always
  WRONG: every target checked below would be split by it. There is no length
  disassembler here, and the branch guard cannot detect a mid-instruction cut.
  Read the boundary off `ghidra.ps1 disasm` and pass the smallest value >= 5.
- **Relative branches in the stolen range are REFUSED** (`E8 E9 EB 70-7F 0F8x`).
  Relocating one needs a displacement fixup; declining to hook is far better
  than silently corrupting a prologue.
- `mem_executable` is checked before arming, and 8 slots is the maximum.

### Getting the steal length

```
.\ghidra.ps1 disasm out.txt 0 8 <ADDR>
```

Add up instruction sizes until the running total reaches 5 or more; that total
is the steal. Example for `639230` — boundaries 0,1,2,4,**6**,12,14 so steal 6:

```
00639230: PUSH ESI        1
00639231: PUSH ECX        1
00639232: MOV ESI,ECX     2
00639234: MOV EDX,ESP     2   <- running total 6, first boundary >= 5
```

## Worth tracing first

Addresses already verified elsewhere in these docs. `nargs` is a guess from the
decompiled signature — the tracer captures raw stack slots, so read them against
the decompile rather than trusting the count.

**Steal lengths below are computed from the real prologues — do not use the
default 5 for any of them.**

| function | static | steal | prologue | why it matters |
|---|---|---|---|---|
| `FUN_005B3E00` | `5B3E00` | **7** | `MOVZX EAX,[ECX+0x3b3]` (7) | **the selection order dispatcher** — every unit order funnels through `(opcode, amount)`. Tracing it logs every order the player issues, with its opcode |
| `BCQ_FIRE_PROJECTILE` | `5D0560` | **6** | `SUB ESP,0xac` (6) | fires one projectile; shows whether the command path is used in single-player |
| `BCQ_ENTITY_ORDER_MOVE` | `5D02F0` | **8** | `SUB ESP,0x54`(3) `PUSH ESI`(1) `MOV ESI,[ESP+0x5c]`(4) | **per-entity** move order — the engine has per-soldier commands even though Lua does not expose them |
| `FUN_00718930` | `718930` | **6** | `SUB ESP,0xa0` (6) | the pending-shot object: one man, one round, with the drill delay |
| `FUN_007192A0` | `7192A0` | **7** | `SUB ESP,0xc`(3) `MOV EDX,[ESP+0x10]`(4) | terrain height at (x,z); useful to confirm call frequency |
| `FUN_00639230` | `639230` | **6** | `PUSH ESI`(1) `PUSH ECX`(1) `MOV ESI,ECX`(2) `MOV EDX,ESP`(2) | camera controller move-to (`ctl->vt[0x128]`) |
| `FUN_010485D0` | `10485D0` | **5** | `PUSH ECX`(1) `PUSH ESI`(1) `PUSH EDI`(1) `MOV EDI,ECX`(2) | binds `animation_matrix_stack` — shows when bone params rebind. The only one where 5 is genuinely correct |

The dispatcher at `5B3E00` is the highest-value first target: it sees **every**
selection order, and a trace of it maps opcode numbers to the orders you issue
in game — which is how the rest of the order table gets named.

Example:

```lua
ESE_Trace("s:5B3E00", "on", "3", "7")   -- arm, 3 args, steal 7
-- issue some orders in game --
ESE_Trace("s:5B3E00")                   -- hits=.. args=<opcode> ..
ESE_Trace("s:5B3E00", "off")
```

## Warning

A tracer writes into live code. Arm one at a time, confirm with the `hits`
report, and `"off"` it before arming the next until each is known good. The
prologue guard refuses the obviously unsafe cases but cannot catch everything —
in particular it cannot tell whether byte 5 lands mid-instruction.
