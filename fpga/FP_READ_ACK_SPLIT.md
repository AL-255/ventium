# Separate FP read acknowledgement — October 11

**Private candidate: 23.50176 MHz unplaced synthesized estimate, below 40 MHz.
156 directed cases, 64 fault/fragment fixtures, sequential cache-reset tests and
both short CoreMark seeds pass; no gameplay, standard-suite or FPGA acceptance
is claimed.** The closed
[next-query synthesis](NEXT_QUERY_PAYLOAD_CUT.md) regresses to 22.51593 MHz;
this candidate excludes that header change and uses the faster carry parent. The target
remains at least 40 MHz synthesized Fmax with UV and fast pipeline enabled;
the best retained estimate is 23.5855 MHz, unplaced.

## Structural reason

The carry candidate's worst synthesized path reaches FP bank enables through
raw decode, next-request lookup, paired-store/backing admission and
`fp_shared_load_cmd`. The latter is a read-only `S_FLOAD` consumer, but its
`mem_ack` input is shared with writes. The memory subsystem selects a read
response or a backing-write/paired-store acknowledgement into one `c_ack`.

The [recipe](../verif/l1/prepare_fp_read_ack_split.py) adds a read cofactor
under the existing `VEN_FP_LOAD_EARLY_CMD` feature. It changes four pinned
files, reverses every edit to the original whole-file hash, and retains the
original ACK/data response block verbatim. No feature define, clock exception,
pipeline stage, array, request, store acceptance or architectural owner changes.

| Boundary | New signal | Required relation |
| --- | --- | --- |
| `ven_l1d` | `c_read_ack` | Equals `c_ack` when `c_we=0`; contains no backing-write or paired-store admission inputs |
| `ventium_l1_axi` | `core_read_ack` | Same reset, DMA-drain, SMRAM and route-denial handling as `core_ack` |
| `ventium_top` | `core_mem_read_ack` | Same backend selection; legacy/direct modes retain their original ACK |
| `core` | `mem_read_ack` | Same `!fx_hold_e` final-fragment gate as `mem_ack` |

Only the final FP-load command, complete-m64 acceptance and the two associated
high-half-valid gates consume this sideband. Those consumers already require
reads. Assertions compare both ACKs on every read cycle in the cache and core.
Stream response ownership is retained explicitly, including no-new-request
response consumption. When early FP loads are not enabled, the original
interfaces remain unchanged and the internal read ACK aliases ordinary ACK.

This is not a justification for a false-path constraint. Live request, lookup,
tag/owner, cacheability, invalidation and fragment predicates remain; any of
them may become the next critical path. Only a native synthesis can show the
actual timing/area effect. No CPI change has been measured for this proposal.

## Closed leaf evidence

Evidence: `/home/yukidama/external/tmp/ventium-fp-read-ack.kG3e5cW7/leaf-r2`.
Four recipe tests pass. The source-extracted Icarus comparison checks the
actual old ACK block against the proposed read block in four profiles:
registered, registered with code reuse/dual store/stream, combinational with
dual store, and combinational with dual store/stream. Combinational ACK is
only a diagnostic compatibility profile, not permission to deploy it.

Each profile enumerates all 19 symbolic read-control bits, including all four
cache-state encodings, under both extremal backing/store-credit patterns:
**1,048,576 samples per profile**, **4,194,304 total**, with **2,097,152 read
equivalence checks**. These are Boolean control samples, not sequential cache
transactions. A separate structural check rejects write-credit names in the
new read block. All four deliberate `read_ack | m_ack` mutants fail at sample
0/backing 1 with native exit 1; every positive run exits 0.

Unit `ventium-fp-read-ack-leaf-r2-oct11.service`, invocation
`cc1a397cffcf4095a8a28ca0f9aa656d`, closes in **6.93 seconds**. Independent
reading checks all 20 source/binary pins, 13 native exit/log receipts, sample
counts and the retained terminal owner. Closed receipt SHA:
`d6a3e4a5064656bad624a113d3cf665c17ba43c023b043a548f5804b32ffef6e`.

R1 failed preprocessing, not equivalence: removing a data assignment up to
its first semicolon left a conditional payload's alternate branch behind.
Its original files, failed exit and logs remain in `leaf-r1`. The
[R2 extractor](../verif/l1/extract_fp_read_ack_r2.py) removes the complete
data-only span before the next ACK assignment and checks balanced directives.
The four-file RTL transformation is unchanged. Use
[the R2 runner](../verif/l1/run_fp_read_ack_split_r2.py), not the retained R1.

### Backend and fragment boundary check

[The seam checker](../verif/l1/run_fp_read_ack_seam.py) extracts the actual
old/new ACK assignments from the memory subsystem, both top-level backend
configurations and the core's final-fragment gate. It also checks the actual
read-ACK and write-direction port bindings. Given the independently checked
read-equivalence premise, **2,048 control combinations / 12,288 comparisons**
pass, covering reset, DMA drain, SMRAM/route rejection, request/response,
runtime backend selection, legacy/direct responses and fragment hold.

All four deliberate faults—bypassing reset, DMA drain or fragment hold, and
selecting the wrong backend—fail with native exit 1. The positive simulation
and compilation exit 0. Unit `ventium-fp-read-ack-seam-oct11.service`, invocation
`57b8c54dc7ba4204a7a2a46fc1eae8cb`, is terminal with exit 0. Receipt:
`seam-r1/closed.json`, SHA
`f698f11077c0a93470a677194e896e1191ece1effe3d67f961ce1fb44c851cf4`.
This verifies the combinational equations and bindings, not sequential cache
behavior, actual exception delivery or complete module elaboration.

## Next qualification

The matched synthesis/clock audit rejects the next-query header change.
The [private whole-core builder](../verif/l1/build_fp_read_ack_core.py) now
accepts either exact known parent hash; all four edited files have identical
hashes in both parents, and the unchanged source closure is inherited from
the explicitly selected parent, not mixed. This run selects carry model
`8c8898416ab8af4e6e53f9c4d94e3d9c2bbd1020edce3abdb300272dfc8104d6`.
The four recipe tests pass against both parent trees. Unit
`ventium-fp-read-ack-core-oct11.service`, invocation
`d141cf10c8af402cb9466edbc0374e52`, closes `core-r1` in **11.88 seconds**,
native 0, under the shared 32-compiler guard after both Vivado units closed.
Its exact four-file delta, unchanged defines, source pins and local native
harness/header dependency pass. Model SHA:
`b5554a977cd1ef4f12ee4a55a92fa514608cc902178aec2060a71fd00537e442`.

The unchanged cold paged memory, FP and AGI drivers pass **72 + 72 + 12
fixtures** at AXI latencies 0 and 7. All 75,192 candidate architectural records
match complete QEMU traces, and all complete candidate/parent architectural
and retirement-cycle streams match exactly. There are 1,500 targeted memory
V retirements; neither model disables UV or the fast paths. The longest
matrix takes 11.53 seconds. Native units `ventium-fp-read-ack-{memory,fp,agi}-oct11`
are terminal with exit 0. This is not a gameplay IPC result or a new CM score.

At this checkpoint, fragment/reset coverage, canonical gates and both original
long CoreMark seeds remained outstanding. Subsequent sections record the
fragment checks, short-seed comparisons and diagnostic synthesis; none replaces
the still-required long correctness seeds. Leaf equivalence alone does not prove
full wiring, cache ownership or full-system safety.
For the existing `run-fp-memory-fault-gate.sh` fixtures, both same-profile
models must use `FP_MEM_ADMIT=1` and `FP_LOAD_COMMAND=1`; neither is a disabled
handoff control. Check the **complete** cycle-functional trace against QEMU in
addition to the script's selected fault/retry records. Its functional-mode
control is diagnostic, not UV acceptance. The existing fixed QEMU port requires
serialization unless a separately reviewed per-run port adapter is used.

[The prepared fault-matrix runner](../verif/l1/run_fp_read_ack_faults.py)
serializes that unchanged gate on both models, then requires an additional
complete QEMU-versus-`cycle-func` comparison and exact same-input A/B records.
Its 16 fixtures cover FADD/FLD/FILD split-page retry, EM/TS priority, pending
FP-owner drain and DS/SS relocation. Both models retain early FP commands and
memory admission. It preserves nonzero gate exits even if a later comparison
passes, checks matching defines and input images, pins sources/binaries and
records actual child affinity. Three matrix/command tests pass. The native
matrix closes as `ventium-fp-read-ack-faults-oct11.service`, invocation
`63394e00fcec45d2b28981ff3e6cf5aa`, explicitly on CPU 12 within the normal
shared build guard. **All 16 fixtures / 32 model comparisons / 64 commands
pass**, including complete UV traces, unchanged A/B records and final guest
PASS witnesses. An independent re-read verifies 7,095 source pins, 609
artifacts and all 23,585 candidate architectural records against QEMU, with
no trace truncation or custom mask. Closed SHA:
`61835b209ff30def7796487f9d993495ab06cb5fac6648e82f86ca8f128a0fc1`.
No result from its functional-mode control counts as UV acceptance, and these
short fixtures do not replace the standard suite. These m64 page-boundary
fixtures also do not replace misaligned single-beat fragment/reset testing.

The unchanged canonical `make verify` closed **FAIL**, unit
`ventium-fp-read-ack-verify-oct11.service`, invocation
`2751b01f229a4bcd96cb8a4bf07273d0`: native make exit 2, 7 functional passes,
101 failures (91 length-only; ten first x87 C1 differences plus terminal
length), and 12 of 19 scored cycle failures. All 20 complete parent/candidate
RTL cycle streams remain identical. Functional traces use independently
initialized stack addresses, so this is **not** a claim of 108 identical
functional streams. No oracle, mask, band or trace-length workaround was used.
The independent canonical inventory checks 80,800 candidate records; SHA:
`ab85441bbb38281f5029c974860a8577ae3c9457bd09ed2bda43f059f439eee1`.

## Unaligned fragment fault/retry coverage

[The new fixture recipe](../verif/l1/prepare_fp_fragment_faults.py) shifts the
unchanged original FP operands and initialization words by 1, 2 or 3 bytes:
page offsets FFD, FFE and FFF. CR2 still must be 0x401000. All sixteen original
fault/priority variants are retained, including relocated DS/SS clients,
NM EM/TS priority and pending-FP handling. The first 32-bit operand read now
straddles a page; these are not merely aligned m64 reads across two beats.

[The runner](../verif/l1/run_fp_read_ack_fragments.py) passes **48 fixtures**,
each on parent/candidate and AXI latency 0/7: 192 measurements, **141,510
candidate architectural records and 29,640 V retirements**. Complete original
QEMU and parent state/cycle comparisons pass, with exactly one target page
fault then one FP-load command after retry and no target early-m64 take.
The original prelude's three other page faults are counted, not discarded.
No state injection, snapshot or changed exception handler is used.

Unit `ventium-fp-read-ack-fragments-oct11.service`, invocation
`b94fc95c17814b83876318eacfc20c2d`, exits 0 in 18.46 seconds with 32 workers.
Closed SHA: `2d09861a00f1216c9c205294cc0338e502b4c98cb7545f7d897d5ff351ae8dbf`.
This does **not** cover reset midway through a transaction.

[The independent combined audit](../verif/l1/audit_fp_read_ack.py) rechecks
the exact four-file delta, complete source closure, leaf/seam mutations,
156 directed cases, 16 aligned fault cases, 48 unaligned cases and canonical
failure inventory. Audit SHA:
`4cc88852c4e3245dda0eee35067ad416628915849cb4479b6125310f754b9eb7`.
The aligned-fault driver's invocation belongs to its nested build scope
(`a0125826adc8482fb6b91111b940d4a1`), not its outer service; both owners were
independently checked, including all sixteen journal completion messages.

## Full-PC and FPGA export

[The full-PC builder](build_fp_read_ack_soc.py) closes in 15.19 seconds with
32 compile jobs and a unique local harness/header dependency. All 102 shared
RTL payloads match the directed model; 154 simulator defines are unchanged.
Model: `f0277909b0c93780900619b2801c2da17372003e47ee9f21621a5727d71e949b`.
The inherited 98 full-SoC structural warnings are unchanged, not waived away
as a clean full-SoC lint result.

Both original **ten-iteration diagnostic** CoreMark seeds complete and pass
independent CRC, native owner, source-pin and complete guest-screen checks:

| Seed | Parent ticks | Candidate ticks | Change |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 0% |
| Validation | 4,753,406 | 4,753,406 | 0% |

These runs exercise the real posted-16 AXI model and UV/fast paths (over one
million V retirements per seed). They are **not duration-valid scores**, the
original long correctness seeds or a standard-suite pass. Unit
`ventium-v-carry-cm10-read-ack-oct11.service` has a historical prefix but uses
the read-ACK model above; invocation `0dc8658ba254448b8b9f2cabf223dc3a` is
terminal, native exit 0 for both seeds, no OOM and all children reaped.

[The FPGA exporter](freeze_fp_read_ack_rk_candidate.py) preserves all 156
hardware defines, full P5 L1s, posted-16 writes, platform L2 configuration and
40/100 MHz constraints. Its 190 payloads differ from the carry parent only
in the four intended files; 117 filelist units and 49 include edges are
resolved. Manifest SHA:
`1be147cc54d3f92991bef55d739fb2254eb5883079fe075da3cdee01385a1383`.
The independent export audit rechecks 35,704 input pins. Strict exported
CPU-hierarchy lint passes in 2.29 seconds, invocation
`914f5e5cda474c3abae791ee2dc42782`; this is not full-SoC lint.

Native synthesis **started at 2026-10-11 01:28:58 UTC**, unit
`ventium-fp-read-ack-full-synth-oct11.service`, invocation
`83f3739ae3434163af3312effdc12d0a`. The single guarded Vivado family has an
8 GiB RAM cap, 6 GiB swap cap, 4 GiB disk stop floor and 30-minute native
deadline. Actual native affinity is CPUs 12–15; `general.maxThreads=1` and
one synthesis worker remain unchanged.

The native owner closes with **exit 0 in 1,011.42 seconds** at 01:45 UTC.
The independent closure audit rechecks **35,920 input pins**, all **156
hardware defines**, 148 native Verilog inputs and the exact four changed
payloads. Peak RAM is 8 GiB, peak swap 1.034 GiB; no OOM or resource stop
occurs. The inherited generated-PS `create_clock` unknown-pin warning remains
recorded (one critical warning, 1,568 warnings); it is not silently waived.

| Synthesized resources | Carry parent | Read-ACK candidate | Change |
| --- | ---: | ---: | ---: |
| CLB LUTs | 197,313 | 197,169 | -144 |
| Registers | 54,645 | 54,631 | -14 |
| BRAM tiles | 277.5 | 277.5 | 0 |
| DSPs | 47 | 47 | 0 |

Synthesis audit SHA:
`a7124d9fc44e33a42750ff0faeabc6c49f46f12ce2fde41ca20577487791cca0`.
Checkpoint SHA:
`16b48264480c37121b66e6ebf4e63eee9fcb87ed56f168e269a4637fc43209f3`.

`ventium-fp-read-ack-audit-queue-oct11.service`, invocation
`d50545b96faa4e44892a8d80b727c187`, has audited that exact native closure and
launched `ventium-fp-read-ack-clock-oct11.service`, invocation
`6d91d26e71bf4a5d8161b11a8fdbd4cc`, for candidate/carry-parent original-clock
comparison. The candidate project reports the original 40 MHz core and
100 MHz PL clocks. The queue does not retry a failed run or launch
placement/routing. Both timing audit and queue have now closed with exit 0.
The audit takes **246.17 seconds**, checks **35,952 input pins**, reports no
black boxes or structural DRC errors, and observes no OOM.

| Matched unplaced synthesis | Carry parent | Read-ACK candidate |
| --- | ---: | ---: |
| Core Fmax estimate | 23.58546 MHz | **23.50176 MHz** |
| Setup slack at 25 ns | -17.399 ns | -17.550 ns |
| Worst path logic levels | 146 | 148 |

The global estimate regresses **0.355%**; this is **not** an accepted standalone
frequency improvement. All 30 reported worst paths now end at L1 `dc_lru`
data inputs, not FPU bank enables. The worst has 42.339 ns data delay:
9.433 ns logic and 32.906 ns estimated routing. It traverses frontend decode,
next-read address/permission preparation, lookup, paired-store admission,
backing alias/credit logic, ordinary ACK, next-read commit and LRU update.
The FP cut exposes another long path; it does not remove the need to shorten
that common chain. No false-path exception is justified by this observation.
Core hold slack remains -0.101 ns. Timing audit SHA:
`66fea69d45499d10c398755a1a26581dd7b11cfe305540503a9a043ed08b51fc`.

The best retained estimate remains **23.58546 MHz**, below the **40 MHz target**.
No placement, routing, new bitstream or physical acceptance is claimed.

Before launch, 67 closed builds' generated `Vventium_top`/`Vsystem` C++ and
compiler intermediates were losslessly archived and checked with
`tar --compare` plus file hashes before removing the loose copies. This
recovers **2,849,258,354 bytes (2.65 GiB)**; available disk reaches 7.9 GiB.
RTL, binaries, private harness objects/headers, logs, traces, media and board
captures are retained. One historical build with input drift is untouched.
Each `read-ack-generated-archive-closed.json` records the exact restoration
command. Aggregate evidence:
`/home/yukidama/external/tmp/ventium-read-ack-recovery.AKq4H65m/r2-closed.json`,
SHA `81386389b37b1d85b63366f056f262890dc05d1246b1ae6786ef26b327f25e33`.
All current export input pins were rechecked unchanged after cleanup.

## Additional sequential reset regression — R3 passes

[The R3 testbench](../verif/l1/tb_fp_read_ack_reset_r3.sv) exercises the actual
L1 array and backing handshake, without injecting internal state. At backing
delays 0, 3 and 7 it resets each incomplete-fill position (0–7 acknowledged
beats), aborts a resident response before its sampling edge, aborts a blocked
store, and checks that reset does not undo an acknowledged write. A separate
diagnostic hit-stream profile additionally holds a response while the live
address changes, then tests both reset and consumption with no new request.

[The R3 runner](../verif/l1/run_fp_read_ack_reset_r3.py) compares the unchanged
carry parent and exact exported candidate with all hardware feature defines
retained (only `SYNTHESIS` removed to execute assertions). The streaming
profile adds `VEN_L1D_HIT_STREAM`; it is not the deployed profile. Inputs and
logs are pinned, structural lint classes are fatal, and parent/candidate
completion counts must agree. This is cache-level, not whole-core reset
coverage or FPGA acceptance.

Preflight found that R1 omitted `ven_p54_hit_return` and its bank arbiter from
the source list despite enabling the hardware dual-hit profile. Its pending
queue (`d7dd46eb7ffd4cd59a75919e2e8a0bb5`) was explicitly stopped before any
native build/test launched; no `reset-r1` output or native log exists. R1 and
its original pin receipt remain preserved. R2 supplies both dependencies and
checks each against both frozen manifests; the testbench is unchanged.

R2 compiles the unchanged parent successfully but fails
`RESIDENT_ACK_FIXTURE_MISSING`: a first cold read may complete by early-word
forwarding without a reusable full-line window. Requiring an immediate reuse
ACK was a fixture error, not an established DUT defect. R2 sources, binary,
logs and failed receipt remain intact under `reset-r2`.

R3 waits at most two clocks for the resident response, checks that no backing
read occurred, then resets after the response-producing edge and before the
next consumption edge. It does not force cache state or weaken response/data
checks. Unit `ventium-fp-read-ack-reset-r3-oct11.service`, invocation
`fdb0f1bcc7f5472ea8d12c835762631b`, closes native 0 in **6.93 seconds** under
scope invocation `3c67ae277d504e309a253d4632c61d09`, CPU 16.

All four parent/candidate hardware/diagnostic-stream builds and runs exit 0.
Each checks 24 abandoned fills, 3 aborted resident responses, 3 aborted stores
and 3 preserved committed writes. The hardware profile completes 36 reads,
60 resets and 1,890 ACK comparisons; streaming completes 48 reads, 66 resets,
3 held-response consumptions and 2,173 comparisons. Parent/candidate counts
match exactly. The independent audit checks 13 source/tool pins, all four
native binaries/logs/commands and their scoped journal records. Receipt:
`reset-r3/independent-audit.json`, SHA
`b66220b070c6da63ba972d8d67ad8efea2dfec53e59b59c7a24bdc7efbf0e850`.
This remains cache-level reset coverage, not whole-core or board acceptance.

Verified gameplay baseline: **0.51030715 U+V retirement-event IPC**, model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates both timing
candidates; neither has a gameplay measurement.
