# Way-banked tags + fetch-fault page arithmetic

October 14, 2026 UTC. **Private combined core; not promoted or installed.**
Directed and private-QEMU checks pass, but the canonical gate remains
**7 functional PASS / 101 FAIL**. No whole-chip frequency or gameplay gain is
established. The existing FPGA still fails Doom startup; there is no Doom FPS.

## Exactly two source changes

The parent is `fp-compare-core-r1`, model
`5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8`.
`build_way_banked_core.py` transfers its complete 195-file closure, changing only:

- `rtl/mem/ven_l1d.sv`: [explicit way banks](WAY_BANKED_TAGS.md), preserving
  all cache capacity, ports, reset/validity, ownership and latency. The closed
  isolated full-L1 synthesis restores tag RAM and saves 40.84% of that module's
  LUTs; that is **not** a whole-chip utilization or Fmax result.
- `rtl/core/core.sv`: rebase the original proved fetch-fault page calculation
  onto current core SHA `6c020b3c171fb422756a7874fb48cd32a683953ff5b95d44b708be3a7fa08b1c`.
  A 13-bit offset-plus-length sum chooses the precomputed current/previous/next
  page; the page-crossing predicate uses that sum directly. Zero length,
  exact page ends, underflow and 32-bit wrapping retain the original values.
  Decoder length, permissions, exception priority, state and latency do not
  change. This targets the measured late fetch/translation dependency.

The new rebase recipe hashes and imports the original expressions; it does not
weaken or rewrite the historical parent's guard. Both recipes reverse exactly
and reject source drift/reapplication. Root RTL and old freezes are untouched.

The fresh leaf run repeats the unchanged three tests: both all-32-bit-address /
all-5-bit-length Z3 identities are UNSAT; three deliberate defects are SAT.
The actual SV replacement passes **1,048,576 comparisons**; wrong-boundary and
missing-underflow native mutations fail. Evidence is
`/home/yukidama/external/tmp/ventium-fetch-fault-page-leaf.wkkmde3g`,
`evidence.json` SHA `8ec83add5affdad3db5dcbb348a039da0ac3f40578c30d15aa3679eca215411a`.
Its original owner `ventium-fetch-page-current-oct14-r1.service`, invocation
`8096281e69e44fd7b68677cbf9cd5c74`, closed exit 0; all 11 native commands waited.

## Closed core checks

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.
The candidate is `way-banked-core-r1`, model
`139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7`.
All 152 definitions, assertions, UV/system/relocated fast paths and single-fill
policy are retained. The private host was compiled against its own generated
header; the guarded 32-job build closed in **20.61 s**, all input pins unchanged.

| Check | Result and scope |
| --- | --- |
| Original 22 fetch-boundary fixtures | AXI delays 0/7; 176 native RTL executions, 88 full QEMU architectural comparisons across parent/candidate; exact complete A/B architectural and cycle records |
| Fetch candidate witnesses | 21,832 records, 4,968 actual V retirements, 44 payload-probe observations; 28.49 s |
| Qualified private-QEMU corpus | 108 PASS / 80,800 records; 105 unmasked, three using pre-existing x87 manifest masks; 116.38 s |
| Identical-input parent/candidate replay | 216 native executions, all 108 complete traces equal including ESP, clocks and 30,132 V retirements; 168.89 s |
| Canonical `make verify` | **FAIL**, native make exit 2, 7 functional PASS / 101 FAIL; 20 candidate cycle traces equal parent; 394.49 s |

The fetch auditor regrades original image bytes/symbols, exact fault order and
frame/effect witnesses, complete QEMU state, actual native waits/exits, clean
process-group closure and log hashes; **17,882 pins** are rechecked. That run
records outer `taskset` affinity, not independently observed child affinity;
do not claim the latter. Raw supervisor `result=FAIL` is an ungraded default,
not the guest verdict; the separate full grading does not alter those receipts.

The regression auditor independently regrades all functional and same-input
traces, existing mask policy, canonical verdicts and terminal owner invocations;
**19,149 pins** are checked. Private-QEMU success and unchanged A/B records do
not override canonical failures. No golden, mask, cycle band or backend was
changed. Functional/replay children have observed CPU13–16 affinity; both runs
have zero OOM events. All three owners are terminal with MainPID 0; canonical
remains failed with wrapper exit 1. Three adapter tests also pass.

| Evidence | SHA-256 |
| --- | --- |
| `way-banked-core-r1/build-closed.json` | `87b599da14be893aa0aa3e5b86de4c55ed7e10a957f9fbfeb02ee6a45fdc4565` |
| `way-banked-fetch-r1/audit.json` | `70c739de0cc4834dbdbdf73325319655c02510c068ea675787dd7f9a409349c0` |
| `way-banked-same-input-r1/closed.json` | `d362c6720884a628c5f106c4fae551ef4a7eb0fed1135d981a9a895e14c4cb25` |
| `way-banked-regression-audit.json` | `bf17a9053431218ff69194286ab1a91ed3434196ec51e2d78ea9cd5e10e60c96` |

For headroom, nine **unpinned regenerable compiler products** (six PCH files,
three static build archives) from the closed cache-equivalence runs were
removed, freeing 506,239,171 bytes. Source/header/log/model/audit files remain.
Hashes, inodes, terminal owners and absence of open handles were checked before
deletion; current source pins remain unchanged. The plan/closure are
`way-tag-products-pruned-{plan,closed}.json`. These products require regeneration;
they were not recoverably archived.

## Still open

The [full-PC transfer and source-matched FPGA export](../../fpga/WAY_BANKED_EXPORT.md)
now pass CPU-hierarchy lint, 44 cold environment-store fixtures at latency 0/7
and both short CoreMark CRC controls, with unchanged benchmark clocks. The
single guarded full synthesis started at 02:12:34 UTC after disk admission was
met without lowering guards; it has no result yet.

Resolution of canonical failures, the complete standard suite, full synthesis
at **>=40 MHz**, routed timing and physical UV-fast Win95 keyboard/mouse and
Quake timedemo acceptance remain open. This candidate has no bitstream or
gameplay IPC measurement.

Latest verified gameplay baseline: **0.51027341 total U+V IPC**, older
FP-repair simulation `c7b95b78`, cycles **1,200,065,237–1,300,065,237**
([evidence](../../fpga/FP_REPAIR_EXPORT.md)). The different scene window is not
a measured gain from these changes, a full-timedemo average or a physical result.
