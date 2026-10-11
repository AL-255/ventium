# Raw-prime address preparation — 2026-10-11 UTC

**Proposed private candidate. Native RTL test queued; no full-core, gameplay,
frequency or FPGA result. Not part of the running write-direction synthesis.**

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
actual descriptor type. Its prepared 65,536-case stimulus covers the four
sources, code/line boundaries, denied byte ownership, segment limits, address
arithmetic, AGI/reference priority and two compiled defects. Cache-return
ownership is mocked, so this will remain a leaf result even if it passes.

Evidence root: `/home/yukidama/external/tmp/ventium-mc-address.24Et4ycG`.
The native leaf queue is live, unit `ventium-mc-address-leaf-queue-oct11.service`,
invocation `b6e531761abc4bfb90136c8078e8b6d5`. It waits for the exact existing
write-direction timing-audit queue to close, then uses the shared build guard.
It never starts a competing synthesis or retries a failed native test.

Before adoption: pass the native leaf and whole-core fault/permission/branch
checks, preserve full-PC benchmark cycles, resolve canonical-gate failures,
and measure matched synthesis. The >=40 MHz target remains open.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating this unmeasured experiment.
