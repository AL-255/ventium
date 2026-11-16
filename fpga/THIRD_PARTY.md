# Hardware-source attribution

Ventium-authored sources retain the repository's Solderpad Hardware License 2.1.
The following vendored files retain their original licenses and notices:

- `3rd-party/ao486_MiSTer/rtl/`: patched source subset of
  [MiSTer-devel/ao486_MiSTer](https://github.com/MiSTer-devel/ao486_MiSTer),
  including Aleksander Osman's BSD-licensed ao486 peripherals. The upstream
  license is preserved at `3rd-party/ao486_MiSTer/LICENSE`; per-file notices take
  precedence where different (for example individual sound cores).
- `rtl/soc/sound/opl3/` beneath that tree: Greg Taylor's OPL3 FPGA,
  LGPL-3.0-or-later; `COPYING.LESSER` and `COPYING` accompany the source.
- `fpga/rk/` contains the frozen project-specific RK integration, not AMD
  generated IP output or a redistribution of Vivado. Licensed AMD device/IP
  support is supplied by the builder's own Vivado 2025.2 installation.

The exact modified peripheral sources are included rather than an unpatched
submodule reference. No proprietary reference manuals, Windows/Quake media,
BIOS binary, HDD image or FPGA checkpoint is part of this publication.
