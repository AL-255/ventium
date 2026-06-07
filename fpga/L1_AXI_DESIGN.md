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
1. **L1 data array (task #10):** add the 8KB data array to a new `ven_l1d` (or
   extend dcache_timing) — same-cycle hit returns real data; miss falls through to
   the existing back-side `mem_*` (the TB / AXI). Verify `make verify` cycle-
   identical (the timing SM is unchanged; only the data source moves from the
   backdoor to the cache on hits). This is the first, independently-verifiable step.
2. **AXI4 master + CDC:** the miss-fill engine + the AXI4-master FSM (burst
   read/write) + the async FIFO CDC. Verify against an AXI VIP / a behavioral
   DDR model in the TB.
3. **Integration:** `ventium_top` `bus_mode=2` selects the L1+AXI path (keep
   `bus_mode=0` inert as today); wire `S_AXI_HPC0`. Re-run the full gates.
4. **Clocking:** MMCM (core clk + AXI clk) + reset sync (P1-3).

## 5. Reuse / replace
* `dcache_timing.sv` — REUSE the tag/val/LRU SM; ADD the data array (its data path
  is the missing piece, REVIEW_Jun5 Limit #4).
* `biu_p5.sv` / `biu.sv` — ORTHOGONAL (P5 pin-level bus exerciser, 19 SVA). Leave
  as the protocol-validation companion; the AXI master is a separate path.
* Verify in `ventium_top` (the bus_mode mux home), NOT `ventium_soc` (which routes
  mem_* directly) — port the L1+AXI to the soc top afterward.
