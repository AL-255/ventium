# Independent V D-TLB lookup: FPGA leaf cost

Vivado 2025.2 OOC synthesis, `xck26-sfvc784-2LV-c`, 45 MHz clock constraint.
All four matched runs used `fpga/run_vivado_exclusive.sh`, each below ten
minutes, with no overlapping or orphan Vivado instance. The direct-map and
four-way sources were respectively SHA-256
`f4c040a28c170d0e470cc37516e25bd30c2c55ac325268619438a857f13e477a`
and `5af4f2b5ed5be17c341a6f5eb1217d8fe6efb72fc311f3149d52484a799f0c53`.
Both base variants include the pre-existing memory-chain lookahead query;
the pair variants add an independent V query on top of that. The paired ports
are still unused by the core issue/commit path.

| D-TLB geometry | Base LUTs | With V lookup | Extra LUTs | FFs both |
| --- | ---: | ---: | ---: | ---: |
| 16-entry direct-mapped | 438 | 640 | **202** | 736 |
| 16-set, four-way (64 entries) | 2,763 | 3,164 | **401** | 2,976 |

All rows infer only LUT logic and FFs, no LUTRAM or BRAM. The V lookup is
side-effect-free: it shares the registered entries and the single fill/flush
writer, while selecting its own tag, physical frame, permission and dirty
payload. The four-way extra port costs 14.5% more LUTs than its two-query
control. This is a real, bounded FPGA area cost, not a measured throughput
gain. It is small enough to retain as an opt-in prerequisite, but a final
P54 memory pipeline should compare this three-query design against sharing
the lookahead query only when V-memory pairing needs it. Sharing may reduce
area but could lose memory-chain lookahead on those edges; neither tradeoff is
measured yet.

The OOC clock only constrains internal register paths. The combinational
lookup outputs have no top-level output delays in this probe, so its positive
WNS is **not** a D-TLB lookup Fmax or a routed core frequency. See
`/tmp/p54-pair-dtlb-{direct,assoc}-{base,pair}-r1/` for all utilization and
timing reports. Reproduce one row at a time:

```sh
timeout --signal=TERM --kill-after=15s 540s \
  fpga/run_vivado_exclusive.sh -mode batch \
  -source fpga/synth_p54_pair_dtlb_leaf.tcl \
  -tclargs assoc_pair /tmp/p54-pair-dtlb-assoc-pair-example
```

The bounded direct/four-way Verilator microbench (`verif/bench/run-p54-pair-dtlb.sh`)
passes seven checks per geometry, including same-set way identity and large
page offset. No full verification or gameplay run was performed for this
uncommitted-to-issue port; the historical verified gameplay IPC remains
0.426371504 on build `229c4cd5`, window 1.15–1.40B cycles, and predates
this candidate.
