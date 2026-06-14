.. _opcode-map:

Ventium x86 Opcode-Map Reference (auto-generated)
=================================================

.. note::
   This page is **generated** by ``tools/opcode_map/gen_opcode_map.py`` from
   ``tools/opcode_map/coverage_data.json`` and verified against
   ``rtl/core/core.sv`` on every Sphinx build (``.github/workflows/docs.yml``).
   Do not edit by hand — update the JSON and re-run the generator.

Complete one-byte (primary) and two-byte (``0F``-prefixed) x86 opcode maps as
decoded by the Ventium P54C core in **functional mode** (the KV260 board path,
``cycle_mode=0``). Reference model: ``qemu -cpu pentium`` (P54C: no MMX/SSE).
Out-of-scope opcodes HALT loudly (``d_unknown`` -> ``S_HALT``); they are never
silently mis-executed.

Status legend
-------------

.. list-table::
   :header-rows: 1
   :widths: 8 18 74

   * - Glyph
     - Status
     - Meaning
   * - ``I``
     - implemented
     - Fully decoded and retired; behaviour QEMU-matched for the P54C model.
   * - ``~``
     - partial
     - Decoded, but some ModRM/x87 sub-forms, modes, or value-ranges are gated off and HALT.
   * - ``S``
     - system-only
     - Decodes only in ``sys_mode``; user mode HALTs.
   * - ``X``
     - gap
     - Architecturally-valid P54C opcode with no decode arm -> HALTs. (Implementation target.)
   * - ``P``
     - prefix
     - Legacy/segment/operand prefix; consumed in the prefix loop.
   * - ``.``
     - undefined
     - Not a P54C instruction (MMX/SSE/post-Pentium/reserved); HALTs.

Primary one-byte opcode map
---------------------------

High nibble runs down the left, low nibble across the top. Each cell is a
terse mnemonic followed by its status glyph.

.. code-block:: text

          x0          x1          x2          x3          x4          x5          x6          x7          x8          x9          xA          xB          xC          xD          xE          xF
     0x  ADDr/m8,r I ADDr/m16/ I ADDr8,r/m I ADDr16/32 I ADDAL,imm I ADDeAX,im I PUSHES    I POPES     I ORr/m8,r8 I ORr/m16/3 I ORr8,r/m8 I ORr16/32, I ORAL,imm8 I OReAX,imm I PUSHCS    I 0F(two-by P
     1x  ADCr/m8,r I ADCr/m16/ I ADCr8,r/m I ADCr16/32 I ADCAL,imm I ADCeAX,im I PUSHSS    I POPSS     I SBBr/m8,r I SBBr/m16/ I SBBr8,r/m I SBBr16/32 I SBBAL,imm I SBBeAX,im I PUSHDS    I POPDS     I
     2x  ANDr/m8,r I ANDr/m16/ I ANDr8,r/m I ANDr16/32 I ANDAL,imm I ANDeAX,im I ESsegment P DAA       I SUBr/m8,r I SUBr/m16/ I SUBr8,r/m I SUBr16/32 I SUBAL,imm I SUBeAX,im I CSsegment P DAS       I
     3x  XORr/m8,r I XORr/m16/ I XORr8,r/m I XORr16/32 I XORAL,imm I XOReAX,im I SSsegment P AAA       I CMPr/m8,r I CMPr/m16/ I CMPr8,r/m I CMPr16/32 I CMPAL,imm I CMPeAX,im I DSsegment P AAS       I
     4x  INCeAX    I INCeCX    I INCeDX    I INCeBX    I INCeSP    I INCeBP    I INCeSI    I INCeDI    I DECeAX    I DECeCX    I DECeDX    I DECeBX    I DECeSP    I DECeBP    I DECeSI    I DECeDI    I
     5x  PUSHeAX   I PUSHeCX   I PUSHeDX   I PUSHeBX   I PUSHeSP   I PUSHeBP   I PUSHeSI   I PUSHeDI   I POPeAX    I POPeCX    I POPeDX    I POPeBX    I POPeSP    I POPeBP    I POPeSI    I POPeDI    I
     6x  PUSHA/PUS I POPA/POPA I BOUNDr,m1 X ARPLr/m16 X FSsegment P GSsegment P Operand-s P Address-s P PUSHimm16 I IMULr16/3 I PUSHimm8( I IMULr16/3 I INSBm8,DX ~ INSW/INSD ~ OUTSBDX,m X OUTSW/OUT X
     7x  JOrel8    I JNOrel8   I JB/JC/JNA I JAE/JNB/J I JE/JZrel8 I JNE/JNZre I JBE/JNAre I JA/JNBEre I JSrel8    I JNSrel8   I JP/JPErel I JNP/JPOre I JL/JNGEre I JGE/JNLre I JLE/JNGre I JG/JNLEre I
     8x  group-1r/ I group-1r/ I group-1r/ X group-1r/ I TESTr/m8, I TESTr/m16 I XCHGr/m8, I XCHGr/m16 I MOVr/m8,r I MOVr/m16/ I MOVr8,r/m I MOVr16/32 I MOVr/m16, ~ LEAr16/32 I MOVSreg,r ~ POPr/m16/ I
     9x  NOP/XCHGe I XCHGeAX,e I XCHGeAX,e I XCHGeAX,e I XCHGeAX,e I XCHGeAX,e I XCHGeAX,e I XCHGeAX,e I CWDE/CBW  I CDQ/CWD   I CALLfarpt I FWAIT/WAI I PUSHF/PUS I POPF/POPF I SAHF      I LAHF      I
     Ax  MOVAL,mof I MOVeAX,mo I MOVmoffs8 I MOVmoffs1 I MOVSB     I MOVSW/MOV I CMPSB     I CMPSW/CMP I TESTAL,im I TESTeAX,i I STOSB     I STOSW/STO I LODSB     I LODSW/LOD I SCASB     I SCASW/SCA I
     Bx  MOVAL,imm I MOVCL,imm I MOVDL,imm I MOVBL,imm I MOVAH,imm I MOVCH,imm I MOVDH,imm I MOVBH,imm I MOVeAX,im I MOVeCX,im I MOVeDX,im I MOVeBX,im I MOVeSP,im I MOVeBP,im I MOVeSI,im I MOVeDI,im I
     Cx  ROL/ROR/R I ROL/ROR/R I RETimm16( I RET(near) I LESr,m16: ~ LDSr,m16: ~ MOVr/m8,i ~ MOVr/m,im ~ ENTERimm1 X LEAVE     I RETFimm16 ~ RETF      ~ INT3      ~ INTimm8   ~ INTO      ~ IRET      ~
     Dx  ROL/ROR/R I ROL/ROR/R I ROL/ROR/R I ROL/ROR/R I AAMimm8   ~ AADimm8   I (undefine . XLATB     X FADD/FMUL ~ FLD/FST/F ~ FIADD/FIC ~ FILD/FIST ~ FADD/FMUL ~ FLD/FSTm6 ~ FIADDm16; ~ FILD/FIST ~
     Ex  LOOPNErel I LOOPErel8 I LOOPrel8  I JECXZrel8 I INAL,imm8 ~ INeAX,imm ~ OUTimm8,A ~ OUTimm8,e ~ CALLrel16 I JMPrel16/ I JMPfarptr ~ JMPrel8   I INAL,DX   ~ INeAX,DX  ~ OUTDX,AL  ~ OUTDX,eAX ~
     Fx  LOCK      P INT1/ICEB X REPNE     P REP/REPE  P HLT       I CMC       I TEST/NOT/ ~ TEST/NOT/ ~ CLC       I STC       I CLI       I STI       I CLD       I STD       I INC/DECr/ ~ INC/DEC/C ~

Secondary ``0F`` opcode map
---------------------------

High nibble runs down the left, low nibble across the top. Each cell is a
terse mnemonic followed by its status glyph.

.. code-block:: text

          x0          x1          x2          x3          x4          x5          x6          x7          x8          x9          xA          xB          xC          xD          xE          xF
     0x  GRP6(SLDT ~ GRP7(SGDT ~ LARr,r/m  X LSLr,r/m  X (undefine . (undefine . CLTS      X (undefine . INVD      I WBINVD    I (undefine . UD2(#UD)  S (undefine . (undefine . (undefine . (reserved .
     1x  (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (P6+/CETm I NOPr/m(mu I
     2x  MOVr32,CR I MOVr32,DR S MOVCRn,r3 I MOVDRn,r3 S (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine .
     3x  WRMSR     X RDTSC     I RDMSR     X (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine . (undefine .
     4x  CMOVOr,r/ X CMOVNOr,r X CMOVB/CMO X CMOVAE/CM X CMOVE/CMO X CMOVNE/CM X CMOVBE/CM X CMOVA/CMO X CMOVSr,r/ X CMOVNSr,r X CMOVP/CMO X CMOVNP/CM X CMOVL/CMO X CMOVGE/CM X CMOVLE/CM X CMOVG/CMO X
     5x  MOVMSKPSr X SQRTPS/SQ X RSQRTPS/R X RCPPS/RCP X ANDPS/AND X ANDNPS/AN X ORPS/ORPD X XORPS/XOR X ADDPS/ADD X MULPS/MUL X CVTPS2PD/ X CVTDQ2PS/ X SUBPS/SUB X MINPS/MIN X DIVPS/DIV X MAXPS/MAX X
     6x  PUNPCKLBW X PUNPCKLWD X PUNPCKLDQ X PACKSSWBm X PCMPGTBmm X PCMPGTWmm X PCMPGTDmm X PACKUSWBm X PUNPCKHBW X PUNPCKHWD X PUNPCKHDQ X PACKSSDWm X PUNPCKLQD X PUNPCKHQD X MOVDmm/xm X MOVQmm,mm X
     7x  PSHUFW/PS X Group12:P X Group13:P X Group14:P X PCMPEQBmm X PCMPEQWmm X PCMPEQDmm X EMMS(VZER X VMREADr/m X VMWRITEr, X (undefine X (undefine X HADDPS/HA X HSUBPS/HS X MOVDr/m32 X MOVQmm/m, X
     8x  JOrel16/3 I JNOrel16/ I JB/JC/JNA I JAE/JNB/J I JE/JZrel1 I JNE/JNZre I JBE/JNAre I JA/JNBEre I JSrel16/3 I JNSrel16/ I JP/JPErel I JNP/JPOre I JL/JNGEre I JGE/JNLre I JLE/JNGre I JG/JNLEre I
     9x  SETOr/m8  I SETNOr/m8 I SETB/SETC I SETAE/SET I SETE/SETZ I SETNE/SET I SETBE/SET I SETA/SETN I SETSr/m8  I SETNSr/m8 I SETP/SETP I SETNP/SET I SETL/SETN I SETGE/SET I SETLE/SET I SETG/SETN I
     Ax  PUSHFS    X POPFS     X CPUID     ~ BTr/m,r   ~ SHLDr/m,r ~ SHLDr/m,r ~ (reserved . (reserved . PUSHGS    X POPGS     X RSM       S BTSr/m,r  ~ SHRDr/m,r ~ SHRDr/m,r ~ (group15: . IMULr,r/m I
     Bx  CMPXCHGr/ I CMPXCHGr/ I LSSr,m16: ~ BTRr/m,r  ~ LFSr,m16: ~ LGSr,m16: ~ MOVZXr,r/ I MOVZXr,r/ I (reserved . UD1(reser . BT/BTS/BT ~ BTCr/m,r  ~ BSFr,r/m  I BSRr,r/m  I MOVSXr,r/ I MOVSXr,r/ I
     Cx  XADDr/m8, X XADDr/m16 X (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . Group9:CM X BSWAPEAX  I BSWAPECX  I BSWAPEDX  I BSWAPEBX  I BSWAPESP  I BSWAPEBP  I BSWAPESI  I BSWAPEDI  I
     Dx  (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 .
     Ex  (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 .
     Fx  (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 . (noneinP5 .

Coverage summary
----------------

.. list-table::
   :header-rows: 1
   :widths: 40 30 30

   * - Status
     - Primary (256)
     - ``0F`` (256)
   * - ``I`` implemented
     - 199
     - 56
   * - ``~`` partial
     - 36
     - 15
   * - ``S`` system-only
     - 0
     - 4
   * - ``X`` gap
     - 8
     - 76
   * - ``P`` prefix
     - 12
     - 0
   * - ``.`` undefined
     - 1
     - 105

Detail: partial / gap / system-only cells
-----------------------------------------

Primary map
~~~~~~~~~~~

* ``62`` **BOUND r,m16&16/m32&32** — *gap*. No decode arm exists; is_prefix() excludes 0x62 so it is a real opcode byte that falls to the one-byte default -> d_unknown -> S_HALT. [core.sv:2547 (one-byte default d_unknown); pkg is_prefix() ventium_decode_pkg.sv:93-95 excludes 62]
* ``63`` **ARPL r/m16,r16** — *gap*. No decode arm; not in is_prefix(). Falls to the one-byte default -> d_unknown -> S_HALT. [core.sv:2547 (one-byte default d_unknown)]
* ``6C`` **INSB m8,DX** — *partial*. K_STR ST_INS implemented ONLY under cosim_en\|\|soc_en (per-element S_INS port handshake, REP via S_USEQ). In user mode (both off) it sets d_unknown -> S_HALT. Mode/feature-gated, so partial. [core.sv:2037-2047 (8'h6C/6D; else d_unknown)]
* ``6D`` **INSW/INSD m16/32,DX** — *partial*. Same 6C/6D arm: K_STR ST_INS, width eff_opsize; only under cosim_en\|\|soc_en, else d_unknown -> S_HALT. [core.sv:2037-2047 (8'h6C/6D; else d_unknown)]
* ``6E`` **OUTSB DX,m8** — *gap*. No decode arm — only INS (6C/6D) is implemented (the comment at core.sv:2024 calls INS 'the co-sim's only string-I/O op'). 6E falls to the one-byte default -> d_unknown -> S_HALT. [core.sv:2547 (one-byte default d_unknown); no 8'h6E arm]
* ``6F`` **OUTSW/OUTSD DX,m16/32** — *gap*. No decode arm for OUTS word/dword; falls to the one-byte default -> d_unknown -> S_HALT. [core.sv:2547 (one-byte default d_unknown); no 8'h6F arm]
* ``82`` **group-1 r/m8, imm8 (undocumented alias of 0x80)** — *gap*. No decode arm; the undocumented P54C alias of 0x80 falls through unique-casez to the one-byte default -> d_unknown -> S_HALT. Real silicon executes it like 0x80 but Ventium HALTs loudly on it. [no arm; one-byte default core.sv:2547]
* ``8C`` **MOV r/m16, Sreg** — *partial*. Register-dest form IMPLEMENTED (SYS_MOVSREG_FROM, writes a GPR, all modes). Memory-dest form (mod!=11) is gated on sys_mode (stores the selector via d_store_sreg); in user mode the mem-dest form -> d_unknown -> S_HALT. [core.sv:1894-1912 (user-mode mem path d_unknown at :1910)]
* ``8E`` **MOV Sreg, r/m16** — *partial*. Register-source form IMPLEMENTED in all modes (SYS_MOVSREG_TO: real -> base=sel<<4, PM -> GDT walk in S_SEGLD). Memory-source form (mod!=11) implemented ONLY in real mode (seg_real, low-half seg-load); a PM mem-source MOV Sreg would need the GDT walk and falls to d_unknown -> S_HALT. [core.sv:1917-1936 (PM mem path d_unknown at :1934)]
* ``C4`` **LES r,m16:16** — *partial*. Real-mode 16-bit LES only; PM/32-bit/reg forms HALT. (On modern CPUs C4 is also the 3-byte VEX prefix, out of P54C scope.) [core.sv:1886-1892 8'hC4,8'hC5: implemented ONLY for mod!=11 && seg_real && eff_opsize (real-mode 16-bit). Reg form (mod==11), 32-bit (0x66/no eff_opsize) and protected mode -> else d_unknown (HALT).]
* ``C5`` **LDS r,m16:16** — *partial*. Real-mode 16-bit only; PM/32-bit/reg HALT. (Also 2-byte VEX prefix on modern CPUs, out of scope.) [core.sv:1886-1892 8'hC4,8'hC5: same gate as LES — only mod!=11 && seg_real && eff_opsize; otherwise d_unknown (HALT). d_lseg=SG_DS for C5.]
* ``C6`` **MOV r/m8,imm8 (grp11 /0)** — *partial*. Only the /0 MOV form is architecturally valid; /1-/7 (incl C6 /7=XABORT on modern CPUs) are reserved #UD but here decode as MOV (reg field ignored). Functionally fine for the corpus (only /0 emitted), but reg sub-form not validated. [core.sv:2049-2056 8'hC6: decodes as MOV r/m8,imm8 unconditionally (d_is_mov, ALU_MOV) for any modrm_reg — does NOT check reg==0. Reg and mem forms handled.]
* ``C7`` **MOV r/m,imm (grp11 /0)** — *partial*. Only /0 valid; /1-/7 (C7 /7=XBEGIN modern) reserved but decode as MOV. Note: the 8'hC7 at core.sv:1612 is the TWO-BYTE 0F C7 (CMPXCHG8B), a different opcode. [core.sv:2057-2075 8'hC7 (one-byte): MOV r/m,imm decoded unconditionally for any modrm_reg (no reg==0 check); reg+mem, 16/32-bit forms handled.]
* ``C8`` **ENTER imm16,imm8** — *gap*. isa-coverage.md:53 mislabels 'LEAVE/ENTER' as IMPLEMENTED, but only LEAVE (C9/SM_LEAVE) exists; ENTER (C8) HALTs. Whole-opcode gap. [No 8'hC8 case anywhere in the one-byte casez (grep confirms none); falls to one-byte default core.sv:2547 -> d_unknown=1'b1 -> S_HALT.]
* ``CA`` **RETF imm16** — *partial*. Real-mode far return implemented; protected-mode far return (descriptor/privilege checks) deferred -> HALT. [core.sv:2232-2233 8'hCA -> SYS_RETF, d_ret_imm from imm16. isa-coverage.md:227-229: routed REAL-MODE only (S_RETF, CS base=sel<<4); PM RETF HALTs (routing in core_fetch_decode.svh).]
* ``CB`` **RETF** — *partial*. Real-mode far return implemented; PM RETF deferred. [core.sv:2230-2231 8'hCB -> SYS_RETF, d_ret_imm=0. Real-mode only per isa-coverage.md:227-229 (S_RETF pops IP then CS, base=sel<<4); PM form HALTs.]
* ``CC`` **INT3** — *partial*. system-mode only (IDT); user mode HALTs (no IDT). Partial = mode-gated. [core.sv:2251-2256 8'hCC: sys_mode -> d_int=1,d_int_vec=3 (IDT delivery). USER mode -> d_unknown (HALT). isa-coverage.md:54,78.]
* ``CD`` **INT imm8** — *partial*. System mode: full IDT delivery. User mode: only 0x80 (syscall proxy) handled, all other vectors HALT. [core.sv:2257-2267 8'hCD: sys_mode -> d_int,d_int_imm,d_int_vec=imm8 (IDT). USER mode -> only INT 0x80 routes (d_int80/proxy or d_halt); any other INT n HALTs. isa-coverage.md:54,78.]
* ``CE`` **INTO** — *partial*. system-mode only; user HALTs. [core.sv:2268-2273 8'hCE: sys_mode -> d_int,d_int_vec=4,d_int_cond_of (IDT, conditional). USER mode -> d_unknown (HALT). isa-coverage.md:54,78.]
* ``CF`` **IRET** — *partial*. system-mode near/same-privilege IRET; user HALTs. PM cross-privilege/task-switch IRET not modeled. [core.sv:2274-2277 8'hCF: sys_mode -> d_iret=1 (pop EIP/CS/EFLAGS, near same-privilege). USER mode -> d_unknown (HALT). isa-coverage.md:54,78.]
* ``D4`` **AAM imm8** — *partial*. Result/flags QEMU-exact; architectural #DE on base==0 not raised. Partial per isa-coverage.md:56,80. [core.sv:1970-1972 8'hD4 -> K_ALU ALU_AAM, d_use_imm imm8 base. Exec QEMU-exact (core.sv:2356-2439 BCD block per isa-coverage.md:56). BUT AAM base-0 #DE is deferred (quotient/remainder guarded to 0, core.sv:2422-2423 region per isa-coverage.md:80).]
* ``D7`` **XLATB** — *gap*. Architecturally valid IA-32 instruction with no decode arm -> whole-opcode gap. [No 8'hD7 case (grep confirms); not in the 1101_1??? x87 pattern. Falls to one-byte default core.sv:2547 -> d_unknown -> S_HALT.]
* ``D8`` **FADD/FMUL/FCOM/FSUB/FDIV m32/st(i)** — *partial*. All D8 sub-forms decode; PARTIAL only because x87 is bit-exact ONLY for normal finite values/+-0 at default 64-bit PC/RNE; Inf/NaN/denormal/non-default RC/PC paths HALT (isa-coverage.md:121-127,157). d_is_x87 cleared if d_unknown. [core.sv:2363-2379 (under 8'b1101_1??? at 2355). Mem form: reg 0,1,4,5,6,7 -> FX_AR_M32; reg2 FCOM_M32; default FCOMP. Reg form: 0,1,4,5,6,7 FX_AR_ST0_STI; 2 FCOM_STI; default FCOMP. No d_unknown arm — every ModRM handled.]
* ``D9`` **FLD/FST/FLDCW/FNSTCW + D9 reg group** — *partial*. Reg-form FRNDINT (FC) and FSCALE (FD) now implemented (libm floor/ceil/rint, ldexp). Still HALT: FPREM/FPREM1 (F8/F5 — need an exact-remainder engine), FXTRACT (F4); transcendentals (F0-F3/F9-FF) only under +VEN_TRANSCENDENTAL else d_unknown. [core.sv:2381-2429. Reg adds 8h FC FRNDINT / FD FSCALE (exec FX_FRNDINT/FX_FSCALE); F8 FPREM deferred -> d_unknown.]
* ``DA`` **FIADD/FICOM m32; FUCOMPP** — *partial*. Integer-arith + FICOM + FUCOMPP implemented; FCMOVB/E/BE/U (DA reg forms) deferred -> HALT (isa-coverage.md:154). Plus finite-value caveat. [core.sv:2427-2438. Mem: reg 0,1,4,5,6,7 -> FX_AR_I32; reg2 FICOM_M32; default FICOMP. Reg form: only mrm==E9 -> FUCOMPP; everything else (FCMOVcc) -> d_unknown (HALT).]
* ``DB`` **FILD/FISTP/FLD m80/FNINIT; DB reg** — *partial*. FILD/FIST/FLD-m80/FNCLEX/FNINIT implemented; FCMOVNB/NE/NBE/NU + FCOMI/FUCOMI HALT (isa-coverage.md:154); mem /1,/4,/6 -> d_unknown. Plus finite-value caveat. [core.sv:2440-2457. Mem: /0 FILD_M32,/2 FIST,/3 FISTP,/5 FLD_M80,/7 FSTP_M80; default d_unknown. Reg: mrm E2 FNCLEX, E3 FNINIT; default d_unknown (FCMOVcc/FCOMI/FUCOMI deferred).]
* ``DC`` **FADD/FMUL/FSUB/FDIV m64/st(i)-dest** — *partial*. Arith m64 + ST(i)-dest arith implemented; reg form reg=2/3 (FCOM/FCOMP st(i) via DC, non-canonical) -> d_unknown. Plus finite-value caveat. [core.sv:2459-2479. Mem: reg 0,1,4,5,6,7 FX_AR_M64; reg2 FCOM_M64; default FCOMP. Reg form: 0,1 + 4,5,6,7 (with SUBR/SUB DIVR/DIV bit0 flipped) -> FX_AR_STI_ST0; reg2/3 -> d_unknown.]
* ``DD`` **FLD/FST m64; FFREE/FUCOM; FRSTOR/FNSAVE** — *partial*. FRSTOR/FNSAVE present in enum (M11b) but isa-coverage.md:155 lists them deferred in default build; mem /1,/5 -> d_unknown; reg F0+/F8+ -> d_unknown. Plus finite-value caveat. [core.sv:2481-2502. Mem: /0 FLD_M64,/2 FST,/3 FSTP,/4 FRSTOR,/6 FNSAVE,/7 FNSTSW_M; default d_unknown. Reg: FFREE(C0+),FST st(i)(D0+),FSTP st(i)(D8+),FUCOM(E0+),FUCOMP(E8+); default d_unknown.]
* ``DE`` **FIADD m16; FADDP/FCOMPP** — *partial*. FADDP/FMULP/FSUBRP/FSUBP/FDIVRP/FDIVP + FCOMPP + FIxxx m16 implemented; reg=2/3 non-D9 -> d_unknown. Plus finite-value caveat. [core.sv:2504-2523. Mem: reg 0,1,4,5,6,7 FX_AR_I16; reg2 FICOM_M16; default FICOMP. Reg: mrm D9 FCOMPP; else 0,1 + 4,5,6,7 (SUBR/SUB DIVR/DIV swap) FX_AR_STI_ST0 with pop; reg2/3 -> d_unknown.]
* ``DF`` **FILD/FISTP m16/m64; FBLD/FBSTP; FNSTSW AX** — *partial*. FILD/FIST m16/m64, FBLD/FBSTP (M10), FNSTSW AX implemented; mem /1 -> d_unknown; reg forms other than E0 (incl FCOMIP/FUCOMIP) -> d_unknown. Plus finite-value caveat. [core.sv:2525-2541. Mem: /0 FILD_M16,/2 FIST_M16,/3 FISTP_M16,/4 FBLD,/5 FILD_M64,/6 FBSTP,/7 FISTP_M64; default(/1) d_unknown. Reg: mrm E0 FNSTSW_AX; else d_unknown (FCOMIP/FUCOMIP deferred).]
* ``E4`` **IN AL,imm8** — *partial*. Implemented under co-sim/SoC io-bridge; outside it HALTs (no real port). [core.sv:2326-2330 8'hE4,E5: d_io,d_io_imm,port=imm8,width byte. Decode unconditional but EXEC gated: in co-sim takes io-bus value; outside co-sim only 'out 0xf4' is legal, any other IN/OUT HALTs (isa-coverage.md:59,79).]
* ``E5`` **IN eAX,imm8** — *partial*. co-sim/SoC only; otherwise HALT. [core.sv:2326-2330 8'hE4,E5 -> d_io, port imm8, width eff_opsize. Same co-sim gating as E4 (isa-coverage.md:59,79).]
* ``E6`` **OUT imm8,AL** — *partial*. co-sim/SoC or the 0xf4 terminator; otherwise HALT. [core.sv:2331-2335 8'hE6,E7 -> d_io,d_io_write,port imm8,width byte. EXEC: only 'out 0xf4' (isa-debug-exit) legal outside co-sim; others HALT (isa-coverage.md:59,79).]
* ``E7`` **OUT imm8,eAX** — *partial*. co-sim/SoC only (or 0xf4); otherwise HALT. [core.sv:2331-2335 8'hE6,E7 -> d_io,d_io_write, port imm8, width eff_opsize. Same gating as E6.]
* ``EA`` **JMP far ptr16:off** — *partial*. Real-mode + real->PM transition far JMP implemented; general PM far-jump (gate/TSS) not modeled. Marked partial vs the broad ISA. [core.sv:2282-2297 8'hEA -> SYS_LJMP, off/sel by operand size. isa-coverage.md:60 far JMP via SYS_LJMP. Real-mode/PM-entry transition path (S_LJMP); full PM descriptor far-jump beyond the boot transition is out of scope.]
* ``EC`` **IN AL,DX** — *partial*. co-sim/SoC only; otherwise HALT. [core.sv:2336-2340 8'hEC,ED -> d_io, port=DX, width byte. Co-sim/SoC gated in EXEC; outside HALTs (isa-coverage.md:59,79).]
* ``ED`` **IN eAX,DX** — *partial*. co-sim/SoC only; otherwise HALT. [core.sv:2336-2340 8'hEC,ED -> d_io, port=DX, width eff_opsize. Same gating.]
* ``EE`` **OUT DX,AL** — *partial*. co-sim/SoC only; otherwise HALT. [core.sv:2341-2345 8'hEE,EF -> d_io,d_io_write, port=DX, width byte. Co-sim/SoC gated; outside (except 0xf4 which is imm8) HALTs.]
* ``EF`` **OUT DX,eAX** — *partial*. co-sim/SoC only; otherwise HALT. [core.sv:2341-2345 8'hEE,EF -> d_io,d_io_write, port=DX, width eff_opsize.]
* ``F1`` **INT1/ICEBP** — *gap*. Undocumented single-step/ICEBP opcode; no decode arm. HALTs loudly. [No 8'hF1 case; not a prefix; falls to one-byte default core.sv:2547 -> d_unknown -> S_HALT.]
* ``F6`` **TEST/NOT/NEG/MUL/DIV r/m8 (grp3)** — *partial*. All 8 reg sub-ops implemented; architectural #DE (divide error) is not raised -> partial. [core.sv:2097-2145 8'hF6,F7: reg /0,/1 TEST imm (reg+mem); /2 NOT; /3 NEG; /4-/7 K_MULDIV (MUL/IMUL/DIV/IDIV) — all sub-forms decoded. BUT DIV/IDIV do NOT raise #DE on divide-by-zero/overflow (native \*/% no srcv==0 guard, isa-coverage.md:63, core_exec.svh:214-284).]
* ``F7`` **TEST/NOT/NEG/MUL/DIV r/m (grp3)** — *partial*. All sub-ops implemented; #DE deferred -> partial. [core.sv:2097-2145 8'hF6,F7 (op0==F7 -> d_w=eff_opsize?2:4): same dispatch — /0,/1 TEST imm (reg+mem incl 'test mem,imm'), /2 NOT, /3 NEG, /4-/7 K_MULDIV. #DE not raised on div-by-zero/overflow (isa-coverage.md:63).]
* ``FE`` **INC/DEC r/m8 (grp4)** — *partial*. /0 INC, /1 DEC implemented; reserved /2-/7 mis-decode as DEC rather than #UD (only /0,/1 ever emitted, so functionally fine for the corpus). [core.sv:2146-2150 8'hFE -> ALU_INC if modrm_reg==0 else ALU_DEC; reg+mem forms. Does NOT validate reg<2 — reg /2-/7 (reserved #UD) decode as DEC.]
* ``FF`` **INC/DEC/CALL/JMP/PUSH r/m (grp5)** — *partial*. INC/DEC/CALL-near/JMP-near/PUSH fully implemented; far CALL/JMP-indirect-through-memory real-mode only; /7 reserved and PM/reg far forms HALT. [core.sv:2151-2200 8'hFF: /0 INC,/1 DEC,/2 CALL near,/4 JMP near,/6 PUSH all implemented (reg+mem). /3 CALLF m16:16 and /5 JMPF m16:16 only mod!=11 && seg_real && !paging_on else d_unknown; /7 (and CALLF/JMPF reg/PM forms) -> default d_unknown (HALT).]

Secondary ``0F`` map
~~~~~~~~~~~~~~~~~~~~~

* ``0F 00`` **GRP6 (SLDT/STR/LLDT/LTR/VERR/VERW r/m)** — *partial*. ModRM.reg group. Ventium decodes only the register-form /1 STR and /3 LTR, and ONLY when sys_mode=1; SLDT(/0), LLDT(/2), VERR(/4), VERW(/5), and ALL memory forms set d_unknown->S_HALT, and the whole opcode HALTs in user mode. [core.sv:1412-1424 (STR /1 reg, LTR /3 reg gated on sys_mode; else d_unknown); exec core_exec.svh:103 (SYS_STR), core_fetch_decode.svh:430 (SYS_LTR)]
* ``0F 01`` **GRP7 (SGDT/SIDT/LGDT/LIDT/SMSW/LMSW/INVLPG)** — *partial*. ModRM.reg group. Implemented: /2 LGDT and /3 LIDT (mem, read 6-byte pseudo-desc); /0 SGDT and /1 SIDT (mem store) only when modrm_mod!=11 AND !paging_on. /4 SMSW, /6 LMSW, /7 INVLPG, and all reg forms set d_unknown->S_HALT. System-context (boot path). [core.sv:1451-1463 (LGDT/LIDT/SGDT/SIDT arms; else d_unknown); exec core_fetch_decode.svh:406 (S_LGDT), :450 (S_SGDT)]
* ``0F 02`` **LAR r,r/m** — *gap*. No decode arm; falls to the two-byte default d_unknown->S_HALT. [core.sv:1668 (two-byte default d_unknown); FSM core_fetch_decode.svh:351 (->S_HALT)]
* ``0F 03`` **LSL r,r/m** — *gap*. No decode arm; two-byte default d_unknown->S_HALT. [core.sv:1668 (default d_unknown); core_fetch_decode.svh:351]
* ``0F 06`` **CLTS** — *gap*. Valid P54C system instr (clear CR0.TS); no Ventium decode arm. Two-byte default d_unknown->S_HALT. [core.sv:1668 (default d_unknown); core_fetch_decode.svh:351]
* ``0F 0B`` **UD2 (#UD)** — *system-only*. Architecturally-reserved opcode that raises #UD. Ventium DELIVERS #UD (vector 6) through the IDT only when sys_mode=1 (d_ud2); in user mode it stays d_unknown->S_HALT (no IDT). [core.sv:1664-1666 (if(sys_mode) d_ud2 else d_unknown)]
* ``0F 21`` **MOV r32, DRn** — *system-only*. Move FROM debug reg. Gated on sys_mode (M2S.6): sets SYS_MOVDR_FROM only when sys_mode=1; user mode keeps d_unknown->S_HALT. Also DR7.GD general-detect fault checked. [core.sv:1473-1479 (if(sys_mode) SYS_MOVDR_FROM else d_unknown); exec core_exec.svh:87]
* ``0F 23`` **MOV DRn, r32** — *system-only*. Move TO debug reg. Gated on sys_mode (M2S.6): SYS_MOVDR_TO only when sys_mode=1; user mode keeps d_unknown->S_HALT. [core.sv:1481-1485 (if(sys_mode) SYS_MOVDR_TO else d_unknown); exec core_exec.svh:75]
* ``0F 30`` **WRMSR** — *gap*. Valid P54C system instruction (write model-specific reg from EDX:EAX). No Ventium decode arm; two-byte default d_unknown->S_HALT. (MSR access listed as a deferred gap in isa-coverage.md.) [core.sv:1668 (default d_unknown); isa-coverage.md:113]
* ``0F 32`` **RDMSR** — *gap*. Valid P54C system instruction (read MSR to EDX:EAX). No Ventium decode arm; two-byte default d_unknown->S_HALT. [core.sv:1668 (default d_unknown); isa-coverage.md:113]
* ``0F 40`` **CMOVO r,r/m** — *gap*. CMOVcc post-dates P54C (Pentium Pro). Decoder HALTs loudly. [No 0F op1 case for 0x40; hits two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc is P6, not in the P54C ISA; no K\_ enum exists.]
* ``0F 41`` **CMOVNO r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x41; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 42`` **CMOVB/CMOVC/CMOVNAE r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x42; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 43`` **CMOVAE/CMOVNB/CMOVNC r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x43; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 44`` **CMOVE/CMOVZ r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x44; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 45`` **CMOVNE/CMOVNZ r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x45; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 46`` **CMOVBE/CMOVNA r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x46; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 47`` **CMOVA/CMOVNBE r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x47; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 48`` **CMOVS r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x48; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 49`` **CMOVNS r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x49; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 4A`` **CMOVP/CMOVPE r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x4A; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 4B`` **CMOVNP/CMOVPO r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x4B; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 4C`` **CMOVL/CMOVNGE r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x4C; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 4D`` **CMOVGE/CMOVNL r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x4D; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 4E`` **CMOVLE/CMOVNG r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x4E; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 4F`` **CMOVG/CMOVNLE r,r/m** — *gap*. Not in P54C ISA; HALTs. [No 0F op1 case for 0x4F; two-byte default d_unknown -> S_HALT (core.sv:1668). CMOVcc (P6).]
* ``0F 50`` **MOVMSKPS r32,xmm** — *gap*. SSE, post-P54C; HALTs. No XMM datapath in Ventium. [No 0F op1 case for 0x50; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE (PIII), no K\_/FX\_ enum.]
* ``0F 51`` **SQRTPS/SQRTSS xmm,xmm/m (66/F3/F2 variants)** — *gap*. SSE family, post-P54C; HALTs (all prefix variants since 66/F2/F3 are consumed into pfx then still no case). [No 0F op1 case for 0x51; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 52`` **RSQRTPS/RSQRTSS xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x52; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 53`` **RCPPS/RCPSS xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x53; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 54`` **ANDPS/ANDPD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x54; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE/SSE2.]
* ``0F 55`` **ANDNPS/ANDNPD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x55; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE/SSE2.]
* ``0F 56`` **ORPS/ORPD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x56; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE/SSE2.]
* ``0F 57`` **XORPS/XORPD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x57; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE/SSE2.]
* ``0F 58`` **ADDPS/ADDSS/ADDPD/ADDSD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x58; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 59`` **MULPS/MULSS/MULPD/MULSD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x59; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 5A`` **CVTPS2PD/CVTSS2SD/CVTPD2PS/CVTSD2SS** — *gap*. SSE2, post-P54C; HALTs. [No 0F op1 case for 0x5A; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE2.]
* ``0F 5B`` **CVTDQ2PS/CVTPS2DQ/CVTTPS2DQ** — *gap*. SSE2, post-P54C; HALTs. [No 0F op1 case for 0x5B; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE2.]
* ``0F 5C`` **SUBPS/SUBSS/SUBPD/SUBSD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x5C; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 5D`` **MINPS/MINSS/MINPD/MINSD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x5D; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 5E`` **DIVPS/DIVSS/DIVPD/DIVSD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x5E; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 5F`` **MAXPS/MAXSS/MAXPD/MAXSD xmm,xmm/m** — *gap*. SSE, post-P54C; HALTs. [No 0F op1 case for 0x5F; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE.]
* ``0F 60`` **PUNPCKLBW mm,mm/m (xmm w/66)** — *gap*. MMX, post-P54C; HALTs. No MMX/XMM datapath. [No 0F op1 case for 0x60; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX (P55C).]
* ``0F 61`` **PUNPCKLWD mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x61; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 62`` **PUNPCKLDQ mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x62; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 63`` **PACKSSWB mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x63; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 64`` **PCMPGTB mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x64; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 65`` **PCMPGTW mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x65; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 66`` **PCMPGTD mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x66; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX. (Note: 0x66 as the leading byte is the opsize prefix, handled in pfx loop; here 0x66 is op1 after 0F.)]
* ``0F 67`` **PACKUSWB mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x67; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 68`` **PUNPCKHBW mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x68; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 69`` **PUNPCKHWD mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x69; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 6A`` **PUNPCKHDQ mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x6A; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 6B`` **PACKSSDW mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x6B; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 6C`` **PUNPCKLQDQ xmm,xmm/m (66 only)** — *gap*. SSE2, post-P54C; HALTs (no-prefix encoding is also invalid). [No 0F op1 case for 0x6C; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE2. No-prefix form is undefined.]
* ``0F 6D`` **PUNPCKHQDQ xmm,xmm/m (66 only)** — *gap*. SSE2, post-P54C; HALTs. [No 0F op1 case for 0x6D; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE2. No-prefix form is undefined.]
* ``0F 6E`` **MOVD mm/xmm,r/m32** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x6E; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX/SSE2.]
* ``0F 6F`` **MOVQ mm,mm/m (MOVDQA/MOVDQU xmm w/66/F3)** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x6F; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX/SSE2.]
* ``0F 70`` **PSHUFW/PSHUFD/PSHUFHW/PSHUFLW mm/xmm,mm/m,imm8** — *gap*. Post-P54C (PSHUFW is SSE/MMX-ext); HALTs. [No 0F op1 case for 0x70; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX-ext/SSE2.]
* ``0F 71`` **Group12: PSRLW/PSRAW/PSLLW mm/xmm,imm8 (ModRM.reg /2,/4,/6)** — *gap*. MMX shift-by-imm group, post-P54C; all sub-forms HALT. [No 0F op1 case for 0x71; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX shift group, ModRM-extended.]
* ``0F 72`` **Group13: PSRLD/PSRAD/PSLLD mm/xmm,imm8 (ModRM.reg /2,/4,/6)** — *gap*. MMX shift-by-imm group, post-P54C; all sub-forms HALT. [No 0F op1 case for 0x72; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX shift group, ModRM-extended.]
* ``0F 73`` **Group14: PSRLQ/PSRLDQ/PSLLQ/PSLLDQ mm/xmm,imm8 (ModRM.reg /2,/3,/6,/7)** — *gap*. MMX/SSE2 shift-by-imm group, post-P54C; all sub-forms HALT. [No 0F op1 case for 0x73; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX/SSE2 shift group, ModRM-extended.]
* ``0F 74`` **PCMPEQB mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x74; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 75`` **PCMPEQW mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x75; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 76`` **PCMPEQD mm,mm/m** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x76; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX.]
* ``0F 77`` **EMMS (VZEROUPPER/VZEROALL w/VEX)** — *gap*. MMX EMMS, post-P54C; HALTs. [No 0F op1 case for 0x77; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX (EMMS).]
* ``0F 78`` **VMREAD r/m,r (also Group17 EXTRQ/INSERTQ w/66/F2)** — *gap*. VMX/SSE4a, post-P54C; HALTs. [No 0F op1 case for 0x78; two-byte default d_unknown -> S_HALT (core.sv:1668). VMX (P4+).]
* ``0F 79`` **VMWRITE r,r/m (also EXTRQ/INSERTQ w/66/F2)** — *gap*. VMX/SSE4a, post-P54C; HALTs. [No 0F op1 case for 0x79; two-byte default d_unknown -> S_HALT (core.sv:1668). VMX (P4+).]
* ``0F 7A`` **(undefined; later AMD XOP/SSE-context only)** — *gap*. Reserved/undefined in legacy IA-32 (no architectural Pentium-era mapping); the Ventium decoder HALTs loudly regardless. [No 0F op1 case for 0x7A; two-byte default d_unknown -> S_HALT (core.sv:1668). No canonical legacy IA-32 instruction.]
* ``0F 7B`` **(undefined; reserved in legacy IA-32)** — *gap*. Reserved/undefined in legacy IA-32; HALTs loudly. [No 0F op1 case for 0x7B; two-byte default d_unknown -> S_HALT (core.sv:1668). No canonical legacy IA-32 instruction.]
* ``0F 7C`` **HADDPS/HADDPD xmm,xmm/m (66/F2)** — *gap*. SSE3, post-P54C; HALTs. [No 0F op1 case for 0x7C; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE3. No-prefix form undefined.]
* ``0F 7D`` **HSUBPS/HSUBPD xmm,xmm/m (66/F2)** — *gap*. SSE3, post-P54C; HALTs. [No 0F op1 case for 0x7D; two-byte default d_unknown -> S_HALT (core.sv:1668). SSE3. No-prefix form undefined.]
* ``0F 7E`` **MOVD r/m32,mm (MOVQ xmm,xmm/m w/F3)** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x7E; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX/SSE2.]
* ``0F 7F`` **MOVQ mm/m,mm (MOVDQA/MOVDQU mem w/66/F3)** — *gap*. MMX, post-P54C; HALTs. [No 0F op1 case for 0x7F; two-byte default d_unknown -> S_HALT (core.sv:1668). MMX/SSE2.]
* ``0F A0`` **PUSH FS** — *gap*. Push FS segment register; unimplemented, HALTs loudly. [No arm in two-byte casez (core.sv:1406-1668); 8'hA0 falls to two-byte default core.sv:1668 -> d_unknown=1 -> S_HALT. (The 8'hA0 case at core.sv:1983 is in the ONE-byte else-block, MOV AL,moffs8 — not this 0F path.)]
* ``0F A1`` **POP FS** — *gap*. Pop into FS; unimplemented. [No arm; 8'hA1 -> two-byte default core.sv:1668 -> d_unknown -> S_HALT. (8'hA1 at core.sv:1989 is the one-byte MOV eAX,moffs path.)]
* ``0F A2`` **CPUID** — *partial*. No-operand; IMPLEMENTED under co-sim/SoC, HALTs in plain user mode. isa-coverage.md:102. [core.sv:1630-1635: d_kind=K_CPUID only if (cosim_en \|\| soc_en); else d_unknown -> S_HALT. Leaf table in S_EXEC (qemu -cpu pentium model).]
* ``0F A3`` **BT r/m,r** — *partial*. Memory destination HALTs. isa-coverage.md:100,111. [core.sv:1540-1548 (8'hA3): K_BITTEST reg-dst form (mod==11) implemented; mem-dst (mod!=11) sets d_unknown -> S_HALT (core.sv:1548).]
* ``0F A4`` **SHLD r/m,r,imm8** — *partial*. Memory destination HALTs. isa-coverage.md:101,112. [core.sv:1563-1576 (8'hA4): K_SHLDRD reg-dst (mod==11) implemented with d_shift_imm; mem-dst sets d_unknown -> S_HALT (core.sv:1573).]
* ``0F A5`` **SHLD r/m,r,CL** — *partial*. Memory destination HALTs. [core.sv:1563-1576 (8'hA5): reg-dst (mod==11) implemented, d_shift_cl=1; mem-dst sets d_unknown -> S_HALT (core.sv:1573).]
* ``0F A8`` **PUSH GS** — *gap*. Push GS segment register; unimplemented. [No arm; 8'hA8 -> two-byte default core.sv:1668 -> d_unknown -> S_HALT. (8'hA8 at core.sv:2007 is one-byte TEST AL,imm8.)]
* ``0F A9`` **POP GS** — *gap*. Pop into GS; unimplemented. [No arm; 8'hA9 -> two-byte default core.sv:1668 -> d_unknown -> S_HALT. (8'hA9 at core.sv:2009 is one-byte TEST eAX,imm.)]
* ``0F AA`` **RSM** — *system-only*. Resume from SMM; valid only inside SMM, HALTs elsewhere (incl. user mode). isa-coverage.md:91. [core.sv:1446-1449 (8'hAA): d_rsm=1 only if (sys_mode && smm_active); otherwise d_unknown -> S_HALT.]
* ``0F AB`` **BTS r/m,r** — *partial*. Memory destination HALTs. [core.sv:1540-1548 (8'hAB): K_BITTEST reg-dst (mod==11) implemented; mem-dst sets d_unknown -> S_HALT (core.sv:1548).]
* ``0F AC`` **SHRD r/m,r,imm8** — *partial*. Memory destination HALTs. [core.sv:1563-1576 (8'hAC): K_SHLDRD d_shrd=1 reg-dst implemented; mem-dst sets d_unknown -> S_HALT (core.sv:1573).]
* ``0F AD`` **SHRD r/m,r,CL** — *partial*. Memory destination HALTs. [core.sv:1563-1576 (8'hAD): reg-dst implemented, d_shrd & d_shift_cl; mem-dst sets d_unknown -> S_HALT (core.sv:1573).]
* ``0F B2`` **LSS r,m16:16/32** — *partial*. Implemented only as real-mode 16-bit m16:16 far load; PM/32-bit form HALTs. [core.sv:1516-1523 (8'hB2): decodes (d_lseg=SG_SS) ONLY if (mod!=11 && seg_real && eff_opsize); every other case (incl. all 32-bit/protected-mode forms) sets d_unknown -> S_HALT (core.sv:1522).]
* ``0F B3`` **BTR r/m,r** — *partial*. Memory destination HALTs. [core.sv:1540-1548 (8'hB3): K_BITTEST reg-dst (mod==11) implemented; mem-dst sets d_unknown -> S_HALT (core.sv:1548).]
* ``0F B4`` **LFS r,m16:16/32** — *partial*. Real-mode 16-bit far-pointer load only; PM/32-bit HALTs. [core.sv:1516-1523 (8'hB4): d_lseg=SG_FS only if (mod!=11 && seg_real && eff_opsize); else d_unknown -> S_HALT (core.sv:1522).]
* ``0F B5`` **LGS r,m16:16/32** — *partial*. Real-mode 16-bit far-pointer load only; PM/32-bit HALTs. [core.sv:1516-1523 (8'hB5): d_lseg=SG_GS only if (mod!=11 && seg_real && eff_opsize); else d_unknown -> S_HALT (core.sv:1522).]
* ``0F BA`` **BT/BTS/BTR/BTC r/m,imm8 (grp 8)** — *partial*. ModRM.reg group: /4 BT /5 BTS /6 BTR /7 BTC handled reg-only; memory dst HALTs. Invalid sub-forms /0-/3 are NOT rejected as #UD (decoded as a bit-test). isa-coverage.md:100,111. [core.sv:1550-1556 (8'hBA): K_BITTEST d_bit_imm, d_bit_op=modrm_reg, reg-dst (mod==11) implemented; mem-dst sets d_unknown -> S_HALT (core.sv:1555).]
* ``0F BB`` **BTC r/m,r** — *partial*. Memory destination HALTs. [core.sv:1540-1548 (8'hBB): K_BITTEST reg-dst (mod==11) implemented; mem-dst sets d_unknown -> S_HALT (core.sv:1548).]
* ``0F C0`` **XADD r/m8, r8** — *gap*. XADD is a real P54C instruction but unimplemented; loud HALT, never misexecuted. [Two-byte casez over op1 (core.sv:1406) has no 0F C0 arm; falls to default d_unknown=1 -> HALT (core.sv:1668). isa-coverage.md:113 lists all other 0F xx as two-byte default gaps.]
* ``0F C1`` **XADD r/m16/32, r16/32** — *gap*. Real P54C instruction, unimplemented -> HALT. [No 0F C1 arm in the two-byte casez (core.sv:1406-1669); falls to default d_unknown=1 -> HALT (core.sv:1668).]
* ``0F C7`` **Group 9: CMPXCHG8B m64 (/1)** — *gap*. Group opcode (only /1 CMPXCHG8B defined in P54C). The single valid form (m64) and the invalid reg form both HALT loudly; reg-dst flagged d_f00f so the FSM can reproduce the F00F hang when errata_en[ERR_F00F]. [Explicit arm sets d_unknown=1 for ALL forms (core.sv:1612-1613); /1 reg-dst (mod==11) additionally tagged d_f00f for Erratum 81 (core.sv:1614). isa-coverage.md:110 confirms both reg and mem forms HALT.]

