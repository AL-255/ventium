# P54 uop-cache cross-line FPGA leaf synthesis

Vivado 2025.2, `xck26-sfvc784-2LV-c`, out-of-context `uopcache`, 45.0 MHz
clock constraint (22.222 ns). Both rows use the same RTL, synthesis script,
single-thread setting, and source SHA-256
`624d50265af37a334e926dc10a1ae94ce258f25c24877502d44e92064be54262`
for `rtl/mem/uopcache.sv`. Reports are in
`/tmp/p54-uopcache-{base,crossline}-r4/` on the measurement host.

| Leaf profile | LUTs | LUTRAMs included | FFs | RAMB36 | RAMB18 | WNS at 45 MHz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Base: `EXEC_REPAIR=0` | 11,984 | 0 | 3,593 | 74 | 4 | +16.112 ns |
| `VEN_UOP_CROSSLINE`, `EXEC_REPAIR=1` | 14,449 | 48 | 3,851 | 74 | 4 | +16.138 ns |

Cross-line repair costs **2,465 LUTs (+20.6%) and 258 FFs (+7.2%)** in
this isolated leaf; BRAM count is unchanged. The clock constraint is 45.0 MHz
for both. The positive WNS is synthesis-only, not a routed maximum frequency:
the leaf has unconstrained external interfaces, no whole-core fanout or
placement, and Vivado warns that `HD.CLK_SRC` is unset. No core-side
`VEN_UOP_CROSSPAIR` circuitry is included, so the final 3-to-2-cycle
cross-pair improvement has **no area/timing estimate** here. Neither this
comparison nor the separate raw decoder leaf can be subtracted directly from
the processor utilization to claim a net saving.

The matched directed frontend ladder in `verif/bench/README.md` found a
line-straddling four-instruction loop at **23 cycles** with the base uop-cache,
**3** with cross-line repair, **2** with cross-pair, and **2** with the raw-byte
frontend; all compared architectural traces matched. This is a fixed-work
microbenchmark, not a gameplay IPC measurement. The large repair area and
localized throughput win make a registered, banked byte-prefetch/length path
worth exploring before promoting the current repair flags. Such a replacement
must preserve instruction-byte coherence, prefix/length and fault ordering,
and it needs integrated FPGA timing, not merely a smaller decoder leaf.

Reproduce one row at a time through the exclusive launcher (the script limits
Vivado synthesis threads to one to stay within the process cap):

```sh
timeout --signal=TERM --kill-after=15s 540s \
  fpga/run_vivado_exclusive.sh -mode batch \
  -source fpga/synth_p54_uopcache_leaf.tcl \
  -tclargs base /tmp/p54-uopcache-base-example
```

Replace `base` with `crossline` and use a different output directory for the
second row. Do not run the two Vivado instances concurrently.
