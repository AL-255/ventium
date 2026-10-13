# Obsolete x87 no-ops: cold failure witnesses

October 13, 2026. **No repair implemented or deployed here.** The LMSW-repaired
cold Doom simulation raises #UD at `24C7:0243` on `DB E4` (FSETPM). This is
separate from the existing FPGA's earlier memory-SMSW fault. Neither has FPS.

## Required semantics and proposed repair

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

Proposed implementation: recognize exactly the three valid register encodings,
retain the x87 #NM classification, and retire them through the ordinary
no-write completion path after #NM checks but before waiting-FP dispatch.
Do not issue a shared-FPU command or rewrite FP state. Keep LOCK/prefix,
instruction-fetch, debug and retirement checks intact. Do not replace guest
bytes, change the extender or disable U/V and fast pipeline.

Before accepting a repair, add pending-exception and full-state-preservation
tests (including FP instruction/data pointers), FNOP/#MF negative controls,
WAIT-prefixed variants, LOCK, protected/V86/CPL coverage, page-boundary fetch
and debug/interrupt cases. The simple cold witness below does **not** cover
those cases. Then require green canonical gates, standard suite and hardware
qualification; this missing-opcode diagnosis is not permission to waive them.

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

Candidate gameplay IPC: **unmeasured**. Older simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. Predates the candidate; not FPGA/Doom IPC.
