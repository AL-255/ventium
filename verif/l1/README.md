# `verif/l1` — L1 Caches, TLBs, BTB, and AXI4 Memory Subsystem Verification

## Scope and Architectural Invariants

`verif/l1/` verifies the synthesizable Pentium P5/P54C memory hierarchy, address translation
caches, branch target buffer, and 64-bit AXI4 platform bridge:

- **Split 8 KiB L1 Caches (`rtl/mem/icache.sv`, `rtl/mem/ven_l1d.sv`):**
  - **L1 I-Cache:** 8 KiB, 2-way set-associative, 32 B lines, `8xRAMB36` data arrays +
    LUTRAM tags, physical-address snoop-coherent across aliased linear mappings.
  - **L1 D-Cache:** 8 KiB, 2-way set-associative, 32 B lines, 8-way 32-bit interleaved banks
    with `ven_p54_bank_arb` and `ven_p54_hit_return` for simultaneous dual-port U+V read hit
    return, write-back/write-allocate policy, and tag-qualified store updates.
  - **Full-P5 Policy:** Deployed hardware uses full P5 L1s with **no enabled outer L2**
    (`VEN_EN_L2` disabled; `VEN_CACHE_HALF` and `VEN_IC_NARROWB` are permanently forbidden).
- **Set-Associative TLBs (`rtl/mem/tlb.sv`, `rtl/mem/tlb_assoc.sv`):**
  - **I-TLB:** 32-entry 4-way set-associative (`VEN_ITLB_ASSOC_4WAY`).
  - **D-TLB:** 64-entry 4-way set-associative (`VEN_DTLB_ASSOC_4WAY`, `VEN_DTLB_P54_LARGE`),
    supporting 4 KiB and 4 MiB (`CR4.PSE`) pages, `A`/`D` bit tracking, and selective
    `CR0`/`CR4` architectural flushes.
- **Branch Target Buffer (`rtl/core/bpred_btb.sv`):** Dual-ported 256-entry 4-way BTB
  (`VEN_BTB_PIPE`) with 2-bit bimodal saturating counters and a 4-entry return address stack
  (RAS), supporting simultaneous fetch lookup and retirement update.
- **AXI4 Master & Platform Bridge (`rtl/mem/ven_axi_master.sv`, `rtl/mem/ventium_l1_axi.sv`,
  `rtl/northbridge/ven_cachemap.sv`, `ao486-sim/ven/ven_axi2avalon.sv`):** Drives 64-bit
  cacheable DRAM bursts, byte-exact uncacheable/MMIO/VGA transactions, optional CDC
  (`ven_axi_cdc.sv`), and the 16-slot posted DDR4 queue (`fpga/ven_ddram_axi_posted.sv`).

### Mandatory Subsystem Invariants

1. **Byte-Exact Non-Cacheable Accesses:** Uncacheable (`CR0.CD`, `PCD`, MMIO, legacy VGA)
   reads and writes must honor exact `ARSIZE` and `WSTRB` byte lanes; AXI models and bridges
   must never silently widen narrow device reads.
2. **Physical Alias & SMC Coherence:** Core and DMA store snoops match physical tags so
   self-modifying code across aliased linear pages invalidates resident I-cache lines
   (`tb_ic_alias.sv`, `tb_icache_snoop.sv`).
3. **Tag-Qualified Store Policy (`VEN_L1D_STORE_POLICY`):** Store hits update matching
   resident ways in place and invalidate duplicate physical tags in the opposite way; store
   misses and ignored ROM writes (`tb_l1axi_ao486_romwrite.sv`) never leave phantom modified
   lines in `ven_l1d`.
4. **True External Drain Barrier:** Posted DDR4 write acknowledgement is **not**
   architectural external completion; I/O instructions, debugger `HALT`, and MMCM DRP clock
   changes must wait for complete write-buffer and posted-DDR drain.

---

## Feature & Experiment Status

> **Physical Gameplay Baseline (`c0e3fe43`):** Verified physical Quake gameplay IPC on
> board-qualified image `c0e3fe43` (`main`, 161 defines, 40.000 MHz) is **`0.515778001`
> total U+V** (`0.397847833` primary/U-only; counters include `REP`-element retirement)
> across cycles **`28,696,827,616–32,989,404,795`**. Unmeasured experimental-branch variants
> do not inherit this baseline.

| Sub-Area | Deployed in `c0e3fe43` (`main`) | Experimental / Opt-In (`experimental/uv-fast-ipc-apr`) | Rejected / Disabled |
| --- | --- | --- | --- |
| **L1D Banking & Dual-Hit** | `VEN_L1D_BANKED_DATA`, `VEN_L1D_BANK0_SHARED_XLINE`, `VEN_L1D_TAG_LUTRAM`, `VEN_P54_DUAL_HIT`, `VEN_P54_DUAL_LOAD_PAIR`, `VEN_P54_DUAL_BYTE_LOAD_PAIR`, `VEN_P54_LOAD_STORE_PAIR`, `VEN_P54_DUAL_STORE_PAIR` | Standalone way-banked tag RAM probes (`run_way_banked_*.py`) | `VEN_CACHE_HALF`, `VEN_IC_NARROWB`, `CURRENT_U_PAIR`, `PAIR_NEXT_DISJOINT`, `PARALLEL_NEXT_TAG` |
| **Window Reuse & Fill Overlap** | `VEN_L1D_WINDOW_REUSE`, `VEN_L1D_TWO_WINDOW_REUSE`, `VEN_L1D_WINDOW_KEEP_STORE`, `VEN_L1D_TWO_WINDOW_KEEP_STORE`, `VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE`, `VEN_L1D_STORE_WINDOW_WARM`, `VEN_L1D_WINDOW_WRITE_UPDATE`, `VEN_L1D_HIT_UNDER_FILL`, `VEN_L1D_FILL_FORWARD`, `VEN_L1D_DATA_UNDER_IFILL`, `VEN_L1D_PRIME_UNDER_FILL`, `VEN_L1D_CODE_BUFFER`, `VEN_L1D_CODE_STREAM`, `VEN_L1D_CODE_WORD_REUSE` | `VEN_FP_LOAD64_UNDER_FILL`, `payload-cut/` primary-window byte-mux miter | `WINDOW_CURRENT_REUSE`, `FP_WIDE_CONTEXT`, `PRIME_WIDTH_PAYLOAD`, `RAW_PRIME_STORAGE` |
| **Payload Cuts, Write Buffer & Bridge** | `VEN_L1D_RESPONSE_PAYLOAD_SELECT`, `VEN_L1D_HIGH_PAYLOAD_SELECT`, `VEN_L1D_CODE_PAYLOAD_SELECT`, `VEN_L1D_PAYLOAD_CODE_HINT`, `VEN_P54_WBUF_PIPE_DISPATCH`, `VEN_P54_WBUF_ADMIT_DISPATCH`, `VEN_P54_WBUF_QUAD_COMBINE`, `VEN_AXI2AVL_BPIPE` / `WRITE_THROUGH` / `READ_THROUGH`, `VEN_VGA_WIDE_STORE` / `VEN_VGA_FULL_STORE_SETUP`, `VEN_DDR_POSTED` | `VEN_P54_WBUF_EMPTY_DISPATCH` (superseded by `ADMIT_DISPATCH`) | `VEN_EN_L2` (256 KiB outer L2 capacity/LRU experiments), `BACKING_DIRECTION`, `BACKING_PAYLOAD_MUX`, `BRANCH_ADDRESS_SHAPE`, `QUALIFIED_PAIR_CREDIT`, `READ_OWNER_ACK`, `RESPONSE_KIND_MUX`, `SYSTEM_READ_ACK` |
| **TLBs & BTB** | `VEN_ITLB_ASSOC_4WAY` (32-entry 4-way), `VEN_DTLB_ASSOC_4WAY` + `VEN_DTLB_P54_LARGE` (64-entry 4-way), `VEN_BTB_PIPE` (256-entry 4-way dual-port + 4-entry RAS) | Direct-mapped vs. associative `make pdtlbassoc` differential controls | — |

---

## Active Testbenches and Gate Scripts

Top-level `make l1` globs and executes **every** `verif/l1/run-*.sh` gate (48 shell scripts;
non-early-exit so a single failure never masks remaining gates):

| Gate Family | Representative Scripts | Primary Testbenches |
| --- | --- | --- |
| **L1D Coherence & Window Reuse** | `run-l1d-gate.sh`, `run-l1d-coherence-gate.sh`, `run-l1d-hit-stream-gate.sh`, `run-l1d-early-retarget-gate.sh`, `run-l1d-tag-policy-gate.sh`, `run-l1d-window-reuse-gate.sh`, `run-l1d-window-keep-store-gate.sh`, `run-l1d-window-keep-reset-gate.sh` | `tb_l1d.sv`, `tb_l1d_coherence.sv`, `tb_l1d_hit_stream.sv`, `tb_l1d_early_retarget.sv`, `tb_l1d_window_reuse.sv`, `tb_l1d_window_keep_store.sv`, `tb_l1d_window_keep_reset.sv` |
| **Dual-Port & Wide Load/Store** | `run-l1d-load64-gate.sh`, `run-l1d-load-store-policy-gate.sh`, `run-l1d-mem-chain-gate.sh`, `run-l1d-pair-store-gate.sh`, `run-l1axi-pair-hit-micro.sh` | `tb_l1d_load64.sv`, `tb_l1d_load_store_policy.sv`, `tb_l1d_mem_chain.sv`, `tb_l1d_pair_store.sv`, `tb_l1axi_pair_hit.sv` |
| **I-Cache Snoop & Aliasing** | `run-icache-snoop-gate.sh`, `run-ic-alias-gate.sh` | `tb_icache_snoop.sv`, `tb_ic_alias.sv` (`VEN_IC_SNOOP_LINEAR` hazard control) |
| **TLB, BTB & Region Routing** | `run-tlb-gate.sh`, `run-tlb-assoc-gate.sh`, `run-tlb-p54-large-micro.sh`, `run-btb-gate.sh`, `run-cachemap-gate.sh`, `run-l1axi-route-gate.sh`, `run-l1axi-smram-gate.sh` | `tb_tlb.sv`, `tb_tlb_assoc.sv`, `tb_tlb_p54_large.sv`, `tb_btb.sv`, `tb_cachemap.sv`, `tb_l1axi_route.sv`, `tb_l1axi_smram.sv` |
| **L1-AXI Protocol & CDC** | `run-l1axi-gate.sh`, `run-l1axi-verify.sh`, `run-l1axi-narrow-gate.sh`, `run-l1axi-lock-gate.sh`, `run-l1axi-rlast-gate.sh`, `run-l1axi-alias-gate.sh`, `run-l1axi-bypass-reset-gate.sh`, `run-l1axi-wd-gate.sh`, `run-l1axi-callret-gate.sh`, `run-l1axi-xline-gate.sh`, `run-l1axi-xword-gate.sh`, `run-l1axi-cdc*-gate.sh`, `run-axi-wbuf-gate.sh`, `run-axi-quad-*-gate.sh`, `run-axi-*-replay-gate.sh`, `run-axi-*-contain-gate.sh` | `tb_l1_axi.sv`, `tb_l1axi_narrow.sv`, `tb_l1axi_lock.sv`, `tb_l1axi_rlast.sv`, `tb_l1axi_cdc.sv`, `tb_l1axi_cdc_rresp.sv`, `tb_l1axi_cdc_dma_reset.sv`, `tb_axi_wbuf.sv`, `tb_axi_*_contain.sv` |
| **Platform / VGA / Legacy L2** | `run-axi2avalon-wrap-gate.sh`, `run-axi-ao486-path-gate.sh`, `run-axi-ao486-write-pipe.sh`, `run-l1axi-ao486-romwrite-gate.sh`, `run-vga-wide-store-gate.sh`, `run-vga-full-store-setup-gate.sh`, `run-l2inv-gate.sh`, `run-l2stream-cwf-gate.sh` | `tb_axi_ao486_path.sv`, `tb_l1axi_ao486_romwrite.sv`, `tb_vga_wide_store.sv`, `tb_vga_full_store_setup.sv`, `tb_l2_inv.sv`, `tb_l2_stream_cwf.sv` |

---

## Safe Execution Guidelines

- **Scratch & Object Directories:** Export `TMPDIR=/home/yukidama/external/tmp` (verify
  mount/free space first; never fall back to `/` or home folders) and compile variants into
  private object directories. Never traverse or reuse stale `verif/l1/obj_dir*` build trees
  across incompatible defines.
- **Explicit Verilator & Backend Flag:** On the maintainer host, set
  `VERILATOR=/tools/verilator/v5.046/bin/verilator`. Compiling a full-core testbench with
  `+define+VEN_L1_AXI` does **not** select the AXI backend at runtime — pass `--l1-axi`
  explicitly and verify AXI traffic.

```bash
# Run the full 48-gate L1/TLB/BTB/AXI regression suite:
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator make l1

# Run targeted standalone unit gates:
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/l1/run-l1d-coherence-gate.sh
TMPDIR=/home/yukidama/external/tmp VERILATOR=/tools/verilator/v5.046/bin/verilator \
  bash verif/l1/run-l1axi-narrow-gate.sh
```
