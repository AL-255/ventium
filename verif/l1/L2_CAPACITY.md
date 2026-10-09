# Platform L2 capacity qualification — October 9

Experimental **256 KiB platform L2**, not a change to the P54C split 8 KiB
L1 caches. Latest verified gameplay is **0.43894030 total U+V IPC**, model
`e9097d96`, clocks **1,200,000,000–1,300,000,000**. This predates the capacity
candidate, which has **no gameplay result or standard-suite acceptance**.

## Intended change

The current ao486 platform cache has only 128 sets: **32 KiB, four ways,
64-byte lines**. Measured gameplay still spends 21.14% of clocks in D-pipeline
result wait. Passive diagnostics also show substantial fill waits, although
those overlapping counters cannot establish a capacity-miss fraction.

`prepare_l2_capacity_profile.capacity_profile()` applies the existing tested
capacity parameterization and selects 1,024 sets at the one platform instance.
It refuses an input missing the three-part LRU ownership/forwarding repair.
The data RAM depth, tag/index widths and invalidation bitmap scale with the
number of sets. Ways, line size, memory ports, registered read-first data RAM,
write-through behavior, all core/FP/L1 source, UV/system-fast mode and the outer
DDR double-read policy remain unchanged. No guest-specific logic is introduced.

Only `l2_cache.v` and its `system.v` instantiation change in the frozen full-PC
candidate. The system edit preserves every other byte, including CRLF.
Default parameter value is still 128; no production geometry is selected here.
**Cold use also requires `prepare_l2_init_backpressure.transform()`**, described
below. The geometry-only first candidate exposed a pre-existing readiness bug
and failed boot; do not deploy the capacity transform alone.

## Functional checks

Evidence: `external/tmp/ventium-l2-capacity-xpm.tu7z9vVs`.

- `r1/closed.json`: **512** native capacity/replacement/invalidation/reset
  cases pass across 128/256/512/1,024 sets, 1–8 response words, zero/one idle
  cycle, two DDR cadences and 512–4,096-line footprints. The actual FPGA-style
  registered, read-first data RAM model is selected, not just the old model.
- `stores-r1/closed.json`: **45** additional native runs pass: original128
  versus parameterized128/256/512/1,024, three return cadences and three random
  initializations. Every set, four resident ways, all sixteen byte masks,
  both dword lanes, aliased write misses and external-mutation invalidations
  are checked. Captured stores face six clocks of DDR backpressure while live
  CPU inputs are poisoned. The oracle checks all returned words and the entire
  backing memory. Totals: **313,344 stores, 2,506,752 returned dwords and
  18,432 external mutations**. No internal DUT state is forced.
- The original128 and parameterized128 store executables have the **same
  SHA-256**, and identical case receipts. Fifteen host recipe tests pass,
  including rejected unsupported geometry, missing LRU repair and duplicate
  application.

`stores-negative-r2` deliberately truncates the enlarged RAM write index to
the old width. The store oracle rejects it at word18,433 (native exit1),
confirming that the extra index bits are exercised. The initial negative R1
attempt is **invalid**: a symlink-versus-canonical path comparison left the
original source in its build command. R2 resolves paths, asserts exactly one
source replacement and checks the generated input manifest; R1 is retained,
not counted as a negative-control pass.

All leaf builds hard-fail IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/LATCH/
UNOPTFLAT. Store builds use four concurrent eight-job compilations inside the
shared 16 GiB build scope; native tests are bounded. No full-system correctness
claim follows from these microbenchmarks.

Reproduce with fresh external output directories:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
tools/build_scope.sh -- python3 -B verif/l1/run_l2_capacity.py \
  --source /path/to/original/l2_cache.v --prims /path/to/sim_prims.sv \
  --out /home/yukidama/external/tmp/FRESH_CAPACITY \
  --repair-lru --check-lru-owner --check-lru-write-owner \
  --words 1 2 3 4 5 6 7 8 --gaps 0 1 --xpm-fidelity

TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
tools/build_scope.sh -- python3 -B verif/l1/run-l2-capacity-stores.py \
  --capacity /home/yukidama/external/tmp/FRESH_CAPACITY \
  --out /home/yukidama/external/tmp/FRESH_STORES
```

The first command takes the **unrepaired** source and applies the existing
complete repair. Its repaired source was explicitly compared with the running
read-through model before this test; do not apply the repair twice.

## Isolated FPGA cost

`fpga/run-l2-capacity-leaf.py` pins the complete tested capacity matrix before
one exclusive, 8 GiB/no-swap Vivado family builds original128, default128 and
1,024 sets sequentially. No CPU bitstream or board programming is performed.

| Routed leaf metric | Original/default 32 KiB | 256 KiB |
| --- | ---: | ---: |
| CLB LUTs | 1,164 | 4,478 |
| Registers | 588 | 1,548 |
| RAMB36E2 | 8 | 64 |
| RAMB18E2 | 0 | 1 |
| Setup-limited isolated frequency estimate | 214.09 MHz | 164.26 MHz |
| Worst hold slack | −0.135 ns | −0.135 ns |
| Hold-failing endpoints | 266 | 264 |

The enlargement costs **3,314 CLB LUTs, 960 registers and 56.5 BRAM tiles**.
The larger leaf uses 64.5 of the device's 744 BRAM tiles. The setup estimate
decreases; it is **not processor Fmax**. Both geometries fail isolated hold
constraints, so this is **not timing sign-off**. All profiles use identical
25 ns/zero-I/O-delay constraints, with no hold waiver. Original/default128
mapping and timing are identical. RAM reports identify the extra RAMB18 as
dirty state; no new memory port or combinational data-read assumption was added.

Evidence: `external/tmp/ventium-l2-capacity-physical.yhm8eon6`.
Native exit0, **368.96 seconds**, 3,712,593,920-byte peak cgroup RAM, zero OOM,
unchanged pins, and the vendor family exited. The scope invocation is
`b8974f02edd147958f6954ecdbb4560e`.

## Acceptance still required

The first frozen full-PC derivative at
`external/tmp/ventium-l2-256k-soc.vSfxzuji`, model `e5b4b41b`, parent `e9097d96`,
**failed both cold boots**: zero retirements past18M clocks. It retains all
133 defines and the existing cold, unchanged-media UV+fast qualification flow.
Both failed runs were normally stopped/reaped, with their actual supervisor
closures retained. Native exit0 is not a guest pass; both receipts remain FAIL.

### Initialization readiness repair

`CPU_BUSY` originally advertised ready in `START`, even though that state
only walks the tag RAM and cannot consume a CPU request. The 128-set cache
usually finished before the core's first request; 1,024 sets exposed the lost
first fetch. A fixed harness sleep would mask the protocol defect.

`prepare_l2_init_backpressure.transform()` asserts ordinary request
backpressure while `RESET`, its first registered stage, or `START` is active.
It changes both streaming and legacy busy assignments. There is no new
register, memory port, queue, steady-state stall or guest condition. The real
bridge holds the command until the cache is able to accept it. Reset timing in
the full-PC harness is **unchanged**.

`init-r1/closed.json` has **576 expected outcomes** across two geometries,
three stream modes, eight arrival delays, read/write-first commands, three
random initializations and cold/populated-cache resets: 288 repaired passes,
126 late-arrival control passes and **162 old-logic early-admission failures**.
Requests obey only the public BUSY handshake, not internal state or a fixed
initialization delay. A public handshake while the cache cannot consume it is
an error. After the fix, the complete **512 capacity cases and 45 store runs**
also pass again (`init-capacity-r1`, `init-stores-r1`). Nineteen recipe tests pass.
`warm-parity.json` independently compares all 512 cycle/miss/capacity rows
and all 45 store case receipts against the unmodified readiness logic: they
are **exactly identical after initialization**. This is a microbenchmark
nonregression result, not a gameplay speedup.

Repaired full-PC model:
`86731249748f06e2baa1ba59ea3a92d5fb1313ca12b70935006374aad859c6df`,
`external/tmp/ventium-l2-init-soc.tt7Ma9rk`. Only L2 readiness changes from the
failed geometry model. Native build0, stable source pins, model-local C++
header/object and unchanged 98 inherited structural warnings are checked;
this is not clean whole-SoC lint. Cold Quake/Win95 now retire BIOS instructions
and continue, CPUs24/26, invocations `67865eeae00e4876aed09f8388646e1b` and
`534dca670f6e42ad8f4f16bad4716f26`. Independent admission passes; no gameplay,
desktop or timedemo acceptance yet. Supervisor closure retention is active.

The physical table above describes the **geometry-only parent**. The matched
repaired-geometry run is now closed at
`external/tmp/ventium-l2-capacity-physical.qaq6ps__`: original/default128 are
identical at **1,167 CLB LUTs / 588 registers / 8 RAMB36**, and repaired1024
uses **4,459 CLB LUTs / 1,548 registers / 64 RAMB36 + 1 RAMB18**. The added
capacity therefore costs **3,292 LUTs / 960 registers / 56.5 BRAM tiles** with
the readiness repair present. Setup-limited isolated estimates are
**203.50 / 160.33 MHz**, respectively, not CPU Fmax. Worst hold is still
−0.135 ns; repaired1024 has250 failing endpoints. No timing sign-off follows.
Native exit0, stable inputs, **387.16 seconds**, 3,978,215,424-byte observed
peak cgroup RAM, zero OOM/swap and vendor family exited. Scope invocation:
`aa4e97a8c1124d5e89d9bdad3298da74`.

The generic differential gate is still **FAIL** on the previously recorded
terminal-oracle/cold-cycle-band issues; it is not waived by source parity.
Neither cache enlargement nor a passing leaf test is a measured performance
fix. Require actual gameplay ≥0.48, current full CoreMark seeds, Win95 desktop,
completed Quake timedemo, full FPGA timing/resources and deployment before
declaring the target achieved.
