# L1 / ao486 ignored-ROM-write regression

This guest-independent fixture connects production `ventium_l1_axi` (L1 and
AXI master), `ven_axi2avalon`, and the actual ao486 `l2_cache` to a bounded,
byte-strobed DDR model. It does not inject CPU opcodes, alter page mappings,
restore snapshots, or patch cached data.

An acknowledged ROM store that the backend ignores must not leave a modified
resident L1 copy. `VEN_L1D_STORE_POLICY` controls only cached-copy updates and
targeted invalidation, not backing strobes, acknowledgements or paired-store
admission. Writable UMA/shared windows must still receive their original
writes and refill from the authoritative backend.

## Reproduction

Run from the repository root:

```sh
# Default feature-on gate: packed, banked and paired-banked must pass.
bash verif/l1/run-l1axi-ao486-romwrite-gate.sh

# Feature off: actual ROM-value failures required, with RAM controls green.
EXPECT_RED=1 STORE_POLICY=0 \
  ROMWRITE_SOURCE_ROOT=/tmp/ventium-l1axi-ao486-romwrite.Vxr4Q9/src \
  bash verif/l1/run-l1axi-ao486-romwrite-gate.sh
```

`ROMWRITE_SOURCE_ROOT=/absolute/source-snapshot` selects immutable production
sources for a pre-fix control. Each invocation uses the serialized build scope,
one compiler, a 540-second aggregate deadline and 30 seconds per DUT. Sources,
exact defines, logs and binary hashes are retained under the validated,
non-symlink root-filesystem scratch directory
`verif/l1/obj_dir_store_policy_scratch/`. New builds avoid the full external
`tmp/build-tmp` volume and quota-limited `/tmp`.

## Coverage

All profiles enable real CODE_BUFFER, read-window and shadow-window paths.
All 16 write strobes at offsets 0, 1, 2, 3, 29, 30 and 31 cover byte/word/dword,
sparse, zero-strobe, unaligned and cross-line stores.

- Ignored C/F ROM writes preserve DDR and immediate D/code reads, including
  after bus drain, code-buffer replacement and flush/refill.
- UMA off/on and an older queued shared-folder enable preserve backing-write
  order under independent AW, W and B stalls.
- Ordinary RAM remains coherent without extra AR on prewarmed within-line
  stores. ROM invalidation preserves the other tag in the same L1 set.
- Inactive policy bits/zero strobes do not invalidate RAM. Active-zero masks
  still send writable RAM stores; mixed-mask cross-line and physical ROM/RAM
  boundary stores retain exact backing strobes.
- Real atomic U/V stores cover ROM/RAM in both orders, both ROM/both RAM,
  V ROM misses, writable UMA/shared windows and independent U/V masks.

Structural IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/LATCH/UNOPTFLAT warnings
remain errors. The `.vlt` waiver covers only omitted optional pins at three
existing Intel primitive instantiations in the vendor ao486 cache.

## Verified receipts: 2026-09-30

Clean pre-fix RED: `/tmp/ventium-l1axi-ao486-romwrite.Vxr4Q9`. Packed and banked
each reported 20,742 checks, 907 ROM-value mismatches and zero RAM errors.
Compiler failures/timeouts are not RED evidence. Its historical runner digest
was recorded but the script copy was not retained; the summary marks that
provenance gap. The earlier `Um5COH` receipt is unqualified because it lacked a
shadow-window warm-up witness.

Final GREEN:
`verif/l1/obj_dir_store_policy_scratch/ventium-l1axi-ao486-romwrite.vhhQql`.
Packed and banked each passed 20,948 checks; paired-banked passed 21,216,
including 18 atomic U/V pairs. Every profile reported zero errors, 128
no-extra-AR RAM witnesses, two no-global-flush witnesses and ten byte-policy
controls. All frozen GREEN inputs are verified in its `summary.json`:

The later runner default/setup change was checked with `bash -n` and all three
cached executables: every result count matched exactly, without recompilation.
All three frozen profiles also passed lint-only after removing DECLFILENAME
and INITIALDLY suppressions. Their warnings remain visible; the six structural
classes remain errors. The summary separates these checks and the current
runner from the frozen executed script; no final-flags C++ rebuild is claimed.

```sh
python3 -B verif/l1/summarize_l1axi_ao486_romwrite.py \
  --green verif/l1/obj_dir_store_policy_scratch/ventium-l1axi-ao486-romwrite.vhhQql \
  --red /tmp/ventium-l1axi-ao486-romwrite.Vxr4Q9 \
  --out verif/l1/obj_dir_store_policy_scratch/ventium-l1axi-ao486-romwrite.vhhQql/summary.json
```

This focused contract gate is not the standard suite or an exhaustive
32-offset/full-core/paired-load/MMIO test. Windows desktop, Quake timedemo,
CoreMark correctness and FPGA timing require separate acceptance.

Latest verified gameplay IPC is 0.42089513 on immutable build b7, cycles
3.0B–3.1B. It predates this store-policy candidate, which is not yet measured.
