# Raw-prime address preparation — 2026-10-11 UTC

**Private candidate. Native RTL leaf, whole-core build, five cold directed
matrices and focused FP-fault checks pass. Canonical verification remains
FAIL. No gameplay, frequency or FPGA result for this change.**

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

The [whole-core builder](../verif/l1/build_mc_address_core.py)
requires successful native positive/negative leaf runs and the source proof,
rechecks all input hashes, and changes only `core_mem_chain.svh`. It retains
the parent's complete feature profile and builds a separately named C++
harness against its own generated model headers. Its parent remains the independently measured
write-direction core `1bfb1bb2`, not an unmeasured combination of SRT changes.

The first core queue exits before launching anything: its exclusive-create
receipt encounters the prior leaf queue's `queue-started.json`. The existing
receipt is preserved. The corrected queue uses a separate `core-queue-r2/`
directory and unit `ventium-mc-address-core-queue-r2-oct11.service`, invocation
`1572e89b87f84731abebb21ba9d08c08`. It waits for the exact SRT unit queues, then
losslessly archives only their closed generated compiler products before
launching the guarded core build. Source, headers, binaries, logs and pins are
retained. No other Vivado run, test-profile weakening or retry is introduced.

The core build now closes successfully in **12.52 seconds**, unit
`ventium-mc-address-core-oct11.service`, invocation
`578d7ea095204605a2860bda4ec0e524`, native exit 0. The single-header delta and
all input pins are checked; model SHA:
`911fe92597bea7eb194cc9b3b3194206324c8ed0ee3ae95ab4fdcdaef261e3f0`.
This is a build result, not a functional pass.

The later balanced-SRT timing result reaches 24.56339 MHz and exposes the
shared memory path as the new worst cone: `EIP -> dc_lru[8]/D`, -15.711 ns,
139 levels; V capture is -15.392 ns. That confirms the need to address this
chain. The separately leaf-verified [parallel tag lookup](PARALLEL_TAG_LOOKUP.md)
is another candidate for it, not part of this model.

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

Both matrices run in order after the exact successful build by
`ventium-mc-address-checks-queue-oct11.service`, invocation
`55d03159af5d42acac4f4a41cae3c710`. Both now close successfully. The full
**640-fixture branch matrix** uses `ventium-mc-address-branch-oct11.service`,
invocation `7823c41b6ad143c89194f212e56f4dd6`; 90.20 seconds, 2,560 model/latency
measurements. The **24-fixture held matrix** follows under invocation
`d766f05192e5485e83ef6a1128246b12`; all 48 latency cases pass for both models.
Each has a bounded native service, explicit CPU affinity, separate logs and
receipt, and a 4 GiB disk-reserve stop. Complete architectural states match
QEMU, complete architectural/cycle records match the control, actual paired
execution is witnessed, and the hint-owner checks pass. No prefix truncation
or cycle-band adjustment is used.

Branch receipt SHA:
`4b110ee10d7d973178915daa1d2fdf04ee64f7340b6b86f7d86fcfb177d61884`.
Held receipt SHA:
`31c0e43ce23ed9026f57104d9e5a3a33c7490a53288b45b028a5829ae4d51907`.

The existing paged/relocated memory, FP and AGI matrices also close with native
exit 0, stable inputs, full QEMU comparisons and identical complete A/B state
and cycle records:

| Matrix | Fixtures | Model/latency measurements | Time | Native invocation |
| --- | ---: | ---: | ---: | --- |
| Memory | 72 | 288 | 11.50 s | `b19c53905dd44f0a91c00c4e0a4d6773` |
| FP | 72 | 288 | 6.96 s | `f7ffdccd77874f4f9d5a9793f60f5eb7` |
| AGI | 12 | 48 | 1.38 s | `7dba970104494047b0dc1c04dc79376d` |

That is **820 cold fixtures** across the five directed matrices. The unchanged
canonical gate closes in **203.79 seconds** under
`ventium-mc-address-verify-oct11.service`, invocation
`aa45bb1412bd4852bc13a2b6a874c1c0`, with native gate exit 2 (**FAIL**): 7/108
functional passes; terminal-length and x87 C1 discrepancies remain. All 20
complete cycle-record streams still match the parent. No masks, goldens,
terminal-record truncation or cycle bands are changed.

The first audit queue (`9dc68fec8c0643e4b6e456b83ae1ed2b`) fails before reading
the matrices: its draft compares the guarded builder's scope invocation with
the distinct outer controller invocation. That script and receipt are retained.
The [corrected independent auditor](../verif/l1/audit_mc_address_r2.py) verifies
the controller, the manager's native scope start/close events and exact builder
command/closure record separately. This short-lived builder's stdout record
lacks runtime cgroup fields, so those fields are not invented. The intermediate
R2 draft is also retained locally as `audit-mc-address-r2-initial.py`.

The corrected audit reopens **438,312 candidate architectural records** and the
same number of cycle records, compares every record against its control and
every architectural stream against full QEMU output, and witnesses **117,436 V
retirements**. It checks all five retained service closures, 150 matching core
defines, the exact single-header change, unchanged observation-mode clocks,
native terminal statuses and all 20 canonical cycle streams. Its **65,253 pins**
are independently rehashed after the audit closes. Receipt
`core-audit-r2.json`, SHA:
`30863a7bf308deb31b6bbbca473e76833606e24b98df7aa7db6146f14fa043fd`.
Audit completion is explicitly separate from the still-failing canonical gate.

### Focused fault ordering

The unchanged [fault driver](../verif/l1/run_fp_read_ack_faults.py) completes
16 cases on both models (**32 model/case runs**, 47,170 complete UV-fast
architectural records across both models), unit
`ventium-mc-address-faults-oct11.service`, invocation
`44ee9efb08ec4e1ca666236a58f30aa7`, native exit 0. Cases cover FADD/FLD/FILD
source page faults and exact restart state, CR0.EM/TS #NM-before-#PF ordering,
pending FP-owner drain, and relocated DS/SS addressing. Every complete UV-fast
trace matches QEMU and the identical-image parent; the driver's functional-mode
checks are diagnostic controls, not substituted acceptance. All native inputs
and retained artifact hashes are independently rechecked.

Fault receipt SHA:
`f7e9f18cb98c828571b5f837d1b2f5696162e24d0b6b03aea4d03ccfc5b29e39`.
This is focused fault coverage, not the full permission/fault or standard suite.
Full-PC benchmarking, matched synthesis and physical acceptance remain open.

Before adoption: pass the native leaf and whole-core fault/permission/branch
checks, preserve full-PC benchmark cycles, resolve canonical-gate failures,
and measure matched synthesis. The >=40 MHz target remains open.

Gameplay baseline: **0.51030715 total U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating this unmeasured experiment.
