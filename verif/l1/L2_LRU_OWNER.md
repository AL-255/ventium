# Platform L2 replacement-state repair — October 9

Private full-PC candidate; **not a completed standard-suite or FPGA pass**.
Latest verified Quake gameplay remains **0.38065044 total U+V IPC**, dispatch
model `ba2463bf`, cycles **1,200,000,000–1,300,000,000**. It predates this repair.
The current candidate has no gameplay score; the **0.48 target is open**.
The earlier 2.10736/2.11041 CM/MHz results are direct-memory simulation scores,
not FPGA cache/DDR performance. The current core's full seeds are still running.

## Evidence and root cause

Passive, read-only counters from the running dispatch model attributed 27.35%
of a 6,813,201-clock diagnostic window to L1 fill-read wait and 9.31% to L1
idle-read wait. L2 streaming occupied 17.18% (overlaps L1 wait). These are
asynchronously bracketed diagnostic samples, **not an acceptance IPC window**.
Evidence: `ventium-live-counter-layout.wKizYtu6/dispatch-all-{first,second}.json`
under `/home/yukidama/external/tmp`. The outer bridge also makes two eight-beat
reads per L2 miss; its historical hardware-coherence workaround is unchanged.

A capacity sweep exposed a replacement bug before any cache enlargement was
selected. This is the ao486 platform's **32 KiB, four-way, 64-byte-line cache**,
not the disabled `EN_L2` northbridge and not the core's full P5 L1s.

`READONE` assigns `LRU_addr` and simultaneously selects a streaming victim from
asynchronous `LRU_out`. That output still belongs to the **previous set**. The
streaming path captures the wrong way permanently, whereas legacy `FILLCACHE`
selects again after the new address has arrived. A sequential 512-line working
set fits the existing cache, yet all **512 warm accesses miss**. A cold ownership
assertion catches request set 0 consuming reset's final set 127.

## Repair, including rejected partial fixes

`prepare_l2_capacity.repair_lru_lookup()` makes three related changes:

1. Present the admitted CPU request's set to the existing LRU read port in IDLE.
2. Register **LRU write-set ownership alongside rank data**, including START's
   initialization. Advancing the read address alone redirects a pending update
   from a one-word hit into the next request's set; that partial fix fails.
3. Forward pending rank data when a read and registered write address match.
   Without forwarding, an immediate same-set miss can evict the line just hit.
   The independent reference-LRU test reproduces this with a one-word hit and
   no extra idle cycle. The no-forward partial fix fails at reference read 1052.

No cache size, data RAM port, response stage, guest behavior, pairing or fast
pipeline policy changes. At the actual 128-set geometry the added state is one
**seven-bit write address**, with an eight-bit pending-rank bypass. No blanket
stall is introduced. Physical LUT/timing/route impact is **not measured yet**.
The FPGA filelist uses the same asynchronous `altdpram` implementation from
`ao486-sim/stubs/sim_prims.sv`; no synchronous-read memory is assumed here.

The separate capacity transform permits 128/256/512/1024 sets only for tests.
**No enlargement is included in the full-PC candidate.**

## Verification

Evidence root: `/home/yukidama/external/tmp/ventium-l2-capacity.NaPFMpwa`.

| Receipt | Result |
| --- | --- |
| `owner-negative` | Original source fails wrong-set ownership assertion |
| `short-owner-negative` | Read-address-only repair fails write ownership |
| `true-lru-r1` | Separate write owner without bypass fails reference LRU |
| `true-lru-r3` | Complete repair passes 512 capacity/order cases |
| `final-any-r1` | 512 final any-offset streaming cases pass |
| `final-lower-r1` | 128 final lower-half streaming cases pass |
| `final-legacy-r1` | 128 final non-streaming cases pass |

The **768 final cases** vary 1–8 response words, zero/one idle cycle, two DDR
beat/tail cadences and 512–4096-line footprints. Any-offset coverage also varies
all four geometries. Each uses an independent physical-address data oracle and
four-entry software LRU per set, immediate same-set hit/eviction sequences,
4,096 pseudo-random reads, eleven external-mutation/invalidation probes and a
second real reset. Streaming cases poison each of the eight returning DDR beats
and require refetch; lower-only poisoning applies to its eligible eight-word
form. Tests naturally fill memory; no DUT state is forced or restored.

Builds run assertions and hard IMPLICIT/PINMISSING/UNDRIVEN/MULTIDRIVEN/LATCH/
UNOPTFLAT checks. The leaf binds previously omitted primitive inputs identically
in control and candidate, after verifying the frozen primitive does not consume
them. No structural warning is suppressed. Native cases run with 32 workers.
Source/command/native logs and frozen scripts are retained. Earlier failed
preparation/build attempts remain distinct, including `r1`, `r2`, `r3` and
`true-lru-r2`; they are not passing evidence.

Example (use a fresh external output directory and the intended frozen source):

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
tools/build_scope.sh -- python3 -B verif/l1/run_l2_capacity.py \
  --source /path/to/frozen/l2_cache.v --prims /path/to/frozen/sim_prims.sv \
  --out /home/yukidama/external/tmp/FRESH_OUTPUT \
  --repair-lru --check-lru-owner --check-lru-write-owner \
  --words 1 2 3 4 5 6 7 8 --gaps 0 1
```

Use `--sets 128 --stream lower` or `--sets 128 --stream legacy` for controls.
`--unsafe-read-only` and `--unsafe-no-forward` retain the deliberately incomplete
repairs for negative tests only. Host recipe guards:
`python3 -B verif/l1/test_l2_capacity_recipe.py`.

## Cold full-PC candidate and remaining gates

Root: `/home/yukidama/external/tmp/ventium-lru-owner-soc.CEg0ogJu`.
Model SHA-256:
`227b03736c0d04b1451e18f797c9d7c9c0cb969f9df49944d53f8a9353d640be`.
Exactly one RTL file changes from under-fill model `e44e3176`:
`3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v`. All core/FP/L1 source and all
117 defines remain identical. Native build exits zero, inputs stay pinned and
the unique host object uses its own generated header. The 98 existing third-party
structural warnings are unchanged (warning source lines are mapped through the
actual edit); this is **not clean whole-SoC structural lint**.

Fresh cold services use unchanged media, UV + relocated system fast pipeline,
posted16 transport, full P5 L1s, unchanged 32 KiB L2 and 40/40/80 MHz clocks:

| Guest | Service | Invocation | CPU |
| --- | --- | --- | ---: |
| Quake | `ventium-lru-owner-quake-oct09.service` | `2557b5b125e54208a4e36c0865d2497c` | 22 |
| Win95 | `ventium-lru-owner-win95-oct09.service` | `17c71a3c977f4f6190557f3343be49ef` | 23 |

Each retains its one-CPU/2 GiB/no-swap/task/file/runtime bounds. Both are in
progress; no guest pass or gameplay improvement is claimed. No snapshot, guest
patch, debugger STEP, pairing suppression or global slow fallback is used.

The generic differential gate is still **FAIL**, not waived or inherited as
passing. Complete same-source CoreMark correctness, Win95 desktop confirmation,
complete Quake timedemo, measured gameplay ≥0.48 IPC, physical qualification and
FPGA deployment remain required. This recipe is not production acceptance.

To preserve disk headroom, 58 individually enumerated, closed GCC PCH cache files
were removed (4,861,559,330 bytes). They are regenerable; runnable models, source,
objects, archives, headers, dependency files, guest media and all evidence remain.
Plan/receipts: `ventium-lru-pch-reclaim.s9RAAA2z/{plan,closed,final-plan,final-closed}.json`.
