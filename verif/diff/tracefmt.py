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

# --- system-mode (M2S) field groups -----------------------------------------
# Present only when header "sys":true.  Control registers carry the privileged
# machine state the user-mode trace never exposes (always reads 0 in linux-user):
#   cr0  — PE/MP/EM/TS/ET/NE/WP/AM/NW/CD/PG  (PE bit0, PG bit31)
#   cr2  — page-fault linear address (#PF)
#   cr3  — page-directory base + PCD/PWT
#   cr4  — VME/PVI/TSD/DE/PSE/PAE/MCE/PGE/...
# These are read straight from the qemu-system gdbstub g-packet (the i386-32bit.xml
# target description advertises cr0/cr2/cr3/cr4 right after the segment bases — the
# tail-anchor layout fix already places them correctly).
SYS_CR = ["cr0", "cr2", "cr3", "cr4"]

# Segment HIDDEN descriptor state (base/limit/attr per selector).  These are
# RESERVED in the v1 format for M2S.1 (segmentation): the gdbstub exposes some of
# them (ss_base..gs_base) but not the full hidden cache for cs/ds in one packet,
# so the producer only emits the fields it can read and the comparator only diffs
# the ones present in BOTH traces.  Field naming convention (lowercase):
#   <seg>_base (32b), <seg>_limit (32b), <seg>_attr (16b)   e.g. cs_base, cs_attr
# Emission of these is OPTIONAL even under sys:true (gated on availability); the
# CRx block above is the always-present system payload.
SEG_HIDDEN_SUFFIX = ["base", "limit", "attr"]
SYS_SEG_HIDDEN = [f"{s}_{suf}" for s in SEG_KEYS for suf in SEG_HIDDEN_SUFFIX]

# widths (in bits) used for canonical hex formatting / validation
_WIDTH = {k: 32 for k in GPR_KEYS}
_WIDTH.update({k: 16 for k in SEG_KEYS})
_WIDTH["eflags"] = 32
_WIDTH.update({k: 80 for k in X87_REGS})
_WIDTH.update({"fctrl": 16, "fstat": 16, "ftag": 16, "fop": 16,
               "fioff": 32, "fooff": 32, "fiseg": 16, "foseg": 16})
_WIDTH["pc"] = 32
# system control registers are all 32-bit
_WIDTH.update({k: 32 for k in SYS_CR})
# reserved segment-hidden fields: base/limit 32b, attr 16b
_WIDTH.update({f"{s}_base": 32 for s in SEG_KEYS})
_WIDTH.update({f"{s}_limit": 32 for s in SEG_KEYS})
_WIDTH.update({f"{s}_attr": 16 for s in SEG_KEYS})

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
def header(producer: str, mode: str, x87: bool = False, sys: bool = False,
           note: str = "") -> dict:
    assert mode in ("func", "cycle")
    h = {"vtrace": VERSION, "producer": producer, "mode": mode,
         "x87": bool(x87), "note": note}
    # "sys":true marks func records that carry system/privileged state (CRx, and
    # optionally the reserved segment-hidden fields).  Analogous to "x87" — when
    # absent/false the record is a plain user-mode func record (unchanged).  Only
    # emit the key when set so existing user-mode/x87 traces are byte-for-byte
    # identical to before.
    if sys:
        h["sys"] = True
    return h


def dumps(obj: dict) -> str:
    """One compact JSON line (no trailing newline)."""
    return json.dumps(obj, separators=(",", ":"))


# --- M7.1 syscall-effect field (Quake input-replay lock-step) ----------------
# The `sys_call` record field is a *producer-only environment-input* carried on
# the record of an `int 0x80` site (Quake / linux-user). It describes the KERNEL
# effects of the syscall that the RTL CPU cannot compute on its own, so the
# lock-step testbench can REPLAY them (apply eax=ret + the kernel memory writes +
# any TLS %gs base) and resume — the TB never executes the kernel. See
# docs/m7-lockstep-spec.md "Trace-contract extension".
#
# IMPORTANT (non-negotiable additive invariant): `sys_call` is NEVER in
# func_compare_keys(), so compare.py never grades it. An RTL trace that lacks
# `sys_call` still compares clean on every arch field (compare.py iterates the
# arch keys and ignores extra record fields). A normal instruction's record has
# NO `sys_call` key at all (so all existing goldens are byte-for-byte identical).
#
# Shape:
#   sys_call : {
#     "nr"   : int,                         # syscall number (eax pre-step)
#     "ret"  : "0x%08x" (hex32),            # eax post-step (kernel return value)
#     "writes": [                           # kernel-written memory regions
#         {"addr":"0x%08x", "hex":"<bytes>"},          # explicit bytes written
#         {"addr":"0x%08x", "len":int, "zero":true},   # zero-filled region (anon)
#     ],
#     "gs_base": "0x%08x" (hex32)           # OPTIONAL: resulting %gs TLS base
#                                           # (set_thread_area user_desc.base_addr)
#   }
# --- M7.3 Win95 system input-replay fields (co-sim-bus lock-step) ------------
# Three producer-only environment-input fields, carried on the record of the
# instruction that consumed / was-interrupted-at the corresponding boundary. The
# RTL CPU cannot compute any of them on its own; the co-sim-bus CONSUMER REPLAYS
# them (returns the dev_in value for the matching in/MMIO read, raises the intr at
# the same retire boundary QEMU did, applies the dma_wr bytes a bus master wrote
# into guest memory). NONE is graded by compare.py (they are never in
# func_compare_keys) — exactly like sys_call. A normal instruction's record has
# none of these keys, so all existing goldens stay byte-for-byte identical. See
# docs/m7-lockstep-spec.md "Trace-contract extension".
#
# Shapes (all on a func record, all optional):
#   dev_in : [ {addr, val, size, region} , ... ]   # PIO in / MMIO read VALUE(s)
#            the instruction consumed (>=1 when one insn does several reads, e.g.
#            rep insw). addr/size/region are decimal/string ints; val is the raw
#            value the device returned. The TB returns these for the matching
#            in/MMIO read, in order.
#   intr   : {vec, err?, soft?, cpl?, ip?, sp?}    # an interrupt/exception
#            delivered AT this instruction's boundary. `vec` is the IDT vector
#            (e.g. 0x8 = PIT IRQ0). `err` (errcode), `soft` (INT n vs async),
#            `cpl`/`ip`/`sp` (the seg_helper boundary) are emitted when known
#            (the authoritative seg_helper `v=` line provides them; an async
#            hwint marker provides only `vec`). The TB raises it into the RTL IDT
#            path at the same boundary.
#   dma_wr : [ {addr, val, size, region} , ... ]   # device/DMA WRITE(s) into
#            guest memory that the CPU did NOT compute (a bus master / device
#            wrote them). The TB applies these to RTL memory at this boundary so
#            the CPU sees the same memory a real device would have produced.
#            (Pure CPU `out`/MMIO-writes are NOT here — those the RTL computes
#            itself; this is reserved for writes whose SOURCE is a device.)
def dev_in_field(reads) -> list:
    """Build the `dev_in` field: a list of {addr,val,size,region} read records.

    `reads`: iterable of dicts {addr:int, val:int, size:int, region:str}. Returns
    a normalized list (ints + string region). Empty -> [] (caller should only
    attach a non-empty list)."""
    out = []
    for r in (reads or []):
        out.append({"addr": int(r["addr"]), "val": int(r["val"]),
                    "size": int(r["size"]), "region": str(r.get("region", ""))})
    return out


def dma_wr_field(writes) -> list:
    """Build the `dma_wr` field: a list of {addr,val,size,region} device-write
    records (same shape as dev_in). See the block comment above."""
    out = []
    for w in (writes or []):
        out.append({"addr": int(w["addr"]), "val": int(w["val"]),
                    "size": int(w["size"]), "region": str(w.get("region", ""))})
    return out


def intr_field(vec: int, err=None, soft=None, cpl=None, ip=None, sp=None) -> dict:
    """Build the `intr` field for a delivered interrupt/exception at a boundary.

    vec: IDT vector (int). err/soft/cpl/ip/sp: emitted only when not None (the
    authoritative seg_helper `v=` line supplies them; an async hwint marker
    supplies only vec). ip/sp are kept as the "SEG:OFF" strings QEMU logs."""
    d = {"vec": int(vec)}
    if err is not None:
        d["err"] = int(err)
    if soft is not None:
        d["soft"] = bool(soft)
    if cpl is not None:
        d["cpl"] = int(cpl)
    if ip is not None:
        d["ip"] = str(ip)
    if sp is not None:
        d["sp"] = str(sp)
    return d


def sys_call_field(nr: int, ret: int, writes=None, gs_base=None) -> dict:
    """Build the optional `sys_call` record field (see the block comment above).

    writes: iterable of dicts, each either
        {"addr":int, "hex":str|bytes}      -> explicit bytes the kernel wrote
        {"addr":int, "len":int, "zero":True}-> a zero-filled region (anon map/brk)
      The addr is normalized to canonical hex32; "hex" is normalized to a lowercase
      hex string. Empty/None writes -> an empty list (a syscall with no memory
      effect, e.g. set_tid_address, still carries nr+ret).
    gs_base (optional): the resulting %gs segment base (hex32), emitted only when
      not None (e.g. the TLS base after set_thread_area).
    """
    w_out = []
    for w in (writes or []):
        addr = w["addr"]
        if w.get("zero"):
            w_out.append({"addr": h32(addr), "len": int(w["len"]), "zero": True})
        else:
            b = w["hex"]
            hexstr = b if isinstance(b, str) else b.hex()
            w_out.append({"addr": h32(addr), "hex": hexstr.lower()})
    sc = {"nr": int(nr), "ret": h32(ret), "writes": w_out}
    if gs_base is not None:
        sc["gs_base"] = h32(gs_base)
    return sc


# --- record builders ---------------------------------------------------------
def func_record(n, pc, eflags, gpr: dict, seg: dict,
                bytes_=None, exc=None, x87: dict | None = None,
                sysregs: dict | None = None, sys_call: dict | None = None,
                dev_in: list | None = None, intr: dict | None = None,
                dma_wr: list | None = None) -> dict:
    """Build a functional-mode retire record.

    gpr: {name: int} over GPR_KEYS;  seg: {name: int} over SEG_KEYS.
    x87 (optional): {st0..st7: int(80b), fctrl,...: int}.
    sysregs (optional, M2S): {cr0,cr2,cr3,cr4: int} plus any reserved
        segment-hidden fields (cs_base, cs_attr, ...).  Only the keys present in
        the dict are emitted, formatted at their declared width.  Pass this only
        when the header has "sys":true.
    sys_call (optional, M7.1): the {nr,ret,writes[,gs_base]} kernel-effect dict
        built by sys_call_field(), present ONLY on an `int 0x80` record. It is a
        producer-only environment input (replayed by the TB, NEVER graded by
        compare.py — see the block comment above). Absent => a normal instruction.
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
    if sysregs is not None:
        # Control registers (always emitted under sys:true).
        for k in SYS_CR:
            if k in sysregs:
                r[k] = h32(sysregs[k])
        # Reserved segment-hidden fields: emit only those actually provided.
        for k in SYS_SEG_HIDDEN:
            if k in sysregs:
                r[k] = hx(sysregs[k], _WIDTH[k])
    # M7.1: the producer-only syscall-effect field (NOT in func_compare_keys, so
    # compare.py never grades it). Emitted only on `int 0x80` records.
    if sys_call is not None:
        r["sys_call"] = sys_call
    # M7.3: producer-only Win95 input-replay environment fields (also NEVER in
    # func_compare_keys — the consumer replays them, the comparator ignores them).
    # Each is emitted only when non-empty/non-None, so a normal instruction's
    # record is byte-for-byte identical to before.
    if dev_in:
        r["dev_in"] = dev_in
    if intr is not None:
        r["intr"] = intr
    if dma_wr:
        r["dma_wr"] = dma_wr
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

    @property
    def sys(self): return bool(self.hdr.get("sys"))


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


def func_compare_keys(x87: bool, sys: bool = False) -> list:
    """Field compare order for functional mode.

    When `sys` is set, the system control registers (cr0/cr2/cr3/cr4) are
    appended to the compare list.  The reserved segment-hidden fields are NOT in
    the default compare order — they only become comparable once M2S.1 emits them
    in both producers; the comparator should intersect the keys present in both
    traces before diffing (a producer that omits a field must not force a miss).
    """
    keys = ["pc"] + GPR_KEYS + ["eflags"] + SEG_KEYS
    if x87:
        keys += X87_REGS + X87_CTL
    if sys:
        keys += SYS_CR
    return keys


def eflags_undefined_mask(mnemonic: str | None) -> int:
    if not mnemonic:
        return 0
    m = mnemonic.lower()
    for pfx, mask in EFLAGS_UNDEFINED.items():
        if m.startswith(pfx):
            return mask
    return 0
