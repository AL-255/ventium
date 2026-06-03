# Ventium RTL (`rtl/`) — block map

Synthesizable SystemVerilog skeleton of the Intel Pentium (P5/P54C). This is the
**M0** state (PLAN.md §7): `ventium_top` is a *NOP-stub* core that boots reset
and retires a finite, deterministic canned sequence through the DPI retire
callback, proving the clock/reset/DPI/trace path end-to-end. There is **no real
x86 decode/execute yet** — that lands at M1+.

Contracts this directory implements (read these, not this README, when in doubt):
- [`../docs/rtl-interface.md`](../docs/rtl-interface.md) — top ports (§1, §3),
  the DPI `vtm_retire` import (§2), and M0 NOP-stub behaviour (§5).
- [`../docs/trace-format.md`](../docs/trace-format.md) — the `.vtrace` fields
  the retire callback ultimately feeds (§2.2) and the M0 gate (§4).
- [`../PLAN.md`](../PLAN.md) — §2 (target µarch + parameters), §6 (block
  decomposition, mirrored below), §7 (milestones).

## Build / lint (the self-test)

Lint must pass standalone (no DPI symbol) via the `VTM_NO_DPI` define:

```sh
cd /home/yukidama/github/ventium && \
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED \
  -sv --top-module ventium_top $(find rtl -name '*.sv') +define+VTM_NO_DPI
```

All `rtl/*.sv` files form a **single compilation unit** (the package
`ventium_pkg` is supplied on the command line, so no `` `include `` is needed —
`import ventium_pkg::*` resolves it). It also lints with the DPI import present
(drop `+define+VTM_NO_DPI`); the Verilator testbench phase (`verif/tb/`) does the
full `--cc --exe` build that binds the C++ `vtm_retire`.

### Warning waivers (kept minimal, as the task allows)
- `-Wno-DECLFILENAME` — block files are grouped by directory (`core/`, `mem/`,
  …), so module name ≠ file basename for some; this is intentional.
- `-Wno-UNUSED` — block stubs have documented-but-unwired ports for M1+; the
  command-line waiver covers them. (We *also* add narrow inline
  `lint_off UNUSED` sinks per stub so each file is self-contained-clean.)

No other waivers are required.

## Block map → PLAN §6 + reference pages

PLAN §6 lists ten blocks; §2 pins their parameters. Each stub file's header
comment cites the PLAN §6 sub-block and the primary reference. `ventium_top`
**instantiates** every block (inputs tied to `clk`/`rst_n`, outputs left for
M1+) so the block decomposition is executable and port-list drift is caught at
elaboration.

| File | PLAN §6 block | Key reference (page) | Milestone it goes live |
|---|---|---|---|
| `ventium_pkg.sv` | arch types + DPI import | rtl-interface.md §2 (verbatim); tracefmt.py field order | M0 |
| `ventium_top.sv` | top / M0 retire sequencer | rtl-interface.md §1,§3,§5 | M0 |
| `core/fetch.sv` | §6.1 Front end (prefetch) | Alpert & Avnon p.2–3 | M1 |
| `core/bpred_btb.sv` | §6.1 Front end (BTB+predictor) | Alpert & Avnon p.3 Fig.6 | M4 |
| `core/decode.sv` | §6.2 Decode (len/prefix/ModRM, D1/D2) | Dev. Manual Vol.1 ch.2; A&A p.3 Fig.5 | M1 |
| `core/issue_uv.sv` | §6.3 U/V issue + pairing | Dev. Manual Vol.1 ch.2; AP-500 241799; Agner Fog | M4 |
| `core/exec_int.sv` | §6.3 ALU/shift/mul/div/flags/bypass | Dev. Manual Vol.1 ch.2; Agner Fog tables | M1 |
| `core/regfile.sv` | §6.3 integer GPR file | IA-32 SDM Vol.1 (243190) ch.3 | M1 |
| `fpu/fpu_top.sv` | §6.6 x87 FPU (8-stage) | Alpert & Avnon p.6–8 Fig.8/9 | M3 |
| `mem/icache.sv` | §6.1 L1 I-cache (8K/2-way/32B) | Alpert & Avnon p.5 | M2 |
| `mem/dcache.sv` | §6.5 L1 D-cache (banked, MESI, dual-port) | Alpert & Avnon p.5 Fig.7; AP-500 | M2 |
| `mem/tlb.sv` | §6.4 Address gen / I+D TLBs / paging | IA-32 SDM Vol.3 (243192) ch.3 | M2 |
| `bus/biu.sv` | §6.10 64-bit bus interface unit | Datasheet 241997-010 | M5 |
| `ucode/ucode_rom.sv` | §6.7 Microcode engine | Dev. Manual Vol.1 ch.2; Agner Fog | M1 |
| `sys/sys_state.sv` | §6.9 system state + §6.8 exc pipeline | IA-32 SDM Vol.3 (243192); Dev. Manual Vol.3 | M2 |

(§6.8 Interrupt/exception pipeline is folded into `sys/sys_state.sv`'s scope at
M0 and may split into its own file when it grows.)

## M0 NOP-stub behaviour (what `ventium_top` actually does)

Per rtl-interface.md §5 and trace-format.md §4:

1. Synchronous active-low reset; comes up clean.
2. After `rst_n` deasserts, retires `N_RETIRE` (default 16) canned
   "instructions", **one per clock**, from a single `always_ff` retire point,
   calling `vtm_retire(n, pc, …)` with:
   - `n` — the core's retire counter, 0-based, monotonic +1 per retire;
   - `pc = ENTRY + n*STEP` (params; defaults `ENTRY=0x08048000`, `STEP=1`). The
     real testbench can override `ENTRY` with the manifest `entry`
     (rtl-interface.md §4).
   - trivially-predictable stub state: all regs/segs zero except `eax=n` and
     `eflags=0x00000002` (IA-32 always-set bit 1). This deliberately will **not**
     match QEMU — the M0 gate is *infrastructure*, not correctness
     (trace-format.md §4).
3. After `N_RETIRE` retires, asserts `done` and goes idle (no further retires),
   giving the TB its end-of-trace condition.

The M0 memory port group (`mem_*`, rtl-interface.md §3) is driven inert
(`mem_req=0`); `mem_rdata`/`mem_ack` are sunk so they stay live. Real bus traffic
arrives with the icache/dcache at M2 and the modeled P5 bus FSM at M5.

## Integration notes

- **DPI guard.** The `vtm_retire` import lives in `ventium_pkg.sv`, fenced by
  `` `ifndef VTM_NO_DPI ``; the call site in `ventium_top.sv` is fenced the same
  way. Standalone lint defines `VTM_NO_DPI`; the TB build leaves it undefined and
  links a C++ `extern "C" void vtm_retire(...)` matching the §2 signature
  (verified here against the exact arg widths: `longint→uint64_t`,
  `int→uint32_t`, `shortint→uint16_t`).
- **Parameters for the TB.** Override on the `ventium_top` instance:
  `ENTRY` (fetch base = manifest `entry`), `STEP`, `N_RETIRE` (trace length).
- **x87 retire.** `vtm_retire_x87` (rtl-interface.md §2, trace-format.md §2.2) is
  **not** declared yet — it lands with the FPU at M3, alongside `fpu/fpu_top.sv`.
- **Single compilation unit.** Pass all `rtl/*.sv` together (e.g.
  `$(find rtl -name '*.sv')`); do not compile files individually.
