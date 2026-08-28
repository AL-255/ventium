#!/usr/bin/env python3
"""Build the reversible second heap-scan accelerator for DOS Quake 1.06."""

from hashlib import sha256
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "quake_norender" / "QUAKE_NORENDER.EXE"
OUTPUT = Path(__file__).resolve().parent / "QUAKE_NORENDER_HEAPSCAN.EXE"

# Runtime EIP 0x456b0, accounting for the 0x800-byte DJGPP DOS stub.
# This is the backedge of the four-pass 64 KiB-stride heap checksum.  The
# preceding prologue/allocation and the outer pass count remain untouched.
PATCH_OFF = 0x44EB0
EXPECTED = bytes.fromhex("7c e2 43 83 fb 03 7e cc")
REPLACEMENT = bytes.fromhex("90 90 43 83 fb 03 7e cc")
SOURCE_SHA256 = "ab85733550b61a0cfee9bbb8a66aafd1f80d502575603d5bfabc585ebe528639"


def main() -> None:
    src = SOURCE.read_bytes()
    got = sha256(src).hexdigest()
    if got != SOURCE_SHA256:
        raise SystemExit(f"unexpected source SHA-256: {got}")
    if src[PATCH_OFF:PATCH_OFF + len(EXPECTED)] != EXPECTED:
        raise SystemExit("unexpected heap-loop context")
    out = bytearray(src)
    out[PATCH_OFF:PATCH_OFF + len(REPLACEMENT)] = REPLACEMENT
    OUTPUT.write_bytes(out)
    print(f"{OUTPUT.name} {sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
