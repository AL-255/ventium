# Ventium — progress log

Living status for the P5/P54C Verilog replica. Plan: [`PLAN.md`](PLAN.md).
Newest entries at the top. Dates are ISO (YYYY-MM-DD).

## Status at a glance

| Milestone | Description | Gate | Status |
|---|---|---|---|
| **M0** | Bootstrap: repo skeleton, QEMU golden-trace plugin, trace format, Verilator TB shell, comparator | comparator runs end-to-end on trivial trace | ✅ done (infrastructure proven; RTL still a NOP stub) |
| M1 | Decoder + single-issue integer functional | integer subset diff-clean vs QEMU (decoder-exhaustive vs XED/Capstone is ongoing toward M2) | ✅ done (integer SUBSET func-equiv vs QEMU on smoke + M1 corpus; not yet decoder-exhaustive) |
| M2 | Full integer ISA + memory + paging/segmentation | ISA arch corpus diff-clean | ☐ not started |
| M3 | x87 FPU | x87 corpus vs SoftFloat/MPFR + QEMU | ☐ not started |
| M4 | Dual-issue U/V + pairing + branch prediction | µbench CPI/pairing/mispredict match p5model | ☐ not started |
| M5 | Cache/bus timing + x87 cycle accuracy | bus corpus + FP/branch cycle match | ☐ not started |
| M6 | Errata & stepping fidelity (stretch) | targeted errata repro | ☐ not started |

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
