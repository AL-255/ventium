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
from capstone import Cs, CS_ARCH_X86, CS_MODE_16, CS_MODE_32

_md32 = Cs(CS_ARCH_X86, CS_MODE_32)
_md16 = Cs(CS_ARCH_X86, CS_MODE_16)
for _m in (_md32, _md16):
    _m.detail = False


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
C_WALK   = "#f85149"   # page-table walk (red)
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


# legend entries for the timeline / board
LEGEND = [
    ("dual-issue (S_PIPE)", C_PIPE),
    ("I-cache fill (S_PF)", C_FILL),
    ("slow microcode", C_SLOW),
    ("x87 FP pipe", C_FP),
    ("page-table walk", C_WALK),
    ("int/task/SMM", C_SYS),
    ("halt/hang", C_HALT),
]
