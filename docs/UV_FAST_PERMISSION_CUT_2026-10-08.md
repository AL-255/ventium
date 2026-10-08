# UV-fast permission-path experiment — Oct 8, 2026

Source-closure correction: this experiment inherited an Oct 3 frozen L1 that
omitted committed response-owner repair `0f12b208`. Its results below belong to
that exact source, not the current checkout. The omission, exact-profile failing
reproduction and corrected combined candidate are documented in the
[L1 integration audit](UV_FAST_L1_OWNER_INTEGRATION_2026-10-08.md).

**Still not a Quake fix or FPGA acceptance.** The deployed `1c8f20ac` image,
repaired `5a56eec6` RTL and this candidate have no qualified gameplay IPC.
Historical `53f129e9`: **0.1659957781052303 primary/U-counter IPC**, not total
U+V, over 127 qualified intervals with gaps within cycles
8,721,490,845–19,169,282,165 (frames 37–898, 37.499869765 MHz). It predates
these changes. No board image, clock or runtime mode changed in this round.

## Implemented, privately tested, not enabled by default

The [address-only cut](UV_FAST_TRANSLATION_CUT_2026-10-08.md) left the large
parent DTLB's permission lookup combinational. The extension captures raw
`{US,RW,P}` with each exact child page/PFN/hit/dirty tuple. Current CPL/access
class, write intent and CR0.WP remain live; a successful read never grants a
later write. Reset, context flush and **every parent fill/replacement** dominate
capture and invalidate all children. Simulation assertions compare the child
against the real parent and reject requests/commits while capture is pending.

No U-only mode, pairing suppression, global slow-FSM fallback, unconditional
memory bubble, guest-specific special case or extra architectural TLB capacity.
The prototype adds only `VEN_FE_DTLB_PERM` to the previous eight-entry profile.
It explicitly rejects `VEN_PIPE_MEM_CHAIN`, whose differently owned lookahead
result has no raw-permission capture. That flag was already absent from the
exact 107-definition hardware profile; no enabled path was disabled to pass.

Source, integration patch, positive/negative leaf tests, two full-core fixtures
and their runner: [`verif/fe_pipe/permission`](../verif/fe_pipe/permission/README.md).
Full frozen source and evidence:
`/home/yukidama/external/tmp/ventium-fe8-perm-uv.ZKQfBa`.
Native SoC binary: `858519b1ab3e845ae856da1ad207add15d82fb8643734f3ba906fc4a1a25d93b`.
Build: frozen repaired107 plus FE_PIPE/MULTI/PERM, 32 bounded compile jobs,
assertions and all six structural hard-error classes. Unique harness object
basenames/header dependencies prevent cross-model object reuse. The user-mode
model removes only `VEN_KV260_SOC`; no fast-mode switches are removed.
User binary: `e451c06072bafeb5136a87d212eb0a6b4adbcdb59a031e14dfdf3e9957a931ad`.

## Closed functional checks, with oracle limitations kept explicit

- **40 full candidate-vs-QEMU comparisons pass** at AXI latencies 0/7:
  the original eight paging/fault fixtures (16), eleven additional ordinary
  system/permission fixtures (22), and the corrected FS stack fixture (2).
  All use `cycle_mode=1`, actual U/V execution and fast memory paths. No full
  trace masks or comparator relaxation were introduced.
- **48/48** U/V intermediate-retirement checks and **32/32** shift/Jcc cases
  pass. CPL3/dirty-task matrix **12/12** passes, retaining all 640 CMP/JNE pairs.
  The four measured hot loops add **zero clocks** versus the no-cut baseline.
  This is not gameplay IPC or a whole-program zero-overhead claim.
- The new read-only warm-up has **8 actual same-clock load/ADD pairs** in each
  cycle trace, followed by the expected protected-write fault, mapping repair
  and retry. The stack fixture has 70 paired V retirements, three fast reads
  and one fast write; its complete architectural trace matches QEMU.
- Leaf: **520,844** checks, including permission updates, ownership, replacement
  and capture/invalidation collisions. Real-parent test: **60,166** checks,
  including **273,216** live access-policy combinations. Removing fill
  invalidation deliberately fails on the first stale cached-negative owner.
  The repository replay closed in `ventium-fe-permission-leaf.QQhIER`.
- Repository full-core replay: `ventium-fe-permission-core.0jibhm9f`, four full
  QEMU comparisons plus four cycle/path checks, all green and input-pinned.
  The first runner attempt (`u8yi88_a`) wrongly passed a cycle-only trace to a
  functional-header grader. It is retained as a failed harness attempt, not
  counted as a DUT failure or pass.

The broader initial matrix was **red**; its logs/results were not overwritten:

1. `pfaststack` originally accessed FS after outer IRET invalidated the CPL0
   selector. The same #GP stop reproduced on the no-cut control. Its own source
   documents dependence on a non-enforcing profile. The private fixture now
   reloads FS in the handler (the enforcement companion already did this),
   preserving the faulting PUSH/POP instructions and all frame/atomicity checks.
   All six no-cut/address-cut/permission-cut × latency full QEMU diffs pass.
2. `ptswflt` explicitly declares a **witness oracle**, not a whole-trace QEMU
   differential: outgoing task-save/probe ordering differs. The observed first
   CR2 difference, `0x7000` versus `0x7020`, is exactly the manifest's P1 case,
   also reproduced on the no-cut control. The existing seven final-GPR checks
   and eleven exact vector/error-count checks pass for both cut candidates and
   latencies. This does **not** close the documented task-phase oracle gap.
3. The added expand-down-stack companion also uses its existing independent
   architectural witness: QEMU does not provide the required segment-limit
   oracle. Six runs pass the final-register checks and exact 3×#PF/2×#SS counts;
   their expected full-QEMU divergence is not relabeled differential success.
4. `pxwrapm` deliberately triple-faults and requires a partial-memory witness
   flow. Generic `-no-reboot` preparation timed out. It remains **unverified in
   this round**, not a pass. Do not run it through an ordinary exit-133 grader.

Required UV-fast `make verify` still **FAILS**: 7 functional passes / 101
length-only divergences (terminal user-exit/cap boundary), plus the existing
`mb_dmiss` timing band (4,154 versus 20,524 clocks). This is the same unresolved
gate behavior described in the [retirement audit](UV_FAST_RETIRE_STATE_2026-10-08.md).
No terminal records were discarded and no passing slow-mode run substitutes
for it. The complete standard suite has not qualified this candidate.

## Physical result: local improvement, not CPU sign-off

Evidence: `ventium-fe8-permission-physical.bS36Hy`, one exclusive Vivado 2025.2
family, `xczu15eg-ffvb1156-2-i`, three routed leaves, 25 ns clock constraint.
Native exit 0, input pins unchanged, peak sampled cgroup memory 3,750,035,456
bytes (3.49 GiB), no resource stop; the scope is closed. No full implementation
or bitstream was launched. Probe replay files are under `permission/physical/`;
only the copied probe's introductory comment was clarified after the run.

Identical registered stimulus/results retain the actual large parent and its
independent V lookup. This run adds a live user/write/WP-to-fault output, so its
placement is not directly comparable to the preceding leaf run's placement.

| Local routed quantity | No cut | Address-only 8 | Address + permissions 8 |
|---|---:|---:|---:|
| U query → physical address, ns | 4.935 | 4.289 | 4.185 |
| U query → raw permissions, ns | 4.607 | 5.620 | 3.770 |
| U query → permission fault, ns | 4.543 | 5.910 | 3.892 |
| V query → physical address, ns | 4.459 | 6.268 | 4.775 |
| Total LUTs | 2,867 | 2,851 | 2,878 |
| Total FFs | 3,415 | 3,761 | 3,790 |
| Local worst-setup equivalent MHz, **not CPU Fmax** | 125.5 | 132.7 | 128.6 |

The permission-fault query path improves **34.1% versus address-only**, but only
**14.3% versus the uncut control**. The child itself grows from 199 LUT/347 FF to
214 LUT/371 FF. The worst local path still belongs to the parent fill machinery;
the V path is still slower than the uncut control. Thus neither the 34.1% figure
nor the leaf clock equivalent proves a 40 MHz whole-CPU repair. All leaves have
zero route errors; external port/clock timing and whole-core congestion are not
represented by this out-of-context probe.

## Remaining acceptance work

Keep UV + fast pipe mandatory. Check the complete integrated critical paths,
including V translation, forwarded flags and next-PC selection, before spending
another full implementation run. Resolve the generic verification gate's trace
boundary contract without inventing/dropping architectural states, and retain
all paging/exception checks. Both CoreMark seeds, Win95 desktop, and the original
cold 40 MHz FPGA Quake timedemo with a complete raw-color movie remain required.
The goal is still open; these microbenchmarks are not a substitute.

Disk hygiene: removed six closed-build GCC precompiled-header caches, reclaiming
551,872,479 bytes (526.3 MiB). They can be rebuilt; all native binaries, build
identities, object/archive files, source trees and evidence remain. Binary hashes
were checked unchanged afterward. No browser processes were touched.
