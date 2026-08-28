#!/usr/bin/env python3
"""Arm the RK Ventium on-die retire comparator for a bounded trace run.

This is intentionally separate from ven_board_probe.py: the probe is strictly
read-only, while this utility writes only the documented core/debug control
registers.  Its default mode holds the core before clearing a previous freeze,
then arms a CS match.  ao486d --trace can subsequently load the guest, clear
the rings, and release the core; the first matching retire freezes the trace
ring.  ``--live`` arms a comparator on an already-running, non-frozen core
without clearing either ring; use it only after a read-only progress marker has
qualified a late failure window.
"""

from __future__ import annotations

import argparse
import mmap
import os
import struct
import sys


CTRL_BASE = 0xA000_0000
CTRL_SIZE = 0x1_0000
IDENT_MAGIC = 0xA048_6501
FPGA_STATE_PATH = "/sys/class/fpga_manager/fpga0/state"

R_IDENT = 0x00
R_CTRL = 0x20
W_DBG_CTL = 0x80
W_DBG_CMPCFG = 0xA0
W_DBG_CMPRNG = 0xB0
R_DBG_FRZINFO = 0x90

CTRL_CORE_RESET = 0x0001
DBG_CLEAR = 1 << 8
CMP_ENABLE = 1 << 16
CMP_CS_CARE = 1 << 17
CMP_EIP_CARE = 1 << 18
CMP_FREEZE = 1 << 19


def u32(buf: mmap.mmap, off: int) -> int:
    return struct.unpack_from("<I", buf, off)[0]


def put_u32(buf: mmap.mmap, off: int, value: int) -> None:
    struct.pack_into("<I", buf, off, value & 0xFFFF_FFFF)


def parse_int(value: str) -> int:
    return int(value, 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cs", required=True, type=parse_int)
    parser.add_argument("--eip-lo", type=parse_int)
    parser.add_argument("--eip-hi", type=parse_int)
    parser.add_argument(
        "--live",
        action="store_true",
        help="arm a running core without holding it or clearing trace rings",
    )
    args = parser.parse_args()

    if not 0 <= args.cs <= 0xFFFF:
        parser.error("--cs must fit in 16 bits")
    if (args.eip_lo is None) != (args.eip_hi is None):
        parser.error("--eip-lo and --eip-hi must be supplied together")
    if args.eip_lo is not None and not (
        0 <= args.eip_lo <= args.eip_hi <= 0xFFFF
    ):
        parser.error("EIP range must satisfy 0 <= lo <= hi <= 0xffff")

    try:
        with open(FPGA_STATE_PATH, "r", encoding="ascii") as state_file:
            state = state_file.read().strip()
        if state != "operating":
            raise RuntimeError(
                f"FPGA-manager state is {state!r}, refusing PL MMIO"
            )

        fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        try:
            ctrl = mmap.mmap(
                fd,
                CTRL_SIZE,
                flags=mmap.MAP_SHARED,
                prot=mmap.PROT_READ | mmap.PROT_WRITE,
                offset=CTRL_BASE,
            )
            try:
                ident = u32(ctrl, R_IDENT)
                if ident != IDENT_MAGIC:
                    raise RuntimeError(
                        f"IDENT={ident:08x}, expected {IDENT_MAGIC:08x}"
                    )

                cfg = CMP_ENABLE | CMP_CS_CARE | CMP_FREEZE | args.cs
                rng = 0
                if args.eip_lo is not None:
                    cfg |= CMP_EIP_CARE
                    rng = (args.eip_hi << 16) | args.eip_lo

                if args.live:
                    frozen = (u32(ctrl, R_DBG_FRZINFO) >> 31) & 1
                    held = u32(ctrl, R_CTRL) & 1
                    if frozen:
                        raise RuntimeError(
                            "trace is already frozen; reprogram before live-arm"
                        )
                    if held:
                        raise RuntimeError(
                            "core is held; use the default pre-load arm mode"
                        )

                    # The daemon starts with the comparator disabled.  Keep it
                    # disabled while changing the range, then make enable the
                    # final write.  Do not clear the rolling prehistory.
                    put_u32(ctrl, W_DBG_CMPCFG, 0)
                    put_u32(ctrl, W_DBG_CMPRNG, rng)
                    put_u32(ctrl, W_DBG_CMPCFG, cfg)
                    frozen = (u32(ctrl, R_DBG_FRZINFO) >> 31) & 1
                    print(
                        f"IDENT={ident:08x} live=1 core_held={held} "
                        f"frozen={frozen} cmp_cfg={cfg:08x} "
                        f"cmp_range={rng:08x}"
                    )
                    return 0

                # A previous debug freeze itself holds soc_reset.  Assert the
                # normal core reset first so clearing that sticky freeze cannot
                # briefly resume the failed guest.
                put_u32(ctrl, R_CTRL, CTRL_CORE_RESET)
                put_u32(ctrl, W_DBG_CMPCFG, 0)
                put_u32(ctrl, W_DBG_CTL, DBG_CLEAR)

                put_u32(ctrl, W_DBG_CMPRNG, rng)
                put_u32(ctrl, W_DBG_CMPCFG, cfg)

                frozen = (u32(ctrl, R_DBG_FRZINFO) >> 31) & 1
                held = u32(ctrl, R_CTRL) & 1
                print(
                    f"IDENT={ident:08x} core_held={held} frozen={frozen} "
                    f"cmp_cfg={cfg:08x} cmp_range={rng:08x}"
                )
                if not held or frozen:
                    raise RuntimeError("debug block did not reach held/clear state")
            finally:
                ctrl.close()
        finally:
            os.close(fd)
        return 0
    except (OSError, RuntimeError) as error:
        print(f"trace-arm error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
