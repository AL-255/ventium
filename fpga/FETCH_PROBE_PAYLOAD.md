# Early fetch-probe payload — October 12

**Private RTL candidate; no measured Fmax, gameplay or FPGA acceptance yet.**
The immediate requirement remains **at least 40 MHz post-synthesis Fmax** in
UV + fast-pipe mode with full P5 caches. The measured
[load-ACK parent](LOAD_READ_ACK_TIMING.md) reaches **30.02192 MHz**.

## Measured reason and exact change

The parent's worst 119-level path runs through `fetch_overlength_probe` at
16.840 ns, the shared current-address/DTLB network, L1 response selection and
FP conversion into SRT input normalization. Qualifying an otherwise inactive
probe payload puts the long instruction/event predicate ahead of that network.

The [source recipe](../verif/fetchguard/prepare_probe_payload.py) changes only
two S_DECODE payload assignments in `rtl/core/core.sv`:

- Select instruction-side access kind directly. This state has no data beat.
- Present the next page base and one-byte extent before the late probe guard.

The decoder's first-overrun endpoint is always 16..31 bytes from `flin`. If
its page differs, it must name the next page, including 32-bit address wrap.
**The original first-field crossing test still decides whether a probe exists.**
In particular, a later unused immediate crossing cannot authorize a probe when
the first overrun field stays on-page. All debugger/event, #NM and privilege
precedence and `fe_translatable` qualification are unchanged. No bus request,
state, feature flag, register, added cycle or arithmetic engine is introduced.

Inactive address/type/extent values intentionally differ. Runtime assertions
require exact active probe payload, valid endpoint range, no S_DECODE bus/data
owner, and no translation/miss/permission side effect when no probe is offered.
This is not an all-internal-signals equivalence claim.

Parent core source SHA-256:
`552ad08f48da2833f7d299c37c9f73455f5cd08eafdbbc1fa129ccc10906c985`.
Candidate:
`70cc3e386aaa7c359b09021cd6c3e38803bfd6ab93533ede73611a74f9694837`.
The recipe rejects drift/reapplication; three host tests verify exact scope and
unchanged fetch/extent predicates. Production checkout RTL is not overwritten.

## Closed component and core checks

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

The [native extracted-payload test](../verif/fetchguard/run_probe_payload.py)
passes **278,528 checks**: every page offset and endpoint length 16..31 at four
page bases (including wrap), plus all 16,384 Boolean qualification combinations.
It observes 1,459 active probes, 379 wrapped probes, 16,365 suppressed crossings
and 277,069 intentionally different idle payloads. Those counts overlap and
are not processor instructions. Four independently compiled mutations fail
with an actual mismatch: wrong page, wrong extent, data classification and
saturating instead of wrapping the page address.

The Z3 page-arithmetic query has no counterexample over all 32-bit addresses
and endpoint lengths 16..31 when a crossing exists. Wrong-page and lost-wrap
queries have counterexamples. The endpoint range is tied to the decoder's
actual four assignments and their guards. This arithmetic proof is not a
whole-core temporal/translation proof or a synthesized timing result.

`probe-payload-leaf-r1` closes native zero in **2.50 seconds**, unit
`ventium-fetch-probe-payload-leaf-oct12`, invocation
`288c788ed58647989276175d922ce627`; stable pins, controller affinity CPU12.
Receipt SHA-256:
`b0cf3c64d69eb6d9dddd4d5ce2682502727d03681e08100bae3b1790e81a6f5f`.
The unchanged source-linked fetch-guard testbench also passes **1,596 checks**
with Icarus against the candidate predicates in `probe-fetchguard-r1`; native
log, source link, executable and hashes remain there. This is not a Verilator
structural-lint claim.

The [private core builder](../verif/fetchguard/build_probe_payload_core.py)
retains all 195 inputs, the same 152 definitions and all assertions; only
`core.sv` changes. It reuses the established guarded build/closure checks,
including the private host basename and model-local generated-header dependency.
Native compilation closes zero in **19.63 seconds**, unit
`ventium-fetch-probe-core-oct12`, invocation
`ef8e180876d1496196aca97303acbaa6`. Model SHA-256:
`9097e2ae0c56e26a66f7dabeb631820bdb196ebeda7da1c132a9ea10f7758265`.
The build uses 32 jobs in the existing 16 GiB/128-task scope, with no Vivado
family running. Its source/command pins remain unchanged.

The [whole-core boundary runner](../verif/fetchguard/run_probe_boundary_ab.py)
passes **all 22 original pfetchbound cases** at AXI latency 0 and 7. It retains
the original fixture validation, exact fault frames, unchanged IRET retries,
free-running QEMU exit, complete architectural comparison and complete A/B
cycle streams. **21,832 candidate records / 4,968 actual V retirements / 44
probe witnesses** pass; cycle counts are unchanged. No mask, instruction skip,
snapshot, exception substitution or narrowed oracle is used.

`probe-boundary-r1` closes native zero in **24.48 seconds**, unit
`ventium-fetch-probe-boundary-oct12`, invocation
`5977193e3dcd4871bfbf2e13de481c2b`. Its separate native service has 22 workers,
4 GiB/no swap and 2,048 tasks; sampled live model PIDs 2949598–2949619 have
actual CPU affinity 0–31. No compiler build overlaps this matrix.

## Broader regression status

The cold memory matrix passes **72 fixtures / 31,392 candidate records** in
28.12 seconds. The integer/store matrix passes **256 fixtures / 169,472
candidate records**, with 512 V retirements, in 64.62 seconds. Both use the
unchanged original QEMU oracle and full A/B cycle comparison at AXI latency
0/7. Evidence: `probe-memory-r1` and `probe-integer-r1`; invocations
`d95b844026d9489aa05dccb29171d9c6` and `621bc10c118942ff9348efbc4f6da0ba`.

The first 384-case FP matrix **FAILS**, not passes: three golden-generation
jobs cannot connect to QEMU's GDB stub at ports 47066/47080/47116 within the
existing 20-second limit. Those cases have no RTL comparison. QEMU's retained
stderr reports termination by the generator, not a demonstrated address-bind
error; the precise cause is not established. All test inputs remain pinned.
The [scheduling adapter](../verif/fetchguard/run_probe_core_corpus.py) assigns
distinct ports per case but those ports lie inside the host ephemeral range;
that fact alone does not prove it caused these failures. `probe-fp-r1` and its
failed owner `3a24df3a623c48c791f60b21e561e865` remain intact. A separate serial
six-fixture reproduction (`dcb47b9508be45f2aaf693d6b5b37a59`) also fails on
47066; the other five fixtures pass. A read-only socket check finds an existing
outbound IPv4 connection using local port 47066. A five-second controlled QEMU
startup on the same port exposes only an IPv6 `[::]:47066` listener, while the
collector connects to `127.0.0.1`. This explains the reproducible connection
failure; it does not prove the now-closed failures on the other two ports had
the same cause. The diagnostic exits by its explicit timeout (124), not guest
completion, and does not touch the unrelated outbound connection. Move future
case ports outside the host's 32768–60999 ephemeral range before a full rerun.

The unchanged canonical gate closes **FAIL**, native make exit 2 in **413.38
seconds**, under
`ventium-fetch-probe-verify-oct12`, invocation
`0231455e6780425e9fe9584c8d6bbaf8`. All 20 complete cycle streams equal the
parent, and input pins remain stable. The inherited functional failures remain
an acceptance blocker; successful A/B comparisons do not turn that gate green.
Further full-core regression, source-matched PC/hardware transfer, measured
synthesis and full original standard-suite plus physical Win95/UI and Quake
timedemo acceptance remain open. No synthesis, route or deployment is queued.

Gameplay baseline: **0.51030715 total U+V simulated retirement-event IPC**,
older model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. This candidate
is gameplay-unmeasured; the baseline is not board IPC or a full-timedemo mean.
