# Read-only successor-hint commit — October 11, 2026

**Whole-core directed tests pass; timing and full-system acceptance pending.**
Target: at least **40 MHz synthesized Fmax**, preserving UV + relocated/system
fast pipes, fast loads/stores and full P5 caches. The immediate predecessor
measures **30.34809 MHz**, unplaced; no new frequency result is claimed.

## Change

The [readiness candidate](PAIR_READY_COFACTOR.md)'s worst 111-level path runs
through paired-store/backing-write ACK, architectural integer commit, read-hint
commit and cache capture/LRU. A read-only successor hint does not need the
unrelated write-ACK branch.

[The exact-parent transformation](../verif/l1/prepare_mc_read_commit.py) changes
only private `rtl/core/core_mem_chain.svh`. It copies the actual integer-commit
equation into a read-only predicate, replacing its memory-wait guard with
`!pipe_store_req && (!pipe_load_req || mem_read_ack)`, and uses this only in
`mem_next_commit`. Architectural `pipe_int_commit` remains unchanged. The new
predicate uses the existing **fragment-qualified** read ACK, not raw bus ACK.
Every fault/stall/issue guard, branch correctness, AGI/ref commit and FP
self-prime/admission term remains. No state, register, cycle or guest-specific
exception is added. A simulation assertion compares the complete old/new
read-hint commit every reset-released clock.

The context is essential: integer hints originate from a held read, a fresh
read, or a nonmemory packet; a current U store cannot own such a hint. FP
self-prime uses its separate unchanged FP-admission arm. The proof is not a
claim that a read-only predicate could replace general architectural commit.
The separate [same-line cache ACK draft](PAIR_NOW_ACK_CUT.md) is **not included**.

## Executed evidence

Evidence root: `/home/yukidama/external/tmp/ventium-mc-read-commit.PNi1O0xm`.

- [Source-extracted microtest](../verif/l1/test_mc_read_commit.py), `leaf-r2`:
  155,651 samples, including 141 read commits, 74,807 nonmemory commits and
  1,638 blocked reads. Positive native exit 0; missing-read-ACK, raw-fragment-ACK
  and lost-FP-admission mutants each fail natively. Other commit samples include
  unchanged AGI/reference arms. This is a predicate test, not a cache/CPU proof.
- First attempt `leaf-r1` failed compilation because its fixture omitted the
  extracted equation's `pipe_mem_pair_q` input. The corrected fixture declares
  and drives it; the failed driver/logs remain. No RTL change was needed.
- [Abstract Boolean proof](../verif/l1/prove_mc_read_commit.py), `formal-r1`:
  positive UNSAT; all four mutants SAT, additionally including store-prime
  admission. Decode/permission/branch qualifiers remain arbitrary. This is
  explicitly not formal verification of the full processor.
- [Whole-core build](../verif/l1/build_mc_read_commit_core.py), `core-r1`:
  native exit 0 in 19.96 seconds; all 195 source files and 150 definitions
  preserved except the single header. Private harness object uses its own
  generated model header. All started input pins independently rehash unchanged.

Model SHA-256:
`64dadfc92c708c49d45e8c0f3b7704e1c24dff48f8d525956dc4624946a07695`.
Native build invocation: `f09cbeb42fa04c2380c332d506df59bd`.

| Cold whole-core corpus | Cases | Candidate architectural records, AXI 0/7 | Result |
| --- | ---: | ---: | --- |
| Paired reads/read-ALU and rejection cases | 72 | 31,392 | PASS; 1,500 memory V retirements |
| Load/store pairs and actual post-store readback | 72 | 32,112 | PASS; 456 memory V retirements |
| FP/integer/memory overlap | 72 | 39,024 | PASS; actual pairing and early FP acceptance |

These compare complete fresh-QEMU state and complete parent/candidate cycle
streams, including relocation, instruction-line seams and AXI latency 0/7.
All **102,528 candidate architectural records** pass, with **zero cycle-count
change**. No terminal trimming, goldens, C1 masks, cycle bands or guest image
changes. Native owners respectively `b6f189f1b1344c8bbe8d83b86bf9bbea`,
`bbff2d17df894eea82aa6281c9ef7602`, `f5498ebb40ae42c6b8e3a10d5e76a597` are
terminal zero; their pinned sources/models independently rehash unchanged.

Two additional whole-core corpora exercise the actual hint contexts changed
by the cofactor, not just ordinary load/store retirement:

- Held/fresh read hints: 24 cold fixture cases / 48 latency cases, **9,200**
  candidate architectural records and **346 actual held-read hints**. Unsafe
  candidate forms must not prime; existing immediate load pairs remain intact.
- Predicted branch fallthrough: 40 cold cases / 80 latency cases, **22,120**
  candidate records and **488 actual branch hints**. Taken outcomes, unsafe
  forms and line-boundary exclusions retain full state/cycle/hint equality.

Both pass fresh QEMU plus complete A/B comparisons, native exit zero, with
independently rechecked input pins. Invocations are respectively
`937691346aea4088b35a46ddc19c56f3` and `6e188d3cd3d44e9f83d93a0378927fa5`.
Total across all five corpora: **133,848 candidate architectural records**.

The unchanged canonical gate closes **FAIL**, native make exit 2 / owner exit 1,
in **384.29 seconds**, invocation `aaac1084050145b7a7ab2604aef3ab87`.
All 20 complete cycle traces match the predecessor. The 108 functional tests
remain 7 PASS / 101 FAIL: 91 first report length mismatch and 10 first report
x87 C1 mismatch; this A/B agreement does not waive the failures. Pinned inputs
independently rehash unchanged. Closure SHA-256:
`51ab36882b593e3ecb72da562e54b4b56eb19703fdac16c3828c677a56c71091`.

The independent canonical inventory confirms all **101** failures include a
length mismatch, with **10** additionally reporting earlier C1 differences.
Only one of the separately invoked parent/candidate functional traces is fully
identical: QEMU supplies different initial stack addresses across invocations.
Those runs must not be described as identical-input architectural comparisons.
Inventory SHA-256:
`f432259473b41e6c813e9bd77afb7cf2c631cfc524862e7fd162a12e54a3e6c1`.

To check the full failing corpus without masking that input difference,
[`run_canonical_same_input_ab.py`](../verif/l1/run_canonical_same_input_ab.py)
replays **both models** with the candidate's exact retained input bytes and
initial stack. All **108 cases / 80,800 complete architectural records** match,
including every already-failing case; the candidate also reproduces its own
original trace verbatim. Native owner `1e5208733588453db615e1c4bea4d8cf` closes
zero in **72.86 seconds**, with independently rehashed inputs. No record or field
is dropped. This is a same-input regression pass, **not a QEMU/canonical pass**.

The [full-PC builder](build_mc_read_commit_soc.py) closes native zero in
**22.51 seconds**, invocation `f569eebbb2f8434c86d8426196e31c20`. It verifies
all 102 intersecting core/FP sources match the directed model, changing only
the one header; the platform, 154 simulator definitions and posted-16 transport
are unchanged. Its private C++ harness is compiled against its own generated
header. All input pins independently rehash unchanged. The inherited 98 platform
structural warnings remain debt, not a full-platform lint pass. Model SHA-256:
`1699b3b8af036f01feb1ff25a54aa6be337f54215952023eeaef479c13cc5c07`.

Both unchanged short CoreMark disks close **PASS** under
`ventium-v-carry-cm10-mc-read-oct11.service`, invocation
`1a56bfa30fcf4bd683f017646a2c124f`, native exit zero. Performance takes
**4,767,218 ticks**, validation **4,753,406 ticks**: both exactly match the
predecessor (**0% cycle-count gain**). All five CRCs match for each seed:
`e9f5/e714/1fd7/8e3a/fcaf` and `18f2/e3c1/0747/8d84/c64e`, respectively.
Both actually retire V-pipe work (1,055,307 and 1,054,254 events). The independent
audit passes, all artifact pins rehash unchanged, all children are reaped and
there was no OOM. Audit SHA-256:
`9ebed6330c4efc30b0bbbd479d9c0bbbe9a8b90f9b05fca73deba0bd83958e48`.
These ten-iteration runs are diagnostic CRC/cycle checks, **not duration-valid
scores or standard-suite acceptance**. No new synthesized timing, routed result,
bitstream or FPGA acceptance yet.

The [hardware export](freeze_mc_read_commit_rk_candidate.py) closes native zero
under `e603a9cab1e14e9482cf5ab90c3f9770`, retaining all 190 payloads, 156 hardware
definitions, 40/100 MHz clocks, posted-16 transport and filelist/include closure.
All 798 input pins and all exported payloads independently rehash unchanged.
Exactly `core_mem_chain.svh` differs from the measured readiness export.
Manifest SHA-256:
`8bf3e5b5444b681ed8fa38d936bdb948fa028d6f37c63b47eca6c6e6060be9da`.

Strict CPU-hierarchy lint passes in **3.78 seconds**, invocation
`b8a43b53961b47e19d7ff1eeac8175f4`, with all 156 hardware definitions and the
six structural warning classes fatal. All pinned inputs independently rehash
unchanged; this is not a full-platform lint pass.

[The timing-controller derivation](prepare_mc_read_commit_timing.py) preserves
the completed predecessor's native lifecycle, exclusive Vivado launcher and
resource guards verbatim. It changes source/proof identities only: matched
`logic_only` diagnostic synthesis, not a timing-driven mapper or routed sign-off.
The first attempt reached the disk-admission check only after actual CoreMark
closure and independent audit, then **failed before native Vivado launch**.
Queue invocation `8155476807884799bcf17b3fedb07fe0` and synthesis invocation
`e66afabbb14f416da9730d01864cf32f` are terminal nonzero. The measured-growth
reserve required **7,208,493,056 bytes** free (about 6.71 GiB), more than the
space available. This is not an RTL synthesis failure or an OOM.

After removing only closed, regenerable compiler caches (below), the
[retry preparation](prepare_mc_read_timing_retry.py) admitted **7,405,940,736
bytes** free with the **same guards** and the same pinned RTL. It retains the
failed attempt and uses fresh `synthesis-r2` / `clock-r2` directories. The retry
changes only owner/output identities and adds its proof receipt; the native
guard lifecycle is checked byte-for-byte unchanged. All preparation pins and
generated-controller hashes independently recheck.

At **2026-10-11 23:39 UTC**, R2 synthesis is **actually running**, controller
invocation `d9aa6de7a98c4962b52685ceb4db8d5b`, live Vivado scope invocation
`a0d553946580454ca459cadd5b153da3`. Queue invocation
`4026d9918fe74e8cb69a02b7ac733999` will audit native synthesis and then measure
the original clocks. It retains the 8 GiB RAM / 6 GiB swap caps,
13 GiB combined early-stop limit, 2 GiB host reserves and 4 GiB disk stop floor.
Admission still requires over 6 GiB free disk and twice measured predecessor
growth above that floor. No user applications are killed; no route/deploy is
authorized by this diagnostic controller. **40 MHz remains unachieved.**

Eight regenerable PCH files from the two **closed** same-line cache runs were
removed, reclaiming 668,977,594 bytes. Exact target/hash and deletion receipts
are in `closed-cache-pch-{plan,closed}.json` under this evidence root. Sources,
generated headers/C++, objects, binaries and logs remain; the PCH can be
regenerated, but there is no byte-for-byte backup.
Also, 2,376 byte-identical closed traces were consolidated as hardlinks,
reclaiming 206,241,792 allocated bytes. Every path/content remains available
and all input hashes remain unchanged. Plan/events/closure receipts are in
`closed-trace-dedup-*`; copy a shared trace to a fresh inode before editing it.
Four additional PCH files from the terminal predecessor core/PC builds were
removed, reclaiming 376,135,343 bytes. Their exact targets/hashes and recovery
scope are in `closed-parent-pch-{plan,closed}.json`. They were not pinned inputs
or open files; all source, generated headers/C++, objects and models remain.
Finally, six closed descriptor-core/current-core/current-PC PCH files were
removed, reclaiming **561,621,810 bytes**. Exact targets, hashes, terminal owners
and recovery scope are in `closed-remaining-pch-{plan,closed}.json`. An initial
owner-identity precheck rejected before deleting anything; the successful pass
uses the actual terminal native descriptor-build owner, not its preparation
invocation. Again, only regenerable PCH files were removed, not model binaries,
sources, generated headers/C++, objects, traces, or receipts.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**.
This candidate has no gameplay measurement. The 0% directed cycle-count change
is not a measured gameplay gain.
