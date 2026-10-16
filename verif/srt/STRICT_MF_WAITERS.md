# Strict x87 waiting-instruction delivery — 2026-10-16

The system-read ACK derivative preserves strict pending-#MF delivery across
**29 waiting-instruction forms**: all 174 candidate runs pass, and their complete
architectural traces and clock counts match the immediate parent. This is a
cold directed regression, **not QEMU differential, gameplay, canonical-gate or
FPGA acceptance**. No RTL was changed for this test.

## Coverage and checks

`run_strict_mf_waiters.py` reuses the pinned underflow-delivery supervisor and
guest handler. Two normal-operand FPREM/FPREM1 producers generate positive and
negative wrapped underflow results with UE unmasked. The first pending-#MF case
executes the selected waiting instruction immediately after the arithmetic:
there is no intervening status read, FWAIT, forced state or snapshot. A separate
case sets TS while #MF is pending and requires #NM before #MF. The inherited TS
and EM probes remain FLD1 tests; they are not claimed as a 29-form #NM matrix.

Forms: FWAIT, FNOP, FLD1, FCHS, FABS, FXCH, FFREE, FINCSTP, FDECSTP;
FLD m32/m64/m80; FILD m16/m32/m64; FST m32/m64/ST; FSTP m80;
FIST m16/m32; FADD/FSUB/FMUL/FDIV m32; FCOM, FUCOM, FTST and FLDCW.

The real protected-mode handlers check the saved fault EIP, exact exception
order and UE/ES/B status without accidental IE/DE/OE. They clear the cause and
retry the same instruction, never skip it. Ordinary instructions after retry
restore the selected operation's stack/sign effect before existing checks of
the full 80-bit remainder, ST1, TOP and exactly-once FLD1 push. Operand setup
precedes the arithmetic. AXI read/write delays are 0, 7 and 31 clocks.

The independent auditor rehashes sources and artifacts, verifies the closed
owner and each reaped native child, reads all architectural/x87 records, checks
116 actual instruction encodings in the BIOS images, and verifies delivery and
retry PCs. The existing trace ABI emits a post-delivery record at the faulting
PC; this is not a successful execution. The auditor requires the corresponding
handler entry and pushed stack, then exactly one successful retry. It does not
trim those records or interpret their count as workload IPC.

Six host tests include negative grading checks for wrong exit, fault order,
exception status, handler PC, stack, TS priority, uncleared retry, duplicate
execution, absent x87 payload, and zero pairing/backing activity. Explicit
`--quiesce` suppresses the harness's default-quiesce banner: backend evidence is
the observed native `--l1-axi` argv plus nonzero L1 backing ACKs, not that banner.

## Retained results

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Run: `system-read-ack-mf-waiters-r1`, independent result `audit.json`.
Unit: `ventium-system-read-ack-mf-waiters-oct16-r1.service`, invocation
`6c8aa64270064f888e24f7dcb089037b`, closed successfully in 247.955 seconds.

| Model | SHA-256 prefix | Pass / fail | Records checked | V retirements |
|---|---|---:|---:|---:|
| Older non-strict diagnostic control | `6deb3e92` | 12 / 162 | 315,015 | 95,478 |
| Immediate RAW/input parent | `41f99bcf` | 174 / 0 | 338,730 | 97,260 |
| System-read ACK candidate | `005d0f17` | 174 / 0 | 338,730 | 97,260 |

522 native executions, 58 BIOS images, 174 exact parent/candidate trace pairs;
1,160 source pins independently rechecked. The old control passes FWAIT/FNOP
and fails the other 27 forms. It has other older-source differences, so it is
not a single-define causal experiment or an acceptance substitute.
Parent/candidate retain the same 153 defines, including `VEN_X87_MF_STRICT`,
UV, system/relocated fast paths and full P5 caches. Native execution uses
`--system --cosim --cycle-func --l1-axi --x87`, `cycle_mode=1`, CPU 12, no
debugger STEP/breakpoint, with positive V retirements in every run.

Regrade a closed run (output is create-exclusive; do not overwrite evidence):

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B verif/srt/audit_strict_mf_waiters.py \
  --run /home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/system-read-ack-mf-waiters-r1 \
  --unit ventium-system-read-ack-mf-waiters-oct16-r1.service
```

This does not cover every x87 encoding, all arithmetic exception classes,
page/segment-fault precedence, physical board execution, or poisoned-memory
proof of suppressed early stores. Those claims must not be inferred from a
passing saved-EIP/stack test. Canonical verification remains failed; no oracle,
mask, cycle-band or guest-workload waiver was introduced.

Latest verified gameplay baseline: **0.50229051 total U+V IPC**, model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`, cycles
**1,400,065,247–1,500,065,247**. It predates the RAW/input and ACK candidates;
neither candidate has a verified gameplay measurement.
