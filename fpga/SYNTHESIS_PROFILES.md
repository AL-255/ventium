# FPGA Synthesis & Place-and-Route Profiles (`xczu15eg-ffvb1156-2-i`)

All current Ventium FPGA builds target **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`) using **AMD Vivado 2025.2**, full P5 8 KiB 2-way L1 I$/D$ caches (no outer L2, never `VEN_CACHE_HALF` or `VEN_IC_NARROWB`), mandatory **`U/V + system fast-pipe`** (`cycle_mode = 1'b1`), `40.000 MHz` core (`N = 25` boot divider on `MMCME4_ADV`) and `100.000 MHz` PS/HP0 AXI4 constraints.

> **Current Verified Physical Baseline (`c0e3fe43`, 2026-11-14):** Board-qualified `main` release image **`c0e3fe43`** (`161` defines, `retime_muxf_route_first`) closes post-route static timing at **`40.264133 MHz`** (`WNS = +0.164 ns`, `WHS = +0.010 ns`, `0` failing endpoints, `0` `>=85%` congestion hotspots, `171,819` LUTs / `50.35%`, `30,703` CLBs / `71.97%`, `39,520` FFs / `5.79%`) and passes all three physical standard-suite gates. Verified interior DOS Quake gameplay IPC is **`0.515778001` total U+V** (`0.397847833` primary/U-only, counters include `REP`-element retirement) across cycles **`28,696,827,616–32,989,404,795`**. Unmeasured fresh rebuilds and post-freeze `experimental/uv-fast-ipc-apr` candidates do not inherit `c0e3fe43`'s qualification.

---

## 1. Public Release Profile on `main` (`retime_muxf_route_first`)

On **`main`**, `fpga/build_known_good.py` verifies and builds the self-contained, hash-pinned 193-file hardware closure in `fpga/known_good_c0e3fe43.json` (`161` defines in `fpga/known_good_defines.txt`, ordered `rtl_ven_core.f` / `rtl_ven_soc.f`, no private `ventium-refs` submodule, and zero prebuilt DCP/IP-cache inputs).

### Exact `retime_muxf_route_first` Stage Directives

| Vivado 2025.2 Stage | Configured Property / Hook | Purpose in `c0e3fe43` Closure |
| --- | --- | --- |
| `synth_design` | `DIRECTIVE = PerformanceOptimized`<br>`GLOBAL_RETIMING = on`<br>`FLATTEN_HIERARCHY = rebuilt` | Balances deep decode/FPU/tag cones across pipeline registers while preserving module hierarchy reporting |
| `opt_design` | `DIRECTIVE = RuntimeOptimized`<br>Post-opt hook: `opt_design -muxf_remap` | Avoids aggressive-opt runtime pathology while remapping wide `MUXF7`/`MUXF8` trees into routable LUT6 cones |
| `place_design` | `DIRECTIVE = AltSpreadLogic_high` | Spreads dense `u_fp_shared`, `u_icache`, and `u_regfile` CLB clusters (`71.97%` CLB occupancy) |
| `phys_opt_design` | `DIRECTIVE = Default` (route-first flow) | Avoids pre-route fanout/congestion inflation before global track assignment |
| `route_design` | `DIRECTIVE = AlternateCLBRouting` | Clears 100% of `>=85%` global routing hotspots (`22.45%` V / `21.05%` H global utilization) |
| `post_route_phys_opt_design` | `IS_ENABLED = true`, `DIRECTIVE = Explore` | Final post-route setup slack recovery (`WNS = +0.164 ns`, `WHS = +0.010 ns`) |

### Preflight & Fresh-Source Build (`main`)

```sh
# Fast source/hash/filelist preflight (never launches Vivado):
python3 -B fpga/build_known_good.py --check
tclsh fpga/test_known_good_wrapper.tcl "$PWD"
python3 -B -m unittest discover -s fpga -p test_known_good.py -v

# Explicitly authorized fresh-source Vivado 2025.2 build on scratch storage:
TMPDIR=/home/yukidama/external/tmp python3 -B fpga/build_known_good.py --build \
  --vivado-root /tools/Xilinx/2025.2/Vivado \
  --output /home/yukidama/external/tmp/ventium-c0e3fe43-rebuild
```

A fresh Vivado build from source is not guaranteed bit-identical across hosts/threads and requires its own post-route timing, DRC, and physical board audit before deployment.

---

## 2. Experimental APR Runner (`experimental/uv-fast-ipc-apr`)

On **`experimental/uv-fast-ipc-apr`**, ongoing core/cache/APR exploration is decoupled from `main` and driven through two layers:

1. **Project Wrapper (`fpga/create_project_3mhz_wrapper.tcl`):** Accepts `VEN_FPGA_BUILD_PROFILE` (`legacy` `AreaOptimized_high`, `balanced` `Default` + spread placement, `logic_only` `Default -no_timing_driven` for fast structural/netlist audits, and on `main` `retime_muxf_route_first`) while enforcing the `40 MHz` core / `100 MHz` AXI constraints, full P5 cache geometry, and `cycle_mode = 1'b1`. `logic_only` is strictly a structural diagnostic and never establishes timing closure.
2. **Isolated Fresh-Source Strategy Sweep (`fpga/run_fresh_strategy.py` + `fpga/fresh_strategy.tcl`):**
   - Copies a hash-verified source freeze into a brand-new leaf under `/home/yukidama/external/tmp` and rejects symlinks or binary `.dcp`/`.bit`/`.xsa`/`.edf` artifacts (`prepared.json`).
   - Intercepts `create_project` and `launch_runs` to force `config_ip_cache -disable_cache` (`IP_CACHE_PERMISSIONS = disable`) and clear `AUTO_INCREMENTAL_CHECKPOINT` / `INCREMENTAL_CHECKPOINT` so every trial is a true clean-sheet synthesis + APR run.
   - Verifies ZynqMP BD invariants (`PSU__GPIO_EMIO_WIDTH = 95`, `PSU__SAXIGP2__DATA_WIDTH = 128`, non-clock `u_soc/pll_safe`, active `ven_programmable_clock.v` + `ven_pll_ctrl.sv`, absent `clk_div32_40mhz.v`).
   - Supports named strategy sweeps (`performance-retime-muxf-route-first`, `performance-retime-muxf-timing-route-first`, `performance-retime-muxf-explore-route-first`, `routability-retime-remap-route-first`, etc.) with audited stage thread policies (`synth=1, APR=4` for route-first profiles or `synth=8, APR=8` under `unbounded` memory) and independent post-run verification (`fpga/audit_fresh_strategy.py`).

> **Experimental Branch APR Context:** Fresh-source APR sweeps on the heavier post-freeze `experimental/uv-fast-ipc-apr` RTL concluded at a **`35.736 MHz`** legal MUXF route (`5c630403`, unmeasured on hardware). Do not overwrite experimental RTL with the `main` snapshot or claim `40 MHz` STA closure on experimental RTL without passing a fresh post-route audit and physical board qualification.

### Wrapper & Strategy Guard Tests (`experimental/uv-fast-ipc-apr`)

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s fpga -p 'test_*fresh*.py' -v
```

---

## 3. Exclusive Vivado Execution, Memory & Scratch Rules

Every Vivado invocation in this repository **must** obey three operational safeguards (`AGENTS.md`):

1. **Single Vivado Process Family (`fpga/run_vivado_exclusive.sh`):**
   - Never invoke `vivado -mode batch` directly. Always launch through `fpga/run_vivado_exclusive.sh` (wrapped by `tools/build_scope.sh` inside `ventium-vivado.scope`).
   - Check active build ownership **before** launching: a replacement launch stops `ventium-vivado.scope` and terminates all same-UID `vivado` / `vrs` processes and descendants from the selected installation (`VENTIUM_VIVADO_ROOT`, default `/tools/Xilinx/2025.2/Vivado`). Never clobber an active, useful build with an ad-hoc checkpoint query.
2. **Uncapped RAM/Swap Policy with Active Safeguards:**
   - Current project policy permits uncapped Vivado RAM and swap (`VENTIUM_VIVADO_MEMORY_POLICY=unbounded` / `MEMORY_PROFILES['unbounded'] = (None, None)`). Do not abort a healthy synthesis/router run solely for swap usage or kill unrelated user applications.
   - Retain cgroup ownership, `TasksMax` (`serial` `48`, `parallel2` / `serial_apr4` `128`, `parallel8` `256`), stage wall-time ceilings, free-disk floors, and real kernel OOM/error detection. Inspect older experimental scripts before running them, as historical controllers may still default to legacy `16 GiB` / `20 GiB` caps.
3. **Scratch Storage Under `/home/yukidama/external/tmp`:**
   - On the maintainer host, every Vivado output directory, temporary project, and `TMPDIR` must reside on verified writable storage under **`/home/yukidama/external/tmp`** (never in `$HOME`, repo root, or through symlinks into `/home/yukidama/external/ventium_run`). Verify free disk space before launching (`>= 8 GiB` recommended per full routed build).
