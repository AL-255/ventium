# Ventium P54C Replica Fidelity Review

Date: 2026-06-05

## Verdict

Ventium is a credible high-fidelity P5/P54C replica for the scope it can actually verify: non-MMX IA-32/x87 architectural behavior, the documented U/V pipeline rules, AP-500-style pairing, branch/AGI/cache/FP cycle bands, selected system-mode machinery, and a standalone P5 bus protocol FSM. It is not a gate-for-gate Pentium and should not be presented as a complete silicon-faithful implementation.

The best summary is: **good fidelity as an ISA-exact and cycle-approximate P54C reconstruction over a broad tested subset; medium fidelity as a full microarchitectural/pin-level clone.**

## Evidence Reviewed

- Top-level scope and claims: `README.md`, `PLAN.md`, `PROGRESS_Jun04.md`.
- RTL: `rtl/core/*`, `rtl/fpu/*`, `rtl/mem/*`, `rtl/bus/*`, `rtl/ventium_top.sv`.
- Verification: `verif/tests`, `verif/sys`, `verif/bus`, `verif/errata`, `verif/tb`.
- Local references: `ventium-refs/00-index/*`, especially Intel AP-500, Pentium developer manuals, datasheet/spec-update notes, and the p5model harness.

## Verification Run During Review

Commands run on 2026-06-05:

- `make verify`: PASS. 57/57 functional programs diff-clean vs QEMU, including x87; all M4/M5 cycle bands passed within the repo's 10% p5model tolerance.
- `make verify-sys`: PASS when rerun with local gdbstub loopback permission. Covered pseg, pmode, ppage, pintr, pfault, pcpl, ptask, psmm structural checks, pdebug, and pv86.
- `make -C verif/bus run`: PASS. Standalone `biu_p5` lint plus 76 directed bus checks and SVA assertions.
- `make m6`: PASS. FDIV, FIST, F00F, MOV-moffs pairing, and V86 #DB errata checks all passed behind the errata flag.
- `bash verif/bus/run_busmode_corpus.sh`: PASS. 12/12 `bus_mode=1` programs functionally equivalent vs QEMU.
- `cd rtl && verilator --lint-only -sv -Wall -Wno-UNUSED -f ventium.f`: PASS.
- `make -C verif/tb rtl-sva`: PASS build of assertion-enabled integrated testbench. This target builds the SVA-enabled model; it does not by itself run the corpus.

## High-Fidelity Areas

The verification stack is a major strength. The repo does not rely on casual smoke tests: it compares RTL traces against QEMU architectural traces, uses p5model for cycle bands, and has separate system, bus, and errata gates. That is the right methodology for a public-source P54C reconstruction.

The integer pipeline and cycle model are directionally faithful. The RTL has an actual in-order U/V fast path, branch predictor, AGI behavior, and cycle trace rather than only reporting a formula. The passing `mb_depadd`, `mb_indepadd`, `mb_agi`, `mb_brloop`, and `mb_brrandom` bands are meaningful evidence.

The system-mode work is unusually strong for a hobby/replica CPU: protected mode, paging, faults, interrupt gates, cross-privilege transitions, one-way hardware task switch, SMM/RSM structural coverage, debug registers, and V86 all have focused gates. This is a real fidelity advantage.

The errata mode is also a strong fidelity signal. Reproducing selected documented P5 defects behind an off-by-default flag, with clean behavior still passing the normal gate, is a disciplined design choice.

## Fidelity Limits

### 1. The "full integer ISA" claim is too broad

The current docs still identify several P5-era instructions as deferred or HALT-only. For example, BCD/ASCII adjust instructions `AAA`, `AAS`, `AAM`, `AAD`, `DAA`, and `DAS` are explicitly not decoded and HALT in `docs/sphinx/isa/index.rst:973` through `docs/sphinx/isa/index.rst:1059`. That conflicts with a plain reading of "full integer ISA."

This is not necessarily a bad engineering tradeoff: loud HALT is better than silent misexecution. But for fidelity language, call it "broad IA-32/P54C subset with documented HALT gaps" unless those gaps are closed.

### 2. x87 is strong for covered operands, not complete P54C x87

`rtl/fpu/fpu_x87_pkg.sv:3` through `rtl/fpu/fpu_x87_pkg.sv:22` states the datapath is bit-exact for normal finite values, signed zero, and default 64-bit precision, but not guaranteed for infinities, NaNs, denormals, non-default precision/control cases. `docs/m3-fpu-spec.md:50` through `docs/m3-fpu-spec.md:58` also defers transcendental ops, BCD FP load/store, environment save/restore, and unmasked numeric exceptions.

That is enough for many workloads and the tests are solid. It is not a complete 1990s x87 compatibility surface.

### 3. Cache/TLB fidelity is deliberately approximate

The D-cache model is timing-only: `rtl/mem/dcache_timing.sv:3` through `rtl/mem/dcache_timing.sv:9` explicitly says there is no data array and load data still comes from the memory model. This can validate hit/miss timing bands, but it is not a P54C D-cache implementation with data, MESI, writeback, write buffers, and store/load corner behavior.

The TLB is also a correctness model rather than a P54C-accurate structure. `rtl/mem/tlb.sv:4` through `rtl/mem/tlb.sv:11` describes a 16-entry direct-mapped I/D TLB, with the page-walk FSM kept in the core spine. This differs from the documented Pentium TLB organization and should not be called structurally faithful.

### 4. Integrated bus mode is a protocol exerciser, not a faithful memory path

This is the biggest pin-level fidelity caveat. `rtl/bus/biu.sv:25` through `rtl/bus/biu.sv:40` says the integrated `biu_p5` is strictly a protocol exerciser: the core consumes combinational back-side memory data independent of the BIU, and the address on the pins is not guaranteed to correspond to the data returned on `d_in`. `rtl/bus/biu.sv:54` through `rtl/bus/biu.sv:62` further limits integrated traffic to single, non-burst, non-pipelined cycles; burst, pipelined, locked, snoop, backoff, and arbitration behavior remain standalone-validated only.

The standalone `biu_p5` looks well tested, but the integrated CPU is not yet faithfully executing through a real P5 external bus timing/data path.

### 5. Some microarchitecture is modeled by effect, not by original internal structure

Several complex operations are implemented in a practical RTL style rather than as likely P54C internal hardware. For example, `docs/sphinx/isa/index.rst:922` through `docs/sphinx/isa/index.rst:1039` says integer multiply/divide use native Verilog `*`, `/`, and `%`, not an iterative microcoded/SRT-style structure. That is fine for architectural correctness and rough serialization, but it is not transistor/microcode fidelity.

Similarly, the fast path only realizes pairing for whitelisted forms; otherwise pairable AP-500 forms can fall to the slow FSM and serialize. That is honest in the ISA catalog, but it means cycle fidelity is strongest for the measured kernels and common fast-path forms.

#### Actions to Address This

1. Create a "modeled by effect" inventory. List every instruction/block currently implemented as direct behavioral RTL rather than P5-like structure: integer `MUL/IMUL/DIV/IDIV`, string ops, complex control flow, x87 slow-path helpers, task/SMM microsequences, and similar paths. For each entry, record the current implementation, expected P54C structure, public evidence, observable fidelity gap, and test coverage.

2. Prioritize by observable impact. Put timing-visible and pairing-visible gaps first: integer multiply/divide latency, serialization, exceptions, slow-FSM instructions that should be pairable, and microcoded stack/string/control-flow sequencing. Leave purely internal structure with no architectural or timing evidence lower priority.

3. Add a real microcode/useq layer for complex ops. Move complex instructions out of one-shot `S_EXEC` arms into a small sequencer with explicit micro-ops: read operands, execute internal step(s), writeback, and retire. Start with `MUL/IMUL/DIV/IDIV`, `PUSHA/POPA`, `CALL/RET`, and string ops.

4. Replace native integer divide with an iterative divider. It does not need to be transistor-identical, but it should expose P5-like occupancy, serialization, `EDX:EAX` coupling, and `#DE` timing/behavior instead of relying on native `/` and `%` in a single execute arm.

5. Wrap or replace native multiply with staged multiply timing. Native `*` can remain as an internal arithmetic primitive if needed, but the visible instruction should occupy the pipe through an explicit multi-cycle sequence with correct U-pipe-only serialization and dependency behavior.

6. Expand AP-500 fast-path coverage. Identify AP-500 pairable forms that currently fall to the slow FSM and serialize. Add fast-path decode/execute support where practical, especially accumulator-immediate forms, common memory/register forms, push/pop variants, and simple branch patterns.

7. Add microbenchmarks for every structural change. Each converted family should have tests for total cycles versus p5model or documented timing, pairing/non-pairing, dependency stalls, exception behavior, and architectural equivalence versus QEMU.

8. Separate architectural implementation from timing implementation. Keep a functional helper where useful, but make the timing-visible path explicit. For example, a divider may compute the quotient with helper logic, but retire only after the modeled internal sequence completes.

9. Document irreducible approximations. Some P54C internals are not publicly recoverable. For those, use labels like "effect-faithful" or "cycle-modeled" rather than "structurally faithful," and point to the tests proving the observable behavior.

10. Gate progress incrementally. After each instruction family or block is converted, require `make verify`, the relevant cycle microbenchmarks, system gates if the behavior is system-visible, lint, and a short progress note describing what became more structure-faithful and what remains effect-modeled.

## Overall Assessment

I would accept the repo's core claim only with the existing honest qualifier: **ISA-exact for the verified corpus and cycle-approximate to public P54C timing sources, not a gate-level or complete pin-level Pentium clone.**

The fidelity is good enough to be interesting and useful: the differential verification, system-mode coverage, P5 errata mode, and p5model-aligned cycle gates are much stronger than superficial "Pentium-like" RTL. The main risk is wording. Claims such as "full integer ISA," "pin-level bus integrated," or "high-fidelity RTL reconstruction" need the same caveats that the code comments already contain.

## Recommended Next Steps

1. Tighten public claims: replace unqualified "full integer ISA" with a coverage matrix and list the HALT/deferred opcodes.
2. Promote the integrated bus SVA corpus run into a single command that builds and runs assertion-enabled `bus_mode=1` traffic, so the current build-only `rtl-sva` target cannot be misread.
3. Decide whether cache/TLB fidelity means structural fidelity or timing fidelity. If structural, add a real D-cache data/MESI/writeback model and a more P54C-shaped TLB; if timing, label the current blocks as timing models everywhere.
4. Add focused tests for currently deferred x87 and BCD/ASCII instructions, even if the expected result is a documented HALT, so the coverage boundary stays machine-checkable.
