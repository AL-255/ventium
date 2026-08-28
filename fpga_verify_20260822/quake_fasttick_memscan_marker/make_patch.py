#!/usr/bin/env python3
"""Instrument the QEMU-proven FASTTICK+heap-scan Quake workload for FPGA proof."""

import argparse
from hashlib import sha256
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "quake_memscan_patch" / "QUAKE_MEM.EXE"
OUTPUT = HERE / "QUAKE_FASTTICK_MEMSCAN_MARKER.EXE"
SOURCE_SHA256 = "e7b4a6879355ba74d6cab8589db0ae1f1d18407e5bcaecff07a354c42b27167e"

# The executable layout is unchanged by the heap-scan-only edit.  The wrapper
# writes a persistent completion witness before retaining the original result
# printer.  Con_DebugLog itself returns, leaving its caller's condition and
# formatting work intact while eliminating DOS fopen/fwrite/fclose traffic.
RESULT_OFF = 0x37E0
RESULT_EXPECTED = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
RESULT_REPLACEMENT = bytes.fromhex(
    "e80700000083c41883c404c3"
    "83c404c705480b0900c9030000"
    "e8b42b0000"
    "68e53f0000c3"
)
LOGGER_OFF = 0x6344
LOGGER_EXPECTED = bytes.fromhex("57538b5c240c8d442414")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--keep-logger",
        action="store_true",
        help="produce a QEMU-only oracle binary with the original logging body",
    )
    args = parser.parse_args()
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected FASTTICK+heap-scan Quake source SHA-256")
    if src[RESULT_OFF:RESULT_OFF + len(RESULT_EXPECTED)] != RESULT_EXPECTED:
        raise SystemExit("unexpected timedemo-result context")
    if src[LOGGER_OFF:LOGGER_OFF + len(LOGGER_EXPECTED)] != LOGGER_EXPECTED:
        raise SystemExit("unexpected Con_DebugLog context")
    out = bytearray(src)
    out[RESULT_OFF:RESULT_OFF + len(RESULT_REPLACEMENT)] = RESULT_REPLACEMENT
    if not args.keep_logger:
        out[LOGGER_OFF] = 0xC3
    output = OUTPUT if not args.keep_logger else HERE / "QUAKE_FASTTICK_MEMSCAN_MARKER_QEMU.EXE"
    output.write_bytes(out)
    print(f"{output.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
