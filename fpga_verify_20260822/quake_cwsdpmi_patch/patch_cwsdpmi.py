#!/usr/bin/env python3
"""Make the exact Quake-only CWSDPMI workaround used for FPGA bring-up.

This is deliberately hash- and context-locked.  It does not claim to repair
CWSDPMI generally; it bypasses the CPU's currently unsupported protected-mode
LDS in release-7 ``_ring0_iret`` while preserving the exact five-byte length.
"""

from __future__ import annotations

import hashlib
import pathlib
import sys


ORIGINAL_SHA256 = "0a890815df6cbdc052915a856c16944cedec825267e7b6e453c351a0cdc695f2"
CONTEXT = bytes.fromhex(
    "66 83 c7 04 "        # add edi,4
    "16 07 "              # push ss; pop es (destination segment)
    "66 67 c5 75 10 "     # lds esi,[ebp+16]
    "fc "                  # cld
    "f3 66 67 a5 "        # rep movsd
    "66 59 66 5f 66 5e"   # restore ecx/edi/esi
)

# Workload-specific equivalence:
#   * MOV retains only old ESP from the m16:32 pointer.
#   * SS overrides the following MOVS source; the preceding push-SS/pop-ES
#     already makes the destination current SS as well.
#   * The captured call-gate EFLAGS has DF=0, so replacing CLD with the segment
#     override does not change this exact Quake path.
PATCHED = bytes.fromhex(
    "66 83 c7 04 "
    "16 07 "
    "66 67 8b 75 10 "     # mov esi,[ebp+16]
    "36 "                  # SS override for the following rep movsd
    "f3 66 67 a5 "
    "66 59 66 5f 66 5e"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} ORIGINAL.EXE PATCHED.EXE", file=sys.stderr)
        return 2

    source = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    data = source.read_bytes()
    digest = sha256(data)
    if digest != ORIGINAL_SHA256:
        raise SystemExit(
            f"refusing unexpected input: sha256={digest}, expected={ORIGINAL_SHA256}"
        )

    matches = []
    start = 0
    while True:
        found = data.find(CONTEXT, start)
        if found < 0:
            break
        matches.append(found)
        start = found + 1
    if matches != [0x12FF]:
        raise SystemExit(f"refusing unexpected context matches: {matches!r}")
    if len(CONTEXT) != len(PATCHED):
        raise AssertionError("in-place replacement changed length")

    result = data[: matches[0]] + PATCHED + data[matches[0] + len(CONTEXT) :]
    if len(result) != len(data):
        raise AssertionError("output size changed")
    output.write_bytes(result)
    print(
        f"patched {source} @0x{matches[0]:x}: "
        f"{ORIGINAL_SHA256} -> {sha256(result)} ({len(result)} bytes)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
