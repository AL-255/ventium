# Ventium ISA Coverage Matrix

Status of the integer (one-byte + `0F` two-byte) and x87 ISA as actually decoded
in `rtl/core/core.sv`. This replaces the unqualified "full integer ISA" claim
flagged in `REVIEW_Jun5.md` §1 with a machine-checkable family-by-family table.

**Scope line:** Ventium implements a broad IA-32 / P54C integer subset plus a
normal-operand x87 datapath. **Instructions not listed as IMPLEMENTED HALT
loudly (no silent misexecution):** any decode path that does not match an
implemented arm falls to a `default` (or guarded `else`) that sets
`d_unknown=1'b1`, which routes the FSM to `S_HALT` (`core.sv:19`,
`core.sv:2029`, `core.sv:1281`). A HALT is never a wrong retire — it is a hard
stop, so the differential gate cannot mistake an unimplemented opcode for a
clean run.

## How the HALT set is derived

Status is read directly from decode in `rtl/core/core.sv`. An instruction is:

- **IMPLEMENTED** — its opcode has a decode arm that sets a real `d_kind` /
  `d_sysop` / `d_fxop` / branch fields and never reaches `d_unknown` on that
  path.
- **PARTIAL** — implemented for the forms the corpus needs, but specific
  sub-forms (a `mod`/`reg` subcase, a non-default operand class, or a
  mode/feature gate) fall to `d_unknown` and HALT, OR an architectural detail
  (e.g. `#DE` on divide-by-zero) is not raised.
- **HALT (deferred)** — every decode path for that opcode sets `d_unknown=1'b1`
  (or it has no arm and hits the one-byte `default` at `core.sv:2029`). These
  are the real coverage gaps.

The HALT gaps below were confirmed by grepping every `d_unknown=1'b1`
occurrence in `core.sv` and reading the guarding opcode/comment.

---

## Integer — one-byte opcodes

| Family | Opcodes | Status | Evidence (core.sv) |
| --- | --- | --- | --- |
| ALU r/m,r,imm (ADD/OR/ADC/SBB/AND/SUB/XOR/CMP, group-1 `80/81/83`) | 00–3D, 80–83 | IMPLEMENTED | fast path `S_PIPE` + slow `K_ALU`; flags QEMU-matched |
| INC/DEC/PUSH/POP r (single-byte) | 40–5F | IMPLEMENTED | `K_*`/`K_STKMISC` arms |
| PUSHA / POPA | 60 / 61 | IMPLEMENTED (modeled by effect) | `K_STKMISC` SM_PUSHA/SM_POPA, micro-sequenced in `S_USEQ` (`core.sv:1311-1312`; exec `core_exec.svh:479`) |
| PUSH imm / IMUL r,r/m,imm | 68/6A, 69/6B | IMPLEMENTED | `K_IMUL2` 3-op (`core.sv:1322,1336`) |
| INS / OUTS (string port I/O) | 6C/6D | IMPLEMENTED (cosim/co-sim gated) | `K_STR` ST_INS (`core.sv:1586`) |
| Jcc rel8 | 70–7F | IMPLEMENTED | branch decode |
| MOV / TEST / XCHG / LEA r/m | 88–8D, 84–87 | IMPLEMENTED | `K_MOV`/`K_ALU`/`K_LEA` |
| NOP / XCHG eAX,r | 90–97 | IMPLEMENTED | `core.sv:1494` |
| CWDE/CDQ, PUSHF/POPF, SAHF/LAHF | 98/99, 9C/9D, 9E/9F | IMPLEMENTED (PUSHF/POPF modeled by effect via `S_USEQ`) | `K_STKMISC` SM_PUSHF/SM_POPF (`core.sv:1500-1501`) |
| MOV moffs, string MOVS/STOS/LODS/SCAS/CMPS | A0–A3, A4–A7, AA–AF | IMPLEMENTED (string = modeled by effect, REP via `S_USEQ`) | `K_STR` arms (`core.sv:1561-1570`) |
| MOV r,imm | B0–BF | IMPLEMENTED | `core.sv:1285,1290` |
| Shift/rotate group-2 imm8 | C0/C1 | IMPLEMENTED | shift decode |
| RET near (+imm16) | C2 / C3 | IMPLEMENTED (modeled by effect) | `K_CTRL` CT_RETN/CT_RETN_IMM (`core_exec.svh:548-555`) |
| LEAVE / ENTER, MOV r/m,imm | C8/C9, C6/C7 | IMPLEMENTED | `K_*` arms; `t_leave16` |
| INT3 / INT n / INTO / IRET | CC / CD / CE / CF | PARTIAL — IMPLEMENTED in **system mode** (IDT delivery); HALT in user mode (no IDT) | `core.sv:1763,1769,1780,1786` — user path sets `d_unknown` (except `INT 0x80` proxy) |
| Shift/rotate group-2 by 1 / CL | D0–D3 | IMPLEMENTED | `core.sv:1620` |
| **BCD / ASCII adjust: DAA / DAS / AAA / AAS / AAM / AAD** | **27 / 2F / 37 / 3F / D4 / D5** | **IMPLEMENTED (review response, QEMU-exact)** | `K_ALU` `ALU_DAA..ALU_AAD` decode (`core.sv:1509-1520`); exec (`bcd_ax`/`bcd_flags` block) matches QEMU `helper_aaa/aas/daa/das/aam/aad` exactly (`core.sv:2356-2439`). Undefined flags masked via `tracefmt.eflags_undefined_mask`. `AAM` base-0 `#DE` is deferred (quotient/remainder guarded to 0, like native DIV-by-zero — `core.sv:2422-2423`) |
| x87 escapes | D8–DF | PARTIAL (see x87 table) | `core.sv:1853` |
| LOOP/LOOPE/LOOPNE/JCXZ | E0–E3 | IMPLEMENTED | `K_CTRL` CT_LOOP* (`core_exec.svh:556`) |
| IN/OUT imm8 / DX | E4–E7, EC–EF | IMPLEMENTED (out-of-cosim non-`out 0xf4` HALTs) | `core.sv:1824-1842` |
| CALL rel / near JMP rel / far JMP | E8 / E9/EB / EA | IMPLEMENTED (CALL = modeled by effect) | `K_CTRL` CT_CALLREL (`core.sv:1737`); far JMP `SYS_LJMP` (`core.sv:1794`) |
| HLT | F4 | IMPLEMENTED (stops retiring) | `d_halt` (`core.sv:1810`) |
| CLC/STC/CLI/STI/CLD/STD, group-3 (TEST/NOT/NEG/MUL/IMUL/DIV/IDIV), group-4/5 (INC/DEC/CALL/JMP/PUSH) | F5–FF | IMPLEMENTED (MUL/DIV native — see PARTIAL note) | `K_MULDIV` (`core.sv:1684`); CALL-ind `core.sv:1702` |
| **MUL/IMUL/DIV/IDIV (group-3)** | F6/F7 /4–/7 | **PARTIAL — architecturally correct result, but DIV/IDIV do NOT raise `#DE` on divide-by-zero or quotient-overflow** | native `* / %` in single `S_EXEC` arm, no `srcv==0` guard (`core_exec.svh:214-284`) |

### Integer one-byte HALT (deferred) gaps

There are **no whole-opcode one-byte integer HALT gaps** in the current decode.
The BCD/ASCII adjusts (`0x27/0x2F/0x37/0x3F/0xD4/0xD5`) flagged in the review
have been implemented as the review response (see the integer table) — they now
decode to `K_ALU` `ALU_DAA..ALU_AAD` (`core.sv:1509-1520`) and no longer fall to
the one-byte `default` at `core.sv:2029`.

The remaining one-byte boundaries are **mode/feature conditional**, not whole
opcodes (already listed PARTIAL in the integer table):

| Mnemonic | Opcode | Conditional HALT |
| --- | --- | --- |
| INT3 / INT n / INTO / IRET | CC / CD / CE / CF | HALT in **user mode** (no IDT); `INT 0x80` user routes to the proxy (`core.sv:1763,1769,1780,1786`) |
| Other IN/OUT outside co-sim | E4–E7, EC–EF | only `out 0xf4` (isa-debug-exit) is allowed outside co-sim; any other IN/OUT HALTs (`core.sv:1818-1842`) |
| AAM base 0 (`#DE`) | D4 00 | architectural `#DE` is deferred (quotient/remainder guarded to 0; corpus never executes it) (`core.sv:2422-2423`) |

---

## Integer — two-byte `0F` opcodes

| Family | Opcode | Status | Evidence (core.sv) |
| --- | --- | --- | --- |
| LGDT / LIDT | 0F 01 /2,/3 | IMPLEMENTED (system mode) | `SYS_LGDT/SYS_LIDT` (`core.sv:1109-1114`) |
| LTR / STR | 0F 00 /3,/1 | IMPLEMENTED (system mode, reg form) | `SYS_LTR/SYS_STR` (`core.sv:1087-1091`) |
| MOV CRn / MOV DRn | 0F 20/22, 0F 21/23 | IMPLEMENTED (DRn system-mode gated) | `SYS_MOVCR_*` (`core.sv:1116-1136`) |
| RSM | 0F AA | IMPLEMENTED (only inside SMM) | `d_rsm` (`core.sv:1104-1106`) |
| Jcc rel16/32 | 0F 80–8F | IMPLEMENTED | `core.sv:1138` |
| SETcc r/m8 | 0F 90–9F | IMPLEMENTED | `core.sv:1154` |
| MOVZX / MOVSX | 0F B6/B7/BE/BF | IMPLEMENTED | `core.sv:1164` |
| IMUL r,r/m | 0F AF | IMPLEMENTED (native `*`) | `K_IMUL2` (`core.sv:1175`) |
| BSF / BSR | 0F BC/BD | IMPLEMENTED | `core.sv:1197` |
| BSWAP | 0F C8–CF | IMPLEMENTED | `core.sv:1217` |
| CMPXCHG r/m,r | 0F B0/B1 | IMPLEMENTED | `K_CMPXCHG` (`core.sv:1233`) |
| UD2 | 0F 0B | IMPLEMENTED (system: delivers #UD; user: HALT) | `d_ud2` (`core.sv:1277`) |
| BT/BTS/BTR/BTC reg `0F A3/AB/B3/BB`, imm `0F BA` | 0F A3.. / 0F BA | PARTIAL — register destination IMPLEMENTED; **memory destination HALTs** | `mod!=11` sets `d_unknown` (`core.sv:1188,1195`) |
| SHLD / SHRD | 0F A4/A5/AC/AD | PARTIAL — register destination IMPLEMENTED; **memory destination HALTs** | `mod!=11` sets `d_unknown` (`core.sv:1213`) |
| CPUID | 0F A2 | PARTIAL — IMPLEMENTED only under co-sim (`cosim_en`); HALT otherwise | `core.sv:1267-1271` |

### Two-byte `0F` HALT (deferred) gaps

| Mnemonic | Opcode | Why it HALTs |
| --- | --- | --- |
| SLDT / LLDT / VERR / VERW (and `0F 00` memory form) | 0F 00 /0,/2,/4,/5, mem | not the LTR/STR reg subforms → `else d_unknown` (`core.sv:1092-1093`) |
| SMSW / LMSW (and other `0F 01` subforms) | 0F 01 /4,/6,... | not LGDT/LIDT → `d_unknown` (`core.sv:1114`) |
| CMPXCHG8B | 0F C7 /1 | both reg and mem forms `d_unknown`; reg-dst also tagged `d_f00f` for Erratum 81 (`core.sv:1252-1254`) |
| BT/BTS/BTR/BTC **memory dst** | 0F A3/AB/B3/BB, 0F BA mem | `mod!=11` → `d_unknown` (`core.sv:1188,1195`) |
| SHLD / SHRD **memory dst** | 0F A4/A5/AC/AD mem | `mod!=11` → `d_unknown` (`core.sv:1213`) |
| All other `0F xx` (incl. MMX, MSR access, NOP-`0F 1F`, etc.) | various | two-byte `default` `d_unknown` (`core.sv:1281`) |

Note: `INT3/INT n/INTO/IRET` and `MOV DRn` HALT specifically in **user mode**
(no IDT / not a user instruction) but are IMPLEMENTED in system mode; they are
listed PARTIAL above rather than as unconditional gaps.

---

## x87 FPU (escapes D8–DF)

x87 is bit-exact-vs-QEMU for **normal finite values and signed zero at the
default 64-bit precision / round-to-nearest** (`rtl/fpu/fpu_x87_pkg.sv:3-22`).
Out-of-corpus inputs (Inf / NaN / denormal results, non-default RC/PC) are not
guaranteed bit-exact, and the affected decode paths HALT rather than emit a
wrong answer (Tier-3 deferral, `docs/m3-fpu-spec.md`).

| Family | Status | Evidence (core.sv) |
| --- | --- | --- |
| FLD/FST/FSTP m32/m64/m80, FLD/FST st(i), FXCH | IMPLEMENTED | `core.sv:1879-1986` |
| FILD/FIST/FISTP m16/m32/m64 | IMPLEMENTED | `core.sv:1926-2022` |
| FADD/FSUB/FMUL/FDIV (+R, +P, m32/m64/i16/i32, st(i)) | IMPLEMENTED (slow-path `f_eval` helper — modeled by effect) | `FX_AR_*` (`core.sv:1865,1948,1960`); exec `f_eval` at `core.sv:4044,4155-4172`, arm `core.sv:4166` |
| FSQRT | IMPLEMENTED | `core.sv:1907` |
| FCOM/FCOMP/FCOMPP/FUCOM/FUCOMPP/FICOM, FTST, FXAM | IMPLEMENTED | `core.sv:1874,1917,1921,1982,1996` |
| FCHS/FABS, FLD1/FLDZ/FLDPI/... constants, FNOP, FINCSTP/FDECSTP, FFREE | IMPLEMENTED | `core.sv:1894-1906,1978` |
| FLDCW/FNSTCW, FNCLEX/FNINIT, FNSTSW AX/m16 | IMPLEMENTED | `core.sv:1885-1886,1938-1939,1973,2020` |

### x87 HALT (deferred) gaps

| Mnemonic | Opcode | Why it HALTs |
| --- | --- | --- |
| FLDENV / FNSTENV | D9 /4,/6 | `default d_unknown` (`core.sv:1887`) |
| Transcendentals / F2XM1 / FYL2X / FPTAN / FPATAN / FSIN / FCOS / FSCALE / FPREM / FRNDINT etc. | D9 F0–FF (non-impl) | `default d_unknown` (`core.sv:1908`) |
| FCMOVcc / FCOMI / FUCOMI | DA/DB reg forms | `d_unknown` (`core.sv:1922,1940`) |
| FRSTOR / FSAVE / FNSAVE | DD /4,/6 | `default d_unknown` (`core.sv:1974`) |
| FBLD / FBSTP (BCD FP) | DF /4,/6 | `default d_unknown` (`core.sv:2017`) |
| Any other escape sub-form (Inf/NaN/denormal-producing or non-default RC/PC paths) | D8–DF | per-escape `default d_unknown`; `if (d_unknown) d_is_x87=1'b0` (`core.sv:2026`) |

---

## Test coverage of the boundary

Implemented families are exercised by the differential corpus under
`verif/tests/` (e.g. `t_mul`, `t_div`, `t_string`, `t_callret`, `t_stack`,
`t_cmpxchg`, `t_shld`, `t_bit`, and the `tx_*` x87 suite) and by the system
gates under `verif/sys/tests/`. Per `REVIEW_Jun5.md` recommendation 4, the HALT
boundary should also gain focused tests asserting the documented HALT for the
deferred opcodes above so the coverage edge stays machine-checkable.
