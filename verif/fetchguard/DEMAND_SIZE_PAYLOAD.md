# Request-independent demand-fetch width — October 15, 2026

**Private candidate; not accepted or deployed.** The predecessor's closed
estimate is **34.049507985 MHz synthesized/unplaced**, below 40 MHz. This
candidate has no frequency, gameplay or physical-board measurement yet.

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

The one matched diagnostic synthesis launched at **20:45:39 UTC**, under
`ventium-demand-size-synth-oct15-r1.service`, invocation
`690da7de4b1f4ed79bef83ab80db0a47`; the owned Vivado scope invocation is
`938e9e23e99e4cb984eee49855eeff80`. Admission observed 7,935,717,376 bytes free
external disk and 16,503,087,104 bytes available RAM. Limits remain 8 GiB RAM /
6 GiB swap, 13 GiB combined early stop, 4 GiB disk floor and 2 GiB host reserve.
Native lifetime, exact owner checks, one-Vivado lock and resource controls are
byte-identical to the closed parent. No compiler overlaps the synthesis.

`ventium-demand-size-timing-chain-oct15-r1.service`, invocation
`aa9a95ce0ddf4e3b8b757f272163da8c`, observes only that exact synthesis. It
requires successful waited closure and an independent source/DCP audit before
launching the read-only clock audit. It cannot retry synthesis, route or deploy.
Host tests reject relaxed stops, fake success, changed owners and additional
source changes. Candidate synthesized frequency remains **unknown** until the
new reports close; the 40 MHz constraint is not a measurement.

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
