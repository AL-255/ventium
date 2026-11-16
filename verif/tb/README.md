# Producer C — Verilator C++ Testbench & Bus-Functional Models (`verif/tb/`)

`verif/tb/` is **Producer C** of the Ventium differential-verification stack (`docs/rtl-interface.md`, `docs/trace-format.md`). It verilates `rtl/ventium_top.sv` from the ordered filelist `rtl/ventium.f` (plus optional L1/AXI and CDC leaf modules), services memory and I/O in C++, and emits functional or cycle `.vtrace` files via `vtm_retire` DPI callbacks for comparison against the pinned QEMU Pentium oracle (`verif/diff/compare.py`).

## Key Source Files

| File | Role |
| --- | --- |
| `Makefile` | Verilator build rules (`rtl`, `l1axi`, `l1axi_kv_full`, `l1axi_full_snapshot`, `l1axi_cdc`, `rtl-sva`, `cov`, `cov-feat`, `selftest`), cgroup/lock wrapper (`tools/verilator_serial.sh`), and bounded split/parallelism controls. |
| `tb_main.cpp` | CLI + main simulation loop: loads flat/BIOS/process images, drives `clk`/`rst_n`, services direct `mem_*` or 64-bit AXI4 (`--l1-axi`) and co-sim I/O (`--cosim`), enforces quiescence/cycle caps, and finalizes traces. |
| `memmodel.h` / `memmodel.cpp` | Sparse 4 KiB-paged byte-addressable RAM backing both the direct `mem_*` BFM and the behavioral AXI4 DDR responder. |
| `bfm_store_policy.h` | Drives per-byte U/V cached-store update masks on the standalone AXI BFM from the `MemModel` RAM/ROM/remap contract so ordinary RAM writes update rather than invalidate resident L1D lines. |
| `dpi_retire.cpp` / `trace_writer.h` | Implements DPI `vtm_retire` / `vtm_retire_x87` / system-state callbacks, emitting canonical `.vtrace` records matching `verif/diff/tracefmt.py`. |
| `syscall_emu.cpp` / `quake_image.cpp` / `win95_cosim.cpp` / `xover.cpp` | Optional M7/M14 Linux syscall proxy/emulator, user-snapshot loader, port-I/O replay co-sim, and `--public-flat-rw` state-crossover (`VEN_XOVER`) helpers. |
| `selftest/ventium_top.sv` | Minimal standalone stub top for `make -C verif/tb selftest` (validates DPI + `tracefmt` round-trip in `obj_dir_selftest/`). |

## Mandatory Build & Resource Safeguards

1. **Private Variant Object Directories:** `obj_dir/tb_ventium` is reserved for the canonical default build, and existing `obj_dir*` entries may be live symlinks into `external/ventium_run`. **Never clobber `obj_dir` or traverse/delete `obj_dir*` symlinks** when testing define variants — always pass a private directory (`OBJDIR=obj_dir_<variant>`, `L1AXI_OBJDIR=obj_dir_l1axi_<variant>`, or an external `/home/yukidama/external/tmp/...` `-Mdir`).
2. **Explicit Verilator & Serialized Build Lock:** All Verilator builds route through `tools/verilator_serial.sh` inside `tools/build_scope.sh`. On the maintainer host, set `VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator` explicitly (especially under `systemd-run`) and place scratch in `TMPDIR=/home/yukidama/external/tmp`. Python child processes launched inside the guard must inherit the lock descriptor (`pass_fds=(9,)`).
3. **Bounded C++ Parallelism (`VL_J`):** `VL_J` defaults to `1` with `--output-groups 0 --output-split 20000 --output-split-cfuncs 20000` and `-Werror-UNOPTFLAT`. Higher `VL_J` (`1..4` in `ipc_parallel`, `1..32` with `3000`-line splitting in `ipc_parallel32`) is permitted only inside the corresponding `VENTIUM_BUILD_SCOPE_PROFILE`.
4. **External C++ Harnesses:** Custom C++ harnesses compiled against a generated model must use per-model unique source basenames and verify local object/generated-header dependencies (`Vventium_top*.h`) so `VPATH` never reuses incompatible objects across define profiles.

```sh
# Canonical default core build (direct mem_* backend):
make -C verif/tb

# Isolated L1/AXI variant build (32-job bounded scope on maintainer host):
TMPDIR=/home/yukidama/external/tmp \
VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator \
VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
  tools/build_scope.sh -- make -C verif/tb l1axi VL_J=32 \
  L1AXI_OBJDIR=/home/yukidama/external/tmp/obj_dir_my_candidate \
  VL_EXTRA_DEFINES="+define+VEN_UOPCACHE +define+VEN_IC_BRAM"
```

## Runtime CLI Reference (`tb_ventium`)

| Flag | Default | Description |
| --- | --- | --- |
| `--out <file>` / `--no-trace` | *(required)* | Output `.vtrace` path, or `--no-trace` to suppress file formatting during long free-runs. |
| `--image <blob>` | *(none)* | Flat user binary or 64 KiB `--system` BIOS image (`0x100000 - size` ending at `0xFFFFF`). |
| `--load <hex>` / `--entry <hex>` | `0` / `0` | Load base and reset `EIP` for flat user-mode images. |
| `--init-esp <hex>` | `0x40c34910` | Initial `ESP` for user-mode ELFs (workers pass the golden's `n=0` `ESP` to align stack addresses). |
| `--x87` | off | Emit 80-bit `st0..st7` and `fctrl/fstat/ftag/fiseg/fioff/foseg/fooff/fop` (`x87:true`). |
| `--cycle` | off | Enable `cycle_mode=1` (dual-issue U+V fast pipeline) and emit `mode:"cycle"` timing records (`cyc`, `pipe`, `paired`, `stall`). |
| `--cycle-func` | off | Run with `cycle_mode=1` (dual-issue U+V fast pipeline active) while emitting full architectural state records (`mode:"func"`). Note: paired U+V callbacks report post-pair state; group-aware checkers compare at completed issue-group boundaries. |
| `--system` | off | Cold reset at `F000:FFF0` in real mode; emit `sys:true` records including `cr0/cr2/cr3/cr4` and segment selectors. |
| `--l1-axi` | off | **Required at runtime** to route core memory through `ventium_l1_axi` (`ven_l1d` + `ven_axi_master`, `bus_mode=2`) in `+VEN_L1_AXI` builds. Compiling `+define+VEN_L1_AXI` alone leaves `l1axi_en=0`! |
| `--bus-mode` | off | Route core memory through the pin-level 64-bit P5 `biu_p5` bus (`bus_mode=1`, used by `make bus-sva`). |
| `--cosim` / `--soc-en` | off | Service port `IN`/`OUT` (`0x3F8`/`0xE9` console, `0xF4` `isa-debug-exit`) and ungate SoC `CPUID`/`RDTSC`/`INVD`/`WBINVD`. |
| `--quiesce K` | `64` (`200000` with `--l1-axi`) | Stop after `K` consecutive clocks with zero retirements (explicit `--quiesce` overrides defaults). |
| `--max-insn N` / `--max-cycles M` | `1<<20` / `1<<24` | Hard instruction and clock caps. |
| `--errata <hexmask>` | `0` | Enable documented P5 silicon errata bits (`errata_en[4:0]`) for `make m6` (default `0` = clean core). |
| `--smm-dump <json>` / `--smbase <hex>` | off / `0x30000` | Dump SMRAM save-state map + handler sentinels after `--system` SMM runs (`psmm`). |
| `--dbg-step N` / `--dbg-bp <eip>` | `0` / `0` | `VEN_DBG_CORE` diagnostic controls only. **Never use in repair/performance acceptance runs** (inhibits U/V pairing). |
| `--trace-vcd <file>` | off | Emit VCD waveform (requires `TRACE=1` build). |

## Host Simulation & Observer Rules

- **Acceptance Mode:** Repair and performance qualification requires **`U/V + system fast-pipe`** (`--cycle` or `--cycle-func` with `cycle_mode=1`, plus `--l1-axi` on L1/AXI builds and verified non-zero backing traffic), never U-only or direct-memory diagnostic controls.
- **Unchanged-Input Settle Elision (`VL_INPUT_SNAPSHOT=1` / `--skip-unchanged-settle`):** Host-only direct-user optimization (`tools/prepare_inactive_l1_settle.py` / `model_input_snapshot.mk`) that omits redundant same-clock combinational settles only when every generated DUT input is unchanged. Both clock edges remain mandatory and **zero guest clocks are altered** (cannot be credited as an IPC or CM/MHz gain). Rejected when active AXI, system devices, debug ports, VCD tracing, or save/restore are enabled.
- **Memory-Geometry Observer (`VEN_MEM_GEOMETRY`):** Passive pre-edge hook (`memory_geometry_probe.h`, `check_memory_geometry.py`, `memory_geometry_proof.py`) remains inert unless `VEN_MEM_GEOM_LOG` is set. Enabling `VEN_MEM_GEOMETRY` at compile time requires a fresh same-elaboration `memory_geometry_model_map.h` generated via `memory_geometry_proof.py` (`begin` → Verilator `--dump-tree-json` → `seal` → `bind` → `verify`); never retrofit current `core.sv` state enum numbers onto an older compiled binary.
