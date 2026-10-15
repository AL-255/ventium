# Boundary-fetch extent isolation — October 15, 2026

**Rejected timing experiment: 34.177518029 MHz synthesized/unplaced**, versus
the retained prefix-payload parent's **36.591166892 MHz** (6.596% slower).
The functional equivalence checks below do not justify promoting a slower
implementation. No production RTL change, routed result, standard-suite pass
or FPGA acceptance is claimed. Neither rejected decoder selection nor
response-kind factoring is inherited.

## Change

The parent's 93-level worst path crosses late `d_fetch_need`, fetch size and
generic fragment crossing before cache-response selection and U/V writeback.
Boundary-fetch beats already clamp their size to the bytes remaining in the
current page. The actual bus driver's `S_FETCH` arm is unconditionally read-only.
Therefore their generic `fx_cross` predicate is always false, including idle
zero-byte beats. They need no second page-fragment calculation.

[The exact one-file recipe](prepare_fetch_fragment_extent.py) uses the existing
pre-fetch `cur_data_size` tap for that calculation and explicitly selects false
for `S_FETCH && sfetch_boundary`. All other states retain their original crossing
calculation; **non-boundary fetches are also unchanged**, without assuming a
reachable `fetch_word` range. The actual fetch size, request strobes, address,
page/CS authorization, overlength-fault probe, fragment sequencing and ACK
equations do not change. No cycle, register, queue or feature switch is added.
An unsynthesized assertion checks the new crossing predicate against the
original expression on every active core clock.

## Closed evidence

Scratch root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

- Three [recipe/proof tests](test_fetch_fragment_extent.py) pass. Two-state
  bit-vector inequality is UNSAT for all offsets, five-bit counts, data widths
  and request/direction controls. Removing the fetch exclusion, forcing data
  width four, or removing the original page clamp each produces SAT. This is
  an arithmetic contract, not sequential whole-core formal proof or X/Z proof.
- [Actual source-extracted RTL](run_fetch_fragment_extent.py) passes
  **8,529,920 cases in each of two demand-fetch profiles** (17,059,840 total).
  Each observes 2,976 nonzero edge fetches, 4,390,912 idle fetches and 2,224 data
  crossings. Both deliberately broken RTL variants fail in each profile.
  Native closure: 9.284 s, 201,723,904-byte peak, no OOM; exact source pins and
  CPU13–16 affinity retained. Owner `ventium-fetch-fragment-leaf-oct15-r5.service`,
  invocation `605c5cd902444705a33b0984e83213d4`.
- [Full-core build](build_fetch_fragment_core.py): 195 frozen sources, only
  `core.sv` changed, unchanged 152 definitions, UV/system/relocated fast paths,
  full caches, `--assert`, and `AXI_LINE_REPLAY=0`. The unique host object uses
  this model's generated header. Guarded 32-job build closes in **20.56 s**.
  Model SHA-256:
  `0698ce2f2e0de10ec1952704b63b40fd70fc8cbb682171d5ed83cade6e612c6c`.
- The [installed cache repair](../lib/GOLDEN_CACHE_PREEXIT.md#production-installation--october-15)
  is recorded separately as an exact qualified tooling delta. Old input
  receipts are not rewritten. Three transfer/adapter tests pass.
- Original 22-case boundary corpus: **176 RTL executions / 88 complete QEMU
  comparisons**, 21,832 candidate records, 4,968 V retirements and 44 required
  probe witnesses. All state/cycle A/B comparisons pass in **26.31 s**.
- Five cold system/fault fixtures, both models at AXI delay0/7/31: **30 native
  executions pass** in 25.52 s, with identical full state/cycles. No STEP,
  pairing disable, slow-mode workaround or snapshot was used.
- Canonical `make verify` closes **FAIL**, native make exit2, in **399.38 s**:
  **7 functional PASS / 101 FAIL**. All 20 cycle streams remain parent-identical.
  No timing band, reference binary, mask or instruction limit was changed.
- Private-oracle functional run closes **FAIL: 107/108**, not a corpus pass.
  Its `t_fastmem` golden actually contains `t_faststack`'s instructions while
  labelling itself `t_fastmem`. This is a newly observed golden-connection
  ownership defect, described below; the failed run is retained verbatim.

Leaf R1 rejects a misspelled build profile; R2 rejects a missing `.scope` suffix,
both before native tests. R3/R4 fail a required coverage counter: the initial
task-based fixture did not drive fetch controls as intended in generated code.
R5 sets controls on every sample and places the settle delay explicitly in the
stimulus loop. No DUT expression or expected result was relaxed. Coverage and
negative controls are necessary: old/new equality alone was insufficient.

## Newly exposed verification race

`fetch-fragment-func-r1` has a native, unmasked failure at record0 of
`t_fastmem`: expected EBP equals ESP, while the actual first instruction only
sets EDI. The golden's bytes start `89e5545883e810...`, exactly the adjacent
`t_faststack` ELF, not the requested `t_fastmem` ELF. It continues to its cap
384 rather than the target's 201 records. Both compiled images are retained.

The worker assigns adjacent TCP ports and retries failed golden generation on
`PORT+1`. Port41345, assigned to `t_fastmem`, was observed occupied by Steam;
port41346 belongs to the adjacent `t_faststack` job. The producer connects to
whatever answers that port without proving ownership by its launched QEMU.
The mislabeled program is confirmed; the exact first-attempt error is not
retained because the worker overwrites its retry log. Do not claim that missing
diagnostic was observed or erase/relabel the contaminated golden as a pass.

This defect is now reproduced and repaired by
[private, peer-authenticated sockets](../qemu-trace/OWNED_GDB.md). The functional
cache also includes the producer's source identity, avoiding reuse of the old
contaminated entry without deleting evidence. No RTL was changed for this fix.

`fetch-fragment-owned-func-r2` closes **108/108 private functional PASS** in
110.58 seconds, with unchanged inputs, observed QEMU/RTL CPU13–16 affinities
and no OOM. This is the same candidate, jobs, comparisons, masks and limits;
only the explicitly recorded verification-tool deltas differ.

`fetch-fragment-owned-same-input-r1` closes **108/108 PASS** in 170.90 seconds:
216 native executions, all 80,800 records exactly equal across both models and
the original candidate run, identical clocks and 30,132 V retirements in each
model. CPU13–16 child affinity is observed; no OOM. Owner
`ventium-fetch-fragment-owned-replay-oct15-r1.service`, invocation
`75c3a20c15fc4eb396e8c2f7c2833f18`, exits0 with no remaining main process.

[Independent artifact audit](audit_fetch_fragment_owned.py) regrades all
records and 18,982 pinned inputs: 108 functional passes, **105 without optional
x87 masks**, the same three existing stack-fault mask cases (`tx_regform`,
`tx_regform2`, `tx_stack`), and all 20 parent-identical cycle traces. No mask was
added or expanded. Canonical reference failures and FPGA/standard-suite
acceptance remain open.

## Full-PC transfer and short cold controls

[PC transfer](../../fpga/build_fetch_fragment_soc.py) checks the exact one-file
change across all 102 shared HDL sources. The guarded full-PC build passes in
24.39 seconds. All 156 definitions, UV-fast/full caches/single-fill/posted16
and the parent's 32-job, 10 GiB RAM / 2 GiB swap build limits are preserved.
The unique local harness object and its generated-header dependency are checked.
Model SHA-256:
`a97035b6138624e3ccd89c7ce0eabac8d069e3957e71e430144aae770629d06d`.
The full-PC build retains 98 pre-existing structural warnings: **not** a
full-SoC lint pass. Separate strict CPU-hierarchy lint passes in 3.98 seconds
with all six structural warning classes treated as errors.

[Hardware freeze](../../fpga/freeze_fetch_fragment_rk_candidate.py) compares
170 common HDL inputs, 117 filelist units and 49 include edges. Its 190-file
manifest changes only `ventium/rtl/core/core.sv`; the 158 hardware definitions
are the 156 simulation definitions plus `SYNTHESIS` and `VTM_NO_DPI`. The
40 MHz target and board profile remain unchanged. Manifest SHA-256:
`daa75aa75147262bef5001122ed533c74747fa6647e6d80fe4233a78939a3239`.
The manifest explicitly remains **UNQUALIFIED**.

The [44 environment-store fault cases](run_fetch_fragment_env_faults.py)
pass 88 complete RTL comparisons at AXI delays 0/7 in 11.28 seconds, with
unchanged pinned inputs, no OOM, actual backend activity and V retirement.
The [independent fetch audit](audit_fetch_fragment_fetch.py) regrades every
record of the earlier 22-case corpus and its 44 probe witnesses. The earlier
fetch controller's affinity was observed; that run did not record per-child
affinity, so do not claim it did.

Both [short, cold CoreMark controls](../../fpga/run_fetch_fragment_coremark.py)
pass under the real board-memory timing profile, with no snapshot or debugger
STEP and more than one million V retirements per seed. The
[independent audit](../../fpga/audit_fetch_fragment_coremark.py) checks complete
console output, native ownership/affinity, CRCs, inputs and parent cycle counts.

| Ten-iteration seed | CRCs (seed/list/matrix/state/final) | Guest ticks | Parent delta | Wall time |
|---|---|---:|---:|---:|
| Performance | `e9f5 e714 1fd7 8e3a fcaf` | 4,767,218 | 0 | 224.99 s |
| Validation | `18f2 e3c1 0747 8d84 c64e` | 4,753,406 | 0 | 213.85 s |

These runs are **duration-invalid diagnostics**, not CoreMark scores or a
standard-suite pass. They demonstrate no cycle-throughput regression in these
controls; they do not demonstrate a clock-frequency improvement.

The first control run is retained separately under `coremark/`: performance
passed, but the controller rejected an incomplete `/proc` argument observation
at validation startup, then terminated and reaped that child. It was not a
guest CRC failure. [The observer repair](../../fpga/native_observation.py)
retries incomplete observations for at most three seconds; it still requires
the live owned child's exact executable, arguments, start-time identity,
affinity and cgroup. Dead children and persistent mismatches fail closed.
Three negative/positive host tests pass. The successful repeat uses its own
`coremark-r2/` directory; neither failed evidence nor acceptance rules changed.

## Finite-CS RTL coverage, without waiving the reference failure

The original boundary differential gate aborts each finite-CS case at QEMU's
native failure, before running RTL. A separate
[self-checking RTL diagnostic](run_fetch_fragment_finite_cs.py) now executes
the **same eight BIOS images**, not replacement fixtures: flat/relocated CS,
instruction offsets 4080/4093/4094/4095, both models, AXI delays 0/7/31, and
both full-functional and cycle trace modes. No RTL or BIOS rebuild is needed.

R5 passes **96 native executions in 5.02 seconds**, with 35,905,536-byte peak
RAM, zero swap/OOM and observed child CPU13–16 affinities. Each run requires
guest exit133 (success byte `0x42`), precisely one #GP(0) at the original
instruction EIP, live L1 backing transactions and complete trace termination.
The unchanged guest handler checks the saved EIP/error code and unchanged
EAX/EBX, then returns through IRET; the caller checks exactly one fault and
no partial arithmetic/register commit. The ordinary paired control executes.
Full parent/candidate records and clocks are equal at each latency: **3,048
candidate functional records and 264 candidate V retirements**. Read-only
regrading rechecks all 96 receipts, logs, traces and 28 input pins.

A further [independent audit](audit_fetch_fragment_finite_cs.py) reuses the
existing [exception-delivery contract](audit_finite_cs_rtl.py), including all
architectural fields across the deliberate delivery record, the precise
16-byte stack-frame effect, handler entry and real same-cycle U/V partners
for **both** MOV controls. It also rechecks each model's 195-source closure
and the exact single-file transformation. All **48 complete parent/candidate
comparisons** pass, with no trace trimming or new masks. This extends the
earlier response-kind candidate's finite-CS coverage to this candidate and
adds AXI delay31; it does not claim those checks were absent from all prior work.

The first four runner attempts remain recorded, not relabelled as passes:
R1 rejects the TB's expected duplicate `VEN_FPREM` token before execution;
R2 wrongly requires a banner that is absent with explicit `--quiesce`;
R3 reads a functional register field from the distinct cycle-trace schema;
R4 assumes the assembly label `pair_v` must issue in V. The real alignment NOP
can instead occupy U while `pair_u` occupies V. The corrected checker requires
both control instructions and an actual same-cycle U/V pair within that code,
not a prescribed slot based on a label. Seven host tests cover these contracts
and reject missing faults, wrong restart EIP, missing transactions, broken
pair cycles, wrong trace mode and unexpected build-definition duplicates.
No DUT assertion or guest success criterion was relaxed.

Closed owner: `ventium-fetch-fragment-finite-cs-oct15-r5.service`, invocation
`8346a8f72f264c20b0fe0c4605b32597`, MainPID0 / exit0.
`fetch-fragment-finite-cs-r5/closed.json` SHA-256:
`ab3adfad83088023e6ef15426bd769602d361b1fad1e44040af22676288a55a5`.
This **does not repair or pass the original QEMU differential gate**. It closes
an RTL coverage gap while preserving the reference failure and all broader
acceptance requirements.

## Timing run and storage safeguards

[The timing controller preparation](../../fpga/prepare_fetch_fragment_synthesis.py)
retains the parent's lifecycle and resource guards unchanged. Two tests check
the inherited guards and reject a deliberately weakened disk reserve. The
single synthesis family is limited to 8 GiB RAM / 6 GiB swap, with a 45-minute
timeout and early-stop reserve checks. No concurrent Vivado run or route is
launched. This is an unplaced synthesis comparison, not FPGA acceptance.

Initial admission stopped **before launching Vivado** because free disk space
did not cover the reserve derived from the parent's 1,456,762,880-byte measured
growth. The guard was not reduced. Closed, byte-identical timing reports and
traces were hardlinked, preserving every path and verifying content hashes
before/after. Four unused compiler PCH caches (377,520,602 bytes) were removed
after checking closed owners, no open users and no pinned references. Source,
generated headers/makefiles, objects, models and evidence remain; the PCH
caches are rebuildable. The exact removal plan is retained in
`fetch-fragment-compiler-prune-plan.json`.

Synthesis was admitted with 7,568,551,936 bytes free. Its closed owner is
`ventium-fetch-fragment-synth-oct15-r1.service`, invocation
`f116adc06b8e4469a46cfb6301341626`; the failed admission is retained separately.
It closes native exit0 in **1,956.54 seconds**, inputs unchanged, no resource
stop/controller failure and no OOM. Peak scope RAM/swap are
8,449,413,120 / 2,086,707,200 bytes. The independent synthesis audit checks
27,393 input pins, all 158 definitions, 148 native `read_verilog` files,
the exact one-file delta, unchanged mapper and a readable checkpoint.

| Synthesis area | Prefix-payload parent | Fetch-fragment candidate | Delta |
|---|---:|---:|---:|
| LUTs | 186,045 | 186,530 | +485 (+0.261%) |
| Registers | 54,985 | 54,969 | -16 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

The native log retains one critical warning at generated PS-IP XDC line21
(`create_clock` on an unknown pin), also present in the parent, and 1,564
synthesis warnings. These are not waived. The separate clock audit must verify
actual clock objects and constraints; synthesis success alone is not sign-off.
DCP SHA-256:
`6c09459be05993db6a32d104776a31c1f3cc2f6cc392371cef83bbe403686267`.
Synthesis audit SHA-256:
`1b63f8beb277a21ac40619e0c4ce719decb1282befd7f241b55315e6edc38c9a`.

The separate read-only timing query closes successfully under
`ventium-fetch-fragment-clock-oct15-r1.service`, invocation
`4394c22721324d71b64c64b40c702061`, only after native synthesis and its independent
audit passed. Native exit0 in **463.41 seconds**, peak RAM 4,866,273,280 bytes,
zero swap and no OOM. The independent audit rechecks **23,223 input pins**, the
closed owner, actual 40 MHz core / 100 MHz PL clock objects and the parent's
original -2.329 ns setup result. Neither checkpoint is rebuilt or placed/routed.

| Unplaced timing | Prefix-payload parent | Fetch-fragment candidate |
|---|---:|---:|
| Setup slack at 25 ns | -2.329 ns | -4.259 ns |
| Derived Fmax estimate | 36.591166892 MHz | 34.177518029 MHz |
| Worst-path logic levels | 93 | 100 |

Candidate core hold slack is -0.101 ns. Its worst path is EIP to
`pipe_mem_v_hit_q`, with **29.048 ns data delay**: 6.097 ns logic and 22.951 ns
estimated interconnect (79.0%). Named nets traverse prefix/V decode,
`mc_prime_v_branch`, next-address/DTLB qualification, `mc_prepare_ok`,
`core_mem_next_req`, pair-bank readiness and paired-load acceptance. Of the
30 reported paths, 27 end in paired-read payload registers; the other two
besides the worst path end in L1 validity/LRU. These are report samples, not
an exhaustive path census; rebuilt hierarchy names are not RTL ownership.

The source-level simplification did not improve the mapped netlist. Preserve
the faster parent as the timing baseline; **do not route or deploy this
candidate**. The next investigation must account for both the parent's
fetch/response/writeback path and the newly exposed next-read/bank-arbitration
path, rather than assuming one shortened expression implies overall improvement.
Neither 40 MHz synthesized closure nor routed closure has been achieved.

Key closure hashes:

| Artifact | SHA-256 |
|---|---|
| `fetch-fragment-leaf-r5/closed.json` | `c521a2ef21d288398b6b70b3015a284b5e54615b4232ff366ba2fc1fcd07c11e` |
| `fetch-fragment-core-r1/build-closed.json` | `6bea87731add27f60e16bef3cd0bffcf359b6faf9415e181512ae92b362906d4` |
| `fetch-fragment-core-r1/verify-closed.json` | `7152577e2971a2531be53ad6d0df5c2f12212b33e473c4c82e107b217ee137bc` |
| `fetch-fragment-func-r1/closed.json` | `76e246f6e723a59378c9655f88143524b721e29e7993b2520e00ffd06febb14d` |
| `fetch-fragment-fetch-r1/closed.json` | `c780491ad79cb96dc0c956999ef52363dbf271fc698bbe6eefe0f71607078d90` |
| `fetch-fragment-owned-func-r2/closed.json` | `55712af50f9d8a69cfa0763fe27fa4bd409693fe5edffb9552a26980ed0d5569` |
| `fetch-fragment-owned-same-input-r1/closed.json` | `4a37fb82d06bbc78f285baadbef9f0cffdf9365b986cff1ea27fcc8c90c6a5e7` |
| `fetch-fragment-regression-audit.json` | `3f7c8b21b0e4023f721413cbdb70d7e243a244d360e90081dc494eee42949131` |
| `fetch-fragment-env-fault-r1/closed.json` | `02d30ff8d8aba16d322f6fa6130d02b53d96f58861b35eff91740f6a36b4dcff` |
| `fetch-fragment-lint-r1/closed.json` | `a19f263bd9cf1517bebae1498651380cabc1791df0d8f184f6594c33a2368e9f` |
| `fetch-fragment-clock-r1/closed.json` | `943373862435593eeaf648e874484627ff9e82693cf8fdf7aa95f89a55fa96d8` |
| `fetch-fragment-clock-r1/audit.json` | `e00ec7e1888b299ffec16ee304ed839d1d67259c120495683fe04e25ff5e9bf4` |
| `fetch-fragment-finite-cs-r5/audit.json` | `a5badad4455c9f53af9e308142c399ed2b253b00f015a3a08deacc79eaa1ff97` |

Current candidate gameplay is **unmeasured**. Latest verified gameplay remains
**0.50520554 total U+V IPC**, older model `c7b95b78`, cycles
**5,600,065,237–5,700,065,237**, predating this candidate. The physical board is
unchanged, and existing-image Doom still has no valid gameplay FPS.
