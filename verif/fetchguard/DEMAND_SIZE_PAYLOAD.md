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

## Remaining work

Canonical `make verify` and cold INT/IRET/SMM controls are in progress.
The SMM control uses an eight-million
cycle cap because the unchanged parent already needs 6,040,521 clocks at
latency 31; it must still reach the real exit and every original witness.

The canonical parent is **red**, not waived: 7 functional PASS / 101 FAIL,
including terminal-record and x87 status differences. Parent-equivalent cycle
streams are not cycle-band acceptance. No comparator, golden, mask or band
is changed here. A matched-input replay must use the same initial ESP/image,
not normalize divergent records from separate QEMU initial states.

Full-PC transfer, strict hardware-profile lint, cold CRC controls and a new
source-matched timing measurement remain pending. Full simulated standard
suite, valid CoreMark scoring, routed timing and physical Win95 desktop/UI
plus full Quake timedemo are also outstanding. The continuing cold Quake run
uses the older DECODE-bus model; it cannot qualify this candidate.
