# mairq — live-board interrupt-injection smoke (M-A)

The cheapest hardware gate on the road to interrupt-driven guests (SeaBIOS/FreeDOS)
on the live KV260: it proves the deployed bitstream's PS→core interrupt-injection
seam (`R_INTR`) delivers a real-mode IVT interrupt on silicon, with `cosim_en`
(IO bridge) + `soc_en` (INTR divert) both active.

- `mairq.S` / `mairq.ld` — real-mode guest (`gcc -m32`, reset stub F000:FFF0):
  init COM1, print `A`, install IVT[8]→handler, `sti; spin`; the handler prints
  `T` per delivered IRQ0 and isa-debug-exits after 16. Build `-DNO_IVT_WRITE` to
  skip the guest's own IVT write (so the PS-staged DDR IVT is the only source).
- `../../../sw/ps/ven_soc_app/ven_irqtest.c` — the PS harness (cross-compile
  `aarch64-linux-gnu-gcc -O2 -static`). Knobs: `-DDIAG` single-shot with retire +
  IVT probing, `-DPRESTAGE_IVT` writes IVT[8] straight into the carveout DDR.

## Result (2026-06-13)

Injection + INTA handshake + IVT vectoring all work on silicon **when the IVT is
coherent in DDR** (PS-staged). But a guest-written IVT entry (cached in the
write-back L1D under mode-2 L1AXI) is NOT seen by the core's INT-delivery, which
reads the IVT uncached from DDR → mis-vector. This is the gating blocker for
SeaBIOS/FreeDOS on hardware; it needs an RTL fix (route INT-delivery memory
accesses through L1D, or make the low region coherent) + a new bitstream. See the
`hw-irq-ivt-coherence` project memo.
