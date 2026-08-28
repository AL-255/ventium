#!/usr/bin/env python3
"""Build a no-write FPGA completion witness from the QEMU-checked heap-scan run.

The marker executes immediately before Quake's existing timedemo-result
``Con_Printf`` call.  It writes 969 (0x3c9) to the otherwise boolean
``con_debuglog`` global, then calls the unmodified printer.  On FPGA the
result-file PIO write is currently the failing path, but the marker is visible
before that transfer.  Boot-time ``-condebug`` is disabled so no earlier IDE
write can reach that path.
"""

from hashlib import sha256
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "quake_norender_heapscan" / "QUAKE_NORENDER_HEAPSCAN.EXE"
OUTPUT = HERE / "QUAKE_HEAPSCAN_MARKER.EXE"
SOURCE_SHA256 = "16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3"

DISABLE_OFF = 0x6107
DISABLE_EXPECTED = bytes.fromhex("e812880000")
DISABLE_REPLACEMENT = bytes.fromhex("31c0909090")

RESULT_OFF = 0x37E0
RESULT_EXPECTED = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
# Redirect the existing result call to 0x3fec.  The wrapper drops its private
# return address, records the completion witness, then invokes the original
# Con_Printf with the caller's untouched variadic argument list.
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
    if src[DISABLE_OFF:DISABLE_OFF + len(DISABLE_EXPECTED)] != DISABLE_EXPECTED:
        raise SystemExit("unexpected condebug call context")
    if src[RESULT_OFF:RESULT_OFF + len(RESULT_EXPECTED)] != RESULT_EXPECTED:
        raise SystemExit("unexpected timedemo-result context")
    out = bytearray(src)
    out[DISABLE_OFF:DISABLE_OFF + len(DISABLE_REPLACEMENT)] = DISABLE_REPLACEMENT
    out[RESULT_OFF:RESULT_OFF + len(RESULT_REPLACEMENT)] = RESULT_REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
