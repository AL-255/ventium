# Ventium ISA Coverage Matrix

Family-by-family coverage of the non-MMX Intel Pentium (**P5/P54C**, Family 5) integer, system, and x87 ISA as decoded in `rtl/core/decode_stages.sv`, `rtl/core/decode.sv`, `rtl/core/core.sv`, and `fp_shared/ven_fp_top.sv`.

- **Hardware Qualification Baseline (Nov 2026):** Board-qualified on **RK-XCZU15EG-F** image **`c0e3fe43`** (`161` defines, `40.264133 MHz` STA sign-off, **`0.515778001` total U+V / `0.397847833` primary/U Quake gameplay IPC** across cycles `28,696,827,616–32,989,404,795`), passing CoreMark, cold Windows 95 OSR2 GUI + shutdown, and cold DOS Quake `demo1` (`8.0 FPS`).
- **Loud-Fail Safety Rule:** Unsupported or out-of-scope opcodes **never silently mis-execute**. Unimplemented encodings either raise architectural `#UD` (where required in system mode, such as `UD2`, illegal `LOCK`, or invalid `MOV CRn`/`DRn` encodings) or set `d_unknown = 1'b1` → `S_HALT` (`rsp_unsupported` in `ven_fp_top`). See also [`unsupported-isa.md`](unsupported-isa.md) and the interactive [`docs/sphinx/isa/opcode-map.rst`](sphinx/isa/opcode-map.rst).

---

## 1. Integer & System — One-Byte Opcodes (`00`–`FF`)

| Family | Opcodes | Status | Implementation Notes (`decode.sv` / `decode_stages.sv` / `core.sv`) |
| --- | --- | --- | --- |
| `ADD`/`OR`/`ADC`/`SBB`/`AND`/`SUB`/`XOR`/`CMP` (`r/m`, `r`, `imm`, Group 1) | `00`–`3D`, `80`–`83` | **IMPLEMENTED** | Fast-path `S_PIPE` (`u_pipe`/`v_pipe`) + `K_ALU`; 8/16/32-bit operand & address sizes. |
| Segment pushes/pops (`PUSH`/`POP` `ES`/`CS`/`SS`/`DS`) | `06`/`07`/`0E`/`16`/`17`/`1E`/`1F` | **IMPLEMENTED** | Real, V86, and protected-mode descriptor load/checks (`core_seg_ljmp.svh`). |
| BCD / ASCII adjust (`DAA`, `DAS`, `AAA`, `AAS`, `AAM`, `AAD`) | `27`, `2F`, `37`, `3F`, `D4`, `D5` | **IMPLEMENTED** | `uv_common.sv` / `K_ALU` (`AAM` base-0 `#DE` guarded in non-faulting user mode). |
| `INC`/`DEC`/`PUSH`/`POP` general register | `40`–`5F` | **IMPLEMENTED** | Fast-path `S_PIPE` (including AP-500 ESP-exempt `PUSH`/`POP` pairs) + slow FSM. |
| `PUSHA` / `POPA` | `60` / `61` | **IMPLEMENTED** | `K_STKMISC` (`SM_PUSHA`/`SM_POPA`) 8-transfer sequence in `S_USEQ`. |
| `BOUND r16/32, m16&16/m32&32` | `62` | **IMPLEMENTED** | `K_BOUND`; raises `#BR` (vector 5) when out of bounds (`#UD` on `mod==11`). |
| `ARPL r/m16, r16` | `63` | **HALT (deferred)** | Unimplemented (`d_unknown = 1'b1`). |
| `PUSH imm8/16/32` & `IMUL r, r/m, imm` | `68`/`6A`, `69`/`6B` | **IMPLEMENTED** | `S_PIPE` fast `PUSH imm` + `K_IMUL2` (10-cycle modeled occupancy). |
| String port I/O (`INSB`/`INSW`/`INSD`, `OUTSB`/`OUTSW`/`OUTSD`) | `6C`–`6F` | **IMPLEMENTED (system/SoC)** | `K_STR` I/O string transfers with `REP` and CPL/IOPL/TSS I/O bitmap checks; HALT in plain user-mode TB. |
| `Jcc rel8` | `70`–`7F` | **IMPLEMENTED** | `S_PIPE` `PV`-pairable branch + dual-port 256-entry BTB. |
| `TEST`, `XCHG`, `MOV r/m,r`, `MOV sreg`, `LEA`, `POP r/m` | `84`–`8F` | **IMPLEMENTED** | Fast-path `S_PIPE` for `MOV`/`TEST`/`LEA`; descriptor-checked `MOV sreg` in PM. |
| `NOP`, `XCHG eAX,r`, `CBW`/`CWDE`, `CWD`/`CDQ` | `90`–`99` | **IMPLEMENTED** | `S_PIPE` `NOP` + `K_ALU` / sign-extension arms. |
| Far `CALL ptr16:16/32` (`9A`) & `FWAIT` (`9B`) | `9A`, `9B` | **IMPLEMENTED** | `SYS_LJMP` (real/PM code, call gates, 32-bit TSS; task gate/`286` TSS loud-HALT per `unsupported-isa.md`); `FWAIT` checks pending `#MF`. |
| `PUSHF`/`POPF`, `SAHF`/`LAHF` | `9C`–`9F` | **IMPLEMENTED** | `SM_PUSHF`/`SM_POPF` with CPL/IOPL/V86 `IF`/`VIP`/`VIF` semantics. |
| `MOV moffs` & String ops (`MOVS`, `CMPS`, `STOS`, `LODS`, `SCAS` + `REP*`) | `A0`–`AF` | **IMPLEMENTED** | `K_STR` via `S_USEQ` + pipelined 1-elem/clk `REP STOS` cacheable store streaming (`VEN_REP_STOS_STREAM`). |
| `MOV r, imm` & Shift/Rotate Group 2 (`imm8`, `1`, `CL`) | `B0`–`C1`, `D0`–`D3` | **IMPLEMENTED** | `S_PIPE` fast `MOV imm` and `PU` shifts by `1`/`imm8`; `CL` shifts `NP`. |
| `RET` near (`C2`/`C3`), `LES`/`LDS` (`C4`/`C5`), `MOV r/m,imm` (`C6`/`C7`), `ENTER`/`LEAVE` (`C8`/`C9`), `RETF` (`CA`/`CB`) | `C2`–`CB` | **IMPLEMENTED** | Near `RET` + 4-entry RAS; real/V86/PM `LES`/`LDS` and inter-privilege `RETF`. |
| `INT3`, `INT n`, `INTO`, `IRET` | `CC`–`CF` | **IMPLEMENTED (system)** | Full real/V86/PM IDT gate & cross-privilege/NT-TSS `IRET` delivery (`boot_mode=user` halts except `INT 0x80` syscall/exit proxy). |
| `XLATB` (`D7`) & `LOOP*`/`JCXZ`/`JECXZ` (`E0`–`E3`) | `D7`, `E0`–`E3` | **IMPLEMENTED** | `XLATB` address/segment-aware lookup; `K_CTRL` loop/counter branches. |
| Port `IN` / `OUT` (`imm8` & `DX`) | `E4`–`E7`, `EC`–`EF` | **IMPLEMENTED (system/SoC)** | CPL/IOPL/V86 TSS I/O-permission bitmap checked; in standalone user TB only `out 0xf4` debug-exit is enabled. |
| `CALL rel`, `JMP rel32/rel8`, far `JMP ptr16:16/32` | `E8`–`EB` | **IMPLEMENTED** | `S_PIPE` `PV` near `CALL`/`JMP`; far `JMP` via `SYS_LJMP` (real/PM/gate/32-bit TSS). |
| `LOCK` (`F0`), `REPNE`/`REP` (`F2`/`F3`), `HLT` (`F4`), `CMC`/`CLC`/`STC`/`CLI`/`STI`/`CLD`/`STD` | `F0`–`FD` | **IMPLEMENTED** | Illegal `LOCK` prefix combinations raise architectural `#UD`; `VEN_L1_AXI` enforces `LOCK` RMW fabric hold. |
| Group 3 (`TEST`/`NOT`/`NEG`/`MUL`/`IMUL`/`DIV`/`IDIV`) & Group 4/5 (`INC`/`DEC`/`CALL`/`JMP`/`PUSH`) | `F6`/`F7`, `FE`/`FF` | **IMPLEMENTED** | `DIV`/`IDIV` raise `#DE` (vector 0) on divide-by-zero & quotient overflow (`pde` gate) and run on iterative `ven_idiv.sv` (`+VEN_IDIV_ITER`). |

---

## 2. Two-Byte `0F` Opcodes

| Family | Opcode | Status | Implementation Notes (`decode_stages.sv`) |
| --- | --- | --- | --- |
| `SLDT` / `STR` / `LLDT` / `LTR` | `0F 00 /0../3` | **PARTIAL (reg implemented; mem HALT)** | Register forms implemented in system mode; memory forms set `d_unknown` (HALT). |
| `VERR` / `VERW` | `0F 00 /4, /5` | **IMPLEMENTED** | Register and memory word forms in protected mode (`S_DQUERY`, `pverrw` gate; `#UD` in real/V86). |
| `SGDT` / `SIDT` / `LGDT` / `LIDT` / `INVLPG` | `0F 01 /0../3, /7` | **IMPLEMENTED** | 16/32-bit operand-size aware (`LGDT` 24-bit mask in `o16`); `INVLPG` flushes I/D TLBs. |
| `SMSW` / `LMSW` | `0F 01 /4, /6` | **PARTIAL** | `SMSW r16/r32` (`mod==11`) implemented; `SMSW m16` and `LMSW` set `d_unknown` (HALT). |
| `LAR` / `LSL` | `0F 02` / `0F 03` | **IMPLEMENTED** | Protected-mode register & memory word selector forms (`S_DQUERY`, `plar` gate). |
| `CLTS` | `0F 06` | **IMPLEMENTED** | CPL0 clear `CR0.TS` (`#GP(0)` if `CPL > 0`). |
| `INVD` / `WBINVD` | `0F 08` / `0F 09` | **IMPLEMENTED (SoC/cosim)** | CPL0 privilege-checked (`d_cacheinv`); HALT in user-only TB. |
| `UD2` | `0F 0B` | **IMPLEMENTED** | Delivers `#UD` (vector 6) in system mode; loud HALT in user-only TB. |
| `MOV CRn` (`CR0`,`CR2`,`CR3`,`CR4`) & `MOV DRn` (`DR0`–`DR7`) | `0F 20`–`0F 23` | **IMPLEMENTED** | Register-only (`mod!=11` or invalid `CR1`/`CR5`–`CR7` raises `#UD`); `DR4`/`DR5` alias or `#UD` per `CR4.DE`; `DR7.GD` `#DB` supported. |
| `RDTSC` & `CPUID` | `0F 31`, `0F A2` | **IMPLEMENTED (SoC/cosim)** | 64-bit cycle counter (`EDX:EAX`) and Pentium Family-5 `CPUID` leaf table (`psoccpuid`); HALT in user-only TB. |
| `WRMSR` / `RDMSR` | `0F 30` / `0F 32` | **HALT (deferred)** | Unimplemented (`d_unknown = 1'b1`). |
| `Jcc rel16/rel32` & `SETcc r/m8` | `0F 80`–`9F` | **IMPLEMENTED** | `0F 8x` fast-pathed (`PV`) in 32-bit mode and `o16`-aware (`rel16`) in real/16-bit mode. |
| `PUSH`/`POP` `FS`/`GS` | `0F A0`/`A1`/`A8`/`A9` | **IMPLEMENTED** | Real, V86, and protected-mode descriptor-checked loads. |
| `BT` / `BTS` / `BTR` / `BTC` (`r` & `imm8`) | `0F A3`/`AB`/`B3`/`BB`, `0F BA` | **IMPLEMENTED** | Register and bit-offset memory RMW forms (`t_bitmem`, `pbitmem`; note `0F BA /0..3` reserved sub-encodings are not rejected). |
| `SHLD` / `SHRD` (`imm8` & `CL`) | `0F A4`/`A5`/`AC`/`AD` | **IMPLEMENTED** | Both register and memory-RMW destinations implemented. |
| `RSM` | `0F AA` | **IMPLEMENTED (SMM)** | Restores P5 SMRAM state map inside SMM (`psmm`); HALT outside SMM. |
| `IMUL r, r/m` | `0F AF` | **IMPLEMENTED** | 2-operand signed multiply (`K_IMUL2`). |
| `CMPXCHG r/m, r` & `XADD r/m, r` | `0F B0`/`B1`, `0F C0`/`C1` | **IMPLEMENTED** | Register and memory RMW forms (`LOCK`-legal on memory). |
| `LSS` / `LFS` / `LGS` | `0F B2` / `B4` / `B5` | **IMPLEMENTED** | Far-pointer GPR + segment loads across real, V86, and protected modes. |
| `MOVZX` / `MOVSX` | `0F B6`/`B7`/`BE`/`BF` | **IMPLEMENTED** | 1-cycle `S_PIPE` fast-path loads (`NP` per AP-500) + slow FSM. |
| `BSF` / `BSR` & `BSWAP r32` | `0F BC`/`BD`, `0F C8`–`CF` | **IMPLEMENTED** | Bit scan and byte-reverse GPR operations. |
| `CMPXCHG8B m64` | `0F C7 /1` | **IMPLEMENTED** | 64-bit memory compare-exchange (`K_CX8B`); illegal `LOCK CMPXCHG8B reg` models Pentium `F00F` Erratum 81 when `errata_en[ERR_F00F]` is set. |
| Post-P54C extensions (`CMOVcc`, MMX, `RDPMC`, `SYSCALL`, `0F 1F` NOP) | various `0F xx` | **UNIMPLEMENTED (non-P54C)** | Intentionally out of P5/P54C scope (`#UD` or loud HALT). |

---

## 3. x87 Floating-Point Unit (`D8`–`DF`, `fp_shared/ven_fp_top.sv`)

Under the production **`VEN_FP_SHARED` + `VEN_TRANSCENDENTAL` + `VEN_FPREM` + `VEN_BCD_ITER` + `VEN_SRT_ITER`** profile (`c0e3fe43`), Ventium implements the complete Pentium P54C x87 instruction set (save for `FXTRACT` `D9 F4`), including all rounding (`RC`) and precision (`PC24`/`PC53`/`PC64`) modes, architectural `C1` round-direction and stack-fault semantics, delayed `#MF` exception reporting, and `CR0.EM`/`MP`/`TS` (`#NM`) traps:

| x87 Family | Status in Production (`VEN_FP_SHARED`) | Notes |
| --- | --- | --- |
| `FLD`/`FST`/`FSTP` (`m32`/`m64`/`m80`/`ST(i)`), `FXCH`, `FFREE`, `FINCSTP`/`FDECSTP`, `FNOP` | **IMPLEMENTED** | Zero-cycle `FXCH` rename queue (`ven_fp_fxch_queue`), exact `C1` & unmasked store range suppression. |
| `FILD` / `FIST` / `FISTP` (`m16`/`m32`/`m64`) & `FBLD` / `FBSTP` (`m80` BCD) | **IMPLEMENTED** | Pre-probed store atomicity (`make fpstore`); iterative `ven_bcd` / `ven_bcd_to_fp` (`-0.0` sign preserved). |
| `FADD`/`FSUB`/`FSUBR`/`FMUL` (`ST(i)`, `+P`, `m32`/`m64`, `FI*` `m16`/`m32`) | **IMPLEMENTED** | Pipelined `ven_fp_alu` with exact IEEE-754 rounding & `C1` direction. |
| `FDIV`/`FDIVR` (`+P`, `m32`/`m64`, `FIDIV*`), `FSQRT`, `FPREM`, `FPREM1` | **IMPLEMENTED** | Unified radix-4 SRT engine (`fpu_srt_div`, `+VEN_FPREM`), optional Erratum 23 (`FDIV` bug). |
| `FCOM`/`FCOMP`/`FCOMPP`, `FUCOM`/`FUCOMP`/`FUCOMPP`, `FICOM`/`FICOMP`, `FTST`, `FXAM` | **IMPLEMENTED** | Full unordered/NaN/zero/denormal classification. |
| `FCHS`, `FABS`, `FLD1`/`FLDL2T`/`FLDL2E`/`FLDPI`/`FLDLG2`/`FLDLN2`/`FLDZ`, `FRNDINT`, `FSCALE` | **IMPLEMENTED** | Shared converter in `ven_fp_misc`. |
| `FLDCW`/`FNSTCW`, `FNSTSW AX`/`m16`, `FNCLEX`/`FNINIT`, `FLDENV`/`FNSTENV`, `FRSTOR`/`FNSAVE` | **IMPLEMENTED** | All four 14/28/94/108-byte real & protected-mode memory layouts. |
| Transcendentals: `F2XM1`, `FYL2X`, `FYL2XP1`, `FPATAN`, `FSIN`, `FCOS`, `FSINCOS`, `FPTAN` | **IMPLEMENTED (`+VEN_TRANSCENDENTAL`)** | `ven_fp_trans` shared polynomial sequencer (gated off only in bare minimal user-TB builds). |
| `FXTRACT` (`D9 F4`) | **HALT (deferred)** | Unimplemented (`d_unknown = 1'b1`). |
| P6+ `FCMOVcc` / `FCOMI` / `FUCOMI` (`DA`/`DB` reg) | **UNIMPLEMENTED (non-P54C)** | P6 instructions absent on real Pentium P54C. |
