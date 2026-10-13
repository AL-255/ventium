# Open defect: x87 environment restore omits saved pointers

October 13, 2026. **Reproduced in the frozen shared-FP RTL and pinned QEMU;
not repaired.** This defect was found while testing the obsolete-x87 repair,
but does not depend on FENI, FDISI or FSETPM executing.

## Evidence

The failed `state.S` fixture in `obsolete-fp-state-r1` loads eight known stack
values, FNSAVEs all 108 bytes, FRSTORs them, executes an integer NOP control,
and saves/compares again. Both engines fail the guest's check at environment
offset 12 (FPIP). The simplest integer-NOP control's 94 architectural trace
records agree completely; both native guests still exit **135**, not success
133. Agreement between two incomplete implementations is not correctness.
All 24 original fixture cases and their failed logs remain retained.

Source evidence in `obsolete-fp-core-r1/candidate/fp_shared`:

- `ven_fp_top.sv:1088`: `FX_FLDENV`/`FX_FRSTOR` commit CW, TOP, status and tag;
  FRSTOR additionally commits register contents. No saved pointer is decoded
  and passed to a pointer commit here.
- `ven_fp_top.sv:470`: existing pointer ports are wired to the current command's
  `cmd_fip/fcs/fdp/fds`, not a restored environment image.
- `ven_fp_state.sv:251`: pointer registers already have independent commit
  ports. Its `commit_env` block at line 263 restores no pointer fields.
- The core classifies environment administration separately and suppresses
  ordinary command pointer updates. FNSAVE initializes state afterward; an
  incomplete FRSTOR therefore leaves the reset pointers rather than the saved
  ones. This is not a state-comparison artifact caused by the obsolete no-op.

Pinned QEMU source below
`ventium-refs/07-p5-emulation-harness/build/qemu/target/i386/tcg`:

- `fpu_helper.c:2435`, `do_fldenv`: reads CW, SW and TW only, then restores
  status and tags; it never restores FPIP/FPCS/FPDP/FPDS.
- `fpu_helper.c:2484`, `do_frstor`: calls that helper and then restores ST
  contents. `do_fsave` initializes the FPU after writing the saved image.
- This gap is independent of `translate.c:4773` leaving `update_fip=true`
  for the three obsolete no-ops; both reference issues need separate tests.

The exact source closure is pinned by `obsolete-fp-core-r1/build-started.json`.
Model SHA-256:
`2fc497047dc64848f28a920522a6fa4ec1e8ef0c686179394576d6237402acb2`.
Pinned system-QEMU SHA-256:
`b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd`.
Evidence root:
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/obsolete-fp-state-r1`.
Closure SHA-256:
`29af242e16f518369d8d8d999dd3d89608c8ec9961dc91d2388cac4f1748b6aa`.

The replacement `state2.S` avoids the broken save/restore roundtrip only to
isolate obsolete-op semantics. It observes live state non-destructively and
compares all saved fields afterward. It **does not fix, waive or test arbitrary
pointer restoration**. Its 18 differential discrepancies remain red.

## Proposed general fix and acceptance tests

Decode restored instruction/data pointers from the already-collected
environment image, then multiplex them onto the existing independent pointer
commit ports on a successful FLDENV/FRSTOR commit. Do not use the current
instruction's own pointers as the restored values. This can avoid a new
multiport register bank or additional memory reads. Preserve the original
commit edge, precise fault behavior and separation from ordinary FP execution.
This is a design proposal, not a measured area/timing improvement.

Before implementing it, verify the Intel-defined layouts and supported opcode
field semantics for 14-/28-byte environments and real/protected/V86 modes.
Do not assume the protected-mode 32-bit layout also applies in real mode.
Use distinct nonzero pointer values, selectors and saved values so an identity
restore or a reset-to-zero bug cannot pass unnoticed. Test both FLDENV and
FRSTOR, both operand sizes, nonzero TOP, all tags, CW masks, pending exceptions,
reserved fields, save-after-restore, and back-to-back ordinary FP operations.
An independent spec-based saved-image oracle is necessary because the pinned
QEMU implementation has the same omission.

Add page/segment boundary and late-fragment faults with retries: no partial
environment/register/pointer update may leak before all input bytes are valid.
Test debug/interrupt ordering and older in-flight FP work, and reject mutants
that retain old pointers, restore only one pointer, swap fields or commit early.
Then run unchanged canonical/differential gates and the full standard suite,
including physical UV-fast Win95 desktop/UI and full Quake timedemo, before
promotion. No guest patch or save-state-based acceptance is appropriate.

Candidate gameplay IPC is **unmeasured**. Older simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; predates this candidate, not FPGA/Doom IPC.
