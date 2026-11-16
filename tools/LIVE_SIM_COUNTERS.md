# Passive Live Simulator Counter Reader (`tools/live_sim_counters.py`)

`tools/live_sim_counters.py` samples compiled C++/Verilator performance counters
from a running `ao486sim_ven` process via read-only `/proc/<pid>/mem` without
rebuilding, restarting, pausing, `ptrace`-stopping, or writing to the simulator.

> **Diagnostic Scope & Physical Baseline (`c0e3fe43`, 2026-11-14):** Bracketed
> `/proc/<pid>/mem` reads are non-invasive simulator diagnostics, not atomic
> snapshots or official gameplay IPC measurements. Current verified physical DOS
> Quake gameplay IPC on **RK-XCZU15EG-F** release image **`c0e3fe43`** (`161`
> defines, `40.264133 MHz` STA-signed-off, `cycle_mode = 1'b1`) is
> **`0.515778001` total U+V** (`0.397847833` primary/U-only, counters include
> `REP`-element retirement) across cycles **`28,696,827,616–32,989,404,795`**.

---

## Preparation & Read-Only Sampling

1. **`prepare` (ordinary user, against the live binary's exact private `obj_dir`):**
   Pins the running executable, generated model header layout, and compiler
   dependencies into `layout.json` under `/home/yukidama/external/tmp`. Omit
   `--board-header` when the target build does not include `board_axi_memory.h`.
2. **`read` (read-only `/proc/<pid>/mem`):**
   Verifies process executable identity and start-time epoch, reads counter
   partitions inside a bounded `<= 16`-clock simulator bracket (failing with
   exit `2` rather than stopping the target if a bracket tears), and writes JSON.
   Host `yama/ptrace_scope` policy may require `sudo` for `read` only; never
   weaken host kernel `ptrace` settings.

```sh
export TMPDIR=/home/yukidama/external/tmp

python3 -B tools/live_sim_counters.py prepare \
  --obj /home/yukidama/external/tmp/ventium-pc-sim/obj_dir_ven_cand \
  --binary /home/yukidama/external/tmp/ventium-pc-sim/obj_dir_ven_cand/ao486sim_ven \
  --board-header /home/yukidama/github/ventium/ao486-sim/ven/board_axi_memory.h \
  --out "$TMPDIR/live-counter-layout"

python3 -B tools/live_sim_counters.py read \
  --layout "$TMPDIR/live-counter-layout/layout.json" \
  --pid ACTUAL_SIM_PID \
  --out "$TMPDIR/live-sample-1.json"
```

### Accounting Notes

- Difference two samples (`sample-2` minus `sample-1`) from the **same PID,
  layout, and reset epoch**; counter families overlap (e.g. L1 fill waits vs.
  outer memory transport residency) and must not be summed as disjoint shares.
- Non-monotonic fields (such as FP FIFO timestamps) are intentionally excluded.
- Note on platform L2 counters: legacy unbypassed `ao486` simulations expose the
  32 KiB platform `l2_cache` counters, whereas physical release profile
  `c0e3fe43` bypasses the outer `ao486` L2 data path in favor of full P5 8 KiB
  L1 caches driving the 16-slot posted DDR4 bridge (`ven_ddram_axi_posted.sv`)
  with CAM read-after-write hazard bypass.

---

## Host Unit Tests

Seven host unit tests (`tools/test_live_sim_counters.py`) verify layout bounds,
torn-bracket detection, mismatched binary/header rejection, PIE symbol
resolution, and read-only child-process sampling without launching RTL:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s tools -p test_live_sim_counters.py -v
```
