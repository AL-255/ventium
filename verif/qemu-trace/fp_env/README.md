# Private QEMU x87 environment-pointer reference

October 13, 2026. **192/192 directed private-reference comparisons pass.**
This is not a canonical-oracle replacement, a green `make verify`, processor
acceptance, or a new FPGA image. Canonical verification remains **7 PASS /
101 FAIL** from the preceding RTL stage. The installed `fe9f539d` image still
fails original Doom startup on memory SMSW; **no Doom FPS is available**.

## Reason and scope

The [RTL restore](../../sys/fp_env_restore/README.md) and
[save-layout](../../sys/fp_env_store/README.md) tests exposed two independent
QEMU 8.2.2 omissions: `do_fldenv` restores CW/SW/tags but not the saved error
pointers; `do_fstenv` always uses the protected-mode pointer layout.

`prepare.py` is an exact-parent-hash transform of the actual QEMU
`target/i386/tcg/fpu_helper.c`. It changes only `do_fstenv`/`do_fldenv`:

- Decode and serialize the four 14/28-byte protected/real layouts.
- Restore FIP/FDP/selectors; real images hold linear pointers, so restored
  selectors are zero. Ordinary translator-produced offset/selector pairs are
  added when serializing real-mode pointers, not added twice after restore.
- Select real format for either PE clear or **`env->eflags & VM_MASK`**.
  The runtime VM bit is not stored in `env->hflags`.
- Collect all seven environment words before committing restored state, so
  adding the previously omitted pointer reads does not introduce a partial CW
  commit before an environment-operand fault. Fault atomicity is not yet tested.
- Encode/decode saved FOP where the format represents it; protected 16-bit
  restore leaves it unchanged. Nonzero FOP is outside the current qualification.

The layout authority is Intel Pentium Processor Family Developer's Manual,
Volume 3, figures 6-6 through 6-9, printed pages 6-17/6-18, plus FLDENV and
FRSTOR at printed pages 25-116/117 and 25-129/130. All six complete PDF pages
were visually reviewed, including the field diagrams; the local
[manual](../../../ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf)
SHA-256 is `63c27628292de539eb6ea9089404fe7b5d1fca9d292021a4493dce044e9aa988`.

No translator, arithmetic, ordinary opcode capture, comparator, trace mask,
golden, cycle band, guest fixture or root RTL was changed in this stage.

## Native qualification

The three private executables use the original expanded compile/link commands,
with only the helper object and output executable redirected. Headers,
unchanged objects and thin-archive members are hashed before/after the build.
The original source, objects and pinned executable are read-only. Explicit
`-iquote` retains the helper's original quoted-header lookup; explicit `-L`
retains the firmware search directory when running the relocated executables.

The runner reuses all **192 unchanged cold BIOS images and closed RTL traces**
from `ventium-fp-env.jCGwerGG/store-modes-r1`: protected/real/V86, both input
sizes, both output sizes, FLDENV/FRSTOR, FNSTENV/FNSAVE, offsets 0/1/63/4090.
Each private binary executes every image natively and through the GDB producer.

| Variant | Native result | Complete trace result |
| --- | --- | --- |
| Unmodified helper control | 192 expected pointer-check failures, exit 135 | All 192 record sequences identical to the original pinned-QEMU traces |
| Corrected helper | 192 successful self-check exits, 133 | 192/192 compare against closed RTL traces; 26,624 candidate records |
| Deliberately wrong V86 format | 16 expected failures; other 176 pass | Detects every V86 32-bit-input/32-bit-output case, across both load/store choices and all offsets |

The traces retain every instruction and use the unchanged system functional
comparator. They have **`sys=true`, `x87=false`**: guest integer readback checks
the stored FP-pointer fields, not direct per-instruction x87-register tracing.
These tests do not prove every internal FP field, every reserved bit, paging
fault behavior, or nonzero FOP. Crossing address 4096 with paging disabled is
not a page-fault test. This distinction also applies to the preceding RTL
pointer corpus; no x87 trace fields were removed to obtain these results.

Build R4 closed in **20.60 seconds**. Its actual default guarded scope peaked
at **447,762,432 bytes**, recorded swap peak zero. Cases R2 closed in
**51.38 seconds**, peak **224,997,376 bytes**, four workers with actual native
QEMU affinity observed on CPU pairs 8-9/10-11/12-13/14-15. Each invocation is
bounded to 20 seconds; the overall service is capped at 600 seconds and 2 GiB,
without swap. Both native owners are terminal with MainPID 0 / exit 0.

The independent read-only `audit.py` passes: **12,945 pins rehashed**, **576
complete comparisons rerun**, **1,152 native affinity receipts** inspected,
matched helper-only links checked, and inner build-scope/outer service lifetimes
joined against the journal. It also requires the exact 192-case cross-product
and the precise 16-case mutant failure set. One recipe unit test passes.

## Evidence and reproduction

Evidence root: `/home/yukidama/external/tmp/ventium-qemu-env.oo7IGAh3`.

| Artifact | SHA-256 |
| --- | --- |
| Original helper source | `efb0daf00682ed65488b6ee606a409da7d84f1bb6c118d1bdbc8d27ead37c4e6` |
| Unchanged canonical QEMU | `b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd` |
| R4 corrected helper source | `d02dd5e66350ed8482b8ccf8252e3e2d80708dff096f7695cff2535c3e056305` |
| R4 control executable | `a05dab566c1b644cce8ec76a5a4cb506d7b07b1bb9ec4589a63a1bcfb38d6ab5` |
| R4 corrected executable | `f09369f734347c6ca0baf73b3edac8218c482b2fc1cd33c31b3e6672b7e51202` |
| R4 wrong-mode executable | `f6cb56ce620a1d9e8948748914384933c5c7c980062d03b8882545510d682a8d` |
| `build-r4/closed.json` | `29bbf28096e49c4599cdd93f22e8c3f9a450849e940a1b65a959979e52b39149` |
| `cases-r2/closed.json` | `a9d7d9b3f86b231aa87e68e1b5c5003f493d9f9351d70c2f6fb72dfc950f231d` |

Build service: `ventium-qemu-env-build-oct13-r4.service`, outer invocation
`24b4185f8dab47c5a4804a3908402d16`, inner guarded scope invocation
`daaee430d2e545e2bda3d19641099bdd`. Cases service:
`ventium-qemu-env-cases-oct13-r2.service`, invocation
`e2e10779ff3e45dc84cac2e4600ea66d`.

- `build.py --out FRESH_ROOT`: run through `tools/build_scope.sh` in a bounded
  user service, explicit CPU8-15 `taskset`, external `TMPDIR`, no bytecode.
  It reads Ninja's command database; it does not invoke a canonical Ninja build.
- `run.py --build CLOSED_BUILD --witness CLOSED_RTL_MODES --out FRESH_ROOT`:
  bounded user service, CPU8-15, external `TMPDIR`, no bytecode. Firmware,
  BIOS images, traces, model identities and tool sources must still match pins.
- `audit.py --root EVIDENCE_ROOT`: read-only audit of the named R4/R2 closures.
- `test_prepare.py`: set `QEMU_FP_HELPER` to the unchanged pinned helper source.

All scripts refuse optimized Python (`-O`) where runtime safety assertions are
used. The light helper relink admits above 4 GiB + 512 MiB free; each subsequent
variant and the test driver require 4 GiB + 128 MiB. This does not relax the
separate greater-than-5-GiB admission for heavy Verilator builds.

## Failed attempts and limits

Build R1 stopped before compilation because the service PATH lacked Ninja.
R2 failed dependency scanning because relocated source lost `tcg-cpu.h` lookup.
R3 compiled successfully but its helper mistakenly tested the VM bit in
`hflags`. Cases R1 retained **176 completed cases / 16 errors**, native failure,
without altering expected values. R4 fixes the runtime mode source; Cases R2
above reruns the complete unchanged matrix. The former driver/recipe copies
and failed outputs remain under their original run names. The final auditor's
initial scope-name and output-stream API mistakes were corrected before its
successful read-only audit; they did not rerun or modify native evidence.

Two closed `store-core-r1` precompiled-header caches were removed after a
byte-verified recoverable archive, approximately **160 MB net freed**. Archive:
`/home/yukidama/external/tmp/ventium-fp-env.jCGwerGG/store-core-r1-pch.tar.gz`,
SHA-256 `7eb0a0d488ef0c4848141431c20894cb529efbf1ba415e515cb104b25c571c2d`.
Its two relative paths restore under that `ventium-fp-env.jCGwerGG` root.
No model, source, media, dependency file or run evidence was removed.

Still unqualified: nonzero FOP, ordinary FP opcode capture, loaded pending
exception recomputation, FNSTENV exception masking, environment operand faults,
and FRSTOR faults after environment commit but before all eight register loads.
The wrong-mode mutant qualifies this **private QEMU** mode selection; it is
not the still-open equivalent native RTL mutation test. Separate pre-exit/C1/
remainder reference repairs and canonical cycle failures are not resolved by
this helper change. No oracle has been promoted or silently substituted.

No new synthesis, implementation, FPGA programming or gameplay run occurred.
The latest earlier endpoint/SMSW unplaced estimate is **35.057 MHz**, below
40 MHz; the later RTL candidate has no timing result. Full standard-suite and
physical UV-fast Win95/Quake validation remain open. Candidate gameplay IPC is
**unmeasured**. Older verified simulation baseline: **0.51030715 total U+V**,
build `2b4d7a48`, cycles **1,200,065,237-1,300,065,237**; predates the candidate,
not FPGA/Doom IPC. No performance gain is claimed for this reference repair.
