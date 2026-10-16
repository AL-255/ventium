# System read-owner ACK cut — 2026-10-16

Status: implemented in an isolated nine-file RTL derivative and transferred
to a matching full-PC model. Directed, cold-input, short CoreMark and strict
CPU-lint checks pass. Matched synthesis has been submitted; **no completed
synthesis/timing result, routing, deployment or standard-suite acceptance yet.
Canonical `make verify` still fails.** The dirty checkout's RTL and pre-existing
full-PC runs remain untouched.

## Purpose and change

The preceding RAW-storage synthesis estimated only **35.3744 MHz unplaced**
(40 MHz constraint, WNS −3.269 ns), below both the 40 MHz requirement and its
36.9686 MHz parent. Its worst path reaches interrupt-error state through the
general ACK's write/paired-store admission logic. This change removes that
dependency from owners whose actual bus transactions are reads.

`prepare_system_read_ack.py` checks exact predecessor hashes, then changes:

- Twenty read-only descriptor, interrupt, return, query and task-switch states
  to use the existing `mem_read_ack` instead of general `mem_ack`.
- Page-walk PDE/PTE reads (steps 0/2) to read ACK; A/D writes (step 1 and the
  original default arm) retain general ACK. The same split applies to the
  independent TLB-fill driver.
- Matching GPR/ESP/segment commit guards, string-store rollback and diagnostic
  page-fault mirrors, so every architectural effect uses the same edge.

The existing final-fragment qualifier is unchanged. No request authorization,
fault precedence, transaction, clock, latency, queue depth, pairing policy,
fallback, instruction semantics or guest program is changed. Mixed LTR and
write-only states retain their original completion logic. Non-early-ACK builds
retain the original alias `mem_read_ack = mem_ack`.

A nonsynthesis witness checks actual read direction and ACK equality on all
changed owners. Native tests reach those states naturally; they do not force
state, ACK, STEP, breakpoints or snapshots. Source-preservation tests reverse
each transformation and require the original state-machine bodies verbatim.

## Exact models and evidence

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

- Parent directed model: `41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b`
  (`raw-prime-storage-core-r1`).
- Candidate: `005d0f17a3360588d6b67c5f49267db785cb7cc07893ee6a14dc42cafe615aeb`
  (`system-read-ack-core-r1`).
- Exactly 195 source files, nine changes; all 153 ordered defines unchanged.
  Full source/host dependency hashes and the private model-specific harness
  object/header are retained in `build-started.json` / `build-closed.json`.
  32-job build closed successfully in 20.113 seconds.
- `system-read-ack-audit-r1.json` independently replays system comparisons,
  native closure, actual affinity, source hashes and complete state coverage.
- `system-read-ack-canonical-audit-r1.json` checks same-input parent replay and
  preserves the canonical failed verdict.

## Verification

| Check | Result |
|---|---|
| Host source/builder/supervisor contracts | 9 tests pass |
| Native ACK miter, early and fallback profiles | 61,440 combinations each pass |
| Deliberate broken ACK/fragment variants | All 8 fail as required |
| Cold system matrices, AXI delays 0/7/31 | 19 cases, 228 native RTL runs pass |
| Full state and clock equality | 114 parent/candidate trace pairs identical |
| Candidate records checked | 26,667 functional + 26,667 cycle records |
| Actual candidate V retirement | 5,925; U/V fast mode, not STEP or U-only |
| Changed owner coverage | All 20 states plus both page-walk read phases |
| Same-input canonical functional replay | All 108 parent-identical, 80,800 records |
| Canonical cycle traces | All 20 parent-identical, 66,807 records |
| Canonical verdict | FAIL: native make exit 2, controller exit 1 |

The 19 cold fixtures cover segmentation, paging, IDT delivery, cross-privilege
IRET/RETF, TSS stack changes, task CALL/NT return, incoming LDT installation,
V86, I/O permission checks, call-gate parameters, descriptor queries, fragment
faults and nested real-mode INT/IRET. The last fixture is a new generic BIOS
microbenchmark with real IVT/stack accesses and SP/GPR/carry restoration checks.
All functional comparisons use complete QEMU architectural records; no new
flag masks, trace trimming or golden changes.

Both `--cycle-func --l1-axi` and `--cycle --l1-axi` exercise `cycle_mode=1`.
The build retains `VEN_FE_PIPE`, `VEN_SYS_FASTPATH`, relocated fast-path support,
fast load/store defines and dual-issue defines. Native commands and actual
child CPU affinity are retained per run. These are microbenchmark correctness
counts, **not gameplay IPC**.

The canonical run took 392.118 seconds: 7/108 functional cases pass and 101
fail; nine cycle bands fail. Its original failed results remain authoritative.
The parent already has these failures; a fresh same-input parent replay passed
all 108 cases (80,800 complete records) in 55.480 seconds, distinguishing RTL
changes from different QEMU initial stacks.
Directly comparing independently generated functional traces first detected
ESP `0x40800020` versus `0x40800030`, so that comparison was rejected. The
replay uses the candidate's actual flat images and golden-derived initial ESP;
it does not normalize or ignore ESP.

### Fresh private-reference qualification and broader x87 delivery

`system-read-ack-func-r1/audit.json` now independently checks a fresh
**108/108 functional pass**, 80,800 complete records and 30,132 V retirements,
against qualified private reference
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`.
This reference includes separately qualified x87/status and live pre-exit
observation repairs. It is explicitly selected, **not promoted to canonical
QEMU**. The unchanged comparator/worker and existing masks are retained;
105 cases also pass unmasked, while `tx_regform`, `tx_regform2` and `tx_stack`
retain their existing unmasked failures. All executable input images match;
54 ELF differences are solely non-loadable compiler temporary-file metadata.

The retained owner is `ventium-system-read-ack-func-oct16-r1.service`, invocation
`308ed25771dc4c8f9f90f1be75d32ca7`, closed successfully. The auditor checks
12,365 input pins, actual CPU 4–7 affinity, native closure and fresh goldens.
The parent-to-candidate source change is still exactly the original nine files.
Two additional driver/auditor contract tests pass. This does not change the
failed canonical verdict or its nine failed cycle bands.

[Strict waiting-instruction delivery](../srt/STRICT_MF_WAITERS.md) additionally
checks 29 x87 forms using the same candidate: 174/174 candidate runs and
338,730 full records match the immediate parent, including exact clocks.
All 522 native executions, including an explicitly older non-strict diagnostic
control, are retained. Six host contract/grader tests pass. These are directed
architectural self-checks, not a new QEMU or standard-suite pass.

Failed infrastructure attempts are preserved, not called passes:

- Leaf launch r1 omitted the build guard's required `--` and exited before
  compilation; r2 ran the native miter successfully.
- Extra system matrix r1 could not link the new real-mode fixture because its
  handler symbols were local. Its three other cases passed, but the aggregate
  remains FAIL. The separately retained fixed fixture exports those symbols;
  extra matrix r2 passes all four cases. No RTL change was needed.

## Full-PC integration and FPGA export

The exact nine-file transfer is `system-read-ack-soc-r1`, model
`3d94caaa60d85a2cd13823a24ee629d76a08fdfb0ed1795c5aed8e0f7f65a17f`.
All 102 shared processor sources match the directed model; all 157 full-PC
defines, full P5 caches, posted-16 transport, retained 8042 fix, peripherals
and host contents are unchanged. A private model-specific C++ harness object
was freshly compiled. Build closed successfully in 27.800 seconds; the
parent's 98 full-SoC structural warnings are unchanged, **not waived as clean**.

`system-read-ack-input-r1/audit.json` independently checks two cold keyboard
probes through the real 8042, raw modes 0/1, 6.5M clocks each, native ownership,
69,637 source pins and no OOM. This does not test Windows UI or physical input.

`system-read-ack-soc-r1/coremark-ui-disabled-r1/audit.json` independently checks
both short 10-iteration controls against the immediate RAW/input parent:

| Seed | Parent and candidate ticks | Candidate V retirements | CRCs |
|---|---:|---:|---|
| Performance | 4,771,298 | 1,055,307 | All five match |
| Validation | 4,755,366 | 1,054,254 | All five match |

The observed throughput change is **0%**, as intended for a combinational
timing cut. Both controls are **duration-invalid**, not a CM/MHz score or full
CoreMark acceptance. Native children are reaped; 69,674 source pins and the
closed owner are independently rechecked, with no OOM.

The immutable FPGA export is `system-read-ack-fpga-r1`; manifest SHA-256
`6ab025121f1f06b1d42f3b277f40349035b5a278ca85ac41ca11d27487c5ecb2`.
It has 192 payloads, 170 common compiled HDL files and the same 159 hardware
defines. The only payload changes are the nine processor files above: keyboard
retry, retained 8042 and posted mouse wrapper remain byte-identical to the
parent. The independent source audit rechecks 71,174 pins. Frozen CPU lint
passes all six structural-error classes in 3.979 seconds; this is not full-SoC
lint or full-wrapper qualification. Fifteen additional integration/export/
timing-controller host tests pass.

The guarded synthesis unit is `ventium-system-read-ack-synth-oct16-r1.service`,
invocation `5650ceca536a4cfa83efc0d29be671ef`. Its one-shot observer is
`ventium-system-read-ack-timing-chain-oct16-r1.service`, invocation
`8065b90e615f4b7ca63e6d7ae4828e25`. The observer audits native closure and only
then launches read-only timing reports; it cannot retry synthesis or start
implementation/deployment. Evidence directories are
`system-read-ack-synthesis-r1` and `system-read-ack-clock-r1`.

This compares against the **immediate RAW/input parent**, not the faster older
boundary-only model: same Default logic-only mapper and 40/100 MHz clocks,
parent DCP `2af6ae8a36eb11fd122f9519b4c2400f66603694f21ce08387fce06a30a2db60`.
Process ownership, exclusive Vivado launch, 8 GiB synthesis RAM / 6 GiB swap
caps, 45-minute bound, measured-growth disk admission and 4 GiB stop floor are
unchanged. The read-only clock audit keeps its 8/4 GiB caps and 15-minute bound.

## Limits and next work

No frequency or IPC gain is claimed for this cut. Finish and independently
audit the matched synthesis/timing; do not inherit the parent's timing or board
result. Routing to ≥40 MHz, repairing canonical gates,
duration-valid CoreMark ≥2.1 CM/MHz, full standard-suite completion, and physical
Win95 cold desktop/UI plus full Quake timedemo acceptance remain required.

The existing cold Win95 run continues on **older full-PC model `e9159acb`**,
not this new derivative. Its boot-only controller cannot establish UI robustness.
The older Quake runs also remain separate evidence.

Latest verified gameplay baseline: **0.50229051 total U+V IPC**, model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`, cycles
**1,400,065,247–1,500,065,247**. U-only IPC was 0.38787572. This predates both
the RAW/input candidate and this ACK derivative; neither has a verified
gameplay measurement. It is not a completed timedemo or FPGA acceptance.
