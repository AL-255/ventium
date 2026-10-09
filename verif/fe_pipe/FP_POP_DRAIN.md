# Popping x87 arithmetic: last-response admission

Experimental, default-off `VEN_FP_POP_DRAIN`; not FPGA or standard-suite
acceptance. Latest verified gameplay is **0.38064497 total U+V IPC**, full-PC
model `e44e3176c915a275cfd644a0cfe6cd7bc487d45b2d2cc5a3378a52d6a18c928e`,
cycles **1,200,000,000–1,300,000,000**. That predates this fix and the LRU/XPM
candidates. The target remains **0.48**. Direct-memory CoreMark's earlier
**2.10736/2.11041 CM/MHz** does not measure FPGA DDR/cache performance or this
new candidate.

## Combined full-PC qualification launched

`external/tmp/ventium-pop-drain-soc.PSCvg59V` combines this core with the
LRU-owner repair and the FPGA registered-output/read-first RAM profile.
Model `c90d8fc04321f4875111f3f038d8e47e28f3f19539f0bb044bec3fce4878f6a5`
builds natively with stable pins. Every actual core/FP source matches the
microtested pop-drain candidate; platform sources match the XPM parent.
`VEN_FP_POP_DRAIN` is the only added macro. The unique host object/header and
all four intended RAM-model instances are checked. The same 98 inherited
third-party structural warnings remain; this is not clean full-SoC lint.

Fresh cold Quake/Win95 services `ventium-pop-drain-{quake,win95}-oct09` run
on CPUs18/19, invocation IDs `a41823228ff2456c8b359fa1253de2a5` and
`d997b066cf73405cb027edbf8b8a95c2`. Both actual native executable identities
were admitted with unchanged media, 40/40/80 MHz clocks, full P5 L1s,
32 KiB platform L2, posted16 and UV + relocated fast paths. No snapshots,
guest patches or STEP. Neither has a qualified gameplay or suite result yet.

Current-core direct model `3cde0281ae31b217b1915b2dbf2cadd241969a2efc7468297016533e30bd6273`
passes two short host-settle qualifications under
`ventium-pop-drain-coremark.9tka4Ty1/qualify-r{3,4}`. Both standard seed forms
have correct CRCs, identical clocks/retirements and byte-identical final model
and mapped memory with/without the host optimization. Fifteen unsafe host
configurations are rejected. These ten-iteration checks are **not full scores**.

Full seeds were not launched because measured host throughput (~189k clocks/s)
projects beyond the unchanged 60-minute cap. A matched cross-CPU diagnostic,
`ventium-current-host-check.5VOcWwjR`, gives the previous passing model and this
model the same 4,823,423-clock workload: both take 25.3–25.8 seconds, with
unchanged CRCs/retirements, ~99% CPU, zero major page faults or swaps and only
0.11 seconds aggregate cgroup throttling. This identifies shared host slowdown,
not a pop-drain clock-count regression; its underlying host cause remains open.
The earlier full 2.10736/2.11041 scores are not transferred to this model.

## Observed cause

A read-only host probe links each **unchanged** frozen RTL archive and logs
the settled signals immediately before each rising edge. Both functional and
cycle traces are byte-identical to their original executions, including all
retirements and exit. It modifies no registers, clocks, ready signals or memory.
Evidence: `external/tmp/ventium-fld-prime-probe.cJrMTJzy/closed.json`.

The unprimed FLD/FADDP fixture takes 23 clocks per four load/pop pairs plus
DEC/JNZ. Aggressively priming FLD made it **24**, despite removing a memory wait:
the earlier operand is queued behind an unfinished FADDP. Its eventual stack
push commits before the registered response, but popping arithmetic is excluded
from `fp_async_stream_shape`. It therefore waits for `fp_async_count` to become
zero on the following edge even when the leaf already has the committed state.

One recurring control sequence, sampled before the edge:

| Clock | Older work / leaf action | Following FADDP |
| --- | --- | --- |
| 2968 | Older FADDP commits; acquired FLD enters the ordered slot | Not yet at issue |
| 2969 | FLD pushes the stack; older arithmetic response is consumed | Held |
| 2970 | FLD response valid; leaf ready; only one owner remains | **Unnecessarily held** |
| 2971 | Owner count has drained to zero | Accepted |

This is response-accounting latency, not evidence that simultaneous push/pop
needs more RAM ports. Blindly speeding up operand acquisition does not solve it.

## Proposed fix, implemented in the private candidate

`prepare-fp-pop-drain.py` changes only `rtl/core/core_fp_async.svh`. It permits
the existing fast popping arithmetic descriptor on the **last registered
response** (`count == 1 && rsp_valid`), under the existing add/multiply/subtract,
masked-exception, ES, trap and protected-32-bit checks. The normal issue/debug/
event gates and the unchanged leaf `cmd_ready` still own acceptance.

The previous command's architectural mutation has already happened. The new
operation does not cross an unfinished stack mutation, forward speculative
TOP/tags, add a write port, replicate an ALU or alter response-owner accounting.
Ordinary count replacement handles a response and new asynchronous admission
on the same edge. Earlier pending owners, division, unmasked exceptions and
event/debug drains retain their existing behavior. The flag-off source is
whitespace-equivalent to the parent.

## Verification completed so far

Artifact root: `external/tmp/ventium-fp-pop-drain.85Kvxes9`.

- Four recipe guards pass: exact scope/default-off identity, unique anchors,
  reapplication rejection and private-copy preservation.
- `fixture-defaults/closed.json` reassembles all 24 old prime fixtures and
  confirms byte-identical images after adding the new optional parameters.
- Both core builds pass all six structural hard-error classes and verify the
  private host object/header dependency. Board-profile model:
  `0619fce4fe20a49a09bb9432bc5a4e8663cb8afa98c25d583618305d645135eb`;
  full-address user model:
  `be7cd43d76a8f720ec5abf34fde7ccdf781c181dc0909283447e3294dc473b4d`.
- Extracted **actual candidate** admission/hold equations pass 204 checks with
  the flag off/on: owner counts 0–4, response/no response, all eight operation
  selectors, each exception mask, ES/trap/context blockers, debug, events and
  invalid frontend. The first extraction attempt rejected alternate tie-off
  assignments before compiling; `unit-r1` is retained, corrected `unit-r2` is
  the passing run. This predicate unit is not a real-FPU timing proof.
- `matrix-r1`: 72 cold paged fixtures, two AXI latencies, two models, both
  functional and cycle modes: **288 complete QEMU architectural comparisons**
  and 288 cycle executions pass. Cases cover FLD32/FILD32/FILD64 with FADDP,
  FMULP, FSUBP and FSUBRP; flat/256-MiB-relocated code/data, aligned/byte-31
  instruction placement and control words 037f/077f/0e7f. Every run reaches
  its own result check/normal exit and contains a real U/V-pair witness.
- All 144 A/B latency/case comparisons are non-regressing. Resident m32
  load/pop loops improve **23→20 clocks** (13.04% fewer clocks; 15% throughput
  increase), or **24→21** at the other placement. FILD64 remains **24→24**.
  These are directed-loop results, **not gameplay or CoreMark gains**.
- The retained 19-fixture ordinary/system QEMU corpus passes **76 model/latency
  cases**, each in functional and cycle modes. No comparator masks or oracle
  states were changed.
- Canonical `make verify` was rerun on the new UV-fast/AXI user model:
  **FAIL**, native exit 2. It retains 7/108 functional passes (101 terminal
  trace-length failures) and the same five hard cycle-band failures:
  depadd 1.177 CPI, indepadd 0.682, dmiss 5.002, imiss 16.504, nearbr 0.589.
- With the separately qualified private QEMU exit observer, unchanged
  functional workers/comparator pass **106/108**, overall **FAIL**, just as
  for the parent. `mb_fxch` n923 retains FSW 0000/0041 and `tx_fprem` n300
  retains 0020/0320. Their existing masks are not extended. All input pins
  remain stable; the failure receipts are retained in
  `generic-user-r2-closed.json` and `functional-observer-r1/closed.json`.

Run under the repository's bounded build scope, with `TMPDIR` on external:

```sh
python3 -B verif/fe_pipe/prepare-fp-pop-drain.py --source FROZEN --out CANDIDATE
# Build matched private models, adding only +define+VEN_FP_POP_DRAIN.
python3 -B verif/fe_pipe/run-fp-pop-drain-unit.py --candidate CANDIDATE --out UNIT
python3 -B verif/fe_pipe/run-fp-pop-drain.py \
  --control CONTROL_TB --candidate CANDIDATE_TB --out MATRIX
```

The main matrix uses eight multi-threaded QEMU producers followed by 32
single-threaded RTL workers, keeping the 128-task resource cap intact.

## Remaining gates

The generic differential gate is still not closed; retain its known terminal
oracle and hard timing-band failures rather than weakening comparisons.
Full new-candidate CoreMark, Win95 desktop, complete Quake timedemo, gameplay
IPC, full FPGA resource/timing/route/deployment and target acceptance remain
open. No production profile or running guest was changed by this experiment.
