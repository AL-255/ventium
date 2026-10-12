# Early backing payload — October 12

Target: **at least 40 MHz synthesized Fmax**, UV+fast and full P5 caches.
This change is implemented in a **private source-matched derivative** and has
passed leaf/cache/AXI tests, whole-core regressions and whole-PC compilation. **Timing is unmeasured;
it is not a release, standard-suite pass or FPGA acceptance.** The last timing
candidate was 30.556744 MHz; the best retained result is 30.676729 MHz.

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

Both unchanged short CoreMark seeds are running under
`ventium-v-carry-cm10-backing-payload-oct12.service` (CPU 11), and strict
CPU-hierarchy hardware-profile lint under
`ventium-backing-payload-lint-oct12.service`. Neither is a standard-suite pass;
the short seeds cannot establish a duration-valid score. No Vivado is running.
After these close, perform one bounded synthesis/timing comparison against the
**best retained** checkpoint, with sufficient disk reserve restored first.
Do not claim a timing gain from the source rewrite or passing equivalence tests.

The final requirements remain ≥40 MHz synthesized Fmax, routed timing,
duration-valid CoreMark performance, the complete standard suite, and physical
UV+fast Windows 95 cold desktop/UI and original FreeDOS Quake full timedemo
acceptance. Later PS/2 work must be source-audited before that physical test.

Current derivative gameplay IPC is unmeasured. Older verified simulated
gameplay baseline: **0.51030715 total U+V retirement events/cycle**, model
`2b4d7a48453fb8f901730d70b5731d9fb6a5459a83fc36f69241f441a7ab298e`,
cycles **1,200,065,237–1,300,065,237**. It is neither FPGA IPC nor a complete-demo
average and does not qualify this derivative.
