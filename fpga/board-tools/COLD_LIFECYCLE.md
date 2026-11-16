# Cold-Boot Ownership, Reset & Posted-DDR4 Drain Lifecycle

This note documents the board-side supervision, reset, and posted-DDR4 drain lifecycle for cold-booting physical workloads (CoreMark, FreeDOS/Quake, and Windows 95 OSR2) on **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`).

> **Current Hardware Qualification (`c0e3fe43`, 2026-11-14):** Image **`c0e3fe43`** (`40.264133 MHz` STA-signed-off, `161` defines, `cycle_mode = 1'b1`) passes all three standard-suite gates from cold reset on physical hardware. Verified interior DOS Quake gameplay IPC is **`0.515778001` total U+V** (`0.397847833` primary/U-only, including `REP`-element retirement) across cycles **`28,696,827,616–32,989,404,795`**. Host lifecycle tests validate supervision invariants only and do not qualify CPU correctness or performance.

---

## 1. Hardware Reset, DDR4 Reservation & External-Drain Contract

1. **Reserved Guest DDR4 (`0x6000_0000–0x6FFF_FFFF`):** Linux must reserve the 256 MiB `no-map` aperture before any PL programming or daemon startup (`HOW_TO_RUN_FPGA.md`).
2. **Posted DDR4 Survives Guest Reset (`ven_ddram_axi_posted.sv`):** The 16-slot posted DDR4 write queue and CAM read-after-write bypass intentionally survive `soc_reset` so accepted AXI writes complete cleanly on `S_AXI_HP0_FPD` (`128b @ 100 MHz`) rather than tearing burst protocol. Before reprogramming PCAP, switching the MMCM divider (`ven_pll_clock.py`), inspecting final guest RAM/disk, or starting a new cold run, software **must** hold guest reset and verify external drain completion (`0x50440003`, matching `ven_posted_reset_guard.h` and hardware `pll_safe`).
3. **Cache & Counter Reset Semantics:** Asserting management guest reset drives `soc_reset`, initiating a full tag/LRU clear walk while `CPU_BUSY` blocks requests. Across cold boots without PCAP reprogramming, the debug bridge's cumulative **primary/U** counter persists while `ventium_top.retire_n` (**total U+V**, debug selectors `76/77`) resets to zero.
4. **Cold Admission Preflight (`ABI 5`):**
   - `ven_cold_clock.py` verifies held guest reset, reset `CR0` (`0x6000_0010`), cleared forensic freeze, unchanged retirement baseline, and a read-time-bounded **`39.5–40.5 MHz`** core clock over 5 seconds without writing any register.
   - `ven_board_probe.py prepare-cold` verifies those preconditions before any write, requests manual halt, clears/disables hardware breakpoints, and disarms forensic freeze comparators while keeping guest reset held.
   - Start passive VGA capture (`ven_record_stream.py`) and any hosted PS/2 service (`ven_ps2_service.py`) **before** releasing guest reset (`ven_board_probe.py run`), and require natural daemon exit so guest stdio/sector buffers flush before reading the closed disk image.

---

## 2. Systemd Service Ownership Guards (`fpga/board-tools/ven_cold_*.py`)

Stopping a board unit by name without checking `InvocationID` can accidentally kill a replacement run or reset hardware out from under another controller. The cold supervision helpers enforce strict invocation ownership:

- **`ven_cold_owners.py`:** Binds each managed unit's exact `Id`, `InvocationID`, and native `MainPID`. Every signal/stop re-verifies ownership before and after; closure requires `MainPID == 0` and zero remaining cgroup tasks (`TasksCurrent`). Unknown or replaced invocations are never adopted or killed.
- **`ven_cold_watch.py`:** Encloses MMIO/RAM mapping and startup-receipt publication inside the cleanup handler, treats `SIGTERM`/`SIGINT` as orderly stop requests, verifies native recorder exit, and reaps all owned workers before final debug/RAM inspection. On an ownership mismatch, it refuses to write reset or PLL registers and records an explicit failure receipt rather than fabricating `0` IPC.
- **`ven_cold_start.py`:** Verifies worker identities through watcher handoff and stops an admitted watcher first on startup failure, leaving an explicit `requires inspection` receipt without mutating clocks or resets from a partially owned state.

> **Supervision Caveat:** Systemd property reads and signals are not atomic transactions, and `SIGKILL`/power loss bypass Python `finally` blocks. Exclusive board ownership, unique unit names, and fresh reset/drain verification remain mandatory before every hardware run.

---

## 3. Host Regression Suite

Run the 36 host unit tests covering ownership binding, watcher cleanup, launcher failure handoff, and held-reset clock admission (uses mocked systemd/MMIO; touches no board state):

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s fpga/board-tools -p 'test_ven_cold_*py' -v
```
