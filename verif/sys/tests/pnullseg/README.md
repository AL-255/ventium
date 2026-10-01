# Strict null-data-segment witness

`pnullseg` requires a **frozen TB compiled with `VEN_SEG_ENFORCE`**. It is an
Intel-spec witness, not a QEMU differential test. Intel's January1997
IA-32 SDM Vol2, order243191-001, MOV pp.3-287/3-289 (PDF317/319), permits
loading selectors0–3 into DS/ES/FS/GS but requires subsequent data access to
raise `#GP(0)` without a memory reference. The pinned QEMU8.2.2 softmmu does
not perform that per-access null-segment validation; its permissive execution
cannot serve as the oracle or justify changing RTL/masking the differential.

## Coverage and grading

The four sites are DS0 read/write and ES3 read/write. The handlers use valid
SS for every memory reference, check exact saved EIP/error0/CS, all8 GPRs,
originalESP, defined EFLAGS except the fault-image RF bit, visible DS/ES, and
unchanged target plus both neighbors. On return the fixture rechecks live
GPRs/flags and memory. RF is excluded only from this exception-image witness,
not from the global differential mask. There are six legal controls: explicit
SS and defaultSS/EBP read+write with DSnull, and ordinaryDS read+write with
ESnull. Nonpresent poisonGDT[0] makes an accidental descriptor qualification
fail. No paging, task switching, OS, replay, or application special cases exist.
At present the four cases cover moffs and one ModRM load; they are not an
exhaustive encoding/width/segment-prefix matrix.

`make -C verif/sys/tests/pnullseg` builds exactly64KiB only; it launches neither
model nor QEMU. A bounded **prebuilt** TB run uses
`--cosim --image pnullseg.bin --out ... --max-insn 1200 --quiesce 400
+ven_faultlog`. `--cosim` enables the existing ordinary I/O service so OUTF4
reaps with status85 (`AL42`); plain `--system` on the frozen direct TB would
not provide that debug-exit closure. No disk or Win95 input is required.

The closed grader requires return85, a genuine debug-exit stop and matching
complete retirement footer, all four exact faultPCs, zero additional faults,
four validated delivery-marker/adjacent-handler pairs, and every final
manifest witness. It rejects capped/quiescent/fatal/incomplete traces.

The current DPI stream deliberately emits a fault-delivery record at the
original fault PC (`core_int_deliver.svh`, `q_pc <= int_src_pc` followed by
`retire_valid <= 1`). Its presence is **not** proof that the null memory
instruction committed. The grader requires exactly one such event per fault,
in the same order as the four exact #GP(0) log entries, immediately followed
by the handler's POST-PUSHAL record. Both records must retain every staged
non-ESP GPR, defined EFLAGS, and all visible segment selectors. ESP must be
8FFF0 after the same-CPL exception frame and 8FFD0 after PUSHAL. The assembly
still independently checks the saved original EIP/error/frame, untouched
target/neighbors and post-IRET live state; none of those no-effect checks are
relaxed. Footer/trace counts are labelled **legacy reported retires** and
include four delivery events, not only instruction commits. This change is
local grading/documentation only: no RTL or global trace/flags mask changes.

`check_witness.py --help` lists the evidence inputs. Its expected TB and
Verilator compile-record hashes must come from the reviewed frozen-build
receipt; it checks their colocation and actual `+define+VEN_SEG_ENFORCE`
command. Environment variables are not proof of the binary's compile profile.
Colocation/hashes supplement, not replace, source/binary closure provenance.
`python3 -m unittest discover -s verif/sys/tests/pnullseg -p test_check_witness.py`
tests only the host grader, not the CPU.

## Relationship to all five pselnull cases

This new narrow witness must not replace the existing five-case selector test:

| Case | Obligation retained in pselnull |
| --- | --- |
| B | TI1/index0 selector0004 is valid LDTentry0; far JMP succeeds. |
| C | OOB LDT selector0006 delivers GP0004, preservingTI. |
| D | Incoming taskLDTR0004 delivers TS0004; outgoing-context ESP and unchanged TSS busy bytes remain individually graded. Existing QEMU task-switch ordering gap remains explicit. |
| A | NullDS load completes with visibleDS0 and no descriptor read/PF although poisonGDT[0] is on a nonpresent page. |
| E | Paged task switch with incoming nullDS/nullLDTR completes with visibleDS0 and no descriptor read/PF. |

The preferred universal integration makes A/E sentinel accesses SS-qualified,
checks visibleDS0, and retains B/C/D verbatim. It is legal with enforcement on
or off and needs no define-driven substitution. `pnullseg` then supplies the
missing precise null-use faults. LegalSS accesses do **not** prove a hidden
nullDS base of0; that former claim must be retired or checked by a separately
qualified passive hidden-state assertion. An explicit `LEGACY_NULL_USE`
assembly/build variant may retain the historical unenforced poison-base probe,
but must never count as the architectural standard gate. Existing golden-cache
entries must be regenerated from the changed BIOS hash, never silently reused.

Before the adaptation, selecting the correct test by build profile would need
the actual frozen executable plus hashed compile metadata—not
`VL_EXTRA_DEFINES` in the runner's current environment. The universal legal
adaptation avoids that hazard for pselnull. The strict pnullseg witness still
requires an actually enforced profile and fails closed if accesses do not fault.

Status (October1): exact64KiB host build and22 host grader tests PASS. Fresh
`run-pnullseg-gate.sh` evidence in
`verif/tb/obj_dir_bitmem_sep30.aUqHZB/pnullseg-oct01.2/` qualifies all four
GP0/no-effect cases and six legal controls on frozen TB `6aeaff4b…` with
compile record `33648668…`: actual debug-exit status85, 481 legacy reported
records in4548 clocks, complete footer and unchanged input/source hashes.
The preceding `.1` attempt is preserved: the CPU passed its in-image checks,
but the original host checker incorrectly treated legacy delivery events as
null-instruction commits. The corrected checker now validates those events
explicitly; no RTL or global comparison mask changed. Neither witness run
counts as Windows desktop or Quake timedemo acceptance.
