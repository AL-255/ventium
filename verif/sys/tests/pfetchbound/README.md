# Instruction-fetch boundary regressions

These twenty-two independent 64KiB BIOS fixtures test fetch **necessity**, precise
fault ownership, and the maximum instruction-length boundary. They do not
qualify Windows95, Quake, performance, or the standard suite. This source
addition has not itself been assembled or executed by its author; actual
closed receipts establish validation and pre-fix failures.

| Case | User instruction / boundary | Required fault sequence |
| --- | --- | --- |
| 1: short CALL | Five-byte `E8 rel32` at `0x401ffa`, fully inside the mapped page, branches to mapped `0x400000` | None; unused nonpresent `0x402000` must not fault |
| 2: NOP / next opcode | One-byte NOP at `0x401fff`, then `INC [0x4004]` starts on the nonpresent next page | PF error4, EIP **`0x402000`**, not the NOP |
| 3: immediate | `MOV EAX,imm32` at `0x401ffc`, final immediate byte at `0x402000` | PF error4, EIP `0x401ffc` |
| 4: ModR/M | `MOV EAX,[disp32]` opcode at `0x401fff`, required ModR/M byte at `0x402000` | PF error4, EIP `0x401fff` |
| 5: SIB | `8B 04` at `0x401ffe`, required SIB byte `25` at `0x402000` | PF error4, EIP `0x401ffe` |
| 6: byte16 nonpresent | Fifteen legacy CS prefixes at `0x401ff1..0x401fff`, byte16 NOP on nonpresent page | PF error4 at original EIP, unchanged IRET retry, then GP0 at original EIP |
| 7: byte16 present | Same sixteen-byte sequence, both pages mapped | GP0 at original EIP, no PF; CR2 remains explicitly initialized zero |
| 8: immediate overrun endpoint | Twelve `2e` prefixes plus `B8 imm32` at `0x401ff0`: byte16 is mapped, but the immediate's byte17 endpoint is nonpresent | PF error4, CR2 `0x402000`, EIP `0x401ff0`; unchanged IRET retry, then GP0 at the same EIP |
| 9: displacement is first overrun | Eleven `2e` prefixes plus final `3e`, then `C7 05 disp32 imm32` at `0x401fee`: displacement ends at mapped `0x401fff`, while the unused immediate ends at nonpresent `0x402003` | GP0 at EIP `0x401fee`, **no PF**; CR2 remains zero |
| 10: x87 opcode / missing ModR/M | `D9` at `0x401fff`, FLD1 ModR/M `E8` nonpresent, CR0.TS set | NM at original EIP, architectural CLTS and unchanged IRET, then PF4, map/retry, exactly-once FLD1 and raw80 FSTP witness |
| 11: MOV-CR privilege | `0F 20` at `0x401ffe`, ModR/M `C0` nonpresent, CPL3 | GP0 at original EIP **before fetching ModR/M**; no PF/effect |
| 12: MOV-DR privilege | `0F 21` at `0x401ffe`, ModR/M `C0` nonpresent, CPL3 | Same CPL0 GP priority, no PF/effect |
| 13: x87 opcode is byte15 | Fourteen `2e` prefixes plus `D9` through `0x401fff`, missing ModR/M byte16, CR0.TS set | NM first, CLTS/unchanged IRET, PF4, map/unchanged IRET, then overlength GP0; no x87/counter retirement |
| 14: x87 opcode is byte16 nonpresent | Fifteen prefixes through `0x401fff`, `D9` opcode nonpresent at `0x402000`, CR0.TS set | PF4 then map/unchanged IRET and GP0, **no NM**; TS remains set |
| 15: x87 opcode is byte16 present | Same sequence with page2 mapped | GP0 directly, **no NM/PF**; TS remains set |
| 16: LGDT privilege before EA | `0F 01 14` at `0x401ffd`, required SIB `25` on the nonpresent next page, CPL3 | GP0 at original EIP before SIB/displacement, no PF/effect; CR2 remains zero |
| 17: LMSW privilege before EA | `0F 01 34`, same geometry | Same GP0/no-PF requirement |
| 18: LLDT privilege before EA | `0F 00 14`, same geometry | Same GP0/no-PF requirement in protected mode |
| 19: LIDT privilege before EA | `0F 01 1C`, same geometry | Same GP0/no-PF requirement |
| 20: SMSW is unprivileged | Default32 `0F 01 E0` at `0x401ffd`, followed on the mapped next page by `66 0F 01 E3` | No fault; full EAX and word BX results equal guest-prepared CR0 expectations, preserving EBX upper half; counter1, CR2 zero |
| 21: in-page LGDT priority | Eleven `2e` prefixes plus `0F 01 15` at `0x401ff0`: authorized ModR/M is byte14, disp32 bytes15–16 are mapped and bytes17–18 are nonpresent, CPL3 | GP0 at original EIP **before EA/atomic overrun probing**, no PF/effect; CR2 remains zero |
| 22: in-page unknown x87 priority | Fully mapped unsupported `D9 D1` at `0x401f00`, CR0.TS set | NM first, architectural CLTS and unchanged IRET, then UD6 at the same EIP; complete no-error frames, no retirement/effect, CR2 zero |

Every PF has CR2 `0x402000`, saved CS `0x1b`, EFLAGS `2`, old SS:ESP
`0x23:0x80000`. The GP cases check the same complete frame with error0;
CR2 is unchanged by GP. The valid cases' handler maps **only** the missing
code page, reloads CR3, and IRETs without modifying saved EIP, CS, EFLAGS,
or old SS:ESP. Actual stack operands are captured at labelled MOVs; no host
register injection, frame patch, synthetic record, or instruction skip occurs.

The short CALL's mapped target POPs and verifies the exact return address
`0x401fff` and restored ESP. It increments its counter and exits there; it
deliberately does **not** return into unused successor bytes. This tests CALL
fetch overreach, not the distinct behavior of executing its fall-through.
The NOP must retire before the next-opcode PF. Essential-byte cases must not
change EAX, the seed, or the counter before their PF; after retry, EAX is
checked and the counter must equal one. The overlong instruction and
following counter must never retire. Its checked GP handler terminates the
fixture, since retrying an unchanged invalid overlength instruction cannot
make forward progress; it does not rewrite its saved frame or resume it.

The pinned QEMU 8.2.2 source explicitly gives a newly crossed-page PF precedence
before raising the overlength GP:
`ventium-refs/07-p5-emulation-harness/build/qemu/target/i386/tcg/translate.c`,
`advance_pc`, lines2094–2122. Case6 checks this order, not a weakened GP-only
expectation. Repeated `2e` is a recognized legacy segment prefix; the sequence
has fifteen prefixes and an actual sixteenth byte, not fourteen prefixes plus
a valid fifteen-byte instruction.

Byte16 alone is not a universal overlength check. `advance_pc` consumes a
displacement or immediate in one atomic-width step, then probes the **page
base of that step's last byte** if the step first exceeds fifteen bytes.
Case8 therefore requires PF even though byte16 is mapped: the imm32 step
ends at byte17 on `0x402000`. CR2 is that page base, not an arbitrary last-byte
address. After mapping only that page, the unchanged retry must reject the
same invalid instruction with GP0 and unchanged EAX/seed/counter.

Case9 distinguishes the first overrun field from the full encoding length.
Its disp32 is already overlength but ends on the mapped first page, so GP0
must occur without fetching/probing the later imm32's nonpresent page.
The twelve-prefix C7 encoding is 22 bytes, but that total is not the probe
endpoint. Its last segment prefix selects writable DS, so an operand-side
GP on a write through CS cannot masquerade as instruction-length rejection.
The golden differential, exact frame, no retirement, no counter/seed effect,
and no PF are the acceptance witnesses; observed native delivery states
remain supplemental metadata. Original cases1–7 keep their existing witness
and fault-state grading.

Cases10–15 test fetch stopping points before full instruction metadata exists.
The pinned decoder checks CR0.EM/TS after an x87 escape opcode but **before**
reading its ModR/M (`translate.c`, x87 arm near line4367); MOV-CR/DR checks CPL0
before ModR/M (near lines6452/6496). These are different from rejecting an
already-fetched overlong opcode: byte16 opcode advancement faults before an
x87 escape can reach its CR0 check. Case13 versus14/15 proves that distinction.

The #NM handler verifies the actual no-error-word frame (EIP, CS, EFLAGS,
old ESP, old SS), zero CR2, incoming TS, and untouched EAX/seed/counter. It
executes CLTS and IRETs without changing any saved operand. Only then may the
missing essential ModR/M cause PF; that handler still maps only page2 and
IRETs unchanged. Case10 additionally stores FLD1's result as raw80 at
`0x4010`: exact dwords `0x00000000`, `0x80000000` and exponent `0x3fff` are
read back by the guest. The successful FLD1, FSTP and counter must each retire
exactly once. No host mutation, execution injection, save-state, or skip is
used. Original cases1–9 retain their existing frame/status grading.

Cases16–19 require the authorized ModR/M before recognizing the group
privilege check, but forbid demand for a later SIB/displacement at CPL3.
Their three-byte headers are mapped; `25 00 40 00 00` on the nonpresent page
would form a valid no-base SIB/disp32 operand if privilege allowed it.
LGDT/LIDT/LMSW/LLDT must reject CPL3 before decoding that EA, leaving CR2,
the seed, EAX and the counter untouched. These use the existing complete
GP error-word frame checker, not an implementation-state-only witness.
Original cases1–15 keep their existing metadata and grading requirements.

Case20 catches a privileged-op classification alias: SMSW is not MOV-CR and
is readable at CPL3 on P54C. Before launching user mode, guest CPL0 reads its
actual CR0 and stores both that full value and `0xa5a50000 | (CR0 & 0xffff)`
as expectations. It initializes EBX to `0xa5a55a5a`; user default32 SMSW EAX
stores its full result at `0x4008`, and prefixed word SMSW BX stores EBX at
`0x400c`. The guest compares both against the prepared expectations and the
checker reads the same raw values and actual CR0 preparation. There is no
hardcoded host reset-CR0 assumption. EAX is architecturally restored to the
fixture seed before the counter and normal INT40 exit. Page2 is mapped, every
user instruction must retire exactly once, and any ordinary fault fails.
Original cases1–19 keep their existing metadata and grading requirements.

Cases21–22 exercise the ordinary in-page decode path, not merely a latched
boundary-fetch exception. Case21's sixteen-byte window fits entirely in the
mapped first page. Eleven CS prefixes precede `0F 01 15`; the LGDT ModR/M is
legally fetched at byte14, and no SIB is needed. Its disp32 `00 40 00 00`
starts at mapped `0x401ffe` and ends at nonpresent `0x402001`. CPL3 must be
rejected before that atomic displacement advancement, whose byte18 endpoint
would otherwise probe page base `0x402000` and spuriously PF. The manifest
pins the exact page-one and page-two encoding, in addition to the image
checker. The full golden differential and exact GP frame are required, not
just a native state number.

The first closed case21 receipts used twelve prefixes plus a SIB at byte16;
both the corrected and old c5d0 builds passed that geometry, because SIB
advancement could already cause GP before the later displacement was
considered. Those retained receipts are not a negative-control proof for
this strengthened no-SIB geometry. Its new fixtures and results must be
separately assembled, pinned and verified; historical receipts are unchanged.

Case22 uses `D9 D1`, which the pinned QEMU rejects as an unknown x87 operation
(`translate.c`, D9 /2 accepts only rm0 FNOP near lines4600–4612). The raw D9
escape must still check TS before that semantic rejection. Its actual #NM
handler captures the complete no-error-word frame, executes CLTS, and IRETs
unchanged. The real retry then enters a distinct checked #UD handler, also
without an error word. That handler verifies the same EIP, CS, flags, old
SS:ESP, zero CR2 and untouched EAX/seed/counter, and terminates without any
frame patch or instruction skip. The checker requires the ordered NM→UD
faults, actual CLTS/IRET between their complete readbacks, TS cleared at exit,
and no retirement of the invalid instruction or its successor. Original
cases1–20 keep their existing metadata and grading requirements.

## Frozen, bounded execution

Build only these BIOS fixtures into an externally chosen, fresh owned path
under `/tmp` or the existing repository scratch area after checking space:

```sh
df -h / /tmp
make -C verif/sys/tests/pfetchbound OUTDIR=/absolute/owned/new-fixtures
```

Run against an already-built and independently reviewed frozen simulator;
the runner never builds or clobbers a testbench:

```sh
bash verif/sys/tests/pfetchbound/run-gate.sh \
  --tb /absolute/frozen-build/tb_ventium \
  --tb-sha256 REVIEWED_TB_SHA256 \
  --compile-sha256 REVIEWED_COMPILE_RECORD_SHA256 \
  --fixtures /absolute/owned/new-fixtures \
  --out /absolute/owned/new-run --cases all --modes both --jobs 2 --port-base 41710
```

`--cases 1,3` is an explicit narrow short-CALL/immediate subset, **not** full
coverage. `--jobs 1..22` runs independent case pipelines concurrently with
distinct GDB ports. Normal functional and `--cycle-func` both preserve complete
architectural state; bare cycle traces are not an accepted substitute.

The 540s shell wall bound includes a 530s internal deadline (plus5s forced
cleanup). Free-QEMU/golden/native/diff command bounds are30/90/60/30s.
Each command uses the existing process-group supervisor and real child wait;
native and independent free QEMU must exit normally with debug-exit **133**.
Timeout, cap, descendants, truncated logs, wrong frames, unexpected ordinary
faults, or wrong terminal effects cannot pass. Inputs, fixture copies, TB,
compile record, QEMU executable, helpers and trace contracts are SHA-pinned
before and after execution. Full raw `.vtrace` rows are retained and compared
without record filtering using the canonical functional differential.

Coverage is deliberately bounded: these are CPL3/32-bit/nonpresent-page and
instruction-length cases, not a complete fetch matrix. They do not exercise
warm ITLB supervisor protection, CS limit faults, 16-bit wrap, every prefix
combination, or architectural interrupt interposition. Passing them cannot
replace ordinary differential gates or the complete standard suite.
