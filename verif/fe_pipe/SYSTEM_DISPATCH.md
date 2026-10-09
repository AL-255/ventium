# Protected reference dispatch (prototype)

`system-dispatch.patch` is a narrow extension of the existing direct-memory
CoreMark dispatch optimization to checked system clients. It is not enabled
in production RTL merely by adding these files. See the
[measured results and limitations](../../docs/UV_FAST_BANK64_2026-10-08.md#protected-reference-dispatch-prototype--october-9).

Apply the patch only to a private, audited copy of the intended RTL. Build
matched control/candidate models with assertions, U/V, system fast pipeline,
real L1/AXI, BRAM I-cache, `VEN_PIPE_SDECODE`, `VEN_PIPE_SDISPATCH` and
`VEN_PIPE_SDISPATCH_SHORT`. Use separate uniquely named C++ harness sources
and verify their generated-header dependencies. Do not reuse a mismatched
model-dependent object or call a different memory/backend profile equivalent.

For prebuilt models, run from the repository root (all outputs must be new):

```sh
export TMPDIR=/home/yukidama/external/tmp
python3 -B verif/fe_pipe/prepare-system-dispatch.py \
  --control /absolute/control/tb_ventium --out "$TMPDIR/dispatch-fixtures"
python3 -B verif/fe_pipe/run-system-dispatch.py \
  --control /absolute/control/tb_ventium --candidate /absolute/candidate/tb_ventium \
  --fixtures "$TMPDIR/dispatch-fixtures" --out "$TMPDIR/dispatch-ab"
python3 -B verif/fe_pipe/run-system-dispatch-events.py \
  --control /absolute/control/tb_ventium --candidate /absolute/candidate/tb_ventium \
  --out "$TMPDIR/dispatch-events"
```

Preparation requires independent cold free-QEMU and control self-checks.
The A/B gate requires complete unfiltered QEMU architectural equivalence,
actual dispatch/V-pair witnesses, faster matched warm rounds and an unchanged
excluded-instruction control. The event gate checks TF/RF ownership, CPL3
RMW permissions/precise retry and CPU-store SMC at a line seam. No guest state
is restored or repaired, and neither driver compiles RTL or changes its mode.
Each child is bounded to at most 60 seconds; models run concurrently, not CAD.

These are microtests, **not** standard-suite or FPGA acceptance. They do not
establish a Quake IPC gain, a CoreMark board score, external-DMA concurrency
coverage, or successful complete Win95/Quake execution on this derivative.
