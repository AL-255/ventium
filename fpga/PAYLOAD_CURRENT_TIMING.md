# Combined I-fill, bank-overlap and payload-kind timing candidate

October 12: **private candidate, not timing- or FPGA-qualified**. The immediate
requirement is **at least 40 MHz post-synthesis Fmax**, retaining UV dual issue,
system/relocated fast execution, fast loads/stores and full P5 L1s. The latest
measured parent is still **28.88420323 MHz**, unplaced; no new Fmax is claimed.

The [exact-current recipe](../verif/l1/prepare_payload_current.py) combines:

- The previously compiled [read-only I-fill ACK cut](IC_FILL_READ_ACK.md).
- The [guarded bank-overlap ACK cut](PAIR_OVERLAP_ACK_CUT.md), preserving the
  independently qualified same-line return fix.
- The previously isolated [payload-kind sideband](../verif/l1/PAYLOAD_CODE_HINT.md),
  with the stronger S_PIPE `pf_miss` selector. This keeps late request and
  permission logic off the operand-data selector leading to the FPU/SRT input.

Only payload selection uses the new sideband; original request classification,
ACK, permissions, translation, fault/fragment handling and cache-state updates
retain their authority. No bubble, cache reduction, timing exception or guest
special case is added. Seven host tests check exact-parent rejection, unambiguous
patch context, preservation of all current fixes with the flag disabled, and
byte-identical cache-mux/request equations to the native extracted proofs,
native cache-proof admission and the exact one-flag canonical replay adapter.
These host tests are not processor verification.

## Combined build

Evidence root: `/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS`.

`payload-current-core-r1` compiles natively in **20.11 seconds**, retaining all
195 sources and 150 parent definitions, plus `VEN_L1D_PAYLOAD_CODE_HINT`.
Exactly four interface files differ from the I-fill parent: `core.sv`,
`ventium_top.sv`, `ventium_l1_axi.sv`, and `ven_l1d.sv`. The unique C++ harness
has a verified model-local generated-header dependency; strict structural
warning classes remain enabled. Source and prerequisite evidence pins rehash.

Model SHA-256:
`fbe7b4e3b31c83396414de6802fe2e06dd4be0d4b039199dfc0f8e660154c8d6`.
Native owner: `ventium-payload-current-core-oct12.service`, invocation
`ed9c9c04a2184c3b9ec2fa3372181f57`, terminal zero.

Build closure SHA-256:
`caa18357a9b48ecb496357242e0fb1beade74161a468051be162d904b1e3abff`.

## Cold regression results

The first matrix controller incorrectly places all 32 native workers in the
128-task compiler scope. Its `pids.events` records 682 failed task admissions;
assembler/linker/QEMU spawns fail with `Resource temporarily unavailable`.
All four parallel matrices fail and this attempt is **not accepted**. The
serialized fault subtest subsequently completes with native zero and all
comparisons passing. Whole controller
`ventium-payload-current-regressions-oct12.service`, invocation
`bb4d5b5c65564d358019218a2dc42ad2`, closes exit 1. Its exact failed launcher is
retained as `payload-current-regressions-r1/failed-under128-controller.py`,
not installed as a reusable repository command.

The same generated matrix drivers are retried in separate native-test services,
each capped at 3 GiB RAM, no swap, 2,048 tasks and 600 seconds. CPU affinities
are explicitly 0–3 / 4–11 / 12–27 / 28–31, with **4/8/16/4 workers**.
The compiler/Vivado guard is unchanged. All four retries close native zero:

| Matrix | Fixtures | Candidate architectural records | Candidate V events |
| --- | ---: | ---: | ---: |
| Memory | 72 × AXI latency 0/7 | 31,392 | 1,500 |
| FP memory operands | 384 × AXI latency 0/7 | 208,128 | 768 |
| Integer/store | 256 × AXI latency 0/7 | 169,472 | 512 |
| Held read | 24 × AXI latency 0/7 | 9,200 | checked by original corpus |
| Faults | 16 | 23,585 | full UV architectural comparison |

Total: **441,777 candidate records**. The existing adapter admits only the one
new sideband flag. Complete QEMU architecture and full parent/candidate cycle
streams match in the four timing matrices. Faults retain all 32 complete
model/QEMU comparisons, no timeout and identical full A/B architecture.
This is directed no-regression evidence, not a gameplay or standard-suite pass.

Retry owners are `ventium-payload-current-{memory,held,fp,integer}-r2-oct12.service`.
Invocations, in that order: `3f17fb4d391646829c1875967b05bb5c`,
`7f8f1601a6a64a24b9aefcf21fcd4224`, `1c2f3213540a46cfb66359c95e5ad29b`,
`28b52175113b49f5837c05455fbbb71f`. Evidence directories have the same suffixes
under the root above. Fault evidence is `payload-current-regressions-r1/faults`,
with the independently recorded native child result in `faults-exit.json`.

Canonical `make verify` closes **FAIL: 7 PASS / 101 FAIL**, make exit 2, with
all 20 full cycle streams identical to the parent. No oracle, mask, terminal
record or cycle band is changed. Owner `ventium-payload-current-verify-oct12.service`,
invocation `d60f149c01e64cd59eadc51d2cfb0a32`. Full same-input replay then closes
native zero: **108 programs / 80,800 records**, 81.70 s, all pins unchanged;
`ventium-payload-current-canonical-ab-oct12.service`, invocation
`ee82e1ead0d3407c9e77d388a0ec9681`. Replay closure SHA-256:
`d2b894ab2194fef8b583b0cb58a195d5c21467c32931e142d938d469d08103be`.
Replay equivalence does not waive canonical FAIL.

## PC model and FPGA inputs

[The PC builder](build_payload_current_soc.py) preserves the original platform
and posted-16 transport. All **102 shared RTL/FP sources** match the tested
core. It adds only the payload flag to the 154-definition native profile.
Build closes zero in **24.72 s**, with the original 98 full-platform structural
warnings unchanged (not waived as correctness evidence) and a verified private
harness dependency. Model:
`0910a3be8bf6c3a5d293dfd8204e0be89e98bb1163a4f2eb6e73f547ddff133a`.
Owner `ventium-payload-current-soc-oct12.service`, invocation
`52b766bfa547436fb3252a2a677d6dd3`; build closure SHA-256
`1015bd533d0bc0e77e97aaeae20a4fc2332850a669f3f55c61f25e7ef85015c3`.

Both original short cold CoreMark seed diagnostics are launched through
`ventium-v-carry-cm10-payload-current-oct12.service`, invocation
`3e6dbce005f944a199534d5ade80f848`, native CPU affinity 11. The performance seed
closes zero with unchanged **4,767,218 ticks** and all five CRCs, in 219.46 s.
Validation also closes zero: **4,753,406 ticks**, all original CRCs, 199.37 s.
The independent audit rehashes all **3,720 source/input pins**, confirms the
actual native child identities, affinity and reaping, checks completed console
output and reports no OOM. Timing/throughput gain in these diagnostics is **0%**,
as expected for cycle-preserving structural cuts. Ten-iteration diagnostics
are neither duration-valid CM/MHz scores nor the full standard seeds.

[The source exporter](freeze_payload_current_rk_candidate.py) publishes
`payload-current-fpga-r1`: **190 payloads, 170 simulator-matched non-wrapper RTL/header files and
157 hardware definitions**, preserving the actual 40/100 MHz clocks and all
previous features. Exactly the four checked interface files change. Manifest:
`1f78fbf6d9384f8e79a558f25d6e2b9a2b3e3a7a286fd8100f3f8764daca87f2`;
freeze receipt `87aa416d05181d1e593286d257fcf320c21de8f8ebd695fa9f10def7c9f8966d`.
Three export/profile tests pass, including a wrong-flag negative. Initial test
fixture failures were missing upstream flow inputs and unresolved symlink paths;
the corrected fixture uses the actual frozen inputs and canonical paths.
The actual Tcl contract passes; it invokes no Vivado and claims no Fmax.

Strict hardware-profile CPU lint closes native zero in **3.63 s** as
`ventium-payload-current-lint-oct12.service`, invocation
`b89b28d17b324e0dac111285210f3df6`. The adapter preserves all structural-error
classes and admits only the exact 157th flag. Full SoC lint is not claimed.

Still required: new synthesis measurement, canonical correctness, full standard
suite, and actual current-candidate FPGA Win95/UI and original Quake timedemo.

## Native synthesis in progress

At **2026-10-12 05:31:51 UTC**, the combined candidate starts its first native
synthesis. There is **no new Fmax result yet**. The previous **28.88420323 MHz**
measurement remains the baseline, below the requested **40 MHz**.

[The preparation recipe](prepare_payload_current_synthesis.py) derives five
controllers/audits from the byte-pinned, completed PRIME logic-only experiment.
Three preparation tests pass. The entire resource monitor and stop/reap code
is byte-identical to that parent; proof checks rehash the tested core, PC model,
short CoreMark runs, lint and frozen hardware source closure. Canonical failure
remains explicit. The first preparation attempt rejects a lexical-versus-resolved
external-path mismatch before creating outputs; the corrected recipe and tests
handle the template's literal path explicitly.

Native owner `ventium-payload-current-synth-oct12.service`, invocation
`a0ce840d0860406ebdd6fb2d64dd0610`, owns the sole `ventium-vivado.scope`
invocation `35dfee26af8a4f0f9a1c5e64fbdddaee`. Evidence is under
`payload-current-synthesis-r1`. The retained queue owner is
`ventium-payload-current-timing-queue-oct12.service`, invocation
`2f2f9d9b3fce4dfaac6ccdcb59729926`; its script and receipts remain in the evidence
root. It launches the read-only native clock/netlist audit only after successful
synthesis closure and an independent DCP/source/define audit.

The run preserves **40 MHz core / 100 MHz PL** constraints, the matched
`Default -no_timing_driven` mapper, 157 hardware definitions, full P5 caches,
UV and fast execution. A constraint or successful synthesis alone cannot satisfy
the Fmax requirement. RAM/swap caps remain **8/6 GiB**, combined early stop
**13 GiB**, host RAM/swap floors **2 GiB**, and disk stop floor **4 GiB**.
Admission retains both the **6 GiB** minimum and twice the older measured
parent's **1,456,762,880-byte** growth above the disk floor (a stricter
**7,208,493,056-byte** admission threshold). The native timeout remains 45 minutes.
No implementation, bitstream programming, or acceptance waiver is queued.

The live native synthesis Tcl independently confirms the **exact 157 ordered
definitions** and the requested part/mapper. All **147 frozen `read_verilog`
inputs** rehash to the manifest; the only additional `read_verilog` input is
the generated block-design wrapper. This is distinct from the exporter's 170
simulator-matched files, which also preserve unused/alternative units. The
initial ad-hoc preflight incorrectly equates these counts and rejects before
performing its source checks; inspecting the actual Tcl and the parent's same
148-entry read list resolves that checker assumption. It is not a missing-source
or native-build failure. The completed native/DCP audit remains pending.

## Disk preservation

Removed **12 closed, unopened, unpinned compiler PCH caches**, reclaiming
1,040,048,128 allocated bytes. These are the `fast`/`slow` `.gch` pairs for
I-fill core, combined core, failed overlap-cache FF build, and the three
completed overlap-cache variants. Retained headers/build inputs regenerate
them; model binaries, sources, generated C++, objects and evidence remain.

Completed FP/integer matrix logs and traces are losslessly archived and
byte-compared with `tar -d` before removing 4,992 / 3,328 redundant raw files.
Metadata, fixture inputs and results remain unpacked. Restore either archive
with `tar -xzf ARCHIVE -C EVIDENCE_ROOT` when raw traces are needed:

- `payload-current-fp-r2.tar.gz`:
  `862022d47c131fc18785a1a2d0e7ba72ca8931bacd948ccc60ca78c9bf845d6b`.
- `payload-current-integer-r2.tar.gz`:
  `bfc39e8758bd3a047c0767d4aaeedc2980eeb748c7b85c01d03279ea4b841ead`.

Before synthesis, further closed diagnostics are losslessly archived, every
member verified against its original SHA-256, and only then raw text removed:

- `closed-timing-text.tar.gz`: 24,258 logs/traces from closed branch-residency
  and timing-combo experiments;
  `f153bae665580e1121c1b4ad15020e38fe5e2e69bbc26b2e013d15b8ee7f4ee3`.
- `closed-timing-reports.tar.gz`: four large closed branch-residency capture-cone
  and primitive-cell reports;
  `71e16c2074988a56ef88a46bf70c2e1062f4735dc3e135fe1f3234f29405eb0b`.
- `closed-ancestor-text.tar.gz`: 5,865 unpinned diagnostic text files from the
  closed BUS/fragment timing ancestors;
  `9e0103e949d41edd1bbe22ccc637ca36a5ddb0f4bae4c8cc94710b1bbc220e4c`.

Restore these three archives with `tar -xzf ARCHIVE -C /home/yukidama/external/tmp`.
Plans and closure receipts remain beside them. The initial text-archive verifier
is stopped before deletion because random gzip seeks for hard links repeatedly
decompress the archive; a sequential verifier completes all member checks,
including links to previously verified bytes. Also removed two unpinned, closed
PC-model `.gch` caches (**190,685,184 allocated bytes**); retained headers and
build inputs regenerate them. Sources, model binaries, media, checkpoints and
current synthesis input pins remain intact. Free space rises from about 4.7 to
7.1 GiB without reducing the launch reserves.

Gameplay IPC is **unmeasured for this candidate**. Last verified baseline:
**0.51030715 total U+V simulated retirement-event IPC**, older model `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**; neither hardware IPC nor a full-demo average.
