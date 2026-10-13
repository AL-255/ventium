# LMSW: next Doom startup blocker

October 13, 2026. **Isolated repair tested, not promoted or deployed.** The
original missing-instruction witness below remains immutable. The passive cold full-PC replay
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

## Isolated general repair

`prepare_lmsw.py` now decodes `/6` register and memory forms as a distinct LMSW marker on the existing
serialized CR0 path. Memory always reads **two bytes**, independently of
operand size; register sourcing uses the low word. Candidate CR0 value:

```text
(old_cr0 & ~0xF) | (source & 0xF) | (old_cr0 & 1)
```

It preserves the existing CR0 commit, MMU/TLB, fetch and mode-transition side
effects. Memory forms enter the normal `S_LOAD` path and use its completed,
merged value before `S_EXEC`; register forms add no state. There is no second
CR0 writer, new FSM state, workload special case or global fast-pipe fallback.
CPL0 checks and existing LOCK/segment/page rejection remain in force. The
passive CR0 transition/TLB observers now use the same actual value as commit,
including CLTS. An unrestricted MOV-CR alias would incorrectly change high
bits or clear PE.

The semantics were checked against the local Intel Pentium Volume 3 manual,
PDF page 831 / printed 25-214, and pinned QEMU's LMSW translation. The LOCK
instruction list on printed 25-215 excludes LMSW. The test fixtures separately
exercise Intel-spec denial behavior; QEMU disagreements are retained, not
masked or counted as differential passes.

The private build has exactly five changed files out of the parent's 195-file
closure: `core.sv`, `decode_stages.sv`, `core_refdecode_latch.svh`,
`core_fetch_decode.svh`, `core_exec.svh`. All 152 UV-fast definitions and the
explicit AXI backend are retained; model-dependent host C++ is compiled
privately against the matching generated header. Root RTL and the installed
FPGA image are untouched. No new Fmax, CoreMark score or gameplay result exists
for this LMSW derivative.

## Closed qualification, 14:10 UTC

| Check | Result | Limitation |
| --- | --- | --- |
| Source contracts | 3 methods pass | Not native RTL correctness |
| Original cold witnesses + MOV-CR controls | 16/16 native successes and complete QEMU system traces match | Includes 8 controls, not 16 distinct LMSW cases |
| CPL1/2/3 and V86 | 32/32 complete-trace differential passes | Register/memory, address/operand prefixes; serialized instructions, not paired gameplay |
| Memory/fault/retry | 44/44 RTL self-checks; **28/44 differential passes** | **16 QEMU disagreements; gate exits 1** |
| Unchanged canonical `make verify` | **7 PASS / 101 FAIL**, make exit 2, 396.70 s | Still red; no masks, goldens or bands changed |
| Canonical cycle comparison | All 20 traces identical to parent | Not a QEMU pass |
| Same-input canonical replay | 108 cases / 80,800 records identical, 77.28 s | Full records, no stack normalization; not a QEMU waiver |

The fault matrix uses nonadjacent physical pages, two-byte operands crossing
page boundaries, read-only mappings with CR0.WP set, first/second-page absence,
and fault repair/retry. Handlers check unchanged pre-fault CR0, GPRs, flags,
original fault PC, error code, CR2 and source memory before repairing anything.
Page success/retry cases are repeated at AXI latencies 0, 7 and 31. A read-only
data segment is a permitted source. The sixteen disagreements are null DS,
segment-limit crossing, and LOCK register/memory cases: RTL delivers the
required exception and reaches success; pinned QEMU reaches the fixture's
failure exit instead. These are not sixteen passing differential tests.

In total, **92 directed case executions pass RTL self-checks**, of which
**76 pass full QEMU comparison**, spanning **11,248 RTL records**. This does not
qualify the full fault matrix, canonical gate or standard suite. IRQ/NMI/debug
boundaries, all source registers/low-bit patterns, wider addressing/segment
corners, negative mutants and post-LMSW full-PC startup remain open.

Evidence is under
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`:
`lmsw-core-r1`, `lmsw-diff-r1`, `lmsw-fault-r1`, `lmsw-privilege-r1`,
`lmsw-replay-r1`. All six owner services are terminal with MainPID 0; the fault
and canonical owners correctly retain exit 1, not success. The 32-job compile
completed in **20.41 s** inside the exclusive 10 GiB RAM / 2 GiB swap scope;
directed runs used bounded four-worker or two-CPU native execution. No Vivado
run was launched.

- Model SHA-256: `fddb1fd3f7b677c44ddcc320808a9b756e45adc38718ff4d08b1dedb94d6b52b`.
- Independent closure audit: `lmsw-audit-r1.json`, SHA-256
  `fd3e80dab02e36d857ba8601db19bd44df05850310fa422d22b05671117134eb`.
- `audit_repaired.py` rechecks the entire source delta, retained input/artifact
  hashes, terminal owner identities, test counts and exact canonical replays.
  Its success does **not** change either failing gate to a pass.

## Still required before promotion

Resolve the reference/RTL differential failures without weakening checks;
complete the missing corners above and unchanged MOV-CR/CLTS/SMSW controls.
Update opcode coverage when promoting the decoder, then run green canonical
gates, cold Doom, the standard suite and physical UV-fast Win95/Quake/Doom
validation. No app patches or mode fallback. This candidate has not been
transferred into the full-PC model or a new FPGA source freeze yet.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates the candidate and is not FPGA/Doom
IPC. The **pre-LMSW parent** synthesized/unplaced estimate is
**35.056967572 MHz**, below 40 MHz; the LMSW derivative is not synthesized.
