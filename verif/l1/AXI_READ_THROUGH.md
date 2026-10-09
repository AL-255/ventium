# AXI-to-Avalon read-command forwarding

Latest full-PC gameplay result: **0.43894030 total U+V IPC**, `e9097d96`,
cycles **1.2B–1.3B**. This is below parent `f780b331`'s 0.44439995 window;
no representative speedup is established. Both endpoint frames show advancing
unaltered Quake gameplay, with236 source/17 runtime pins and native/service
identity checked. Evidence:`ventium-read-through-gameplay.vnfwAGcz/window`.
Equal-clock windows do not prove equal work. The complete timedemo, standard
suite and FPGA deployment remain open; later larger-L2 gameplay is unmeasured.

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
not a clean full-SoC lint result. It has not completed the standard suite or
been synthesized/deployed to FPGA.

Cold Quake/Win95 qualification is now running, with unchanged media and the
same per-run one-CPU/2 GiB/no-swap/32-task/4 GiB-file limits. CPU28 Quake
invocation is `fa4189beba1e4f438494237b9dfec7f0`; CPU29 Win95 invocation is
`bd39a4aeaf774e3693c1a9b29099edcc`. The independent `admission-audit.json`
rechecks source/runtime pins, native identities, resource bounds and zero OOM.
`gameplay-plan.json` fixes samples12/13 and frames6/7 before gameplay. These
are candidate qualification runs, not production acceptance.

Verified gameplay remains **0.44004644 total U+V IPC**, model `15f56054`, clocks
**1,200,012,763–1,300,012,763**, predating this optimization. This change has no
gameplay measurement. Full same-source CoreMark, Win95, timedemo, differential
gate and hardware timing qualification remain required.

## Isolated FPGA cost check

`fpga/run-axi-read-through-leaf.py --leaf-result /absolute/path/to/r2` freezes
the actually tested bridge sources and runs old/disabled/enabled sequentially
in one exclusive, 8 GiB/no-swap, ten-minute-bounded Vivado family. The matching
Tcl uses `xczu15eg-ffvb1156-2-i`, 25 ns and zero-delay isolated I/O budgets.
It creates no CPU bitstream and changes nothing on the board.

Evidence: `external/tmp/ventium-read-through-physical.ou0amfh0`.

| Routed isolated bridge | Original / disabled | Enabled |
| --- | ---: | ---: |
| CLB LUTs | 149 | 175 |
| Registers | 71 | 72 |
| BRAM / DSP | 0 / 0 | 0 / 0 |
| Setup-limited leaf frequency estimate | 451.67 MHz | 445.83 MHz |
| Worst hold slack | −0.049 ns | −0.050 ns |
| Hold-failing endpoints | 21 | 17 |

The saved command clock costs **26 mapped CLB LUTs and one register**. The
disabled candidate reproduces the original area and timing exactly. Raw LUT
primitive counts are 187→216, a different metric from mapped CLB LUTs.
The setup path grows by 0.029 ns; this tiny leaf's frequency is **not CPU Fmax**.
All three reports explicitly fail hold timing under these isolated constraints;
there is no timing sign-off or ignored hold violation.

Native exit0, unchanged source pins, 255.49 seconds, peak cgroup RAM
4,180,992,000 bytes, zero swap/OOM, and no surviving Vivado family. Scope
invocation: `6eb4e42e12434ecda5b182c616164f07`. The full-system cold runs and
0.48 gameplay target remain open; no performance is inferred from leaf timing.
