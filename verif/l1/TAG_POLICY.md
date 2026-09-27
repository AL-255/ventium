# Tag-qualified stores — normal L1 policy

Tag-qualified, ACK-qualified mutation is now the normal `ven_l1d.sv` policy;
`VEN_L1D_TAG_INVALIDATE` is a compatibility define with no remaining behavior
change. It fixes the measured unrelated-tag evictions while preserving the full
P5 8 KiB / 2-way cache geometry.

- Store hit: update matching bytes in place; invalidate the other way only if
  it duplicates the same physical tag.
- Store miss / crossing store: invalidate only matching touched physical tags.
  Do not allocate or discard unrelated lines.
- Mutate the cache only when the store is accepted (`c_ack`); held then withdrawn
  stores no longer leave speculative cached data.
- External snoop/flush precedence, fill poisoning and the ordered AXI write
  buffers are unchanged. Unrelated CPU stores cannot fix a missing DMA snoop.

## Verified so far

- `bash verif/l1/run-l1d-tag-policy-gate.sh`: PASS with/without window reuse,
  including a no-define build of the normal policy.
  All 32 offsets × 15 nonempty byte masks, crossing stores, unrelated-way
  residency, accepted write-through, blocked/cancelled stores and simultaneous
  accepted-hit/snoop precedence. Existing 16-case transactional-invalidation
  tests pass in both configurations.
- Real L1/AXI integration with tag policy + window reuse: PASS, including
  store-miss→dependent-load visibility and remapping. Two-entry P5 write-buffer
  capacity/response-drain gate: PASS. Original baseline pollution counts remain
  8/16/16 backing dwords under the default policy; candidate requires 0/0/0.
- Promoted normal-policy source: `make verify` PASS (105 pinned-QEMU functional
  programs and M4/M5 metric bands), `make verify-sys` PASS, `make lint` PASS,
  `run-l1axi-gate.sh` PASS, and `run-l1d-gate.sh` PASS. These checks exercise
  the source after the default-policy change; they are not a full-PC boot.
- Candidate full-core L1/AXI build `obj_dir_sep14_tag_policy`: FP/integer overlap,
  deferred #NM/#MF and the FADD memory-fault regression all PASS. Logs:
  `tmp/build-tmp/sep14_tag_core_qualification/`.

Leaf/integration logs: `ventium-l1d-tag-policy.qfljup`,
`ventium-tag-qualification.cwSZh0`, and `sep14_tag_directed_final.log`, all under
`tmp/build-tmp/`. The final directed run corrects the snoop fixture to assert
the snoop and accepted store on the **same** resident-hit edge.

## Matched-start gameplay evidence

Baseline: `ventium-state-delta.ee463166`; candidate:
`ventium-state-delta.uz7nzvef`, both under `tmp/build-tmp/`. Each contains a full
million-cycle differential internal-state trace, with exact reconstruction and
recorder OFF/ON native-state/disk equivalence checked.

| Measurement | Baseline | Tag policy |
|---|---:|---:|
| Retirements per 1M cycles / IPC | 439,604 / 0.439604 | 479,578 / 0.479578 |
| Nonmatching line drops during stores | 5,482 | 0 |
| Total valid→invalid transitions | 5,485 | 3 |
| L1 miss starts | 7,448 | 4,505 |
| L1 fill residency | 255,892 | 176,524 |
| PIPE load-wait classification | 280,188 | 231,435 |

Fixed-cycle retirement throughput is +9.09%. Stronger equal-work evidence:
308,590 instructions have identical PC order and 239,534 common integer/segment
commit-boundary snapshots match with **no flag masking or resynchronization**.
That prefix takes 647,963 baseline clocks versus 596,243 candidate clocks:
1.08674× speed, or 7.98% fewer clocks.

The raw comparison then reports `DIVERGED_INTEGER_STATE` at ordinal 402807136,
PC `3e458`; it is NOT relabeled a full-run pass. The complete traces show IRQ0
rising at 1,300,647,959 in BOTH models and `intr_take` at 1,300,647,962. The slower
baseline enters vector 136 at `3e458`; the faster candidate has reached `1111c`
and enters at `1111e`. Thus the first differing snapshot is the baseline's IRQ
stack/segment/IF transition. The timer was not disabled or moved for the test.
The diagnostic compares integer/segment state, not deferred x87 or all memory.

## Snapshot use is measurement tooling, not a processor fix

The new elaboration retains two previously inlined **combinational** wires,
`hit0` and `hit_n0`; its native serialized layout is therefore two bytes longer.
`tools/migrate_l1d_tag_checkpoint.py` supports only this exact conversion. It
checks all RTL/filelists/defines differ solely by the cache policy, and the
entire root serializer is identical except those wires and its layout checksum.
All 12,731 old serialized fields must match the recorded baseline verbatim.
The two bits are calculated from the saved physical address, valid bits and tags.
Reversing the conversion must reproduce the entire old file byte-for-byte.
No register, cache line, memory byte, device state or counter is repaired/reset.

Converted bundle: `tmp/build-tmp/ventium-tag-migration.uY4ymJ/bundle`.
`migration.json` records provenance; `gameplay.sha256` pins binary, ROMs, snapshot
and disk. Later source/define validation hardening can be rerun with
`--validate-only`. Conversion is independent of guest addresses/software.

## Integrated acceptance still required

- Further candidate system/REP/cache race regressions, and cold boot through
  Quake timedemo completion and a real Windows95 desktop. Neither a migrated
  snapshot nor the short matched prefix establishes those acceptance results.
- Investigate remaining read-hit/fill latency and FP/frontend serialization.
  0.479578 IPC is still well below the >1 IPC objective.
- Hardware timing/area qualification when a new FPGA run is warranted; no FPGA
  synthesis or implementation was launched for this experiment.
