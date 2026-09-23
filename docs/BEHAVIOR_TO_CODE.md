# Behavior-to-code toolkit

The toolkit narrows engine research to one observed behavior. It joins four
kinds of evidence: static instructions/functions, memory reads and writes,
controlled runtime inputs, and resulting state transitions. A graph edge means
the relation named by that edge was recorded or asserted in the input. It is
not automatic proof that two addresses form an object or that a function caused
the observed change.

## Workflow

1. Choose a small set of candidate memory addresses and state what is uncertain.
   Keep fields keyed by offsets such as `48` or `4c`; names like `position` are
   hypotheses, not capture labels.
2. Capture distinct phases with the same fields: stand still, move straight,
   turn in place, then repeat a phase. Change one input at a time. Do not compare
   a selection change, terrain change, and movement in the same interval.
3. Run `sysid.rb` and `active.rb` on that trace. Treat the winning interpretation
   as a candidate, and run the suggested phase before accepting it.
4. Add observed call/read/write links to a graph and slice backward from the
   value or forward from the instruction. Use CFG dominators only on control
   flow edges for one function.
5. Keep counterexamples and alternate explanations next to the result. A field
   with no movement during the capture is unclassified, not a constant.

## Capture live battle fields

`tools/behavior/capture.ps1` uses the current ESE pipe client and dynamically
resolves the toolkit and game paths. It calls only `ESE_ReadFloat` and
`ESE_ReadInt`. A field spec is `hex-offset=address:type`; the address may be a
live hex address (`0x...`) or a Ghidra static address (`s:...`, to which ESE
adds the current ASLR delta).

```powershell
.\tools\behavior\capture.ps1 `
  -Fields @('48=s:01234567:float','4c=s:0123456B:float') `
  -Out .\movement.jsonl -SamplesPerPhase 24 -IntervalMs 250
```

At each prompt, perform the matching action in the battle and enter the phase
and its two input values, for example `stop 0 0`, `straight 1 0`, `turn 0 1`,
and `stop 0 0` again. The collector labels observations; it does not move the
unit or verify that a key was physically held. Enter `q` to end.
Capture requests each read at a 250 ms target interval; the models treat one
consecutive sample as one step, so keep capture cadence consistent. Unreadable
fields are written as JSON `null`, not zero. Address strings are retained as
capture metadata. The output path must be new so separate sessions cannot be
mistaken for adjacent frames.

ESE's local named pipe accepts Lua source. Keep ESE and its pipe on a trusted,
local machine; do not expose it to a network or shared account. This collector
passes generated calls to read-only ESE natives, but the pipe itself is a more
powerful interface. It reads fixed process addresses for one capture; it does
not yet follow pointer chains or reacquire a changing selected-entity pointer.

## Shared trace format

One JSON object per line:

```json
{"t":0,"phase":"stop","u":{"fwd":0,"turn":0},"x":{"48":1523.0,"4c":189.2}}
```

`t` is a monotonically increasing sample index. Gaps are excluded from
transition fitting. `phase` names the intervention. `u` records the input
applied during the interval starting at `t`. `x` maps candidate hex offsets to
observed numbers, strings, or `null`. Unknown keys such as capture address
metadata are preserved in the source file but ignored by the analyzers.

## Tools

### System identification: `sysid.rb`

Fits a deliberately small set of models: static, free counter, movement or
turn integrator, proportional response, decay, gated/free cycle, and a two-input
integrator. With at least eight transitions it fits alternating transitions
and scores on held-out transitions; shorter traces are scored in-sample and
reported `LOW DATA`. Complexity is penalized. The margin compares the top model
to its nearest rival. `MODEL SUPPORTED` means the candidate model separated by
the configured score margin on these held-out samples. It is not a calibrated
probability that the semantic label is correct.

```powershell
ruby .\tools\behavior\sysid.rb .\movement.jsonl --field 48 --verbose
ruby .\tools\behavior\sysid.rb .\movement.jsonl --all
```

The model library is intentionally incomplete. A winning integrator is
consistent with position under the recorded inputs; it does not rule out an
unmodeled controller that happens to track those inputs. Use more interventions
when the report is ambiguous or the train/held-out errors diverge.

### Experiment ranking: `active.rb`

Forecasts each plausible fitted model under candidate controls and ranks the
controls by expected entropy reduction over predicted outcomes. Weights are a
softmax of model scores and are a heuristic, not Bayesian posteriors. The
default candidates are stop, move straight, turn in place, and move while
turning. A custom JSON array can specify `name`, `u`, and optional `steps`:

```json
[{"name":"stop 8 ticks","u":{"fwd":0,"turn":0},"steps":8}]
```

```powershell
ruby .\tools\behavior\active.rb .\movement.jsonl --field 48 --steps 8
```

The ranking is useful only when candidate inputs can actually be applied and
recorded. It maximizes disagreement among current models; it does not account
for unlisted explanations or measurement noise beyond the output tolerance.

### Dependency graph and loops: `graph.rb`

JSON nodes have an `id`, `kind` (`instruction`, `function`, `memory`, or
`state`), and optional `function` and `entry` properties. Edges carry `from`,
`to`, and one of `calls`, `reads`, `writes`, `transitions`, or `controls`.
Backward slices answer which recorded dependencies lead to a node; forward
slices list recorded possible effects. `--kind` and `--depth` limit traversal.

```powershell
ruby .\tools\behavior\graph.rb slice .\battle_graph.json backward mem+0x48 --kind reads,writes
ruby .\tools\behavior\graph.rb cfg .\battle_graph.json FUN_007192A0 --entry bb0
```

For a CFG, give every basic-block node the same `function` value and connect
blocks only with `controls` edges. For example, `bb3 -> bb1` is a natural-loop
back edge when `bb1` appears in the dominator set for `bb3`:

```json
{"nodes":[{"id":"bb0","kind":"instruction","function":"F","entry":true},
          {"id":"bb1","kind":"instruction","function":"F"},
          {"id":"bb2","kind":"instruction","function":"F"},
          {"id":"bb3","kind":"instruction","function":"F"}],
 "edges":[{"from":"bb0","to":"bb1","type":"controls"},
          {"from":"bb1","to":"bb2","type":"controls"},
          {"from":"bb2","to":"bb3","type":"controls"},
          {"from":"bb3","to":"bb1","type":"controls"}]}
```

CFG analysis calculates dominator sets per function and marks a control-flow
edge `u -> h` as a back edge when `h` dominates `u`. It then reports the
natural-loop body. Supply only actual control-flow edges for that function;
runtime repetition (a unit patrolling repeatedly) is a different observation
and belongs in the trace/state-machine tools.

### Repeating states: `automata.rb`

Given a directly observed categorical state field, this reports transitions
conditioned on input values. If the same state and input lead to multiple next
states, it flags a missing-state clue: perhaps a timer, target, flag, or a noisy
observation. It does not decide which missing variable explains the split.

```powershell
ruby .\tools\behavior\automata.rb .\behavior.jsonl --state 1a0 --input fwd,turn
```

### Constraints and bit-vector wrap: `constraints.rb`

Checks whether consecutive integer samples fit the proposed cyclic update
`q' = (q + 1) mod n` at a stated bit width. The direct checker always runs. If
Z3 is available on `PATH`, or `Z3_EXE`/`--z3` names it, the tool also submits a
QF_BV SMT-LIB model so machine-width overflow is represented directly. `--emit`
writes the formula for inspection. This is a constrained counter hypothesis,
not a general-purpose engine solver.

```powershell
ruby .\tools\behavior\constraints.rb .\counter.jsonl --field 88 --width 8 --modulus 256 --emit .\counter.smt2
```

### Candidate field groups: `groups.rb`

Ranks numeric fields that move together and co-occur in samples. Optional graph
evidence can report functions that read/write both memory nodes. Correlation,
shared access, and nearby offsets are leads for examining ownership/lifetime;
none alone proves a class or object boundary.

```powershell
ruby .\tools\behavior\groups.rb .\movement.jsonl --min-corr 0.9 --graph .\battle_graph.json
```

## Evidence model and current limits

- A backward slice follows supplied graph edges; it cannot discover missing
  call sites, aliasing, indirect writes, or code paths that were never added.
- Dominators are meaningful only for a complete-enough CFG with correct entry
  nodes and control-flow edges.
- Runtime values that co-move may be coupled by animation, camera smoothing,
  terrain, or selection state. Controlled stop/move/turn contrasts are stronger
  evidence than another passive scan, but still do not establish source-level
  ownership.
- Trace timestamps are sample indices, not game frames. The collector has a
  target interval, not a guarantee of exact timing. Do not compare rates across
  captures with materially different intervals.
- Model coverage is intentionally small. `LOW DATA`, `AMBIGUOUS`, and
  counterexamples are actionable results, not tool failures.
- For engine provenance, pair these reports with Ghidra decompilation and ESE
  trace/read evidence. An address found by a memory scan becomes a named field
  only after independent interventions and code access evidence agree.

## Mirror to the game tree

Edit the kit copy, then mirror it before testing. `.\empire.ps1 sync` copies
`tools/behavior` alongside the other helper categories into the game's
`EmpireScriptExtender\tools` tree.

Standing rule: every new tool or Lua file, and every edit to a tool or Lua
file, must be present in both ESE trees:

- dev/kit: `Total war empire tools\EmpireScriptExtender`
- live/game: `EmpireScriptExtender`

The script sources use `require_relative` and resolve the ESE client from the
toolkit path, so the toolkit does not assume a fixed Steam library or current
working directory.
