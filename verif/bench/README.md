# P54 IPC Microbenchmarks & Subsystem A/B Harnesses (`verif/bench/`)

`verif/bench/` provides bounded fixed-work user-mode and bare-metal microbenchmarks for isolating specific P5/P54C front-end, dual-issue, cache-bank, TLB, write-buffer, and FP-overlap behaviors on prebuilt `tb_ventium` L1/AXI models.

> **Mandatory Reporting & Acceptance Rule (`AGENTS.md`):**
> **Never substitute CoreMark, startup windows, or directed microbenchmarks for physical Quake gameplay IPC.**
> - **Current Verified Physical Gameplay Baseline (`c0e3fe43` on `main`, 2026-11-14):** **`0.515778001` total U+V IPC** (`0.397847833` primary/U-only IPC, counters include `REP`-element retirement) across interior DOS Quake gameplay cycles **`28,696,827,616–32,989,404,795`** (`demo1` **`8.0 FPS`**, `969` frames / `121.2 s` at measured `39.999802 MHz`, `40.264133 MHz` post-route STA sign-off on RK-XCZU15EG-F). Prior physical release `2886d24c` measured `0.496499864` total U+V / `0.383002768` primary/U across cycles `625,021,130,428–629,480,208,865`.
> - Experimental define candidates on `experimental/uv-fast-ipc-apr` are **unmeasured in physical gameplay** until qualified on the physical board across the full standard suite (both CoreMark CRC seeds, cold Windows 95 GUI + interaction + shutdown, and cold Quake `timedemo demo1` in `U/V + system fast-pipe`, `cycle_mode=1`).

---

## Running `run-p54-ipc-micro.py`

`run-p54-ipc-micro.py` executes the fixed-work loops in `p54_ipc_cases.s` (100 warmup + 899 measured iterations by default) against an existing `--l1-axi` binary and optional matched `--control` binary, recording exact clocks, retired callbacks, IPC, and cycles/loop in `results.json` while verifying full A/B architectural trace equality (and optional `--qemu` / `--qemu-cases` completed-group equivalence against pinned `qemu-i386`).

```sh
timeout 600s python3 -B verif/bench/run-p54-ipc-micro.py \
  --binary /home/yukidama/external/tmp/obj_dir_ipc_candidate/tb_ventium \
  --control /home/yukidama/external/tmp/obj_dir_ipc_control/tb_ventium --jobs 32
```

### Building Matched Candidate / Control Models Safely

Always compile into **private variant object directories** under `/home/yukidama/external/tmp` (never clobber `verif/tb/obj_dir` or canonical `ao486-sim` outputs), using explicit `/tools/verilator/v5.046/bin/verilator` inside `tools/build_scope.sh`:

```sh
TMPDIR=/home/yukidama/external/tmp \
VENTIUM_VERILATOR_BIN=/tools/verilator/v5.046/bin/verilator \
VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32 \
VENTIUM_BUILD_SCOPE_UNIT=ventium-ipc-parallel32 \
  tools/build_scope.sh -- make -C verif/tb l1axi VL_J=32 \
  L1AXI_OBJDIR=/home/yukidama/external/tmp/obj_dir_ipc_candidate \
  VL_EXTRA_DEFINES="+define+VEN_UOPCACHE +define+VEN_IC_BRAM +define+VEN_SYS_FASTPATH"
```

At runtime, remember that compiling `+define+VEN_L1_AXI` does **not** select the L1/AXI backend — `--l1-axi` must be passed explicitly (`run-p54-ipc-micro.py` supplies `--l1-axi` automatically).

---

## Deployed Hardware Features (`c0e3fe43`) vs Experimental Microgates

| Subsystem | Deployed on `main` (`c0e3fe43`, 161 Defines) | Experimental / Diagnostic Harnesses (`verif/bench/`) |
| --- | --- | --- |
| **TLBs & Branch Prediction** | **32-entry 4-way I-TLB** (`VEN_ITLB_ASSOC_4WAY`) + resident FE page filter, **64-entry 4-way D-TLB** + FE D-TLB slice, dual-ported **256-entry 4-way BTB** + 4-entry RAS | `run-p54-itlb-assoc-micro.sh`, `run-p54-pair-dtlb.sh`, `run-tlb-p54-large-micro.sh`, `run-p54-large-dtlb-micro.sh` (`VEN_DTLB_P54_LARGE` 4 MiB bank) |
| **L1D Banked Read & Hit Return** | **8 KiB 2-way L1 D-Cache** (`ven_l1d`, 8×32-bit interleaved word banks + `ven_p54_hit_return` dual-port read hit return), dual AGUs (`ven_p54_dual_agu`) | `run-p54-dual-agu.sh`, `run-p54-bank-arb.sh`, `run-p54-hit-return.sh`, `run-p54-banked-l1d-micro.sh`, `run-p54-bram-bank.sh`, `run-p54-bram-data.sh`, `run-p54-l1d-pair-hit.sh` |
| **Fast Load/Store & Dual Memory Issue** | Protected-mode flat/relocated/bounded `S_PIPE` fast loads & stores (`MOV`, `ALU`, `PUSH`, `POP`, `LEA`, fast-path `MOVZX`/`MOVSX`), pipelined `REP STOS` streaming (`VEN_REP_STOS_STREAM`) | `run-p54-dual-load-issue.sh`, `run-p54-dual-load-pair.py` (`VEN_P54_DUAL_LOAD_PAIR` / `PRIME`), `VEN_P54_LOAD_STORE_PAIR` (cases 54–59), `VEN_P54_STORE_LOAD_PAIR` leaf (cases 60–62), `run-dual-store-core-gate.sh` |
| **Lookahead Priming & Window Reuse** | Checked register-packet load priming (`VEN_PIPE_MEM_CHAIN`, `VEN_PIPE_REG_LOAD_PRIME`) and coherent line-window reuse | `run-p54-branch-target-prime.py` (`VEN_PIPE_BRANCH_LOAD_PRIME`, cases 22–27), `VEN_L1D_TWO_WINDOW_REUSE` / `KEEP_STORE`, `run-p54-l1d-code-buffer.sh` / `run-p54-code-data-collision.py` / `run-p54-code-tag-micro.sh` |
| **Front-End & Memory-ALU Overlap** | Split 8 KiB L1 I-Cache (`8×RAMB36` data + LUTRAM physical snoop tags), predecode length table, dual U+V decoders | `VEN_FAST_MEM_ALU` (`run-alu-memory-ab.py`, `run-alu-memory-fault.py`), `VEN_UOP_CROSSLINE` / `CROSSPAIR`, `VEN_PIPE_SDECODE` (`verif/uopcache/run-pipe-sdecode-ab.py`) |
| **Shared x87 & Integer Overlap** | `u_fp_shared` (`ven_fp_fxch_queue`, `ven_fp_alu`, `ven_fp_trans`, `fpu_srt_div`) | `fp_integer_overlap`, `fp_fistp_*` (`VEN_FP_STORE_EARLY_CMD`), `VEN_FP_ASYNC_STACK` (`verif/issue_uv/run-fp-integer-overlap.py`) |
| **BIOS-Bootable CoreMark** | Physical standard-suite gate (`2.100128 / 2.106796 CM/MHz` on `c0e3fe43` at `40.000 MHz`, `4,000` iterations, all 5 CRCs matched) | [`coremark_boot/`](coremark_boot/README.md) bare-metal disk builder, 10-iteration smoke check, and result verifier |
| **Simulated Dhrystone 2.1 (`DMIPS/MHz`)** | Simulated on frozen `c0e3fe43` (`U/V + system fast-pipe`, `--l1-axi`, 4 KiB paging): **`0.5960 DMIPS/MHz`** (`955.0` cyc/iter, exact `z486` `-march=i386 -O3 -fno-inline` flags — `3.07×` `ao486` `0.194`, `1.81×` `z486` `0.330`), **`0.6287`** (`z486` Makefile `-O2 -DREG=register`), **`0.6680`** (`-march=pentium -O3 -fno-inline`), and **`0.7139 DMIPS/MHz`** (`-march=pentium -O2 -DREG=register`) | [`dhrystone/`](dhrystone/README.md) self-checking Weicker 2.1 harness (`run_dhrystone.py` & `test_run_dhrystone.py`) |

---

## Representative Cases in `p54_ipc_cases.s`

| Case Group | Structural Question Probed |
| --- | --- |
| `reg_load_prime`, `register_u_memory_v`, `memory_u_register_v` | Can an independent register packet lend its idle D-cache lookup slot to eliminate the registered-hit capture bubble? |
| `dual_load_{distinct,same}_bank`, `dual_load_after_store*` | Do two independent loads from distinct `[4:2]` word banks retire together while same-bank accesses serialize cleanly? |
| `dual_store_{distinct,same}_bank` | Does dual-store admission respect word-bank conflicts, write-buffer capacity, and executable snoop coherence? |
| `resident_{same_line,two_line}_loads`, `resident_xline_return` | Does registered line-window reuse serve same-line hits without extra bank reads while rejecting stale/cross-line hazards? |
| `branch_{target,fallthrough}_load`, `*_mispredict` | Does predicted-branch load priming cancel cleanly without creating a stale response owner on direction reversal? |
| `resident_memory_{alu,or,adc,sbb,and,sub,xor}` | Do memory-ALU instructions preserve P54 execution occupancy and `CF` dependencies across U/V pairing? |
| `fp_integer_overlap`, `fp_fistp_*` | Does independent integer work overlap in-flight x87 arithmetic while keeping `FIST(P)` permission probes and ordered stores precise? |
| `frontend_{aligned,line_straddle}` | How does the fetch/decode front end behave across 32-byte I-cache line boundaries? |
| `resident_hit_under_fill`, `landed_word_forward` | Can resident hits or critical-word-first beats complete while a backing cache-line fill drains? |
