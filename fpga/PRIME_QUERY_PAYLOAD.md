# Resident-query payload selection — October 12

**Prepared and microtested only; no full-core, timing or FPGA acceptance.**
The running [load-ACK synthesis](LOAD_READ_ACK_TIMING.md) is unchanged and does
not include this separate candidate. The target remains **at least 40 MHz
post-synthesis Fmax** with UV, fast paths and full P5 caches. The last completed
parent estimate is **29.69650 MHz**, not a timing pass.

## Measured dependency and proposed cut

The prior synthesized report's LRU path traverses `mc_prime_offer`,
`mem_next_addr`, address-region decoding (`mc_next_dram`), paired-store
readiness, snoop/continuation guards and `core_mem_next_commit` before the LRU
update. It has 120 logic levels and -8.617 ns slack at 25 ns. Its path is retained
in `ventium-srt-rem-split.pM3Jsjhi/clock-r1/core_setup_unplaced_estimate.rpt`
under external temporary storage. This is evidence of a late request qualifier
in the address-selection cone, not proof that the proposed cut reaches 40 MHz.

[`prepare_prime_query_payload.py`](../verif/l1/prepare_prime_query_payload.py)
changes two selectors in `core_mem_chain.svh`: the speculative read address and
byte/dword strobe use `!mc_valid_q`, rather than `mc_prime_offer`, to select the
live query payload. AGI/reference selector priority is unchanged.

Every retained offer requires `mc_valid_q`; all four live-prime classes exclude
it. Thus offered payloads are identical. Unoffered payloads may differ, which
is intentional: no new request/commit is generated, and the downstream
resident-cache lookup/capture requires its existing request-valid condition.
Memory-map decoding may evaluate another idle address but does not initiate
traffic. No new port, state, feature flag, exception, pipeline bubble or
arithmetic unit is added. All permission and coherence checks remain intact.

Simulation assertions compare old/new payloads on every request and require
every commit to have a request. They still need to execute in the whole core.
This is not a claim of equivalence for every internal idle signal.

## Executed checks

- Four source tests pass: exact two-selector scope, unchanged request/commit,
  drift/reapplication rejection, and simulation-only ownership witnesses.
- The [native extracted-equation miter](../verif/l1/test_prime_query_payload.py)
  passes **65,536 samples** in a complete 16-bit control sweep. It observes
  1,024 retained, 1,024 FP-self, 512 held-read, 256 fresh-read and 96 ordinary
  live-prime cases without AGI/reference selection, plus 16,384 AGI and 8,192
  reference offers. Those are overlapping classification counts, not processor
  instructions. There are 6,304 intentionally different unoffered payloads.
- Four separately compiled mutations fail natively with exit 1 and an actual
  payload mismatch: always live, always retained, wrong query width and lost
  AGI width priority. They are not compile failures or timeouts.
- The [all-bit contract proof](../verif/l1/prove_prime_query_payload.py) finds no
  accepted-address/strobe counterexample for arbitrary 32-bit addresses and
  widths under the offer-owner implications. All four mutations and removal
  of live/retained exclusion have counterexamples. Idle differences also have
  a counterexample, explicitly preventing an all-signals-equivalent claim.

The native miter extracts the actual payload, retained-offer and live-prime
source equations. Other AGI/reference eligibility terms are over-approximated
as independent predicates while retaining their selector implication. The
formal check abstracts the four live eligibility predicates. Neither test is
a full-core temporal proof, an independent ISA oracle or a cache-system gate.

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.
`query-payload-leaf-r1` closes native zero in **1.27 seconds**, owner
`ventium-prime-query-payload-leaf-oct12`, invocation
`d5de1f9d9ad74cab89a3518f750be4be`. Its SHA-256 is
`d9666207feaea6813c2d6b7d1602653ec81b88ef31fea79105762866da8fd60f`.
The proof in `query-payload-proof-r1` closes zero as
`ventium-prime-query-payload-proof-oct12`, invocation
`c1c1e07298e944dd88f324bb53db3b98`; receipt SHA-256
`c7e5e9e15ada055493bfb26f50c0bee0286336f298922e6e0f75eeb8fad70c8f`.
Both are CPU-12-only light jobs with no swap, separate from Vivado.

## Next qualification

The [private core builder](../verif/l1/build_prime_query_payload_core.py)
prepares `query-payload-core-r1`: 195 input files, the same 152 definitions,
one changed header and a unique private harness basename. It admits the native
positive/negative results and proof, rechecks their pins, and retains the
model-local generated-header dependency audit. **No compiler is launched yet.**

After the current synthesis/clock audit closes, run its guarded 32-job build,
canonical `make verify`, complete parent/candidate architectural/cycle replays,
memory/held-read/FP/store/fault and branch/priming regressions. Only a qualified
candidate should transfer into the PC model and a new measured synthesis.
The inherited canonical **7 PASS / 101 FAIL** is still an acceptance blocker;
unchanged A/B behavior does not waive it. Full original standard-suite and
physical FPGA Win95/UI and Quake timedemo acceptance remain required.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This candidate is
gameplay-unmeasured; no IPC or Fmax gain is claimed.
