# Ventium — progress log

Living status for the P5/P54C Verilog replica. Plan: [`PLAN.md`](PLAN.md).
Newest entries at the top. Dates are ISO (YYYY-MM-DD).

## Status at a glance

| Milestone | Description | Gate | Status |
|---|---|---|---|
| **M0** | Bootstrap: repo skeleton, QEMU golden-trace plugin, trace format, Verilator TB shell, comparator | comparator runs end-to-end on trivial trace | ✅ done (infrastructure proven; RTL still a NOP stub) |
| M1 | Decoder + single-issue integer functional | integer subset diff-clean vs QEMU (decoder-exhaustive vs XED/Capstone is ongoing toward M2) | ✅ done (integer SUBSET func-equiv vs QEMU on smoke + M1 corpus; not yet decoder-exhaustive) |
| M2 | User-mode integer ISA completeness (re-scoped; system mode → M2S) | broad integer-ISA corpus diff-clean vs QEMU (user-mode) | ✅ done (28-program corpus func-equiv vs QEMU user-mode; system ops / far CALL-RET / ENTER / mem-operand bit-string + SHLD deferred & HALT; decoder-exhaustive-vs-XED still ongoing) |
| M2S.0 | System-mode ORACLE + harness (qemu-system-i386, gen_trace --system, bare-metal flow, `make verify-sys`) | system golden round-trips + sys-field compare path | ✅ done (qemu-system-i386 built; sys .vtrace = cr0..cr4 + 6 selectors + GPRs + eflags + eip; comparator sys-field intersect path) |
| M2S.1 | Real→protected mode + protected-mode SEGMENTATION (dual `boot_mode`) | `pseg` RTL sys-diff-clean vs qemu-system golden; `make verify` (user) GREEN | ✅ done-partial (cold reset + real mode + real→PM transition + flat & based GDT segment loads = RTL EQUIVALENT to the golden, 70 records; descriptor protection DECISION computed (present/type/DPL/limit, CPL=CS.RPL) but fault DELIVERY = M2S.3; 16-bit reg addressing modes, paging, IDT delivery, A20/real-mode wrap deferred) |
| M2S.2 | 2-level paging MMU (CR3/CR0.PG/CR4.PSE, page walk, split I/D TLBs, A/D bits, #PF decision) | `pmode` + `ppage` RTL sys-diff-clean vs qemu-system golden; pseg stays green; `make verify` (user) GREEN | ✅ done-partial (CR3→PDE→PTE 2-level walk + split 16-entry I/D TLBs + A/D-bit table writes + P/RW/US permission DECISION + #PF DECISION/CR2/error-code: `pmode` (identity 4 MiB PSE, 1084 records) AND `ppage` (NON-IDENTITY 4 KiB, 128 records) = RTL EQUIVALENT to the golden; CR0.PG=0 ⇒ linear==physical. #PF DELIVERY through the IDT = M2S.3 (decision computed/HALTs); 4 MiB NON-identity translation + A/D differential read-back + page-split + global pages/INVLPG deferred; TLB is functional-not-cycle) |
| M2S.3 | IDT-delivered interrupts/exceptions (gate read → exception frame push → handler → `IRET`); software `INT n`/`INT3`/`INTO`/`UD2` + the M2S.1/.2 hardware-fault DECISIONS now DELIVER | `pintr` + `pfault` RTL sys-diff-clean vs qemu-system golden; pseg/pmode/ppage stay green; `make verify` (user) GREEN | ✅ done-partial (SAME-PRIVILEGE CPL0 delivery: read IDT[v] gate → read gate CS descriptor → push EFLAGS/CS/EIP[/errcode] on SS:ESP → load CS:EIP → handler → `IRET` (pop EIP/CS/EFLAGS, reload CS); `pintr` (INT n/INT3/INTO trap+int gates, 171 records) AND `pfault` (#PF not-present DELIVERS via IDT[14]+CR2+errcode, #GP, #UD; 348 records) = RTL EQUIVALENT to the golden. FAULT pushes faulting EIP (restart), TRAP pushes next EIP; int gate clears IF, both clear TF/NT/RF/VM (IA-32 6.12.1); error code for #DF/#TS/#NP/#SS/#GP/#PF/#AC. user `int 0x80` STILL halts (IDT gated behind sys_mode). DEFERRED: cross-priv stack switch/TSS = M2S.4; gate-Present/gate-DPL/CS-descriptor protection checks (#NP/#GP-on-gate) + per-access perm #PF (perm_fault) + segment-limit #GP (seg_off_over_limit) computed-not-delivered; external/HW INTR + #DB single-step + BOUND not exercised) |
| M2S.4 | TSS + cross-privilege delivery + inter-priv `IRET` + gate/CS protection (TSS/task switch) | `pcpl` RTL sys-diff-clean vs qemu-system golden; pseg/pmode/ppage/pintr/pfault stay green; `make verify` (user) GREEN | ✅ done-partial (PRIVILEGE MACHINERY: **TR/TSS** (`LTR` loads TR base/limit/sel from the GDT TSS descriptor, `STR`; `SS0:ESP0` privilege stack); **CROSS-PRIV delivery** — gate target CS.DPL < CPL ⇒ load SS:ESP from `TSS.ssN:espN`, push the LARGER 5-word frame (old SS, old ESP, EFLAGS, CS, EIP [+errcode]), CPL 3→0; **INTER-PRIV `IRET`** — pop EIP/CS/EFLAGS + ESP/SS, CPL 0→3, null DS/ES/FS/GS whose DPL < new CPL; **gate/CS protection** (deferred from M2S.3): gate Present→#NP, gate DPL<CPL for `INT n`→#GP, target CS present/code/DPL≤CPL→#NP/#GP. `pcpl` (CPL3 user `INT n` → cross-priv CPL0 handler stack switch → inter-priv `IRET` back to CPL3) = RTL EQUIVALENT to the golden, 304 records. user mode bit-identical (all gated behind `sys_mode`). DEFERRED (documented honest follow-ons): full HW TASK SWITCH (`CALL`/`JMP` to TSS / task gate, `INT` through task gate) — **the far-`JMP`-to-TSS variant LANDED in M2S.4b** (`ptask` now an RTL `--system` diff EQUIVALENT to the golden, 292 records; see the M2S.4b row); the `CALL`/`INT`-task-gate (NT+back-link) + round-trip switch-back remain deferred; TSS busy-bit writeback on `LTR` (memory-only, STR returns the selector = the only observed reg effect — the M2S.4b task switch instead toggles the busy bits on the SWITCH); `tr_valid`/`tr_limit` #TS bound checks (missing/truncated TSS); cross-priv new-SS protection (SS.DPL/RPL/writable/present #TS/#GP) + inter-priv `IRET` SS RPL/DPL re-validation #GP; per-access perm #PF (`perm_fault`) — all NEGATIVE paths with no triggering corpus test / no oracle) |
| M2S.4b | HARDWARE TASK SWITCH (far `JMP`/`CALL` to a 32-bit TSS) — the deferred M2S.4 piece | `ptask` RTL `--system` sys-diff-clean vs qemu-system golden; all prior sys gates (pseg/pmode/ppage/pintr/pfault/pcpl + psmm/pdebug/pv86) stay green; `make verify` (user) GREEN | ✅ done-partial (HARDWARE TASK SWITCH on a far `JMP` to an available/busy 32-bit TSS descriptor (type 9/B). The `core.sv` micro-sequence (gated `sys_mode`): **S_TSW_SAVE** writes the OUTGOING task state into the current TSS (`tr_base`) at the documented 32-bit-TSS offsets — EIP@0x20 (= the insn after the jmp), EFLAGS@0x24, the 8 GPRs@0x28..0x44, the 6 segment selectors ES/CS/SS/DS/FS/GS@0x48..0x5C, LDTR@0x60; **S_TSW_READ** loads the INCOMING state from the new TSS (named by the jump selector, base from its GDT descriptor) — CR3@0x1C, EIP@0x20, EFLAGS@0x24, GPRs, the 6 selectors, LDTR — into holding regs; **S_TSW_SEG** reloads each incoming segment descriptor's hidden base/limit/attr from the GDT (CPL ← new CS.RPL, `cs_d` ← its D/B bit); **S_TSW_BUSY** toggles the descriptor busy bits (a JMP CLEARS the outgoing TSS busy B→9 and SETS the incoming one 9→B, single-byte GDT writes), then COMMITs — new TR (`tr_base/limit/sel`), `CR0.TS=1`, the incoming EIP/EFLAGS/GPRs/CR3 — and retires ONCE (q_pc = the jmp PC). `ptask` (far `JMP` to TSS2: outgoing save into TSS1 + incoming reload from TSS2 + busy toggle) = RTL EQUIVALENT to the golden, **292 records** (cr0..cr4 + selectors + GPRs + eflags + eip), incl. n=275 GPR/ESP/CR0.TS reload, the EDX=TSS1.EIP-save + ESI=0x1A1A1A1A live-EAX-save proofs, and EDI=0x898B busy-toggle. user mode bit-identical (all gated behind `sys_mode`). DEFERRED (honest, not in the corpus): a `CALL`-far / `INT`-through-task-gate switch (sets EFLAGS.NT + the TSS back-link@0x00 — a JMP does NOT); `IRET` with NT=1 (task-return); the round-trip switch-back (reloading the CPU-written TSS1 image); LDTR descriptor reload (no LDT machinery; the LDTR slot is saved/skipped); `tr_valid`/`tr_limit` #TS bound + TSS-descriptor-type/present #GP/#NP negative paths) |
| M2S.5 | SMM / `RSM` (PARTIAL-ORACLE: `SMI#` → save CPU state to the P5 SMRAM save-map → real-mode-like SMM handler → `RSM` restore + resume) | `psmm` RTL `--system` STRUCTURAL self-check (differential golden INFEASIBLE — see below); pseg/pmode/ppage/pintr/pfault/pcpl stay sys-green; `make verify` (user) GREEN | ✅ done-partial (**STRUCTURAL, not differential** — the gdbstub single-step oracle masks `SMI#` via `SSTEP_NOIRQ` + has no SMM awareness ⇒ a differential golden is INFEASIBLE and is NOT fabricated). RTL (gated `sys_mode`): **SMBASE** reg (reset `0x30000`); **`SMI#` source** = the APIC self-IPI (store to `0xFEE00300`, delivery-mode SMI) latched + taken at the next insn boundary, exactly as qemu's APIC — so the SAME bare-metal `psmm.bin` drives it; **`SMI#` entry** saves the CPU state to the **P5** save-map at the documented offsets (CR0 `@SMBASE+0xFFFC`, EIP `+0xFFF0`, EFLAGS `+0xFFF4`, GPRs, the 6 segment selectors, GDT/IDT base, SMBASE slot `+0xFEF8`, rev-id `+0xFEFC` = `0x00020000` bit-17-set, auto-HALT word `+0xFF02`), clears `CR0` PE/PG/EM/TS, sets `CS` sel=`SMBASE>>4` base=`SMBASE` + 4-GiB limits, `EIP=0x8000`, CPL0, 16-bit default; **`RSM` (`0F AA`)** reads the whole map back + commits the restored architectural state (incl. a handler-relocatable SMBASE / resume-EIP) in one clock, resumes. `psmm` self-checked BOTH ways: (3c) qemu **free-run** + QMP memory readback ([0x2000]/[0x2004]/[0x2008] sentinels + the save area + `SMM=0` post-RSM), and (3d) the **RTL** trace (`CS=SMBASE>>4`, `CR0.PE` cleared, EIP `SMBASE+0x8000`; RSM restores CS/CR0.PE/EBX-witness/resume-EIP) + the P5 save-map dump at the documented offsets. user-mode bit-identical (RSM is `#UD` outside SMM/in user mode). DEFERRED (honest): the differential golden (oracle INFEASIBLE); I/O-restart + auto-HALT-restart slots (written 0 / not exercised); a handler that actually relocates SMBASE / modifies resume EIP (only round-trip-to-saved exercised); the exact P5 reserved-area encoding for the hidden descriptor state (RTL-internal convention); **DR6 `@+0xFFCC` / DR7 `@+0xFFC8` / TR `@+0xFFC4` / LDT-base `@+0xFFC0`** (Table 20-1 slots — NOT saved/restored: DR is M2S.6, no LDT-base reg yet, TR left unchanged through SMM; corpus does not touch them so the round-trip closes); FPU not auto-saved per Table 20-1) |
| M2S.6 | debug registers / `#DB` (last system stage) | `pdebug` RTL `--system` sys-diff-clean vs qemu-system golden (PARTIAL oracle); pseg/pmode/ppage/pintr/pfault/pcpl stay sys-green; `make verify` (user) GREEN | ✅ done-partial (**DR0–DR7 file** (reset DR6=`0xFFFF0FF0`/DR7=`0x400`, reserved-1 fixed-bit masking on write; DR4/DR5 ALIAS DR6/DR7 when CR4.DE=0, **#UD when CR4.DE=1**); **MOV DRn↔GPR** (`0F 21`/`0F 23`, gated `sys_mode`, user-mode bit-identical); **`#DB` delivery** (vector 1, no errcode) through the M2S.3 IDT path via `arm_db()` from the triggering insn's RETIRE boundary (the qemu gdbstub fuses insn+synchronous #DB into ONE record). Three **DIFFERENTIAL** #DB causes: **TF single-step** (DR6.BS, TRAP) keyed off `tf_at_issue` sampled at S_DECODE — now wired on ALL the common retire paths (`do_retire` + every `S_STORE` case: PUSH/CALL/XCHG/PUSHF/string); **DR0–3 instruction-bp** (DR6.Bn, FAULT, honoring EFLAGS.RF suppress+auto-clear); **DR1–3 data-write-bp** (DR6.Bn, TRAP, + the qemu data-watchpoint extra handler-entry record via `S_DB_EXTRA`). `pdebug` (MOV-DR round-trip + 3 #DB deliveries) = RTL EQUIVALENT to the golden, **239 records**. user mode bit-identical (all gated behind `sys_mode`). **DEFERRED (honest):** **DR7.GD general-detect FIRING** — IMPLEMENTED-BUT-DISABLED behind `DBG_GD_ENABLE=1'b0` (qemu 8.2.2 does not model GD ⇒ a differential golden is INFEASIBLE; with the gate off the RTL takes EXACTLY 3 #DB like the golden, so the diff stays EQUIVALENT; **no wired structural self-check** — needs a TB hook for an RTL-only GD-enabled trace, which does not exist yet); BT task-switch debug trap (needs HW task switch, M2S.4 defer); I/O breakpoints (CR4.DE R/W=10); SMM save/restore of DR6/DR7; exotic single-stepped multi-cycle ops not in the corpus; reserved-DR-bit corners) |
| M3 | x87 FPU | x87 corpus diff-clean vs QEMU (`make m3` exit 0) | ✅ done (x87 functional core: stack/status/control/tag + 80-bit datapath, data movement + normal-operand arithmetic bit-exact vs QEMU; 14-program x87 corpus + 28 integer = 42/42 PASS. Transcendentals, BCD, FSAVE/FRSTOR/FLDENV, unmasked #MF, and non-default **precision** control (PC≠64-bit) are DEFERRED and HALT loudly) |
| M4 | Dual-issue U/V + pairing + branch prediction | µbench CPI/pairing/mispredict match p5model | ✅ done (real 5-stage U/V fast path + serialized slow path; M1/M2/M3 func gates stay green; all 5 integer cycle bands met EMERGENT from the RTL pipeline — depadd CPI 1.080/pair 0.6%, indepadd CPI 0.590/pair 49.5%, agi 49.9%, brloop mispred 0.2% (7/3004), brrandom mispred 61.0% (244/400). Cycle oracle is an ESTIMATE (PLAN §8); FP/cache cycle accuracy = M5) |
| M5 | Cache-cycle + x87/FP-cycle accuracy (re-scoped; pin-level bus → M5B) | faddchain gated CPI≈3 + I$/D$-miss kernels track p5model; tightened abs-cyc; func+M4 bands green | ✅ done (FP latency+throughput+occupancy + L1 I$/D$ (2-way/128/LRU) miss timing — all EMERGENT, matching the p5model oracle. m1/m2/m3 stay green (53/53 func-diff-clean); all 5 M4 integer bands met; all 4 new M5 bands met (faddchain CPI 3.01, fpindep 1.16 < chain, dmiss/imiss miss-elevated). Tightened abs-cyc at **M5_TOL_PCT=10%**, achieved: FP/cache kernels ≤0.14% (faddchain +0.5%, fpindep +2%, dmiss +0.10%, imiss +0.14%), integer worst-case +6.16% (indepadd). Cycle oracle is an ESTIMATE (PLAN §8); miss penalty is a p5model assumption. Pin-level bus = M5B (no oracle)) |
| M5B | Pin-level 64-bit bus protocol (needs real-chip bus traces) | structural + local SVA (no differential oracle) | ✅ done STANDALONE (biu_p5, 16 cycle types, 19 mutation-validated SVA + 76 directed checks; commit 3e82269). Integration into rtl/ + wiring = M5B-int (deferred) |
| R1 | RTL modularization + gate speedup (maintenance) | all of m1–m5 stay green across the refactor; fast `make verify` | ✅ done (fast parallel+cached gate `make verify` ~2s vs ~3h, mutation-validated; intcore.sv 3648→core.sv 3146 + ventium_alu_pkg/decode_pkg/decode.sv/issue_uv.sv extracted, lint-clean, behavior bit-exact. Leaf modules regfile/caches/fpu/btb DEFERRED to R2 — too entangled with the shared pipeline FSM to extract mechanically). **R2 (2026-06-04, see PROGRESS_Jun04.md):** the 4 single-write-port leaves EXTRACTED bit-exact — `mem/dcache_timing.sv`, `core/bpred_btb.sv`, `mem/tlb.sv` (×2 I/D), `mem/icache.sv`; regfile (`gpr[8]`, 2-write-port dual-issue) + fpu-state proven spine-bound + left inline. All gates stay green; behavior bit-exact. |
| M6 | Errata & stepping fidelity (stretch) | targeted errata repro behind a flag, default OFF; `make verify` (OFF) stays GREEN + `make m6` (ON) self-checks vs DOCUMENTED values | ✅ done (PARTIAL, non-differential stretch) — 4 documented P5 errata reproduced behind `errata_en[3:0]` (default 0 = clean core, so `make verify` stays fully GREEN): **Err23 FDIV/SRT** (published vector 4195835/3145727 → documented flawed `1.3337390689…`; no fabrication for other operands — negative-controls confirm), **Err20 FIST overflow** (operand 4294967295.5 → stores 0, no IE), **Err81 F00F** (LOCK CMPXCHG8B reg-dst → hang), **Err59 MOV moffs** (A2/A3 fails to pair, cycle gate). Verified against DOCUMENTATION (Spec Updates), NOT a differential oracle — QEMU computes correctly. `make m6` = 11/11 self-checks. All BTB/SMM/NMI/APIC/DP/paging/exception/timing errata DEFERRED to M2S (need system-mode infra / no oracle). |

Legend: ☐ not started · ▶ in progress · ✅ done · ⚠ blocked

## What exists today (inherited)

- **`ventium-refs/` submodule** — full reference library (Intel manuals, Alpert &
  Avnon, AP-500/AP-526, Agner Fog, datasheet, spec updates, die-photo articles)
  with a cheap page-referenced index in `ventium-refs/00-index/INDEX.md`.
- **`ventium-refs/07-p5-emulation-harness/`** — a working QEMU-based functional +
  cycle **golden reference** for P54C/non-MMX:
  - plugin-enabled `qemu-i386 -cpu pentium` build scripts (#UDs on non-P5 opcodes),
  - `plugin/p5model.c` — in-order U/V cycle-estimation model (validated 6/6 on
    its microbenchmarks: dependent/independent ALU CPI, fadd chain, AGI, branch
    predictable/random),
  - `tools/isa_verify.py` — static P5-ISA checker (capstone),
  - mined timing constants + provenance in `docs/p5_timing_*.json`,
  - benchmark corpus (Dhrystone/Whetstone/LINPACK/CoreMark/STREAM + kernels).

  This is the cycle oracle for layers 3–4 and the functional oracle for layers
  1–2. **No RTL exists yet.**

## Log

### 2026-06-05 — M2S.4b done-partial: HARDWARE TASK SWITCH (far JMP to a TSS) — the deferred M2S.4 piece lands

The deferred M2S.4 piece — the **hardware task switch** — now lands as a real RTL
`--system` differential. M2S.4 left a far `JMP`/`CALL` to a SYSTEM (TSS) descriptor
HALTing cleanly in `S_LJMP` (no mis-delivery); the `ptask` stretch corpus (a far
`JMP` to an available 32-bit TSS) tracked the golden bit-for-bit for ~275 records
then halted at the ljmp-to-TSS, staying golden self-diff + the step-5d validation
only. M2S.4b implements the switch and promotes `ptask` to a REAL RTL diff.

**What landed (RTL EQUIVALENT to the golden, gated `sys_mode`; IA-32 SDM Vol.3 §7.3):**
The `S_LJMP` system-descriptor arm now dispatches a far `JMP` whose target GDT
descriptor is an available (type `0x9`) or busy (`0xB`) 32-bit TSS into a four-state
task-switch micro-sequence (the new `S_TSW_SAVE/_READ/_SEG/_BUSY`):
- **S_TSW_SAVE** — write the OUTGOING task state into the CURRENT TSS (`tr_base`),
  one dword per beat at the documented 32-bit-TSS offsets: EIP@0x20 (= the insn
  after the jmp = `next_eip`), EFLAGS@0x24, the 8 GPRs@0x28..0x44 (eax..edi map to
  `gpr[0..7]`), the 6 segment selectors ES@0x48/CS@0x4C/SS@0x50/DS@0x54/FS@0x58/
  GS@0x5C, LDTR@0x60. (CR3@0x1C is read on entry, not written.)
- **S_TSW_READ** — read the INCOMING task state from the NEW TSS (named by the jump
  selector, base from its GDT descriptor) into `tsw_*` holding regs: CR3@0x1C,
  EIP@0x20, EFLAGS@0x24, the GPRs, the 6 selectors, LDTR.
- **S_TSW_SEG** — reload each of the 6 incoming segment descriptors' hidden
  base/limit/attr from the GDT (two reads per descriptor, like a normal segment
  load); CPL ← the new CS.RPL, `cs_d` ← its D/B bit.
- **S_TSW_BUSY** — toggle the descriptor busy bits (a JMP CLEARS the outgoing TSS
  busy `B→9` and SETS the incoming one `9→B`, via single-byte GDT writes to the
  access byte at descriptor+5), then COMMIT atomically: new TR (`tr_base/limit/sel`
  ← the incoming TSS descriptor + `tr_attr`), `CR0.TS=1` (every task switch sets TS),
  the incoming EIP/EFLAGS/GPRs/CR3, and retire ONCE (`q_pc` = the jmp PC, so the
  switch record stamps at the ljmp exactly as the golden's n=275).
A JMP does **not** set EFLAGS.NT or the TSS back-link (only a CALL / interrupt-task-
gate does). The outgoing TSS descriptor access is captured into a new `tr_attr` reg
at `S_LTR` so its busy bit can be cleared on a switch without a re-read. All the TSS/
GDT accesses address physical memory under the M2S.1/.2 identity-map convention
(paging off in the corpus) and are excluded from the paging post-translate.

`ptask` = RTL `--system` EQUIVALENT to the golden, **292 records** (cr0..cr4 +
selectors + GPRs + eflags + eip), across the far-JMP task switch + outgoing state
save + incoming reload + busy toggle. The proofs all match: n=275 reloads
EAX=0xAAAAAAAA/EBX=0xBBBBBBBB/ESP=0x00070000 + `CR0.TS` (cr0 0x60000011→0x60000019)
+ EFLAGS←TSS2 (0x46→0x2); EDX=0x000f01d8 (TSS1 saved resume EIP) + ESI=0x1A1A1A1A
(the live EAX saved into TSS1) prove the outgoing SAVE; EDI=0x898B proves the
busy-bit toggle (TSS1→0x89 available, TSS2→0x8B busy). `ptask` is now in
`RTL_SYS_TESTS` (run-sys-golden.sh) → step-7 RTL-SYS-DIFF-OK; the `verify-sys`
Makefile target already listed it.

**`make verify` (user) stays GREEN + bit-identical** (the whole task switch is gated
behind `sys_mode`, INERT in user mode). **All prior sys gates stay EQUIVALENT**:
pseg/pmode/ppage/pintr/pfault/pcpl/pdebug/pv86 RTL-SYS-DIFF-OK + psmm SMM-PARTIAL-OK.
Lint clean (`verilator --lint-only -Wall -Wno-UNUSED`, 0 warn/err).

**Deferred (honest done-partial; not in the corpus — no oracle to differentially
validate):** the `CALL`-far / `INT`-through-task-gate task switch (sets EFLAGS.NT +
the TSS back-link@0x00); `IRET` with NT=1 (the task-return); the round-trip
switch-back (reloading the CPU-written outgoing TSS image — the gnarliest reload);
LDTR descriptor reload (no LDT machinery — the LDTR slot is saved/skipped, 0 here);
`tr_valid`/`tr_limit` #TS bound + TSS descriptor type/present #GP/#NP negative paths.

**Next: M2S.5/M2S.6** already done (above). The system-mode RTL deferrals that remain
are the negative protection paths (no triggering corpus / no oracle).

### 2026-06-04 — M2S.6 done-partial: debug registers / `#DB` (PARTIAL-ORACLE; differential MOV-DR + 3 #DB causes, GD deferred) — LAST system-mode stage

The sixth and **final system-mode RTL** stage adds the **debug registers (DR0–DR7)**
and **`#DB` (vector 1) delivery**: MOV to/from a DR, the TF single-step trap, and
hardware instruction/data breakpoints, all delivered through the M2S.3 IDT path.
New corpus **`pdebug`** (real→protected, NO paging, a #DB TRAP gate at vector 1):
(a) MOV DRn↔GPR round-trips, (b) TF single-step a `nop`, (c) a DR0 instruction
breakpoint, (d) a DR1 data-write breakpoint, (e) a DR7.GD general-detect probe.

**Verification mode — PARTIAL oracle, mostly DIFFERENTIAL (honest).** Unlike psmm,
the bulk of M2S.6 **IS** differentially observable: `#DB` is a SYNCHRONOUS exception
raised inside the TB (`raise_exception(EXCP01_DB)`), NOT an `interrupt_request`, so
`SSTEP_NOIRQ` does **not** mask it — qemu's gdbstub single-step delivers it through
the guest IDT *before* returning `EXCP_DEBUG` to gdb. So `pdebug` is a REAL RTL
`--system` differential against the qemu-system golden (**239 records, EQUIVALENT**)
covering: the MOV-DR round-trip (DR values observed THROUGH the GPRs/memory the
handlers read — the M2S.1 hidden-base trick; DR values are HMP-only, not in the
g-packet), the TF single-step `#DB` (DR6.BS, TRAP, resume at next EIP), the DR0
instruction-breakpoint `#DB` (DR6.B0, FAULT, restart the faulting EIP, RF resume-
flag honored), and the DR1 data-write `#DB` (DR6.B1, TRAP, incl. the qemu data-
watchpoint **extra** handler-entry record). The ONE structural corner is **DR7.GD
general-detect**, which qemu 8.2.2 does NOT model — kept DIFFERENTIAL-EQUIVALENT by
holding the GD `#DB` fire DISABLED (see DEFERRED).

**What landed (RTL, gated `sys_mode`):**
- **DR0–DR7 register file** — reset DR6=`0xFFFF0FF0` / DR7=`0x00000400`; on write the
  reserved-1 fixed bits are forced (DR6 |= `0xFFFF0FF0`, DR7 |= `0x400`) so the read-
  back is deterministic, exactly matching qemu's `helper_set_dr` in 32-bit mode (the
  upper-32 reserved mask never bites). **DR4/DR5 ALIAS DR6/DR7 when CR4.DE=0**, and
  raise **`#UD` when CR4.DE=1** (the P5 debug-extensions semantics; matches qemu's
  `helper_get/set_dr` `EXCP06_ILLOP`).
- **MOV DRn↔GPR** — `0F 21` (MOV r32,DRn) / `0F 23` (MOV DRn,r32) decoded mirroring
  `0F 20`/`0F 22` and **gated on `sys_mode`** (user mode keeps the prior
  `d_unknown`→HALT, so `make verify` is byte-identical).
- **`#DB` delivery** — vector 1, no error code, through the M2S.3 `S_INT_GATE` path
  via a new `arm_db()` task launched FROM the triggering instruction's RETIRE
  boundary (the qemu gdbstub single-step FUSES the instruction + its synchronous
  `#DB` into ONE record stamped at the instruction PC). DR6 status bits are sticky.
- **TF single-step** (DR6.BS, TRAP, pushes next EIP) keyed off `tf_at_issue` sampled
  at S_DECODE (so a POPF that SETS TF does not self-trap) — wired on `do_retire` AND
  every `S_STORE` retire case (PUSH/CALL/XCHG/PUSHF/string), so an attempted single-
  step of ANY common retiring instruction is eligible for the trap (qemu delivers a
  `#DB` on every stepped insn). **DR0–3 instruction breakpoints** (DR6.Bn, FAULT on
  the committed next-EIP via `dr_match()` honoring DR7 Ln/Gn + R/Wn + LENn alignment)
  honor **EFLAGS.RF** suppression + auto-clear. **DR1–3 data-write breakpoints**
  (DR6.Bn, TRAP, detected at S_STORE) plus the qemu data-watchpoint **extra**
  handler-entry record (new `S_DB_EXTRA` state via `db_wp_extra`).

`pdebug` = RTL `--system` **EQUIVALENT** to the golden, **239 records** (cr0..cr4 +
the 6 selectors + GPRs + eflags + eip). Golden self-diff also EQUIVALENT.

**Adversarial-review fixes this phase:** (1) **TF single-step now fires on all the
common retire paths** — `tf_at_issue` (and the data-write breakpoint) was previously
honored only on the `do_retire` path and the `K_ALU mov mem,reg` `S_STORE` case; the
`K_CTRL`/`K_XCHG`/`K_STKMISC`/`K_STR` `S_STORE` cases (CALL/XCHG/PUSHF/string)
retired WITHOUT checking it, so single-stepping a PUSH/CALL/PUSHF/string under TF=1
would have missed the `#DB`. Now all of them divert to `arm_db()` when `tf_at_issue`
(or a data-write hit) is set, matching qemu's per-step delivery. (The corpus single-
steps only a `nop` ⇒ those paths run with `tf_at_issue=0` today, so this is a
coverage extension that stays bit-identical on the existing gate.) (2) **MOV DR4/DR5
now `#UD`s when CR4.DE=1** — previously the DR4→DR6 / DR5→DR7 alias was
unconditional with no `CR4.DE` test; the alias is correct only for CR4.DE=0, and
CR4.DE=1 must `#UD`. Added the `creg4[3]` test in S_DECODE (delivers vector 6, no
errcode, a FAULT). The corpus keeps CR4.DE=0 throughout, so the gate is unchanged;
the RTL is now spec-faithful for CR4.DE=1. (3) **Manifest GD claim corrected** — the
committed `pdebug/manifest.json` claimed the GD path is "self-checked STRUCTURALLY
(the RTL trace MUST show a 4th `#DB` + the `0x2038`/`0x203c` witnesses set)", which
NO gate performs and which is mutually exclusive with the as-built RTL
(`DBG_GD_ENABLE=0` ⇒ 3 `#DB`, witnesses 0; flipping it to 1 DIVERGES the only wired
gate). Reworded lines 32/52/55 to the honest state: GD is IMPLEMENTED-BUT-DISABLED
and DEFERRED, NOT structurally self-checked (a TB hook for an RTL-only GD-enabled
trace does not yet exist).

**DEFERRED (honest done-partial):** **DR7.GD general-detect FIRING** — the GD
decision + `#DB`-fire path is fully CODED but held behind a default-off localparam
`DBG_GD_ENABLE=1'b0`. qemu 8.2.2 does NOT model GD (`DR7_GD`/`DR6_BD` are defined but
never tested/set in `target/i386` — grep-confirmed; empirically MOV %dr0 with
DR7.GD=1 did NOT fault), so a differential golden is **INFEASIBLE** and is NOT
fabricated; with the gate off the RTL takes EXACTLY 3 `#DB` like the golden, keeping
the diff EQUIVALENT, and the corpus's section-(e) GD probe runs IDENTICALLY in both
oracles. There is **no wired structural self-check** of GD firing (it needs a TB hook
to build an RTL-only `DBG_GD_ENABLE=1` trace, which does not exist — a psmm-style
3c/3d confirmation is future work). Also deferred: the BT task-switch debug trap
(needs a HW task switch, M2S.4 defer); I/O breakpoints beyond decode (CR4.DE + R/W=10);
SMM save/restore of DR6/DR7 (the M2S.5/M2S.6 seam, not exercised by `pdebug`); exotic
single-stepped multi-cycle ops outside the corpus; exotic P5 reserved-DR-bit corners.

**Gates after the fixes:** `make verify` (user) GREEN + bit-identical (56/56 func +
all M4/M5 cycle bands); all prior sys tests sys-green — pseg 70 / pmode 1084 /
ppage 128 / pintr 171 / pfault 348 / pcpl 304 RTL `--system` EQUIVALENT; ptask self-
diff EQUIVALENT (292); psmm structural self-check PASS both ways; `pdebug` RTL
`--system` EQUIVALENT (239). verilator lint clean. **M2S.6 is the LAST system-mode
stage** — the M2S arc (segmentation → paging → IDT delivery → cross-priv/TSS → SMM →
debug) is complete; the deferred M6 debug/stepping errata become reachable from here.

### 2026-06-04 — M2S.5 done-partial: SMM / RSM (PARTIAL-ORACLE; STRUCTURAL self-check, not differential)

The fifth **system-mode RTL** stage adds **System Management Mode**: `SMI#` saves
the CPU state to the SMRAM save-state map, the CPU enters a real-mode-like SMM
context and runs the SMM handler, then `RSM` (`0F AA`) restores the saved state and
resumes the interrupted program. New corpus **`psmm`** (set up SMRAM + an SMM
handler at `SMBASE+0x8000`, trigger `SMI#` via an APIC self-IPI, write sentinels +
`RSM`, prove resume with state intact).

**Verification mode — STRUCTURAL, not differential (honest).** This is a
**partial-oracle** stage. The de-risk phase proved the differential golden is
**INFEASIBLE** and we did **not** fabricate one: the system oracle is built on the
`qemu-system-i386` gdbstub **single-step** (`s`) path, which sets `SSTEP_NOIRQ` and
masks `SMI#` (`CPU_INTERRUPT_SMI == CPU_INTERRUPT_TGT_EXT_2`, cleared from
`interrupt_request` under single-step), so `SMI#` is never delivered between steps;
and the gdbstub `g`-packet carries no SMM-active flag (it is HMP-only per M2S.0).
qemu also writes the **P6/SDM-34.4** save area, not the **P5** layout this stage
targets. So instead of a faked sys-diff, `psmm` self-checks the round-trip
**structurally, two ways**: (3c) qemu **free-running** + QMP physical-memory
readback, and (3d) the **RTL** SMM mechanism (RTL trace + a save-map dump at the
documented P5 offsets). Both are RTL-/free-run-only structural checks — NOT a
golden differential. (`pseg/pmode/ppage/pintr/pfault/pcpl` remain REAL RTL
`--system` differentials and stay green; `psmm` is explicitly the structural one.)

**What landed (RTL, gated `sys_mode`):**
- **SMBASE** register (reset default `0x30000`) + **`RSM` (`0F AA`)** decode, which
  is `#UD` outside SMM / in user mode (so user-mode `make verify` stays bit-identical).
- **`SMI#` source** — the RTL recognises the **APIC self-IPI SMI** exactly as
  qemu's APIC: on the ICR-low write (store to phys `0xFEE00300` with delivery-mode
  `010`) it latches `smi_pending` and takes the SMI at the **next instruction
  boundary**. The SAME bare-metal `psmm.bin` drives the RTL round-trip — no TB poke.
- **`SMI#` entry (`S_SMI_SAVE`)** — saves the CPU state to the **P5** SMRAM save map
  (Vol.3 Table 20-1) at the documented offsets, then enters SMM: clear `CR0`
  PE/PG/EM/TS; `CS` sel=`SMBASE>>4` base=`SMBASE`, data segs base 0, all 4-GiB
  limits; `EIP=0x8000`; CPL0; 16-bit default operand/address size.
- **`RSM` (`S_RSM`)** — reads the whole map back into holding regs and **commits the
  restored architectural state in one clock** (honoring a handler-relocatable SMBASE
  / resume-EIP; `{cs_d,cpl}` committed straight from the final read-back word so
  CS.D/B + CPL restore correctly), then resumes the interrupted context.

`psmm` self-check PASS both ways — qemu free-run sentinels (`[0x2000]=0x5A4D5A4D`,
`[0x2004]='RET!'`, `[0x2008]=0x5A4D900D` EBX-witness survived, `SMM=0` post-RSM) AND
the RTL trace + P5 save-map dump (entry `CS=0x3000`/`CR0.PE` cleared/`EIP=0x8000`,
RSM back to `CS=0x08`/`CR0.PE` set/EBX intact/mainline resume EIP; save-map CR0/EIP/
EBX/CS-sel/SMBASE at the documented offsets).

**P5-fidelity fixes this phase (review findings):** SMM Revision Identifier set to
the faithful P5 value **`0x00020000`** (bit 17 = SMBASE-relocation support set per
Vol.3 §20.1.5.1/§20.1.5.3 — *"bit 17 … is set in the Pentium processor (510\60,
567\66)"*; bit 16 I/O-restart = 0; the §20.2.2 *"revision ID is 0"* refers to the
upper-word EXTENSION version, not bit 17; `qemu-system-i386` agrees:
`SMM_REVISION_ID=0x00020000`) — was `0` with a backwards comment claiming
`0x00020000` is P6-only. Auto-HALT Restart slot moved to the documented **word
location `0x7F02`** (Table 20-1 / Fig 20-4; `0x7F00` is Reserved) — was `0x7F00`.
Removed three stale comments describing signals that were simplified away
(`smm_saved_pe`; the `rsm_csd/rsm_cpl` one-clock-late note) — the implemented
final-beat commit is correct; the comments now match it. Documented the explicit
omission of **DR6 `0x7FCC` / DR7 `0x7FC8` / TR `0x7FC4` / LDT-base `0x7FC0`** from
the save map (Table 20-1 slots not save/restored: DR is M2S.6, no LDT-base reg yet,
TR left unchanged through SMM; the corpus does not touch them so the round-trip
closes — a real divergence, deferred honestly).

**Gates after the fixes:** `make verify` (user) GREEN + bit-identical; all prior
sys tests sys-green (pseg 70 / pmode 1084 / ppage 128 / pintr 171 / pfault 348 /
pcpl 304 RTL `--system` EQUIVALENT; ptask self-diff + step-5d); `psmm` structural
self-check PASS both ways; verilator lint clean.

**DEFERRED (honest done-partial):** the differential golden (oracle INFEASIBLE,
documented — never faked); the I/O-instruction-restart + auto-HALT-restart slots
(written 0 / not exercised by the corpus); a handler that actually RELOCATES SMBASE
or modifies the resume EIP (RTL commits both from the writeable slots, but
`psmm.bin`'s handler leaves them unchanged ⇒ only round-trip-to-saved-value is
exercised); the exact P5 reserved-area encoding for the segment hidden descriptor
state (stepping-specific / not publicly documented ⇒ RTL-internal convention at
`SMBASE+0xFE00`); DR6/DR7/TR/LDT-base save-map slots (above); FPU/DR3–DR0 not
auto-saved per Table 20-1; APIC-SMI *sourcing* corner cases in the front end.

**Next: M2S.6** — debug registers / `#DB` (the last system-mode stage). _(Done —
see the M2S.6 entry above.)_

### 2026-06-04 — M2S.4 done-partial: TSS + cross-privilege delivery + inter-priv IRET + gate/CS protection

The fourth **system-mode RTL** stage adds the **privilege machinery** on top of
M2S.3's same-privilege (CPL0) IDT delivery. M2S.3 delivered faults/interrupts to a
CPL0 handler on the current stack; M2S.4 makes the CPL transition real: a CPL3 user
task `INT n` switches to the CPL0 handler stack via the TSS, and the inter-priv
`IRET` returns to CPL3. New corpus **`pcpl`** (set up a TSS with `SS0:ESP0`, a CPL3
code/data segment + user task that issues `INT n`, the cross-priv delivery, the
handler, the inter-priv `IRET` back to CPL3). Gated vs `qemu-system-i386`.

**What landed (RTL EQUIVALENT to the golden):**
- **TR / TSS (32-bit).** `LTR r16` (`S_LTR`) reads the GDT TSS descriptor named by
  the selector and loads the TR hidden cache (`tr_base`/`tr_limit`/`tr_sel`,
  `tr_valid`). `STR` returns the TR selector (the only observed register effect).
- **Cross-privilege delivery.** When the gate's target CS.DPL < CPL (`S_INT_CS`),
  the handler is more privileged: freeze the interrupted task's CS:SS:ESP, set the
  target CPL, read `TSS.ssN:espN` (`S_INT_TSS`, N = target DPL), load the new SS
  descriptor (`S_INT_SS`), then push the **larger 5-word frame** (`S_INT_PUSH`):
  old SS, old ESP, EFLAGS, CS, EIP `[+errcode]`, descending from the NEW stack
  (`xpl_active`). CPL 3→0; SS:ESP ← `TSS.SS0:ESP0`.
- **Inter-privilege `IRET`.** After popping EIP/CS/EFLAGS, when the popped CS.RPL >
  current CPL the return is privilege-lowering: also pop ESP/SS (`iret_interpriv`),
  reload the outer SS descriptor (`S_IRET_SS`), CPL 0→3, and NULL any of
  DS/ES/FS/GS whose DPL < the new CPL (IA-32 6.12.3). Verified non-vacuous (the
  transfer-down nulls DS/ES/FS/GS 0x10→0x0000 and the RTL matches the golden).
- **Gate/CS protection checks (deferred from M2S.3).** `S_INT_GATE`: gate not
  Present → `#NP(v*8+2)`; software `INT n` with gate.DPL < CPL → `#GP(v*8+2)`.
  `S_INT_CS`: target CS must be Present (else `#NP(sel)`), a code segment, and
  DPL ≤ CPL (else `#GP(sel)`).

`pcpl` = RTL `--system` EQUIVALENT to the golden, **304 records** (cr0..cr4 +
selectors + GPRs + eflags + eip), across the CPL 0→3 transfer-down + cross-priv
3→0 delivery (SS stack switch to TSS.SS0:ESP0 confirmed by step 5c) + handler +
inter-priv `IRET` 0→3 return. **`make verify` (user) stays GREEN + bit-identical**
(all M2S.4 logic gated behind `sys_mode`/`paging_on`); **pseg/pmode/ppage/pintr/
pfault stay sys-green** (70/1084/128/171/348 records). Lint clean.

**Phase-3 findings addressed (this close-out):**
- **[med, fixed] Paging/TSS translation asymmetry + stale comment.** `S_INT_TSS`
  (the `TSS.ssN:espN` read) was in the `translatable` list AND not excluded from
  the linear→physical post-translate, while its sibling `S_INT_SS` (the GDT new-SS
  descriptor read) and the other descriptor reads (`S_LGDT/S_SEGLD/S_LJMP/S_LTR`)
  were excluded — so under paging the TSS read would be translated while the GDT
  reads were not, and the `cur_lin` comment claimed `S_INT_TSS` was untranslated
  (code/comment contradiction). Per IA-32 the GDT and TSS are BOTH linear
  structures; the M2S.1/.2 convention reads all descriptor/TSS structures
  PHYSICALLY under the identity-map simplification. **Fixed:** removed `S_INT_TSS`
  from `translatable`, added it to the post-translate exclusion (now consistent
  with `S_INT_SS`/`S_LTR`), and corrected all three comments to describe the single
  consistent convention. Inert for `pcpl` (no paging), so the gate stays bit-exact
  EQUIVALENT — a latent-consistency fix that makes a future paged-TSS test correct.
- **[low, documented] Cross-priv new-SS protection checks** (`S_INT_SS` loads the
  new SS unconditionally; no SS.DPL/RPL == target CPL, writable-data, present, no
  `tr_valid`/`tr_limit` #TS bound) and **inter-priv `IRET` SS RPL/DPL
  re-validation** (`S_IRET_SS`). These are NEGATIVE paths: `pcpl` uses a well-formed
  SS0 (0x10, DPL0, present, writable, within the 104-byte TSS) and matching RPL=3
  selectors (CS=0x1B, SS=0x23), so none fire and there is NO oracle to
  differentially validate the #TS/#GP delivery. Per the iron rule (never fake a
  sys-diff; needs a triggering corpus test), wiring an unvalidated fault would be
  unverified dead logic — kept DEFERRED, with the deferral now documented precisely
  at each code site (`S_INT_SS`, `S_IRET_SS`) and in the `tr_valid`/`tr_limit`
  lint-sink note.

**Deferred (honest done-partial; documented) — UPDATED by M2S.4b (2026-06-05):**
- **Full hardware task switch** — the far-`JMP`-to-TSS variant **LANDED in M2S.4b**
  (see the dated entry below): the `S_LJMP` system-descriptor HALT now dispatches a
  far `JMP` to an available/busy 32-bit TSS into the `S_TSW_SAVE/_READ/_SEG/_BUSY`
  micro-sequence (save outgoing state, load incoming state + segments, set CR0.TS,
  toggle busy bits, new TR). `ptask` is now in `RTL_SYS_TESTS` and is RTL `--system`
  EQUIVALENT to the golden (292 records). STILL DEFERRED (not in the corpus): the
  `CALL`-far / `INT`-through-task-gate switch (sets EFLAGS.NT + the TSS back-link —
  a JMP does NOT), `IRET` with NT=1 (task-return), and the round-trip switch-back
  (reloading the CPU-written outgoing TSS image).
- **TSS busy-bit writeback on `LTR`** (type 9 → B in the GDT) — a memory-only side
  effect the corpus never reads back (STR returns the selector = the only observed
  register effect); omitted as a documented simplification.
- **`tr_valid`/`tr_limit` #TS bound checks** (missing/truncated TSS), **cross-priv
  new-SS protection** (#TS/#GP), **inter-priv `IRET` SS re-validation** (#GP), and
  the M2S.2 **per-access permission `#PF`** (`perm_fault`: CPL3 / WP=1 against a
  present supervisor/RO page) — all computed-not-delivered NEGATIVE paths needing a
  triggering corpus test + an oracle.

**Next:** **M2S.5** — SMM / `RSM` (System Management Mode: SMI entry → save the
SMM state-save area → SMM handler → `RSM` restore).

### 2026-06-04 — M2S.3 done-partial: IDT-delivered interrupts/exceptions + exception frame + IRET

The third **system-mode RTL** stage: **IDT delivery**. The fault DECISIONS that
M2S.1 (segmentation: `#GP/#NP/#SS` selector checks) and M2S.2 (paging: `#PF` +
`CR2` + error code) only **computed** (and HALTed on) now **DELIVER** through the
IDT — read the gate, push the exception frame, load `CS:EIP`, run the handler,
and `IRET` back — gated **differentially** against the `qemu-system-i386` golden.
Two new tests run as REAL RTL `--system` diffs: **`pintr`** (software `INT n` /
`INT3` / `INTO` → interrupt+trap gate handlers → `IRET`, **171 records**) and
**`pfault`** (the M2S.1/.2 **hardware faults** `#PF` / `#GP` / `#UD` DELIVERING
through the IDT → handler → `IRET`/restart, **348 records**), both **RTL
EQUIVALENT** to the golden across cr0..cr4 + the 6 selectors + GPRs + eflags +
eip. `pseg` (70), `pmode` (1084), `ppage` (128) **stay sys-green**, and `make
verify` (boot_mode=user) is **GREEN and unchanged** (56/56 func diff-clean +
every M4/M5 cycle band met) — the HARD requirement, since all IDT delivery is
gated behind `sys_mode` (in `boot_mode=user`, `int 0x80` STILL HALTs — no IDT).

**What works (RTL EQUIVALENT to the qemu-system golden):**
- **IDT delivery micro-sequence** (`S_INT_GATE → S_INT_CS → S_INT_PUSH`): read
  the 8-byte IDT gate at `idt_base + v*8` (IDTR from `LIDT`, M2S.1) → extract the
  gate offset/selector and the gate type (`0xE` interrupt / `0xF` trap) → read the
  gate's **CS descriptor** from the GDT and load the hidden base/limit/attr + CPL
  exactly like a far jump → **push the exception frame** on `SS:ESP` (descending:
  EFLAGS @ ESP-4, CS @ ESP-8, EIP @ ESP-12, error code @ ESP-16 when present) →
  `ESP -= frame size`, `EIP ← gate offset`, retire ONCE. These reads/pushes are
  **paged** when `paging_on` (translated through the TLB/walk like any access).
- **Software `INT`/cond** (`S_DECODE`): `INT n` (`CD ib`), `INT3` (`CC`, vec 3),
  `INTO` (`CE`, vectors only when `OF=1`, else a no-op advance), `UD2` (`#UD`,
  vec 6). `INT n`/`INT3`/`INTO` are **TRAPS** → push the **NEXT** EIP (`IRET`
  resumes after the INT); `UD2` is a **FAULT** → push the **faulting** EIP.
- **Hardware faults DELIVER** via `start_fault(vec, has_err, err, fault_pc)`:
  `S_SEGLD`/`S_LJMP` raise `#GP/#NP/#SS` from `seg_load_fault`; `S_WALK` raises
  the **not-present `#PF`** (vector 14) with `CR2 ←` faulting linear + the
  `{US,RW,P}` error code. A FAULT always pushes the **faulting** EIP (restartable:
  the `pfault` handler maps the page, `IRET` re-runs the access).
- **Error code** pushed only for `#DF(8)/#TS(10)/#NP(11)/#SS(12)/#GP(13)/#PF(14)/
  #AC(17)` (generic `int_has_err`/`int_err`; #GP/#NP/#SS/#PF exercised). `INT n`/
  `INT3`/`INTO`/`#UD` carry none (correct — `INTO` `#OF` has no error code).
- **Gate-entry EFLAGS mask:** an **interrupt** gate clears `IF`+`TF` (and `NT/RF/
  VM`); a **trap** gate clears `TF` (and `NT/RF/VM`) but leaves `IF` (IA-32 6.12.1).
  The pushed EFLAGS is the PRE-clear value.
- **`IRET`** (`S_IRET → S_INT_CS_RET`): pop `EIP`, `CS`, `EFLAGS` (near, same-
  privilege), `ESP += 12`, reload the returned-to CS descriptor from the GDT, set
  EIP, restore EFLAGS. The handler-return register state + handler reads of the
  stack frame indirectly prove the pushed frame.

**Phase-3 adversarial review — found + fixed:**
- **[low, correctness] Gate-entry EFLAGS mask was incomplete (NT/RF/VM not
  cleared).** Gate entry cleared only `IF`+`TF` (int gate) / `TF` (trap gate);
  IA-32 6.12.1 also clears `NT`, `RF`, `VM` on **any** interrupt/trap-gate entry.
  **Fixed:** the masks are now `IF|TF|NT|RF|VM` (`0x0003_4300`, int gate) and
  `TF|NT|RF|VM` (`0x0003_4100`, trap gate). `NT/RF/VM` are 0 throughout the
  corpus (eflags = 0x202), so this is a no-op for the gate (it stays bit-exact
  EQUIVALENT) but makes the entry IA-32-correct for any future `TF`/`NT`/V8086 test.
- **[low, docs] Stale `Makefile` `verify-sys` comment contradicted the real gate.**
  The comment block claimed `pmode`/`ppage`/`pintr`/`pfault` were "golden self-diff
  only / RTL sys-diff SKIPPED / Phase-1", but `run-sys-golden.sh` step 7 runs a
  REAL RTL `--system` diff for ALL FIVE (each prints `RTL-SYS-DIFF-OK`). **Fixed:**
  rewrote the comment to describe the implemented gate (all five run the real RTL
  diff) so the gate is not mistaken for vacuous.
- **[low, docs] Misleading "delivery is M2S.3" comments on the still-undelivered
  per-access checks.** With this stage, the *segment-LOAD* faults and the
  *not-present* `#PF` now deliver, but the **per-access** `perm_fault` (present-page
  P/RW/US violation) and `seg_off_over_limit` (operand past the segment limit)
  remain **computed-not-delivered**. **Fixed** the comments (core.sv perm_fault +
  the lint sink) to state this honestly and re-tag those two as M2S.4 follow-ons,
  rather than implying M2S.3 delivers them.

**Deferred (honest done-partial; the gate does not exercise these):**
- **Cross-privilege (CPL>0) delivery + TSS stack switch** (load `SS:ESP` from the
  TSS, push the SS/ESP frame) and the cross-priv / NT / V8086 `IRET` return forms —
  **M2S.4** per spec. All handlers here are **CPL0 same-privilege**.
- **Gate descriptor protection checks** on delivery: gate **Present** bit (→
  `#NP(v*8+2)`), gate **DPL** for software `INT n` (`gate.DPL ≥ CPL` else
  `#GP(v*8+2)`), and the target **CS descriptor** via `seg_load_fault` (bad/absent
  CS → `#GP/#NP`). The CPL0 corpus uses all-present DPL0 gates + a present 32-bit
  code CS, so none can fire; a fault DURING delivery escalates to `#DF` (with
  cross-priv) = **M2S.4**. (Documented in `S_INT_GATE`.)
- **Per-access `#PF`/`#GP` that are COMPUTED-but-not-DELIVERED:** the
  permission-violation `#PF` (`perm_fault`: present page, US/RW protection fails —
  needs a CPL3 or `WP=1` test) and the segment-limit `#GP` (`seg_off_over_limit`:
  an operand past the segment limit). Both would require raising a fault from the
  combinational data path AND a corpus test that triggers them (none does) to
  differentially validate — documented M2S.4 follow-ons.
- **External/hardware interrupts** (no `INTR` pin / PIC) and **single-step `#DB`**
  (`TF` traps) — only software `INT`/`INT3`/`INTO` + the M2S.1/.2 hardware faults
  are exercised. **`BOUND` (`#BR` via `0x62`)** named in the spec is not in the
  corpus (decode not wired) — a future add. `#DF/#TS/#AC` and the other error-code
  vectors are wired generically (`int_has_err`/`int_err`) but only `#GP/#NP/#SS/
  #PF/#UD/#BP/#OF` are exercised.

**Next:** **M2S.4** — TSS / task switch / cross-privilege (the deferred cross-priv
stack switch, gate protection checks, per-access perm `#PF` / limit `#GP`).

### 2026-06-04 — M2S.2 done-partial: 2-level paging MMU + split I/D TLBs + A/D bits + #PF decision

The second **system-mode RTL** stage: the **2-level paging MMU**. The core now does
real linear→physical translation under `CR0.PG`, gated **differentially** against the
`qemu-system-i386` golden. Two paging tests now run as REAL RTL `--system` diffs (no
longer skipped/self-diff-only): **`pmode`** (M2S.0 bootstrap — identity-mapped **4 MiB
PSE** pages, the full real→PM→paging-enable→paged-execution sequence, **1084 records**)
and **`ppage`** (a focused **NON-IDENTITY 4 KiB** map — linear ≠ physical so a base-only
/ no-translation bug is caught, **128 records**), both **RTL EQUIVALENT** to the golden
across cr0..cr4 + the 6 selectors + GPRs + eflags + eip. `pseg` (M2S.1) **stays
sys-green** (70 records) and `make verify` (boot_mode=user) is **GREEN and unchanged**
(56/56 func diff-clean + every M4/M5 cycle band met) — the HARD requirement, since all
paging is gated behind `paging_on` (`CR0.PG & sys_mode`).

**What works (RTL EQUIVALENT to the qemu-system golden):**
- **2-level walk:** a TLB miss diverts the FSM to `S_WALK`, which reads
  `CR3`→PDE→PTE from physical memory (PDE @ `(CR3&~0xFFF)+lin[31:22]*4`, PTE @
  `(PDE&~0xFFF)+lin[21:12]*4`), forms the physical frame, and fills the TLB. 4 KiB
  pages (`ppage`) and 4 MiB pages (`CR4.PSE & PDE.PS`, `pmode`, PDE is the leaf,
  frame = `{pde[31:22],lin[21:0]}`).
- **Split I/D TLBs:** 16-entry direct-mapped, separate I-side (fetch) and D-side
  (data). A data load uses the D-TLB + D permissions; an icache fill uses the I-TLB.
- **A/D bits:** the walk writes `Accessed` (PDE+PTE) and `Dirty` (PTE/4 MiB-PDE on a
  write) back to the page tables in memory as qemu-system does; a first write to a
  clean-Dirty resident page re-walks to set D.
- **Permission DECISION** (P/RW/US): the effective `{US,RW,P}` is the AND of the PDE
  and PTE bits; a user (CPL==3) access to a supervisor page, or a write to a
  read-only page (user writer, or supervisor with CR0.WP), is a #PF DECISION. The
  gate runs at CPL=0 / WP=0 to present pages, so the decision is always "no fault".
- **#PF decision:** a not-present PDE/PTE sets `CR2` (faulting linear) + the
  `{US,RW,P}` error code; **delivery through the IDT is M2S.3**, so a raised #PF
  HALTs (the gate tests are fully mapped + never fault).
- **`CR0.PG=0` ⇒ linear == physical** (paging off path preserved; the M2S.1
  segmentation path and the user flat path stay bit-identical).

**Phase-3 adversarial review — found + fixed (each probed live):**
- **[high] Walk diversion wrote a spurious value to the untranslated LINEAR address
  on a TLB-miss write.** On a TLB miss the clocked FSM diverts to `S_WALK`, but the
  combinational bus driver was NOT gated on `xlate_miss`: during the diversion cycle
  `state` is still the write state, so the driver asserted `mem_req=1, mem_we=1` with
  `mem_addr = mem_xlate(linear)` — which on a MISS returns the **linear** address —
  and the single-beat memmodel committed that write immediately, BEFORE the walk
  filled the TLB. It was masked in `pmode` (the spurious linear==physical targets are
  never read back) but would silently corrupt the page tables or live data at a
  write's linear address. **Fixed:** the bus driver now SQUASHES the access entirely
  when `xlate_miss` (the walk owns the bus that clock; the access is re-driven against
  the correct physical frame when the FSM resumes). **Proven live** by instrumenting
  the memmodel on the `ppage` run: pre-fix it logged spurious LINEAR writes
  `0x00400000`, `0x00404000`, `0x00403000`; post-fix the ONLY writes to a
  freshly-walked page go to the correct PHYSICAL frames `0x00800000`/`0x00801000`/
  `0x00802000` — **zero** writes to the `0x004xxxxx` linear window.
- **[med] S_PIPE fast-path DATA load was routed through the I-TLB.** `cur_is_d` was
  hardcoded 0 (I-TLB) for `S_PIPE` with a comment claiming "only the icache fill reads
  memory here", but `S_PIPE` also issues register-base DATA loads (`pipe_load_req`).
  Under paging such a load was classified as a fetch — it filled/used the I-TLB and
  would apply I-side permissions, defeating the split I/D model and mis-targeting the
  future M2S.3 permission check. **Fixed:** `cur_is_d = pipe_load_req` for `S_PIPE` (a
  data load → D-TLB + D permissions; the icache fill → I-TLB; the two are mutually
  exclusive). The physical address was already computed correctly, so the gate is
  unaffected; this restores the correct TLB targeting.
- **[low] #PF error-code US bit was hardcoded supervisor (0).** Both not-present
  arms built the error code as `{1'b0, walk_is_write, 1'b0}`. **Fixed** to derive the
  US bit from the real CPL (`{cpl_r==3, walk_is_write, 1'b0}`); the gate runs at CPL=0
  so the value is unchanged for it, but it is now correct for M2S.3 delivery. (The full
  `pf_errcode` is now sunk in the lint sink, since delivery is M2S.3.)

**Deferred (genuinely-gnarly corners, consistent with done-partial; the gate avoids
them):**
- **#PF DELIVERY through the IDT** = M2S.3. A not-present PDE/PTE or a permission
  fault is genuinely **COMPUTED** (CR2 set, error code computed) but HALTs/sets `exc`
  rather than vectoring; delivery is the next stage.
- **A/D-bit memory writes** work and match qemu for the gate, but are **invisible to
  the gate diff** — the page tables are never read back into a register/selector, so
  the writes are exercised (and `ppage`'s first-write-sets-D re-walk runs) but not
  directly differentially-proven against the golden. (The [high] fix's live probe
  confirms the writes land at the correct physical PTE addresses.)
- **4 MiB NON-identity translation** is unproven: the only 4 MiB test (`pmode`) is
  identity-mapped (base 0), so a 4 MiB frame-masking bug would be masked there;
  `ppage` uses 4 KiB. **Page-split** accesses (a 4-byte access straddling a page
  boundary) are untranslated (translation keys on the access's starting word) — not
  exercised by the aligned gate tests.
- **Global pages** (`CR4.PGE` / `PTE.G`) and the **INVLPG** single-page flush are not
  modeled — only a full TLB flush on a `CR3` write; no gate test uses them.
- **TLB is a functional/correctness model only** (16-entry direct-mapped split I/D),
  NOT cycle-accurate — TLB-miss walk timing is not charged into the M5 cycle model
  (`cycle_mode` is 0 in the sys gate).
- **Real-mode A20 1 MiB wrap and seg:off-overflow** on the fetch linear remain
  unmodeled (pre-existing M2S.1 deferral; not exercised by any paging test).

**Lint clean** (`verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED`, 0
warn/err). **Files:** `rtl/core/core.sv` (bus-driver `xlate_miss` squash + `cur_is_d`
data-load classification + #PF US-bit from CPL + lint-sink update),
`verif/sys/run-sys-golden.sh` (already had `pmode ppage` un-skipped from Phase 2),
`PROGRESS.md`.

**Next:** **M2S.3** — interrupts / exceptions / IDT delivery. This turns the deferred
#PF (and the M2S.1 #GP/#NP/#SS segmentation) **DECISIONS** into real IDT-vectored
faults (gate descriptor read, CPL/stack switch, error-code push), and the A/D-bit and
permission-fault paths become differentially observable once a fault changes
architectural state.

### 2026-06-04 — M2S.1 done-partial: real→protected mode + protected-mode SEGMENTATION

The first **system-mode RTL** stage. The core now boots from the architectural
**cold-reset vector** (real mode, `CS:EIP=F000:FFF0`), runs real-mode code, makes
the **real→protected transition** (set `CR0.PE`, then a far jump that loads CS
from the GDT and switches to 32-bit PM), and does **protected-mode segmentation**
(MOV-Sreg / far-jump read the 8-byte GDT descriptor and load the hidden
base/limit/attr). Gated **differentially** against the `qemu-system-i386` golden
(M2S.0). `make verify-sys` runs the `pseg` segmentation test as a REAL RTL
sys-diff (RTL `--system` trace vs the golden, 70 records, **EQUIVALENT** across
cr0..cr4 + the 6 selectors + GPRs + eflags + eip); `pmode` (paging = M2S.2) keeps
its golden self-diff and the RTL sys-diff is correctly **SKIPPED**.

**Dual `boot_mode` (the crux) — user mode stays bit-for-bit GREEN.** A single
registered `sys_mode` bit selects the reset: `boot_mode=user` (DEFAULT, M0–M6
unchanged) resets to the TB-supplied `init_eip`/`init_esp` with flat 4 GB segments;
`boot_mode=system` cold-resets to the qemu-system state (`cr0=0x60000010`,
`EDX=0x663`, `eflags=0x2`, real mode). Every M2S addition is gated behind
`sys_mode`/`real_mode` so the user path is numerically identical — `make verify`
is **GREEN and unchanged** (every program diff-clean vs QEMU + every M4/M5 cycle
band met), the HARD requirement.

**What works (RTL EQUIVALENT to the qemu-system golden):**
- Cold reset + 16-bit real mode (linear = (seg<<4)+offset), `LGDT`/`LIDT`, MOV
  to/from CR0, the `66 ljmp ptr16:32` transition far-jump.
- Real→PM transition as two single-step-atomic retires (CR0.PE 0→1, then the
  CS far-jump) matching the golden.
- Protected-mode segment loads: flat code/data (0x08/0x10), a **based** data
  segment (0x18, hidden base 0x20000), a second based segment (0x28, base
  0x40000), and a read-only data segment (0x20) — hidden base/limit/attr loaded
  from the descriptor; PM linear = `seg.base + offset`. The hidden base is pinned
  **indirectly** (the gdbstub does not expose it) by flat read-backs of based
  stores; a **cross-base** check (two differently-based segments) catches
  base-extraction bugs that corrupt descriptors by different amounts.

**Phase-3 adversarial review — found + fixed (each probed live):**
- **[med] Protection checks were claimed but not computed.** The S_SEGLD/S_LJMP
  comments said present/type/DPL checks "are computed" while nothing was — and no
  CPL existed. **Fixed:** added `desc_present/dpl/s/type` + a real
  `seg_load_fault()` decision (null-SS/CS, P→#NP, S=0→#GP, SS=writable-data &
  DPL==CPL==RPL, DS/ES/FS/GS readable & max(CPL,RPL)≤DPL, CS=code), a per-access
  `seg_off_over_limit` limit decision, and `cpl_r` derived from CS.RPL on the far
  jump. The DECISION is fully computed; fault DELIVERY (vectoring) is M2S.3, so a
  raised decision HALTs loudly (never silently mis-loads). **Proven live:** forcing
  the CS descriptor not-present makes the far jump HALT at record 25 → gate RED;
  the clean pseg never trips it → GREEN. Comments rewritten to match reality.
- **[med] Hidden-base check masked a uniform base offset.** The flat read-back
  through ES cancels a base error applied IDENTICALLY to every descriptor (both
  the based store and the ES read-back shift together — a fundamental limit of any
  in-guest round-trip, since x86 always adds a base; only a direct hidden-base diff
  via HMP, deferred, catches it). **Strengthened:** added a second based segment
  (0x28, base 0x40000) + a CROSS-BASE store/read, which catches the realistic
  base-EXTRACTION bug class (different descriptors corrupted by different amounts).
  **Proven live:** a `desc_base` that drops base[23:16] now diverges the based
  read-backs (ebp/esi) → gate RED. The uniform-additive class is documented as the
  residual, awaiting the deferred HMP hidden-base diff.
- **[low] Stale gate docs.** The Makefile `verify-sys` comment said "the RTL is
  NOT yet involved" — stale; step 7 builds the TB and runs the real RTL sys-diff.
  Corrected the Makefile + run-sys-golden.sh comments.
- **[low] Real-mode A20/20-bit wrap** unmodeled — full 32-bit fetch add, correct
  for A20-enabled (the bootstrap's qemu-system default); documented as a deferred
  corner (pseg never wraps).
- **[low] Reset CS.base = 0x000F0000** (low alias) not the architectural
  0xFFFF0000 — equivalent for the `-bios` low-alias image layout (qemu reports
  cs=0xf000, fetch hits the correct reset bytes); documented simplification, kept.

**Deferred (genuinely-gnarly corners, consistent with done-partial; pseg avoids
them):** descriptor protection-fault DELIVERY (#GP/#NP/#SS vectoring through the
IDT) = M2S.3 (the DECISION is computed now, delivery is not); the 16-bit
register addressing modes ([bx+si] etc.) — only the [disp16] direct form the
bootstrap uses is implemented (others HALT loudly); **paging** (CR0.PG/CR3/CR4.PSE)
= M2S.2 (the `pmode` test keeps golden self-diff only; the RTL `--system` sys-diff
is correctly SKIPPED for it); IDTR is loaded by LIDT but interrupt/IDT delivery =
M2S.3; segment hidden base/limit/attr are exercised INDIRECTLY via addressing (the
gdbstub does not expose them — a direct diff awaits HMP `info registers` sourcing).

**Lint clean** (`verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED`, 0
warn/err). **Files:** `rtl/core/core.sv` (seg_attr/cpl_r state + desc_*/seg_load_fault
helpers + S_SEGLD/S_LJMP protection decisions + limit decision + comment fixes),
`verif/sys/tests/pseg/pseg.S` (+ second based descriptor + cross-base check),
`verif/sys/tests/pseg/manifest.json`, `verif/sys/tests/pseg/pseg.sys.vtrace.golden`
(regenerated snapshot), `Makefile` + `verif/sys/run-sys-golden.sh` (gate-doc fixes).

**Next:** **M2S.2** — paging + TLBs + MMU (CR0.PG/CR3, the 2-level page walk,
`rtl/mem/tlb.sv`, #PF + error code + CR2, A/D bits); the `pmode` test becomes its
differential gate. (M2S.3 then adds the fault-DELIVERY pipeline the M2S.1
protection decisions feed into.)

### 2026-06-04 — M6 done (PARTIAL): documented P5/P54C errata behind a stepping flag

M6 reproduces **documented Pentium silicon errata** in the RTL. It is — by the
nature of the task — a **partial, mostly-non-differential stretch milestone**, and
the report below states that plainly.

**The oracle problem (read first).** QEMU `-cpu pentium` computes the **correct**
result; it does **not** reproduce P5 silicon bugs. So there is **no differential
oracle** for errata: we cannot diff a "buggy" core against QEMU because QEMU is the
*correct* answer. M6 is therefore verified against the **DOCUMENTED behavior** in
the Intel Specification Updates (242480-022, 242480-041) via **self-checking**
tests that assert the documented buggy result occurs — never by diffing against
QEMU. This is a fundamentally weaker form of verification than M1–M5's differential
gate, and we do not claim otherwise.

**The errata-stepping flag (default OFF → clean core stays GREEN).** Errata are
SELECTABLE behind a 4-bit `errata_en` input on `rtl/core/core.sv` (plumbed through
`ventium_top` from the TB's `--errata <hexmask>`), **default `0`**. With
`errata_en==0` the datapath is the unmodified M0–M5 core, so **`make verify`
(errata OFF) stays fully GREEN** — the HARD requirement; reproducing a bug must
never regress the clean core. Bit map: `[0]` FDIV, `[1]` FIST, `[2]` F00F,
`[3]` MOFFS. `make m6` runs the suite with the relevant bit ON per test and
asserts both the documented defect (ON) and the clean result (OFF).

**Reproduced + self-checked vs documented values (`make m6` = 11/11 PASS):**

1. **Erratum 23 — FDIV / SRT divide flaw** (242480-022 printed p.78). Bit 0 /
   `--errata 0x1`. *Approach:* the SRT-flaw **model** path (bit-reproducing Intel's
   buggy SRT iteration for all operands) is **not faithfully verifiable** — Intel
   never published per-operand reduced-precision bits and QEMU is correct, so there
   is no oracle for an arbitrary operand. We therefore took the spec's explicit
   fallback: **reproduce the published failing operand**. The canonical public pair
   `4195835.0 / 3145727.0` is held in a table; errata ON returns the documented
   flawed quotient floatx80 `0x3fffaab7f6392a768800` (= `1.3337390689…`, double
   `0x3FF556FEC7254ED1`, wrong at the 13th significant binary digit — the documented
   severity); errata OFF returns the correct `0x3fffaabaa0e3e35a14bd` (= QEMU/M3
   bit-exact). We **deliberately do NOT fabricate** a quotient for any other
   triggering divisor (an earlier draft did; that invented Intel-undocumented values
   and was removed). Two **negative-control** self-checks confirm this: a divisor
   that *hits* the documented SRT trigger pattern but is *not* the published pair
   (`7654321.0/3145727.0`), and a non-triggering divisor (`/3.0`), both divide
   **bit-identically with the flag ON and OFF**. So the only injected error is the
   one published, self-checkable vector. *Honest limit:* the family-wide flaw is
   **not** claimed reproduced — only the single published operand is.

2. **Erratum 20 — FIST/FISTP overflow undetected** (242480-022 printed p.75).
   Bit 1 / `--errata 0x2`. Operand `4294967295.5` (documented 32-bit / round-nearest
   affected operand: unbiased exp 31, top 33 significand bits = 1), `FISTP m32`.
   Errata ON → stores `0x00000000` and IE bit = 0 (the documented **Actual**
   response); errata OFF → stores `0x80000000` (integer-indefinite) and IE = 1 (the
   documented masked **Expected** response). *Honest limit:* this reproduces
   **Erratum 20 only**. Erratum 21 ("Six Operands…", printed p.77 — the small
   ±0.0625/±0.125/±0.1875 up/down case with PE/C1 anomalies) is a **distinct**
   erratum and is **NOT** modelled; the label was corrected from "20/21" to "20".

3. **Erratum 81 — F00F LOCK CMPXCHG8B register destination** (242480-041 printed
   p.51). Bit 2 / `--errata 0x4`. Invalid sequence `F0 0F C7 C9`. Errata ON → the
   core latches `cpu_hung` and the TB prints `CPU HUNG … Erratum 81` (the documented
   system hang — never retires the offending op); errata OFF → loud HALT, no hang; a
   **valid memory** form `F0 0F C7 09` does **not** hang even with the flag ON.

4. **Erratum 59 — MOV moffs (A2/A3) fails to pair** (242480-022 printed p.99).
   Bit 3 / `--errata 0x8`, **cycle-mode** gate. An `A3` moffs store followed by an
   EAX-referencing `MOV`. Errata OFF → the follower PAIRS (cycle trace pipe=V,
   paired=true); errata ON → the follower does NOT pair (the documented false-EAX-
   dependency), retiring as its own U op on the next clock. moffs is fast-pathed
   cycle-mode only (func mode keeps the proven slow FSM → no functional risk).

**Page-citation note.** All in-code/README citations (FDIV p.78, FIST p.75/Err21
p.77, F00F p.51, moffs p.99) were re-verified against the printed-page footers of
the actual PDFs and are correct for these document revisions. The original M6 brief
listed different pages (p.82/p.82/p.105); `docs/m6-errata-spec.md` was corrected to
the verified printed pages.

**Deferred to M2S (documented but NOT verifiable here — no oracle / need system
infra):** all BTB multiple-allocation / BTB-flush, SMM / NMI / STPCLK# / RSM
(Errata 80, 2, 39, 49…), APIC and dual-processing (xAP/xDP) errata — need system
mode / bus / DP infra. CMPXCHG8B page-boundary #UD (Err 26), EIP corruption after
FP + MOV Sreg (Err 32), 0F-misdecode (Err 42) — need the exception/segment/cache-
line-alignment paths M2S builds. FBSTP A/D-bit on 16-bit wrap (Err 83) — needs
paging A/D bits. Debug-exception-on-POPF/IRET (Err 79) — needs debug + exceptions.
Timing / performance-counter errata — no oracle. Each is tracked under **M2S**.

**Honest verdict.** M6 is a partial, mostly-non-differential stretch milestone:
4 documented errata reproduced behind a default-OFF flag and self-checked against
the Spec-Update text (not QEMU), with the clean core proven untouched (`make
verify` GREEN). It does **not** model the full errata family for any erratum.

**Files:** `rtl/core/core.sv` (errata_en plumbing, F00F FSM hang, FIST/FDIV errata
dispatch, moffs non-pair), `rtl/fpu/fpu_x87_pkg.sv` (`fx_div_errata`,
`fist_errata_overflow`/`fx_to_int_errata`, `srt_flaw_divisor`),
`verif/errata/` (`run-m6.sh`, `README.md`, `err_fdiv`/`err_fdiv_neg`/`err_fist`/
`err_f00f`/`err_f00f_mem`/`err_moffs`), `docs/m6-errata-spec.md`.

**Next:** **M2S** (system mode — unlocks the deferred errata family + the integer
system-ISA gap) and **M5B-int** (wire the standalone pin-level bus into `rtl/`).

### 2026-06-04 — R1 done (gate speedup + RTL modularization; maintenance)

Two-part maintenance pass after the M0–M5 fidelity ladder, both serving direct
user requests (faster gates + a readable, partitioned RTL tree). Behavior is
**bit-for-bit unchanged** — proven by the differential gate.

**R1a — fast differential gate (`make verify`, commit 9fdee89).** `verif/verify.sh`
runs the full m1–m5 func+cycle verification **parallelized** (`gen_goldens.sh`,
30 workers), **golden-cached** (key = sha1 of the test `.s`; a golden depends only
on the program, not the RTL), and **de-duplicated** (no redundant 3× `make
m1/m2/m3`). Cold ~17 min (one-time parallel golden gen); **warm/refactor-time
~2 s** (goldens cached, RTL re-traced). Adversarially validated: verdict-equivalent
to the slow gate (no check weakened), and **mutation-tested** — a broken ALU_XOR,
a zeroed fadd latency, and a zeroed D-cache miss penalty each turn it RED in the
right failure class (re-confirmed in-hand: inverted `parity8` → FUNCTIONAL
REGRESSION caught; restore → GREEN). This permanently fixes the slow-sequential-
gate thrash that stalled M5, and M6/M2S/M5B-int will all use it.

**R1b — modularize `intcore.sv` (gate-protected, behavior-preserving).** Carved the
3648-line monolith using `make verify` GREEN after **every** extraction:
- **Packages:** `ventium_alu_pkg` (ALU/flags/shift/width-helper pure functions),
  `ventium_decode_pkg` (op/uop/micro/x87 enums + `fpd_t` struct + `mfl`/`is_prefix`/
  `cond_true`); explicit `rtl/ventium.f` filelist (packages before modules).
- **Modules:** `decode.sv` (variable-length decoder, instantiated ×2),
  `issue_uv.sv` (AP-500 U/V pairing checker).
- **Spine:** `intcore.sv` → **`core.sv`** (3146 lines, now mostly wiring + the
  pipeline FSM). Dropped the `-Wno-DECLFILENAME` lint waiver (file names now match
  module names); `verilator --lint-only -Wall -Wno-UNUSED` is 0 warn/err.
- **Deferred (honest):** `regfile`/`icache`/`dcache`/`fpu_unit`/`bpred_btb` — their
  state is written from ~100+ scattered sites inside the single shared pipeline
  `always_ff`, so extraction needs a *non-mechanical FSM re-architecture* (behavior-
  risky), not a refactor. One `bpred_btb` attempt was built then reverted to keep
  the tree green. These await a future pipeline-decoupling pass, not R1.

Adversarial review ran a full normalized diff of `core.sv` vs the pristine
pre-refactor monolith: every change is intended + behavior-preserving, every
extracted symbol byte-identical (no enum/width/struct drift). Independently
re-verified: `make verify` GREEN, build clean, lint clean.

**Next:** M6 (errata — oracle-limited), M2S (system mode), M5B-int (wire the bus
unit into `rtl/`). All now run on the fast gate.

### 2026-06-03 — M5 complete (L1 cache-miss timing + x87/FP cycle accuracy; tightened abs-cyc)

Extended the M4 dual-issue cycle model with the two pieces M4 deferred **and that
the `p5model` oracle can differentially verify** (`docs/m5-cycle-spec.md`):
**(1) L1 cache-miss cycle timing** and **(2) x87/FP latency + throughput +
occupancy** — both **EMERGENT** from real RTL state machines using the SAME
geometry/penalty as the oracle (`build/p5trace.so`: imiss=8, dmiss=8, 8 KB /
2-way / 32 B / 128 sets, misalign +3), never a formula copied from p5model. The
pin-level 64-bit bus protocol has **no oracle** and stays deferred to **M5B**.
Gate: `make m5` (= `bash verif/run-m5.sh`), exit 0. **Hard safety held: m1/m2/m3
stay func-diff-clean vs QEMU (53/53), and all five M4 integer bands stay met.**

**FP latency / throughput / occupancy (emergent).** The M4 FP serialize-stall is
replaced by a real scoreboard with **two distinct mechanisms**, mirroring the
oracle's `p5_insn_exec` (`verif/qemu-plugins/p5trace.c`):
- **Result LATENCY** (`fp_ready_cyc`): a dependent FP consumer stalls until the
  producer's result is ready (issue+lat). A dependent `fadd %st(1),%st` chain runs
  at **CPI 3.01** (fadd lat 3) — the headline gated band.
- **Pipe OCCUPANCY** (`fp_occ`, new): an FP op HOLDS the in-order pipe for `occ`
  clocks, so even a *following independent integer op* is delayed until occupancy
  expires (oracle `pipe_free_at = issue + occ`): `fdiv` occ 39, `fmul` occ 2,
  fadd/fsub occ 1. The op retires at issue+occ and `fp_ready` is anchored to the
  issue cycle. Independent FP pipelines at throughput 1 (`mb_fpindep` CPI **1.16**,
  far below the chain — latency-vs-throughput contrast).

**L1 cache miss timing (emergent).** Both caches are **2-way / 128-set / 32 B /
LRU** — the I-cache was rebuilt from M4's direct-mapped 256-line form to match the
oracle's associativity (set=addr[11:5], tag=addr[31:12], `victim = lru^1`), so the
miss SEQUENCE — not just the aggregate — agrees. An I-miss fills 8 words = imiss=8
clocks; a D-read-miss defers +dmiss to the next insn (read-allocate); misalign +3;
the 8-bank D-conflict +1 is kept from M4. Strided/oversized kernels show the
miss-driven CPI elevation (`mb_dmiss` CPI **2.50**, `mb_imiss` **6.01**) and their
absolute `cyc` tracks the golden to **≤0.14%**.

**Tightened abs-cyc (`M5_TOL_PCT=10%`, achieved figures — honest).** With the same
caches+FP timing modeled, the totals converge far inside the band: FP/cache
kernels `mb_faddchain` **+0.5%**, `mb_fpindep` **+2.1%**, `mb_dmiss` **+0.10%**,
`mb_imiss` **+0.14%**; integer kernels `mb_depadd` **+2.85%**, `mb_agi` **+2.84%**,
`mb_brloop` **+0.23%**, `mb_brrandom` **−0.86%**, worst-case `mb_indepadd`
**+6.16%** (unchanged structural path). No kernel needed a looser tolerance.

**Adversarial review — found + fixed** (each reproduced vs the p5model golden
first; functional correctness was paramount; each fix locked with a regression
kernel where applicable):
- **[high] FP unit OCCUPANCY/THROUGHPUT not modeled.** M4 charged only the result-
  latency consumer stall; an FP op retired in 1 clock and a *following independent*
  instruction issued immediately, so a single `fdiv` + independent integer work ran
  **~2× too fast** vs the oracle (fdiv occ 39, fmul occ 2 dropped). **Fixed:** added
  `fp_occ` and a real pipe-occupancy hold (the op retires at issue+occ; `fp_ready`
  anchored to issue). Reproduced: oracle single-fdiv+6 movs ≈ 54 cyc, RTL was ≈ 27
  → now matches per-op. Regression: `mb_fpocc` (fdiv/fmul + 8 independent movs;
  abs-cyc **−1.5%** vs golden).
- **[med] Unconditional short JMP (EB) never filled the V slot.** The oracle makes
  JMP `pclass=PV`/`pairs_second` (V-only-pairable, like Jcc). M4 set
  `pairs_second=0`, so `<UV op>; jmp` groups (e.g. the assembler's `.p2align`
  `mov; jmp` filler) never paired, costing a clock per group. **Fixed:** EB
  `pairs_second=1`; and an unconditional-jmp mispredict now costs 3 (oracle
  `P5_MISPREDICT_UNCOND`), not the V-cond 4 (the old V-branch always charged 4).
  Regression: `mb_jmppair` (abs-cyc **+1.6%**).
- **[med] FLD-const lat/occ should be 2.** FLDZ/FLD1/FLD<const> are occ=2/lat=2 in
  the oracle (vs lat=1 for FLD ST(i)/FLD mem). M4 conflated them. **Fixed.**
- **[med] I-cache direct-mapped vs oracle 2-way.** Different associativity → a
  different hit/miss sequence for conflict-prone/partially-resident working sets.
  **Fixed:** I-cache rebuilt as 2-way/128/LRU (`ic_present`/`ic_hit_way`/`ic_byte`/
  `ic_touch` + 2-way fill victim). `mb_imiss` miss count now matches the oracle
  exactly (2010/2010) where before the geometries diverged.
- **[med] Stores + slow-path disp/SIB loads bypassed the D-cache model.** The
  oracle's `p5_mem` runs `l1_access` for STORES too (read-allocate: allocate/LRU,
  no miss penalty) and for all loads. M4 mutated the D-cache only from fast-path
  register-indirect loads, so a line a store warmed was wrongly counted a miss.
  **Fixed:** slow-path S_LOAD/S_STORE run `dc_access` (+dmiss/misalign deferral on
  loads; allocate-only on stores, cycle-mode-gated). Regression: `mb_dstore`
  (199/200 reg-indirect loads HIT because the preceding stores warmed the lines —
  the divergent-miss-sequence bug is gone; abs-cyc there is dominated by the
  slow-path disp-store cost, an M4 cycle-approximation, so the regression checks
  STATE consistency, not abs-cyc).
- **[med] I-miss off-by-one + over-eager straddle.** M4 burned a non-fetching
  S_PIPE→S_PF transition clock (effective ~9 not 8), and `pipe_bytes_ok` always
  required BOTH `ic_present(eip)` and `ic_present(eip+11)`, charging a second-line
  I-miss for short instructions near a line end that don't straddle. **Fixed:** the
  detection clock now issues the fill's word-0 read (so a miss = exactly 8 clocks);
  the straddle line is required only when `(eip&31)+len > 32` (matching the
  oracle's real straddle test). Effect: `mb_imiss` +16.8%→**+0.14%**, and every
  kernel's startup cold-miss offset shrank.
- **[low] FK_ARITH fast path had no precision-control guard.** The slow path HALTs
  (Tier-3 deferral) on an arithmetic op under PC≠extended; the cycle-mode fast path
  silently used full extended precision → potential functional divergence vs QEMU's
  programmed-precision rounding. **Fixed:** the fast-path FK_ARITH now HALTs under
  `fctrl[9:8]!=11`, matching the slow path (default cw 0x037f is PC=11, so gate
  kernels are unaffected).
- **[low] Terminating `int 0x80` dropped its retire record (cycle mode).** The
  oracle emits a record for the syscall; the RTL halted without one, so the cycle
  trace was one record short (a `compare.py` LENGTH MISMATCH). **Fixed (cycle-mode
  only):** a genuine HALT syscall (`int 0x80`) emits one retire then stops;
  `d_unknown` (out-of-scope opcode) stays a LOUD no-retire HALT. Func mode keeps the
  QEMU-gdbstub convention (no exit-syscall row), so the functional gates are
  unaffected; `mb_imiss` now emits 4019 records = the golden 4019.

**Functional correctness preserved by construction + verified.** Cache/FP timing
changes ONLY cycle accounting (stalls), never architectural results; the FP fast
path reuses the exact M3 `floatx80` helpers and is gated on `cycle_mode` (func runs
keep FP on the proven slow FSM). The 2-way I-cache delivers the same bytes (only
the LRU/timing changed). Verified: `make m1`/`m2`/`m3` all exit 0 (53/53
func-diff-clean vs QEMU), and the five M4 integer bands stay met from the now
cache-aware RTL. RTL stays **lint-clean** (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**How to run:** `make m5`. It (a) runs `make m1 && m2 && m3` (HARD functional
regression), then (b) builds the TB and for each kernel generates the p5trace.so
golden + RTL `--cycle` traces, runs `compare.py --mode cycle` at the tightened
`M5_TOL_PCT=10%`, and asserts the M4 integer bands + the new M5 FP/cache bands
(computed by `m5_metrics.py`, which delegates to `m4_metrics` for the integer
kernels). Exit 0 iff func-green AND every gated band met.

**Honest caveats (PLAN §8 / `docs/m5-cycle-spec.md`).** The cycle oracle
(`p5model`) is itself an **estimate** of documented P5 timing rules, not silicon;
the miss penalty (imiss/dmiss=8) is a p5model **assumption**, not a documented P5
constant — matching it is estimate-vs-estimate, and we claim structural fidelity
(same caches/FP timing/components), not bit-true silicon timing. The **pin-level
64-bit bus protocol is deferred to M5B** (no differential oracle; structural +
local-SVA only). The serialized slow path (mul/div/string, disp/SIB loads, stores,
rel32/indirect/call/ret branches) stays functionally exact but **cycle-approximate
by design** — `mb_dstore`'s abs-cyc reflects that, hence its STATE-only check.

**Next:** M6 — errata & stepping fidelity (targeted errata repro). **M2S** (system
mode) and **M5B** (pin-level bus) remain no-oracle deferred milestones.

### 2026-06-03 — M4 complete (dual-issue U/V pipeline + branch prediction; first CYCLE milestone)

Turned the single-issue multi-cycle functional core into a **real in-order
5-stage dual-issue (U/V) integer pipeline** whose **emergent** cycle behavior
matches the `p5model` cycle oracle on the canonical integer microbenchmarks,
**while the M1/M2/M3 functional gates stay green** (the hard safety rule).
Gate: `make m4` (= `bash verif/run-m4.sh`), exit 0.

**The pipeline (emergent-not-faked, `docs/m4-pipeline-spec.md`).** The control is
reorganized into PF/D1/D2/EX/WB stages with **two pipes (U & V)**; the cycle
counts *fall out* of the structure, they are not computed from the p5model
formula. The proven M1–M3 execute/flag/FPU datapath is **reused unchanged**, so
functional behavior is preserved bit-for-bit.
- **Fast path (`S_PIPE`, `rtl/core/intcore.sv`):** simple/pairable insns
  (ALU reg/imm, MOV, LEA, INC/DEC, TEST, NOP, shift-by-imm, reg-base load, Jcc/JMP
  rel8) flow through the pipe at up to **2 insns/clock**. A combinational
  **pairing checker** (`fp_can_pair`, mirrors the p5model *rules*, never its
  formula) admits a V member only when: both simple, U is a U-member & V a
  V-candidate, no disp+imm, no GP RAW/WAW (ESP/flags excepted). Pairing classes
  follow AP-500 / `docs/ap500-pairing-table.md`: **UV** (ALU/MOV/LEA/INC/DEC/TEST),
  **PU = U-only-pairable** (ADC/SBB, shift-by-imm — lead a pair, never fill V),
  **V-only** (simple near branch). **Bypass:** the dependent `add`-chain runs at
  1/clk while independent adds pair (depadd vs indepadd). **AGI:** a 1-cycle
  interlock fires when an address base/index reg was written in the immediately
  preceding clock. **Branch prediction:** a 64-set×4-way **BTB with 2-bit
  saturating counters**, looked up in D1; miss ⇒ predict not-taken; first-taken
  **allocates strongly-taken (ctr=3)**; mispredict penalty 3 (U) / 4 (V) bubbles.
- **Serialized (slow) path:** complex/microcoded insns (mul/div/string/shift-CL/
  rotates/x87/etc.) issue **alone** on the existing multi-cycle FSM and hold the
  pipe until done — functionally exact, cycle-approximate (fine for M4, whose
  bands use only simple-ALU/branch streams; FP/cache cycle = M5).

**RTL cycle-trace producer (Producer C, cycle mode).** The core conveys
**pipe** (U/V) and **paired** to the TB via the retire path; `tb_ventium --cycle`
emits a `mode:"cycle"` vtrace `{n, pc, cyc=clock-at-retire, pipe, paired}`
(`docs/trace-format.md` §2.3) — a paired issue gives both members the same `cyc`
and `paired:true`. Default mode still emits the func trace (func gates unchanged).
`verif/m4_metrics.py` derives CPI / pairing% / AGI-stall% / mispredict% **from the
RTL trace** (only per-insn *identity* — is-this-a-branch — is borrowed from the
golden's `bytes`; every cycle *cost* is the RTL's), and checks the
`55-validate-model.sh` bands.

**Measured per-kernel metrics vs the p5model bands** (`make m4`, all GATED bands
met — EMERGENT from the RTL pipeline):

| kernel | band | RTL measured | verdict |
|---|---|---|---|
| `mb_depadd`   | CPI 0.97–1.10 & pairing <2% | CPI **1.080**, pairing **0.6%** | PASS |
| `mb_indepadd` | CPI 0.48–0.62 & pairing >40% | CPI **0.590**, pairing **49.5%** | PASS |
| `mb_agi`      | AGI stalls >20% of insns | AGI **49.9%** (1208/2419) | PASS |
| `mb_brloop`   | mispredict <2% | **0.2%** (7/3004 branches) | PASS |
| `mb_brrandom` | mispredict >20% | **61.0%** (244/400 branches) | PASS |

INFO-only (not gated): `mb_agiloop` (looped-AGI regression, see below) RTL CPI
**1.010** vs golden **1.013**, AGI fires **99.8%** of loop iterations;
`mb_faddchain` is FP, deferred to M5.

**Emergent-real vs approximate (honest).** *Real* and matched to the oracle: U/V
pairing decisions & pairing%, the 2-insn/clk vs 1/clk vs serialized cadence,
EX/WB bypass, the AGI interlock, and BTB 2-bit prediction (per-PC mispredict
counts match the oracle exactly on `mb_brloop`: inner 5/3000, outer 2/4).
*Approximate*: absolute cumulative `cyc` carries a fixed offset because p5model
charges an **icache cold-miss (imiss=8) per first-touched line** that the M4 RTL
(cache cycle = M5) does not model — so `compare.py --mode cycle` runs at a
generous structural tolerance (T=50%, pc-alignment / retire-order / no per-insn
blow-ups) and the **tight 55-validate bands are the real verdict**. The
serialized slow path (mul/div/string/x87, and rel32/indirect/call/ret branches)
is functionally exact but cycle-approximate by design.

**Adversarial review — found + fixed** (each reproduced vs the cycle golden /
QEMU first; functional-correctness fixes locked with a regression program):
- **[high] ADC/SBB pairable into V → pairing mislabel + ARCH CORRUPTION.** The
  fast-path decoder set `pairs_second=1` for all ALU ops incl. ADC(op2)/SBB(op3),
  so they could issue into V. p5model makes them **PU = U-only-pairable**
  (`pclass=PU`); pairing into V both inflated pairing% and shifted per-insn cyc.
  Worse, the V ALU path has **no carry-in forwarding**, so a paired `add(U)/adc(V)`
  computed the adc with the **stale architectural CF** instead of the carry U just
  produced — live arch corruption (invisible to func gates since func mode never
  pairs, and to the cycle compare which checks only pc). **Fixed:** ADC/SBB are
  now `pairs_second=0` (U-only-pairable) at all three decode sites (`00??_?001`,
  `00??_?011`, `0x83 /2,/3`), exactly the P5 rule — which also removes the
  corruption (an adc/sbb can never sit in V; the only V-pairable ALU ops do not
  consume CF). Verified: the cycle pairing structure now matches the golden
  with **0 pipe/paired mismatches** on a add/adc test, and the arch state is
  **func-equivalent vs QEMU**. Regression: `verif/tests/t_adcpair` (64-bit
  add/adc + sub/sbb carry-chains, reg & imm forms; func-diff-clean vs QEMU).
- **[med] BTB first-taken allocated weakly-taken (2) not strongly-taken (3).**
  Diverged from the oracle (`p5model.c:371 ctr=3`): after a loop-exit not-taken
  the RTL counter went 2→1 (predict not-taken) and re-mispredicted the next loop
  entry. **Fixed** to allocate ctr=3; per-PC mispredict counts on `mb_brloop` now
  match the oracle exactly (inner 5/3000, outer 2/4).
- **[med] Phantom AGI after a slow-path divert.** `agi_wr*` (regs written last
  fast clock) were not cleared when a non-simple insn diverted to the slow FSM, so
  on return the first insn could take a phantom 1-cycle AGI stall. **Fixed:** clear
  `agi_wr0/agi_wr1` on the divert. Verified vs the golden (`mov(base)` after a
  `mul` now costs 1, not 2).
- **[med] Looped-AGI undercount.** A per-PC suppressor (`agi_stalled_eip`, set once
  and never reset) charged a static AGI site inside a loop only on the FIRST
  iteration. **Fixed:** removed the suppressor — the stall now fires every time the
  hazard exists (the immediate double-charge is prevented *structurally* because
  the stall clock clears `agi_wr*`), matching p5model's per-issue
  `reg_wcycle==issue-1` check. Regression: `verif/tests/mb_agiloop` (INFO kernel;
  AGI fires 99.8% of iterations, RTL CPI 1.010 ≈ golden 1.013).
- **[low] rel32 / indirect / CALL / RET branches: no BTB modeling.** The fast path
  decodes only rel8 Jcc/JMP; wider/indirect/call/ret run the slow FSM with no
  prediction. **Dispositioned (documented tradeoff, not a corruption):** the
  serialized path is cycle-approximate by design and the integer gate uses only
  rel8 Jcc; functionally these branches are exact. Flagged for M5+ when real-code
  cycle fidelity (rel32-dominated) matters.
- **[low] `retire2_state` hardwired to the primary U `snap`.** Harmless today
  (the cycle compare checks only pc for the V member) but a latent trap if
  dual-issue were ever state-checked. **Fixed (guard):** added a sim-only
  assertion (`synopsys translate_off`) that trips if a paired V retire is ever
  emitted in func mode (`cycle_mode=0`), locking the cycle-only invariant; pairing
  is already structurally gated on `cycle_mode`.

**RTL stays lint-clean** (`verilator --lint-only -Wall -Wno-DECLFILENAME
-Wno-UNUSED`, exit 0, no warnings).

**How to run:** `make m4`. It (a) runs `make m1 && make m2 && make m3` (HARD
functional regression — a pipeline that breaks func-equivalence FAILS M4
regardless of cycle bands) then (b) for each integer microbench builds the ELF,
ISA-verifies it, generates the `p5trace.so` golden cycle vtrace and the RTL
`--cycle` vtrace, runs `compare.py --mode cycle` (structural) and asserts the
55-validate bands computed from the RTL trace. Exit 0 iff func-green AND every
gated integer band met.

**Honest caveat (PLAN §8).** The cycle oracle (`p5model`) is itself an **estimate**
of documented P5 timing rules, not silicon. M4 "cycle accuracy" = the RTL pipeline
matches those rules as captured by p5model, within tolerance — not bit-true to a
real chip. **x87/FP cycle accuracy and cache/bus timing are M5**, not M4: the FPU
stays functionally correct (M3 green) but serializes the pipe; its cycle count is
not yet matched. No assertion that the serialized slow-path cycle counts match the
oracle (they are approximate by design).

**Next:** M5 — cache/bus timing + x87/FP cycle accuracy (the `faddchain` CPI~3
kernel and the icache cold-miss offset folded into the cycle model).

### 2026-06-03 — M3 complete (x87 FPU functional core, bit-exact vs QEMU)

Added the **x87 floating-point unit** to the single-issue core and verified the
x87 architectural state **diff-clean vs QEMU** (`compare.py --mode func` exit 0).
**M3 = the x87 functional core: data movement + normal-operand arithmetic,
bit-exact vs QEMU's softfloat `floatx80`. Transcendentals and exotic corners are
deferred (and HALT loudly).** Gate: `make m3` (exit 0). `make m2` / `make m1` /
`make m0-smoke` all still pass; RTL stays lint-clean (`verilator --lint-only
-Wall -Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**The x87 FPU** (`rtl/core/intcore.sv` FSM + `rtl/fpu/fpu_x87_pkg.sv` datapath):
- **Register stack model**: 8×80-bit physical regfile with a 3-bit `TOP`; `st(i)`
  = `fpr[(TOP+i)&7]`; push = `TOP--`, pop = `TOP++`; an 8-bit per-register valid
  tag (`fptag`, 1=empty) drives FXAM's empty class and FFREE.
- **Status word** (`fstat`): condition codes C0/C2/C3 (compares/classify), the C1
  bit, and the masked exception flags IE/ZE/PE accumulated sticky; the retire
  snapshot overlays `TOP` into bits[13:11] exactly as QEMU's gdbstub reports it.
- **Control word** (`fctrl`): FLDCW/FNSTCW; reset/FNINIT = `0x037f` (RC=00
  nearest, PC=11 64-bit, all six masks set). RC (rounding control) is fully
  honored by the datapath (see below).
- **Tag word**: QEMU's user-mode gdbstub abridges `ftag` to `0x0000`, so the RTL
  reports `0x0000` (confirmed across empty/full-stack/FFREE/after-pop probes) —
  we reproduce **what QEMU reports**, not the architectural 2-bit-per-reg tag.
- **80-bit datapath** (`fpu_x87_pkg.sv`): a self-contained `floatx80` engine —
  add/sub (aligned 128-bit significand, RNE/directed round-pack), multiply
  (64×64→128), divide (long division with an exact-remainder sticky), sqrt
  (256-bit restoring integer sqrt + sticky), and float32/64↔floatx80,
  int16/32/64↔floatx80 conversions. The canonical layout (sign|exp in [79:64],
  mantissa in [63:0]) is the SAME encoding `gen_trace --x87` emits, so the st-reg
  hex strings compare directly.

**Trace infrastructure** (the second DPI hook, per `rtl-interface.md` §2 /
`trace-format.md` §2.2): the core calls `vtm_retire_x87` on the same retirement
as `vtm_retire`, carrying the post-commit x87 state (st0..st7 as packed 80-bit,
`fctrl`/`fstat`/`ftag`); the TB buffers both and emits ONE func record with the
x87 fields, and the RTL trace header declares `x87:true`. `fop`/`fiseg`/`fioff`/
`foseg`/`fooff` are reported 0 (matches QEMU user-mode, which does no FP ptr
tracking). The golden side uses the already-committed `gen_trace.py --x87`
i387/tail-anchor fix (commit c39905b). `compare.py` compares the full x87 set iff
BOTH headers say `x87:true`; the 28 integer programs keep `x87:false` and are
unaffected.

**Tier-1 / Tier-2 coverage — bit-exact vs QEMU** (the 14-program x87 corpus):
- **Tier 1** (data movement, stack, status/control, compares, classify): FLD/FST/
  FSTP (m32/m64/m80 + `st(i)`), FILD/FIST/FISTP (m16/m32/m64), FXCH, FFREE,
  FINCSTP/FDECSTP, FNOP; the seven constants FLDZ/FLD1/FLDPI/FLDL2E/FLDL2T/FLDLG2/
  FLDLN2; FABS/FCHS; FCOM/FCOMP/FCOMPP, FUCOM/FUCOMP/FUCOMPP, FTST, FXAM, FICOM/
  FICOMP; FNSTSW ax/m16, FNSTCW/FLDCW, FNINIT, FNCLEX, FWAIT.
- **Tier 2** (normal operands, default control word): FADD/FSUB/FSUBR/FMUL/FDIV/
  FDIVR (+ `p`/`ip` and memory/int FIADD… forms), FSQRT — round-to-nearest-even,
  64-bit precision, bit-exact.
- **Tier 3 pulled INTO the gate this phase**: non-default **rounding** control
  (RC = toward-zero / toward +inf / toward -inf) at 64-bit precision; masked
  special-operand arithmetic (x/0, 0/0, sqrt of a negative / of -0).

**Adversarial review — found + fixed** (each reproduced against QEMU with a tiny
program first, fixed, then locked with a new gated regression program; the FSQRT
clear-codes/C2 behavior was discovered while reproducing finding 1):
- **[high] FXAM on an Infinity** — `fxam_codes` returned the WRONG class encoding
  for Inf (C3+C0 = 0x4100; the in-code comment was self-contradictory). QEMU's
  `helper_fxam_ST0` sets **0x500 (C2+C0)** for Inf. Fixed the Inf branch.
  (Reproduced: `fxam` on +Inf → QEMU fstat=0x3d00; pre-fix RTL=0x7900.) Locked by
  `tx_fxam` (every FXAM class incl. ±Inf/QNaN/±0/normal/empty).
- **[med] FST/FIST store flags** — the store path never set PE (precision/inexact)
  on a rounding FST m32/m64 or non-integer FIST, and never set IE + integer-
  indefinite on an out-of-range FIST. QEMU's helper_fst*/fist* latch these via
  `merge_exception_flags`. Added `_ex` conversion variants returning inexact (and
  invalid+indefinite for FIST overflow), latched into `fstat` at store dispatch.
  (Reproduced: `fstps` of 1.2345678901234567 → QEMU fstat PE=0x0020; FIST of 2.5
  → PE; FIST m16 of 100000 → IE + 0x8000.) Locked by `tx_storeflags`.
- **[med] arithmetic under non-default RC/PC** — the datapath was hard-wired to
  RNE/64-bit and silently ignored `fctrl`. **Fixed RC fully** (round-pack now
  takes the RC field; toward-zero/+inf/-inf verified bit-exact for all of add/sub/
  mul/div/sqrt incl. the signed-zero cancellation cases). **PC (precision)** other
  than 64-bit is now a DEFERRED Tier-3 corner that **HALTs loudly** at the
  arithmetic op (rather than silently mis-rounding). (Reproduced: 10/3 under RC=11
  matches QEMU; PC=53-bit arithmetic correctly produces a length-mismatch FAIL,
  not a false pass.) Locked by `tx_round`.
- **[low] FDIV by zero / 0÷0 / FSQRT of a negative** — `fx_div` divided by mb=0
  (X in sim) and `fx_sqrt` of a negative returned sqrt(|x|) with a forced-positive
  sign. With masked exceptions QEMU produces: x/0 → signed Inf + ZE; 0/0 →
  real-indefinite QNaN (0xffff_c000000000000000) + IE; sqrt(−x) → real-indefinite
  QNaN + IE + C2; sqrt(−0) → −0 + C2. Implemented all four bit-exact (guarded the
  datapath against /0 and negative-sqrt as defense-in-depth). Locked by
  `tx_special`. (`helper_fsqrt` also clears 0x4700 and sets C2 whenever ST0's sign
  bit is set — reproduced and matched.)
- **[low] FCOM vs FUCOM #IA on NaN** — one shared `fcom_codes` produced correct
  C-codes but never raised IE. QEMU's signaling compares (FCOM/FCOMP/FCOMPP/FTST/
  FICOM, `floatx80_compare`) raise IE on ANY NaN; the quiet compares (FUCOM/
  FUCOMP/FUCOMPP, `floatx80_compare_quiet`) raise IE only on a SIGNALING NaN.
  Added SNaN/QNaN classifiers and a per-op signaling flag; IE latched accordingly.
  (Reproduced: FCOM vs QNaN → IE; FUCOM vs QNaN → no IE; FCOM/FUCOM vs SNaN(m80)
  → IE both.) Locked by `tx_fcomnan`.

**DEFERRED — loud HALT, never a false pass** (confirmed each retires the
preceding ops then STOPS, yielding a length-mismatch FAIL — verified for FSIN,
FRNDINT, FXTRACT, FPREM):
- **Transcendentals** FSIN/FCOS/FSINCOS/FPTAN/FPATAN/F2XM1/FYL2X/FYL2XP1 — QEMU
  computes these with its own approximation; matching it bit-exact ≠ matching a
  real Pentium, so deferred to a later ulp-tolerance oracle. HALT.
- **BCD** FBLD/FBSTP; **environment/state** FSAVE/FRSTOR/FLDENV/FNSTENV (28/108-
  byte memory images). HALT.
- **FCMOVcc / FCOMI / FUCOMI** register forms (P6+ extensions, not core P5
  user x87 in the corpus). HALT.
- **Tier-3 numeric ops** FPREM/FPREM1/FRNDINT/FSCALE/FXTRACT. HALT.
- **Non-default PRECISION control (PC ≠ 11 / 64-bit)** at an arithmetic op — the
  datapath implements full extended precision only; rather than silently
  mis-rounding to 53/24-bit, the core HALTs. (RC directed rounding IS supported.)
- **Unmasked numeric exceptions / #MF delivery** — not implemented; the corpus
  keeps exceptions masked (default cw) and avoids faulting operands. FWAIT is a
  no-op (no SE is ever set in the masked corpus).

**Harness:** `run-m3.sh` is the differential gate (per-program `x87:true` via an
optional `"x87"` manifest field; everything else identical to `run-m2.sh`).
`run-m1.sh` was also taught to build any discovered program's ELF/flat
generically from the manifest `src` (mirroring run-m2/run-m3) when the tests
Makefile didn't pre-build it — this enrolls the x87 corpus in the M1 integer gate
too (the x87 programs run as integer streams there and pass), so `make m1` is
green again (it was failing on the auto-discovered x87 dirs before, an
infrastructure gap independent of the RTL).

**How to run:** `make m3` (= `bash verif/run-m3.sh`). For each program discovered
from `verif/tests/**/manifest.json` it builds the ELF, ISA-verifies it, flattens
it, generates the QEMU golden (with `--x87` for x87 programs), runs the RTL TB
(`--x87`, init-ESP from the golden n=0), runs `compare.py --mode func`, and
asserts exit 0 for all.

**Observed result** (`make m3` from a clean TB build, exit 0):

```
    PROGRAM          MODE  RESULT DETAIL
    -------          ----  ------ ------
    smoke            int   PASS   func-equivalent (22 insns max)
    t_bit            int   PASS   func-equivalent (55 insns max)
    t_branch         int   PASS   func-equivalent (43 insns max)
    t_callret        int   PASS   func-equivalent (35 insns max)
    t_carry          int   PASS   func-equivalent (40 insns max)
    t_div            int   PASS   func-equivalent (60 insns max)
    t_ext            int   PASS   func-equivalent (50 insns max)
    t_leave16        int   PASS   func-equivalent (25 insns max)
    t_loop16         int   PASS   func-equivalent (60 insns max)
    t_loop2          int   PASS   func-equivalent (65 insns max)
    t_loop           int   PASS   func-equivalent (78 insns max)
    t_mem            int   PASS   func-equivalent (25 insns max)
    t_mixed          int   PASS   func-equivalent (200 insns max)
    t_moffs          int   PASS   func-equivalent (30 insns max)
    t_mul            int   PASS   func-equivalent (60 insns max)
    t_op16b          int   PASS   func-equivalent (60 insns max)
    t_op16           int   PASS   func-equivalent (60 insns max)
    t_op8            int   PASS   func-equivalent (64 insns max)
    t_partial        int   PASS   func-equivalent (44 insns max)
    t_prefix         int   PASS   func-equivalent (44 insns max)
    t_rep            int   PASS   func-equivalent (85 insns max)
    t_rotate         int   PASS   func-equivalent (68 insns max)
    t_setcc          int   PASS   func-equivalent (65 insns max)
    t_shift          int   PASS   func-equivalent (67 insns max)
    t_shld           int   PASS   func-equivalent (44 insns max)
    t_stack          int   PASS   func-equivalent (45 insns max)
    t_string         int   PASS   func-equivalent (50 insns max)
    t_unary          int   PASS   func-equivalent (80 insns max)
    tx_addsub        x87   PASS   func-equivalent (80 insns max)
    tx_chain         x87   PASS   func-equivalent (70 insns max)
    tx_cmp           x87   PASS   func-equivalent (45 insns max)
    tx_const         x87   PASS   func-equivalent (35 insns max)
    tx_ctl           x87   PASS   func-equivalent (30 insns max)
    tx_fcomnan       x87   PASS   func-equivalent (50 insns max)
    tx_fxam          x87   PASS   func-equivalent (40 insns max)
    tx_ldst          x87   PASS   func-equivalent (25 insns max)
    tx_muldiv        x87   PASS   func-equivalent (90 insns max)
    tx_round         x87   PASS   func-equivalent (45 insns max)
    tx_special       x87   PASS   func-equivalent (45 insns max)
    tx_sqrt          x87   PASS   func-equivalent (70 insns max)
    tx_stack         x87   PASS   func-equivalent (33 insns max)
    tx_storeflags    x87   PASS   func-equivalent (40 insns max)

    totals: 42 PASS / 0 FAIL / 42 total
M3 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

**Honest coverage statement:** M3 is the x87 **functional core** — the register
stack, status/control/tag words, and a `floatx80` datapath that is **bit-exact vs
QEMU** for data movement and **normal-operand** arithmetic under the default
control word, plus directed rounding (RC) and the masked special-operand cases
above. **Transcendentals, BCD, FSAVE/FRSTOR/FLDENV/FNSTENV, unmasked exceptions
(#MF), the P6 FCMOV/FCOMI forms, the Tier-3 numeric ops (FPREM/FRNDINT/FSCALE/
FXTRACT), and non-default precision control all HALT loudly** — never silently
mis-executed. No pipeline / U-V pairing / branch prediction / cycle accuracy yet
(M4/M5); M3 is functional-only.

**Next:** M4 — dual-issue U/V pipeline + instruction pairing + branch prediction
(the first CYCLE milestone: µbench CPI/pairing/mispredict matched against
`p5model`).

### 2026-06-02 — M2 complete (user-mode integer ISA completeness, func-equiv vs QEMU)

Extended the M1 single-issue core to the **complete user-visible integer ISA**
(`docs/m2-isa-spec.md`). **Every program in the corpus (M0/M1 baseline + the M2
corpus = 28 programs) is func-diff-clean vs QEMU user-mode** (`compare.py --mode
func` exit 0, no length mismatch). Gate: `make m2` (exit 0). `make m1` and
`make m0-smoke` still pass; RTL stays lint-clean (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**Instruction groups now implemented** (on top of the M1 ALU/MOV/LEA/PUSH/POP/
INC/DEC/TEST/Jcc/JMP subset): shifts & rotates `D0/D1/D2/D3`, `C0/C1` (ROL/ROR/
RCL/RCR/SHL/SHR/SAL/SAR, count `& 0x1f`, count==0 ⇒ no flag change) and
`SHLD/SHRD` (`0F A4/A5/AC/AD`, register destination); MUL/IMUL/DIV/IDIV
(`F6/F7 /4../7`, EDX:EAX), two-/three-operand IMUL (`0F AF`, `69`, `6B`);
MOVZX/MOVSX (`0F B6/B7/BE/BF`), NEG/NOT (`F6/F7 /2,/3`), INC/DEC r/m
(`FE/FF /0,/1`), CDQ/CWDE/CBW (`99/98`, `66 98`), XCHG (`86/87`, `90+r` incl.
`90`=NOP), SETcc (`0F 90+cc`), BSWAP (`0F C8+r`); bit tests BT/BTS/BTR/BTC
(`0F A3/AB/B3/BB` reg, `0F BA /4../7` imm) and BSF/BSR (`0F BC/BD`); stack/flags
PUSH/POP imm & r/m, PUSHA/POPA (`60/61`), PUSHF/POPF (`9C/9D`, user-mode POPF
mask), LAHF/SAHF (`9F/9E`), LEAVE (`C9`); string ops MOVS/STOS/LODS/SCAS/CMPS
(`A4..A7`, `AA..AF`) with REP/REPE/REPNE (`F3/F2`) and direction from DF
(`STD/CLD` = `FD/FC`); control/loop LOOP/LOOPE/LOOPNE (`E2/E1/E0`), JCXZ/JECXZ
(`E3`), near CALL `rel32` (`E8`) + RET (`C3`, `C2 iw`), near CALL/JMP r/m
(`FF /2,/4`); and the carry-flag trio STC/CLC/CMC (`F9/F8/F5`, added this phase).

**Prefix machine + partial-register handling.** A combinational prefix scanner
consumes a run of up to four legacy prefixes (`66` operand-size, `67`
address-size, `2E/36/3E/26/64/65` segment, `F0` LOCK, `F2/F3` REP) and feeds the
correct opcode + length downstream; segment/LOCK are functional no-ops in the
flat user model. **Partial-register semantics** route through a single
`reg_read`/`reg_merge` pair: an 8-bit write updates `[7:0]` (or `[15:8]` for
AH..BH) preserving the rest; a `66`-prefixed 16-bit write updates `[15:0]` and
**preserves `[31:16]`**; flags are computed at the operand width (SF=bit7/15/31,
PF on the low byte, CF/OF at the width boundary). The decoder maps AH..BH
(encoded index 4..7) to the physical GPR so every datapath site uses
`gpr[d_*_reg]` directly.

**EFLAGS undefined-bit masking.** `verif/diff/tracefmt.py::EFLAGS_UNDEFINED`
already carried the M2 cases (MUL/IMUL SF/ZF/AF/PF; DIV/IDIV all six;
SHL/SHR/SAR/SHLD/SHRD OF+AF; ROL/ROR/RCL/RCR OF; BT* OF/SF/AF/PF; BSF/BSR
CF/OF/SF/AF/PF; AAA/AAS/AAM/AAD/DAA/DAS). **No new entries were required this
phase:** the instructions fixed/added below either touch no flags (MOVZX/MOVSX,
MOV-moffs8, LEAVE, LOOP/JCXZ) or set only deterministic, *defined* flags
(STC/CLC/CMC set CF exactly; their masking-table absence is correct so CF is
compared in full), or their undefined bits are already covered by the existing
`bt`/`bsf`/`bsr` keys (the new 16-bit BT*/BSF/BSR forms reuse them). The table is
deliberately minimal so the gate cannot hide a real RTL bug.

**New test corpus** (added this phase; discovered by the gate via
`manifest.json`). The bulk of the M2 groups above were already covered by the
inherited corpus (`t_bit`, `t_callret`, `t_div`, `t_ext`, `t_loop2`, `t_mixed`,
`t_mul`, `t_op16`, `t_op8`, `t_partial`, `t_prefix`, `t_rep`, `t_rotate`,
`t_setcc`, `t_shift`, `t_shld`, `t_stack`, `t_string`, `t_unary`). The five new
programs regression-lock the adversarial-review findings the corpus did **not**
hit:
- `t_op16b` — `66`-prefixed MOVZX/MOVSX/BSF/BSR/BT*/BTS/BTR/BTC: proves the
  destination's `[31:16]` is preserved and the bit index is mod 16 (not mod 32).
- `t_carry` — STC/CLC/CMC, with the resulting CF consumed by ADC/RCL.
- `t_moffs` — MOV AL,moffs8 (`A0`) and MOV moffs8,AL (`A2`), hand-encoded.
- `t_leave16` — `66 C9` 16-bit LEAVE (preserve EBP[31:16], ESP += 2).
- `t_loop16` — `67`-prefixed LOOP/LOOPE/JCXZ using CX (preserve ECX[31:16]).

**Adversarial review — what was found and fixed** (every finding reproduced
against QEMU with a tiny program before fixing, and each fix re-verified
diff-clean; for the high findings a negative test — reverting the fix —
confirmed the new regression program FAILS, proving the lock):
- **MOVZX/MOVSX 16-bit (`66 0F B6/B7/BE/BF`)** [high, real]: `K_EXT` committed
  the full 32-bit result, ignoring `q_w`; the `66` form must preserve `[31:16]`.
  Fixed to `reg_merge(...,q_w,...)`. (Reproduced: `66 0F B6 C3` gave RTL
  `eax=0x000000a5` vs QEMU `0xdead00a5`.)
- **BSF/BSR 16-bit (`66 0F BC/BD`)** [high, real]: scanned all 32 bits, computed
  ZF from 32 bits, wrote a full-32 index. Fixed to scan/ZF/merge at `q_w`.
- **BT/BTS/BTR/BTC 16-bit reg/imm (`66 0F A3/AB/B3/BB`, `66 0F BA /4..7`)**
  [high, real]: bit index was always masked mod 32 and modify forms wrote full
  32. Fixed: index mod 16 for `q_w==2`, modify via `reg_merge`.
- **STC/CLC/CMC (`F9/F8/F5`)** [high, real]: not decoded → `d_unknown` → HALT.
  Added decode + a CF-only update arm (no other flags change).
- **MOV AL,moffs8 / MOV moffs8,AL (`A0/A2`)** [med, real]: only the 16/32-bit
  `A1/A3` were decoded; the 8-bit absolute forms HALTed. Added both (8-bit,
  preserve `[31:8]` on load).
- **16-bit near CALL/RET/LEAVE (`66 E8/C3/C2/C9`)** [low, real]: hardcoded 32-bit
  width. Now width-aware: 16-bit CALL pushes a 2-byte next-IP, RET pops 2 bytes,
  LEAVE pops 16-bit BP — all adjust ESP by 2 and (CALL/RET) truncate EIP to 16
  bits, exactly matching QEMU. LEAVE-16 is regression-tested (`t_leave16`);
  CALL-16/RET-16 are implemented but not testable in a continuing flat program
  (the 16-bit-truncated target lands at an unmapped low address and faults in
  **both** models — confirmed against QEMU), so they are documented, not gated.
- **`67`-prefixed JECXZ/LOOP/LOOPE/LOOPNE** [low, real]: always used the full
  32-bit ECX. Now the count register is CX (low 16, preserve `[31:16]`) under
  `0x67`. Regression-tested (`t_loop16`).

**Still HALTs (deliberately deferred; loud HALT, never mis-execute)** — confirmed
the core stops cleanly (retires nothing past the unsupported opcode) rather than
corrupting state:
- **Memory-operand BT/BTS/BTR/BTC and SHLD/SHRD** (the bit-string memory addressing
  and the memory-RMW shift-double): marked `d_unknown` → HALT. Genuine ISA forms
  but uncommon (compilers rarely emit them); deferred to a later milestone.
- **ENTER (`C8`)** — spec explicitly defers it ("LEAVE at least"); HALTs.
- **System / privileged ops, far CALL/RET, segment-load, paging/TLB** — out of
  M2 scope by design (need a system-mode oracle); these are **M2S**.

**How to run:** `make m2` (= `bash verif/run-m2.sh`). It builds the RTL TB, then
for each program discovered from `verif/tests/**/manifest.json` it builds the ELF
(`gcc -m32 -nostdlib -static`), ISA-verifies it (`tools/isa_verify.py`, pure P5),
flattens it, generates the QEMU golden (gdbstub), runs the RTL TB with init-ESP
from the golden n=0, runs `compare.py --mode func`, and asserts exit 0 for all;
prints a per-program table and exits 0 only if all pass.

**Observed result** (`make m2` from a clean TB build, exit 0):

```
    PROGRAM          RESULT DETAIL
    -------          ------ ------
    smoke            PASS   func-equivalent (22 insns max)
    t_bit            PASS   func-equivalent (55 insns max)
    t_branch         PASS   func-equivalent (43 insns max)
    t_callret        PASS   func-equivalent (35 insns max)
    t_carry          PASS   func-equivalent (40 insns max)
    t_div            PASS   func-equivalent (60 insns max)
    t_ext            PASS   func-equivalent (50 insns max)
    t_leave16        PASS   func-equivalent (25 insns max)
    t_loop16         PASS   func-equivalent (60 insns max)
    t_loop2          PASS   func-equivalent (65 insns max)
    t_loop           PASS   func-equivalent (78 insns max)
    t_mem            PASS   func-equivalent (25 insns max)
    t_mixed          PASS   func-equivalent (200 insns max)
    t_moffs          PASS   func-equivalent (30 insns max)
    t_mul            PASS   func-equivalent (60 insns max)
    t_op16b          PASS   func-equivalent (60 insns max)
    t_op16           PASS   func-equivalent (60 insns max)
    t_op8            PASS   func-equivalent (64 insns max)
    t_partial        PASS   func-equivalent (44 insns max)
    t_prefix         PASS   func-equivalent (44 insns max)
    t_rep            PASS   func-equivalent (85 insns max)
    t_rotate         PASS   func-equivalent (68 insns max)
    t_setcc          PASS   func-equivalent (65 insns max)
    t_shift          PASS   func-equivalent (67 insns max)
    t_shld           PASS   func-equivalent (44 insns max)
    t_stack          PASS   func-equivalent (45 insns max)
    t_string         PASS   func-equivalent (50 insns max)
    t_unary          PASS   func-equivalent (80 insns max)

    totals: 28 PASS / 0 FAIL / 28 total
M2 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

**Honest coverage statement:** M2 covers the user-mode integer ISA a flat QEMU
user-mode program can execute and reproduce bit-exactly. It is **NOT** yet
"decoder-exhaustive vs XED/Capstone" — that audit remains ongoing. Memory-operand
BT*/SHLD/SHRD and ENTER are genuine integer forms that currently HALT (deferred,
not mis-executed). System mode (segmentation/paging/TLB/interrupts/SMM), far
CALL/RET, and privileged ops are out of scope by design and move to **M2S**. No
pipeline / U-V pairing / branch prediction / caches yet (M4/M5); M2 is
functional-only (no cycle accuracy).

**Next:** M3 — x87 FPU (x87 corpus vs SoftFloat/MPFR + QEMU).

### 2026-06-02 — M1 complete (real single-issue integer core, func-equiv vs QEMU)

Replaced the M0 NOP-stub core with a **real single-issue, in-order, multi-cycle
functional integer core** (`rtl/core/intcore.sv`) that fetches IA-32 bytes over
the `mem_*` bus, decodes the M1 integer subset, executes one instruction at a
time, and reports post-commit architectural state through the single
`vtm_retire` DPI point. **Every program in the corpus (smoke + the three M1
tests) is now func-diff-clean vs QEMU** (`compare.py --mode func` exit 0, no
length mismatch).

**Core structure** (a coherent functional FSM, one instruction at a time):
`S_RESET → S_FETCH` (4 word reads → a 16-byte instruction window) `→ S_DECODE`
(combinational length + operand + ModR/M/SIB/disp decode) `→ S_LOAD` (memory
source/pop) `→ S_EXEC` (ALU + EFLAGS) `→ S_STORE` (push / mov-to-mem / RMW)
`→ S_RETIRE` (commit GPR/EFLAGS/EIP, pulse `retire_valid`) `→ S_HALT` (on
`int $0x80`, and now also on any opcode outside the M1 subset).

**Init-state handling:** the TB (playing the loader) drives `init_eip`/`init_esp`
at reset; the core latches them plus constant segment selectors (CS=0x23,
SS/DS/ES/GS=0x2b, FS=0) and EFLAGS reset 0x202 (bit1 + IF). Segments never change
in the M1 corpus — the core just reports the constants.

**Instruction subset implemented:** MOV (`B8+rd`, `89/8B /r`, `C7 /0`, and the
`A1`/`A3` EAX-moffs32 absolute forms — added this phase), LEA (`8D`), PUSH/POP
(`50+rd`/`58+rd`), the full ALU group ADD/OR/ADC/SBB/AND/SUB/XOR/CMP in all
standard forms (`/r` both directions incl. memory operands, `eAX,imm32`,
`81 /digit id`, `83 /digit ib` sign-extended), INC/DEC (`40+rd`/`48+rd`),
TEST (`85 /r`, `A9 id`), NOP (`90`), JMP `rel8`/`rel32`, the full `Jcc` `tttn`
condition set (`70+cc` and `0F 80+cc`), and `INT 0x80` (halt). EFLAGS (CF/PF/AF/
ZF/SF/OF) match QEMU exactly — the comparator compares them in full (no
undefined-flag ops in the corpus). General 32-bit ModR/M + SIB + disp8/disp32
addressing is decoded.

**New test corpus** (`verif/tests/**`, discovered by the gate via `manifest.json`):
- `t_branch` — Jcc condition-code coverage (je/jne/jl/jge/jg/jb/ja) with
  signed/unsigned operand pairs that diverge, plus never-taken sentinels.
- `t_loop` — counted loops / back-edges: dec/inc + cmp/test + jne/jl, each branch
  taken (per iteration) and finally not-taken (exit).
- `t_mem` — AGU coverage: store/reload via absolute disp32, `[reg]`, base+disp8,
  and SIB, then ALU on the reloaded values.

**Adversarial review — what was found and fixed (all reproduced before fixing):**
- **AF computed at the wrong bit position** (high; failed `t_loop` n=5, `t_branch`
  n=33). The six `flags_next` arms computed `af = a[3]^b[3]^res[3]` (carry *into*
  bit 3) instead of the architectural carry *out of* bit 3 = `a[4]^b[4]^res[4]`.
  Verified ~50% mismatch vs the true AF on random ADD/SUB operands; fixed and
  re-verified to 0 mismatches over 200k random cases each. Affects ADD/ADC/SUB/
  SBB/CMP/INC/DEC.
- **MOV moffs32 (`A1`/`A3`) decode gap** (failed `t_mem` n=4 + length mismatch).
  GAS emits `A3` for `movl %eax,<abs32>` (5 bytes); the decoder had no case and
  mis-lengthed it to 1 byte via `default`, desyncing the fetch stream. Added
  `A1` (MOV EAX,moffs32 load) and `A3` (MOV moffs32,EAX store).
- **ALU with a MEMORY SOURCE operand** (high; latent — not in corpus). The EXEC
  operand mux collapsed both ALU inputs onto `mem_load_data`, so `add (%edx),%eax`
  computed `mem OP mem` and dropped the register. Added a `d_mem_dst` decode flag
  distinguishing "memory is the source" from "memory is the RMW destination"; the
  mux now feeds `src_a=gpr[dst]`, `src_b=mem` for memory-source forms.
- **ALU with a MEMORY DESTINATION (read-modify-write)** (high; latent). Same root
  cause from the other direction: `add %eax,(%edx)` stored `mem OP mem` instead of
  `mem OP reg`. The `d_mem_dst` flag fixes `src_b` to `gpr[src]`.
- **`pop %esp`** (med; latent). Two NBAs to `gpr[ESP]` (`<= mem_load_data` then
  `<= ESP+4`) raced; the +4 won, discarding the popped value. Now the ESP bump is
  suppressed when the pop destination IS ESP, so the loaded value wins (Intel SDM).
- **Silent mis-decode of out-of-subset opcodes** (low). The `default`/`0F`-non-Jcc
  arms advanced 1–2 bytes silently. Added a `d_unknown` flag that routes to
  `S_HALT` (a LOUD stop, no retire) so an unsupported opcode can't corrupt the
  fetch stream. The implemented subset is unaffected.

All four latent datapath fixes (mem-source ALU, RMW, `pop %esp`, and the AF
exposing cases `add %eax,%eax`/`inc %eax`) were verified func-equivalent vs QEMU
with dedicated micro-tests before being declared fixed.

**False positives / out-of-scope (dispositioned, not "fixed"):**
- **Prefix consumption** (low): the decoder handles only a single `0F` for the
  two-byte Jcc; other prefixes (0x66/0x67/seg/F2/F3) are not consumed. The M1
  corpus contains no prefixes (all 32-bit default forms), so this is documented
  M1 scope, not a corpus bug. (M2 extends the decoder toward exhaustiveness.)
- **8-bit accumulator / other unimplemented opcodes** (low): out of the M1 subset
  per spec; now guarded by `d_unknown → S_HALT` rather than silently mis-decoded.

**HARNESS/SPEC fix (init ESP):** the spec-documented `--init-esp 0x40c348d0` was
**stale** — QEMU's linux-user loader places the initial stack pointer for these
static binaries at `0x40c34910` for smoke (and a slightly different value per
program, because argv[0] = the ELF path length varies). The literal `0x40c348d0`
made *every* program (incl. smoke) diverge at n=0 on ESP; the core is correct (it
latches whatever ESP it is given). The M1 gate now derives each program's init
ESP from its golden's n=0 record (environment-independent, and exactly the spec's
intent that "the testbench, playing the loader, establishes the init state");
`docs/m1-core-spec.md` and the TB default were corrected to `0x40c34910`.

**How to run:** `make m1` (= `bash verif/run-m1.sh`). It builds the corpus + RTL
TB, discovers every program from `verif/tests/**/manifest.json`, generates each
QEMU golden, runs the RTL TB (init ESP from the golden n=0), runs
`compare.py --mode func`, asserts exit 0 for all, and prints a per-program table.
Exits 0 only if all pass. RTL stays lint-clean (`verilator --lint-only -Wall
-Wno-DECLFILENAME -Wno-UNUSED`, exit 0).

**Observed result** (`make m1` from a clean TB build, exit 0):

```
    PROGRAM      RESULT DETAIL
    -------      ------ ------
    smoke        PASS   func-equivalent (22 insns max)
    t_branch     PASS   func-equivalent (43 insns max)
    t_loop       PASS   func-equivalent (78 insns max)
    t_mem        PASS   func-equivalent (25 insns max)
M1 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0).
```

`make m0-smoke` still exits 0 (the M0 infrastructure gate is met; with a real
core the smoke func compare now reports EQUIVALENT, which the M0 script treats as
a benign WARN and still passes).

**Honest coverage statement:** M1 implements an integer **SUBSET** sufficient for
the corpus and built to extend cleanly. It is **NOT** yet "decoder-exhaustive vs
XED/Capstone" (that remains ongoing, toward M2). There is **no** pipeline, U/V
pairing, branch prediction, or caches/TLB yet — those are M4/M5; cycle accuracy
is out of M1 scope (func-mode only). Correct architectural state on the integer
subset is the only M1 claim, and it is met.

**Next:** M2 — full integer ISA + memory + paging/segmentation (ISA arch corpus
diff-clean), extending the decoder toward exhaustive XED/Capstone coverage.

### 2026-06-02 — M0 bootstrap complete (infrastructure proven end-to-end)

Built the full M0 differential-testing skeleton — six components plus an
end-to-end integration runner — and ran the smoke pipeline cleanly from a
clean tree. **M0 proves the *infrastructure*, not functional correctness:** the
RTL is still a NOP stub, so the functional comparator is *expected* to diverge.

**Components landed** (all build/run in isolation, then wired together):
- **Producer A — golden FUNC trace** (`verif/qemu-trace/gen_trace.py`): drives
  `qemu-i386 -g <port>` over the GDB RSP, single-steps, and emits post-commit
  architectural state as a `mode:"func"` `.vtrace` (pure python3 stdlib; imports
  the shared `verif/diff/tracefmt.py`).
- **Producer B — golden CYCLE trace** (`verif/qemu-plugins/p5trace.c`): a TCG
  plugin (same U/V cycle model as the harness `p5model.c`) emitting retire-order
  PC + cumulative `cyc` + pipe/pairing. Builds to `build/p5trace.so`.
- **RTL skeleton** (`rtl/`): `ventium_top` + all PLAN §6 block stubs; the M0
  NOP-stub core boots reset and retires a fixed canned sequence via the
  `vtm_retire` DPI callback (`rtl-interface.md` §2).
- **Producer C — Verilator C++ TB** (`verif/tb/`): implements `vtm_retire`,
  preloads the flat image, services the M0 bus, and emits the RTL `mode:"func"`
  `.vtrace`.
- **Consumer — comparator** (`verif/diff/compare.py`): diffs A-vs-C (func) and
  B-vs-C (cycle); exit `0`=equivalent, `1`=divergence, `2`=malformed.
- **Test corpus** (`verif/tests/`): the `smoke` program (24 static / 22 retired
  i586-base instructions, no undefined-EFLAGS ops) + `elf2flat.py` loader and a
  manifest (`load_addr`/`entry`=`0x08048000`, `max_insn`=22).
- **Integration runner** (`verif/run-m0-smoke.sh`, invoked by `make m0-smoke`):
  builds corpus + plugin + TB, generates both golden traces, runs the TB,
  validates every `.vtrace` with `tracefmt.read_trace`, and runs the comparator
  in both modes — capturing (not aborting on) the comparator's exit code.

**How to run:** `make m0-smoke` (from the repo root). Artifacts land in
`build/m0/{qemu_func,qemu_cycle,rtl_func}.vtrace`.

**Observed end-to-end result** (`make m0-smoke` from a clean tree, exit 0):
- `qemu_func`: well-formed FUNC trace, 21 records (n=0..20, first pc=0x08048000).
  *(22 retired; the final `int $0x80` exit isn't emitted as a post-state row.)*
- `qemu_cycle`: well-formed CYCLE trace, 22 records (cyc 0..46, pairs=8, CPI≈2.09).
- `rtl_func`: well-formed FUNC trace, 16 records (NOP stub, n=0..15).
- FUNC compare (A vs C) — the EXPECTED coherent divergence:
  `RESULT: DIVERGENT` → `n=0 pc=0x08048000 field=eax: expected(A)=0x11111111
  got(C)=0x00000000` (golden `movl $0x11111111,%eax` vs stub's zeroed eax);
  `func exit=1`. The smoke program is longer than the stub's canned sequence, so
  the comparator also notes the length mismatch (A=21 vs C=16).
- CYCLE path is exercised by self-diffing the golden cycle trace (no RTL cycle
  DUT exists until M4): `RESULT: EQUIVALENT`, `cycle exit=0`.

This confirms the clock/reset/DPI/trace path, the three producers' formats, the
manifest→loader→TB seam, and the comparator all line up. **No integration bugs
required fixing** — the pinned `trace-format.md`/`rtl-interface.md` contracts and
the single-source-of-truth `tracefmt.py` held: DPI signature
(`ventium_pkg.sv` ↔ `dpi_retire.cpp`), field names/hex formatting, and the
register layout all matched on the first wired run.

**Next:** M1 — replace the NOP stub with a real decoder + single-issue integer
core, and turn the func comparator green on the smoke corpus (decoder matches
Capstone; integer ISA diff-clean vs QEMU). For a full match M1 must also align
the TB's reset ESP with QEMU's linux-user initial ESP (`esp=0x40c34900` in the
current golden trace) — see the corpus notes on push/pop.

### 2026-06-02 — Planning complete
- Read the reference library (`REF.md`, `MANIFEST.md`, `00-index/`) and the
  existing QEMU golden-model harness (`07-p5-emulation-harness/`).
- Locked target: **P54C, non-MMX, single core, L1-only, no FRC** (per REF.md
  practical recommendation; matches the existing harness).
- Wrote [`PLAN.md`](PLAN.md): scope & honest-fidelity statement, target µarch
  parameters (5-stage U/V integer pipe, 256-entry/4-way BTB, 8-stage FPU, 8 KB
  2-way split L1, 64-bit bus), reference map, Verilator+QEMU differential
  verification strategy, repo layout, 10-block RTL decomposition, and milestones
  M0–M6 gated on REF.md's five success layers.
- **Next:** start M0 — create `rtl/`, `verif/`, `tools/`, `docs/` skeleton; define
  the golden-trace record format; write the QEMU golden-trace plugin (sibling to
  `p5model.c`); stand up the Verilator testbench shell + trace comparator.
