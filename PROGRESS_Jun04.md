# Ventium — progress snapshot (2026-06-04)

Dated progress record opened 2026-06-04. The full historical log stays in
[`PROGRESS.md`](PROGRESS.md); this file records the state at the close of the
planned roadmap and the continuing **R2 leaf-module-extraction** refactor.

## Roadmap status — COMPLETE (all planned milestones done)

| Milestone | What | Gate | Status |
|---|---|---|---|
| M0 | Bootstrap: QEMU golden-trace oracle, trace format, Verilator TB, comparator | comparator end-to-end | ✅ |
| M1 | Decoder + single-issue integer functional | integer subset diff-clean vs QEMU | ✅ |
| M2 | User-mode integer ISA completeness | broad integer corpus diff-clean | ✅ |
| M2S.0 | System-mode oracle + harness (qemu-system-i386, gen_trace --system) | sys golden round-trips | ✅ |
| M2S.1 | Real→protected mode + segmentation (dual boot_mode) | `pseg` RTL sys-diff (70) | ✅ done-partial |
| M2S.2 | 2-level paging MMU + split I/D TLBs + A/D + #PF decision | `pmode`(1084)/`ppage`(128) | ✅ done-partial |
| M2S.3 | IDT-delivered interrupts/exceptions + IRET | `pintr`(171)/`pfault`(348) | ✅ done-partial |
| M2S.4 | TSS + cross-priv delivery + inter-priv IRET | `pcpl`(304); `ptask` self-diff | ✅ done-partial |
| M2S.5 | SMM / RSM (partial oracle) | `psmm` structural self-check | ✅ done-partial |
| M2S.6 | Debug registers DR0–DR7 + `#DB` (last system stage) | `pdebug` RTL sys-diff (239) | ✅ done-partial |
| M3 | x87 FPU | x87 corpus diff-clean | ✅ |
| M4 | Dual-issue U/V + pairing + branch prediction | µbench bands match p5model | ✅ |
| M5 | Cache-cycle + FP-cycle accuracy | FP/cache bands track p5model | ✅ |
| M5B | Pin-level 64-bit bus protocol (standalone) | structural + SVA (no oracle) | ✅ standalone |
| M6 | Errata & stepping fidelity (stretch) | targeted errata behind a flag | ✅ partial |
| R1 | RTL modularization + fast gate (`make verify` ~2 s) | all m1–m5 + sys stay green | ✅ |

**Verification at this snapshot (independently re-run 2026-06-04):** `make verify`
(user) GREEN — 56/56 func diff-clean + all M4/M5 cycle bands; all 6 differential
system gates EQUIVALENT (pseg 70 / pmode 1084 / ppage 128 / pintr 171 / pfault 348 /
pcpl 304); `ptask` self-diff (292) + `psmm` structural OK; verilator lint clean.
Latest commit `2a00d06` (M2S.6) pushed to `origin/main`.

## Deferred, no-oracle tracks (carried, not auto-started)

- **R2 — leaf-module extraction** (this file's active work; the R1 deferral). Carve
  the leaf blocks (icache / dcache / tlb / regfile / fpu-state / btb) out of the
  `core.sv` spine into their own modules, **behavior-preserving** (gate-proven
  bit-exact after every step). R1 left these in because they are entangled with the
  shared pipeline FSM; R2 extracts what is mechanically separable and documents what
  must stay in the spine, and why.
- **M5B-int** — wire the standalone pin-level bus into `rtl/` (would change M5 cycle
  timing; no bus oracle to re-verify).
- **Full hardware task switch** (`ptask` differential) — the gnarliest M2S.4 piece.
- **M6 system-errata family** (BTB-flush / SMM / APIC / DP) — reachable now, but most
  lack a differential oracle.

---

## R2 — leaf-module extraction (IN PROGRESS, opened 2026-06-04)

**Goal.** Reduce the `rtl/core/core.sv` monolith by extracting the leaf blocks into
their own modules with clean port interfaces, **without changing behavior** — the
differential gate (`make verify` user GREEN + all sys gates EQUIVALENT + lint clean)
must hold after EVERY extraction. Replace the stub files `rtl/mem/icache.sv`,
`rtl/mem/dcache.sv`, `rtl/mem/tlb.sv` (and add `rtl/core/regfile.sv` / btb / fpu-state
as feasible) with the real extracted logic. The invariant is bit-exactness: any
extraction that cannot be made bit-exact is reverted and documented as spine-bound.

**Plan.**
1. Analysis (read-only): map each leaf's state + every core.sv touch-point + an
   extractability ranking + a proposed module interface.
2. Extract leaves one at a time, easiest/most-separable first, gate-verifying after
   each (revert-rather-than-regress).
3. Adversarial review (behavior-equivalence focus) + independent full-gate re-run.
4. Commit + push.

**Status:** ✅ done — 4 of 6 leaves extracted (the 4 with a single write port);
regfile + fpu-state proven spine-bound and left inline (honest).

### R2 outcome

A read-only analysis fan-out ranked each leaf by *write-port* structure (the
extraction discriminant): a leaf with **one** state-mutating transaction per clock
extracts bit-exact behind a single funnelled port; a leaf needing **two**
simultaneous writes needs an FSM restructure, not a lift. Then each extractable
leaf was lifted one at a time, **full gate after every step**, commit-on-green.

**Extracted (behavior-preserving, gate-verified bit-exact):**
- `rtl/mem/dcache_timing.sv` (74 L) — the D-cache timing model (`dc_tag/dc_val/dc_lru`):
  comb `lu_addr→lu_hit` off the registered arrays (pre-access, NBA-correct) + a single
  posedge access port. Commit `ed573c3`.
- `rtl/core/bpred_btb.sv` (115 L) — the BTB + 2-bit predictor (4 arrays): two comb
  predict ports (U/V) + one synchronous update transaction. Commit `f782700`.
- `rtl/mem/tlb.sv` (134 L) — ONE parameterized `tlb #(IS_D)` instantiated **twice**
  (`u_itlb`/`u_dtlb`): comb lookup + pulsed fill-commit (driven from the spine S_WALK)
  + CR3-flush (val-bits only). The page-walk FSM stays in the spine. Commit `544a365`.
- `rtl/mem/icache.sv` (150 L) — the functional I-cache (`ic_data/ic_tag/ic_val/ic_lru`):
  per-word fill + fill-complete MRU + 3 mutually-exclusive LRU-touch ports (U/straddle/V,
  last-write-wins order preserved), arrays exposed read-only so the spine keeps its
  `ic_present/ic_byte` probes verbatim; victim picked in-spine from pre-edge LRU. Commit
  `6bb98ea`.

**Left in the spine (proven spine-bound — honest):**
- **regfile `gpr[8]`** — 88 write statements; CONFIRMED 2-writes/clock (dual-issue U+V,
  XCHG, MUL/DIV EAX+EDX, CDQ/CWD, POP/LEAVE dst+ESP). Bit-exact extraction needs a
  2-write-port mux + re-routing all 88 arms = an FSM restructure, not a lift.
- **fpu-state** (`fpr/ftop/fstat/fptag` + the M5 scoreboard) — written from two
  runtime-exclusive FSM arms; `FNSTSW AX` writes `gpr[EAX]` from inside the x87 case
  (cross-leaf into the regfile); the scoreboard is braided into the integer cycle model.
  Needs an FSM rewrite. The pure x87 datapath already lives in `fpu_x87_pkg.sv`.

**Honest note on size:** the leaf *logic* moved into 473 lines of self-contained,
separately-readable modules, but `core.sv` did **not** shrink (5741 → 5990) — the
port-wiring + combinational drivers + comments for the small/timing leaves exceed the
inline logic removed. The win is **separation + testability + clear interfaces**
(each leaf now has a documented port boundary), not raw line reduction. Behavior is
bit-exact: this is verified, not asserted.

**Verification (independently re-run on the final HEAD `6bb98ea`):** `make verify`
(user) PASS (56/56 func + all M4/M5 cycle bands — cache/BTB-sensitive bands clean:
dmiss +0.10%, imiss +0.14%, brloop 7/3004 mispred, brrandom 251/400); all **9** sys
gates green (pseg 70 / pmode 1084 / ppage 128 / pintr 171 / pfault 348 / pcpl 304 /
pdebug 239 RTL `--system` EQUIVALENT; ptask self-diff; psmm structural); verilator
lint clean (0 warn/err). Adversarial review verdict: GENUINE + behavior-preserving
(one cosmetic INFO: an unread `itlb_lk_perm[2:1]` slice, waived by `-Wno-UNUSED`).

### R2 log

- 2026-06-04 — R2 opened; roadmap snapshot recorded; leaf analysis launched.
- 2026-06-04 — R2 done: dcache_timing/bpred_btb/tlb(×2)/icache extracted bit-exact
  (`ed573c3`/`f782700`/`544a365`/`6bb98ea`); regfile + fpu-state documented spine-bound.

## M7 — macro-workload lock-step (Quake + Win95) — OPENED 2026-06-04

Per user direction (Quake via QEMU-proxied syscalls; Win95 via a real system
co-sim built now — V86 + co-sim bus; **run each as far as feasible**). Architecture
in [`docs/m7-lockstep-spec.md`](docs/m7-lockstep-spec.md): **input-replay lock-step**
— QEMU is the golden + environment, the RTL is the checked CPU, the trace carries
arch state + the environment inputs each instruction consumed (syscall effects for
Quake; device-read values + delivered interrupts for Win95), the TB replays those
inputs, and the comparator grades only the CPU. Stages: M7.0 oracle/contract +
de-risk (running) → M7.1 Quake (ELF loader + int-0x80 proxy) → M7.2 V86 mode →
M7.3 Win95 device-input replay + boot-prefix run.

### M7 log

- 2026-06-04 — M7 opened; spec written; M7.0 oracle de-risk launched (Quake syscall
  capture / Win95 device+interrupt capture / throughput / V86 scope).
- 2026-06-04 — **M7.0 de-risk DONE.** Verdicts:
  - **Quake: GO.** `int 0x80` is dispatched inside QEMU's host `cpu_loop` (not as
    stepped guest code), so ONE RSP `s` over a syscall site runs the whole kernel
    emulation — the post-step `g`-packet already has `eax=ret` AND every kernel
    memory write applied. Capture: read 2 bytes at EIP (`==cd80`, catches the
    musl/vDSO `__kernel_vsyscall` stub a static-site set would miss), snapshot
    nr+args, step, read `ret`=eax + the kernel-written region via RSP `m`+diff per a
    per-nr dispatch table. Proven: 38 syscalls in exact `-strace` order; all 3
    write classes (zero-fill anon `mmap2` 32 MB zone, struct-fill `clock_gettime64`,
    read-buffer `readv` → `pak0.pak` 'PACK' magic). Deterministic via `-seed` +
    static no-PIE EXEC. No qemu hook/plugin needed.
  - **Win95: PARTIAL-GO.** All 3 input classes (PIO/MMIO read VALUE via the dest GPR;
    interrupt VECTOR+BOUNDARY) capturable over the same gdbstub — but ONLY under
    **record/replay** (`rr=record`→`rr=replay` + blkreplay COW overlay + drop
    `-rtc base=localtime`), because plain `-icount` diverges at the first RTC read.
    rr=replay is bit-identical across runs (33,511 ints / 2,232,434 reads identical
    twice). Full boot is throughput-deferred.
  - **V86: GO (lands 100%).** Method-1 (VME-off) subset — `v86=sys_mode&eflags[17]`,
    IOPL guards (`CLI/STI/PUSHF/POPF/INT n/IRET/IN/OUT`→`#GP` when `iopl<3`), sel<<4
    seg bases + forced CPL3 + the 9-word V86 exception frame. A closed ~400-insn
    bare-metal gate, fully oracled by the existing sys contract.
  - **Throughput (the binding limit):** RTL ~95k insns/s; gdbstub oracle was ~12
    insns/s (latency-bound RSP), **fixed ~300–600× by adding `TCP_NODELAY`** to the
    RSP socket (this commit) → ~10k insns/s. Feasible prefixes: Quake overnight
    ~hundreds-of-k–few-M insns (covers full process init + the 38-syscall surface;
    a full frame in a multi-hour window; a full timedemo is OFF the table); Win95 a
    bounded boot prefix. **The harness is architecturally complete; the RUN is
    throughput-capped — bounded honestly, never faked.**
  - Enabler landed: `gen_trace.py` `TCP_NODELAY` (speed-only; every existing golden
    bit-identical — pseg re-verified EQUIVALENT). Next: M7.1 (Quake harness:
    producer int-0x80 proxy + TB ELF/process-image loader + int-0x80 proxy).
- 2026-06-04 — **M7.1 DONE: Quake lock-step is BIT-EXACT over a 30k-insn prefix.**
  The full input-replay harness works end-to-end and grades only the CPU:
  - **Producer** (`gen_trace.py --syscall-proxy` + `tracefmt.py` `sys_call` field):
    single-steps `tyr-quake-p5` under `qemu-i386 -seed 1234`, captures each int-0x80
    effect (eax=ret + kernel memory writes via the per-nr dispatch table; `%gs` TLS
    base from `set_thread_area`) and the initial process image (PT_LOAD + stack +
    vDSO stub). 9 syscalls captured in the prefix.
  - **Consumer** (TB `quake_image.cpp` loader + the int-0x80 proxy + a `proxy_en`-gated
    user-mode `%gs` base in `core.sv`/`ventium_top.sv`): loads QEMU's process image,
    replays each `sys_call` effect at the int-0x80 boundary (writes→bus, eax+gs→core),
    runs the RTL as the checked CPU. The proxy injects ONLY the kernel environment
    effect — never CPU-computed state (review-audited HONEST).
  - **Result: 30,000 / 30,000 records EQUIVALENT** (`compare.py` exit 0), independently
    re-run from a clean TB rebuild + a fresh trace. Negative controls (corrupt eax/
    ebx/gs, truncate) all correctly DIVERGENT — the grade is real. All 9 int-0x80
    boundaries + the `%gs` 0x2b→0x33 TLS transition (correct for 28,551 records) match.
  - **2 genuine ISA gaps found + fixed** (the payoff of a macro-workload): `TEST r/m,imm`
    memory form (`F6/F7 /0,/1` mod≠11) and the operand-segment base for an indirect
    `call gs:[0x10]` under a segment override — both forms the M1–M6 corpus never hit,
    fixed additively + differentially re-validated by the lock-step.
  - ADDITIVE: `make verify` GREEN (56/56 goldens byte-identical), all 9 sys gates
    EQUIVALENT, lint clean — the proxy/`%gs` path is inert without `--quake-image`.
  - Reproducer: `verif/m7/run-quake-lockstep.sh [N] [PORT]`. The run length is
    oracle-bound (gdbstub ~10k insn/s); a longer background prefix follows.
- 2026-06-05 — **M7.1 LONGEST-RUN: Quake bit-exact to 1,106,162 instructions, then
  a named ISA wall.** Ran a ~9.6M-record background golden (timeout-bounded) and the
  RTL lock-step against it via a new O(1)-memory streaming comparator
  (`verif/diff/compare_stream.py`, reuses compare.py's exact func+eflags grading;
  24 MB RSS for 9.6M records vs compare.py loading all into RAM). Result: **1,106,162
  instructions EQUIVALENT** (independently streamed; the 1M cross-check matches
  compare.py; corrupt control DIVERGENT) — then the RTL HALTed (went quiescent) on
  the instruction at n=1106162, pc=0x080a7810, bytes `f0 0f b1 97 f4 33 00 00` =
  **`LOCK CMPXCHG dword ptr [edi+0x33f4], edx`** — `CMPXCHG` (0F B1) with a memory
  operand, undecoded by the core (musl's atomic/lock path). A genuine, precisely-
  named coverage gap — the **3rd** ISA gap the Quake macro-workload has surfaced
  (after `TEST r/m,imm` mem-form + the `call gs:[]` operand segment in M7.1). The
  run went as far as the RTL's ISA coverage allows; the wall is real, not a harness
  artifact (everything before it is bit-exact). Next: implement `CMPXCHG` (0F B0/B1)
  to push the frontier (it also benefits Win95).
- 2026-06-05 — **CMPXCHG (0F B0/B1) implemented + the Quake frontier is now a HARNESS
  time-boundary, not a CPU gap.** Added `CMPXCHG r/m8,r8` + `r/m16/32,r16/32` (reg +
  mem forms, all widths, LOCK=no-op on the in-order core) as a new `K_CMPXCHG` slow-FSM
  RMW: flags = `CMP acc,temp`; equal⇒dest←src, ZF=1; not-equal⇒acc←temp, ZF=0 (mem
  written back unchanged for atomicity, matching QEMU). The equality decision is latched
  (`cmpxchg_wrsrc_r`) across S_EXEC→S_STORE so the not-equal acc update can't corrupt the
  store-data resolver. **Validated:** targeted differential test `verif/tests/t_cmpxchg`
  EQUIVALENT vs QEMU (both opcodes, reg+mem, equal+not-equal, 8/16/32-bit, LOCK form);
  `make verify` PASS **57/57**; the Quake lock-step now **passes the old wall at
  n=1106162** (the `lock cmpxchg [edi+0x33f4],edx` executes bit-exact) and runs the full
  1.2M instructions. The next divergence (n≈1,106,793, `mov ecx,[esp+0x18]`) is **NOT a
  CPU bug**: it reads `tv_nsec` from a **vDSO `__vdso_clock_gettime`** result — the vDSO
  reads the kernel vvar time page directly in userspace (no syscall, so the proxy can't
  replay it), and host wall-clock advances between golden-gen and the RTL run (tv_sec
  matched, tv_nsec didn't). So the Quake user-mode frontier is now bounded by **vDSO
  clock nondeterminism** (the documented harness time class), with the CPU proven
  **bit-exact over ~1.106M instructions** of real Quake code. Pushing further would
  require replaying the vvar-page reads as inputs (a harness feature, diminishing
  CPU-verification returns) — deferred. Lint clean; sys gates green.
- 2026-06-05 — **M7.2 DONE: VIRTUAL-8086 mode (method-1 / VME-OFF) RTL-diffs
  EQUIVALENT 949/949.** The `pv86` bare-metal gate boots real→protected→paging→TSS,
  ENTERS V86 by an IRET of a 9-word V86 frame (EFLAGS.VM 0→1, CPL 0→3, sel<<4 seg
  bases, paging still live), exercises V86 sel<<4 segmentation, and routes 6 IOPL-
  sensitive ops (CLI/STI/PUSHF/POPF/INT 0x21/INT 0x20 at IOPL=0) as `#GP(0)` to the
  CPL0 monitor, each pushing the 9-word V86 frame on TSS.SS0:ESP0 with VM cleared +
  DS/ES/FS/GS zeroed, then IRETing back into V86.
  - **What landed (RTL delta in `rtl/core/core.sv`, all gated behind
    `v86=sys_mode&&eflags[17]` so it is INERT when EFLAGS.VM=0):** (a) `v86`/`iopl`/
    `seg_real`/`eff_cpl` signals (`eff_cpl` feeds the #PF US-bit + perm_fault);
    (b) MOV-sreg + far-jump `sel<<4` bases under `seg_real` (no GDT read); (c) the
    IOPL guard at `S_DECODE` → `#GP(0)` to the monitor for CLI/STI/PUSHF/POPF/INT n/
    IRET when `iopl<3`; (d) the 9-word V86 frame in `S_INT_PUSH` (`from_v86`: push
    GS..EIP+errcode, clear VM, zero DS/ES/FS/GS) reusing the `xpl_active` TSS switch +
    the cross-priv decision via `eff_cpl`, and `S_IRET` return-into-V86 (popped
    EFLAGS.VM=1 from CPL0 → 9-word pop, force CPL3, sel<<4 bases). `int_step` widened
    3→4 bits for the 10-beat push. Two corpus-surfaced fidelity fixes (additive):
    MOV-moffs A0–A3 width now follows `eff_addr` (16-bit moffs under V86/real); the
    `pv86.ld` `.reset` LMA pinned with `AT()` so the reset `ljmp` is not truncated
    (golden regenerated 956→949).
  - **M7.2 review finding applied (robustness, no functional change):** in `S_INT_CS`
    the `from_v86` latch is now gated on the SAME cross-priv predicate that loads
    `int_new_esp`/SS from the TSS — `from_v86 <= v86 && (tgt_dpl < eff_cpl)` (was
    `from_v86 <= v86`). A correct V86 monitor's IDT gate always targets a CPL0
    handler (`tgt_dpl<eff_cpl=3`), so this is a no-op for every valid delivery (the
    corpus stays 949/949). It closes the latent path where a malformed V86 gate to a
    DPL3 target would take the same-priv push arm yet still set `from_v86=1`, emitting
    the 9-word frame off a never-loaded `int_new_esp`/SS base. Pure hardening.
  - **pv86 gate record (re-run from a fresh TB build + fresh deterministic golden,
    PORT 53310):** golden 949 records; step-5e V86 validation VALID (V86 entry VM 0→1
    + CPL 0→3 + PG live at n=692; 6 IOPL-sensitive `#GP` deliveries to the CPL0
    monitor with the TSS stack switch + VM cleared at n=698/736/777/820/865/903; IRET
    back into V86 VM 0→1 at n=735/776/819/864/902); step-6 self-diff EQUIVALENT;
    **step-7 RTL --system diff EQUIVALENT 949/949** (`compare.py` exit 0, cr0..cr4 +
    selectors + GPRs + eflags + eip). Success proof matched: ecx=0x6 (6 deliveries),
    eax=0x1 (CLI count), ebx=0x02010101, edx=0x20→0xf4, esi=0xcafebabe (V86 sel<<4
    sentinel read back from linear 0x20000). The negative control (corrupt esi
    sentinel) is correctly DIVERGENT, so the grade is real; the golden is
    deterministic/byte-identical across regen.
  - **ADDITIVE proof (independently re-run 2026-06-05):** `make verify` GREEN +
    bit-identical (56/56 func goldens, 0 regenerated; all M4 integer bands + M5 FP/
    cache bands met). All 7 differential sys gates stay EQUIVALENT — pseg 70 / pmode
    1084 / ppage 128 / pintr 171 / pfault 348 / pcpl 304 / pdebug 239 — and the
    structural gates stay green (ptask SELF-DIFF-OK + task-switch VALID, psmm
    SMM-PARTIAL-OK). Lint clean (`verilator --lint-only -Wall -Wno-UNUSED` → 0
    warn/err; the `int_step` 3→4 widening is width-clean). The V86 path is fully
    inert without EFLAGS.VM=1, so the user gate is unaffected. Harness: `pv86` is in
    `RTL_SYS_TESTS` in `run-sys-golden.sh` + a `PORT=53220 pv86` line in the
    `verify-sys` Makefile target.
  - **Deferred (out of scope per the brief, documented follow-on):** VME/VIF/VIP +
    the interrupt-redirection bitmap (method-2). INT3 (0xCC) and INTO (0xCE) are not
    IOPL-trapped under V86 (distinct #BP/#OF V86 semantics, never exercised by the
    corpus — un-oracled, documented in-code). IN/OUT IOPL trapping is not wired
    because this core does not decode the IN/OUT opcodes at all (no oracle in the
    corpus; the V86 task uses CLI/STI/PUSHF/POPF/INT n) — documented in the IOPL-guard
    comment + manifest. The non-V86 #DF nesting / SS-RPL revalidation deferrals from
    M2S.4 are unchanged (pre-existing, not touched).
  - Reproducer: `PORT=53xxx bash verif/sys/run-sys-golden.sh pv86`. The `pv86` test
    dir is the Corpus-phase deliverable (currently git-untracked); `ventium-refs/`
    untouched (read-only).
