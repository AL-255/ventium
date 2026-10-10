# Serialized integer-converter sharing experiment

**Private candidate: native equivalence and matched synthesis now pass.**
No production RTL, active build input or acceptance mask was changed.
Latest verified gameplay is **0.49761630 total U+V retirement-event IPC**,
model `958f7ec4`, clocks 1,300,048,811–1,400,048,811. Its two consecutive
100M windows beginning 1,200,048,811 average **0.497514935**. This is not a
completed timedemo; the sharing derivative has no gameplay measurement.
Full direct-memory CoreMark remains
**2.107843209 / 2.110905243 CM/MHz**, separate model `b5453f16`, not FPGA scores.

## Why and what changes

`ven_fp_misc` executes one command at a time but calls `fx_to_int_ex` at three
separate sites: FIST, FRNDINT and FSCALE. This can duplicate the variable shifts,
rounding and signed range checking. Actual duplication/savings must be measured
in the matched native synthesis; source call counts alone do not establish LUTs.

The one-file rewrite selects the conversion operand **before the existing
capture register**: ST1 for FSCALE, ST0 otherwise. On that same capture edge,
FSCALE selects truncating RC; other operations preserve their supplied RC.
Only FSCALE used the previous B register and it did not consume the old RC.
Thus no state, stage, register, queue or latency is added. The existing FIST
width decode selects 16/32/64, and one converter supplies all three consumers.
The FIST erratum override still replaces its result only for the original
guarded cases. Store conversion and the new memory-FST C1 sideband are unchanged.

This is **behavioral equivalence**, not an ISA fix for existing FIST, FRNDINT,
FSCALE, noncanonical-input or unmasked-exception behavior. The reference is the
literal prepared memory-C1 candidate, renamed only at the module declaration;
that parent itself is not fully qualified.

## Verification and resource measurement

- Three host recipe tests pass, including missing/duplicate/repeated-patch
  refusal and preservation of memory-FST C1.
- `tb_misc_shared_int.sv` compares every output on every sampled edge in both
  original and early-notification profiles. Each profile requests **73,728
  directed cases**: nine operation classes, all RC/PC encodings, both erratum
  settings, signed zeros, integer limits, fractions, denormals, infinity/NaN
  and noncanonical bit patterns. Busy-pin mutation, sustained requests and
  reset cancellation additionally check ownership and exact latency.
- Both native miter profiles now pass, build/run exits 0, stable pins,
  **15.64 seconds**. Normal 4 GiB scope, one compiler, strict structural errors
  and assertions. Each completes all 73,728 matrix cases; normal/early observed
  latencies remain two/one clocks respectively, with reset and busy ownership
  checks. Closed service:
  `ventium-misc-shared-int-oct10.service`, invocation
  `c9056622a55e460f8cdf0011aadefdf0`.
- Prepared evidence: `external/tmp/ventium-misc-shared-int.dE4vmaE3/leaf/`.
  Parent: `ventium-fst-memory-core.KeXO3LAk`; its 651 inherited pins were checked
  by the parent preparation, and the new preparation rechecks its full plan.
- `run_misc_shared_int_ooc.py` refuses to synthesize unless both native miter
  profiles passed. It also refuses an active Vivado family, then uses the
  mandatory exclusive launcher, 4 GiB RAM/1 GiB swap and ten-minute bound.
  Both variants use the same XCZU15EG part, 25 ns constraint, early response
  mode, Default synthesis and rebuilt hierarchy. No route or board operation
  occurs. The first attempt failed before synthesis because project-mode
  `read_verilog -define` requires compile-unit mode. That native failure is
  retained under `ventium-misc-shared-ooc.U2itW4VW`. The corrected script sets
  the same define on each source fileset; it changes no RTL/constraint.

Matched retry `ventium-misc-shared-ooc-r2.6HWlbguy/run` closes **native 0** in
107.20 seconds with stable pins and both report/checkpoint sets. Supervisor
invocation `f1fb89724e1e406d89ba92791c4542f5` is independently archived as
inactive/success, exit 0, MainPID 0 and no remaining cgroup.

| Isolated synthesized leaf | Original | Shared |
| --- | ---: | ---: |
| CLB LUTs | 4,452 | 4,040 |
| Registers | 265 | 263 |
| DSPs | 0 | 0 |
| Register-to-register setup slack at 25 ns | +12.111 ns | +10.163 ns |
| Setup-only frequency estimate | 77.59 MHz | 67.40 MHz |

The leaf saves **412 LUTs (9.25%)**, while its estimated setup path gets slower.
The frequencies are `1000/(25−slack)` for this one-clock, **unplaced/unrouted**
leaf; they are not measured processor Fmax. OOC clock-source and unconstrained
I/O warnings remain. No global-route speed, routed timing sign-off or whole-chip
area saving is established. Current cache-backed CoreMark short ratios remain
**1.96212548 / 1.96640592**, duration errors retained, not valid scores.

Reproduce with fresh external output directories and explicit `TMPDIR`:

```sh
python3 -B fp_shared/tb/run_misc_shared_int.py \
  --prepare-from <prepared-memory-C1-core-root> --out <fresh-leaf-root>
VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator \
  tools/build_scope.sh -- timeout --kill-after=20s 600s \
  python3 -B fp_shared/tb/run_misc_shared_int.py --out <leaf-root>
# Only after both native passes and the intentional FPGA run has closed:
python3 -B fp_shared/tb/run_misc_shared_int_ooc.py \
  --leaf <leaf-root> --out <fresh-area-root>
```

Any area gain remains a leaf result. Full-core differential tests, both CoreMark
seeds, Win95 desktop, complete Quake timedemo and new FPGA implementation are
still required before promotion or performance/functional acceptance.
