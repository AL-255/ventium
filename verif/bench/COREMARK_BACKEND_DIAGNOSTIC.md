# CoreMark backend diagnostic — October 9

This is **not a new CoreMark score, standard-suite pass or FPGA measurement**.
Latest verified gameplay is **0.49083588 total U+V IPC**, repaired-L2 model
`86731249`, clocks **1,200,000,000–1,300,000,000**. The pending x87 repairs
have no gameplay measurement. Complete direct-memory CoreMark results are
**2.107843209/2.110905243 CM/MHz** on `b5453f16`, not a board-memory score.

## Current-model repeat and exact backend delta — October 10

The actual full-CoreMark binary `b5453f16` repeats the short diagnostic on
the unchanged low-RAM ordinary entry images below. All four runs close with
native exit0, all five CRCs correct, real V retirement, no canonical delivered
fault, unchanged226 input pins, zero OOM and every child reaped. The supervisor
also closes successfully. These are **10-iteration, insufficient-duration
diagnostics**, not valid CoreMark scores. Neither AXI case uses bypass starts.

| Seed | Direct clocks | AXI0 clocks | AXI0 diagnostic CM/MHz |
| --- | ---: | ---: | ---: |
| Performance | 4,821,818 | 5,241,779 | 1.907749258 |
| Validation | 4,815,105 | 5,235,258 | 1.910125537 |

Performance executes exactly3,661,024 instructions on both backends; validation
executes3,656,168. The repeat reproduces the prior WBUF-admission model's
clocks exactly. The full host optimization contributes **zero guest clocks**.
This model contains WBUF admission; the gameplay/FPGA export does not. The
standalone AXI model still lacks platform L2, posted16 transport and physical
DDR, and retains its existing line-replay policy. Do not transfer these ratios
to the full-PC or FPGA model.

The performance-seed difference is **419,961 clocks**. Replacing the aggregate
S_PIPE row with its exclusive first-arm counters gives this complete signed
accounting; no clocks are counted twice:

| Exclusive residency change (AXI minus direct) | Clocks | Share of net gap |
| --- | ---: | ---: |
| S_PIPE D-result wait | +325,523 | +77.5127% |
| S_FETCH | +57,262 | +13.6351% |
| S_LOAD | +31,396 | +7.4759% |
| S_PIPE instruction bytes absent | +30,669 | +7.3028% |
| S_PIPE address-generation interlock | +10,284 | +2.4488% |
| S_STORE | +1,040 | +0.2476% |
| S_PIPE ISSUE | −36,361 | −8.6582% |
| Remaining states/arms together | +148 | +0.0352% |
| **Total** | **+419,961** | **100% (rounding)** |

D-result waiting splits220,840 load/104,683 store clocks. These are residency
deltas, **not causal savings or cache-miss percentages**. Changed pairing and
admission opportunities explain why positive waiting buckets can exceed the
net gap. All unchanged rows, including1,324,018 S_EXEC clocks and88,785 prefix
clocks, contribute zero. The raw full state and pipe totals each reconcile.

The132,220 slow memory-EXT acknowledgements are a large population, but simply
turning on the old `VEN_FAST_MEM_EXT` switch is not an acceptable optimization.
Its original leaf/hot tests use an NP two-clock occupancy model; the current
P54 profile deliberately requires the documented three execution clocks plus
the opcode-prefix clock. See the AP-500 finding in
[the cycle survey](../../docs/P54_COREMARK_CYCLE_SURVEY_2026-09-29.md), and the
explicit exclusion in `ao486-sim/Makefile`. Preserve that timing contract and
complete the outstanding ownership/event tests before using the old experiment.
No define, timing band, golden or production RTL changed in this diagnostic.

Receipts: `external/tmp/ventium-current-coremark-host-r2.3ixLJTn1/`
`backend-diag-oct10-r2/{plan.json,closed.json}`; closed SHA256
`9c4a73a9f275032d4f7501eebd13a778f5902be57c6a50d7ebd5765a366eca50`.
Invocation `8b9336814dbb428db08b9f1566267ea2`, explicit CPUs2/3,
2GiB RAM/zero swap,420-second outer cap; actual whole diagnostic62.2seconds.
The preceding r1 supervisor failed before launching a native: `AllowedCPUs`
alone did not constrain `sched_getaffinity` on this host. R2 explicitly uses
`taskset`; the failed first admission remains recorded, not overwritten.

### Every retirement matched; the largest instruction sites

A second observation on the unchanged `b5453f16` executes the performance
seed on both backends with native cycle tracing enabled. **All 3,661,024
sequence numbers and PCs match**, both runs reproduce the earlier clock totals
exactly, both guest outputs/CRCs are byte-identical to their baselines, actual
fault deliveries remain zero and both have real V retirements. Inputs remain
pinned and both children/supervisor close normally. This is still a short,
insufficient-duration diagnostic, not a score or architectural-state oracle.

The collector attributes each interval to the instruction retiring at its end.
Intervals sum to 4,821,804 direct / 5,241,738 AXI clocks; unretired final tails
are 14 / 41 clocks. Thus **419,934 + 27 = 419,961** extra clocks are accounted
for. These are **signed retirement-interval attributions**, not causal savings:
pairing changes and preceding stalls can shift cost between instructions.

| Retiring instruction class | Extra interval clocks |
| --- | ---: |
| MOV | +152,286 |
| PUSH | +105,682 |
| RET | +47,909 |
| POP | +42,430 |
| All other instructions, including outside-ELF runtime code | +71,627 |
| Unretired final tail | +27 |
| **Total** | **+419,961** |

The first four classes account for **82.94%** of the net gap under this
attribution. `core_state_transition` contributes 154,013 interval clocks;
`core_bench_list` 62,759; `crc16` 43,186. Every disassembled instruction byte
was checked against the unchanged ordinary-entry image, including encodings
that cross image-region boundaries. The 35 retirements outside the ELF remain
explicitly classified, not omitted or assigned invented instructions.

Specific targets:

- Four consecutive pushes at `0804ad11..0804ad14` execute 10,240 times each.
  Each costs approximately three clocks with AXI instead of one with direct
  memory; together they account for **81,915** extra interval clocks. Inspect
  ordinary stack-store admission and the two-entry write-buffer return path;
  do not enlarge the architectural buffers or discard ordering requirements.
- `crc16`'s RET at `0804b3f4` contributes **41,630** extra clocks across 1,344
  executions. The source still demands a complete 16-byte slow-decode window
  for this one-byte near return. A
  [private exact-byte capture proposal](../fe_pipe/RET_SHORT_WINDOW.md) retains
  ordinary decode/stack/target checks; measured savings are not yet established.
- List loads at `0804a7e6` and `0804a972`, both `MOV 4(EAX),EDX`, contribute
  **48,887** extra clocks together. These are read-owner/lookahead candidates,
  not evidence that every interval is a cache miss.

The short scored service-to-service windows are 4,746,008 direct / 5,105,915
AXI clocks, corresponding to diagnostic ratios 2.10703 / 1.95851. Do not mix
those with the table's conservative whole-program ratios 2.07391 / 1.90775,
or present either short ratio as a valid full score. About 60,054 clocks of
the whole-program backend difference occur outside that service window.

Receipts: `external/tmp/ventium-coremark-cycle-diff.XqqsWNnn/`
`r1/{started.json,closed.json,symbols.json}`; invocation
`f104cffd0fa9436fbb9d107606e3ba8f`. Two FIFO streams retain exact native traces
as gzip without intermediate uncompressed files: about **61.6 MiB** combined.
Actual elapsed time is 34.46 seconds under a 768 MiB/zero-swap/360-second bound,
with native CPUs 2/3 and collector affinity 2–4. No model build, production RTL,
guest code, clock policy, comparison mask or timing band changes.

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
