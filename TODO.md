# Ventium — Status & TODO

_Last updated: 2026-06-18_

## Current focus: F4A — first DOS Quake frame on the KV260 (under FreeDOS)

DOS Quake = DJGPP/go32 + CWSDPMI, booted under FreeDOS via SeaBIOS on the
PS-assisted Ventium SoC (real PL core + A53 peripheral models / soft devices).

---

## DONE this session: real-mode stack-pointer 16-bit wrap fix (committed `1a64426`)

A genuine RTL bug, found + fixed + verified — **but it turned out NOT to be the
F4A blocker** (see below).

- **Bug:** in real mode the stack pointer is 16-bit, but the core computed every
  stack address and ESP writeback from the full 32-bit ESP with no wrap. At SP=0 a
  push computed `ss_base+0xFFFFFFFE` = `ss_base-2` instead of `ss_base+0xFFFE`
  (top of the 64K SS segment). RTL-confirmed in `core_bus_driver.svh` + the
  centralized `core_gpr_wb.svh`.
- **Fix:** `stk16()` helper masks a stack-address offset to 16 bits when
  `real_mode`; one post-mask wraps the ESP writeback. Gated on `real_mode`
  (=`sys_mode && !CR0.PE`) ⇒ pure identity in user/PM ⇒ `make verify` byte-identical.
- **Verified working:** a sim trace shows the DOS reentrant trampoline now wraps
  SP `0xfffe → 0xfffc → …` (zero `0xffffffff` underflows). SeaBIOS POSTs; a
  low-cluster `.COM` EXECs fine from AUTOEXEC.

## STILL OPEN: the actual F4A blocker — high-cluster file EXEC fails

The SP wrap was a **red herring** for F4A. The real bug is separate and present
even with the fix:

- **Symptom:** a `.COM` at a **low cluster** EXECs fine from AUTOEXEC
  (`[KLO-RAN]` prints); a `.COM` at a **high cluster** (~4500, after an 18 MB
  filler — mirrors VGATEST/QUAKE.EXE) does NOT (`[KHI-RAN]` never prints).
  Deterministic, cluster-number-dependent ⇒ a real CPU bug.
- **Where it fails (trace, sentinel-armed at the KHI EXEC):** the kernel's
  high-cluster file read fails in the **read-SETUP, before INT 13h AH=02** — it
  **never issues the high-LBA read** (highest LBA stays ~432, the low region).
  Instead the kernel spins in a disk-retry loop at `cs=10ef:0x108c–0x1098`
  issuing INT 13h **resets (AH=00) but no reads (AH=02)**. The original 70142-byte
  kernel surfaced this as `E_CMD`/"unknown command"; this 48856-byte kernel spins
  in reset/retry.
- **Localized (kwc8616.map + sentinel-armed trace):** the spin is in the kernel's
  **`LBA_Transfer_` / `LBA_to_CHS_`** region (TGROUP link `020b:0e3a`/`0ee2`; the
  failing loop is TGROUP offset `~0x108c`, runtime `cs=10ef:0x108c`). The loop
  scans `bx` upward by 2 (~1871 iterations for the high sector ~36000) with
  `cx=0`, `ax=0x2030`, never issuing INT 13h AH=02 → then reset/retry forever.
  So the bug is in the **LBA→CHS conversion / transfer-split loop** for a high
  sector. NOT the SP wrap (ruled out), NOT the disk (low-cluster works), NOT
  silicon (sim-reproducible). The exact faulting instruction still needs the
  correct kernel disassembly (kernel.sys file layout ≠ link paragraphs — find the
  TGROUP/HMA_TEXT file offset, then `ndisasm -b16` the `0x108c` loop).

## NEXT STEPS

1. **Pin the high-cluster read-setup bug.** Disassemble the kernel loop at
   `cs=10ef:0x108c–0x1098` (map via the kwc8616.map link addrs + the runtime load
   base) to identify the function; trace the cluster→sector/CHS computation for a
   high cluster vs a low one and find the diverging value. Capture needs a bigger
   trace budget OR `VEN_F4A_CYC_LO` set to the KHI-EXEC cycle (~70M) — the 400k
   per-commit budget runs out in the ~6M-cycle COMMAND.COM reload gap after KLO.
   Alternative: cluster-threshold bisection (vary the filler size) to find the
   failing bit-width.
2. Fix that bug; re-run the `fdhi.img` KLO/KHI test until `[KHI-RAN]` prints.
3. Keep the SP-wrap fix (it's correct + safe); `make verify` stays byte-identical.
4. **Pre-existing regression to address:** `tx_fprem` (FPREM) — broken by the R3
   `fpu_writeback.sv` extraction (`de67eca`), the only `make verify` failure,
   independent of the above. FPREM is on the Quake render path.
5. After F4A EXEC works: QUAKE.EXE load → CWSDPMI → PAK0.PAK → first mode-13h frame.
6. [#41 F5] tyrquake interactive — PARKED (board-only synth fetch-bit[2] bug).

## Harness notes (rebuilt this session after `/tmp` was cleared)

- Original patched kernel `kwc8616.sys` (70142 B) + disk-build inputs were LOST
  with `/tmp`. Recovered `ventium-refs/freedos/kernel.sys` (48856 B, kwc8616
  build) + `COMMAND.COM` + the boot.asm VBR recipe (`build-freedos-hdd.sh`).
- `tb_main` additions (uncommitted debug): 0xB8000 **VGA text-screen dump** at
  `--dos` exit; `VEN_F4A_ARM_LBA` / `VEN_F4A_CYC_LO/HI` per-commit `cs/eip/GPR`
  trace; **0x07-on-port-0xE9 sentinel** arms the trace (a marker `.COM` emits it
  right before the instruction under study). FreeDOS console output goes via INT
  10h (no sim handler) ⇒ the screen is blank unless soft-VGA is present; use a
  port-0xE9 marker `.COM` for visible output in the sim.
- Repro disks: `/tmp/fdmin.img` (3 MB, boots + runs a low-cluster `.COM`),
  `/tmp/fdhi.img` (28 MB, spc=8, KLO low + 18 MB filler + KHI high — the repro).
- Sim run: `obj_dir_l1axi_kvdosq/tb_ventium --image bios.bin --dos --disk <img>
  --no-trace --quiesce 8000000 --max-cycles 150000000 --max-insn 250000000`,
  `VEN_IDE_LOG=1`. Boot reaches AUTOEXEC ~cyc 60M; ~10 min wall.
