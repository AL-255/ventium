# LMSW: next Doom startup blocker

October 13, 2026. **Reproduced, not repaired.** The passive cold full-PC replay
of the SMSW + endpoint-map candidate captures #UD on `LMSW AX` (`0F 01 F0`),
at `24C7:032A` / linear `0x24F9A`, cycle **32,709,048**, after retire
**4,134,037**. The fetched buffer is `0f01f0ea...`, AX is `0x0011`, CR0 is
`0x10`, and IF is clear. The decoder explicitly sends `/6 LMSW` to `d_unknown`.
This is a general missing instruction, not a Doom-specific quirk.

After that captured fault, further exceptions lead to a HLT at `16F0:DAF0`,
cycle 32,731,255. The 34-million-cycle passive replay and 100-million-cycle
smoke stop at identical 4,135,554 retirements. Both guest startups fail despite
native exit zero. Further exception-handling or startup defects are not excluded.
The physical old bitstream still fails earlier on memory SMSW; it has not been
replaced. **No Doom FPS exists.**

## Cold directed witness

`probe.S` / `probe.ld` boot from reset and install deliberate #UD failure
handlers. Register or m16 LMSW is tested with/without the operand-size prefix,
with two source patterns. Initial LMSW must set PE while preserving high CR0
bits; the protected-mode continuation must change MP/EM/TS but cannot clear PE.
The memory operand straddles `0x4fff/0x5000`, with paging off. Checks include
defined flags after mode entry, source registers, CR0 and the read-only operand.
MOV-CR variants validate the fixture; they are **not LMSW passes**.

Pinned QEMU system binary
`b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd`
passes all **16** cases (guest success exit 133). On endpoint core
`164e17003b2ec03cd7b92cc8bbe89b576e5f440becc4204e37368e075c87e8df`:

- Eight LMSW cases reach the intentional #UD failure exit 135.
- Eight MOV-CR controls pass, exit 133.

The witness runner passes only because it **expects missing LMSW**. It is not
repaired RTL, a complete-trace differential gate, privilege/fault matrix or
suite acceptance. RTL never reaches the sticky-PE continuation in the failing
instruction cases; QEMU validates those fixture assertions. UV-fast is compiled
and the AXI backend explicitly selected, but these serialized cases do not
claim paired gameplay execution.

Run root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI/lmsw-missing-r1`.
Unit `ventium-lmsw-missing-oct13-r1.service`, invocation
`a2b90209f32344d2b28df19f75dd4822`, is terminal, MainPID 0 / exit 0.
Runtime **1.63 seconds**, peak **39,878,656 bytes**, CPUs14–15, 1 GiB RAM /
no swap / 240-second cap. Input hashes remain unchanged. Closure SHA-256:
`ec7644051e86520add0e58289ba70ee8dd1ef39107b23a8e063b7987683a4a8d`.

The full-PC fault log is `endpoint-map-doom-trace-r1/fault-ring.log`, SHA-256
`1c07c5d7a8d333020aa9d8e1be4b960ef15cc158975a634e3beab8de2ff0ef38`, under the
same parent. Its closure audit checks 17,950 input pins and six artifacts.
The passive replay has no breakpoint, STEP, snapshot save/restore or guest patch.

## Proposed general repair and required tests

Decode `/6` register and memory forms as a distinct LMSW marker on the existing
serialized CR0 path. Memory always reads **two bytes**, independently of
operand size; register sourcing uses the low word. Candidate CR0 value:

```text
(old_cr0 & ~0xF) | (source & 0xF) | (old_cr0 & 1)
```

Preserve existing CR0 commit, MMU/TLB, fetch and mode-transition side effects.
Do not add a second unconstrained CR0 writer or bypass memory faults. Keep CPL0
checks, V86/LOCK rejection and precise original-instruction restart. An
unrestricted MOV-CR alias would incorrectly change high bits or clear PE.

Before promotion, add complete-trace differential cases for real/PM entry,
sticky PE, all low-bit combinations and registers, memory addressing/prefixes,
CPL1–3/V86, segment/page-crossing faults, repair/retry, interrupt boundaries and
unchanged MOV-CR/CLTS/SMSW controls. Then run canonical gates, cold Doom, the
standard suite and physical UV-fast Win95/Quake/Doom validation. No app patches
or mode fallback.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates the candidate and is not FPGA/Doom
IPC. Synthesized/unplaced estimate is **35.056967572 MHz**, below 40 MHz.
