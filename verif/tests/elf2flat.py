#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""elf2flat.py -- extract the loadable bytes of a static i386 ELF into a flat
memory image for the Ventium Verilator testbench.

See docs/rtl-interface.md §4 (image loading): the testbench loads a raw binary
blob plus a load address from the test manifest. This helper produces that blob.

What it does
------------
Parses the ELF header and program headers (pure python3 stdlib -- no external
deps), then concatenates the bytes of every PT_LOAD segment into one flat blob
positioned so that:

    blob[ vaddr - base ] == the byte that the loader maps at virtual address
                            `vaddr`

where `base` defaults to the lowest p_vaddr among the PT_LOAD segments (so the
blob starts exactly at the first loadable virtual address = the manifest's
`load_addr`). Gaps between segments and the .bss tail (p_memsz > p_filesz) are
zero-filled, matching how a real loader presents the address space.

CLI
---
    elf2flat.py <elf> --out <blob> [--base 0xADDR] [--check-manifest <json>]

On success writes the blob to --out and prints the entry point and load (base)
address, both as canonical 32-bit hex (0x%08x), so callers / the Makefile can
cross-check them against `readelf -h` and the manifest.

With --check-manifest the tool also validates a test manifest.json against the
freshly-computed ELF facts (entry, load base) and against the bytes it just
wrote, exiting non-zero on any mismatch / missing key. This lets the Makefile
validate the manifest with the same code that produced the image (no second,
drifting parser).

Only 32-bit little-endian ELFs (ELFCLASS32 / ELFDATA2LSB), as produced by the
M0 smoke toolchain, are supported; anything else is a hard error.
"""
import argparse
import json
import os
import struct
import sys

# --- ELF constants -----------------------------------------------------------
ELFMAG = b"\x7fELF"
ELFCLASS32 = 1
ELFDATA2LSB = 1
PT_LOAD = 1


def _die(msg: str) -> "None":
    print(f"elf2flat: error: {msg}", file=sys.stderr)
    sys.exit(2)


def parse_elf32(data: bytes):
    """Return (entry, [(p_offset, p_vaddr, p_filesz, p_memsz), ...] for PT_LOAD).

    Hand-parses the 32-bit little-endian ELF header + program header table.
    """
    if len(data) < 52 or data[:4] != ELFMAG:
        _die("not an ELF file (bad magic)")
    ei_class, ei_data = data[4], data[5]
    if ei_class != ELFCLASS32:
        _die("not a 32-bit ELF (ELFCLASS32 required)")
    if ei_data != ELFDATA2LSB:
        _die("not little-endian (ELFDATA2LSB required)")

    # Elf32_Ehdr fields we need (little-endian):
    #   e_entry  @ 24 (Elf32_Addr, 4)
    #   e_phoff  @ 28 (Elf32_Off,  4)
    #   e_phentsize @ 42 (Half, 2)
    #   e_phnum     @ 44 (Half, 2)
    e_entry, e_phoff = struct.unpack_from("<II", data, 24)
    (e_phentsize,) = struct.unpack_from("<H", data, 42)
    (e_phnum,) = struct.unpack_from("<H", data, 44)
    if e_phoff == 0 or e_phnum == 0:
        _die("ELF has no program headers (not a loadable image)")
    if e_phentsize < 32:
        _die(f"unexpected e_phentsize {e_phentsize} (<32)")

    loads = []
    for i in range(e_phnum):
        base = e_phoff + i * e_phentsize
        if base + 32 > len(data):
            _die("program header table runs past end of file")
        # Elf32_Phdr: p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz,
        #             p_flags, p_align  (all 4-byte, little-endian)
        (p_type, p_offset, p_vaddr, _p_paddr,
         p_filesz, p_memsz, _p_flags, _p_align) = struct.unpack_from(
            "<IIIIIIII", data, base)
        if p_type == PT_LOAD and p_memsz > 0:
            loads.append((p_offset, p_vaddr, p_filesz, p_memsz))
    if not loads:
        _die("no PT_LOAD segments found")
    return e_entry, loads


def build_flat(data: bytes, loads, base: "int | None"):
    """Place every PT_LOAD segment into a flat blob starting at `base`.

    Returns (blob: bytearray, base: int). Gaps and .bss tails are zero-filled.

    `base` defaults to the lowest PT_LOAD vaddr. A caller may pass an *explicit*
    `base` (the manifest `load_addr`) that is HIGHER than some segment's vaddr:
    the M0 toolchain emits a small read-only segment for the ELF/program headers
    one page below the code segment (e.g. 0x08047000 vs the 0x08048000 text),
    and the bare-metal testbench only loads/executes from `load_addr` upward.
    Segments (or the parts of segments) below `base` are therefore clipped off;
    a segment entirely below `base` is skipped. Bytes at/above `base` are always
    kept, so requesting `--base <text vaddr>` yields exactly the code image.
    """
    lo = min(vaddr for (_off, vaddr, _fsz, _msz) in loads)
    if base is None:
        base = lo

    # End of the address span = highest (vaddr + memsz) over loadable bytes that
    # extend at/above `base`.
    hi = base
    for (_off, vaddr, _fsz, memsz) in loads:
        seg_end = vaddr + memsz
        if seg_end > hi:
            hi = seg_end
    size = max(0, hi - base)
    blob = bytearray(size)  # zero-initialised -> gaps & .bss come out as zero

    placed_any = False
    for (p_offset, p_vaddr, p_filesz, _p_memsz) in loads:
        if p_offset + p_filesz > len(data):
            _die("segment file range runs past end of file")
        seg_end = p_vaddr + p_filesz
        if seg_end <= base:
            # Whole file-backed range is below the requested base; skip it.
            continue
        # Clip the leading part of the segment that lies below `base`.
        skip = max(0, base - p_vaddr)
        src_lo = p_offset + skip
        src_hi = p_offset + p_filesz
        dst = (p_vaddr + skip) - base
        blob[dst:dst + (src_hi - src_lo)] = data[src_lo:src_hi]
        placed_any = True
        # bytes from p_filesz..p_memsz stay zero (already zero-initialised).

    if not placed_any:
        _die(f"--base {base:#x} is above every loadable segment "
             "(nothing to place)")
    return blob, base


_MANIFEST_KEYS = ("name", "src", "elf", "image",
                  "load_addr", "entry", "max_insn")


def check_manifest(path: str, entry: int, base: int, out_blob: str):
    """Validate a test manifest against computed ELF facts. Exit 1 on mismatch.

    Checks: all required keys present; manifest entry == ELF entry; manifest
    load_addr == the blob base we used; the referenced image file exists.
    """
    with open(path) as f:
        m = json.load(f)
    errs = []
    for k in _MANIFEST_KEYS:
        if k not in m:
            errs.append(f"missing required key {k!r}")
    if "entry" in m and int(str(m["entry"]), 0) != entry:
        errs.append(f"entry {m['entry']} != ELF entry 0x{entry:08x}")
    if "load_addr" in m and int(str(m["load_addr"]), 0) != base:
        errs.append(f"load_addr {m['load_addr']} != image base 0x{base:08x}")
    if "image" in m:
        # Resolve image relative to the manifest dir as well as as-given.
        cand = [m["image"],
                os.path.join(os.path.dirname(path) or ".", m["image"]),
                os.path.join(os.path.dirname(path) or ".",
                             os.path.basename(m["image"])),
                out_blob]
        if not any(os.path.isfile(c) for c in cand):
            errs.append(f"image {m['image']!r} not found")
    if "max_insn" in m and not (isinstance(m["max_insn"], int)
                                and m["max_insn"] > 0):
        errs.append(f"max_insn {m['max_insn']!r} is not a positive int")
    if errs:
        print(f"elf2flat: manifest {path} INVALID:", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)
    print(f"manifest_ok={path} "
          f"(entry={m['entry']} load_addr={m['load_addr']} "
          f"max_insn={m['max_insn']})")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Flatten a static i386 ELF's PT_LOAD bytes into a raw blob.")
    ap.add_argument("elf", help="input static ELF")
    ap.add_argument("--out", required=True, help="output flat blob path")
    ap.add_argument("--base", default=None,
                    help="load base address (hex/dec); default = lowest "
                         "loadable vaddr")
    ap.add_argument("--check-manifest", default=None, metavar="JSON",
                    help="validate this manifest.json against the built ELF")
    args = ap.parse_args(argv)

    base = None
    if args.base is not None:
        base = int(args.base, 0)

    with open(args.elf, "rb") as f:
        data = f.read()

    entry, loads = parse_elf32(data)
    blob, base = build_flat(data, loads, base)

    with open(args.out, "wb") as f:
        f.write(blob)

    # Report canonical 32-bit hex so the Makefile / TB can cross-check.
    print(f"entry=0x{entry:08x}")
    print(f"load_addr=0x{base:08x}")
    print(f"image={args.out} ({len(blob)} bytes)")

    if args.check_manifest:
        check_manifest(args.check_manifest, entry, base, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
