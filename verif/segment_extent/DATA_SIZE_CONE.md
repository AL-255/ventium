# Data-segment size without fetch-decode feedback

October 13, 2026. **Private candidate; synthesis/timing audit closed, not deployed.**
The independently audited unplaced estimate is **35.830735605 MHz**, versus
**35.856430851 MHz** for the parent: **0.0717% worse**, still below 40 MHz.
This is not an optimization win, routed timing or measured board frequency.
No gameplay gain is claimed.

## Structural change

The parent's 93-level worst path crosses instruction-fetch demand-size decode
and the data-segment limit checker before reaching cache/store-pair admission,
AXI ACK and a register input. `S_FETCH` is unconditionally classified as code,
so the data fault cannot consume its size. Nevertheless, sharing the generic
`cur_size` mux puts that late decoded size in the data-comparator cone.

`prepare_data_size.py` makes one hash-checked `core.sv` change:

- Preserve the single existing per-state access descriptor generator.
- Take `cur_data_size` before the `S_FETCH`-only demand-size override.
- Apply that override afterwards, leaving the actual `cur_size` bus/fragment
  descriptor unchanged in every state.
- Use the earlier size only in the two data-segment extent comparisons,
  retaining the whole-object overrides for x87 environments and other accesses.

The original canonical size, fetch-limit checks, data/code classification,
fault qualification, page probes, requests and sequential state are unchanged.
An assertion requires exact extent equality whenever `cur_is_d` is true.
There is no extra cycle, queue, RAM port, feature switch or timing exception.
Root RTL and the running full-PC model are untouched.

This removes a source-level dependency; Vivado may still refactor or share
logic, and the separate real fetch-limit path remains. Only a matched new
synthesis can establish the effect on frequency and area.

## Closed checks

| Check | Result | Scope |
| --- | --- | --- |
| Recipe tests | 4 pass | Exact reversible delta; all other size assignments, fetch checks and classification retained; drift/reapplication rejected |
| Symbolic data-owner equivalence | UNSAT for disagreement | All binary beat sizes, fetch sizes and 8-bit object overrides under the actual fetch-excludes-data premise; not whole-core sequential proof |
| Missing exclusion negative proof | SAT | Shows why the cofactor cannot be used for a fetch consumer |
| Source-derived native leaf | 362,144 checks pass | Actual state enum, classification, extent function and new tap; unchanged non-fetch size arms abstracted as arbitrary size |
| Leaf coverage | 352,910 data owners; 650 differing inactive fetch extents; 173,128 large-object overrides | Directed state/width sweep plus deterministic simulator random vectors |
| Negative RTL variants | All 3 fail | Fixed dword data width, lost fetch bus width, lost whole-object override |
| Full-core build | Native exit 0, 20.82 s | 195 sources, exactly one changed; 152 UV-fast definitions; explicit board `AXI_LINE_REPLAY=0`; private matching host object/header |
| Fetch-boundary differential | 22/22 pass | Full architectural QEMU comparison, `--cycle-func --l1-axi`, AXI latency 7; required fault frames/retries and actual backing activity |
| Private-QEMU functional corpus | 108/108 pass, 80,800 complete records | 30,134 V retirements; original three stack-test masks retained; 105 programs also pass unmasked |
| Canonical gate | FAIL, native make exit 2 | 7 functional passes / 101 failures and cycle-band failures; no verdict waived |
| Single-fill cycle A/B | All 20 complete traces unchanged | Explicit board `AXI_LINE_REPLAY=0`, AXI latency 7; not a cycle-band pass |
| Full-PC transfer/build | Native exit 0, 24.38 s | All 102 shared RTL files match the directed core; exactly one changed; private host compiled against its own generated header |
| Hardware CPU-hierarchy lint | Pass, 3.93 s | All six structural error classes, exact 158 hardware definitions; not full-platform lint |
| Both short CoreMark seeds | Pass, all five CRCs each; clocks unchanged | 4,767,218 performance / 4,753,406 validation clocks; 0% cycle-throughput gain; not duration-valid scoring |

The leaf proof is two-state, not arbitrary X/Z equivalence. Existing non-fatal
testbench style/width warnings remain visible; all six hard structural classes
are enabled. The first fetch launcher rejected a symlink-spelled output path
before creating a run. The second uses its canonical path without changing a
guard, fixture or checker; the failed launch is retained separately.

The unmodified canonical `make verify` and separately qualified private-QEMU
functional corpus are now closed. `run_data_size_checks.py` binds the exact
model and changes only explicit path/model identities. Canonical cycle replay
uses the audited **single-fill** parent traces, not the earlier double-fill
baseline. No record, mask, golden, comparator or timing band changed. The
private oracle includes independently tested pre-exit/x87 repairs; it has not
replaced canonical QEMU. Its functional passes do not turn the canonical gate
green. Unmasked failures remain `tx_regform2`, `tx_regform` and `tx_stack`.

`audit_data_size.py` independently rechecks **14,928 input pins**, the complete
195-file source closure, native commands/private header dependencies, exact
terminal owner invocations, both proof queries, negative controls, all 108
functional comparisons, all 20 cycle traces and all 22 precise fetch witnesses.
It preserves the failed canonical verdict and makes no standard-suite,
frequency or hardware claim.

The hardware export is one byte-exact `core.sv` delta from the general-repair
parent: **190 payloads, 170 matching full-PC HDL inputs, 117 filelist units and
49 include edges**. All 156 full-PC definitions plus the two synthesis-only
definitions, 40/100 MHz constraints, full P5 L1s and posted-16 transport remain
unchanged. Three transfer/rejection tests and three synthesis-controller tests
pass. Full-PC compilation retains the parent's **98 platform structural
warnings**; strict CPU lint does not waive that separate debt.

## Reproduction and remaining work

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

| Artifact | SHA-256 |
| --- | --- |
| `leaf-r1/closed.json` | `5fffbdcd021240d496ff7241c50bf8f1e0506e97ce7a5e5bb2e82612fb396277` |
| `core-r1/build-closed.json` | `5d05a324dd2a3aa2e617f251fb8470004f15979e7bc25a65d27c70071c17f63d` |
| `core-r1/obj/tb_ventium` | `fef9f3b6ad52a1dbf86ec19c8e6eb50dd79d3b4aa9f3601e35797cb93a62a041` |
| `core-r1/candidate/rtl/core/core.sv` | `6c020b3c171fb422756a7874fb48cd32a683953ff5b95d44b708be3a7fa08b1c` |
| `audit.json` | `913c25bf68f8b2c65dd341c13b3e4356b44aa4ddcd7299e9f4a70f4243a79193` |
| `soc-r1/build-closed.json` | `0497d3fb24e8b596c95401b6bf481ee190c315cdd652933d5cdafc3e6ae6af18` |
| Full-PC model | `c0de36c5456d737ed38431598095f3df7d5c03f4f61da5e9462d1ddb23cd772f` |
| `fpga-r1/input-manifest.json` | `8e8ab037834da5120453149a60766b4455f60be0e14e06f6a7be33a19aa5b864` |
| `lint-r1/closed.json` | `21f0d956022294749834abe55118aa0b122e820d7718892d539daf9cecd029f0` |
| `soc-r1/coremark/audit.json` | `8461b3974bb4c0a866c557e600b8be408bfc176a65af6615dc12094713b99a4f` |

Closed owners: leaf, core, fetch-r2, func, soc and lint services named
`ventium-data-size-*-oct13-r1.service` (fetch uses `-r2`); each has MainPID 0 /
exit 0. The canonical owner is terminal **exit 1**, preserving native make
exit 2. Full-PC owner invocation: `b5bcdbe1e30041d9b69b986a39a17a7e`;
lint owner: `4c49f95186794c8b802be11fdae97f4d`.

Both short CoreMark controls closed successfully under
`ventium-data-size-cm10-oct13-r1.service`, invocation
`96ddbcc22a4c4b2fbf86ead477bf622e`, on CPU12 with 1 GiB/no-swap and a 600 s
per-seed limit. Native elapsed times: **212.52 / 218.11 s**; final V counts:
**1,055,307 / 1,054,254**. Both children were reaped, owner MainPID is 0, and
all OOM counters are zero. The independent audit rechecks **17,170 pins**, both
native commands/CPU affinities, completed consoles, original disks and CRCs,
and exact parent/candidate benchmark clocks. These are not duration-valid
scores, gameplay IPC or the standard suite.

Matched synthesis launched at **20:44:30 UTC**, only after that audit and
strict CPU lint passed, and closed normally in **1,930.13 s**.
Controller `ventium-data-size-synth-oct13.service`,
invocation `ad838e8d4b0543cd87932bd52f908799`, owns the sole Vivado scope
invocation `65ad0adba6c848038ad63508af87b1e7`; both are now terminal.
Limits were unchanged: 8 GiB RAM /
6 GiB swap, 13 GiB combined early-stop, 2 GiB host reserve, 4 GiB live disk
floor, conservative measured-growth disk admission and 45-minute native cap.
Independent synthesis audit rechecked **18,628 source pins**, 148 native HDL
reads and all 158 definitions. Utilization is **187,487 LUT / 54,988 FF /
277.5 BRAM / 47 DSP**, versus 186,770 / 55,011 / 277.5 / 47: **717 more LUTs
(+0.384%), 23 fewer FFs**. Peak RAM/swap: 8,329,760,768 / 1,366,659,072 bytes;
no OOM, resource stop or error. The one critical warning concerns the generated
PS8 clock lookup; the following timing audit explicitly verifies both clocks.

The separate report-only Vivado owner `ventium-data-size-clock-oct13.service`,
invocation `48ba1e58caa84a42b00860cf4685130f`, closed normally in **518.55 s**.
Its sole native scope is `01044558c6d64fe695e3fe726343cbba`; no implementation
or programming followed. The independent audit rechecked **17,573 pins**,
40 MHz core / 100 MHz PL clocks, zero black boxes and structural DRC errors,
and the original parent checkpoint under the same constraints. Peak RAM was
4,869,001,216 bytes, no swap/OOM.

Candidate setup/hold slack is **-2.909 / -0.101 ns**. Its worst setup path is
**97 logic levels**, from `eip_reg[0]` to `u_regfile/gpr_reg[4][16]`, with
27.698 ns data delay (5.663 ns logic, **22.035 ns estimated unplaced net delay**).
It traverses instruction-byte/decode selection, V length/pair lookahead,
`mc_prime_v_branch`, next-load address/TLB preparation, `mc_prime_offer`,
`core_mem_next_req`, L1 immediate-pair validity and GPR writeback. These are
observed netlist names, not proof that each source-level path is sensitizable.
The old fetch-size/data-segment chain is absent from this reported worst path,
but that did **not** improve the worst-clock result.

The selected pair-capture cone shrank from 69,141 cells / 21,811 startpoints to
68,545 / 21,716; its worst reported slack improved from -1.947 to -1.754 ns.
That local improvement is not a whole-core timing gain. Next investigation:
prove current-response ownership separately from speculative next-load lookup,
and inspect pair-valid/writeback dependencies before another synthesis. Do not
disable priming/pairing, add global waits or declare false paths to hide it.

Audit hashes: `synthesis-r1/audit.json`
`ecc2366911c3c73cfff3bdbe9cc92ba6b83bc59431860e5830e79e81ad34ad83`;
`clock-r1/audit.json`
`c77ffdf435ac6fb1d5bd7cf47ba89dee720d6cf7f33afa37c895ddceeea17f04`.
The later [environment-write decoder repair](../sys/fp_env_store/WRITE_CLASS.md)
is **not in this checkpoint** and has no synthesized frequency result.

Still required: canonical gate repair, >=40 MHz synthesized Fmax,
routed timing and physical FPGA standard-suite acceptance. The parent's cold
Win95 and Quake jobs remain running without restart; their results cannot
qualify this new candidate. No board programming was performed.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA or
Doom performance.
