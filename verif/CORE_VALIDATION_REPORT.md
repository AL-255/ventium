# Ventium Core & Verification Validation Report (November 2026)

## 1. Branch & Qualification Boundary

Ventium maintains a strict verification boundary between the physical release branch and the active development harness:

- **`main` (Frozen Physical Release `c0e3fe43`, 2026-11-14):** Publishes the self-contained 193-file hardware source closure (`fpga/known_good_c0e3fe43.json`, `161` defines) qualified on **RK-XCZU15EG-F** (`xczu15eg-ffvb1156-2-i`, AMD Vivado **2025.2**).
- **`experimental/uv-fast-ipc-apr` (Development & Differential Harness):** Retains ongoing core/cache/FPU/APR work and the full Verilator + pinned QEMU Pentium (`ventium-refs/`) differential verification stack. Uncommitted or post-freeze experimental edits do **not** inherit `c0e3fe43`'s physical qualification or gameplay IPC without fresh re-verification.

### Verified Physical Baseline (`c0e3fe43` on `main`)

Every physical acceptance gate below ran in **mandatory `U/V + system fast-pipe` mode** (`cycle_mode=1`, `161` defines), never U-only or slow-FSM diagnostic controls:

| Acceptance Gate / Metric | Verified Result (`c0e3fe43`, 2026-11-14) | Prior Release (`2886d24c`, 2026-10-17) | Scope & Evidence |
| --- | --- | --- | --- |
| **CoreMark** (both standard seeds) | **`2.100128 / 2.106796 CM/MHz`** (PASS) | `2.100128 / 2.106796 CM/MHz` | `40.000 MHz`, `4,000` iterations, `2 KiB` dataset, all 5 reference CRCs matched |
| **Windows 95 OSR2 GUI** | **PASS (Cold Boot + Multi-App + Shutdown)** | Unqualified | Cold boot to clean desktop, PS/2 mouse & keyboard across Calculator (`355/113`), Notepad & MS Paint, clean OS shutdown |
| **DOS Quake `timedemo demo1`** | **`8.0 FPS`** (`969` frames / `121.2 s`, PASS) | `7.7 FPS` (`969` frames / `125.8 s`) | Cold FreeDOS boot at measured `39.999802 MHz`, `320×200`, zero errors |
| **Verified Quake Gameplay IPC** | **`0.515778001` total U+V**<br>`0.397847833` primary/U-only | `0.496499864` total U+V<br>`0.383002768` primary/U-only | Interior gameplay cycles **`28,696,827,616–32,989,404,795`** (`2,214,014,744` total U+V events, `506,223,958` paired V retirements; `+3.88%`) |
| **Post-Route Core STA Sign-Off** | **`40.264133 MHz` (SIGNED OFF)**<br>`WNS = +0.164 ns`, `WHS = +0.010 ns` | `28.701817 MHz` (unclosed estimate)<br>`WNS = -9.841 ns`, `WHS = +0.004 ns` | Vivado 2025.2 slow-corner static timing closure at `40.000 MHz` (`0` failing endpoints, `0` `>=85%` congestion hotspots, `171,819` LUTs / `30,703` CLBs) |
| **Empirical Runtime DRP Overclock** | `58.824 MHz` (Win95 + Quake)<br>`62.500 MHz` (Quake `11.6 FPS`) | `52.63 MHz` CoreMark max | Single-board silicon runtime MMCM DRP measurements on `c0e3fe43`; **not** multi-board PVT STA sign-off above `40 MHz` |

> **IPC Reporting Rule:** Hardware retirement counters include individual `REP` string iterations alongside architectural instruction retirements. Total U+V (`retire_n`) and primary/U-only counters must always be distinguished, and startup, BIOS, CoreMark, or microbenchmark windows must never be substituted for interior Quake gameplay IPC. Candidates on `experimental/uv-fast-ipc-apr` are **unmeasured in physical gameplay** unless explicitly qualified on hardware; `0.515778001` total U+V (`c0e3fe43`) is the baseline.

---

## 2. Differential & Subsystem Verification Gates (`experimental/uv-fast-ipc-apr`)

Instruction-by-instruction architectural lockstep against the pinned QEMU Pentium 8.2.2 oracle (`ventium-refs/07-p5-emulation-harness`) using `.vtrace` records (`verif/diff/tracefmt.py` + `verif/diff/compare.py`) is the **correctness authority** across real, protected, V86, paged, and system-management modes.

| Make Target | Runner / Scope | What It Verifies |
| --- | --- | --- |
| `make verify` | `verif/issue_uv/run-issue-uv-gate.sh` + `verif/verify.sh` | Parallel user-mode integer + x87 functional equivalence vs `qemu-i386` (cached goldens keyed on source/ELF/oracle/observer/transport) plus M4 integer and M5 cache/FP cycle bands vs `p5trace.so`. |
| `make verify-sys` | `verif/sys/run-sys-golden.sh` + system witness gates | Bare-metal `-bios` corpus (`pseg`, `pmode`, `ppage`, `pintr*`, `pfault`, `pcpl`, `pssiret`, `pfarok`, `psoccallfmem`, `ppriv`, `pstk16`, `pdf`, `ptask*`, `pretf*`, `pcall*`, `pjmp*`, `pltr`, `piretgp0`, `piopermwrap`, `pxfer`, `pselnull`, `pnullseg`, `pxprobe`, `pxwrap*`, `pxfrag`, `pxdplan`, `fxabort`, `pcg*`, `pxc04*`, `pxwalkd`, `pdescprec`, `pint16f`, `psamepf`, `ptswflt`, `prsmflush`, `psmmmeta`, `pintslim`, `psmm`, `pdebug`, `ppopf`, `pv86*`) diffed in `--system` mode (`cr0..cr4`, selectors, GPRs, `eflags`, `eip`) or graded by SDM witnesses where QEMU softmmu lacks fidelity. |
| `make verify-sys-fpreloc`<br>`make verify-sys-fpload`<br>`make verify-sys-faststore`<br>`make verify-sys-faststack`<br>`make verify-sys-faststack-seg` | `verif/sys/run-*.sh` | System fast-pipeline (`S_PIPE`) acceptance gates: relocated equal-base clients, flat/bounded fast loads & stores with precise `#PF` restart (`CR0.WP`), CPL3 `PUSH`/`POP` `#PF` retry under delayed backing ACKs, and full-limit expand-down `#SS(0)` precision. |
| `make l1` | `verif/l1/run-*.sh` (auto-discovered) | All L1D coherence/store/load/window/bank, I-cache physical-tag snoop/alias (`icache.sv`), D-TLB/I-TLB, BTB, and `ventium_l1_axi` / `ven_axi_cdc` / DMA reset-release unit & seam gates. |
| `make bus`<br>`make bus-sva` | `verif/bus/` | Standalone 64-bit P5 `biu_p5` protocol gate (19 SVA + 76 directed checks), `ao486` PS/2 I/O-bus delayed-read regression, and integrated `bus_mode=1` corpus run with live `biu_p5` SVA assertions + QEMU functional equivalence. |
| `make verify-srt`<br>`make verify-srt-iter`<br>`make verify-fprem`<br>`make verify-idiv`<br>`make verify-bcd`<br>`make verify-fbld`<br>`make verify-fppipe`<br>`make verify-fppipe2` | `verif/{srt,idiv,bcd,fbld,fppipe}/` | Bit-exact arithmetic unit & in-core gates: combinational `fx_srt_div` and iterative `fpu_srt_div` (both correct IEEE-754 PLA and documented Pentium FDIV flaw PLA), iterative `FSQRT`, 3-config `FPREM`/`FPREM1`, `ven_idiv`, `ven_bcd`/`ven_bcd_to_fp`, and pipelined FP datapath splits. |
| `make x87b` / `fenv` / `fpstore` / `x87stk` / `x87trap` / `x87depop` / `x87debug` | `verif/tests/` & `verif/sys/` | Shared/legacy x87 architectural boundaries: loud-HALT on unenabled deferred ops, `FNSTENV` exception masking, writable destination probe before `FISTP` pop, 7×2 `#IS` stack-fault matrix, strict `#NM > #MF` fast-path bailout (`VEN_X87_MF_STRICT`), masked `DE` arithmetic-and-pop tag/QNaN commit, and post-commit `TF`/`#DB` retirement. |
| `make m6` | `verif/errata/run-m6.sh` | Self-checks 4 documented P5/P54C silicon errata behind runtime `errata_en` (default `0`): Err 23 (FDIV), Err 20 (FIST overflow), Err 81 (`F00F` hang), and Err 79 (V86 `POPF`/`IRET` `#DB`), plus Err 59 withdrawal guard. |
| `make lint` | `verif/lint/run-lint-gate.sh` | Verilator structural lint across 5 build profiles (default, `L1/AXI`, full-P5 FPGA, iterative-BCD, and `FP_PS_ALL`); `IMPLICIT`, `PINMISSING`, `UNDRIVEN`, `MULTIDRIVEN`, `LATCH`, and `UNOPTFLAT` are hard errors. |
| `make docs-status` | `verif/sys/run-docs-status-gate.sh` | Mechanical check keeping `docs/unsupported-isa.md`, RTL loud-halt tags (`0xD*`), off-by-default defines, closed-range x87 manifest masks, and `run-verify-all.sh` classifications synchronized. |
| `make verify-all` | `verif/run-verify-all.sh` | Sequential 25-gate umbrella executing the routine regression set above; reports `PASS` correctness gates and `XFAIL-PINNED` expected-failure pins separately (`0` active `XFAIL-PINNED` entries after `xc04` and `ic-alias` fixes landed), and explicitly logs excluded targets (`verify-soc`, artifact-dependent `m7` Quake/Win95 co-sims). |

> **Profile Note (`make verify` vs Deployed Hardware Profile):** The canonical `make verify` target builds the default direct-memory `ventium_top` configuration. Running the 150+-define full-P5 `VEN_L1_AXI` + `VEN_FP_SHARED` profile through `make verify` requires `--l1-axi` at runtime and, for user-mode x87/exit parity, the opt-in hash-pinned `VTM_QEMU_PROFILE_BUILD` (`i386-defined-x87-preexit-20261016` in `verif/qemu-trace/qualified_profile.py`; `108/108` functional PASS), while direct-memory `p5trace` cycle-miss bands (`imiss=8`/`dmiss=8`) naturally differ from multi-beat AXI linefill latencies. Never weaken masks or cycle bands to paper over backend differences.

---

## 3. Shared Pipelined x87 FPU (`fp_shared/`) Validation Summary

In the deployed hardware profile (`VEN_FP_SHARED` + `VEN_FP_SHARED_DIRECT` + `VEN_SRT_ITER` + `VEN_TRANSCENDENTAL` + `VEN_FPREM`), `fp_shared/ven_fp_top.sv` (`u_fp_shared`: `72,204` LUTs, `10,596` FFs, `2.5` BRAM36, `38` DSP48E2 on `c0e3fe43`) is the sole architectural owner of 80-bit x87 state:

- **Zero-cycle `FXCH` rename queue** (`ven_fp_fxch_queue`) + 80-bit physical stack (`ven_fp_state`).
- **Pipelined add/sub/compare** (`ven_fp_alu`, single-front automatic-DSP carry architecture) and **shared 38-DSP wide multiplier & polynomial transcendental engine** (`ven_fp_widemul`, `ven_fp_trans` covering `FSIN`, `FCOS`, `FSINCOS`, `FPTAN`, `FPATAN`, `F2XM1`, `FYL2X`, `FYL2XP1`) triangulated against Berkeley SoftFloat-3e (`extF80`, `verif/fpu87/`) and `qref` (`verif/trsc/`).
- **Unified radix-4 SRT divide / square-root / remainder engine** (`rtl/fpu/fpu_srt_div.sv` as `u_srt`), bit-exact IEEE-754 across all 4 rounding modes and precision controls (`PC24`/`PC53`/`PC64`), including subnormal normalization, exact `FPREM`/`FPREM1` partial/complete reductions, `IE`/`DE` operand-abort priority, and `UM=0` exact tiny-result `2^24576` rescaling (`verif/srt/`).
- **Precise exception & environment handling:** 14/28-byte real/V86 (`seg_real`) and protected-mode `FLDENV`/`FRSTOR`/`FNSTENV`/`FNSAVE` pointer codecs, pre-commit write-permission probes (`d_f_mem_write`, `make fpstore`), `FRNDINT` extended-precision/C1/DE compliance, and strict waiting-instruction `#NM > #MF` delivery (`VEN_X87_MF_STRICT`, `make x87trap`).

---

## 4. Mandatory Verification & Development Safeguards

1. **Dual-Issue Fast-Pipe Acceptance:** Repair and performance qualification requires **`U/V + system fast pipeline`** (`cycle_mode=1`), including relocated protected-mode clients and fast load/store paths, with proven paired V retirements and **no** `STEP` or execution-breakpoint (`--dbg-step` / `--dbg-bp`) pairing suppression. U-only or slow-FSM runs are diagnostic controls only.
2. **Private Variant Object Directories:** Never overwrite `verif/tb/obj_dir/tb_ventium` or follow/delete `external/ventium_run` symlinks. Always pass a private `OBJDIR=obj_dir_<variant>` (or `L1AXI_OBJDIR=...`) and keep all new scratch under `/home/yukidama/external/tmp` with explicit `TMPDIR`.
3. **Explicit Verilator & Lock Discipline:** Use `/tools/verilator/v5.046/bin/verilator` (`VENTIUM_VERILATOR_BIN`) through `tools/verilator_serial.sh` / `tools/build_scope.sh`. Guarded Python child processes must inherit the lock descriptor (`pass_fds=(9,)`), verify actual child CPU affinity (`taskset`), and compile per-model C++ harnesses with unique basenames against model-local generated headers.
4. **Runtime Backend Selection:** Compiling `+define+VEN_L1_AXI` does **not** select the L1/AXI backend at runtime — pass `--l1-axi` explicitly (`FUNC` and `CYCLE` jobs use separate extra-flag variables) and verify non-zero AXI backing handshakes.
5. **Trace & Opcode-Map Integrity:** Always emit and parse `.vtrace` files via `verif/diff/tracefmt.py` (never hand-formatted JSON). Never weaken EFLAGS/x87 masks or convert regressions into `XFAIL-PINNED` entries. Update `tools/opcode_map/coverage_data.json` whenever decoder behavior changes.
