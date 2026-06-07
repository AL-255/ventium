# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Capstone-backed x86 disassembly + the FSM-state -> P5-pipeline-stage model.

The Ventium core is an FSM (rtl/core/core.sv `state`): S_PIPE is the steady-state
dual-issue fast path (U/V), S_PF is an I-cache line fill, S_FETCH..S_STORE is the
slow microcode path, S_FLOAD/S_FEXEC/S_FSTORE is the x87 FP pipe, S_WALK is a
page-table walk, and the S_INT*/S_IRET/S_TSW*/S_SMI* arms are fault/interrupt/
task/SMM microcode. STATE_STAGE maps each to a (lane, P5-stage, colour) so the
visualizer can render the classic Prefetch->D1->D2->EX->WB picture faithfully.
"""
import re
from capstone import Cs, CS_ARCH_X86, CS_MODE_16, CS_MODE_32

_md32 = Cs(CS_ARCH_X86, CS_MODE_32)
_md16 = Cs(CS_ARCH_X86, CS_MODE_16)
for _m in (_md32, _md16):
    _m.detail = False

# detail-enabled disassemblers for per-byte field segmentation (trace bytes).
_md32d = Cs(CS_ARCH_X86, CS_MODE_32)
_md16d = Cs(CS_ARCH_X86, CS_MODE_16)
for _m in (_md32d, _md16d):
    _m.detail = True

# x86 instruction-field colours (per the requested scheme; tuned for contrast
# on the near-black canvas so prefixes are legible).
FIELD_COLOR = {
    "prefix": "#aab4c0",   # light slate-gray (brighter than before)
    "opcode": "#4ea1ff",   # blue
    "modrm":  "#56d364",   # green
    "sib":    "#c89bff",   # purple
    "disp":   "#e3b341",   # yellow (memory offset / displacement)
    "imm":    "#ff7b72",   # red (immediate operand)
    "rel":    "#ff6a00",   # red-orange (relative branch target) — pushed further
                           # from the golden disp-yellow (RGB dist now ~102, was 81)
                           # because at 9px AA the old #ff8c00 still blended toward
                           # the offset-yellow; a red-orange can't be read as yellow.
}
_PREFIX_BYTES = {0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65}


def byte_fields(code: bytes, addr: int = 0, bits: int = 32):
    """Segment one instruction's bytes into x86 fields. Returns a list of
    (byte_value, field_name) for prefix / opcode / modrm / sib / disp / imm.
    Falls back to a single 'opcode' byte on decode failure."""
    md = _md16d if bits == 16 else _md32d
    insn = None
    try:
        for i in md.disasm(code, addr):
            insn = i
            break
    except Exception:
        insn = None
    if insn is None:
        return [((code[0] if code else 0), "opcode")]
    n = insn.size
    bs = list(insn.bytes)[:n]
    fields = ["opcode"] * n
    # leading legacy prefixes
    p = 0
    while p < n and bs[p] in _PREFIX_BYTES:
        fields[p] = "prefix"
        p += 1
    enc = getattr(insn, "encoding", None)
    modrm_off = getattr(enc, "modrm_offset", 0) if enc else 0
    disp_off = getattr(enc, "disp_offset", 0) if enc else 0
    disp_sz = getattr(enc, "disp_size", 0) if enc else 0
    imm_off = getattr(enc, "imm_offset", 0) if enc else 0
    imm_sz = getattr(enc, "imm_size", 0) if enc else 0
    # opcode spans from end-of-prefixes to the first of modrm/disp/imm
    ends = [n]
    if modrm_off > 0:
        ends.append(modrm_off)
    if disp_sz > 0:
        ends.append(disp_off)
    if imm_sz > 0:
        ends.append(imm_off)
    opcode_end = min(ends)
    for i in range(p, min(opcode_end, n)):
        fields[i] = "opcode"
    if 0 < modrm_off < n:
        fields[modrm_off] = "modrm"
        b = bs[modrm_off]
        if (b >> 6) != 3 and (b & 7) == 4 and modrm_off + 1 < n:   # SIB present
            fields[modrm_off + 1] = "sib"
    for i in range(disp_off, min(disp_off + disp_sz, n)):
        if disp_sz > 0:
            fields[i] = "disp"
    for i in range(imm_off, min(imm_off + imm_sz, n)):
        if imm_sz > 0:
            fields[i] = "imm"
    # A relative branch's rel8/rel16/rel32 target is a control-flow displacement,
    # not a data immediate (capstone reports it via the imm field) and not a
    # memory offset — give it its own 'rel' colour for jmp/jcc/call/loop forms.
    mn = (insn.mnemonic or "")
    if imm_sz > 0 and (mn[:1] == "j" or mn.split(" ")[0] in
                       ("call", "loop", "loope", "loopne", "loopz", "loopnz")):
        for i in range(imm_off, min(imm_off + imm_sz, n)):
            fields[i] = "rel"
    return [(bs[i], fields[i]) for i in range(n)]


# reg-name (incl. 16/8-bit sub-registers) -> architectural GPR index 0..7.
_GPR_OF = {}
for _i, _names in enumerate([("eax", "ax", "al", "ah"), ("ecx", "cx", "cl", "ch"),
                             ("edx", "dx", "dl", "dh"), ("ebx", "bx", "bl", "bh"),
                             ("esp", "sp", "spl"), ("ebp", "bp", "bpl"),
                             ("esi", "si", "sil"), ("edi", "di", "dil")]):
    for _n in _names:
        _GPR_OF[_n] = _i


def written_regs(code: bytes, addr: int = 0, bits: int = 32):
    """Which architectural GPRs (and EFLAGS) an instruction WRITES, via capstone's
    register-access analysis. Returns (gpr_index_list, flags_written). Used to
    attribute each retirement's effect to the instruction that caused it — the
    per-cycle commit snapshot alone can't separate a dual-issue U/V pair's writes."""
    md = _md16d if bits == 16 else _md32d
    try:
        for insn in md.disasm(code, addr):
            try:
                _, wr = insn.regs_access()
            except Exception:
                wr = getattr(insn, "regs_write", []) or []
            gprs, flags = [], False
            for rid in wr:
                nm = (insn.reg_name(rid) or "").lower()
                if nm in _GPR_OF and _GPR_OF[nm] not in gprs:
                    gprs.append(_GPR_OF[nm])
                elif "flags" in nm:
                    flags = True
            return gprs, flags
    except Exception:
        pass
    return [], False


_OPTOK = re.compile(r'0x[0-9a-fA-F]+|\d+|[A-Za-z_]\w*|.')


def operand_segments(ops: str, is_branch: bool, reg_col: str = "#c9d1d9"):
    """Tokenise an operand string into (text, colour) runs so the disassembly is
    FIELD-coloured to match the bytes column: immediate=salmon, displacement
    (inside `[...]`)=gold, branch-target=orange, registers/keywords neutral. So a
    `mov ax, 0x10` shows its `0x10` salmon, exactly like its immediate byte."""
    segs, depth = [], 0
    for m in _OPTOK.finditer(ops):
        tok = m.group(0)
        if tok == "[":
            depth += 1; col = reg_col
        elif tok == "]":
            depth = max(0, depth - 1); col = reg_col
        elif tok[0].isdigit():                       # a number literal (0x.. or dec)
            col = (FIELD_COLOR["rel"] if is_branch
                   else FIELD_COLOR["disp"] if depth > 0
                   else FIELD_COLOR["imm"])
        else:
            col = reg_col
        segs.append((tok, col))
    return segs


def disasm_one(code: bytes, addr: int = 0, bits: int = 32):
    """Disassemble the first instruction in `code`. Returns
    (size, mnemonic, op_str, bytes). On failure returns (1, 'db', '0xNN', ...)."""
    md = _md16 if bits == 16 else _md32
    try:
        for insn in md.disasm(code, addr):
            return insn.size, insn.mnemonic, insn.op_str, bytes(insn.bytes)
    except Exception:
        pass
    b0 = code[0] if code else 0
    return 1, "db", f"0x{b0:02x}", bytes(code[:1])


def text(code: bytes, addr: int = 0, bits: int = 32):
    sz, mn, ops, _ = disasm_one(code, addr, bits)
    return f"{mn} {ops}".strip(), sz


# ---------------------------------------------------------------------------
# FSM state -> pipeline lane + stage + colour. lane in {U, V, FP, MEM, FE, SYS}.
# stage is the P5 stage name shown on the live board.
# ---------------------------------------------------------------------------
# colours (hex) chosen for clear separation on a dark canvas
C_PIPE   = "#3fb950"   # dual-issue fast path (green)
C_FILL   = "#d29922"   # I-cache fill / prefetch (amber)
C_SLOW   = "#58a6ff"   # slow microcode (blue)
C_FP     = "#bc8cff"   # x87 FP pipe (purple)
C_WALK   = "#f778ba"   # page-table walk (pink — distinct from flush red)
C_SYS    = "#e3b341"   # interrupt / task / SMM microcode (gold)
C_HALT   = "#8b949e"   # halt / hang (grey)
C_IDLE   = "#21262d"   # reset / idle

# state name -> (lane, stage_label, colour, human description)
STATE_STAGE = {
    "S_RESET":     ("FE",  "reset",   C_IDLE, "reset latch"),
    "S_PIPE":      ("U",   "EX/WB",   C_PIPE, "dual-issue fast path (U/V)"),
    "S_PF":        ("FE",  "PF-fill", C_FILL, "I-cache line fill (8 word reads)"),
    "S_FETCH":     ("FE",  "PF",      C_SLOW, "slow-path fetch into ibuf"),
    "S_DECODE":    ("U",   "D1/D2",   C_SLOW, "slow-path decode"),
    "S_LOAD":      ("MEM", "EX(ld)",  C_SLOW, "slow-path load"),
    "S_LOAD2":     ("MEM", "EX(ld)",  C_SLOW, "slow-path load (2nd beat)"),
    "S_EXEC":      ("U",   "EX",      C_SLOW, "slow-path execute"),
    "S_STORE":     ("MEM", "WB(st)",  C_SLOW, "slow-path store"),
    "S_USEQ":      ("U",   "useq",    C_SLOW, "microcode sequence"),
    "S_HALT":      ("FE",  "HALT",    C_HALT, "halted"),
    "S_FLOAD":     ("FP",  "X1(ld)",  C_FP,   "x87 operand load"),
    "S_FEXEC":     ("FP",  "X1/X2",   C_FP,   "x87 execute + commit"),
    "S_FSTORE":    ("FP",  "ER(st)",  C_FP,   "x87 store"),
    "S_FENV_ST":   ("FP",  "env-st",  C_FP,   "x87 env/state store"),
    "S_FENV_LD":   ("FP",  "env-ld",  C_FP,   "x87 env/state load"),
    "S_IO":        ("MEM", "IO",      C_SLOW, "port I/O handshake"),
    "S_INS":       ("MEM", "INS",     C_SLOW, "INS string port input"),
    "S_F00F_HANG": ("FE",  "F00F",    C_HALT, "F00F LOCK CMPXCHG8B hang"),
    "S_LGDT":      ("SYS", "LGDT",    C_SYS,  "GDT/IDT table load"),
    "S_SEGLD":     ("SYS", "seg-ld",  C_SYS,  "segment descriptor load"),
    "S_LJMP":      ("SYS", "ljmp",    C_SYS,  "far jump"),
    "S_WALK":      ("MEM", "TLB-walk", C_WALK, "2-level page-table walk"),
    "S_INT_GATE":  ("SYS", "int-gate", C_SYS, "read IDT gate"),
    "S_INT_CS":    ("SYS", "int-cs",  C_SYS,  "read GDT code descriptor"),
    "S_INT_PUSH":  ("SYS", "int-push", C_SYS, "push exception frame"),
    "S_IRET":      ("SYS", "iret",    C_SYS,  "IRET pop"),
    "S_INT_CS_RET": ("SYS", "iret-cs", C_SYS, "IRET reload CS"),
    "S_LTR":       ("SYS", "ltr",     C_SYS,  "load task register"),
    "S_INT_TSS":   ("SYS", "int-tss", C_SYS,  "cross-priv TSS read"),
    "S_INT_SS":    ("SYS", "int-ss",  C_SYS,  "cross-priv SS load"),
    "S_IRET_SS":   ("SYS", "iret-ss", C_SYS,  "inter-priv IRET SS"),
    "S_TSW_SAVE":  ("SYS", "tsw-save", C_SYS, "task switch save"),
    "S_TSW_READ":  ("SYS", "tsw-read", C_SYS, "task switch read"),
    "S_TSW_SEG":   ("SYS", "tsw-seg", C_SYS,  "task switch seg reload"),
    "S_TSW_BUSY":  ("SYS", "tsw-busy", C_SYS, "task switch busy commit"),
    "S_SMI_SAVE":  ("SYS", "smi",     C_SYS,  "SMI state save"),
    "S_RSM":       ("SYS", "rsm",     C_SYS,  "RSM state restore"),
    "S_DB_EXTRA":  ("SYS", "#DB",     C_SYS,  "data-watchpoint re-report"),
}


def stage_of(state_name):
    return STATE_STAGE.get(state_name, ("FE", state_name, C_HALT, state_name))


# ---------------------------------------------------------------------------
# Instruction-class colouring (by mnemonic). Green is RESERVED for the
# dual-issue/S_PIPE meaning in the pipeline panel, so ALU/data mnemonics use a
# neutral off-white here and only branches/fp/mem/sys carry an accent.
# ---------------------------------------------------------------------------
CC_BRANCH = "#ff6a00"   # control transfer — SAME red-orange as the rel8/rel32
                        # branch-target BYTE colour, so a branch target reads the
                        # same hue in the bytes column and the disassembly (kept in
                        # lock-step with FIELD_COLOR['rel']).
CC_FP = "#c89bff"       # x87 (purple)
CC_MEM = "#79c0ff"      # load/store/stack (blue)
CC_ALU = "#d9dee3"      # arithmetic / data (neutral off-white)
CC_SYS = "#d9dee3"      # privileged / system — NEUTRAL (same as ALU). Every warm
                        # accent collided with a legend colour (orange read as the
                        # branch accent, red as the immediate-byte colour), so
                        # lgdt/lidt/hlt/cr-moves now render plain; the mnemonic
                        # itself is the signal that it's a system op.
CC_OTHER = "#8b949e"

_BR = {"jmp", "call", "ret", "retn", "retf", "iret", "iretd", "loop", "loope",
       "loopne", "loopz", "loopnz", "jcxz", "jecxz", "int", "int3", "into", "syscall"}
_MEM = {"push", "pop", "pusha", "popa", "pushf", "pushfd", "popf", "popfd",
        "movs", "stos", "lods", "scas", "cmps", "lea", "xchg", "leave", "enter",
        "in", "out", "ins", "outs"}
_SYS = {"mov", "lgdt", "lidt", "ltr", "lldt", "hlt", "cli", "sti", "rsm",
        "wrmsr", "rdmsr", "invlpg", "cpuid", "clts"}


def insn_class(mnemonic: str):
    m = (mnemonic or "").lower()
    if not m:
        return ("other", CC_OTHER)
    if m[0] == "j" or m in _BR:
        return ("branch", CC_BRANCH)
    if m[0] == "f" and m not in ("fs", "gs"):
        return ("fp", CC_FP)
    if m in _MEM:
        return ("mem", CC_MEM)
    if m in ("lgdt", "lidt", "ltr", "lldt", "hlt", "rsm", "invlpg", "cpuid", "clts",
             "wrmsr", "rdmsr"):
        return ("sys", CC_SYS)
    return ("alu", CC_ALU)


# waterfall event colours (stalls / mispredict flushes are the most common
# events in these traces and previously had no legend entry).
C_STALL = "#d2a24c"     # pipeline stall / bubble (amber)
C_MISPRED = "#f85149"   # mispredict flush (red)

# legend entries for the waterfall / board
LEGEND = [
    ("dual-issue", C_PIPE),
    ("I-cache fill", C_FILL),
    ("slow microcode", C_SLOW),
    ("x87 FP", C_FP),
    ("page walk", C_WALK),
    ("int/task/SMM", C_SYS),
    ("stall/bubble", C_STALL),
    ("mispredict", C_MISPRED),
    ("halt", C_HALT),
]
