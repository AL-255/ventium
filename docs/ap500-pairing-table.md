# U/V pairing — canonical reference (Intel AP-500 / 241799-001)

Transcribed from **AP-500, "Optimizations for Intel's 32-Bit Processors"**
(`ventium-refs/03-optimization-timing/241799-001_AP-500_Optimizations_for_Intel_32bit_Processors.pdf`),
§5.6 (PDF p.15–16) and **Appendix A — Instruction Pairing Summary** (PDF p.27–35).
This is the **authoritative ground truth** for the M4 dual-issue pairing checker —
verify the RTL against this, not the mined summary in `m2-isa-spec.md`.

## Pairing classes (Appendix A legend)

- **UV** — pairable in either pipe.
- **PU** — pairable only if issued to the **U** pipe (pairs with a suitable V-pipe
  instruction; never executes in V).
- **PV** — pairable only if issued to the **V** pipe (can run in U or V, but only
  *pairs* when in V; a branch in U won't pair with the next insn even if predicted
  not-taken).
- **NP** — not pairable; executes alone in the U pipe.
- FP table: **FX** = pairs only with `FXCH`; **NP** = no pairing.

## The five pairing rules (§5.6.1–5.6.5)

1. **Pairability (§5.6.2):** both instructions must be pairable per the class table
   below, and the second must be allowed in V (UV or PV) while the first occupies U.
2. **No instruction-cache split (§5.6.1):** both must be in the I-cache; *exception*
   — pairing is allowed if the first instruction is one byte.
3. **Register contention (§5.6.3)** blocks pairing:
   - **flow-dependence** — first *writes* a reg the second *reads* (`mov eax,8` /
     `mov [ebp],eax`): NO pair.
   - **output-dependence** — both *write* the same reg (`mov eax,8` /
     `mov eax,[ebp]`): NO pair.
   - **anti-dependence is OK** — first *reads* a reg the second *writes*
     (`mov eax,ebx` / `mov ebx,[ebp]`): pairs.
   - **eflags exception** — two ALU ops that both write EFLAGS DO pair; the paired
     result carries the **V-pipe** instruction's condition codes.
   - **Partial-register = full register for contention:** a byte/word reg counts as
     its containing 32-bit reg, so `mov al,1` / `mov ah,0` do **NOT** pair (apparent
     EAX output dependence). ← easy to get wrong.
4. **Special pairs (§5.6.4)** — allowed despite register deps (implicit ESP / flags):
   - Stack: `push reg/imm ; push reg/imm` · `push reg/imm ; call` · `pop reg ; pop reg`
   - Flags: `cmp ; jcc` · `add ; jne`
5. **Execution restrictions (§5.6.5)** — pairs that issue but don't run fully parallel:
   - **D-cache bank conflict:** if both access the same bank (physical-address bits
     **2–4 equal**; cache = 8 banks × 32-bit), the V-pipe access waits → **+1 clock**
     on the V-pipe instruction.
   - A **multi-cycle U-pipe** instruction executes alone until its last memory access
     (inter-pipe memory-ordering).

## Integer instruction classification (Appendix A, exhaustive)

**UV** (pair in either pipe):
`ADD, AND, OR, XOR, SUB, CMP, INC, DEC, MOV` (data; reg/mem/imm — **not** seg/CR/DR),
`LEA, NOP`, `PUSH reg`, `PUSH imm`, `POP reg`, and **TEST** only in the forms
`reg,reg` / `mem,reg` / `imm,accumulator(eAX)`.

**PU** (U-pipe, pairable):
`ADC, SBB`, and the **shift/rotate by 1 or by immediate** forms of
`RCL, RCR, ROL, ROR, SAL, SAR, SHL, SHR` (reg or mem). Also **prefixed
instructions** are PU (per §5.6.2.3). FP `FADD/FMUL/FLD` are PU-class on the integer
side (see FP table for FXCH pairing).

**PV** (V-pairable):
`CALL` *direct near (same segment)*, `JMP` *short* and *direct near*, and `Jcc`
(both short and the `0F`-prefixed near forms). Plus `FXCH` (FP).

**NP** (never pair — notable / easy-to-miss ones):
- shift/rotate **by CL** (`SHL…/ROL… reg/mem,CL`) — NP (only by-1/by-imm are PU).
- **`SHLD`/`SHRD` — all forms NP** (not pairable at all).
- **`NEG`, `NOT`** — NP (unary, despite looking ALU-like).
- **`MOVZX`/`MOVSX`** — NP (0F-prefixed, 3+ cycles).
- **`XCHG`, `XADD`, `BSWAP`, `SETcc`** — NP.
- **`BT`/`BTC`/`BTR`/`BTS`, `BSF`/`BSR`** — NP.
- **`JCXZ`/`JECXZ` — NP** (unlike `Jcc`, these do NOT pair).
- `CALL`/`JMP` **register/memory-indirect** and **far** — NP (only direct near = PV).
- `PUSH mem`, `POP mem`, `PUSH/POP seg`, `PUSHA/POPA`, `PUSHF/POPF`, `LAHF/SAHF` — NP.
- `MUL, IMUL, DIV, IDIV` — NP. `CBW/CWDE, CWD/CDQ` — NP.
- `TEST imm,reg` and `TEST imm,mem` — NP (only the UV forms above pair).
- All string ops (`MOVS/STOS/LODS/SCAS/CMPS`, `REP*`), `LOOP/LOOPx`, `RET`, `ENTER`,
  `LEAVE` — NP.
- `AAA/AAD/AAM/AAS, DAA/DAS`, `ARPL, BOUND`, `CMPXCHG/CMPXCHG8B`, `XLAT` — NP.
- Flag ops `STC/CLC/CMC, STD/CLD, STI/CLI` — NP.
- All system/privileged (`MOV CR/DR/seg, LGDT…, INVD, WBINVD, RDMSR/WRMSR, RSM, HLT,
  INT/INTO, IRET, LAR/LSL/LTR/STR, VERR/VERW, SMSW/LMSW, CLTS, WAIT`) — NP.
- I/O instructions (`IN/OUT`) — NP.

## Floating-point classification (Appendix A FP table)

**FX** (pairs with a following `FXCH`):
`FABS, FCHS, FADD, FADDP, FSUB, FSUBP, FSUBR, FSUBRP, FMUL, FMULP, FDIV, FDIVP,
FDIVR, FDIVRP, FCOM, FCOMP, FUCOM, FUCOMP, FUCOMPP, FTST`, `FXCH`, and
`FLD` (32-bit mem / 64-bit mem / `ST(i)` only).

**NP** (FP, no pairing): everything else, incl. `FLD m80`, `FLD1/FLDZ/FLDPI/FLDL2E/
FLDL2T/FLDLG2/FLDLN2`, `FILD/FIST/FISTP/FIADD/FISUB/FIMUL/FIDIV/FICOM…` (all integer-
mem FP ops), `FSQRT, FSCALE, FRNDINT, FXTRACT, FPREM/FPREM1`, `FST/FSTP/FSTCW/FSTSW/
FSTENV/FSAVE/FLDCW/FLDENV/FRSTOR, FINIT/FCLEX, FINCSTP/FDECSTP, FFREE, FNOP, FWAIT`,
and all transcendentals (`F2XM1, FSIN, FCOS, FSINCOS, FPTAN, FPATAN, FYL2X, FYL2XP1`).

## Use in Ventium

- **M4 pairing checker** must implement exactly this classification + the §5.6.3–5.6.5
  conditions. Verify the RTL's pair/no-pair decision against this table (especially
  the subtleties flagged above: partial-reg contention, TEST/PUSH/POP operand-form
  dependence, `SHLD/SHRD`/`NEG`/`NOT`/`JCXZ` = NP, only *direct-near* branches PV,
  the eflags-write & anti-dependence exceptions, and the special pairs).
- **Cross-check** against the independent measurements in Agner Fog's instruction
  tables (`ventium-refs/03-optimization-timing/agner-fog-instruction-tables.pdf`) when
  they disagree; AP-500 is Intel-first-party and is the primary authority here.
