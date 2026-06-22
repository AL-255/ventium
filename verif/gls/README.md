# verif/gls — xsim gate-level FreeDOS boot harness

A Xilinx **xsim** gate-level simulation (GLS) harness that boots SeaBIOS +
FreeDOS on the **synthesized `ventium_top` funcsim netlist**, reusing the
existing C/C++ memory + peripheral models via **DPI-C**. The point is to
reproduce the *board-only* instruction-fetch bug in a fully-visible netlist sim
(the real RAMB36 fetch RAMs, every flop nameable) — something Verilator's
2-state RTL sim is structurally blind to.

This is the SystemVerilog + DPI-C re-creation of the seams in the Verilator C++
testbench `verif/tb/tb_main.cpp` (the `--system --dos --l1-axi` / `l1axi_kv_dos`
path). It drives the netlist with the **deployed KV260 L1AXI boot config**.

## Files

| file | role |
|------|------|
| `gls_dpi.cpp`    | DPI-C exports: `gls_init`, `gls_mem_read32/write32`, `gls_io_service`, `gls_io_idle`, `gls_irq_poll`, `gls_inta`. Reuses `verif/tb/memmodel.cpp` (`MemModel`) + the PS peripheral C models `sw/ps_periph/*.c` verbatim — **nothing is reimplemented**. |
| `tb_gls_soc.sv`  | SV testbench: clk/rst/boot-config, the behavioral **AXI4 DDR slave**, the **port-I/O bridge** handshake, the **F3 IRQ0 timer pump**; instantiates `ventium_top`. |
| `run_gls_freedos.sh` | Full `xsc`/`xvlog`/`xelab`/`xsim` flow, RTL-mode and netlist-mode switch via `GLS_MODE`. Writes `gls_<mode>.log`. |

## How it works

The netlist drives a 40-bit AXI4 master (the deployed L1AXI config). The tb:

1. **DDR via AXI4 slave** (`tb_gls_soc.sv`): a behavioral read+write AXI4 slave
   whose FSMs (`axr`/`axw`) and **pre-edge-capture / post-edge-advance** phasing
   mirror `tb_main.cpp`'s `axi_drive()` / `axi_capture()` / `axi_advance()`. It is
   backed by `MemModel` through `gls_mem_read32` / `gls_mem_write32`. The KV260
   carveout `AXI_REMAP = 0x4000_0000` is **subtracted** off every AXI address
   before indexing (the MemModel is x86-phys-indexed), exactly like the Verilator tb.

2. **Port-I/O bridge**: `cosim_en=1`; the core raises `io_req/io_we/io_addr/
   io_size/io_wdata`, the tb answers `io_rdata/io_ack`. `gls_io_service` is the
   `service_io()` port dispatch — ONE side-effect per `io_req` assertion
   (`gls_io_idle` re-arms on deassert) to the PS C-models created by
   `ven_pit_new/ven_rtc_new/ven_pic_new/ven_i8042_new/ven_vgaregs_new/ven_ide_new`.
   Port map (same as `tb_main.cpp`): `0x60/0x64`→i8042, `0x20/21/A0/A1/4D0/4D1`→pic,
   `0x3B0-0x3DF`→vga, `0x40-0x43`→pit, `0x70/71`→rtc, `0x1F0-0x1F7 & 0x3F6`→ide,
   `0xF4`→isa-debug-exit (terminate), COM1 `0x3F8`/`0xE9` printed.

3. **Boot setup**: `gls_init` loads `seabios.bin` so its last byte is at phys
   `0xFFFFF` (`load = 0x100000 - filesize`), reset = `boot_mode=1` (CS=F000
   EIP=FFF0, real mode). Because SeaBIOS > 64 KiB, a second copy is staged at the
   KV260 carveout alias `(0 - filesize) & 0x0FFF_FFFF` (= `0x0FFE0000` for a 128 KiB
   ROM) — the deployed L1AXI `ADDR_MASK=0x0FFF_FFFF` folds the top-of-4G BIOS
   window there. The FreeDOS disk is attached to `ven_ide` via `--disk`.

4. **IRQ0 pump**: `gls_irq_poll(cycle)` raises IRQ0 every `VEN_IRQ0_PERIOD`
   (default 8000) cycles, presents the PIC vector on `intr`/`inta_vector` once the
   PIC is programmed; `gls_inta` intacks on the core's `inta` strobe. Mirrors the
   `--dos` IRQ pump in `tb_main.cpp`.

The netlist is built with **`VTM_NO_DPI`** (no retire DPI), so there is no
per-instruction retire counter to watch. Progress / termination is observed off
the bus instead: the per-`report_every` line prints IO-in/out counts +
`retire_count` (the netlist's own KV260 PS-observability counter) + the live AXI
handshake state; termination on isa-debug-exit (`out 0xf4`), `bus_err`, or
`max_cycles`.

## Running

```sh
# netlist mode (the real target): boots on fpga/build/ventop_funcsim/ventium_top_funcsim.v
GLS_MODE=net bash verif/gls/run_gls_freedos.sh

# netlist + on-die debug taps (the bug-hunt platform): boots on the +VEN_DBG_CORE
# netlist and prints committed PC / FSM / retire trajectory + auto-dumps on a wedge
# or fault. Needs the dbg netlist (synth_ventop_funcsim_dbg.tcl, built once).
GLS_MODE=net GLS_DBG=1 bash verif/gls/run_gls_freedos.sh

# RTL mode (harness debug): compiles against rtl/ ventium_top
GLS_MODE=rtl bash verif/gls/run_gls_freedos.sh
```

### GLS_DBG=1 — committed-state observability (the fetch-bug hunt mode)

The default funcsim netlist has **no observability**: progress is inferred off the
AXI bus only. `GLS_DBG=1` switches to a netlist synthesized **with
`+VEN_DBG_CORE`** (`fpga/scripts/synth_ventop_funcsim_dbg.tcl` →
`fpga/build/ventop_funcsim_dbg/ventium_top_funcsim_dbg.v`), which exposes
`ventium_top`'s `dbg_*` outputs. The tb (`` `ifdef VEN_DBG_CORE``) wires them and
adds a **GLS analogue of `dbg_dump_core()`**:

- **Periodic `gls-dbg:` line** alongside each progress report: committed
  `cs:eip`, `esp`, `eflags`, the live FSM micro-state, the last
  interrupt/exception vector, the fault PC, the in-tb retire count, and the PC-ring
  fill — i.e. *where the core actually is*, not just "the bus is busy".
- **Committed-PC ring** (32-deep), rebuilt in the tb from `dbg_eip` +
  `dbg_retire_valid` (the real `ven_soc_dbg` ring lives below `ventium_top`, so the
  tb reconstructs it). Dumped newest→oldest on any stop.
- **Wedge auto-detector**: if the core makes forward progress and then retires
  **nothing for `GLS_WEDGE_K` cycles** (default 200000; `0` disables), the harness
  dumps the committed-PC ring + live state + the current AXI fetch address and
  stops — so a derail-into-dead-memory wedge is caught automatically.
- **Fault auto-detector**: a **new non-IRQ exception vector** (`0x00`–`0x1F`,
  excluding the HW-IRQ ranges `0x08`–`0x0F` / `0x70`–`0x77` driven by the DOS IRQ0
  pump) triggers the same dump + stop. This is exactly the signal needed for the
  DOS-Quake "Division by Zero at eip=24e" hunt: the dump shows the committed-PC
  trajectory *into* the fault and the `ibuf@eip` fetch bytes, so a corrupted-fetch
  derail (mislabeled by go32 as `#DE`) is distinguishable from a real `#DE`.

DBG-mode env knobs:

| env | default | effect |
|-----|---------|--------|
| `GLS_DBG=1`         | `0`      | select the dbg netlist + `+define+VEN_DBG_CORE` + wire the taps |
| `GLS_WEDGE_K=<n>`   | `200000` | no-retire cycles before the wedge dump (`0` = disable) |
| `GLS_NO_STOP_FAULT=1` | `0`    | keep running past a detected exception (just dump, don't stop) |
| `GLS_NETLIST=<path>` | (auto)  | override the netlist path explicitly |

The `dbg_*` taps available at the `ventium_top` level are: `dbg_eip`, `dbg_cs`,
`dbg_esp`, `dbg_eflags`, `dbg_state`, `dbg_int_vec`, `dbg_fault_pc`,
`dbg_retire_valid`, `dbg_cr0`, `dbg_ibuf`, and the AXI read-beat tap
`dbg_rd_valid/_addr/_data`. The PC ring / freeze snapshot / comparator that the PS
reads over AXI-Lite (`0xA000_0000+0x80..`) live in `ven_soc_dbg` **below**
`ventium_top`, so they are not direct top-level ports — the tb rebuilds the ring
from `dbg_eip`/`dbg_retire_valid`.

To (re)build the dbg netlist (~15-20 min, one-time):

```sh
source /tools/Xilinx/2025.2/Vivado/settings64.sh
vivado -mode batch -source fpga/scripts/synth_ventop_funcsim_dbg.tcl
```

### GLS_FETCHSTRESS=1 — fast fetch-RAM exercise (no SeaBIOS POST)

A full SeaBIOS boot is multi-minute at gate-level. `GLS_FETCHSTRESS=1` (an env
knob read by `gls_init` in `gls_dpi.cpp`) instead stages a tiny self-contained
16-bit real-mode loop **at the reset far-jump target** (phys `0xFE05B`, where the
reset `jmp f000:e05b` lands) and overwrites the SeaBIOS entry there. The stream is
`mov cx,0x40` + an 80-byte NOP sled (spanning several fetch granules) + a tight
backward-branch loop (`dec cx; jnz back`) + `out 0xf4` (isa-debug-exit). The reset
vector itself is untouched, so the core takes the **exact same first control
transfer** as a real boot — only the landing code changes. This exercises the
fetch RAMs / line-select across cache-line boundaries in a few thousand gate-level
cycles instead of the full POST, so a fill/select-triggered fetch bug (if that is
its trigger) can be hit far faster. Combine with `GLS_DBG=1` to see the committed
PC trajectory through the loop:

```sh
GLS_MODE=net GLS_DBG=1 GLS_FETCHSTRESS=1 GLS_MAX_CYCLES=200000 \
  bash verif/gls/run_gls_freedos.sh
```

The default (knob unset) leaves the boot path byte-identical. This is a starting
scaffold — widen the sled / vary the branch displacements to sweep the fetch
address space if the simple loop does not trip the divergence.

Env knobs: `GLS_DISK` (default `verif/freedos/f4a/fdhi.img`), `GLS_BIOS`
(default `sw/ps/kv260/assets/seabios.bin`), `GLS_MAX_CYCLES`, `GLS_REPORT`,
`GLS_SKIP_COMPILE=1` (re-run only), `GLS_TRACE=1` (+ `GLS_TRACE_N=<bursts>`) for
the fetch forensics, `VIVADO_SETTINGS`.

The periodic report prints `retire=N io_in=.. io_out=..` plus the AXI transaction
counters (`ar`/`rbeat`/`aw`/`wbeat`) and last read/write address — enough to tell
"the core is making forward progress" from "the core wedged". `GLS_TRACE=1`
additionally dumps the first N AR addresses and their R-beat fill data (the
exact fetch stream), which is how the divergence below was localized.

The DPI shared object is built by a single `xsc` invocation (no `--shared`):
`.c` models compile with `gcc` (C linkage, matching the `extern "C"` decls in
`gls_dpi.cpp`), `.cpp` with `g++`. `xelab -sv_lib dpi` links it.

## Status

- **DPI-C glue (`xsc`)**: builds clean (`gls_dpi.cpp` + `memmodel.cpp` +
  `sw/ps_periph/*.c`).
- **Netlist mode (`GLS_MODE=net`)**: **WORKING** — `xvlog`/`xelab` (with
  `-L unisims_ver -L secureip` + `glbl`) elaborate the funcsim netlist + tb, and
  `xsim` runs. SeaBIOS is loaded, reset releases, the AXI slave + io-bridge are
  live, and bursts are serviced correctly. Gate-level sim is slow (~tens of k
  cycles/min for the full Pentium netlist).

### Reproduced: a netlist-vs-RTL fetch divergence (the board-only bug)

With `GLS_TRACE=1`, the harness immediately exposes a divergence between the
**funcsim netlist** and the **Verilator RTL**, fed byte-identical memory:

```
gls: [AR #1 @cyc 26] araddr=00400fffe0 (phys 000fffe0) arlen=7   <- reset-vector fetch, CORRECT
gls: [R beat #5] phys=000ffff0 data=00e05bea rlast=0             <- bytes ea 5b e0 00 f0 = jmp f000:e05b
gls: [AR #2 @cyc 65] araddr=0040003620 (phys 00003620) arlen=7   <- WRONG: jumped to phys 0x3620
gls: [R beat #9..16] phys=0000362x data=00000000                 <- 0x3620 is unpopulated (zeros)
... core wedges: retire_count stays 0, no further AR, forever.
```

The reset vector at phys `0xFFFF0` holds `ea 5b e0 00 f0` = `jmp f000:e05b`,
whose correct target is **phys 0xFE05B**. The netlist instead fetches **phys
0x3620**, lands in unpopulated (zero) memory, and **wedges with 0 instructions
retired**. The R-beat fill data for AR#1 is byte-for-byte identical to what the
Verilator RTL receives (`c08566ff 4b660475 ... 00e05bea ...`), and the
**Verilator RTL fed the same bytes reaches the SeaBIOS POST entry and retires
1577 instructions in 20k clocks / 226708 in 3M clocks, doing real port-I/O**
(69 IN / 283 OUT). So this is a **netlist-only** mis-computation of the reset far
-jump target — the synthesized `ventium_top` diverges from its own RTL on the very
first control transfer. This is precisely the kind of board-only fetch-path bug
the harness was built to make visible: every internal net of the failing far-jump
is now nameable in xsim (add a `log_wave`/`add_wave` or `-wdb` to capture the
fetch FSM, the L1 line buffer, and the jump-target adder around cyc 26–65).

Calibration reference (Verilator `obj_dir_l1axi_kvdos`, same images, quiesce
disabled): `--dos --l1-axi --image seabios.bin --disk fdhi.img --quiesce
100000000` → 226708 retired / 69 IN / 283 OUT in 3M clocks. (Note: the Verilator
default 64-clock quiesce trips during the first burst fill and aborts at "retired
1" — pass a large `--quiesce` to actually boot.)
- **RTL mode (`GLS_MODE=rtl`)**: the SV harness + DPI compile and `xvlog` the
  full RTL clean (the deployed define set, `--relax` to downgrade `ventium_top`'s
  legal forward-net-references). **`xelab` of the RTL core is blocked by an xsim
  language limitation** — `xsim` rejects an *indexed part-select of a
  concatenation/function-call result* (`{...}[7:0]`) in `rtl/core/decode.sv:56`
  ("[XSIM 43-3980] feature 'Indexed Expression' is not supported yet"). This is
  purely an xsim front-end gap on the behavioral RTL; the **funcsim netlist has
  no such expressions** (it is flattened gates), so the netlist path — the actual
  deliverable — is unaffected. To debug the harness against RTL under xsim, those
  few `{...}[N:0]` part-selects in the core would need rewriting into an
  intermediate temp (a core-source change, deliberately NOT done here so the
  synth/verify flow stays byte-identical).

## Notes / gotchas

- The funcsim netlist was synthesized **without `VEN_DBG_CORE`**
  (`fpga/scripts/synth_ventop_funcsim.tcl`), so the netlist `ventium_top` has **no
  `dbg_*` ports**. The run script therefore does **not** define `VEN_DBG_CORE`
  (the tb's `dbg_*` connections are under `` `ifdef VEN_DBG_CORE``, kept
  unconnected). Re-synthesize with `+VEN_DBG_CORE` if the dbg taps are wanted.
- Vivado's `settings64.sh` dereferences unset vars, so the script does **not**
  use `set -u`.
- `glbl` must be on the `xelab` top list in netlist mode (GSR for the unisim flops).
