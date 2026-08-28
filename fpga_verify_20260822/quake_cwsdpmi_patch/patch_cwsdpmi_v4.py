#!/usr/bin/env python3
"""Build the fully addressed, selector-faithful CWSDPMI LDS workaround.

The deployed RTL cannot execute the protected-mode LDS in CWSDPMI's ring-0
return path.  This replacement performs the same offset and selector loads with
ordinary instructions supported by that image.  It recovers four bytes without
weakening either address:

* width-matched PUSH/POP sets ECX in five bytes;
* LEA replaces MOV+ADD and saves two bytes; and
* ten MOVSW iterations replace five MOVSD iterations and save one prefix byte.

The source and destination addresses, final ESI/EDI values, zero ECX, loaded DS,
clear DF, saved registers, and stack depth therefore match the original path.
This remains a hash-locked workload workaround, not a general LDS substitute.
"""

from __future__ import annotations

import hashlib
import pathlib
import sys


ORIGINAL_SHA256 = "0a890815df6cbdc052915a856c16944cedec825267e7b6e453c351a0cdc695f2"
CONTEXT = bytes.fromhex(
    "66 56 66 57 66 51 "       # push esi; push edi; push ecx
    "66 b9 05 00 00 00 "       # mov ecx,5
    "66 8b fd "                 # mov edi,ebp
    "66 83 c7 04 "              # add edi,4
    "16 07 "                    # push ss; pop es
    "66 67 c5 75 10 "           # lds esi,[ebp+16]
    "fc "                       # cld
    "f3 66 67 a5 "              # rep movsd
    "66 59 66 5f 66 5e"        # restore ecx/edi/esi
)

PATCHED = bytes.fromhex(
    "66 56 66 57 66 51 "       # push esi; push edi; push ecx
    "66 6a 0a 66 59 "           # push dword 10; pop ecx (save one byte)
    "66 67 8d 7d 04 "           # lea edi,[ebp+4] (save two bytes)
    "16 07 "                    # push ss; pop es
    "66 67 8b 75 10 "           # mov esi,ss:[ebp+16]
    "67 8e 5d 14 "              # mov ds,ss:[ebp+20]
    "fc "                       # preserve CLD
    "f3 67 a5 "                 # ten words = original five dwords
    "66 59 66 5f 66 5e"        # restore ecx/edi/esi
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

    matches: list[int] = []
    start = 0
    while True:
        found = data.find(CONTEXT, start)
        if found < 0:
            break
        matches.append(found)
        start = found + 1
    if matches != [0x12F0]:
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
