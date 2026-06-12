# KV260 microSD boot image (baremetal)

Builds a flashable microSD image that, on power-on, configures the FPGA with the
Ventium SoC bitstream and runs a bare-metal A53 bring-up app — **no PetaLinux
required**. The serial console (UART1, MIO36/37, 115200 8N1) shows the FSBL boot
log followed by the Ventium bring-up.

## Boot chain

```
SD card (FAT32) ─► BOOT.BIN
                     ├─ FSBL            (zynqmp_fsbl, A53-0)   configures PS, loads ↓
                     ├─ PMUFW           (zynqmp_pmufw, PMU)
                     ├─ ventium_kv260.bit (PL)                Ventium SoC into the fabric
                     └─ ven_boot.elf    (A53-0)               drives ven_soc_axil:
                                                              IDENT check → boot psocfw → console
```

`ven_boot.elf` (`ven_boot/ven_boot.c`) is the baremetal twin of
`sw/ps/ven_soc_app/ven_soc_app.c`. It runs in two tiers:
1. **IDENT smoke test** — reads the control slave at `0xA000_0000` and confirms the
   `VTMC` magic. This alone proves PL-configured + PS↔PL AXI alive + clocks running.
2. **F2 demo (best-effort)** — stages `psocfw` (the COM1-banner firmware) into the DDR
   carveout, boots the core in real mode, and routes its COM1 output to the console.
   Liveness is also reported via the RETIRE instruction counter.

## Build

```bash
# after an impl build (fpga/scripts/impl_kv260_soc.tcl) with OUTTAG=_f3:
fpga/sd/build_sd_image.sh _f3
# -> fpga/build/kv260_soc_impl_f3/sd/ventium_kv260_sd.img   (dd to a card)
#    fpga/build/kv260_soc_impl_f3/sd/boot/BOOT.BIN          (QSPI / manual copy)
```

Or point at explicit artifacts:
```bash
XSA=path/to.xsa BIT=path/to.bit OUT=outdir fpga/sd/build_sd_image.sh
```

Env knobs: `IMG_MB` (image size, default 128), `REUSE_SW=1` (skip FSBL/PMUFW/BSP
regen — valid only when the PS config is unchanged).

Tooling (Vitis 2025.2): `xsct` generates FSBL/PMUFW/BSP, `bootgen` packs BOOT.BIN,
`mtools` formats the FAT32 partition in-place (no root needed). The FSBL/PMUFW depend
only on the fixed PS config, so they are stable across PL revisions — only the `.bit`
changes.

## Flash

```bash
dd if=ventium_kv260_sd.img of=/dev/sdX bs=4M conv=fsync   # DOUBLE-CHECK /dev/sdX
```

Set the K26 SOM boot-mode switch to **SD**, attach the USB-serial console, power on.

## Note

There is no board in the dev loop, so this image is **built and structurally verified
but not hardware-tested**. It implements the gate-proven `ven_soc_axil` register
protocol; the Tier-1 IDENT check is correct by construction (a plain AXI read of a
constant register).
