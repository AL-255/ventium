# Passive simulator counters

`live_sim_counters.py` reads already compiled performance counters without
rebuilding, restarting, pausing, stepping or writing to the simulator. It does
not restore a save state. The live executable, its generated-header layout
and compiler dependencies are pinned; mismatched process identity or input
drift is rejected. The only process-memory descriptor is opened read-only.

Prepare as an ordinary user, against the **actual model's** object directory:

```sh
export TMPDIR=/home/yukidama/external/tmp
python3 -B tools/live_sim_counters.py prepare \
  --obj /absolute/model/obj --binary /absolute/live/executable \
  --board-header /absolute/frozen/board_axi_memory.h \
  --out "$TMPDIR/new-layout"
python3 -B tools/live_sim_counters.py read \
  --layout "$TMPDIR/new-layout/layout.json" --pid ACTUAL_NATIVE_PID \
  --out "$TMPDIR/new-sample.json"
```

Omit `--board-header` for a model without `board_memory`. Linux ptrace access
policy may require `sudo` for **read**, not for preparing/compiling the layout.
Do not change system ptrace policy. No debugger attaches or signals are sent.
Two different output names give a cumulative-counter delta. Only compare the
same executable, layout and process-start-time/reset epoch. Counter families
overlap; their shares must not be added together. FP FIFO timestamps are
excluded because they are not cumulative counters.

This is deliberately **diagnostic**, not an atomic full-state capture or
performance acceptance. Each read records a before/after simulator-clock
bracket, limited to 16 clocks, and validates state, response and L2 partitions.
Different families may be sampled within that bracket. Official gameplay IPC
still requires clock-boundary log samples and rendered-gameplay evidence.

Seven host tests (`test_live_sim_counters.py`) cover parsing/duplicate guards,
layout bounds, torn partitions, wrong executable, short reads, an actual owned
child's read-only memory, and the complete native PIE-symbol/header/pointer
workflow including host AXI counters and deliberate header drift.

## First diagnosis, October 9

Evidence: `/home/yukidama/external/tmp/ventium-live-counter-layout.wKizYtu6`.
Dispatch-only `ba2463bf` remains the measured old model, not the current
FP/under-fill candidate. Its verified gameplay baseline is **0.38065044 total
U+V IPC**, cycles **1.2–1.3B**; no new acceptance IPC is assigned here.

`dispatch-all-{first,second}.json` samples clocks approximately
**2,262,859,579–2,269,672,781**, with one-clock endpoint brackets and a core
counter delta of **6,813,201 clocks**. No process stop or guest write occurred.

| Observation | Count | Meaning |
| --- | ---: | --- |
| L1 read waiting during fill | 1,863,518 clocks | 27.35%; includes backing service/ownership |
| L1 read waiting while idle | 634,512 clocks | 9.31%; not a cache-miss count |
| L1 fill starts | 82,190 | 657,520 acknowledged dwords in this window |
| Platform L2 misses | 16,318 | Not the same population as L1 misses |
| L2 streaming residency | 1,170,509 clocks | 17.18%; overlaps L1 waits |
| Outer AXI AR / R | 32,636 / 261,088 | Exactly two eight-beat reads per L2 miss here |

The frozen platform L2 has 128 sets × four ways × 64-byte lines = **32 KiB**.
The core's `EN_L2=0` does **not** disable this ao486-platform cache. The outer
posted DDR adapter still discards/replays the first read. These observations
support testing cache capacity and transport costs separately; they do not
establish a removable percentage or justify deleting the hardware workaround.
The existing narrow-read/stale-HP0 evidence still requires root-cause closure.

Earlier snapshots with fewer fields are retained separately. An initial
strict double-read/unchanged-clock attempt could not obtain an atomic sample
and exited 2 without stopping the process. The current bracketed diagnostic
reader explicitly reports its weaker sampling contract; it does not relabel
that failed attempt or any acceptance test as passing.
