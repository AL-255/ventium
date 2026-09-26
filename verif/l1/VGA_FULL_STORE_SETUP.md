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
measured for the setup flag independently. The combined-profile runtime below
is measured, but is not an isolated A/B attribution to this flag. FPGA timing
qualification remains open.

## Qualified four-plane store

`VEN_VGA_WIDE_STORE` is separately opt-in. For a full-strobe write in VGA
chain-4 mode with the unmodified byte replacement function, the cache sends
one 32-bit word to the four independent plane RAM write ports in one clock.
Eligibility is checked when the write is accepted and again at commit; a VGA
register change between those edges falls back to the byte sequencer. Map
masks and bank selection still apply. Partial stores, other VGA write modes,
and framebuffer/DDR traffic retain the legacy route. This does not depend on
guest PC or data patterns.

```sh
tools/build_scope.sh -- bash verif/l1/run-vga-wide-store-gate.sh \
  tmp/build-tmp/vga-wide-NEW
```

The September 26 gate passed both wide-only and wide-plus-setup profiles,
comparing all four physical plane RAMs against the legacy path across 18
cases per profile, including unsupported modes, configuration changes, and
reset. The eligible transfer used one write clock instead of four. A full-PC
model with `VEN_L2_STREAM_CWF` and `VEN_VGA_WIDE_STORE` compiled. Neither a
full Quake timedemo nor FPGA synthesis/timing has qualified this opt-in
path. Reconstruction of the
complete wave7 1M-cycle state trace found all 16,000 full-strobe setup clocks
and all 64,000 byte-write clocks in the eligible VGA register mode. Replacing
four byte writes with one can directly remove at most 48,000 of those write
clocks in that window (plus up to 16,000 setup clocks with both flags), before
any secondary scheduling effects. This is an exposure bound, not a measured
IPC gain.

## Combined-profile full-PC runtime (September 26)

The current RTL with the wave9 define set plus both VGA flags built as binary
SHA256 `b278c988be64f7eaae0ab56b21faafd5dfcee250984136c9dd628a332513c247`.
The cold Quake-disk run and same-binary, paired-disk checkpoints at 100M, 300M,
500M, 700M, 900M, 1.100B and 1.101B clocks all passed bundle verification.
Same-binary 2M→3M replay produced identical final snapshot and disk. A raw
1.000B frame and the final 1.101B frame show Quake gameplay. The latest bundle
is `tmp/build-tmp/ventium-vga-wave9-resume1101000000-sep26/`.

| Gameplay clock window | Wave9 IPC | Combined VGA candidate IPC |
| --- | ---: | ---: |
| 1.050–1.100B (50M) | 0.444702 | **0.44577548** |
| 1.100–1.101B (1M) | 0.305049 | **0.564642** |

The candidate was already 884,766 retirements ahead at 1.100B, and the raw
frames show different points in the demo. Thus the large 1M-window difference
is a **phase-shifted observation, not a matched-work speedup**. Even the small
50M difference is not an isolated causal estimate: current RTL differs from
the older wave9 build beyond these flags. The combined candidate's **current
verified gameplay IPC is 0.564642** for its 1.100–1.101B window. A completed
timedemo, Win95 boot, matched-work A/B, and FPGA timing remain open; no >1 IPC
claim is made. The full-PC profile still includes `VEN_FAST_RETRACE` and the
headless keyboard defines, so this is not an on-board framerate sign-off.
