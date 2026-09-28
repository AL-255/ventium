# P54 checked memory-ALU decoder FPGA probe

Vivado 2025.2, `xck26-sfvc784-2LV-c`, 22.222 ns (45 MHz) clock. A common
register-to-register wrapper (`p54_decode_probe.sv`) encloses the existing
`decode.sv` so both variants have the same input/output registers and timing
endpoints. The control defines `VEN_FAST_MEM_ADD`; the candidate adds only
`VEN_FAST_MEM_ALU`. This mirrors production's fast-ADD base flag; neither
variant adds the separate optional `VEN_FAST_MEM_ADD7` profile. Decoder source
SHA-256: `5be69149ae87e369d29dc431e5ea399409de72c810e8f72c6b23ad79debf14db`.
Wrapper SHA-256: `c475a8dbff66496d05c9743c1b57c3b4701d3bbc108ebf3f9ac6c61e2d1e9872`.

| Variant | Logic LUTs | FFs | Synthesis WNS at 45 MHz |
| --- | ---: | ---: | ---: |
| Fast ADD control | 970 | 249 | +20.010 ns |
| + checked memory ALU | 975 | 249 | +19.989 ns |

The opt-in extension adds **5 LUTs** and changes isolated synthesis WNS by
**−0.021 ns**. These are useful area/logic-depth bounds for the decoder leaf,
not routed whole-core frequency: the real input muxes, issue/AGU path,
fanout, physical congestion and clock skew are not in this wrapper. The
directed 22-case and pinned-QEMU memory-ALU tests in
`verif/bench/README.md` establish functional/short-loop behavior separately;
they do not provide gameplay IPC or full-system acceptance. Promotion still
requires candidate-specific full gates, gameplay and routed FPGA timing.

Artifacts: `/tmp/p54-decode-probe-{control,mem-alu}-r2/`. Both runs used the
exclusive Vivado launcher and completed inside the 10-minute limit. Reproduce
one variant at a time:

```sh
timeout --signal=TERM --kill-after=15s 540s \
  fpga/run_vivado_exclusive.sh -mode batch \
  -source fpga/synth_p54_decode_probe.tcl \
  -tclargs control /tmp/p54-decode-probe-control-example
```
