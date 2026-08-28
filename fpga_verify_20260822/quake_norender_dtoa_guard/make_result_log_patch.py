#!/usr/bin/env python3
"""Compose the bounded-dtoa guard with the proven result-only logger."""

from hashlib import sha256
from pathlib import Path


HERE = Path(__file__).resolve().parent
SOURCE = HERE / "QUAKE_NORENDER_DTOA_GUARD.EXE"
OUTPUT = HERE / "QUAKE_NORENDER_DTOA_GUARD_RESULT.EXE"
SOURCE_SHA256 = "679cc14c72aef596626664f752266924792e5c36dacdc81d74e00626ae680033"

# Existing final-log instrumentation, independently context-checked in the
# guarded parent.  File offsets are runtime addresses minus the DJGPP 0x800
# stub.  The first disables boot-time condebug; the second enables it only for
# the existing timedemo-result Con_Printf call.
DISABLE_OFF = 0x6107
DISABLE_EXPECTED = bytes.fromhex("e812880000")
DISABLE_REPLACEMENT = bytes.fromhex("31c0909090")
RESULT_OFF = 0x37E0
RESULT_EXPECTED = bytes.fromhex("e8cd2b000083c41883c404c374696d65")
RESULT_REPLACEMENT = bytes.fromhex(
    "e80700000083c41883c404c3"
    "83c404c705400b090001000000"
    "e8b42b0000"
    "c705400b090000000000"
    "68e53f0000c3"
)


def main() -> None:
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected source SHA-256")
    if src[DISABLE_OFF:DISABLE_OFF + len(DISABLE_EXPECTED)] != DISABLE_EXPECTED:
        raise SystemExit("unexpected condebug context")
    if src[RESULT_OFF:RESULT_OFF + len(RESULT_EXPECTED)] != RESULT_EXPECTED:
        raise SystemExit("unexpected timedemo result-call context")
    out = bytearray(src)
    out[DISABLE_OFF:DISABLE_OFF + len(DISABLE_REPLACEMENT)] = DISABLE_REPLACEMENT
    out[RESULT_OFF:RESULT_OFF + len(RESULT_REPLACEMENT)] = RESULT_REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
