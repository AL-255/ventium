# M2 — user-mode integer ISA completeness spec

M2 (PLAN §7, re-scoped) extends the M1 single-issue integer core to the
**complete user-visible integer ISA** that QEMU's user-mode (linux-user gdbstub)
oracle can validate, keeping every test program **diff-clean vs QEMU**
(`verif/diff/compare.py --mode func` exit 0). This document is the milestone
contract; it builds on [`m1-core-spec.md`](m1-core-spec.md) (init state, bus,
termination, retire convention — all unchanged).

## Why this scope (and what's deferred to M2S)

The differential oracle is QEMU **user-mode**: it runs flat, with no
paging/segmentation/SMM/ring transitions exposed. So M2 does **not** attempt
those — they move to **M2S** (PLAN §7), which needs a *system-mode* oracle
(`qemu-system-i386` + system-state trace). M2 = the integer ISA a user-mode
program can execute and that QEMU user-mode reproduces bit-exactly.

Unchanged from M1: in-order, single-issue, multi-cycle, functional only (no
pipeline/pairing/caches — M4/M5). `int 0x80` still **halts** (no Linux syscall
emulation; test programs compute in registers/memory and exit). Functional
memory via the existing BFM is sufficient.

## Correctness model: QEMU is ground truth

Unlike M1 (tiny program, hand-specified flag anchors), M2 relies on the
**differential gate**: a broad generated corpus defines coverage, and QEMU
defines correct results. The RTL is extended/fixed until the comparator is green.
This means the implementer does **not** need a hand table for every flag — but
must get the **EFLAGS undefined-bit masking** right, because the comparator
compares EFLAGS and several M2 ops leave bits architecturally undefined.

### EFLAGS undefined masking (critical)
`verif/diff/tracefmt.py::EFLAGS_UNDEFINED` lists, per mnemonic, the bits to
exclude from the EFLAGS compare (the comparator decodes each record's `bytes`
with capstone to get the mnemonic). M2 MUST extend this table to cover the new
ops whose flags are undefined, so the gate neither (a) false-fails on a bit QEMU
happens to set a particular way nor (b) false-passes by over-masking. Known
undefined cases to encode (verify against the SDM / QEMU behavior):
- `MUL/IMUL`: SF/ZF/AF/PF undefined (CF/OF defined). *(already present)*
- `DIV/IDIV`: all six status flags undefined. *(already present)*
- `SHL/SHR/SAR/SHLD/SHRD`: **OF undefined** for counts ≠ 1; **AF undefined**;
  for count == 0, **no flags change at all** (must match QEMU exactly).
- `ROL/ROR/RCL/RCR`: affect **only CF and OF**; OF undefined for counts ≠ 1;
  other flags unchanged; count == 0 changes nothing.
- `BT/BTS/BTR/BTC`: CF = selected bit; **OF/SF/AF/PF undefined**, ZF unchanged.
- `BSF/BSR`: ZF defined (set iff src == 0); **CF/OF/SF/AF/PF undefined**;
  on src == 0 the destination is **undefined** too (QEMU leaves dest unchanged —
  the corpus should avoid relying on dest in that case, or mask it).
- `AAD/AAM/AAA/AAS/DAA/DAS`: various undefined (avoid in the corpus unless masked).
Prefer **avoiding** instructions/operands whose *destination register* is
undefined; where flags are undefined, mask them. Document every table change.

## Instruction groups to add (on top of M1)

Encodings in Intel/SDM convention. Implement the 32-bit forms; see Prefixes for
16/8-bit. Group by the shared datapath they extend.

### Shifts / rotates — `D0/D1/D2/D3` and `C0/C1`, group /digit
`/0 ROL /1 ROR /2 RCL /3 RCR /4 SHL /5 SHR /6 SAL(=SHL) /7 SAR`.
Forms: by 1 (`D1 /r`), by CL (`D3 /r`), by imm8 (`C1 /r ib`); 8-bit variants
`D0/D2/C0`. Count is masked to 5 bits (`& 0x1f`) on the 386+; count==0 ⇒ no
flag change. `SHLD/SHRD` = `0F A4/A5` (imm8) and `0F AC/AD` (CL).

### Multiply / divide (microcoded; not pairable, but functional here)
`MUL r/m` `F6/F7 /4`, `IMUL r/m` `/5`, `DIV` `/6`, `IDIV` `/7`; plus
`IMUL r32, r/m32, imm` (`69`/`6B`) and `IMUL r32, r/m32` (`0F AF`).
EDX:EAX semantics; `#DE` on divide overflow/by-zero (but the corpus should avoid
faulting since user-mode QEMU would deliver SIGFPE — keep divisors safe).

### Sign/zero extend, misc unary
`MOVZX` `0F B6/B7`, `MOVSX` `0F BE/BF`; `NEG` `F6/F7 /3`, `NOT /2`;
`INC/DEC r/m` (`FE/FF /0,/1`); `CDQ`(`99`)/`CWDE`(`98`)/`CBW`(66 98);
`XCHG r/m,r` (`86/87`), `XCHG eAX,r32` (`90+r`, note `90`=NOP=xchg eax,eax);
`SETcc r/m8` (`0F 90+cc`); `BSWAP r32` (`0F C8+r`).

### Bit tests
`BT/BTS/BTR/BTC`: `0F A3/AB/B3/BB` (reg) and `0F BA /4../7 ib` (imm8).
`BSF`(`0F BC`)/`BSR`(`0F BD`).

### Stack / flags
`PUSH imm8/imm32` (`6A/68`), `PUSH r/m` (`FF /6`), `POP r/m` (`8F /0`),
`PUSHA/POPA` (`60/61`), `PUSHF/POPF` (`9C/9D`), `LAHF/SAHF` (`9F/9E`),
`ENTER/LEAVE` (`C8/C9`) — LEAVE at least.

### String ops + REP
`MOVS B8/MOVSD` (`A4/A5`), `STOS` (`AA/AB`), `LODS` (`AC/AD`),
`SCAS` (`AE/AF`), `CMPS` (`A6/A7`), with `REP`(`F3`)/`REPE`/`REPNE`(`F2`)
prefixes; direction from **DF** (`STD 0xFD`/`CLD 0xFC`). ECX as count for REP;
ESI/EDI auto-inc/dec by operand size. (ES/DS overrides ignored in flat model.)

### Control / loop
`LOOP/LOOPE/LOOPNE` (`E2/E1/E0 cb`), `JCXZ/JECXZ` (`E3 cb`),
`CALL rel32` (`E8`) + `RET` (`C3`, `C2 iw`), `CALL/JMP r/m` (`FF /2,/4`).
(CALL/RET use the stack; near forms only — far/gate forms are M2S.)

## Operand sizes & prefixes

- **0x66 operand-size**: 32-bit default → **16-bit** operand. Partial-register
  write: writing AX/CX/… updates bits [15:0] and **preserves [31:16]**. Flags
  computed on the 16-bit result (SF=bit15, etc.).
- **8-bit forms** (low opcodes even / `B0+r` / `/r` byte forms): writing AL/CL/…
  updates [7:0] preserving [31:8]; AH/CH/DH/BH update [15:8]. Flags on 8-bit
  result (SF=bit7, PF on the byte). Partial-register correctness is a top bug
  source — test it explicitly.
- **0x67 address-size**: 16-bit addressing — rare in 32-bit code; recognize/skip,
  implement if the corpus needs it (prefer not to generate it).
- **Segment overrides** `2E/36/3E/26/64/65` and **LOCK** `F0`: decode and skip;
  functionally no-ops in the flat user model (FS/GS base = 0 here).
- Multiple prefixes may stack; the prefix machine must consume them all and feed
  the correct opcode. Prefixed instructions remain single-issue (pairing is M4).

## Verification (the M2 gate)

Same mechanism as M1, multi-program (per-program init-ESP derived from the
golden's n=0). The corpus is a broad set of freestanding P5 programs, each
exercising one or more groups above, plus randomized sequences. Build + ISA-
verify (`tools/isa_verify.py`) + diff each vs QEMU:
```
gen_trace.py --elf <p>.elf --out build/m2/<p>_qemu.vtrace --max-insn <N>
tb_ventium --image <p>.flat --load <a> --entry <a> --init-esp <golden n0 esp> \
           --out build/m2/<p>_rtl.vtrace --max-insn <N>
compare.py --mode func build/m2/<p>_qemu.vtrace build/m2/<p>_rtl.vtrace   # exit 0
```
**Gate (`make m2` / `verif/run-m2.sh`): every M2 program is func-diff-clean
(exit 0, no length mismatch), EFLAGS masking documented and minimal.** Keep
`make m1` and `make m0-smoke` green. Honest reporting: list which instruction
groups are covered and any deliberately deferred (far CALL/RET, system ops →
M2S; anything not yet decoded should HALT the core, not silently mis-execute).
