# Current-response payload isolation — October 10

**Default-off private candidate, not production or FPGA acceptance.**
`VEN_L1D_RESPONSE_PAYLOAD_SELECT` separates the current registered read's data
selection from a younger read's shared tag lookup. No cache port, RAM, register,
pipeline stage, ACK, permission check or coherence qualification is added or
removed. U/V and all existing system/relocated fast paths stay enabled.

## Why this path

The preceding hardware export (`03921cda`, manifest `9e7b6b78…`) synthesized to
194,062 LUTs. Its independently inspected **unplaced** timing estimate is
**20.962 MHz**, not 40 MHz sign-off. The worst 165-level path goes from EIP /
successor decode through `mc_prime_offer`, the shared L1 tag RAM,
`shadow_reuse`, current load data, U flags, V branch selection and younger
read commitment, finally reaching `pipe_mem_v_hit_q`.

`shadow_reuse` is necessary for **acceptance**, but unnecessarily serializes
that tag/next-request decision ahead of the saved payload mux. The candidate
keeps that acceptance logic and selects bytes using saved physical ownership.
This is a structural timing experiment; **no frequency or IPC improvement has
yet been measured for it**. The previous export's timing is not its result.

## Correctness obligation

The exact `rd_match` owner chooses primary bytes. Otherwise, after the
unchanged bypass/critical-fill/code-word priority, a consumed read must be
primary or shadow reuse. Both reuse paths share the same current permission,
tag, state, cancellation and extent qualification. Therefore an eligible
saved shadow address can select payload without recomputing that qualification.
The separately owned hit-stream override is unchanged.

Same-line captures can create duplicate primary/shadow owners. Choosing primary
on `rd_match` additionally requires their **owned dword** to agree; a borrowed
V bank means the *entire* saved lines need not agree. A dedicated simulation
assertion checks this dword invariant. The parent's original full read-mux
assertion remains active on every consumed read. No state is forced by the TB.

`response_payload.smt2` checks the inner combinational selection lemma, assuming
that duplicate-owner invariant. Results are `unsat, sat, sat`: equivalence,
then required counterexamples without duplicate consistency and without physical
shadow identity. **This is not a formal proof of the sequential cache FSM.**

## Closed evidence

External scratch prefix: `/home/yukidama/external/tmp/`.

- `ventium-response-payload-r3.n76qodyi`: original, candidate-disabled and
  candidate-enabled leaves close native 0 with byte-identical complete
  per-clock interface observations, SHA
  `524a4844dd13c37b6c0abb4101e3386b4bfd5c7da6d7d5a10a2442c984b94e0c`.
  Logs are retained losslessly as `*/cycles.txt.gz`.
- Original memory-chain corpus: 150 accepted lookaheads; coherent-window
  corpus: 68,262 checks / 1,137 stores; store-warming corpus: 15,913 checks /
  535 stores. New witnesses: 29 duplicate owners, 276 active lookaheads and
  eight real partial U/V bank captures. The deliberately broken never-shadow
  mux fails the independent data check with native exit 1, as required.
- `ventium-response-payload-core.pndCkpV5`: directed-core model
  `3c3ab2151327a5a65803f6c5429cd24a9ee29c7300d16b1478547c68f0da8d99`,
  derived from numeric-SRT-fixed `b1cb5dc8`. Exactly one RTL file and one
  define change. Build native 0 in 17.515 seconds, strict structural classes
  enabled, private harness compiled against its own generated header.
- `verification-r2/`: 384 FP/system cases and 256 integer/system cases,
  covering both relocations and all 32 instruction offsets from cold reset, with AXI
  latency 0 and 7. **2,560 complete QEMU architectural comparisons** pass;
  **1,280 whole cycle-record pairs** match exactly. Actual V retirement and
  normal native exits are required. No masks, goldens or fixtures changed.
  The integer suite explicitly strengthens the reused driver to compare every
  cycle record; it requires zero cycle change, not a performance gain.

The unchanged canonical `make verify` closes **native 2 / FAIL**: 7/108
functional passes and 12/19 scored cycle-band failures, matching the parent's
counts. Independent `verification-r2/generic-audit.json` rechecks 4,547 pins
and confirms all 20 complete cycle-record lists equal the parent's. Neither
microcase success nor unchanged parent failures are a generic pass.

The private full-PC backport in `ventium-response-payload-soc.ZMhPPhmY` builds
native 0 in 19.038 seconds: model
`c883878de2e262f4845fc05d68b7ccf81db7c423c8d8c49f72892eccd50f0ed7`.
Only the tested L1 selector and numeric SRT-floor backport differ from the
preceding full-PC source tree. It retains the 98 inherited platform structural
warnings; this is not clean whole-platform lint. Both short CoreMark
diagnostics are running. The candidate has no own qualified CoreMark score,
gameplay, standard-suite closure, hardware synthesis, route or deployment.

### Current-code-owner corner

`critical-owners-r3/` additionally checks actual full-profile critical-fill
overlap against independent backing data, original and candidate: retargeted
resident data, ordinary held miss, and instruction-buffer reuse all pass.
[`prepare_response_owner_tb.py`](prepare_response_owner_tb.py) reproduces the
**exact compiled fixture** from the original owner test. The code-buffer case
samples its earlier real ACK, withdraws that consumed request, and checks a
fresh transaction after the unrelated critical response arrives. A deliberately
wrong code-data selector fails that second transaction. Eight positive native
runs and one required native-1 negative close; positive logs must contain no
fatal/error diagnostics. No processor RTL changed for these tests.

The original test's code case failed in **both** models because it required a
now-redundant registered capture. The first adaptation also fell through after
SV `$finish` and printed a later fatal despite native exit 0. An independent
log audit caught it; those attempts remain failed. The corrected named process
explicitly exits after `$finish`, and clean-log checks remain mandatory.

## Retained failures and resources

The first leaf launcher rejected non-define compiler options before building.
The second stopped in the new **control** witness: it incorrectly expected
shadow validity to survive a rejected next-read miss. The corrected fixture
tests duplicate ownership before that conservative invalidation and tests
miss rejection separately. Neither attempt is reported as an RTL pass.

The first 32-worker native matrix hit the fixed 128-task limit (`EAGAIN`), not
OOM or an RTL assertion. All cases were rerun with eight native workers inside
the same envelope. Model compilation still uses 32 compiler jobs. The failed
attempt remains intact; it is not silently replaced or counted as passing.

Only 48 **closed generated compiler intermediates** in the successful leaf
root were archived and removed, recovering 587,086,979 bytes. Sources, native
executables, traces and reports remain. The verified archive is
`generated-objects.tar.zst`, SHA
`d544dd24d8f030bfaff402ef4238374f8ccc4a4b83e8c92146bebd57f9bce856`.
Restore it in that exact root before incremental rebuilding:
`tar --zstd -xf generated-objects.tar.zst -C .`.

## Reproduce

Apply `prepare_response_payload.transform()` only to the pinned parent L1
SHA `acb5dca4d2ef4489d3c95b8c051624da581c2e77e2f7bc9a662b2a11d00deb8c`.
`run_response_payload.py --parent <frozen-core-root> --out <fresh-external-dir>`
runs the leaf corpus through `tools/build_scope.sh` with its reviewed
`ipc_parallel32` profile and `TMPDIR` equal to the fresh directory.

`run_response_payload_core.py --suite fp|integer --control <parent-bin>
--candidate <candidate-bin> --out <fresh-external-dir> --workers 8` reuses the
strict cold-system corpora, archives its exact adapted driver, and preserves
the original comparators and closure requirements. For this runner, `TMPDIR`
must be `/home/yukidama/external/tmp`; launch within the bounded build scope.
Recipe/adapter/owner-fixture host tests: `python3 -B -m unittest discover
-s verif/l1 -p 'test_response*.py'` — 11 pass. They are not RTL or benchmark
acceptance.
