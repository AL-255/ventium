# Early branch address payload — October 15, 2026

**Directed tests and source-matched PC/hardware export pass. Timing and physical
acceptance are pending; this experiment is not promoted or deployed.**

## Why this cut

The rejected fetch-metadata experiment's synthesized worst path traverses live
U/V decode, pairing eligibility, raw branch lookahead, address generation and
cache/execution logic. The retained parent already separates address fields
from late descriptor checks, but selects the third-slot payload using the
fully qualified `mc_prime_v_branch` predicate. This puts pairing admission
back in front of address calculation.

[`prepare_branch_address_shape.py`](prepare_branch_address_shape.py) selects
that **payload only** using the live V descriptor's branch shape. The actual
checked descriptor still requires the original pairing, prediction, complete
byte ownership, code extent and segment checks. Offers, commit conditions,
permissions, data dependencies, cache configuration and state are unchanged.
No register, pipeline bubble, backing prefetch or application special case is
added. Held-load and FP-self address sources retain their higher priority.

The safety distinction is explicit: a nonpaired V branch cannot itself be a
memory or FP descriptor, so its altered address is unused. A new clocked
assertion checks that decoder invariant independently of hint acceptance. The
existing payload-versus-checked-descriptor assertion remains mandatory for
every nonempty memory/FP descriptor, before offer permission checks. It no
longer constrains meaningless address fields of a non-memory descriptor.
AGI/reference payload overrides are unchanged.

This is an exact-parent private transformation. It preserves the qualified
FPREM numeric, operand-exception and exact-underflow repairs, but **does not
inherit the rejected buffered fetch-metadata experiment**. The earlier timing
result, 36.591166892 MHz unplaced for the prefix-payload parent, is not this
candidate's frequency and is not routed sign-off. The target remains at least
40 MHz synthesized and routed.

## Closed verification

Evidence root: `/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.

| Check | Result |
|---|---|
| Exact-parent/source tests | Two pass; transformation is reversible; request/commit equations unchanged |
| Extracted RTL payload test | 65,536 samples; 29,373 consumed checks; ordinary, FP, held and branch producers exercised |
| Negative controls | Dropped held priority, dropped FP priority, disabled branch selection and unconditional branch selection all fail |
| Core build | 195-source closure; exactly one include changed; 152 unchanged defines; assertions and single-fill retained; 20.31 seconds |
| Cold branch/system cases | 140 cases: 10 forms, two relocation settings, offsets 0/26/27/28/29/30/31, AXI delays 0/7; 38.34 seconds |
| Complete branch comparison | 77,420 candidate architectural records; complete parent/candidate functional and cycle streams identical; branch hint identities unchanged |
| Pair/hint evidence | 280 explicit initial V-pair witnesses and 880 paired-branch hint captures; not merely compiled dual-issue defines |
| Private-reference functional corpus | 108/108 pass, 110.19 seconds; existing comparison policy unchanged |
| Other cold system controls | Five fixtures at delays 0/7/31: 30,141 candidate records, 5,487 V retirements; parent-identical records and counts; 22.85 seconds |
| Canonical `make verify` | **FAIL**, native make exit 2, 394.38 seconds; all 20 RTL cycle streams remain parent-identical |

The extracted test uses the actual descriptor and producer equations with
mocked returned-byte ownership. It is not a complete cache simulation or
formal whole-core proof. The cold system tests exercise real UV-fast execution,
both functional/cycle observations, QEMU comparisons and original invalid-SS
fault witnesses. No trace trimming, new comparison mask, cycle-band change,
STEP control or pairing suppression was introduced. The canonical gate stays
red; neither private-reference passes nor unchanged failing bands waive it.

## Full-PC and FPGA source transfer

[`build_branch_address_soc.py`](../../fpga/build_branch_address_soc.py) audits
all **102 shared RTL sources** against the directed core. Exactly four files
differ from the retained prefix-payload PC parent: `core_mem_chain.svh`,
`core.sv` (legacy SRT mask tie-off only), `fpu_srt_div.sv` and
`fp_shared/ven_fp_top.sv`. The FPU transformation composes all three repairs in
order; tests reject an omitted underflow repair or an additional source change.

The PC build passes in **23.21 seconds**, with a unique harness object and its
own generated headers, 156 unchanged defines, posted-16 transport and unchanged
single-fill mode. Its 98 inherited structural diagnostics remain visible;
this is not a full-SoC lint pass. The hardware export matches all 170 common
HDL inputs, 190 payloads and 158 hardware defines. Strict CPU-hierarchy lint
passes in **3.98 seconds** with all six structural classes still hard errors.
Export qualification remains `UNQUALIFIED`.

- Directed core: `6deb3e92ae302d2166c18d239711754c049f1f775f2518a2f5b576108eb8b16d`.
- Full-PC model: `0a1f097ee98c816eef72fc432a17fe09e77d7912651c548ad14853512e8edc52`.
- FPGA manifest: `f3d9952f0d85d60ce85a85bfec38bb37a939b39a739dc02e6ebde5a6d0297427`.

Both short cold CoreMark controls and their independent regrade **pass**:

| Seed | Candidate / parent ticks | Actual V retirements | Runtime |
|---|---:|---:|---:|
| Performance | 4,767,218 / 4,767,218 | 1,055,307 | 217.46 s |
| Validation | 4,753,406 / 4,753,406 | 1,054,254 | 214.68 s |

Both complete five-CRC sets match the reference. CPU12 affinity, exact native
argv, source/media hashes, process wait/reaping and zero OOM are rechecked.
Owner `ventium-branch-address-cm10-oct15-r1.service`, invocation
`0cca37c66dd64113b54b4352297643c3`, is terminal exit 0 / MainPID 0, peak RAM
56,348,672 bytes. The independent audit rechecks 13,140 source pins. Measured
cycle-count gain is **0%**, as intended for this combinational timing cut.
Ten iterations are insufficient for valid scoring or standard-suite acceptance.

`prepare_branch_address_synthesis.py` prepares the matched single-Vivado
measurement. Three tests verify unchanged launch/watchdog/reaping code, the
same clock-audit Tcl, exact four-file transfer and unchanged resource admission:
6 GiB starting disk reserve plus twice the measured parent growth above a
4 GiB stop floor, 8 GiB resident / 6 GiB swap caps and a 13 GiB combined stop.
No memory or disk guard was relaxed. The first preflight, invocation
`b374d7e05d184a049ec80b96157431ab`, refused the measured-growth disk check
(6.714 GiB required, about 6.2 GiB available) **before launching Vivado**. Its
failure receipt and journal are retained. After pruning additional unused
compiler caches, the same unchanged controller was restarted under
`ventium-branch-address-synth-oct15-r1.service`, invocation
`622dfdcd29284642bceadb4de91a341d`; its result is **pending**. No placement,
routing, bitstream or FPGA deployment is authorized by that controller.

Next: close and audit synthesis, measure the candidate's frequency, and retain
or reject the change on that evidence. Full simulation and physical Win95/Quake acceptance, valid
CoreMark scoring, canonical failures and delayed underflow `#MF` qualification
remain open.

Gameplay baseline is **0.50520554 total U+V IPC**, older model
`c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd`, cycles
**5,600,065,237–5,700,065,237**. Candidate gameplay, FPS and frequency are
unmeasured. No IPC or area gain is claimed from this combinational change.

Disk hygiene: 24 unused compiler precompiled-header files from closed tests
were pruned (about 1.96 GiB). All native binaries, generated source/dependency
files, traces, logs and successful/failed evidence remain. The caches can be
regenerated; pruning receipts are `PCH_PRUNE_Oct15.md` and
`sequences-underflow-r1/PCH_PRUNE.md` under the evidence root.
