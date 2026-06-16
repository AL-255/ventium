#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""quake_fpstate.py — capture qemu's x87 FP state at the post-Alpha_Init snapshot
point and inject an FRSTOR image + stub into a Quake snapshot JSON.

The snapshot format carries int regs + segs + memory but NOT the x87 FP register
stack, so a bare restore stalls the render path (FP ops on an empty stack). The
core implements FRSTOR (DD /4, 108-byte FSAVE image), so we:
  1. re-run qemu to the SAME breakpoint (deterministic) and read st0..st7 + the
     control/status/tag words from the g-packet,
  2. build the 108-byte FSAVE image (placed at 0x08047200),
  3. extend the entry stub (0x08047000) to `frstor [0x08047200]` before it jmps
     to Host_Frame — same no-respin pattern as the TLS (set_thread_area) stub.

    quake_fpstate.py --qemu <qemu-i386> --elf <tyr-quake-p5> --break 0x0807d540 \
        --hits 3 --in post_init2_stub.json --out post_init3.json \
        --args -basedir <qdata> -noconinput -nosound -mem 32
"""
import sys, os, json, struct, argparse, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "verif", "qemu-trace"))
import gen_trace as gt
import quake_snapshot as qs   # reuse cont_to_bp / step_off / clr_bp

FRSTOR_ADDR = 0x08047200
STUB_ADDR   = 0x08047000

def find_fp_tail(raw):
    """The RegLayout/anchor_tail naive offset for st0 is wrong for this qemu build,
    so locate the FP tail directly: st0..st7 are eight 80-bit extended floats. Score
    each candidate offset (>=64, past the int/seg block) by how many of the 8 slots
    are a normalized float (mantissa integer-bit set + sane biased exponent) or a
    clean empty (all-zero). The right offset scores 16 (all eight registers)."""
    best, bestscore = None, -1
    for off in range(64, len(raw) - 112):
        sc = 0
        for k in range(8):
            b = raw[off + k*10 : off + k*10 + 10]
            e = struct.unpack('<H', b[8:10])[0] & 0x7fff
            if int.from_bytes(b, 'little') == 0:        sc += 1       # empty slot
            elif (0x3f00 <= e <= 0x4200) and (b[7] & 0x80): sc += 2   # normalized float
        if sc > bestscore: bestscore, best = sc, off
    return best, bestscore

def build_fsave(raw):
    off, score = find_fp_tail(raw)
    fctrl = struct.unpack('<H', raw[off+80 : off+82])[0]
    fstat = struct.unpack('<H', raw[off+84 : off+86])[0]
    ftag  = struct.unpack('<H', raw[off+88 : off+90])[0]
    sys.stderr.write("[fp] FP tail @g-off %d score %d  fctrl=%04x fstat=%04x(TOP=%d) ftag=%04x\n"
                     % (off, score, fctrl, fstat, (fstat >> 11) & 7, ftag))
    img = bytearray(108)
    struct.pack_into('<H', img, 0, fctrl)   # FCW (0x037f = masked, expected)
    struct.pack_into('<H', img, 4, fstat)   # FSW (carries TOP)
    struct.pack_into('<H', img, 8, ftag)    # FTW
    # FIP(12)/FCS+FOP(16)/FDP(20)/FDS(24): exception bookkeeping, irrelevant -> 0
    for i in range(8):
        img[28 + i*10 : 28 + i*10 + 10] = raw[off + i*10 : off + i*10 + 10]  # physical order
    return bytes(img)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True); ap.add_argument("--elf", required=True)
    ap.add_argument("--break", dest="brk", required=True)
    ap.add_argument("--hits", type=int, default=3)
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=51177)
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    a = ap.parse_args()
    bp = int(a.brk, 0)

    env = dict(os.environ); env.setdefault("P5Q_VIDEO", "/p5q_video_capture")
    cmd = [a.qemu, "-g", str(a.port), a.elf] + a.args
    sys.stderr.write("launch: %s\n" % " ".join(cmd))
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rsp = None
    try:
        rsp = gt.RSPClient(port=a.port, timeout=a.timeout); rsp.handshake()
        layout = rsp.discover_layout()
        for i in range(a.hits):
            qs.cont_to_bp(rsp, bp, a.timeout)
            if i < a.hits - 1: qs.step_off(rsp, bp)
        qs.clr_bp(rsp, bp)
        raw = rsp.read_g()
        eip, eflags, gpr, seg, _x87 = gt.regs_to_fields(layout, raw)
        sys.stderr.write("[fp] eip=%08x (g-packet %d bytes)\n" % (eip, len(raw)))
        fsave = build_fsave(raw)
        for i in range(8):
            st = int.from_bytes(fsave[28+i*10 : 28+i*10+10], 'little')
            sys.stderr.write("[fp] st%d = %020x\n" % (i, st))
    finally:
        if rsp is not None:
            try: rsp.send("k")
            except Exception: pass
            rsp.close()
        try: proc.kill()
        except Exception: pass

    # ---- inject FRSTOR image + extend the entry stub ----
    d = json.load(open(a.inp))
    # new stub @0x08047000: TLS (set_thread_area + mov gs,0x33) + frstor + jmp Host_Frame
    # 7014 dd 25 00720408   frstor [0x08047200]   (6 bytes)
    # 701c e9 1f650300       jmp 0x0807d540 (rel = 0x0807d540-(0x0804701c+5)=0x3651f)
    stub = bytes.fromhex('5053' + 'b8f3000000' + 'bb00710408' + 'cd80' +
                         '66b83300' + '8ee8' + 'dd2500720408' + '5b58' + 'e91f650300')
    assert (0x0804701c + 5 + 0x3651f) == 0x0807d540
    regs = [r for r in d['regions'] if r['vaddr'] not in ('0x08047000',)]
    regs.append({'vaddr': '0x08047000', 'hex': stub.hex()})
    regs.append({'vaddr': '0x%08x' % FRSTOR_ADDR, 'hex': fsave.hex()})
    d['regions'] = regs
    d['regs']['eip'] = '0x08047000'
    json.dump(d, open(a.out, 'w'), separators=(',', ':'))
    sys.stderr.write("[fp] wrote %s (stub+frstor; %d regions, fsave@0x%08x)\n"
                     % (a.out, len(regs), FRSTOR_ADDR))
    return 0

if __name__ == "__main__":
    sys.exit(main())
