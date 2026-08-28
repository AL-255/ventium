#!/usr/bin/env python3
"""Add a fail-safe bound to Quake's libc float digit-emission loop.

The parent workload already disables rendering and bypasses the known console
background formatter.  This guard preserves every normal QEMU conversion: it
only exits the fractional-digit loop after 32 emitted digits, which is far
beyond any valid `%4.2f` conversion.  It prevents an invalid FPU value from
turning that loop into an unbounded write into a caller-owned buffer.
"""

from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "quake_norender_heapcap_noconback" / "QUAKE_NORENDER_HEAPCAP_NOCONBACK.EXE"
OUTPUT = Path(__file__).with_name("QUAKE_NORENDER_DTOA_GUARD.EXE")

# runtime 0x548d1 / file 0x540d1.  The original `jne 0x5484e` repeats the
# float digit loop until an x87 compare reaches zero.  Replacing its six bytes
# with `cmp digit_count,32; jl 0x5484e` gives malformed input a finite exit.
PATCH_OFF = 0x540D1
EXPECTED = bytes.fromhex("0f8577ffffff")
REPLACEMENT = bytes.fromhex("837ddc207c77")
SOURCE_SHA256 = "8e3a93dff2131a71dab904f00ca3b96a9507d6f1c6021b14cd721943f3db156d"


def main() -> None:
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected source SHA-256")
    if src[PATCH_OFF:PATCH_OFF + len(EXPECTED)] != EXPECTED:
        raise SystemExit("unexpected dtoa loop context")
    out = bytearray(src)
    out[PATCH_OFF:PATCH_OFF + len(REPLACEMENT)] = REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
