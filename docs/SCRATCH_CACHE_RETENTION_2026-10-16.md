# Closed compiler-cache cleanup — 2026-10-16

Recovered **4,892,780,300 bytes (4.56 GiB)** without deleting any source,
accepted executable, log, disk image, snapshot, or trace path. This restored
the 10 GiB admission reserve before the parallel-write whole-core build.

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

- `trace-dedup-apply-r1.json` and `.complete.json`: 4,970 byte-identical closed
  `.vtrace` files now share hard-linked storage, recovering 2,081,980,416 bytes.
  Every path and hash is preserved. Shared trace artifacts are read-only to
  prevent an accidental append from corrupting another historical run.
- `pch-prune-r1/closed.json`: 252 generated Verilator precompiled-header (`.gch`)
  cache members removed from 111 reviewed compiler archives, recovering
  2,810,799,884 bytes. Every **non-PCH** archive member, payload and tar metadata
  was independently hashed/compared before replacement. Sources, generated C++,
  objects, libraries, headers and executables are retained.

PCH bytes are discarded, not archived elsewhere. They are regenerable compiler
caches. **The original compressed archive SHA-256 values therefore no longer
apply** to these 111 archives. Each `pch-prune-r1/*-replacement.json` records the
old/new archive hashes, discarded member hashes and complete retained inventory.
Existing extraction commands still recover all retained members; a subsequent
build may regenerate its PCH. Do not mistake these cache changes for source or
functional-evidence drift, or claim original-archive byte identity.

Protected input-pin closures from the RAW FPGA/core, qualified-credit FPGA and
parallel-write native audit were excluded from archive replacement. The latter
native audit was rechecked after cleanup and remains stable. No entire run
directory was removed, and no broad home/workspace cleanup was performed.

The successful read-only inventory was `pch-inventory-r2` (220 archives). The
first attempt failed because the service PATH lacked `rg`; a wider read-only
`pch-inventory-r3` failed its decompressor completion check. Neither modified
archives. Only the complete r2 inventory authorized pruning. The stream reader
now drains compression padding through EOF so zstd can validate its checksum.

Prune owner: `ventium-pch-prune-oct16-r1.service`, invocation
`3a49c3b2a3f54b68bf7fd1b8502fe909`; closed exit 0, MainPID 0. Its guarded child
reported 275.9 MiB peak memory. Three cleanup-helper unit tests pass.

Tools: `tools/prune_archived_pch.py` requires a separately inspected dry-run
plan before applying; `tools/dedup_closed_traces.py` requires closed receipts,
old regular trace files, matching bytes and no open writer. Never use either
on mutable guest disks or active traces.
