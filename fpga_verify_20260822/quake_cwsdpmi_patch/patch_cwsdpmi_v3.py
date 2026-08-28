#!/usr/bin/env python3
"""Build the selector-faithful Quake CWSDPMI LDS workaround.

The first two bring-up patches copied the LDS offset but did not load its DS
selector.  That is not instruction-equivalent: the immediately following
REP MOVSD takes its source through the newly loaded DS.  This revision spells
the operation as ordinary instructions already supported by the deployed RTL:

    mov esi,ss:[ebp+16]
    mov ds,ss:[bp+20]

CWSDPMI's ring-0 frame uses a 16-bit stack, so BP and EBP select the same stack
frame for the selector word.  The offset access remains explicitly 32-bit.
Two source bytes are recovered with LEA and one with the width-matched ECX
PUSH/POP spelling, preserving CLD and the exact executable length.

This is deliberately hash- and context-locked.  It is a silicon bring-up
workaround for one CWSDPMI release-7 path, not a general LDS implementation.
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
    "66 6a 05 66 59 "           # push dword 5; pop ecx (save one byte)
    "66 67 8d 7d 04 "           # lea edi,[ebp+4] (save two bytes)
    "16 07 "                    # push ss; pop es
    "66 67 8b 75 10 "           # mov esi,ss:[ebp+16]
    "8e 5e 14 "                 # mov ds,ss:[bp+20]
    "fc "                       # preserve CLD
    "f3 66 67 a5 "              # rep movsd from DS:ESI to ES:EDI
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
