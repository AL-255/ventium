# RTL ↔ testbench interface (v1)

How the Verilator C++ testbench (`verif/tb/`) drives and observes the RTL core
(`rtl/`). Pinned so the RTL author and the testbench author can work
independently. See also [`trace-format.md`](trace-format.md).

## 1. Top module

`rtl/ventium_top.sv`, module `ventium_top`, ports:

| port | dir | width | meaning |
|---|---|---|---|
| `clk`   | in  | 1  | core clock, rising-edge |
| `rst_n` | in  | 1  | active-low synchronous reset; held low ≥1 cycle at start |
| `mem_*` | various | — | bus-functional-model port group (see §3) |

All architectural observation happens through the **DPI retire callback** (§2),
*not* through output ports — this keeps the top port list stable as the core
grows and avoids exposing internal register files as ports.

## 2. DPI retire callback (the observation contract)

The RTL **imports** one DPI-C function and **calls it once per retired
instruction**, in architectural order, with that instruction's fetch PC and the
**post-commit** architectural state (matching `trace-format.md` §2.2):

```systemverilog
import "DPI-C" context function void vtm_retire(
    input longint unsigned n,        // retire seq, 0-based, monotonic
    input int      unsigned pc,      // fetch vaddr of retired insn
    input int      unsigned eflags,
    input int      unsigned eax, input int unsigned ecx,
    input int      unsigned edx, input int unsigned ebx,
    input int      unsigned esp, input int unsigned ebp,
    input int      unsigned esi, input int unsigned edi,
    input shortint unsigned cs,  input shortint unsigned ss,
    input shortint unsigned ds,  input shortint unsigned es,
    input shortint unsigned fs,  input shortint unsigned gs);
```

- The testbench **implements** `vtm_retire` (C++ linkage `extern "C"`) and emits
  one func-mode `.vtrace` line per call.
- `n` is the core's own retire counter (starts at 0, +1 per retired insn).
- The core calls this from a single always_ff retire point; pairing (two retires
  in one cycle, M4+) means two calls in the same clock with consecutive `n`.
- **x87** (M3+) uses a second optional import `vtm_retire_x87(...)` called
  immediately after `vtm_retire` for FP-affecting instructions; defined later.
- A `--no-dpi` Verilator define lets the core compile without the import for
  standalone lint.

## 3. Bus-functional model (memory port group)

M0 is L1-only with a flat backing memory owned by the testbench. The core's bus
port is deliberately minimal at M0 and grows toward the real 64-bit P5 bus
(`ADS#/BRDY#/NA#/KEN#/CACHE#/...`, see PLAN §2) at M5. M0 contract:

| port | dir | width | meaning |
|---|---|---|---|
| `mem_req`   | out | 1  | request valid |
| `mem_we`    | out | 1  | 1=write, 0=read |
| `mem_addr`  | out | 32 | byte address |
| `mem_wdata` | out | 32 | write data |
| `mem_wstrb` | out | 4  | byte enables (writes) |
| `mem_rdata` | in  | 32 | read data (valid when `mem_ack`) |
| `mem_ack`   | in  | 1  | single-beat handshake (combinational-OK at M0) |

The testbench preloads the flat memory from the test image (§4) and services
`mem_req` each cycle. This is a placeholder protocol; M2 adds instruction fetch
width/lines, M5 replaces it with the modeled P5 bus FSM.

## 4. Image loading

The testbench loads a flat memory image and a load address from the test
manifest (`verif/tests/<name>/manifest.json`: fields `image` = path to a raw
binary blob, `load_addr`, `entry`). `verif/tests/` provides a helper that
extracts the loadable bytes of the test ELF into a flat blob. Reset vector / EIP
init = `entry`.

## 5. M0 NOP-stub behaviour

At M0 `ventium_top` need not decode/execute real x86. It must:
1. come out of reset cleanly,
2. retire a short, deterministic canned sequence (e.g. N "instructions"),
   calling `vtm_retire` with monotonic `n` and stub state (e.g. `pc=entry+seq*…`,
   zeroed regs), and
3. assert an end-of-trace condition (finite sequence, then idle) so the TB stops.

This proves the clock/reset/DPI/trace path end-to-end. Real decode/execute lands
at M1.
