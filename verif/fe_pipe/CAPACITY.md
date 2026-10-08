# UV-fast translation working-set probe

`capacity.S` boots a fresh protected/paged system with nonidentity data pages.
Its hot loop reads one cache line per data page, increments an independent V
register, and accumulates a checked checksum. Page-specific cache-line offsets
avoid L1 set conflicts. A/D bits are initialized; the hot loop never touches
the stack or page tables. Normal OUT F4 exits must return 133.

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 verif/fe_pipe/run-capacity.py --tb /absolute/path/to/tb_ventium
```

No model rebuild. The runner requires the actual UV-fast/AXI/permission-cut
profile and assertions, uses `--cycle-func` and `--cycle` with `--l1-axi`, and
compares every architectural record to pinned Pentium QEMU without masks or
truncation. It checks actual same-clock U load + V increment, normal native
exit and complete instruction-sequence equality. Seven warm round intervals
are measured after two traversals. Two small native jobs run concurrently;
each process group has a 120-second limit and is reaped on timeout.

## Oct 8 finding: an eight-page performance cliff

Candidate `ventium-l1-primary-payload.rSTQAk/obj/tb_ventium`, SHA-256
`2d26fc35aee8ed8eef0852050efbb28fa1e93af3aac5c063ab9616766c89f7e2`.
Closed evidence:
`/home/yukidama/external/tmp/ventium-fe-capacity.v3bvwzjc/result.json`.
All **14 full-state QEMU comparisons pass**, all 28 RTL cycle/state executions
exit 133, input pins unchanged. Every case has all **10** first-load/increment
pairs genuinely in U/V on the same clock. This is not a U-only control.

Both AXI latencies **0 and 7** produce the same warm results:

| Hot data pages | Cycles per warm round | Cycles per data load |
|---:|---:|---:|
| 4 | 13 | 3.2500 |
| 7 | 22 | 3.1429 |
| 8 | 25 | 3.1250 |
| 9 | 37 | 4.1111 |
| 16 | 65 | 4.0625 |
| 32 | 130 | 4.0625 |
| 64 | 258 | 4.0313 |

The eight-entry registered translation child uses round-robin eviction;
`fe_d_capture` waits to register the parent's result when the child misses.
These results are consistent with repeated child misses once a cyclic working
set exceeds eight pages, even when the parent TLB and data cache retain the
working set. A no-cut UV-fast reference is still needed to quantify the exact
regression independently of code length/alignment. This **invalidates any
generalized zero-overhead claim** from the earlier three/five-page fixtures.
Do not accept this cut as a performance repair merely because these functional
tests pass. The frozen hardware synthesis remains useful physical evidence,
not permission to overlook this regression risk.

The first run, `ventium-fe-capacity.6yyqzm_p`, completed the same native checks
but its final receipt writer raised `AttributeError` while hashing string
paths. That run is not a closed pass. The runner now canonicalizes the digest
argument and writes each case result separately; the fresh run above closes
normally. Original native logs are retained.

Candidate gameplay IPC is **unmeasured**. Historical `53f129e9` baseline:
**0.1659957781052303 primary/U-counter IPC**, not total U+V, in 127 qualified
intervals within cycles 8,721,490,845–19,169,282,165; it predates this candidate.
Neither this microbenchmark nor the pending synthesis qualifies CoreMark,
Windows 95, original cold Quake timedemo or the complete movie.
