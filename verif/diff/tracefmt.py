#!/usr/bin/env python3
"""Ventium trace format (v1) — shared parser/emitter.

This module is the *executable* definition of docs/trace-format.md. The QEMU
gdbstub generator (verif/qemu-trace/gen_trace.py) and the comparator
(verif/diff/compare.py) both import it so field names, formatting and EFLAGS
masking never drift between producer and consumer. The C plugin and C++
testbench emit JSON lines by hand following the same field names; this module
parses whatever they emit (parse is field-based, not text-identical).

See docs/trace-format.md for the prose spec.
"""
from __future__ import annotations
import json

VERSION = 1

# --- field name groups (canonical order = compare order) ---------------------
GPR_KEYS = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"]
SEG_KEYS = ["cs", "ss", "ds", "es", "fs", "gs"]
X87_REGS = [f"st{i}" for i in range(8)]
X87_CTL  = ["fctrl", "fstat", "ftag", "fop", "fioff", "fooff", "fiseg", "foseg"]

# widths (in bits) used for canonical hex formatting / validation
_WIDTH = {k: 32 for k in GPR_KEYS}
_WIDTH.update({k: 16 for k in SEG_KEYS})
_WIDTH["eflags"] = 32
_WIDTH.update({k: 80 for k in X87_REGS})
_WIDTH.update({"fctrl": 16, "fstat": 16, "ftag": 16, "fop": 16,
               "fioff": 32, "fooff": 32, "fiseg": 16, "foseg": 16})
_WIDTH["pc"] = 32

# --- EFLAGS masking ----------------------------------------------------------
# Architecturally meaningful EFLAGS bits on a P5 in the situations the corpus
# exercises. Reserved bits (1,3,5,15, 22..31) are excluded by default.
#   CF0 PF2 AF4 ZF6 SF7 TF8 IF9 DF10 OF11 IOPL12-13 NT14 RF16 VM17 AC18 VIF19 VIP20 ID21
EFLAGS_DEFAULT_MASK = 0x003F7FD5

# Per-mnemonic flags left ARCHITECTURALLY UNDEFINED after the op (excluded from
# the compare for that record). Keyed by lowercase mnemonic prefix; the
# comparator decodes the record's `bytes` with capstone to get the mnemonic and
# matches via str.startswith (see eflags_undefined_mask below). Masks use the
# status-flag bit layout CF=0x001 PF=0x004 AF=0x010 ZF=0x040 SF=0x080 OF=0x800.
#
# Design rule (m2-isa-spec.md "EFLAGS undefined masking"): be MINIMAL and
# CORRECT — mask only the bits the SDM marks Undefined for the op, so the gate
# does not hide real RTL bugs. The table is keyed by mnemonic only (capstone
# detail/operands are off in the comparator), so where a flag is "undefined for
# count != 1" we mask it for the whole mnemonic: the bit is undefined in the
# common case and this is the finest granularity the mechanism supports. The
# DEFINED flags of the same op (e.g. CF for shifts, ZF for bsf) stay compared,
# which is what actually pins correctness. Counts that are masked to 0 leave all
# flags unchanged in both QEMU and (required of) the RTL, so the still-compared
# flags catch a wrong no-op.
EFLAGS_UNDEFINED = {
    # MUL / IMUL (1-, 2- and 3-operand; capstone reports all forms as "imul"):
    # SDM "MUL"/"IMUL": CF and OF are DEFINED (set when the result is
    # truncated); SF, ZF, AF, PF are Undefined.  -> mask SF|ZF|AF|PF = 0x0D4.
    "mul":  0x0000000D4,
    "imul": 0x0000000D4,
    # DIV / IDIV: SDM "DIV"/"IDIV": CF, OF, SF, ZF, AF, PF are all Undefined.
    #   -> mask all six status flags = 0x8D5.
    "div":  0x0000008D5,
    "idiv": 0x0000008D5,
    # SHL/SHR/SAR/SAL and SHLD/SHRD (capstone normalizes SAL -> "shl"):
    # SDM "SAL/SAR/SHL/SHR" & "SHLD/SHRD": the OF flag is DEFINED only for
    # 1-bit shifts (Undefined for count != 1); the AF flag is Undefined.  CF,
    # SF, ZF, PF are DEFINED (and for a masked-to-0 count NOTHING changes).
    #   -> mask OF|AF = 0x810.  ("shl" also prefix-covers "shld"; "shr" covers
    #      "shrd"; same mask, so prefix overlap is harmless.)
    "shl":  0x000000810,
    "shr":  0x000000810,
    "sar":  0x000000810,
    "sal":  0x000000810,  # belt-and-suspenders; capstone emits "shl" for SAL
    "shld": 0x000000810,
    "shrd": 0x000000810,
    # ROL/ROR/RCL/RCR: SDM "RCL/RCR/ROL/ROR": these affect ONLY CF and OF; OF
    # is DEFINED only for 1-bit rotates (Undefined for count != 1); all other
    # flags (SF/ZF/AF/PF) are UNCHANGED (not undefined).  -> mask OF only =
    # 0x800 (CF stays compared; SF/ZF/AF/PF must match the carried-through old
    # values, which the full default mask still checks).
    "rol":  0x000000800,
    "ror":  0x000000800,
    "rcl":  0x000000800,
    "rcr":  0x000000800,
    # BT/BTS/BTR/BTC: SDM "BT/BTS/BTR/BTC": CF = selected bit (DEFINED); OF, SF,
    # AF, PF are Undefined; ZF is UNCHANGED.  -> mask OF|SF|AF|PF = 0x894 (CF and
    # ZF stay compared).  Prefix "bt" covers bts/btr/btc (identical flag rule).
    "bt":   0x000000894,
    # BSF/BSR: SDM "BSF"/"BSR": ZF is DEFINED (set iff src == 0); CF, OF, SF,
    # AF, PF are Undefined.  -> mask CF|OF|SF|AF|PF = 0x895 (ZF stays compared).
    # (On src == 0 the destination is also undefined; the corpus must not rely
    # on the dest in that case — that is a corpus rule, not a flag mask.)
    "bsf":  0x000000895,
    "bsr":  0x000000895,
    # AAA/AAS: SDM: OF, SF, ZF, PF Undefined; AF and CF DEFINED.
    #   -> mask OF|SF|ZF|PF = 0x8C4.
    "aaa":  0x0000008C4,
    "aas":  0x0000008C4,
    # AAM/AAD: SDM: OF, AF, CF Undefined; SF, ZF, PF DEFINED.
    #   -> mask OF|AF|CF = 0x811.
    "aam":  0x000000811,
    "aad":  0x000000811,
    # DAA/DAS: SDM: OF Undefined; CF, AF, SF, ZF, PF DEFINED.  -> mask OF = 0x800.
    "daa":  0x000000800,
    "das":  0x000000800,
}


# --- hex helpers -------------------------------------------------------------
def hx(val: int, bits: int) -> str:
    """Canonical lowercase hex string, zero-padded to `bits`."""
    digits = (bits + 3) // 4
    return f"0x{val & ((1 << bits) - 1):0{digits}x}"


def h32(v): return hx(v, 32)
def h16(v): return hx(v, 16)
def h80(v): return hx(v, 80)


def parse_hex(s) -> int:
    """Accept '0x..' / bare hex / int."""
    if isinstance(s, int):
        return s
    return int(s, 16)


# --- header ------------------------------------------------------------------
def header(producer: str, mode: str, x87: bool = False, note: str = "") -> dict:
    assert mode in ("func", "cycle")
    return {"vtrace": VERSION, "producer": producer, "mode": mode,
            "x87": bool(x87), "note": note}


def dumps(obj: dict) -> str:
    """One compact JSON line (no trailing newline)."""
    return json.dumps(obj, separators=(",", ":"))


# --- record builders ---------------------------------------------------------
def func_record(n, pc, eflags, gpr: dict, seg: dict,
                bytes_=None, exc=None, x87: dict | None = None) -> dict:
    """Build a functional-mode retire record.

    gpr: {name: int} over GPR_KEYS;  seg: {name: int} over SEG_KEYS.
    x87 (optional): {st0..st7: int(80b), fctrl,...: int}.
    """
    r = {"n": int(n), "pc": h32(pc), "eflags": h32(eflags)}
    for k in GPR_KEYS:
        r[k] = h32(gpr[k])
    for k in SEG_KEYS:
        r[k] = h16(seg[k])
    if bytes_ is not None:
        r["bytes"] = bytes_ if isinstance(bytes_, str) else bytes_.hex()
    if exc is not None:
        r["exc"] = int(exc)
    if x87 is not None:
        for k in X87_REGS:
            r[k] = h80(x87[k])
        for k in X87_CTL:
            r[k] = hx(x87[k], _WIDTH[k])
    return r


def cycle_record(n, pc, cyc, pipe="-", paired=False, stall=None,
                 bytes_=None) -> dict:
    r = {"n": int(n), "pc": h32(pc), "cyc": int(cyc),
         "pipe": pipe, "paired": bool(paired)}
    if stall is not None:
        r["stall"] = int(stall)
    if bytes_ is not None:
        r["bytes"] = bytes_ if isinstance(bytes_, str) else bytes_.hex()
    return r


# --- reading -----------------------------------------------------------------
class Trace:
    """A parsed .vtrace: .hdr (dict) + .records (list of dict)."""
    def __init__(self, hdr: dict, records: list):
        self.hdr = hdr
        self.records = records

    @property
    def mode(self): return self.hdr.get("mode")

    @property
    def x87(self): return bool(self.hdr.get("x87"))


def read_trace(path: str) -> Trace:
    hdr = None
    records = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            obj = json.loads(line)
            if hdr is None:
                if "vtrace" not in obj:
                    raise ValueError(f"{path}: first line is not a vtrace header")
                hdr = obj
            else:
                records.append(obj)
    if hdr is None:
        raise ValueError(f"{path}: empty / no header")
    return Trace(hdr, records)


def func_compare_keys(x87: bool) -> list:
    """Field compare order for functional mode."""
    keys = ["pc"] + GPR_KEYS + ["eflags"] + SEG_KEYS
    if x87:
        keys += X87_REGS + X87_CTL
    return keys


def eflags_undefined_mask(mnemonic: str | None) -> int:
    if not mnemonic:
        return 0
    m = mnemonic.lower()
    for pfx, mask in EFLAGS_UNDEFINED.items():
        if m.startswith(pfx):
            return mask
    return 0
