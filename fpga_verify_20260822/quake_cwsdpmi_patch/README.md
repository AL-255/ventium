# CWSDPMI LDS workaround and repair evidence — 2026-08-23

## Purpose and immutable inputs

The repaired L1-ownership FPGA image reaches CWSDPMI but the original Quake
disk faults on the protected-mode instruction `66 67 C5 75 10`
(`LDS ESI,[EBP+0x10]`).  This directory contains a hash-locked guest workaround
used to advance silicon past that first defect while a real RTL repair is built.

| Artifact | SHA-256 |
|---|---|
| `CWSDPMI_ORIG.EXE` | `0a890815df6cbdc052915a856c16944cedec825267e7b6e453c351a0cdc695f2` |
| `CWSDPMI_PATCH.EXE` | `aaa60d777f931cc8bd3214475a1df76def056833c03d9bfdf843fc84caed82a3` |
| clean patched disk `qk_td_cwsdpmi_patch.vhd` | `cca2b2ed9fce773074d29bb6a7f4f8b5cbe817e688b7bfe138bd849a29b546cc` |
| patcher `patch_cwsdpmi.py` | `2dc1f17208b62ffcf83068d4ce53775883d0605d167e78758f446cf1cf96e3e5` |

The patcher verifies the complete input hash and instruction context.  It makes
two fixed-length substitutions in CWSDPMI release 7's `_ring0_iret` path:

```text
66 67 C5 75 10  ->  66 67 8B 75 10    MOV ESI,[EBP+0x10]
next FC         ->  36                SS override on the following REP MOVSD
```

The preceding code has already loaded `ES=SS`, and the saved DF is clear on the
exact Quake path.  This is therefore a workload discriminator, not a general
replacement implementation of LDS.

Pinned QEMU 8.2.2 ran the patched disk through the complete workload and wrote
`969 frames 0.6 seconds 1711.3 fps`.  The unrestricted TCG time is not an FPGA
performance result; the exact 969-frame count proves only that the patch
preserves this Quake path.

## FPGA results with the workaround

Both runs used the known L1-ownership image
`fpga_run_20260822_l1bypown/rk_ao486_system.bit.bin`, SHA-256
`891881f6b7196023bf1d34a6433b7a53f7814166ce6a38dbeb31c0db5f15b5dc`,
and `IDENT=A0486501`.

The workaround passes the original protected LDS location: Quake page tables
are installed and protected/client EIPs advance.  The sampled execution later
crossed back through CWSDPMI into real-mode selectors without yet creating
`QCONSOLE.LOG`.  Those runs were stopped (and one was deliberately frozen) at
that observation; they do **not** prove that Quake had terminated.  A later
uninterrupted run showed disk reads continuing across the same selector
round-trip.  The board disk remained byte-identical to the clean `cca2...`
image, so neither early run is an acceptance pass.  Preserved daemon logs:

| Log | SHA-256 | Observation |
|---|---|---|
| `quake_cws_patch_first.log` | `e3cdce6f89c9e19cc3ab2997bb34f54ddcd8cdda7a8503c2b8cf1cf106121537` | disk activity stops near daemon time 392 s; no result |
| `quake_cws_patch_second.log` | `ac48ccad5942fb3e03c352d517cfda0b48f32a23bc73e5412dac8e532c543356` | independent repeat through the same late window |

A read-only live-ring sample caught the late transition from repeated
`CS=26D9`, EIPs approximately `0x30AF..0x5966`, through `05F7/10EF` and then
BIOS/DOS selectors.  The original CWSDPMI exception-record trigger did not fire,
so this is a silent protected-mode/DPMI exit rather than the earlier formatted
exception.

The first stateful selector trigger fired much earlier on a normal real-mode
loader round trip (`26D9:138B -> 05F7`).  It is retained as a negative-control
for trigger qualification:

| Artifact | SHA-256 |
|---|---|
| `quake_protexit_early_trap.log` | `d61f5221985205007a2059df1d066e117733bf9c835bd8af60ad955abd608194` |
| `quake_protexit_early_ring.log` | `d8052a1bb0b36971d9184b5cf7d7a2888612567fb54eac53b1236b3e3cd96ff2` |

The superseding diagnostic uses `ven_board_probe.py trap-pe-exit` after a
300-second startup delay.  It arms only on live `CR0.PE=1` and freezes on the
first `PE 1->0` transition, preserving the late boundary without mistaking a
real-mode segment value for a protected selector.

That trigger fired on the fourth run and the evidence was copied off the board
before it was reset:

| Artifact | SHA-256 |
|---|---|
| `quake_peexit4_ring.log` | `38b9592420fc7cb41063459d33d6b64549726490881b510bd4206aa4f51270f9` |
| `quake_peexit4_lowmem.bin.gz` | `0061c9a4a08f8a35dece346f29c932575b04928d463061e498357bce05a5f479` |
| `quake_peexit4_highmem.bin.gz` | `cfb256f78af7a5635d0cd091e35f332ac5810537aa3d6e30b0470cc6f01cbea6` |
| `quake_peexit4.log` | `f82bace665aadc45b6fc55fc1e56e6788d5450ec6837109a50af2f05d98f57c8` |
| `quake_cws_patch4.log` | `aa54289f5168f6a224a23ebde1f60705b9d0af3f95614f029a2d47521abd2e3e` |

The transition follows CWSDPMI's protected-to-real-mode teardown sequence: the
stub clears `CR0.PE` and far-jumps back to `26D9`.  It is not an immediate
repeat of the protected `LDS` exception.  It proves the first workaround crossed
the original blocker, but the trigger itself freezes execution at a transition
that can be a normal DPMI-host round trip.  It therefore cannot establish that
the client chose to terminate.

## DF-robust workaround revision

The first workaround replaced the original `CLD` byte with the `SS:` override.
Pinned QEMU proved that equivalent for its exact run because DF arrived clear,
but it left a path-sensitive assumption in the FPGA experiment.  The v2 patch
keeps `CLD` and obtains the one extra prefix byte by shortening `mov ecx,5`:

```text
66 b9 05 00 00 00     mov ecx,5
    ->
66 6a 05 66 59        push dword 5; pop ecx

66 67 c5 75 10 fc f3 66 67 a5
    ->
66 67 8b 75 10 fc 36 f3 66 67 a5
```

The 32-bit push and pop have equal width, so the stack is unchanged at the next
instruction.  The complete replacement is fixed-length, matches once at file
offset `0x12f0`, and is implemented by the hash-locked
`patch_cwsdpmi_v2.py`.

| v2 artifact | SHA-256 |
|---|---|
| `CWSDPMI_PATCH_V2.EXE` | `257f7816f9a5569368903c613bd61e333ae4b82260171f92c4ee3d83b957c3b4` |
| clean `qk_td_cwsdpmi_patch_v2.vhd` | `1204ede290e2a93b860fb2fca24e9c1211a4d871073a9096bf512fe535e3b97a` |
| QEMU result `QCONSOLE_V2_QEMU.LOG` | `d6a7781957fa9d997bb1e5406aa019d9459bc958948d99c6ea2addf9e49824de` |

The EXE was copied back out of FAT and compared byte-for-byte before testing.
Pinned QEMU 8.2.2 (`-cpu pentium`, 32 MiB) completed the exact 969-frame
workload and produced the 36-byte record:

```text
969 frames   2.5 seconds 382.6 fps
```

The clean v2 disk passed the board-side no-result precheck and was deployed
in-place (the board had only 12 MiB free).  The `ven-quake-cwsv2.service` run was
stopped after about four minutes when its normal real-mode round trip was still
being misclassified as a terminal exit.  It produced no result and is neither a
pass nor a proof of a second defect.

## Selector-faithful workaround

Both earlier patches intentionally avoided loading DS.  They therefore did not
reproduce the full semantics of `LDS`: the following `REP MOVSD` normally reads
through the selector installed by the instruction.  The final v4 patch performs
both loads with instructions supported by the deployed image and keeps every
address fully 32-bit:

```text
66 67 8b 75 10        mov esi,ss:[ebp+0x10]
67 8e 5d 14           mov ds,ss:[ebp+0x14]
```

Four bytes are recovered without changing executable length: `mov ecx,5`
becomes a width-matched `push dword 10; pop ecx`, `mov edi,ebp; add edi,4`
becomes `lea edi,[ebp+4]`, and ten `MOVSW` iterations replace five `MOVSD`
iterations.  Source/destination addresses, final ESI/EDI, zero ECX, DS, clear
DF, saved registers, and stack depth match this fault-free workload path.  The
hash/context-locked implementation is `patch_cwsdpmi_v4.py`; v3 is retained only
as the intermediate audit trail and must not be deployed.

| v4 artifact | SHA-256 |
|---|---|
| `CWSDPMI_PATCH_V4.EXE` | `749b94dc3fd5234800e81073d1a6a8cccce259bed54ea38198fe36c99572d35d` |
| clean `qk_td_cwsdpmi_patch_v4.vhd` | `4af49c172426f7588bd2697c3208d94803abddf22b570f932e62f126193a6891` |
| patcher `patch_cwsdpmi_v4.py` | `2927bdd78b8c21c21228085fd92df82e0feabc2bea8d24b0f342a6a2ead072c` |

Pinned QEMU 8.2.2 completed v4 with the exact 36-byte result
`969 frames   2.5 seconds 394.0 fps`.  The original unpatched executable was
also restored into a clean deployment disk, round-tripped byte-for-byte, and
independently completed 969 frames under the same oracle:

| original-path artifact | SHA-256 |
|---|---|
| clean `qk_td_cwsdpmi_original.vhd` | `616d7c7ebf03b00b6c2031e1e81733e324adb859d91707dd3bf0f6772b2b50e2` |

The v4 FPGA run was `ven-quake-cwsv4.service`.  It crossed the old LDS location,
reached Quake protected code around EIP `0x4dfe5`, and continued issuing disk
reads after an early DPMI real-mode round trip.  It ultimately returned to a
sustained DOS/BIOS idle loop without creating the result.  The final daemon log
records `reads=582` followed by 258 seconds with no disk activity; independent
live samples remained in real mode with `CR0=0x60000010` and timer IRQs still
advancing.  The exact result checker reported `QUAKE TIMEDEMO NOT COMPLETE`, and
the stopped disk retained the clean SHA-256 `4af49c...a6891`, proving that no
partial or stale result had been written.  The preserved negative-result log is
`quake_cwsv4_fpga_failed.log`, SHA-256
`3eb11d29775507b37e4925e416d37cbb3947241d16ee60bce8e3b65b1f06ae6c`.

Thus a selector-faithful binary substitution is still only a discriminator, not
an FPGA workaround pass.  The source-level atomic LDS implementation and the
unpatched disk remain the authoritative next experiment; only the exact
969-frame record closes the workload.

## RTL repair status

The actual RTL repair accepts every legal C4/C5 and 0F B2/B4/B5 memory form and
reuses one `S_SEGLD` descriptor transaction.  Descriptor selection, table
bounds, type/privilege/presence validation, and the success predicate are each
computed once.  Protected far-pointer loads suppress ordinary `S_EXEC` GPR
writeback and commit the offset plus hidden segment cache only on that shared
success event; a fault commits neither destination.

Verification from the exact rebuilt RTL is green:

- five-profile fatal lint matrix: `LINT-GATE-OK`;
- `pseg`: exact `66 67 C5 75 10` from a 16-bit protected CS, 90 QEMU/RTL
  records equivalent;
- `pdescprec`: not-present LDS descriptor leaves poisoned ESI unchanged, 2,568
  QEMU/RTL records equivalent;
- fast gate: 98/98 functional programs and all 20 cycle/throughput bands pass.

The fresh full Vivado build completed in `fpga_run_20260823_lds2`; its deployable
binary has SHA-256
`013396318e9c385b80c36d43422fa5795c3c50c65615126082ca5ff302eda4b9`.
It was deployed with the unpatched clean disk. Silicon executes beyond the old
`0018:00001105` LDS location and reaches Quake protected code, so the original
decode/atomic-commit blocker is closed. The full workload still fails later:
direct capture shows vector 14 after deterministic stack corruption, and a final
clean 600-second run produced no timedemo record. The disk retained SHA-256
`616d7c7ebf03b00b6c2031e1e81733e324adb859d91707dd3bf0f6772b2b50e2`.

Current evidence, uncertainty boundaries, and proposed fixes are in
`../quake_lds_repaired/README.md`. The workaround images in this directory
remain diagnostic artifacts; none is an FPGA Quake pass.
