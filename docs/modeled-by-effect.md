# Ventium "Modeled by Effect" Inventory

This is the inventory requested in `REVIEW_Jun5.md` §5 / Action 1. It lists every
block currently implemented as **direct behavioral RTL** ("modeled by effect" —
the architectural result is correct, but the implementation is not a P54C-like
internal structure such as an SRT divider, a microcode ROM, or a real data
cache). Architecturally-correct vs QEMU; not transistor/microcode faithful.

Each row records: current implementation (file:line, grep-confirmed), expected
P54C structure, the observable fidelity gap (timing? architectural? none
visible?), and current test coverage. A prioritized list follows at the end,
timing/pairing-visible items first.

Distinction used throughout: **architectural gap** = a guest-visible wrong
result or missing exception (highest severity). **timing gap** = correct result
but the cycle count / pairing / occupancy does not match P54C. **none visible**
= effect-faithful with no architectural or timing evidence available to falsify.

---

## Inventory

### 1. Integer DIV / IDIV — native `/` and `%`, no `#DE`

- **Current impl:** `K_MULDIV` arm computes the quotient/remainder with native
  Verilog `/` and `%` in a single `S_EXEC` clock, for 8/16/32-bit forms
  (`rtl/core/core_exec.svh:247-284`, dispatched from `core.sv:1684`). No
  divisor-zero or quotient-overflow check. (The same `#DE` deferral applies to
  the just-added `AAM` base-0 case — guarded to 0 at `core.sv:2422-2423`.)
- **Expected P54C:** iterative SRT/radix divider occupying the U-pipe for the
  documented ~17 (8-bit) / ~25 (16-bit) / ~41 (32-bit) cycles, with `EDX:EAX`
  coupling and a real `#DE` (vector 0) fault on divide-by-zero or quotient
  overflow.
- **Fidelity gap:** **ARCHITECTURAL + TIMING.** (a) Architectural: `#DE` is
  **not raised** — a divide-by-zero currently does not fault (native `/` by 0 is
  undefined-but-non-faulting in this arm). (b) Timing: retires in one execute
  clock instead of the ~40-cycle non-pairable occupancy.
- **Coverage:** `verif/tests/t_div` (architectural result for non-zero
  divisors). No `#DE` test; no divide-occupancy microbenchmark.

### 2. Integer MUL / IMUL — native `*`

- **Current impl:** `K_MULDIV` (one-operand, `core_exec.svh:218-246`) and
  `K_IMUL2` (two/three-operand, `core_exec.svh:287-303`) compute the product
  with native `*` / `$signed`*`$signed` in a single `S_EXEC` clock. CF/OF
  overflow flags match QEMU `compute_all_mul`.
- **Expected P54C:** staged multiply occupying the U-pipe for the documented
  ~10/11-cycle latency, U-pipe-only serialization, and the correct dependency
  behavior against a following dependent op.
- **Fidelity gap:** **TIMING.** Result and flags correct; the visible
  multi-cycle U-pipe occupancy and serialization are not modeled (retires in one
  execute clock).
- **Coverage:** `verif/tests/t_mul` (architectural result + flags). No
  multiply-occupancy microbenchmark.

### 3. String ops (MOVS/STOS/LODS/SCAS/CMPS/INS) and REP

- **Current impl:** `K_STR` decode (`core.sv:1561-1568`, INS `1586`); each
  element runs through the `S_LOAD`/`S_STORE` path and REP iterates by holding
  the PC fixed and looping in `S_USEQ` (`core.sv:16`, `core_exec.svh:486`,
  `core_store_useq.svh:130`).
- **Expected P54C:** microcoded string engine with the documented per-iteration
  cycle cost, fast-string optimizations, and the REP startup/steady-state cycle
  profile.
- **Fidelity gap:** **TIMING** (per-element/REP cycle profile is the
  effect-loop, not the microcoded P5 profile). Architecturally correct,
  including DF direction and partial-register element widths.
- **Coverage:** `verif/tests/t_string`, `t_rep` (architectural). No REP cycle
  microbenchmark.

### 4. PUSHA / POPA / PUSHF / POPF — `S_USEQ` micro-loop

- **Current impl:** `K_STKMISC` with `SM_PUSHA/SM_POPA/SM_PUSHF/SM_POPF`
  (`core.sv:1311-1312,1500-1501`); PUSHA/POPA hand off to an 8-word transfer
  loop in `S_USEQ` (`core_exec.svh:479`, `core_store_useq.svh:129-132`).
- **Expected P54C:** these are microcoded stack sequences; the effect-loop
  reproduces the 8 transfers but is not the original micro-op sequencing.
- **Fidelity gap:** **TIMING** (sequence cycle count vs documented microcode).
  Architecturally correct (register order, ESP handling).
- **Coverage:** `verif/tests/t_stack` (architectural). No PUSHA/POPA cycle
  microbenchmark.

### 5. CALL / RET (near, rel and indirect)

- **Current impl:** `K_CTRL` with `CT_CALLREL`/`CT_CALLIND`/`CT_RETN`/
  `CT_RETN_IMM` (`core.sv:1702-1703,1737`; exec `core_exec.svh:537-555`,
  store/push `core_store_useq.svh:53`). CALL stores the return EIP via the
  store path; RET pops it via the load path.
- **Expected P54C:** microcoded control-flow with the documented push/pop
  sequencing, the return-stack-buffer prediction interaction, and the proper
  cycle/pairing profile.
- **Fidelity gap:** **TIMING** (sequencing/pairing cycle profile). Far CALL to a
  TSS is the hardware-task-switch path (row 7), separate from near CALL/RET.
  Architecturally correct.
- **Coverage:** `verif/tests/t_callret` (architectural). No CALL/RET cycle
  microbenchmark.

### 6. x87 arithmetic slow-path helpers (`f_eval` etc.)

- **Current impl:** all x87 arithmetic (FADD/FSUB/FMUL/FDIV/FSQRT and compares)
  evaluates the result through the `fpu_x87_pkg` software helpers
  (`f_eval`/`f_arith`/`f_div_by_zero`...) in the FP exec path
  (`core.sv:4044,4155-4172`; `rtl/core/core_fp_exec.svh:18`). The datapath is
  bit-exact only for normal/zero operands at default precision
  (`rtl/fpu/fpu_x87_pkg.sv:3-22`).
- **Expected P54C:** the pipelined FADD/FMUL units and the iterative FDIV (the
  unit whose lookup-table defect is Erratum 23) with documented FP latencies and
  the FXCH-pairing behavior.
- **Fidelity gap:** **ARCHITECTURAL (bounded) + TIMING.** Architectural: Inf /
  NaN / denormal / non-default RC-PC operands are out of the helper's exact
  range and **HALT** rather than execute (see `docs/isa-coverage.md` x87 gaps) —
  loud, not silent. Timing: FP latency/throughput is modeled by the M5 FP
  scoreboard cycle bands, not by structural FP pipelines. (The FDIV Erratum 23
  defect IS reproducible behind `errata_en[ERR_FDIV]`, `core.sv:526,4044`.)
- **Coverage:** `verif/tests/tx_*` (addsub, muldiv, sqrt, cmp, round, special,
  ...) architectural; `mb_faddchain`, `mb_fpindep`, `mb_fpocc` cycle bands.

### 7. Hardware task switch — `S_TSW_*` microsequence

- **Current impl:** far JMP/CALL to a TSS runs a behavioral micro-sequence:
  `S_TSW_SAVE` (write outgoing state to current TSS) → `S_TSW_READ` (load
  incoming) → `S_TSW_SEG` (reload hidden descriptors) → `S_TSW_BUSY` (toggle
  busy bits) (`core.sv:575-589`, `rtl/core/core_tsw.svh:5-18`).
- **Expected P54C:** the (microcoded) task-switch sequence with the full
  documented cycle cost and ordering.
- **Fidelity gap:** **TIMING** (sequence is correctness-shaped, beat-by-beat,
  not P5 microcode-cycle-accurate). Architecturally exercised by the `ptask`
  system gate; it is a one-way switch (noted in `core.sv:586`).
- **Coverage:** `verif/sys/tests` `ptask` (structural/architectural). No cycle
  band.

### 8. SMM entry / RSM — `S_SMI_SAVE` / `S_RSM` microsequence

- **Current impl:** SMI# entry writes the P5 save-state map to SMRAM and RSM
  reads it back and commits, via behavioral beat-mapped sequences
  (`core.sv:591-598`, `rtl/core/core_smm.svh:5-6,31,65`). Some hidden-state
  slots are explicitly DONE-PARTIAL / not in the save/restore beat list
  (`core.sv:342`).
- **Expected P54C:** the microcoded SMI save / RSM restore with the full
  documented SMRAM layout and cycle cost.
- **Fidelity gap:** **ARCHITECTURAL (bounded) + TIMING.** Architectural: a
  documented subset of hidden state is not saved/restored (`core.sv:342`);
  timing is not cycle-accurate. Structurally covered by `psmm`.
- **Coverage:** `verif/sys/tests` `psmm` (structural). No cycle band.

### 9. Page-table walk — `S_WALK` microsequence

- **Current impl:** on a TLB miss the 2-level walk (read PDE → write A; read PTE
  → write A/D; fill TLB; `#PF` decision/CR2/error-code) is a behavioral
  micro-sequence kept in the core spine (`core.sv:464,479`,
  `rtl/core/core_walk.svh:5-6,17`).
- **Expected P54C:** the hardware page-walk state machine with the documented
  walk cycle cost and the actual TLB-fill timing.
- **Fidelity gap:** **TIMING** (walk is correctness-shaped; the per-walk cycle
  cost is not a modeled P5 walk profile). Architecturally correct (A/D bits,
  fault generation).
- **Coverage:** `verif/sys/tests` `ppage`, `pfault` (architectural). No
  walk-cycle band.

### 10. D-cache — TIMING-only model (no data array)

- **Current impl:** `rtl/mem/dcache_timing.sv:1-19` — tracks tag/valid/LRU only;
  **there is no data array**, load data still comes from the memory model. It
  decides only WHEN a load completes (read-miss adds `dmiss`, misaligned `+3`).
- **Expected P54C:** an 8 KB / 2-way / 32 B-line / 128-set write-back D-cache
  with a real data array, MESI states, write buffers, and store/load corner
  behavior.
- **Fidelity gap:** **TIMING-faithful by design; NOT structural.** No MESI,
  writeback, or write-buffer behavior; data correctness comes from the backing
  memory, not the cache. Per `REVIEW_Jun5.md` §3 this should be labeled a timing
  model everywhere.
- **Coverage:** `verif/tests` `mb_dmiss`, `mb_dstore` (hit/miss timing bands).

### 11. TLB — correctness model (16-entry direct-mapped, split I/D)

- **Current impl:** `rtl/mem/tlb.sv:1-11` — a 16-entry direct-mapped TLB per
  side (I/D) indexed by `lin[15:12]`; holds arrays + combinational lookup +
  pulsed fill/flush. The walk FSM stays in the spine (row 9).
- **Expected P54C:** the documented Pentium TLB organization (set-associative,
  separate sizes for I/D, the 4K/4M structure) — this 16-entry direct-mapped
  array is a correctness model, not that structure.
- **Fidelity gap:** **STRUCTURAL** (organization differs from P54C; not a timing
  claim). Functionally correct for translation/flush.
- **Coverage:** `verif/sys/tests` `ppage`, `pfault` (translation correctness).

### 12. Integrated BIU — protocol exerciser, not a faithful memory path

- **Current impl:** `rtl/bus/biu.sv:25-40,54-62` — the integrated `biu_p5` is a
  protocol exerciser; the core consumes combinational back-side memory data
  independent of the BIU, and the pin address is not guaranteed to match the
  `d_in` data. Integrated traffic is single, non-burst, non-pipelined only.
- **Expected P54C:** a real external bus path where the core's loads/stores
  flow through the BIU with burst, pipelined, locked, snoop, backoff, and
  arbitration behavior.
- **Fidelity gap:** **STRUCTURAL / pin-level** (data path does not flow through
  the bus). Burst/pipelined/locked/snoop/backoff/arbitration are
  standalone-validated only.
- **Coverage:** `verif/bus` standalone `biu_p5` (76 directed checks + SVA);
  integrated path is not a faithful memory path. (This block is owned/edited by
  the orchestrator; listed here only for inventory completeness.)

---

## Prioritized list (highest observable impact first)

Ordered by `REVIEW_Jun5.md` Action 2: architectural gaps and timing/pairing-
visible gaps first; purely internal structure with no falsifiable evidence last.

1. **DIV / IDIV (`#DE` + ~40-cycle occupancy)** — row 1. *Architectural*
   (missing divide-by-zero/overflow `#DE`) **and** the largest timing gap
   (~40x: one execute clock vs ~40-cycle non-pairable occupancy). Highest
   priority on both axes.
2. **MUL / IMUL (~10-11 cycle staged occupancy)** — row 2. Timing-visible
   U-pipe-only serialization (~10x). Native `*` may remain as the internal
   primitive; the visible instruction should occupy the pipe.
3. **String / REP cycle profile** — row 3. Timing-visible per-element and REP
   startup/steady-state cost; pairing-relevant.
4. **PUSHA/POPA/PUSHF/POPF and CALL/RET sequencing** — rows 4, 5. Microcoded
   stack/control-flow cycle + pairing profile; move out of the effect-loop into
   an explicit micro-op sequencer.
5. **x87 slow-path (Inf/NaN/denormal exactness + FP latencies)** — row 6.
   Architectural boundary is currently a loud HALT (acceptable); FP
   latency/throughput is band-modeled, not structural. Medium priority.
6. **Task-switch / SMM / page-walk cycle accuracy** — rows 7, 8, 9.
   System-visible but rarely on a hot timing path; architecturally covered by
   the system gates. Lower timing priority. (SMM has a bounded architectural
   hidden-state gap at `core.sv:342`.)
7. **D-cache data/MESI/writeback and a P54C-shaped TLB** — rows 10, 11.
   Deliberate timing/correctness models; promote to structural only if
   structural fidelity is the chosen goal (`REVIEW_Jun5.md` §3). Otherwise label
   as timing/correctness models everywhere — no architectural gap today.
8. **Integrated BIU faithful memory path** — row 12. Pin-level structural;
   biggest pin-level caveat but standalone-validated and orchestrator-owned.
   Lowest priority for *this* inventory's ISA/timing focus.
