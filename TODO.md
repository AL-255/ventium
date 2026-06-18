# Ventium — Status & TODO

_Last updated: 2026-06-17_

## Current focus: F4A — first DOS Quake frame on the KV260 (under FreeDOS)

DOS Quake = DJGPP/go32 + CWSDPMI, booted under FreeDOS via SeaBIOS on the
PS-assisted Ventium SoC (real PL core + A53 peripheral models / soft devices).

---

## ★★★ MAJOR RESULT (this milestone): F4A blocker ROOT-CAUSED + RTL-confirmed

**Symptom:** EXEC of a **high-cluster** file (VGATEST.COM ~cluster 4500, QUAKE.EXE)
fails with `Error reading from drive C: ... unknown command given to driver
(A)bort,(I)gnore,(R)etry,(F)ail?`, then idles at the prompt. Low-cluster `.COM`s
(M1/M2/M3) EXEC fine. FreeDOS boots to `C:\>`; the soft-VGA teletype renders the
full boot banner correctly.

**Root cause — real-mode stack pointer is NOT masked to 16 bits in the core.**
- The error is kernel `E_CMD` (code 3, `hdr/device.h:62`) from `Genblkdev`
  (`dsk.c:517`) — a kernel block-device request whose command/category field is
  **corrupted**. It is NOT an IDE/ATA abort and NOT a go32/CWSDPMI problem:
  instrumented `VEN_IDE_LOG` shows the **board IDE trace == Verilator sim IDE
  trace EXACTLY** (226 clean `CMD 20` reads to LBA 496 = AUTOEXEC.BAT, highest
  LBA 496, **zero real aborts**, no high-cluster read ever issued). ⇒ **not
  silicon-specific** ⇒ a deterministic, sim-debuggable CPU bug.
- Traced (LBA-armed per-commit trace) to the **DOS reentrant interrupt-stack
  trampoline** (LGROUP `cs=0070`: `mov ss,[6]; mov sp,[2]=0; push…; call far[bx]`),
  which switches to **SP=0** (= top of a 64 KB internal stack) on every reentrant
  DOS/disk call.
- **RTL confirmed:** `core_bus_driver.svh` computes every stack address as
  `seg_base[SG_SS] + (gpr[R_ESP] - q_w)` and `core_store_useq.svh`/`core_exec.svh`
  write back `gpr[R_ESP] <= gpr[R_ESP] ± q_w` — **full 32-bit ESP, no 16-bit
  wrap**. At SP=0 a push computes `ss_base + 0xFFFFFFFE` = **`ss_base − 2`**
  (should be `ss_base + 0xFFFE`, top of the segment) → it scribbles *below* the
  stack segment, corrupting adjacent kernel data → bad block request → `E_CMD`.
- **Why only high-cluster EXEC:** boot / SeaBIOS / low-cluster `.COM`s keep SP
  well above 0 and never wrap; the high-cluster EXEC path drives the reentrant
  DOS stack down to SP=0.
- The core HAS `real_mode` (=`sys_mode && !creg0[0]`) and masks 16-bit EA, but
  never applies it to the **stack** pointer.

---

## TODO

### 1. [NEXT] Implement the real-mode stack-wrap fix (~35 sites / 7 files)
Gate everything on `real_mode` (identity when 0 ⇒ user-mode `make verify` stays
byte-identical by construction; only real-mode stack wraps change).

- Add 2 module-scope fns in `core.sv` near `seg_real`:
  - `stk16(off)   = real_mode ? {16'd0, off[15:0]} : off`        (address offsets)
  - `stk16wb(new) = real_mode ? {gpr[R_ESP][31:16], new[15:0]} : new`  (ESP writeback; preserves ESP high word)
- **Address** sites (wrap the esp-offset arg with `stk16`):
  `core_bus_driver.svh` L34, 36, 68, 71, 79, 80, 109, 120, 165, 177, 247, 258;
  `core.sv` `st_addr` L3257, 3266, 3270, 3274 (+ any other `st_addr=gpr[R_ESP]-…`
  in the push if/else ~3250–3300).
- **ESP/EBP writeback** sites (wrap the new value with `stk16wb`):
  `core_store_useq.svh` L57, 86, 87, 89, 130, 131, 165, 180;
  `core_exec.svh` L165, 168, 703, 710, 798, 802;
  `core_seg_ljmp.svh` L155, 181; `core_rmint.svh` L34, 66;
  `core_iret.svh` L41, 60, 80; `core_int_deliver.svh` L172, 178, 183.
- **CRITICAL:** mask an address AND its matching writeback together — a
  half-masked op = inconsistent push/pop = worse than the bug.
- Cross-priv / `int_deliver` sites (214/234/172/178) are PM (real_mode=0) ⇒
  `stk16` is identity there; safe.

### 2. [VERIFY] Regression the fix
- `make verify` → 77/77 byte-identical (guaranteed by the `real_mode=0` guard).
- SeaBIOS / FreeDOS SoC gates pass.
- `VEN_F4A_ARM_LBA=496 obj_dir_l1axi_kvdosq/tb_ventium --dos --disk
  /tmp/quake_safe.img …` must now show a **high-LBA read of VGATEST's cluster
  (~36000)** replacing the `E_CMD` retry loop (= the fix works).

### 3. [BOARD] Respin + deploy + retest on the KV260
- Rebuild the bitstream with the fix (respins are expensive — exhaust sim first).
- Deploy + re-run the F4A flow with `--soft-vga` + `kms-draw --vga13`.
- VGATEST should render its mode-13h grayscale gradient on the monitor.

### 4. [F4A] Continue DOS-Quake bring-up to the first frame
After EXEC works: QUAKE.EXE load → CWSDPMI real→PM/paging → PAK0.PAK load
(18 MB PIO) → Quake init (`Alpha_Init` ~1 B insns) → first mode-13h frame at
0xA0000. Watch for the userspace-path silicon fetch bug ([[f4-board-memcpy-halt]]).

### 5. [#99 Soft VGA] Finish validation
PS-side INT 10h handler in `ven_soc_app` (`--soft-vga`): teletype banner renders
(validated). Mode-13h set + DAC + framebuffer-capture path is implemented but the
gradient render is blocked by the high-cluster EXEC bug above — re-validate once
VGATEST can run.

### 6. [#41 F5] tyrquake interactive Quake — PARKED
Board-only synthesis fetch hazard (RTL sim clean; "instruction-fetch address
bit[2] dropped" — see [[fetch-addr-bit2-drop]] / [[quake-freeze-fetch-path]]).
Distinct from the F4A bug above (that one IS sim-reproducible).

---

## Debug tooling added this milestone (in this commit)
- **`ven_soc_app --soft-vga`** (`sw/ps/ven_soc_app/ven_soc_app.c`): PS-side INT 10h
  VGABIOS — trapped via a C000:0 stub + port 0x2E0; teletype → 0xB8000, set-mode-13h
  → 0xA0000, DAC via 0x3C8/0x3C9. Plus `--extmem-kb N` (CMOS extended memory for
  CWSDPMI's heap; DOS Quake needs `--extmem-kb 64512`).
- **`ven_ide` diagnostics** (`sw/ps_periph/ven_ide.c`): `VEN_IDE_LOG` now logs every
  ATA command + flags aborts; `g_ven_f4a_arm` global armed by `VEN_F4A_ARM_LBA`.
- **f4a instruction trace** (`verif/tb/tb_main.cpp`): per-commit `cs/eip/GPR` trace
  armed by `VEN_F4A_ARM_LBA` (the disk LBA that starts the trace), optionally
  windowed by `VEN_F4A_CYC_LO`/`VEN_F4A_CYC_HI`. Default-off ⇒ byte-identical.

## Repro recipes
- **Board (fast, ~secs):** `ven_soc_app_q --sys --dos --soft-vga --bios seabios.bin
  --disk quake_safe.img --extmem-kb 64512` + `kms-draw --vga13` (board @ 40 MHz).
- **Sim (faithful, ~20 min boot):** `obj_dir_l1axi_kvdosq/tb_ventium --image
  bios.bin --dos --disk /tmp/quake_safe.img --no-trace --quiesce 8000000
  --max-cycles 4000000000 --max-insn 250000000`.
- Disk built by `/tmp/build_safe.sh` (28 MB, CHS 56/16/63, FAT16 spc=8, `-r 32`).
