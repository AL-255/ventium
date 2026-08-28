#!/usr/bin/env python3
"""Add only a pre-print 969 witness to the FPGA-best heap-scan executable.

Unlike the earlier marker experiment this deliberately leaves the original
``-condebug`` startup path byte-identical.  That is the only configuration
which has crossed the 582-read hardware retry boundary.  The sole mutation is
at the already QEMU-validated timedemo-result call site.
"""

from hashlib import sha256
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "quake_norender_heapscan" / "QUAKE_NORENDER_HEAPSCAN.EXE"
OUTPUT = HERE / "QUAKE_HEAPSCAN_RESULT_MARKER.EXE"
SOURCE_SHA256 = "16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3"

RESULT_OFF = 0x37E0
RESULT_EXPECTED = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
# The wrapper writes 969 to con_debuglog before calling the original result
# printer.  It changes no startup control flow or heap/layout state.
RESULT_REPLACEMENT = bytes.fromhex(
    "e80700000083c41883c404c3"
    "83c404c705400b0900c9030000"
    "e8b42b0000"
    "c705400b090000000000"
    "68e53f0000c3"
)


def main() -> None:
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected heap-scan source SHA-256")
    if src[RESULT_OFF:RESULT_OFF + len(RESULT_EXPECTED)] != RESULT_EXPECTED:
        raise SystemExit("unexpected timedemo-result context")
    out = bytearray(src)
    out[RESULT_OFF:RESULT_OFF + len(RESULT_REPLACEMENT)] = RESULT_REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
