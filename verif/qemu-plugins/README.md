# `verif/qemu-plugins/` — Producer B: QEMU TCG Cycle-Trace Plugin

`p5trace.c` builds into `build/p5trace.so`, a QEMU 8.2.2 TCG plugin (`QEMU_PLUGIN_VERSION 1`) that rides functional execution of `qemu-i386 -cpu pentium` and emits a **cycle-mode `.vtrace`** — **Producer B** of the Ventium verification stack (`docs/trace-format.md` §2.3).

For every retired instruction, `p5trace.so` buffers and writes a JSON-Lines record matching `verif/diff/tracefmt.py`:

```json
{"vtrace":1,"producer":"qemu-plugin","mode":"cycle","x87":false,"note":"p5trace: ..."}
{"n":0,"pc":"0x08049092","cyc":9,"pipe":"U","paired":false,"stall":8,"bytes":"31ed"}
```

## Model Scope & Limitations

`p5trace.c` shares the analytical non-MMX Pentium (P5/P54C) timing core of `ventium-refs/07-p5-emulation-harness/plugin/p5model.c`:

- **Dual-issue U/V pairing** per Intel AP-500 / Agner Fog pairing rules (unprefixed 32-bit `PUSH r32` / `POP r32` are classified with their implicit `SS:[ESP]` memory access for D-cache and AGI accounting).
- **RAW result latencies** and **1-cycle AGI stalls** when a base/index GPR was written in the immediately preceding clock.
- **256-entry, 4-way BTB** with 2-bit saturating counters (`3`-cycle U / `4`-cycle V mispredict penalty).
- **Split 8 KiB, 2-way, 32 B L1 I/D caches** with configurable fixed miss penalty (`imiss=8`, `dmiss=8` default) and `+3`-cycle misaligned data penalty.

> **Important Boundary:** `p5trace.so` is an **L1-resident, single-threaded user-mode cycle estimate** used to gate the M4/M5 microbenchmark bands on the direct-memory testbench (`make verify`). It does **not** model multi-beat AXI4/DDR4 linefills, page-table walks, posted write buffers, or PC/AT peripheral I/O, and **never substitutes for physical Quake gameplay IPC** (current verified baseline on `c0e3fe43`: **`0.515778001` total U+V / `0.397847833` primary/U**).

## Building & Running

```sh
make plugin   # from repo root -> build/p5trace.so
```

Or standalone:

```sh
make -C verif/qemu-plugins \
  QEMU_SRC=/path/to/ventium-refs/07-p5-emulation-harness/build/qemu \
  CAPSTONE=/path/to/ventium-refs/07-p5-emulation-harness/build/capstone
```

Run under the pinned `qemu-i386`:

```sh
QEMU=ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386
"$QEMU" -cpu pentium -plugin build/p5trace.so,out=/tmp/cyc.vtrace <static-elf>
```

### Plugin Arguments (comma-separated)

| Argument | Default | Meaning |
| --- | --- | --- |
| `out=<path>` | `stderr` | Output `.vtrace` path |
| `imiss=<n>` / `dmiss=<n>` | `8` / `8` | Modeled L1 I-cache / D-cache miss penalty in clocks |
| `cache=<0\|1>` | `1` | Enable (`1`) or bypass (`0`) L1 I/D cache modeling |
| `bytes=<0\|1>` | `1` | Emit optional lowercase hex instruction `bytes` per record |
