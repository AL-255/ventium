# Instruction-fetch boundary regressions

These seven independent 64KiB BIOS fixtures test fetch **necessity**, precise
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
checked and the counter must equal one. The overlong prefix instruction and
following counter must never retire. Its checked GP handler terminates the
fixture, since retrying an unchanged invalid sixteen-byte instruction cannot
make forward progress; it does not rewrite its saved frame or resume it.

The pinned QEMU 8.2.2 source explicitly gives a second-page PF precedence
when byte16 crosses a page, before raising the overlength GP:
`ventium-refs/07-p5-emulation-harness/build/qemu/target/i386/tcg/translate.c`,
`advance_pc`, lines2094–2122. Case6 checks this order, not a weakened GP-only
expectation. Repeated `2e` is a recognized legacy segment prefix; the sequence
has fifteen prefixes and an actual sixteenth byte, not fourteen prefixes plus
a valid fifteen-byte instruction.

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
coverage. `--jobs 1..7` runs independent case pipelines concurrently with
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
