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
  * gs_base (TLS) — the QEMU target-description parser must ignore commented
    `<reg>` examples.  With that contract honored, the linux-user g-packet
    reports the real GS base; this tool validates it against the TCB self pointer.
    `--gs-base` remains an explicit escape hatch for a known nonstandard target.
  * emulator-side fd state (open pak0.pak handle, the /p5q_video_capture fd) is
    NOT in a memory image; a bare restore won't capture frame writes. For a
    SIM proof-of-render, dump the framebuffer straight from Hunk memory instead.
    Full board restore needs a fd manifest + --restore-fds (TODO / F5).
"""
import sys, os, json, time, argparse, subprocess, struct

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


def scan_regions(rsp, lo, hi, coarse, page, verbose, anchors=()):
    """Dump mapped ranges in [lo,hi) plus ranges containing live pointers.

    A post-init image must include small, non-coarse-aligned mappings such as
    the Linux stack.  The normal sweep therefore probes at page granularity.
    `anchors` additionally preserves a complete mapping containing a live GPR
    pointer (notably ESP/EBP), even when it lies outside the requested sweep.
    read_mem -> None means unmapped (gdbstub 'E14').
    """
    regions, ranges = [], []

    def covered(addr):
        return any(start <= addr < end for start, end in ranges)

    def dump_run(probe, min_addr, max_addr):
        if probe < min_addr or probe >= max_addr or covered(probe):
            return False
        if rsp.read_mem(probe, 16) is None:
            return False
        start = probe & ~(page - 1)
        while start >= min_addr + page and rsp.read_mem(start - page, 16) is not None:
            start -= page
        end = start
        while end < max_addr and rsp.read_mem(end, 16) is not None:
            end += page
        if end <= start:
            return False
        before = len(regions)
        gt._append_phys_region(rsp, regions, start, end - start)
        for i in range(before, len(regions)):     # _append emits {paddr,hex}; the
            r = regions[i]                         # loader scans for OBJECTS that
            regions[i] = {"vaddr": r["paddr"],     # START with "vaddr" -> rebuild
                          "hex": r["hex"]}         # vaddr-FIRST (dict order matters)
        ranges.append((start, end))
        if verbose:
            sys.stderr.write("  region %08x..%08x (%d KiB)\n"
                             % (start, end, (end - start) // 1024))
        return True

    # Pointer-anchored mappings can live below the normal executable/data sweep
    # (Linux-user's randomized stack is the canonical example). Ignore the
    # conventional unmapped low page and out-of-address-space scalar values.
    for anchor in anchors:
        if 0x1000 <= anchor < hi:
            dump_run(anchor, 0x1000, hi)

    addr = lo
    while addr < hi:
        containing = next((end for start, end in ranges if start <= addr < end), None)
        if containing is not None:
            addr = containing
        elif dump_run(addr, lo, hi):
            addr = ranges[-1][1]
        else:
            addr += coarse
    return regions


def trace_from_stop(rsp, layout, raw, out_path, max_insn, want_x87, verbose):
    """Write a lock-step golden prefix from the already-stopped QEMU process.

    Capturing the image and the golden from the same stop makes a failed restore
    diagnosable: it is either incomplete CPU/memory state or a later host-resource
    dependency, never a race between two separately launched QEMU processes.
    """
    layout.anchor_tail(len(raw))
    eip, eflags, gpr, seg, x87 = gt.regs_to_fields(layout, raw)
    emit_x87 = want_x87 and layout.has("st0")
    cur_brk = None
    n_emitted = 0
    n_syscalls = 0

    def reg(name):
        value = layout.slice(raw, name)
        return 0 if value is None else value

    with open(out_path, "w") as f:
        f.write(tracefmt.dumps(tracefmt.header(
            "qemu-gdbstub-postinit", "func", x87=emit_x87,
            note="post-init snapshot companion; same stopped QEMU process")) + "\n")
        while n_emitted < max_insn:
            pc = eip
            site = rsp.read_mem(pc, 2)
            is_syscall = (site == b"\xcd\x80")
            if is_syscall:
                nr = reg("eax")
                call_args = (reg("ebx"), reg("ecx"), reg("edx"),
                             reg("esi"), reg("edi"), reg("ebp"))

            stop = gt.StopReply(rsp.step())
            while stop.kind == "output":
                stop = gt.StopReply(rsp.recv())
            if stop.kind in ("exit", "term"):
                break

            raw = rsp.read_g()
            eip, eflags, gpr, seg, x87 = gt.regs_to_fields(layout, raw)
            sys_call = None
            if is_syscall:
                ret = reg("eax")
                writes, gs_base = gt._syscall_effect(rsp, nr, call_args, ret)
                if nr == gt._NR["brk"]:
                    requested = call_args[0]
                    if cur_brk is None:
                        cur_brk = ret
                    elif requested and ret > cur_brk:
                        writes.append({"addr": cur_brk,
                                       "len": gt._u32(ret - cur_brk),
                                       "zero": True})
                    if requested and ret > cur_brk:
                        cur_brk = ret
                sys_call = tracefmt.sys_call_field(nr, ret, writes, gs_base)
                n_syscalls += 1
                if verbose:
                    sys.stderr.write("[snap] trace int80 n=%d nr=%d ret=%#x writes=%d\n"
                                     % (n_emitted, nr, gt._u32(ret), len(writes)))

            f.write(tracefmt.dumps(tracefmt.func_record(
                n_emitted, pc, eflags, gpr, seg,
                x87=(x87 if emit_x87 else None), sys_call=sys_call)) + "\n")
            n_emitted += 1

    sys.stderr.write("[snap] wrote trace %s: %d instructions, %d syscalls%s\n"
                     % (out_path, n_emitted, n_syscalls,
                        " (x87)" if emit_x87 else ""))


def _step_sigtrap(rsp, what):
    """Single-step one known instruction and reject anything but normal #DB."""
    stop = gt.StopReply(rsp.step())
    while stop.kind == "output":
        stop = gt.StopReply(rsp.recv())
    if stop.kind != "stop" or stop.signal != 5:
        raise gt.RSPError("%s did not complete with SIGTRAP" % what)


def _find_x87_env_pair(rsp, elf_path):
    """Find Quake's verified FNSTENV/FLDENV scratch pair in a static ELF.

    QEMU's i386 g-packet supplies logical ST values but intentionally hardcodes
    the full tag word to zero.  The pinned static Quake image contains a
    `MaskExceptions` helper whose two existing text instructions save and reload
    a 32-bit x87 environment through a writable .data scratch word.  Reusing
    those instructions avoids self-modifying stack/text probes altogether.
    """
    try:
        with open(elf_path, "rb") as f:
            elf = f.read()
    except OSError as exc:
        raise gt.RSPError("cannot read Quake ELF for x87 environment capture: %s" % exc)
    if len(elf) < 52 or elf[:4] != b"\x7fELF" or elf[4:6] != b"\x01\x01":
        raise gt.RSPError("x87 environment capture requires a 32-bit little-endian ELF")
    e_type = struct.unpack_from("<H", elf, 16)[0]
    if e_type != 2:                  # ET_EXEC: virtual addresses are fixed.
        raise gt.RSPError("x87 environment capture requires a non-PIE ET_EXEC Quake ELF")
    phoff = struct.unpack_from("<I", elf, 28)[0]
    phentsz, phnum = struct.unpack_from("<HH", elf, 42)
    if phentsz < 32 or phoff + phentsz * phnum > len(elf):
        raise gt.RSPError("Quake ELF has malformed program headers")

    saw_pair = False
    for p in range(phnum):
        off = phoff + p * phentsz
        p_type, p_off, p_vaddr, _p_paddr, p_filesz, _p_memsz, p_flags, _p_align = \
            struct.unpack_from("<IIIIIIII", elf, off)
        if p_type != 1 or not (p_flags & 1) or p_off + p_filesz > len(elf):
            continue
        text = elf[p_off:p_off + p_filesz]
        pos = 0
        while True:
            pos = text.find(b"\xd9\x35", pos)
            if pos < 0:
                break
            seq = text[pos:pos + 20]
            if (len(seq) == 20 and seq[6:8] == b"\x83\x0d" and
                    seq[8:12] == seq[2:6] and seq[12] == 0x3f and
                    seq[13:15] == b"\xd9\x25" and seq[15:19] == seq[2:6] and
                    seq[19] == 0xc3):
                saw_pair = True
                code_addr = (p_vaddr + pos) & 0xffffffff
                scratch = int.from_bytes(seq[2:6], "little")
                # Never redirect the stopped guest unless every dependency is
                # proven live: exact executable bytes, readable scratch, and a
                # no-op RSP write/read-back to the writable scratch.
                if rsp.read_mem(code_addr, len(seq)) != seq:
                    pos += 1
                    continue
                old_scratch = rsp.read_mem(scratch, 28)
                if old_scratch is None or len(old_scratch) != 28:
                    pos += 1
                    continue
                if (not rsp.write_mem(scratch, old_scratch) or
                        rsp.read_mem(scratch, 28) != old_scratch):
                    pos += 1
                    continue
                return code_addr, code_addr + 13, scratch, old_scratch
            pos += 1
    if saw_pair:
        raise gt.RSPError("Quake FNSTENV/FLDENV pair is not live or writable in this process")
    raise gt.RSPError("could not find the verified Quake FNSTENV/FLDENV environment pair")


def capture_x87_state(rsp, layout, raw, elf_path):
    """Return (restored-g-packet, 28-byte x87 environment) without guest drift.

    The two instructions are existing Quake instructions.  FNSTENV captures the
    authoritative full tag/pointer environment; FLDENV restores x87 state; then
    the original .data scratch bytes and EIP are restored and checked.  No code
    page is ever modified, so QEMU's self-modifying-code protections cannot leave
    a debugger stub behind in the process image.
    """
    eip = layout.slice(raw, "eip")
    if eip is None:
        raise gt.RSPError("cannot read EIP for x87 environment capture")
    fnenv_addr, fldenv_addr, scratch, old_scratch = _find_x87_env_pair(rsp, elf_path)
    if not rsp.write_register(layout, "eip", eip):
        raise gt.RSPError("gdbstub does not support the EIP restore needed for x87 capture")

    saved = None
    fpu_dirty = False
    fpu_restored = False
    recovery_error = None
    try:
        if not rsp.write_register(layout, "eip", fnenv_addr):
            raise gt.RSPError("could not enter Quake FNSTENV capture instruction")
        _step_sigtrap(rsp, "FNSTENV capture")
        fpu_dirty = True
        saved = rsp.read_mem(scratch, 28)
        if saved is None or len(saved) != 28:
            raise gt.RSPError("FNSTENV did not produce a complete 32-bit environment")
        if not rsp.write_register(layout, "eip", fldenv_addr):
            raise gt.RSPError("could not enter Quake FLDENV restore instruction")
        _step_sigtrap(rsp, "FLDENV restore")
        fpu_restored = True
    finally:
        # A failed path after FNSTENV must attempt the paired existing FLDENV
        # before reporting the error.  A failure here is fatal and the outer
        # launcher kills QEMU; no JSON is emitted from a partially restored state.
        if fpu_dirty and not fpu_restored:
            try:
                if not rsp.write_register(layout, "eip", fldenv_addr):
                    raise gt.RSPError("could not enter emergency FLDENV restore")
                _step_sigtrap(rsp, "emergency FLDENV restore")
                fpu_restored = True
            except Exception as exc:
                recovery_error = exc
        try:
            if (not rsp.write_mem(scratch, old_scratch) or
                    rsp.read_mem(scratch, 28) != old_scratch):
                raise gt.RSPError("could not restore Quake x87 scratch bytes")
            if not rsp.write_register(layout, "eip", eip):
                raise gt.RSPError("could not restore EIP after x87 environment capture")
        except Exception as exc:
            raise gt.RSPError("failed to restore x87 debugger state: %s" % exc)
        if recovery_error is not None:
            raise gt.RSPError("failed to restore x87 state after capture: %s" % recovery_error)

    restored = rsp.read_g()
    # The g-packet's tag word is intentionally abridged, but equality still
    # detects corruption of all g-packet-visible state. `saved` carries the full
    # tag word consumed by the snapshot loader.
    for name in (tracefmt.GPR_KEYS + ["eip", "eflags"] + tracefmt.X87_REGS +
                 ["fctrl", "fstat", "ftag", "fioff", "fooff", "fiseg", "foseg"]):
        if layout.has(name) and layout.slice(restored, name) != layout.slice(raw, name):
            raise gt.RSPError("x87 environment probe failed to restore %s" % name)
    return restored, saved


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
    ap.add_argument("--trace-out", default=None,
                    help="write a lock-step golden prefix from this stopped state")
    ap.add_argument("--trace-insns", type=int, default=0,
                    help="positive instruction count required with --trace-out")
    ap.add_argument("--trace-x87", action="store_true",
                    help="include x87 state in the companion golden")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    a = ap.parse_args()
    if ((a.trace_out is None and a.trace_insns != 0) or
            (a.trace_out is not None and a.trace_insns <= 0) or
            (a.trace_x87 and a.trace_out is None)):
        ap.error("--trace-out and a positive --trace-insns must be supplied together")
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
        layout.anchor_tail(len(raw))
        raw, xenv = capture_x87_state(rsp, layout, raw, a.elf)
        eip, eflags, gpr, seg, x87 = gt.regs_to_fields(layout, raw)
        if x87 is None:
            raise gt.RSPError("post-init snapshots require an x87-capable QEMU g-packet")

        # seg_base: flat (0) for ss/ds/es; FS/GS come directly from the corrected
        # QEMU g-packet layout. For the non-flat Linux TLS selector, validate the
        # reported GS base against the TCB's ABI self pointer before accepting it.
        seg_base = {k: 0 for k in ("ss_base", "ds_base", "es_base", "fs_base", "gs_base")}
        for br in ("fs_base", "gs_base"):
            v = layout.slice(raw, br) if layout.has(br) else None
            if v:
                seg_base[br] = v & 0xFFFFFFFF
        if a.gs_base is not None:
            seg_base["gs_base"] = int(a.gs_base, 0)
            gs_base_source = "override"
        elif seg["gs"]:
            tcb = read_u32(rsp, seg_base["gs_base"])
            if seg_base["gs_base"] == 0 or tcb != seg_base["gs_base"]:
                raise gt.RSPError("non-flat GS base is absent or fails the TCB self-pointer check; use --gs-base only with an authoritative value")
            gs_base_source = "g-packet-tcb-validated"
        else:
            seg_base["gs_base"] = 0
            gs_base_source = "flat"

        sys.stderr.write("[snap] eip=%08x esp=%08x gs=%04x gs_base=%08x (%s) — scanning memory...\n"
                         % (eip, gpr["esp"], seg["gs"], seg_base["gs_base"], gs_base_source))
        # Page granularity matters: a 1 MiB probe can skip a 4 KiB randomized
        # stack mapping entirely.  Register anchors retain any live mapped page
        # below --scan-lo as well (e.g. a low constrained user stack).
        anchors = [eip] + list(gpr.values()) + list(seg_base.values())
        regions = scan_regions(rsp, int(a.scan_lo, 0), int(a.scan_hi, 0),
                               0x1000, 0x1000, a.verbose, anchors)
        nbytes = sum(len(bytes.fromhex(r["hex"])) for r in regions if "hex" in r)

        # ST(i) values in the g-packet are TOP-relative.  Keep all x87 fields,
        # including the full tag word and environment pointers, so the restore
        # consumer can reconstruct the physical register file without guessing.
        fpu = {k: tracefmt.h80(x87[k]) for k in tracefmt.X87_REGS}
        # Intel's 32-bit FNSTENV image places its full control/status/tag state
        # at offsets 0/4/8 and FIP/FCS/FOP at 12/16, FDP/FDS at 20/24. Prefer
        # this authoritative environment over QEMU's deliberately abridged GDB
        # tag/pointer fields.
        fpu["fctrl"] = tracefmt.hx(int.from_bytes(xenv[0:2], "little"), 16)
        fpu["fstat"] = tracefmt.hx(int.from_bytes(xenv[4:6], "little"), 16)
        fpu["ftag"]  = tracefmt.hx(int.from_bytes(xenv[8:10], "little"), 16)
        fpu["fioff"] = tracefmt.h32(int.from_bytes(xenv[12:16], "little"))
        fcs_fop = int.from_bytes(xenv[16:20], "little")
        fpu["fiseg"] = tracefmt.hx(fcs_fop & 0xffff, 16)
        fpu["fop"]   = tracefmt.hx((fcs_fop >> 16) & 0x07ff, 16)
        fpu["fooff"] = tracefmt.h32(int.from_bytes(xenv[20:24], "little"))
        fpu["foseg"] = tracefmt.hx(int.from_bytes(xenv[24:26], "little"), 16)

        img = {
            "regs": {k: tracefmt.h32(gpr[k]) for k in tracefmt.GPR_KEYS},
            "seg":  {k: "0x%04x" % seg[k] for k in tracefmt.SEG_KEYS},
            "seg_base": {k: tracefmt.h32(v) for k, v in seg_base.items()},
            "fpu": fpu,
            "regions": regions,
            "meta": {
                "producer": "quake_snapshot-postinit",
                "elf": os.path.basename(a.elf),
                "break": "0x%08x" % bp, "hits": a.hits,
                "regions": len(regions), "bytes": nbytes,
                "arch_state": "ventium-modeled-user-checkpoint",
                "gs_base_source": gs_base_source,
                "note": "post-Alpha_Init Quake snapshot: load regions and Ventium-modeled "
                        "user architectural state, then run from EIP without re-doing Alpha_Init.",
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
        if a.trace_out is not None:
            trace_from_stop(rsp, layout, raw, a.trace_out, a.trace_insns,
                            a.trace_x87, a.verbose)
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
