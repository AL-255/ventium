# Pipeline read/write wait cofactor — October 15, 2026

**Private experiment, not accepted or deployed.** Its closed, matched-mapper
synthesized/unplaced estimate is **37.950664137 MHz**, up **5.78%** from the
demand-width parent's **35.875726483 MHz**, but still below the 40 MHz target.
This is not routed timing or measured hardware frequency. No gameplay or
cycle-throughput gain is established.

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
| `pipe-wait-physical-r1` | All 36 INT/IRET and SMM native executions pass; 158,511 candidate records and 888 V retirements, exact parent state/clocks; 561.87 s |
| `pipe-wait-soc-r1` | Fresh full-PC build, 22.60 s; all 102 shared HDL inputs match the directed model, all 157 defines retained |
| `pipe-wait-lint-r1` | Strict CPU-hierarchy lint passed with the exact 159 hardware defines; six structural classes remain fatal |

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

### Saved cycle-cost accounting (no new processor run)

`verif/analyze_cycle_gate_costs.py` reads the canonical gate's **complete 20
cycle-trace pairs** through `tracefmt`. It conserves every retirement interval,
including startup and simultaneous U/V retirement, and retains the original
failed verdicts. Six host tests reject truncation, reordered instructions and
counter repair, and check empty/revisited-PC partitions and same-clock V events.
This is not a new correctness run, cache-cause oracle or warm-filtered PASS.

The analysis owner `ventium-cycle-cost-analysis-oct15-r1.service`, invocation
`7d5c11929d5749cfad87b7ed8674e1de`, closed with native status zero and MainPID
zero. It used 22,466,560 bytes peak RAM under a 384 MiB/no-swap/60-second cap.
All **105 input hashes** independently rechecked unchanged. Artifact:
`pipe-wait-cycle-costs-r1.json`, SHA-256
`0db08b454bb6fcf55be2b7affa946e19f52c362f782b5a97b2c7ccb9bda0ba3e`.
The saved original runs used `--cycle --l1-axi`, AXI read/write latency 7,
the directed candidate hash below and no debugger STEP/breakpoint override.

Selected results (full 20-kernel/per-PC intervals are in the artifact):

| Kernel | Reference clocks | RTL clocks | Excess at first PC occurrences | Excess at revisited PCs |
|---|---:|---:|---:|---:|
| `depadd` | 3,400 | 4,626 | 1,225 | 1 |
| `indepadd` | 1,802 | 3,028 | 1,225 | 1 |
| `faddchain` | 9,201 | 10,306 | 1,104 | 1 |
| `mul` | 4,819 | 5,355 | 137 | 399 |
| `imul2` | 4,818 | 5,425 | 208 | 399 |
| `rmimm` | 2,027 | 2,295 | 268 | 0 |
| `nearbr` | 1,290 | 1,732 | 441 | 1 |
| `dmiss` | 20,524 | 137,367 | 179 | 116,664 |
| `imiss` | 24,115 | 146,730 | 24,527 | 98,088 |

For `depadd`/`indepadd`, 99.918% of the excess appears on first PC occurrences;
each original native log records 20 fill starts, 1,320 fill clocks and 1,160
backing-wait clocks. This does **not** prove those intervals are entirely cache
cost, or establish a percentage of Quake's IPC gap. The fixed-eight-clock miss
estimate in the cycle reference is not an AXI beat/service-latency model.
Revisited PCs are not necessarily hits: the miss kernels retain their large
repeated costs rather than having them subtracted away.

Both multiply kernels have exactly **399 repeated 10→11-clock intervals** at
their multiply PCs (`0804800f` / `0804800a`). The MUL native profile contains
4,000 `S_EXEC` clocks for 400 multiplies: the ten-clock EX occupancy is correct.
The extra clock is the `S_PIPE` dispatch into `S_EXEC`, not an off-by-one EX
counter. A future improvement must overlap safe decode/operand handoff;
shortening the occupancy counter would hide the dispatch cost and violate the
existing `core_int_exec_occ.svh` invariant. No such RTL change, reference
promotion, comparator change or tolerance adjustment was made here.

Identities:

- Parent model: `cce12fc71c394b5a154e8bad108a3b88ab1d1acccba000f1961a26ea4f19d07d`.
- Candidate model: `c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a`.
- Parent `core.sv`: `fc02d7c55bfc0f33a0e8f87fdcf04d6a4709b97a420b8161e2d0effc0a854de1`.
- Candidate `core.sv`: `1430e18b5c039ab2ebb69e7cdf14d114ae6d0ee1dd4b63c72c2f4f2207b34076`.
- Leaf receipt: `a33faf577ca84074823c01459dfc014f4e919ab45633b15e480e0f95bdd53f66`.
- Full-PC model: `55e9255323354c314c102b2e7362ad3f9a5dfb1ca9c4e613a289f379936b6fce`.
- FPGA manifest: `d655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc`.

The hardware freeze rechecks 170 shared HDL inputs / 190 payloads against the
compiled full PC. Only `ventium/rtl/core/core.sv` changes. The actual project
Tcl source contract passes, with unchanged full P5 L1s, single-fill, posted-16
transport and requested 40/100 MHz core/PL clocks. An independent read-only
pass rechecked **13,894 transfer/export pins**. The freeze is **UNQUALIFIED**,
not a bitstream. The full-PC build retains 98 inherited structural warnings;
strict CPU-hierarchy lint is not a full-SoC structural-cleanliness claim.

Retained successful owners:

- Physical-address tests: `ventium-pipe-wait-physical-oct15-r1.service`,
  invocation `b68da418c5b5464eb4e95241930d3b89`.
- Full-PC build: `ventium-pipe-wait-soc-oct15-r1.service`, invocation
  `43ef88a30cff4132bdfda8039020ae4d`.
- Hardware-profile lint: `ventium-pipe-wait-lint-oct15-r1.service`, invocation
  `563e977d6f8c442b81eb2b58649d6eb8`.

Each owner is exited / MainPID zero / native status zero. The slowest SMM
metadata case completes in **6,040,521 clocks** on both models; its established
eight-million-cycle bound is retained, not mistaken for a completed run.

## Outstanding qualification

The INT/IRET and SMM tests above are simulations, not physical FPGA tests.
Both short ten-iteration cold CoreMark controls **passed** on the new full-PC
model. Owner `ventium-branch-address-cm10-pipe-wait-oct15-r1.service`, invocation
`dbc97700d80c48df8762401da4d36b2c`, is exited / MainPID zero / native status zero.
Actual native CPU12 affinity, 2 GiB RAM/no swap, exact argv and waited native
closures are retained. The independent audit rechecks **13,732 source pins**,
all five CRCs per seed, matching media and actual V execution, with zero OOM.

| Short seed | Ticks | V retirements | Host time |
|---|---:|---:|---:|
| Performance | 4,767,218 | 1,055,307 | 208.40 s |
| Validation | 4,753,406 | 1,054,254 | 211.46 s |

Both tick counts match the parent exactly: **0% cycle-throughput gain**.
The original duration-error message is retained: these are not duration-valid
scores, standard-suite passes or physical-board measurements. Evidence is
`pipe-wait-soc-r1/coremark-r1/{closed.json,audit.json}` under the root above.

Before accepting: measure timing with unchanged mapper
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

## One owned timing measurement launched

`prepare_pipe_wait_synthesis.py` preserves the previous synthesis/report
controllers' native wait, owner checks, mapper, clocks and resource limits
byte-for-byte. It adds the new leaf and mixed/held/store evidence requirements.
Five host tests check these adaptations, reject resource/native-exit mutations
and extra source changes, and verify the fixed-invocation reporting sequence.
The report Tcl is unchanged and the exact parent checkpoint is
`5ebc7472c4130f7939e0673d78df53a5fee378bc7d7da2adbd4d740bd471cfd5`.

The single synthesis launched **2026-10-15 22:24:00 UTC**, owner
`ventium-pipe-wait-synth-oct15-r1.service`, invocation
`2557906dc891404683ec0353d017f8d5`. Its owned Vivado scope invocation is
`b915257b1d6d446d85a655733543a449`. Admission saw **7,365,836,800 bytes** free
external disk and **24,210,165,760 bytes** available host RAM. The unchanged
disk guard requires both 6 GiB initially and twice the retained measured
parent growth (1,456,762,880 bytes) above the 4 GiB stop floor.

Limits remain 8 GiB scope RAM / 6 GiB swap, 13 GiB combined early stop, a
2 GiB host RAM/swap reserve and 45-minute native timeout. No compiler or other
Vivado family overlaps it. All normal child synthesis/helper processes belong
to that single owned family; they are not independent orphan runs.

`ventium-pipe-wait-timing-chain-oct15-r1.service`, invocation
`81350f4992c64591b417b4891ced23e5`, observes **only that synthesis invocation**.
Only successful native closure plus the independent DCP/source audit permits
the prepared read-only clock report. It does not restart synthesis, route,
program the board or waive a failed admission. No candidate frequency,
utilization or timing-closure result is claimed while synthesis is running.

## Closed synthesis and clock audit — October 15, 23:06 UTC

Both original owners and the sequencer are now exited, MainPID zero, native
status zero. The single Vivado family has closed. Synthesis took **1,896.90 s
(31.62 min)**; the read-only two-checkpoint audit took **603.24 s (10.05 min)**.
No resource stop, controller failure or OOM occurred. Synthesis peaked at
8 GiB RAM / 233,828,352 bytes swap; the report peaked at 4,507,537,408 bytes RAM
and zero swap. The independently closed synthesis audit rechecks **14,126
input pins**, all **159 actual defines** and 148 native `read_verilog` inputs;
the clock audit checks **14,130 pins**. No new route or bitstream was launched.

| Matched diagnostic result | Demand-width parent | Wait cofactor |
|---|---:|---:|
| Synthesized/unplaced core estimate | 35.875726483 MHz | **37.950664137 MHz** |
| Core setup slack at 40 MHz | -2.874 ns | -1.350 ns |
| CLB LUTs | 187,745 | 189,756 |
| CLB registers | 55,007 | 55,041 |
| BRAM tiles | 277.5 | 277.5 |
| DSPs | 47 | 47 |

The frequency estimate improves **5.78%**, but LUT usage increases **1.07%**;
this is not an area reduction. Core hold slack remains **-0.101 ns** (global
-0.108 ns). Both clocks retain their original 40/100 MHz constraints. The
diagnostic `Default -no_timing_driven` mapper is unchanged. The synthesis log
retains one generated-PS8 `create_clock` critical warning and 1,564 warnings;
native source completion does not imply a warning-free or routed design.

Worst core setup is now `q_pc[0]` → register-file `gpr[4][5]`, **93 logic levels**,
26.139 ns data delay: 6.299 ns logic + 19.840 ns estimated routing. The reported
path crosses decode/fetch qualification, U carry, `v_input_flags[0]`, V ALU and
GPR writeback, instead of the parent's worst EIP endpoint. The remaining path
therefore needs a further structural cut; relaxing clocks is not a 40 MHz pass.

Next investigation: the generic V ALU contains ADC/SBB result arithmetic,
although the actual decoder marks all their supported forms `pairs_second=0`
and every `issue_uv` pairing class requires that bit. A V result-only carry cut
may remove this unused serial U→V arithmetic. **Do not remove V flag carry
forwarding**: INC/DEC must preserve U's post-instruction carry. Before accepting
such a change, prove decode/held-packet eligibility, add an accepted-V runtime
assertion and datapath/whole-core controls, preserve all pairing and commit
enables, and rerun differential/standard/physical acceptance. No V-ALU RTL
change or measured gain for that proposed cut is claimed here.

Identities and durable evidence under the root above:

- Synthesized DCP: `1d9d3641ebe12b64f66e4b00f7dccd0da9a5b3c4f4de99d4116257a4cb02d30c`.
- `pipe-wait-synthesis-r1/audit.json`:
  `3e354c02df0b1617229d916917f83934e4a1dfdb28c90a954ad19530f8dc402c`.
- `pipe-wait-clock-r1/audit.json`:
  `2d40a5b84a65eb4be6b642553e70f60e69e2a5e7a164afecc9bb7069fb94d9db`.
- Clock owner `ventium-pipe-wait-clock-oct15-r1.service`, invocation
  `930c66798f80481c81dfbb38879243e8`; native scope
  `8621b967b1f94f69b0e4caf766c41459`.
- `pipe-wait-sequence-closed.json` retains both successful independent audits.

The canonical gate, full standard suite, 40 MHz synthesized target, routed
timing and matching physical Win95/Quake acceptance remain open. Candidate
gameplay IPC remains unmeasured; the older baseline at the top is unchanged.

## Recoverable storage cleanup

To satisfy the existing disk guard without relaxing it, **4,210 closed,
unpinned `.vtrace` files** were archived losslessly. Every member was read
back and SHA-256 verified before its original was removed. Original trace
bytes total **985,242,038**; the two archives total **5,652,824 bytes**. Four
unused precompiled-header caches, **377,649,511 bytes**, were also removed;
they are regenerable. Executables, sources, dependency records, native logs,
original receipts and all active-run input pins remain intact.

Archives under the evidence root:

- `closed-pipe-wait-traces-oct15.tar.zst`, SHA-256
  `76b7a0d6dbc94b1de938621a5ce899df2216a83a342b41a8f35df033e1ca2158`.
- `closed-pipe-wait-reserve-oct15.tar.zst`, SHA-256
  `ffd2457d00a3ff10ed6ca5f17640632b68da5049bd4dc90adb03a4c63d592de0`.

Restore traces into a chosen inspection directory with
`zstd -dc ARCHIVE | tar -xf - -C DESTINATION`; each member retains its original
run-relative path. Inspect archive names before restoring into the evidence
root to avoid overwriting newer files. Exact removed paths, hashes, producing
owners and stable-pin checks are retained in `closed-pipe-wait-storage-oct15.json`
and `closed-pipe-wait-reserve-oct15.json`.

The first cleanup attempt failed before deletion because non-dumpable desktop
processes deny `/proc` descriptor reads. That failed owner and script remain.
The successful attempts explicitly record inaccessible PIDs, rather than claim
every descriptor was inspected. Authority was the terminal producing jobs,
absence of compilers, exact unpinned targets, live-consumer pin checks and the
verified restore archives. Both successful cleanup owners are terminal.
