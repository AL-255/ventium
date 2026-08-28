#!/usr/bin/env python3
"""Bound the observed x87 dtoa loop and add a non-DOS completion witness."""
import argparse
from hashlib import sha256
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "quake_norender_heapscan" / "QUAKE_NORENDER_HEAPSCAN.EXE"
OUTPUT = HERE / "QUAKE_DTOA_GUARD_MARKER.EXE"
SOURCE_SHA256 = "16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3"

DTOA_OFF = 0x540D1
DTOA_EXPECTED = bytes.fromhex("0f8577ffffff")
DTOA_REPLACEMENT = bytes.fromhex("837ddc207c77")
RESULT_OFF = 0x37E0
RESULT_EXPECTED = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
RESULT_REPLACEMENT = bytes.fromhex("e80700000083c41883c404c383c404c705480b0900c9030000e8b42b000068e53f0000c3")
LOGGER_OFF = 0x6344
LOGGER_EXPECTED = bytes.fromhex("57538b5c240c8d442414")

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep-logger", action="store_true")
    args = parser.parse_args()
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected source hash")
    if src[DTOA_OFF:DTOA_OFF+6] != DTOA_EXPECTED or src[RESULT_OFF:RESULT_OFF+len(RESULT_EXPECTED)] != RESULT_EXPECTED or src[LOGGER_OFF:LOGGER_OFF+len(LOGGER_EXPECTED)] != LOGGER_EXPECTED:
        raise SystemExit("unexpected patch context")
    out = bytearray(src)
    out[DTOA_OFF:DTOA_OFF+6] = DTOA_REPLACEMENT
    out[RESULT_OFF:RESULT_OFF+len(RESULT_REPLACEMENT)] = RESULT_REPLACEMENT
    if not args.keep_logger:
        out[LOGGER_OFF] = 0xC3
    output = OUTPUT if not args.keep_logger else HERE / "QUAKE_DTOA_GUARD_MARKER_QEMU.EXE"
    output.write_bytes(out)
    print(output.name, sha256(out).hexdigest())

if __name__ == "__main__":
    main()
