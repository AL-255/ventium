# Read-retirement cache priming — October 9

Private, default-off RTL proposal; not production, standard-suite or FPGA
acceptance. Latest verified gameplay: **0.44513116 total U+V retirement-event
IPC**, permission-shadow model `1f2583cb`, cycles **1,200,000,000–1,300,000,000**.
That model predates this proposal and the target-read/scalar-dispatch candidates.
The 0.48 target remains open.

## Change

`prepare-held-read-prime.py` changes only `core_mem_chain.svh` and adds
`core_raw_held_prime.svh` in a new private copy. Under
`VEN_RAW_HELD_READ_PRIME`, an unpaired integer U read can lend its retirement
edge to the existing registered D-cache next-read port. This primes only a
resident, checked successor read. No backing transaction, third decoder,
additional SRAM port, instruction admission or architectural owner is created.
The ordinary next-U path still checks permissions, faults and pairing.

For a held U, one validity/poison bit qualifies its existing saved V descriptor.
Capture checks complete code bytes, page and CS extent; reset, abort, snoops,
flushes and TLB replacement poison it. An already-acknowledged fresh U instead
uses the existing live V descriptor. Both retain the ordinary dependency,
segment, TLB, event/debug, cacheability and resident-hit checks. Capture commits
only with the actual older U retirement, never merely an ACK-independent offer.

## Regression found and repaired

The first fresh-U prototype passed architectural comparisons but **lost
same-line immediate V load pairing**. A hint redirected the cache lookup,
suppressed `window_reuse`, and converted V into a later U instruction. The
pair-preservation gate correctly rejected it; no deployment used that version.

The repaired helper reserves an eligible memory V using the ACK-independent
`pipe_pair_mem_ok` decoder predicate. It must not use the actual immediate
pair acceptance, which depends on the cache lookup and would create feedback.
This does not globally disable pairing or change cache-port arbitration.
Existing same-line V counts remain **15/14** at AXI latency 0/7, exactly matching
the parent in both flat and relocated layouts.

## Closed directed evidence

Scratch root: `external/tmp/ventium-read-retire-pair-safe.YcBvKMJ0`.
Board-core model:
`19ac54ac84825524acac7611b7d14bca206f8d6c5c5bece2d2cb6c60c050f660`.
Full-address user model:
`f6f0b8e4b129209b6c349456447fe01ec1ada87bfac6839b00b13fc7ba73be2a`.
Both compile with assertions, six hard structural checks, stable source pins,
unique host basenames and verified model-local generated-header dependencies.
Parent `5081f17d` includes permission shadow and checked system target reads;
the sole added define is `VEN_RAW_HELD_READ_PRIME`. UV-fast remains enabled.

- `matrix-r1`: **48 matched measurements / 96 complete QEMU comparisons**.
  Four same-destination memory ALU reads: **9→6 clocks** per warm loop in all
  layouts/latencies: 33.33% fewer clocks, not a gameplay gain. All five other
  kernels retain their clocks and the independent register V pair count.
- `pair-owner-r1`: **32 runs / 16 complete QEMU comparisons**, same-line and
  separate-line younger reads, flat/relocated, latency 0/7. No orphan owner;
  immediate memory pairing retained, not hidden by U-only fallback.
- `events-r1`: **16 complete QEMU comparisons plus cycle traces**, with real
  cold guest paging, #PF/retry, split-page #PF, TF trap and CPU-store SMC.
  Eight warm calls establish positive hint witnesses before each event;
  handlers check exact fault PC/CR2, prior-only accumulator, DR6 and retry.
  The SMC test changes a displacement in already-executed RAM code and requires
  the new data. No host-injected state, skipped instruction or trace trimming.
- `system-matrix`: **76/76 complete system comparisons**, nineteen fixtures
  against pinned QEMU, exact parent architectural parity and complete cycle PC
  sequences at latency 0/7.
- `leaf-r1`: actual helper enabled/disabled, **239,285 checks each**: admission
  combinations, every page offset and short U/V length, segment endpoint/wrap,
  twelve poison events, owner classes, fresh pair priority and ACK independence.
- `test_held_read_prime.py`: five fail-closed transformation/copy-guard tests.

Generic `make verify` closes **FAIL**, native exit 2, stable inputs: seven
functional passes / the existing 101 terminal-record length mismatches, and
four legacy cycle-band failures (dependent ADD, independent ADD, D-miss,
I-miss). This mandatory gate remains an open blocker. No comparison mask,
terminal record or band has been changed.
Full CoreMark seeds, cold Win95/Quake, gameplay measurement and hardware
implementation are not qualified for this proposal.

## Full-PC qualification in progress

`external/tmp/ventium-read-prime-soc.xkz3smgJ` builds model
`15f5605496acfed016b5af95d66e315eb1e01db04d9475c8c4b67203945ff453`.
Only the chain include and new helper differ from checked-target parent
`59650fe2`; all core/FP source matches the micro model. The native build closes
zero, stable source pins, model-local host header and real registered XPM
fields checked. The same 98 third-party structural warnings remain; this is
not whole-SoC hard-lint acceptance or a routed bitstream.

Cold, unchanged media/ROMs, UV-fast, posted16 DDR3, P5 L1s, 40/40/80 MHz and
16 MiB guest RAM are retained. The unchanged resource/closure guards run:

- Quake CPU17, service `ventium-read-prime-quake-oct09.service`, invocation
  `73acee364e4545199f0e118efa80b6b6`.
- Win95 CPU21, service `ventium-read-prime-win95-oct09.service`, invocation
  `e169108300904df4894fab89920f10c8`.

`admission-audit.json` independently rechecks native executables, PID start
times, affinities, input pins, service ownership and 2 GiB/no-swap/one-CPU
limits, with no OOM. Launch/admission is **not** desktop/timedemo acceptance;
the model remains gameplay-unmeasured. Keep both CPUs and their SMT siblings
out of subsequent heavy builds.

## Retained unsuccessful evidence

`ventium-held-read-prime.6FLwLgNL` holds the held-only experiment (9→8 clocks).
`ventium-read-retire-prime.LAWR3Rot` holds the first fresh/held experiment
`ca630e97`, including the failed `pair-owner-r1` receipt and exact archived R2
helper/test sources. Its `events-r1` also retains a test-driver rejection:
post-retirement #DB does not pass through `start_fault`'s logger. The corrected
`events-r2` requires the actual handler entry, full architectural comparison
and guest DR6/frame assertions, rather than treating an absent fault-log line
as a missing trap. That corrected gate also passes on the repaired model.

## Reproduction

Use the frozen parent profile, not these flags alone on unrelated production
RTL. `VEN_PIPE_MEM_CHAIN`, `VEN_PIPE_REG_LOAD_PRIME` and
`VEN_RAW_V_READ_PRIME` are prerequisites; the parent also contains the existing
primed-U/registered-V ownership repair.

```sh
export TMPDIR=/home/yukidama/external/tmp
python3 -B verif/fe_pipe/prepare-held-read-prime.py \
  --source /absolute/frozen/parent --out "$TMPDIR/new-private-candidate"
# Build a uniquely named model with the same UV-fast/AXI profile and
# +define+VEN_RAW_HELD_READ_PRIME, assertions and hard structural checks.
python3 -B verif/fe_pipe/run-raw-v-prime.py --feature held-read \
  --control /absolute/parent/tb_ventium --candidate /absolute/candidate/tb_ventium \
  --out "$TMPDIR/new-read-prime-matrix"
python3 -B verif/fe_pipe/run-prime-pair-owner.py --feature held-read \
  --control /absolute/parent/tb_ventium --candidate /absolute/candidate/tb_ventium \
  --out "$TMPDIR/new-read-prime-pair-gate"
python3 -B verif/fe_pipe/run-read-retire-events.py \
  --control /absolute/parent/tb_ventium --candidate /absolute/candidate/tb_ventium \
  --out "$TMPDIR/new-read-prime-events"
```
