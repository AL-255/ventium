# FPGA build and hardware-verification guide

This is the operating procedure for the Ventium-swapped `ao486_MiSTer` system on
the RK-XCZU15EG-F board. It covers the current build, deployment, test, and
debug tools as inspected through **2026-08-23**.

The short version is:

1. Record the exact source state.
2. Pass the relevant simulation gates.
3. Build the AArch64 board daemon.
4. Validate the Vivado block design, then build the full bitstream.
5. Sign off timing, DRC, and utilization from the final reports.
6. Hash the artifacts, preflight the board, and program the PL through Linux.
7. Prove the control path with `IDENT`, then test POST, disk boot, Quake, and
   Win95 in that order.
8. Keep logs and hashes. `fpga state: operating` alone is not proof that the
   intended bitstream is running.

> **Current stop condition (2026-08-23):** the superseding L1 request-ownership
> image passes the reset-state IRQ/IRET ROM twice, boots production BIOS and
> FreeDOS, and reaches CWSDPMI. The source-repaired
> `fpga_run_20260823_lds2` image also executes beyond the old protected-mode
> `66 67 C5 75 10` LDS blocker and enters Quake code. Quake still fails later:
> direct capture shows vector 14 after deterministic stack corruption, and a
> final clean 600-second run produced no exact 969-frame result. See
> `fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md` and
> `fpga_verify_20260822/quake_lds_repaired/README.md` for evidence and proposed
> fixes.

The same `l1bypown` image cleanly passed the established headless Win95
VMM/System-VM desktop signature on 2026-08-23 with reset-state CR0 and no input,
flush, freeze, or guest patch. See
`fpga_verify_20260822/win95_l1bypown/README.md`.

## 1. Scope and sources of truth

Use these paths on the current development host:

```bash
VENTIUM=/home/yukidama/github/ventium
FLOW=/home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system
TEMPLATE=/home/yukidama/external/RK-XCZU15EG-F-Template
BOARD=riguke@10.0.0.214
SSH_CONFIG=/dev/null
```

The repositories have distinct roles:

| Location | Role | Authority |
|---|---|---|
| `$VENTIUM` | Ventium RTL, ao486 file lists, simulation gates, BIOS ROMs | Functional RTL and verification |
| `$FLOW` | RK board top, PL/PS bridges, Vivado project generator, daemon, deploy helpers | Actual FPGA integration |
| `$TEMPLATE` | Board PS preset, Linux/FPGA-manager flow, complete BSP and SD-image build | Board and Linux reference |
| `$VENTIUM/ao486-sim/DISK_BOOT_STATUS.md` | Append-only bring-up and forensic record | Historical evidence, not an operating procedure |

The board reference is the local checkout of
[AL-255/RK-XCZU15EG-F-Template](https://github.com/AL-255/RK-XCZU15EG-F-Template).

Important reproducibility limitation: `$FLOW` is currently an **untracked
directory** in the separate `/home/yukidama/github/ao486_MiSTer` checkout. At
the time of inspection:

```text
Ventium HEAD                 4a643c164e80 (with a dirty working tree)
standalone ao486_MiSTer HEAD ddadd507564d
RK template HEAD             08b0b171d77b
flow status                  ?? fpga/rk-ao486-system/
```

A clean clone therefore does not reproduce the hardware flow. Before treating
this as a release-quality flow, commit or otherwise archive `$FLOW`, including
its source, constraints, software, and scripts. Do not archive generated
`build/`, Vivado journals, binaries, or disk images.

The flow's own `README.md` is historical and is not authoritative for current
commands or results. It describes old first-fetch blockers and a nonexistent
`scripts/build.sh`. The source now implements a `/32`, approximately 3 MHz core
clock; an older 2026-08-01 artifact ran at 5.966 MHz and is only a comparison
baseline. The latest source-matched hardware outcomes are stricter than the
historical forensic log. The timing-valid non-fast control image reached the
established Win95 VMM/System-VM desktop signature on 2026-08-21. The first
repaired-fast `irqfix` image still corrupted real-mode BIOS control flow after
the valid VGA option-ROM return. The superseding `l1bypown` image fixes that
request-A versus request-B ownership defect and boots FreeDOS. The later `lds2`
image repairs the protected far-pointer decode/atomic-commit gap and crosses its
exact silicon discriminator, but Quake then exposes the page-fault/stack-
corruption path described in the stop condition. No current image has completed
the exact 969-frame timedemo; never convert startup/progress into a pass.

## 2. Hardware architecture

The design targets `xczu15eg-ffvb1156-2-i` and uses the running Linux system on
the Zynq UltraScale+ PS:

```text
Linux/A53 PS
  M_AXI_HPM0_FPD -> AXI-Lite -> control/mgmt at 0xA000_0000 (64 KiB)
  S_AXI_HP0_FPD  <- 128-bit converter <- 64-bit Ventium memory AXI
                                      -> guest RAM at 0x6000_0000 (256 MiB)
  FPGA manager/PCAP programs the PL at runtime

PL
  ao486_MiSTer system + Ventium core
  control/mgmt bridge + DDRAM-to-AXI bridge + custom debug block
  LED pins are the only external PL I/O and keep the design structurally anchored
```

Guest RAM is PS DDR, not the board's separate PL DDR4. Stock Linux leaves the
PS `pl0_ref` clock at approximately 100 MHz. `clk_div32.v` cascades BUFG
divisions of `/8` and `/4`, so silicon runs the core at `/32`, approximately
3.125 MHz. The local wrapper must model that clock tree; older reports that
show 95.456 MHz / 2.983 MHz are under-constrained for this running platform.
For a deliberately slower diagnostic run, the source-controlled board probe
can select the PS IOPLL `/16` profile: 93.75 MHz PL and approximately
2.9297 MHz after `/32`. That profile is timing-safe for an image routed at
95.456/2.983 MHz. Do not select the superficially matching RPLL `/11` profile
on stock Linux: the live RPLL rate differs from the Vivado preset and was
measured at 3.0303 MHz after `/32`, faster than that image's constraint.

The HP0 path is deliberately 128 bits at the PS boundary. An explicit AXI
clock converter and 64-to-128-bit width converter avoid a previously observed
PS-side 128-to-64-bit data-duplication failure. Do not simplify that path based
only on block-design validation.

The current memory bridge also contains a build-specific priming/double-read
workaround for stale HP0 data. It is not a complete repair: the 2026-08-22
silicon A/B proves that one discarded narrow response followed by one replay
can still deliver stale reset-state data. Do not increase the replay count as
an acceptance fix; capture transaction ownership and root-cause the HP0 reset,
drain, and converter path. The current debug ring has been repurposed more than
once during bring-up. Consequently, a daemon, bitstream, and debug decoder must
be treated as one versioned set.

## 3. Safety rules

- Reprogramming the PL disrupts the current guest immediately. Check for an
  existing `ao486d` first and stop it deliberately before loading a bitstream.
  Process absence does **not** mean the guest is idle: the daemon can exit after
  releasing the core, leaving the PL running. Read `CTRL`/`STATUS` with
  `ao486d --ident` as well. `CTRL=0x102` means RUN+IRQ are still enabled.
- A normal `ao486d` run holds/resets the core, zeros all 256 MiB of guest RAM,
  loads BIOS state, and then releases the core. It destroys the current guest
  session even when no disk is supplied.
- Win95 writes its disk image. Restore or clone a known-good image before a
  repeatable run.
- `ven_board_probe.py clock ...` writes the PS `PL0_REF_CTRL` register. Stop
  `ao486d` first and reset/reinitialize the guest afterward. Every other probe
  mode remains read-only.
- The board root filesystem was 95% full with about 79 MiB free at the
  2026-08-09 inspection.
  The 2 GiB Win95 VHD is sparse. Never send it with ordinary `scp`, which can
  materialize the holes and fill the filesystem. Use `rsync -S --inplace`.
- `--inject-keys` changes guest BDA memory and triggers a cache flush.
  `--stall-flush` is explicitly a workaround. A run that needs either option
  is diagnostic evidence, not a clean correctness pass.
- Trace freeze and comparator modes can stop or reset the core. Use them only
  after a normal run has failed or when the run is intentionally diagnostic.
- Never access the PL AXI-Lite window through `/dev/mem` unless
  `/sys/class/fpga_manager/fpga0/state` is exactly `operating`. An access to an
  unconfigured PL address can leave the PS interconnect waiting indefinitely
  and take the board off the network. The source-controlled board probe checks
  this condition; use its `quake --precheck-only` mode for disk-only checks.
- Do not put passwords in new scripts or logs. The existing deploy helpers use
  password-oriented defaults and disable strict host-key checking; prefer SSH
  keys and a normal `known_hosts` entry for manual/release use.
- No local serial or JTAG device (`ttyUSB*`/`ttyACM*`) was attached at the
  2026-08-09 inspection. The current flow has no Xilinx ILA/VIO/debug bridge. Its
  “mini-ILA” is a custom AXI-Lite register/ring block, not Vivado ILA.

### JTAG capability boundary

The deployed flow is deliberately **PCAP-only**: Linux's FPGA manager loads a
raw bitstream through the ZynqMP PS and does not establish a JTAG transport.
The current image contains neither a Xilinx debug hub/ILA/VIO core nor an
`.ltx` probe map, and the available AXI-Lite forensic registers are not a JTAG
scan chain.  The deployed image cannot scan arbitrary fabric state,
preserve-and-resume the core, single-step it, or restore a captured machine
state. The in-tree debug-image work described below adds an AXI-Lite
instruction-boundary halt/step facility, but it is still not JTAG and does not
change this deployment boundary.

The RK board itself has physical JTAG headers (base-board 2x5 standard and
core-board 1x6 at 3.3 V).  Full Vivado JTAG therefore requires an attached,
authorized Xilinx-compatible cable reachable from this host or an explicitly
configured remote `hw_server`/XVC endpoint.  Neither is present in this setup.
Adding ILA/VIO, a debug hub, or BSCANE2/Virtual-JTAG logic is a debug-bitstream
change and requires a matching `.ltx` plus a new timing/sign-off run; it cannot
be enabled against the deployed bitstream by a board-side script.  Prefer the
source-controlled AXI capture and simulator save/restore procedures below
until that hardware and a debug image are explicitly authorized.

## 4. Host prerequisites

The inspected host has the expected toolchain:

```text
Vivado 2025.2, build 6299465
/tools/Xilinx/2025.2/Vivado/bin/vivado
aarch64-linux-gnu-g++ (Ubuntu GCC 15.2.0)
ssh, scp, rsync, sha256sum
```

The inspected host also has an unsafe system SSH fragment,
`/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` (owned by `nobody`, mode
`0777`). OpenSSH refuses to start with that file. The explicit commands below
use `-F "$SSH_CONFIG"` to bypass the broken system configuration while retaining
normal user identity and host-key files. An administrator should instead restore
the fragment's intended owner and permissions. Do not work around it by disabling
host-key checking.

Initialize the Xilinx environment before building hardware or the daemon:

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
vivado -version
aarch64-linux-gnu-g++ --version
```

The project generator hard-codes `$VENTIUM` and `$TEMPLATE`; moving either tree
requires updating `hw/create_project.tcl`. The template supplies
`board/XCZU15EG_Base_Config.tcl`, which configures PS DDR/MIO/clocks. The running
board was booted from the template's Linux/BSP flow and already provides:

```text
/usr/local/bin/load-bitstream.sh
/sys/class/fpga_manager/fpga0
configfs device-tree overlays
dtc
```

Normal Ventium iteration does **not** require rebuilding `BOOT.BIN`, the kernel,
rootfs, or SD-card image. Rebuild those from `$TEMPLATE` only when changing or
repairing the PS/Linux platform; see its `docs/03-build-guide.md` and
`docs/04-bitstream-from-ps.md`.

## 5. Record provenance before building

Create a run directory outside generated Vivado output and capture at least:

```bash
date -Ins
git -C "$VENTIUM" rev-parse HEAD
git -C "$VENTIUM" status --short
git -C /home/yukidama/github/ao486_MiSTer rev-parse HEAD
git -C /home/yukidama/github/ao486_MiSTer status --short -- fpga/rk-ao486-system
git -C "$TEMPLATE" rev-parse HEAD
vivado -version
sha256sum "$VENTIUM/rtl_ven_core.f" "$VENTIUM/rtl_ven_soc.f"
```

If any RTL or flow source is dirty, save the diff with the test results. A
commit ID by itself is insufficient. Also record the exact synthesis defines;
`hw/create_project.tcl` is the authority. The inspected configuration includes
`VEN_CORE`, `VEN_L1_AXI`, `VEN_L1_HONOR_CD`, the iterative/FPU options,
`VEN_DBG_CORE`, `VEN_FAST_RETRACE`, `VEN_KBD_AUTOACK`, and `VEN_KBC_FAST`.

## 6. Run pre-hardware verification

Hardware should be the last stage of verification, not the first. From
`$VENTIUM`, run the gates appropriate to the change:

```bash
cd "$VENTIUM"
make verify
make l1
make verify-all
```

`verif/run-verify-all.sh` is the authority for what `verify-all` includes in
this branch. It explicitly excludes some historical SoC/Quake/Win95 suites that
are absent here, so a green umbrella is necessary but not proof of a full-PC
boot. For system-mode or memory changes, also run the corresponding directed
gates rather than relying only on the fast differential gate.

Do not use a cache-disable, blanket serialization, periodic reset, forced
flush, or retry loop to turn a failing hardware run green unless the purpose is
fault isolation. Such a run must remain labeled diagnostic.

## 7. Build the board daemon

The daemon reuses the MiSTer PS x86/disk code from
`$VENTIUM/ao486-sim/ps`. It must be a static AArch64 binary because the board's
glibc is older than the cross toolchain's:

```bash
cd "$FLOW"
make -C sw
file sw/ao486d
sha256sum sw/ao486d
```

Expected output is an AArch64 statically linked executable. If the compiler
prefix differs, pass `CROSS=<prefix>-` to `make`.

## 8. Build and sign off the FPGA image

### 8.1 Validate the block design

```bash
cd "$VENTIUM"
"$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
  -source fpga/create_project_3mhz_wrapper.tcl \
  -tclargs bd "$VENTIUM/fpga_run_<tag>"
```

This creates and validates the block design but does not synthesize it. It is a
quick check for missing files, interface inference failures, address conflicts,
and PS/AXI width propagation errors. Confirm the log reports HP0 at 128 bits.

### 8.2 Run synthesis, implementation, and bitstream generation

#### Mandatory single-run guard

Use `fpga/run_vivado_exclusive.sh` for **every** Ventium Vivado launch.  It
holds an exclusive host lock and, before each new top-level build, terminates
every existing `vivado` process (including stale synthesis workers), waits for
them to disappear, then starts the replacement.  A Vivado run may still use
its deliberately bounded internal workers selected by `VEN_FPGA_JOBS`; the
rule is that there is only one top-level run on the host.

This is intentionally host-global and destructive to another active Vivado
job.  Do not launch `vivado -mode batch ...` directly, do not run two FPGA
commands in separate terminals, and do not bypass the guard with a background
shell.  The launcher records the PID/command line it terminates and escalates
from `SIGTERM` to `SIGKILL` if a stale process survives 45 seconds.

```bash
"$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
  -source "$VENTIUM/fpga/create_project_3mhz_wrapper.tcl" \
  -tclargs all "$VENTIUM/fpga_run_<tag>"
```

The local wrapper evaluates the external authoritative Tcl after correcting
its stale 6 MHz interface metadata to 3 MHz, models the running board's IOPLL
`/15` 100 MHz PL clock, enables the verified `VEN_SYS_FASTPATH` plus its narrow
equal-common-base `VEN_SYS_FASTPATH_RELOC` and full-limit DS
`MOV r32,[base{+disp8|+disp32}]` `VEN_SYS_FASTLOAD_FLAT` extensions (the latter differential-tested with a
common non-zero base and non-identity paging; not `VEN_SYS_FASTPATH_ALL`),
caps Vivado at four threads, and selects `AreaOptimized_high`. The direct
upstream script still labels the `/32` clock as `/16`/6 MHz and imports a PS
clock configuration that does not match stock Linux; do not bypass the wrapper
for this image. A BD preflight should report
approximately 99.999 MHz for `pl_clk0`; the final clock summary must report
approximately 3.125 MHz for the divided core.

Two environment knobs support controlled implementation experiments:

```bash
# Diagnostic A/B: omit both system-fast-path defines, leave every other define unchanged.
VEN_FPGA_FASTPATH=0 VEN_FPGA_JOBS=2 \
  "$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
    -source "$VENTIUM/fpga/create_project_3mhz_wrapper.tcl" \
    -tclargs all "$VENTIUM/fpga_run_<tag>"
```

`VEN_FPGA_FASTPATH` defaults to `1`; setting it to `0` removes the system
fast-path defines. `VEN_FPGA_RELOC_FASTPATH` also defaults to `1`; setting it
to `0` retains the stricter base-zero subset. `VEN_FPGA_FASTLOAD` defaults to
`1`; setting it to `0` retains the system register/control path but sends all
memory loads to the slow FSM for a source-identical diagnostic A/B.
`VEN_FPGA_JOBS` accepts 1 through 4 and defaults to 4. Use 2 on the current
build host: a four-worker run lost synthesis workers under
memory pressure, while the successful two-worker run still reached roughly
22.6 GiB physical memory. Always verify the generated synthesis Tcl's
`verilog_define` line rather than trusting an output-directory label.

### 8.2.1 Preset-free PCAP fallback

On the currently installed Vivado 2025.2/IP catalog, the external template's
board-level PS preset can be rejected during project creation (incompatible
MIO/DDR settings) before RTL synthesis begins. The wrapper supports the
upstream script's documented preset-free fallback for this **PCAP-only** case:

```bash
VEN_FPGA_SKIP_PRESET=1 VEN_FPGA_FASTPATH=0 VEN_FPGA_JOBS=2 \
  "$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
    -source "$VENTIUM/fpga/create_project_3mhz_wrapper.tcl" \
    -tclargs bd "$VENTIUM/fpga_run_<tag>"
```

It retains the wrapper's explicit GP0, HP0, and PL-clock configuration; the
already booted Linux/FSBL owns the PS configuration when loading a raw PL
bitstream through PCAP. The BD preflight must still validate with HP0 at 128
bits and `pl_clk0` near 100 MHz. Do not use this switch to export an XSA,
rebuild BOOT.BIN, or change the PS/Linux platform. It is a compatibility
fallback for raw runtime PL images only.

The mode behavior is subtle:

- `bd`: create and validate the BD, then return.
- `all`: synthesize, implement through `write_bitstream`, and copy the results.
- Any other string, including the advertised `xsa`, runs synthesis but does not
  emit a useful XSA. Do not depend on `xsa` mode in this flow.

The canonical outputs are:

```text
$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit
$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit.bin
$VENTIUM/fpga_run_<tag>/rk_ao486_system/rk_ao486_system.runs/impl_1/
```

`write_bitstream -bin_file` creates the raw `.bin`; the flow copies it to the
`.bit.bin` name. Do not run the template's `bit2bin.sh` on it again.

### 8.3 Sign-off checks

Do not accept `## IMPL OK` or a single WNS line as complete sign-off. Review the
final post-route/post-physical-optimization reports:

```bash
IMPL="$VENTIUM/fpga_run_<tag>/rk_ao486_system/rk_ao486_system.runs/impl_1"

rg -n -A 12 'Design Timing Summary|Clock Summary' \
  "$IMPL/rk_ao486_bd_wrapper_timing_summary_postroute_physopted.rpt"

rg -n 'CLB LUTs|LUT as Logic|CLB Registers|Block RAM Tile|DSPs|URAM' \
  "$IMPL/rk_ao486_bd_wrapper_utilization_placed.rpt"

sed -n '1,80p' "$IMPL/rk_ao486_bd_wrapper_drc_routed.rpt"
```

Acceptance criteria:

- setup and hold WNS are non-negative;
- TNS and THS are zero with no failing endpoints;
- all user timing constraints are met;
- routed DRC contains no Error or Critical Warning;
- utilization is plausible and routability margin has not collapsed;
- the reported clocks match the intended PS and divided core clocks; and
- the sign-off record states both the constrained clock frequencies and a
  measured on-board core frequency.  WNS/WHS demonstrate timing closure at a
  constraint; they are not a frequency measurement.

Warnings still require review. The inspected routed DRC had no errors, but had
many DSP pipelining warnings plus a clock-buffer cascade and one no-load
warning. Do not blindly waive new warning classes.

The 2026-08-29 passive-VGA-capture build is the current board image.  It has
route/timing/DRC sign-off and its clocks were measured while the normal guest
boot was running, but it is not a workload-acceptance result yet:

| Metric | Value |
|---|---:|
| raw image SHA-256 | `279bc2c0caa14cbea169ddf1b25a60407ef0b44bbc3a92186d96e251895064fd` |
| constrained PL / divided / core clock | 100.000 MHz / 12.500 MHz / **3.125 MHz** |
| measured live core clock | **3.125179 MHz** over 2.000085 s (separate 1.000072 s sample: 3.125326 MHz) |
| WNS / TNS | +4.521 ns / 0 |
| WHS / THS | +0.014 ns / 0 |
| CLB LUT | 315,981 / 341,280 (92.59%) |
| CLB registers | 42,984 / 682,560 (6.30%) |
| BRAM tiles | 101 / 744 (13.58%) |
| DSP | 1,264 / 3,528 (35.83%) |
| route | 415,938 routable nets; fully routed |
| silicon status | passive recorder is armed; cold boot reaches FreeDOS, then returns to the real-mode `C:\QUAKE>` prompt without a 969-frame timedemo result (workload acceptance blocked) |

The two counter samples use the retired-cycle counter and elapsed host interval,
so their small difference is measurement jitter rather than an overclock claim.
Use **3.125 MHz** as the implementation frequency and quote the measured value
with its sampling interval when reporting silicon results.

The workload blocker above is not a clock-rate inference. Read-only samples
show the live real-mode FreeDOS/BIOS path (`CR0=0x00000010`) through firmware
(`f000:xxxx`), IO.SYS (`0070:xxxx`), and the command interpreter (`05f7:xxxx`).
A simultaneous 1.000071 s counter interval retired 181,638 instructions at
**3.125329 MHz** but issued zero new AXI reads; the last completed disk-read
count was 527. The sparse core-observation reconstruction contains a recent
`C:\QUAKE>` prompt. It therefore establishes that the timedemo command has
returned to DOS, not that Quake ran or that a disk/CPU hang occurred. The exact
error/exit cause remains open. This diagnosis neither resets nor changes the
guest, disk image, or passive recorder.

The latest corrected-clock repaired candidate was built and deployed on
2026-08-22. It is the current implementation reference, but **not a functional
acceptance image**:

| Metric | Value |
|---|---:|
| raw image SHA-256 | `f8f69b38417a6039db64f38c691bb1c65111afc09f670b02042e09177c2d3bf1` |
| WNS / TNS | +2.004 ns / 0 |
| WHS / THS | +0.011 ns / 0 |
| PS clock / core clock | 99.999 MHz / 3.125 MHz |
| CLB LUT | 316,250 / 341,280 (92.67%) |
| CLB registers | 42,339 / 682,560 (6.20%) |
| BRAM tiles | 85 / 744 (11.42%) |
| DSP | 1,265 / 3,528 (35.86%) |
| route | 415,779 fully routed nets; 0 unrouted nets |
| silicon result | FAIL: reset-state non-cacheable narrow read returns stale data before POST |

The cacheable A/B ROM passes both 256-iteration interrupt phases on this exact
image, while the default reset-state ROM fails deterministically. Treat timing,
DRC, and utilization sign-off as necessary conditions only; this is the current
counterexample showing why the focused silicon gate must precede workloads.
See `fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md`.

The source-matched `AreaOptimized_high` candidate built on 2026-08-20/21 had
the following implementation results. This table is retained as historical
utilization evidence, but the image is **not timing-valid on stock Linux**:

| Metric | Value |
|---|---:|
| WNS / TNS | +1.606 ns / 0.000 ns |
| WHS / THS | +0.010 ns / 0.000 ns |
| PS clock / core clock | 95.456 MHz / 2.983 MHz |
| CLB LUT | 315,780 / 341,280 (92.53%) |
| LUT as logic | 312,370 (91.53%) |
| CLB | 41,933 / 42,660 (98.30%) |
| CLB registers | 42,367 (6.21%) |
| BRAM tiles | 85 (11.42%) |
| DSP | 1,265 (35.86%) |
| route | 415,264/415,264 routable nets complete; 0 errors/overlaps |

All ten CDC bus-skew constraints pass (minimum slack +9.637 ns), all internal
endpoints are constrained, routed DRC/bitgen have zero errors and zero critical
warnings, and the deployable `.bit.bin` SHA-256 is
`fce0eb3f431c5ea813cc5fca832d5c0d5f89d1a2eb2333a6f4a6f9a51af49a5d`.
This image was internally clean at its reported clocks but had only 1.70% CLB
headroom. It must not be used as a board acceptance image: a source-controlled
counter sample later measured the live core at 3.125041 MHz, faster than the
2.983 MHz constraint. Preserve the warning/congestion audit in
`FPGA_RUN_Aug20.md`, and require a new route against the real clock.

The 2026-08-21 corrected-clock non-fast attempt used the same current sources
with `VEN_FPGA_FASTPATH=0` and modeled 99.999 MHz / 3.125 MHz. Synthesis and
placement succeeded with zero errors, but the 90.70% LUT / 96.55% CLB design
was not legally routable: after 3 h 17 min, `route_design -directive Explore`
ended with 592 node overlaps and reported 935 signals affected by congestion.
Vivado wrote only `rk_ao486_bd_wrapper_routed_error.dcp`; no bitstream was
generated or deployed. An intermediate positive WNS is not usable when route
verification fails.

For comparison, the older **host artifact** built on 2026-08-01 had:

| Metric | Value |
|---|---:|
| WNS / TNS | +1.470 ns / 0.000 ns |
| WHS / THS | +0.012 ns / 0.000 ns |
| PS clock / core clock | 95.456 MHz / 5.966 MHz |
| CLB LUT | 298,463 / 341,280 (87.45%) |
| LUT as logic | 292,297 (85.65%) |
| CLB | 40,875 / 42,660 (95.82%) |
| CLB registers | 34,672 (5.08%) |
| BRAM tiles | 85 (11.42%) |
| DSP | 1,262 (35.77%) |
| URAM | 0 |

This is a comparison baseline, not an evergreen pass result. It predates the
current dirty Ventium RTL and cannot validate those changes.

Finally hash the deployable set:

```bash
sha256sum \
  "$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit.bin" \
  "$FLOW/sw/ao486d" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot0.rom" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot1.rom"
```

## 9. Board preflight

All commands in this section are read-only:

```bash
ssh -F "$SSH_CONFIG" "$BOARD" 'hostname; uname -a; df -h / /tmp'
ssh -F "$SSH_CONFIG" "$BOARD" 'cat /sys/class/fpga_manager/fpga0/state'
ssh -F "$SSH_CONFIG" "$BOARD" 'pgrep -a -x ao486d || true'
ssh -F "$SSH_CONFIG" "$BOARD" 'ls -lh /tmp/ao486 2>/dev/null || true'
ssh -F "$SSH_CONFIG" "$BOARD" \
  'sha256sum /tmp/ao486/rk_ao486_system.bit.bin /tmp/ao486/ao486d 2>/dev/null || true'
```

If the staged daemon is the one built from the inspected `board_shim.cpp`, its
`--ident` path only reads the control/debug registers (it does not hold/reset,
zero RAM, mount a disk, or release the core):

```bash
ssh -F "$SSH_CONFIG" -t "$BOARD" 'sudo /tmp/ao486/ao486d --ident'
```

Run that command only after the preceding FPGA-manager check reports
`operating`; “read-only” does not make an access to an unconfigured PL address
safe. Recheck the implementation before assuming a future daemon's `--ident`
is read-only.

On 2026-08-09, the board was `rk-xczu15eg-f`, ran Linux 6.12 on AArch64,
reported FPGA state `operating`, and had about 79 MiB free on a 95%-full root
filesystem. No `ao486d` process existed, but the read-only IDENT probe returned
`STATUS=0x100` and `CTRL=0x102`: the core was still released and running. The
staged files were:

```text
host bitstream  45207ed279f67a431b8782f57ad902c7428fc9f99ea9df87645c46cacd6de01b
board bitstream 2d71598087053eecdb62a53c8380de2209597a3682692ff0312d4a997d6e0d0f
host/board ao486d f42b49b964209265933b133fe7f9cd385169224228c878aca2043dac72e2bdba
```

The bitstreams did **not** match. Therefore the board's `operating` state was
not validation of the current host artifact. Always repeat the comparison for
the run being reported.

A five-second read-only `perf.py` sample on that unmatched board image measured
6.250 MHz, IPC 0.0582, and 94.2% no-retire cycles. The compared 2026-08-01 host
artifact instead described a 5.966 MHz core, while the later under-constrained
candidate described 2.983 MHz. This is additional evidence that the staged board image and both host
artifacts are different builds. Treat any board-local script's hard-coded
expected-frequency text as build-specific; use raw interval deltas unless its
source and bitstream are explicitly paired.

## 10. Program and smoke-test the PL

### 10.1 Preferred explicit sequence

The explicit sequence makes every mutation visible and avoids transferring a
disk image:

```bash
ssh -F "$SSH_CONFIG" "$BOARD" 'mkdir -p /tmp/ao486'

scp -F "$SSH_CONFIG" \
  "$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit.bin" \
  "$FLOW/sw/ao486d" \
  "$VENTIUM/fpga/board-tools/ven_board_probe.py" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot0.rom" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot1.rom" \
  "$BOARD:/tmp/ao486/"

ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /usr/local/bin/load-bitstream.sh /tmp/ao486/rk_ao486_system.bit.bin &&
   sudo /usr/local/bin/load-bitstream.sh --status &&
   sudo chmod +x /tmp/ao486/ao486d &&
   sudo /tmp/ao486/ao486d --ident'
```

The loader copies the raw bitstream to `/lib/firmware`, applies a configfs
device-tree overlay to `&fpga_full`, and programs through the ZynqMP FPGA
manager/PCAP. It falls back to the legacy manager sysfs interface if necessary.

Smoke passes only when both conditions hold:

```text
fpga manager state = operating
IDENT               = A0486501
```

An IDENT mismatch means the PL/control-map/daemon set is wrong even if the FPGA
manager says `operating`.

### 10.2 Existing smoke helper

From `$FLOW`, this is the equivalent convenience command:

```bash
scripts/deploy.sh smoke
```

Review it before use. It rebuilds the daemon, copies the deployable set,
programs the PL, and runs `--ident`, but currently embeds password-based
automation and disables strict host-key checking. It also does not pass
`-F /dev/null`, so it currently aborts on the inspected host's unsafe system SSH
fragment. Until that system file is repaired or the helper is corrected, use
the explicit sequence above.

## 11. Verification ladder

Run one stage at a time and preserve its log. A later-stage failure must not
erase the last known-good lower stage.

### 11.1 BIOS/POST without a disk

After staging/programming in section 10, run the daemon explicitly for 60
seconds with BIOS and text reporting:

```bash
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --secs 60 --text'
```

Look for core release, advancing memory/retirement counters, BIOS text, disk
detection state, and no watchdog/forced-flush rescues. With no disk, reaching a
clean boot failure after POST is expected; random reset, frozen counters, or an
IDENT/control failure is not.

After the host SSH fragment is repaired (or the script learns the same `-F`
option), `scripts/deploy.sh post` is the convenience equivalent that also
reprograms the PL.

### 11.2 Trace a POST or boot failure

```bash
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --secs 25 --text --trace'
```

or add selected daemon options:

```text
--trace                 dump the PC and auxiliary rings at the end
--freeze CYCLES         freeze after this many no-retire cycles
--tracesecs N           freeze rings after N seconds
--cmpcfg VALUE          configure retire comparator/freeze
--cmprng VALUE          comparator EIP range
--peek ADDR             dump guest RAM while core remains held after load
--peekrun ADDR          dump guest RAM after the run
--loadonly              initialize memory/BIOS, leave core held, exit
```

These modes are intrusive. The ring format is build-specific; decode it against
the exact `rk_ao486_system_pl.v`, `ven_soc_dbg.sv`, and `board_shim.cpp` used to
build the bitstream/daemon.

### 11.3 Quake

The board already has `/tmp/ao486/qk_td.vhd`. The current `deploy.sh quake`
tries to copy a host image from
`$VENTIUM/ao486-sim/run_eipfix/qk_td.vhd`, which is absent. Reuse the
board-staged disk and run explicitly after verifying it:

```bash
ssh -F "$SSH_CONFIG" "$BOARD" \
  'stat /tmp/ao486/qk_td.vhd; sha256sum /tmp/ao486/qk_td.vhd'
scp -F "$SSH_CONFIG" \
  "$VENTIUM/fpga/board-tools/ven_board_probe.py" \
  "$BOARD:/tmp/ao486/"
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ven_board_probe.py quake \
     --disk /tmp/ao486/qk_td.vhd --precheck-only'
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --hdd /tmp/ao486/qk_td.vhd --secs 600 --text' \
  |& tee quake-board.log
```

The precheck reads only the disk and must print `QUAKE DISK PRECHECK CLEAN`.
Do **not** run the normal Quake probe alongside the daemon: its current
implementation rereads the complete 64 MiB disk image on every interval, which
is needlessly intrusive and can distort a slow hardware run.  Let `ao486d`
finish, then run the probe once without `--precheck-only`; it requires an exact
969-frame result and prints `QUAKE TIMEDEMO COMPLETE`. PC movement, disk reads,
or a nonzero retired count alone does not prove Quake completed.

Once CWSDPMI has installed Quake's live page tables, `quake-progress` is the
non-intrusive progress probe. It walks PDE/PTE entries in guest RAM and reads
Quake's own counters; it never scans or modifies the disk:

```bash
sudo /tmp/ao486/ven_board_probe.py quake-progress \
  --cr3 0x7e000 --ds-base 0x10000000 --samples 10 --interval 5
```

Those defaults match the current instrumented timedemo only. A non-present
PDE/PTE or a different DPMI layout is a hard error. `demo_frames` is progress
evidence; the 36-byte disk record remains the acceptance authority. In the
automatic command-line path `td_startframe == 0` is valid: the tool therefore
uses active demo playback plus a non-null demo file, rather than the truthiness
of `td_startframe`, to decide whether `host_framecount - td_startframe - 1` is
real progress.

For a failing run, the existing external-freeze path can stop the on-die rings
as soon as CWSDPMI finishes formatting an exception:

```bash
sudo /tmp/ao486/ven_board_probe.py trap-cwsdpmi-exception \
  --start 0x20000 --end 0x50000 --timeout 900
sudo /tmp/ao486/ven_board_probe.py dump-ring --depth 128
```

The scan is read-only until a complete register record matches, then it pulses
the debug block's external freeze. That freeze is deliberately intrusive and
sticky: archive RAM/rings first and reprogram the same hashed bitstream before
the next clean workload. Its displayed vector can be stale; parse the guest's
saved exception frame/TSS before assigning an architectural vector.

Do not arm this text trigger immediately after a preceding frozen experiment.
A PL reload does not by itself make DDR a trustworthy fresh-guest witness: a
previous CWSDPMI formatter string can remain visible while the next daemon is
starting. The probe waits for an absent-record sample before it will fire, but
the safe operating rule is stronger: arm this trigger only after a clean boot
has reached the audited client phase, and treat an early boot-stage hit as
suspect until its rings and reset epoch agree. It is a forensic aid, never an
acceptance-run monitor.

For the dedicated `QUAKE_FAULT_FRAME_LOGGER.EXE` diagnostic disk, use the
cache-aware fault-frame trigger instead. The guest patch copies its exception
frame to its reserved client-data slot; the host tool translates that slot
through the live Quake page tables and watches both DDR *and* the existing
core-observation ring. The ring is essential: a client store can still be in
L1 when external freeze prevents it reaching DDR.

```bash
sudo /tmp/ao486/ven_board_probe.py trap-quake-fault-frame \
  --cr3 0x7e000 --ds-base 0x10000000 --offset 0x90b80 \
  --words 16 --timeout 1800 --interval 0
```

Run it only with the matching patched diagnostic executable and an explicitly
disposable disk. On a hit it reports whether DDR or the core ring supplied the
witness, freezes the FPGA, and prints the captured dwords/ring stores. Copy a
compact `capture` bundle off-board before reprogramming. A zero-valued raw DDR
slot does **not** disprove that the logger ran; it can be a cache-visibility
artifact. The production, unmodified-disk timedemo must run without this
trigger and still requires the exact 969-frame record.

Some DPMI-client failures return normally to DOS and never format that
exception record.  If read-only evidence has already established that the
failure is a particular protected-mode exit, the selector-independent CR0
trigger can capture its boundary.  Do **not** use it merely because a sample
shows real-mode selectors: CWSDPMI makes legitimate protected/real-mode round
trips during Quake startup, and freezing the first `PE=1 -> 0` transition can
turn healthy progress into an apparent exit.  Delay and qualify the trigger
against a preceding uninterrupted run; it arms on CR0.PE=1 and freezes on the
first transition back to real mode:

```bash
sudo /tmp/ao486/ven_board_probe.py trap-pe-exit \
  --delay 300 --timeout 900
sudo /tmp/ao486/ven_board_probe.py dump-ring --depth 128
```

`trap-pe-exit` also accepts `--arm-cs 0xa7` to defer arming until a particular
protected-mode client selector has retired.  This is a useful guard against
pre-client extender setup, but it is **not** by itself a terminal-failure
detector for DOS Quake: its normal demand-page path at `00a7:000010bc` enters
CWSDPMI and legitimately returns to real mode.  A 2026-08-23 capture froze
exactly on that expected `00a7:000010bc -> 26d9` transition.  Use a
CS/EIP-qualified comparator for a known late fault window, or establish a
more specific state predicate from a preceding read-only run; never infer an
abort merely from the first client-qualified PE exit.

If the failing workload remains protected but leaves a known code-selector
set, use the narrower stateful selector-boundary trigger instead.  It ignores
startup, arms only after the audited protected selector/EIP has retired, and
freezes on the first retire outside the protected selector set:

```bash
sudo /tmp/ao486/ven_board_probe.py trap-protected-exit \
  --enter 0x26d9 --allow 0x0018,0x00d9,0x26d9 \
  --enter-eip-min 0x3000 --delay 300 --require-pe --timeout 900
sudo /tmp/ao486/ven_board_probe.py dump-ring --depth 128
```

The selector, EIP, and delay values are workload/build-specific; derive them
from a preceding read-only `sample --all` run rather than copying them to
another guest. `--require-pe` rejects real-mode segments that happen to have
the same numeric value and fires when the captured protected-mode session
clears CR0.PE. The
trigger is a diagnostic write: once it fires the external freeze is sticky,
so archive the ring and RAM before reprogramming.

For a still-running daemon, the source-controlled comparator utility can arm a
narrow late-failure window without holding the core or clearing its rolling
prehistory:

```bash
scp -F "$SSH_CONFIG" \
  "$VENTIUM/fpga/board-tools/ven_board_trace_arm.py" \
  "$BOARD:/tmp/ao486/"
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo python3 /tmp/ao486/ven_board_trace_arm.py \
     --cs 0x00a7 --eip-lo 0xd5c4 --eip-hi 0xd611 --live'
```

Use `python3` explicitly because `scp` need not preserve the executable bit.
`--live` refuses a non-operating FPGA, wrong `IDENT`, held core, or already
frozen trace. It disables the comparator while changing the range and makes the
enable/freeze write last; it does not clear either ring. A successful arm for
the example above prints:

```text
IDENT=a0486501 live=1 core_held=0 frozen=0 cmp_cfg=000f00a7 cmp_range=d611d5c4
```

This debug block compares only the low 16 bits of EIP. Never arm an EIP range
without a known CS, and derive both from a preceding read-only sample. An EIP
above 64 KiB aliases its low word; the example catches `00a7:0004d5c4` only
because CS and the narrow late-run interval jointly qualify it. The default
mode, without `--live`, is the safer pre-load procedure: it holds the core,
clears a previous sticky freeze, and arms before the daemon loads/releases the
guest.

After a match, the sticky freeze holds the guest reset and cannot be resumed.
First archive `trap-status`, rings, and required RAM. Then reprogram the exact
same hashed bitstream before any clean rerun; merely disabling the comparator is
not a reset of the failed experiment.

On 2026-08-23 the earlier tools captured `CS:EIP=0018:00001105`, bytes
`66 67 c5 75 10`, and a correct old `ESP:SS=00003484:0033` call-gate pointer.
The subsequently repaired image crosses that location. A live, CS-qualified
comparator then captured vector 14 in the later Quake window and a repeatable
ASCII-zero stack overwrite. Exact old-blocker evidence is in
`fpga_verify_20260822/quake_final_log/README.md`; current repaired-image evidence
and fix guidance are in
`fpga_verify_20260822/quake_lds_repaired/README.md` and
`fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md`.

The board-local `/tmp/ao486/qk_board_mon.sh` scans guest RAM/logs for this
signature. It is a useful monitor, but it is not source-controlled and must be
archived with its hash when used as evidence.

For a multi-hour run on a nearly full board, do not save the daemon's complete
verbose output. A detached transient service can retain only progress and
acceptance markers:

```bash
sudo systemd-run --unit=ven-quake-nonfast --collect /bin/sh -c \
  '/tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --hdd /tmp/ao486/qk_td.vhd \
     --secs 21600 --text 2>&1 | \
   stdbuf -oL grep -E \
     "board_init|mounting HDD0|x86_init done|IDENTIFY STORE OK|BOOT SECTOR LOADED|IDESNAP|TIMEDEMO|969 frames|FLUSHWD|done: x86_polls|DBG\\[final\\]" \
     > /tmp/ao486/quake_nonfast_long.log'
```

Check it without perturbing the guest:

```bash
systemctl is-active ven-quake-nonfast.service
systemctl show -p MainPID -p ActiveEnterTimestamp ven-quake-nonfast.service
tail -20 /tmp/ao486/quake_nonfast_long.log
```

Do not run the normal `quake` probe concurrently: it rereads the entire disk
on every interval. If control-flow evidence is needed, use only a short read-only
`sample` run against the newest on-die PC-ring entry. After `ao486d` exits, run
the normal probe once; only `QUAKE TIMEDEMO COMPLETE` with exactly 969 frames is
an acceptance result.

For an unattended run, schedule that one scan behind the workload rather than
polling the disk:

```bash
sudo systemd-run --unit=ven-quake-postcheck --collect /bin/sh -c \
  'while systemctl is-active --quiet ven-quake-nonfast.service; do
     sleep 60
   done
   /tmp/ao486/ven_board_probe.py quake \
     --disk /tmp/ao486/qk_td.vhd --allow-existing --timeout 1 \
     > /tmp/ao486/quake_nonfast_result.log 2>&1'
```

`--allow-existing` is correct only here: the clean precheck was already logged,
and the postcheck does not start until the producing daemon is gone. The short
timeout deliberately makes this a single full-disk scan; without it, a missing
result causes the detached postcheck to rescan the disk forever.

### 11.4 Windows 95

Current known result: the procedure below passed on the repaired-fast
`l1bypown` image at 3.125029 MHz on 2026-08-23. The source-controlled detector
held `last_ar=0x001021c0` for all 1,500 samples, observed both idle EIPs
`0x1e5/0x1e6`, 553 live transitions, correct Windows IVT values, and an advancing
tick; the old `vga-text` DDR-aperture check read 2,000 zero cells. That does
not establish a blank VGA text screen on this platform, because B8000 is VGA
MMIO rather than guest DDR. This remains a headless control-flow proxy, not
rendered-pixel proof.

The board has `/tmp/ao486/w95fresh.vhd`; it is a sparse, mutable 2 GiB image.
Restore it from the local pristine sparse backup before a reproducible run:

```bash
rsync -S --inplace -e "ssh -F $SSH_CONFIG" \
  "$FLOW/disk-backup/w95fresh.pristine.vhd" \
  "$BOARD:/tmp/ao486/w95fresh.vhd"

ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --hdd /tmp/ao486/w95fresh.vhd --secs 21600 --text' \
  |& tee win95-board.log
```

`scripts/restore_w95.sh` performs the same sparse-aware restore but contains
fixed credentials/host values; the explicit command is preferred.

The current headless hardware flow has no connected video output. The best
available automated proxy is the board-local `/tmp/ao486/w95det.py`, which
samples for the known desktop-idle EIP/fetch-region signature. Treat that as a
control-flow proxy, not as proof of a correctly rendered desktop. Stronger
evidence would require adding a reproducible framebuffer/video capture path.

Expected lower-level signs include:

- BIOS reports an HDD and the BDA hard-disk count becomes at least one;
- a valid `0x55aa` boot sector is loaded at guest `0x7c00`;
- IDE read/write counts advance without uniform/corrupt data warnings;
- the core continues retiring after protected-mode entry;
- no workaround-only `FLUSHWD`/rescue path is required.

## 12. Available tools

### Host-side flow tools

| Tool | Purpose | Important caveat |
|---|---|---|
| `hw/create_project.tcl` | Creates BD, synthesizes, implements, writes `.bit`/raw `.bin` | Hard-coded paths; only `bd` and `all` are useful modes |
| `sw/Makefile` | Cross-builds static AArch64 `ao486d` | Pulls PS sources from the Ventium tree |
| `scripts/deploy.sh` | `smoke`, `post`, `trace`, `quake`, `win95` orchestration | HDD source paths are absent; dense `scp` is unsafe for Win95; current host SSH config blocks it |
| `scripts/deploy_nohdd.sh` | Programs/runs while reusing a board-staged HDD | Correct disk strategy, but current host SSH config blocks it until repaired/patched |
| `scripts/restore_w95.sh` | Sparse restore of pristine Win95 image | Fixed credentials/host; explicit `rsync -S --inplace` is cleaner |
| template `scripts/bit2bin.sh` | Converts an ordinary `.bit` to raw `.bit.bin` | Not needed for this flow's already-generated `.bit.bin` |
| template full build | Rebuilds XSA, DT, boot chain, kernel, rootfs, SD image | Platform recovery/change only, not normal PL iteration |

### Reference-template recovery tools

These commands belong to `$TEMPLATE`, not to the normal Ventium PL iteration.
They are relevant when rebuilding or repairing the board's PS/Linux platform:

| Command | Output/use |
|---|---|
| `make sources` | Fetch pinned Xilinx bootloader, kernel, and device-tree sources |
| `make hw` / `make hw MODE=xsa` | Rebuild the template example hardware/XSA; not the Ventium PL |
| `make devicetree` | Generate `system.dtb` with overlay symbols from the selected XSA |
| `make boot` | Build bitstream-free `BOOT.BIN` by default |
| `make kernel` | Build the Linux 6.12 image and modules with FPGA-manager support |
| `make rootfs` | Build the Debian/Ubuntu AArch64 root filesystem |
| `make sdcard` | Assemble the boot and root partitions into `sdcard.img` |
| `make all` | Run the platform pipeline using the template's golden XSA; it does not run `make hw` |
| `scripts/bit2bin.sh FILE.bit` | Convert a normal Vivado bitstream for FPGA-manager loading |

Do not substitute `make hw` in the template for the Ventium build in section 8;
the actual Ventium block design is generated by `$FLOW/hw/create_project.tcl`.

### Board-side platform tools

| Tool | Purpose |
|---|---|
| `/usr/local/bin/load-bitstream.sh FILE [--partial]` | Programs PL through FPGA manager/PCAP |
| `/usr/local/bin/load-bitstream.sh --status` | Reports FPGA-manager state |
| `/sys/class/fpga_manager/fpga0/state` | Direct manager state (`operating` is necessary, not provenance) |
| configfs overlay `rk-fpga-full` | Runtime `&fpga_full` region/firmware binding |
| `dtc` | Builds the temporary overlay used by the loader |
| `/dev/mem` | MMIO and guest-RAM mapping used by root-only daemon/diagnostics |

There is no `devmem` utility on the inspected image. Use the daemon or the
existing Python `mmap` diagnostics instead.

### `ao486d` modes

| Option | Purpose |
|---|---|
| `--ident` | Read IDENT, status, control, and basic debug state; does not initialize/run the guest |
| `--bios DIR` | Directory containing `boot0.rom` and `boot1.rom` |
| `--hdd IMAGE` | Mount image as primary-master HDD |
| `--membase 0x60000000` | Must match the PL guest-RAM base |
| `--secs N`, `--text` | Run duration and VGA-text dump |
| `--loadonly`, `--peek`, `--peekrun` | Controlled memory/load diagnostics |
| `--trace`, `--freeze`, `--tracesecs` | Ring/freeze diagnostics |
| `--cmpcfg`, `--cmprng` | Retire comparator diagnostics |
| `--inject-keys` | PS-side BIOS-keyboard-buffer injection plus cache flush; diagnostic, visible only to BIOS-buffer consumers |
| `--stall-flush` | Stale-line watchdog workaround; never a correctness pass |

`ao486d` must run as root because it maps `/dev/mem`.

### Source-controlled board workload probe

`fpga/board-tools/ven_board_probe.py` is paired with the current debug map. Its
workload probes are read-only. `quake --precheck-only` proves that a disk contains no
pre-existing result without touching PL MMIO. Normal `quake` monitoring accepts
only an exact 969-frame result. `win95` requires the known VMM last-AXI-AR proxy
and idle-EIP signature, transitions between both idle EIPs, and an advancing
BDA tick before printing `DESKTOP SIGNATURE PRESENT`. Register `0x70` is not a
live fetch PC; it holds the last accepted AXI read address, so this remains an
empirical signature rather than a direct proof of the currently executing
instruction. Every MMIO mode first requires
FPGA-manager state `operating` and then validates `IDENT=A0486501`.

`quake-progress` is also read-only: it translates Quake linear symbols through
the live guest CR3 and reports the timedemo counters. `trap-cwsdpmi-exception`
is intentionally not read-only end-to-end; it scans RAM without writes, then
pulses external freeze after a full exception record appears. It requires an
observed clear scan first, but retained/noncoherent DDR still makes it unsafe to
arm blindly across a previous frozen run. `trap-quake-fault-frame` is the
dedicated patched-Quake diagnostic trigger: it recognizes the logger's stores
in both DDR and the core-observation ring, so it remains useful when L1 hides
the store from a raw DDR read.
`trap-pe-exit` and `trap-protected-exit` likewise use the external freeze: the
former catches a delayed CR0.PE 1->0 transition, while the latter waits for an
audited protected-mode selector and catches a silent return outside its
selector allow-list. `dump-ring` requires a frozen trace unless `--allow-live`
is explicit. Treat these as paired forensic trigger/readout tools, not as
acceptance instrumentation.

### Hosted PS/2 keyboard device

The original board wrapper ties both keyboard pins high, so `--inject-keys`
only alters the BIOS Data Area and is invisible to software such as Quake that
reads the 8042/IRQ1 path directly. Patch
`fpga/patches/0003-hosted-ps2-keyboard.patch` adds a versioned, device-side
PS/2 endpoint. It serializes ordinary Set-2 make/break bytes over the existing
8042 pins; it does not write guest RAM, alter the disk, or patch guest code.

Apply the patch after the passive-capture patches to `$FLOW`, build and deploy a
matching image, then copy the matching board probe. The probe refuses to send
any byte unless the hardware capability at `0x3a0` is `0x564b0001`.

```bash
cd "$VENTIUM"
git -C /home/yukidama/github/ao486_MiSTer apply --check fpga/patches/0003-hosted-ps2-keyboard.patch
git -C /home/yukidama/github/ao486_MiSTer apply fpga/patches/0003-hosted-ps2-keyboard.patch

env CCACHE_DISABLE=1 verilator --binary --timing -Wall -Wno-fatal \
  --top-module ven_ps2_kbd_inject_tb -Mdir /tmp/ven_ps2_kbd_inject_tb_obj \
  fpga/ven_ps2_kbd_inject_tb.sv \
  "$FLOW/src/ven_ps2_kbd_inject.v" \
  3rd-party/ao486_MiSTer/rtl/soc/ps2.v \
  3rd-party/ao486_MiSTer/rtl/common/simple_fifo.v && \
  /tmp/ven_ps2_kbd_inject_tb_obj/Vven_ps2_kbd_inject_tb
```

After programming, use the normal device transport, not `--inject-keys`:

```bash
sudo /tmp/ao486/ven_board_probe.py ps2-keys '~timedemo demo1' --enter
```

`ps2-keys` accepts the lowercase ASCII map used by the simulation keyboard;
`ps2-raw` sends deliberate raw Set-2 bytes for diagnostic keys. Each command
waits for the one-byte hardware transport before issuing the next byte, so it
cannot silently reorder a make, `f0`, break sequence. It remains an operator
input facility, not a correctness oracle: acceptance still requires the
unmodified disk's exact 969-frame timedemo result.

### Frozen forensic capture and simulation replay

The source-controlled probe now provides a capture bundle for a **frozen**
execution.  It records the current debug CSRs, counter values, the complete
128-entry architectural PC ring, the paired core/L1 observation ring, and any
explicitly selected physical guest-RAM ranges in a versioned `manifest.json`.
It refuses to mix a live CPU with RAM/ring reads unless `--allow-live` is
supplied, and refuses to overwrite an existing destination.  Copy the bundle
off the board before the next run: the board's root filesystem is small and a
freeze is sticky.

```bash
# Run only after a trap has frozen the CPU.  The first range keeps IVT/BDA/DOS
# state; the second covers the historical protected-mode stack-fault window.
sudo /tmp/ao486/ven_board_probe.py capture \
  --output /tmp/ao486/capture-$(date +%Y%m%d-%H%M%S) \
  --range 0:0x100000 --range 0xe0000:0x20000

# A one-off high-RAM dump is read-only and is useful for a page discovered from
# CR3/PDE/PTE inspection.  Copy the output off-board with scp afterwards.
sudo /tmp/ao486/ven_board_probe.py dump-ram \
  --start 0xe0000 --length 0x20000 --output /tmp/ao486/stack.bin

# Separate from the architectural PC ring: core/L1 address/data observations
# with retire/INTA/FSM metadata sampled at the same ring index.
sudo /tmp/ao486/ven_board_probe.py dump-core-ring --depth 128
```

`--full-ram` deliberately captures all `--ram-size` bytes (16 MiB by default),
but should only be used after checking free space and arranging an immediate
copy to the host.  A capture is an evidence bundle, not a claim of complete
architectural state: the deployed bitstream does **not** expose GPRs, segment
descriptor caches, CR2/CR3/CR4, debug registers, x87 state, cache/TLB content,
or in-flight bus/pipeline state.  The manifest names these unavailable fields
explicitly so an offline analysis cannot confuse absent data with zeros.  A
debug image advertises the latched freeze-context frame with
`0x56440001` at read offset `0x200`; only then does the probe include
`{CS,EIP,ESP,EFLAGS,fault_PC,CR0,state,vector}`.  Any other read value means
that frame is unavailable, not that the machine state is zero.

There is no true FPGA single-step or restore operation in the **deployed**
debug fabric. A comparator or external freeze is one-way and holds the guest;
it cannot resume the captured state. Replay therefore happens in source-matched
Verilator, which already serializes the SoC, guest DDR, DDR read FIFO/write
burst state, and Verilated RTL state:

```bash
cd "$VENTIUM/ao486-sim"

# Take a baseline only at a quiescent point: after POST and outside an IDE/FDD
# transaction.  Re-use the exact disk and executable build for restoration.
./obj_dir_ven/ao486sim_ven --ide /path/to/qk_td.vhd \
  --save-at 250000000 --save-file quake-baseline.snap --cycles 300000000

# Iterate from the saved state rather than cold-booting.
./obj_dir_ven/ao486sim_ven --ide /path/to/qk_td.vhd \
  --restore quake-baseline.snap --cycles 600000000
```

`--save-every N` makes cycle-stamped periodic simulator snapshots. Snapshot
files are build- and model-specific; do not restore them after RTL, Verilator,
or harness-layout changes, and do not treat an FPGA RAM capture as a simulator
restore file. This is a hardware change, not something a board-side `/dev/mem`
script can emulate.

For a direct cold-boot forensic window that does **not** use a save-state, build
an isolated trace-enabled cosim directory and request a bounded architectural
retire trace. `VERILATOR_BUILD_JOBS` is explicit so this diagnostic build cannot
silently consume all host cores; the canonical `obj_dir_ven` remains untouched:

```bash
make -C "$VENTIUM/ao486-sim" ven \
  VEN_OBJDIR=ao486-sim/obj_dir_ven_diag \
  VEN_EXE=ao486sim_ven_diag VERILATOR_BUILD_JOBS=4

cd "$VENTIUM/ao486-sim"
./obj_dir_ven_diag/ao486sim_ven_diag --ide /path/to/qk_td.vhd \
  --cycles 43000000 --vtm-dump-start 422000 --vtm-dump 4096 \
  2> retire-window.log
```

`--vtm-dump-start` is the absolute post-reset retirement number and
`--vtm-dump` is the maximum number of `VTM` records. Omitting the start captures
from the first retirement. The trace reflects a source-matched simulator build,
not FPGA state, and is a diagnosis aid rather than an acceptance result.

### Quiescent execution debugger (new debug image; not deployed yet)

The new debug image advertises `0x56450005` at read offset `0x2c0`. It routes
the core's existing debug hold mechanism to AXI-Lite; it does **not** gate the
PL clock and does **not** assert the forensic `frozen` reset. `halt` parks at
the next quiescent issue boundary: either `S_DECODE` on the slow path or
`S_PIPE` on the dual-issue fast path, or an already-idle `S_HLTWAIT`. The park
uses one shared issue-block
predicate, so it suppresses all fast-path mirrors together (GPR/x87 writeback,
BTB/L1 metadata, and speculative memory requests). An already-issued
multi-cycle or pipelined x87 operation is allowed to complete; HALTED is not
reported until its deferred architectural writeback has drained. Pending
SMI/NMI/INTR requests remain pending and are delivered after `run`; a host
`step` deliberately defers them until its one requested instruction retires.
An interrupt pending while a manual halt owns `S_HLTWAIT` is not acknowledged
until `run`, so no PIC event is silently consumed by the debugger.

After deploying a bitstream carrying that capability and copying the matching
probe to the board, use this workflow:

```bash
# Safe halt: no guest reset and no global clock gate.
sudo /tmp/ao486/ven_board_probe.py halt --timeout 5

# Full integer/system state at the parked boundary. This leaves the core halted.
sudo /tmp/ao486/ven_board_probe.py dump-state

# Execute one *retired instruction* and park again. A REP instruction is one
# architectural step even if its microcode takes a long time to retire.
sudo /tmp/ao486/ven_board_probe.py step --count 1 --timeout 30

# Pre-issue full-32-bit EIP breakpoint. --wait prints the same stopped state.
sudo /tmp/ao486/ven_board_probe.py breakpoint 0x00002bd2 --wait --timeout 30

# Disable the breakpoint, clear its sticky latch, and resume normal execution.
sudo /tmp/ao486/ven_board_probe.py run
```

`dump-state --halt` combines the first two operations. The probe refuses all
execution-control commands unless `0x2c0` carries the capability marker, so a
new host tool cannot accidentally operate an older image. A step is accepted
only after a verified halt and the probe checks that exactly one retirement
occurred before the core re-parks. It forcibly suppresses U/V pairing (including
the special folded x87 `FLD; FXCH` case); a breakpoint at a candidate V slot
also suppresses that pair so the requested EIP stops before it executes.
Single-step deliberately does not manufacture an instruction from an
already-idle `HLT`: leave the core stopped until an external event is intended,
then use `run` rather than expecting a step to wake it.

The selector state dump stays deliberately compact: a seven-bit selector and
one 32-bit data word keep the wrapper interface narrow, while a halted dump
includes EAX..EDI, about-to-issue EIP, EFLAGS, CS/SS/DS/ES/FS/GS, CR0..CR4,
DR0..DR3/DR6/DR7, and the complete x87 physical stack. Each 80-bit physical
FPR is read as three words; the host probe uses the captured TOP and tag bits
to print both the physical slots and logical `ST(i)` view, explicitly marking
EMPTY slots. It also returns x87 control/status/tag and FIP/FDP/FCS/FDS
environment pointers, every segment's hidden base/limit/access/B-bit cache,
GDT/IDT base and limit, and the complete LDTR/TR descriptor caches (selector,
base, limit, validity, and TR access byte). It is not a full internal scan:
cache/TLB arrays and in-flight bus/pipeline state remain unavailable. The
last selector also reports whether the current stop was a manual halt,
breakpoint, or completed single-step.
The older freeze-context page at `0x200` remains the right tool for a terminal
forensic event; `capture` still requires that sticky freeze and should not be
used to claim a halt-state RAM snapshot is atomic.

Before a hardware build, run the focused AXI-Lite regression from the host. It
also verifies that a `STEP` command cannot alias the old ring-clear command:

```bash
iverilog -g2012 -s ven_mgmt_debug_tb -o /tmp/ven_mgmt_debug_tb.vvp \
  /home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system/src/ven_mgmt_axil.v \
  fpga/ven_mgmt_debug_tb.sv && vvp /tmp/ven_mgmt_debug_tb.vvp
```

`fpga/board-tools/ven_board_trace_arm.py` is the paired, deliberately small
write utility for the raw retire comparator. Its default mode holds the core,
clears the sticky debug freeze/rings, and arms before guest load. `--live` is the
late-window mode documented in section 11.3: it requires an already-running,
non-frozen core, preserves rolling prehistory, writes the range while disabled,
and enables/freeze-arms last. It accepts only a 16-bit CS plus an optional
16-bit EIP range; it is not a general MMIO writer. Invoke the copied file with
`python3` so deployment does not depend on its executable bit.

`vga-text` reads the *DDR aperture* at B8000 and reports printable/nonblank
bytes. It is not a rendered-text capture: on the deployed ao486 platform,
B8000 is a VGA device mapping, so all-zero DDR data says nothing about the
visible display. Do not use it as Win95/FreeDOS visual evidence.

`vga-ring-text --depth 128 --allow-live` is a separate, explicitly sparse
best-effort decoder for recent core-side B8000 accesses. It writes only the
debug ring's read-index selector, restores it to zero before returning, and
never changes guest memory or execution. Its output is useful for a recent
prompt or error (the 2026-08-29 run reconstructed `C:\QUAKE>`), but is not a
framebuffer and must not be presented as an image. Use `vga-capture` for a
passive rendered-pixel frame; its 512-KiB RGB332 private BRAM holds a complete
720x400 text scanout (288,000 bytes) as well as Mode 13h. Larger modes report
overflow rather than emitting a truncated image.

Its `perf --seconds N` mode reads the split cycle/retirement counters, AXI
event counters, state slots, I/O-cycle counter, and external-interrupt-
acknowledgement counter twice and reports raw interval deltas, measured clock,
IPC, and I/O ratio. It writes no control or ring-index register. Prefer this
source-controlled mode over volatile board-local performance scripts.

Two current wrapper defects constrain interpretation. The deployed feature set
numbers `S_PF=26` and `S_PIPE=27`, while `ven_soc_dbg.sv` hard-codes state 23
and 24 into offsets `0x1b0` and `0x1a0`; the probe therefore calls them
`fsm_slot_1b0`/`fsm_slot_1a0`, not PF/PIPE. Also, the wrapper ties
`io_pending` to zero, so `perf_io` is not a valid S_IO measure. Fix the hardware
by routing semantic state flags rather than copying feature-dependent enum
numbers. The PC ring samples `dbg_state` only on a retirement, so a moving ring
of state-27 entries means normal fast-path retirement in this build; it is not
a live FSM sample and must not be mistaken for the later F00F-hang enumerator.

The explicit `clock PROFILE` subcommand is one allow-listed write mode. It
accepts only audited `PL0_REF_CTRL` values rather than exposing a general
`/dev/mem` writer:

| Profile | Register | Intended use |
|---|---:|---|
| `iopll-93m` | `0x01011000` | 93.75 MHz PL / ~2.9297 MHz core; conservative fallback for the routed 95.456 MHz non-fast image |
| `iopll-100m` | `0x01010f00` | Restore the current 100 MHz IOPLL `/15` profile |
| `rpll-95m` | `0x01010b02` | Reproduce the Vivado PS preset only; not timing-safe on the inspected stock-Linux clock tree |

Run it only with `ao486d` stopped, then measure the resulting hardware counter
rate before accepting the image:

```bash
sudo /tmp/ao486/ven_board_probe.py clock iopll-93m
sudo /tmp/ao486/ven_board_probe.py perf --seconds 5
```

The other write modes are fixed on-chip forensic traps, not workload probes:

| Mode | Effect |
|---|---|
| `trap-zero` | Arms `cfg=0x000f0000`, range `0x00030000`; freezes on the first retired `CS=0,EIP=0..3` |
| `trap-badcs` | Arms a fixed `CS=0x3107` boot-derail comparator; this selector was observed once but is not deterministic |
| `trap-status` | Read-only report of the sticky freeze snapshot |

Comparator configuration bit 19 is the freeze-mode bit. A value such as
`0x00070000` can match without freezing; the `trap-zero` value is deliberately
`0x000f0000`. A trap holds the guest in reset after a match and is never valid
during a clean acceptance run.

### Board-local diagnostics

The following have been found under `/tmp/ao486` on earlier board boots. `/tmp`
is volatile; for example, `perf.py` was absent after the 2026-08-21 recovery.
They are useful when present but are not in the source-controlled flow, so
inspect and hash them before citing their output:

| Tool | Purpose |
|---|---|
| `perf.py [seconds]` | Interval cycles, retired instructions, IPC, stall, I/O, IRQ metrics; its expected-frequency text is build-specific |
| `stall.py` | Simple stall-percentage sampling |
| `hot.py` | Samples last-EIP and fetch pages to find hot loops |
| `ring.py` | Reads the PC ring; writes the non-destructive ring-index selector |
| `rdring.py` | Reads the build-specific auxiliary/debug ring; writes the same index selector |
| `w95det.py [samples]` | Win95 desktop-idle control-flow proxy |
| `qk_board_mon.sh` | Searches guest RAM for the Quake timedemo/FPS signature and rewrites its monitor log |
| `run_w95.sh`, `run_long.sh` | Long board-local orchestration |

The last two run helpers kill processes and reprogram the PL, and their comments
refer to old build labels. Prefer the explicit procedure above.

## 13. Custom debug/control register map

The AXI-Lite window starts at `0xA0000000`. Every implemented 32-bit register is
at a `0x10` boundary because other 32-bit lanes were observed to drop accesses
in this block design.

| Offset | Read meaning | Write meaning |
|---:|---|---|
| `0x000` | IDENT `0xA0486501` | — |
| `0x010` | management address | management address |
| `0x020` | control | bit 0 hold reset, bit 1 run, bit 8 IRQ enable |
| `0x030` | auxiliary ring data high | management write data/pulse |
| `0x040` | management read data | — |
| `0x050` | IDE/FDD/core status | — |
| `0x060` | saturating DDR/AR/R counters and bridge state | — |
| `0x070` | last accepted memory-read address | — |
| `0x080` | last retired EIP | ring index, clear, external freeze |
| `0x090` | frozen flag/vector/state/count | freeze threshold |
| `0x0a0` | EIP at freeze | comparator configuration |
| `0x0b0` | PC ring EIP | comparator range |
| `0x0c0` | PC ring state/CS | — |
| `0x0d0` | auxiliary ring address | — |
| `0x0e0` | auxiliary ring data low | — |
| `0x0f0` | no-retire/stall counter | — |
| `0x100/0x110` | cycle counter low/high | — |
| `0x120/0x130` | retired counter low/high | — |
| `0x140` | intended cycles in I/O; tied to zero in the current wrapper | — |
| `0x150` | external interrupt acknowledgements | — |
| `0x160` | live CR0 | — |
| `0x170` | accepted AXI read beats | — |
| `0x180` | AXI AR handshakes, including priming reads | — |
| `0x190` | AXI B responses | — |
| `0x1a0` | cycles in hard-coded state 24 (not `S_PIPE` in the deployed profile) | — |
| `0x1b0` | cycles in hard-coded state 23 (not `S_PF` in the deployed profile) | — |
| `0x1c0` | build-specific tagged state/value count; decode from exact source | — |
| `0x1d0` | cycles in all other states | — |
| `0x200` | snapshot capability (`0x56440001` = context-frame format 1) | — |
| `0x210` | frozen CS | — |
| `0x220` | frozen context EIP (same-edge retire aware) | — |
| `0x230` | frozen ESP | — |
| `0x240` | frozen EFLAGS | — |
| `0x250` | frozen core fault-PC tap | — |
| `0x260` | frozen CR0 | — |
| `0x270` | frozen state in bits `[15:10]`, vector/halt tag in `[7:0]` | — |
| `0x280` | execution status: `[0]` halt-request, `[1]` breakpoint-enable, `[2]` quiescent halt (`S_DECODE`, `S_PIPE`, or `S_HLTWAIT`) | write `[0]` halt request, `[1]` breakpoint enable, `[8]` one-step pulse, `[9]` clear breakpoint latch |
| `0x290` | pre-issue full-32-bit breakpoint EIP | write breakpoint EIP |
| `0x2a0` | compact architectural state selector (`0..75`: integer/system, x87 stack/environment, segment/task/debug state, stop cause) | write selector |
| `0x2b0` | selected architectural word (valid only while `0x280[2]`) | — |
| `0x2c0` | execution-debug capability (`0x56450005` = format 5, seven-bit selector, x87/segment/task/debug state plus stop cause) | — |

The auxiliary ring is **not generically an AXI read-beat ring** in the current
source. The top currently feeds it a live core/L1 handshake bundle. Several
nearby comments describe older taps. Decode entries from the exact source, not
from a historical label.

## 14. How to interpret failures

| Symptom | First checks |
|---|---|
| FPGA state is not `operating` | raw `.bit.bin`, overlay/manager availability, loader output, correct part/build |
| FPGA is operating but IDENT is wrong | artifact hash, daemon/bitstream version pairing, control address, lane-0 map |
| IDENT works but no reads/retirement | reset/run bits, `0x060/0x070`, core clock, first fetch |
| AR advances but R does not | HP0 clock/width converter, reset domain, AXI bridge state |
| Wrong/repeated 64-bit halves | verify HP0 remains 128-bit and explicit 64-to-128 converter remains present |
| POST differs run-to-run | first capture source/artifact hashes and rings; do not immediately add retries or flushes |
| `VEN_SYS_FASTPATH` loses real-mode CS/EIP before FreeDOS | run at a measured timing-safe clock, then inspect `fp_irq_divert`/`inta`; both must use one fast-eligible accepted-divert predicate |
| Reset-state ROM fails but the CD/NW-cleared A/B passes | isolate `ven_l1d` non-cacheable bypass and HP0 AR/R ownership; capture discarded priming responses; do not add another blind replay |
| `L1_BYP` serves a value after the core request changes | require the live request to match a latched address/type/extent token and select data with that latched token |
| Disk detected but no boot sector | management request service, image geometry, sector signature, BDA HDD count |
| Guest stalls with high no-retire count | `perf.py`, `0x1a0..0x1d0`, PC/aux rings, CR0 cache bits |
| Win95/Quake passes only with injection/flush | still failing clean correctness; isolate PS-to-PL coherence or guest-input need |
| Vivado has enough LUTs but cannot place | inspect CLB occupancy/congestion; current baseline is already 95.82% CLBs |

When reporting a hardware result, include:

- Ventium commit and dirty diff;
- standalone ao486 commit and a snapshot/archive of the untracked flow;
- Vivado version and synthesis defines;
- bitstream, daemon, BIOS, and disk hashes;
- final timing, DRC, and utilization report excerpts;
- exact deployment command and daemon options;
- FPGA state plus IDENT;
- complete log and explicit workload pass signature;
- whether any injection, flush, retry, cache-disable, or debug-freeze mode was used.

That bundle distinguishes a reproducible verification result from “some
bitstream was operating on the board.”
