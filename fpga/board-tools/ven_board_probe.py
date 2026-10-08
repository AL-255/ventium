#!/usr/bin/env python3
"""Runtime probes for the RK-XCZU15EG-F Ventium image.

Run as root on the board.  The register offsets match ven_soc_dbg and the
current board_shim.cpp.  The workload and sampling modes are read-only and can
run beside ao486d without resetting or perturbing the guest. ``clock``,
``trap-*``, and the capability-gated quiescent execution-debug commands write
registers: clock switching requires ao486d to be stopped; a trap deliberately
arms the one-way forensic freeze; halt/step/breakpoint use a separate safe
instruction-boundary controller in a matching debug image.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import mmap
import os
import re
import signal
import struct
import sys
import time
import zlib
from pathlib import Path


CTRL_BASE = 0xA000_0000
CTRL_SIZE = 0x1_0000
DDR_BASE = 0x6000_0000
LOWMEM_SIZE = 0x10_0000
VGA_TEXT_BASE = 0xB8000
VGA_TEXT_SIZE = 80 * 25 * 2
IDENT_MAGIC = 0xA048_6501
FPGA_STATE_PATH = "/sys/class/fpga_manager/fpga0/state"
CRL_APB_BASE = 0xFF5E_0000
CRL_APB_SIZE = 0x1_0000
CRL_APB_PL0_REF_CTRL = 0xC0

# Values emitted by the matching Vivado PS configuration.  Keeping this an
# allow-list avoids turning the board probe into an unrestricted /dev/mem
# writer.  iopll-93m is the conservative runtime profile for the non-fast image
# routed at 95.453590 MHz; rpll-95m is retained only to reproduce the Vivado PS
# preset (stock Linux may run RPLL faster), and iopll-100m is the current flow.
PL0_CLOCK_PROFILES = {
    "rpll-95m": 0x0101_0B02,
    "iopll-93m": 0x0101_1000,
    "iopll-100m": 0x0101_0F00,
}

R_IDENT = 0x00
R_DBG2 = 0x70          # last accepted AXI AR address
R_DBG_LASTEIP = 0x80   # last retired EIP
R_DBG_FRZINFO = 0x90   # {frozen, vector, state, trace_count}
R_DBG_FRZEIP = 0xA0    # EIP latched by the forensic freeze
R_DBG_TRPC = 0xB0      # PC ring[trace index].EIP
R_DBG_TRAUX = 0xC0     # PC ring[trace index].{state[5:0], CS[15:0]}
R_DBG_CYC_LO = 0x100
R_DBG_CYC_HI = 0x110
# ven_soc_dbg counts dbg_retire_valid once per clock, not retire2_valid.
# These are primary/U retirements, NOT the architectural U+V instruction count.
R_DBG_RET_LO = 0x120
R_DBG_RET_HI = 0x130
R_DBG_IO_CYC = 0x140
R_DBG_IRQ_ACK = 0x150
R_DBG_CR0 = 0x160
R_DBG_RD_BEATS = 0x170
R_DBG_AR_HS = 0x180
R_DBG_B_HS = 0x190
# Keep these names semantic-free.  The external debug RTL currently hard-codes
# state numbers 24/23 even though feature defines move S_PIPE/S_PF (27/26 in
# the deployed profile), so labeling the slots "pipe"/"PF" would be false.
R_DBG_ST_SLOT_A = 0x1A0
R_DBG_ST_SLOT_B = 0x1B0
R_DBG_ST_TAGGED = 0x1C0
R_DBG_ST_OTHER = 0x1D0
R_DBG_RDDATA_HI = 0x30  # read-only alias; write at this offset is MGMT_WD
R_DBG_RDADDR = 0xD0
R_DBG_RDDATA = 0xE0
R_DBG_STALL = 0xF0       # cycles since clear with no primary/U retirement

# Debug-bitstream snapshot page (absent/zero on the currently deployed image).
# The capability marker prevents a legacy unused read from being reported as a
# valid all-zero CPU context.
R_DBG_SNAPSHOT_CAP = 0x200
R_DBG_SNAPSHOT_CS = 0x210
R_DBG_SNAPSHOT_EIP = 0x220
R_DBG_SNAPSHOT_ESP = 0x230
R_DBG_SNAPSHOT_EFLAGS = 0x240
R_DBG_SNAPSHOT_FAULT_PC = 0x250
R_DBG_SNAPSHOT_CR0 = 0x260
R_DBG_SNAPSHOT_STATE_VEC = 0x270
DBG_SNAPSHOT_CAP = 0x5644_0001

# Quiescent instruction-boundary debugger.  Unlike the forensic-freeze block,
# this stops issuing new instructions without resetting the SoC, so the narrow
# architectural selector is coherent while HALTED is set.  An explicit
# capability marker keeps these commands harmless on an older bitstream.
R_DBG_EXEC_CTRL = 0x280
R_DBG_BP_ADDR = 0x290
R_DBG_ARCH_SEL = 0x2A0
R_DBG_ARCH_DATA = 0x2B0
R_DBG_EXEC_CAP = 0x2C0
DBG_EXEC_CAP = 0x5645_0005
DBG_EXEC_HALT_REQ = 1 << 0
DBG_EXEC_BP_EN = 1 << 1
DBG_EXEC_HALTED = 1 << 2
DBG_EXEC_STEP = 1 << 8
DBG_EXEC_BP_CLR = 1 << 9

# Passive scan-out recorder.  Its BRAM is private to the recorder; none of
# these registers touches guest RAM, the VGA RAM ports, or execution control.
R_CAP_CTL = 0x300
R_CAP_STATUS = 0x310
R_CAP_CYCLE_LO = 0x320
R_CAP_CYCLE_HI = 0x330
R_CAP_DIMS = 0x340
R_CAP_PIXELS = 0x350
R_CAP_ADDR = 0x360
R_CAP_DATA = 0x370
CAPTURE_MAX_BYTES = 512 * 1024
CAP_STATUS_OVERRUN = 1 << 31
CAP_STATUS_ACTIVE = 1 << 30
CAP_STATUS_READY = 1 << 29
CAP_STATUS_SEQUENCE_MASK = (1 << 29) - 1

# Hosted PS/2 keyboard device.  This is a physical-device-level debug path:
# writes are serialised as Set-2 bytes on the ordinary 8042 PS/2 pins.  The
# capability word prevents a write to an older image from being mistaken for a
# supported keyboard event.
R_KBD_INJECT = 0x380
R_KBD_STATUS = 0x390
R_KBD_CAP = 0x3A0
KBD_INJECT_CAP = 0x564B_0001
KBD_STATUS_READY = 1 << 0
KBD_STATUS_BUSY = 1 << 1

# Binary stdout protocol for ``vga-capture --stream``.  Keeping frames in an
# SSH byte stream avoids filling the board's small root filesystem.  All human
# progress messages go to stderr in that mode.  Each payload is packed RGB332
# in scan order and the CRC covers only the payload bytes.
VCAP_STREAM_MAGIC = b"VENVCAP1"
VCAP_STREAM_VERSION = 1
VCAP_STREAM_HEADER = struct.Struct("<8sII")
VCAP_FRAME_HEADER = struct.Struct("<4sIQQHHII")

# Values are raw 32-bit words selected by R_DBG_ARCH_SEL.  The selector is
# only meaningful while the execution debugger reports HALTED.
ARCH_SELECTORS = (
    (0, "eax"), (1, "ecx"), (2, "edx"), (3, "ebx"),
    (4, "esp"), (5, "ebp"), (6, "esi"), (7, "edi"),
    (8, "eip"), (9, "eflags"), (10, "cs_ss"), (11, "ds_es"),
    (12, "fs_gs"), (13, "cr0"), (14, "cr2"), (15, "cr3"),
    (16, "cr4"), (17, "fctrl_fstat"), (18, "ftag_top"),
    (43, "fip"), (44, "fdp"), (45, "fcs_fds"),
    (46, "seg_base_cs"), (47, "seg_base_ss"), (48, "seg_base_ds"),
    (49, "seg_base_es"), (50, "seg_base_fs"), (51, "seg_base_gs"),
    (52, "seg_limit_cs"), (53, "seg_limit_ss"), (54, "seg_limit_ds"),
    (55, "seg_limit_es"), (56, "seg_limit_fs"), (57, "seg_limit_gs"),
    (58, "seg_attr_cs_es"), (59, "seg_attr_fs_gs_b"),
    (60, "gdt_base"), (61, "idt_base"), (62, "dt_limits"), (63, "ldt_tr_sel"),
    (64, "dr0"), (65, "dr1"), (66, "dr2"), (67, "dr3"), (68, "dr6"), (69, "dr7"),
    (70, "tr_base"), (71, "tr_limit"), (72, "tr_attr_valid"),
    (73, "ldt_base"), (74, "ldt_limit"), (75, "debug_stop_reason"),
)

# The AXI-Lite block has separate read/write decodes at these offsets.  This
# single allow-listed comparator profile freezes the PC ring on the first
# retired CS=0000, EIP=0000..0003.  cfg bits are enable, CS-care, EIP-care,
# and freeze mode (ventium_top.sv dbg_cmp_cfg[19:16]).
W_DBG_CMP_CFG = 0xA0
W_DBG_CMP_RANGE = 0xB0
W_DBG_CTL = 0x80
W_DBG_FREEZE_THRESH = 0x90
TRAP_ZERO_CFG = 0x000F_0000
TRAP_ZERO_RANGE = 0x0003_0000
TRAP_CS0_HIGH_CFG = 0x000F_0000
TRAP_CS0_HIGH_RANGE = 0xFFFF_8000
TRAP_BADCS_CFG = 0x000B_3107
TRAP_BADCS_RANGE = 0x0000_0000

# This format is intentionally conservative: it contains every field that the
# *deployed* AXI-Lite debug block can prove, plus caller-selected physical-RAM
# ranges.  It must not be called a complete CPU-state dump: the current image
# does not route the GPRs, segment descriptors, control/debug registers other
# than CR0, caches, or x87 state to AXI-Lite.  Those fields are listed in the
# manifest so an offline investigation cannot silently mistake an absent field
# for zero.
CAPTURE_FORMAT_VERSION = 1
CAPTURE_UNAVAILABLE_STATE = (
    "general-purpose registers",
    "segment bases/limits/attributes",
    "CR2/CR3/CR4 and debug registers",
    "IDTR/GDTR/LDTR/TR",
    "x87/MMX state",
    "L1 cache/TLB contents",
    "in-flight pipeline and bus transaction state",
)


def parse_range(value: str) -> tuple[int, int]:
    """Parse a physical ``START:LENGTH`` range without accepting negatives."""
    try:
        start_text, length_text = value.split(":", 1)
        start = int(start_text, 0)
        length = int(length_text, 0)
    except (TypeError, ValueError) as error:
        raise argparse.ArgumentTypeError("range must be START:LENGTH (for example 0xe0000:0x20000)") from error
    if start < 0 or length <= 0:
        raise argparse.ArgumentTypeError("range start must be non-negative and length positive")
    return start, length


def inject_keys_probe(args: argparse.Namespace) -> int:
    """Feed a bounded ASCII command through the BIOS keyboard ring.

    This is intentionally a diagnostic escape hatch for a guest that is already
    waiting in INT 16h.  It uses the same BDA layout and cache-flush edge as the
    board daemon's ``ven_inject_key`` helper; it neither resets the core nor
    alters disk contents.  A character is injected only once the guest has
    consumed the previous one, avoiding overwrite of real input.
    """
    payload = args.text.encode("ascii", "strict")
    if not payload or len(payload) > 160 or any(
        byte != 0x0D and (byte < 0x20 or byte > 0x7E) for byte in payload
    ):
        raise RuntimeError("text must be 1..160 printable ASCII characters (plus optional Enter)")

    fd, ctrl, lowmem = open_mmio(with_lowmem=True, writable=True)
    assert lowmem is not None
    try:
        # The comparator range can be armed by a concurrent forensic probe.
        # Bit 31 is an independent edge-triggered L1D flush in the deployed
        # shim, so retain every other range bit exactly as board_shim does.
        flush_base = u32(ctrl, W_DBG_CMP_RANGE) & 0x7FFF_FFFF
        flush_phase = 0x8000_0000
        # A previous invocation may have queued a BIOS key whose cached BDA
        # line was not invalidated.  Flush before checking head/tail so that
        # key can be observed and drained instead of timing out forever.
        struct.pack_into("<I", ctrl, W_DBG_CMP_RANGE, flush_base ^ flush_phase)
        for byte in payload:
            deadline = time.monotonic() + args.timeout
            while True:
                head = u16(lowmem, 0x41A)
                tail = u16(lowmem, 0x41C)
                if head == tail:
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("guest did not consume the prior injected key")
                time.sleep(0.01)
            if tail < 0x1E or tail > 0x3C:
                tail = 0x1E
            key = 0x1C0D if byte == 0x0D else byte
            struct.pack_into("<H", lowmem, 0x400 + tail, key)
            next_tail = 0x1E if tail + 2 >= 0x3E else tail + 2
            struct.pack_into("<H", lowmem, 0x41C, next_tail)
            # The guest may retain the BDA cache line indefinitely because the
            # PS write has no CPU-side snoop.  The debugger's bit-31 edge is
            # the deployed, audited L1D invalidation mechanism.
            flush_phase ^= 0x8000_0000
            struct.pack_into("<I", ctrl, W_DBG_CMP_RANGE, flush_base ^ flush_phase)
            time.sleep(args.interval)
        print(f"injected {len(payload)} BIOS key(s)")
        return 0
    finally:
        lowmem.close()
        ctrl.close()
        os.close(fd)


def queue_keys_probe(args: argparse.Namespace) -> int:
    """Queue one short command into an empty BIOS ring without polling it."""
    payload = args.text.encode("ascii", "strict")
    if not payload or len(payload) > 15 or any(
        byte != 0x0D and (byte < 0x20 or byte > 0x7E) for byte in payload
    ):
        raise RuntimeError("text must be 1..15 printable ASCII characters (plus optional Enter)")
    fd, ctrl, lowmem = open_mmio(with_lowmem=True, writable=True)
    assert lowmem is not None
    try:
        head, tail = u16(lowmem, 0x41A), u16(lowmem, 0x41C)
        if head != tail:
            raise RuntimeError("BIOS keyboard ring is not empty; refusing to overwrite queued input")
        if tail < 0x1E or tail > 0x3C:
            tail = 0x1E
        for byte in payload:
            struct.pack_into("<H", lowmem, 0x400 + tail, 0x1C0D if byte == 0x0D else byte)
            tail = 0x1E if tail + 2 >= 0x3E else tail + 2
        struct.pack_into("<H", lowmem, 0x41C, tail)
        flush_base = u32(ctrl, W_DBG_CMP_RANGE) & 0x7FFF_FFFF
        struct.pack_into("<I", ctrl, W_DBG_CMP_RANGE, flush_base ^ 0x8000_0000)
        print(f"queued {len(payload)} BIOS key(s)")
        return 0
    finally:
        lowmem.close()
        ctrl.close()
        os.close(fd)


# The platform 8042 is configured for Set-2-to-Set-1 translation, just as the
# normal ao486 simulation keyboard device is.  These values deliberately model
# real key transitions: each printable character is a make, F0 prefix, break.
SET2_ASCII = {
    **{chr(ord("a") + index): code for index, code in enumerate((
        0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B,
        0x42, 0x4B, 0x3A, 0x31, 0x44, 0x4D, 0x15, 0x2D, 0x1B, 0x2C,
        0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A,
    ))},
    **{str(index + 1): code for index, code in enumerate((
        0x16, 0x1E, 0x26, 0x25, 0x2E, 0x36, 0x3D, 0x3E, 0x46,
    ))},
    "0": 0x45, " ": 0x29, ".": 0x49, ",": 0x41, "/": 0x4A,
    "-": 0x4E, "=": 0x55, ";": 0x4C, "~": 0x0E, "`": 0x0E,
    "_": 0x4E, "\r": 0x5A,
}


def _kbd_wait_ready(ctrl: mmap.mmap, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while not (u32(ctrl, R_KBD_STATUS) & KBD_STATUS_READY):
        if time.monotonic() >= deadline:
            raise RuntimeError("hosted PS/2 keyboard did not become ready")
        time.sleep(0.001)


def _kbd_send_raw(ctrl: mmap.mmap, payload: list[int], timeout: float) -> None:
    if u32(ctrl, R_KBD_CAP) != KBD_INJECT_CAP:
        raise RuntimeError("this bitstream does not advertise the hosted PS/2 keyboard device")
    for byte in payload:
        _kbd_wait_ready(ctrl, timeout)
        struct.pack_into("<I", ctrl, R_KBD_INJECT, 0x100 | byte)
    _kbd_wait_ready(ctrl, timeout)


def ps2_keys_probe(args: argparse.Namespace) -> int:
    """Send normal make/break transitions from the hosted PS/2 device."""
    text = args.text + ("\r" if args.enter else "")
    if not text:
        raise RuntimeError("text must not be empty")
    try:
        payload = []
        for char in text:
            code = SET2_ASCII[char]
            payload.extend((code, 0xF0, code))
    except KeyError as error:
        raise RuntimeError(f"unsupported PS/2 text character: {error.args[0]!r}") from error
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        _kbd_send_raw(ctrl, payload, args.timeout)
        print(f"sent {len(text)} PS/2 key event(s), {len(payload)} Set-2 byte(s)")
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def ps2_raw_probe(args: argparse.Namespace) -> int:
    """Send bounded raw Set-2 bytes for diagnostic or non-ASCII keys."""
    payload = args.bytes
    if not payload or len(payload) > 256:
        raise RuntimeError("supply 1..256 raw Set-2 bytes")
    if any(byte < 0 or byte > 0xFF for byte in payload):
        raise RuntimeError("raw PS/2 bytes must be in 0x00..0xff")
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        _kbd_send_raw(ctrl, payload, args.timeout)
        print(f"sent {len(payload)} raw Set-2 byte(s)")
        return 0
    finally:
        ctrl.close()
        os.close(fd)


RESULT_RE = re.compile(
    rb"(?<![%0-9])(\d{1,5})\s+frames\s+([0-9]+(?:\.[0-9]+)?)\s+"
    rb"seconds\s+([0-9]+(?:\.[0-9]+)?)\s+fps",
    re.IGNORECASE,
)

# CWSDPMI formats this record only after taking a protected-mode exception.  Its
# resident binary contains the ``%08lx`` format string, so require hexadecimal
# digits in every field to avoid firing on the executable image itself.
CWSDPMI_EXCEPTION_RE = re.compile(
    rb"ebp=[0-9a-fA-F]{8} esp=[0-9a-fA-F]{8} "
    rb"cs=[0-9a-fA-F]+ ds=[0-9a-fA-F]+ es=[0-9a-fA-F]+ "
    rb"fs=[0-9a-fA-F]+ gs=[0-9a-fA-F]+ ss=[0-9a-fA-F]+ "
    rb"error=[0-9a-fA-F]{4}"
)


def map_region(fd: int, base: int, size: int, writable: bool = False) -> mmap.mmap:
    prot = mmap.PROT_READ | (mmap.PROT_WRITE if writable else 0)
    return mmap.mmap(
        fd, size, flags=mmap.MAP_SHARED, prot=prot, offset=base
    )


def u16(buf: mmap.mmap, off: int) -> int:
    return struct.unpack_from("<H", buf, off)[0]


def u32(buf: mmap.mmap, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def guest_address(raw: int) -> int:
    if DDR_BASE <= raw < DDR_BASE + 0x1000_0000:
        return raw - DDR_BASE
    return raw


def stable_u64(buf: mmap.mmap, lo_off: int, hi_off: int) -> int:
    """Read a free-running split counter without a low-word rollover tear."""
    while True:
        hi0 = u32(buf, hi_off)
        lo = u32(buf, lo_off)
        hi1 = u32(buf, hi_off)
        if hi0 == hi1:
            return (hi0 << 32) | lo


def require_fpga_operating() -> None:
    """Refuse PL MMIO unless Linux says the FPGA is configured.

    A read from an unconfigured AXI-Lite PL address is not necessarily benign:
    on this board it can leave the PS interconnect waiting forever and take the
    board off the network.  Check the manager before opening /dev/mem so the
    disk-only Quake precheck remains safe on a freshly booted board.
    """
    try:
        with open(FPGA_STATE_PATH, "r", encoding="ascii") as state_file:
            state = state_file.read().strip()
    except OSError as error:
        raise RuntimeError(f"cannot read FPGA-manager state: {error}") from error
    if state != "operating":
        raise RuntimeError(
            f"FPGA-manager state is {state!r}, refusing PL MMIO until 'operating'"
        )


def open_mmio(
    with_lowmem: bool = False, writable: bool = False
) -> tuple[int, mmap.mmap, mmap.mmap | None]:
    require_fpga_operating()
    flags = os.O_RDWR if writable else os.O_RDONLY
    fd = os.open("/dev/mem", flags | os.O_SYNC)
    ctrl = map_region(fd, CTRL_BASE, CTRL_SIZE, writable=writable)
    ident = u32(ctrl, R_IDENT)
    if ident != IDENT_MAGIC:
        raise RuntimeError(f"IDENT={ident:08x}, expected {IDENT_MAGIC:08x}")
    lowmem = (
        map_region(fd, DDR_BASE, LOWMEM_SIZE, writable=writable)
        if with_lowmem
        else None
    )
    return fd, ctrl, lowmem


def win95_probe(args: argparse.Namespace) -> int:
    fd, ctrl, lowmem = open_mmio(with_lowmem=True)
    assert lowmem is not None
    try:
        eips: collections.Counter[int] = collections.Counter()
        last_ars: collections.Counter[int] = collections.Counter()
        tick0 = u32(lowmem, 0x46C)
        ebda = u16(lowmem, 0x40E)
        ivt13 = u32(lowmem, 0x4C)
        ivt19 = u32(lowmem, 0x64)
        transitions = 0
        previous: int | None = None
        for _ in range(args.samples):
            eip = u32(ctrl, R_DBG_LASTEIP)
            last_ar = guest_address(u32(ctrl, R_DBG2))
            eips[eip] += 1
            last_ars[last_ar] += 1
            if previous is not None and eip != previous:
                transitions += 1
            previous = eip
            time.sleep(args.interval)
        tick1 = u32(lowmem, 0x46C)

        idle_hits = eips[0x1E5] + eips[0x1E6]
        vmm_hits = last_ars[0x10_21C0]
        threshold = int(args.samples * args.min_ratio)
        present = (
            idle_hits >= threshold
            and vmm_hits >= threshold
            and eips[0x1E5] > 0
            and eips[0x1E6] > 0
            and transitions >= args.min_transitions
            and tick1 != tick0
        )

        print(f"samples={args.samples} transitions={transitions}")
        print(
            "top_last_ar="
            + ", ".join(f"{k:08x}:{v}" for k, v in last_ars.most_common(8))
        )
        print(
            "top_eip="
            + ", ".join(f"{k:08x}:{v}" for k, v in eips.most_common(8))
        )
        print(
            f"lowmem EBDA_seg={ebda:04x} IVT13={ivt13:08x} "
            f"IVT19={ivt19:08x} tick={tick0:08x}->{tick1:08x}"
        )
        print("DESKTOP SIGNATURE PRESENT" if present else "DESKTOP SIGNATURE ABSENT")
        return 0 if present else 1
    finally:
        lowmem.close()
        ctrl.close()
        os.close(fd)


def vga_text_probe(args: argparse.Namespace) -> int:
    """Read the DDR backing at B8000 without changing guest or VGA state.

    This is *not* a scan-out capture.  The ao486 platform can route B8000 to
    the VGA peripheral rather than guest DDR, in which case an all-zero DDR
    aperture says nothing about the visible text screen.  Use ``vga-ring-text``
    for a sparse reconstruction from recent core-side B8000 accesses, or the
    passive VGA recorder for rendered pixels.
    """
    del args
    fd, ctrl, lowmem = open_mmio(with_lowmem=True)
    assert lowmem is not None
    try:
        page = bytes(lowmem[VGA_TEXT_BASE:VGA_TEXT_BASE + VGA_TEXT_SIZE])
        chars = page[0::2]
        attrs = page[1::2]
        printable = sum(0x20 <= value < 0x7F for value in chars)
        nonblank = sum(value not in (0x00, 0x20) for value in chars)
        nonzero_attrs = sum(value != 0 for value in attrs)
        print(
            f"vga_ddr_b8000 printable={printable}/2000 nonblank={nonblank}/2000 "
            f"nonzero_attrs={nonzero_attrs}/2000"
        )
        if not any(page):
            print(
                "DDR B8000 is all zero; on this platform this is not a blank-screen verdict. "
                "Use vga-ring-text or rendered VGA capture.",
                file=sys.stderr,
            )
        for row in range(25):
            start = row * 160
            rendered = "".join(
                chr(page[start + col * 2])
                if 0x20 <= page[start + col * 2] < 0x7F
                else " "
                for col in range(80)
            ).rstrip()
            if rendered:
                print(f"{row:02d}: {rendered}")
        return 0
    finally:
        lowmem.close()
        ctrl.close()
        os.close(fd)


def _sparse_vga_ring_lines(entries: list[dict[str, object]]) -> list[str]:
    """Render known character cells from a short core-side B8000 observation ring.

    The deployed observation ring contains a data value and no byte-enable
    metadata.  Values narrower than a dword are zero-extended, so only bytes
    through the most-significant nonzero byte can be trusted for each record.
    Processing oldest to newest makes a later observed access win.  This is a
    deliberately sparse *access reconstruction*, never a claim to be a full
    VGA text framebuffer.
    """
    chars: list[int | None] = [None] * (80 * 25)
    for entry in reversed(entries):
        address = int(str(entry["core_address"]), 16)
        data = int(str(entry["data"]), 16)
        byte_count = max(1, (data.bit_length() + 7) // 8)
        for byte_index in range(byte_count):
            byte_address = address + byte_index
            if not VGA_TEXT_BASE <= byte_address < VGA_TEXT_BASE + VGA_TEXT_SIZE:
                continue
            relative = byte_address - VGA_TEXT_BASE
            if relative & 1:
                continue
            chars[relative // 2] = (data >> (byte_index * 8)) & 0xFF

    lines: list[str] = []
    for row in range(25):
        row_cells = chars[row * 80:(row + 1) * 80]
        col = 0
        while col < 80:
            while col < 80 and row_cells[col] is None:
                col += 1
            start = col
            while col < 80 and row_cells[col] is not None:
                col += 1
            if start == col:
                continue
            rendered = "".join(
                chr(value) if 0x20 <= value < 0x7F else f"\\x{value:02x}"
                for value in row_cells[start:col]
                if value is not None
            )
            lines.append(f"{row:02d}:{start:02d}-{col - 1:02d} {rendered}")
    return lines


def vga_ring_text_probe(args: argparse.Namespace) -> int:
    """Reconstruct recently accessed B8000 character cells from the debug ring.

    Selecting ring indices is the only write.  It affects neither guest RAM nor
    execution, but a live ring is inherently incoherent; require an explicit
    acknowledgement for that useful, best-effort case.
    """
    if args.depth < 1 or args.depth > 128:
        raise RuntimeError("depth must be in 1..128")
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        info = u32(ctrl, R_DBG_FRZINFO)
        frozen = bool((info >> 31) & 1)
        if not frozen and not args.allow_live:
            raise RuntimeError("core observation ring is live; freeze it first or pass --allow-live")
        entries = read_core_observe_ring(ctrl, args.depth)
        lines = _sparse_vga_ring_lines(entries)
        print(
            "vga_ring_text source=recent-core-side-b8000-accesses "
            f"entries={len(entries)} frozen={int(frozen)} lines={len(lines)}; "
            "not a framebuffer or rendered-pixel capture"
        )
        if not lines:
            print("no character-cell bytes observed in this ring window")
        for line in lines:
            print(line)
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def _rgb332_to_rgb24(pixels: bytes) -> bytes:
    """Expand RGB332 scan-out samples to packed RGB24 without dependencies."""
    rgb = bytearray(len(pixels) * 3)
    for index, value in enumerate(pixels):
        red3 = (value >> 5) & 0x7
        green3 = (value >> 2) & 0x7
        blue2 = value & 0x3
        base = index * 3
        rgb[base] = (red3 << 5) | (red3 << 2) | (red3 >> 1)
        rgb[base + 1] = (green3 << 5) | (green3 << 2) | (green3 >> 1)
        rgb[base + 2] = (blue2 << 6) | (blue2 << 4) | (blue2 << 2) | blue2
    return bytes(rgb)


class CaptureMetadataError(RuntimeError):
    """A completed recorder image with unusable or empty raster metadata."""

    def __init__(self, sequence: int, width: int, height: int, pixels: int):
        super().__init__(
            f"invalid frozen VGA metadata seq={sequence} "
            f"{width}x{height} pixels={pixels}"
        )
        self.width = width
        self.height = height
        self.pixels = pixels


def _capture_scanout_frame(
    ctrl: mmap.mmap, *, frame_timeout: float, poll_interval: float
) -> tuple[int, int, int, int, int, bytes]:
    """Arm the passive recorder and return one self-consistent frozen image.

    This routine deliberately performs the slow AXI-Lite BRAM drain only after
    READY has frozen the recorder.  It never pauses the guest and is safe while
    ``ao486d`` continues to execute.
    """
    before = u32(ctrl, R_CAP_STATUS)
    if before & CAP_STATUS_ACTIVE:
        raise RuntimeError("VGA recorder is already active; refusing to overlap captures")
    previous_sequence = before & CAP_STATUS_SEQUENCE_MASK

    # CAP_CTL is a write-one pulse.  A prior READY image remains intact until
    # this arm is accepted, so every read above has already completed.  READY
    # is sticky between captures, so it is not itself an acknowledgement that
    # this arm reached the recorder: an AXI-Lite read immediately following the
    # W1P write could otherwise return the previous frozen image.  A completed
    # arm always advances the recorder's sequence number (wraparound would
    # require 2**29 captures), which is the unambiguous acknowledgement.
    struct.pack_into("<I", ctrl, R_CAP_CTL, 1)
    deadline = time.monotonic() + frame_timeout
    while True:
        status = u32(ctrl, R_CAP_STATUS)
        sequence = status & CAP_STATUS_SEQUENCE_MASK
        if status & CAP_STATUS_READY and sequence != previous_sequence:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(
                "VGA recorder did not finish before timeout "
                f"(status={status:08x}); this bitstream may not include capture support"
            )
        time.sleep(poll_interval)

    if status & CAP_STATUS_OVERRUN:
        raise RuntimeError("VGA recorder overflowed its private frame BRAM")
    cycle = stable_u64(ctrl, R_CAP_CYCLE_LO, R_CAP_CYCLE_HI)
    dims = u32(ctrl, R_CAP_DIMS)
    width = dims & 0xFFF
    height = (dims >> 12) & 0xFFF
    pixels = u32(ctrl, R_CAP_PIXELS) & 0xFFFFF
    if not width or not height or pixels != width * height or pixels > CAPTURE_MAX_BYTES:
        raise CaptureMetadataError(sequence, width, height, pixels)

    rounded_bytes = (pixels + 3) & ~3
    payload = bytearray(rounded_bytes)
    for word_addr in range(rounded_bytes // 4):
        struct.pack_into("<I", ctrl, R_CAP_ADDR, word_addr)
        struct.pack_into("<I", payload, word_addr * 4, u32(ctrl, R_CAP_DATA))
    return sequence, cycle, width, height, pixels, bytes(payload[:pixels])


def vga_capture_probe(args: argparse.Namespace) -> int:
    """Capture passive rendered-VGA frames without observing or changing RAM.

    ``--stream`` emits a documented binary stream on stdout so a persistent SSH
    session can archive frames directly on the host.  It is intentionally the
    preferred multi-frame mode: writing 969 raw frames locally would exhaust
    the board filesystem long before a Quake timedemo completes.

    An optional SIGUSR1 request stops only between whole records. It does not
    abort the recorder or bound an in-flight wait/drain/write. The original
    stream header still declares the requested quota, not the shorter count.
    """
    if args.frames < 1:
        raise SystemExit("--frames must be positive")
    if args.output and args.stream:
        raise SystemExit("--output and --stream are mutually exclusive")
    if args.output and args.frames != 1:
        raise SystemExit("--output is only valid with --frames 1; use --stream for a sequence")
    if args.width < 0 or args.height < 0 or bool(args.width) != bool(args.height):
        raise SystemExit("--width and --height must be supplied together, or both omitted")

    stop_requested = False

    def request_stop(_signum, _frame):
        nonlocal stop_requested
        stop_requested = True

    stop_on_sigusr1 = getattr(args, "stop_on_sigusr1", False)
    previous_handler = None
    fd = None
    ctrl = None
    try:
        if stop_on_sigusr1:
            previous_handler = signal.getsignal(signal.SIGUSR1)
            if previous_handler is None:
                raise RuntimeError("cannot restore the existing SIGUSR1 handler")
            signal.signal(signal.SIGUSR1, request_stop)
        fd, ctrl, _ = open_mmio(writable=True)
        stream = sys.stdout.buffer if args.stream else None
        if stream is not None:
            stream.write(VCAP_STREAM_HEADER.pack(VCAP_STREAM_MAGIC, VCAP_STREAM_VERSION, args.frames))
            stream.flush()

        completed = 0
        oversized_skips = 0
        startup_metadata_skips = 0
        startup_metadata_deadline = None
        empty_scanout_skips = 0
        empty_scanout_deadline = None
        while completed < args.frames:
            if stop_requested:
                break
            capture_timeout = args.frame_timeout
            if empty_scanout_deadline is not None:
                remaining = empty_scanout_deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("VGA empty scanout did not resume before timeout")
                capture_timeout = min(capture_timeout, remaining)
            try:
                sequence, cycle, width, height, pixels, payload = _capture_scanout_frame(
                    ctrl, frame_timeout=capture_timeout, poll_interval=args.poll_interval
                )
            except RuntimeError as error:
                # A READY interval with no active pixels is not an image.
                # Display blanking can occur after mode setup as well as
                # before it. Opt-in filtering may re-arm, but must not drain
                # stale BRAM, emit a fabricated black frame, or wait forever.
                if (
                    isinstance(error, CaptureMetadataError)
                    and args.skip_unmatched and args.width
                    and (error.width, error.height, error.pixels) == (0, 0, 0)
                ):
                    now = time.monotonic()
                    if empty_scanout_deadline is None:
                        empty_scanout_deadline = now + args.frame_timeout
                    if now >= empty_scanout_deadline:
                        raise RuntimeError("VGA empty scanout did not resume before timeout") from error
                    empty_scanout_skips += 1
                    if empty_scanout_skips == 1 or empty_scanout_skips % 20 == 0:
                        print(
                            f"skipping empty VGA scanout: {error} "
                            f"(count={empty_scanout_skips}); no payload emitted",
                            file=sys.stderr if stream is not None else sys.stdout,
                            flush=True,
                        )
                    time.sleep(0.25)
                    continue
                # VGA timing changes during cold firmware setup can leave a
                # nonrectangular transitional raster. Only before the FIRST
                # accepted requested-mode frame, and only with explicit
                # --skip-unmatched and dimensions, discard an out-of-mode
                # raster WITHOUT draining or emitting any of its payload.
                # Partial-zero/oversized metadata is not safe. Requested-mode
                # corruption, impossible metadata, and nonempty metadata
                # errors after requested capture starts remain fatal.
                if (
                    isinstance(error, CaptureMetadataError)
                    and args.skip_unmatched and args.width and completed == 0
                    and 0 < error.width <= 0xFFF and 0 < error.height <= 0xFFF
                    and 0 < error.pixels <= CAPTURE_MAX_BYTES
                    and (error.width != args.width or error.height != args.height)
                ):
                    now = time.monotonic()
                    if startup_metadata_deadline is None:
                        startup_metadata_deadline = now + args.frame_timeout
                    if now >= startup_metadata_deadline:
                        raise RuntimeError("VGA startup metadata did not settle before timeout") from error
                    startup_metadata_skips += 1
                    if startup_metadata_skips == 1 or startup_metadata_skips % 20 == 0:
                        print(
                            f"skipping non-requested startup VGA metadata: {error} "
                            f"(count={startup_metadata_skips}); no payload emitted",
                            file=sys.stderr if stream is not None else sys.stdout,
                            flush=True,
                        )
                    time.sleep(0.25)
                    continue
                # The recorder deliberately has only one private BRAM image.
                # Firmware text/graphics modes can exceed that capacity before
                # the guest selects its requested low-resolution mode.  The
                # frozen overrun frame is safe but cannot be emitted as a
                # complete image; with --skip-unmatched, discard just that
                # frame and re-arm at the next VSYNC instead of aborting a
                # long wait for Mode 13h.  Any other capture fault remains
                # fatal, including a timeout or an overlapping arm.
                if args.skip_unmatched and str(error) == "VGA recorder overflowed its private frame BRAM":
                    oversized_skips += 1
                    if oversized_skips == 1 or oversized_skips % 20 == 0:
                        print(
                            "skipping oversized VGA scanout frame while waiting for requested dimensions "
                            f"(count={oversized_skips})",
                            file=sys.stderr if stream is not None else sys.stdout,
                            flush=True,
                        )
                    # Do not pollute the low-rate management fabric while
                    # firmware still owns a high-resolution display mode.
                    time.sleep(0.25)
                    continue
                raise
            if args.width and (width != args.width or height != args.height):
                message = f"skipping VGA capture seq={sequence}: got {width}x{height}, need {args.width}x{args.height}"
                if args.skip_unmatched:
                    print(message, file=sys.stderr, flush=True)
                    continue
                raise RuntimeError(message)

            host_ns = time.monotonic_ns()
            empty_scanout_deadline = None  # Only a complete requested image resumes capture.
            checksum = zlib.crc32(payload) & 0xFFFF_FFFF
            if stream is not None:
                stream.write(
                    VCAP_FRAME_HEADER.pack(
                        b"VFRM", sequence, host_ns, cycle, width, height, pixels, checksum
                    )
                )
                stream.write(payload)
                stream.flush()
            elif args.output:
                rgb = _rgb332_to_rgb24(payload)
                output = Path(args.output)
                output.parent.mkdir(parents=True, exist_ok=True)
                with output.open("wb") as image:
                    image.write(f"P6\n{width} {height}\n255\n".encode("ascii"))
                    image.write(rgb)
                metadata = output.with_suffix(output.suffix + ".json")
                metadata.write_text(
                    json.dumps(
                        {
                            "format": "RGB332",
                            "sequence": sequence,
                            "fpga_cycle": cycle,
                            "host_monotonic_ns": host_ns,
                            "width": width,
                            "height": height,
                            "pixels": pixels,
                            "crc32": f"{checksum:08x}",
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )

            completed += 1
            print(
                f"VGA FRAME {completed}/{args.frames} seq={sequence} "
                f"cycle={cycle} {width}x{height} pixels={pixels} crc32={checksum:08x}",
                file=sys.stderr if stream is not None else sys.stdout,
                flush=True,
            )
        if stop_requested:
            print(
                f"VGA CAPTURE STOP reason=SIGUSR1 completed={completed} requested={args.frames}; "
                "NOT timedemo or temporal-coverage acceptance",
                file=sys.stderr,
                flush=True,
            )
        return 0
    finally:
        # CAP_CTL is an arm W1P, not an abort register. A successful capture
        # already reached READY/inactive; do not issue a cleanup MMIO write.
        try:
            if ctrl is not None:
                ctrl.close()
        finally:
            try:
                if fd is not None:
                    os.close(fd)
            finally:
                if stop_on_sigusr1 and previous_handler is not None:
                    signal.signal(signal.SIGUSR1, previous_handler)


def dump_lowmem_probe(args: argparse.Namespace) -> int:
    """Copy an explicitly bounded guest-RAM range for offline disassembly."""
    if not 0 <= args.start < LOWMEM_SIZE:
        raise SystemExit("start must lie in the first MiB of guest RAM")
    if not 0 < args.length <= 0x10000 or args.start + args.length > LOWMEM_SIZE:
        raise SystemExit("length must be 1..65536 bytes within the first MiB")
    fd, ctrl, lowmem = open_mmio(with_lowmem=True)
    assert lowmem is not None
    try:
        Path(args.output).write_bytes(bytes(lowmem[args.start:args.start + args.length]))
        print(f"wrote {args.length} bytes guest[{args.start:#x}:{args.start + args.length:#x}] to {args.output}")
    finally:
        lowmem.close()
        ctrl.close()
        os.close(fd)


def validate_guest_range(start: int, length: int, ram_size: int) -> None:
    """Reject a RAM range before creating a potentially huge /dev/mem mapping."""
    if ram_size <= 0 or ram_size > 0x4000_0000:
        raise RuntimeError("ram-size must be in 1..0x40000000 bytes")
    if start < 0 or length <= 0 or start + length > ram_size:
        raise RuntimeError(
            f"guest range {start:#x}:{start + length:#x} is outside 0:{ram_size:#x}"
        )


def file_fingerprint(path_text: str, include_hash: bool) -> dict[str, object]:
    """Record immutable replay inputs without failing a valuable capture.

    A mounted sparse VHD can be sizable, so hashing is opt-in.  Size and mtime
    are still enough to flag an obvious wrong input; a requested hash is
    streamed rather than read all at once.
    """
    path = Path(path_text)
    answer: dict[str, object] = {"path": path_text}
    try:
        status = path.stat()
    except OSError as error:
        answer["stat_error"] = str(error)
        return answer
    answer.update({"size": status.st_size, "mtime_ns": status.st_mtime_ns})
    if include_hash:
        digest = hashlib.sha256()
        try:
            with path.open("rb") as source:
                while block := source.read(1 << 20):
                    digest.update(block)
        except OSError as error:
            answer["sha256_error"] = str(error)
        else:
            answer["sha256"] = digest.hexdigest()
    return answer


def debug_state(ctrl: mmap.mmap) -> dict[str, object]:
    """Read all deployed, non-ring debug CSRs into a JSON-safe structure.

    The counters are split registers and remain stable once a forensic freeze
    is asserted.  ``stable_u64`` also makes this routine useful for a live,
    explicitly requested status capture without fabricating torn counter data.
    """
    info = u32(ctrl, R_DBG_FRZINFO)
    freeze: dict[str, object] = {
        "raw": f"{info:08x}",
        "frozen": bool((info >> 31) & 1),
        "debug_spare": (info >> 24) & 0x7F,
        "int_vector_or_halt_tag": (info >> 16) & 0xFF,
        "core_state": (info >> 8) & 0x3F,
        # The current AXI wrapper exposes only count[5:0] although the
        # physical ring has 128 entries.  Zero is consequently ambiguous
        # (empty, 64, or 128) and must not be used to truncate a dump.
        "trace_count_low6_ambiguous": info & 0x3F,
        "freeze_eip_legacy": f"{u32(ctrl, R_DBG_FRZEIP):08x}",
    }
    snapshot_cap = u32(ctrl, R_DBG_SNAPSHOT_CAP)
    if snapshot_cap == DBG_SNAPSHOT_CAP:
        state_vec = u32(ctrl, R_DBG_SNAPSHOT_STATE_VEC)
        freeze["snapshot"] = {
            "format": snapshot_cap & 0xFFFF,
            "cs": f"{u32(ctrl, R_DBG_SNAPSHOT_CS) & 0xFFFF:04x}",
            "eip": f"{u32(ctrl, R_DBG_SNAPSHOT_EIP):08x}",
            "esp": f"{u32(ctrl, R_DBG_SNAPSHOT_ESP):08x}",
            "eflags": f"{u32(ctrl, R_DBG_SNAPSHOT_EFLAGS):08x}",
            "fault_pc": f"{u32(ctrl, R_DBG_SNAPSHOT_FAULT_PC):08x}",
            "cr0": f"{u32(ctrl, R_DBG_SNAPSHOT_CR0):08x}",
            "core_state": (state_vec >> 10) & 0x3F,
            "int_vector_or_halt_tag": state_vec & 0xFF,
        }
    else:
        freeze["snapshot"] = {"available": False, "capability_read": f"{snapshot_cap:08x}"}
    exec_cap = u32(ctrl, R_DBG_EXEC_CAP)
    if exec_cap == DBG_EXEC_CAP:
        exec_ctrl = u32(ctrl, R_DBG_EXEC_CTRL)
        execution: dict[str, object] = {
            "available": True,
            "format": exec_cap & 0xFFFF,
            "raw": f"{exec_ctrl:08x}",
            # ABI 5 reads back only HALT_REQ/BP_EN/HALTED (bits 0..2).
            # STEP is a write pulse, not a readable execution-history bit.
            "step_command_readback_available": False,
            "halt_requested": bool(exec_ctrl & DBG_EXEC_HALT_REQ),
            "breakpoint_enabled": bool(exec_ctrl & DBG_EXEC_BP_EN),
            "halted": bool(exec_ctrl & DBG_EXEC_HALTED),
            "breakpoint_eip": f"{u32(ctrl, R_DBG_BP_ADDR):08x}",
            "arch_selector": u32(ctrl, R_DBG_ARCH_SEL) & 0x7F,
        }
    else:
        execution = {"available": False, "capability_read": f"{exec_cap:08x}"}
    return {
        "ident": f"{u32(ctrl, R_IDENT):08x}",
        "freeze": freeze,
        "execution": execution,
        "last_retired_eip": f"{u32(ctrl, R_DBG_LASTEIP):08x}",
        "last_axi_ar_raw": f"{u32(ctrl, R_DBG2):08x}",
        "core_cr0": f"{u32(ctrl, R_DBG_CR0):08x}",
        "counters": {
            "retirement_counter_kind": "primary_U_not_total_UV",
            "cycles": stable_u64(ctrl, R_DBG_CYC_LO, R_DBG_CYC_HI),
            "retirements": stable_u64(ctrl, R_DBG_RET_LO, R_DBG_RET_HI),
            "io_cycles": u32(ctrl, R_DBG_IO_CYC),
            "irq_acknowledges": u32(ctrl, R_DBG_IRQ_ACK),
            "ddr_read_beats": u32(ctrl, R_DBG_RD_BEATS),
            "axi_ar_handshakes": u32(ctrl, R_DBG_AR_HS),
            "axi_b_handshakes": u32(ctrl, R_DBG_B_HS),
            "state_slot_a": u32(ctrl, R_DBG_ST_SLOT_A),
            "state_slot_b": u32(ctrl, R_DBG_ST_SLOT_B),
            "state_tagged": u32(ctrl, R_DBG_ST_TAGGED),
            "state_other": u32(ctrl, R_DBG_ST_OTHER),
        },
    }


def require_exec_debug(ctrl: mmap.mmap) -> None:
    """Reject execution-control writes on images that do not advertise them."""
    capability = u32(ctrl, R_DBG_EXEC_CAP)
    if capability != DBG_EXEC_CAP:
        raise RuntimeError(
            "quiescent execution debugger is unavailable "
            f"(capability read {capability:08x}; deploy the debug image first)"
        )


def execution_ctrl(ctrl: mmap.mmap) -> int:
    require_exec_debug(ctrl)
    return u32(ctrl, R_DBG_EXEC_CTRL)


def wait_execution_halted(ctrl: mmap.mmap, expected: bool, timeout: float) -> int:
    """Wait for the core's quiescent slow/fast instruction-boundary park."""
    deadline = time.monotonic() + timeout
    while True:
        ctrl_word = execution_ctrl(ctrl)
        if bool(ctrl_word & DBG_EXEC_HALTED) == expected:
            return ctrl_word
        if time.monotonic() >= deadline:
            action = "park" if expected else "resume"
            raise RuntimeError(f"timeout waiting for the core to {action}; exec_ctrl={ctrl_word:08x}")
        time.sleep(0.001)


def read_halted_arch_state(ctrl: mmap.mmap) -> dict[str, object]:
    """Read the compact architectural mux after a verified boundary halt.

    The x87 stack is returned as physical fpu_top slots together with TOP and
    tags.  Reporting both physical and logical ST(i) views makes stale slots
    visible without pretending an empty physical register has a valid value.
    """
    ctrl_word = execution_ctrl(ctrl)
    if not (ctrl_word & DBG_EXEC_HALTED):
        raise RuntimeError("core is not halted at an instruction boundary; run halt or breakpoint first")
    raw: dict[str, int] = {}
    for selector, name in ARCH_SELECTORS:
        struct.pack_into("<I", ctrl, R_DBG_ARCH_SEL, selector)
        raw[name] = u32(ctrl, R_DBG_ARCH_DATA)
    result: dict[str, object] = {
        name: f"{value:08x}" for name, value in raw.items()
    }
    result["cs"] = f"{raw['cs_ss'] & 0xFFFF:04x}"
    result["ss"] = f"{raw['cs_ss'] >> 16:04x}"
    result["ds"] = f"{raw['ds_es'] & 0xFFFF:04x}"
    result["es"] = f"{raw['ds_es'] >> 16:04x}"
    result["fs"] = f"{raw['fs_gs'] & 0xFFFF:04x}"
    result["gs"] = f"{raw['fs_gs'] >> 16:04x}"
    result["fctrl"] = f"{raw['fctrl_fstat'] & 0xFFFF:04x}"
    result["fstat"] = f"{raw['fctrl_fstat'] >> 16:04x}"
    result["ftag"] = f"{raw['ftag_top'] & 0xFF:02x}"
    ftop = (raw["ftag_top"] >> 8) & 0x7
    result["ftop"] = ftop
    result["fcs"] = f"{raw['fcs_fds'] & 0xFFFF:04x}"
    result["fds"] = f"{raw['fcs_fds'] >> 16:04x}"
    physical: list[dict[str, object]] = []
    logical: list[dict[str, object]] = []
    ftag = raw["ftag_top"] & 0xFF
    for phys in range(8):
        base = 19 + phys * 3
        struct.pack_into("<I", ctrl, R_DBG_ARCH_SEL, base)
        lo = u32(ctrl, R_DBG_ARCH_DATA)
        struct.pack_into("<I", ctrl, R_DBG_ARCH_SEL, base + 1)
        mid = u32(ctrl, R_DBG_ARCH_DATA)
        struct.pack_into("<I", ctrl, R_DBG_ARCH_SEL, base + 2)
        hi = u32(ctrl, R_DBG_ARCH_DATA) & 0xFFFF
        value = (hi << 64) | (mid << 32) | lo
        physical.append({
            "physical": phys,
            "empty": bool(ftag & (1 << phys)),
            "floatx80": f"{value:020x}",
        })
    for st_index in range(8):
        phys = (ftop + st_index) & 7
        logical.append({
            "st": st_index,
            "physical": phys,
            "empty": bool(ftag & (1 << phys)),
            "floatx80": physical[phys]["floatx80"],
        })
    result["x87_physical"] = physical
    result["x87_logical"] = logical
    segment_names = ("cs", "ss", "ds", "es", "fs", "gs")
    attrs_lo = raw["seg_attr_cs_es"]
    attrs_hi_b = raw["seg_attr_fs_gs_b"]
    segments: dict[str, object] = {}
    for index, name in enumerate(segment_names):
        attr = (attrs_lo >> (index * 8)) & 0xFF if index < 4 else (attrs_hi_b >> ((index - 4) * 8)) & 0xFF
        segments[name] = {
            "selector": result[name],
            "base": f"{raw[f'seg_base_{name}']:08x}",
            "limit": f"{raw[f'seg_limit_{name}']:08x}",
            "attr": f"{attr:02x}",
            "b": bool((attrs_hi_b >> (16 + index)) & 1),
        }
    result["segments"] = segments
    result["gdt_base"] = f"{raw['gdt_base']:08x}"
    result["idt_base"] = f"{raw['idt_base']:08x}"
    result["gdt_limit"] = f"{raw['dt_limits'] & 0xFFFF:04x}"
    result["idt_limit"] = f"{raw['dt_limits'] >> 16:04x}"
    result["ldt_selector"] = f"{raw['ldt_tr_sel'] & 0xFFFF:04x}"
    result["tr_selector"] = f"{raw['ldt_tr_sel'] >> 16:04x}"
    result["ldt_limit"] = f"{raw['ldt_limit'] & 0xFFFF:04x}"
    result["tr_valid"] = bool((raw["tr_attr_valid"] >> 8) & 1)
    result["tr_attr"] = f"{raw['tr_attr_valid'] & 0xFF:02x}"
    stop_reasons = {0: "none", 1: "manual-halt", 2: "breakpoint", 3: "single-step"}
    result["stop_reason"] = stop_reasons.get(raw["debug_stop_reason"] & 0x3, "reserved")
    result["scope"] = (
        "integer GPRs, debug registers, selectors, hidden segment cache, CR0..CR4, descriptor-table bases/limits, LDTR/TR hidden caches, complete x87 stack plus environment pointers, and debugger stop cause; "
        "not caches/TLBs or in-flight state"
    )
    return result


def prepare_cold_probe(args: argparse.Namespace) -> int:
    """Disarm a freshly programmed, still-reset ABI-5 image before daemon init.

    Never programs the FPGA, writes guest RAM, changes clocks, asserts reset,
    clears evidence counters, steps, or releases execution. The caller must
    separately pin the bitstream and qualify its compiled UV-fast profile.
    """
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        require_exec_debug(ctrl)

        def cold_state():
            state = debug_state(ctrl)
            if (u32(ctrl, R_IDENT) != IDENT_MAGIC or u32(ctrl, 0x20) != 1 or
                    state['counters']['retirements'] != 0 or
                    state['freeze']['frozen'] or state['core_cr0'] != '60000010'):
                raise RuntimeError('cold preparation requires unexecuted, held-reset, non-frozen reset state')
            return state

        before = cold_state()  # Complete admission before the first write.
        # Preserve the held reset. The daemon may later initialize RAM/devices
        # and release reset, but execution stays parked until a separate RUN.
        struct.pack_into('<I', ctrl, R_DBG_EXEC_CTRL, DBG_EXEC_HALT_REQ | DBG_EXEC_BP_CLR)
        struct.pack_into('<I', ctrl, W_DBG_CMP_CFG, 0)
        struct.pack_into('<I', ctrl, W_DBG_FREEZE_THRESH, 0)
        after = cold_state()
        if not after['execution']['halt_requested'] or after['execution']['breakpoint_enabled']:
            raise RuntimeError('cold preparation did not leave manual halt with breakpoint disabled')
        print(json.dumps(dict(action='prepare-cold-abi5', before=before, after=after,
                              guest_held_reset=True, guest_released=False, acceptance=False,
                              gameplay_ipc=None), sort_keys=True))
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def halt_probe(args: argparse.Namespace) -> int:
    """Request a safe instruction-boundary halt; the guest is not reset."""
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        require_exec_debug(ctrl)
        # A manual halt disables and clears a stale breakpoint latch; a later
        # breakpoint command owns its own enable/clear sequence.
        struct.pack_into("<I", ctrl, R_DBG_EXEC_CTRL, DBG_EXEC_HALT_REQ | DBG_EXEC_BP_CLR)
        state = wait_execution_halted(ctrl, True, args.timeout)
        print(f"HALT OK exec_ctrl={state:08x}")
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def run_probe(args: argparse.Namespace) -> int:
    """Resume a quiescent halt and clear any sticky breakpoint latch."""
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        require_exec_debug(ctrl)
        struct.pack_into("<I", ctrl, R_DBG_EXEC_CTRL, DBG_EXEC_BP_CLR)
        state = wait_execution_halted(ctrl, False, args.timeout)
        print(f"RUN OK exec_ctrl={state:08x}")
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def step_probe(args: argparse.Namespace) -> int:
    """Execute exactly one retired instruction per requested step from a safe halt."""
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        require_exec_debug(ctrl)
        if args.count < 1:
            raise RuntimeError("--count must be at least one")
        if not (execution_ctrl(ctrl) & DBG_EXEC_HALTED):
            raise RuntimeError("core is not halted; issue halt or wait for a breakpoint before step")
        for number in range(args.count):
            before = stable_u64(ctrl, R_DBG_RET_LO, R_DBG_RET_HI)
            struct.pack_into("<I", ctrl, R_DBG_EXEC_CTRL, DBG_EXEC_HALT_REQ | DBG_EXEC_STEP)
            deadline = time.monotonic() + args.timeout
            while True:
                after = stable_u64(ctrl, R_DBG_RET_LO, R_DBG_RET_HI)
                halted = bool(execution_ctrl(ctrl) & DBG_EXEC_HALTED)
                if after == before + 1 and halted:
                    print(f"STEP {number + 1}/{args.count} retired={after}")
                    break
                if after > before + 1:
                    raise RuntimeError(
                        f"step retired {after - before} instructions, expected exactly one; leaving core halted"
                    )
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"timeout waiting for step {number + 1}/{args.count}; retired delta={after - before} halted={int(halted)}"
                    )
                time.sleep(0.001)
        print(json.dumps(read_halted_arch_state(ctrl), sort_keys=True))
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def breakpoint_probe(args: argparse.Namespace) -> int:
    """Arm a pre-issue EIP breakpoint and optionally wait for the safe park."""
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        require_exec_debug(ctrl)
        struct.pack_into("<I", ctrl, R_DBG_BP_ADDR, args.eip)
        # Drop a prior manual halt and clear a prior latched breakpoint in the
        # same edge before enabling the requested target.
        struct.pack_into("<I", ctrl, R_DBG_EXEC_CTRL, DBG_EXEC_BP_EN | DBG_EXEC_BP_CLR)
        if args.wait:
            state = wait_execution_halted(ctrl, True, args.timeout)
            print(f"BREAKPOINT HIT eip={args.eip:08x} exec_ctrl={state:08x}")
            print(json.dumps(read_halted_arch_state(ctrl), sort_keys=True))
        else:
            print(f"BREAKPOINT ARMED eip={args.eip:08x}")
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def dump_state_probe(args: argparse.Namespace) -> int:
    """Dump the selector-based architectural state at a verified safe halt."""
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        require_exec_debug(ctrl)
        if args.halt:
            struct.pack_into("<I", ctrl, R_DBG_EXEC_CTRL, DBG_EXEC_HALT_REQ)
            wait_execution_halted(ctrl, True, args.timeout)
        result = {
            "debug_state": debug_state(ctrl),
            "architectural_state": read_halted_arch_state(ctrl),
        }
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def read_pc_ring(ctrl: mmap.mmap, depth: int) -> list[dict[str, object]]:
    """Copy a ring after BRAM latency, then restore selector zero/newest."""
    entries: list[dict[str, object]] = []
    try:
        for index in range(depth):
            struct.pack_into("<I", ctrl, W_DBG_CTL, index)
            _ = u32(ctrl, R_DBG_TRPC)  # prime the synchronous BRAM read port
            eip = u32(ctrl, R_DBG_TRPC)
            aux = u32(ctrl, R_DBG_TRAUX)
            cs = aux & 0xFFFF
            entries.append(
                {
                    "newest_offset": index,
                    "cs": f"{cs:04x}",
                    "eip": f"{eip:08x}",
                    "core_state": (aux >> 16) & 0x3F,
                    "real_mode_linear_if_applicable": f"{(cs << 4) + eip:08x}",
                }
            )
    finally:
        # ``sample`` is intentionally a read-only newest-entry probe.  Indexed
        # diagnostics must leave that convention intact even on an exception.
        struct.pack_into("<I", ctrl, W_DBG_CTL, 0)
    return entries


def read_core_observe_ring(ctrl: mmap.mmap, depth: int) -> list[dict[str, object]]:
    """Copy the existing core/L1 observation ring, newest entry first.

    The hardware names this the historical ``rd`` ring, but the deployed
    wiring is a core-side observation tap, not a generic AXI read trace.  Its
    upper word encodes current FSM state and retire/INTA samples, which makes
    it especially useful beside the architectural PC ring at a freeze.
    """
    entries: list[dict[str, object]] = []
    try:
        for index in range(depth):
            struct.pack_into("<I", ctrl, W_DBG_CTL, index)
            _ = u32(ctrl, R_DBG_RDADDR)  # prime the synchronous BRAM read port
            address = u32(ctrl, R_DBG_RDADDR)
            data = u32(ctrl, R_DBG_RDDATA)
            aux = u32(ctrl, R_DBG_RDDATA_HI)
            entries.append(
                {
                    "newest_offset": index,
                    "core_address": f"{address:08x}",
                    "data": f"{data:08x}",
                    "core_state": (aux >> 2) & 0x3F,
                    "retire_valid": bool((aux >> 1) & 1),
                    "inta": bool(aux & 1),
                    "raw_aux": f"{aux:08x}",
                }
            )
    finally:
        struct.pack_into("<I", ctrl, W_DBG_CTL, 0)
    return entries


def dump_ram_probe(args: argparse.Namespace) -> int:
    """Copy any bounded physical guest-RAM range, including protected-mode RAM.

    Unlike ``dump-lowmem`` this deliberately permits the caller to capture the
    high physical pages selected by DPMI page tables.  It is read-only; the
    output file is created only after the range has been checked.
    """
    validate_guest_range(args.start, args.length, args.ram_size)
    fd, ctrl, _ = open_mmio()
    guest = map_region(fd, DDR_BASE, args.ram_size)
    try:
        Path(args.output).write_bytes(bytes(guest[args.start:args.start + args.length]))
        print(
            f"wrote {args.length} bytes guest[{args.start:#x}:{args.start + args.length:#x}] "
            f"to {args.output} sha256={hashlib.sha256(guest[args.start:args.start + args.length]).hexdigest()}"
        )
        return 0
    finally:
        guest.close()
        ctrl.close()
        os.close(fd)


def capture_probe(args: argparse.Namespace) -> int:
    """Create a coherent forensic bundle from a frozen FPGA execution.

    A running CPU can change the PC ring, counters and RAM between reads, so a
    capture refuses live state unless the operator explicitly overrides that
    safety check.  ``--range`` can be supplied repeatedly; ``--full-ram`` is
    a deliberate opt-in because board root filesystems are often small.
    """
    ranges = list(args.range)
    if args.full_ram:
        if ranges:
            raise RuntimeError("--full-ram and --range cannot be combined")
        ranges = [(0, args.ram_size)]
    for start, length in ranges:
        validate_guest_range(start, length, args.ram_size)
    total_bytes = sum(length for _start, length in ranges)
    destination = Path(args.output)
    if destination.exists():
        raise RuntimeError(f"refusing to overwrite existing capture path {destination}")
    parent = destination.parent
    if not parent.is_dir():
        raise RuntimeError(f"capture parent does not exist: {parent}")
    free_bytes = os.statvfs(parent).f_bavail * os.statvfs(parent).f_frsize
    if total_bytes + 1_048_576 > free_bytes:
        raise RuntimeError(
            f"capture needs at least {total_bytes + 1_048_576} free bytes; only {free_bytes} available"
        )

    fd, ctrl, _ = open_mmio(writable=True)
    guest: mmap.mmap | None = None
    try:
        state = debug_state(ctrl)
        frozen = bool(state["freeze"]["frozen"])
        if not frozen and not args.allow_live:
            raise RuntimeError("refusing incoherent live capture; freeze it first or pass --allow-live")
        depth = min(args.depth, 128)
        if depth < 1:
            raise RuntimeError("depth must be in 1..128")
        ring = read_pc_ring(ctrl, depth)
        core_observe_ring = read_core_observe_ring(ctrl, depth)

        destination.mkdir()
        manifest: dict[str, object] = {
            "format": "ventium-fpga-forensic-capture",
            "version": CAPTURE_FORMAT_VERSION,
            "captured_unix_ns": time.time_ns(),
            "coherent_freeze": frozen,
            "debug_state": state,
            "pc_ring_newest_first": ring,
            "core_observe_ring_newest_first": core_observe_ring,
            "unavailable_in_deployed_bitstream": list(CAPTURE_UNAVAILABLE_STATE),
            "ram_size": args.ram_size,
            "ram_ranges": [],
            "operator_inputs": {
                "disk": file_fingerprint(args.disk, args.hash_inputs),
                "bitstream": file_fingerprint(args.bitstream, args.hash_inputs),
            },
        }
        if ranges:
            guest = map_region(fd, DDR_BASE, args.ram_size)
            for number, (start, length) in enumerate(ranges):
                filename = f"ram_{number:02d}_{start:08x}_{length:08x}.bin"
                payload = bytes(guest[start:start + length])
                (destination / filename).write_bytes(payload)
                manifest["ram_ranges"].append(
                    {
                        "start": f"{start:08x}",
                        "length": length,
                        "file": filename,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                    }
                )
        (destination / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(
            f"CAPTURE OK path={destination} frozen={int(frozen)} ring={depth} "
            f"ram_bytes={total_bytes}; copy the directory off-board before re-running"
        )
        return 0
    except Exception:
        # A partial capture must never be mistaken for a usable one.  Do not
        # remove it automatically: the user may need it to understand a disk
        # full or I/O error, but mark it unambiguously for inspection.
        if destination.is_dir():
            (destination / "INCOMPLETE").write_text("capture did not complete\n", encoding="ascii")
        raise
    finally:
        if guest is not None:
            guest.close()
        ctrl.close()
        os.close(fd)


def sample_probe(args: argparse.Namespace) -> int:
    """Sample the live newest PC-ring entry without changing its index."""
    fd, ctrl, _ = open_mmio()
    try:
        previous: tuple[int, int, int] | None = None
        for _ in range(args.samples):
            # ao486d leaves the trace index at zero after its startup clear, so
            # these are read-only accesses to the newest retired ring entry.
            trace_eip = u32(ctrl, R_DBG_TRPC)
            aux = u32(ctrl, R_DBG_TRAUX)
            cs = aux & 0xFFFF
            state = (aux >> 16) & 0x3F
            current = (cs, trace_eip, state)
            if current != previous or args.all:
                print(
                    f"cs:eip={cs:04x}:{trace_eip:08x} state={state} "
                    f"lastEIP={u32(ctrl, R_DBG_LASTEIP):08x} "
                    f"last_ar_guest={guest_address(u32(ctrl, R_DBG2)):08x}",
                    flush=True,
                )
                previous = current
            time.sleep(args.interval)
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def perf_probe(args: argparse.Namespace) -> int:
    """Measure raw primary/U counter deltas, not qualified gameplay or U+V IPC."""
    if not 0 < args.seconds <= 3600:
        raise ValueError("--seconds must be positive and at most 3600")
    fd, ctrl, _ = open_mmio()
    try:
        cyc0 = stable_u64(ctrl, R_DBG_CYC_LO, R_DBG_CYC_HI)
        ret0 = stable_u64(ctrl, R_DBG_RET_LO, R_DBG_RET_HI)
        io0 = u32(ctrl, R_DBG_IO_CYC)
        stall0 = u32(ctrl, R_DBG_STALL)
        irq0 = u32(ctrl, R_DBG_IRQ_ACK)
        rd0 = u32(ctrl, R_DBG_RD_BEATS)
        ar0 = u32(ctrl, R_DBG_AR_HS)
        b0 = u32(ctrl, R_DBG_B_HS)
        slot_a0 = u32(ctrl, R_DBG_ST_SLOT_A)
        slot_b0 = u32(ctrl, R_DBG_ST_SLOT_B)
        other0 = u32(ctrl, R_DBG_ST_OTHER)
        started = time.monotonic()
        time.sleep(args.seconds)
        elapsed = time.monotonic() - started
        cyc1 = stable_u64(ctrl, R_DBG_CYC_LO, R_DBG_CYC_HI)
        ret1 = stable_u64(ctrl, R_DBG_RET_LO, R_DBG_RET_HI)
        io1 = u32(ctrl, R_DBG_IO_CYC)
        stall1 = u32(ctrl, R_DBG_STALL)
        irq1 = u32(ctrl, R_DBG_IRQ_ACK)
        rd1 = u32(ctrl, R_DBG_RD_BEATS)
        ar1 = u32(ctrl, R_DBG_AR_HS)
        b1 = u32(ctrl, R_DBG_B_HS)
        slot_a1 = u32(ctrl, R_DBG_ST_SLOT_A)
        slot_b1 = u32(ctrl, R_DBG_ST_SLOT_B)
        other1 = u32(ctrl, R_DBG_ST_OTHER)

        # A 64-bit wrap takes millennia at the supported core frequencies.
        # Treat a backwards interval as reset/clear, never near-2**64 work.
        if cyc1 < cyc0 or ret1 < ret0:
            raise RuntimeError("counter reset/clear during sample; interval is invalid")
        dcyc = cyc1 - cyc0
        dret = ret1 - ret0
        dio = (io1 - io0) & 0xFFFF_FFFF
        dstall = (stall1 - stall0) & 0xFFFF_FFFF
        dirq = (irq1 - irq0) & 0xFFFF_FFFF
        drd = (rd1 - rd0) & 0xFFFF_FFFF
        dar = (ar1 - ar0) & 0xFFFF_FFFF
        db = (b1 - b0) & 0xFFFF_FFFF
        dslot_a = (slot_a1 - slot_a0) & 0xFFFF_FFFF
        dslot_b = (slot_b1 - slot_b0) & 0xFFFF_FFFF
        dother = (other1 - other0) & 0xFFFF_FFFF
        ipc = dret / dcyc if dcyc else 0.0
        cpi = dcyc / dret if dret else float("inf")
        mhz = dcyc / elapsed / 1_000_000.0 if elapsed else 0.0
        io_ratio = dio / dcyc if dcyc else 0.0
        stall_ratio = dstall / dcyc if dcyc else 0.0
        print(
            f"elapsed={elapsed:.6f}s cycles={dcyc} primary_u_retired={dret} "
            f"clock={mhz:.6f}MHz primary_u_ipc={ipc:.6f} cycles_per_u_retirement={cpi:.3f} "
            f"no_retire={dstall} no_retire_ratio={stall_ratio:.6f} "
            f"io_cycles={dio} io_ratio={io_ratio:.6f} irq_ack={dirq}"
        )
        print("counter_kind=primary_U_not_total_UV total_uv_ipc=unavailable "
              "gameplay_qualified=false")
        print(
            f"raw cycles={cyc0}->{cyc1} primary_u_retired={ret0}->{ret1} "
            f"io={io0:08x}->{io1:08x} irq={irq0:08x}->{irq1:08x}"
        )
        print(
            f"axi rd_beats={drd} ar_hs={dar} b_hs={db} "
            f"slot_1a0={dslot_a} slot_1b0={dslot_b} "
            f"fsm_other={dother} "
            f"tagged_raw={u32(ctrl, R_DBG_ST_TAGGED):08x} "
            f"cr0={u32(ctrl, R_DBG_CR0):08x}"
        )
        if args.axi_read_profiler:
            # The matching profiler image defines 0x1A0 as total AR..RLAST
            # occupancy and 0x1B0 as AR..first-R latency.  Do not infer these
            # meanings from a legacy image: this opt-in is intentionally explicit.
            interbeat = dslot_a - dslot_b - (drd - dar)
            if dar and interbeat >= 0:
                print(
                    f"axi-read-profiler txns={dar} beats={drd} "
                    f"busy_cycles={dslot_a} first_wait_cycles={dslot_b} "
                    f"interbeat_gap_cycles={interbeat} "
                    f"avg_busy={dslot_a / dar:.3f} "
                    f"avg_first_wait={dslot_b / dar:.3f} "
                    f"avg_interbeat_gap={interbeat / dar:.3f}"
                )
            else:
                print(
                    "axi-read-profiler unavailable/inconsistent interval: "
                    f"txns={dar} beats={drd} busy={dslot_a} first={dslot_b}"
                )
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def clock_probe(args: argparse.Namespace) -> int:
    """Select one of the audited PS PL0 clock configurations.

    This deliberately does not touch the Ventium AXI-Lite control block.  The
    caller must stop ao486d first so the core is reset after any clock-source
    switching transient.
    """
    value = PL0_CLOCK_PROFILES[args.profile]
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    crl = map_region(fd, CRL_APB_BASE, CRL_APB_SIZE, writable=True)
    try:
        previous = u32(crl, CRL_APB_PL0_REF_CTRL)
        struct.pack_into("<I", crl, CRL_APB_PL0_REF_CTRL, value)
        # A readback orders the device write and supplies a positive witness.
        current = u32(crl, CRL_APB_PL0_REF_CTRL)
        if current != value:
            raise RuntimeError(
                f"PL0_REF_CTRL readback={current:08x}, expected {value:08x}"
            )
        print(
            f"PL0 clock profile={args.profile} "
            f"PL0_REF_CTRL={previous:08x}->{current:08x}"
        )
        return 0
    finally:
        crl.close()
        os.close(fd)


def arm_trap(cfg: int, eip_range: int, label: str) -> int:
    """Arm one fixed forensic comparator profile.

    Range is written before enable so an instruction cannot match a stale
    range.  The IDENT read orders the device writes.  A match intentionally
    freezes the on-chip trace ring and holds the guest in reset; this command
    is therefore diagnostic, never an acceptance-run probe.
    """
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        struct.pack_into("<I", ctrl, W_DBG_CMP_RANGE, eip_range)
        struct.pack_into("<I", ctrl, W_DBG_CMP_CFG, cfg)
        ident = u32(ctrl, R_IDENT)
        if ident != IDENT_MAGIC:
            raise RuntimeError(f"IDENT={ident:08x} after comparator arm")
        print(f"{label} TRAP ARMED cfg={cfg:08x} range={eip_range:08x}")
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def trap_zero_probe(args: argparse.Namespace) -> int:
    """Freeze on the first retired CS=0000, EIP=0000..0003."""
    del args
    return arm_trap(TRAP_ZERO_CFG, TRAP_ZERO_RANGE, "ZERO-RETIRE")


def trap_badcs_probe(args: argparse.Namespace) -> int:
    """Freeze on the first retired CS=3107 boot-derail signature."""
    del args
    return arm_trap(TRAP_BADCS_CFG, TRAP_BADCS_RANGE, "BAD-CS-3107")


def trap_cs0_high_probe(args: argparse.Namespace) -> int:
    """Freeze on a CS=0000 retire in EIP 8000h..FFFFh."""
    del args
    return arm_trap(TRAP_CS0_HIGH_CFG, TRAP_CS0_HIGH_RANGE, "CS0-HIGH-EIP")


def trap_status_probe(args: argparse.Namespace) -> int:
    """Report the forensic freeze latch without changing the guest."""
    del args
    fd, ctrl, _ = open_mmio()
    try:
        info = u32(ctrl, R_DBG_FRZINFO)
        frozen = (info >> 31) & 1
        vector = (info >> 16) & 0xFF
        state = (info >> 8) & 0x3F
        count = info & 0x3F
        print(
            f"trap frozen={frozen} frz_eip={u32(ctrl, R_DBG_FRZEIP):08x} "
            f"last_eip={u32(ctrl, R_DBG_LASTEIP):08x} state={state} "
            f"vector={vector:02x} count={count}"
        )
        return 0 if frozen else 1
    finally:
        ctrl.close()
        os.close(fd)


def trap_wide_eip_probe(args: argparse.Namespace) -> int:
    """Freeze the hardware rings when a live real-mode EIP exceeds 16 bits.

    The deployed comparator only compares ``dbg_eip[15:0]``.  This PS-side
    trigger watches the full last-retired EIP and asserts the existing
    one-cycle external-freeze control as soon as it becomes impossible for the
    16-bit BIOS/DOS phase.  It is a diagnostic trigger; it does not reset or
    patch guest state.
    """
    fd, ctrl, _ = open_mmio(writable=True)
    started = time.monotonic()
    try:
        while True:
            eip = u32(ctrl, R_DBG_LASTEIP)
            if eip >= args.minimum:
                struct.pack_into("<I", ctrl, W_DBG_CTL, 1 << 16)
                ident = u32(ctrl, R_IDENT)  # order the device write
                if ident != IDENT_MAGIC:
                    raise RuntimeError(f"IDENT={ident:08x} after external freeze")
                time.sleep(0.002)
                info = u32(ctrl, R_DBG_FRZINFO)
                print(
                    f"WIDE-EIP TRAP FIRED observed={eip:08x} "
                    f"frozen={(info >> 31) & 1} "
                    f"frz_eip={u32(ctrl, R_DBG_FRZEIP):08x} "
                    f"last_eip={u32(ctrl, R_DBG_LASTEIP):08x}",
                    flush=True,
                )
                return 0
            if args.timeout and time.monotonic() - started >= args.timeout:
                print("WIDE-EIP TRAP NOT FIRED (timeout)", flush=True)
                return 1
            if args.interval:
                time.sleep(args.interval)
    finally:
        ctrl.close()
        os.close(fd)


def trap_unexpected_cs_probe(args: argparse.Namespace) -> int:
    """Freeze when the newest retire uses a CS outside an audited boot set."""
    allowed = {int(value, 0) & 0xFFFF for value in args.allow.split(",")}
    fd, ctrl, _ = open_mmio(writable=True)
    started = time.monotonic()
    try:
        if args.delay:
            time.sleep(args.delay)
        while True:
            eip = u32(ctrl, R_DBG_TRPC)
            aux = u32(ctrl, R_DBG_TRAUX)
            cs = aux & 0xFFFF
            if cs not in allowed:
                struct.pack_into("<I", ctrl, W_DBG_CTL, 1 << 16)
                ident = u32(ctrl, R_IDENT)
                if ident != IDENT_MAGIC:
                    raise RuntimeError(f"IDENT={ident:08x} after external freeze")
                time.sleep(0.002)
                info = u32(ctrl, R_DBG_FRZINFO)
                print(
                    f"UNEXPECTED-CS TRAP FIRED cs:eip={cs:04x}:{eip:08x} "
                    f"allowed={','.join(f'{value:04x}' for value in sorted(allowed))} "
                    f"frozen={(info >> 31) & 1} "
                    f"frz_eip={u32(ctrl, R_DBG_FRZEIP):08x}",
                    flush=True,
                )
                return 0
            if args.timeout and time.monotonic() - started >= args.timeout:
                print("UNEXPECTED-CS TRAP NOT FIRED (timeout)", flush=True)
                return 1
            if args.interval:
                time.sleep(args.interval)
    finally:
        ctrl.close()
        os.close(fd)


def trap_protected_exit_probe(args: argparse.Namespace) -> int:
    """Freeze at the first CS outside a protected-workload selector set.

    Unlike ``trap-unexpected-cs``, this trigger is stateful: it ignores the
    complete BIOS/DOS startup and does not arm until one of the requested
    protected-mode entry selectors has retired.  It is intended for failures
    where a DPMI client silently returns to DOS without formatting an exception
    record.  The first out-of-set retire then pulses the existing external
    freeze, preserving the boundary in the on-chip PC ring.
    """
    entries = {int(value, 0) & 0xFFFF for value in args.enter.split(",")}
    allowed = {int(value, 0) & 0xFFFF for value in args.allow.split(",")}
    if not entries:
        raise RuntimeError("protected-exit entry-selector set is empty")
    if not entries <= allowed:
        raise RuntimeError("every protected-exit entry selector must be allowed")

    fd, ctrl, _ = open_mmio(writable=True)
    started = time.monotonic()
    armed = False
    observed_exits = 0
    try:
        if args.delay:
            time.sleep(args.delay)
        while True:
            eip = u32(ctrl, R_DBG_TRPC)
            aux = u32(ctrl, R_DBG_TRAUX)
            cs = aux & 0xFFFF
            cr0 = u32(ctrl, R_DBG_CR0)
            if (not armed and cs in entries and eip >= args.enter_eip_min
                    and (not args.require_pe or (cr0 & 1))):
                armed = True
                print(
                    f"PROTECTED-EXIT TRAP ARMED cs:eip={cs:04x}:{eip:08x} "
                    f"cr0={cr0:08x} "
                    f"allowed={','.join(f'{value:04x}' for value in sorted(allowed))}",
                    flush=True,
                )
            elif armed and (cs not in allowed or (args.require_pe and not (cr0 & 1))):
                observed_exits += 1
                if observed_exits <= args.skip_exits:
                    print(
                        f"PROTECTED-EXIT OBSERVED ({observed_exits}/{args.skip_exits}) "
                        f"cs:eip={cs:04x}:{eip:08x} cr0={cr0:08x}; rearming",
                        flush=True,
                    )
                    armed = False
                    continue
                struct.pack_into("<I", ctrl, W_DBG_CTL, 1 << 16)
                ident = u32(ctrl, R_IDENT)
                if ident != IDENT_MAGIC:
                    raise RuntimeError(f"IDENT={ident:08x} after external freeze")
                time.sleep(0.002)
                info = u32(ctrl, R_DBG_FRZINFO)
                print(
                    f"PROTECTED-EXIT TRAP FIRED cs:eip={cs:04x}:{eip:08x} "
                    f"cr0={cr0:08x} "
                    f"frozen={(info >> 31) & 1} "
                    f"frz_eip={u32(ctrl, R_DBG_FRZEIP):08x}",
                    flush=True,
                )
                return 0
            if args.timeout and time.monotonic() - started >= args.timeout:
                phase = "armed" if armed else "waiting-for-entry"
                print(f"PROTECTED-EXIT TRAP NOT FIRED ({phase}, timeout)", flush=True)
                return 1
            if args.interval:
                time.sleep(args.interval)
    finally:
        ctrl.close()
        os.close(fd)


def trap_pe_exit_probe(args: argparse.Namespace) -> int:
    """Freeze on CR0.PE 1->0 after an optional qualified PM epoch."""
    fd, ctrl, _ = open_mmio(writable=True)
    started = time.monotonic()
    armed = False
    observed_exits = 0
    try:
        if args.delay:
            time.sleep(args.delay)
        while True:
            cr0 = u32(ctrl, R_DBG_CR0)
            eip = u32(ctrl, R_DBG_TRPC)
            aux = u32(ctrl, R_DBG_TRAUX)
            cs = aux & 0xFFFF
            # A DOS extender legitimately enters and leaves protected mode many
            # times before its client runs.  ``--arm-cs`` makes the trigger a
            # client-qualified one: do not freeze on one of those expected host
            # round trips; arm only after the requested protected-mode CS has
            # actually retired.  The freeze still occurs only on PE -> 0.
            if not armed and (cr0 & 1) and (args.arm_cs is None or cs == args.arm_cs):
                armed = True
                print(
                    f"PE-EXIT TRAP ARMED cs:eip={cs:04x}:{eip:08x} cr0={cr0:08x}",
                    flush=True,
                )
            elif armed and not (cr0 & 1):
                observed_exits += 1
                if observed_exits <= args.skip_exits:
                    print(
                        f"PE-EXIT OBSERVED ({observed_exits}/{args.skip_exits}) "
                        f"cs:eip={cs:04x}:{eip:08x} cr0={cr0:08x}; rearming",
                        flush=True,
                    )
                    armed = False
                    continue
                struct.pack_into("<I", ctrl, W_DBG_CTL, 1 << 16)
                ident = u32(ctrl, R_IDENT)
                if ident != IDENT_MAGIC:
                    raise RuntimeError(f"IDENT={ident:08x} after external freeze")
                time.sleep(0.002)
                info = u32(ctrl, R_DBG_FRZINFO)
                print(
                    f"PE-EXIT TRAP FIRED cs:eip={cs:04x}:{eip:08x} "
                    f"cr0={cr0:08x} frozen={(info >> 31) & 1} "
                    f"frz_eip={u32(ctrl, R_DBG_FRZEIP):08x}",
                    flush=True,
                )
                return 0
            if args.timeout and time.monotonic() - started >= args.timeout:
                phase = "armed" if armed else "waiting-for-PE"
                print(f"PE-EXIT TRAP NOT FIRED ({phase}, timeout)", flush=True)
                return 1
            if args.interval:
                time.sleep(args.interval)
    finally:
        ctrl.close()
        os.close(fd)


def trap_linear_data_probe(args: argparse.Namespace) -> int:
    """Freeze after a sustained even-stride sequential retire stream.

    The observed invalid IRET lands in word-oriented data and then retires a
    long +2-byte stream.  By default, gate on a live BIOS tick so VGA/POST
    initialization cannot trigger this heuristic before interrupts are
    established; focused test ROMs can disable that gate explicitly.
    """
    fd, ctrl, lowmem = open_mmio(with_lowmem=True, writable=True)
    assert lowmem is not None
    started = time.monotonic()
    previous: tuple[int, int] | None = None
    streak = 0
    try:
        while True:
            if args.no_tick_gate or u32(lowmem, 0x46C) != 0:
                eip = u32(ctrl, R_DBG_LASTEIP)
                aux = u32(ctrl, R_DBG_TRAUX)
                cs = aux & 0xFFFF
                current = (cs, eip)
                if previous is not None and current != previous:
                    delta = eip - previous[1]
                    if (
                        cs == previous[0]
                        and 0 < delta <= args.max_delta
                        and (delta & 1) == 0
                    ):
                        streak += 1
                    else:
                        streak = 0
                    if streak >= args.streak:
                        struct.pack_into("<I", ctrl, W_DBG_CTL, 1 << 16)
                        ident = u32(ctrl, R_IDENT)
                        if ident != IDENT_MAGIC:
                            raise RuntimeError(
                                f"IDENT={ident:08x} after external freeze"
                            )
                        time.sleep(0.002)
                        info = u32(ctrl, R_DBG_FRZINFO)
                        print(
                            f"LINEAR-DATA TRAP FIRED cs:eip={cs:04x}:{eip:08x} "
                            f"streak={streak} max_delta={args.max_delta} "
                            f"frozen={(info >> 31) & 1} "
                            f"frz_eip={u32(ctrl, R_DBG_FRZEIP):08x}",
                            flush=True,
                        )
                        return 0
                previous = current
            if args.timeout and time.monotonic() - started >= args.timeout:
                print("LINEAR-DATA TRAP NOT FIRED (timeout)", flush=True)
                return 1
            if args.interval:
                time.sleep(args.interval)
    finally:
        lowmem.close()
        ctrl.close()
        os.close(fd)


def trap_cwsdpmi_exception_probe(args: argparse.Namespace) -> int:
    """Freeze the forensic rings when CWSDPMI formats an exception record.

    The scan is read-only.  Only after a fully substituted register record is
    present does the probe pulse the existing external-freeze control.  A PL
    reload alone does not necessarily clear DDR, so the monitor first requires
    an absent-record sample; this prevents a prior capture from immediately
    retriggering before ``ao486d`` has zeroed and loaded the new guest.  This is
    intentionally a diagnostic trigger: the matching RTL holds the guest in
    reset once the trace is frozen.
    """
    if not 0 <= args.start < args.end <= LOWMEM_SIZE:
        raise RuntimeError(
            f"invalid low-memory scan range {args.start:#x}..{args.end:#x}"
        )
    fd, ctrl, lowmem = open_mmio(with_lowmem=True, writable=True)
    assert lowmem is not None
    started = time.monotonic()
    saw_clear = False
    try:
        while True:
            window = bytes(lowmem[args.start:args.end])
            match = CWSDPMI_EXCEPTION_RE.search(window)
            if match is None:
                saw_clear = True
            elif saw_clear:
                observed = args.start + match.start()
                record = match.group(0).decode("ascii")
                struct.pack_into("<I", ctrl, W_DBG_CTL, 1 << 16)
                ident = u32(ctrl, R_IDENT)  # order the device write
                if ident != IDENT_MAGIC:
                    raise RuntimeError(f"IDENT={ident:08x} after external freeze")
                time.sleep(0.002)
                info = u32(ctrl, R_DBG_FRZINFO)
                print(
                    f"CWSDPMI EXCEPTION TRAP FIRED lowmem={observed:05x} "
                    f"record={record!r} frozen={(info >> 31) & 1} "
                    f"vector={(info >> 16) & 0xff:02x} "
                    f"state={(info >> 8) & 0x3f} "
                    f"frz_eip={u32(ctrl, R_DBG_FRZEIP):08x} "
                    f"last_eip={u32(ctrl, R_DBG_LASTEIP):08x}",
                    flush=True,
                )
                return 0
            if args.timeout and time.monotonic() - started >= args.timeout:
                print("CWSDPMI EXCEPTION TRAP NOT FIRED (timeout)", flush=True)
                return 1
            if args.interval:
                time.sleep(args.interval)
    finally:
        lowmem.close()
        ctrl.close()
        os.close(fd)


def dump_ring_probe(args: argparse.Namespace) -> int:
    """Dump the frozen PC ring, newest entry first."""
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        info = u32(ctrl, R_DBG_FRZINFO)
        frozen = (info >> 31) & 1
        count = info & 0x3F
        if not frozen and not args.allow_live:
            raise RuntimeError("PC ring is live; freeze it first or pass --allow-live")
        print(
            f"PC-RING frozen={frozen} frz_eip={u32(ctrl, R_DBG_FRZEIP):08x} "
            f"last_eip={u32(ctrl, R_DBG_LASTEIP):08x} count={count}"
        )
        for entry in read_pc_ring(ctrl, args.depth):
            print(
                f"[{entry['newest_offset']:3d}] cs={entry['cs']} eip={entry['eip']} "
                f"state={entry['core_state']:02d} "
                f"lin={entry['real_mode_linear_if_applicable']}"
            )
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def dump_core_observe_ring_probe(args: argparse.Namespace) -> int:
    """Dump the frozen core/L1 observation ring paired with the PC ring."""
    fd, ctrl, _ = open_mmio(writable=True)
    try:
        info = u32(ctrl, R_DBG_FRZINFO)
        frozen = (info >> 31) & 1
        if not frozen and not args.allow_live:
            raise RuntimeError("core observation ring is live; freeze it first or pass --allow-live")
        if args.depth < 1 or args.depth > 128:
            raise RuntimeError("depth must be in 1..128")
        for entry in read_core_observe_ring(ctrl, args.depth):
            print(
                f"[{entry['newest_offset']:3d}] core_addr={entry['core_address']} "
                f"data={entry['data']} state={entry['core_state']:02d} "
                f"retire={int(entry['retire_valid'])} inta={int(entry['inta'])} "
                f"aux={entry['raw_aux']}"
            )
        return 0
    finally:
        ctrl.close()
        os.close(fd)


def disk_results(path: str) -> list[tuple[int, str, str]]:
    with open(path, "rb", buffering=0) as disk:
        data = disk.read()
    found: list[tuple[int, str, str]] = []
    for match in RESULT_RE.finditer(data):
        found.append(
            (
                int(match.group(1)),
                match.group(2).decode("ascii"),
                match.group(3).decode("ascii"),
            )
        )
    return found


def quake_probe(args: argparse.Namespace) -> int:
    initial = disk_results(args.disk)
    if initial and not args.allow_existing:
        print(f"refusing pre-existing result(s): {initial}", file=sys.stderr)
        return 2
    if args.precheck_only:
        if initial:
            print(f"pre-existing result(s) allowed: {initial}")
        else:
            print("QUAKE DISK PRECHECK CLEAN: no timedemo result present")
        return 0

    fd, ctrl, _ = open_mmio()
    started = time.monotonic()
    last_progress: tuple[int, int] | None = None
    try:
        while True:
            results = disk_results(args.disk)
            for frames, seconds, fps in results:
                line = f"{frames} frames {seconds} seconds {fps} fps"
                print(line, flush=True)
                if frames == args.frames:
                    print("QUAKE TIMEDEMO COMPLETE", flush=True)
                    return 0

            eip = u32(ctrl, R_DBG_LASTEIP)
            last_ar = guest_address(u32(ctrl, R_DBG2))
            progress = (eip, last_ar)
            if progress != last_progress:
                elapsed = time.monotonic() - started
                print(
                    f"elapsed={elapsed:.0f}s lastEIP={eip:08x} "
                    f"last_ar_guest={last_ar:08x}",
                    flush=True,
                )
                last_progress = progress
            if args.timeout and time.monotonic() - started >= args.timeout:
                print("QUAKE TIMEDEMO NOT COMPLETE (timeout)", flush=True)
                return 1
            time.sleep(args.interval)
    finally:
        ctrl.close()
        os.close(fd)


def quake_progress_probe(args: argparse.Namespace) -> int:
    """Read Quake's own frame counters through its live 32-bit page tables."""

    fd, ctrl, _ = open_mmio()
    guest = map_region(fd, DDR_BASE, args.ram_size)

    def linear_u32(linear: int) -> tuple[int, int]:
        pde_addr = (args.cr3 & 0xFFFFF000) + ((linear >> 22) & 0x3FF) * 4
        if pde_addr + 4 > args.ram_size:
            raise RuntimeError(f"PDE address {pde_addr:08x} is outside mapped guest RAM")
        pde = u32(guest, pde_addr)
        if not pde & 1:
            raise RuntimeError(f"linear {linear:08x} has non-present PDE {pde:08x}")
        if pde & 0x80:
            physical = (pde & 0xFFC00000) | (linear & 0x003FFFFF)
        else:
            pte_addr = (pde & 0xFFFFF000) + ((linear >> 12) & 0x3FF) * 4
            if pte_addr + 4 > args.ram_size:
                raise RuntimeError(
                    f"PTE address {pte_addr:08x} is outside mapped guest RAM"
                )
            pte = u32(guest, pte_addr)
            if not pte & 1:
                raise RuntimeError(
                    f"linear {linear:08x} has non-present PTE {pte:08x}"
                )
            physical = (pte & 0xFFFFF000) | (linear & 0xFFF)
        if physical + 4 > args.ram_size:
            raise RuntimeError(
                f"linear {linear:08x} maps outside guest window at {physical:08x}"
            )
        return u32(guest, physical), physical

    try:
        for sample_index in range(args.samples):
            # ``td_startframe == 0`` is a valid timedemo start: the automatic
            # command line can enter demo playback before Quake's first host
            # frame.  The former truthiness test silently hid that case and
            # reported zero progress throughout a healthy run.  Use the two
            # playback fields as the validity witness instead; they are the
            # same conditions used by the board tick-assist path.
            demo_active, _ = linear_u32(args.ds_base + 0x6C980)
            demo_file, _ = linear_u32(args.ds_base + 0x6C988)
            frame_count, frame_phys = linear_u32(args.ds_base + 0x95BB4)
            start_frame, start_phys = linear_u32(args.ds_base + 0x6C990)
            demo_frames = (
                frame_count - start_frame - 1
                if demo_active and demo_file and frame_count > start_frame
                else 0
            )
            print(
                f"demo_active={int(bool(demo_active and demo_file))} "
                f"host_framecount={frame_count} td_startframe={start_frame} "
                f"demo_frames={demo_frames} "
                f"phys={frame_phys:08x}/{start_phys:08x} "
                f"lastEIP={u32(ctrl, R_DBG_LASTEIP):08x}",
                flush=True,
            )
            if sample_index + 1 < args.samples:
                time.sleep(args.interval)
        return 0
    finally:
        guest.close()
        ctrl.close()
        os.close(fd)


def linear_peek_probe(args: argparse.Namespace) -> int:
    """Read a small guest-linear window through the supplied live page tables.

    This is deliberately read-only.  It is intended for forensic guest patches
    which leave a compact record in normal mapped memory; unlike a raw DDR
    dump, it reports the physical page actually selected by the DPMI mapping.
    """

    if args.words < 1 or args.words > 64:
        raise RuntimeError("words must be in 1..64")
    fd, _ctrl, _ = open_mmio()
    guest = map_region(fd, DDR_BASE, args.ram_size)

    def linear_phys(linear: int) -> int:
        pde_addr = (args.cr3 & 0xFFFFF000) + ((linear >> 22) & 0x3FF) * 4
        if pde_addr + 4 > args.ram_size:
            raise RuntimeError(f"PDE address {pde_addr:08x} is outside mapped guest RAM")
        pde = u32(guest, pde_addr)
        if not pde & 1:
            raise RuntimeError(f"linear {linear:08x} has non-present PDE {pde:08x}")
        if pde & 0x80:
            physical = (pde & 0xFFC00000) | (linear & 0x003FFFFF)
        else:
            pte_addr = (pde & 0xFFFFF000) + ((linear >> 12) & 0x3FF) * 4
            if pte_addr + 4 > args.ram_size:
                raise RuntimeError(f"PTE address {pte_addr:08x} is outside mapped guest RAM")
            pte = u32(guest, pte_addr)
            if not pte & 1:
                raise RuntimeError(f"linear {linear:08x} has non-present PTE {pte:08x}")
            physical = (pte & 0xFFFFF000) | (linear & 0xFFF)
        if physical + 4 > args.ram_size:
            raise RuntimeError(f"linear {linear:08x} maps outside guest RAM at {physical:08x}")
        return physical

    try:
        for index in range(args.words):
            linear = args.linear + 4 * index
            physical = linear_phys(linear)
            print(f"linear={linear:08x} phys={physical:08x} value={u32(guest, physical):08x}")
        return 0
    finally:
        guest.close()
        os.close(fd)


def quake_marker_probe(args: argparse.Namespace) -> int:
    """Wait for the binary-only Quake completion witness in its live data page.

    The marker workload writes the expected value immediately before its
    existing timedemo-result ``Con_Printf``.  The client page tables do not
    exist during DOS/CWSDPMI startup, so an absent mapping is an ordinary
    in-progress condition rather than a probe error.
    """

    fd, ctrl, _ = open_mmio()
    guest = map_region(fd, DDR_BASE, args.ram_size)

    def linear_u32(linear: int) -> tuple[int, int]:
        pde_addr = (args.cr3 & 0xFFFFF000) + ((linear >> 22) & 0x3FF) * 4
        if pde_addr + 4 > args.ram_size:
            raise RuntimeError("PDE outside guest RAM")
        pde = u32(guest, pde_addr)
        if not pde & 1:
            raise RuntimeError("PDE absent")
        if pde & 0x80:
            physical = (pde & 0xFFC00000) | (linear & 0x003FFFFF)
        else:
            pte_addr = (pde & 0xFFFFF000) + ((linear >> 12) & 0x3FF) * 4
            if pte_addr + 4 > args.ram_size:
                raise RuntimeError("PTE outside guest RAM")
            pte = u32(guest, pte_addr)
            if not pte & 1:
                raise RuntimeError("PTE absent")
            physical = (pte & 0xFFFFF000) | (linear & 0xFFF)
        if physical + 4 > args.ram_size:
            raise RuntimeError("marker maps outside guest RAM")
        return u32(guest, physical), physical

    started = time.monotonic()
    try:
        while True:
            try:
                value, physical = linear_u32(args.ds_base + args.offset)
                if value == args.expected:
                    print(
                        f"QUAKE COMPLETION MARKER {value} (969 frames path) "
                        f"phys={physical:08x} lastEIP={u32(ctrl, R_DBG_LASTEIP):08x}",
                        flush=True,
                    )
                    return 0
            except RuntimeError:
                pass
            if args.timeout and time.monotonic() - started >= args.timeout:
                print("QUAKE COMPLETION MARKER NOT OBSERVED (timeout)", flush=True)
                return 1
            time.sleep(args.interval)
    finally:
        guest.close()
        ctrl.close()
        os.close(fd)


def trap_quake_fault_frame_probe(args: argparse.Namespace) -> int:
    """Freeze after the diagnostic Quake image writes its exception frame.

    ``QUAKE_FAULT_FRAME_LOGGER.EXE`` stores the protected-mode exception frame
    in a deliberately unused client-data slot before it resumes GO32's normal
    reporting path.  This host-side trigger walks the live client page tables
    and uses the existing external-freeze bit only after a complete, non-zero
    record is present.  It never writes guest RAM or alters the RTL.
    """
    if args.words < 1 or args.words > 32:
        raise RuntimeError("words must be in 1..32")
    if args.offset & 3:
        raise RuntimeError("offset must be dword aligned")
    if (args.offset & 0xFFF) + args.words * 4 > 0x1000:
        raise RuntimeError("fault-frame record must fit within one page")

    fd, ctrl, _ = open_mmio(writable=True)
    guest = map_region(fd, DDR_BASE, args.ram_size)

    def linear_phys(linear: int) -> int:
        pde_addr = (args.cr3 & 0xFFFFF000) + ((linear >> 22) & 0x3FF) * 4
        if pde_addr + 4 > args.ram_size:
            raise RuntimeError("PDE outside guest RAM")
        pde = u32(guest, pde_addr)
        if not pde & 1:
            raise RuntimeError("PDE absent")
        if pde & 0x80:
            physical = (pde & 0xFFC00000) | (linear & 0x003FFFFF)
        else:
            pte_addr = (pde & 0xFFFFF000) + ((linear >> 12) & 0x3FF) * 4
            if pte_addr + 4 > args.ram_size:
                raise RuntimeError("PTE outside guest RAM")
            pte = u32(guest, pte_addr)
            if not pte & 1:
                raise RuntimeError("PTE absent")
            physical = (pte & 0xFFFFF000) | (linear & 0xFFF)
        if physical + args.words * 4 > args.ram_size:
            raise RuntimeError("fault frame maps outside guest RAM")
        return physical

    linear = args.ds_base + args.offset
    started = time.monotonic()
    try:
        while True:
            try:
                physical = linear_phys(linear)
                words = [u32(guest, physical + 4 * index) for index in range(args.words)]
                # A client store can still be resident in the L1 when an
                # external freeze takes effect.  The raw DDR copy above is
                # therefore intentionally not the sole witness: the existing
                # core-observation ring records the core-side store address
                # and data before cache writeback.  Polling that ring closes
                # the otherwise fatal cache-visibility gap in this diagnostic
                # path without changing guest memory or RTL.
                core_entries = read_core_observe_ring(ctrl, 128)
                logger_stores = [
                    entry
                    for entry in core_entries
                    if physical
                    <= int(str(entry["core_address"]), 16)
                    < physical + args.words * 4
                ]
                if any(words) or logger_stores:
                    struct.pack_into("<I", ctrl, W_DBG_CTL, 1 << 16)
                    ident = u32(ctrl, R_IDENT)  # order the device write
                    if ident != IDENT_MAGIC:
                        raise RuntimeError(f"IDENT={ident:08x} after external freeze")
                    time.sleep(0.002)
                    info = u32(ctrl, R_DBG_FRZINFO)
                    print(
                        "QUAKE FAULT-FRAME TRAP FIRED "
                        f"linear={linear:08x} phys={physical:08x} "
                        f"source={'ddr' if any(words) else 'core-ring'} "
                        f"frozen={(info >> 31) & 1} "
                        f"vector={(info >> 16) & 0xff:02x} "
                        f"state={(info >> 8) & 0x3f} "
                        f"frz_eip={u32(ctrl, R_DBG_FRZEIP):08x} "
                        f"last_eip={u32(ctrl, R_DBG_LASTEIP):08x} "
                        "words=" + ",".join(f"{word:08x}" for word in words) + " "
                        "ring=" + ",".join(
                            f"{entry['core_address']}:{entry['data']}"
                            for entry in logger_stores
                        ),
                        flush=True,
                    )
                    return 0
            except RuntimeError:
                pass
            if args.timeout and time.monotonic() - started >= args.timeout:
                print("QUAKE FAULT-FRAME TRAP NOT FIRED (timeout)", flush=True)
                return 1
            if args.interval:
                time.sleep(args.interval)
    finally:
        guest.close()
        ctrl.close()
        os.close(fd)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)

    w95 = sub.add_parser("win95", help="sample the known Win95 desktop-idle signature")
    w95.add_argument("--samples", type=int, default=1500)
    w95.add_argument("--interval", type=float, default=0.01)
    w95.add_argument("--min-ratio", type=float, default=0.90)
    w95.add_argument("--min-transitions", type=int, default=10)
    w95.set_defaults(func=win95_probe)

    vga_text = sub.add_parser(
        "vga-text", help="read-only inspection of the DDR B8000 aperture (not rendered VGA)"
    )
    vga_text.set_defaults(func=vga_text_probe)

    vga_ring_text = sub.add_parser(
        "vga-ring-text",
        help="best-effort recent B8000 character reconstruction from the core observation ring",
    )
    vga_ring_text.add_argument("--depth", type=int, default=128)
    vga_ring_text.add_argument("--allow-live", action="store_true")
    vga_ring_text.set_defaults(func=vga_ring_text_probe)

    vga_capture = sub.add_parser(
        "vga-capture",
        help="passively record frozen RGB332 scan-out frames (no guest-memory or execution access)",
    )
    vga_capture.add_argument("--frames", type=int, default=1)
    vga_capture.add_argument(
        "--stop-on-sigusr1",
        action="store_true",
        help="finish any in-flight frame, then stop between records on SIGUSR1 (no recorder abort)",
    )
    vga_capture.add_argument("--width", type=int, default=0, help="require this captured width")
    vga_capture.add_argument("--height", type=int, default=0, help="require this captured height")
    vga_capture.add_argument(
        "--skip-unmatched",
        action="store_true",
        help="discard oversized or mismatched frames while waiting for --width/--height graphics mode",
    )
    vga_capture.add_argument(
        "--frame-timeout", type=float, default=30.0,
        help="maximum seconds to wait for each scan-out frame (default: 30)",
    )
    vga_capture.add_argument(
        "--poll-interval", type=float, default=0.002,
        help="status-poll delay in seconds while waiting for a frame (default: 0.002)",
    )
    vga_capture.add_argument(
        "--stream",
        action="store_true",
        help="write VENVCAP1 binary frames to stdout; progress stays on stderr",
    )
    vga_capture.add_argument(
        "--output",
        help="write one expanded PPM frame and JSON metadata on the board (only with --frames 1)",
    )
    vga_capture.set_defaults(func=vga_capture_probe)

    dump_lowmem = sub.add_parser(
        "dump-lowmem",
        help="read-only bounded first-MiB guest-RAM dump for offline analysis",
    )
    dump_lowmem.add_argument("--start", type=lambda value: int(value, 0), required=True)
    dump_lowmem.add_argument("--length", type=lambda value: int(value, 0), required=True)
    dump_lowmem.add_argument("--output", required=True)
    dump_lowmem.set_defaults(func=dump_lowmem_probe)

    dump_ram = sub.add_parser(
        "dump-ram",
        help="read-only bounded physical guest-RAM dump (also supports high protected-mode pages)",
    )
    dump_ram.add_argument("--start", type=lambda value: int(value, 0), required=True)
    dump_ram.add_argument("--length", type=lambda value: int(value, 0), required=True)
    dump_ram.add_argument("--ram-size", type=lambda value: int(value, 0), default=0x01000000)
    dump_ram.add_argument("--output", required=True)
    dump_ram.set_defaults(func=dump_ram_probe)

    capture = sub.add_parser(
        "capture",
        help="write a frozen debug-state/PC-ring bundle plus optional physical-RAM ranges",
    )
    capture.add_argument("--output", required=True, help="new directory on the board")
    capture.add_argument(
        "--range",
        action="append",
        type=parse_range,
        default=[],
        metavar="START:LENGTH",
        help="physical guest-RAM range to include; repeatable",
    )
    capture.add_argument(
        "--full-ram",
        action="store_true",
        help="include all --ram-size bytes (deliberate opt-in for board disk space)",
    )
    capture.add_argument("--ram-size", type=lambda value: int(value, 0), default=0x01000000)
    capture.add_argument("--depth", type=int, default=128, help="PC-ring entries, 1..128")
    capture.add_argument(
        "--allow-live",
        action="store_true",
        help="permit an explicitly non-coherent capture of a running guest",
    )
    capture.add_argument(
        "--disk", default="/tmp/ao486/qk_td.vhd", help="record mounted disk path in manifest"
    )
    capture.add_argument(
        "--bitstream", default="/tmp/ao486/rk_ao486_fastload.bin", help="record bitstream path in manifest"
    )
    capture.add_argument(
        "--hash-inputs",
        action="store_true",
        help="stream SHA-256 of disk and bitstream into manifest (may take time for large images)",
    )
    capture.set_defaults(func=capture_probe)

    inject_keys = sub.add_parser(
        "inject-keys",
        help="inject bounded ASCII through the BIOS keyboard ring (write; diagnostic)",
    )
    inject_keys.add_argument("text", help="printable ASCII text; append \\r with --enter")
    inject_keys.add_argument("--enter", action="store_true", help="append an Enter key")
    inject_keys.add_argument("--interval", type=float, default=0.05)
    inject_keys.add_argument("--timeout", type=float, default=2.0)
    inject_keys.set_defaults(func=inject_keys_probe)

    queue_keys = sub.add_parser(
        "queue-keys", help="queue a short command into an empty BIOS ring (write; diagnostic)"
    )
    queue_keys.add_argument("text", help="1..15 printable ASCII characters; append Enter with --enter")
    queue_keys.add_argument("--enter", action="store_true", help="append an Enter key")
    queue_keys.set_defaults(func=queue_keys_probe)

    ps2_keys = sub.add_parser(
        "ps2-keys",
        help="send normal make/break events through the hosted PS/2 keyboard device (write)",
    )
    ps2_keys.add_argument("text", help="lowercase ASCII text accepted by the PC keyboard map")
    ps2_keys.add_argument("--enter", action="store_true", help="append a physical Enter make/break")
    ps2_keys.add_argument("--timeout", type=float, default=2.0, help="per-Set-2-byte transport timeout")
    ps2_keys.set_defaults(func=ps2_keys_probe)

    ps2_raw = sub.add_parser(
        "ps2-raw",
        help="send raw Set-2 bytes through the hosted PS/2 keyboard device (write)",
    )
    ps2_raw.add_argument("bytes", nargs="+", type=lambda value: int(value, 0))
    ps2_raw.add_argument("--timeout", type=float, default=2.0, help="per-byte transport timeout")
    ps2_raw.set_defaults(func=ps2_raw_probe)

    sample = sub.add_parser(
        "sample", help="read-only sampling of the newest on-die PC-ring entry"
    )
    sample.add_argument("--samples", type=int, default=20)
    sample.add_argument("--interval", type=float, default=0.05)
    sample.add_argument("--all", action="store_true")
    sample.set_defaults(func=sample_probe)

    perf = sub.add_parser(
        "perf", help="read-only raw primary/U counter deltas (not total U+V/gameplay IPC)"
    )
    perf.add_argument("--seconds", type=float, default=5.0)
    perf.add_argument(
        "--axi-read-profiler", action="store_true",
        help="decode 0x1A0/0x1B0 as passive outer-AXI latency counters (matching profiler image only)",
    )
    perf.set_defaults(func=perf_probe)

    clock = sub.add_parser(
        "clock",
        help="set an audited PL0 clock profile (write; stop ao486d first)",
    )
    clock.add_argument("profile", choices=sorted(PL0_CLOCK_PROFILES))
    clock.set_defaults(func=clock_probe)

    trap_zero = sub.add_parser(
        "trap-zero",
        help="arm the fixed CS=0,EIP=0..3 on-chip trace freeze (write)",
    )
    trap_zero.set_defaults(func=trap_zero_probe)

    trap_badcs = sub.add_parser(
        "trap-badcs",
        help="arm the fixed CS=3107 boot-derail trace freeze (write)",
    )
    trap_badcs.set_defaults(func=trap_badcs_probe)

    trap_cs0_high = sub.add_parser(
        "trap-cs0-high",
        help="freeze on CS=0000,EIP=8000..ffff during early boot",
    )
    trap_cs0_high.set_defaults(func=trap_cs0_high_probe)

    trap_status = sub.add_parser(
        "trap-status", help="read the on-chip forensic freeze status"
    )
    trap_status.set_defaults(func=trap_status_probe)

    prepare_cold = sub.add_parser(
        "prepare-cold", help="disarm a fresh ABI-5 image while leaving reset and manual halt held"
    )
    prepare_cold.set_defaults(func=prepare_cold_probe)

    halt = sub.add_parser(
        "halt", help="park at the next instruction boundary (debug image; does not reset the guest)"
    )
    halt.add_argument("--timeout", type=float, default=5.0)
    halt.set_defaults(func=halt_probe)

    run = sub.add_parser(
        "run", help="resume a quiescent debug halt and clear a breakpoint latch"
    )
    run.add_argument("--timeout", type=float, default=1.0)
    run.set_defaults(func=run_probe)

    step = sub.add_parser(
        "step", help="execute exactly one instruction per count from a quiescent halt"
    )
    step.add_argument("--count", type=int, default=1)
    step.add_argument("--timeout", type=float, default=5.0)
    step.set_defaults(func=step_probe)

    breakpoint = sub.add_parser(
        "breakpoint", help="arm a pre-issue EIP breakpoint (debug image)"
    )
    breakpoint.add_argument("eip", type=lambda value: int(value, 0))
    breakpoint.add_argument("--wait", action="store_true", help="wait for the breakpoint and print state")
    breakpoint.add_argument("--timeout", type=float, default=30.0)
    breakpoint.set_defaults(func=breakpoint_probe)

    dump_state = sub.add_parser(
        "dump-state", help="dump integer/system architectural state from a quiescent halt"
    )
    dump_state.add_argument("--halt", action="store_true", help="request a safe halt before dumping")
    dump_state.add_argument("--timeout", type=float, default=5.0)
    dump_state.set_defaults(func=dump_state_probe)

    trap_wide_eip = sub.add_parser(
        "trap-wide-eip",
        help="freeze rings when the full retired EIP exceeds a real-mode limit",
    )
    trap_wide_eip.add_argument("--minimum", type=lambda value: int(value, 0), default=0x10000)
    trap_wide_eip.add_argument("--timeout", type=float, default=15.0)
    trap_wide_eip.add_argument("--interval", type=float, default=0.0)
    trap_wide_eip.set_defaults(func=trap_wide_eip_probe)

    trap_unexpected_cs = sub.add_parser(
        "trap-unexpected-cs",
        help="freeze when newest retire CS leaves an audited real-mode boot set",
    )
    trap_unexpected_cs.add_argument(
        "--allow", default="0x0000,0x07c0,0x1fe0,0xc000,0xf000"
    )
    trap_unexpected_cs.add_argument("--timeout", type=float, default=15.0)
    trap_unexpected_cs.add_argument("--interval", type=float, default=0.0)
    trap_unexpected_cs.add_argument("--delay", type=float, default=0.1)
    trap_unexpected_cs.set_defaults(func=trap_unexpected_cs_probe)

    trap_protected_exit = sub.add_parser(
        "trap-protected-exit",
        help="after protected-mode entry, freeze when CS leaves its audited set",
    )
    trap_protected_exit.add_argument(
        "--enter",
        default="0x26d9",
        help="comma-separated selector(s) that arm the trigger",
    )
    trap_protected_exit.add_argument(
        "--allow",
        default="0x0018,0x26d9",
        help="comma-separated protected-mode selector allow-list",
    )
    trap_protected_exit.add_argument(
        "--enter-eip-min",
        type=lambda value: int(value, 0),
        default=0,
        help="do not arm until the entry selector retires at/above this EIP",
    )
    trap_protected_exit.add_argument(
        "--delay",
        type=float,
        default=0.0,
        help="ignore startup for this many seconds before watching selectors",
    )
    trap_protected_exit.add_argument(
        "--require-pe",
        action="store_true",
        help="arm only with CR0.PE=1 and also fire when protected mode exits",
    )
    trap_protected_exit.add_argument(
        "--skip-exits",
        type=int,
        default=0,
        help="observe and rearm across this many qualified exits before freezing",
    )
    trap_protected_exit.add_argument("--timeout", type=float, default=900.0)
    trap_protected_exit.add_argument("--interval", type=float, default=0.0)
    trap_protected_exit.set_defaults(func=trap_protected_exit_probe)

    trap_pe_exit = sub.add_parser(
        "trap-pe-exit",
        help="after CR0.PE becomes one, freeze on the transition back to real mode",
    )
    trap_pe_exit.add_argument(
        "--delay",
        type=float,
        default=0.0,
        help="ignore startup for this many seconds before watching CR0.PE",
    )
    trap_pe_exit.add_argument("--timeout", type=float, default=900.0)
    trap_pe_exit.add_argument("--interval", type=float, default=0.0)
    trap_pe_exit.add_argument(
        "--arm-cs",
        type=lambda value: int(value, 0),
        default=None,
        help="arm only after this protected-mode CS is observed (for example 0xa7 for Quake)",
    )
    trap_pe_exit.add_argument(
        "--skip-exits",
        type=int,
        default=0,
        help="observe and rearm across this many qualified PE exits before freezing",
    )
    trap_pe_exit.set_defaults(func=trap_pe_exit_probe)

    trap_linear_data = sub.add_parser(
        "trap-linear-data",
        help="freeze after a sustained even-stride retire stream through data",
    )
    trap_linear_data.add_argument("--streak", type=int, default=16)
    trap_linear_data.add_argument("--max-delta", type=int, default=4096)
    trap_linear_data.add_argument("--timeout", type=float, default=30.0)
    trap_linear_data.add_argument("--interval", type=float, default=0.0)
    trap_linear_data.add_argument(
        "--no-tick-gate",
        action="store_true",
        help="do not wait for the BIOS tick; intended only for focused test ROMs",
    )
    trap_linear_data.set_defaults(func=trap_linear_data_probe)

    trap_cwsdpmi = sub.add_parser(
        "trap-cwsdpmi-exception",
        help="freeze rings when CWSDPMI formats a protected-mode exception",
    )
    trap_cwsdpmi.add_argument(
        "--start", type=lambda value: int(value, 0), default=0x20000
    )
    trap_cwsdpmi.add_argument(
        "--end", type=lambda value: int(value, 0), default=0x50000
    )
    trap_cwsdpmi.add_argument("--timeout", type=float, default=900.0)
    trap_cwsdpmi.add_argument("--interval", type=float, default=0.05)
    trap_cwsdpmi.set_defaults(func=trap_cwsdpmi_exception_probe)

    dump_ring = sub.add_parser(
        "dump-ring", help="dump the frozen on-chip PC ring newest-first"
    )
    dump_ring.add_argument("--depth", type=int, default=128)
    dump_ring.add_argument("--allow-live", action="store_true")
    dump_ring.set_defaults(func=dump_ring_probe)

    dump_core_ring = sub.add_parser(
        "dump-core-ring", help="dump the frozen core/L1 observation ring newest-first"
    )
    dump_core_ring.add_argument("--depth", type=int, default=128)
    dump_core_ring.add_argument("--allow-live", action="store_true")
    dump_core_ring.set_defaults(func=dump_core_observe_ring_probe)

    quake = sub.add_parser("quake", help="wait for the exact timedemo result in the HDD image")
    quake.add_argument("--disk", default="/tmp/ao486/qk_td.vhd")
    quake.add_argument("--frames", type=int, default=969)
    quake.add_argument("--interval", type=float, default=30.0)
    quake.add_argument("--timeout", type=float, default=0.0)
    quake.add_argument("--allow-existing", action="store_true")
    quake.add_argument(
        "--precheck-only",
        action="store_true",
        help="scan the disk and exit without opening /dev/mem",
    )
    quake.set_defaults(func=quake_probe)

    quake_progress = sub.add_parser(
        "quake-progress",
        help="read Quake's live timedemo frame counters through its page tables",
    )
    quake_progress.add_argument("--cr3", type=lambda value: int(value, 0), default=0x7E000)
    quake_progress.add_argument(
        "--ds-base", type=lambda value: int(value, 0), default=0x10000000
    )
    quake_progress.add_argument(
        "--ram-size", type=lambda value: int(value, 0), default=0x01000000
    )
    quake_progress.add_argument("--samples", type=int, default=1)
    quake_progress.add_argument("--interval", type=float, default=1.0)
    quake_progress.set_defaults(func=quake_progress_probe)

    linear_peek = sub.add_parser(
        "linear-peek", help="read a guest-linear dword window through live page tables"
    )
    linear_peek.add_argument("--linear", type=lambda value: int(value, 0), required=True)
    linear_peek.add_argument("--cr3", type=lambda value: int(value, 0), default=0x7E000)
    linear_peek.add_argument("--ram-size", type=lambda value: int(value, 0), default=0x01000000)
    linear_peek.add_argument("--words", type=int, default=16)
    linear_peek.set_defaults(func=linear_peek_probe)

    quake_marker = sub.add_parser(
        "quake-marker", help="wait for the binary-only 969-frame completion witness"
    )
    quake_marker.add_argument("--cr3", type=lambda value: int(value, 0), default=0x7E000)
    quake_marker.add_argument("--ds-base", type=lambda value: int(value, 0), default=0x10000000)
    # The hash-locked timedemo wrapper at runtime 0x3fec writes its 969-frame
    # witness to DS:0x90b48.  DS:0x90b40 is the unrelated con_debuglog flag.
    quake_marker.add_argument("--offset", type=lambda value: int(value, 0), default=0x90B48)
    quake_marker.add_argument("--expected", type=lambda value: int(value, 0), default=969)
    quake_marker.add_argument("--ram-size", type=lambda value: int(value, 0), default=0x01000000)
    quake_marker.add_argument("--interval", type=float, default=0.25)
    quake_marker.add_argument("--timeout", type=float, default=0.0)
    quake_marker.set_defaults(func=quake_marker_probe)

    trap_fault_frame = sub.add_parser(
        "trap-quake-fault-frame",
        help="freeze after QUAKE_FAULT_FRAME_LOGGER writes its protected-mode fault frame",
    )
    trap_fault_frame.add_argument("--cr3", type=lambda value: int(value, 0), default=0x7E000)
    trap_fault_frame.add_argument(
        "--ds-base", type=lambda value: int(value, 0), default=0x10000000
    )
    trap_fault_frame.add_argument(
        "--offset", type=lambda value: int(value, 0), default=0x90B80
    )
    trap_fault_frame.add_argument("--words", type=int, default=16)
    trap_fault_frame.add_argument(
        "--ram-size", type=lambda value: int(value, 0), default=0x01000000
    )
    trap_fault_frame.add_argument("--interval", type=float, default=0.001)
    trap_fault_frame.add_argument("--timeout", type=float, default=0.0)
    trap_fault_frame.set_defaults(func=trap_quake_fault_frame_probe)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.mode in ("inject-keys", "queue-keys") and args.enter:
            args.text += "\r"
        return args.func(args)
    except (OSError, RuntimeError) as error:
        print(f"probe error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
