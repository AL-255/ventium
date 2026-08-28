#!/usr/bin/env python3
"""Keep Quake's console state but suppress only its DOS log-write tail.

The FPGA reaches a PIO WRITE before the timedemo result because buffered
``-condebug`` output flushes through DOS.  This patch leaves initialization,
formatting, and the condebug flag intact; it bypasses only the file logger in
``Con_Printf``.  A persistent independent marker is written immediately before
the genuine timedemo-result call.
"""

from hashlib import sha256
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "quake_norender_heapscan" / "QUAKE_NORENDER_HEAPSCAN.EXE"
OUTPUT = HERE / "QUAKE_HEAPSCAN_NOLOG_MARKER.EXE"
SOURCE_SHA256 = "16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3"

RESULT_OFF = 0x37E0
RESULT_EXPECTED = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
RESULT_REPLACEMENT = bytes.fromhex(
    "e80700000083c41883c404c3"
    # wrapper @ 0x3fec: remove wrapper return, set independent BSS witness,
    # call original Con_Printf, resume original caller without clearing witness.
    "83c404c705480b0900c9030000"
    "e8b42b0000"
    "68e53f0000c3"
)

# Runtime 0x6be0, file offset 0x63e0.  The original cmp/je is the condebug
# file-log branch.  Jump directly to 0x6c0a, leaving normal console formatting
# and every other Con_Printf side effect intact.
LOGGER_OFF = 0x63E0
LOGGER_EXPECTED = bytes.fromhex("833d400b0900007421")
LOGGER_REPLACEMENT = bytes.fromhex("eb2890909090907421")


def main() -> None:
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected heap-scan source SHA-256")
    if src[RESULT_OFF:RESULT_OFF + len(RESULT_EXPECTED)] != RESULT_EXPECTED:
        raise SystemExit("unexpected timedemo-result context")
    if src[LOGGER_OFF:LOGGER_OFF + len(LOGGER_EXPECTED)] != LOGGER_EXPECTED:
        raise SystemExit("unexpected Con_Printf logger context")
    out = bytearray(src)
    out[RESULT_OFF:RESULT_OFF + len(RESULT_REPLACEMENT)] = RESULT_REPLACEMENT
    out[LOGGER_OFF:LOGGER_OFF + len(LOGGER_REPLACEMENT)] = LOGGER_REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
