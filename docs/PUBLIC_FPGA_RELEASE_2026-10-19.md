# Public FPGA source release — 2026-10-19

This promotion is **not a merge of experimental RTL**. It imports the frozen
processor/peripheral source closure associated with deployed image `2886d24c`
and the repaired full-width programmable-clock source wrapper. Development
history and unqualified changes remain on `experimental/uv-fast-ipc-apr`.
The user's pre-existing uncommitted experimental work remains uncommitted locally.

## Source and artifact identity

- Reference raw bitstream SHA256:
  `2886d24c5f9c84219f54e23a4766cfb7106f2999d28e794a0fd00256fd60cc52`.
- Reference routed DCP SHA256:
  `b38e8bd49d8327eb6497146016e252703f9e90235957e903ec85f932fec41d17`.
- Original frozen-source preparation receipt SHA256:
  `5308f8044f35b387e833e1b62a52ec7605bb3a5e157096d9327b638d4b659a54`.
- **188 source/filelist/constraint/profile files, 4,010,025 bytes**, compared
  byte-for-byte with the retained source freeze. The original `flow/` files
  are relocated to `fpga/rk/`; the wrapper sets their roots through environment
  variables. CPU/FPU/cache/SoC RTL and all 159 defines are unedited.
- Four portable build/ownership helpers complete the **192-file public hash
  manifest**, `fpga/known_good_2886d24c.json`. The deployed ECO's narrow clock
  port adapter is not substituted into the full-width source-level block design.
- The larger metadata receipt, synthesis products, routed checkpoint, bitstreams,
  guest disks and private reference material are not Git inputs.

The original image reused physical placement. Fresh source synthesis/APR can
produce a different hash and timing. No new whole-design synthesis, place/route,
CPU differential or hardware acceptance run was launched for this publication.
The owner had cancelled runs before moving to another computer.

## Offline publication checks

- All **215** pins of the cancelled final trial rehashed unchanged after closure.
- Public source hashes and ordered filelist closure pass; exact UV-fast/full-P5
  159-define profile passes; Tcl expansion binds only the packaged source/flow.
- **104 host tests pass**: four source-release, 25 build-scope policy, 27 physical
  map, seven PLL-helper, ten clock-measurement, 13 debug-contract and 18 decoder
  fingerprint tests.
- Bash syntax passes. Opcode-map entries were reconciled for frozen SMSW/LMSW,
  obsolete x87 control no-ops and environment write probing; the decoder
  fingerprint/table were regenerated and verified, not waived.
- All five physical-map PNGs regenerate byte-identically from the committed
  compact dataset without Vivado. The README uses the compact-column CLB view.
- README GIF: 2,814 frames, 320×200, 187.6 s, 15 fps presentation; 5,634,798 bytes,
  palette compression only. No resizing, discarded frames or tonal changes.
- Source hashes deliberately retain the original RTL bytes, including existing
  whitespace in both Ventium and vendored sources; no cosmetic RTL change is
  hidden in this release.

These checks qualify packaging/tool behavior, **not processor correctness or
fresh-implementation timing**. Private-oracle/full-system gates were not rerun.
The public CI rejects large Git blobs and disk/checkpoint/bitstream artifacts.

## Current hardware scope

Verified gameplay: **0.496499864 total U+V IPC**, original `2886d24c`, cycles
**625,021,130,428–629,480,208,865**; primary/U 0.383002768. Counters include
REP-element retirement. The published source is not a new measured image.

Original physical results: Quake 7.7 FPS and Doom 20.50 FPS at approximately
40 MHz; CoreMark 2.100128/2.106796 CM/MHz at 40 MHz, both seeds repeat-tested
through 52.6316 MHz. The STA-derived conditional period budget remains
28.701817 MHz. **40 MHz STA sign-off and this image's Win95/full-suite pass
remain open.** Do not infer them from this publication or from older images.
