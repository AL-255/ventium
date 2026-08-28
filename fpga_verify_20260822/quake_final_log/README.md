# Quake result-only logging instrument

## Purpose

Normal `-condebug` makes the 3.125 MHz FPGA write every console message through
DOS file services. The first board experiment created `QCONSOLE.LOG` but became
dominated by this instrumentation and stopped advancing at a 133-byte file. This
variant leaves console-file logging disabled during boot and initialization, then
enables it only around the existing timedemo-result `Con_Printf` call. The expected
disk write is one 36-byte record.

This is a guest workload instrument, not an RTL workaround. The deployed BIOS is
unchanged, CR0 starts at its real P5 reset value, the exact demo still executes 969
frames, and the repaired RTL must boot the complete BIOS/FreeDOS/CWSDPMI path
before this code is reached.

## Exact changes

The base is `../quake_norender_pagein/QUAKE_NORENDER_PAGEIN.EXE`, SHA-256
`2a7a8a1abe337c2c800ae453a41c493e08587d4f8eac0cd9eb20d2d27817bd96`.
It already contains the documented no-render and startup-page-in accelerators.

`QUAKE_FINAL_LOG.EXE`, SHA-256
`5288124fdc6b950000d2d4244e49603ec04671418ded296faa816a1a1f6bfc1f`,
adds two changes. Runtime addresses are file offsets plus `0x800`:

1. At file `0x6107` / runtime `0x6907`, replace the five-byte
   `COM_CheckParm("-condebug")` call with `xor eax,eax; nop; nop; nop`. The
   cumulative caller cleanup and its already-pushed argument are preserved.
2. At file `0x37e0` / runtime `0x3fe0`, retarget only the timedemo result call to
   a wrapper at runtime `0x3fec`. The wrapper drops its private return address,
   sets `con_debuglog` at `0x90b40`, calls the original `Con_Printf` at `0x6bb2`
   with the caller's existing variadic arguments, clears `con_debuglog`, pushes
   the original continuation `0x3fe5`, and returns. Dropping the wrapper return
   before the variadic call is essential; the first attempted wrapper left that
   word between the format string and arguments, and pinned QEMU caught the
   resulting 12 instruction bytes instead of a result line.

The final wrapper bytes at file `0x37ec` are:

```text
83 c4 04
c7 05 40 0b 09 00 01 00 00 00
e8 b4 2b 00 00
c7 05 40 0b 09 00 00 00 00 00
68 e5 3f 00 00
c3
```

## QEMU oracle

Pinned QEMU 8.2.2 with `-cpu pentium`, 32 MiB, and the same timedemo disk emits
exactly:

```text
969 frames   2.4 seconds 404.7 fps
```

`qemu_final_only_qconsole.log` is exactly 36 bytes and has SHA-256
`f161736fa8e9d1fae566fd5f581895154d4550f56e25757678711f37f99bbbf8`.
The QEMU-mutated disk is `qk_td_final_log.vhd`, SHA-256
`3aa767cc33c6ad6dd3eba988cdb30338a312888aa1df80a105c8b218cf9c33b2`.
The clean, never-booted deployment copy is `qk_td_final_log_clean.vhd`, SHA-256
`13f0a1286ceb0da61ddb2f2f20cacdcabbe585dc2967ba39df3a519463795509`.

On this FAT16 image, `\QUAKE\ID1` is cluster 138 and its directory occupies disk
LBAs 878--879. `QCONSOLE.LOG` receives cluster 18814, whose data begins at LBA
38230. A live board check can read the result without mounting or modifying the
disk:

```bash
ssh riguke@10.0.0.214 \
  "sudo dd if=/tmp/ao486/qk_td.vhd \
   bs=512 skip=38230 count=2 status=none" | \
  grep -a -o '969 frames[^[:cntrl:]]*'
```

## FPGA run

The clean disk is paired with
`fpga_run_20260822_l1bypown/rk_ao486_system.bit.bin`, SHA-256
`891881f6b7196023bf1d34a6433b7a53f7814166ce6a38dbeb31c0db5f15b5dc`.
The detached board service is `ven-quake-final-only.service`; its filtered log is
`/tmp/ao486/quake_norender_repaired.log`. During the long CPU-only phase, use the
read-only hardware probes rather than interpreting an idle disk as a hang:

```bash
sudo /tmp/ao486/ven_board_probe.py sample --samples 20 --interval 0.25 --all
sudo /tmp/ao486/ven_board_probe.py perf --seconds 10
```

## Board result and preserved failure evidence

The exact image above was run twice on the repaired L1-ownership bitstream. It
did **not** create `QCONSOLE.LOG`; this is a failure, not an in-progress or
partial Quake pass. After both attempts the board disk still had the clean
SHA-256
`13f0a1286ceb0da61ddb2f2f20cacdcabbe585dc2967ba39df3a519463795509`.
The final Quake and exception-trap services were inactive after evidence capture.

The second run paired the daemon with:

```bash
sudo /tmp/ao486/ven_board_probe.py trap-cwsdpmi-exception \
  --start 0x20000 --end 0x50000 --timeout 900
```

The probe scans guest RAM read-only and pulses the existing external freeze only
after a fully substituted CWSDPMI exception record appears. It fired at low
memory `0x338ba` on:

```text
ebp=0000384a esp=0000383a cs=18 ds=af es=20 fs=cf gs=cf ss=20 error=0003
```

The on-die ring then held 128 post-fault entries in CWSDPMI's formatter. The
freeze register's displayed vector `08` was stale diagnostic metadata and is not
used as the architectural diagnosis. The authoritative resident TSS at physical
`0x30142` in the frozen RAM contains:

```text
irqn=0d error=00000028 cr3=0007e000 cr2=00000000
cs:eip=0018:00001105 eflags=00003006
eax=00114571 ebx=0011b298 ecx=00000005 edx=80000f7f
esi=00119ea1 edi=0000384e ebp=0000384a esp=0000383a
ds=00af es=0020 fs=00cf gs=00cf ss=0020
```

The captured GDT is at `0x2d0d0`: selector `0x18` is 16-bit ring-0 code with
base `0x26d90`, `0x20` is ring-0 data with base `0x2c9d0`, and `0x33` is a valid
ring-3 data selector. Thus the faulting physical address is `0x27e95`, whose
bytes are `66 67 c5 75 10` (`lds esi,[ebp+0x10]`, m16:32). The saved call-gate
frame at `SS:[EBP+16]`, physical `0x3022a`, correctly contains old
`ESP=0x3484, SS=0x33`. CWSDPMI r7 source names this exact instruction in
`_ring0_iret`. The inspected distribution identifies itself as
`csdpmi7s CWSDPMI source distribution (release 7)`; its archive SHA-256 is
`882d29200a720ef5ad3591afc27f7d66a5fc575dddcd6590acea346813aa6d7f`.

RTL inspection closes the chain: `decode_stages.sv` accepts C4/C5 only under
`seg_real`, so the protected-mode instruction is delivered as `#UD`; the later
CWSDPMI path reports `#GP(0x28)`. The protected-mode `S_SEGLD` execution path
already exists but is unreachable from C4/C5. The complete fix must also defer
the GPR write until descriptor validation so a fault cannot partially commit
LDS/LES. See `../IRQFIX_SILICON_AUDIT.md` for the compact shared-transaction fix
and mandatory regressions.

Preserved artifacts:

| Artifact | SHA-256 |
|---|---|
| `quake_exception_lowmem.bin` | `7c6dd8d31345713e5018d4a55d779cbd0fc3cb135a1a6377d29e8ea4d74e2601` |
| `quake_exception_highmem.bin` | `5aa47878d2049bf5969f9f1254452c1f4a20ea57540485d29db04cb1a4a238d9` |
| `quake_exception_ring.log` | `2e5044b48650d8e6dd7dfc99288fcb315cfbc445348fa0871b69672f5baa4e4e` |
| `quake_exception_trap.log` | `c503f835d47c74ab4b1e3a2e99cafc0045ebb27217805c85f3eb61dcecf98214` |
| second daemon log `quake_norender_repaired.log` | `4a47cc8a31fe889ff50590ed4e64b815e0610f115e692d0736a0fb0519b55b0c` |
| first daemon log `quake_norender_repaired_first.log` | `c6d66b2dd1bbb99bc06b3ab70d0581e75a9278054b5c17906e07876202752dd9` |
| `../../fpga/board-tools/ven_board_probe.py` used on board | `436a8d86f3f3fcd6f2b56f4548130b29031a9066ae4cf0f6f73e2688e9a7e600` |

`quake-progress` is a safe read-only companion once Quake has created its live
page tables. With the captured CWSDPMI layout its defaults are `CR3=0x7e000` and
Quake DS base `0x10000000`; it walks PDE/PTE entries in guest RAM and reports
`host_framecount`, `td_startframe`, and their physical locations without reading
or rewriting the disk.
