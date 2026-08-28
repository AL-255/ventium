# FPGA verification run — 2026-08-20

Current status: **L1 OWNERSHIP PASS; FREEDOS PASS; WIN95 PASS; QUAKE FAIL/OPEN**.
The superseding 2026-08-22 `l1bypown` image closes the reset-state stale-read
failure, passes the focused IRQ/IRET ROM twice on silicon, and boots production
BIOS/FreeDOS. Windows 95 reaches the established VMM/System-VM desktop signature
on that same image. Quake stops earlier in CWSDPMI at the exact protected-mode
`66 67 C5 75 10` LDS instruction because C4/C5 decode is gated to `seg_real`.
The full 2026-08-23 update is at the end of this chronological log; exact
evidence and proposed compact fixes are in
`fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md`.

This log is deliberately not a Quake pass record. The remaining workload
acceptance condition is an exact `969 frames ... seconds ... fps` result from a
disk that started without a pre-existing result. The clean Win95 condition is
now satisfied independently.

No Verilog/SystemVerilog source was edited as part of this board run. The only
hardware-flow selection is made by the Tcl wrapper described below.

## Configuration decision

The first `/32` build was stopped during synthesis after finding that the
external `create_project.tcl` did not define `VEN_SYS_FASTPATH`. That image
would have exercised the old all-system-mode slow-FSM profile, repeated the
known 12.7--15.9 cycles/instruction bottleneck, and failed to verify the repaired
path that this run is meant to test. Its partial output is preserved under
`fpga_run_20260820_3mhz/`; it is not deployable evidence.

The replacement build uses `fpga/create_project_3mhz_wrapper.tcl`. It makes
exactly two configuration corrections while evaluating the authoritative
external flow:

- fixes stale block-design clock metadata from 6 MHz (`pl_clk0/16`) to 3 MHz
  (`pl_clk0/32`), matching the unchanged `src/clk_div32.v`; and
- adds `VEN_SYS_FASTPATH`, which enables the repaired conservative system fast
  path. It intentionally does **not** add `VEN_SYS_FASTPATH_ALL`, the broader
  experimental real-mode/segmentation profile.

The effective synthesis define list is recorded in the generated project and
`synth_1/rk_ao486_bd_wrapper.tcl` and includes:

```text
SYNTHESIS VTM_NO_DPI VEN_CORE VEN_L1_AXI VEN_KV260_SOC
VEN_L1_HONOR_CD VEN_TRANSCENDENTAL VEN_SRT_ITER VEN_IDIV_ITER
VEN_BCD_ITER VEN_FP_PIPE VEN_BTB_PIPE VEN_CACHE_HALF VEN_IC_NARROWB
VEN_ALTSYNCRAM_XPM VEN_DBG_CORE VEN_FP_PC_RELAX VEN_SYS_FASTPATH
VEN_FAST_RETRACE VEN_KBD_AUTOACK VEN_KBC_FAST VEN_FPREM
```

`VEN_SYS_FASTPATH` is present in both the generated `.xpr` and the synthesis
run Tcl.

The first source-matched attempt under `fpga_run_20260820_fast3mhz/` reached
`Start Timing Optimization` but its synthesis child vanished without an end or
error sentinel. At that point Vivado had launched seven approximately 2 GiB
task workers in addition to an approximately 6 GiB synthesis parent and the
project process; only 257 MiB of physical RAM remained. The partial run is
preserved as a host-memory-failure diagnostic and is not deployable evidence.
The wrapper now sets `general.maxThreads=4`. This bounds tool concurrency only;
it does not alter RTL, constraints, defines, or the synthesized netlist. The
clean replacement output directory is `fpga_run_20260820_fast3mhz_mt4/`.
That source-matched attempt proved synthesis but missed placement as recorded
below. The next run keeps the same RTL, defines, clocks, and constraints and
adds only Vivado 2025.2's documented `AreaOptimized_high` synthesis directive;
its fresh output directory is `fpga_run_20260820_fast3mhz_area/`.

## Source provenance

The bitstream input set comprises the two root FPGA filelists, every source
named by them, every `rtl/core/*.svh` and `rtl/fpu/*.svh` included header, the
external RK flow's five PL sources, its project Tcl and three XDC files, the RK
board PS preset, and the local wrapper: **139 files** total.

Aggregate construction hash at build start (sorted `sha256sum` records hashed
again):

```text
209f26172a2f926ba9cd6c920ebdc82b2e1fd611565bf90c7a733abd12d351f5
```

This hash must be recomputed after bitstream generation and match before the
image is deployed.

## Pre-synthesis verification

### Default profile

- `make lint`: all five configurations passed the hard `IMPLICIT`,
  `PINMISSING`, `UNDRIVEN`, `MULTIDRIVEN`, `LATCH`, and `UNOPTFLAT` classes;
  `LINT-GATE-OK`.
- `make verify`: 98/98 functional programs passed against QEMU and all 20
  timing kernels met their bands; `VERIFY GATE: PASS`.

### `VEN_SYS_FASTPATH` profile

- An exact FPGA-profile Verilator lint, including `VEN_SYS_FASTPATH`, passed
  every hard structural class.
- A separate `verif/tb/obj_dir_sysfp/tb_ventium` build was generated with
  `+define+VEN_SYS_FASTPATH`; the canonical testbench was not overwritten.
- The 98-program functional suite and all 20 cycle bands passed against the
  same QEMU/p5model oracles (`VERIFY GATE: PASS`). The user-mode corpus proves
  configuration buildability and non-regression but does not by itself expose
  the system-mode gate.
- Three actual system-mode runs using that variant were therefore compared
  against their QEMU-system goldens:

| Test | Records | Result | Fast-path seam exercised |
|---|---:|---|---|
| `pmode` | 1,084 | EQUIVALENT | real-to-flat-PM transition and paging |
| `pintr` | 171 | EQUIVALENT | flat-PM execution plus IDT delivery/IRET |
| `pdebug` | 239 | EQUIVALENT | TF/DR breakpoint delivery and the debug bail-out |

The existing cycle structural comparator still reports its known non-gating
diagnostic (20/20 control-flow records marked divergent because that stream has
only `{n,pc,cyc,pipe,paired}`); this was not hidden or counted as a pass.

## Vivado run

Command:

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
vivado -mode batch \
  -source /home/yukidama/github/ventium/fpga/create_project_3mhz_wrapper.tcl \
  -tclargs all /home/yukidama/github/ventium/fpga_run_20260820_fast3mhz_mt4
```

The block design validated with HP0 at 128 bits and the core clock interface at
3,000,000 Hz. The clean bounded-concurrency synthesis began at 2026-08-20 21:34
local time and confirms `Multithreading enabled ... maximum of 4 processes`.
Synthesis completed with 0 errors and 0 critical warnings. Its flat report was
already over capacity at 342,092 CLB LUTs (100.24%; 338,668 logic LUTs), with
42,574 registers, 85 BRAM tiles, and 1,263 DSPs. Placement-time physical
synthesis combined away 1,164 LUTs, but detailed placement still failed:

```text
[Place 30-487] ... 22603 CLBs are available ... instances require 22793 CLBs
Luts: 343951 (combined) 379029 (total), available capacity: 341280
```

The failed run also exposed six L1D nets (`p_4_in[5:0]`) with 1,396 loads each
that could not be replicated under the current timing/macro constraints. The
profile is therefore **not deployable**; there is no bitstream and no route or
timing result to waive.

The next-smallest registered area/routability option, `VEN_FP_PIPE2`, was
rebuilt from current RTL and run through `make verify-fppipe2`. `mb_faddchain`
was byte-identical and both kernels remained within their QEMU cycle bands, but
`mb_fpindep` still produced 3,046 A/B cycle-trace deltas, so the explicit gate
ended `FP_PIPE2 A/B GATE: FAIL`. That red gate is not being hidden or counted as
area relief. A different functionally gated fit profile is required.

A second prospective compact profile was also rejected before synthesis. It
enabled the deployed front-end set (`VEN_FE_PIPE`, `VEN_UOPCACHE`,
`VEN_IC_BRAM`) together with the otherwise verified hardware configuration,
but a fresh full differential run passed only 96/98 functional tests:
`tx_bcd_st` terminated after 2 instead of 25 records and `tx_fprem` after 246
instead of 300 records. Its cycle profile also missed multiple established
bands. The run ended `VERIFY GATE: FAIL — FUNCTIONAL REGRESSION`, so those
defines are not present in the candidate image.

The tool-only candidate uses `AreaOptimized_high`, a value reported directly
by this installed Vivado 2025.2 `synth_design -help`. It permits general area
mapping, including use of otherwise spare BRAM/DSP resources, but does not
alter the RTL's architectural behavior or latency. Its 139-input construction
hash is the value recorded above and must match again after implementation.

Warnings already selected for the final audit include the pre-existing Vivado
use-before-declaration diagnostics in `core.sv`, same-priority set/reset
diagnostics, trimmed/undriven debug or FP signals, unregistered BRAM outputs,
and unpipelined DSP cascade paths in transcendental units. None is being
silently converted into an acceptance waiver; the routed reports decide timing
and DRC sign-off.

### Source-matched `AreaOptimized_high` implementation

The semantics-preserving area run used the same sources, defines, clocks, and
constraints as the failed source-matched attempt.  Its only mapper change was
Vivado 2025.2's `AreaOptimized_high` synthesis directive.  It ran from `/tmp`
(the repository `.Xil` path resolves to an unwritable external volume) with:

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
vivado -mode batch \
  -source /home/yukidama/github/ventium/fpga/create_project_3mhz_wrapper.tcl \
  -tclargs all \
  /home/yukidama/github/ventium/fpga_run_20260820_fast3mhz_area
```

Synthesis completed with no errors or critical warnings.  It was expensive:
1 h 17 min and approximately 18.3 GiB peak main-process memory despite the
four-thread cap.  The flat synthesis estimate was over capacity (363,753 CLB
LUTs), but implementation optimization swept about 48,000 cells and detailed
placement completed.  The final placed resources were:

| Resource | Used / available | Utilization |
|---|---:|---:|
| CLB LUT | 315,780 / 341,280 | 92.53% |
| LUT as logic | 312,370 / 341,280 | 91.53% |
| CLB | 41,933 / 42,660 | 98.30% |
| CLB registers | 42,367 / 682,560 | 6.21% |
| BRAM tiles | 85 / 744 | 11.42% |
| DSP48E2 | 1,265 / 3,528 | 35.86% |

This is the first source-matched candidate that fits, but the 98.30% CLB
occupancy leaves little physical margin.  Routing initially had 208,316 node
overlaps and converged to zero after 100 global rip-up/reroute iterations.  The
final localized congestion dump names two fragment page-plan nets in
`CLEM_X49Y256`/`CLEL_R_X49Y256`; this remains a future placement-quality target,
not an unrouted-net waiver.

Final routed sign-off:

| Check | Result |
|---|---|
| Route status | 415,264/415,264 routable nets fully routed; 0 failed, partial, unrouted, or overlapping |
| Setup | WNS +1.606 ns, TNS 0, 0/152,179 failing endpoints |
| Hold | WHS +0.010 ns, THS 0, 0/152,139 failing endpoints |
| Pulse width | WPWS +3.738 ns, TPWS 0 |
| CDC bus skew | all ten constraints met; minimum slack +9.637 ns |
| Timing coverage | 0 unconstrained internal endpoints; all user timing constraints met |
| Routed DRC / bitgen | 0 errors, 0 critical warnings; bitgen completed successfully |

The routed DRC warnings are not hidden.  It reports 1,960 DSP input-pipeline,
1,242 DSP P-output-pipeline, 381 DSP M-output-pipeline, five dynamic-opmode DSP
feedback, one cascaded-clock, and one no-routable-load warning, plus power
advisories.  Methodology reports one `LUTAR-1`: a LUT-derived asynchronous
clear fans out to 141 reset pins and could glitch.  It also reports two
`CLKC-8` advisories for the cascaded `/8` and `/2` BUFGCE_DIV chain.  These are
real implementation-quality findings for a later RTL/clocking fix; the current
image nevertheless has clean route, timing, and bitstream DRC at 2.983 MHz.

The 139 filenames were sorted before generating `sha256sum` records and those
records were hashed as a stream.  The post-build construction hash exactly
matched the pre-build value:

```text
209f26172a2f926ba9cd6c920ebdc82b2e1fd611565bf90c7a733abd12d351f5
```

Generated artifacts:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `rk_ao486_system.bit` | 20,939,783 | `6a834e417d904d30577961a62c89b694d72eff3db82f71bc428270c0423006d4` |
| `rk_ao486_system.bit.bin` | 20,939,628 | `fce0eb3f431c5ea813cc5fca832d5c0d5f89d1a2eb2333a6f4a6f9a51af49a5d` |

## Board preflight

Target: `riguke@10.0.0.214` (`rk-xczu15eg-f`, Linux 6.12). Before deployment,
FPGA-manager state was `unknown`, no `ao486d` process was running, and the root
filesystem had about 150 MiB free. Only one final bitstream will be staged.

| Staged artifact | SHA-256 |
|---|---|
| `ao486d` | `07a39c8668313299c668d1d8166bb4630ecf322706feb46c109f5ae7de49b7a7` |
| `boot0.rom` | `e70c8843ac9c6485856d360ad6a306934ccc8399fc4c777c930373da84c4331e` |
| `boot1.rom` | `fb0d673a4cc3a96c388b4404db262db70bdde0746ee1ef9284923a5661e08296` |
| pristine Quake timedemo VHD | `38e31d11c17fb739b7a3605e6e0d43f85707c2b94a237ed19c5fdd62d97f3c0d` |
| pristine Windows 95 VHD | `877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8` |
| board-staged probe before safety fix | `9a2997283e6713db744392774fe9f7826065733227b51d809afb7059408d1499` |
| first corrected host probe after the unconfigured-PL safety fix | `e3a618214403f205079ed662a4e46aa07d6c6dab9821957a355f6492d02a9772` |
| current source-controlled probe (safe MMIO gate, traps, VGA text, expanded read-only perf) | `e9d08dd339935b82761c065202701f87b48b779210d441d86b299f5550827d1d` |
| area-run bitstream staged as `rk_ao486_system_area3_fce0eb3f.bin` | `fce0eb3f431c5ea813cc5fca832d5c0d5f89d1a2eb2333a6f4a6f9a51af49a5d` |

The normal workload runs will not use `--stall-flush`, `--inject-keys`, cache
disable, reset/retry watchdogs, trace freeze, or guest-memory patching. Those
facilities remain available only if a clean run fails and needs diagnosis; any
such run stays labelled diagnostic.

At 2026-08-21 00:25 local time the bitstream transfer and board-side hash
verification completed.  Before PL programming, the original probe scanned the
Quake disk and then attempted its IDENT read while FPGA-manager state was still
`unknown`.  The board immediately disappeared from the LAN: new SSH connections
returned `No route to host` and the host neighbor entry became `FAILED`.
Although the operation was logically read-only, an AXI-Lite `/dev/mem` access
to an unconfigured PL target can wedge the PS interconnect.  This is the likely
cause, not workload or FPGA pass/fail evidence; neither `load-bitstream.sh`,
`ao486d`, nor a guest was invoked.

The probe is now fixed and locally verified.  Every MMIO path first requires
FPGA-manager state `operating`, while the new `quake --precheck-only` path scans
only the disk and exits without opening `/dev/mem`.  After the board is rebooted,
the corrected hash above must replace the staged copy before deployment.

## 2026-08-21 non-fast-path hardware A/B

> **Timing invalidation:** the build and initial hardware observations in this
> section used a 95.456 MHz PS-clock constraint (2.983 MHz after `/32`), but a
> source-controlled counter interval measured the stock Linux board at
> 3.125041 MHz. The 15.232 ns period mismatch is larger than the routed setup
> margin. The guest observations remain useful diagnostic clues, but none is
> acceptance evidence. The six-hour service was stopped once this was found.

The recovered board was used for a controlled `VEN_SYS_FASTPATH` A/B.  The
diagnostic image was built from the same checkout and deployment profile as the
area image above, except that the wrapper was invoked with
`VEN_FPGA_FASTPATH=0`.  The generated synthesis Tcl is the authority: its
`verilog_define` list contains `VEN_FP_PC_RELAX` and `VEN_FAST_RETRACE`, but
does **not** contain `VEN_SYS_FASTPATH`.  Vivado concurrency was reduced to two
workers because the four-worker attempt exhausted physical memory and lost
three synthesis workers.

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
VEN_FPGA_FASTPATH=0 VEN_FPGA_JOBS=2 \
  vivado -mode batch \
    -source /home/yukidama/github/ventium/fpga/create_project_3mhz_wrapper.tcl \
    -tclargs all \
    /home/yukidama/github/ventium/fpga_run_20260821_slow3mhz_area_j2
```

The successful build completed with zero errors and zero critical warnings.
Synthesis used `AreaOptimized_high`; the overall process reached about 22.6
GiB physical memory and emitted a host-thrashing warning, so two jobs is the
reproducible setting on this machine.  Final implementation results were:

| Resource/check | Non-fast-path result | Fast-path area image |
|---|---:|---:|
| CLB LUT | 309,556 / 341,280 (90.70%) | 315,780 (92.53%) |
| LUT as logic | 306,146 (89.71%) | 312,370 (91.53%) |
| CLB | 41,187 / 42,660 (96.55%) | 41,933 (98.30%) |
| CLB registers | 35,145 (5.15%) | 42,367 (6.21%) |
| BRAM tiles | 85 (11.42%) | 85 (11.42%) |
| DSP48E2 | 1,265 (35.86%) | 1,265 (35.86%) |
| WNS / TNS | +0.696 ns / 0 | +1.606 ns / 0 |
| WHS / THS | +0.015 ns / 0 | +0.010 ns / 0 |
| routable nets | 407,320 / 407,320 | 415,264 / 415,264 |

Disabling the fast path saves 6,224 placed LUTs, 746 occupied CLBs, and 7,222
registers, but leaves the design physically dense.  Placement warned that the
design was highly congested; initial routing congestion was level 5 and began
with 217,783 node overlaps.  Routing nevertheless converged to zero overlaps.
The final congestion dump names
`frm_pg_addr_reg[3][31]_i_2111_n_11` and `vl[0][0]_i_23_n_0` around
`CLEM_X36Y329`/`CLEM_X28Y336`.  Six L1D `p_4_in[5:0]` nets still have nominal
fanout 1,396; timing/macro constraints reduce their optimizable loads to 157,
and Vivado declines to replicate them.  These remain concrete congestion and
compactness targets; the non-fast image is diagnostic evidence, not a proposed
performance configuration.

All ten CDC bus-skew checks met their 10.476 ns requirements.  Final route had
no routing errors, routed DRC/bitgen had zero errors, and methodology retained
the known `LUTAR-1` asynchronous-reset warning plus two `CLKC-8` clock-buffer
advisories.  The routed DRC also retained the DSP input/output-pipelining
warnings; they are not treated as failures at the 2.983 MHz diagnostic clock.

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `.bit` | 20,944,219 | `be64aeada174b03f675259fbdcb07bedd4c5f925372cc966017815dbe654e054` |
| `.bit.bin` | 20,944,064 | `0247cb33f5397fc3b42f003af5fa4cabbed9396c5cfd04bd9e712259a951957e` |
| synthesis DCP | — | `6c6393ff8066c5d826a7c70fe0a410c34daecde5d3306b5e2e54d7e7157e7572` |
| routed DCP | — | `b287e9b6d9cfa6bd68556178d44959dc87a147a40d9a0fb11d739e94146ecb08` |

The image was staged separately as
`/tmp/ao486/rk_ao486_system_nonfast_3mhz.bit.bin`, preserving the fast image for
rollback.  Host and board hashes matched before programming.  The loader then
reported `operating`, and the matching daemon returned `IDENT=a0486501`,
`STATUS=0x36`, `CTRL=0x1`.

The pristine Quake disk retained SHA-256
`38e31d11c17fb739b7a3605e6e0d43f85707c2b94a237ed19c5fdd62d97f3c0d`,
and `quake --precheck-only` found no pre-existing result.  A clean 600-second
run used no trace/freeze, flush rescue, guest-memory patch, or concurrent disk
scanner.  It identified the HDD, loaded a valid `0x55aa` boot sector, entered
FreeDOS/CWSDPMI, serviced timer interrupts, and advanced through the known
`0x45694..0x456b0` memory-commit loop into the bounded `0x44d60..0x44d7e`
Quake memory sweep.  A read-only PC-ring sample contained valid `f000`, `0070`,
and `05f7` real-mode segments followed by protected-mode `00a7` execution; it
did not reproduce the earlier corrupt-selector/zero-memory signature.  The
run ended only because its requested 600 seconds elapsed while the 2.983 MHz
core was still advancing through that sweep.

The intended 21,600-second acceptance service was stopped at approximately
1,420,500 daemon polls when the timing mismatch was discovered. Its compact
log showed disk reads resume from 449 to 461 just before shutdown, so the guest
was still progressing; the pristine disk hash remained unchanged and no exact
969-frame result existed. The companion postcheck was also stopped because its
original no-result path lacked a timeout and would rescan indefinitely. The
runbook now uses `--timeout 1` for a single post-run disk scan.

A five-second read-only hardware-counter interval during the `0x44d6x` sweep
measured 15,625,478 cycles, 299,816 retired instructions, zero I/O-state cycles,
and 71 external interrupt acknowledgements.  That is a measured 3.125041 MHz
silicon clock, IPC 0.019188, and about 59,962 retired instructions/s.  The
3.125 MHz measurement differs from Vivado's 2.983 MHz constraint-derived clock
because the running PS supplies approximately 100 MHz rather than the report's
95.456 MHz model. It also invalidates that route for hardware correctness, not
just throughput. At the
observed phase IPC, six hours covers only about 1.30 billion instructions.
This is forward progress but also a concrete performance regression from
disabling the repaired system fast path; the non-fast image is an isolation
control, not a shippable configuration.

## 2026-08-21 corrected-clock route and timing-valid fallback

A fresh non-fast implementation modeled the stock-Linux clock tree explicitly:
IOPLL `/15`, 99.999 MHz PL, and 3.125 MHz after the unchanged `/32` fabric
divider. Synthesis and placement completed with zero errors or critical
warnings, and placement estimated +3.455 ns WNS. Routing was the limiting
condition. `Explore` reduced the first global iteration to 5,715 overlaps and
the second to 592, but final verification reported 935 signals failed to route
and terminated with `ERROR: [Route 35-2] Design is not legally routed`.
No `.bit`/`.bit.bin` was produced from this run. The failed output is under:

```text
/home/yukidama/github/ventium/fpga_run_20260821_slow3125b_area_j2/
```

This is stronger evidence than the placement utilization warning: the current
non-fast netlist at 90.70% LUT and 96.55% occupied CLB is not a deployable
100 MHz implementation with the tested placement/router strategy.

For the guest acceptance run, the previously legal non-fast image was retained
and the live PS clock was instead reduced below its routed constraint. The new
allow-listed probe command wrote `PL0_REF_CTRL=0x01011000`, selecting the live
IOPLL `/16` clock. A five-second hardware-counter witness measured 2.929726 MHz,
below the image's 2.9829 MHz constrained core clock. The rejected RPLL `/11`
setting measured 3.030343 MHz on stock Linux because its live RPLL rate differs
from the Vivado PS preset.

The timing-valid Quake attempt started from disk SHA-256
`38e31d11c17fb739b7a3605e6e0d43f85707c2b94a237ed19c5fdd62d97f3c0d`;
the precheck found no result. FPGA-manager state was `operating`, IDENT was
`a0486501`, IDE identify/RAM transfer passed, and the `0x55aa` boot sector was
loaded. An initial live interval measured 2.929725 MHz, 252,979 retires in
14,648,873 cycles (IPC 0.017270), and 67 external interrupt acknowledgements.
The 12-hour-ceiling daemon and its one-shot exact-result postcheck were started
without trace/freeze, flush rescue, guest patching, or concurrent disk scans.
At approximately 26 minutes the guest naturally left its CPU-bound sweep and
disk reads advanced from 448 to 527. The run was then stopped deliberately:
the historical non-fast image at roughly twice this clock had already exhausted
six hours without completing the timedemo, so another 12-hour half-speed run
would only repeat the same amount of work. The disk retained its pristine hash
and contained no exact 969-frame result. This is performance/control evidence,
not acceptance.

### Timing-valid fast-path failure

The source-matched fast image was then reprogrammed under the same
`iopll-93m` profile. A counter interval again measured approximately
2.9297 MHz, below its 2.983 MHz implementation constraint, so the earlier
3.125 MHz timing ambiguity was removed. The fast image nevertheless derailed
during early real-mode BIOS boot on repeated clean resets. The disk remained
byte-identical and no guest workaround was active.

The on-chip retire comparator was corrected to include its freeze-mode bit and
armed for the first `CS=0000,EIP=0000..0003` retirement. Two representative
frozen trails were:

```text
frozen=1 frz_eip=0006ecc0 last_eip=00000000 state=27 vec=e6
[0] cs=0000 eip=00000000
[1] cs=0000 eip=0006ecc0
[2] cs=3107 eip=0006ecbe lin=0009fd2e

frozen=1 frz_eip=00039d30 last_eip=00000000
[0] cs=0000 eip=00000000
[1] cs=0000 eip=00039d30
[2] cs=6600 eip=00039d2e lin=0009fd2e
```

A third run caught the corruption developing through ordinary sequential BIOS
execution rather than the long zero-filled walk:

```text
f000:8664 -> 1fe0:8665
f000:85d6 -> e986:85e6
... -> 0000:00000000
```

The exact bad selector varies, but every clean fast run loses real-mode control
flow before FreeDOS. The same image at 3.125 MHz and 2.9297 MHz fails, whereas
the non-fast image at the timing-safe clock reaches FreeDOS/Quake. This makes
the remaining fast-path defect functional, not a route-timing explanation.

The RTL audit found one concrete interrupt seam. `sys_fp_ok` correctly rejects
real mode and non-flat protected mode, but `fp_irq_divert` is not gated by that
eligibility:

```systemverilog
assign fp_irq_divert = (state == S_PIPE) && !fp_occ_pending
                    && (smi_take || nmi_take || intr_take);
```

Also, the `VEN_SYS_FASTPATH` `inta` expression acknowledges every `S_PIPE`
`intr_take`, independently of whether the same boundary is accepted by
`fp_irq_divert`. Thus merely compiling the conservative fast path changes
interrupt handling in the real-mode BIOS even when no fast instruction is
eligible. The proposed repair is to derive one canonical accepted-divert
predicate gated by `sys_fp_ok` (preferably the complete canonical fast-issue
eligibility), consume it in the spine and all mirrors, and derive the S_PIPE
INTA pulse from `fp_irq_divert && intr_take`. Ineligible real-mode/non-flat
instructions must continue through the verified slow decode boundary. A
real-mode BIOS/PIT interrupt regression is required; the existing `pmode`,
`pintr`, and `pdebug` tests did not cover this boot-time case.
`verif/sys/tests/mairq` already contains the right real-mode `STI` plus external
IRQ shape, but it is a historical board smoke rather than a current automated
gate. Promote or adapt it so both the default and `VEN_SYS_FASTPATH` variants
must survive repeated IRQ/IRET delivery while spinning in ineligible real mode.

An attempted IRQ-mask A/B was rejected as invalid evidence. Management
`CTRL[8]` gates only the PS-facing `irq_out` in the external
`ven_mgmt_axil.v`; it does not mask the guest PIC-to-core interrupt. The probe
does not expose that misleading command.

### Win95 non-fast control rerun

The pristine Win95 image was restored and verified as
`877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8`
before the first timing-valid non-fast boot. That run progressed from 121 to
1,247 disk reads, entered graphics mode by the independent blank-B8000 proxy,
and continuously retired through `CS=05c1,EIP=1e5/1e6` with the BIOS tick
advancing. It did not reach the required `0x001021c0` last-AR/VMM signature.

One diagnostic Enter was delivered through the legacy PS-to-BDA injection
path to test whether a first-boot dialog was blocking progress. It was not
consumed after 41 seconds, proving that this protected-mode/V86 state was not
polling the BIOS keyboard buffer. The logical buffer tail and debug flush phase
were restored exactly. Because the associated cache-flush diagnostic changed
the last-AR register from `0x000fff40` to `0x00000440`, that run was classified
diagnostic and stopped; it is not desktop acceptance evidence. Its compact
logs are preserved under `fpga_verify_20260821/win95_nonfast_diag/`.

The read-only counter extension exposed two instrumentation defects in the
external hardware wrapper:

- the deployed feature set makes `S_PF=26` and `S_PIPE=27`, but
  `ven_soc_dbg.sv` hard-codes 23 and 24 for its named PF/PIPE buckets; and
- `rk_ao486_system_pl.v` ties `ven_soc_dbg.io_pending` to zero, so `perf_io`
  cannot measure S_IO occupancy.

Consequently the probe now reports offsets `0x1a0/0x1b0` as semantic-free
slots, not as PF/PIPE. The repair should route explicit `in_pipe`, `in_pf`, and
`io_pending` signals (or symbolic counters from the core) rather than duplicate
feature-dependent enum values in the board wrapper.

After preserving the diagnostic logs, the sparse disk was restored again and
rehash-verified. A second clean acceptance service started at
2026-08-21 22:51:22 UTC on the same non-fast image and timing-safe 2.9297 MHz
clock. It uses only the read-only `win95` detector; no input, cache flush,
freeze, trace-index write, or guest-memory patch was used. It reached the exact
established desktop proxy at approximately 23:07 UTC:

```text
samples=1500 transitions=954
top_last_ar=001021c0:1500
top_eip=000001e6:744, 000001e5:727, 00000138:2, 00000162:2,
        00000193:2, 0000feb0:2, 000089c2:1, 00000170:1
lowmem EBDA_seg=9fc0 IVT13=024c0122 IVT19=05b0002f
       tick=0017133d->00171407
DESKTOP SIGNATURE PRESENT
```

The new read-only `vga-text` mode independently found the complete B8000 page
blank (`0/2000` printable, nonblank, and nonzero-attribute cells), corroborating
the graphics-mode transition. A ten-second post-success interval measured
2.929714 MHz, 571,624 retires in 29,297,397 cycles, 134 interrupt
acknowledgements, zero AXI reads/ARs, and 3,082 write responses. The service was
then stopped and the result/logs were preserved under
`fpga_verify_20260821/win95_clean2/`.

This closes the Win95 half on the source-matched timing-valid non-fast control
image. It does not waive the broken fast image or satisfy Quake.

### Fast-path real-mode interrupt/return isolation

The current fast image remains unsuitable for Quake acceptance. Focused
silicon diagnostics are preserved in
`fpga_verify_20260821/fastpath_irq_isolation/README.md`.

The failure is not IVT corruption and not a bad stack frame. Two diagnostic ROM
captures show real-mode microcoded consumers accepting stale instruction-stream
bytes on `mem_ack`:

- hardware IRQ delivery through `S_RMINT_RD` used ROM bytes around
  `F000:023C` as the IRQ0 IVT entry and jumped to `B900:0105`, while IVT8
  still contained the correct `F000:024E` target; and
- real-mode software-handler `IRET` used instruction bytes around
  `F000:00E2` as the return CS (`B9A5`), while the stack still contained the
  correct `F000:00E8` return frame.

The proposed repair is to qualify/serialize the core memory response at the
fast-path interrupt-to-microcode boundary, especially for `S_RMINT_RD` and
`S_RMIRET`, and to align `inta` with the actual `fp_irq_divert` acceptance
predicate. Do not fix this by globally disabling the fast path or flushing
cache state on every interrupt; that is likely to erase the Quake performance
budget while only masking the bad response association.

### 2026-08-22 repaired-image implementation and silicon audit

The repair agent added a one-clock `rm_read_armed` request gap at the real-mode
IVT/IRET consumers and enabled `NARROW_REPLAY_SAFE` for the DDR-only FPGA
integration. The latter discards one narrow HP0 response, repeats the same AR,
and delivers the second response. The accompanying gate models exactly one
stale first response followed by a correct second response.

The corrected-clock Vivado 2025.2 implementation completed legally. Its exact
raw bitstream is
`fpga_run_20260822_irqfix/rk_ao486_system.bit.bin`, SHA-256
`f8f69b38417a6039db64f38c691bb1c65111afc09f670b02042e09177c2d3bf1`.
Final implementation used 316,250 CLB LUTs (92.67%), 42,339 registers, 85
BRAM tiles, and 1,265 DSP48E2 blocks. All 415,779 nets routed; post-route timing
was WNS +2.004 ns and WHS +0.011 ns at the modeled 100 MHz PL / 3.125 MHz core
clock. The repair added only 115 placed LUTs and removed 28 registers relative
to the preceding fast image, so it did not create a new large area regression.

The board-side hash matched, FPGA manager reported `operating`, the paired
daemon returned `IDENT=A0486501`, and the core clock measured approximately
3.12533 MHz. Nevertheless the default reset-state focused ROM failed
deterministically: all 256 phase-1 nested IRQ/IRET iterations completed, but
the VGA-tail `STI; POP DX; POP AX; RET` phase escaped after only 35 of 256
returns. A 45-second rerun stopped at the exact same counters. The stack frames,
IVT, bad counters, and completed phase-1 state were intact.

The decisive A/B cleared only CR0.CD/NW in the test ROM. On the same bitstream,
the identical interrupt program then completed both 256-iteration phases with
zero bad counters. This localizes the remaining failure to the reset-state
non-cacheable narrow L1D/HP0 path, not the cacheable core response handoff.

A diskless production BIOS run then froze before POST or disk access. The ring
shows the correct VGA option-ROM `RET` at `C000:1D69`; the returned offset is
still the correct `1CEA`, but CS becomes `2ADB` instead of the correct `C000`
and execution walks data. Stack RAM still holds `1CEA C000`, and IVT8 remains
correct. The implemented fixed gap plus one blind replay is therefore not a
transaction-identity repair: silicon can still deliver an older value on the
nominally real response.

The current P0 is to instrument all AR/R traffic including priming responses,
root-cause HP0 reset/drain/width-converter ownership, register data and its
transaction token together, and require `ven_l1d`'s `L1_BYP` completion to
match the latched core request identity. Tests must cover address-changing
back-to-back reads, reset with an outstanding response, and more than the
single-stale-response pattern. A third blind replay, global fast-path disable,
forced caching, or interrupt-wide flushing is not an acceptable fix.

Complete hashes, counter tables, ring excerpts, proposed implementation steps,
and final board state are in
`fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md`. At this superseded checkpoint,
Quake and Win95 were not started on the first `irqfix` image because production
BIOS failed before disk access.
The pristine Quake disk remains SHA-256
`38e31d11c17fb739b7a3605e6e0d43f85707c2b94a237ed19c5fdd62d97f3c0d`.

### 2026-08-22 follow-up: exact L1 bypass ownership root cause

The earlier conclusion that HP0 itself necessarily returned stale data was
superseded by an exact source-matched reproduction. In the full Verilator PC
model, the unpatched `CR0=60000010` diagnostic failed at cycle 41,304,062 when
an IVT8 read at physical `0x20` received preceding instruction-fetch bytes
`06c72600` instead of `f000024d`, escaping to `CS=06c7`.

`ven_l1d`'s normal hit response has a registered owner match, but `L1_BYP`
acknowledged any live non-cacheable read and selected the buffered A response
using B's live `c_addr`. The compact repair qualifies the response with the
already-saved `fbase` plus a four-bit saved strobe/extent, and indexes the
response only with saved `fbase[1:0]`. A retargeted request retries from IDLE;
cacheable traffic gets no new bubble, flush, replay, or serialization.

The new focused A-to-IVT-B retarget gate fails before the repair and passes at
both cache geometries plus `VEN_L1_HONOR_CD`. The exact reset-state ROM now
finishes the full model at 82,340,000 cycles with software return 256/256,
POP-tail return 256/256, zero bad counters, and 1,096,308 retires. Lint, the
98-program fast differential gate, the deployed KV260 CALL/RET/cross-word/
cross-line tests, and both single-clock and CDC L1/AXI differential suites are
green (each L1/AXI suite: 98/98 user plus 10/10 system equivalence).

Historical pre-deployment checkpoint: a new implementation was running in
`fpga_run_20260822_l1bypown/`. Until it was deployed, the previous image was
separately running a diagnostic BIOS stub that
only clears CD/NW before the unchanged production BIOS, with the clean
viewsize-30 timedemo disk. This control is intended to obtain an exact
969-frame result without pretending the guest workaround repairs reset-state
hardware. The repaired image still must pass the original ROM and unpatched
BIOS/timedemo on silicon.

The timedemo result file is actually `\QUAKE\ID1\QCONSOLE.LOG`; early manual
checks watched the parent `\QUAKE` directory. A corrected read of ID1 (cluster
138, disk LBAs 878-879) showed that the old-bitstream control still had not
created the file after about an hour. Local QEMU controls proved exact 969-frame
completion for the untouched disk, an 82-byte minimal-timer TSR disk, and a
two-byte heap-scan-loop patch. The timer TSR is available as a reversible FPGA
performance aid, but neither guest experiment waives the repaired image's
unpatched reset-ROM and production-BIOS acceptance requirements. Details and
hashes are in `fpga_verify_20260822/quake_fasttick/` and
`fpga_verify_20260822/quake_memscan_patch/`.

## Pending acceptance ladder

- routed timing and DRC clean, with utilization/congestion reviewed;
- bitstream and 139-input hashes recorded and unchanged;
- FPGA-manager `operating` plus `IDENT=A0486501` from the matching daemon
  (**observed with a measured timing-safe 2.9297 MHz runtime clock**);
- SeaBIOS/POST, valid boot sector, FreeDOS/CWSDPMI, and advancing Quake init
  (**observed with a measured timing-safe 2.9297 MHz runtime clock**);
- exact 969-frame Quake timedemo result from a disk with no pre-existing result;
- pristine Windows 95 boot to the VMM/System-VM desktop-idle signature
  (**PASSED cleanly on the timing-valid non-fast control image**); and
- final hashes, logs, runtime samples, and repeat commands added here and to
  `HOW_TO_RUN_FPGA.md`.

## 2026-08-23 superseding ownership image, full utilization audit, and workloads

The completed superseding implementation is
`fpga_run_20260822_l1bypown/rk_ao486_system.bit.bin`, SHA-256
`891881f6b7196023bf1d34a6433b7a53f7814166ce6a38dbeb31c0db5f15b5dc`.
The board copy matched, FPGA-manager reported `operating`, and the paired daemon
returned `IDENT=A0486501`. The original reset-state nested IRQ/IRET ROM passed
twice on silicon with all 256 handler returns, all 256 POP-tail returns, and
every bad counter zero. Production BIOS and FreeDOS now boot without clearing
CR0.CD/NW. This closes the L1 bypass request-A/request-B ownership defect.

### Full synthesis/implementation compactness result

The image is legal and timing-positive, but its structure is not acceptable as
a compact hardware implementation. Synthesis produces 364,029 CLB LUTs against
341,280 available (106.67%). Cross-hierarchy optimization reduces placement to
316,176 LUTs (92.64%), with final WNS +0.844 ns and WHS +0.013 ns, but the placer
reports high congestion and routing reaches conflict iteration 100. Synthesis
took 3:02:39 and 17.99 GB; placement took 21:26 and routing 41:04.

The routed hierarchy localizes the waste: x87 leaf blocks own 214,613 placed
LUTs, and the four transcendental engines own 1,231 of the core's 1,265 DSPs.
The supposedly shared `fpu_fx_ppl` exists only below FSINCOS; F2XM1, FPATAN, and
FYL2X still elaborate private add/multiply/normalize/round and wide-product
cones. FPATAN alone is 59,339 LUTs and 516 DSPs. This must be combined
aggressively into one owner-tagged floatx80 arithmetic service, one sequential
estimate divider, and one scheduled 64x64 multiplier lane (two only after a
measured throughput failure), with one coefficient ROM and eventually one
transcendental microsequencer. Leaving old inline functions behind a result mux
does not remove hardware.

Other measured duplication is also material: the 256-flop GPR file hierarchy
uses 16,779 LUTs because eight independent write-data/enable cones replace two
addressed architectural write ports; BTB and I-cache metadata account for 909
of the core's 1,199 control sets. Use exactly two addressed GPR writes, exactly
two physical integer lanes (U and V, with the slow path sharing U), addressed
BTB storage, and one reused I-cache hit/snoop decoder. Do not serialize U/V,
add cache-hit bubbles, globally flush on interrupts/stores, disable the fast
path, or offload x87 to PS as an area claim.

Acceptance is less than 85% placed LUT use with no congestion warning (stretch
less than 80%) and a measurable full-design reduction after every structural
stage. Stop after synthesis when a stage does not remove the old primitive
owners; only pay the P&R cost after the reports prove sharing. Exact hierarchy,
RAM/control-set reports, rejected shortcuts, and the staged verification plan
are in `fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md`.

### Quake: exact protected-mode LDS blocker

The QEMU-proven result-only disk has clean SHA-256
`13f0a1286ceb0da61ddb2f2f20cacdcabbe585dc2967ba39df3a519463795509`
and produces the exact 36-byte `969 frames   2.4 seconds 404.7 fps` record under
the pinned oracle. Two repaired-image board runs produced no result. The second
used only the built-in RAM, PC-ring, and external-freeze infrastructure and
captured CWSDPMI's resident TSS at physical `0x30142`:

```text
irqn=0d error=00000028 cr3=0007e000
cs:eip=0018:00001105  ss:esp=0020:0000383a
```

Selector `0x18` has base `0x26d90`; bytes at the faulting physical `0x27e95`
are `66 67 c5 75 10`, CWSDPMI `_ring0_iret`'s
`lds esi,[ebp+0x10]` m16:32. The saved pointer itself is correct:
`SS:[EBP+16]` contains old `ESP:SS=00003484:0033`. RTL inspection shows C4/C5
decode is restricted to `seg_real`, although `core_exec.svh` already has an
unreachable protected-mode route through `S_SEGLD`.

The compact fix is one common far-segment-load transaction shared by C4/C5,
0F B2/B4/B5, MOV-Sreg memory, and (with explicit stack semantics) POP-Sreg. It
must stage selector/target/optional GPR side effects, reuse the existing
descriptor walker, and atomically commit only after validation. Merely deleting
the decoder gate would boot farther but would retain the corner-case bug where a
descriptor/page/privilege fault leaves the destination GPR modified. Required
tests include the exact `66 67 C5 75 10` instruction, both pointer widths, SS
default and overrides, GDT/LDT/null/not-present/privilege cases, page splits,
and poisoned destinations proven unchanged on every fault. No Verilog was
modified during this board-debug pass. Evidence and hashes are under
`fpga_verify_20260822/quake_final_log/`.

### Win95: repaired-fast image passes

The pristine sparse disk source SHA-256
`877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8`
was restored and booted on the same bitstream with reset-state
`CR0=0x60000010`. The source-controlled read-only detector repeated a clean
desktop result:

```text
samples=1500 transitions=553
top_last_ar=001021c0:1500
top_eip=000001e5:735, 000001e6:725, ...
lowmem IVT13=024c0122 IVT19=05b0002f tick=0005f000->0005f0d7
DESKTOP SIGNATURE PRESENT
```

B8000 was blank in all 2,000 cells. A ten-second interval measured 3.125029 MHz,
373,986 retires, and 142 IRQ acknowledgements. No input, cache flush, freeze,
stall watchdog, guest patch, or Verilog debug change was used. The service was
stopped and confirmed inactive; logs and hashes are in
`fpga_verify_20260822/win95_l1bypown/`.

Therefore the current repaired-fast workload status is: FreeDOS **PASS**,
Win95 headless desktop signature **PASS**, exact Quake timedemo **FAIL/open on
protected-mode LDS**. Quake is the remaining workload acceptance item.
