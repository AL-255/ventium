#!/usr/bin/env python3
"""Ventium Producer A — QEMU gdbstub golden architectural-state trace generator.

This is the *functional oracle* of the whole Ventium differential-testing stack
(see PLAN.md §4.1 and docs/trace-format.md, where this tool is "Producer A").

Why the gdbstub and not a TCG plugin?  QEMU 8.2.2's plugin API (QEMU_PLUGIN_VERSION 1)
*cannot read register values* — qemu_plugin_read_register only arrived in QEMU 9.0.
Plugins can see PC / instruction bytes / memory addresses (that's Producer B's job),
but the architectural register file is only observable through the GDB Remote Serial
Protocol (RSP) exposed by `qemu-i386 -g <port>`.  So we single-step the guest over
RSP and read the register file after every instruction.

We speak RSP directly over a TCP socket — NO dependency on a host `gdb` binary, and
NO third-party Python packages (stdlib only: socket / subprocess / struct / etc.).

State / record convention (docs/trace-format.md §2.1):
    record n describes the instruction *fetched* at `pc`, carrying the architectural
    state *immediately after it commits* (post-state).  So the loop is:
        read regs  -> pc = current eip   (fetch address of the insn about to run)
        step       -> execute that one instruction
        read regs  -> post-state; new eip is the next insn's fetch address
        emit {n, pc=old_eip, <post-state regs>}
    Hence pc(record n+1) == next-eip(record n) modulo control flow — the redundant
    control-flow check the comparator uses.

Field names / hex formatting are produced *exclusively* through
verif/diff/tracefmt.py (header()/func_record()/dumps()) so they can never drift
from the comparator's parser.

CLI:
    gen_trace.py --qemu <path> --elf <file> --out <trace.vtrace>
                 [--max-insn N] [--port P] [--args ...]
                 [--x87] [--stop-at 0xADDR] [--no-bytes] [--verbose]
"""
from __future__ import annotations

import argparse
import os
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import time

# --- import the shared trace format module (single source of field truth) -----
# verif/qemu-trace/gen_trace.py  ->  verif/diff/tracefmt.py
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_DIFF_DIR = os.path.normpath(os.path.join(_THIS_DIR, "..", "diff"))
if _DIFF_DIR not in sys.path:
    sys.path.insert(0, _DIFF_DIR)
import tracefmt  # noqa: E402  (path tweak above is intentional)


# =============================================================================
#  Register layout
# =============================================================================
# The g-packet is a flat little-endian byte image of the register file.  We
# discover its layout at runtime from the target description XML
# (qXfer:features:read:target.xml -> i386-32bit.xml), parsing every
# <reg name= bitsize=> in declaration order.  That order *is* the g-packet order.
#
# The classic i386 layout below is the documented fallback used only if qXfer
# fails.  It matches what QEMU actually serves for `qemu-i386` (verified live):
#   eax ecx edx ebx esp ebp esi edi   (8 GPRs, 32b)
#   eip(32) eflags(32)
#   cs ss ds es fs gs                 (selectors, each 32b *in the g-packet*)
#   st0..st7                          (80b each)
#   fctrl fstat ftag fiseg fioff foseg fooff fop   (each 32b)
# Note: QEMU's real description inserts ss_base..efer (12 extra 32b regs) between
# the segment selectors and st0, and appends xmm0..mxcsr after fop — none of
# which we emit, but the runtime parser handles them automatically by offset.
# (name, bits)
FALLBACK_LAYOUT = [
    ("eax", 32), ("ecx", 32), ("edx", 32), ("ebx", 32),
    ("esp", 32), ("ebp", 32), ("esi", 32), ("edi", 32),
    ("eip", 32), ("eflags", 32),
    ("cs", 32), ("ss", 32), ("ds", 32), ("es", 32), ("fs", 32), ("gs", 32),
    ("st0", 80), ("st1", 80), ("st2", 80), ("st3", 80),
    ("st4", 80), ("st5", 80), ("st6", 80), ("st7", 80),
    ("fctrl", 32), ("fstat", 32), ("ftag", 32), ("fiseg", 32),
    ("fioff", 32), ("foseg", 32), ("fooff", 32), ("fop", 32),
]


class RegLayout:
    """Ordered (name, bits, byte_offset) describing the g-packet image."""

    def __init__(self, regs):
        self.regs = []          # list of (name, bits)
        self.offset = {}        # name -> byte offset in g-packet
        self.nbits = {}         # name -> bit width
        off = 0
        for name, bits in regs:
            self.regs.append((name, bits))
            self.offset[name] = off
            self.nbits[name] = bits
            off += bits // 8
        self.total_bytes = off
        # Tail-anchor correction (see anchor_tail): the target description can
        # advertise registers (segment bases, CRx, EFER, ...) that QEMU does NOT
        # transmit in the 'g' packet, so the naive prefix-sum offsets for the
        # FP/SSE tail (st0..mxcsr) are wrong. We correct those by anchoring the
        # contiguous FP/SSE tail to the END of the actual g-packet image.
        self._tail_delta = 0          # bytes to add to tail-register offsets
        self._tail_from = None        # naive offset at/after which the delta applies

    def has(self, name):
        return name in self.offset

    def anchor_tail(self, actual_len: int):
        """Reconcile the layout with the real g-packet length.

        The integer/segment registers occupy the FRONT of the g-packet at their
        naive offsets (verified correct). The FP+SSE registers (st0..mxcsr) are a
        contiguous block at the TAIL. If the actual g-packet is shorter/longer
        than the naive total, the difference is entirely in the middle
        (un-transmitted sys/seg-base/CRx registers), so we shift the whole tail
        (everything at/after st0's naive offset) by that difference. This makes
        st0 land exactly `sizeof(st0..mxcsr)` before the end, regardless of which
        middle registers QEMU omits. No-op when lengths already match or there is
        no FP block. Idempotent-safe: call once after the first read_g().
        """
        anchor = "st0" if "st0" in self.offset else None
        if anchor is None:
            return
        delta = actual_len - self.total_bytes
        if delta == 0:
            return
        self._tail_delta = delta
        self._tail_from = self.offset[anchor]

    def slice(self, raw: bytes, name: str):
        """Return the little-endian integer for `name` from a raw g-packet image.

        Robustness: if the field is wholly/partly missing (g-packet truncated, as
        QEMU does for the xmm tail) or its bytes came back as 'xx' (unavailable),
        the caller has already turned those bytes into 0 — see decode_g_hex().
        """
        if name not in self.offset:
            return None
        off = self.offset[name]
        # Apply the tail-anchor correction to FP/SSE registers (st0 onward).
        if self._tail_from is not None and off >= self._tail_from:
            off += self._tail_delta
        nbytes = self.nbits.get(name, 0) // 8
        if off < 0 or off + nbytes > len(raw):
            return None
        chunk = raw[off:off + nbytes]
        return int.from_bytes(chunk, "little")


def parse_target_xml_layout(features: dict):
    """Build a RegLayout from the {filename: xml_text} feature documents.

    target.xml lists <xi:include href="..."/> children; each included feature
    file lists <reg name= bitsize= ...> in g-packet order.  We concatenate the
    regs of every included feature, in include order.
    """
    target = features.get("target.xml", "")
    includes = re.findall(r'<xi:include\s+href="([^"]+)"', target)
    # Some descriptions put regs directly in target.xml too — collect those first.
    reg_re = re.compile(r'<reg\s+name="([^"]+)"\s+bitsize="(\d+)"')
    regs = []
    regs += [(n, int(b)) for n, b in reg_re.findall(target)]
    for inc in includes:
        xml = features.get(inc, "")
        regs += [(n, int(b)) for n, b in reg_re.findall(xml)]
    if not regs:
        return None
    return RegLayout(regs)


# =============================================================================
#  Minimal GDB Remote Serial Protocol client (TCP, stdlib only)
# =============================================================================
class RSPError(RuntimeError):
    pass


class RSPClient:
    """A just-enough RSP client to single-step qemu-i386 and read its registers.

    Framing (GDB RSP):
        packet  = '$' <payload> '#' <cksum2hex>
        cksum   = (sum of payload bytes) & 0xff
        every received packet is acked with '+'  (or '-' to request resend)
    We optionally negotiate QStartNoAckMode to drop per-packet acks for speed.
    """

    def __init__(self, host="127.0.0.1", port=1234, timeout=10.0, verbose=False):
        self.timeout = timeout
        self.verbose = verbose
        self.no_ack = False
        self._buf = b""
        self.sock = self._connect_with_retry(host, port, timeout)
        self.sock.settimeout(timeout)

    # -- connection ----------------------------------------------------------
    @staticmethod
    def _connect_with_retry(host, port, timeout):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                return socket.create_connection((host, port), timeout=1.0)
            except OSError as e:
                last = e
                time.sleep(0.03)
        raise RSPError(f"could not connect to gdbstub {host}:{port}: {last}")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    # -- raw I/O -------------------------------------------------------------
    def _recv_more(self):
        try:
            chunk = self.sock.recv(8192)
        except socket.timeout:
            raise RSPError("RSP read timed out")
        if not chunk:
            raise RSPError("RSP connection closed by qemu")
        self._buf += chunk

    def _read_ack(self):
        """Consume a single leading '+'/'-' ack byte, if present."""
        while not self._buf:
            self._recv_more()
        c = self._buf[:1]
        if c in (b"+", b"-"):
            self._buf = self._buf[1:]
            return c
        return None  # no ack (NoAckMode) — payload starts immediately

    # -- packet layer --------------------------------------------------------
    @staticmethod
    def _checksum(payload: bytes) -> bytes:
        return ("%02x" % (sum(payload) & 0xff)).encode()

    def send(self, payload):
        """Send '$payload#cksum' and (unless in NoAckMode) wait for the '+' ack.

        Retries the send up to a few times if the target NAKs ('-').
        """
        if isinstance(payload, str):
            payload = payload.encode()
        frame = b"$" + payload + b"#" + self._checksum(payload)
        if self.verbose:
            sys.stderr.write(f">>> {payload!r}\n")
        for _ in range(5):
            self.sock.sendall(frame)
            if self.no_ack:
                return
            ack = self._read_ack()
            if ack == b"+":
                return
            # ack == b'-' (resend) or None — loop and retry
        raise RSPError(f"target kept NAKing packet {payload!r}")

    def recv(self) -> bytes:
        """Receive one packet payload, verify checksum, and ack it.

        Returns the payload with RSP escape ('}') decoding applied.
        """
        # Consume any pending ack first (for our just-sent packet in ack mode,
        # the ack has already been read by send(); but the stub may also send a
        # stray leading '+').
        while True:
            while b"$" not in self._buf:
                self._recv_more()
            start = self._buf.index(b"$")
            # find '#' followed by 2 checksum hex digits
            hashpos = -1
            while True:
                hashpos = self._buf.find(b"#", start + 1)
                if hashpos != -1 and len(self._buf) >= hashpos + 3:
                    break
                self._recv_more()
            payload = self._buf[start + 1:hashpos]
            cksum = self._buf[hashpos + 1:hashpos + 3]
            self._buf = self._buf[hashpos + 3:]
            # verify checksum
            if cksum != self._checksum(payload):
                if not self.no_ack:
                    self.sock.sendall(b"-")   # request retransmit
                continue
            if not self.no_ack:
                self.sock.sendall(b"+")       # ack good packet
            decoded = self._unescape(payload)
            if self.verbose:
                sys.stderr.write(f"<<< {decoded[:80]!r}\n")
            return decoded

    @staticmethod
    def _unescape(data: bytes) -> bytes:
        """RSP '}' escape: next byte XOR 0x20.  (Used in binary qXfer data.)"""
        if b"}" not in data:
            return data
        out = bytearray()
        i = 0
        while i < len(data):
            if data[i] == 0x7d and i + 1 < len(data):  # '}'
                out.append(data[i + 1] ^ 0x20)
                i += 2
            else:
                out.append(data[i])
                i += 1
        return bytes(out)

    # -- handshake -----------------------------------------------------------
    def handshake(self):
        self.send("qSupported:multiprocess+;xmlRegisters=i386;qXfer:features:read+")
        self.recv()
        # Try to drop per-packet acks for speed (optional; harmless if rejected).
        self.send("QStartNoAckMode")
        reply = self.recv()
        if reply == b"OK":
            self.no_ack = True

    # -- target description (qXfer) -----------------------------------------
    def qxfer_read(self, annex: str) -> str:
        """Read a complete qXfer:features document (handles m.../l... chunking)."""
        out = b""
        off = 0
        for _ in range(64):  # bounded chunk count
            self.send("qXfer:features:read:%s:%x,fff" % (annex, off))
            reply = self.recv()
            if not reply:
                break
            flag, data = reply[:1], reply[1:]
            out += data
            if flag == b"l":          # last chunk
                break
            if flag == b"m":          # more follow
                off += len(data)
                if not data:
                    break
            else:
                # 'E..' error or unexpected — give up on this annex
                return ""
        return out.decode("utf-8", errors="replace")

    def discover_layout(self) -> RegLayout:
        """Build the g-packet register layout from the target description.

        Follows target.xml's <xi:include> chain (i386-32bit.xml / i387 files).
        Falls back to the documented classic i386 layout if qXfer is unavailable.
        """
        target = self.qxfer_read("target.xml")
        if not target:
            sys.stderr.write("[gen_trace] qXfer target.xml unavailable; "
                             "using documented fallback i386 layout\n")
            return RegLayout(FALLBACK_LAYOUT)
        features = {"target.xml": target}
        for inc in re.findall(r'<xi:include\s+href="([^"]+)"', target):
            features[inc] = self.qxfer_read(inc)
        layout = parse_target_xml_layout(features)
        if layout is None or not layout.has("eip"):
            sys.stderr.write("[gen_trace] target.xml parse incomplete; "
                             "using documented fallback i386 layout\n")
            return RegLayout(FALLBACK_LAYOUT)
        return layout

    # -- registers / step / memory ------------------------------------------
    def read_g(self) -> bytes:
        """Read the whole register file ('g'); return the raw byte image.

        Hex fields are little-endian.  Unavailable bytes come back as the ASCII
        pair 'xx' — we substitute 0x00 for those (and the caller treats the
        register as 0, per the robustness requirement) so a partly-unknown file
        never crashes the trace.
        """
        self.send("g")
        hexstr = self.recv()
        return decode_g_hex(hexstr)

    def step(self) -> bytes:
        """Single-step one instruction; return the raw stop-reply payload.

        Prefers 'vCont;s' (reported via vContSupported) and falls back to 's'.
        """
        # 's' is universally supported by QEMU's stub and simplest; use it.
        self.send("s")
        return self.recv()

    def read_mem(self, addr: int, length: int):
        """Read `length` bytes at guest `addr` via 'm'; None on error."""
        self.send("m%x,%x" % (addr, length))
        reply = self.recv()
        if not reply or reply[:1] == b"E":
            return None
        try:
            return bytes.fromhex(reply.decode())
        except ValueError:
            return None


def decode_g_hex(hexstr: bytes) -> bytes:
    """Decode a 'g'/'p' hex reply to raw bytes, mapping 'xx' (unavailable) -> 0.

    GDB stubs may report unknown register bytes as the literal ASCII 'xx'.
    We replace any non-hex pair with '00' so int conversion stays valid; the
    affected register effectively reads as 0 (documented robustness behavior).
    """
    if len(hexstr) % 2:
        hexstr = hexstr[:-1]          # defensive: drop a dangling nibble
    out = bytearray(len(hexstr) // 2)
    for i in range(0, len(hexstr), 2):
        pair = hexstr[i:i + 2]
        try:
            out[i // 2] = int(pair, 16)
        except ValueError:
            out[i // 2] = 0           # 'xx' or junk -> 0
    return bytes(out)


# =============================================================================
#  Stop-reply parsing
# =============================================================================
class StopReply:
    """Parsed RSP stop reply.

    kind: 'stop' (T/S — stopped, still running), 'exit' (W — exited),
          'term' (X — terminated by signal), 'output' (O — console), 'other'.
    """

    def __init__(self, payload: bytes):
        self.raw = payload
        self.kind = "other"
        self.signal = None
        self.exit_code = None
        if not payload:
            return
        c = payload[:1]
        if c in (b"T", b"S"):
            self.kind = "stop"
            self.signal = _hex2(payload[1:3])
        elif c == b"W":
            self.kind = "exit"
            # W<code>[;process:pid]
            m = re.match(rb"W([0-9a-fA-F]*)", payload)
            self.exit_code = int(m.group(1), 16) if m and m.group(1) else 0
        elif c == b"X":
            self.kind = "term"
            m = re.match(rb"X([0-9a-fA-F]*)", payload)
            self.signal = int(m.group(1), 16) if m and m.group(1) else None
        elif c == b"O":
            self.kind = "output"
        elif payload == b"OK":
            self.kind = "ok"

    @property
    def running(self):
        return self.kind in ("stop", "output", "ok")


def _hex2(b: bytes) -> int:
    try:
        return int(b, 16)
    except (ValueError, TypeError):
        return 0


# =============================================================================
#  Trace generation
# =============================================================================
def regs_to_fields(layout: RegLayout, raw: bytes):
    """Slice a raw g-packet image into (eip, eflags, gpr, seg, x87) per tracefmt.

    Selectors are masked to 16 bits (they live in 32b slots in the g-packet).
    Any field absent from the layout / truncated g-packet reads as 0.
    """
    def get(name):
        v = layout.slice(raw, name)
        return 0 if v is None else v

    eip = get("eip")
    eflags = get("eflags")
    gpr = {k: get(k) for k in tracefmt.GPR_KEYS}
    seg = {k: get(k) & 0xFFFF for k in tracefmt.SEG_KEYS}

    x87 = None
    if layout.has("st0"):
        x87 = {}
        for k in tracefmt.X87_REGS:
            x87[k] = get(k)
        for k in tracefmt.X87_CTL:
            # ctl words are 16-bit fields per trace-format, stored in 32b g slots
            x87[k] = get(k) & ((1 << tracefmt._WIDTH[k]) - 1)
    return eip, eflags, gpr, seg, x87


def generate(qemu, elf, out_path, max_insn, port, extra_args,
             want_x87, stop_at, want_bytes, verbose):
    """Launch qemu under gdbstub, single-step, and write the .vtrace."""
    cmd = [qemu, "-g", str(port), "-one-insn-per-tb", elf] + list(extra_args)
    if verbose:
        sys.stderr.write("[gen_trace] launching: %s\n" % " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    rsp = None
    n_emitted = 0
    exit_info = None
    try:
        rsp = RSPClient(port=port, timeout=15.0, verbose=verbose)
        rsp.handshake()
        layout = rsp.discover_layout()
        if verbose:
            sys.stderr.write("[gen_trace] g-packet layout: %d regs, %d bytes; "
                             "x87=%s\n" % (len(layout.regs), layout.total_bytes,
                                           layout.has("st0")))

        emit_x87 = want_x87 and layout.has("st0")

        with open(out_path, "w") as f:
            note = "elf=%s qemu=-one-insn-per-tb%s" % (
                os.path.basename(elf),
                (" args=%s" % " ".join(extra_args)) if extra_args else "")
            f.write(tracefmt.dumps(
                tracefmt.header("qemu-gdbstub", "func", x87=emit_x87, note=note)) + "\n")

            # The stub halts at the entry point before executing anything.
            raw = rsp.read_g()
            # Reconcile the FP/SSE tail offsets with the real g-packet length
            # (QEMU omits some advertised sys/seg-base/CRx registers from 'g').
            layout.anchor_tail(len(raw))
            if verbose and layout._tail_delta:
                sys.stderr.write("[gen_trace] tail-anchor: g-packet %d bytes vs "
                                 "layout %d; FP tail shifted %+d (st0 @ %d)\n"
                                 % (len(raw), layout.total_bytes,
                                    layout._tail_delta,
                                    layout.offset['st0'] + layout._tail_delta))
            eip, eflags, gpr, seg, x87 = regs_to_fields(layout, raw)

            while True:
                if max_insn is not None and n_emitted >= max_insn:
                    if verbose:
                        sys.stderr.write("[gen_trace] reached --max-insn %d\n"
                                         % max_insn)
                    break
                if stop_at is not None and eip == stop_at:
                    if verbose:
                        sys.stderr.write("[gen_trace] reached --stop-at 0x%x\n"
                                         % stop_at)
                    break

                pc = eip  # fetch address of the instruction we're about to step

                # Optionally fetch raw instruction bytes (up to 15 = max x86 len).
                bytes_hex = None
                if want_bytes:
                    mem = rsp.read_mem(pc, 15)
                    if mem:
                        bytes_hex = mem.hex()

                # Execute exactly one instruction.
                stop = StopReply(rsp.step())
                if stop.kind in ("exit", "term"):
                    exit_info = stop
                    if verbose:
                        sys.stderr.write("[gen_trace] program %s (code/sig=%s) "
                                         "after %d insns\n"
                                         % (stop.kind, stop.exit_code if stop.kind
                                            == "exit" else stop.signal, n_emitted))
                    break
                if stop.kind == "output":
                    # console output mid-step — re-read the real stop reply
                    stop = StopReply(rsp.recv())
                    if stop.kind in ("exit", "term"):
                        exit_info = stop
                        break

                # Post-state of the instruction at `pc`.
                raw = rsp.read_g()
                eip, eflags, gpr, seg, x87 = regs_to_fields(layout, raw)

                # The g-packet may report SIGTRAP fields but no exit; we trust
                # the W/X reply for termination.  exc is only set if QEMU signals
                # a non-trap stop signal (e.g. SIGSEGV) — record it as a vector.
                exc = None
                rec = tracefmt.func_record(
                    n_emitted, pc, eflags, gpr, seg,
                    bytes_=bytes_hex, exc=exc,
                    x87=(x87 if emit_x87 else None))
                f.write(tracefmt.dumps(rec) + "\n")
                n_emitted += 1

        return n_emitted, exit_info
    finally:
        if rsp is not None:
            try:
                # Best-effort: tell the stub to kill the inferior, then close.
                rsp.send("k")
            except Exception:
                pass
            rsp.close()
        _terminate(proc)


def _terminate(proc):
    """Ensure the qemu child is reaped, even on error paths."""
    if proc.poll() is None:
        try:
            proc.terminate()
            for _ in range(50):
                if proc.poll() is not None:
                    break
                time.sleep(0.01)
        except Exception:
            pass
    if proc.poll() is None:
        try:
            proc.kill()
        except Exception:
            pass
    try:
        proc.wait(timeout=2)
    except Exception:
        pass


# =============================================================================
#  CLI
# =============================================================================
def main(argv=None):
    p = argparse.ArgumentParser(
        description="Ventium Producer A: QEMU gdbstub golden functional .vtrace.")
    p.add_argument("--qemu", required=True, help="path to qemu-i386 binary")
    p.add_argument("--elf", required=True, help="32-bit i386 ELF to trace")
    p.add_argument("--out", required=True, help="output .vtrace path")
    p.add_argument("--max-insn", type=int, default=None,
                   help="stop after N retired instructions (safety cap)")
    p.add_argument("--port", type=int, default=1234,
                   help="gdbstub TCP port (default 1234)")
    p.add_argument("--x87", action="store_true",
                   help="emit x87 fields (st0..st7, fctrl..fop) in records")
    p.add_argument("--stop-at", default=None,
                   help="stop when EIP reaches this address, e.g. 0x8049010")
    p.add_argument("--no-bytes", action="store_true",
                   help="do not read/emit per-instruction raw bytes")
    p.add_argument("--verbose", action="store_true", help="trace RSP I/O to stderr")
    # Everything after a literal '--args' is forwarded to the guest program.
    p.add_argument("--args", nargs=argparse.REMAINDER, default=[],
                   help="guest program arguments (must be last)")
    args = p.parse_args(argv)

    if not os.path.isfile(args.qemu):
        p.error("qemu binary not found: %s" % args.qemu)
    if not os.path.isfile(args.elf):
        p.error("elf not found: %s" % args.elf)

    stop_at = None
    if args.stop_at is not None:
        stop_at = int(args.stop_at, 0)

    n, exit_info = generate(
        qemu=args.qemu, elf=args.elf, out_path=args.out,
        max_insn=args.max_insn, port=args.port, extra_args=args.args,
        want_x87=args.x87, stop_at=stop_at, want_bytes=(not args.no_bytes),
        verbose=args.verbose)

    msg = "[gen_trace] wrote %d records to %s" % (n, args.out)
    if exit_info is not None:
        if exit_info.kind == "exit":
            msg += " (guest exited, code=%d)" % (exit_info.exit_code or 0)
        elif exit_info.kind == "term":
            msg += " (guest terminated, sig=%s)" % exit_info.signal
    sys.stderr.write(msg + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
