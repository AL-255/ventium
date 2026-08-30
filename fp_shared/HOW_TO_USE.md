# How to integrate the area-shared PL x87 block

This is the handoff contract for the implementation in the repository's
`fp_shared/` directory.  The public module is
`ven_fp_top`; every other `ven_fp_*` module is its private implementation.

The block is ready for a shadow integration, not an unconditional cutover.
Its arithmetic and architectural routing have been checked against the current
Ventium implementation, but the CPU adapter does not exist yet.  Functional
differential gates after that adapter is connected remain the final authority.
In particular, do not claim precise memory-fault or interrupt behavior unless
the commit rules in this document are implemented.

The current hardware target is the RK-XCZU15EG-F device,
`xczu15eg-ffvb1156-2-i`.  K26/KV260 results are legacy and must not be used for
this integration.  Do not open or modify the board-flow project while its
other owner is using it; the supplied synthesis flow is FP-only OOC.

## What the audit establishes

The design follows the reference organization rather than duplicating one RTL
cone per x87 instruction:

- a centralized state/control and command boundary, analogous to the P5 FIRC;
- one registered floatx80 add/subtract/multiply pipeline, also borrowed by all
  transcendental micro-operations;
- one iterative SRT engine shared by divide, reverse divide, square root,
  FPREM/FPREM1, FPTAN, and the FPATAN divide step;
- one iterative estimate divider and one 32x32-limb wide multiplier shared by
  the transcendental sequencer;
- one compare/classify cone, one conversion/store service, and the existing
  iterative BCD engines;
- one x87 command in flight, with latency isolated behind a ready/valid
  boundary rather than placed on the integer setup path.

The primary organization references are:

- `ventium-refs/02-pipeline-internals/alpert-avnon-pentium-ieee-micro-1993_FPU_transcribe.txt`;
- `ventium-refs/07-p5-emulation-harness/docs/p5_timing_extractions.json`;
- the current functional implementation in `rtl/fpu/fpu_top.sv`,
  `rtl/core/fpu_writeback.sv`, `rtl/fpu/fpu_x87_pkg.sv`, and the iterative and
  transcendental engines.

The new design deliberately serializes more work than the physical P5.  It
preserves values and architectural mutation as modeled by Ventium, but it is
not a claim of three-cycle P5 arithmetic throughput or cycle-identical overlap.

The current proof boundary is:

| Property | Evidence | Status |
| --- | --- | --- |
| Leaf arithmetic and exceptions | ALU, SRT, estimator, BCD, wide-multiply, and transcendental A/B suites | Passed |
| State-file behavior | 5,000 randomized cycle-by-cycle comparisons | Passed |
| Decoded operation routing | 101 architectural comparisons covering all 64 supported `fxop_e` values | Passed |
| Unsupported operation behavior | `FX_NONE` completes with `rsp_unsupported=1` | Passed |
| Command capture | Long FDIV remains correct while every live command field changes after acceptance | Passed |
| Environment formats | 14/28/94/108-byte forms and real-mode 16-bit field encoding | Passed |
| Integrated CPU faults/interrupts | Requires the adapter and differential gates below | Not yet established |
| Complete-image timing | Requires eventual placed/routed system build | Not yet established |

No finite test suite is a mathematical guarantee.  The passed A/B and directed
tests establish fidelity to the current Ventium oracle within the cases above;
the shadow and QEMU phases are mandatory before architectural ownership moves.

## Canonical files

Copy these seven new files into `rtl/fpu/`:

```text
ven_fp_top.sv
ven_fp_state.sv
ven_fp_alu.sv
ven_fp_misc.sv
ven_fp_widemul.sv
ven_fp_estdiv.sv
ven_fp_trans.sv
```

Also port the small final-result register change from the scratch
`fpu_srt_div.sv` into `rtl/fpu/fpu_srt_div.sv`.  Inspect the patch first:

```sh
git diff --no-index -- rtl/fpu/fpu_srt_div.sv \
  fp_shared/fpu_srt_div.sv
```

Apply only the `round_uq_q`/`round_sh_q` register cut if the checkout's SRT file
has changed since this audit.  Replacing a concurrently edited file wholesale
is unsafe.

The audited RTL hashes are:

```text
4e89bce46d4d4fe02e13d7dd8595da79c59dec14526af08e1b535c7303a553a4  ven_fp_top.sv
946ec3812c73b195e285e534bf1150451aab926378b7e945c8b4ddf22fbc6421  ven_fp_state.sv
cf3925b5f93fedd56cf81fd721cef020dd8c3d5fb4af2fb7a289a2e6270fc22a  ven_fp_alu.sv
16b6f2b9582bb15563ec730a2496cd1ab96c36173017f4c92e2ea78df6d5c69c  ven_fp_misc.sv
7cf6f9f906a79e60d19875c575d6e632f0525617528291e645fb057ec36ca5b9  ven_fp_widemul.sv
8b6260df1025996cbbbb4e819d66c2cadcd52f8fc8da4f4890bfdf3179bff69a  ven_fp_estdiv.sv
fd3500f077e2c3c44dc4c62e8f9174f19ed0b014b7cc4d21b7acd7d9644f121a  ven_fp_trans.sv
d034a95027cd631d1dad759ccfbf1955cee319106292859e112e6a68ffa419dd  fpu_srt_div.sv
```

Do not copy `ven_fp_old_ooc.sv`, any `tb/` file, synthesis script, DCP, report,
or generated `build/`/`obj_*` directory into the RTL tree.

## Filelist and defines

Keep package ordering.  The relevant order is:

```text
rtl/core/ventium_decode_pkg.sv
rtl/fpu/fpu_x87_pkg.sv
rtl/core/ventium_x87_pkg.sv
rtl/fpu/fpu_srt_div.sv          # with the audited register cut
rtl/fpu/ven_bcd.sv
rtl/fpu/ven_bcd_to_fp.sv
rtl/fpu/ven_fp_state.sv
rtl/fpu/ven_fp_alu.sv
rtl/fpu/ven_fp_misc.sv
rtl/fpu/ven_fp_widemul.sv
rtl/fpu/ven_fp_estdiv.sv
rtl/fpu/ven_fp_trans.sv
rtl/fpu/ven_fp_top.sv
```

Add the new files to `rtl_ven_core.f` for the Ventium-swapped ao486 build and
to `rtl/ventium.f` for the verification top, without globbing `rtl/**`.
`rtl_ven_soc.f` contains the surrounding ao486 platform and does not need a
second copy of the FP modules.  The shared top does not instantiate the old
`fpu_estdiv` or the separate old transcendental engines.

Compile the shared hierarchy with `VEN_FPREM`; the unified SRT remainder logic
is conditional on that define.  The new transcendental sequencer itself is not
conditional on `VEN_TRANSCENDENTAL`, although the CPU decoder may continue to
use that feature gate.

## Clock and handshake contract

`rst_n` is an active-low synchronous reset.  Hold it low across at least one
`clk` rising edge; the scratch tests use three.

A command is accepted on a rising edge where:

```systemverilog
cmd_valid && cmd_ready
```

All `cmd_*` fields must be stable for that edge.  If `cmd_ready` is low, keep
`cmd_valid` and every field stable until acceptance.  After acceptance the
producer may change the command bus; this behavior is explicitly tested.

`rsp_valid` is a one-clock pulse and has no ready/backpressure input.  The
adapter must sample every response in the cycle it is asserted.  Store and AX
payload qualifiers are valid only with `rsp_valid`.

`busy` reports a multi-cycle execution state.  It is not a replacement for an
adapter-owned pending bit: immediate commands can accept and produce a response
without asserting `busy`.  Track acceptance through completion explicitly.
Back-to-back operation can also produce a previous response in the same cycle
that a new command is accepted.

A safe pending-bit skeleton is:

```systemverilog
wire fp_accept = fp_cmd_valid && fp_cmd_ready;

always_ff @(posedge clk) begin
  if (!rst_n)
    fp_pending <= 1'b0;
  else begin
    unique case ({fp_accept, fp_rsp_valid})
      2'b10: fp_pending <= 1'b1;
      2'b01: fp_pending <= 1'b0;
      2'b11: fp_pending <= 1'b1; // old response plus new acceptance
      default: begin end
    endcase
  end
end
```

There is only one response stream and no tag/ID.  Never allow a second producer
or a second outstanding x87 command around this interface.

## Command mapping

Drive the command from the latched slow x87 decode record, not directly from a
wide combinational decoder.  Registering this boundary is part of keeping FP
logic off the integer critical path.

| Input | Adapter source/meaning |
| --- | --- |
| `cmd_op` | `q_fxop` (`ventium_decode_pkg::fxop_e`) |
| `cmd_aluop` | `q_f_aluop`: 0 add, 1 multiply, 4 subtract, 5 reverse subtract, 6 divide, 7 reverse divide |
| `cmd_sti` | `q_f_sti` |
| `cmd_pop` | `q_f_pop`; FCOMPP/FUCOMPP and FBSTP have fixed stack motion in the opcode |
| `cmd_constant` | `q_f_const` for `FX_FLDCONST` |
| `cmd_mem` | Little-endian operand buffer; first byte at memory address is in bits `[7:0]` |
| `cmd_mem_bytes` | 2, 4, 8, or 10 for the ordinary operand form |
| `cmd_fdiv_bug` | `errata_en[ERR_FDIV]` (`ERR_FDIV=0` in current core) |
| `cmd_fist_bug` | `errata_en[ERR_FIST]` (`ERR_FIST=1` in current core) |
| `cmd_env16` | Operand-size form: 1 for 14/94-byte environment/state, 0 for 28/108-byte form |
| `cmd_real_mode` | Current real-mode environment-image encoding selector |
| `cmd_env_image` | Fully assembled little-endian FLDENV/FRSTOR payload |
| `cmd_update_fip` | Existing non-administrative-operation predicate |
| `cmd_fip`, `cmd_fcs` | Existing instruction pointer/selector values |
| `cmd_update_fdp` | `cmd_update_fip && (q_f_mem_read || q_f_mem_write)` |
| `cmd_fdp`, `cmd_fds` | Existing effective data pointer/selector values |

Use the same administrative list as `fpu_writeback`:

```text
FNINIT FNCLEX FNSTCW FNSTSW_M FLDCW FWAIT
FNSTENV FLDENV FNSAVE FRSTOR
```

`FNSTSW_AX` and `FNOP` are intentionally not in that list; the current oracle
updates FIP for them.  `FNINIT` clears all saved FP pointers internally.

Do not reinterpret `rsp_arith` as a uniform external exception bus.  Its high
bits retain the leaf-engine format and differ for arithmetic, remainder, BCD,
and transcendental completions.  Architectural exception merging already
occurs inside `ven_fp_top`; use `fstat_o`/`fctrl_o` for architectural exception
delivery.  `rsp_arith` is useful for shadow diagnostics and leaf A/B tests.

The response contract is:

| Output | Meaning |
| --- | --- |
| `rsp_valid` | Completion pulse; always capture it |
| `rsp_unsupported` | Loud unsupported witness; halt/trap exactly as the existing unsupported-ISA path does |
| `rsp_stack_fault` | The accepted operation encountered the modeled x87 stack fault matrix |
| `rsp_store_valid` | `rsp_store_data[8*n-1:0]` contains `n=rsp_store_bytes` bytes to write |
| `rsp_ax_valid` | `rsp_ax` is the `FNSTSW AX` result |
| `ftop_o`/`fstat_o`/`fctrl_o`/`fptag_o` | Live architectural metadata |
| `fpr_phys_flat_o` | Eight physical 80-bit registers, physical register `p` at `[p*80 +: 80]` |
| `st_flat_o` | Eight logical ST registers, ST(i) at `[i*80 +: 80]` |

## Mandatory memory atomicity protocol

This is the most important integration rule.  `ven_fp_top` owns architectural
state and has no external commit, cancel, or memory-ack input.  Store
conversions can update status and pop the x87 stack when the FP response is
created, before the CPU performs the external memory write.  FNSAVE resets the
FPU and FNSTENV masks exceptions when their response is created.

Therefore a command that writes memory may be accepted only after every byte
of the destination is known to be writable without a later architectural
fault.

For an ordinary or environment load:

1. Translate and read the complete operand with the existing fragment engine.
2. If any read/protection/page fault occurs, deliver it without accepting an
   FP command.
3. Assemble the complete payload into `cmd_mem` or `cmd_env_image`.
4. Accept the command only after the final successful memory beat.

For a memory store:

1. Determine the exact final length before FP acceptance: 2, 4, 8, 10, 14,
   28, 94, or 108 bytes.
2. Probe translation, protection, limits, and every page spanned by the whole
   destination before asserting `cmd_valid`.
3. Prevent an interrupt, task switch, page-table-context change, or squash
   between that probe and the final write beat.
4. Accept the FP command and capture `rsp_store_data` and `rsp_store_bytes` on
   `rsp_valid`.
5. Serialize exactly the low `rsp_store_bytes` bytes through `S_FSTORE` or the
   environment-store loop.
6. Retire only after the final memory acknowledgement.

The existing page-split fragment engine is useful, but its normal
probe-before-second-fragment behavior is not sufficient if the first FP state
mutation has already occurred.  Both pages must be proven safe before the
`cmd_valid && cmd_ready` edge, and that proof must remain valid through the
write.  If the core cannot guarantee this, extend the FP interface with a
separate commit/abort phase before cutover; do not paper over the problem by
restoring state after a fault.

## Environment payload layout

All images are little-endian flat vectors.  The 32-bit environment is:

| Byte offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | FCW in low 16 bits |
| 4 | 4 | FSW in low 16 bits, with TOP overlaid |
| 8 | 4 | Full tag word in low 16 bits |
| 12 | 4 | FIP |
| 16 | 4 | FCS in low 16 bits; FOP is zero in the current oracle |
| 20 | 4 | FDP |
| 24 | 4 | FDS in low 16 bits |
| 28 | 80 | Logical ST(0)..ST(7), ten bytes each; FNSAVE/FRSTOR only |

The 16-bit environment is:

| Byte offset | Size | Field |
| ---: | ---: | --- |
| 0 | 2 | FCW |
| 2 | 2 | FSW with TOP overlaid |
| 4 | 2 | Full tag word |
| 6 | 2 | FIP[15:0] |
| 8 | 2 | Protected: FCS; real: `{FIP[19:16], 1'b0, FOP[10:0]=0}` |
| 10 | 2 | FDP[15:0] |
| 12 | 2 | Protected: FDS; real: `{FDP[19:16], 12'b0}` |
| 14 | 80 | Logical ST(0)..ST(7), ten bytes each; FNSAVE/FRSTOR only |

This reproduces the current Ventium/QEMU oracle: FLDENV/FRSTOR restore
control, status/TOP, tags, and (for FRSTOR) registers, but do not reload the
saved FIP/FDP selector fields.  That oracle behavior is independently visible
in the pinned QEMU `do_fldenv`.  Do not silently change it in the adapter.  If
full silicon pointer restoration becomes a requirement, make it a separate
architectural change with a directed test and an explicit differential-oracle
policy.

## Precise exceptions, interrupts, and non-blocking execution

The command edge is irrevocable for immediate operations, and completion is
irrevocable for deferred ones.  There is no kill input.  Never accept a command
from speculative decode or from an instruction that can still be squashed by
an older fault, branch redirect, debug event, or interrupt.

Preserve the existing deferred x87 exception delivery rule: `fstat_o[7]`/ES
continues to feed the core's next waiting x87/FWAIT `#MF` decision.  An unmasked
modeled stack fault suppresses the ordinary state action but commits IE/SF and
ES/B; a masked one commits the indefinite response.  The adapter must not
clear or duplicate those state changes.

Use two integration phases:

1. **Fidelity phase:** accept from a commit-safe `S_FEXEC` point, hold younger
   architectural retirement and interrupt/debug delivery until `rsp_valid`,
   then retire the x87 instruction (or complete its pre-probed store).  This is
   already a multi-cycle timing boundary even though it is conservative about
   integer overlap.
2. **Overlap phase:** keep one `fp_pending`/SIR record containing the x87 PC,
   next EIP, operand/store metadata, and fault state.  Allow independent
   integer execution while the FP service is busy, but retain enough in-order
   retirement or recovery state that an interrupt, debug trap, and pending
   x87 exception observe the same architectural boundary as the original P5
   model.  Block another x87 command, FWAIT, environment save/restore, task
   switch, and any instruction that consumes FP state until completion.

Do not call the implementation fully non-blocking merely because `busy` is
decoupled.  The overlap phase is complete only when directed tests inject
interrupts, debug events, page faults, and dependent x87 instructions at every
busy age.  The P5 reference's Safe Instruction Recognition role is the design
model for that recovery/retirement record.

## Recommended integration sequence

1. Copy the audited files and SRT hunk into a dedicated integration branch.
   Add the ordered filelist entries and make lint pass before connecting the
   block.
2. Introduce a `VEN_FP_SHARED` integration profile.  Initially route every x87
   operation through one registered slow command producer; do not let the
   current `u_d` fast FP arm and `S_FEXEC` become competing producers.
3. Instantiate `ven_fp_top` beside the old `u_fpu_wb` and `u_fpu_state`.
   Keep the old hierarchy architecturally authoritative.
4. Gate x87 issue on `cmd_ready`, shadow each accepted logical instruction into
   the new top, and implement the complete load/pre-probe/store protocol above.
5. At each logical FP retirement compare TOP, raw status, control, tags,
   pointers, all eight physical registers, all eight logical ST views, store
   payload/length, AX response, and unsupported/stack-fault responses.  Use
   `tb/tb_ven_fp_arch_ab.sv` as the comparison template.
6. Exercise both former producers: the fast `S_PIPE` x87 cases in
   `core_fastpath.svh` and the slow/load/store/environment paths in
   `core_fp_exec.svh`, `core_load.svh`, and `core_fenv.svh`.  A temporary
   all-slow profile is safer for the first shadow run; reintroduce optimized
   issue only after it produces the same single command stream.
7. Run all gates listed below.  Investigate the first state divergence; do not
   adjust cycle bands or mask trace fields to hide it.
8. Move architectural ownership to `ven_fp_top` only after shadow and QEMU
   differential runs are clean.  Reroute `fpr_flat`, metadata, debug scan,
   FNSTSW AX, and environment/store payload consumers to the new outputs.
9. Remove `u_fpu_wb`, `u_fpu_state`, and the old parallel ALU/SRT/BCD/
   transcendental instances in the same cutover.  A synthesis containing both
   generations does not demonstrate the intended area saving.
10. Run only the guarded FP OOC synthesis while the board flow is occupied.
    Coordinate with its owner before any complete-system implementation or
    hardware use.

Useful places to locate the current integration surface are:

```sh
rg -n 'u_fpu_wb|u_fpu_state|S_FEXEC|S_FP_BUSY|S_FSTORE|S_FENV' \
  rtl/core/core.sv rtl/core/*.svh
rg -n 'fpu_writeback.sv|fpu_top.sv' rtl_ven_core.f rtl/ventium.f
```

## Verification commands and acceptance markers

From the repository root (this test does not invoke Vivado):

```sh
cd fp_shared
make test
```

The current complete run must include these markers:

```text
VEN-FP-STATE-A-B-OK steps=5000
VEN-FP-ALU-A-B-OK checks=1216
VEN-FP-WIDEMUL-OK checks=1005
VEN-FP-ESTDIV-A-B-OK checks=5004
VEN-FP-SRT-SQRT-A-B-OK checks=8012
SRT-ITER-GATE-OK
BCD-GATE-OK
FBLD-GATE-OK
VEN-FP-TRANS-A-B-OK checks=1640
VEN-FP-TOP-SMOKE-OK checks=132
VEN-FP-ARCH-A-B-OK checks=101
FPPIPE-GATE-OK
```

The randomized state, ALU, wide-multiply, estimator, and transcendental suites
have also passed seeds 1, 17, and 20260830 using Verilator's seed plusarg.

After connecting the adapter, run at least:

```sh
make lint
make verify
make verify-sys
make m3
make verify-srt
make verify-fppipe
make verify-bcd
make verify-fbld
make verify-all
```

Use variant object directories and never clobber the canonical Verilator test
binary.  The functional differential result is authoritative; cycle-model
changes caused by serialization must be reviewed separately from value/state
correctness.

## OOC synthesis and measured screen

The OOC launcher refuses to start if any other Vivado executable is active and
never signals or preempts it:

```sh
make synth-ooc-shared
```

Do not bypass that guard while the other agent owns Vivado.  The canonical
reports are only:

```text
ooc_xczu15eg_shared/utilization.rpt
ooc_xczu15eg_shared/utilization_hier.rpt
ooc_xczu15eg_shared/timing_summary.rpt
ooc_xczu15eg_old/utilization.rpt
ooc_xczu15eg_old/timing_summary.rpt
```

Ignore the exploratory `ooc_*_post_*`, `ooc_*_pre_*`, `vivado_synth*`, and
legacy `obj_*` directories.

The audited XCZU15EG post-synthesis OOC comparison is:

| Resource | Old split leaf bundle | Complete shared top | Change |
| --- | ---: | ---: | ---: |
| LUT | 155,118 | 69,211 | -55.38% |
| FF | 7,171 | 9,464 | +31.98% |
| CARRY8 | 9,881 | 1,978 | -79.98% |
| DSP48E2 | 1,405 | 118 | -91.60% |
| BRAM tiles | 2.5 | 2.5 | no change |

At a 320 ns constraint the shared netlist has +295.517 ns WNS, implying a
24.483 ns internal minimum-period screen, or 40.845 MHz.  The worst internal
path is the shared SRT leading-one/round/pack cone: 24.465 ns, 88 logic levels,
83.0% estimated routing.  The longest unconstrained input-to-register path is
20.192 ns and the longest register-to-output path is 1.209 ns; this is why the
adapter boundary must be registered and why complete integration timing still
has to constrain the ports.

These are area-optimized, unplaced, post-synthesis estimates.  The clock was
created after synthesis, I/O delays and a placed clock source are absent, and
the command/response boundary paths are reported as unconstrained.  Treat
40.845 MHz as an OOC screening result, not routed Fmax or board sign-off.

## Cutover checklist

Do not remove the old implementation until every item is true:

- [ ] Audited source hashes or reviewed diffs match this handoff.
- [ ] All ordered filelists compile with `VEN_FPREM`.
- [ ] Exactly one registered command producer exists.
- [ ] Adapter tracks acceptance through response independently of `busy`.
- [ ] All load bytes are collected before FP acceptance.
- [ ] All store bytes/pages are pre-probed and protected from context change.
- [ ] `rsp_valid`, store payload, and AX payload are captured without backpressure.
- [ ] No speculative, cancelable, or interruptible command can be accepted.
- [ ] All 64 supported decoded operations match in shadow state.
- [ ] `FX_NONE` reaches the loud unsupported path.
- [ ] Masked and unmasked stack-fault tests pass.
- [ ] 14/28/94/108-byte environment cases pass, including page splits.
- [ ] FP busy-age interrupt/debug/page-fault/dependency tests pass.
- [ ] `make verify`, `verify-sys`, x87 unit gates, and `verify-all` are green.
- [ ] Integrated synthesis contains no surviving duplicate old FP engines.
- [ ] Integrated timing constrains command inputs and response outputs.
- [ ] Complete placed/routed target validation is coordinated with the board-flow owner.

If the memory pre-probe or precise-retirement conditions cannot be satisfied,
stop at shadow mode.  The correct next change is an explicit execute/commit/
abort protocol, not an optimistic cutover.
