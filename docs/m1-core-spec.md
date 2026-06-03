# M1 — single-issue in-order integer core spec

The M1 milestone (PLAN §7) replaces the M0 NOP stub with a **real** integer core
that decodes and executes IA-32 instructions and is **diff-clean vs QEMU**
(`verif/diff/compare.py --mode func` exits 0) on the smoke corpus and the M1 test
programs. This document is the milestone contract.

## Scope (and what M1 is NOT)

- **In-order, single-issue, multi-cycle functional core.** A clean
  fetch → decode → execute → mem → writeback/retire flow, one instruction at a
  time. NO pipelining, NO U/V pairing, NO branch prediction, NO caches/TLB yet —
  those are M4/M5. Correct *architectural state* is the only M1 goal (REF.md
  success layer 1, integer subset).
- **Cycle counts are irrelevant at M1.** Only the func-mode arch-state trace is
  compared. (The cycle oracle/comparison returns at M4.)
- **Decoder coverage = the implemented integer subset below**, built to extend
  cleanly toward the "exhaustive vs XED/Capstone" goal — not yet exhaustive.
  Document what is and isn't covered; don't claim more.

## Initial architectural state (reset)

To match QEMU's *linux-user* process-entry state for the test binaries (this is
the OS/loader's job, which QEMU's linux-user mode performs — so the testbench,
playing the loader, establishes it; the core latches it at reset):

| state | reset value | notes |
|---|---|---|
| EIP | `entry` (manifest; smoke = `0x08048000`) | from `--entry` |
| ESP | `0x40c34910` (host/argv-dependent; derive from golden n=0) | QEMU linux-user initial ESP for these static binaries; testbench `--init-esp`. The exact value depends on the argv/env bytes QEMU's loader pushes (argv[0] = the ELF path, which differs per program), so the differential gate derives it from each golden's n=0 record. `0x40c34910` is the smoke value; the prior `0x40c348d0` was stale and made every program (incl. smoke) diverge at n=0. |
| EFLAGS | `0x00000202` | bit1 reserved-1 + IF(bit9) |
| CS | `0x0023` | linux-user i386 selectors |
| SS,DS,ES,GS | `0x002b` | |
| FS | `0x0000` | |
| EAX,ECX,EDX,EBX,EBP,ESI,EDI | `0x00000000` | |

Recommended realization: `ventium_top` takes `init_eip`/`init_esp` input ports
(driven by the TB) and uses parameters/constants for the segment selectors and
EFLAGS reset value; latch all of these at the reset edge. Segments never change
in the M1 corpus — the core just reports the constants. Document the choice.

## Termination

`int $0x80` (`CD 80`) is the program exit. The core must **halt** on it: stop
retiring (do NOT emit a retire record for the `int` itself). The testbench stops
on quiescence (K idle clocks). This makes the RTL trace end exactly where QEMU's
gdbstub trace ends (QEMU does not emit a post-state row for the final `int`).

## Instruction set to implement

Encodings use Intel/SDM conventions. `/r` = ModR/M with reg field as operand;
`/digit` = ModR/M reg field is an opcode extension. `rel8`/`rel32` are
sign-extended and added to the address of the *next* instruction. All operand
sizes are 32-bit (no operand-size prefix in the M1 corpus); build the prefix
machine to *recognize* 0x66/0x67/segment/F2/F3/0F but M1 need only fully execute
the 32-bit forms below.

### Data movement
| mnemonic | encoding | action |
|---|---|---|
| `MOV r32, imm32` | `B8+rd id` | reg ← imm32 |
| `MOV r/m32, r32` | `89 /r` | r/m ← reg |
| `MOV r32, r/m32` | `8B /r` | reg ← r/m |
| `MOV r/m32, imm32` | `C7 /0 id` | r/m ← imm32 |
| `MOVZX`/`MOVSX` | (optional, M1.x) | — |
| `LEA r32, m` | `8D /r` | reg ← effective address (no memory access, no flags) |
| `PUSH r32` | `50+rd` | ESP−=4; mem[ESP] ← reg |
| `POP r32` | `58+rd` | reg ← mem[ESP]; ESP+=4 |
| `XCHG`/`NOP` | `90` | NOP (xchg eax,eax) |

### Integer ALU — register/immediate forms
Group: `ADD ADC SUB SBB AND OR XOR CMP` plus `INC DEC`. Standard encodings:
| form | opcodes |
|---|---|
| `ALU r/m32, r32` | `00..3D` low nibble pattern: `01 /r`(ADD) `09`(OR) `11`(ADC) `19`(SBB) `21`(AND) `29`(SUB) `31`(XOR) `39`(CMP) |
| `ALU r32, r/m32` | `03 0B 13 1B 23 2B 33 3B` |
| `ALU eAX, imm32` | `05 0D 15 1D 25 2D 35 3D` |
| `ALU r/m32, imm32` | `81 /digit id` (digit selects ADD..CMP: 0..7) |
| `ALU r/m32, imm8` (sign-ext) | `83 /digit ib` |
| `INC r32` | `40+rd` |
| `DEC r32` | `48+rd` |
| `TEST r/m32, r32` | `85 /r` (AND for flags only, no writeback) |
| `TEST eAX, imm32` | `A9 id` |
| `CMP` (above) | flags only, no writeback |

(M1 must implement at least the opcodes the corpus uses; implementing the whole
ALU group is recommended since they share one datapath.)

### Control flow
| mnemonic | encoding | action |
|---|---|---|
| `JMP rel8` / `rel32` | `EB cb` / `E9 cd` | EIP ← next + rel |
| `Jcc rel8` | `70+cc cb` | if cc(EFLAGS): EIP ← next + rel8 |
| `Jcc rel32` | `0F 80+cc cd` | 32-bit displacement form |
| `INT 0x80` | `CD 80` | **halt** (see Termination) |

`cc` decode (tttn): O/NO, B/AE, E/NE, BE/A, S/NS, P/NP, L/GE, LE/G — i.e. test
`OF / CF / ZF / CF|ZF / SF / PF / SF≠OF / ZF|(SF≠OF)` and the negations.
The corpus uses `JE (74)`, `JNE (75)`.

## EFLAGS computation (must match QEMU exactly — the comparator compares them)

Compare mask = `tracefmt.EFLAGS_DEFAULT_MASK` (`0x003f7fd5`) minus any per-op
undefined bits (only `mul/imul/div/idiv/bsf/bsr/daa/das` have undefined entries
— none are in the M1 corpus, so EFLAGS is compared fully for every M1 op). So
get all six status flags right:

- **CF**: unsigned carry (ADD: carry out of bit31) / borrow (SUB/CMP). For
  AND/OR/XOR/TEST: **CF = 0**. INC/DEC: **CF unchanged**.
- **PF**: even parity of the **low 8 bits** of the result.
- **AF**: carry/borrow out of **bit 3** for ADD/SUB/CMP/INC/DEC. For
  AND/OR/XOR/TEST: QEMU yields **AF = 0** — match it (set AF=0).
- **ZF**: result == 0.
- **SF**: result bit 31.
- **OF**: signed overflow. ADD: `(~(a^b) & (a^res))>>31`. SUB/CMP:
  `((a^b) & (a^res))>>31`. AND/OR/XOR/TEST: **OF = 0**. INC: OF set iff result ==
  0x80000000. DEC: OF set iff result == 0x7fffffff.
- Bit 1 always reads 1; IF (bit9) stays 1 (no CLI/STI in corpus); other system
  bits unchanged.

Sanity anchors from the smoke golden trace (`build/m0/qemu_func.vtrace`):
`add→0x33333333` eflags `0x206` (PF=1); `xor ebx,ebx→0` eflags `0x246`
(ZF=1,PF=1,CF=0,OF=0,AF=0); `and ebx,7→7` eflags `0x202` (PF=0); `dec esi 16→15`
eflags `0x216` (PF=1,AF=1, CF preserved); `cmp ebp,eax (equal)` eflags `0x246`
(ZF=1). Reproduce these exactly.

## ModR/M, SIB, displacement, immediate

Implement general 32-bit addressing decode (needed already for `lea (%eax,%edx,2)`
= ModR/M `0x3c`, SIB `0x50`):
- **ModR/M** = `mod[7:6] reg[5:3] rm[2:0]`. `mod==11`: rm is a register.
  `mod==00/01/10`: memory; `rm==100` → SIB follows; `rm==101 && mod==00` →
  disp32 (no base). disp8 if `mod==01`, disp32 if `mod==10`.
- **SIB** = `scale[7:6] index[5:3] base[2:0]`. EA = base + (index<<scale) + disp;
  `index==100` → no index; `base==101 && mod==00` → disp32 base-less.
- **Immediate**: `imm8` sign-extended for the `83` group; `imm32` otherwise.

## Verification (the M1 gate)

For each test program (smoke + M1 corpus):
```
python3 verif/qemu-trace/gen_trace.py --qemu <qemu-i386> --elf <prog.elf> \
    --out build/m1/<prog>_qemu.vtrace --max-insn <N>
# --init-esp = the ESP the golden reports at n=0 (loader-established; varies per
# program with the argv[0]/env layout). The gate (verif/run-m1.sh) extracts it
# from <prog>_qemu.vtrace's first record. 0x40c34910 is the smoke value.
<tb_ventium> --image <prog.flat> --load <addr> --entry <addr> \
    --init-esp <golden-n0-esp> --out build/m1/<prog>_rtl.vtrace --max-insn <N>
python3 verif/diff/compare.py --mode func \
    build/m1/<prog>_qemu.vtrace build/m1/<prog>_rtl.vtrace    # must exit 0
```
**Gate: every M1 test program is func-diff-clean (exit 0, no length mismatch).**
