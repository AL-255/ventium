<!--
Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
-->
# pipeviz — Visual & Functional Evolution Summary

`tools/pipeviz/` evolved through an automated render → adversarial visual/UX
audit → RTL-coupled regression loop. Detailed per-iteration July/August 2026
audit notes have been condensed below into the resulting architecture and
invariants enforced by the automated test suite.

## Core Visualization & Microarchitectural Fidelity

- **Konata Superscalar Timing Diagram (`pipeline_view.py`):** Replaced a static
  EX-latch waterfall with a per-retirement gem5/Konata lifecycle plot (`F` fetch,
  `L` I-cache fill, `D` decode, `X` integer/FP execute, `M` memory, `W`
  writeback, `=` stall, `!` mispredict flush, `S` system/microcode) reconstructed
  from per-cycle RTL FSM observations and retirement-captured instruction bytes.
- **Linked Cross-Panel Inspection:** Two-way retirement-ID linking across the
  Konata plot, retired Trace, pinned AS-OF Registers (`LIVE` vs. `PINNED` banner
  with explicit **Unpin**), producer→consumer GPR/EFLAGS dependency overlays
  (amber load-use stall highlighting), Shift-click `Δ`-cycle measurement bands,
  live U/V/FP stage-board source jumps, and a clickable/keyboard-navigable IPC &
  event sparkline scrubber.
- **Ten Microarchitectural Analysis Tabs (`tables_view.py`):**
  - **Code$ / Data$:** 2D `set × way` occupancy heatmaps plus a client-side
    2-way LRU replay miss-rate model seeded from resident snapshot tags/MRU.
  - **TLB & Prefetch:** Split I/D TLB residency and live 16-byte `ibuf` decode.
  - **Hotspots, Branches, Instr Mix & Cycles:** Per-PC fetch-to-retire `Σ lat`
    and D$ miss attribution, resolved branch bias bars, U/V pairing split, and
    exhaustive FSM cycle-state attribution.
  - **Memory & Mem Map:** Physical hex/ASCII inspector (`→ EIP` / `→ ESP` /
    `→ access` page-table walk) and clickable effective-offset stride scatter.
- **Trace & Register Precision (`trace_view.py`, `regs_view.py`):** Field-colored
  x86 encoding bytes/disassembly (honoring live `CS.D`), architectural write
  effects, inline-validated structured filters (`pc:`, `n>=`, `cyc>=`, `pipe:`,
  `stall`, `@`), named-bit EFLAGS grid, and rotated logical 80-bit `ST(0..7)`
  x87 snapshots with explicit empty-tag masks.

## Integrated Authoring Workbenches & UX Safeguards

- **Assembly & Freestanding Pentium C11 Editors (`source_view.py`, `isa_catalog.py`):**
  Line-numbered editors with DWARF PC↔source mapping, GCC `-m32 -march=pentium`
  (`-O0/-O1/-O2/-Os`, x87-only, freestanding) C-to-Assembly compilation, a
  self-verifying dual-chain Fibonacci U/V demo (`0x198c09a0`), and a
  **292-entry** Ventium/P54C autocomplete catalogue (including `INVLPG` through
  x87 transcendentals) coupled directly to the RTL decoder and P5 timing classes.
- **Transactional State & Responsive Layout:** Invalid resets, malformed
  `manifest.json` files, failed loads/saves, and unavailable SoC libraries
  preserve the active live session and dirty source buffers with explicit
  amber/red diagnostics. Full layout and keyboard/screen-reader accessibility
  are verified down to compact `900×620` windows (indexed register pages and
  compact `Alt+1..Alt+0` analysis selector).

## Automated Verification Gates (`tools/pipeviz/`)

- `smoke_test.c`: Native C ABI (`ventium_viz.h`) build and execution smoke check.
- `verify_gui.py` & `gen_review_shots.py`: Offscreen GUI rendering and watermarked
  multi-panel visual capture sweep.
- `verify_examples.py`: End-to-end GUI verification of all five `docs/user-guide.md`
  workloads (dual-issue loop, D-cache misses, x87 overlap, and paged system boot).
- `verify_interactions.py` & `verify_authoring.py`: QTest regressions locking
  controls, error rollbacks, 292-opcode decoder parity, DWARF line mapping, and
  the `>= 20%` U/V dual-issue cycle advantage on `examples/fibonacci_uv.c`.
