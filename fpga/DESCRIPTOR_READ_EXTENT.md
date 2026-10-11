# LGDT/LIDT excess read — October 11, 2026

**Reproduced bug; private correction passes rebuilt-core and physical-byte checks.**
This is present in both the 28.10410 MHz BUS predecessor and the exact-fragment
candidate whose completed synthesis estimates 27.83654 MHz. Its timing inputs
were unchanged; the descriptor correction is a separate successor.
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

After the timing owner closed, the guarded-32 build completed in 19.96 seconds
(invocation `042e8427669749d39d399f543e7d5a81`). Model SHA-256:
`87035ad6ae27896b38274a908b5fcb92e37f6c5c1b1a66b8b3f122f491ed6ddf`.
The private harness dependency names this model's own generated header.

The [candidate checker](../verif/issue_uv/run_descriptor_extent_fixed.py)
passes all **24 cases**: twelve contained-operand fixtures and twelve genuine
crossing/fault fixtures. Both AXI latencies (0/7) and functional/cycle execution
are checked, for 96 simulations. There are 48 complete QEMU architectural
comparisons covering 20,364 records, plus cycle traces with 3,636 paired V
retirements. The previously spurious faults are gone; real crossing/fault
behavior remains correct. No trace trimming, masking or oracle change is used.
Closed invocation `158fd29e4376405bb8cc402272b55557`, 7.65 seconds;
`descriptor-fixed-r1/closed.json` SHA-256:
`ded79dfeeadaabf59b4ca0961a06c5104ea6542e8be37196b27d11ca0b090599`.
All 60 checker input pins were independently rehashed after closure.

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

The corrected model then passes the same observer **without**
`--expect-overread`. All four cases now accept four bytes at `0x2ff8` and two
at `0x2ffc`, exactly the six architectural bytes, with no missing, repeated or
extra byte. Each complete architectural trace remains byte-identical to its
passing directed trace. The observer first requires the completed 24-case
check and exact new model hash. It makes no writes to guest/model state.

Evidence: `descriptor-bus-fixed-r1/closed.json`, closed invocation
`13147e53c4524da2a324d5426a1a4303`, native exit 0, 17.56 seconds;
SHA-256 `7971382abbf898efb180e669c8fdfce051858c5b5a2bfee0ccccf2f45cf5a9f2`.
All 19 input pins were independently rehashed after closure. This is a real
Verilator AXI-bus observation, **not** a physical FPGA-board test.

## Remaining acceptance

The unchanged canonical gate **fails**, native exit 2, after 384.24 seconds
(`49d4536f869b49d0b416f99091516284`). All 20 complete cycle traces are identical
to its predecessor, and input pins remain unchanged; that is a regression
comparison, not a QEMU/differential pass. Inherited failures are not masked,
trimmed or relabelled. The measured synthesis candidate does not
include this additional fix. Neither candidate is FPGA-qualified; at least
40 MHz synthesized Fmax, green differential gates, the full standard suite and
physical Win95/Quake validation remain outstanding.

Verified gameplay baseline: **0.51030715 total U+V simulated retirement-event
IPC**, model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates these
candidates, neither of which has a gameplay measurement.
