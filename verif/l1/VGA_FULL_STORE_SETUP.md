# Legacy VGA full-store setup

`VEN_VGA_FULL_STORE_SETUP` is default off. In `l2_cache.v`, an accepted legacy
VGA write with all four byte enables starts `VGAWRITE` directly. The existing
four byte-port writes, their addresses, data, order, and busy release remain
unchanged. Partial stores, framebuffer/DDR routing, and reads retain the old
path. This is a generic VGA transfer optimization, not a Quake address match.

The cache's effective reset now clears `vga_wr`, `vga_re`, and `vga_be` in all
profiles. The downstream VGA plane RAM write enable is not reset-gated, so a
registered strobe left active would otherwise repeat a byte during the cache's
tag-initialization walk. Bytes issued before the effective reset edge are not
rolled back.

Run the actual cache-port gate with a fresh output directory:

```sh
tools/build_scope.sh -- bash verif/l1/run-vga-full-store-setup-gate.sh \
  tmp/build-tmp/vga-full-store-NEW
```

The September 26 run passed 523 normal writes in each profile, all byte and
DDR traffic comparisons, and six interrupted write/read reset cases. Full VGA
stores completed one cache clock sooner when enabled. The existing AXI to
ao486 cache path gate passed all six replay/stream configurations. The canonical
platform overlay applies to the pinned submodule index and reverses cleanly
from the live source.

The verified wave7 gameplay trace has 16,000 legacy VGA setup clocks followed
by 64,000 byte-write clocks for a 16,000-DWORD VGA copy. At most the setup
clocks are directly removable by this feature; no gameplay speedup has been
measured for it. Latest verified gameplay IPC is **0.305049** on wave9's
1.100–1.101B-cycle window, which predates this feature. Full-PC and FPGA
performance and timing qualification remain open.
