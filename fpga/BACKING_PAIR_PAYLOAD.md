# Early backing payload — October 12

Target: **at least 40 MHz synthesized Fmax**, UV+fast and full P5 caches.
This change is implemented in a **private source-matched derivative** and has
passed leaf/cache/AXI tests, whole-core regressions and whole-PC compilation.
Its closed **30.591330 MHz unplaced synthesized estimate is below 40 MHz and
below the retained best 30.676729 MHz**. It is not a release, standard-suite
pass or FPGA acceptance. The immediate predecessor was 30.556744 MHz.

## Measured problem and change

The previous synthesis's 30 worst paths traverse decode/address and route
classification, backing address selection, quadword write-buffer credit,
paired-store admission, general acknowledgement and `int_ret_eip` enable.
The worst path has 114 logic levels and 32.429 ns estimated data delay.
See [the closed timing report](FP_HIGH_VALID_COFACTOR.md#closed-timing-result-and-next-measured-target).

`ven_l1d` previously selected `m_addr`/`m_wstrb` only after the late `c_req`
qualification. However, `ven_axi_master.pair_quad_ok` consumes these fields
*before* request admission to determine whether two stores fit in one remaining
write-buffer slot. Prepare the U store payload, or the V payload for read/store
pairs, directly from the existing producer direction. Keep the original fill
address/zero-strobe override and all original request, direction, data, stream,
permission, pairing, ordering and backpressure equations unchanged.

No register, queue slot, cycle, speculative transaction, workload special case
or feature switch is added. The master still needs `m_req` to issue a transaction.
The change is gated by the existing dual-store configuration; the default
configuration remains identical. Unsynthesized assertions retain the original
complete backing producer and compare every control/data output, plus address
and strobes on both actual transactions **and blocked, observable credit hints**.
Unrequested payload changes are not simply assumed harmless.

Recipe: [`prepare_backing_pair_payload.py`](../verif/l1/prepare_backing_pair_payload.py).
Parent L1 SHA-256: `a9a1c8c640f2f5781765ca2f27979a664c1914fb14e4b93c348877b39ad29fae`.
Derivative: `15c3b939ac56928ad0484677058e3fad913cee9686de91940304e80bb202187f`.
The recipe refuses any predecessor drift or reapplication.

## Closed verification evidence

All paths below are under
`/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

| Evidence | Result | Scope |
|---|---|---|
| `backing-payload-leaf-r1` | 524,288 checks each in default, dual-store and dual+load-store configurations | Actual source-extracted combinational equations, binary stimuli in four-state Icarus; all four mutation controls fail |
| `backing-payload-cache-r3` | 737,677 edge comparisons; 414 next-read observations; 66,339 wide-response witnesses | Full 128-set, two-way, 32-byte-line banked L1s, all enabled outputs, state, tags, validity, LRU and every data-bank entry; wrong V-address control fails |
| `backing-payload-axi-r1` | 2,387 transaction-test clocks; 4,781 full-cache edge comparisons | Two actual full-profile L1s, **independent real AXI masters**, independent RAM slaves, all AXI signals and final 64 KiB memory compared; wrong U-address control fails |
| `backing-payload-core-r1` | Native compile exit 0, 20.91 seconds, input hashes unchanged | 195-source frozen derivative, same 152 defines, 32-job bounded build; private C++ object and matching generated-header dependency verified |
| `backing-payload-core-r1/verify-closed.json` | **FAIL**, native `make` exit 2; 7 functional passes / 101 failures; 396.48 seconds | Unmodified canonical gate, all 20 cycle streams exactly equal to the parent; no masking, golden or band changes |
| `backing-payload-fp-r1` | Native exit 0; 384 fixtures, 1,536 measurements, 208,128 candidate records, 768 actual V retirements | Complete QEMU/parent FP architectural comparisons; all 768 candidate/control cycle totals unchanged; 66.80 seconds, unchanged pins |
| `backing-payload-regressions-r1` | All 12 phases exit 0, 604.24 seconds, input hashes unchanged | Six boundary offsets, faults, integer, memory, held responses, branches and complete 108-program same-input replay (80,800 records) |
| `backing-payload-soc-r1` | Native compile exit 0, 23.61 seconds, input hashes unchanged | Exact L1+DMA transfer; 102 shared core RTL files checked, DMA checked separately; same 156 defines and 98 inherited structural diagnostics |
| `backing-payload-fpga-r1` | Source contract passed | 190 payloads, all 170 common HDL inputs source-matched to the PC build; same 158 hardware defines and 40/100 MHz constraints |
| `backing-payload-lint-r1` | Native exit 0, 3.83 seconds, input hashes unchanged | Strict CPU-hierarchy lint of the exact 158-define hardware export; not full-SoC lint |
| `backing-payload-soc-r1/coremark` | Both short cold-boot seeds and independent audit passed | All five CRCs per seed match QEMU; unchanged 4,767,218 / 4,753,406 ticks; actual V retirements 1,055,307 / 1,054,254; not duration-valid scores |

The AXI test observes 68 U stores, three V stores (including one load/store
pair), one one-slot fused quadword admission, 30 blocked-store clocks, 84
full-queue clocks and four cycles in which idle raw credit changes without
changing any admitted request or state. It exercises all 15 nonempty byte
masks at all four alignments, split stores, ordered readback, invalid-pair
rejection followed by single-store retry, flush/snoop, uncacheable cross-word
and page-edge reads, and out-of-window **unrequested** hints. It does not claim
to newly qualify AXI error injection, asynchronous CDC or the whole PC.

Both compiled cache tests enforce `IMPLICIT`, `PINMISSING`, `UNDRIVEN`,
`MULTIDRIVEN`, `LATCH`, and `UNOPTFLAT` as errors. Width/style diagnostics remain
visible; this is not a warning-free claim. No hierarchical cache/queue-state
writes or forced credits are used. Only the external RAM models are seeded.

The failed `backing-payload-cache-r1` remains failed: its positive test passed,
but removing the fill-strobe restoration did not fail that particular fixture
because its selected strobes were zero during fills. The leaf test does catch
that mutation. The replacement cache control corrupts an actual V store address.
`backing-payload-cache-r2` then stopped at a test-driver text-count assertion,
before compilation; r3 corrects that assertion and closes both native runs.
No RTL or acceptance condition was relaxed to obtain these results.

The full core's model hash is
`4c410b962f602cbb52d402c2072413ec74bc4d2fb020d392511d4637db24ec15`.
Its only source deltas from FP-HIGH-VALID are the L1 change above and the
already-committed [DMA declaration repair](DMA_DECLARATION_ORDER.md). The latter
is carried in the source closure for subsequent PC/FPGA transfer; the directed
core top does **not** instantiate DMA. Its separate real-controller evidence
is checked during preparation. No current-checkout or full-PC claim is made.

Closed compiler `.cpp`/`.o`/`.a`/`.gch` products from the six cache/AXI builds
were losslessly archived and verified before removing the uncompressed copies.
Sources, generated headers, accepted binaries, logs and receipts remain.
`backing-products-archive-closed.json` records all hashes and restore commands.

## Whole-PC transfer and next qualification

The unchanged canonical gate is closed **red**, not waived. Complete same-input
replay now passes for all 108 programs and 80,800 records: this derivative does
not change their parent results. That is regression evidence, not evidence that
the inherited functional failures are correct. Boundary offsets 0, 1, 24, 25,
29 and 4093 (both instruction alignments), all 32 fault measurements, 1,024
integer measurements, 288 memory measurements, 48 held-response cases and 2,560
branch measurements also passed. The exact coordinator
`ventium-backing-payload-checks-oct12.service`, invocation
`3a112d84a0e942d697f636be994a02a9`, closed natively with exit 0; its receipt
explicitly retains `canonical_gate_passed: false`.

The PC model is `87afedaa869e6d8a86f36e31ea7a880875e096b924389ae78e37e65d018ad466`.
Its build owner `ventium-backing-payload-soc-oct12.service`, invocation
`a4a4f43fc78f48acad783379b747b755`, closed successfully. The private C++ harness
object and matching generated-header dependency were checked. The export
manifest is `d6f856259c0cdef90c0ef3f1a97b0a5568bdba13b8eb9d3a8332fc351bc90c20`.
No additional source, clock, queue-depth or define change was admitted.

Closed FP/integer/memory/branch traces were independently re-compared, then
losslessly archived with every member byte-verified. Their native receipts,
fixtures, models and source pins remain unpacked; fault and replay artifacts
were not removed. `closed-backing-payload-{fp,regression}-text-closed.json`
records archive hashes and restore commands.

[`test_backing_pair_payload_flow.py`](../verif/l1/test_backing_pair_payload_flow.py)
passes five scheduling/source-admission tests. The export and synthesis
preparation helpers pass eight more tests, including rejection of missing,
extra or wrong source deltas, preservation of resource bounds and comparison
against the best retained checkpoint. The synthesis audit also requires the
old eight DMA generated-control undriven diagnostics to disappear.

Both unchanged short CoreMark seeds closed under
`ventium-v-carry-cm10-backing-payload-oct12.service`, invocation
`3296c316dc5f461d80bbfefdf036b07c`, with actual child affinity CPU 11. The
independent audit rechecked 3,756 source pins, native child closure and zero OOM
events. The sole console error is the expected **under-ten-second duration**
failure; these are CRC/cycle preflights, not error-free standard-suite results
or publishable CoreMark scores. The CPU lint owner also closed successfully.

At **17:19:41 UTC**, one synthesis launched as
`ventium-backing-payload-synth-oct12.service`, invocation
`821db0a58cad4ab7ab1526f00cd45435`; its single Vivado family is scope invocation
`4e6cdc2a87054eea90d3783e1f3d42b2`. Admission rechecked the exact sources,
canonical failure, replay, PC build, lint and both audited preflights. The
unchanged diagnostic `Default -no_timing_driven` mapper preserves a comparable
structural timing measurement; it does not constitute timing closure.

The bounds remain one worker, 8 GiB RAM / 6 GiB swap, 13 GiB combined early
stop, 2 GiB host reserve, 4 GiB live disk floor and 45-minute native timeout.
Starting disk reserve exceeds both 6 GiB and twice the measured parent growth
above that floor. Closed historical matrix text and the two closed builds'
four PCH files were byte-verified in lossless archives to restore that reserve;
no source, binary, media or active input was removed.

`ventium-backing-payload-report-queue-oct12.service`, invocation
`1ce9d17db029447cad350bc7d1824bfc`, waits on that exact synthesis owner. Only
after native closure and the independent source/DCP/DMA-diagnostic audit may it
launch the read-only original-clock timing comparison against **MEMDIV-QUERY,
the best retained 30.676729 MHz checkpoint**. It cannot launch another
synthesis, placement, routing or deployment. Receipts and controllers reside
in `backing-payload-synthesis-r1`, `backing-payload-clock-r1`, and
`backing-payload-report-queue-{started,closed}.json`.

### Closed synthesis and clock audit

At **17:51:28 UTC**, synthesis closes native zero in **1,906.84 seconds**.
The exact controller is terminal with PID zero. The independent closure audit
passes **4,144 pinned inputs / 158 hardware definitions / 148 native HDL files**,
and confirms the eight old DMA generated-scope undriven diagnostics are absent.
Peak scope memory is **8,589,766,656 bytes**, peak swap zero; there is no OOM,
resource stop or source drift. The inherited PS8 scoped-XDC unknown-clock-pin
warning and eight I-cache-bypass metadata set/reset warnings remain; no clean
warning or full-SoC correctness claim is made.

The queued read-only timing audit ran as
`ventium-backing-payload-clock-oct12.service`, invocation
`1f2b090e17d346499f4c3d8eeeb5b4dd`. It closes native zero at **17:59:44 UTC**
in **491.24 seconds**; its independent audit checks **4,159 input pins**, native
closure, original 100/40 MHz clocks and the best-parent checkpoint. Peak memory
is **4,700,164,096 bytes**, zero swap and no OOM. Both the report owner and its
coordinator are terminal, and the Vivado scope is empty. No implementation or
deployment is started.

| Result | Current candidate | Retained best MEMDIV-QUERY |
|---|---:|---:|
| Unplaced synthesized core estimate | **30.591330 MHz** | **30.676729 MHz** |
| Core setup slack at 40 MHz | -7.689 ns | -7.598 ns |
| LUTs | 186,579 | 186,766 |
| FFs | 54,941 | 54,831 |
| BRAM36 equivalents / DSPs | 277.5 / 47 | 277.5 / 47 |

Core hold slack is **-0.101 ns**. The new estimate is **0.113% above its
immediate predecessor but 0.278% below the retained best**; this is not a
successful frequency optimization. The coordinator explicitly records
`forty_mhz_synthesis_met: false`. The combined source delta includes the DMA
wiring repair, so whole-design area changes cannot be attributed solely to
backing payload preparation. No gameplay or CoreMark throughput gain is claimed.

### Next measured target: lookahead in paired-memory readiness

All 30 worst paths still end at `int_ret_eip` clock enables, but the dominant
route has changed. The path now has **111 logic levels / 32.392 ns data delay**:
6.161 ns logic and 26.231 ns estimated routing. The old route-extent/backing
address/quad-credit sequence is no longer on this first critical path. It now
traverses V decode/branch lookahead, next-address translation and permission,
`mem_next_req`, L1 paired-memory readiness, paired request and general ACK.

Selected first-path delays, subtracting the 2.902 ns launch-clock arrival:

| Path point | Cumulative data delay |
|---|---:|
| V descriptor length | 12.269 ns |
| V-branch lookahead selection | 15.425 ns |
| Next-read request | 23.348 ns |
| L1 paired-store readiness | 24.742 ns |
| Core paired-store request | 25.899 ns |
| L1 general ACK | 28.962 ns |
| Interrupt return-PC enable | 32.392 ns |

The next investigation is the read/store readiness exclusion
`!(c_next_req && rd_match)` and its core producer. Do **not** simply remove
this guard: the next lookup redirects the cache port and masks paired bank
writes. First prove whether a real active read/store-pair candidate can coexist
with any of the four next-request producers (AGI, reference, retained chain,
raw priming). Pair *shape* alone is insufficient to justify suppressing a
hint: an AGI clock can have decoded pair-shaped instructions without an active
architectural memory request. A valid cut must preserve those useful hints,
owner/cancellation rules, cache writes and actual U/V acceptance; require
targeted contention microtests and full architectural comparison before a
new synthesis. No replacement RTL cut is claimed here.

The final requirements remain ≥40 MHz synthesized Fmax, routed timing,
duration-valid CoreMark performance, the complete standard suite, and physical
UV+fast Windows 95 cold desktop/UI and original FreeDOS Quake full timedemo
acceptance. Later PS/2 work must be source-audited before that physical test.

Current derivative gameplay IPC is unmeasured. Older verified simulated
gameplay baseline: **0.51030715 total U+V retirement events/cycle**, model
`2b4d7a48453fb8f901730d70b5731d9fb6a5459a83fc36f69241f441a7ab298e`,
cycles **1,200,065,237–1,300,065,237**. It is neither FPGA IPC nor a complete-demo
average and does not qualify this derivative.
