# Obsolete x87 no-ops: isolated repair and cold witnesses

October 13, 2026. **An isolated repair is implemented and tested, but not
promoted or deployed. The canonical and full-state differential gates remain
red.** The LMSW-repaired cold Doom simulation raises #UD at `24C7:0243` on
`DB E4` (FSETPM). This is separate from the existing FPGA's earlier memory-SMSW
fault. Neither failure provides FPS. A new bounded cold full-PC diagnostic is
described below; it does not alter the installed bitstream.

## Required semantics and repair

Local Intel manual:
`ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf`,
section **23.3.6**, printed **23-38**, PDF **599**. The complete page was
extracted and visually checked using the PDF skill. It explicitly distinguishes
FENI (`DB E0`), FDISI (`DB E1`) and FSETPM (`DB E4`) from FNOP:

- Preserve #NM checks for CR0.EM/TS.
- Do not test pending unmasked FP exceptions as FNOP does.
- Do not change internal FP state.

The pinned QEMU translator recognizes all three, but that alone is not an
oracle for every FP environment field: its common instruction-pointer update
also needs checking before full-state comparisons are trusted.

Implemented in `prepare_repaired.py`: recognize exactly the three register encodings,
retain the x87 #NM classification, and retire them through the ordinary
no-write completion path after #NM checks but before waiting-FP dispatch.
Do not issue a shared-FPU command or rewrite FP state. Keep LOCK/prefix,
instruction-fetch, debug and retirement checks intact. Do not replace guest
bytes, change the extender or disable U/V and fast pipeline.

Exactly two generated RTL files change: `decode_stages.sv` recognizes the
three forms as x87 `FX_NONE`; `core_fetch_decode.svh` sends that classification
to the existing no-write `S_EXEC` completion after #NM and before #MF/shared-FP
dispatch. Other unknown x87 encodings clear `d_is_x87`, so they do not take
this path. Normal retirement/debug handling remains in charge. There is no
new port, FSM, feature flag, FP command, guest-address check or mode fallback.
The recipe rejects source drift and reapplication. Root checkout RTL is not
modified by this isolated experiment.

Before acceptance, still add WAIT-prefixed variants, CPL1–3/V86, page-boundary
fetch, debug/interrupt cases and native negative mutants. Pending exceptions,
full-state preservation, FNOP/#MF controls, LOCK and protected CPL0 now have
the explicit results below. Require green canonical gates, the complete
standard suite and hardware qualification; no disagreement is waived.

## Closed initial witness

`probe.S` cold-boots real mode. It tests each opcode with/without `66`, and
EM/TS clear, EM set, TS set or both. The #NM handler checks the original fault
PC, CS and CR0, then clears EM/TS and skips the instruction. Postconditions
check defined flags, selected GPRs, CR0, #NM count and FP status/TOP after FLD1.
Eight FNOP cases validate the fixture; no pending FP exception is seeded.

On LMSW model
`fddb1fd3f7b677c44ddcc320808a9b756e45adc38718ff4d08b1dedb94d6b52b`:

| Cases | Pinned QEMU native | RTL native |
| --- | --- | --- |
| 6 obsolete-op cases, EM/TS clear | All exit 133 (self-check success) | All #UD, intentional failure exit 135 |
| 18 obsolete-op cases, EM or TS set | All exit 133 | All expected #NM, exit 133 |
| 8 FNOP controls | All exit 133 | All exit 133; 6 expected #NM |

The existing **early-fetch #NM check** explains the second row; it does not
mean the semantic decoder implements these opcodes. The runner reports success
only because it expects the six missing-instruction failures. These are native
self-checks, **not complete QEMU differential traces**, and not gameplay/paired
execution or standard-suite acceptance. All 32 RTL fault-vector observations
were independently checked from retained native logs.

Evidence root:
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/obsolete-fp-missing-r3`.
Owner `ventium-obsolete-fp-missing-oct13-r3.service`, invocation
`3ba57e67bf2841a19448876d683c8e9d`, terminal exit 0 / MainPID 0.
Runtime **3.56 seconds**, taskset CPUs14–15, 512 MiB / no swap / 180-second cap.
Closure SHA-256:
`3d98f97a79187f15350bde1544d5e90a1048bac72823a938470f044ca0af3b70`.
The earlier r1 launch failed before running the script due to a relative path.
r2 rejected its third case because the initial driver incorrectly expected
#UD even with EM set; the expectation was corrected to preserve the already
working early #NM behavior. Neither failed attempt is a passing qualification.

## Repaired-core results

All roots in this section are below
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
Parent `segment-extent-core-r1` model:
`d039f5db76c653b249826d446dd5eab8ef9ac4d73243af6818a22cb26e4383c5`.
New `obsolete-fp-core-r1` model:
`2fc497047dc64848f28a920522a6fa4ec1e8ef0c686179394576d6237402acb2`.
The source ledger checks **195 files, exactly two changes and 152 unchanged
UV-fast defines**. The private host was compiled against its own generated
header; the native build closed in **20.66 seconds**, with 32 jobs and a
10 GiB memory / 2 GiB swap cap. No Vivado ran.

| Test root | Result | Qualification limits |
| --- | --- | --- |
| `obsolete-fp-basic-r1` | **32/32 RTL self-checks and full QEMU differential cases**, 1,912 records, 3.20 s | Original immutable real-mode images: 24 obsolete-op / EM / TS / `66` cases and eight FNOP controls |
| `obsolete-fp-state-r1` | **0/24 self-check passes on both engines**, 2,362 RTL records | Original `state.S` exposes an existing save/restore pointer defect even with an integer NOP; retained as failed evidence |
| `obsolete-fp-state-r2` | **24/24 RTL self-checks; only 6/24 full differential passes**, 3,490 RTL records, 2.73 s | `state2.S` uses non-destructive setup; 12 obsolete-op pointer discrepancies and six LOCK discrepancies remain failures |
| `obsolete-fp-core-r1` canonical verify | **7 PASS / 101 FAIL**, native make exit 2, 405.40 s | All 20 complete cycle traces identical to the parent; gate remains red |
| `obsolete-fp-replay-r1` | **108/108 same-input parent/candidate replays**, 80,800 identical complete architectural records, 77.60 s | Regression evidence, not a replacement for the canonical QEMU gate |

Basic + corrected-state tests therefore provide **56 RTL self-checks and 38
full differential passes over 5,402 RTL records**, not 56 differential passes.
Neither the failed first state fixture nor the 18 discrepant second-fixture
cases are counted as differential success. All native owners are terminal and
all retained pins/artifacts were rechecked. The four-worker test runner uses
observed child taskset affinity on CPUs8–15, 2 GiB memory and no swap. It passes
`--cycle-func --l1-axi`, AXI read/write latency 7, and uses complete system
traces via the existing trace formatter and comparator. It does not request
per-retirement x87 trace fields: FP state is checked by the guest's complete
108-byte comparison. None of this is a gameplay or pairing measurement.

### Full-state fixture and reference gaps

`state.S` fills all eight FP stack slots, FNSAVEs the image, FRSTORs it, executes
the probe, then FNSAVEs and compares all 108 bytes. Even its integer-NOP control
fails at the saved FP instruction pointer (image offset 12). Both the frozen
RTL and pinned QEMU omit instruction/data-pointer restoration in FLDENV and
FRSTOR. Thus the original fixture cannot isolate an obsolete-op failure.
This is an **open general environment-restore defect**, not grounds to drop
the pointer comparison. See [source diagnosis and proposed fix](FP_ENV_RESTORE_GAP.md).

`state2.S` instead FNSTENVs the live environment and constructs the expected
80-byte register image from exact FLD constants. FLDENV seeds control/status
with the same existing pointers, without requiring arbitrary pointer restore.
It still compares **every one of the 108 saved bytes**, including pointers,
and checks flags, GPRs, exact fault PCs and exception counts. It includes
unmasked pending IE with CR0.NE set, with/without `66`, integer-NOP controls,
FNOP controls requiring #MF, and LOCK forms requiring #UD.

Pinned QEMU leaves `update_fip=true` for DB E0/E1/E4, changing FPIP after these
obsolete controls; this contradicts the cited no-state-change requirement and
causes 12 fixture failures. It also accepts six LOCK forms that RTL rejects.
The four integer-NOP and two FNOP controls pass both engines and compare in
full. `run_state2.py` changes only the fixture source path used by the original
runner; native exit, faults, all saved bytes and full-trace comparisons remain
mandatory. The driver exits **1**, not a fabricated pass. Pinned QEMU, masks,
goldens, cycle bands and backends were not changed.

### Native receipts

Each row identifies a terminal user service invocation and SHA-256 of its
closure receipt (`build-closed.json`, `verify-closed.json` or `closed.json`).

| Service suffix (`ventium-…`) | Invocation | Closure SHA-256 |
| --- | --- | --- |
| `obsolete-fp-core-oct13-r1.service` | `163608d1fbe54efd8b97a54fb5d805cc` | `544866a191dfe14cc06b60143bdadde919fad26ad3a911a2630aa738de20dfff` |
| `obsolete-fp-basic-oct13-r1.service` | `71c46e22a3c44a19b4388b9afd6326f1` | `9cb902facf84e10e3597b8ec94573db44f7cbaf420eadba81818d5f6ace9bf8a` |
| `obsolete-fp-state-oct13-r1.service` | `2118cd95734d43d69514c0baa92c632a` | `29af242e16f518369d8d8d999dd3d89608c8ec9961dc91d2388cac4f1748b6aa` |
| `obsolete-fp-state-oct13-r2.service` | `41d52deb98d14379a71f3acba6887a3b` | `ac8d8f2779f734bd3df44d8a8c6b8798f77c01029ae048ca2e053f9089d9d732` |
| `obsolete-fp-verify-oct13-r1.service` | `bbe31d24e609457384258ead7faefd54` | `fc4b16918814cc2958caaf17eaecca6556d42b6247b9bd19c67437f5ecdf517a` |
| `obsolete-fp-replay-oct13-r1.service` | `e63ab610e42b4b6c9220a9266851aacb` | `ef8948f66f5344270073aed05b366341b504e6425a87e2b3e6ca5a887b5d8ebd` |

## Full-PC transfer and cold diagnostic

`fpga/build_obsolete_fp_soc.py` transfers the two-file opcode repair plus the
[segment-extent rewrite](../../segment_extent/README.md) onto `lmsw-soc-r1`.
It checks all **102 shared RTL sources**, exactly three changes, **156 unchanged
full-PC defines**, `cycle_mode=1` and posted-16 transport. The verified private
host/header build closed in **23.02 seconds**. Its successful native exit does
not waive the existing 98 platform structural warnings or failed gates.

Root `obsolete-fp-soc-r1`, model
`f0b7197c7b1becc3043f18ffe650c4956152ae8a20fc7397f9213f55ebdd5d98`;
owner `ventium-obsolete-fp-soc-oct13-r1.service`, invocation
`03518eebf8394932823e28a117b2a61b`, terminal exit 0 / MainPID 0.
Build closure SHA-256:
`895baba1775790eba1e99cb689ad6c4c2f6ae9410553e53aa544c5db1e936e57`.

The original-media, cold-boot Doom diagnostic is `obsolete-fp-doom-r1`, owner
`ventium-obsolete-fp-doom-smoke-oct13-r1.service`, invocation
`cd547ef7cf6640dcacfe6158519a2ae1`. It is capped at 50 million cycles / 900
seconds, CPU12 (actual simulator affinity checked), 512 MiB/no swap, and a
4 GiB disk reserve. Fault history is passive and bounded. There is no snapshot,
STEP, breakpoint, guest patch, new bitstream or FPGA-clock change. This entry
records its launch, **not completion or FPS**; see the
[Doom result log](../../../docs/FPGA_DOOM_2026-10-13.md) for closure.

## Recoverable scratch cleanup

Only 12 precompiled-header caches from closed builds were removed after
byte-verifying these archives under the evidence root. Models, sources,
dependency files, media and logs remain. Each archive restores with
`tar -xzf ARCHIVE -C EVIDENCE_ROOT`; it is not needed to execute retained models.

| Archive | Members | SHA-256 |
| --- | --- | --- |
| `segment-extent-closed-pch-oct13.tar.gz` | 2 extent core PCHs | `38214ca1177a7ce061dd1abbf02d2cca635bfc8c506406930c35a18b6240ee46` |
| `obsolete-fp-closed-pch-oct13.tar.gz` | 2 repaired core PCHs | `9c6ed7979800f7c9ed37e06fddccb27d19a5c58816a935ce57b0fdd9eada7a8d` |
| `endpoint-soc-closed-pch-oct13.tar.gz` | 2 endpoint full-PC PCHs | `fb27b539e01aff9973a3a5922bdacba36b134752d7198bc2203f597c1e50b1c1` |
| `extent-leaf-closed-pch-oct13.tar.gz` | 6 positive/mutant leaf PCHs | `3a47f35a1e32dad4799d5104f5f733a1daf304f2e2cefbd479642ea57dc7cffb` |

Candidate gameplay IPC: **unmeasured**. Older simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. Predates the candidate; not FPGA/Doom IPC.
