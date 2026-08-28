#!/usr/bin/env python3
"""Suppress only the Con_DebugLog callee, preserving caller-side formatting."""

from hashlib import sha256
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "quake_norender_heapscan" / "QUAKE_NORENDER_HEAPSCAN.EXE"
OUTPUT = HERE / "QUAKE_HEAPSCAN_LOGGERRET_MARKER.EXE"
SOURCE_SHA256 = "16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3"

RESULT_OFF = 0x37E0
RESULT_EXPECTED = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
RESULT_REPLACEMENT = bytes.fromhex(
    "e80700000083c41883c404c3"
    "83c404c705480b0900c9030000"
    "e8b42b0000"
    "68e53f0000c3"
)

# Con_DebugLog @ runtime 0x6b44 (file 0x6344).  The caller has already
# formatted the line and discards its return value; returning here removes
# only fopen/fwrite/fclose and leaves the call graph/control cadence intact.
LOGGER_OFF = 0x6344
LOGGER_EXPECTED = bytes.fromhex("57538b5c240c8d442414")


def main() -> None:
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected heap-scan source SHA-256")
    if src[RESULT_OFF:RESULT_OFF + len(RESULT_EXPECTED)] != RESULT_EXPECTED:
        raise SystemExit("unexpected timedemo-result context")
    if src[LOGGER_OFF:LOGGER_OFF + len(LOGGER_EXPECTED)] != LOGGER_EXPECTED:
        raise SystemExit("unexpected Con_DebugLog context")
    out = bytearray(src)
    out[RESULT_OFF:RESULT_OFF + len(RESULT_REPLACEMENT)] = RESULT_REPLACEMENT
    out[LOGGER_OFF] = 0xC3
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
