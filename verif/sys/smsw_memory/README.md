# Memory SMSW: Doom startup regression

Status: **isolated repair compiled; 88 initial full-trace differential cases
pass. Unpromoted; privilege/fault and standard-suite qualification remain open**.
The physical-board finding is in
[FPGA_DOOM_2026-10-13.md](../../../docs/FPGA_DOOM_2026-10-13.md).
No guest patch, saved state, replacement DOS extender or U-only mode is used.

## Closed first-stage witnesses

`run_probe.py` cold-boots 80 SMSW cases plus eight ordinary-MOV controls:

- Real mode and protected CPL0; effective 16/32-bit address and operand sizes.
- Zero and nonzero DS bases, 16-bit BX+SI and 32-bit SIB addressing.
- Destination offsets 0, 1, 3, 31 and 4095: aligned, unaligned, dword, line
  and page-boundary spans. **Paging is off**, so this is not a page-fault test.
- Self-checks for the exact two-byte result, adjacent canaries, every GPR,
  preserved defined flags and unchanged register-form SMSW behavior.

Pinned QEMU `-cpu pentium` passes all 88. The unmodified PRIME-CS UV-fast core
rejects all 80 memory forms with exactly one #UD at the tested PC; all eight MOV
controls pass. The native run closed normally in 11.916 seconds. This is a
**missing-opcode regression/control result**, not repaired-RTL acceptance or a
QEMU differential trace pass. `--cycle-func --l1-axi` and delayed AXI responses
are explicit; the failing short probes do not establish actual V retirement.

Evidence: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/smsw-missing-r1`.
Owner: `ventium-smsw-missing-oct13-r1.service`, invocation
`366d1d792974416bbb724cebc5526c7c`; terminal MainPID 0 / exit 0.
Model SHA-256:
`73f6f9dbd0ca16640456304a01453a8bfd5c28a98fa0c9ec5548a9d1fdd61dca`.
`audit_probe.py` checks the exact emitted instruction bytes, fault vector/PC,
native closure, source/model pins and all 88 outcomes; `audit.json` records
hashes of the complete artifacts. Do not rerun the exclusive auditor in place.

## Proposed implementation

`prepare.py` rejects source drift/reapplication and transforms only three files
from the frozen PRIME-CS source. It does not modify those frozen inputs or the
checkout's dirty RTL in place:

1. Decode every legal `0F 01 /4` memory form as a two-byte write, independent
   of operand size. Preserve register forms and the unprivileged SMSW marker.
2. Dispatch memory SMSW directly to existing `S_STORE`. Do not use `S_EXEC`:
   its `SYS_MOVCR_FROM` arm writes a GPR unconditionally.
3. Supply `CR0[15:0]` to the existing store-data mux. Keep segment checks,
   translation, page-crossing preflight, ACK ownership, flags and retirement
   handling in the ordinary store path.

There is no new state, register, profile switch, ISA shortcut or workload check.
Three source-contract tests pass (`test_prepare.py`); these are **not RTL
simulation or proof of behavioral correctness**. Preparation/build remain
separate from the 40 MHz timing experiment, whose frozen inputs are unchanged.

## Isolated native result

`build_core.py` retains all 195 parent source files / 152 UV-fast definitions,
assertions and a uniquely compiled model-dependent host. Only the three named
RTL files change. Compilation closes native exit 0 / unchanged pins in
19.763 seconds with 32 jobs; the scope journal records a 3 GiB memory peak.
The resource cap was lowered to 10 GiB RAM / 2 GiB swap, below the standard
32-job ceiling. No Vivado family was active during compilation.

Model: `smsw-core-r1/obj/tb_ventium`, SHA-256
`cbf749f16babd88fb5dcf508c2381d48b77dedd348e9b23a5ed9083de9f4e65e`.
`run_diff.py` uses the unchanged QEMU system producer and comparator: all
**88 cases / 6,556 complete architectural records match**, including CRs,
selectors, GPRs and flags. No record trimming, extra masks or band changes.
Every repaired guest also exits with the independent success marker 0x42;
there are no fault deliveries. Native QEMU/RTL child affinity is observed as
CPUs 0–1, not inferred solely from a unit property.

Goldens: `smsw-golden-r2`; checks: `smsw-diff-r1`, under the same evidence
parent above. Both controllers naturally close exit 0 / MainPID 0.
`audit_diff.py` independently validates closure, the separate build-controller
and native-scope identities, exact three-file transformation and every full
trace comparison. Audit SHA-256:
`b2dcb434a336f655330994bd8f3082185e54d20b3879a0562ecac56d63f6ad52`.

The unchanged canonical `make verify` **closed red** in 405.562 seconds:
7 functional passes / 101 failures, native make exit 2. These include the
existing terminal-record and x87 status divergences; none is waived by the
directed passes. All 20 cycle traces have identical complete records to PRIME-CS.

To detect regressions hidden by that red gate, `run_regression.py` reruns both
models on each of the candidate's exact 108 inputs and initial stack pointers.
All **108 cases / 80,800 records** match the parent and reproduce the candidate's
original traces. The native controller closed exit 0 / MainPID 0 in 77.719
seconds, with unchanged input pins. Evidence: `smsw-regression-r1`; unit
`ventium-smsw-regression-oct13-r1.service`, invocation
`ec126ae3d4524763ab3c7ca1a76b148b`. The wrapper changes only the historical
replay driver's definition count from 150 to 152; exact definition equality
and every full-record comparison remain enforced. This is **regression
equivalence, not a QEMU correctness pass**.

There is still **no synthesis, checkout promotion, physical-board acceptance
or gameplay measurement for the SMSW derivative**.

## Required next gates

- CPL3/V86, segment overrides/default SS, invalid LOCK,
  null/read-only/limit-failing segments, present/not-present/read-only page
  boundaries, fault PC/CR2/error and absence of partial writes or GPR changes.
- Register controls, store-delay/backpressure and reset/event/debug boundaries;
  actual paired-path witnesses for UV-fast acceptance.
- Update opcode coverage on promotion, keep differential gates green, and run
  the standard suite before declaring completion. Then rerun unmodified Doom
  on a newly qualified FPGA image and obtain an actual completed timedemo.

Current-candidate gameplay IPC is **unmeasured**. The older simulation baseline
is **0.51030715 total U+V**, build `2b4d7a48`, cycles
1,200,065,237–1,300,065,237. This predates the candidate and is not Doom or FPGA IPC.
