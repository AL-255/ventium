# Interior fetch-size output cofactor — 2026-10-16

Status: **private experiment; leaf/boundary/interior/private-functional checks,
exact PC transfer, short cold CoreMark controls and CPU lint passed; canonical
gate still FAIL; matched synthesis running, timing unmeasured**.
No production RTL, FPGA bitstream, timing constraints, cycle bands or reference
goldens were changed. No frequency/performance gain is established.

## Why this experiment

The [next-ready experiment](../l1/NEXT_READY_COFACTOR.md) reduced LUT use by
0.36% but **regressed** the matched unplaced frequency estimate from 36.968577
to 34.947928 MHz. Its worst 96-level path still traverses `d_fetch_need`,
`sfetch_want_size`, extent/routing, pair credit and ACK into GPR writeback.
Neither estimate is routed sign-off or measured hardware frequency.

The boundary-only stage already registers exact boundary sizes; its interior
arm selects `sfetch_want_size`. That producer first replaces the decoder count
with four whenever `sfetch_interior16` is true, then clips at the page end.
Consequently the selected interior arm cannot depend on the decoder count:

```
want = page_clip(interior ? 4 : decoded_remaining)
old_size = interior ? want : registered_boundary_size
new_size = interior ? page_clip(4) : registered_boundary_size
```

[The exact-source recipe](prepare_sfetch_interior_cofactor.py) makes this
cofactor explicit. It does **not** replace the result with a constant four:
`ffd/ffe/fff` still select `3/2/1`, even for otherwise unreachable input
combinations. Request generation, decoder, stage ownership, page-walk hold,
fault/header priority, reset, acknowledgment and byte-count updates are
unchanged. A non-synthesis assertion compares the **entire size payload every
post-reset clock**, not merely successful requests. The non-interior16 profile
keeps its original registered result.

The new model deliberately starts from the faster boundary-stage parent,
**not** the next-ready derivative. Only `rtl/core/core.sv` differs in the
195-source closure; all 153 definitions, assertion/error-class flags and
real-AXI model parameters are retained. There are no new stages, bubbles,
disabled pairing paths or workload-specific conditions.

## Evidence

Root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

| Check | Result |
| --- | --- |
| Source-extracted default-profile output miter | 196,608 comparisons pass |
| Source-extracted interior16-profile output miter | 196,608 comparisons pass |
| Negative controls | Missing page clip, wrong interior width and raw boundary width each fail |
| Binary symbolic proof | Equivalence `unsat`; non-vacuity and all three mutants `sat` |
| Host/source/build guard tests | 4 pass |
| Private whole-core compile | Exit0, 20.11 seconds, exact private harness/header binding |
| Original 22 fetch-boundary guests, both AXI delays | Pass: full QEMU state plus exact A/B state/cycle comparison |
| Fresh 108-program qualified-private-reference check | 108 pass; 80,800 records / 30,132 actual V retires; not canonical reference promotion |
| Original interior-fetch corpus, 48 cases / delays 0 and 7 | 192 measurements pass; independent complete-trace regrade finds 0% cycle delta |
| Unchanged canonical `make verify` | **FAIL**, native exit2; 7 functional PASS / 101 FAIL; all 20 cycle streams parent-identical |

The miter covers all 4,096 page offsets, both mux arms and all eight registered
size values, plus every pair of five-bit decoder/valid-byte counts at the last
eight page offsets. The symbolic proof covers **all** binary combinations of
these input widths, including count wrap and invalid stage sizes. It is a
combinational identity proof, not whole-core formal verification or an
unrestricted X/Z-control equivalence claim.

Leaf owner `ventium-sfetch-interior-leaf-oct16-r1.service`, invocation
`566a89d5c3a149cdb5c61a0a207c5a21`, closed exit0 / MainPID0 in **0.747 seconds**.
Actual child affinity was CPUs 18–19, all children waited/reaped, peak memory
**34,332,672 bytes**, no swap/OOM. Inputs, generated source, compiled images,
native logs, mutants and proof are retained in `sfetch-interior-leaf-r1`.
The core builder independently rechecked those artifacts and native closure.

Core build owner `ventium-sfetch-interior-build-oct16-r1.service`, invocation
`5aa9ac6d576046c99fcabb0a3e9c7aba`, used the unchanged exclusive 32-job guard,
10 GiB RAM / 2 GiB swap build scope and 600-second native deadline. Inputs
remained unchanged and the freshly named harness object uses this model's
generated header. No Vivado instance overlapped compilation.

The original boundary driver closed exit0 / MainPID0 in **24.50 seconds**:
**21,832 candidate records, 4,968 actual V retirements**, all inputs unchanged.
It ran 176 RTL and 88 native QEMU processes across the 22 original guests and
AXI delays 0/7, preserving complete state/cycle comparisons and all fault
witnesses. No stepping, snapshot, U-only fallback or pairing suppression was
substituted for the original workloads. Evidence: `sfetch-interior-boundary-r1`.

The fresh private-reference run closed in **107.94 seconds**; independent
[regrading](audit_sfetch_interior_func.py) checked **12,367 input pins**, actual
CPU4–7 native execution, complete architectural records and executable-image
identity. All 108 pass under the existing manifest policy; 105 also pass without
optional masks. `tx_regform`, `tx_regform2` and `tx_stack` still require the
**pre-existing** x87 stack-fault masks. The qualified private reference
`998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85`
has not replaced canonical QEMU. Peak memory: **161,189,888 bytes**.

The unchanged canonical gate closed in **391.43 seconds**, native exit2
(controller exit1). Its 7/101 functional verdict and nine failed cycle bands
remain failures; all 20 full cycle streams are parent-identical. No mask,
golden, band, comparison or guest was relaxed. This experiment is **not** a
canonical-gate repair or a standard-suite pass.

A later read-only inventory of the retained canonical results confirms all
**108 complete candidate/parent RTL architectural streams are identical**:
80,800 records. All 101 failed comparisons report the missing terminal record;
90 are length-only, while 11 first report an FSW C1 difference (`xor=0x200`).
The independent private-reference results do not erase these canonical failures.
Evidence: `sfetch-interior-canonical-inventory-r1.json`.

The original interior-fetch driver ran after that gate released the exclusive
guard: 32 queued workers, bounded eight concurrent native children, **5.14
seconds**, no OOM/process-limit event, all children reaped. Independent
[cycle regrading](audit_sfetch_interior_demand.py) checks **192 complete A/B
stream pairs** and all per-case clocks, hot intervals, warm loops and AXI
activity: exactly equal. Candidate cycle traces contain **15,200 records and
384 actual V retirements**, with **0% incremental cycle change**. Peak memory:
**363,503,616 bytes**. Neither these retire counts nor short-loop CPI is a
gameplay measurement. Evidence: `sfetch-interior-demand-r1/cycle-audit.json`.

Identities:

- Parent core model: `e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a`.
- Parent `core.sv`: `8d454c1ce275963da75354aca703701a4341b441031ae53f39e1fb911a365d0d`.
- Changed `core.sv`: `1a9ca5a3e883889dc121c8ae8380f30a01377b8f3681261cc4c1f7fe6160b104`.
- Candidate core model: `ffada6de537cbc101a255845d3094d5eb32fd642306c718734484217d3d7cc5a`.
- Core directory: `sfetch-interior-core-r1`.
- Boundary owner: `ventium-sfetch-interior-boundary-oct16-r1.service`, invocation `2509e3b6d2d949a0bd692e89eb28f889`.
- Canonical owner: `ventium-sfetch-interior-verify-oct16-r1.service`, invocation `f4249836e9c74e9ea5e7c37d339e5859`.
- Private functional owner: `ventium-sfetch-interior-func-oct16-r1.service`, invocation `553fc166e7a14ecca03db6b35ebb8b23`.
- Interior-fetch owner: `ventium-sfetch-interior-demand-oct16-r1.service`, invocation `64ac56cac3e7471eabe6a39f71065484`; native scope `a434ecaf2e974b59ab23cc8ded5e2ac7`.

## Exact full-PC transfer and short cold controls

[The PC transfer](../../fpga/build_sfetch_interior_soc.py) preserves the faster
boundary-stage parent `b32ab4b34482669c03ea57ce7be0dbd475623fa00b00c4c814fec976d75c86d2`,
not the next-ready timing regression. All **102 shared CPU/FP sources** are
checked; only the proven `rtl/core/core.sv` transformation differs. The **157
definitions**, native host, corrected AUX controller and posted-16 backend are
unchanged. This does **not** silently include the later keyboard/UI composition.

Full-PC build `ventium-sfetch-interior-soc-build-oct16-r1.service`, invocation
`b5b789e7ba314285836b5aa363f3d037`, closed native exit0 / MainPID0 in **22.59
seconds**. The private C++ object binds to this model's generated header, all
inputs remain unchanged, and the **98 inherited full-PC structural warnings**
are unchanged—not waived or counted as a full-SoC lint pass. Model:
`bccf110432a3ce42085841ee7dbb9056adaf277220b571b106cf91e6364eec76`.

[Two concurrent short controls](../../fpga/run_sfetch_interior_coremark.py)
cold-boot the original 10-iteration disks without patches or snapshots. Actual
native affinity is CPU12 / CPU13, with the real AXI backend and `cycle_mode=1`.
The original checker and original reference CRCs remain mandatory.

| Seed | Parent ticks | Candidate ticks | Incremental cycle change | Actual V retirements at final sample |
| --- | ---: | ---: | ---: | ---: |
| Performance | 4,771,298 | 4,771,298 | 0% | 1,055,307 |
| Validation | 4,755,366 | 4,755,366 | 0% | 1,054,254 |

Performance CRCs: `e9f5/e714/1fd7/8e3a/fcaf`; validation CRCs:
`18f2/e3c1/0747/8d84/c64e`. Both match the original reference. Native runtimes
are **214.26 / 217.01 seconds**, both exit0 and reaped. Independent
[regrading](../../fpga/audit_sfetch_interior_coremark.py) verifies **27,433
source pins**, full native argv/affinity/image identity, closed owner and exact
cycle equality. Owner `ventium-sfetch-interior-cm10-oct16-r1.service`, invocation
`8b1097944998449db0d84acd19db31ac`, is closed MainPID0 / exit0, peak
**53,362,688 bytes**, no OOM. These are **not duration-valid CM/MHz scores**, full
CoreMark seeds, the standard suite, or gameplay measurements.

## Hardware export and matched timing experiment

[The sealed export](../../fpga/freeze_sfetch_interior_rk_candidate.py) compares
all **192 payloads / 170 common compiled HDL sources** against
`sfetch-boundary-fpga-r1`. Only `ventium/rtl/core/core.sv` changes. The corrected
posted-DDR mouse wrapper, all **159 hardware definitions**, 40/100 MHz clock
constraints, cache geometry and mapper are retained. Posted/nonposted wrapper
preprocessing succeeds; it is not full-wrapper elaboration or board acceptance.
Manifest SHA-256:
`eeccdcf17f7641c80d07718ba6d88b2241912b7f6e3e53d325a1a5d2710c7cd0`.

Strict CPU-hierarchy lint closes native exit0 in **3.78 seconds**, all source
pins unchanged; owner `ventium-sfetch-interior-lint-oct16-r1.service`, invocation
`27949ae7c24049c2a18deedc9e654ec4`. All six structural error classes retain their
original fatal policy. **11 host tests** cover the source transfer, profile
rejections, parallel native controls, resource-guard mutants and exact sequencer
ownership.

One matched synthesis starts at **2026-10-16 06:52:59 UTC** under
`ventium-sfetch-interior-synth-oct16-r1.service`, invocation
`ad8028d56f994bd8ac7a081b4ded17c9`; native exclusive scope invocation
`15acde49eb6c4784af3065d3ed965e44`. The existing 8 GiB RAM / 6 GiB swap cap,
13 GiB combined early stop, 4 GiB free-disk floor, 2 GiB host reserve and
45-minute native deadline are unchanged. Disk admission retains twice the
measured parent's growth above the floor; no second Vivado family is allowed.

The [one-shot sequencer](../../fpga/run_sfetch_interior_timing_sequence.py),
owner `ventium-sfetch-interior-timing-chain-oct16-r1.service`, invocation
`e4ffeb87989f40a3937f8f6ad535db88`, observes this exact synthesis, independently
audits its native closure, then runs the prepared read-only clock comparison.
It cannot retry synthesis, start implementation or deploy a bitstream. Timing
results remain **pending**; neither a 40 MHz constraint nor passing compilation
establishes 40 MHz capability.

## Prepared input-repair composition

While that exact CAD sequence runs, the [source-only UI transfer](../../fpga/build_sfetch_interior_ui_soc.py)
prepares `sfetch-interior-ui-soc-r1`. It rechecks both closed parent builds,
the exact short CoreMark control audit, all source pins and the qualified
controller/injector pressure-test evidence. No CPU source, memory timing,
definition or fast-pipe connection changes. The only platform RTL replacement
is the previously tested `ps2.v` controller
`9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405`.
Its native input host and `kb_fifo_rdreq` binding are copied exactly from the
qualified input parent `0e25af3b6831e0acc44a0f0faba224f66316be2a499127165a66534893983779`.
The new C++ basename is private to this model; generated objects are not copied.
The prepared source closure has **28,816 pins**.

Three transfer tests reject modified CPU/controller/host sources and verify
the closed-cycle controls; two build-owner tests reject replaced, failed,
missing and nonterminal CAD owners. The [one-shot build waiter](../../fpga/run_sfetch_interior_ui_build.py)
runs under `ventium-sfetch-interior-ui-build-oct16-r1.service`, invocation
`53e924c6530d4c6cb42cc694b8626fb4`. It observes the exact timing-chain invocation
above and cannot compile until both native CAD phases and their independent
audits close successfully. It retains the original exclusive build lock,
32-job resource guard, Verilator version probe and 5 GiB disk admission.

At this update it is **waiting; no combined model has been compiled or run**.
A prepared tree is not input qualification for this CPU. After compilation,
the unchanged raw/translated cold-input guest and both short CRC controls must
run on its actual binary. Full Win95 UI, full standard suite and matching
physical FPGA tests remain separate. This preparation does not change the
in-flight hardware export or silently inherit its eventual timing result.

## Remaining qualification

The bounded whole-core comparisons above are complete; they are not exhaustive
correctness proof. Exact source transfer and short CoreMark controls are now
complete. Next require matched synthesis/path analysis, then routed 40 MHz closure. Mapping
may reshare logic; a cleaner expression is not evidence of faster hardware.
The canonical gate, complete standard suite, and matching physical-board Win95
cold desktop/input and complete Quake timedemo remain mandatory.

Candidate gameplay IPC is **unmeasured**. The newer audited older-build baseline
is now **0.48146083 total U+V**, V-result model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`, cycles
**1,100,065,247–1,200,065,247**. U-only IPC is 0.37609117; the remaining
0.10536966 is V retirement. See the [new window audit](../../fpga/audit_v_result_gameplay_window.py).
This model predates the current boundary/interior-fetch and later input
candidates. It is neither full timedemo completion nor FPGA acceptance.
The immutable synthesis-start receipt retains the baseline known at launch:
0.49046518 on `7e877b3b`, cycles 1,600,065,247–1,700,065,247. Different windows
must not be treated as a measured performance regression.
