# SRT remainder operand isolation — October 12

**Private directed-tested candidate; canonical, timing and FPGA qualification incomplete.**
This candidate's completed post-synthesis, unplaced estimate is **29.69650 MHz**,
below the required **40 MHz** and about **2.01% slower** than its
[30.30487 MHz parent](PAYLOAD_CURRENT_TIMING.md). The area reduction below is
not a timing improvement or an accepted FPGA fix.

## Structural change

The mapped worst path crosses reference decode, L1 response selection, FP
memory conversion and SRT remainder setup. In the shared FPU, FPREM/FPREM1
actually use ST0/STi, never a memory operand. Their setup need not inherit the
divide operand mux's memory-data dependency. This is not justification for a
timing exception: remove the unnecessary connection in RTL instead.

[`prepare_rem_operand_split.py`](../verif/srt/prepare_rem_operand_split.py)
derives exactly two sources from the measured candidate. The default-off
`VEN_SRT_REM_OPERAND_SPLIT` adds two combinational operand wires to the existing
SRT instance, connected directly to the existing architectural FP-register
read outputs. Only remainder setup uses these ports. The shared recurrence,
rounder, divider, architectural FP storage, start/accept/fault handling and
operation clock counts remain unchanged. It creates no second arithmetic engine,
memory port, pipeline stage, guest special case, or saved-state dependency.

Carry state `C` is zeroed in IDLE instead of under input-dependent classification
on the three accepted setup branches. Every arithmetic entry already requires
that zero; IDLE and SPECIAL do not consume it. The prior qacc optimization uses
the same dead-state initialization technique. Its altered idle value is not
claimed to be an all-internal-bits equivalence. Every consuming state's carry
value is compared in the native test.

The shared-top simulation witness checks that every actual remainder start's
original `srt_a/srt_b` equals the new ST0/STi wiring. The later whole-core
canonical run retires 36 FPREM and 22 FPREM1 instructions with this assertion
compiled and enabled, without a fatal. This is bounded caller coverage, not a
universal proof. Non-shared integrations must not enable the new port flag
without explicitly wiring and verifying it.

## Executed microtest

Three host tests pass: exact source/recurrence/command-mux scope, drift and
reapplication rejection, and preservation of the expanded native fixture's
checks. The first host attempt rejects an ambiguous whitespace suffix in the
carry-assignment anchor; requiring a complete line fixes the recipe before any
native launch. No old source or active synthesis input is edited.

[`run_rem_operand_split.py`](../verif/srt/run_rem_operand_split.py) instantiates
the actual old and new SRT engines. It extends the existing input-normalization
miter with signed zeros, infinities, NaNs and smallest denormals in both operands.
The enabled test deliberately corrupts common divide inputs during remainder
commands, and corrupts the new remainder inputs during divide/sqrt. It retains
busy-time input changes, ignored starts, reset interruption, precision/rounding
modes, FDIV-bug selection, denormal leading-one positions and unnormal inputs.

Both flag-off and flag-on runs pass **4,736 operations / 165,052 cycle checks /
24 resets each**: 1,558 divide, 1,557 square root and 1,621 remainder operations.
Busy/done, phase, status and valid results match cycle-for-cycle; unchanged
internal operands/recurrence state and carry in every consuming state match too.
Two separately compiled mutants fail natively with exit 1: use of the corrupt
common remainder input, and nonzero carry initialization. Neither negative is
a build failure or timeout. This is A/B equivalence, not an independent numeric
oracle or full processor test.

Evidence: `/home/yukidama/external/tmp/ventium-srt-rem-split.pM3Jsjhi/miter-r1`.
Owner `ventium-srt-rem-split-miter-oct12.service`, invocation
`ff416163c7c243ee96b8c8012e6aebde`, closes native zero in **15.83 s**, including
four guarded 32-job builds. Actual simulator affinities are CPU 11; all 13
input/generated-source pins and the four artifact sets independently rehash.
Closure SHA-256:
`6920cb5bd306f0457aa8c098c8301bf014f9cf5a7e9a6e1ccacc74e4d2ead9e4`.

## Companion V-owner clear cut

The separate measured V-capture path still traverses backing/write ACK into
`pipe_mem_v_hit_q` clearing. The
[exact-parent recipe](../verif/l1/prepare_v_owner_read_clear.py) changes only that
consumer to fragment-qualified `mem_read_ack`, in the raw-V/no-dual-prime
profile. A live V owner here implies an active read-only U packet. When the
owner is already zero, a different clear predicate cannot change its state.
Real ACK, capture and fault/reset/terminal/translation priorities are unchanged.
The existing other-profile expression remains behind the original guards.

Four host tests pass, including all 4,096 abstract Boolean combinations filtered
by the owner/ACK contract, exact source scope, mutation-fixture coverage and
actual Icarus preprocessing of four profiles. This is not an inductive proof
of the whole core or behavior qualification of the other priming profiles.

[`run_v_owner_read_clear.py`](../verif/l1/run_v_owner_read_clear.py) compares
independent old/new V registers driven by the actual source-extracted U/request
transitions. Its decoder/bank/translation inputs remain abstract, and acceptance
obeys the existing fresh-V ownership assertion. No DUT state is deposited.
It checks **77,834 states**, observing 5,108 live owners, 4,083 read waits,
five held-store samples, 39,834 orphan drains and 6,162 acceptance samples.
Raw-fragment ACK, missing-ACK and lost-fault-clear mutants all compile and fail
natively with exit 1. The source witness independently checks read/general ACK
equality whenever the clear consumer has a live read owner.

Evidence: `v-clear-leaf-r1` beside `miter-r1` above. Owner
`ventium-v-owner-read-clear-leaf-oct12.service`, invocation
`014b0798f6614e0a955ff680aac43d0e`, closes native zero in **1.81 s** on CPU 12.
Eight input/generated-source pins and all four artifact sets independently
rehash. Closure SHA-256:
`727bad2bad7fae99c8c96efe2b11789036bdf8c0c03f33c86d6bfa28cc4df45d`.

## Combined core build

[`build_rem_split_v_clear_core.py`](../verif/srt/build_rem_split_v_clear_core.py)
admits both closed native microtests and the measured parent's timing evidence,
retains the complete 195-file source closure, and changes exactly the SRT engine,
shared FP top and core V-clear consumer. It retains all 151 parent definitions
and adds only the SRT operand-split flag. A private C++ harness and its generated
header dependency are checked; the canonical executable is untouched. Two
builder-admission host tests reject missing modes/assertions and failed/missing
negative controls. A passing compile is not a processor regression result.

The combined build closes native zero as `ventium-rem-split-v-clear-core-oct12.service`,
invocation `96c434e02a514ccab71773cdf765a669`, into `core-r1` beside the microtests.
It takes **19.92 s**. All 2,745 pins independently rehash. The native command has
152 unique definitions; `VEN_FPREM` occurs twice, identically in the parent,
because the testbench Makefile adds it to the explicit profile. The only added
token is `VEN_SRT_REM_OPERAND_SPLIT`; both new assertions occur in generated C++.
An initial independent check incorrectly assumed no duplicate command tokens;
comparison with the parent and Makefile resolves that checker error. No native
build failure or source change is hidden by this correction.
Model SHA-256:
`37250c5f8b7350d77b7e102e5fc6b7ebb99c078873534634e84f142c0b779329`.
Build closure SHA-256:
`9772c302359d9f2893338d632d1adc3557fcacbcf065665eeccc05fc90fbea63`.
No Vivado family overlaps it.

## Whole-core regression so far

[`run_rem_split_core.py`](../verif/srt/run_rem_split_core.py) reuses the existing
cold-reset corpora, changing only admission of the one added define. Two host
tests check preservation of their comparisons, fixtures and complete-stream
checks. Four native matrices close zero with source/binary pins unchanged:

| Matrix | Fixtures, each at AXI latency 0/7 | Candidate records | Candidate V retirements |
| --- | ---: | ---: | ---: |
| Memory | 72 | 31,392 | 1,500 |
| Held read | 24 | 9,200 | 1,360 |
| FP memory operands | 384 | 208,128 | 768 |
| Integer/store | 256 | 169,472 | 512 |

Total **418,192 records**. Complete QEMU architectural comparisons and full
parent/candidate cycle streams match. Services `ventium-rem-split-{memory,held,fp,integer}-oct12`
retain invocations `72bfa217f08a4330a950b7626fc8db72`,
`507c371ca1ac4586ae56c231942eada2`, `06e3313d5d7143ac8e67081721cc7e77`,
and `412628eb299440d6b890c855a94ad228`, respectively. Results are `*-r1` beside
the core. They use disjoint CPU affinity sets and 4/8/16/4 workers; native-test
cgroups have 3 GiB RAM, no swap and 2,048 tasks, separate from the compiler guard.

The unchanged canonical `make verify` closes **FAIL: 7 PASS / 101 FAIL**, make
exit 2, in 410.68 s. Service `ventium-rem-split-verify-oct12`, invocation
`3c9b4e7f89f3406c828bccab50548937`, is terminal exit 1 as intended for a failed
gate. All 20 complete cycle streams match the parent; no goldens, masks or bands
are changed. The guard selects one verification worker despite the driver's
four-worker request; this is slower host execution, not a guest cycle change.
`tx_fprem` retains the parent's status-word mismatch at record 3 (`3a00` QEMU
versus `3800` RTL) and the 300/301 terminal-record mismatch. No FPREM differential
pass is claimed.

Complete same-input replay then passes **108 programs / 80,800 records**, in
73.26 s, with all pins unchanged. Its service
`ventium-rem-split-canonical-ab-oct12` closes zero under invocation
`ff6c378bf28c4e719e5c06aa38c5a9b0`; closure SHA-256:
`6badf707ea548aabb59929e0d5ae7c9586f7dbadd22134211ac06d3c2226e7b7`.
All 16 fault cases also pass both models and complete UV/QEMU comparisons
(23,585 candidate records), with unchanged input/artifact pins and no timeout.
Owner `ventium-rem-split-faults-oct12`, invocation
`67eb5c53204d4fe693f1566fc220c1da`, closes zero; closure SHA-256:
`0f4e18a21def4c3324c1d4059970ea9a16d4da9fa9679676f3ad52cfeef16a7a`.
Thus the five directed matrices cover **441,777 candidate records**, separately
from the 80,800-record replay. Replay does not waive the canonical failures.

## PC, hardware export and short CoreMark

[`build_rem_split_soc.py`](build_rem_split_soc.py) transfers exactly three files
and checks all 102 shared core/PC RTL inputs. The original posted-16 platform,
155 native definitions and private harness contract are retained; only the SRT
flag is added. Native build takes **23.16 s**, owner
`ventium-rem-split-soc-oct12`, invocation `3b8027aafe204580a651a7a12a8cd457`.
The existing 98 full-platform structural warnings are byte-identical; this is
not a clean full-SoC lint claim. The model-local harness header check passes.
PC model SHA-256:
`61763f61ef15dadd24602e8cc86b1b4e3bdab75b5bc2c3280d84ad90bdb8cd58`.

[`freeze_rem_split_rk_candidate.py`](freeze_rem_split_rk_candidate.py) preserves
190 hardware payloads, all 170 simulation-matched RTL/header files and the
original 40/100 MHz clock setup. The exact 158 ordered hardware definitions
equal the 156 simulation definitions plus `SYNTHESIS`/`VTM_NO_DPI`. Three
source/profile tests include real Tcl expansion and a wrong-flag negative. An
initial test used a lexical temporary symlink path rather than the resolved
path emitted by Tcl; resolving that path fixes the test without changing the
hardware wrapper. Manifest SHA-256:
`4329eff21cca7394e53cba00944ac165bd95b7d52fff35bdad76acc4d89d2d79`.

[`lint_rem_split_rk.py`](lint_rem_split_rk.py) runs the unchanged strict core lint
with that exact profile: native zero, **3.73 s**, inputs unchanged. Structural
error classes remain enabled; no full-SoC or board pass is implied.

Both original short 10-iteration CoreMark disks cold-boot and match the pinned
reference's five CRCs per seed. Performance/validation ticks remain exactly
**4,767,218 / 4,753,406**: **0% cycle-count gain/regression**, intentionally.
Actual V retirements are 1,055,307 / 1,054,254. Service
`ventium-v-carry-cm10-rem-split-oct12`, invocation
`b351681279284b059d27154a6df01ff0`, closes zero; independent audit rechecks 3,930
source pins, native argv, CPU 11 affinity, process exit/reaping, ROM/media,
CRC/tick results and no OOM. Audit SHA-256:
`95c9c475fea9ad8bffbd584c15a4a9593de9654fad7a2e2521b7480b31fe2c94`.
These are not duration-valid scores or the full CoreMark acceptance seeds.

## Combined synthesis closed; timing audit running

[`prepare_rem_split_synthesis.py`](prepare_rem_split_synthesis.py) derives the
next controllers from the completed 30.30487 MHz run. Two preparation tests
check exact source identities, parent DCP/timing comparison and unchanged
resource monitor/stop/reap code. Native synthesis starts at **06:54:25 UTC**,
owner `ventium-rem-split-synth-oct12`, invocation
`64cbd5aaca99454689260a0c166cbc9b`. Sole Vivado scope invocation:
`455f024c3882426a9175bd5a420ec65a`.

Synthesis closes native zero at **07:26:18 UTC**, after **1,914.75 s**. The
independent audit rechecks **4,318 input pins**, all 158 ordered definitions,
148 native Verilog inputs and the exact three-file delta. Actual utilization is
**184,969 LUTs / 54,596 registers / 277.5 BRAM tiles / 47 DSPs**: 910 fewer LUTs
and two fewer registers than the matched parent, with BRAM/DSP unchanged.
This is not an isolated attribution to either of the two changes or an IPC gain.
The native summary has zero errors, one critical warning and 1,561 warnings;
the generated-PS-clock constraint warning still requires the independent
clock-net audit, not a clean-warning claim. There is no OOM/resource stop. Scope
peaks are 8 GiB RAM and 74,665,984 bytes swap, within the original caps.

DCP SHA-256:
`538e3b5e4dd6ac5bb09ae38d291e979a24005b05f1729db3b39543879a05ee6a`.
Independent synthesis audit SHA-256:
`1e55b7ec067965f724d0adabc0ca1f08ed1b22d6fc626ba074564e1aeba74f8d`.

The queue `ventium-rem-split-timing-queue-oct12`, invocation
`86989d99845a4c3dadbb123d648f1e71`, admits the native clock audit only after
that closure. `ventium-rem-split-clock-oct12` closes under invocation
`f80241e0860b47f99e59a1e49b09a2e0`. Evidence is in `synthesis-r1`, `clock-r1`
and `timing-queue-r1` beside the tests. The audit takes **491.35 s**, exits zero,
and independently rechecks 4,333 input pins. Actual core/PL clocks are 40/100 MHz;
there are no black boxes or checked structural DRC errors. Peak RAM is
4,588,265,472 bytes, swap zero, with no OOM. Audit SHA-256:
`1d4aff92ac2e3011981c139a4c01bb527a26d48f5509988f3a76f64911f6d565`.

The measured setup slack is **-8.674 ns at 25 ns**, giving **29.69650175 MHz**;
unplaced hold slack is -0.101 ns. The queue's `passed=true` means the audit
process completed successfully, not timing acceptance:
`synthesized_40mhz_requirement_met=false`. No implementation or deployment is
queued.

The new worst path runs from `eip_reg[0]` to `int_err_reg[*]/CE` through
**117 logic levels**. Data delay is 33.377 ns (6.493 ns logic plus 26.884 ns
estimated routing). The path crosses decode, memory-chain priming, paired-store
readiness, general backing/L1 ACK, fragment gating and far-load fault control.
Seventeen of the top thirty paths end at the interrupt-error enable; none of
those thirty ends at SRT state. The separately measured V-capture slack also
regresses to -7.824 ns from -6.338 ns. Moving the worst endpoint is not proof
of improved timing.

The matched `Default -no_timing_driven` mapper, real 40/100 MHz constraints,
UV+fast mode and full P5 caches are unchanged. RAM/swap remain capped at 8/6 GiB,
combined early stop 13 GiB, host floors 2 GiB, disk floor 4 GiB. The unchanged
7,208,493,056-byte conservative disk admission passes at 7,279,157,248 bytes;
no resource limit was raised to admit this run.

Next: remove the unnecessary general/write ACK dependency from the read-only
S_LOAD, S_LOAD2 and S_FLOAD completion consumers, with active read-owner/ACK
equality assertions and whole-core fault, page-crossing and cycle comparisons.
The prepared change is not yet timing-qualified and adds no cycle or new mode.
Canonical correctness, full standard suite and actual FPGA Win95/UI and Quake
timedemo remain required; none is waived by the directed tests. The inherited
hosted-mouse hardware gap described in the parent timing audit also remains.
The separately tested service/MMIO work in [PS2_DEVICE.md](PS2_DEVICE.md) is
not incorporated in this frozen hardware export and is not a board/UI pass.

## Scratch retention

Eight regenerable precompiled headers from the closed SRT unit builds were
deleted (656,483,965 bytes); sources, binaries and native logs remain. A further
59,580 closed diagnostic streams from this candidate's FP/integer matrices and
two old branch matrices are retained in `closed-regression-text.tar.gz` alongside
this run. Every archive member was byte-verified before removing its unpacked
copy; all current input pins remain unchanged. Archive SHA-256:
`d22fa8b8e566b651a688031afdfda983f68bc2159efbb963c49a8add02eda8f2`.
It stores 1,746,924,520 original bytes in 133,457,247 bytes. Recover with
`tar -xzf closed-regression-text.tar.gz -C /home/yukidama/external/tmp` from
the evidence root. Source/media/checkpoints and models were not deleted.

After the full core/PC builds close, their four unpinned, unused precompiled
headers are also removed (376,162,049 bytes); native binaries and all pinned
dependencies remain. `closed-memory-text.tar.gz` retains another 8,976 closed
memory-matrix streams, with every member byte-verified: 160,918,820 original
bytes in 13,422,465 bytes. SHA-256:
`41e1724478c96e5c6506033f5214cddcc8081c6c07c441e584b37841def4037b`.
Restore with the same `tar -xzf ARCHIVE -C /home/yukidama/external/tmp` procedure.

Gameplay IPC is **unmeasured for this proposal**. Last verified baseline:
**0.51030715 total U+V simulated retirement-event IPC**, older model `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**; not board IPC or a full-demo mean.
