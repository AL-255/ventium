# Memory SMSW: Doom startup regression

Status: **failure reproduced; repair recipe unpromoted and not yet compiled**.
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
simulation or proof of behavioral correctness**. The new decoder/datapath has
not been compiled, synthesized, promoted or programmed on the FPGA. Preparation
was kept separate from the running 40 MHz timing experiment.

## Required next gates

- Compile the isolated derivative, then run these same native probes; every
  memory case must succeed, not just the ordinary-MOV controls.
- QEMU-differential traces; CPL3/V86, segment overrides/default SS, invalid LOCK,
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
