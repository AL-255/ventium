# Ventium

A high-fidelity RTL reconstruction of the original Intel **Pentium (P5 / P54C,
non-MMX)** microarchitecture, written in synthesizable SystemVerilog, simulated
with **Verilator**, and verified differentially against **QEMU**.

- **Plan & scope:** [`PLAN.md`](PLAN.md)
- **Status / changelog:** [`PROGRESS.md`](PROGRESS.md)
- **Reference library + golden model:** [`ventium-refs/`](ventium-refs/) submodule
  (Intel manuals, Alpert & Avnon, Agner Fog, datasheet, spec updates, and a
  working QEMU `-cpu pentium` functional + cycle golden harness).

> Honest scope: Intel never released the Pentium RTL/microcode, so this is an
> **ISA-exact + cycle-approximate** clone, not a gate-for-gate copy. See PLAN §1.

## Layout

```
rtl/        synthesizable SystemVerilog (core / fpu / mem / bus / ucode / sys)
verif/
  qemu-trace/   golden architectural-state trace via QEMU gdbstub (-g)   [Producer A]
  qemu-plugins/ TCG cycle-trace plugin                                   [Producer B]
  tb/           Verilator C++ testbench + bus-functional model + DPI     [Producer C]
  diff/         trace comparator (functional + cycle) + tracefmt.py      [Consumer]
  tests/        decoder / ISA / x87 / µarch / bus / compat corpora
  cocotb/ formal/  constrained-random and formal harnesses
docs/       trace-format.md (the contract), rtl-interface.md, design notes
tools/      build helpers
```

## Verification model

QEMU 8.2.2 plugins can't read register values, so:

- **Functional truth** comes from single-stepping `qemu-i386 -g` over the GDB
  remote protocol (full architectural state per instruction).
- **Cycle truth** comes from the TCG plugin (PC + cumulative cycle estimate),
  reusing the model mined in `ventium-refs/.../p5model.c`.
- The RTL emits the **same** trace format (`docs/trace-format.md`) via a DPI
  retire callback (`docs/rtl-interface.md`), and `verif/diff/compare.py` diffs
  the streams.

## Quick start (M0 skeleton smoke test)

```bash
make m0-smoke        # build RTL (verilator) + plugin, generate golden traces,
                     # run the RTL testbench, and diff — proves the pipeline runs
```

See [`PROGRESS.md`](PROGRESS.md) for the current milestone (M0: bootstrap).
