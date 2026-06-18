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

## ✅ ROOT-CAUSED + FIXED: F4A blocker = `xchg ch,cl` (XCHG of two byte-halves of one reg)

**The bug:** `XCHG r/m8,r8` where both operands are byte-halves of the **same**
16-bit register (`xchg ch,cl`, `xchg ah,al`, …) only swapped ONE half. The
writeback (`core_gpr_wb.svh` K_XCHG) did two independent
`reg_merge(gpr_o[reg], …)` writes; when dst==src reg the second started from the
ORIGINAL `gpr_o`, discarding the first byte-write. So `xchg ch,cl` on `cx=0x0025`
gave `0x2525` (only ch←cl) instead of `0x2500` (ch↔cl).

**Why it broke F4A:** FreeDOS's INT 13h wrapper packs the cylinder with
`xchg ch,cl; ror cl,1; ror cl,1`. For **cylinder 0** the low byte is 0x00 so the
broken swap is harmless; for **any cylinder ≥ 1** the stale low byte corrupted
CL[7:6] → wrong cylinder (e.g. 37→293) → off-disk LBA → SeaBIOS rejects → the
kernel reset/retry-spins forever. Exactly the observed cyl-0-works / cyl-≥1-fails
boundary, and it never reached `ven_ide` (highest LBA stayed ~432).

**Fix:** in K_XCHG, when `q_dst_reg == q_src_reg`, CHAIN the second `reg_merge`
off the first's result (one write, both byte-halves swapped). Pure addition;
the cross-register path is unchanged.

**Validated (sim):** rebuilt `l1axi_kv_dos_q`, re-ran the KHI@cluster-4646
(cyl-37) repro → `ven_ide` now serves **LBA 37304** (was capped at 432), KHI's
sector loads correctly (`be1101ac` = its real code), and KHI **executes** at
`cs=2182` outputting `[ K H I - R A N`  (al=5b 4b 48 49 2d 52 41 4e). The
standing-goal F4A bug is fixed. (Pending: `make verify` regression + an
`xchg ch,cl` gate test for the coverage gap + a clean trace-off contiguous
`[KHI-RAN]` confirmation + commit.)

The SP wrap was a **red herring** for F4A; so was the earlier "stack-check loop
at `cs=10ef:0x108c`" (read against the wrong-size kernel's map). Evidence trail
that led to the XCHG instruction:

- **Symptom:** a `.COM` whose data is in **cylinder 0** EXECs fine from AUTOEXEC
  (`[KLO-RAN]` prints); a `.COM` whose data is in **cylinder ≥ 1** does NOT
  (`[KHI-RAN]` never prints). The kernel spins issuing INT 13h **resets (AH=00),
  status (AH=01), never a read (AH=02)** → highest LBA stays ~432. Deterministic
  (sim confirmed deterministic: `ven_rtc` is fixed-seed; `l1axi_kv_dos_q` is NOT
  X-randomized) ⇒ a real CPU bug.
- **Bisection (reliable, fixed grep + verified clusters):** `KLO@cluster36`→
  dataLBA 424→**cyl 0 WORKS**. `KHI` fails at cluster 200 (LBA 1736, cyl 1), 256,
  512, 4500 — i.e. **fails whenever dataLBA ≥ 1008** (`cyl = LBA/(16·63) ≥ 1`).
  Threshold is the **cylinder-0→1 boundary (LBA 1008)**, NOT the cluster number,
  NOT the FAT-sector (KHI@200 is FAT sector 0 and still fails).
- **Reliable repro = the MAP-MATCHING 46290 kernel** (`unzip ke2045_86f16.zip
  bin/kernel.sys` → `verif/freedos/f4a/k46.sys`). It reproduces the bug AND its
  layout matches `kwc8616.map`, so symbols are trustworthy. INT handlers at
  `cs=00d9` (load base 0x60). Boot reaches AUTOEXEC ~cyc 70M (the early "stall at
  cyc 11.6M" was just checking before SeaBIOS POST finished — NOT a hang).
- **Disk path located in the 46290 runtime dump** (`/tmp/sim_lowmem.bin`, linear =
  phys): the kernel's INT 13h wrapper (`fl_rw`) is at **linear ~0xfca6** —
  `mov ah,2` (read) @0xfc9c → common path @0xfca6 does the **CHS packing**
  (`mov cx,[bp+0xc]; cmp ch,3; ja…; xchg ch,cl; ror cl,1…` = pack cyl into CH +
  CL[7:6] + sector). The **LBA→CHS conversion** (`cyl = LBA/1008`, head, sector)
  is in the *caller* of `fl_rw` — that conversion (or the cyl≥1 CHS packing) is
  where the core diverges. (`int 13h` cluster: linear 0xfc7a/88/c8/e2/f9/0xfd11.)

## NEXT STEPS

1. **Pin the instruction (on the 46290 kernel).** Either (a) sentinel-armed
   per-commit trace with `VEN_F4A_CYC_LO` ≈ the cyl-1 read cycle, then map the
   diverging `cs:eip` through `kwc8616.map`; or (b) a **minimal standalone
   real-mode test** (loaded via `--image`, like the SoC gates) that runs the
   LBA→CHS math + CHS-packing for an LBA ≥ 1008 and checks the result — fully
   deterministic, no FreeDOS boot, no recovered-kernel disasm. (b) is now the
   cleaner path given the cylinder-boundary characterization. Note: `make verify`
   div16/div32 pass, so the bug is likely NOT a plain DIV — suspect the CHS
   pack/`xchg/ror` path or a cyl≥1-specific branch.
2. Fix it; re-run the `fdhi.img` KLO/KHI test until `[KHI-RAN]` prints.
3. Keep the SP-wrap fix (correct + safe); `make verify` stays byte-identical.
4. **Pre-existing regression:** `tx_fprem` (FPREM) — broken by the R3
   `fpu_writeback.sv` extraction (`de67eca`), the only `make verify` failure,
   independent of the above. FPREM is on the Quake render path.
5. After F4A EXEC works: QUAKE.EXE load → CWSDPMI → PAK0.PAK → first mode-13h frame.
6. [#41 F5] tyrquake interactive — PARKED (board-only synth fetch-bit[2] bug).

## Harness notes (STABLE, in-repo — survives `/tmp` clears)

- **`verif/freedos/f4a/`** holds everything now (`/tmp` was cleared twice, losing
  the original 70142-B kernel + earlier disks; do NOT keep harness state in /tmp).
  - `build_f4a_disk.sh` — rebuilds `fdhi.img` (KLO low + filler + KHI high).
    Selectable: `KERNEL=<path>` (default `ventium-refs/freedos/kernel.sys`; use
    `k46.sys` = the map-matching 46290 kernel) and filler size via `filler.dat`
    (set its byte size first to place KHI at a target cluster/cyl; the script
    prints/verifies KHI's start cluster + dataLBA + cyl).
  - `k46.sys` (46290, map-matching), `kwc8616.map` (in /tmp/kmap or re-extract).
- **Markers:** `KLO.COM`/`KHI.COM` print `[KLO-RAN]`/`[KHI-RAN]` to port 0xE9
  (→ sim stdout); KLO also emits a **0x07 sentinel** that arms the f4a trace.
  GREP THEM LITERALLY (`grep -c KLO-RAN`) — `[K[LH]I-RAN]` does NOT match `KLO`.
- `tb_main` debug (uncommitted): 0xB8000 VGA text dump at `--dos` exit;
  `VEN_F4A_ARM_LBA` / `VEN_F4A_CYC_LO/HI` per-commit `cs/eip/GPR` trace; the
  0x07-sentinel arm (guarded by `#ifdef VEN_DOS_MODELS`).
- Sim run (EXE `obj_dir_l1axi_kvdosq/tb_ventium`): `--image bios.bin --dos --disk
  verif/freedos/f4a/fdhi.img --no-trace --quiesce 30000000 --max-cycles 120000000
  --max-insn 250000000`, `VEN_IDE_LOG=1`. AUTOEXEC ~cyc 70M; ~8 min wall. **Wait
  for `SIM_EXIT` before judging** (POST is INT-less until ~cyc 30M). Use clean
  grep-on-logfile waiters (NOT `pgrep` of a name in the waiter's own cmdline →
  self-match hang) and a *fresh* logfile name (rm/recreate races the waiter).
