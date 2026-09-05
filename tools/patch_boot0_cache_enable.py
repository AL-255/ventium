#!/usr/bin/env python3
"""Create the cache-enabled variant of the deployed ao486 boot ROM.

The MiSTer ao486 firmware was written for a core that ignores CR0.CD/NW.  On a
P5, those reset-set bits disable caching until firmware clears them.  The
Ventium core correctly honours the bits, so that ROM leaves both L1 caches
disabled for the entire guest lifetime.

The legacy Bochs BIOS toolchain (bcc/as86) is not installed on the build host.
This bootstrap tool changes exactly the published 64 KiB release ROM whose
hash is recorded below.  It redirects only the *cold-reset vector* through
known zero padding immediately before the POST entry, where a small trampoline
runs:

    WBINVD; MOV EAX,CR0; AND EAX,~(CR0.CD|CR0.NW); MOV CR0,EAX

MOV CR is serializing.  WBINVD is the P5-correct cache transition companion;
Ventium implements it as a hierarchy invalidate (its L1D is write-through).
The trampoline then enters the unmodified POST entry.  Deliberately leaving
that entry byte-identical matters: the ROM's Ctrl+Alt+Del handler also jumps to
it for a warm reboot, and this narrowly-scoped bootstrap must not add a
privileged cache operation to that unrelated entry path.  The BIOS checksum at
0xffff is recomputed.

The deliberately strict provenance and layout checks make this unsuitable for
silently patching a future, source-built ROM.  Once bcc/as86 are available,
make the corresponding source change in sw/sysbios/rombios.c and retire this
bootstrap tool.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


ROM_SIZE = 0x10000
EXPECTED_INPUT_SHA256 = "e70c8843ac9c6485856d360ad6a306934ccc8399fc4c777c930373da84c4331e"
POST_ENTRY = 0xE05B
TRAMPOLINE = 0xE040
RESET_VECTOR_OFFSET = 0xFFF0
RESET_VECTOR = bytes.fromhex("ea 5b e0 00 f0")
TRAMPOLINE_VECTOR = bytes.fromhex("ea 40 e0 00 f0")
ORIGINAL_POST = bytes.fromhex("31 c0 e6 0d e6 da")  # xor ax,ax; two DMA clears

# 16-bit code segment: explicit 0x66 prefixes are required for the 32-bit
# CR0 transfer/mask.  This is reached only from the cold reset vector; the
# near jump enters the original POST byte-for-byte unchanged.
PAYLOAD = bytes.fromhex(
    "0f 09"                 # wbinvd
    "66 0f 20 c0"           # mov eax,cr0
    "66 25 ff ff ff 9f"     # and eax,0x9fffffff (clear CD and NW only)
    "66 0f 22 c0"           # mov cr0,eax
    "e9 08 00"              # jmp POST_ENTRY
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fail(message: str) -> None:
    raise SystemExit(f"patch_boot0_cache_enable: {message}")


def patch_rom(original: bytes) -> bytes:
    if len(original) != ROM_SIZE:
        fail(f"expected a {ROM_SIZE}-byte ROM, got {len(original)} bytes")
    if sha256(original) != EXPECTED_INPUT_SHA256:
        fail("input hash is not the known deployed boot0.rom; refusing to patch")
    if original[RESET_VECTOR_OFFSET:RESET_VECTOR_OFFSET + len(RESET_VECTOR)] != RESET_VECTOR:
        fail("reset vector is not F000:E05B")
    if original[POST_ENTRY:POST_ENTRY + len(ORIGINAL_POST)] != ORIGINAL_POST:
        fail("POST entry no longer begins with the expected DMA-clear sequence")
    if any(original[TRAMPOLINE:POST_ENTRY]):
        fail("POST trampoline area is not the expected all-zero padding")
    if len(PAYLOAD) > POST_ENTRY - TRAMPOLINE:
        fail("trampoline payload does not fit in verified padding")

    patched = bytearray(original)
    patched[TRAMPOLINE:TRAMPOLINE + len(PAYLOAD)] = PAYLOAD
    patched[RESET_VECTOR_OFFSET:RESET_VECTOR_OFFSET + len(TRAMPOLINE_VECTOR)] = TRAMPOLINE_VECTOR
    patched[-1] = (-sum(patched[:-1])) & 0xFF  # BIOS checksum byte at 0xffff

    if sum(patched) & 0xFF:
        fail("internal checksum calculation failed")
    if patched[RESET_VECTOR_OFFSET:RESET_VECTOR_OFFSET + len(TRAMPOLINE_VECTOR)] != TRAMPOLINE_VECTOR:
        fail("internal reset-vector trampoline check failed")
    if patched[POST_ENTRY:POST_ENTRY + len(ORIGINAL_POST)] != ORIGINAL_POST:
        fail("internal POST-entry preservation check failed")
    if patched[TRAMPOLINE:TRAMPOLINE + len(PAYLOAD)] != PAYLOAD:
        fail("internal payload check failed")
    permitted = set(range(TRAMPOLINE, TRAMPOLINE + len(PAYLOAD)))
    permitted.update(range(RESET_VECTOR_OFFSET, RESET_VECTOR_OFFSET + len(TRAMPOLINE_VECTOR)))
    permitted.add(ROM_SIZE - 1)
    if any(before != after and index not in permitted
           for index, (before, after) in enumerate(zip(original, patched))):
        fail("internal scope check found a change outside the trampoline/vector/checksum")
    return bytes(patched)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="known deployed ao486 boot0.rom")
    parser.add_argument("output", type=Path, help="new cache-enabled 64 KiB ROM")
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve():
        fail("input and output must be distinct; preserve the known stock ROM")

    original = args.input.read_bytes()
    patched = patch_rom(original)
    args.output.write_bytes(patched)
    print(f"input_sha256={sha256(original)}")
    print(f"output_sha256={sha256(patched)} checksum8={sum(patched) & 0xFF:02x}")
    print("patched cold-reset trampoline: WBINVD; clear CR0.CD/NW; enter unmodified POST")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
