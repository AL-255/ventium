# AXI extent payload preparation — 2026-10-11 UTC

**Leaf experiment only. Not included in the currently running write-direction
synthesis. No whole-core, performance, timing or FPGA acceptance.**

The previous critical path includes a wide extent adder after late write-kind
and spill selection. [The proposed recipe](../verif/l1/prepare_axi_extent_payload.py)
prepares both word endpoints before selecting between them:

```text
old: word_base + (spill ? 7 : 3)
new: spill ? {word_index + 1, 2'b11} : {word_index, 2'b11}
```

The increment is exactly 30 bits, preserving 32-bit wraparound. Primary and
paired write extents use the same transformation. Narrow-read arithmetic,
arbitrary address-mask checks, ROM exemptions, requests, rejection, queue and
response logic are untouched. The new code is a private transformation of
master SHA `ed11478bcf7898e410b5d9bd4f1952d8d3291037f38987c3c01eb935b9b13e38`;
the production checkout is not modified.

[Recipe tests](../verif/l1/test_axi_extent_payload.py) reject source drift and
reapplication. Z3 proves the word arithmetic identity for every 32-bit address
and spill value, including arbitrary masks. Both missing-spill and incorrectly
narrowed-increment mutants produce counterexamples. This proves those unsigned
bit-vector expressions, not a sequential AXI implementation.

[The native source-extracted test](../verif/l1/run_axi_extent_payload.py) compares
all extent/rejection outputs over 1,048,576 combinations of controls, strobes,
address-bit boundaries, sparse masks, ROM boundaries and wraparound. It observes
524,288 active requests, 288,512 rejections and 19,584 wrapped endpoints. The
actual candidate passes; a compiled no-increment mutant fails with native exit 1.
The native leaf run closes in 11.44 seconds, service
`ventium-axi-extent-leaf-oct11.service`, invocation
`df02f13c6a594b0ca012fef45339f9f7`.

Evidence: `/home/yukidama/external/tmp/ventium-axi-extent.dnJuEAb2/leaf-r1`.
Receipt SHA: `2d9f60adb04cfdc98a93776eaebb578092e163c0c8cc3cd0b219bb140014dd90`.
It still needs whole-master fault/backpressure tests, full-core comparison,
full-PC regression and matched synthesis before adoption. Leaf equivalence
does not predict how Vivado will map or time it.

The >=40 MHz synthesized-Fmax goal is still open. Gameplay baseline remains
**0.51030715 U+V IPC**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predating both experiments; neither has a
gameplay measurement.
