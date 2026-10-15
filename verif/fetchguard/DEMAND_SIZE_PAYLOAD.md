# Request-independent demand-fetch width — October 15, 2026

**Private candidate; not accepted or deployed.** The closed synthesized/unplaced
estimate is **35.875726483 MHz**, up **5.36342%** from the matched predecessor's
34.049507985 MHz, but still below 40 MHz. Synthesis and the independent R2 clock
audit pass; R1's failed host-RAM admission is retained separately. Gameplay,
routed timing and physical-board performance remain unmeasured.

Last verified gameplay IPC: **0.50520554 total U+V**, older model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
5,600,065,237–5,700,065,237. This is a baseline, not this candidate's IPC.

## Why and what changed

The [early-bus timing audit](EARLY_BUS_PAYLOAD.md) identifies a 100-level
path from `q_pc[0]` through demand-width qualification, fragment strobes,
route/cache qualification and memory ACK to interrupt-state enables.
`prepare_demand_size_payload.py` removes only the request gate and zero
default from the **width payload** calculation in private `core.sv`:

```systemverilog
// Before: calculate size only if sfetch_demand_req; otherwise zero.
// Candidate: calculate the same size independently of that request.
size = min(4, d_fetch_need - sfetch_valid_q);
if (sfetch_interior16) size = 4; // Existing profile-specific override.
size = min(size, bytes_remaining_in_page); // Existing exact page clip.
```

This pseudocode is explanatory; the exact-width SystemVerilog expressions
and compile-time profile guard are unchanged. No issued fetch is widened.
Request, #NM/#GP priority, translation, page/segment checks and byte-commit
conditions are unchanged. No pipeline stage, bubble, cache-size reduction,
guest-specific behavior, snapshot dependency or disabled V path is added.
All 153 directed-model defines, including strict waiting-x87 #MF, are retained.

An inactive payload may differ. A simulation-only copy of the complete old
expression asserts exact issued-width equality and legal page extent. Another
assertion checks that a no-request boundary fetch cannot acquire bus, MMU,
fault or fragment-start authority. The previous complete bus-driver shadow
remains. Assertions are excluded from hardware by `SYNTHESIS`.

## Closed evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Successful receipts retain waited native exits and unchanged source hashes.

| Evidence | Result | Scope |
|---|---|---|
| `demand-size-leaf-r1` | 458,752 actual RTL input tuples; six incorrect variants rejected | Both demand profiles, all 5-bit need/valid values, control combinations and seven page-offset classes; not full-core/formal proof |
| `demand-size-core-r1` | Fresh 32-job build, 20.56 s | One changed source out of 195; private model-dependent host object; unchanged defines |
| `demand-size-boundary-r1` | 22 cases × latency 0/7 pass, 27.72 s | Full QEMU state and exact parent traces/clocks; 21,832 records, 4,968 V retirements, 44 probe witnesses |
| `demand-size-system-r1` | Five fixtures × latency 0/7/31 pass, 22.84 s | Bounded/relocated accesses, store fault/retry and invalid SS; unchanged witnesses/comparisons |
| `demand-size-delivery-r1` | All 144 native executions pass, 78.71 s | FPREM, waiting-x87, #NM/#MF delivery/recovery; exact parent traces/clocks |
| `demand-size-func-r1` | 108/108 pass, 226.08 s | Existing private QEMU reference and comparison policy; not canonical acceptance |
| `demand-size-matched-inputs-r1` | 108/108 complete streams / 80,800 records equal, 48.70 s | Identical flattened images and golden-derived initial ESP; no masks or record normalization; 32 workers |
| `demand-size-physical-r1` | 36 native executions pass, 614.44 s | Cold INT/IRET, relocated IVT and SMM/RSM save-map/metadata witnesses; 158,511 candidate records / 888 V; exact parent traces/clocks |
| `demand-size-soc-r1` | Fresh 32-job full-PC build, 23.37 s | 102 shared HDL inputs match directed model; all 157 defines retained; 98 inherited structural warnings unchanged, not a full-SoC lint pass |
| `demand-size-lint-r1` | Strict CPU-hierarchy lint pass, 3.93 s | Exact 159 hardware defines; six structural error classes remain fatal |

The three mutation classes are incorrect issued width, missing page clipping,
and reinstated request-dependent payload calculation. The last fails the
separate timing-structure property, **not** ISA correctness of the old design.
Three source-scope tests and three build/receipt tests pass; the latter reject
missing profiles, un-waited processes, ineffective negative controls, missing
coverage and OOM evidence. Three full-PC transfer host tests also pass, but do
not constitute a full-PC build or guest run.

Actual `cycle_mode=1`, AXI backend service and paired V retirement are checked
in directed tests. No debugger STEP or intended-V breakpoint is used. Test
retirement counts are not gameplay IPC.

Identities:

- Parent directed model: `c55b996c2c8309e2c152dbab2813a144e5e30db83df6acfa190425e94067b84f`.
- Candidate directed model: `cce12fc71c394b5a154e8bad108a3b88ab1d1acccba000f1961a26ea4f19d07d`.
- Parent `core.sv`: `a26a7dc82d8ab0049bece36548373e57cd71b64547c44c02e2356bd7aa1f14ce`.
- Candidate `core.sv`: `fc02d7c55bfc0f33a0e8f87fdcf04d6a4709b97a420b8161e2d0effc0a854de1`.
- Full-PC candidate: `20cef474c2a10fca2ec27b26f09d88e9b7dc70ead963fab09ce28a6baaa4d60d`.
- FPGA input manifest: `d35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315`.

The FPGA freeze audits all 170 shared HDL files / 190 payloads and passes the
real Tcl source contract. Only `ventium/rtl/core/core.sv` changes. Hardware
defines, full P5 L1s, single-fill, posted-16 transport and 40/100 MHz requested
core/PL clocks remain unchanged. This freeze is explicitly **UNQUALIFIED**.
It does not yet include the separately staged PS/2 AUX owner repair.

## Remaining work

The SMM control uses an eight-million-cycle cap because the unchanged parent
already needs 6,040,521 clocks at latency 31. Both models reached the real
native exit 133 and every original witness in exactly that many clocks.
The successful owner is exited / MainPID zero; no incomplete run is a pass.

Canonical `make verify` also closes **FAIL**, native make exit 2, 479.78 s:
7 functional PASS / 101 FAIL, matching the parent count. Ninety first reports
are length differences; eleven first report x87 status differences. The old
QEMU observation misses the terminal record; neither that nor the status
differences are waived. All 20 cycle RTL streams match the parent exactly;
this is not cycle-band acceptance. No comparator, golden, mask or band changes.
The separate matched-input replay uses the same initial ESP/image and compares
all records, rather than normalizing separately initialized QEMU runs.

Both short ten-iteration cold CoreMark CRC controls **passed**; they are not
duration-valid scores or the standard suite. The independent audit rechecks
13,713 source pins, all five CRCs per seed, actual CPU12 affinity, waited native
closures and zero OOM events. Performance takes **4,767,218 ticks**, 1,055,307 V
retirements, 215.70 s; validation takes **4,753,406 ticks**, 1,054,254 V
retirements, 219.64 s. Both match the parent exactly: **0% cycle gain**. The
duration-error message is retained. Owner
`ventium-branch-address-cm10-demand-size-oct15-r1.service`, invocation
`6eef136ec9924ecfa3ecd986cb1b8bb9`, is exited / MainPID zero.

The one matched diagnostic synthesis launched at **20:45:39 UTC** and closed
at **21:29:15 UTC**, under
`ventium-demand-size-synth-oct15-r1.service`, invocation
`690da7de4b1f4ed79bef83ab80db0a47`; the owned Vivado scope invocation is
`938e9e23e99e4cb984eee49855eeff80`. Admission observed 7,935,717,376 bytes free
external disk and 16,503,087,104 bytes available RAM. Limits remain 8 GiB RAM /
6 GiB swap, 13 GiB combined early stop, 4 GiB disk floor and 2 GiB host reserve.
Native lifetime, exact owner checks, one-Vivado lock and resource controls are
byte-identical to the closed parent. No compiler overlapped the synthesis.

Native exit is **0**, duration **2,616.16 seconds (43.60 minutes)**, all input
hashes unchanged, no resource-stop or OOM event. Peak resident scope memory is
**8,227,012,608 bytes** and peak swap **4,008,255,488 bytes**; these separate
peaks need not coincide. The owner is terminal, MainPID zero. The independent
closure audit passes **14,106 source pins**, 148 native HDL reads and all
159 unchanged hardware defines. It confirms the same mapper/constraints and
only `ventium/rtl/core/core.sv` changed. Native synthesis reports zero errors,
one critical warning and 1,558 warnings. The subsequent independent clock audit
verifies the actual 40/100 MHz constraints; this is not a warning waiver or
evidence of timing closure.

| Synthesized resources | Parent | Candidate | Change |
|---|---:|---:|---:|
| CLB LUTs | 187,708 | 187,745 | +37 (+0.020%) |
| CLB registers | 54,980 | 55,007 | +27 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

The RTL adds no registers; mapped register count can change through synthesis
optimization. No area or cycle-performance gain is claimed. Checkpoint SHA-256:
`5ebc7472c4130f7939e0673d78df53a5fee378bc7d7da2adbd4d740bd471cfd5`.
Independent synthesis-audit SHA-256:
`a8ee80404cdbf70e01c995065402c0a2d0772a3038a710d08d94095a9767a536`.

`ventium-demand-size-timing-chain-oct15-r1.service`, invocation
`aa9a95ce0ddf4e3b8b757f272163da8c`, successfully checked that exact synthesis
and its independent source/DCP audit, then attempted the read-only clock stage.
Clock owner `ventium-demand-size-clock-oct15-r1.service`, invocation
`f259d735df564873b2d2b2ef9fcb3949`, exited **1 before launching Vivado**:
available host RAM did not exceed its existing **10 GiB** admission threshold
(8 GiB grant plus 2 GiB reserve). The sequencer then closed failed, MainPID zero;
it did not retry, route or deploy. The failed preflight and synthesis success
are separate outcomes. No OOM occurred and the completed checkpoint is retained.

[`prepare_demand_size_clock_r2.py`](../../fpga/prepare_demand_size_clock_r2.py)
prepared a separate `demand-size-clock-r2` reporter and
`ventium-demand-size-clock-oct15-r2.service` identity. Its report Tcl, source,
mapper, clock, ownership, native-wait and resource checks are byte-identical
apart from the two service-name substitutions. Three host tests check exact
reversibility and reject changed admission limits, timing reports or structural
checks. Original R1 files/failed owners remain intact. The prepared receipt
retains the native admission traceback. Available RAM was about 5 GiB after
synthesis. The user subsequently authorized closing Chrome; by the new
preflight it had already exited, so this retry sent no browser termination
signal and changed no resource limits.

### Closed R2 clock audit

R2 launched at **21:39:45 UTC**, with 26,071,539,712 bytes available RAM,
27,527,020,544 bytes free swap and 7,702,069,248 bytes free external disk.
The unchanged admission thresholds are 10 GiB RAM, 8 GiB swap and 4 GiB disk.
It reused both completed synthesis projects; **no synthesis was restarted**.
The sole Vivado family retained CPU24–27, an 8 GiB RAM / 4 GiB swap cap,
11 GiB combined early stop, 2 GiB host reserve and 15-minute native timeout.
No compiler overlapped it.

Native exit is **0**, at **21:47:29 UTC**, after **463.24 seconds (7.72 minutes)**.
Peak scope memory is **5,723,074,560 bytes (5.33 GiB)**, with zero swap use,
OOM events or resource stops. The owner is exited / MainPID zero, invocation
`7d6a714ac53e4597a28c331f378de578`; its now-closed Vivado scope invocation is
`20f0752d581e4b92ba23f0e4a89880a9`. Independent `audit_closed.py` passes all
**14,110 input pins**, native closure, original clock constraints, zero black
boxes and zero checked structural DRC violations. It also reproduces the
parent's original timing, ruling out a changed-parent comparison.

| Synthesized/unplaced metric | Early-bus parent | Demand-width candidate |
|---|---:|---:|
| Core frequency estimate | 34.049507985 MHz | **35.875726483 MHz** |
| Setup slack at 40 MHz | -4.369 ns | -2.874 ns |
| Worst-path logic levels | 100 | 94 |
| Worst-path data delay | 29.072 ns | 27.663 ns |

Frequency estimate gain is **5.36342%**; this is not an IPC gain, routed
sign-off or a measured board frequency. Core hold slack remains **-0.101 ns**
(global hold -0.108 ns). The report still flags four output ports without
output delays and requests bus-skew reporting; this diagnostic audit is not
full timing-sign-off qualification. No constraint or timing exception changed.

All 30 worst sampled setup paths start at `q_pc[0]`: 24 end at EIP, four at
EFLAGS, one at the lock-session register and one at SMI-pending. The worst ends
at `eip[20]/D` and contains **21.750 ns estimated routing / 5.913 ns logic**.
It still crosses decoded fetch length/need, fragment strobes, route denial,
paired-store readiness, general ACK and integer commit. Rebuilt hierarchy
names alone do not establish a false path or justify a timing exception.

The separate V-response capture path has -2.065 ns setup slack and 91 logic
levels. Its transitive input cone has 68,373 cells / 21,560 startpoints versus
the parent's 68,685 / 21,556; these are reachability counts, **not exclusive
area ownership**. The total utilization change remains the +37 LUTs above.

Next source-level target, now an **unqualified private experiment**:
`pipe_mem_wait` still uses the general `mem_ack` for both loads and stores,
feeding `pipe_int_commit`. Investigate using the existing fragment-qualified
`mem_read_ack` only for proven read owners, retaining ordinary ACK for writes.
Prove load/store ownership, final-fragment suppression and complete old/new
wait equality before accepting it. Held/paired reads, stores, faults, snoops,
flushes and immediate completions need directed coverage and full parent
architectural/cycle comparisons. Do not globally replace ACK, remove store
admission checks or add a serialization bubble to make timing pass.

The subsequent [pipeline-wait experiment](../l1/PIPE_WAIT_READ_ACK.md) implements
that narrow split with complete old/new wait assertions and directed mixed
load/store checks. It has no timing or physical-board qualification yet; the
35.875726483 MHz result above belongs only to this demand-width parent.

Evidence: `demand-size-clock-r2/{closed.json,audit.json,*rpt}` under the root
above. Independent clock-audit SHA-256:
`c2a81798542f0f0e5b2a0695087966ce623f2283bd60b66a3e43aef696652f15`.

Full simulated standard
suite, valid CoreMark scoring, routed timing and physical Win95 desktop/UI
plus full Quake timedemo are also outstanding. The continuing cold Quake run
uses the older DECODE-bus model; it cannot qualify this candidate.

Storage: four unpinned, unused compiler PCH caches from the two closed builds
were deleted after open-handle and retained-pin checks, reclaiming
**377,649,366 bytes (360 MiB)**. They can be regenerated. Sources, executables,
headers/dependencies, traces and logs are retained; binary/build-receipt hashes
were rechecked afterward. Exact files and hashes are in
`closed-demand-pch-prune-oct15.json` under the evidence root above.

## Read-only board preflight

At **21:10 UTC October 15**, SSH to `riguke@rk-xczu15eg-f.local` succeeded;
the FPGA manager reported `operating`, with no `ao486d`, `ven_soc`, Quake or
Doom process found. No programming, reset, clock/MMIO write or deletion was
performed. The installed firmware file is still the older
`/lib/firmware/ventium_uvfast_bank64_40.bit.bin`, SHA-256
`fe9f539dfcfd9a1d909a33b561d5b7b6a0febf6e90c54b339f568d0cd496f71e`.
That file hash is not a readback proof of which image is loaded.

`/tmp/ao486/ao486d.posted-safe-oct08` matches the locally tested posted-drain
reset daemon byte-for-byte: SHA-256
`085c629bf84039f0dfd1983b9909026f0e18a811cf43730b68fb9d74357ee4d3`.
Local evidence is `ventium-posted-daemon-r2.0ynoRPKK/closed.json` under external
tmp. This removes a daemon-transfer prerequisite, not hardware acceptance.
Board free space is only **253,300,736 bytes** on `/` and **307,503,104 bytes**
on `/dev/shm`; recheck before transferring media or collecting captures.
The existing cold Win95 simulation launcher still requires 8 GiB free host
disk and a qualified ordinary UI-input path; neither check was bypassed.
