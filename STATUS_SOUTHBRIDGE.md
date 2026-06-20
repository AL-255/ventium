# STATUS — Northbridge / Southbridge full-system integration

**As of 2026-06-19.** Working status of gluing the standalone L2 cache
(`rtl/northbridge/ven_l2.sv`) and the `rtl/soc/*` peripherals into one coherent
Pentium-style system. This is the live tracking doc; the design rationale lives in
[`docs/northbridge-system-spec.md`](docs/northbridge-system-spec.md).

> TL;DR — **Phases A, B, C, and Phase D step 1 (the coherence core) are DONE and
> gated.** The cacheability map, the L2 splice behind L1, the cacheable-vs-MMIO
> routing, the L1 `KEN#`, and a coherent DMA bus master (arbiter + snoop-invalidate)
> all work and pass 13 unit gates. **What remains is integration/peripheral work:**
> the `ven_southbridge` wrapper, a real `ven_i8237` transfer engine, PCI-config-driven
> cacheability registers, a separate MMIO master, icache snoop, and the unified
> `ventium_system` top (Phase E). Nothing here is wired into the board build yet
> (`EN_L2` defaults off), so the running system is unchanged.

---

## 1. Goal and reference model

Build a faithful **Intel 430FX "Triton" PCIset** memory/IO subsystem around the
Ventium P5 core:

* **Northbridge = 82437FX TSC + 82436FX TDP** (system controller + data path): owns
  the host bus, the cacheability map, the L2, the DRAM/AXI path, the requester
  arbiter, and the snoop generator.
* **Southbridge = 82371FB PIIX** (PCI-to-ISA bridge): the legacy peripherals
  (`rtl/soc/*`), IDE, DMA, interrupts, timers, plus PCI config.

The authoritative chipset register definitions come from the datasheets the user
archived under `ventium-refs/01-intel-canonical/CHIPSET/` (the 82437FX TSC datasheet
§3.2 is the source for the cachemap below).

**The central correctness idea:** cacheability is decided **once**, at the host-bus
boundary (`ven_cachemap`), and honored identically by the icache, the L1 D-cache, the
L2, and the bypass router — the P5 `KEN#`/`CACHE#` model. Port-I/O (`IN`/`OUT`, the
core's separate `io_*` bus) is inherently uncacheable; the only thing the caches must
learn to *not* cache is **MMIO that lives in memory address space** (the VGA aperture,
BIOS/option-ROM windows, the PCI memory hole, APIC).

---

## 2. Target topology

```
            ┌──────────────────────────────────────────────────────────────────┐
   core ───►│ icache (KEN#, snoop*)        ven_l1d (KEN#, write-through, snoop)  │
  mem_*     └───────────────┬──────────────────────────┬───────────────────────┘
                            │ host backing port (the CPU requester)
                            ▼
        ┌──────────────────────── ven_northbridge (TSC/TDP) ────────────────────────┐
        │  ven_cachemap (PAM+TOM)   CPU/DMA arbiter   snoop-invalidate generator      │
        │        │ l2_cacheable?       ▲   ▲                    │ snoop_inv_*          │
        │        ├─────────────► ven_l2 ──► (downstream backing) │  (→ L1D, icache*)   │
        │        │ uncacheable         │   │                    │                      │
        │        └─────────────► bypass router ──────────────────┼─────────────────────┤
        └────────────────────────────────┼──┼────────────────────┘                     │
                                          ▼  │ DMA requester (dma_*)                     │
                          ven_axi_master / ven_axi_cdc ──► AXI4 ──► PS-DDR               │
                                                                                          │
   io_* (port I/O, uncacheable) ─────────────────────────────► ven_southbridge* (PIIX)  │
                                                                 (rtl/soc/* + PCI cfg)   │
                                                                                          │
   (* = not yet built — see §11)                                                          │
```

Current reality vs. target: `ven_l1d` + `ven_l2` + `ven_axi_master` + `ven_cachemap`
+ `ven_northbridge` all exist and are wired inside `rtl/mem/ventium_l1_axi.sv` behind
`EN_L2`. The southbridge, the DMA-producing peripherals, the second downstream MMIO
master, and the icache snoop wire are **not yet built**.

---

## 3. The coherence model (implemented)

`ven_l1d` is **write-through** ⇒ the CPU's L1 is never *dirtier* than what's
downstream ⇒ **the L2 is the single coherence point for DRAM.** That collapses the
problem to two primitives, both now in place:

| Master | Action | Requirement | Mechanism (status) |
|---|---|---|---|
| CPU | r/w cacheable DRAM | normal | L1D → L2 → DDR (`KEN#`=1) — **done** |
| CPU | r/w MMIO (mem-space) | never cache | `KEN#`=0 → L1D non-allocating bypass; NB routes around L2 — **done** |
| DMA | **read** DRAM | see latest (dirty L2) | DMA routed *through* the L2 (arbiter) — **done** |
| DMA | **write** DRAM | invalidate stale CPU copies | NB pulses per-line `snoop_inv` → L1D — **done** (icache wire pending) |

The L1 being write-through means an **invalidate** is sufficient on a DMA write (no
write-back from the L1). The snoop is the EADS#/inquire-cycle analogue.

---

## 4. Phase status

| Phase | Scope | Status | Commit |
|---|---|---|---|
| **A** | `ven_cachemap` + `KEN#`/snoop ports on `ven_l1d` & `icache` | ✅ done | `c8dbf3b` (new files); RTL in `1fda887`† |
| **B** | Splice `ven_l2` behind L1D (`EN_L2`), L2-ready reset gate, `VEN_DBG_L2` counters | ✅ done | `d9ba8d3` |
| **C** | `ven_northbridge` (cachemap + L2 + bypass router); drive L1D `KEN#` | ✅ done | `d9ba8d3` |
| **D.1** | Coherent DMA requester + CPU/DMA arbiter + snoop-invalidate generation | ✅ done | `938d110` |
| **D.2** | `ven_southbridge` wrapper for `rtl/soc/*` | ⬜ pending | — |
| **D.3** | Real `ven_i8237` transfer engine (today register-only) | ⬜ pending | — |
| **D.4** | PCI-config shim drives the cachemap `cfg_*` registers | ⬜ pending | — |
| **D.5** | Separate MMIO master for `to_dram=0` + single-beat granularity | ⬜ pending | — |
| **D.6** | Wire NB snoop to the **icache** (DMA-loaded code) | ⬜ pending | — |
| **E** | Unified `ventium_system` top; port differential suite + FreeDOS | ⬜ pending | — |
| **F** | Hardening (BIOS-driven PAM, L2 §5 follow-ons, snoop-cycle timing) | ⬜ pending | — |

† The A/B *RTL edits* (`ven_l1d`/`icache`/`core.sv`) were swept into the in-flight
core commit `1fda887` by a parallel committer; only the new files landed in the
phase commits. See §10 (commit state).

All northbridge commits are **local — not pushed to origin.**

---

## 5. What's built — module by module

### 5.1 `rtl/northbridge/ven_cachemap.sv` (Phase A)
Pure-combinational 430FX TSC cacheability decoder. **Inputs:** `addr`, `is_write`,
`is_code`, `smm_active`, and the TSC config registers (`pam[55:0]`, `dramc`, `cc`,
`tom_mb4`, `smram`). **Outputs:** `to_dram` (main memory vs forward-to-PCI/MMIO),
`l1_cacheable` (the `KEN#`), `l2_cacheable` (write-back), `region[3:0]` (debug).

Config registers are **inputs** because the storage belongs in PCI config space
(bus0:dev0); Phase D.4 wires the PCI-config shim to them. Used by value in the L1
`KEN#` map in `ventium_l1_axi` and the routing map inside `ven_northbridge`, so the
decode can never disagree. The exact register/window model is in §6.

### 5.2 `rtl/mem/ven_l1d.sv` (Phase A edits — in `1fda887`)
Added two faithful primitives, both **gated to be byte-identical when off**:
* `cacheable` input — when 0, a **non-allocating bypass**: a read fetches the line
  into a private `bp_line` buffer and serves the word via a new `L1_BYP` state (no
  allocate, no LRU); a write goes straight write-through. (An uncacheable address has a
  stable PAM attribute, so it is never resident — no force-miss needed.)
* `snoop_inv_valid`/`snoop_inv_addr` — per-line invalidate; clears the matching
  `{set,way}` valid bit. Placed LAST in the FF so it wins over a same-cycle allocate.

### 5.3 `rtl/mem/icache.sv` (Phase A edits — in `1fda887`)
Added `snoop_inv_valid`/`snoop_inv_addr` (per-line invalidate, last-write-wins). The
fetch-side `KEN#` (not caching MMIO *code*) is spine-resident and **not yet driven**
— deferred to D.6. The snoop input is currently tied 0 at the `core.sv` instantiation.

### 5.4 `rtl/northbridge/ven_l2.sv` (pre-existing, now wired)
The 2 MiB / 8-way write-back UltraRAM L2. Unchanged in this work except that it is now
*instantiated* (inside `ven_northbridge`). Its `VEN_DBG_CORE` perf counters
(`dbg_hits`/`dbg_misses`/`dbg_wbacks`) are surfaced upward.

### 5.5 `rtl/northbridge/ven_northbridge.sv` (Phase C + D.1)
The TSC cache+route+arbiter+snoop layer. Presents the **same word-granular backing
protocol** as `ven_l2` on both ports (a drop-in for the bare-L2 slot). Internals:
* **Arbiter:** CPU (`u_*`) vs DMA (`dma_*`) into the single L2 upstream. The grant is
  **locked for the whole transaction** (a read = `WORDS` acks, a write = 1 ack), DMA
  wins when both arrive idle. Active requester muxed to `a_*`.
* **`ven_cachemap`** on `a_addr`/`a_we` → `route = l2_cacheable`.
* `route=1` → through `ven_l2`; `route=0` → **bypass** straight to the downstream
  backing (DDR). Single-outstanding ⇒ combinational steer mux, no latch.
* **Snoop generation:** on a completed DMA **write**, pulse `snoop_inv_valid`+`addr`
  one clock. Uses grant-time **latched** `{lk_we, lk_addr, lock_dma}` + `last_ack`
  (the L2's clean registered ack) — *not* the combinational requester signals, which
  a synchronous master drops at the ack edge.
* **Config (`cfg_*`):** inputs (constants from `ventium_l1_axi` params for now).
* **Debug (`VEN_DBG_CORE`):** `dbg_hits/misses/wbacks` (pass-through) + `dbg_bypass`
  (per uncacheable transaction).

### 5.6 `rtl/mem/ventium_l1_axi.sv` (Phase B/C/D.1)
The integration point. Key knobs (parameters):

| Param | Default | Meaning |
|---|---|---|
| `EN_L2` | `1'b0` | 0 = L2 bypassed, **byte-identical** to pre-L2 (incl. AXI traffic shape); 1 = northbridge in the datapath |
| `L2_CAP_BYTES` | `2*1024*1024` | L2 capacity (all 64 URAM at default) |
| `L2_WAYS` | `8` | L2 associativity |
| `NB_CC` | `8'h41` | Cache Control: FLCE=1, SCS=01, SCFMI=0 |
| `NB_DRAMC` | `8'h01` | DRAM Control: HEN=00 (no memory hole) |
| `NB_TOM_MB4` | `8'd255` | Top of memory in 4-MiB units (~1020 MiB cacheable) |
| `NB_PAM` | `56'h0` | PAM0-6: ROM windows uncacheable by default |
| `NB_SMRAM` | `8'h00` | SMRAM control |

Structure: `ven_l1d` (outside the generate) → `b_*` (post-L2 backing) → AXI master /
CDC. The `EN_L2` generate (`g_l2`) instantiates `ven_northbridge` + a second
`ven_cachemap` (on `core_addr`) that drives `ven_l1d.cacheable` (`KEN#`); the `g_nol2`
branch ties everything transparent. **Both `ven_cachemap` and `ven_northbridge` live
INSIDE the `EN_L2` generate**, so `EN_L2=0` builds don't even need those files
(Verilator prunes the false branch — confirmed: the existing L1AXI gates compile
without them in their filelists). The L1 reset is gated on `l2_ready`
(`.rst_n(l1d_rst_n & l2_ready)`) so the core is held until the L2 init valid-clear
walk completes.

**DMA port (gated `VEN_NB_DMA`):** a coherent DMA requester port exposed on the module
boundary, feeding `ven_northbridge.dma_*`; the NB's `snoop_inv_*` routes internally to
`ven_l1d.snoop_inv_*`. Gated so `ventium_top` / the board build are untouched (no
plumbing churn). `EN_L2=0` → snoop tied 0, byte-identical.

**Debug ports (gated `VEN_DBG_L2`):** `dbg_l2_ready`, `dbg_l2_hits`, `dbg_l2_misses`,
`dbg_l2_wbacks`, `dbg_l2_bypass`. A gate-only define (separate from `VEN_DBG_CORE`) so
`ventium_top` is untouched.

---

## 6. The cachemap register model (430FX TSC — faithful)

From the 82437FX TSC datasheet §3.2. PCI config bus0:dev0 (host bridge):

| Reg | Offset | Field | Effect |
|---|---|---|---|
| **CC** | 0x52 | FLCE[0] | first-level cache enable (asserts `KEN#`) |
| | | SCFMI[1] | secondary-cache force-miss |
| | | SCS[7:6] | L2 size (00 = not populated/disabled) |
| **DRAMC** | 0x57 | HEN[7:6] | memory hole: 01 = 512K–640K, 10 = 15M–16M → forwarded to PCI |
| **PAM0–6** | 0x59–5F | nibble `{Rsvd, CE, WE, RE}` | per-segment: RE=read→DRAM, WE=write→DRAM, CE=L1 cacheable |
| **DRB4** | 0x64 | 8-bit | top of DRAM in 4-MiB units (`TOM = DRB4 << 22`) |
| **SMRAM** | 0x72 | DEN[3], DOPEN[6] | SMM aperture enable/open (A0000–BFFFF) |

PAM nibble semantics (datasheet Table): `CE=1` ⇒ L1 cacheable; `CE` must be 0 when
`RE=0`; `CE=1 & WE=0` (read-only) ⇒ L1-cacheable on **code reads only** and **never in
L2**; `RE & WE` (read/write) ⇒ cached in **L1 and L2**.

Fixed (non-programmable) windows:

| Range | Region | Routing / cacheability |
|---|---|---|
| `0x00000–0x9FFFF` | DOS area | cacheable DRAM (minus 512K–640K hole if HEN=01) |
| `0xA0000–0xBFFFF` | video / SMRAM | → PCI, **uncacheable** (or DRAM+cacheable if SMRAM open / SMM) |
| `0xC0000–0xFFFFF` | option-ROM + BIOS | per PAM0–6 |
| `0x100000–(TOM-1)` | extended main memory | cacheable DRAM (minus 15M–16M hole if HEN=10) |
| `TOM–0xFFFFFFFF` | PCI memory space | **always uncacheable**, → PCI (incl. APIC `0xFEC/0xFEE`, top-of-4G BIOS shadow) |

`l1_cacheable = FLCE & CE & RE & (WE | is_code)`;
`l2_cacheable = FLCE & SCS≠0 & ~SCFMI & CE & RE & WE`.

> Phase-C scope note: `to_dram` (DRAM vs forward-to-PCI) is computed but **not yet
> used to split the downstream** — both the L2 path and the bypass currently share one
> DDR downstream. The separate MMIO master that honors `to_dram=0` is Phase D.5.

---

## 7. Data-flow walkthroughs (EN_L2=1)

* **CPU read, cacheable DRAM:** L1D hit → same-cycle. L1D miss → `m_*` → NB arbiter
  grants CPU → cachemap `route=1` → L2 (hit returns; miss → DDR fill, forward-during-
  fill) → 8 words → L1D allocates.
* **CPU read/write, MMIO (mem-space):** `ven_cachemap` on `core_addr` → `l1_cacheable=0`
  → L1D **non-allocating bypass** → `m_*` → NB → `route=0` → straight to DDR (today;
  southbridge MMIO in D.5). Nothing cached.
* **CPU write, cacheable:** write-through. L1D RMW (on hit) + forward to L2 (write-back,
  dirty). DDR written only on L2 eviction.
* **DMA write, cacheable:** `dma_*` → NB arbiter (DMA priority) → L2 (write-allocate /
  RMW, dirty). On completion, NB pulses `snoop_inv` → L1D drops its stale copy. CPU's
  next read of that line misses L1 → L2 → the DMA-written data. **Coherent.**
* **DMA read, cacheable:** `dma_*` → NB → L2. If the CPU had written the line
  (write-through → L2, possibly dirty), the DMA read returns it (not stale DDR).
* **DMA write, uncacheable:** bypass → DDR. `snoop_inv` still pulses (harmless — no
  cache holds an uncacheable line).

---

## 8. Debug features (for future validation)

* **L2 perf counters** — `ven_l2` `dbg_hits`/`dbg_misses`/`dbg_wbacks` (`VEN_DBG_CORE`),
  plus `ven_northbridge` `dbg_bypass`, surfaced at the `ventium_l1_axi` boundary via
  the gate-only **`VEN_DBG_L2`** define as `dbg_l2_ready/hits/misses/wbacks/bypass`.
* **`EN_L2` A/B knob** — flip the L2 on/off for differential validation.
* **L1D `golden` mode** + `flush_all` (pre-existing) for cache-staleness triage.
* **L2-ready reset gating** — clean trace starts (core held until init walk done).
* Future PS-side observability: route these counters into `ven_soc_dbg` (Phase E).

---

## 9. Verification

All gates are standalone Verilator `--binary` unit gates; run from the repo root.
**13/13 pass** as of this status.

| Gate | Proves |
|---|---|
| `verif/l1/run-cachemap-gate.sh` | 25 golden address→{to_dram,l1,l2} checks vs the TSC datasheet |
| `verif/l1/run-l1d-gate.sh` | L1D incl. the new non-cacheable bypass [9] + snoop-invalidate [10] |
| `verif/l1/run-l1l2-gate.sh` | L1+L2 (through the NB): hit-after-flush = no new AR; dirty-eviction AW writeback |
| `verif/l1/run-l1nb-gate.sh` | cacheable→L2 vs uncacheable(0xA0000)→bypass; MMIO not L1/L2-cached |
| `verif/l1/run-l1dma-gate.sh` | **DMA coherence**: DMA-write snoop-invalidate; DMA-read sees dirty L2; arbiter interleave |
| `run-l1axi-gate / -xline / -xword / -callret / -wd / -cdc` | the pre-L2 L1/AXI seam, **byte-identical** (`EN_L2=0`) |
| `run-l2-gate / -l2-axi-gate` | bare `ven_l2` (unchanged) |

`make verify` (the full differential CPU suite) is **unaffected** by all of this:
`ventium_l1_axi` is a `+VEN_L1_AXI`-only module, not in the default `rtl/ventium.f`
build, and Phase D made no `core`/`icache`/`ven_l1d` change. Last `make verify` run:
**96 PASS / 1 FAIL**, the 1 being the documented pre-existing `tx_fprem` (x87).

**Environment note:** the `-O3 -march=native -j32` Verilator C++ build OOMs `cc1plus`
on this box. Build the default model with
`make -C verif/tb rtl VL_OPT_FAST=-O0 VL_OPT_MARCH=` (`verify.sh` *reuses*
`obj_dir/tb_ventium`, it does not rebuild).

Quick re-verify of all 13 gates:

```sh
cd <repo root>
for g in cachemap l1d l1l2 l1nb l1dma \
         l1axi l1axi-xline l1axi-xword l1axi-callret l1axi-wd l1axi-cdc \
         l2 l2-axi; do
  ./verif/l1/run-$g-gate.sh >/dev/null 2>&1 && echo "PASS $g" || echo "FAIL $g"
done
```

Expect 13× PASS.

---

## 10. Commit state

| Commit | Contents | Pushed? |
|---|---|---|
| `c8dbf3b` | Phase A new files: `ven_cachemap.sv`, `tb_cachemap`, `tb_l1l2`, gates, spec | no |
| `d9ba8d3` | Phase B/C: `ven_northbridge.sv`, `ventium_l1_axi` L2/cachemap, `tb_l1nb` | no |
| `938d110` | Phase D.1: NB DMA requester + arbiter + snoop, `tb_l1dma` | no |
| (`1fda887`) | A/B **RTL** edits to `ven_l1d`/`icache`/`core.sv` — swept in by a parallel committer | — |

**Important git hygiene:** a parallel agent/committer is independently committing the
in-flight core/VGA/FPU work during these sessions, and has at times switched the
working tree to feature branches (e.g. `stub-hook`) and clobbered untracked files
(this STATUS doc was wiped once and recreated). When committing this work, **stage only
the northbridge/L1/L2/gate files explicitly** — never `git add -A`. Do **not** stage
`core_*.svh`, `ventium_sys_pkg.sv`, `fpu_*`, `tb_main.cpp`, `sw/ps/*`, etc.; those
belong to the parallel in-flight core work. Track this doc so it survives branch churn.

---

## 11. Remaining work (detailed)

### D.2 — `ven_southbridge` wrapper
Wrap the existing `rtl/soc/*` peripherals (PIC, PIT, RTC, i8042, i8237, i8272, IDE,
UART, ACPI-PM, port92, VGA regs) + the PCI-config shim behind one decode front, with
the port-I/O (`io_*`) bus in and the DMA bus-master ports (`ven_ide.dma_mem_*`, the new
i8237 engine) out toward the northbridge. Mostly structural — the peripherals already
exist and are instantiated in `rtl/soc/ventium_soc.sv` today.

### D.3 — real `ven_i8237` transfer engine
`ven_i8237` is currently **register-only** (it stores channel addr/count/mode but never
moves data; the actual DREQ/DACK/TC transfer is an oracle boundary). A real engine must
walk a transfer and present a `dma_mem_*` master that the NB arbitrates through the L2.

### D.4 — PCI-config drives the cachemap registers
Extend the existing PCI-config shim (in `ventium_soc.sv`) with the host-bridge
registers (PAM0-6, DRAMC, CC, DRB4, SMRAM) and route them to
`ven_northbridge.cfg_*` / the L1 cachemap, replacing the `NB_*` parameter constants.
Then BIOS shadow/cacheability programming works for real.

### D.5 — separate MMIO master (honor `to_dram=0`)
Today the bypass and the L2 share one DDR downstream. Add a second downstream master
that routes `to_dram=0` (uncacheable device space) to the southbridge MMIO fabric
instead of DDR, with single-beat (not 8-word-line) granularity for side-effect
registers. This is what makes a memory-mapped VGA framebuffer / PCI BAR actually reach
its device through the new system (vs. the current `ventium_soc.sv` ad-hoc intercept).

### D.6 — icache snoop
Route `ven_northbridge.snoop_inv_*` to the icache too (it already has the port from
Phase A) so DMA-loaded **code** is coherent. Requires threading the snoop from
`ventium_l1_axi` up to the `core.sv` icache instantiation (currently tied 0).

### E — unified `ventium_system` top
A new top: `core → L1/icache → ven_northbridge → {L2/DDR, ven_southbridge}`. Keep
`ventium_soc.sv` (the differential oracle) and `ventium_kv260_core` intact so the
regression suite keeps running. Port the differential suite + FreeDOS boot onto it and
prove byte-identical. Then flip `EN_L2=1` on the board path.

### F — hardening
BIOS-driven PAM in anger; SMRAM cacheability; the `ven_l2` §5 follow-ons (writeback
buffer, burst writeback, SECDED ECC, prefetcher, flush walker); optional snoop-cycle
timing fidelity (AHOLD/EADS#/HITM# on the modeled P5 bus).

---

## 12. Gotchas / footguns (learned the hard way)

1. **Snoop & transaction-complete must use grant-time LATCHED `we`/`addr`, not the
   combinational requester signals.** A synchronous master (and the TB) deasserts
   `dma_req`/`dma_we` at the ack edge; a combinational `a_we` then reads 0 at ack, so
   `last_ack` never fires → the arbiter lock **sticks** (whole subsystem wedges) and
   the snoop is missed. Fixed in `ven_northbridge` (`lk_we`/`lk_addr`/`lock_dma`).
2. **The L2 reshapes AXI traffic** (write-back absorbs stores until eviction), so
   `EN_L2=1` is **not** byte-identical at the AXI-pattern level — that's why `EN_L2`
   defaults 0 and the AXI-pattern gates (`xword`/`xline`) keep it 0. Only the new
   `l1l2`/`l1nb`/`l1dma` gates use `EN_L2=1`.
3. **Keep new modules inside the `EN_L2` generate** so `EN_L2=0` builds don't need
   `ven_cachemap.sv`/`ven_northbridge.sv` in their filelists (Verilator prunes the
   false branch).
4. **Multiple-driver hazard** on the debug counters across `ifdef VEN_DBG_CORE` +
   `generate` — drive defaults in exactly one place (see the `g_dbg0` pattern).
5. **Cacheability must reach the L1 too** (`KEN#`), not just the L2 — else the L1
   caches MMIO and serves stale. Driven by a second `ven_cachemap` on `core_addr`.
6. **Pre-existing stale testbenches**: several L1 tbs (`tb_l1d`, `tb_l1_axi`,
   `tb_l1axi_wd`, `tb_l1axi_cdc`) didn't bind the `golden`/`golden_l1` ports added to
   the RTL later; those gates were red at HEAD and were fixed in passing.
7. **Two cachemap instances** (one on `core_addr` for L1 `KEN#`, one on the NB's active
   address for routing) — they agree because an address's PAM attribute is stable and a
   32-byte line never straddles a ≥16 KiB-aligned cacheability region.
