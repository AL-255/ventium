# Credit-qualified paired-store enqueue — 2026-10-16

Status: **isolated proposal, not production RTL or an accepted processor fix**.
Native admission-equation and first full-cache/AXI A/B tests pass. Timing,
whole-core correctness, gameplay, the standard suite and FPGA acceptance are
unmeasured. No new Vivado run or deployment was launched for this proposal.

## Reason and scope

The [system read ACK cut](SYSTEM_READ_ACK.md) regressed the matched unplaced
estimate to 34.7524 MHz from its RAW/input parent's 35.3744 MHz. The leading
paths still traverse paired-store credit and general ACK. This proposal starts
from that **RAW/input parent**, not the timing-regressed ACK derivative.

The directly connected L1 already qualifies a paired backing request with
`m_pair_ready`. The AXI master then repeats pair-credit qualification at enqueue.
Under that explicit caller contract, ordinary single-slot credit is sufficient
for enqueue: the paired request could not have arrived without the stronger
pair credit. The original pair/quad queue allocation and payload logic remain
unchanged, as do every downstream state-machine and AXI-output equation.

`prepare_qualified_pair_credit.py` pins the complete predecessor master, cache
and integration wrapper. It produces two changed files:

- `ven_axi_master.sv`: adds default-off `PAIR_REQ_CREDIT_QUALIFIED`. The default
  branch retains the original enqueue equation verbatim. The opt-in branch
  removes only the repeated pair-credit selection, retaining single credit,
  read-idle, request, write, shutdown, alias and fatal-error guards. Nonsynthesis
  assertions check the caller contract and old/new enqueue equality.
- `ventium_l1_axi.sv`: enables the contract only for dual-store, same-clock,
  no-L2 integration. The CDC branch remains excluded; `EN_L2=1` does not enable
  it. The intervening SMRAM deny logic can only suppress the qualified pair.

Derived master SHA-256:
`00089d0af807232a41af150f5f9c0d176258902a5a869873063da6f6e0edba1d`;
derived wrapper:
`2e7d24a7ae3c1802c8c3ca833330592723271332122bb555174e8e24879ce20c`.

The cache itself is byte-identical. No extra buffering, new latency, forced
pairing, disabled fast path, cache-size change, guest change or save-state is
involved. The dirty checkout's RTL and running full-PC models are untouched.

**This contract cannot be a generic default.** With one free slot and a
non-quad pair held by an unqualified producer, the shortcut admits a request
the original master correctly rejects. The negative test demonstrates that
counterexample explicitly. It must not be enabled on a different producer or
across a clock/queue boundary without a new integration proof.

## Retained checks

Evidence root:
`/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4`.
Exact inputs: `raw-prime-storage-fpga-r1/ventium/rtl/mem`.

| Check | Result and limitation |
|---|---|
| Host source/scope tests | 6 pass; source preservation, default-off and CDC/L2 guards |
| Native equation enumeration | 8,192 binary combinations per profile; generic and qualified, quad off/on |
| Qualified combinations compared | 7,344 without quad; 7,368 with quad; all other combinations explicitly excluded by the contract |
| Generic comparisons | All 8,192 per profile, with no caller assumption |
| Negative equation controls | Fatal, alias and single-credit guard removals fail; unqualified-pair counterexample fails |
| Complete L1/AXI A/B | 2,387 clocks, 68 U stores, 3 paired V stores, including 1 load/store pair and 1 quad enqueue |
| Backpressure coverage | 30 blocked-store clocks; 84 full-queue clocks |
| Cache/AXI equivalence | 4,781 half-edge checks; cache data/valid/tag/LRU arrays, queue state, packets and final 64 KiB RAM agree |
| Sequential negative control | Removing single credit fails with `BACKING-AXI-MISMATCH m_ack` |

The equation test uses Icarus's four-state engine with **binary stimulus**; it
is not an exhaustive X-propagation or sequential proof. The cache test uses
two real full P5 caches, complete AXI masters and independent RAM slaves, with
the parent's hardware feature defines, 32-job bounded compilation and unchanged
strict structural-warning errors. The first run used all 159 hardware defines;
the follow-up removed **only `SYNTHESIS`** (158 remain) so the actual master/cache
contract assertions execute too. Both runs produce the same coverage counts;
the generated follow-up model contains both new contract assertions. The first
run's external comparisons were active, but its internal nonsynthesis witnesses
were excluded and are not claimed as tested there. It supplies requests through public ports,
not forced cache/queue state. All candidate/default pair-ready outputs agree,
including idle hints. The complete integration wrapper and processor are not
instantiated by this first cache test.

Successful receipts:

- `qualified-pair-credit-leaf-r2/closed.json`: 0.277 seconds; 42 input/output
  pins independently rechecked, four positive profiles and four expected
  failures.
- `qualified-pair-credit-cache-r2/closed.json`: 4.787 seconds including build,
  native exit 0; 65 pins independently rechecked. Owner
  `ventium-qualified-pair-cache-oct16-r2.service`, invocation
  `6eec9d6c85dc476fbe3042f70e2a3083`, exited successfully, MainPID 0.
- `qualified-pair-credit-cache-mutant-r1/closed.json`: 4.635 seconds, native
  exit 1 as required; 65 pins independently rechecked. Owner
  `ventium-qualified-pair-cache-mutant-oct16-r1.service`, invocation
  `2a29c67300214008b95160bf3096c405`, exited successfully after grading that
  expected failure. This is not a passing mutant design.
- `qualified-pair-credit-cache-witness-r1/closed.json`: 4.790 seconds including
  build, native exit 0, 65 pins independently rechecked, same complete A/B
  results with internal assertions included. Owner
  `ventium-qualified-pair-cache-witness-oct16-r1.service`, invocation
  `be8dfacb127a42bc98ff4fd14757d81e`, exited successfully, MainPID 0. This is
  the current positive receipt. Earlier receipts retain their frozen driver
  versions; the current driver intentionally includes the witnesses.

Failed infrastructure attempts remain retained: leaf r1 truncated a
preprocessor branch during equation extraction; cache r1 used an obsolete
flat-tag observation name. Leaf r2 retains both preprocessor arms, and cache
r2 compares both current per-way tag arrays in full. Neither failed attempt
is counted as a correctness pass.

## Remaining gates

Before deriving or synthesizing a whole-core candidate:

1. Expand native sequential tests for faulting B/R IDs/responses, orphan
   responses, shutdown, reset, wrap/narrow accesses and same-edge release.
   Boolean fatal/alias enumeration alone does not cover response ownership.
2. Exercise the actual no-L2 wrapper, including SMRAM/route denial. Verify
   default/unpaired and CDC exclusion configurations separately.
3. Build the exact two-file derivative, run canonical `make verify` and
   system/fault comparisons in UV + fast-pipe mode with actual V retirement.
   Existing canonical failures remain failures, not newly waived passes.
4. Only then measure matched synthesis/timing. This simplification may have
   little timing effect because the original ready-to-request path remains;
   **no MHz, area, CPI or IPC gain is claimed**.

Full CoreMark correctness/scoring, Win95 desktop and UI, Quake timedemo and
matching physical-FPGA validation remain mandatory before accepting a major
core/cache change. The earlier ACK candidate's ongoing CoreMark runs do not
qualify this different proposal.

Last verified gameplay baseline: **0.497040387 total U+V IPC**, model
`b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e`, clocks
**1,100,065,247–2,100,065,247**. U-only IPC is 0.384240079. That model predates
the RAW/input and ACK candidates and this proposal; none has a newer verified
gameplay measurement. This is not timedemo completion or FPGA acceptance.
