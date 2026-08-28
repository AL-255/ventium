#!/usr/bin/env python3
"""Add a dormant DPMI-fault-frame logger to the FPGA Quake witness image.

The program's exception common path has already saved the complete callback
frame in its private record when it reaches ``HOOK_OFF``.  This patch copies
that record to DS:0x90b80, preserving every register and flags before returning
to the unmodified handler.  The hook is only reached after a CPU exception, so
a healthy timedemo has byte-identical execution outside the patched code.
"""

from hashlib import sha256
from pathlib import Path
import struct


HERE = Path(__file__).resolve().parent
INPUT = Path("/tmp/quake_current.exe")
OUTPUT = HERE / "QUAKE_FAULT_FRAME_LOGGER.EXE"
INPUT_SHA256 = "71985ca618021a90172723c563fb30c3a7a79d4880271fe513b1bc46b7462943"

# Runtime offsets equal file offsets for this flat GO32 image.
HOOK_OFF = 0x4CE82
HOOK_EXPECTED = bytes.fromhex("c74510d4d60400")
HOOK_RESUME = HOOK_OFF + len(HOOK_EXPECTED)
CAVE_OFF = 0x4CF64
CAVE_SIZE = 0x66
LOG_OFF = 0x90B80


def rel32(source_after: int, target: int) -> bytes:
    return struct.pack("<i", target - source_after)


def main() -> None:
    src = INPUT.read_bytes()
    if sha256(src).hexdigest() != INPUT_SHA256:
        raise SystemExit(f"unexpected input SHA-256: {sha256(src).hexdigest()}")
    if src[HOOK_OFF:HOOK_OFF + len(HOOK_EXPECTED)] != HOOK_EXPECTED:
        raise SystemExit("unexpected exception-handler hook context")
    if src[CAVE_OFF:CAVE_OFF + CAVE_SIZE] != b"\0" * CAVE_SIZE:
        raise SystemExit("selected exception-handler code cave is not empty")

    # Reproduce the displaced frame-return rewrite, then save flags/ES and
    # volatile registers.  EBX already names the handler's complete fault
    # record.  DS is the handler's normal client-data selector, so temporarily
    # make ES equal DS for REP MOVSD and restore all architectural state.
    cave = bytearray()
    cave += HOOK_EXPECTED
    cave += bytes.fromhex("9c065657511e0789de")
    cave += b"\xbf" + struct.pack("<I", LOG_OFF)
    cave += b"\xb9" + struct.pack("<I", 16)
    cave += bytes.fromhex("f3a5595f5e079d")
    cave += b"\xe9" + rel32(CAVE_OFF + len(cave) + 5, HOOK_RESUME)
    if len(cave) > CAVE_SIZE:
        raise SystemExit("logger does not fit selected code cave")

    out = bytearray(src)
    out[HOOK_OFF:HOOK_OFF + len(HOOK_EXPECTED)] = (
        b"\xe9" + rel32(HOOK_OFF + 5, CAVE_OFF) + b"\x90\x90"
    )
    out[CAVE_OFF:CAVE_OFF + len(cave)] = cave
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()} cave_bytes={len(cave)}")


if __name__ == "__main__":
    main()
