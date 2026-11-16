# `test386.asm` — External x86 CPU Differential Prefix Gate (`verif/external/test386/`)

[`test386.asm`](https://github.com/barotto/test386.asm) (GPL-3.0, standalone external test image — never linked into Ventium RTL; upstream sources + `COPYING` vendored in `ventium-refs/09-external-cpu-tests/test386.asm/`) is an independently authored 64 KiB bare-metal BIOS CPU test suite (`0xFFFFFFF0 → F000:0045`) used by PCem/86Box to exercise addressing modes, flags, bit/string ops, protected mode, paging, and Virtual-8086 mode.

## Running

```sh
bash verif/external/test386/run-test386-gate.sh [MAXI]   # default MAXI=1500
```

- **Oracle:** Pinned `qemu-system-i386 -bios test386.bin` (`gen_trace.py --system` single-step; `test386.sys.vtrace.golden` holds the 1,500-instruction reference prefix).
- **DUT Vehicle:** Standalone `ventium_soc` (`tb_soc`, `soc_en=1`), which acknowledges early diagnostic POST `OUT DX,AL` writes (whereas bare `ventium_top --system` without `--cosim` halts on undecoded port I/O). Note that `ventium_soc` is an early simulation wrapper distinct from the deployed `ao486_MiSTer`-integrated SoC (`rtl_ven_soc.f` / `ao486-sim` / `c0e3fe43` on RK-XCZU15EG-F).
- **Comparator:** `verif/diff/compare.py --mode func` per retired instruction (`pc`, `eflags`, GPRs, selectors, `cr0..cr4`).
- **Prebuilt Image:** `test386.bin` is committed so `nasm` is not required at test time (to rebuild from `ventium-refs/`: `nasm -i./src/ -f bin src/test386.asm -w-all -o test386.bin`).

Verified `EQUIVALENT` across the first `60,000` instructions (`1.5k` / `30k` / `60k` prefix checks); deeper runs require deterministic PIT/device alignment once `test386` enters platform-timer checks.
