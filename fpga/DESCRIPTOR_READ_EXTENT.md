# LGDT/LIDT excess read — October 11, 2026

**Reproduced bug; private correction prepared, rebuilt-core verification pending.**
This is present in both the 28.10410 MHz BUS predecessor and the exact-fragment
candidate currently undergoing synthesis. Running timing inputs are unchanged.
It is not yet established as the cause of a Windows 95 or Quake failure.

## Actual guest reproduction

[`run_descriptor_read_extent.py`](../verif/issue_uv/run_descriptor_read_extent.py)
derives twelve BIOS fixtures from `pxfrag`: LGDT/LIDT, operand starts `0x2ff8`,
`0x2ff9`, `0x2ffa`, and CR0.CD=0/1. All six operand bytes lie in the present
page. The next page (`0x3000`) is not present. The original handler counts a
page fault, poisons the descriptor tail, maps that page, and retries. SGDT/SIDT
then exposes the installed value. No host writes to DUT state, snapshots,
guest single-step, RTL rebuild or modified memory model are used.

Fresh pinned QEMU Pentium runs complete with zero faults and the intended
descriptor for all twelve fixtures. Existing UV-fast models run at AXI latency
0 and 7 with complete architectural comparisons and real `isa-debug-exit`.

| Operand start | QEMU | Both RTL models, both cache modes/latencies |
| --- | --- | --- |
| `0x2ff8` | No fault, correct descriptor | Full architectural match (16 measurements) |
| `0x2ff9` | No fault, correct descriptor | Spurious #PF, CR2=`0x3000` |
| `0x2ffa` | No fault, correct descriptor | Spurious #PF, CR2=`0x3000` |

The last two rows account for **32 failing differentials**. The handler's
intentional poison is reflected in the restarted descriptor load; this is not
a claim of spontaneous data corruption. All native runs exit normally. The
diagnostic driver exits zero because it successfully reproduces the expected
bug, **not because the differential or processor passes**.

Evidence root:
`/home/yukidama/external/tmp/ventium-fragment-read-payload.etYN56fg/descriptor-extent-r1/`.
Closed service invocation `c8f150cb01de43eab24df6e9c4d85aef`, 7.05 seconds,
stable input pins. Receipt SHA-256:
`99c156ec5eda4f8506b7b066dfe29512563f5560ded58b8abe5ff1700f297429`.

## Cause and correction

`S_LGDT` is shared by LGDT/LIDT. Its first beat consumes four bytes and its
second consumes two. However, `cur_size` stays at the default four for both;
the bus driver leaves read strobes zero, meaning a legacy four-byte read.
The second beat can therefore translate and read past the architectural operand.
Materializing a fragment mask cannot repair an incorrect producer width.

[`prepare_descriptor_read_extent.py`](../verif/issue_uv/prepare_descriptor_read_extent.py)
makes two state-arm changes on the pinned exact-fragment predecessor:

- `cur_size = seg_step ? 2 : 4`, for translation/fragment/segment extent.
- `bd_wstrb = seg_step ? 0011 : 1111`, for actual physical read bytes even
  when no page fragment is necessary.

No new state, cycle, clock exception, fallback or permission change is added.
Descriptor commit and 16-bit base masking are unchanged. Whole-operand
exception-priority behavior is not separately changed or qualified. Three host
tests check exact source scope, drift/reapplication rejection and fixture
boundaries; these do not substitute for rebuilt-core tests.

[`build_descriptor_extent_core.py`](../verif/issue_uv/build_descriptor_extent_core.py)
has prepared `descriptor-core-r1/`, retaining all 195 files except those two
arms, the same 150 UV-fast definitions, and a private C++ harness. New core
SHA-256: `8ef0079de0a0f9eba1f48533f590e0908b96fbaea9ff64030183a5e3e0416ec0`;
bus header: `2e592948d1ae2a99babc970a5c573a1de42fbf011f62e8b34d473c4b216ae08c`.

The owned continuation (`ventium-descriptor-queue-oct11.service`, invocation
`42e8726e7f094dbdbef9cf9e00445589`) waits for the exact timing queue's completed
owner before the guarded-32 build. The
[candidate checker](../verif/issue_uv/run_descriptor_extent_fixed.py) then
requires complete QEMU matches for all twelve contained-operand fixtures and
twelve genuine crossing/fault fixtures at both latencies, with actual V
retirements. The unchanged canonical gate follows; its current failures are
not masked, trimmed or relabelled. No competing heavy build runs now.

## Physical-bus witness, including an architectural false negative

[`observe_descriptor_read_bus.py`](../verif/issue_uv/observe_descriptor_read_bus.py)
observes the existing exact-fragment model at native rising-edge evaluation
boundaries through read-only host GDB. It does not issue guest debug STEP,
inject state, modify RTL, rebuild the model or change the memory model. The
offsets come from that binary's generated header. The normal guest remains
in UV-fast mode.

All four observations (LGDT/LIDT, AXI latency 0/7, CR0.CD=1) confirm that the
**architecturally passing** operand at `0x2ff8` physically reads eight bytes:
four at `0x2ff8`, followed by four at `0x2ffc`. The last two bytes,
`0x2ffe–0x2fff`, are outside its six-byte operand. The full observed architectural
traces remain byte-identical to their earlier passing traces. This separately
proves why repairing only the translation extent, or relying only on the
register-state differential, is insufficient. It is not cache-line prefetch:
these are accepted, single-beat bypass reads with cache disabled.

The independent byte-count oracle rejects those observations. Its three host
tests additionally reject oversized, missing, duplicate, wrong-address,
non-handshaken and wrong-edge transfers. Diagnostic completion is explicitly
**not** a byte-exact gate pass. The corrected model must demonstrate exactly
four plus two bytes and unchanged architectural traces.

Evidence: `descriptor-bus-parent-r1/` under the evidence root's parent above;
closed invocation `577aeb7a588f44a9922d67960e26b574`, native exit 0,
17.78 seconds, peak memory 281,714,688 bytes. All pinned inputs were independently
rehashed after closure. Receipt SHA-256:
`09dde2305d7e07c6e3f9276ddbff74de14f3068e585fc2aff68a43be5fc0c96a`.

After `descriptor-core-r1` and `descriptor-fixed-r1` close successfully, run
the same observer without `--expect-overread`, supplying those directories as
`--build` and `--matrix`, retaining `descriptor-extent-r1` as `--corpus`, and
using a new external scratch output directory. It requires the completed
24-case check and the exact new model hash before observation. This extra
check is not part of the already-pinned running queue; neither that queue nor
the running synthesis inputs were modified.

## Remaining acceptance

Build and behavioral checks are pending. The running synthesis candidate does
not include this additional fix. Neither candidate is FPGA-qualified; at least
40 MHz synthesized Fmax, green differential gates, the full standard suite and
physical Win95/Quake validation remain outstanding.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates these
candidates, neither of which has a gameplay measurement.
