# Pipeline read/write wait cofactor — October 15, 2026

**Private experiment, not accepted or deployed.** The change has no measured
frequency or gameplay gain. Its demand-width parent's synthesized/unplaced
estimate is **35.875726483 MHz**, below the 40 MHz target; that estimate does
not qualify this derivative or establish routed timing.

Latest verified gameplay IPC: **0.50520554 total U+V**, older model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
5,600,065,237–5,700,065,237. Current candidate gameplay IPC is **unmeasured**.

## Exact change and rationale

The [demand-width timing audit](../fetchguard/DEMAND_SIZE_PAYLOAD.md) finds
the remaining worst path crossing paired-store readiness, general memory ACK,
integer commit and EIP. This experiment changes only the private core's wait
expression:

```systemverilog
// Parent
assign pipe_mem_wait = (pipe_load_req || pipe_store_req) && !mem_ack;
// Candidate
assign pipe_mem_wait = (pipe_load_req && !mem_read_ack) ||
                       (pipe_store_req && !mem_ack);
```

The existing read ACK already has the same `!fx_hold_e` final-fragment
qualification. Its read-owner equivalence assertion is retained. U-load and
U-store ownership are mutually exclusive, including held packets. A new
simulation-only shadow asserts complete old/new wait equality every clock,
exclusive U ownership and `!mem_we && mem_read_ack == mem_ack` for loads.

**Mixed U-load/V-store acceptance is not bypassed:** V still requires its
separate request, ready and pair ACK plus ordinary U ACK. The candidate does
not replace that condition. Stores continue using general ACK. The existing
fallback configuration aliases read ACK to general ACK.

No stage, register, cycle, bubble, pairing restriction, cache-size change,
guest-specific behavior or saved-state dependency is added. Default dirty
checkout RTL is untouched; the hash-locked recipe applies to the complete
tested private parent. This is a timing-cone experiment, **not an IPC fix**.
The remaining store cone may still limit timing; synthesis must establish
whether this expression actually helps.

## Evidence and limits

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
All results below use native waited completion and unchanged input pins.

| Run | Closed result |
|---|---|
| `pipe-wait-leaf-r1` | 25,169,920 actual RTL input vectors across early/fallback profiles; both positive runs pass and all eight negative controls fail as required |
| `pipe-wait-core-r1` | Fresh 32-job directed build, 19.61 s; one changed source among 195, all 153 defines retained |
| `pipe-wait-memory-r1` | 72 cold paged fixtures × latencies 0/7; complete QEMU state and exact parent traces/clocks; 31,392 candidate records, 1,500 memory V retirements; 27.40 s |
| `pipe-wait-held-r1` | 24 fixtures × latencies 0/7; exact state/clocks; 9,200 candidate records, 1,360 V retirements, 346 held-read prime witnesses |
| `pipe-wait-integer-r1` | 256 fixtures × latencies 0/7; exact parent state/clocks; 169,472 candidate records, 2,048 paired-store retirements; 36.91 s |
| `pipe-wait-mixed-r1` | 36 cold U-load/V-store fixtures × latencies 0/7; complete QEMU and exact parent state/clocks; 19,152 candidate records, 240 actual V stores; 10.22 s |
| `pipe-wait-boundary-r1` | All 22 fetch-boundary fixtures × latencies 0/7; 21,832 candidate records, 4,968 V retirements and 44 probe witnesses; 23.79 s |
| `pipe-wait-system-r1` | Five bounded/relocated, store-retry and invalid-SS fixtures × latencies 0/7/31; original witnesses, full QEMU state and exact parent clocks; 22.64 s |
| `pipe-wait-delivery-r1` | All 144 FPREM/waiting-x87/#NM/#MF native executions pass with exact parent traces/clocks; 74.40 s |
| `pipe-wait-func-r1` | 108/108 programs pass against the existing repaired private QEMU reference; 225.81 s; **not canonical acceptance** |
| `pipe-wait-matched-inputs-r1` | 108/108 complete streams, 80,800 records equal; identical flattened images and initial ESP; no normalization; 42.65 s |

The leaf uses the actual request equations, complete S_PIPE bus arm and
fragment equations. Translation cancellation and the existing seam ACK
contract are abstract inputs. It is **not a full-core or cache formal proof**.
Negative controls check raw/unfragmented ACK, forced read completion, using
read ACK for stores, and dropping store wait, in both profiles.

The new mixed-store fixtures immediately read back each changing store value
and check it against the written signature. Aligned different-bank stores
must actually retire on V; same-bank and unaligned forms must not. Flat and
relocated clients are covered at six instruction alignments. Candidate logs
show 2,592 completed pipeline reads, including 1,140 held and 312 paired
read-completion witnesses. These are microtest counts, not gameplay IPC.

All core tests retain UV + fast-pipe with `cycle_mode=1`, `--l1-axi`, normal
serialization and actual V-retirement checks. No STEP or intended-V breakpoint
is introduced. Fourteen host tests cover recipe scope/reversal, source drift,
missing or ineffective negative controls, incomplete/OOM receipts, mixed-store
coverage, the full-PC source transfer and unchanged hardware defines.

Canonical `make verify` remains **FAIL**, native make exit 2, 423.91 s:
7 functional PASS / 101 FAIL, with the same 90 first-reported length mismatches
and 11 first-reported x87 status differences as the parent. Its existing
worker policy runs serially despite a requested four workers. All 20 cycle
RTL streams equal the parent's complete records; this is **not cycle-band
acceptance**. No comparator, mask, golden or tolerance was changed. The
private-reference pass and identical-input replay do not override this gate.

Identities:

- Parent model: `cce12fc71c394b5a154e8bad108a3b88ab1d1acccba000f1961a26ea4f19d07d`.
- Candidate model: `c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a`.
- Parent `core.sv`: `fc02d7c55bfc0f33a0e8f87fdcf04d6a4709b97a420b8161e2d0effc0a854de1`.
- Candidate `core.sv`: `1430e18b5c039ab2ebb69e7cdf14d114ae6d0ee1dd4b63c72c2f4f2207b34076`.
- Leaf receipt: `a33faf577ca84074823c01459dfc014f4e919ab45633b15e480e0f95bdd53f66`.

## Outstanding qualification

Cold INT/IRET and SMM physical-address-owner tests are still running. These
are simulations, not physical FPGA tests. Full-PC transfer/export tooling
is prepared and host-tested, but no full-PC build, hardware freeze, lint,
CoreMark result or timing measurement is claimed yet for this candidate.

Before accepting: close those checks, measure timing with unchanged mapper
and constraints, restore canonical gate correctness deliberately, pass the
complete simulated standard suite and validate matching FPGA Win95 cold
boot/UI plus full Quake timedemo. Explicit concurrent snoop/flush injection
is not supplied by the mixed-store corpus; the always-active equality shadow
and source-level cancellation coverage do not replace that directed coverage.

The continuing cold DOS Quake 1.06/FreeDOS run uses the older DECODE-bus model
`7e877b3b…`, not this candidate. Startup progress cannot qualify gameplay or
timedemo completion. No board reset, programming or frequency change was
performed for this experiment. Chrome had already exited when permission to
close it arrived; no browser was killed.
