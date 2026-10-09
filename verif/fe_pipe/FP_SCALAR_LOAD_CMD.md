# Scalar x87 final-operand handoff — October 9

Private/default-off candidate, **not production or FPGA acceptance**.
Latest verified gameplay: **0.44004644 total U+V IPC**, read-prime `15f56054`,
clocks **1,200,012,763–1,300,012,763**. It predates the running combined FP
candidate and this new experiment. Neither has a gameplay result yet.

## Removed bubble

The existing final-operand handoff accepts floating arithmetic and FLD/FILD,
but integer-memory arithmetic and memory compares always take another
`S_FEXEC` clock after acquiring their complete operand.

`prepare-fp-scalar-load-cmd.py` changes only the command whitelist in a private
`core.sv`: `VEN_FP_SCALAR_LOAD_CMD` adds `FX_AR_I32`, `FX_FCOM_M32` and
`FX_FCOM_M64`, only with all FP exceptions masked and no pending ES. Both pop
and non-pop comparisons use their existing decoded pop field. Unmasked/pending
cases keep the old path. No new queue eligibility, storage, arithmetic unit,
memory port, cacheability rule or early operand acquisition is introduced.

The unchanged guard still requires the final **fragment-engine** ACK, a full
32/64-bit operand, an enabled precise FSM edge, and inactive architectural/host
debug. The existing command-ready, registered payload, ordered response and
retirement paths remain authoritative. No EX latency is shortened. Stores,
environment operations, m16/m80 forms and unsupported shapes are not added.

## Measured directed results

Root: `external/tmp/ventium-fp-scalar-load-cmd.tsLkBG8b`.
Board-core model:
`9fa1b292ba13a2a0790519a1eac3e37a89a24b0e204bfd553e8b81eb68ccf14f`.
Full-address model with corrected standalone store-policy driver:
`09aa12d9a1c0f6c5f13a88051c2e1efff45eb52d2c90d3fd076af277572fe856`.
The board A/B retains identical parent harnesses; these are isolated RTL
measurements, not a physical DDR performance model.

Representative warm loops, flat layout, byte17 code, zero added AXI latency:

| Loop operation | Parent clocks | Candidate clocks | Fewer clocks |
| --- | ---: | ---: | ---: |
| FIADD/FIMUL/FISUB/FISUBR m32 | 7 | 6 | 14.29% |
| FIDIV/FIDIVR m32 | 42 | 41 | 2.38% |
| FCOM m32/m64 | 4 | 3 | 25% |
| FCOMP m32/m64 plus balancing FLD1 | 5 | 4 | 20% |

These are **not gameplay gains**. Ordinary stores/control/FADD and unmasked
negative controls retain their measured warm clocks.

- `matrix-r1`: **568 complete QEMU architectural comparisons**, each also
  executed in UV cycle mode. Seventeen operation/control kernels, flat and
  relocated paging, four code positions, AXI0/7 and unmasked controls. Every
  eligible run witnesses all 256 final-operand handoffs in each trace mode.
  Whole-program and long steady-window nonregression checks pass.
- `fault-r1`: **24 complete comparisons plus cycle executions**. FIADD32,
  FCOM32/64; absent first or split second operand page; an older divide must
  finish before #PF. The guest checks exact fault PC/CR2, prior-only FP state,
  saved instruction/data pointers, PTE repair and retry. Exactly nine source
  commands execute, never a partially read or faulting command.
- `events-r1`: **12 complete comparisons plus cycle executions**. Normal,
  TF, RF, TS and EM visits; exact #DB/#NM frame/DR6 checks and final FP value.
  Each candidate has six handoffs per trace mode, while TF/RF retain the
  response path. No STEP mode is used as acceptance.
- `system-matrix`: **76/76** broader system comparisons pass, with complete
  parent architectural parity and matching cycle-mode PC streams.
- `leaf-r5`: actual extracted candidate command/payload expressions,
  **114,688 checks each** enabled and disabled. Every 7-bit operation value,
  operand width/beat/high-half combination, 256 guard combinations and every
  mask/ES combination are checked. An intentionally disabled implementation
  under the positive test fails at the expected FCOM32 case, native exit1.
- Three synthesis-guard core lint profiles pass all six structural hard
  classes. These are not physical timing or full-PC lint sign-off.
- The 38 FP recipe/driver unit tests pass. `driver-regression-r1` also passes
  64 complete comparisons on the preceding combined m64 candidate, verifying
  that the extended shared driver retains its original checks.

The unchanged generic gate still **FAILS**: 101 terminal-record mismatches
and four hard cycle bands. Fresh same-input replays match all **108 complete
architectural record sequences** of the policy-corrected parent. This is
nonregression, not a green generic gate. No records, masks or bands are relaxed.

## Retained failed attempts

Leaf R1/R2 correctly refuse `checks=0`: the generated coroutine increments a
local counter but folds its final display to literal zero. Making that
test-only coverage witness observable fixes the count; no DUT change. R3
passes both positive leaves. R4's negative control reaches the intended
assertion, but its grader incorrectly expects SIGABRT rather than this pinned
runtime's exit1. R5 reruns all variants and requires both exit1 and the exact
expected negative assertion. Earlier refusals remain failed.

The initial short CoreMark launcher refuses a missing required memory/task
envelope **before launching a native model**. It is retained in `coremark-r1`;
the correctly capped attempt uses a fresh directory, not a relabelled result.

`coremark-r2` passes both short seeds on both backends, with all five CRCs,
native exit0, genuine V retirement, zero fault deliveries, stable inputs and
zero OOM. Direct clocks remain **4,821,818/4,815,105**; corrected low-RAM AXI0
clocks remain **5,482,773/5,474,040**, exactly matching the parent. These are
10-iteration diagnostics, not score-eligible full seeds. The FPGA/cache-backed
2.1 target is not established by them.

## Remaining

No full-PC or FPGA image contains this flag yet. Complete the generic gate,
full standard suite, arbitrary-arrival IRQ/relocated-debug qualification and
physical implementation before promotion. The existing combined cold Quake
and Win95 runs remain unchanged; no extra cold pair was launched for this
small experiment. Their fixed gameplay observation is predeclared in
`ventium-fp-combined-soc.WPpVLjvn/gameplay-plan.json`.
