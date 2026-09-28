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

## Rejected true-dual-port storage trial

A subsequent **temporary, discarded** `VEN_UOP_SHARED_BRAM` variant replaced
the duplicate A/B descriptor arrays with one Xilinx true-dual-port array:
port A remained readable; port B was a read port except on the walker's atomic
publication edge, when it wrote the new line. A same-row A read and every B
read on that edge were suppressed by registered validity guards. A new
seven-check collision/port test, the 4,398-check repair test, and the 4/8-tail
capacity tests passed under that variant. Vivado explicitly reported a
“true dual port RAM template” for all three descriptor/map arrays.

Nevertheless, the temporary variant in
`/tmp/p54-uopcache-shared-r1/` mapped to **13,107 LUTs, 3,608 FFs, 74
RAMB36 and 4 RAMB18**, with synthesis WNS +16.366 ns at the same 45 MHz
constraint. Relative to the retained base, it used **1,123 more LUTs, 15
more FFs and exactly the same BRAM count**. The two-read/one-write port
schedule also makes the B result unavailable for one publication cycle. The
temporary RTL and gate were therefore removed, not promoted or included in
the production filelists. The preserved `/tmp` report is a diagnostic record,
not a reproducible variant in the current source tree. The measured result is
consistent with BRAM port-width/packing limits offsetting the removed logical
copy; that explanation is an inference, not a demonstrated primitive-level
proof. Future FPGA memory changes must show an actual mapped resource or
throughput win before accepting new port conflicts.

## September 28: indexed cross-line payload mapped as SRAM

The 33-entry experiment originally declared `cross_index_data` as an unpacked
array of packed `fpd_t` structs with `ram_style="distributed"`. That attribute
did **not** make it RAM: Vivado's log named per-field `cross_index_data_reg`
flip-flops. A storage-only change to a 32×`$bits(fpd_t)` plain vector array,
with an explicit cast back to `fpd_t` on its one indexed read, inferred
`RAM32M16 × 15`. The same single indexed write and exact two-source validity
metadata remain. The 750-check cross-line gate and 1,358,922-check decoder
tail-invariance sweep pass on the changed source.

All rows below use the same script, `xck26-sfvc784-2LV-c`, 22.222 ns clock,
`EXEC_REPAIR=1`, `TAIL_LOCAL=1`, and `VEN_UOP_REPAIR_FAIR`; only the listed
capacity/storage form changes. One Vivado instance ran at a time through the
exclusive launcher, each below ten minutes. Reports are under
`/home/yukidama/ventium-background-sep28.B3cxzoKA/uop_leaf_<variant>/`;
the packed row uses `uop_leaf_cross33_packed/`.
The first three rows use `uopcache.sv` SHA-256 `624d5026...`; the packed row
uses `3c19937a...`.

| Leaf profile | LUTs | LUTRAMs | FFs | RAMB36/18 | Synthesis WNS | Implied leaf setup frequency* |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `crossline_local` (one record) | 14,435 | 48 | 3,869 | 74/4 | +16.418 ns | ~172 MHz |
| `cross2_local` (two records) | 13,598 | 48 | 4,061 | 74/4 | +16.204 ns | ~166 MHz |
| `cross33_local` (struct payload) | 17,019 | 48 | 10,759 | 74/4 | +16.126 ns | ~164 MHz |
| `cross33_local` (vector payload) | 13,055 | 168 | 4,562 | 74/4 | +16.620 ns | ~179 MHz |

Reproduce a row from the corresponding source revision with, for example:

```sh
timeout 540s fpga/run_vivado_exclusive.sh -mode batch \
  -source fpga/synth_p54_uopcache_leaf.tcl \
  -tclargs cross33_local /absolute/output/directory
```

Run rows sequentially; this launcher terminates any earlier Vivado family
before starting a new one.

\*Calculated as `1 / (22.222 ns − WNS)` only to make the **isolated,
partially constrained synthesis** comparison readable. It is not routed Fmax:
external interfaces and clock-source skew are not fully constrained, and the
core-side cross-line pairing logic is absent from this leaf. The packed form
saves 3,964 LUTs and 6,197 FFs over the struct form, using 120 more LUTRAMs;
it does not consume an extra BRAM. Synthesis unexpectedly maps the two-entry
form with fewer LUTs than the one-entry form; do not assume monotonic logic
costs from source-level record counts.

The indexed form beat the two-entry form by 24.24% cycles on a synthetic
12-seam whole-core microbenchmark before this storage-only change. The two
forms tie on the separate two-hot-seam test. Neither result establishes a
gameplay win or routed timing. On the packed full-core build, the 30-case
fixed-work A/B is architecturally and cycle-count identical to the struct
build; the three-phase writable-code test passes 1,552 QEMU-equivalent groups
with descriptor hits after mutations to either source line; and the 12-seam
test retains 8,955 cycles for 3,582 warm instructions with QEMU-equivalent
retirement groups. The isolated corrected-QEMU cross-page diagnostic matches
1,601 groups, but the canonical pinned free-running QEMU fails its own
fixture self-check (exit 135 instead of 133). These directed checks do not
promote the indexed form to production: routed whole-core area/timing and
representative gameplay are still unmeasured.
