# Quake protected-exit capture — 2026-08-26

The FPGA image with `IDENT=a0486501` still does not produce the required
`969 frames` timedemo result.  This note records the live on-board trace
qualification added during the follow-up diagnostic.

`fpga/board-tools/ven_board_probe.py` now supports `trap-pe-exit --skip-exits N`.
It arms only after Quake's protected selector `CS=00a7` and freezes only after
`CR0.PE` falls.  This is deliberately a debug-tool change, not RTL logic.

With a clean result-log disk and the current deployed image, the first three
qualified exits are repeatable:

1. `00a7:00000338` to `0018:00002bcf`, `CR0=e0000019 -> 60000010`.
2. `00a7:00002b70` or `00a7:00002b73` to the same `0018:00002bcf` entry.
3. Another `00a7:00002b73` to `0018:00002bcf`, with freeze PC near `0x2bd2`.

The second and third transitions are vector-14/page-fault dispatch, not a
normal GO32 `int 21h,4Ch` return.  A binary-only marker at that normal return
site remained clear (`0000:0800 != A55A`) after the known 582-read trajectory.
Therefore the sustained DOS/BIOS state is exception cleanup after an earlier
fault, not successful Quake termination.

This narrows the repair investigation to the producer of the client page
fault/stack corruption.  It does not identify the client instruction by itself:
the external freeze preserves the handler entry, not the cache-resident DPMI
fault frame.  The existing x87 EMPTY-source/dtoa-corruption lead remains the
highest-priority source-matched hypothesis; no RTL modification was made here.
