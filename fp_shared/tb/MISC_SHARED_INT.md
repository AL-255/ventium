# Serialized integer-converter sharing experiment

**Private candidate prepared; native equivalence and area results pending.**
No production RTL, active build input or acceptance mask was changed.
Latest verified gameplay is **0.49638834 total U+V retirement-event IPC**,
model `86731249`, 3.8B–3.9B clocks. All 27 consecutive windows from 1.2B–3.9B
average **0.4813445296**, including the low-IPC interval. That partial run is
not a completed timedemo. Neither this proposal nor the later `958f7ec4` SoC
has verified gameplay. Full direct-memory CoreMark remains
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
- The new native miter is queued behind the existing shared build lock, not
  concurrently compiled with Vivado. Normal 4 GiB scope, one compiler, strict
  structural errors and assertions, ten-minute native bound. Pending service:
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
  occurs. **This measurement has not been launched.**

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
