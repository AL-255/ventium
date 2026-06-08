# ventium_l1_axi — design blueprint (P1-1)

The linchpin for booting on the KV260: bridge the Ventium core's **same-cycle-ack**
memory port to the PS DDR4 over AXI4 (multi-cycle), hiding DDR latency behind an
L1 cache that acks on hit in the same clock. Synthesized from the 3-agent
investigation (workflow `wf_cc8bcedc-b18`, 2026-06-07). Cross-ref PLAN §5.2.

## 1. The contract the core imposes (non-negotiable)
Core mem port (`core.sv:187-193`): `mem_req, mem_we, mem_addr[31:0],
mem_wdata[31:0], mem_wstrb[3:0]` (out) / `mem_rdata[31:0], mem_ack` (in). Single
32-bit word port; all traffic (fetch, load, store, page-walk, descriptor/TSS/
SMRAM) multiplexes onto it (`core_bus_driver.svh` `unique case(state)`).

* **Same-cycle ack on HIT is mandatory.** The dual-issue fast path latches
  `mem_rdata` into the GPR combinationally the SAME clock it asserts `mem_req`
  (`core_fastpath.svh:204`, `core_bus_driver.svh:23`). No register stage. So an
  L1 HIT must drive `mem_rdata` + `mem_ack` combinationally off `mem_addr`.
* **Miss may stall.** The slow FSM and the fast-path miss handling gate on
  `if(mem_ack)` and the `pending_mem_pen` deferred-penalty mechanism — they
  tolerate multi-cycle latency. So on an L1 MISS, deassert `mem_ack` (=0) and the
  core stalls/refetches while the AXI burst runs off-path.
* **wstrb byte-enables** must be honored on writes.

## 2. ventium_l1_axi structure
```
core (core clk)                         |  AXI / PS clk (from MMCM)
  mem_* (32b, same-cycle-ack)           |
        │                               |
   ┌────▼─────────────────────────┐     |
   │ A20 mask (already in soc) +   │     |
   │ HARD physical-gate select     │     |   (descriptor/TSS/SMRAM/page-walk
   │  (state-driven, NO re-xlate)  │     |    addresses are ALREADY physical —
   └────┬─────────────────────────┘     |    must bypass any L1 vaddr assumption)
        │ phys addr                      |
   ┌────▼───────────────┐  hit (comb)    |
   │ L1 D-cache          ├──> mem_rdata + mem_ack SAME CLOCK
   │  tag/val/LRU  (reuse dcache_timing SM)
   │  DATA ARRAY (NEW — task #10): 8KB, 2-way, 32B line, distributed/BRAM
   └────┬───────────────┘  miss
        │ line-fill req (32B = 8 words)
   ┌────▼───────────────┐         ┌──────────────────┐
   │ miss FSM + CDC FIFO ├────────►│ AXI4 master       │──► S_AXI_HPC0 (coherent)
   │ (core clk ↔ AXI clk)│◄────────┤  burst read/write │◄── reserved-DDR window
   └─────────────────────┘         └──────────────────┘
        + x86-phys → DDR base remap (flat: ddr_addr = REMAP_BASE + phys)
```

## 3. Key decisions
* **L1 geometry:** match the icache (8 KB, 2-way, 32-byte line, 128 sets) and the
  oracle p5trace L1 (so cycle behavior stays consistent). Tag/val/LRU = reuse the
  `dcache_timing` SM (it's correct, lookahead `lu_hit` is the right shape). Add the
  **data array** the icache way: packed 256-bit lines, `(* ram_style="distributed"
  *)` flat `{set,way}` index, async read (shallow → LUTRAM, NOT BRAM — proven by
  the icache P0-3 finding). Hit data = combinational line slice → `mem_rdata`.
* **Same-cycle hit:** `lu_hit` + the line read are combinational off `mem_addr`
  (registered arrays), exactly like the icache. Drive `mem_ack = lu_hit` and
  `mem_rdata = <hit word>` that clock.
* **Miss:** `mem_ack=0`; latch the miss addr; the miss FSM issues an AXI burst
  (8×32b = one 32B line) read; on return, fill the line + (next core access) hits.
  Core stalls meanwhile (`pending_mem_pen`).
* **Writes:** write-through to AXI (simplest, CCI-coherent) OR write-back with a
  dirty bit. Start write-THROUGH (no dirty/MESI) — wstrb passthrough; `mem_ack=1`
  when the write is accepted into the AXI write buffer. (Write-back is an
  optimization for later.)
* **CDC:** core clk and AXI clk are independent (MMCM). The miss FSM ↔ AXI master
  cross via a small async FIFO (addr/burst out, data in) + handshake synchronizers.
  The HIT path is entirely in the core clock domain (no CDC on the fast path).
* **Address remap:** `ddr_addr = REMAP_BASE + (phys & ADDR_MASK)`. The whole x86
  physical space maps into one reserved DDR window via a base offset. REMAP_BASE /
  window size: TBD from the PetaLinux reserved-memory carveout (a parameter).
* **HARD physical gate:** descriptor/TSS/SMRAM/page-walk states address physical
  memory directly — the L1 sees a physical addr already; it must NOT re-translate.
  (The core already does translation; the L1 is purely physical-addressed.) So the
  L1 is simply physical-addressed — no TLB inside it. CR3-write / TLB-flush must
  invalidate the L1 if it ever caches translated data that could go stale —
  but since the L1 is physical and CCI-coherent, ordinary self-modifying-code /
  page-remap correctness is the core's existing concern, not the L1's.

## 4. Integration + build order
1. **L1 data array (task #10): ✅ BUILT + unit-verified (`rtl/mem/ven_l1d.sv`,
   `verif/l1/run-l1d-gate.sh` → L1D-GATE-OK).** 8 KB / 2-way / 32 B, packed 256-bit
   lines in distributed RAM (icache pattern → async read for the same-cycle hit),
   tag/val/lru == dcache_timing. READ HIT returns the addressed word combinationally
   (c_ack=1 same clock); READ MISS deasserts c_ack and the fill FSM bursts the 32-byte
   line (8 words) from the backing into the not-MRU victim, then the retry hits; WRITE
   is write-through (array on hit + backing). Standalone gate covers cold-miss→fill→
   hit, whole-line fill, write-through, 2-way LRU eviction. Backing = BFM now, AXI later.
   * **KEY FINDING (the central challenge for step 3):** the core's FAST-PATH load
     latches `mem_rdata` UNCONDITIONALLY — `core_fastpath.svh` ~L215 `gpr[dst]<=mem_rdata`
     does NOT gate on `mem_ack` (it assumes the BFM's same-cycle data and DEFERS the
     miss penalty via `pending_mem_pen`). So a REAL stalling L1 (c_ack=0 on miss) needs
     a fast-path MISS-STALL gate — exactly the `ic_fetch_ready` pattern just built for
     the icache (+VEN_IC_BRAM): don't issue the load until c_ack, mirror the line into
     the buffer. AND under bus_mode=2 the core's deferred `pending_mem_pen` penalty
     must be SUPPRESSED (else the real fill stall + the modeled penalty double-count).
     The cycle BANDS verify the bus_mode=0 abstract model; the bus_mode=2 real-latency
     path is verified FUNCTIONALLY (make verify func 75/75 + Quake lockstep), its timing
     emergent (real DDR latency ≠ the abstract P5 L2 penalty).
2. **AXI4 master: ✅ BUILT + verified (`rtl/mem/ven_axi_master.sv`,
   `rtl/mem/ventium_l1_axi.sv`, `verif/l1/run-l1axi-gate.sh` → L1AXI-GATE-OK).**
   The master converts ven_l1d's word-granular backing port into AXI4: a backing
   READ (always a full 32 B line) COALESCES into ONE INCR8 burst (ARLEN=7, ARSIZE=2,
   AxCACHE=0xF coherent), each R beat metered back as one `m_ack`+`m_rdata` in fw
   order (`m_ack = RVALID && RREADY`); a WRITE is a single-beat write-through, AW/W
   DECOUPLED (independent done-latches, no AW-before-W deadlock), `m_ack` on BVALID.
   40-bit address; `ddr_addr = REMAP_BASE + (phys & ADDR_MASK)` done in ADDR_W width;
   bound SVA (VALID-stable, 32 B-aligned base, 4 KiB-safe burst, no R/W overlap).
   `ventium_l1_axi` wraps ven_l1d + the master; single clock (CDC_BYPASS, the clean
   first bring-up). The gate runs all four L1D scenarios THROUGH the AXI path against
   a MULTI-cycle behavioral DDR slave (RD/WR latency + mid-burst RVALID bubbles) plus
   store-miss→dependent-load ordering and the x86-phys→carveout remap end-to-end.
   * ven_l1d change (keeps L1D-GATE-OK): the write-HIT array commit is decoupled from
     the backing `m_ack` (commits as soon as it HITS) so a multi-cycle AXI write
     ack — which may arrive after the core drops c_req — never loses the array
     update. Same-cycle backing (the unit gate) is identical (commit clock == ack).
   * CDC: dual-clock (core clk vs a faster AXI clk via MMCM + a clean-license async
     FIFO) is a later optimization; a single PL clock to S_AXI_HPC0 is the low-risk
     first step and what ships here.
3. **PS integration: ✅ PROVEN (`fpga/scripts/bd_l1axi.tcl` → BD-L1AXI-OK).** A
   Vivado PS8 block design (`zynq_ultra_ps_e` board-preset + `ventium_l1_axi_top`
   [Verilog BD-reference wrapper, AXI X_INTERFACE attrs] → SmartConnect 32→128 →
   `S_AXI_HPC0_FPD`, AFI0 coherent, one PL clock) on `xck26-sfvc784-2LV-c`:
   `validate_bd_design` = 0 errors / **0 critical warnings**; `synth_design` =
   100% / 0 errors / 0 critical warnings (my RTL: 0/0/0); DRC related-violations
   `<none>` (only the expected UCIO unassigned-pin-LOC note — no board pinout, this
   is a subsystem-to-PS connectivity+synth proof, not a bitstream target). The L1
   256-bit lines map to LUT distributed RAM (0 BRAM), matching the icache P0-3
   finding. NOTE: this certifies "connects + elaborates + synthesizes cleanly to
   S_AXI_HPC0"; on-wire AXI protocol + coherency are certified by the Verilator gate
   + SVA (L1AXI-GATE-OK). The full-core `bus_mode=2` boot (the D-side miss-stall
   gate + the icache word-0 fill gate + pending_mem_pen suppression in core.sv, then
   `make verify --l1-axi` 75/75 + Quake lockstep) is the NEXT step (see §4a).
4. **Clocking:** MMCM (core clk + AXI clk) + reset sync (P1-3).

## 4a. Full-core bus_mode=2 boot (the on-chip path): ✅ WIRED + 76/77 VERIFIED
The WHOLE Ventium core now boots through the L1+AXI subsystem (`+VEN_L1_AXI` build,
`--l1-axi` / `l1axi_en`), functionally equivalent to bus_mode=0 (timing emergent).
All behind `` `ifdef VEN_L1_AXI `` (+ a `real_bus` core input tied 0 in modes 0/1) so
the DEFAULT build is byte-identical — **`make verify` stays GREEN (75/75 func + all
M4/M5 cycle bands), the mode-0 canary**.
* `ventium_top`: a mode-2 leg (`l1axi_en`) instantiates `ventium_l1_axi` between
  `core_mem_*` and the new `m_axi_*` top ports; the bus mux is 3-way (the existing
  modes 0/1 `else` branch is the exact original code); the direct mem_* port is held
  inert in mode 2 (all memory via m_axi). `verif/tb/Makefile` adds the `l1axi` target
  (`+VEN_L1_AXI` + `-DVEN_L1_AXI`); `tb_main.cpp` adds `--l1-axi` + a behavioral C++
  AXI4 DDR slave (pre-edge-capture synchronous model) off the same MemModel.
* core (all `` `ifdef VEN_L1_AXI ``): D-side fast-path MISS-STALL gate
  (`real_bus && pipe_load_req && !mem_ack` -> bubble); the I-side icache word-0 fill
  gate (`ic_pf_miss_fill` + the S_PIPE->S_PF launch now require `mem_ack` under
  real_bus — the BLOCKER, fixed); `pending_mem_pen` suppressed in mode 2.
* **ROOT-CAUSE fix in `ven_l1d` (the big one):** the core's mem port is
  BYTE-addressable (the BFM reads the 4 bytes at the exact byte addr — e.g. a
  slow-path `S_FETCH` of an instruction that straddles a 32-byte line). The L1 now
  extracts from the `{next_line, line}` 512-bit window at `c_addr[4:0]`, serving
  UNALIGNED and CROSS-LINE reads (a cross-line miss fills L then L+1); aligned
  accesses are unchanged (L1D/L1AXI gates stay green). This took mode-2 equivalence
  from 34/77 (aligned-only) -> 76/77.
* **VERIFY:** mode-0 vs mode-2 retire-trace equivalence across the microbench corpus
  = **76/77 bit-identical** (incl. the t_*/tx_* ISA tests). The lone failure is
  `tx_fsave` (FNSAVE: the 27-beat x87 state store stalls at beat ~12 in the cosim
  AXI handshake — to isolate as RTL-master vs C++-slave; the RTL alone is
  `L1AXI-GATE-OK`). Cross-line WRITES are handled conservatively (invalidate the
  cached line; the backing got the bytes) — a write-back path is the later refinement.

## 5. Reuse / replace
* `dcache_timing.sv` — REUSE the tag/val/LRU SM; ADD the data array (its data path
  is the missing piece, REVIEW_Jun5 Limit #4).
* `biu_p5.sv` / `biu.sv` — ORTHOGONAL (P5 pin-level bus exerciser, 19 SVA). Leave
  as the protocol-validation companion; the AXI master is a separate path.
* Verify in `ventium_top` (the bus_mode mux home), NOT `ventium_soc` (which routes
  mem_* directly) — port the L1+AXI to the soc top afterward.
