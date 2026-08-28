#!/usr/bin/env python3
"""Compose the no-render heap cap with a console-background bypass.

The FPGA fault cascade enters Draw_ConsoleBackground's version sprintf.  When
x87 state/data is corrupt, its local version buffer overflows and a later
generic memcpy faults.  The existing no-render workload has no visual
acceptance target, so returning from that *overlay-only* function is a narrow
way to keep its known bad formatting path out of the 969-frame experiment.
"""

from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "quake_norender_heapcap" / "QUAKE_NORENDER_HEAPCAP.EXE"
OUTPUT = Path(__file__).with_name("QUAKE_NORENDER_HEAPCAP_NOCONBACK.EXE")

# runtime 0x78e6 / file 0x70e6: immediately after "%4.2f\\0", the cdecl
# Draw_ConsoleBackground prologue begins.  It returns void, so a plain RET
# preserves caller cleanup and leaves all game/demo state outside this overlay.
PATCH_OFF = 0x70E6
EXPECTED = bytes.fromhex("83 ec 14 55 57 56 53 68 d0 78 00 00 e8")
REPLACEMENT = bytes.fromhex("c3 90 90 90 90 90 90 90 90 90 90 90 90")
SOURCE_SHA256 = "4e236687c134363c5d7a3be7f256aacf0b9f7531e603813f8ac946e1ff6e4227"


def main() -> None:
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected source SHA-256")
    if src[PATCH_OFF:PATCH_OFF + len(EXPECTED)] != EXPECTED:
        raise SystemExit("unexpected Draw_ConsoleBackground context")
    out = bytearray(src)
    out[PATCH_OFF:PATCH_OFF + len(REPLACEMENT)] = REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
