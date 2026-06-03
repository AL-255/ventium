# Producer C — Verilator C++ testbench + bus-functional model

This directory is **Producer C** of the Ventium differential-verification stack
(see [`../../PLAN.md`](../../PLAN.md) §4.2 and
[`../../docs/trace-format.md`](../../docs/trace-format.md)). It verilates the RTL
core (`rtl/ventium_top.sv`), drives its clock/reset, services its `mem_*` bus
port from a flat preloaded memory, and emits a **functional-mode `.vtrace`** —
one record per retired instruction — that the comparator (`verif/diff/compare.py`)
diffs against the QEMU gdbstub golden trace (Producer A).

## Files

| file | role |
|---|---|
| `tb_main.cpp` | CLI + main loop: build model, load image, drive clk/rst, service bus, run-until-quiescent, finalize trace |
| `memmodel.h` / `memmodel.cpp` | flat sparse byte-addressable RAM + the `mem_*` bus-functional model (docs/rtl-interface.md §3/§4) |
| `dpi_retire.cpp` | implements the `vtm_retire` DPI callback (docs/rtl-interface.md §2) → emits one func `.vtrace` line per call |
| `trace_writer.h` | tiny shared object owning the open trace file + retire counter (shared by `tb_main.cpp` and `dpi_retire.cpp`) |
| `Makefile` | verilate + build the testbench; `selftest` target builds against the stub |
| `selftest/ventium_top.sv` | **throwaway** stub top obeying the rtl-interface contract; retires 8 NOPs |

## The interface contracts (do not deviate)

- **Ports** (`docs/rtl-interface.md` §1, §3): `clk`, `rst_n`, and the `mem_*`
  group (`mem_req`, `mem_we`, `mem_addr`, `mem_wdata`, `mem_wstrb`, `mem_rdata`,
  `mem_ack`).
- **Observation** (`§2`): the core *imports* `vtm_retire(...)` and calls it once
  per retired instruction with post-commit architectural state. The testbench
  *implements* it (`dpi_retire.cpp`). Verilator generates the DPI prototype into
  `obj_dir/Vventium_top__Dpi.h`; `dpi_retire.cpp` `#include`s it when present so
  the C types are checked against the generated prototype, with a matching
  fallback declaration otherwise. Type mapping:
  `longint unsigned → unsigned long long`, `int unsigned → unsigned int`
  (uint32), `shortint unsigned → unsigned short` (uint16).
- **Trace format** (`docs/trace-format.md` §1/§2.2): header line
  `{"vtrace":1,"producer":"rtl","mode":"func","x87":false,"note":"..."}` then one
  func record per retire with fields `n`, `pc`, `eax..edi`, `eflags`, `cs..gs`.
  32-bit values are `0x%08x`, 16-bit selectors `0x%04x`, lowercase, zero-padded
  — matching `verif/diff/tracefmt.py` exactly (the comparator parses by field
  name).

## Build & run

### Against the real core (what integration uses)

```sh
make            # verilates rtl/*.sv + rtl/**/*.sv against ventium_top, builds the TB
./obj_dir/tb_ventium --out run.vtrace \
    --image <flat.blob> --load 0x08048000 --entry 0x08048000
```

`make` is the **default**: it builds `obj_dir/tb_ventium` from the real
`rtl/` sources. If `rtl/` has no `.sv` files yet it prints a clear error and
points you at `make selftest`.

### Self-test (proves this component in isolation)

```sh
make selftest    # builds against selftest/ventium_top.sv into obj_dir_selftest/,
                 # runs it, prints the trace, and parses it with tracefmt.read_trace
```

The self-test exists because `rtl/` is authored by a sibling agent in parallel;
it does **not** depend on the real core. It builds a stub that retires 8 NOPs
over the `mem_*` handshake, then verifies a well-formed func `.vtrace` is
produced and that `n` is strictly increasing with valid hex fields.

### VCD waveforms (optional)

```sh
make TRACE=1            # (or: make selftest TRACE=1)  builds with --trace
./obj_dir/tb_ventium --out run.vtrace --trace-vcd run.vcd ...
```

### Clean

```sh
make clean      # removes obj_dir, obj_dir_selftest, selftest.vtrace
```

## CLI reference (`tb_main.cpp`)

| flag | default | meaning |
|---|---|---|
| `--out <file>` | *(required)* | output `.vtrace` |
| `--image <blob>` | *(none)* | raw bytes loaded into memory |
| `--load <hexaddr>` | `0` | byte address to load the blob at |
| `--entry <hexaddr>` | `0` | entry / reset EIP (informational at M0; recorded in the trace `note`) |
| `--max-insn N` | `1<<20` | stop after N retired instructions |
| `--max-cycles M` | `1<<24` | stop after M core clocks |
| `--quiesce K` | `64` | stop after K consecutive clocks with no retire |
| `--trace-vcd f` | *(off)* | write a VCD (requires `TRACE=1` build) |

Exit status is `0` on a clean run (quiescence / `--max-*` / `$finish`).

## How the bus loop works

The `mem_*` protocol at M0 is single-beat and combinational-ack-OK
(`docs/rtl-interface.md §3`). Each clock the testbench:

1. drives `clk` low, services the bus from the core's current outputs, `eval()`s;
2. drives `clk` high (the rising edge where `vtm_retire` fires inside `eval()`),
   services the bus again (in case the edge changed the request), `eval()`s.

`MemModel::service()` returns `(mem_rdata, mem_ack)`: reads return the
little-endian 32-bit word at `mem_addr`; writes honour `mem_wstrb` per byte;
`mem_ack` is asserted for any valid request. Memory is sparse (4 KiB pages in a
hash map) so a small image at a high address costs almost nothing; unmapped
reads return `0`.

## Notes for the integration phase

- **Default target builds against `rtl/`.** No edits needed once the real core
  is in place. `RTL_SRCS = $(wildcard $(RTL_DIR)/*.sv $(RTL_DIR)/**/*.sv)`. If
  the core grows nested subdirectories deeper than one level, extend that
  wildcard (or switch to a `find`-based list / a `.f` filelist).
- **Verified end-to-end against the real verilated core** (15 RTL files,
  `ventium_top` + submodules): it boots reset, retires the M0 canned sequence,
  and the testbench writes a well-formed func `.vtrace`. It is also verified
  against the throwaway stub via `make selftest`.
- The executable lands at **`verif/tb/obj_dir/tb_ventium`** (real) and
  **`verif/tb/obj_dir_selftest/tb_ventium`** (self-test).
- **Image source.** `--image` takes a raw flat blob (the loadable bytes of the
  test ELF). `verif/tests/` is expected to provide the ELF→blob helper plus
  `manifest.json` (`image`, `load_addr`, `entry`) per `docs/rtl-interface.md §4`;
  the testbench just consumes the blob + addresses.
- **M0 expectation.** Per `docs/trace-format.md §4`, the M0 stub's func trace
  will *not* match QEMU — the M0 gate is that every producer emits a well-formed
  `.vtrace` and the comparator runs end-to-end. Real functional agreement starts
  at M1.
- **x87 (`x87:true`) is not emitted yet.** The header pins `x87:false`. When the
  core adds the `vtm_retire_x87(...)` import (M3, `docs/rtl-interface.md §2`),
  add its DPI body in `dpi_retire.cpp`, extend the record with the §2.2 x87
  fields, and flip the header flag.
- `trace_writer.h` is a small shared header introduced to coordinate the two
  owned `.cpp` files (file-open + retire counter). It is header-only and
  dependency-free.
