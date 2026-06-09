#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# In-core FSIN/FCOS check: core st0 == the shared-poly model (qref), bit-exact;
# also report the core-vs-qemu spread (qemu = double precision, expected large).
import os, sys, json, struct, subprocess, tempfile

ROOT = os.path.dirname(os.path.abspath(__file__)) + "/../.."
QEMU=os.environ["QEMU"]; GEN=os.environ["GEN_TRACE"]; ELF2FLAT=os.environ["ELF2FLAT"]
QREF=os.environ["QREF"]; TB=os.environ["TB_BIN"]; CC=os.environ["CC"]; W=os.environ["W"]
LOAD=0x08048000

def x80(v):  # python float -> (se,frac) floatx80 via struct (host long double is 80-bit)
    b = struct.pack("<d", v)
    # build floatx80 from double bits
    import math
    if v==0.0: return (0x8000 if math.copysign(1,v)<0 else 0x0000, 0)
    m,e = math.frexp(abs(v))           # v=m*2^e, m in [0.5,1)
    frac = int(m*2*(1<<63)) & ((1<<64)-1)
    se = ((1 if v<0 else 0)<<15) | ((e-1+16383)&0x7fff)
    return (se, frac)

def model(op, se, fr):
    out = subprocess.run([QREF, op, f"{se:x}", f"{fr:x}"], capture_output=True, text=True, check=True).stdout.strip()
    return int(out,16)

def run(op, mnem, prefix):
    # inputs across [-2pi, 2pi] + a few larger
    xs = [i/16.0 for i in range(-100,101)] + [3.14159, -3.14159, 10.0, 100.0, 0.0, 1e-6]
    data=bytearray()
    for v in xs:
        se,fr = x80(v); data += struct.pack("<QH", fr, se)
    s=['    .text','    .globl _start','_start:']
    for i in range(len(xs)):
        s += [f'    fldt invals+{i*10}', f'    {mnem}', '    fstp %st(0)']
    s += ['    movl $1,%eax','    xorl %ebx,%ebx','    int $0x80','    .data','invals:']
    for i in range(len(xs)):
        s.append('    .byte '+','.join(f'0x{c:02x}' for c in data[i*10:(i+1)*10]))
    asm="\n".join(s)+"\n"
    ep=f"{W}/{op}.elf"; fp=f"{W}/{op}.flat"; gp=f"{W}/{op}.gold"; rp=f"{W}/{op}.rtl"
    sp=f"{W}/{op}.s"; open(sp,"w").write(asm)
    maxins=len(xs)*3+4
    subprocess.run([CC,"-m32","-march=pentium","-nostdlib","-static","-Wl,--build-id=none",
                    f"-Wl,-Ttext={hex(LOAD)}","-o",ep,sp],check=True)
    subprocess.run([sys.executable,ELF2FLAT,ep,"--out",fp,"--base",hex(LOAD)],check=True,stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable,GEN,"--qemu",QEMU,"--elf",ep,"--out",gp,"--max-insn",str(maxins),"--x87"],
                   check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    gold=[json.loads(l) for l in open(gp) if l.strip() and not l.startswith("#")]
    esp=gold[1]["esp"]
    subprocess.run([TB,"--image",fp,"--load",hex(LOAD),"--entry",hex(LOAD),"--init-esp",esp,
                    "--out",rp,"--max-insn",str(maxins),"--x87"],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    rtl=[json.loads(l) for l in open(rp) if l.strip() and not l.startswith("#")]
    # The RTL (cosim) trace carries no `bytes` field, but both traces are n-aligned
    # (same instruction stream). Find the fsin/fcos record indices from the GOLD's
    # bytes, then read st0 at those same n's in both traces.
    rtl_by_n={r["n"]:r for r in rtl if "n" in r}
    gold_by_n={r["n"]:r for r in gold if "n" in r}
    op_ns=[r["n"] for r in gold if "n" in r and r.get("bytes","").lower().startswith(prefix)]
    rtl_st0=[int(rtl_by_n[n]["st0"],16)&((1<<80)-1) for n in op_ns]
    qemu_st0=[int(gold_by_n[n]["st0"],16)&((1<<80)-1) for n in op_ns]
    fails=0; worst_qemu=0.0
    for i,v in enumerate(xs):
        se,fr=x80(v); exp=model(op,se,fr)
        if rtl_st0[i]!=exp:
            fails+=1
            if fails<=8: print(f"  MODEL MISMATCH x={v} core={rtl_st0[i]:020x} model={exp:020x}")
        # core-vs-qemu ulp (documentation, EXACT via integer mantissa): when the
        # exponents+sign match, 1 ulp == 1 unit in the 64-bit fraction.
        c=rtl_st0[i]; q=qemu_st0[i]
        if (c>>64)==(q>>64):                       # same sign+exp
            worst_qemu=max(worst_qemu, abs((c&((1<<64)-1)) - (q&((1<<64)-1))))
    print(f"{op}: {len(xs)} cases | core==model: {len(xs)-fails}/{len(xs)} | worst core-vs-qemu = {worst_qemu:.0f} ulp (qemu=double-precision, ~2^11)")
    return fails

def fx_to_float(v):
    se=(v>>64)&0xffff; fr=v&((1<<64)-1); sign=-1.0 if (se>>15) else 1.0
    e=se&0x7fff
    if e==0 and fr==0: return 0.0
    return sign * fr * (2.0**(e-16383-63))

def main():
    f = run("fsin","fsin","d9fe") + run("fcos","fcos","d9ff")
    if f==0:
        print("FSINCOS-CORE-GATE-OK  (core st0 == silicon model, bit-exact)")
        print("FSINCOS-CORE-GATE: PASS")
        return 0
    print("FSINCOS-CORE-GATE: FAIL"); return 1

if __name__=="__main__":
    sys.exit(main())
