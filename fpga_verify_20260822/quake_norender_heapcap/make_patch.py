#!/usr/bin/env python3
"""Build a no-render Quake image with the R_NewMap surface count capped at 800.

The input is already a workload accelerator (FASTTICK, no renderer, and the
bounded heap-check patch).  This adds one branch-only discriminator for the
observed bad floating-point conversion: R_NewMap normally clamps a *small*
surface count up to 800, but a corrupted 8,000,000 value reaches Hunk_Alloc.
Forcing the existing 800 branch leaves the host/demo loop and frame counter
intact while removing that failed allocation from the no-render experiment.
"""

from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "quake_norender_heapscan" / "QUAKE_NORENDER_HEAPSCAN.EXE"
OUTPUT = Path(__file__).with_name("QUAKE_NORENDER_HEAPCAP.EXE")

# Runtime 0x3229b; file offset accounts for the 0x800-byte DJGPP stub.
#   cmp edx, 0x320
#   jg  0x322b0       # allocate edx * 64 bytes
# becomes an unconditional jump to the pre-existing minimum-safe branch.
PATCH_OFF = 0x31A9B
EXPECTED = bytes.fromhex("81 fa 20 03 00 00 7f 0d c7 05 6c 7f 0b 00 20 03 00 00")
REPLACEMENT = bytes.fromhex("81 fa 20 03 00 00 eb 0d c7 05 6c 7f 0b 00 20 03 00 00")
SOURCE_SHA256 = "16cfc75dc096bf5b1a9869f469e1e5d009a84737a7e380e29385a8588e4a79e3"


def main() -> None:
    src = SOURCE.read_bytes()
    if sha256(src).hexdigest() != SOURCE_SHA256:
        raise SystemExit("unexpected source SHA-256")
    if src[PATCH_OFF:PATCH_OFF + len(EXPECTED)] != EXPECTED:
        raise SystemExit("unexpected R_NewMap clamp context")
    out = bytearray(src)
    out[PATCH_OFF:PATCH_OFF + len(REPLACEMENT)] = REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
