# psoftvga — soft-VGA INT 10h unit test (task #99)

Bare-metal real-mode image that exercises the PS-side soft-VGA INT 10h handler
in `verif/tb/tb_main.cpp` (env-gated by `VEN_SOFTVGA`), the same way DOS Quake's
mode-13h init does, but without a full FreeDOS/CWSDPMI boot.

## Build
    make                       # -> psoftvga.bin (64 KiB -bios image)

## Run (needs the VEN_DOS_MODELS tb, e.g. l1axi_kv_dos_q)
    cd ../../../tb && make l1axi_kv_dos_q
    VEN_SOFTVGA=1 VEN_SOFTVGA_FORCE=1 \
      ./obj_dir_l1axi_kvdosq/tb_ventium \
      --image ../sys/tests/psoftvga/psoftvga.bin --dos \
      --no-trace --quiesce 2000 --max-cycles 30000000 --max-insn 5000000
    python3 vga13_to_ppm.py    # /tmp/sim_vga13.bin + .pal -> /tmp/sim_vga13.ppm

## Expected
- "soft-VGA INT10h installed (stub@C000:0, trap port 0x2e0)"
- 3 serviced INT 10h calls: AX=0013 (set mode 13h), AX=1012 (set palette), AX=0F00 (get mode)
- get-mode returns AL=0x13 -> the test takes the PASS path -> clean isa-debug-exit (AL=0)
- BDA mode=0x13, VGA13 dump = 63600 nonzero px (a rendered frame), palette = black/red/green/blue

## Env knobs
- `VEN_SOFTVGA`       — enable the PS soft-VGA INT 10h handler (default OFF; default build byte-identical)
- `VEN_SOFTVGA_FORCE` — install the C000:0 stub at boot instead of on the first IDE READ (for this disk-less test)

For a real DOS-Quake run, use `VEN_SOFTVGA=1` only (no FORCE): the stub installs
on the first ATA READ-SECTORS (POST done), and Quake's mode-13h init is serviced
by the PS instead of SeaVGABIOS.
