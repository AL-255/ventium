# Remaining pre-exit status differences: architectural diagnosis

October 12, 2026. This extends the [closed native observation](../../verif/qemu-trace/PREEXIT_OBSERVER.md)
without changing RTL, canonical QEMU, goldens, masks, timing bands or acceptance.
The canonical gate is still **FAIL**, not waived. The live FPGA timing candidate
is not qualified by this investigation of older model `f74dd76b`.

## Specification and result

The Intel Pentium manual, publication **241430-004**, Volume 3, Table 6-4
(printed page 6-12), section 7.1.13 (7-27), and instruction pages 25-87,
25-122/123, 25-137/138 distinguish rounding C1, zero C1 and undefined condition
codes. PDF pages 151, 218, 704, 739, 740, 754 and 755 were extracted and visually
checked from the original scan using the PDF skill. Source:
[`241430-004`](../../ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf).

[`check_remaining_c1.py`](check_remaining_c1.py) accounts for all **161**
remaining reported fields; it does not discard any of them:

| Category | Fields | Evidence and limit |
|---|---:|---|
| Zero-C1 load/register-pop sites | 61 | Nonoverflowing FLD and nonempty exact FSTP; native TOP/tag transitions checked; RTL/native C1 is zero, QEMU retains one |
| Rounding-C1 arithmetic/narrowing sites | 17 | Exact rational comparisons, squared-result comparison for sqrt, or independent integer binary32/64 narrowing; RTL/native agree, QEMU differs |
| C1 retained across observation/integer/FWAIT instructions | 12 | Actual before/after persistence; not 12 new arithmetic defects |
| EAX/ECX fields | 70 | Full native field equals RTL; the later closed-trace propagation audit below connects these copies to six independently checked rounding results |
| Final `tx_fprem` C0 field | 1 | Retained as unqualified; modern-host agreement is not proof of P54 behavior for previously undefined bits |
| **Total** | **161** | **No acceptance mask added** |

For arithmetic, the actual input control words and operands, and the result
value in ST0, agree between native, RTL and QEMU. The independent C1 calculation
does not use either emulator's status bit. The three missing memory-source
operands are read passively from the unchanged gate ELFs; all three children
exit normally and are reaped. Narrowing C1 is computed from the exact source,
destination precision/exponent limits and rounding control, not from a captured
result or a host floating-point calculation. This does not qualify all x87
exceptions, other instructions, or all bits copied through arbitrary guest code.

The later [GPR propagation audit](../../verif/qemu-trace/PREEXIT_OBSERVER.md#link-the-copies-to-independently-checked-rounding-results)
checks complete FNSTSW AX, MOVZX ECX,AX and GPR-preservation equations on both
unchanged traces. Its join re-evaluates this checker's six source C1 results
with matching operands/control words and **164 rehashed input pins**. All 70
reported GPR differences originate in those six correctly rounded C1=1
results, rather than independent integer defects. This is scoped to the
closed `f74dd76b` corpus, not a general taint oracle or current-candidate pass;
the undefined-C0 and reference-policy debts below remain open.

The first attempt correctly failed closed on `9b db e3`: its eight-byte peek
starts at a separately retired **FWAIT**, not the following FNINIT. R2 checks
the actual one-byte EIP advance, no unmasked pending exception and unchanged
floating-point packet. RTL and QEMU also put FNINIT in the next record. This
is a diagnostic decoder correction, not a processor fix or a dropped record.

## Reproducible evidence

Root: `/home/yukidama/external/tmp/ventium-x87-manual.2WID7ODp`.

- R1: `ventium-remaining-c1-oct12.service`, invocation
  `5df877630b1f4d5ca393a95d42f97a1f`, native exit 1. Preserved `c1-r1/driver.py`
  SHA-256 `db0249e75e80f9393de778140d8ba45bd09d80b18caff547eb9d3a572b21ea01`.
- R2: `ventium-remaining-c1-r2-oct12.service`, invocation
  `a15397565169445f90a7b59739b4bb77`, native exit 0, MainPID 0, **0.255111 s**,
  peak **19,648,512 bytes**. Explicit CPU12 affinity, 512 MiB limit, no swap,
  120-second start timeout. `c1-r2/result.json` and three raw operand witnesses
  remain intact. Independent `audit.py` / `audit.json` rehash **184 input-pin
  entries**, verify exact native owner closure, all 161 identities and raw
  witness hashes. Result SHA-256:
  `82aba9015953da55ff8bcef96b4af2821d09356f2d8a0f03722f3b7c3a9cce08`.
- Nine standalone host tests pass: exact values, binary32 decode, nearest-even
  ties of both signs, directed rounding, subnormals, overflow, unknown-opcode
  rejection, FWAIT instruction boundary and pending-unmasked rejection:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH=fp_shared/tb taskset -c 12 python3 -B -m unittest -v test_remaining_c1
```

## Repair direction, not a gate waiver

1. Do not regress RTL rounding/zero-C1 behavior to match this QEMU omission.
   The inspected QEMU arithmetic and narrowing helpers merge exception bits
   but do not publish a rounding increment to C1; ordinary load/register-move
   helpers retain C1 too. A separately qualified reference repair must supply
   instruction-appropriate C1, including exact results, all PC/RC modes,
   under/overflow and stack exceptions. Do not clear all condition codes
   globally: FXAM, remainder quotients and environment restores have different
   rules. Preserve the original binary and independently test any derivative.
2. Do not blindly mask FSW: 70 reported fields are EAX/ECX copies. Retained
   undefined bits also need a deliberate architectural comparison policy;
   agreement with a modern native host is not that policy.
3. Keep terminal-state collection and observer-mode cache identity separate
   from arithmetic fixes. Their existing private repairs must be deliberately
   qualified/promoted after in-flight build pins are released. Do not rewrite
   a live run's source or reuse goldens from a different observer mode.
4. Independent cycle-band failures remain. Diagnose them using the actual
   configured memory backend; no band relaxation follows from this result.
   Full standard-suite and physical FPGA qualification are still required.

One historical manifest description names the wrong layer of the FPREM1 gap:
`helper_fprem_common` passes a quotient pointer to `floatx80_modrem`, but the
latter zeroes it and passes **NULL to `parts_modrem` when `mod=false`**. Thus
the behavior described by the old mask is real; there is no newly demonstrated
binary/source mismatch. The original, private control and private observer
sources have identical relevant files: `fpu_helper.c` SHA-256
`efb0daf00682ed65488b6ee606a409da7d84f1bb6c118d1bdbc8d27ead37c4e6`,
`softfloat.c` SHA-256
`52bfcaccf667d11d4fbb79a0d51d62ce6362417f5a47043da0a20a0d7395f3fa`.
No manifest or old mask was altered here.

Current candidate gameplay IPC is unmeasured. Older verified simulation baseline:
**0.51030715 total U+V retirement-event IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not a board
measurement or full-timedemo average.
