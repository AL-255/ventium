# Quake fault-frame diagnostic — 2026-08-28

## Result

FreeDOS boots and executes the diagnostic `AUTOEXEC.BAT`, but DOS Quake does
not reach a timedemo frame or the required exact 969-frame disk record on the
deployed `IDENT=a0486501` image.  After the workload returns to the real-mode
FreeDOS loop, the measured core continues retiring at 3.125 MHz, so this is a
guest-workload failure rather than a hung PS daemon.

| Item | Value |
|---|---|
| FPGA raw bitstream | `rk_ao486_fastload.bin`, SHA-256 `5dff8335c4885765dbd6be12e9af02f44eb07d87b9e491968ca7b15a5f34db2d` |
| Diagnostic VHD | `qk_td_fault_frame_logger.vhd`, SHA-256 `6260d058b6b664ae67323b3d13f4a2fd1e3dc78dda39f71002025219e088f7ab` |
| Patched executable on diagnostic disk | SHA-256 `771b5bcc4d180da79a4729df6b0a5bc94ad9d0f59a2741085190cb58d789eacc` |
| Autoexec workload | `quake -nosound -nocdaudio -condebug +viewsize 30 +timedemo demo1` |
| Timedemo result | absent; **not a pass** |

## Frozen exception evidence

The initial `trap-cwsdpmi-exception` capture was coherent and copied off-board
as `quake_fault_capture_20260828/`.  It caught CWSDPMI formatting:

```text
ebp=0000335c esp=00003348 cs=a7 ds=af es=af fs=8f gs=cf ss=33 error=0004
```

The externally frozen hardware snapshot was in the later real-mode formatter
(`CS:EIP=05f7:00001e75`, snapshot `fault_pc=000012d9`), not at the client
instruction.  Its vector field is debug metadata and must not be reported as
the architectural exception vector.  The compact bundle includes the full
128-entry PC and core-observation rings, 64 KiB around the formatter record,
the logger slot page, and the historically implicated high stack page.

The copied raw DDR logger slot at physical `0x0018fb80` remained zero and the
client stack page read as stale code.  That does **not** rule out a cached
client store: the freeze prevents normal L1 writeback.  This is why the board
tool now checks the core-observation ring as well as DDR.

## Diagnostic limitations established

- The CWSDPMI text formatter retains prior records in DDR across a PL reload.
  It cannot be armed blindly before a new guest boot.  A clear-scan guard was
  added, but retained/noncoherent copies still make a boot-stage match suspect.
- The current `QUAKE_FAULT_FRAME_LOGGER.EXE` hook did not produce a visible
  store in its reserved slot on the reproduced return-to-DOS path.  The
  cache-aware core-ring watcher also saw no logger-slot store.
- A clean repeat armed the hardware execution breakpoint at the hook's code
  cave, `EIP=0x0004cf64`.  The workload again returned to FreeDOS without a
  hit, so this particular GO32 handler hook is not on the observed failure
  path (or its assumed runtime EIP needs independently revalidated).  It must
  not be used as proof that no protected-mode exception occurred.

## Tooling changes

`fpga/board-tools/ven_board_probe.py` now provides
`trap-quake-fault-frame`.  It translates the guest logger slot through the
live Quake page tables and freezes on either a nonzero DDR record or a
core-observation-ring store to the slot.  `trap-cwsdpmi-exception` now waits
for an absent record before accepting a new text record.  The operating
constraints and capture procedure are documented in `HOW_TO_RUN_FPGA.md`.
No Verilog, bitstream, or acceptance disk was modified for these host-side
diagnostics.
