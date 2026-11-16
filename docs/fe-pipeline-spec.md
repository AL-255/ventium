# Front-End Fetch & Translation Pipeline Spec (`+VEN_FE_PIPE`)

> **Current Status (Nov 2026 — IMPLEMENTED & BOARD-QUALIFIED in `c0e3fe43`):** `VEN_FE_PIPE` (registered `fe_itlb_q` / `fe_dtlb_q` page filters), together with the **32-entry 4-way I-TLB** (`VEN_ITLB_ASSOC_4WAY`), **64-entry 4-way D-TLB** (`VEN_DTLB_ASSOC_4WAY`), dual-ported **256-entry 4-way BTB**, **4-entry RAS**, BRAM-backed **8 KiB 2-way L1 I-Cache** (`VEN_IC_BRAM` + `pf_fill_addr_rep[0..3]` fanout replication), and `VEN_UOPCACHE`, is deployed in RK-XCZU15EG-F release **`c0e3fe43`** (`40.264133 MHz` post-route STA sign-off, `WNS = +0.164 ns`, `0` `>=85%` congestion hotspots, `0.515778001` total U+V / `0.397847833` primary/U Quake gameplay IPC across cycles `28,696,827,616–32,989,404,795`).

---

## 1. Motivation: Breaking the Combinational `EIP` → TLB → Fetch Loop

Without front-end translation pipelining, every `S_PIPE` cycle evaluates a deep combinational loop from `eip` through the set-associative TLB tag compare, I-cache hit check, instruction-window muxing, and next-`eip` selection:

```text
eip ─▶ I-TLB / D-TLB associative tag compare (tlb_assoc.sv / tlb.sv)
    ─▶ I-cache tag/line hit check + byte-window / uop-cache read
    ─▶ Dual U+V decode length / branch target / page-walk diversion
    ─▶ next eip
```

Because virtual-to-physical translation only changes at **4 KiB page boundaries**, steady-state sequential fetches and same-page data accesses do not need to re-evaluate the full associative TLB CAM on every clock.

---

## 2. Implemented Front-End Architecture

### 2.1 Registered Page-Keyed Micro-TLBs (`VEN_FE_PIPE`)

`core.sv` maintains dedicated registered single-page translation filters for instruction fetch and data access so interleaved code/data pages never thrash a shared latch:

- `fe_itlb_q`: `{page[31:12], phys[31:12], hit, ...}` keyed on the fetch linear page.
- `fe_dtlb_q`: `{page[31:12], phys[31:12], hit, dirty, ...}` keyed on the data linear page.

Behavior:
- **Intra-page steady state (0-cycle overhead):** When `cur_lin[31:12]` matches `fe_*_q.page`, `xlate_miss` and physical address generation read `fe_*_q` directly from flip-flops, removing the 4-way `tlb_assoc.sv` compare cone from the `S_PIPE` critical path.
- **Page crossing (`fe_xlate_stall`):** When `cur_lin[31:12]` changes, the combinational `tlb_assoc` lookup is sampled into `fe_*_q` across a single 1-cycle stall bubble (or diverts to `S_WALK` on a backing TLB miss).
- **Coherence & Flush Safety:** Any `CR3` reload, `INVLPG`, `CR0.PG`/`PE`/`WP` write, SMM transition, or `tlb_fill_*` completion invalidates `fe_itlb_q` and `fe_dtlb_q` immediately so stale translations can never survive.

### 2.2 Backing Associative TLBs, I-Cache, BTB & Congestion Relief (`c0e3fe43`)

| Front-End Block | Implemented Configuration (`c0e3fe43`) |
| --- | --- |
| **I-TLB (`tlb_assoc.sv`)** | **32-entry, 4-way set-associative** (`VEN_ITLB_ASSOC_4WAY`, pseudo-LRU), eliminating direct-mapped code-page conflict misses (`+3.88%` gameplay IPC bundle). |
| **D-TLB (`tlb_assoc.sv`)** | **64-entry, 4-way set-associative** (`VEN_DTLB_ASSOC_4WAY`, pseudo-LRU, 4 KiB + 4 MiB PSE). |
| **L1 I-Cache (`icache.sv`)** | **8 KiB, 2-way, 32 B lines**, synchronous `8 × RAMB36` data (`VEN_IC_BRAM`), physical snoop tags (`ic_ptag`) for alias-safe SMC/DMA invalidation, replicated `pf_fill_addr_rep[0..3]` fill-address trees, and narrowed `ic_res_line_base` muxing. |
| **Branch Predictor (`bpred_btb.sv`)** | **Dual-ported 256-entry, 4-way BTB** (`VEN_BTB_PIPE`) with 2-bit bimodal saturating counters (simultaneous fetch lookup + retire update) and **4-entry Return Address Stack (RAS)**. |
| **Predecode / µop Cache** | `ven_predecode_len.sv` + `uopcache.sv` (`VEN_UOPCACHE`, `VEN_UOP_SFETCH`, `VEN_SFETCH_RESIDENT`), paired in Vivado with `opt_design -muxf_remap` to eliminate byte-window `MUXF7`/`MUXF8` routing hotspots (`0` `>=85%` windows on `c0e3fe43`). |

---

## 3. Verification Gates

- **Default Unit Mode (`VEN_FE_PIPE` off):** Preserves baseline `make verify` cycle-band calibration against `p5trace.so`.
- **Deployed UV-Fast + `VEN_FE_PIPE` Profile:** Verified architecturally bit-exact against pinned `qemu-system-i386` across `make verify`, `make verify-sys` (`pseg`, `pmode`, `ppage`, `pfault`, `xc04`), `make l1` (`run-ic-alias-gate.sh`, associative I/D-TLB gates), and the full physical FPGA standard suite (CoreMark, cold Windows 95 OSR2 GUI, and cold DOS Quake `demo1`).
