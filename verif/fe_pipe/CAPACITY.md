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
working set. This **invalidates any
generalized zero-overhead claim** from the earlier three/five-page fixtures.
Do not accept this cut as a performance repair merely because these functional
tests pass. The frozen hardware synthesis remains useful physical evidence,
not permission to overlook this regression risk.

The first run, `ventium-fe-capacity.6yyqzm_p`, completed the same native checks
but its final receipt writer raised `AttributeError` while hashing string
paths. That run is not a closed pass. The runner now canonicalizes the digest
argument and writes each case result separately; the fresh run above closes
normally. Original native logs are retained.

## No-cut reference: UV-fast remains enabled

The runner also accepts `--no-cut-reference`, which **requires** the cut flags
to be absent while retaining all required UV/system-fast/AXI flags. It does
not change a model's mode or allow a slow/U-only result.

Reference binary `ventium-uv-retire-state.bMk6tx/obj/tb_ventium`, SHA-256
`f1722209acdb29282adc35789fb8f4557b46b2e41dbc19533ad544586bde0c98`.
Closed evidence: `ventium-fe-capacity.0e99srhf/result.json` under external tmp.
Again all **14 full QEMU comparisons** pass, all **28** RTL native runs exit
133, and every case retains **10/10** subject U-load/V-increment pairs.

| Hot pages | No-cut cycles/round | Eight-entry cycles/round | Added cycles |
|---:|---:|---:|---:|
| 4 | 13 | 13 | 0% |
| 7 | 22 | 22 | 0% |
| 8 | 25 | 25 | 0% |
| 9 | 28 | 37 | 32.14% |
| 16 | 49 | 65 | 32.65% |
| 32 | 98 | 130 | 32.65% |
| 64 | 194 | 258 | 32.99% |

Results are identical at AXI latencies 0/7. Same source-generated BIOS images,
instruction sequences and real pairing; **one added cycle per data load**.
This is a measured comparison, not an exact one-variable A/B: the no-cut model
predates the separate L1 response-owner and payload-factoring repairs.
Read-only RTL-tree comparison finds only `core.sv`, `ven_l1d.sv`, and the added
`ven_fe_dtlb.sv` different. The observed eight-page threshold and unchanged
warm AXI-latency sensitivity support child-capacity attribution; a rebuilt
matched control and direct pending-cycle attribution remain stronger follow-ups.

The proposed structural remedy is a [banked child](banked/README.md), matching
the ordinary parent's 16-set/four-way geometry and avoiding a 64-way CAM.
It is leaf-tested, **not yet full-core or FPGA qualified**. The running frozen
eight-entry synthesis must remain unchanged; it is now a physical reference,
not an accepted performance candidate.

Candidate gameplay IPC is **unmeasured**. Historical `53f129e9` baseline:
**0.1659957781052303 primary/U-counter IPC**, not total U+V, in 127 qualified
intervals within cycles 8,721,490,845–19,169,282,165; it predates this candidate.
Neither this microbenchmark nor the pending synthesis qualifies CoreMark,
Windows 95, original cold Quake timedemo or the complete movie.
