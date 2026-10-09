# CoreMark backend diagnostic — October 9

This is **not a new CoreMark score, standard-suite pass or FPGA measurement**.
Verified gameplay remains **0.38588696 total U+V IPC**, XPM-fidelity model
`50f37229`, cycles **1.2B–1.3B**, predating pop-drain/word reuse.
Earlier complete direct-memory CoreMark results remain **2.10736/2.11041
CM/MHz** on model `e3dbf68a`, not the current candidate or board memory path.

## Matched short observations

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
