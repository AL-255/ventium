# AXI-to-Avalon read-command forwarding

`VEN_AXI2AVL_READ_THROUGH` is default-off. It lets the existing registered AXI
AR request present its Avalon command on the address-capture edge. A ready
endpoint saves one clock; a blocked endpoint takes the original captured-command
path. ARREADY is unchanged and does not depend on Avalon waitrequest.

This adds no queue, SRAM port, combinational memory-data return or speculative
read. Byte lanes, IDs, WRAP8 high/low fragments, older write-response drain and
registered responses retain their existing ownership. The endpoint must return
data no earlier than the following clock, and the existing P54 AXI master must
keep RREADY asserted through its burst. Assertions check these contracts.
The historical outer-DDR double-read policy is **not** changed.

## Reproduction and evidence

Run from the repository root with a frozen, pre-change full-PC source tree:

```sh
TMPDIR=/home/yukidama/external/tmp tools/build_scope.sh -- \
  python3 -B verif/l1/run-axi-read-through.py \
  --source /absolute/path/to/frozen/source \
  --out /home/yukidama/external/tmp/fresh-read-through-result
```

The runner builds four variants concurrently, eight compiler jobs each. It
compares the old bridge, candidate disabled and candidate enabled in plain,
B-pipeline and B-pipeline/write-through configurations, plus the actual platform
L2 with registered read-first XPM fidelity and streaming. All six structural
lint classes are errors. Evidence is retained at
`external/tmp/ventium-axi-read-through.jmT8jWbi/r2/closed.json`:

- **21 builds × 3 randomized-initialization seeds = 63 native passes**;
  source pins remain unchanged.
- **7,803 focused transaction checks** cover narrow byte/word/dword lanes,
  INCR8 and all WRAP8 offsets, 0–5 command stalls, three response cadences,
  poisoned post-handshake AR/WSTRB, held older B responses and reset.
- Each focused run checks 1,430 returned beats. Its 49 ready commands each
  save exactly one clock: aggregate command delay **1,009→960**. Blocked
  commands are unchanged. Disabled results exactly match the old bridge.
- The existing WRAP/write-lane/fused-write/reset corpus passes. For 32 real-L2
  reads, aggregate first-response latency is **644→613** clocks and aggregate
  completion latency **1,128→1,097**. These are leaf latencies, not CPU gains.

The retained `r1/closed.json` failed all three real-L2 variants, including the
old control: the legacy fixture started with reset already asserted, so
randomized reset synchronizers could miss the L2's edge-triggered initialization.
R2 supplies the same low/high/low external-reset sequence to all variants and
blocks new DDR commands before platform reset release. Accepted DDR bursts still
survive later resets; the original in-flight/reset checks remain. No DUT state
is forced and no RTL reset behavior or oracle is waived. Unused primitive inputs
are tied identically in both models, not suppressed by a lint waiver.

## Integration and acceptance boundary

Full-PC model **`e9097d96159c60f8605c6f499c19dfb6f357edf00a12485483927a29c9bb4f88`**
is built in `external/tmp/ventium-read-through-soc.NnMGRDlA`. Its only RTL delta
from AGI model `f780b331` is the bridge, with one added define (133 total).
Core, FP, full P5 L1s, 32 KiB platform L2, posted16 writes and memory primitives
are unchanged. Its private harness object uses its own generated headers;
build/pins pass. The 98 inherited full-SoC structural warnings are unchanged,
not a clean full-SoC lint result. This binary has **not** run the standard suite
or been synthesized/deployed to FPGA.

Verified gameplay remains **0.44004644 total U+V IPC**, model `15f56054`, clocks
**1,200,012,763–1,300,012,763**, predating this optimization. This change has no
gameplay measurement. Full same-source CoreMark, Win95, timedemo, differential
gate and hardware timing qualification remain required.
