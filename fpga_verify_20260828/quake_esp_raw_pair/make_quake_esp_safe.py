#!/usr/bin/env python3
"""Build a hash-locked, disposable Quake workaround for the ESP U/V bug.

This deliberately changes only six statically identified Quake stack-allocation
sites.  Each redirected sequence runs the ESP writer and its consumer in a
small zero-filled code cave with a CS-prefix barrier on the consumer.  The
prefix is semantically inert for a register MOV but sends it through Ventium's
slow decoder, so it cannot be the V member that reads the writer's old ESP.

It is a diagnostic bridge to prove FPGA timedemo progress while the general
RTL pairer repair is being validated.  It is not a replacement for that repair.
"""

from __future__ import annotations

import hashlib
import pathlib
import struct
import sys


# Each profile has the same six untouched code contexts below.  Restricting the
# accepted inputs makes it safe to compose this diagnostic patch with the
# previously QEMU-proven accelerated timedemo image without accepting an
# arbitrary retail executable.
SOURCE_PROFILES = {
    "5288124fdc6b950000d2d4244e49603ec04671418ded296faa816a1a1f6bfc1f": "retail baseline",
    "71985ca618021a90172723c563fb30c3a7a79d4880271fe513b1bc46b7462943": (
        "fasttick + no-render + heapscan + logger-return marker"
    ),
}
RUNTIME_BIAS = 0x800  # DJGPP COFF image: runtime EIP = absolute file offset + 0x800
CAVE_FILE = 0x4CF64
CAVE_SIZE = 102


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rel32(source_next: int, target: int) -> bytes:
    delta = target - source_next
    if not -(1 << 31) <= delta < (1 << 31):
        raise ValueError(f"relative jump out of range: {source_next:#x} -> {target:#x}")
    return struct.pack("<i", delta)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} ORIGINAL.EXE PATCHED.EXE", file=sys.stderr)
        return 2

    source = pathlib.Path(sys.argv[1])
    output = pathlib.Path(sys.argv[2])
    original = source.read_bytes()
    source_sha256 = sha256(original)
    if source_sha256 not in SOURCE_PROFILES:
        raise SystemExit(
            f"refusing unexpected input: sha256={source_sha256}; "
            f"accepted={', '.join(SOURCE_PROFILES)}"
        )
    if original[CAVE_FILE:CAVE_FILE + CAVE_SIZE] != bytes(CAVE_SIZE):
        raise SystemExit("refusing non-empty Quake code cave")

    # file offset, exact ESP writer, exact consumer MOV, replayed bytes after
    # the MOV.  The first wide immediate-SUB site returns to its untouched MOV;
    # the other sites replay the MOV under an inert CS prefix.
    sites = (
        (0x2D8C5, bytes.fromhex("81 ec 60 80 00 00"), bytes.fromhex("89 e0"), b"", False),
        (0x445AE, bytes.fromhex("83 ec 30"),          bytes.fromhex("89 e0"), b"", True),
        (0x4CB43, bytes.fromhex("29 c4"),             bytes.fromhex("89 e7"), bytes.fromhex("31 f6"), True),
        (0x4F05F, bytes.fromhex("29 c4"),             bytes.fromhex("89 e6"), bytes.fromhex("31 db"), True),
        (0x4F60C, bytes.fromhex("29 c4"),             bytes.fromhex("89 e3"), bytes.fromhex("89 ca"), True),
        (0x4F674, bytes.fromhex("29 c4"),             bytes.fromhex("89 e7"), bytes.fromhex("31 c9"), True),
    )

    result = bytearray(original)
    cave = bytearray()
    audit: list[str] = []
    for file_offset, writer, consumer, tail, replay_consumer in sites:
        span = writer + (consumer + tail if replay_consumer else b"")
        if original[file_offset:file_offset + len(span)] != span:
            raise SystemExit(f"refusing unexpected context at file {file_offset:#x}")
        if len(span) < 5:
            raise AssertionError("redirection span must hold JMP rel32")

        site_runtime = file_offset + RUNTIME_BIAS
        cave_runtime = CAVE_FILE + RUNTIME_BIAS + len(cave)
        replacement = b"\xe9" + rel32(site_runtime + 5, cave_runtime)
        replacement += b"\x90" * (len(span) - len(replacement))
        result[file_offset:file_offset + len(span)] = replacement

        # The original wide SUB is redirected only through the writer.  Its MOV
        # stays at the old address but is separated by a taken jump.  All other
        # sites replay the MOV with an inert CS prefix, which forces slow issue.
        body = bytearray(writer)
        if replay_consumer:
            body += b"\x2e" + consumer + tail
            continuation = site_runtime + len(span)
        else:
            continuation = site_runtime + len(writer)
        body += b"\xe9" + rel32(cave_runtime + len(body) + 5, continuation)
        cave += body
        audit.append(
            f"file={file_offset:05x} runtime={site_runtime:08x} "
            f"cave={cave_runtime:08x} resume={continuation:08x}"
        )

    if len(cave) > CAVE_SIZE:
        raise AssertionError(f"code cave overflow: {len(cave)} > {CAVE_SIZE}")
    result[CAVE_FILE:CAVE_FILE + CAVE_SIZE] = cave + b"\x90" * (CAVE_SIZE - len(cave))
    output.write_bytes(result)
    print(f"patched {source} -> {output}")
    print(
        f"sha256 {source_sha256} ({SOURCE_PROFILES[source_sha256]}) -> "
        f"{sha256(result)}; cave={len(cave)}/{CAVE_SIZE} bytes"
    )
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
