# KV260 runtime: loading the Ventium PL on a live board

This is the **verified-on-silicon** recipe for programming the Ventium full-SoC
bitstream onto a running Kria KV260 (Ubuntu 24.04) and bringing the core up. It
was used to achieve first light on 2026-06-13:

```
Ventium SoC: Pentium (P54C) core alive on KV260
ven_soc: isa-debug-exit after 54 io
```

`ventium.dts` here is the runtime device-tree overlay (compile with
`dtc -@ -I dts -O dtb -o ventium.dtbo ventium.dts`). It has exactly two
fragments — **no `reserved-memory` fragment** (see gotcha 2):

- `fragment@0` → `&fpga_full`: `firmware-name = "ventium.bit.bin"` + the four PL
  resets. dfx-mgr programs the bitstream from this name.
- `fragment@2` → `&amba`: `clocking0` (pl0 = 40 MHz), `afi0` (HPC0 128b / HPM0 32b),
  and `ventium-soc@a0000000` (the AXI-Lite control slave; `generic-uio` for the
  future IRQ path).

## Package layout (`/lib/firmware/xilinx/ventium/`)

dfx-mgr derives the bitstream name from the **directory** name, so the files must be:

| file | note |
|---|---|
| `ventium.bit.bin` | bitstream; name **must** match the dir (`ventium`). `bootgen -process_bitstream bin` from a **compressed** `.bit` (`BITSTREAM.GENERAL.COMPRESS TRUE`). |
| `ventium.dtbo` | compiled from `ventium.dts`; `firmware-name = "ventium.bit.bin"`. |
| `shell.json` | `{"shell_type":"XRT_FLAT","num_slots":"1"}` |

## Load procedure

```sh
# carveout must be reserved at boot (boot-partition user-override.dtb) AND
# cma must fit — patch boot.scr.uimg cma=800M -> cma=256M (see gotcha 1).
sudo xmutil unloadapp                 # drop the auto-loaded k26-starter-kits
sudo xmutil loadapp   ventium         # DMA-heap programming path (safe at 6.5 MB)
# the dtbo sets 40 MHz; belt-and-suspenders if not relying on it:
sudo busybox devmem 0xFF5E00C0 32 0x01011900   # pl0 div=25 -> 40 MHz

# verify the core is alive (IDENT is at +0x7C, NOT base):
sudo busybox devmem 0xA000007C        # -> 0x56544D43  ("VTMC")

# first light: stage F2 firmware, boot the core, COM1 banner + clean exit:
sudo ven_soc_app /usr/local/share/ventium/psocfw.bin 0xF0000 0x0 0x000FFFF0 --sys
```

## Gotchas (each cost a board hang during bring-up)

1. **`cma=800M` vs the carveout.** Canonical's `boot.scr.uimg` sets `cma=800M`;
   with our 256 MiB carveout at `0x4000_0000` reserved, CMA reservation fails
   (`CmaTotal: 0`) and every FPGA load dies `-ENOMEM`. Patch the boot script to
   `cma=256M` (extract `tail -c +73`, `sed`, repack with `mkimage -A arm64 -T script
   -C none`). Both the carveout **and** `CmaTotal: 262144 kB` must show after boot.
2. **No `reserved-memory` fragment in the runtime overlay.** The carveout is
   reserved at boot by `user-override.dtb`; a second `/reserved-memory` + `ranges`
   in the runtime overlay collides → `create_overlay err=-22` and a half-applied
   changeset that can't revert (`-19`), leaving `region0` stuck "already has overlay
   applied". Recover without reboot: `xmutil loadapp k26-starter-kits; xmutil
   unloadapp; xmutil loadapp ventium`.
3. **Never program via raw configfs.** `cat ventium.dtbo > .../overlays/ventium/dtbo`
   makes the kernel firmware loader `vmalloc` the 6.5 MB bitstream buffer; the
   zynqmp FPGA-manager DMA path then hits `kernel BUG at scatterlist.h:115`
   (`virt_addr_valid`), killing a CPU and wedging mmc. Only `xmutil loadapp` (libdfx
   `dfx_package_load_dmabuf` → `/dev/dma_heap/reserved`) is DMA-safe at this size.
4. **FSBL leaves pl0 at 100 MHz** (`PL0_REF_CTRL = 0x01010A00`, div 10). Set div 25
   (`0x01011900`) before any PL access if not relying on the overlay's `clocking0`.
5. **`mmc1: Timeout waiting for hardware interrupt`** after a JTAG `rst -system` or a
   kernel BUG → the SD card was left mid-transaction. A **cold power cycle** clears
   it; JTAG reset does not.
