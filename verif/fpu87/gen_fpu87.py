#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# =============================================================================
# gen_fpu87.py — random + corner-case x87 FPU test generator for the fpu87 gate.
#
# Emits freestanding i386 (P5) assembly programs that exercise the x87 FPU on
# RANDOMLY-GENERATED 80-bit operands plus a hand-curated pool of denormal /
# special / "unsupported-operand" corner cases, across all four rounding modes.
# Operands are injected as raw 80-bit `fldt` (tbyte) loads, so SNaNs, denormals,
# pseudo-denormals and unnormals reach the FPU WITHOUT a load-time conversion
# masking them.
#
# For each emitted op instruction the generator records (a) which trace record
# holds its st0 result and (b) the EXPECTED result + x87 exception flags from an
# INDEPENDENT oracle — Berkeley SoftFloat (extF80) for arithmetic, qref (the
# qemu-bit-exact port) for the Group-B transcendentals. The gate
# (run-fpu87-gate.sh) then diffs the RTL vs the QEMU golden (authoritative, via
# compare.py over the full st0..st7/fstat/ftag state) AND cross-checks the QEMU
# golden's st0 against the oracle (SoftFloat <-> QEMU <-> RTL triangulation).
#
# Output layout (under --out):
#   <out>/index.json            list of {name, dir, manifest, cases, oracle, max_insn}
#   <out>/<name>/<name>.s       the test program
#   <out>/<name>/manifest.json  harness manifest (auto-discoverable shape)
#   <out>/<name>/<name>.cases.jsonl   per-vector {op,rc,a,b,rec,exp,flags,oracle}
#
# Usage:
#   gen_fpu87.py --out DIR --oracle PATH/ven_fpu_oracle [--qref PATH/qref]
#                [--profile smoke|default|thorough] [--seed N]
#                [--ops add,sub,...] [--no-transcendental]
# =============================================================================
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys

# --- 80-bit extended helpers -------------------------------------------------
SIGNIF_MASK = (1 << 64) - 1
INT_BIT     = 1 << 63                     # explicit integer bit (extF80 bit 63)


def mk(sign, exp, signif):
    """Build (signExp, signif) from sign(0/1), 15-bit exp, 64-bit significand."""
    return (((sign & 1) << 15) | (exp & 0x7FFF), signif & SIGNIF_MASK)


def hex20(se, sig):
    """qref/oracle 20-hex encoding: signExp(4) || significand(16)."""
    return "%04x%016x" % (se & 0xFFFF, sig & SIGNIF_MASK)


def val80_int(se, sig):
    """The 80-bit value as a single integer (signExp<<64 | signif)."""
    return ((se & 0xFFFF) << 64) | (sig & SIGNIF_MASK)


def data_bytes(se, sig):
    """Little-endian 10-byte tbyte image: significand(8) then signExp(2)."""
    return (sig & SIGNIF_MASK).to_bytes(8, "little") + (se & 0xFFFF).to_bytes(2, "little")


def exp_of(se):
    return se & 0x7FFF


def parse_hex20(tok):
    """Parse a 20-hex token (signExp||significand) into (se, sig)."""
    return (int(tok[:4], 16), int(tok[4:], 16))


# --- curated special / corner-case pools -------------------------------------
# Two tiers, so one exploratory divergence can't mask the clean suite:
#   CORE  — IEEE-valid specials (zeros, Inf, QNaN/SNaN, indefinite, smallest/
#           largest normal, denormals). GATED: RTL must match QEMU exactly and
#           the QEMU golden must match the SoftFloat oracle.
#   UNSUP — the x87 "unsupported" encodings (pseudo-denormal / unnormal /
#           pseudo-Inf / pseudo-NaN) that the legacy corpus avoids. QEMU and the
#           RTL may legitimately differ here, so these run as INFORMATIONAL.
def _with_negatives(P):
    out = list(P)
    for (tag, se, sig) in P:
        finite_nonzero = (exp_of(se) != 0x7FFF) and not (se == 0 and sig == 0)
        if finite_nonzero and not (se & 0x8000):
            out.append(("n_" + tag, se | 0x8000, sig))
    return out


def core_pool():
    P = []
    def add(tag, sign, exp, sig): P.append((tag, *mk(sign, exp, sig)))
    add("pzero",        0, 0x0000, 0)
    add("nzero",        1, 0x0000, 0)
    add("one",          0, 0x3FFF, INT_BIT)
    add("two",          0, 0x4000, INT_BIT)
    add("half",         0, 0x3FFE, INT_BIT)
    add("eight",        0, 0x4002, INT_BIT)
    add("pi",           0, 0x4000, 0xC90FDAA22168C235)
    add("just_below_1", 0, 0x3FFE, SIGNIF_MASK)          # 1 - 2^-64
    add("just_above_1", 0, 0x3FFF, INT_BIT | 1)          # 1 + 2^-63
    add("min_norm",     0, 0x0001, INT_BIT)              # smallest normal 2^-16382
    add("max_norm",     0, 0x7FFE, SIGNIF_MASK)          # largest finite
    add("min_denorm",   0, 0x0000, 1)                    # smallest subnormal 2^-16445
    add("max_denorm",   0, 0x0000, (1 << 63) - 1)        # largest subnormal
    add("mid_denorm",   0, 0x0000, 1 << 62)
    add("pinf",         0, 0x7FFF, INT_BIT)              # +Inf
    add("qnan",         0, 0x7FFF, INT_BIT | (1 << 62))  # +QNaN
    add("qnan_pl",      0, 0x7FFF, INT_BIT | (1 << 62) | 0x12345678)
    add("snan",         0, 0x7FFF, INT_BIT | 1)          # +SNaN (quiet bit clear, payload!=0)
    add("snan_pl",      0, 0x7FFF, INT_BIT | 0x0ABCDEF0)
    add("indef",        1, 0x7FFF, INT_BIT | (1 << 62))  # real indefinite
    return _with_negatives(P)


def unsup_pool():
    P = []
    def add(tag, sign, exp, sig): P.append((tag, *mk(sign, exp, sig)))
    add("pseudo_denorm",  0, 0x0000, INT_BIT)            # exp 0 but integer bit SET
    add("pseudo_denorm2", 0, 0x0000, INT_BIT | 0x1234)
    add("unnormal",       0, 0x3FFF, 1 << 62)            # exp!=0 but integer bit CLEAR
    add("unnormal2",      0, 0x4010, 0x0123456789ABCDEF)
    add("pseudo_inf",     0, 0x7FFF, 0)                  # exp all-ones, int bit clear, frac 0
    add("pseudo_nan",     0, 0x7FFF, 1 << 40)            # exp all-ones, int bit clear, frac!=0
    return _with_negatives(P)


# --- random operand generation -----------------------------------------------
def rand_normal(rng):
    sign = rng.getrandbits(1)
    exp = rng.randint(1, 0x7FFE)
    sig = INT_BIT | rng.getrandbits(63)
    return mk(sign, exp, sig)


def rand_small_normal(rng):
    sign = rng.getrandbits(1)
    exp = rng.randint(1, 200)                 # near the denormal boundary
    sig = INT_BIT | rng.getrandbits(63)
    return mk(sign, exp, sig)


def rand_large_normal(rng):
    sign = rng.getrandbits(1)
    exp = rng.randint(0x7F00, 0x7FFE)
    sig = INT_BIT | rng.getrandbits(63)
    return mk(sign, exp, sig)


def rand_denormal(rng):
    sign = rng.getrandbits(1)
    sig = rng.randint(1, (1 << 63) - 1)
    return mk(sign, 0, sig)


def rand_mid(rng):
    """A normal near 1.0 (exponents that make sums/products often inexact)."""
    sign = rng.getrandbits(1)
    exp = rng.randint(0x3F00, 0x40FF)
    sig = INT_BIT | rng.getrandbits(63)
    return mk(sign, exp, sig)


RAND_CATS = [
    (rand_mid,          0.34),
    (rand_normal,       0.26),
    (rand_small_normal, 0.14),
    (rand_large_normal, 0.10),
    (rand_denormal,     0.16),
]


def rand_value(rng):
    r = rng.random()
    acc = 0.0
    for fn, w in RAND_CATS:
        acc += w
        if r <= acc:
            return fn(rng)
    return rand_normal(rng)


# --- op table ----------------------------------------------------------------
# kind: 'bin2'  two-operand reg arithmetic (st0 op st1, no pop)   cleanup 2
#       'binim' implicit-stack binary (fprem/fprem1/fscale, no pop) cleanup 2
#       'trbin' transcendental binary (pops 1)                      cleanup 1
#       'un'    unary (no pop)                                      cleanup 1
# oracle: 'sf'  -> SoftFloat op name | 'qref' -> qref op | None -> QEMU-only
# gate  : True  -> the core tier of this op is GATED (RTL must match QEMU). The
#         set mirrors docs/m3-fpu-spec.md: Tier-2 arithmetic (add/sub/mul/div/
#         sqrt) + the trivially-exact sign ops. Tier-3 "best-effort" ops
#         (rndint/scale/rem/rem1), the QEMU-only compare, and transcendentals
#         run INFORMATIONAL (divergences reported, never fail the gate).
# tf : the matching Berkeley TestFloat generator function. When --testfloat-gen
#      is passed, testfloat_gen's renowned corner-case INPUT operands are ingested
#      as extra core vectors (its computed result is discarded; we re-derive the
#      expected value with our own oracle).
OPS = {
    "add":    dict(kind="bin2",  asm="fadd %st(1), %st(0)",  oracle="sf",   sfop="add",  gate=True, tf="extF80_add"),
    "sub":    dict(kind="bin2",  asm="fsub %st(1), %st(0)",  oracle="sf",   sfop="sub",  gate=True, tf="extF80_sub"),
    "mul":    dict(kind="bin2",  asm="fmul %st(1), %st(0)",  oracle="sf",   sfop="mul",  gate=True, tf="extF80_mul"),
    "div":    dict(kind="bin2",  asm="fdiv %st(1), %st(0)",  oracle="sf",   sfop="div",  gate=True, tf="extF80_div"),
    "sqrt":   dict(kind="un",    asm="fsqrt",                oracle="sf",   sfop="sqrt", gate=True, tf="extF80_sqrt"),
    "abs":    dict(kind="un",    asm="fabs",                 oracle="sf",   sfop="abs",  gate=True),
    "chs":    dict(kind="un",    asm="fchs",                 oracle="sf",   sfop="chs",  gate=True),
    "rndint": dict(kind="un",    asm="frndint",              oracle="sf",   sfop="rndint"),
    "rem1":   dict(kind="binim", asm="fprem1",               oracle="sf",   sfop="rem1"),
    "rem":    dict(kind="binim", asm="fprem",                oracle=None),
    "scale":  dict(kind="binim", asm="fscale",               oracle=None),
    "fucom":  dict(kind="binim", asm="fucom %st(1)",         oracle=None),
    # transcendentals (Group-B, qref-triangulated; RTL needs +VEN_TRANSCENDENTAL)
    "f2xm1":  dict(kind="un",    asm="f2xm1",                oracle="qref", qop="f2xm1",   trans=True),
    "fyl2x":  dict(kind="trbin", asm="fyl2x",                oracle="qref", qop="fyl2x",   trans=True),
    "fyl2xp1":dict(kind="trbin", asm="fyl2xp1",              oracle="qref", qop="fyl2xp1", trans=True),
    "fpatan": dict(kind="trbin", asm="fpatan",               oracle="qref", qop="fpatan",  trans=True),
}

CLEANUP = {"bin2": 2, "binim": 2, "trbin": 1, "un": 1}
IS_BINARY = {"bin2": True, "binim": True, "trbin": True, "un": False}

# x87 rounding control words (PC=64-bit, all exceptions masked); index = RC.
CW = ["0x037f", "0x077f", "0x0b7f", "0x0f7f"]   # RNE, down, up, truncate


# --- profiles ----------------------------------------------------------------
PROFILES = {
    # rr=random×random, sxr=specials×random per special, rc_extra=randoms per
    # extra RC, trans=transcendental vectors, max_vec=vectors/program (chunking),
    # sxs_rcs=which RCs get the special×special cross product, sxs_stride=keep
    # 1-in-N of that cross product.
    "smoke":    dict(rr=60,   sxr=2,  rc_extra=20,  trans=40,  max_vec=700,
                     sxs_rcs=[0],          sxs_stride=3),
    "default":  dict(rr=700,  sxr=16, rc_extra=120, trans=250, max_vec=1200,
                     sxs_rcs=[0, 1, 2, 3], sxs_stride=1),
    "thorough": dict(rr=3000, sxr=40, rc_extra=500, trans=800, max_vec=1400,
                     sxs_rcs=[0, 1, 2, 3], sxs_stride=1),
}


# --- vector construction -----------------------------------------------------
class Vec:
    __slots__ = ("op", "rc", "a", "b")   # a,b are (se,sig) tuples; b None for unary

    def __init__(self, op, rc, a, b=None):
        self.op, self.rc, self.a, self.b = op, rc, a, b


def trans_domain_value(op, rng):
    """A random operand inside the transcendental's valid domain."""
    if op == "f2xm1":                       # |x| <= 1
        x = rng.uniform(-1.0, 1.0)
        return from_double(x)
    if op == "fyl2xp1":                     # |x| < 1 - sqrt(2)/2 ~= 0.2929
        x = rng.uniform(-0.29, 0.29)
        return from_double(x)
    # fyl2x: x>0 ; fpatan: any.  return a positive-ish normal
    return rand_mid(rng)


def from_double(x):
    """Convert a Python float to an exact 80-bit (se,sig) via its bit pattern."""
    import struct
    bits = struct.unpack("<Q", struct.pack("<d", x))[0]
    sign = (bits >> 63) & 1
    e = (bits >> 52) & 0x7FF
    m = bits & ((1 << 52) - 1)
    if e == 0 and m == 0:
        return mk(sign, 0, 0)
    if e == 0x7FF:
        return mk(sign, 0x7FFF, INT_BIT | (m << 11))
    # normal double -> normal extF80 (exact widening)
    exp80 = e - 1023 + 16383
    sig80 = INT_BIT | (m << 11)
    return mk(sign, exp80, sig80)


def build_vectors(op, rng, prof, tier):
    """Construct the vector list for one op + tier ('core' or 'unsup').

    Transcendentals only emit a 'core' tier (random in-domain operands)."""
    spec = OPS[op]
    binary = IS_BINARY[spec["kind"]]
    trans = spec.get("trans", False)
    vecs = []

    if trans:
        if tier != "core":
            return vecs
        # transcendentals: random in-domain operands at RNE (qref single-shot
        # reference is RNE); the trsc sweep gates cover the other RC modes.
        for _ in range(prof["trans"]):
            a = trans_domain_value(op, rng)
            b = rand_mid(rng) if binary else None      # y operand for fyl2x/fpatan
            vecs.append(Vec(op, 0, a, b))
        return vecs

    core = [(se, sig) for (_t, se, sig) in core_pool()]

    def add_vec(rc, a, b):
        # keep a single fprem1 fully-reducing: |exp(a)-exp(b)| < 64.
        if op == "rem1" and b is not None and exp_of(a[0]) - exp_of(b[0]) >= 60:
            return
        vecs.append(Vec(op, rc, a, b))

    if tier == "unsup":
        # x87 unsupported encodings on one side, core specials / randoms on the
        # other (both orders). INFORMATIONAL only, RC0.
        upool = [(se, sig) for (_t, se, sig) in unsup_pool()]
        partners = core + [rand_value(rng) for _ in range(8)]
        for u in upool:
            if binary:
                for q in partners:
                    add_vec(0, u, q)
                    add_vec(0, q, u)
            else:
                add_vec(0, u, None)
        return vecs

    # ---- tier == "core" ----
    stride = prof["sxs_stride"]
    # special x special cross product (both orders cover non-commutative ops),
    # at each requested RC, keeping 1-in-`stride` to bound smoke runs.
    for rc in prof["sxs_rcs"]:
        k = 0
        for a in core:
            for b in (core if binary else [None]):
                if k % stride == 0:
                    add_vec(rc, a, b)
                k += 1
    # special x random / random x special (RC0)
    for a in core:
        for _ in range(prof["sxr"]):
            b = scale_b(op, rng) if binary else None
            add_vec(0, a, b)
            if binary:
                add_vec(0, scale_b(op, rng), a)         # random x special
    # random x random (the bulk, RC0)
    for _ in range(prof["rr"]):
        a = rand_value(rng)
        b = scale_b(op, rng) if binary else None
        add_vec(0, a, b)
    # extra random coverage at RC 1..3
    for rc in (1, 2, 3):
        for _ in range(prof["rc_extra"]):
            a = rand_value(rng)
            b = scale_b(op, rng) if binary else None
            add_vec(rc, a, b)
    return vecs


def scale_b(op, rng):
    """Second operand generator (FSCALE wants integer-ish exponents)."""
    if op == "scale":
        # mostly small integers, some large to probe overflow/underflow to Inf/0.
        if rng.random() < 0.2:
            n = rng.choice([-20000, -16383, -16000, 16000, 16383, 20000])
        else:
            n = rng.randint(-40, 40)
        return from_double(float(n))
    return rand_value(rng)


# --- program emission --------------------------------------------------------
def emit_program(name, vecs):
    """Return (asm_text, cases) for a list of vectors. cases carry the result
    record index (0-based instruction position) per vector."""
    lines = []
    cases = []
    data_labels = {}      # val80_int -> label
    data_order = []       # (label, se, sig)

    def label_for(se, sig):
        key = val80_int(se, sig)
        if key not in data_labels:
            lbl = "v%d" % len(data_order)
            data_labels[key] = lbl
            data_order.append((lbl, se, sig))
        return data_labels[key]

    text = []
    icount = [0]

    def insn(s):
        text.append("    " + s)
        idx = icount[0]
        icount[0] += 1
        return idx

    text.append("_start:")
    insn("fninit")                         # idx 0: clean known state

    cur_rc = -1
    for v in vecs:
        if v.rc != cur_rc:
            insn("fldcw cw%d" % v.rc)
            cur_rc = v.rc
        spec = OPS[v.op]
        binary = IS_BINARY[spec["kind"]]
        # load order: [B, A] for binary so st0=A, st1=B ; [A] for unary.
        if binary:
            insn("fldt %s" % label_for(*v.b))
            insn("fldt %s" % label_for(*v.a))
        else:
            insn("fldt %s" % label_for(*v.a))
        rec = insn(spec["asm"])            # the op; post-state record == rec
        for _ in range(CLEANUP[spec["kind"]]):
            insn("fstp %st(0)")
        cases.append(dict(
            op=v.op, rc=v.rc,
            a=hex20(*v.a),
            b=(hex20(*v.b) if binary else None),
            rec=rec,
            oracle=spec["oracle"],
        ))

    insn("movl $1, %eax")
    insn("xorl %ebx, %ebx")
    insn("int $0x80")
    total = icount[0]

    # assemble the source
    lines.append("# Auto-generated by verif/fpu87/gen_fpu87.py — DO NOT EDIT.")
    lines.append("# Copyright 2026 Anhang Li (AL-255). SPDX: Apache-2.0 WITH SHL-2.1")
    lines.append("    .text")
    lines.append("    .globl _start")
    lines.extend(text)
    lines.append("")
    lines.append("    .data")
    lines.append("    .align 16")
    for rc in range(4):
        lines.append("cw%d: .word %s" % (rc, CW[rc]))
    lines.append("    .align 16")
    for (lbl, se, sig) in data_order:
        b = data_bytes(se, sig)
        lines.append("%s: .byte %s   # %s" % (
            lbl, ",".join("0x%02x" % x for x in b), hex20(se, sig)))
    return "\n".join(lines) + "\n", cases, total


# --- oracle evaluation -------------------------------------------------------
def eval_softfloat(oracle, cases):
    """Batch-evaluate all SoftFloat cases; fill exp/flags in place."""
    sf = [c for c in cases if c["oracle"] == "sf"]
    if not sf:
        return
    inp = []
    for c in sf:
        spec = OPS[c["op"]]
        line = "%s %d %s" % (spec["sfop"], c["rc"], c["a"])
        if c["b"] is not None:
            line += " " + c["b"]
        inp.append(line)
    out = subprocess.run([oracle], input="\n".join(inp) + "\n",
                         capture_output=True, text=True, check=True).stdout.splitlines()
    if len(out) != len(sf):
        raise RuntimeError("oracle produced %d lines for %d cases" % (len(out), len(sf)))
    for c, line in zip(sf, out):
        parts = line.split()
        if parts[0] == "SKIP":
            c["exp"], c["flags"] = None, None
        else:
            c["exp"] = int(parts[0], 16)
            c["flags"] = int(parts[1], 16)


def tf_collect(tf_gen, func, n, level, binary, rng):
    """Ingest the first `n` Berkeley TestFloat input operands for `func`.

    testfloat_gen emits 'a [b] z flags' with each extF80 token already in the
    20-hex signExp||significand form. We keep only the INPUT operand(s); the
    expected result is re-derived by our own oracle. Returns [(a,b_or_None)]."""
    try:
        p = subprocess.Popen([tf_gen, "-level", str(level), func],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return []
    out = []
    try:
        for line in p.stdout:
            toks = line.split()
            if not toks:
                continue
            a = parse_hex20(toks[0])
            b = parse_hex20(toks[1]) if (binary and len(toks) >= 2) else None
            out.append((a, b))
            if len(out) >= n:
                break
    finally:
        p.stdout.close()
        p.terminate()
    return out


def eval_qref(qref, cases):
    """Per-vector qref evaluation for transcendental cases (RNE)."""
    for c in cases:
        if c["oracle"] != "qref":
            continue
        spec = OPS[c["op"]]
        a_se, a_fr = c["a"][:4], c["a"][4:]
        argv = [qref, spec["qop"], a_se, a_fr]
        if c["b"] is not None:                 # qref order is (y, x) = (b, a)
            b_se, b_fr = c["b"][:4], c["b"][4:]
            argv = [qref, spec["qop"], b_se, b_fr, a_se, a_fr]
        try:
            o = subprocess.run(argv, capture_output=True, text=True, check=True).stdout.strip()
            c["exp"] = int(o.split()[0], 16)
            c["flags"] = None
        except Exception:
            c["exp"], c["flags"] = None, None


# --- driver ------------------------------------------------------------------
def chunk(lst, n):
    for i in range(0, len(lst), n):
        yield lst[i:i + n]


def main(argv=None):
    p = argparse.ArgumentParser(description="x87 FPU random/corner-case generator")
    p.add_argument("--out", required=True)
    p.add_argument("--oracle", required=True, help="path to ven_fpu_oracle")
    p.add_argument("--qref", default=None, help="path to qref (transcendental oracle)")
    p.add_argument("--profile", default="default", choices=list(PROFILES))
    p.add_argument("--seed", type=int, default=0x5eed)
    p.add_argument("--ops", default=None, help="comma list to restrict ops")
    p.add_argument("--no-transcendental", action="store_true")
    p.add_argument("--testfloat-gen", default=None,
                   help="path to testfloat_gen; ingest its corner-case inputs")
    p.add_argument("--testfloat-n", type=int, default=4000,
                   help="max TestFloat input vectors per op (default 4000)")
    p.add_argument("--testfloat-level", type=int, default=1, choices=(1, 2),
                   help="TestFloat case level (2 = exhaustive corner cases)")
    p.add_argument("--load-addr", default="0x08048000")
    args = p.parse_args(argv)

    prof = PROFILES[args.profile]
    ops = list(OPS) if not args.ops else args.ops.split(",")
    if args.no_transcendental:
        ops = [o for o in ops if not OPS[o].get("trans")]
    if any(OPS[o].get("trans") for o in ops) and not args.qref:
        sys.stderr.write("WARN: transcendental ops requested but --qref not given; "
                         "their expected results will be omitted.\n")

    os.makedirs(args.out, exist_ok=True)
    index = []
    rng = random.Random(args.seed)

    for op in ops:
        if op not in OPS:
            sys.stderr.write("unknown op: %s\n" % op); continue
        trans = OPS[op].get("trans", False)
        for tier in ("core", "unsup"):
            # transcendentals: core tier only. RTL diff requires +VEN_TRANSCENDENTAL.
            if trans and tier != "core":
                continue
            gating = (tier == "core") and not trans and OPS[op].get("gate", False)
            sub_rng = random.Random(rng.getrandbits(64))
            vecs = build_vectors(op, sub_rng, prof, tier)
            # ingest Berkeley TestFloat corner-case inputs (core tier only)
            if tier == "core" and args.testfloat_gen and OPS[op].get("tf"):
                binary = IS_BINARY[OPS[op]["kind"]]
                for (a, b) in tf_collect(args.testfloat_gen, OPS[op]["tf"],
                                         args.testfloat_n, args.testfloat_level,
                                         binary, sub_rng):
                    vecs.append(Vec(op, 0, a, b))
            if not vecs:
                continue
            for ci, sub in enumerate(chunk(vecs, prof["max_vec"])):
                name = "fp_%s_%s_%02d" % (op, tier, ci)
                asm, cases, total = emit_program(name, sub)
                eval_softfloat(args.oracle, cases)
                if args.qref:
                    eval_qref(args.qref, cases)
                d = os.path.join(args.out, name)
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, name + ".s"), "w") as f:
                    f.write(asm)
                manifest = dict(
                    name=name, src="%s/%s.s" % (name, name),
                    elf="%s/%s.elf" % (name, name), image="%s/%s.flat" % (name, name),
                    load_addr=args.load_addr, entry=args.load_addr,
                    max_insn=total, x87=True,
                )
                with open(os.path.join(d, "manifest.json"), "w") as f:
                    json.dump(manifest, f, indent=2)
                with open(os.path.join(d, name + ".cases.jsonl"), "w") as f:
                    for c in cases:
                        f.write(json.dumps(c) + "\n")
                index.append(dict(name=name, dir=name, manifest="%s/manifest.json" % name,
                                  cases="%s/%s.cases.jsonl" % (name, name),
                                  op=op, tier=tier, gating=gating, trans=trans,
                                  n_vec=len(sub), max_insn=total))
                sys.stderr.write("  %-22s %5d vectors  %6d insns  %s\n"
                                 % (name, len(sub), total, "GATED" if gating else "info"))

    with open(os.path.join(args.out, "index.json"), "w") as f:
        json.dump(dict(profile=args.profile, seed=args.seed, programs=index), f, indent=2)
    sys.stderr.write("generated %d programs into %s\n" % (len(index), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
