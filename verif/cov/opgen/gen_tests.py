#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Generate ONE assembly test per P54C opcode (from opspec.json), each covering
all the cases for THAT opcode: every register for its reg/rm operands, the
disp0/disp8/disp32 + SIB memory forms, and a spread of immediate values. The
exhaustive ModRM/SIB EA decode itself is covered once by gen_easweep.py (LEA),
so per-opcode memory cases use a handful of representative in-buffer forms.

Correctness is SELF-CHECKING: every generated .s is assembled (gas rejects a
mis-encoded operand) and the opgen runner diffs it against the QEMU golden, so a
wrong generation shows up as an assemble-fail or a divergence, never a silent
miss. Opcodes the generator cannot mechanically emit (x87 stack, far ptr,
privileged, string-with-side-effects, intentionally-faulting) are routed to the
halt/known lane or listed in opgen_status.txt for explicit handling — the full
555-opcode checklist (opspec.txt) is the audit list.

Output: verif/cov/opgen/tests/op_<key>/op_<key>.s + manifest.json, and
        opgen_status.txt (per-opcode: GEN / HALT / MANUAL + reason).
"""
from __future__ import annotations
import json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
SPEC = os.path.join(HERE, "opspec.json")

# width(bits) by operand type letter group
def width_of(t):
    if t in ("b", "bs", "bss"):
        return 8
    if t in ("w", "wi"):
        return 16
    return 32     # v/vqp/vds/d/dqp... -> 32-bit in our flat 32-bit corpus

R8  = ["al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"]
R16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"]
R32 = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]
def regs(w):
    return R8 if w == 8 else R16 if w == 16 else R32
# registers swept as the r/m / reg operand. ALL encodings except ESP (whose
# register-direct arithmetic would corrupt the stack pointer). ESI/EDI ARE swept
# (so their ModRM rm=110/111 register form is covered) but are RE-INITIALISED
# (REINIT) before any memory case, since the prologue uses them as the buffer
# base/index — otherwise a reg-direct write to ESI/EDI corrupts the later mem EA.
def safe_regs(w):
    if w == 8:
        return ["al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"]
    if w == 16:
        return ["ax", "cx", "dx", "bx", "bp", "si", "di"]
    return ["eax", "ecx", "edx", "ebx", "ebp", "esi", "edi"]

# restore the buffer base (%esi) + index (%edi) after the reg-direct sweep.
REINIT = ["    movl  %esp, %esi", "    movl  $8, %edi"]

SUF = {8: "b", 16: "w", 32: "l"}
IMM = {8: ("$0x00", "$0x7f", "$0x80", "$0xff"),
       16: ("$0x0000", "$0x7fff", "$0x8000", "$0xffff"),
       32: ("$0x00000000", "$0x7fffffff", "$0x80000000", "$0xffffffff")}

# memory r/m forms (all land in the 256-byte buffer at %esi; %edi is a small index)
MEM = ["(%esi)", "4(%esi)", "64(%esi)", "(%esi,%edi,1)", "8(%esi,%edi,4)"]

# mnemonics we will NOT auto-generate here (routed elsewhere). Reasons keyed.
SKIP = {
    # privileged / system -> would #GP or HALT in user mode
    "LGDT": "priv", "LIDT": "priv", "LLDT": "priv", "LTR": "priv", "LMSW": "priv",
    "CLTS": "priv", "INVD": "priv", "WBINVD": "priv", "INVLPG": "priv", "HLT": "priv",
    "RDMSR": "priv", "WRMSR": "priv", "RDPMC": "priv", "RSM": "priv", "ARPL": "sys",
    "SGDT": "sys-mem", "SIDT": "sys-mem", "SLDT": "sys", "STR": "sys", "SMSW": "sys",
    "LAR": "sys", "LSL": "sys", "VERR": "sys", "VERW": "sys",
    "CPUID": "gated", "RDTSC": "gated",
    # far / segment transfers + segment loads -> selector model / #GP
    "CALLF": "far", "JMPF": "far", "RETF": "far", "LDS": "seg", "LES": "seg",
    "LSS": "seg", "LFS": "seg", "LGS": "seg", "POP CS": "far",
    # interrupts / faults -> deliver / HALT
    "INT": "fault", "INT1": "fault", "INT3": "fault", "INTO": "fault", "IRET": "sys",
    "IRETD": "sys", "BOUND": "fault", "UD2": "fault", "F00F": "fault",
    # port I/O -> #GP in user mode (covered by --cosim covio)
    "IN": "io", "OUT": "io", "INS": "io", "OUTS": "io",
    # not P54C / undocumented-removed / undefined
    "LOADALL": "not-p54c", "UD": "undef", "UD1": "undef", "UD0": "undef",
    "SALC": "undoc", "SETALC": "undoc", "LEAVE": "stackframe",
    # undocumented x87 alias mnemonics gas cannot assemble (redundant encodings)
    "FSTP1": "x87-undoc", "FCOM2": "x87-undoc", "FCOMP3": "x87-undoc",
    "FXCH4": "x87-undoc", "FCOMP5": "x87-undoc", "FXCH7": "x87-undoc",
    "FSTP8": "x87-undoc", "FSTP9": "x87-undoc", "FFREEP": "x87-undoc",
    # standalone prefix opcodes (covered in combination, not alone)
    "LOCK": "prefix", "REP": "prefix", "REPE": "prefix", "REPNE": "prefix",
    "REPZ": "prefix", "REPNZ": "prefix", "REPN": "prefix",
    "CS": "prefix", "DS": "prefix", "ES": "prefix", "SS": "prefix",
    "FS": "prefix", "GS": "prefix",
    # x87: routed to the x87 generator path below (is_x87) — not here.
}

# Intel mnemonic -> the AT&T name gas wants (when they differ).
ATT = {"PUSHAD": "pushal", "POPAD": "popal", "PUSHFD": "pushfl", "POPFD": "popfl",
       "PUSHA": "pushaw", "POPA": "popaw", "PUSHF": "pushfw", "POPF": "popfw"}
SEGREGS = {"ES", "CS", "SS", "DS", "FS", "GS"}


def key_of(s):
    k = s["opval"]
    if s["esc"]:
        k = "0f" + k
    if s["opcd_ext"] is not None:
        k += "_" + s["opcd_ext"]
    if s["pref"]:
        k += "_p" + s["pref"]
    # x87 (and other) reg-form ops share opcode+/digit but differ by the secondary
    # byte (sec_opcd: F0=F2XM1 .. FF=FCOS, C9=FXCH, ...) and mem/nomem form — fold
    # both into the key so each encoding gets its OWN test (no collapse).
    if s.get("sec_opcd"):
        k += "_" + s["sec_opcd"]
    elif s.get("mod_attr"):
        k += "_" + s["mod_attr"][:3]      # mem / nom
    elif s["is_x87"]:
        ms = [o["a"] for o in s["operands"]]
        k += "_m" if any(m == "M" for m in ms) else \
             "_r" if any(m in ("ES", "EST") for m in ms) else "_n"
    return k.lower()


# x87 memory operand-type -> gas size suffix (plain real/int loads+stores).
X87SUF = {"sr": "s", "dr": "l", "er": "t", "wi": "s", "di": "l", "qi": "ll"}
# mnemonics whose size is implied by the mnemonic itself (no extra suffix).
X87_IMPLIED = ("fldcw", "fnstcw", "fstcw", "fldenv", "fnstenv", "fstenv",
               "frstor", "fnsave", "fsave", "fbld", "fbstp", "fnstsw", "fstsw")
# reg-form two-operand x87 with the RESULT in ST0:  <mn> %st(i), %st
X87_TWO_ST = {"fadd", "fmul", "fsub", "fsubr", "fdiv", "fdivr"}
# the POP variants put the result in ST(i):           <mn> %st, %st(i)
X87_POP = {"faddp", "fmulp", "fsubp", "fsubrp", "fdivp", "fdivrp"}


def emit_branch(s, MN):
    mn = MN.lower()
    far = (s["esc"] == "0F") or (s["opval"] in ("E9", "E8"))   # rel32 forms
    has_imm = any(o["a"] == "I" for o in s["operands"])
    L = []
    if mn == "jmp":
        L += (["    jmp  8f", "    .fill 200,1,0x90", "8:"] if far
              else ["    jmp  1f", "    nop", "1:"])
        return L, "GEN", "jmp-rel"
    if mn == "call":
        # call a routine that returns; balance an extra slot for a possible ret imm.
        L += ["    pushl $0", "    call 9f", "    jmp  7f", "9:", "    ret  $4", "7:"]
        return L, "GEN", "call-rel"
    if mn in ("ret", "retn"):
        if has_imm:   # RET imm16 — caller pushes the slot it pops
            L += ["    pushl $0", "    call 9f", "    jmp  7f", "9:", "    ret  $4", "7:"]
        else:         # RET near
            L += ["    call 9f", "    jmp  7f", "9:", "    ret", "7:"]
        return L, "GEN", "ret"
    if mn in ("jcxz", "jecxz"):
        L += ["    xorl %ecx, %ecx", f"    {mn}  1f", "    nop", "1:",   # taken
              "    movl $1, %ecx",  f"    {mn}  1f", "    nop", "1:"]    # not taken
        return L, "GEN", "jcxz"
    if mn in ("loop", "loope", "loopz", "loopne", "loopnz"):
        L += ["    movl $3, %ecx", "    xorl %eax, %eax", "1:",
              "    cmpl %eax, %eax",          # ZF=1 (for loope/loopz)
              f"    {mn}  1b"]
        return L, "GEN", "loop"
    # conditional Jcc
    if far:
        L += [f"    {mn}  8f", "    jmp  8f", "    .fill 200,1,0x90", "8:"]
    else:
        L += ["    xorl %eax, %eax", f"    {mn}  1f", "    nop", "1:",
              "    incl %eax",       f"    {mn}  1f", "    nop", "1:"]
    return L, "GEN", "jcc"


def emit_x87(s):
    mn = s["mnem"].lower()
    # obsolete/no-effect control ops gas may not assemble (the doc='u' undocumented
    # aliases are already routed out at the top of emit_lines).
    if mn in ("feni", "fdisi", "fsetpm", "fneni", "fndisi", "fnsetpm"):
        return None, "MANUAL", "x87-obsolete"
    ops = s["operands"]
    methods = [o["a"] for o in ops]
    types = [o["t"] for o in ops]
    # FNSTSW AX / FSTSW AX
    if any(o["t"] == "AX" for o in ops):
        return [f"    {mn}  %ax"], "GEN", "x87-stsw-ax"
    # no-operand (FNOP/FCHS/FABS/FLD1/FNINIT/F2XM1/FYL2X/FSQRT/FUCOMPP/FCOMPP...)
    if all(o["a"] == "#" for o in ops):
        return [f"    {mn}"], "GEN", "x87-noop"
    # memory form
    mem = next((o["t"] for o in ops if o["a"] == "M"), None)
    if mem is not None:
        suf = "" if mn in X87_IMPLIED else X87SUF.get(mem, "")
        # FLDENV/FRSTOR/FNSAVE read/write a big block — the 256B buffer covers it.
        return [f"    {mn}{suf}  (%esi)", f"    {mn}{suf}  32(%esi)"], "GEN", "x87-mem"
    # register (stack) form: sweep ST(i)
    if any(o["a"] in ("ES", "EST") for o in ops):
        L = []
        for i in range(8):
            if mn in X87_TWO_ST:
                L.append(f"    {mn}  %st({i}), %st")
            elif mn in X87_POP:
                L.append(f"    {mn}  %st, %st({i})")
            else:
                L.append(f"    {mn}  %st({i})")
        return L, "GEN", "x87-reg"
    return None, "MANUAL", "x87-other"


def first_two_methods(s):
    ms = [(o["k"], o["a"], o["t"]) for o in s["operands"]]
    return ms


def emit_lines(s):
    """Return (lines, status, reason). status in GEN/HALT/MANUAL."""
    mn = s["mnem"]
    if mn in SKIP:
        return None, "MANUAL", SKIP[mn]
    if s.get("doc") == "u" or s.get("part_alias"):   # undoc / redundant alias
        return None, "MANUAL", "undoc-alias"          # (FSTP1/FCOM2/FFREEP/...)
    if s["is_x87"]:
        return emit_x87(s)
    # --- near INDIRECT call/jmp (FF /2 = CALL r/m, FF /4 = JMP r/m) ----------
    if mn in ("CALL", "JMP") and s["opval"] == "FF" and s["opcd_ext"] in ("2", "4"):
        L = []
        if mn == "JMP":
            # jump (reg + mem indirect) through a pointer to a forward label
            L += ["    leal 1f, %eax", "    jmp  *%eax", "1:",
                  "    leal 2f, %eax", "    movl %eax, (%esi)", "    jmp  *(%esi)", "2:"]
        else:
            # call a routine via reg + mem indirect; the routine rets
            L += ["    leal 9f, %eax", "    call *%eax", "    jmp 7f",
                  "9:", "    ret", "7:",
                  "    leal 9b, %eax", "    movl %eax, (%esi)", "    call *(%esi)", "    jmp 6f",
                  "6:"]
        return L, "GEN", "indirect-near"
    # --- far indirect / direct (FF /3,/5 m16:16; 9A; EA) -> out of scope -----
    if mn in ("CALL", "JMP") and (s["opcd_ext"] in ("3", "5") or s["opval"] in ("9A", "EA")):
        return None, "MANUAL", "far-transfer"

    # --- control transfers (relative) ---------------------------------------
    if any(o["a"] == "J" for o in s["operands"]) or \
            (mn in ("CALL", "JMP", "RET", "RETN", "LOOP", "LOOPE", "LOOPNE",
                    "LOOPZ", "LOOPNZ", "JCXZ", "JECXZ")
             and not any(o["a"] in ("E", "M", "A") for o in s["operands"])):
        return emit_branch(s, mn)
    ops = s["operands"]
    methods = [o["a"] for o in ops]
    types = [o["t"] for o in ops]
    L = []

    # --- segment PUSH/POP (operand is a literal segment register) -----------
    seg = next((o["t"] for o in ops if o["a"] == "#" and o["t"] in SEGREGS), None)
    if mn == "PUSH" and seg:
        L.append(f"    pushl  %{seg.lower()}")
        L.append("    addl  $4, %esp")     # discard (selector lands in memory, not graded)
        return L, "GEN", "push-seg"
    if mn == "POP" and seg:
        if seg == "CS":
            return None, "MANUAL", "pop-cs-invalid"
        # reload the SAME (valid) selector so no #GP; push it first.
        L.append(f"    pushl  %{seg.lower()}")
        L.append(f"    pop  %{seg.lower()}")
        return L, "GEN", "pop-seg"

    # --- PUSHA/POPA/PUSHF/POPF (AT&T names) ---------------------------------
    if mn in ATT:
        L.append(f"    {ATT[mn]}")
        return L, "GEN", "att-name"

    # --- MOVZX / MOVSX  (G<-E, widening: needs two size suffixes) -----------
    if mn in ("MOVZX", "MOVSX") and len(ops) == 2 and methods == ["G", "E"]:
        dw = width_of(types[0]); sw = width_of(types[1])
        suf = ("z" if mn == "MOVZX" else "s") + SUF[sw] + SUF[dw]
        dreg = safe_regs(dw)[0]
        for r in safe_regs(sw):
            L.append(f"    mov{suf}  %{r}, %{dreg}")
        L += REINIT
        for m in MEM:
            L.append(f"    mov{suf}  {m}, %{dreg}")
        return L, "GEN", "movzx/movsx"

    # --- PUSH imm (68 Iv / 6A Ib) -------------------------------------------
    if mn == "PUSH" and len(ops) == 2 and methods[1] == "I":
        # PUSH imm always pushes a full slot (imm8 is sign-extended) -> pushl.
        iw = width_of(types[1])
        for imm in IMM[iw]:
            L.append(f"    pushl  {imm}")
        return L, "GEN", "push-imm"

    # --- MOV reg,imm (B0-BF: Z + I) -----------------------------------------
    if mn == "MOV" and len(ops) == 2 and methods[0] == "Z" and methods[1] == "I":
        w = width_of(types[0])
        for r in regs(w):
            for imm in IMM[w]:
                L.append(f"    mov{SUF[w]}  {imm}, %{r}")
        return L, "GEN", "mov-reg-imm"

    # --- MUL/IMUL/DIV/IDIV (F6/F7 group /4-/7, implicit AX or EDX:EAX) ------
    if mn in ("MUL", "IMUL", "DIV", "IDIV") and s["opval"] in ("F6", "F7") \
            and s["opcd_ext"] in ("4", "5", "6", "7"):
        w = width_of(types[-1])
        sfx = SUF[w]
        if mn in ("MUL", "IMUL"):
            for r in safe_regs(w):      # multiplier = any r/m
                L.append(f"    {mn.lower()}{sfx}  %{r}")
            L += REINIT
            L.append(f"    {mn.lower()}{sfx}  (%esi)")
        else:                            # DIV/IDIV — divisor must not overlap the dividend
            dividend = ("    movw $0x0041, %ax" if w == 8
                        else "    xorl %edx, %edx\n    movl $0x00004141, %eax")
            setd = (lambda r: f"    movb $7, %{r}") if w == 8 else (lambda r: f"    movl $7, %{r}")
            div_regs = (["bl", "cl", "dl", "bh", "ch", "dh"] if w == 8
                        else ["ecx", "ebx", "esi", "edi"])
            for r in div_regs:
                L += [dividend, setd(r), f"    {mn.lower()}{sfx}  %{r}"]
            L += REINIT + [dividend,
                           ("    movb $7, (%esi)" if w == 8 else "    movl $7, (%esi)"),
                           f"    {mn.lower()}{sfx}  (%esi)"]
        return L, "GEN", "mul/div"

    # --- CMPXCHG (0F B0/B1: r/m, r; implicit AL/eAX) ------------------------
    if mn == "CMPXCHG":
        w = width_of(types[0]); g = safe_regs(w)[1]
        for r in safe_regs(w):
            L.append(f"    {mn.lower()}{SUF[w]}  %{g}, %{r}")
        L += REINIT
        L.append(f"    {mn.lower()}{SUF[w]}  %{g}, (%esi)")
        return L, "GEN", "cmpxchg"

    # --- AAM / AAD (reference mnem AMX / ADX) -------------------------------
    if mn in ("AAM", "AAD", "AMX", "ADX"):
        base = "d4" if mn in ("AAM", "AMX") else "d5"
        L += ["    movw $0x0905, %ax", f"    .byte 0x{base}, 0x0a",   # base 10
              "    movw $0x0905, %ax", f"    .byte 0x{base}, 0x10"]   # base 16
        return L, "GEN", "aam/aad"

    # --- ENTER / LEAVE (stack frame) ---------------------------------------
    if mn == "ENTER":
        L += ["    enter $0, $0", "    leave", "    enter $16, $0", "    leave"]
        return L, "GEN", "enter"
    if mn == "LEAVE":
        L += ["    movl %esp, %ebp", "    pushl $0", "    leave"]
        return L, "GEN", "leave"

    # --- MOV moffs (A0-A3) — known core gap (A0-A3 not decoded); cataloged --
    if mn == "MOV" and any(o["a"] == "O" for o in ops):
        return None, "MANUAL", "mov-moffs-coregap"

    # --- LEA reg, mem -------------------------------------------------------
    if mn == "LEA":
        dreg = safe_regs(32)[0]
        for m in MEM + ["(%esi,%edi,2)", "0x40(%esi,%edi,8)"]:
            L.append(f"    leal  {m}, %{dreg}")
        return L, "GEN", "lea"

    # --- SHLD / SHRD  (Ev, Gv, Ib|CL) ---------------------------------------
    if mn in ("SHLD", "SHRD") and len(ops) == 3:
        w = width_of(types[0]); g = safe_regs(w)[1]
        cnt = "%cl" if any(o["a"] == "#" for o in ops[2:]) else IMM[8][1]
        for r in safe_regs(w):
            L.append(f"    {mn.lower()}{SUF[w]}  {cnt}, %{g}, %{r}")
        L += REINIT
        L.append(f"    {mn.lower()}{SUF[w]}  {cnt}, %{g}, (%esi)")
        return L, "GEN", "shld/shrd"

    # --- AAD / AAM (#AL,#AH,Ib) ---------------------------------------------
    if mn in ("AAD", "AAM"):
        # bare form (base 10) + explicit-base imm form
        L.append(f"    movw  $0x0905, %ax")
        L.append(f"    {mn.lower()}")
        L.append(f"    movw  $0x0905, %ax")
        L.append(f"    .byte 0x{ 'd5' if mn=='AAD' else 'd4' }, 0x10")  # base 16
        return L, "GEN", "aad/aam"

    # --- CMPXCHG8B  (Mq) ----------------------------------------------------
    if mn == "CMPXCHG8B":
        L += ["    movl $0x11223344, (%esi)", "    movl $0x55667788, 4(%esi)",
              "    cmpxchg8b (%esi)",          # mismatch -> EDX:EAX <- mem, ZF=0
              "    cmpxchg8b (%esi)"]          # now match -> mem <- ECX:EBX, ZF=1
        return L, "GEN", "cmpxchg8b"

    # --- string ops (MOVS/STOS/LODS/SCAS/CMPS): DS:ESI / ES:EDI in-buffer ----
    if mn in ("MOVS", "STOS", "LODS", "SCAS", "CMPS"):
        w = width_of(types[-1]) if types else 8
        sfx = SUF[w]
        L += ["    cld", "    movl %esp, %esi", "    leal 80(%esp), %edi"]
        L.append(f"    {mn.lower()}{sfx}")    # one element (no REP; deterministic)
        L.append(f"    {mn.lower()}{sfx}")
        return L, "GEN", "string"
    if mn in ("XLAT", "XLATB"):
        L += ["    movl %esp, %ebx", "    xorl %eax, %eax", "    xlatb"]
        return L, "GEN", "xlat"

    # --- PUSH/POP r/m (FF/6 PUSH Ev, 8F/0 POP Ev) ---------------------------
    if mn in ("PUSH", "POP") and len(ops) >= 1 and \
            any(o["a"] in ("E", "M") for o in ops):
        w = 32
        for r in safe_regs(w):
            L.append(f"    {mn.lower()}l  %{r}")
        L += REINIT
        L.append(f"    {mn.lower()}l  (%esi)")
        return L, "GEN", "push/pop-rm"

    # --- pattern: no explicit operands (NOP, CLC, CWDE, ...) ----------------
    if not ops or all(o["a"] == "#" for o in ops):
        L.append(f"    {mn.lower()}")
        return L, "GEN", "noop/implicit"

    # --- pattern: acc,Ib / acc,Iv  (#AL,Ib  #rAX,Iv) ------------------------
    if len(ops) == 2 and ops[0]["a"] == "#" and ops[1]["a"] == "I":
        w = width_of(types[1])
        acc = {8: "al", 16: "ax", 32: "eax"}[w]
        for imm in IMM[w]:
            L.append(f"    {mn.lower()}{SUF[w]}  {imm}, %{acc}")
        return L, "GEN", "acc,imm"

    # --- pattern: Z (register encoded in opcode): INC/DEC/PUSH/POP/BSWAP r --
    if any(o["a"] == "Z" for o in ops):
        w = width_of(next(o["t"] for o in ops if o["a"] == "Z"))
        for r in safe_regs(w):
            L.append(f"    {mn.lower()}  %{r}")
        return L, "GEN", "reg-in-opcode"

    # --- pattern: single E/M operand groups (NOT, NEG, MUL, IMUL r/m, ...) --
    if len(ops) == 1 and methods[0] in ("E", "M"):
        w = width_of(types[0])
        for r in safe_regs(w):
            L.append(f"    {mn.lower()}{SUF[w]}  %{r}")
        L += REINIT
        for m in MEM:
            L.append(f"    {mn.lower()}{SUF[w]}  {m}")
        return L, "GEN", "unary-rm"

    # --- pattern: E,G or G,E (two-operand ALU/MOV/etc.) ---------------------
    if len(ops) == 2 and set(methods) <= {"E", "G"}:
        # determine which operand is r/m (E) and which is reg (G)
        w = width_of(types[0])
        wr = safe_regs(w)
        other = wr[0]
        # reg-direct: sweep the r/m register; AT&T order is src,dst
        # direction: ops[0]=dst, ops[1]=src (from XML). build src,dst.
        dst_a, src_a = methods[0], methods[1]
        for rm in wr:
            # put the swept register on the E side, a fixed reg on the G side
            if dst_a == "E":      # dst is r/m, src is reg  ->  <mn> %other, %rm
                L.append(f"    {mn.lower()}{SUF[w]}  %{other}, %{rm}")
            else:                  # dst is reg, src is r/m  ->  <mn> %rm, %other
                L.append(f"    {mn.lower()}{SUF[w]}  %{rm}, %{other}")
        L += REINIT
        # memory r/m forms
        for m in MEM:
            if dst_a == "E":
                L.append(f"    {mn.lower()}{SUF[w]}  %{other}, {m}")
            else:
                L.append(f"    {mn.lower()}{SUF[w]}  {m}, %{other}")
        # carry-in diversity: ADC/SBB results depend on CF -> run each with CF=0
        # and CF=1 so the carry-in adder path is exercised both ways.
        if mn in ("ADC", "SBB"):
            for cf in ("clc", "stc"):
                L.append(f"    {cf}")
                if dst_a == "E":
                    L.append(f"    {mn.lower()}{SUF[w]}  %{other}, %{wr[1]}")
                else:
                    L.append(f"    {mn.lower()}{SUF[w]}  %{wr[1]}, %{other}")
        # operand-size (66) prefix: 16-bit form of a 32-bit op exercises the
        # operand-size-override decode + the 16-bit datapath the suite else misses.
        if w == 32:
            w16 = safe_regs(16); o16 = w16[0]
            for rm in w16[1:4]:
                if dst_a == "E":
                    L.append(f"    {mn.lower()}w  %{o16}, %{rm}")
                else:
                    L.append(f"    {mn.lower()}w  %{rm}, %{o16}")
        return L, "GEN", "rm,reg"

    # --- pattern: E,I (group 80/81/83, TEST, MOV imm, ...) ------------------
    if len(ops) == 2 and methods[0] in ("E", "M") and methods[1] == "I":
        w = width_of(types[0])          # r/m width drives the mnemonic suffix
        iw = width_of(types[1])         # immediate width (imm8 for shifts/BT-imm)
        for r in safe_regs(w):
            for imm in IMM[iw]:
                L.append(f"    {mn.lower()}{SUF[w]}  {imm}, %{r}")
        L += REINIT
        for imm in IMM[iw]:
            L.append(f"    {mn.lower()}{SUF[w]}  {imm}, (%esi)")
        # operand-size (66) prefix: 16-bit imm-form exercises the operand-size
        # decode + 16-bit immediate path for the group-1 / TEST / shift-imm ops.
        if w == 32:
            iw16 = min(iw, 16)
            for r in safe_regs(16)[:3]:
                L.append(f"    {mn.lower()}w  {IMM[iw16][1]}, %{r}")
        return L, "GEN", "rm,imm"

    # --- pattern: E,1 or E,CL  shifts/rotates (D0-D3, C0-C1) ----------------
    if len(ops) == 2 and methods[0] in ("E", "M") and ops[1]["a"] == "#" \
            and ("1" in types[1] or "CL" in (ops[1]["t"] or "")):
        w = width_of(types[0])
        for r in safe_regs(w):
            L.append(f"    {mn.lower()}{SUF[w]}  %cl, %{r}")
        # RCL/RCR rotate THROUGH carry -> exercise CF=0 and CF=1 in.
        if mn in ("RCL", "RCR"):
            for cf in ("clc", "stc"):
                L += [f"    {cf}", f"    {mn.lower()}{SUF[w]}  %cl, %{safe_regs(w)[1]}"]
        return L, "GEN", "shift-cl"

    # --- pattern: G,E,I  three-operand IMUL --------------------------------
    if len(ops) == 3 and methods[0] == "G" and methods[1] == "E" and methods[2] == "I":
        w = width_of(types[0])
        for r in safe_regs(w):
            L.append(f"    {mn.lower()}{SUF[w]}  {IMM[w][1]}, %{r}, %{r}")
        L += REINIT
        for m in MEM:
            L.append(f"    {mn.lower()}{SUF[w]}  {IMM[w][1]}, {m}, %{safe_regs(w)[0]}")
        return L, "GEN", "reg,rm,imm"

    return None, "MANUAL", "operand-pattern:" + ",".join(f"{m}{t}" for m, t in zip(methods, types))


def setup_prologue():
    # reserve a 256-byte zero buffer at %esi, %edi small index; non-ESP first insn.
    return [
        "    xorl  %eax, %eax",
        "    subl  $256, %esp",
        "    movl  %esp, %esi",
        "    movl  $8, %edi",
        "    movl  $0x11223344, (%esi)",
        "    movl  $0x55667788, 64(%esi)",
        "    movb  $0x5a, 4(%esi)",
    ]


def write_test(s, lines):
    key = key_of(s)
    d = os.path.join(TESTS, "op_" + key)
    os.makedirs(d, exist_ok=True)
    body = []
    body.append("# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)")
    body.append("# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1")
    ext = f"/{s['opcd_ext']}" if s["opcd_ext"] is not None else ""
    pref = f" [{s['pref']}]" if s["pref"] else ""
    body.append(f"# GENERATED op_{key}: {s['opcode']}{ext}{pref} {s['mnem']} "
                f"({','.join(o['a']+o['t'] for o in s['operands'])})")
    body.append("    .text")
    body.append("    .globl _start")
    body.append("_start:")
    body += setup_prologue()
    if s["is_x87"]:
        # finit + fill all 8 stack slots with distinct constants so reg-form ops
        # (ST(0..7)) and stores have valid operands.
        body += ["    finit", "    fldz", "    fld1", "    fldl2t", "    fldl2e",
                 "    fldpi", "    fldlg2", "    fldln2", "    fld1"]
    body += lines
    body.append("    addl  $256, %esp")
    body.append("    movl  $1, %eax")
    body.append("    xorl  %ebx, %ebx")
    body.append("    int   $0x80")
    open(os.path.join(d, f"op_{key}.s"), "w").write("\n".join(body) + "\n")
    n = (len(lines) + len(setup_prologue())) * 2 + 60   # margin for LOOP iterations
    json.dump({
        "name": "op_" + key, "src": f"op_{key}/op_{key}.s",
        "elf": f"op_{key}/op_{key}.elf", "image": f"op_{key}/op_{key}.flat",
        "load_addr": "0x08048000", "entry": "0x08048000", "max_insn": n,
        "x87": s["is_x87"],
    }, open(os.path.join(d, "manifest.json"), "w"), indent=2)


def write_rep_test():
    """REP/REPE/REPNE string loops with the data-dependent termination paths the
    minimal op_prefixes test doesn't reach: a full-count REP MOVS, a REPE CMPS
    that terminates EARLY when bytes differ (ZF->0), a REPNE SCAS that stops on a
    match (ZF->1), and a REP with ECX=0 (immediate no-op)."""
    d = os.path.join(TESTS, "op_rep")
    os.makedirs(d, exist_ok=True)
    L = ["# GENERATED op_rep: REP/REPE/REPNE termination paths",
         "    .text", "    .globl _start", "_start:"]
    L += setup_prologue()
    L += [
        "    movl  %esp, %esi", "    leal  -64(%esp), %edi",
        "    movl  $0x44332211, (%esi)", "    movl  $0x88776655, 4(%esi)",
        "    movl  $8, %ecx", "    cld", "    rep movsb",
        "    movl  %esp, %esi", "    leal  -64(%esp), %edi",
        "    movl  $0x000000ff, 4(%edi)",
        "    movl  $16, %ecx", "    repe cmpsb",
        "    movl  %esp, %edi", "    movb  $0x22, %al",
        "    movl  $16, %ecx", "    repne scasb",
        "    movl  %esp, %esi", "    leal  -64(%esp), %edi",
        "    xorl  %ecx, %ecx", "    rep movsb",
    ]
    L += ["    movl  $1, %eax", "    xorl  %ebx, %ebx", "    int   $0x80"]
    open(os.path.join(d, "op_rep.s"), "w").write("\n".join(L) + "\n")
    json.dump({"name": "op_rep", "src": "op_rep/op_rep.s",
               "elf": "op_rep/op_rep.elf", "image": "op_rep/op_rep.flat",
               "load_addr": "0x08048000", "entry": "0x08048000", "max_insn": 120},
              open(os.path.join(d, "manifest.json"), "w"), indent=2)


def write_prefix_test():
    """Synthetic cross-cutting test for the legacy PREFIX opcodes (LOCK F0,
    REP/REPNE F3/F2, segment-overrides 26/2E/36/3E/64/65, operand/addr-size
    66/67) — they are skip-as-standalone but their decode IS testable applied to
    a real instruction. Covers the prefix-handling decode the per-opcode tests
    never reach."""
    d = os.path.join(TESTS, "op_prefixes")
    os.makedirs(d, exist_ok=True)
    L = ["# GENERATED op_prefixes: legacy prefix decode in combination",
         "    .text", "    .globl _start", "_start:"]
    L += setup_prologue()
    L += [
        "    lock addl  %eax, (%esi)",        # F0 LOCK + ALU mem
        "    lock orl   $1, (%esi)",
        "    lock xchgl %eax, (%esi)",        # LOCK + XCHG (implicit lock)
        "    movl  %es:(%esi), %eax",         # 26 ES override
        "    movl  %cs:(%esi), %ebx",         # 2E CS override
        "    movl  %ss:(%esi), %ecx",         # 36 SS override
        "    movl  %ds:(%esi), %edx",         # 3E DS override
        "    addw  %ax, (%esi)",              # 66 operand-size override
        "    leal  (%bx,%si), %eax",          # 67 address-size override
        "    movl  %esp, %esi",               # restore (DS:ESI default for string)
        "    leal  80(%esp), %edi",
        "    movl  $3, %ecx",
        "    rep movsb",                      # F3 REP + string
        "    movl  %esp, %esi", "    movl  $0, %ecx",
        "    repe cmpsb",                     # F3 REPE
        "    movl  $0, %ecx",
        "    repne scasb",                    # F2 REPNE
    ]
    L += ["    movl  $1, %eax", "    xorl  %ebx, %ebx", "    int   $0x80"]
    open(os.path.join(d, "op_prefixes.s"), "w").write("\n".join(L) + "\n")
    json.dump({"name": "op_prefixes", "src": "op_prefixes/op_prefixes.s",
               "elf": "op_prefixes/op_prefixes.elf", "image": "op_prefixes/op_prefixes.flat",
               "load_addr": "0x08048000", "entry": "0x08048000", "max_insn": 80},
              open(os.path.join(d, "manifest.json"), "w"), indent=2)


def main():
    spec = json.load(open(SPEC))
    os.makedirs(TESTS, exist_ok=True)
    # remove stale op_* dirs (opcodes that left scope) so the runner never
    # discovers a test that should no longer exist.
    import shutil
    for d in os.listdir(TESTS):
        if d.startswith("op_") and os.path.isdir(os.path.join(TESTS, d)):
            shutil.rmtree(os.path.join(TESTS, d))
    status = {"GEN": [], "MANUAL": [], "HALT": []}
    for s in spec:
        lines, st, reason = emit_lines(s)
        ext = f"/{s['opcd_ext']}" if s["opcd_ext"] is not None else ""
        tag = f"{s['opcode']}{ext} {s['mnem']}"
        if st == "GEN" and lines:
            write_test(s, lines)
            status["GEN"].append((key_of(s), tag, reason))
        else:
            status[st if st in status else "MANUAL"].append((key_of(s), tag, reason))

    write_prefix_test()
    write_rep_test()
    rep = []
    rep.append(f"opgen status — {len(spec)} P54C opcodes")
    rep.append(f"  GEN (auto test written): {len(status['GEN'])}")
    rep.append(f"  MANUAL (needs handling): {len(status['MANUAL'])}")
    rep.append("=" * 70)
    rep.append("\n## MANUAL — explicit list (nothing silently dropped):")
    from collections import Counter
    by_reason = Counter(r for _, _, r in status["MANUAL"])
    for reason, c in by_reason.most_common():
        rep.append(f"\n  [{reason}]  ({c})")
        for k, tag, r in status["MANUAL"]:
            if r == reason:
                rep.append(f"      {tag}")
    open(os.path.join(HERE, "opgen_status.txt"), "w").write("\n".join(rep) + "\n")
    print("\n".join(rep[:5]))
    print(f"  wrote {len(status['GEN'])} op_* tests -> {TESTS}")
    print("  manual breakdown:", dict(by_reason))


if __name__ == "__main__":
    main()
