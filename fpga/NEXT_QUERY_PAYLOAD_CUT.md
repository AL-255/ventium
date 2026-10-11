# Next-read address payload experiment — 2026-10-11 UTC

**Leaf-tested proposal only. No whole-core, timing, gameplay or FPGA pass.**
It is not included in the currently running V-carry synthesis. The objective
remains at least 40 MHz synthesized Fmax with UV and fast pipeline retained.

The previous synthesized critical path traverses raw decode, address/permission
qualification, next-read selection and L1 lookup before returning through
memory acceptance. `core_mem_chain.svh` selects the live `mem_next_addr` using
the final permission-qualified `mc_prime_offer`, even when no retained
descriptor exists. This serializes live-address preparation after eligibility.

Let `A = agi_prime_select || ref_prime_select || mc_prime_offer`, `V` be the
registered retained-owner valid bit, `Q` the live physical query and `R` the
retained physical address:

```
old address = A ? Q : R
new address = (V && !A) ? R : Q
```

They differ only when `V=0` and `A=0`. In that case no next-read request can
exist: AGI and reference offers imply their selects; the ordinary chain offer
implies `V`; the prime offer is part of `A`. The driver checks those implications
against the actual pinned assignment expressions, rejecting top-level OR or
ternary guard bypass. No permission, request, commit, width/strobe, cached-data
owner, memory ordering or clock-edge predicate is changed.

Downstream review: `ventium_l1_axi` uses the address for next-region/SMM
qualification and passes it to `ven_l1d`; actual next lookup requires next
request. Both `mc_lookup_old` and `mc_lookup_prime` are request-qualified.
This is a conditional payload argument, not permission to discard ownership
or remove eligibility from cache effects.

## Evidence and limits

Parent header SHA: `e8cddd9561a4b69c3be59c53b99216bf87851e8732ab5be7e9770f8a372d6129`.
Proposed header SHA: `e142b3257cbb32b9e0592fa714919c74a7199a8423fea43391f4c7b3a21dcb61`.
Parent whole-core model: `8c8898416ab8af4e6e53f9c4d94e3d9c2bbd1020edce3abdb300272dfc8104d6`.
Evidence: `/home/yukidama/external/tmp/ventium-next-query-payload.sd8MaX6W`.

- Four recipe/guard-parser tests pass; all unrelated header text is unchanged.
- Actual source-extracted old/new address and request equations pass Icarus
  simulation of **4,096 samples**, all 128 Boolean control combinations with
  32 complementary walking-bit address patterns. **3,232 active requests**
  have identical addresses. The **256 inactive differences** are retained.
  Other permission/extent conditions are independent symbolic Boolean inputs,
  not an assertion that only successful accesses can happen.
- Both deliberate defects (always using the live address, or always using
  the retained address) fail the offered-address check with native exit 1.
- Leaf receipt SHA: `070aa4c8bba65ce924f9a12ba9f5f96f43a3c3f8f9a5eaf98481f1ab7d885ec5`.

The initial core-build helper selected `core.sv` instead of this header and
was rejected by the source-hash check before compilation. Its archived source
is `core/failed_build_driver.py`. Revision 2 fixes the target and checks it
before copying. Its build was cancelled while waiting on the shared heavy-build
lock held by the existing Vivado family; **no native compilation started**.
The cancellation receipt and original logs remain. Do not bypass the guard.

Next: after the current synthesis and timing audit close, build a fresh core
directory with `build_next_query_payload_core_r2.py`, run complete memory/FP/AGI
QEMU comparisons and canonical verification, then check original cold CoreMark
seeds before another synthesis. A native timing report must demonstrate any
gain; this proposal does not inherit the parent's tests or frequency.

Verified gameplay baseline: **0.51030715 U+V retirement-event IPC**, model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates both timing
experiments, which are gameplay-unmeasured.
