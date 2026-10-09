# CoreMark backend diagnostic — October 9

This is **not a new CoreMark score, standard-suite pass or FPGA measurement**.
Latest verified gameplay is **0.44004644 total U+V IPC**, read-prime model
`15f56054`, clocks **1,200,012,763–1,300,012,763**, predating combined FP work.
Complete direct-memory CoreMark results remain **2.107861982/2.110913372
CM/MHz** on REP model `cb4b2f84`, not the current candidate or board memory path.

## Corrected fixture and standalone store-policy driver

Two independent test-configuration problems were isolated without changing RTL:

1. The old Linux-user stack is above the ordinary chipset DRAM aperture.
   `prepare-coremark-lowram.py` uses pinned QEMU's normal `-R 0x10000000` loader
   reservation to produce new **entry** images. ELF SHA256 remains
   `8d8b84ad407b1ec35344415084fa4b77afa9dfd2b6369e1677345816ee2c7dbe`.
   No saved gameplay state, image-byte relocation, benchmark change or
   high-memory cacheability exception is used. Both native QEMU CRC sets pass;
   the captured stack is `0x05d55460`, and every captured byte is below 256 MiB.
2. The standalone C++ AXI slave did not drive the optional U/V cached-store
   update masks. Verilator initialized both to **zero**, so ordinary accepted
   RAM stores invalidated their resident lines. `bfm_store_policy.h` now drives
   both from the actual flat `MemModel` backing contract, per byte, including
   optional RAM-top, ROM-read-overlay and address-fold behavior. It changes no
   bus writes, cacheability, clock or RTL. The full-PC ao486 shim already drives
   these ports: this is **not** an FPGA/Quake performance fix.

Matched 10-iteration observations; every row completes with both expected CRC
sets, genuine V retirement, zero canonical fault deliveries and native exit0:

| Fixture/host driver/backend | Performance clocks | Validation clocks |
| --- | ---: | ---: |
| Old high stack, old host, direct | 4,821,654 | 4,814,941 |
| Old high stack, old host, AXI0 | 8,144,607 | 8,114,923 |
| New low-RAM entry, old host, direct | 4,821,818 | 4,815,105 |
| New low-RAM entry, old host, AXI0 | 8,459,889 | 8,432,607 |
| Same low-RAM entry, corrected host, direct | 4,821,818 | 4,815,105 |
| Same low-RAM entry, corrected host, AXI0 | **5,482,773** | **5,474,040** |

The host correction saves **35.191%** of performance-seed diagnostic clocks
(**54.299%** higher cycle-derived throughput), not processor cycles on FPGA.
Demand line-fill starts fall **183,566→6,511**; pipeline D-wait falls
**3,067,780→458,724**. Both low-RAM AXI runs have **zero bypass starts**.
Direct-memory clocks and instruction counts are identical across the host fix.
All unchanged low-RAM images and generated RTL archives are pinned. The parent
native is `3f637315…`; corrected host/native is
`03bc76515aa2cf2b90ba610ab36997e88e8c6a69f4ea14f2e49c768e1f0c2379`.

Roots: `ventium-combined-coremark-backend.GR8rLvEA/r2`,
`ventium-coremark-lowram.WReRaqoo`, and
`ventium-bfm-store-policy.9p8ilO1M/coremark-r1` under `external/tmp`.
The last AXI ratios are **1.823895/1.826804 CM/MHz**, still **short diagnostics**:
the sole benchmark error is its insufficient-duration notice. No score-eligible
or standard-suite pass is claimed. The ideal AXI BFM retains line replay and
does not include the full-PC L2/DDR bridge or physical DDR.

Regression: `bash verif/tb/run-bfm-store-policy-unit.sh` checks absent/U/UV
ports, independent masks, fold/32-bit wrap, RAM-top and ROM boundaries.
`run-bfm-store-policy.py --control OLD --candidate NEW --out FRESH` passes
**24 complete QEMU-state comparisons and 24 UV-cycle executions**, offsets
0/1/2/3/28/30 and AXI latency0/7. No records or fields are dropped. Six fixture
variants retain all 1,195 retirements; aligned AXI0 whole-program clocks improve
7,106→2,377. The initial grader wrongly expected a literal `PASS` string and
is retained as failed; R2 verifies the actual success-register sentinel,
normal quiescence and entire QEMU trace instead. Eight low-RAM image-boundary
negative controls also pass. These do not replace the generic or standard suite.

The corrected-host generic run still closes **FAIL**, native exit2: seven
functional passes, 101 terminal-length mismatches and the same four hard
cycle-band failures. Fresh parent executions using the exact candidate ELF,
stack and backend match **all 108 complete architectural record sequences**.
This establishes host-change nonregression, not a passing differential gate;
no terminal records, state fields or cycle bands were changed. Receipts:
`ventium-bfm-store-policy.9p8ilO1M/generic-closed.json` and
`generic-parent-matched/closed.json`.

The latest diagnostic separates stdout/stderr and checks the canonical
`+ven_faultlog` delivery records with `check_faultlog.py`. It does not mistake
the legacy reset-time stderr PC observer for an exception. The failed earlier
receipts below remain failed; no old result was rewritten.

## Earlier word-reuse observations (historical)

Root: `external/tmp/ventium-word-axi-coremark.gAtcHGt0`.
`run_r2.py` uses the already-built full-address user top `9194e7e3` and unchanged
10-iteration standard-seed entry images. All six natives exit zero with the
expected five CRCs, identical instruction counts per seed, genuine V retirements
and reconciled exclusive clock counters. Commands, source/header pins, native
identities and 300-second bounds are retained. No source, guest or clock is changed.

| Backend | Performance clocks | Validation clocks |
| --- | ---: | ---: |
| Direct memory | 4,823,423 | 4,816,710 |
| Explicit `--l1-axi`, zero added latency | 8,146,177 | 8,116,492 |
| Explicit `--l1-axi`, `AXI_RLAT=AXI_WLAT=7` | 21,751,710 | 21,640,677 |

The BFM's `AXI_RLAT=7` is applied between read beats too; this is **not** a
seven-clock DDR first-response-only model. The actual read-handshake counters
prove the selected backend is active. Neither run includes the platform L2,
posted16 bridge, HP0 clock/width converters or physical DDR.

## Why these are not hardware-cache performance numbers

The Linux entry image places its stack near `0x407ffxxx`, above the chipset's
encodable top of DRAM. In the ordinary full-address top, that physical address
is correctly classified as **uncacheable region 6**. The performance seed has
313,891 bypass starts and 2,104,740 uncacheable-type wait clocks at zero added
AXI latency. These counters overlap other wait buckets and must not be summed
as independent losses. The total direct/AXI difference cannot be labelled
ordinary cache-miss overhead or projected onto low-physical-memory DOS Quake.

The board top is unsuitable for this particular identity-addressed fixture too:
its 256 MiB physical mask would fold the high stack. The diagnostic therefore
uses the full-address user top, not the board model. It does **not** enable the
simulation-only `VEN_SNAPSHOT_RESTORE` high-memory cacheability exception.
Meaningful board/cache CoreMark measurements require normal page-table mappings
into real DRAM or a properly booted low-physical-memory benchmark. Do not change
PCI/MMIO cacheability or benchmark data to manufacture a better score.

This user top also retains the conservative line replay policy: 85,448 demand
misses correspond to 170,896 line AR handshakes. `VEN_AO486_SINGLE_FILL` only
selects the policy at the full-PC shim; it does not override `ventium_top`'s
default parameter. The existing HP0 workaround cannot safely be removed based
on an ideal BFM passing.

## Fail-closed status

The diagnostic runner closes **FAIL/unqualified**, not PASS. Its old host logger
prints a reset-time `FAULT` when `prev_fpc=0xffffffff` first observes zero; this
is a PC-change heuristic, not an actual exception-delivery counter. The source
and raw line are retained, and the error predicate is not relaxed to accept it.
Later board/direct CoreMark harnesses already use the explicit delivery counter;
this user binary does not. The short benchmark also explicitly reports its
insufficient duration, so CRC correctness does not make it score-eligible.

The first launcher failed before starting any native because it expected an
optional host-elision header inventory. R2 explicitly pins this non-elision
model's generated headers. Its final source pins remain stable, with zero OOM
events and every native reaped. These observations locate a test configuration
limitation; they do not establish the 2.1 CM/MHz hardware target.
