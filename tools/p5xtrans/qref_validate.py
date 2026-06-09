#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tools/p5xtrans/qref_validate.py — prove qref.c reproduces qemu-i386 bit-for-bit.
#
# qref.c is the QEMU-MODE reference the RTL engine's default mode must match (the
# `make verify` x87 gate). This harness closes the loop to the actual oracle:
#   1. read qref's --sweep (input80, expected80) pairs,
#   2. emit a freestanding i386 probe that does `fldt in_i ; f2xm1 ; fstp st0`
#      for every input,
#   3. trace it under the pinned qemu-i386 via gen_trace.py --x87 (the SAME oracle
#      the corpus uses), capturing st0 after each instruction,
#   4. at each `d9 f0` (f2xm1) record, compare st0 to qref's expected.
# Exit 0 + "QREF-F2XM1-QEMU-OK" iff every result matches to the bit.
import os, sys, json, struct, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
QEMU = os.path.join(ROOT, "ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386")
GEN  = os.path.join(ROOT, "verif/qemu-trace/gen_trace.py")
CC   = os.environ.get("CC", "gcc")
LOAD = 0x08048000

def parse80(tok):  # "SSSSFFFFFFFFFFFFFFFF" (4 hex se + 16 hex frac) -> (se, frac)
    return int(tok[:4], 16), int(tok[4:], 16)

def emit_bytes_80(se, frac):  # floatx80 in memory: frac (8 LE) then se (2 LE)
    return struct.pack("<QH", frac, se)

def validate_rc(rc):
    qref = os.path.join(HERE, "qref")
    sweep = subprocess.run([qref, "--sweep", str(rc)], capture_output=True, text=True, check=True).stdout
    pairs = []  # (in_se,in_frac, exp_se,exp_frac)
    for line in sweep.splitlines():
        a, b = line.split()
        ise, ifr = parse80(a); ese, efr = parse80(b)
        pairs.append((ise, ifr, ese, efr))
    # skip out-of-range / NaN-sentinel results (not produced by these inputs) — none here.

    # ---- build the asm probe -------------------------------------------------
    data = bytearray()
    for (ise, ifr, _, _) in pairs:
        data += emit_bytes_80(ise, ifr)
    # x87 control word per RC: default 0x037f, RC field = bits[11:10].
    cw = 0x037f | (rc << 10)
    s = []
    s.append('    .text')
    s.append('    .globl _start')
    s.append('_start:')
    s.append(f'    movw $0x{cw:04x}, %ax')
    s.append('    movw %ax, ctlw')
    s.append('    fldcw ctlw')
    for i in range(len(pairs)):
        s.append(f'    fldt invals+{i*10}')
        s.append('    f2xm1')
        s.append('    fstp %st(0)')
    s.append('    movl $1, %eax')
    s.append('    xorl %ebx, %ebx')
    s.append('    int $0x80')
    s.append('    .data')
    s.append('ctlw:   .word 0')
    s.append('invals:')
    # one .byte line per input (10 bytes)
    for i in range(len(pairs)):
        chunk = data[i*10:(i+1)*10]
        s.append('    .byte ' + ','.join(f'0x{c:02x}' for c in chunk))
    asm = "\n".join(s) + "\n"

    with tempfile.TemporaryDirectory() as td:
        sp = os.path.join(td, "probe.s"); ep = os.path.join(td, "probe.elf"); vp = os.path.join(td, "probe.vtrace")
        open(sp, "w").write(asm)
        subprocess.run([CC, "-m32", "-march=pentium", "-nostdlib", "-static",
                        "-Wl,--build-id=none", f"-Wl,-Ttext={hex(LOAD)}", "-o", ep, sp], check=True)
        maxins = len(pairs)*3 + 8     # +3 control-word setup insns + exit
        subprocess.run([sys.executable, GEN, "--qemu", QEMU, "--elf", ep,
                        "--out", vp, "--max-insn", str(maxins), "--x87"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        recs = [json.loads(l) for l in open(vp) if l.strip() and not l.startswith("#")]

    # ---- compare: each f2xm1 record's st0 vs qref expected -------------------
    fails = 0; n = 0
    idx = 0  # which f2xm1 we're on
    for r in recs:
        if not r.get("bytes", "").lower().startswith("d9f0"):
            continue
        st0 = int(r["st0"], 16) & ((1 << 80) - 1)
        q_se, q_fr = pairs[idx][2], pairs[idx][3]
        qexp = (q_se << 64) | q_fr
        in_se, in_fr = pairs[idx][0], pairs[idx][1]
        if st0 != qexp:
            fails += 1
            print(f"  MISMATCH in={in_se:04x}{in_fr:016x}  qref={qexp:020x}  qemu={st0:020x}")
        n += 1; idx += 1
    if idx != len(pairs):
        print(f"  WARN: matched {idx} f2xm1 records but had {len(pairs)} inputs")
    print(f"qref f2xm1 rc={rc}: {n} inputs traced through qemu-i386, {fails} mismatches")
    return 0 if (fails == 0 and n == len(pairs)) else 1

def main():
    # validate all four rounding modes (RNE / down / up / truncate) vs qemu-i386.
    rcs = [int(a) for a in sys.argv[1:]] or [0, 1, 2, 3]
    rv = 0
    for rc in rcs:
        rv |= validate_rc(rc)
    if rv == 0:
        print("QREF-F2XM1-QEMU-OK")
    return rv

if __name__ == "__main__":
    sys.exit(main())
