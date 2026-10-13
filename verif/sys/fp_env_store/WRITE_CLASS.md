# FNSTENV/FNSAVE write-permission and fault-state repair

October 13, 2026. **Private UV-fast core candidate, not promoted or programmed.**
This is separate from the environment-layout repair and the physical FPGA's
[Doom SMSW startup failure](../../../docs/FPGA_DOOM_2026-10-13.md).

## Defect and fix

Both decoder arms (`D9 /6` FNSTENV, `DD /6` FNSAVE) set the operation and
object size but leave `d_f_mem_write=0`. The shared core already dispatches
these operations through `S_FENV_LD` for a permission sweep before issuing the
state-changing FPU command. Its no-bus write-probe discriminator requires
`q_f_mem_write`. The missing flag makes the intended sweep actual reads:

- A nonpresent second page raises a **read** #PF instead of a write #PF.
- A read-only second page passes the read probe. FNSTENV masks exceptions, or
  FNSAVE resets the FPU, before the actual destination write faults. The handler
  sees prematurely changed FP state, so retry is not architecturally precise.
- The unintended reads could also trigger device side effects. This corpus
  does not dynamically qualify MMIO destinations.

`prepare_write_class.py` sets **`d_f_mem_write=1` in those two decoder arms**.
It reuses existing write permission checking, precise fault/retry and store
machinery. No new state, global serialization, extra pipeline stage, disabled
pairing, guest patch or application-specific special case is introduced.
The frozen parent hash and reversible exact two-line delta are unit-tested;
drift and reapplication are rejected. Root RTL remains untouched while the
candidate is qualified. No performance gain is claimed.

## Cold native evidence

`fault.S` boots from a fresh BIOS image, initializes its own protected-mode
page tables and FPU state, and enables CR0.WP. It uses two noncontiguous physical
frames and a writable alias for destination checks. Both environment stores
and both operand sizes are covered:

| Cases per model | Expected property |
| --- | --- |
| 64 fault/retry executions | 2 operations × 2 operand sizes × 4 page splits × nonpresent/read-only × AXI latency 0/7 |
| 16 boundary controls | Object ends exactly before the denied page; no fault |
| 8 negative-fixture executions | Deliberately mask/reset FP state early; guest self-check must fail |

The #PF handler checks error code, saved EIP, CR2 and the pre-fault defined
CW/SW/TW/FIP/FDP/selector fields **before restoring the control word**. It repairs
the PTE, invalidates the TLB and retries. Final checks cover destination guards,
saved header, valid stack values and FNSAVE reset. Reserved bytes/FOP are not
graded. Partial destination writes are not forbidden: this test targets FP
state precision, not whole-object memory atomicity. Successful FNSTENV's
post-save masking and direct per-retirement x87-state tracing are not added
acceptance properties here; saved fields are checked by guest integer readback.

On the unchanged parent, **all 64 positive fault executions fail** and disagree
with the separately qualified private system-QEMU oracle. All 16 boundary
controls pass; the eight negative executions correctly fail their guest checks
and match QEMU. On the repaired model, **all 88 executions satisfy their expected
verdicts and complete-trace QEMU comparisons**. All actual RTL runs have nonzero
V retirements and L1 backing ACKs, with `--cycle-func --l1-axi`, no snapshot,
STEP, breakpoint or trace filtering.

The independent audit reruns **176 whole-trace comparisons** (88 parent + 88
candidate), rehashes **31,174 pins**, verifies all 195 source files with exactly
one changed, the private host object's matching generated header, native child
affinities, terminal owner identities and absence of OOM. It joins the build's
inner scope journal lifetime to its outer service, rather than confusing their
different invocation IDs. Private oracle SHA-256:
`f09369f734347c6ca0baf73b3edac8218c482b2fc1cd33c31b3e6672b7e51202`.
It has not replaced canonical QEMU; these passes do not waive canonical failures.

## Regressions and retained harness failures

The unchanged 108-program functional worker also closes **108/108 PASS** against
the separately qualified private user-QEMU oracle, in **122.75 s**. Original
manifest masks are unchanged. The new canonical `make verify` run is still
pending; do not infer a canonical pass from this private-reference result.

All failed observations remain distinct:

- `envfault-r1`: checker wrongly required an optional automatic-quiesce message
  despite explicit `--quiesce`; raw native failures retained. Corrected R2
  checks actual backing ACKs and establishes the 64-failure parent witness.
- `env-write-fault-r1`: 42 rows passed; two observer errors came from interleaved
  stdout/stderr corrupting a performance-log line. Subsequent runs keep streams
  separate without changing the guest, model or correctness comparator.
- `env-write-fault-r2`: 43 rows passed; one short-lived QEMU child was not sampled
  for affinity. It remains a failed harness run, not a pass.
- `env-write-fault-r3`: a fresh full rerun after R2's terminal closure passes
  all 44 fixtures / 88 RTL executions in **12.21 s**, with every actual QEMU/RTL
  child observed. No affinity or correctness guard was relaxed.

## Identity and reproduction

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.
Parent core `core-r1`; repaired core `env-write-core-r1`, model SHA-256
`360c79d44282f77b7deef21a8c4192258c549e85aacd51a80200bc1a62076779`.
All 152 definitions and explicit board single-fill `AXI_LINE_REPLAY=0` remain.
Native build: **20.32 s**, 32 jobs inside the guarded scope, after Vivado closed.

| Receipt | SHA-256 |
| --- | --- |
| `envfault-r2/closed.json` | `5563da27d59b30050fdd52f208bc10409a7ebaa0c5f9afd55154ac9f7c933b67` |
| `env-write-core-r1/build-closed.json` | `d79d4d9e3fecdb41a08e2960994918acc37a183b86cb5b387400b8c982c8c8e4` |
| `env-write-fault-r3/closed.json` | `0af94b120a1567f5ff6ade7cceab7079794bc6f9d6e1b410e098f94a4c19e546` |
| `env-write-audit.json` | `f0830198c4aa7f5b94397a733b225514e1138b1ecb8f319fecbf9b4ae1e52d3e` |
| `env-write-func-r1/closed.json` | `fe1631a388c6fe5e308ef86ad718bd7cb5086ed26265b30530a27889e0334aa5` |

Use external `TMPDIR` and `PYTHONDONTWRITEBYTECODE=1` throughout:

1. Set `ENV_WRITE_DECODER` to the frozen parent decoder for `test_write_class.py`.
2. `build_write_class_core.py prepare --out NEW_CORE` requires the closed parent
   witness. Its `build` action requires the native guarded 32-job scope, CPU8–15,
   matching private host object/header and no live Vivado family.
3. `run_fault.py --core NEW_CORE --out NEW_RUN` requires a systemd invocation,
   actual CPU13–16 affinity and free-disk guards; four workers, 30 s per command.
4. `run_write_checks.py func|canonical --core NEW_CORE --out NEW_RUN` preserves
   the original workers/comparators and stores wrapper/native receipts. Do not
   overlap the canonical guarded gate with Vivado or another heavy build.
5. `audit_write_class.py` audits the exact closed fault run above;
   `audit_write_regressions.py` requires both regression owners to have closed.

Still required: canonical/reference reconciliation, segment/privilege/pending-
exception/MMIO extensions, hardware-profile lint and full-PC transfer, the full
standard suite, 40 MHz synthesized/routed timing and physical Win95/Quake/Doom
validation. The data-size checkpoint lacks these two decoder lines; its
35.831 MHz estimate is **not a measurement of this repaired core**.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; predates this candidate, not FPGA/Doom IPC.
