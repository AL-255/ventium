# Raw-decoder resident-read priming — October 9

Private, default-off prototype; **not production RTL or FPGA acceptance**.
Verified gameplay baseline: **0.37698979 total U+V retirement-event IPC**,
posted16 model `3c8779f4`, cycles **1.2–2.7B**. Neither this prototype nor its
dispatch/shared-FP parent has a gameplay measurement. The 0.48 target is open.

## Change and invariants

The raw FPGA frontend already decodes a V memory instruction behind an
unpaired register U. The existing resident-read lookahead previously required
the uop cache. `prepare-raw-v-prime.py` reuses that V descriptor to warm the
registered L1 window on U's real retirement edge. It does **not** instantiate
a third decoder, enable the uop cache, issue a backing read, or admit V early.
On the next clock, the ordinary U admission path still owns its translation,
permissions, faults, data and potential new V pair. Reserving an incomplete
load-only core packet here would unnecessarily lose that following pair.

Admission retains the existing event/debug, segment/extent, TLB-hit/read
permission, cacheability, resident-hit, flush/snoop and address-dependency
checks. Only the current complete-in-line V instruction on the checked code
page is considered; no predicted branch target or third instruction is decoded.
Misses/MMIO/split reads and addresses written by the retiring U fall back.
The prototype does not seed the frontend translation child: doing so with
the older request's permission metadata would be unsafe. The original fatal
guard remains for actual memory-chain owner replacement with permission cuts.

Added defines: `VEN_PIPE_MEM_CHAIN`, `VEN_PIPE_REG_LOAD_PRIME`,
`VEN_RAW_V_READ_PRIME`. The generator changes only `core.sv` and
`core_mem_chain.svh` in a new private copy. Its parent in this experiment
already includes the protected-dispatch and shared-FP proposals. Never enable
these flags alone on an unmodified production checkout.

## Closed native evidence

Core root: `/home/yukidama/external/tmp/ventium-raw-v-prime-r2.tusL3qBP`.
Board-core model: `f4b2a1928e1091b742ef4cc049a6074e06284a5141ea6b47b8b94f51da71617e`.
Full-address user model: `b36997fce1fb229f6c27dcff8e51ab3e9556f9b713e1e3ba547c527f3408790d`.
Both use assertions, hard structural warnings, unique host basenames and
verified model-local generated-header dependencies. Core profile: 113 defines;
user: 112, only `VEN_KV260_SOC` removed. No STEP/pair suppression.

`micro-r4/result.json`: **48 matched measurements / 96 full QEMU comparisons**,
six fixtures × flat/relocated segments × two code placements × AXI latency 0/7.
Cold native QEMU self-checks and every intermediate architectural record pass;
cycle traces retain the same complete PC sequence. Actual V retirements and
prime edges are observed. The final retry additionally enforces all 16 following
V pairs, actual prime counts, positive directed gains and unchanged negative
controls. No terminal trimming or pair-end-only comparison. The earlier r3
receipt and its hash-matching observed runner remain separate evidence.

| Warm fixed loop | Parent clocks | Candidate clocks | Fewer clocks |
| --- | ---: | ---: | ---: |
| Four resident lines, aligned code | 14 | 10 | 28.57% |
| Four resident lines, alternate code placement | 15 | 11 | 26.67% |
| Byte load at line byte 31, nonzero upper register | 5 | 4 | 20% |
| Four read-ALU operands | 10 | 9 | 10% |
| Address RAW control | 5 | 5 | 0% |
| Crossing-dword control | 5 | 5 | 0% |
| Load with a following independent V register op | 4 | 4 | 0%; pair preserved |

These are directed loop results, **not gameplay speedups**. All profiles and
latencies agree on these warm costs. Guards reject both negative controls;
the paired-load case preserves its V retirement count.

`system-matrix/result.json`: **76/76 PASS**, original/candidate × 19 system
fixtures × AXI latency 0/7, full architectural state and cycle PC sequences,
unchanged pins. The generic gate closes **FAIL**, native exit 2, stable inputs,
152.8 seconds: the same seven functional passes, 101 length-only mismatches and
legacy cycle-band failures as the parent. No new earlier architectural mismatch
is reported, but this is still not a green generic gate.

Exact banked-cache leaf: `ventium-raw-v-prime-leaf-r2.XWiBEyPl/closed.json`
passes, **150 accepted next-read transactions**, including the original chain
ownership/backpressure/miss/MMIO/reset tests and cache-only prime followed by
frontend idle clocks, snoop, flush and a real store. All optional unused ports
are explicitly tied off in the fixture. The two-window profile uses real reads
to evict saved windows before tests requiring a newly registered owner.
This is not arbitrary external-DMA/IRQ scheduling coverage.

Failures remain separate: first core candidate stopped at the permission-cut
guard before guest execution; the retry removes the unnecessary FE capture,
not permission checks. Two earlier fixture versions allowed padding NOPs to
consume a designated V witness; the final fixture branches explicitly to the
aligned witness pair. The first leaf build omitted `ven_p54_hit_return.sv`;
the corrected filelist builds without relaxing structural warnings.

## Full-PC integration and next gates

`ventium-raw-v-prime-soc-r2.AtMi5nga` builds model
`cf07083d99f4f28bd2db17ea01f18ec9f6f81ad75e353485b101ab9df585a63c`.
Only three RTL payloads differ from dispatch SoC parent `ba2463bf`: the two
priming files and `fp_shared/ven_fp_alu.sv`. All common core/FP source hashes
match the micro model. The SoC retains its parent's posted-DDR drain wiring
and live U+V debug counter; its shim is not elaborated in the core testbench.
The initial overbroad audit rejected that known integration difference before
compilation; the corrected audit explicitly checks the shim against its SoC
parent. No old shim was copied back into the hardware-facing integration.

Native build closes with stable pins and the **same 98 pre-existing third-party
structural warnings**, not a hard whole-SoC lint pass. Cold original DOS Quake
and Win95 runs use the same unmodified media, UV-fast mode, posted16 DDR3
transport, 40/40/80 MHz clocks and 16 MiB guest RAM. Their initial services
were rejected before launch because the service timeout did not match the
guard's exact 73-hour envelope. Corrected r2 services retain the 72-hour
native timeout and all existing acceptance checks:

- `ventium-raw-prime-quake-r2-oct09.service`, CPU27,
  invocation `da9ed12a57434234b718bc7f6f8afe03`.
- `ventium-raw-prime-win95-r2-oct09.service`, CPU28,
  invocation `98d0434d98734339981c3f63ea22231e`.

Neither is a completed standard-suite pass. CoreMark's 2.107/2.110 CM/MHz
result belongs to the **dispatch-only direct-memory model**, not this derivative
or the FPGA. Full seeds, complete timedemo/desktop qualification, generic gate,
gameplay ≥0.48, and whole-board synthesis/route remain acceptance requirements.

Reproduction with already qualified matched core models:

```sh
export TMPDIR=/home/yukidama/external/tmp
python3 -B verif/fe_pipe/prepare-raw-v-prime.py \
  --source /absolute/frozen/parent --out "$TMPDIR/new-private-candidate"
# Build that private candidate with the three defines above, UV-fast, AXI,
# assertions and the same remaining profile. Use a unique C++ harness basename.
python3 -B verif/fe_pipe/run-raw-v-prime.py \
  --control /absolute/parent/tb_ventium \
  --candidate /absolute/candidate/tb_ventium --out "$TMPDIR/new-prime-matrix"
```
