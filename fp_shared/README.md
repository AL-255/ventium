# Area-shared PL x87 hierarchy

This scratch tree contains an integration-independent replacement for the
current split `fpu_top`/`fpu_writeback` implementation. It does not modify the
Ventium checkout. The only public block is `ven_fp_top`; the other `ven_fp_*`
modules are private implementation children.

## Reference-driven constraints

The design was checked against these local references:

- `ventium-refs/02-pipeline-internals/alpert-avnon-pentium-ieee-micro-1993_FPU_transcribe.txt`
  describes a centralized FIRC state/control boundary, shared exponent and
  rounding work, FADD micro-operations for conversions/BCD/transcendentals, an
  iterative FDIV section shared by divide/remainder/square root, and
  table-driven transcendental microcode.
- `ventium-refs/07-p5-emulation-harness/docs/p5_timing_extractions.json`
  records three-cycle basic arithmetic latency, precision-dependent iterative
  FDIV, and overlap of long FP execution with integer work.
- The proven functional oracle is the existing RTL: `rtl/fpu/fpu_top.sv`,
  `rtl/core/fpu_writeback.sv`, `rtl/fpu/fpu_x87_pkg.sv`, and the individual
  iterative/transcendental engines.

The original P5 spent area on distinct, throughput-oriented FADD and FMUL
sections. This FPGA variant intentionally preserves the centralized,
sequenced organization while serializing more work onto fewer units. It is a
PL area tradeoff, not a claim of cycle-identical P5 throughput.

## Public contract and timing boundary

`ven_fp_top` accepts one decoded command with `cmd_valid/cmd_ready`, captures
its operands and control state, and returns a later `rsp_valid` completion.
Architectural state changes occur only on the issue edge for simple metadata
operations or on the completion edge for deferred operations.  This makes the
command edge an architectural commit boundary: an adapter must not submit a
speculative command, and must pre-probe every memory-store destination before
submission because the block has no later cancel or memory-ack input.

There is no combinational wide-arithmetic path from command acceptance to an
architectural write:

- add/subtract/multiply: operand capture, execute-front register, then
  normalize/round/pack register;
- divide/square root/remainder: one iterative radix-4 SRT service;
- conversions/stores: registered request and result service;
- BCD: existing iterative load/store engines;
- transcendental functions: one microsequencer that issues one operation at a
  time to the shared arithmetic, quotient, and wide-integer services;
- wide 128-bit products: sixteen cycles through one 32x32 limb multiplier.

The block itself permits only one outstanding x87 command. Integer overlap
and precise retirement are responsibilities of the future core adapter: it
must let independent integer work proceed while retaining the FP command until
`rsp_valid`, and must stall dependent/unsafe retirement as required. This is
the explicit path to a non-blocking CPU integration without putting an FP cone
on the integer setup path.

## Structural sharing

The complete hierarchy contains:

- one pointer-mapped 8x80 architectural register bank;
- one registered floatx80 add/subtract/multiply pipeline, shared by ordinary
  arithmetic and all transcendental polynomial steps;
- one `fpu_srt_div`, shared by FDIV/FDIVR, FSQRT, FPREM/FPREM1, FPTAN, and the
  FPATAN far-ratio path; its final quotient/root choice is registered before
  the one shared leading-one/rounding network;
- one `ven_fp_estdiv`, shared by FYL2X/FYL2XP1 and both FPATAN rational
  reductions; its two estimate quotients use one 32-cycle restoring divider
  and its correction uses one registered multiplier;
- one iterative 32x32 limb multiplier for every 128-bit transcendental
  quotient/reconstruction product;
- one compare/classify cone, one registered conversion/store service, and one
  pair of iterative BCD engines;
- one table-driven sequencer for FSIN, FCOS, FSINCOS, FPTAN, FPATAN, F2XM1,
  FYL2X, and FYL2XP1.

There are no behavioral wide divide/modulo operators reachable from the
synthesized hierarchy. `FX_NONE` completes loudly with
`rsp_unsupported=1`; every decoded `fxop_e` used by the old implementation has
an implemented routing/commit shape.

## Functional verification

Run from this directory:

```sh
make test
make synth-ooc-old
make synth-ooc-shared
```

`make test` keeps all generated files under this scratch tree. Its current
proof set is:

- `VEN-FP-STATE-A-B-OK steps=5000`: randomized cycle-by-cycle state-file
  equivalence against `rtl/fpu/fpu_top.sv`;
- `VEN-FP-ALU-A-B-OK checks=1216`: directed/random arithmetic result and
  exception equivalence;
- `VEN-FP-WIDEMUL-OK checks=1005`: exact directed/random 128x128 product proof
  for the iterative limb multiplier;
- `VEN-FP-ESTDIV-A-B-OK checks=5004`: exact estimate quotient/remainder/result
  equivalence against the old single-cycle `fpu_estdiv` arithmetic;
- `SRT-ITER-GATE-OK (609 vectors x 2 PLAs)`: correct and Pentium-FDIV-bug
  quotient results against the generated golden corpus;
- `VEN-FP-SRT-SQRT-A-B-OK checks=8012`: unified SRT square-root mode against
  the proven `fx_sqrt` result for all rounding modes;
- `BCD-GATE-OK` and `FBLD-GATE-OK`: 40,000 vectors in each direction against
  the proven packed-BCD conversion functions;
- `VEN-FP-TRANS-A-B-OK checks=1640`: all eight operations, all rounding modes,
  and directed/random values against the proven old engines, using the exact
  shared ALU and iterative wide multiplier instantiated by `ven_fp_top`;
- `VEN-FP-TOP-SMOKE-OK checks=132`: command/state/store/environment (including
  14/94-byte and real-mode images), post-accept command-bus mutation, masked
  and unmasked stack faults, SRT, BCD, and all transcendental commit shapes;
- `VEN-FP-ARCH-A-B-OK checks=101`: one logical instruction at a time against
  the old `fpu_writeback` plus `fpu_top`, covering all 64 supported `fxop_e`
  values and comparing stack mapping, tags, control/status, pointers,
  environment images, and deferred destinations (`FX_NONE` is separately
  checked as the required loud unsupported witness);
- `FPPIPE-GATE-OK (1000000 random + directed)`: the repository proof that the
  registered fast split is bit-exact with `f_eval`.

The architectural harness normalizes latency. Leaf result equivalence is
proved by the arithmetic/transcendental/SRT/BCD suites; the command harness
proves routing and architectural mutation. `VEN_FP_SHARED` now connects this
block to the CPU. The full exact-profile CPU differential remains an acceptance
condition; the completed subset and the write-protected FISTP precision gate
are recorded in `HOW_TO_USE.md`.

## FPGA target

The only target in this scratch flow is the current RK-XCZU15EG-F part
`xczu15eg-ffvb1156-2-i`. `synth_xczu15eg.tcl` reports against the deployed
3.125 MHz core constraint (320 ns) after an explicit
`synth_design -mode out_of_context`. It never
opens the board project, block design, PS, implementation run, bitstream flow,
or any `fpga_run_*` directory. The two Make targets call
`run_ooc_vivado.sh`, which delegates to the repository-wide exclusive launcher.
Every new Vivado launch terminates existing `vivado` processes first; do not
invoke raw Vivado or run this concurrently with a board build.

The `old` variant is a conservative leaf-bundle baseline built from the
deployed split units: old `fpu_top`, ordinary `fpu_fx_ppl`, the unified SRT and
BCD engines, and separate FSINCOS/F2XM1/FYL2X/FPATAN engines. All services are
kept observable at the OOC boundary. The `shared` variant is the complete new
`ven_fp_top`, including its command shell and state. This comparison therefore
does not manufacture savings by excluding shell/state logic from the new side;
it slightly understates savings because the old core's writeback/environment
assembly is outside the leaf bundle.

Fresh reports are written under `ooc_xczu15eg_old/` and
`ooc_xczu15eg_shared/`; each directory is deleted at the start of its own run
so a failed retry cannot leave apparently current evidence.

## Measured XCZU15EG out-of-context result

Both variants completed in Vivado 2025.2 with zero errors and zero critical
warnings on 2026-08-30. The old run emitted `VEN-FP-OOC-OLD-OK`; the shared
run emitted `VEN-FP-OOC-SHARED-OK`. The reports and DCPs are fresh products of
those runs, not copied board-flow results.

| Post-synthesis resource | Old split leaf bundle | Complete shared top | Change |
| --- | ---: | ---: | ---: |
| CLB LUTs | 155,118 (45.45%) | 69,211 (20.28%) | -85,907 (-55.38%) |
| CLB registers | 7,171 (1.05%) | 9,464 (1.39%) | +2,293 (+31.98%) |
| CARRY8 | 9,881 (23.16%) | 1,978 (4.64%) | -7,903 (-79.98%) |
| DSP48E2 | 1,405 (39.82%) | 118 (3.34%) | -1,287 (-91.60%) |
| Block-RAM tiles | 2.5 (0.34%) | 2.5 (0.34%) | no change |
| Inferred 64x64 multipliers | 23 | 1 | -22 (-95.65%) |

The register increase is the deliberate cost of capturing commands and
operands, retaining intermediate values, and sequencing one shared service.
The LUT, carry, and especially DSP reductions show that this serialization is
an area reduction after XCZU15EG technology mapping, not merely an RTL source
count reduction. Hierarchically, the complete new transcendental sequencer,
including its shared estimator and iterative wide multiplier, uses 31,351 LUTs
and 30 DSPs;
the old separate F2XM1/FPATAN/FYL2X/FSINCOS engines use 131,225 LUTs and 1,317
DSPs before adding the ordinary arithmetic service.

At the deployed 320 ns period, both synthesized designs have zero TNS. The
old baseline has +79.378 ns WNS; the final shared design has +295.517 ns WNS.
Subtracting WNS from the constraint gives an implied 24.483 ns minimum period,
or a **40.845 MHz post-synthesis OOC Fmax screen** for the final shared design.
The corresponding old split-leaf screen is 240.622 ns, or 4.156 MHz.

The critical-path work was measured after every cut:

| Area-optimized OOC netlist | Implied minimum period | Fmax screen | Worst internal cone |
| --- | ---: | ---: | --- |
| Old split leaf bundle | 240.622 ns | 4.156 MHz | old parallel FP leaf logic |
| Initial shared top | 49.194 ns | 20.328 MHz | behavioral estimator divide |
| Iterative shared estimator | 25.157 ns | 39.750 MHz | FPATAN split/index-to-y cone |
| FPATAN index register cut | 26.230 ns | 38.124 MHz | pre-existing SRT mode/result cone |
| SRT final-value register cut | 24.483 ns | **40.845 MHz** | shared SRT leading-one/rounder |

The small non-monotonic step after the FPATAN cut is normal for an unplaced,
area-optimized mapping: it removed FPATAN from the top paths and exposed the
SRT path, but changed routing estimates. The final screen is 2.01x the initial
shared Fmax and 9.83x the old leaf-bundle Fmax. Relative to the initial shared
top it also removes 6,257 LUTs and 865 CARRY8s while retaining the same 118
DSPs and 2.5 BRAM tiles.

The three low-risk timing changes preserve sharing and non-blocking behavior:

- replace two mutually exclusive single-cycle 64/32 estimator divides with
  one 32-cycle restoring divider;
- register the FPATAN table index before its dependent y-shaping state (one
  extra transcendental microcycle);
- capture the already-final SRT quotient/root magnitude on the last iteration,
  ahead of the common rounder (no added divide/square-root completion cycle).

The remaining worst path is `u_srt/round_uq_q_reg[5]` to
`u_srt/result_q_reg[72]`: 24.465 ns data delay, 88 logic levels, and 83.0%
estimated routing. It is now the intrinsic shared leading-one/round/pack cone,
not a duplicated operator or mode mux. A further cut would require another SRT
rounding stage and is therefore an architectural latency tradeoff rather than
the same class of low-hanging functional-unit fix.

These timing numbers are screening evidence only. The clock is applied after
the area-optimized synthesis pass, so this is the speed of the area comparison
netlist rather than a timing-driven Fmax search. The OOC constraint covers
the internal `fp_clk` sequential paths but deliberately has no top-level
input/output-delay model and no placed clock-buffer `HD.CLK_SRC`; Vivado lists
those boundary paths as unconstrained. The integration adapter must register
the command/response boundary, and the eventual complete-image placement and
routing remains the timing authority.

Evidence files:

- `ooc_xczu15eg_old/utilization.rpt` and
  `ooc_xczu15eg_shared/utilization.rpt`: flat mapped totals;
- `ooc_xczu15eg_old/utilization_hier.rpt` and
  `ooc_xczu15eg_shared/utilization_hier.rpt`: ownership by unit;
- both `timing_summary.rpt` files: 3.125 MHz internal timing and unconstrained
  boundary disclosure;
- `ven_fp_old_ooc_synth.dcp` and `ven_fp_top_synth.dcp`: synthesized
  checkpoints for independent inspection.

K26/KV260 utilization and timing data are legacy and are not used here. The
out-of-context result is only a PL resource/timing audit; final acceptance
requires synthesis, placement, routing, and on-board testing in the complete
RK-XCZU15EG-F image.

## Integration path

1. Copy the seven new implementation files (`ven_fp_top.sv`,
   `ven_fp_state.sv`, `ven_fp_alu.sv`, `ven_fp_misc.sv`,
   `ven_fp_widemul.sv`, `ven_fp_estdiv.sv`, and `ven_fp_trans.sv`) into
   `rtl/fpu/` and add them to each ordered filelist after the x87 packages and
   before their consumers. Apply the small final-value register change from
   this tree's `fpu_srt_div.sv` to the existing module. Retain dependencies on
   `ven_bcd` and `ven_bcd_to_fp`; the shared hierarchy no longer instantiates
   the old combinational `fpu_estdiv`.
2. Add a narrow adapter from the current decoded `q_fxop/q_f_*` fields and
   memory payloads to `cmd_*`. Register the boundary, pre-read load data, and
   pre-probe every byte of a store before the `cmd_valid && cmd_ready` edge.
   Capture one command only when `cmd_ready` is high; hold the core's FP
   occupancy/scoreboard and unsafe retirement until `rsp_valid`. Never submit
   a command that may subsequently be squashed: this interface has no cancel
   or response-backpressure input.
3. Keep the old state/writeback hierarchy active and shadow every accepted FP
   command into `ven_fp_top`. Compare completion payloads, stores, AX results,
   TOP/status/control/tag/pointers, and all eight physical registers after
   every logical FP retirement. `tb/tb_ven_fp_arch_ab.sv` is the template.
4. Run `make verify`, `make verify-sys`, all standalone x87/SRT/BCD/transcendental
   gates, and the long full-system workloads. Functional differential gates
   remain authoritative; latency-band updates must not conceal state drift.
5. Switch architectural ownership to `ven_fp_top` only after the shadow run is
   clean. Remove old parallel engines in the same integration change so the
   area benefit is measurable and no duplicate cone survives synthesis.
6. Run the guarded full RK-XCZU15EG-F build, inspect hierarchical utilization
   and unconstrained paths, route at the real clock, then repeat the current
   board boot/Quake workload. Treat the OOC report as a screening step, not
   sign-off.
