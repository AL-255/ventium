# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Ventium/P54C instruction metadata used by the assembly workbench.

This is intentionally a mnemonic catalogue, not a generic x86 list.  It is
derived from ``rtl/core/decode_stages.sv`` and the P5 timing classifier in
``verif/qemu-plugins/p5trace.c``.  Form-specific restrictions are called out in
the description/status text so completion never silently advertises SSE/MMX or
a later-x86 instruction that the modeled P54C cannot execute.
"""
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class InstructionInfo:
    mnemonic: str
    signature: str
    description: str
    pipe: str
    stages: tuple[str, ...]
    latency: str
    availability: str = "user"

    @property
    def operands(self):
        """Operand portion of the signature, without its repeated mnemonic."""
        return self.signature[len(self.mnemonic):].strip()

    @property
    def search_text(self):
        return " ".join((
            self.mnemonic, self.signature, self.description, self.pipe,
            self.latency, self.availability,
        )).lower()


_catalog = []


def _add(names, operands, description, pipe="NP", stages=("F", "D", "X"),
         latency="1 cycle", availability="user"):
    for name in names.split():
        _catalog.append(InstructionInfo(
            name, f"{name} {operands}".rstrip(), description, pipe,
            tuple(stages), latency, availability))


# Integer data movement and ALU.
_add("mov", "dst, src", "Copy a register, immediate, segment value, or memory operand.",
     "UV", latency="1 cycle; load result 2 cycles")
_add("movsx movzx", "reg, r/m", "Sign-extend or zero-extend a byte/word into a register.",
     latency="2 cycles")
_add("lea", "reg, [address]", "Compute an effective address without reading memory.", "UV")
_add("xchg", "dst, src", "Exchange register or memory operands.",
     latency="1 cycle register; memory is serialized")
_add("xadd", "dst, src", "Exchange operands and store their sum; updates arithmetic flags.",
     latency="multi-cycle / non-pairable")
_add("cmpxchg", "dst, src", "Compare EAX with dst, then conditionally exchange src.",
     latency="multi-cycle / non-pairable")
_add("cmpxchg8b", "qword ptr [mem]",
     "Compare EDX:EAX with 64-bit memory, conditionally store ECX:EBX.",
     latency="two-word memory RMW")
_add("add", "dst, src",
     "Add the source to the destination and update arithmetic flags.", "UV")
_add("sub", "dst, src",
     "Subtract the source from the destination and update arithmetic flags.", "UV")
_add("and", "dst, src",
     "Bitwise AND the operands, store the result, and update logical flags.", "UV")
_add("or", "dst, src",
     "Bitwise OR the operands, store the result, and update logical flags.", "UV")
_add("xor", "dst, src",
     "Bitwise XOR the operands, store the result, and update logical flags.", "UV")
_add("cmp", "dst, src",
     "Compare by subtraction and update flags without storing the result.", "UV")
_add("adc sbb", "dst, src",
     "Add/subtract with carry. May lead a pair but cannot occupy V.", "PU")
_add("test", "dst, src", "Bitwise AND for flags only.",
     "UV", latency="1 cycle for register/common accumulator forms")
_add("inc dec", "dst", "Increment/decrement while preserving carry.", "UV")
_add("neg not", "dst", "Two's-complement negate or bitwise complement.",
     latency="1 cycle register; memory is serialized")
_add("mul imul", "src", "Integer multiply; IMUL also has two- and three-operand forms.",
     latency="about 10 cycles")
_add("div idiv", "src", "Unsigned/signed divide of the implicit accumulator pair.",
     latency="17–46 cycles by width")
_add("aaa aas daa das aam aad", "",
     "Legacy ASCII/BCD adjustment instruction implemented by the core.",
     latency="slow ALU path")
_add("cbw cwde cwd cdq", "",
     "Sign-extend AL/AX/EAX into the wider implicit accumulator pair.")
_add("bsf bsr", "reg, r/m", "Find the first/last set bit.", latency="4 cycles")
_add("bswap", "reg", "Reverse the byte order of a 32-bit register.",
     latency="slow integer path")
_add("bt btc btr bts", "dst, bit",
     "Test, complement, reset, or set a selected bit.", latency="4 cycles")
_add("shl sal shr sar rol ror rcl rcr", "dst, count",
     "Shift or rotate by 1, CL, or an immediate. Immediate forms may lead U/V.",
     "PU", latency="1 cycle register")
_add("shld shrd", "dst, src, count", "Double-precision shift using two operands.",
     latency="4 cycles")
_add("bound", "reg, [bounds]", "Check a signed value against a memory bounds pair.",
     latency="slow/system path")
_add("arpl", "r/m16, r16", "Adjust a selector's requested privilege level.",
     latency="slow/system path", availability="system/protected mode")
_add("nop", "", "Perform no architectural operation.", "UV")
_add("endbr32", "", "Accepted CET compatibility marker; modeled as a no-op.", "UV")
_add("xlat", "", "Load AL from DS:[(E)BX + AL].", latency="memory load")

# Stack, strings, flags, control flow, and I/O.
_add("push pop", "src", "Push or pop a register, immediate, segment, or memory value.",
     "UV", latency="1 cycle for register forms")
_add("pusha pushad popa popad", "", "Push or pop the complete general-register set.",
     latency="micro-sequenced stack operation")
_add("pushf pushfd popf popfd", "", "Push or pop architectural flags.",
     latency="micro-sequenced stack operation")
_add("enter", "size, level", "Create a stack frame (nesting level 0 is supported).",
     latency="micro-sequenced stack operation")
_add("leave", "", "Release the current stack frame.", latency="stack operation")
_add("call", "target", "Push a return address and transfer control.",
     "PV", latency="1 cycle direct; indirect/far uses slow path")
_add("jmp", "target", "Unconditional control transfer; direct forms can occupy V.",
     "PV")
_add("retn ret retf", "[pop-bytes]", "Return from a near or far procedure.",
     latency="2+ cycles / non-pairable")
_add("jo jno jb jnb jz jnz jbe jnbe js jns jp jnp jl jnl jle jnle",
     "target", "Conditional branch selected by EFLAGS.", "PV")
_add("jc jnae jnc jae je jne ja jna jg jng jge jnge jpe jpo", "target",
     "Assembler alias for a conditional branch selected by EFLAGS.", "PV")
_add("seto setno setb setnb setz setnz setbe setnbe sets setns setp setnp "
     "setl setnl setle setnle", "r/m8",
     "Store a one-byte Boolean selected by EFLAGS.", latency="4 cycles")
_add("setc setnae setnc setae sete setne seta setna setpe setpo "
     "setg setng setge setnge", "r/m8",
     "Assembler alias for a one-byte SETcc result.", latency="4 cycles")
_add("loop loopz loope loopnz loopne jcxz jecxz", "target",
     "Counted/zero-count branch handled on the slow control path.",
     latency="about 5 cycles")
_add("movs movsb movsw movsd stos stosb stosw stosd", "",
     "Move or store one string element; REP is micro-sequenced.",
     stages=("F", "D", "S", "M"), latency="memory/string pipeline")
_add("lods lodsb lodsw lodsd scas scasb scasw scasd", "",
     "Load or scan one string element; REP is micro-sequenced.",
     stages=("F", "D", "S", "M"), latency="memory/string pipeline")
_add("cmps cmpsb cmpsw cmpsd", "",
     "Compare string elements and update flags; REP is micro-sequenced.",
     stages=("F", "D", "S", "M"), latency="memory/string pipeline")
_add("ins insb insw insd outs outsb outsw outsd", "",
     "Transfer a string element through an I/O port.",
     stages=("F", "D", "S", "M"), latency="I/O handshake",
     availability="SoC/co-simulation")
_add("rep repe repz repne repnz lock", "instruction",
     "Legacy repetition/atomic prefix accepted by the decoder.",
     latency="depends on following instruction")
_add("clc stc cmc cld std", "",
     "Clear, set, or complement carry/direction control flags.")
_add("cli sti", "", "Clear or set the interrupt-enable flag.",
     availability="system-oriented")
_add("lahf sahf", "", "Transfer selected status flags to/from AH.")
_add("hlt", "", "Stop retirement and enter the terminal halted state.",
     "NP", stages=("F", "D", "."), latency="terminal")
_add("int int3 into iret iretd", "[vector]",
     "Deliver/return from an interrupt through the IDT.",
     latency="system microcode", availability="system; user INT 0x80 is a stop proxy")
_add("in out", "port", "Read or write an I/O port.",
     latency="I/O handshake", availability="SoC/co-simulation")

# System and protected-mode operations decoded by the current RTL.
_add("lgdt lidt sgdt sidt", "[descriptor]",
     "Load or store a six-byte descriptor-table register.",
     "SYS", stages=("F", "D", "S", "M"), latency="system memory sequence",
     availability="system")
_add("ltr lldt str", "r/m16", "Load/store a task or local-descriptor selector.",
     "SYS", stages=("F", "D", "S"), latency="system descriptor sequence",
     availability="system; implemented forms are restricted")
_add("smsw", "r16", "Store CR0's machine-status word.", "SYS",
     stages=("F", "D", "S"), availability="implemented register form")
_add("lss lfs lgs les lds", "reg, far ptr [mem]",
     "Load a general register and segment selector from a far pointer.",
     "SYS", stages=("F", "D", "M", "S"), latency="segment-load sequence",
     availability="system/protected mode")
_add("cpuid", "", "Return the modeled Pentium identity and feature leaves.",
     "SYS", stages=("F", "D", "S"), availability="SoC/co-simulation")
_add("rdtsc", "", "Read the modeled time-stamp counter into EDX:EAX.",
     "SYS", stages=("F", "D", "S"), availability="SoC/co-simulation")
_add("invd wbinvd", "", "Modeled cache-management serialization/no-op.",
     "SYS", stages=("F", "D", "S"), availability="SoC/co-simulation")
_add("rsm", "", "Restore processor state from the SMM save-state area.",
     "SYS", stages=("F", "D", "S"), latency="long system sequence",
     availability="SMM only")
_add("ud2", "", "Architecturally undefined instruction; delivers #UD in system mode.",
     "SYS", stages=("F", "D", "!"), availability="system fault; user mode halts")

# x87 normal-operand implementation.
_add("fld fild fbld", "src", "Push a real, integer, BCD, constant, or x87 register value.",
     "FP", stages=("F", "D", "FP"), latency="1–2 cycles")
_add("fst fstp fist fistp fbstp", "dst", "Store/convert ST(0), optionally popping it.",
     "FP", stages=("F", "D", "FP", "W"), latency="1+ cycles")
_add("fadd faddp fiadd fsub fsubp fsubr fsubrp fisub fisubr", "[dst, src]",
     "x87 add/subtract family.", "FP", stages=("F", "D", "FP"), latency="3-cycle result")
_add("fmul fmulp fimul", "[dst, src]", "x87 multiply family.",
     "FP", stages=("F", "D", "FP"), latency="3-cycle result / 2-cycle occupancy")
_add("fdiv fdivp fdivr fdivrp fidiv fidivr", "[dst, src]",
     "x87 divide family.", "FP", stages=("F", "D", "FP", "=", "W"),
     latency="about 39 cycles")
_add("fsqrt", "", "Replace ST(0) with its square root.",
     "FP", stages=("F", "D", "FP", "=", "W"), latency="about 70 cycles")
_add("fcom fcomp fcompp ficom ficomp fucom fucomp fucompp ftst fxam", "[src]",
     "Compare/classify x87 operands and update the x87 status word.",
     "FP", stages=("F", "D", "FP"), latency="1 cycle")
_add("fchs fabs", "", "Change or clear ST(0)'s sign.",
     "FP", stages=("F", "D", "FP"), latency="3-cycle result")
_add("fld1 fldz fldpi fldl2e fldl2t fldlg2 fldln2", "",
     "Push a built-in x87 constant.", "FP", stages=("F", "D", "FP"), latency="2 cycles")
_add("fxch ffree fincstp fdecstp fnop", "[st(i)]",
     "Manipulate the x87 stack/tag state.", "FP", stages=("F", "D", "FP"),
     latency="0–1 cycle")
_add("fldcw fnstcw fstcw fnclex fclex fninit finit fnstsw fstsw", "[dst]",
     "Load, store, clear, initialize, or inspect x87 control/status state.",
     "FP", stages=("F", "D", "FP"), latency="x87 control sequence")
_add("fldenv fnstenv fstenv frstor fnsave fsave", "[mem]",
     "Load or store the x87 environment/full state image.",
     "FP", stages=("F", "D", "FP", "M"), latency="multi-beat x87 state sequence")
_add("frndint fscale", "", "Round ST(0) to integer or scale it by a power of two.",
     "FP", stages=("F", "D", "FP"), latency="multi-cycle x87")
_add("fprem fprem1", "", "Compute a partial IEEE/x87 remainder.",
     "FP", stages=("F", "D", "FP", "="), latency="data-dependent 16–64 cycles",
     availability="requires VEN_FPREM build")
_add("f2xm1 fyl2x fptan fpatan fyl2xp1 fsincos fsin fcos", "",
     "Iterative x87 transcendental operation.",
     "FP", stages=("F", "D", "FP", "="), latency="long iterative execution",
     availability="requires VEN_TRANSCENDENTAL (FPATAN may use VEN_FPTRAP)")
_add("fwait wait", "", "Wait for pending x87 work (modeled as the P5 wait/no-op path).",
     "FP", stages=("F", "D", "FP"))


_DESCRIPTION_OVERRIDES = {
    "movs": "Move one operand-sized element from DS:[(E)SI] to ES:[(E)DI].",
    "movsb": "Move one byte from DS:[(E)SI] to ES:[(E)DI].",
    "movsw": "Move one word from DS:[(E)SI] to ES:[(E)DI].",
    "movsd": "Move one dword from DS:[(E)SI] to ES:[(E)DI].",
    "stos": "Store the operand-sized accumulator in ES:[(E)DI].",
    "stosb": "Store AL in ES:[(E)DI].",
    "stosw": "Store AX in ES:[(E)DI].",
    "stosd": "Store EAX in ES:[(E)DI].",
    "lods": "Load one operand-sized element from DS:[(E)SI] into the accumulator.",
    "lodsb": "Load one byte from DS:[(E)SI] into AL.",
    "lodsw": "Load one word from DS:[(E)SI] into AX.",
    "lodsd": "Load one dword from DS:[(E)SI] into EAX.",
    "scas": "Compare the accumulator with one operand-sized element at ES:[(E)DI].",
    "scasb": "Compare AL with the byte at ES:[(E)DI].",
    "scasw": "Compare AX with the word at ES:[(E)DI].",
    "scasd": "Compare EAX with the dword at ES:[(E)DI].",
    "cmps": "Compare operand-sized DS:[(E)SI] and ES:[(E)DI] elements.",
    "cmpsb": "Compare the bytes at DS:[(E)SI] and ES:[(E)DI].",
    "cmpsw": "Compare the words at DS:[(E)SI] and ES:[(E)DI].",
    "cmpsd": "Compare the dwords at DS:[(E)SI] and ES:[(E)DI].",
    "ins": "Read one operand-sized element from I/O port DX into ES:[(E)DI].",
    "insb": "Read one byte from I/O port DX into ES:[(E)DI].",
    "insw": "Read one word from I/O port DX into ES:[(E)DI].",
    "insd": "Read one dword from I/O port DX into ES:[(E)DI].",
    "outs": "Write one operand-sized DS:[(E)SI] element to I/O port DX.",
    "outsb": "Write one byte from DS:[(E)SI] to I/O port DX.",
    "outsw": "Write one word from DS:[(E)SI] to I/O port DX.",
    "outsd": "Write one dword from DS:[(E)SI] to I/O port DX.",
    "clc": "Clear the carry flag (CF=0).",
    "stc": "Set the carry flag (CF=1).",
    "cmc": "Complement the carry flag (CF=¬CF).",
    "cld": "Clear the direction flag so string indexes increment.",
    "std": "Set the direction flag so string indexes decrement.",
    "cli": "Clear IF, disabling maskable interrupts after this instruction.",
    "sti": "Set IF, enabling maskable interrupts after the interrupt shadow.",
    "lock": "Request atomic memory access for the following supported instruction.",
    "rep": "Repeat the following string instruction while (E)CX is nonzero.",
    "repe": "Repeat while (E)CX is nonzero and ZF=1.",
    "repz": "Repeat while (E)CX is nonzero and ZF=1.",
    "repne": "Repeat while (E)CX is nonzero and ZF=0.",
    "repnz": "Repeat while (E)CX is nonzero and ZF=0.",
    "in": "Read an I/O port into AL, AX, or EAX.",
    "out": "Write AL, AX, or EAX to an I/O port.",
    "fld": "Push a real memory value or x87 register onto the x87 stack.",
    "fild": "Convert a signed integer memory value to extended real and push it.",
    "fbld": "Convert a packed-BCD memory value to extended real and push it.",
    "fst": "Store ST(0) as a real value without popping the x87 stack.",
    "fstp": "Store ST(0) as a real value, then pop the x87 stack.",
    "fist": "Convert and store ST(0) as a signed integer without popping.",
    "fistp": "Convert and store ST(0) as a signed integer, then pop.",
    "fbstp": "Convert and store ST(0) as packed BCD, then pop.",
    "fadd": "Add the source to the selected x87 destination.",
    "faddp": "Add ST(0) to ST(i), store in ST(i), then pop.",
    "fiadd": "Add a signed integer memory source to ST(0).",
    "fsub": "Subtract the source from the selected x87 destination.",
    "fsubp": "Subtract ST(0) from ST(i), store in ST(i), then pop.",
    "fsubr": "Reverse subtract: source minus the selected x87 destination.",
    "fsubrp": "Store ST(0) minus ST(i) in ST(i), then pop.",
    "fisub": "Subtract a signed integer memory source from ST(0).",
    "fisubr": "Store signed integer memory source minus ST(0) in ST(0).",
    "fmul": "Multiply the selected x87 destination by the source.",
    "fmulp": "Multiply ST(i) by ST(0), store in ST(i), then pop.",
    "fimul": "Multiply ST(0) by a signed integer memory source.",
    "fdiv": "Divide the selected x87 destination by the source.",
    "fdivp": "Divide ST(i) by ST(0), store in ST(i), then pop.",
    "fdivr": "Reverse divide: source divided by the selected x87 destination.",
    "fdivrp": "Store ST(0) divided by ST(i) in ST(i), then pop.",
    "fidiv": "Divide ST(0) by a signed integer memory source.",
    "fidivr": "Store signed integer memory source divided by ST(0) in ST(0).",
    "fcom": "Compare ST(0) with the source and update x87 condition flags.",
    "fcomp": "Compare ST(0) with the source, update x87 flags, then pop.",
    "fcompp": "Compare ST(0) with ST(1), update x87 flags, then pop twice.",
    "ficom": "Compare ST(0) with a signed integer memory source.",
    "ficomp": "Compare ST(0) with a signed integer memory source, then pop.",
    "fucom": "Unordered-compare ST(0) with the source; NaNs are handled quietly.",
    "fucomp": "Unordered-compare ST(0) with the source, then pop.",
    "fucompp": "Unordered-compare ST(0) with ST(1), then pop twice.",
    "ftst": "Compare ST(0) with zero and update x87 condition flags.",
    "fxam": "Classify ST(0) and report its sign/type in x87 condition flags.",
    "fchs": "Toggle the sign of ST(0).",
    "fabs": "Clear the sign of ST(0), producing its absolute value.",
    "fld1": "Push the x87 constant 1.0.",
    "fldz": "Push the x87 constant 0.0.",
    "fldpi": "Push the x87 constant π.",
    "fldl2e": "Push log2(e).",
    "fldl2t": "Push log2(10).",
    "fldlg2": "Push log10(2).",
    "fldln2": "Push ln(2).",
    "fxch": "Exchange ST(0) with ST(i).",
    "ffree": "Mark ST(i)'s x87 tag as empty.",
    "fincstp": "Increment x87 TOP, rotating the logical stack.",
    "fdecstp": "Decrement x87 TOP, rotating the logical stack.",
    "fnop": "Perform no x87 operation.",
    "fldcw": "Load the x87 control word from memory.",
    "fnstcw": "Store the x87 control word without an implicit WAIT.",
    "fstcw": "Wait for pending x87 work, then store the control word.",
    "fnclex": "Clear pending x87 exceptions without an implicit WAIT.",
    "fclex": "Wait for pending x87 work, then clear x87 exceptions.",
    "fninit": "Initialize x87 state without an implicit WAIT.",
    "finit": "Wait for pending x87 work, then initialize x87 state.",
    "fnstsw": "Store the x87 status word without an implicit WAIT.",
    "fstsw": "Wait for pending x87 work, then store the status word.",
}


_CC_CONDITIONS = {
    "o": "overflow is set (OF=1)",
    "no": "overflow is clear (OF=0)",
    "b": "unsigned below / carry (CF=1)",
    "c": "unsigned below / carry (CF=1)",
    "nae": "unsigned below / carry (CF=1)",
    "nb": "unsigned above or equal / no carry (CF=0)",
    "nc": "unsigned above or equal / no carry (CF=0)",
    "ae": "unsigned above or equal / no carry (CF=0)",
    "z": "equal / zero (ZF=1)",
    "e": "equal / zero (ZF=1)",
    "nz": "not equal / nonzero (ZF=0)",
    "ne": "not equal / nonzero (ZF=0)",
    "be": "unsigned below or equal (CF=1 or ZF=1)",
    "na": "unsigned below or equal (CF=1 or ZF=1)",
    "nbe": "unsigned above (CF=0 and ZF=0)",
    "a": "unsigned above (CF=0 and ZF=0)",
    "s": "the sign flag is set (SF=1)",
    "ns": "the sign flag is clear (SF=0)",
    "p": "parity is even (PF=1)",
    "pe": "parity is even (PF=1)",
    "np": "parity is odd (PF=0)",
    "po": "parity is odd (PF=0)",
    "l": "signed less-than (SF≠OF)",
    "nge": "signed less-than (SF≠OF)",
    "nl": "signed greater-than-or-equal (SF=OF)",
    "ge": "signed greater-than-or-equal (SF=OF)",
    "le": "signed less-than-or-equal (ZF=1 or SF≠OF)",
    "ng": "signed less-than-or-equal (ZF=1 or SF≠OF)",
    "nle": "signed greater-than (ZF=0 and SF=OF)",
    "g": "signed greater-than (ZF=0 and SF=OF)",
}
_LOOP_DESCRIPTIONS = {
    "loop": "Decrement (E)CX and jump when the result is nonzero.",
    "loopz": "Decrement (E)CX and jump when nonzero and ZF=1.",
    "loope": "Decrement (E)CX and jump when nonzero and ZF=1.",
    "loopnz": "Decrement (E)CX and jump when nonzero and ZF=0.",
    "loopne": "Decrement (E)CX and jump when nonzero and ZF=0.",
    "jcxz": "Jump when CX is zero; flags are unchanged.",
    "jecxz": "Jump when ECX is zero; flags are unchanged.",
}


def _specialize_description(info):
    """Replace family prose where a mnemonic's exact behavior matters."""
    mnemonic = info.mnemonic
    description = _DESCRIPTION_OVERRIDES.get(mnemonic)
    if description:
        info = replace(info, description=description)
    suffix = (
        mnemonic[3:] if mnemonic.startswith("set")
        else mnemonic[1:] if mnemonic.startswith("j")
        else "")
    condition = _CC_CONDITIONS.get(suffix)
    if condition:
        description = (
            f"Store 1 when {condition}; otherwise store 0."
            if mnemonic.startswith("set")
            else f"Jump when {condition}.")
        return replace(info, description=description)
    description = _LOOP_DESCRIPTIONS.get(mnemonic)
    return replace(info, description=description) if description else info


# One entry per insertion token. Families intentionally share descriptions, but
# aliases remain separate completion choices because users type them directly.
CATALOG = tuple(sorted(
    (_specialize_description(item) for item in _catalog),
    key=lambda item: item.mnemonic))
BY_MNEMONIC = {item.mnemonic: item for item in CATALOG}
MNEMONICS = frozenset(BY_MNEMONIC)


def instruction_info(mnemonic):
    """Return metadata for a mnemonic, accepting common size suffixes."""
    word = (mnemonic or "").strip().lower()
    info = BY_MNEMONIC.get(word)
    if info is not None:
        return info
    # GAS may expose explicit b/w/l suffixes for otherwise width-polymorphic ops.
    if len(word) > 2 and word[-1] in "bwl" and word[:-1] in BY_MNEMONIC:
        return BY_MNEMONIC[word[:-1]]
    return None
