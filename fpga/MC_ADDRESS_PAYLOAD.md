# Raw-prime address preparation — 2026-10-11 UTC

**Proposed private candidate. Native RTL leaf passes; no full-core, gameplay,
frequency or FPGA result. Not part of the completed write-direction synthesis.**

## Structural issue and proposed change

The synthesized path runs from raw decode through descriptor code-byte/span
validation, effective-address arithmetic, DTLB lookup, segment/permission
qualification and L1 lookup before memory acceptance. `mc_descriptor` returns
an all-zero descriptor when validation rejects it. The address generator reads
that gated descriptor's fields, serializing address preparation after those
checks even though the lookup is speculative and read-only.

[The recipe](../verif/l1/prepare_mc_address_payload.py) introduces an address-only
payload selected from the same four existing producers: ordinary decoded V,
FP-self, held V, or the small branch-fallthrough MOV recognizer. It changes only
the segment/base/index/scale/displacement inputs to the speculative AGU.
The checked `mc_query_u` descriptor, its required nonzero length, permission
and extent checks, offers, commits, request selection and capture predicates
are unchanged. AGI and reference-dispatch address overrides keep their original
priority. Non-raw configurations use the original checked descriptor directly.
No new decode capability, cache port, memory request, stage or clock exception
is introduced. The branch byte-index bound remains in the payload preparation.

Producer guards establish the selection relationship:

- Held V requires an active memory owner; FP-self and paired-branch do not.
- FP-self requires U to be FP; paired-branch excludes FP U.
- Paired-branch requires pairing; the ordinary V descriptor excludes pairing.
- The old PC/byte/span checks still decide whether a descriptor can be offered.

Thus a rejected descriptor may produce a different inactive address, but a
checked nonzero descriptor must retain the same address fields. A new native
assertion checks that relationship. It does not waive any permission check.
The existing DTLB next port is combinational/read-only; its replacement and
translation state changes only on reset, flush or fill. In raw-prime mode,
FE translation ownership remains with ordinary instruction admission, not the
speculative lookup.

## Evidence and pending tests

Source header SHA:
`e8cddd9561a4b69c3be59c53b99216bf87851e8732ab5be7e9770f8a372d6129`.
The transformation rejects source drift/reapplication and is reversible.
Four [recipe tests](../verif/l1/test_mc_address_payload.py) pass, including
unchanged checked descriptor and request/commit/address-selection equations.

[The Z3 proof](../verif/l1/prove_mc_address_sources.py) uses a conservative
abstraction of the pinned producer guards, leaving the remaining PC/byte/span
checks unconstrained. Every selected checked source equals the payload source.
Wrong-default and missing-held mutants are falsifiable, and inactive address
differences are intentionally possible. This proves source selection only,
not a sequential processor or the mocked/native decoder implementation.

[The native test](../verif/l1/run_mc_address_payload.py) extracts the real
descriptor, source predicates and raw MOV function from pinned RTL, using the
actual descriptor type. Its 65,536-case stimulus covers the four
sources, code/line boundaries, denied byte ownership, segment limits, address
arithmetic, AGI/reference priority and two compiled defects. Cache-return
ownership is mocked, so this remains a leaf result, not a whole-core pass.

Evidence root: `/home/yukidama/external/tmp/ventium-mc-address.24Et4ycG`.
The native leaf queue closes with exit 0, unit
`ventium-mc-address-leaf-queue-oct11.service`, invocation
`b6e531761abc4bfb90136c8078e8b6d5`, after the exact write-direction timing queue
closes. It uses the shared build guard and does not start another synthesis.
The native leaf takes **3.27 seconds**: 65,536 samples, 35,956 live/override
checks and 20,909 inactive address differences. Valid ordinary/FP/held/branch
source counts are 7,175 / 8,298 / 8,319 / 3,563. Both compiled wrong-source
mutants fail with native exit 1; an independent complete pin check passes.
Receipt SHA:
`9a3d6b3b58302564270bded9c89fb1b805614479c3cad24ede15f3c035b584b0`.

The newly measured [write-direction netlist](L1_WRITE_KIND_PAYLOAD.md) reaches
24.33504 MHz and exposes a different worst endpoint, the SRT remainder setup.
That path is being addressed, but a subsequent review of the retained capture
report also finds `EIP -> pipe_mem_v_hit_q/D` at **-16.057 ns**, only 0.036 ns
behind SRT's -16.093 ns. It crosses the raw branch-prime/descriptor/address
chain before the L1 request and tag lookup. Optimizing SRT alone cannot remove
this independent constraint, so whole-core checks of this address-preparation
candidate are now queued as well. No full-core or timing pass is claimed yet.

The prepared [whole-core builder](../verif/l1/build_mc_address_core.py)
requires successful native positive/negative leaf runs and the source proof,
rechecks all input hashes, and changes only `core_mem_chain.svh`. It retains
the parent's complete feature profile and builds a separately named C++
harness against its own generated model headers. No full-core build has run
for this candidate yet. Its parent remains the independently measured
write-direction core `1bfb1bb2`, not an unmeasured combination of SRT changes.

The first core queue exits before launching anything: its exclusive-create
receipt encounters the prior leaf queue's `queue-started.json`. The existing
receipt is preserved. The corrected queue uses a separate `core-queue-r2/`
directory and unit `ventium-mc-address-core-queue-r2-oct11.service`, invocation
`1572e89b87f84731abebb21ba9d08c08`. It waits for the exact SRT unit queues, then
losslessly archives only their closed generated compiler products before
launching the guarded core build. Source, headers, binaries, logs and pins are
retained. No other Vivado run, test-profile weakening or retry is introduced.

Two additional cold-reset A/B drivers are prepared from the existing prime
fixtures, without editing those fixtures or their original runners:

- [Branch priming](../verif/l1/run_mc_address_branch.py): ten instruction
  shapes, all 32 instruction offsets, flat/relocated segments and AXI delays
  0/7. Both models keep branch priming enabled; complete architectural and
  cycle records, as well as actual branch-hint owners, must agree.
- [Held-read priming](../verif/l1/run_mc_address_held.py): six producer and
  exclusion shapes, flat/relocated segments, offsets 0/31 and AXI delays 0/7.
  Both models keep held priming enabled; complete traces and hint counts
  must agree, with explicit held-read and paired-load witnesses.

These are prepared tests, not passing results. They supplement, rather than
replace, the existing FP, AGI, memory and permission/fault checks.

Before adoption: pass the native leaf and whole-core fault/permission/branch
checks, preserve full-PC benchmark cycles, resolve canonical-gate failures,
and measure matched synthesis. The >=40 MHz target remains open.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating this unmeasured experiment.
