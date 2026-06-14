#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""quake_snapshot.py — capture a POST-init Quake process image from qemu-i386.

The RTL/board load an image.json (regions[] + regs/seg/seg_base) and run from
there. The stock image is dumped at the ELF entry, so the RTL re-runs the WHOLE
~1B-instruction Alpha_Init translucency precompute (~6 min on-board, hours in
sim). This tool fast-forwards the GOLDEN qemu (free-run, full speed) to a
breakpoint PAST that precompute (e.g. the Nth Host_Frame), then snapshots live
memory + registers into a fresh image.json -> the RTL starts already-initialized
and renders in a few million instructions.

    quake_snapshot.py --qemu <qemu-i386> --elf <tyr-quake-p5> \
        --break 0x0807d540 --hits 3 --out post_init.json \
        --args -basedir <qdata> -noconinput -nosound -mem 32

Reuses verif/qemu-trace/gen_trace.py's RSP client + register-layout parsing.

CAVEATS (see L1C_BUG.md / the snapshot notes):
  * gs_base (TLS) — qemu's gdbstub g-packet TLS base is unreliable for
    linux-user; we recover it from the TCB self-pointer at %gs:0 (musl/glibc
    store the TCB address there == gs_base). Override with --gs-base if needed.
  * emulator-side fd state (open pak0.pak handle, the /p5q_video_capture fd) is
    NOT in a memory image; a bare restore won't capture frame writes. For a
    SIM proof-of-render, dump the framebuffer straight from Hunk memory instead.
    Full board restore needs a fd manifest + --restore-fds (TODO / F5).
"""
import sys, os, json, time, argparse, subprocess

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "verif", "qemu-trace"))
import gen_trace as gt          # RSPClient, regs_to_fields, RSPError
import tracefmt                 # GPR_KEYS / SEG_KEYS / h32


def _ok(rsp, cmd):
    rsp.send(cmd); return rsp.recv()


def set_bp(rsp, addr):   return _ok(rsp, "Z0,%x,1" % addr)
def clr_bp(rsp, addr):   return _ok(rsp, "z0,%x,1" % addr)


def cont_to_bp(rsp, addr, timeout):
    """Insert a SW breakpoint, continue (free-run), block until it traps."""
    set_bp(rsp, addr)
    rsp.sock.settimeout(timeout)
    rsp.send("c")
    while True:
        rep = rsp.recv()
        k = rep[:1]
        if k in (b"T", b"S"):                      # stopped (trap)
            return rep
        if k in (b"W", b"X"):                      # exited / killed
            raise gt.RSPError("guest exited before breakpoint: %r" % rep)
        if k == b"O":                              # console output — keep waiting
            continue
        return rep


def step_off(rsp, addr):
    """Step one instruction off the breakpoint location so the next continue
    advances (clear bp, single-step, the caller re-inserts)."""
    clr_bp(rsp, addr)
    rsp.send("s"); rsp.recv()


def read_u32(rsp, addr):
    b = rsp.read_mem(addr, 4)
    return None if b is None or len(b) < 4 else int.from_bytes(b, "little")


def scan_regions(rsp, lo, hi, coarse, page, verbose):
    """Coarse-probe [lo,hi) for mapped memory; dump each mapped run (page-
    aligned) as a region. read_mem -> None means unmapped (gdbstub 'E14')."""
    regions, addr = [], lo
    while addr < hi:
        if rsp.read_mem(addr, 16) is None:
            addr += coarse; continue
        # found a mapped coarse block — walk back to its page start, then
        # forward page-by-page to the end of the contiguous mapped run.
        start = addr & ~(page - 1)
        while start > lo and rsp.read_mem(start - page, 16) is not None:
            start -= page
        end = start
        while end < hi and rsp.read_mem(end, 16) is not None:
            end += page
        before = len(regions)
        gt._append_phys_region(rsp, regions, start, end - start)
        for i in range(before, len(regions)):     # _append emits {paddr,hex}; the
            r = regions[i]                         # loader scans for OBJECTS that
            regions[i] = {"vaddr": r["paddr"],     # START with "vaddr" -> rebuild
                          "hex": r["hex"]}         # vaddr-FIRST (dict order matters)
        if verbose:
            sys.stderr.write("  region %08x..%08x (%d KiB)\n"
                             % (start, end, (end - start) // 1024))
        addr = end + coarse
    return regions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--elf", required=True)
    ap.add_argument("--break", dest="brk", required=True,
                    help="breakpoint EIP (hex), e.g. Host_Frame")
    ap.add_argument("--hits", type=int, default=3,
                    help="stop on the Nth hit (lets the first frames cache gfx)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=51099)
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--scan-lo", default="0x08000000")
    ap.add_argument("--scan-hi", default="0x41000000")
    ap.add_argument("--gs-base", default=None, help="override TLS gs_base (hex)")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    a = ap.parse_args()
    bp = int(a.brk, 0)

    env = dict(os.environ)
    env.setdefault("P5Q_VIDEO", "/p5q_video_capture")
    cmd = [a.qemu, "-g", str(a.port), a.elf] + a.args      # NO -one-insn-per-tb: free-run
    sys.stderr.write("launch: %s\n" % " ".join(cmd))
    proc = subprocess.Popen(cmd, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rsp = None
    try:
        rsp = gt.RSPClient(port=a.port, timeout=a.timeout, verbose=a.verbose)
        rsp.handshake()
        layout = rsp.discover_layout()
        for i in range(a.hits):
            cont_to_bp(rsp, bp, a.timeout)
            sys.stderr.write("[snap] breakpoint hit %d/%d @ %#x\n" % (i + 1, a.hits, bp))
            if i < a.hits - 1:
                step_off(rsp, bp)                 # advance so the next continue progresses
        clr_bp(rsp, bp)

        raw = rsp.read_g()
        eip, eflags, gpr, seg, _x87 = gt.regs_to_fields(layout, raw)

        # seg_base: flat (0) for ss/ds/es; fs/gs from the TLS. gs_base via the
        # TCB self-pointer at %gs:0 needs gs_base first, so try the g-packet slot,
        # then fall back to reading what the user_desc/TCB exposes.
        seg_base = {k: 0 for k in ("ss_base", "ds_base", "es_base", "fs_base", "gs_base")}
        for br in ("fs_base", "gs_base"):
            v = layout.slice(raw, br) if layout.has(br) else None
            if v:
                seg_base[br] = v & 0xFFFFFFFF
        if a.gs_base is not None:
            seg_base["gs_base"] = int(a.gs_base, 0)

        sys.stderr.write("[snap] eip=%08x esp=%08x gs=%04x gs_base=%08x — scanning memory...\n"
                         % (eip, gpr["esp"], seg["gs"], seg_base["gs_base"]))
        regions = scan_regions(rsp, int(a.scan_lo, 0), int(a.scan_hi, 0),
                               0x100000, 0x1000, a.verbose)
        nbytes = sum(len(bytes.fromhex(r["hex"])) for r in regions if "hex" in r)

        img = {
            "regs": {k: tracefmt.h32(gpr[k]) for k in tracefmt.GPR_KEYS},
            "seg":  {k: "0x%04x" % seg[k] for k in tracefmt.SEG_KEYS},
            "seg_base": {k: tracefmt.h32(v) for k, v in seg_base.items()},
            "regions": regions,
            "meta": {
                "producer": "quake_snapshot-postinit",
                "elf": os.path.basename(a.elf),
                "break": "0x%08x" % bp, "hits": a.hits,
                "regions": len(regions), "bytes": nbytes,
                "note": "post-Alpha_Init Quake snapshot: load regions + regs/seg, "
                        "run from EIP to render without re-doing the translucency precompute.",
            },
        }
        img["regs"]["eip"] = tracefmt.h32(eip)
        img["regs"]["eflags"] = tracefmt.h32(eflags)
        with open(a.out, "w") as f:
            # compact separators: quake_image.cpp is a TOKEN SCANNER that matches
            # `"eip":"0x` / `"vaddr":"0x` with NO space after the colon.
            json.dump(img, f, separators=(",", ":"))
        sys.stderr.write("[snap] wrote %s: %d regions, %.1f MiB, eip=%08x\n"
                         % (a.out, len(regions), nbytes / 1048576.0, eip))
        return 0
    finally:
        if rsp is not None:
            try: rsp.send("k")
            except Exception: pass
            rsp.close()
        try: proc.kill()
        except Exception: pass


if __name__ == "__main__":
    sys.exit(main())
