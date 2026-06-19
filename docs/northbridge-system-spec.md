# Ventium northbridge / full-system integration plan

Glue the standalone L2 (`rtl/northbridge/ven_l2.sv`) and the `rtl/soc/*`
peripherals into one coherent **Pentium-style system**, modeled on the Intel
**430FX "Triton"** PCIset (82437FX **TSC** system controller + 82436FX **TDP**
data path + 82371FB **PIIX** PCI-to-ISA bridge — datasheets archived under
`ventium-refs/01-intel-canonical/CHIPSET/`).

Locked scope decisions (2026-06-19):
* **Chipset model:** 430FX Triton (canonical desktop P5; our PCI-config shim
  already targets PIIX3).
* **DMA coherence:** fine-grained per-line **snoop-invalidate from the start**
  (the `EADS#`/`AHOLD` analogue) — no coarse `flush_all`-around-DMA interim.
* **Top level:** a **new `ventium_system` top**; `ventium_soc.sv` (differential
  oracle) and `ventium_kv260_core` stay intact so the regression suite keeps
  running while the new system matures.

Cross-refs: `fpga/L2_DESIGN.md` (the L2 it splices in), `docs/cache-tlb-structural-spec.md`,
`docs/m5b-bus-spec.md`, the L1AXI seam in `rtl/mem/ventium_l1_axi.sv`.

---

## 0. Starting reality (verified 2026-06-19)

* `ven_l1d` is **write-through** and caches **everything** — no cacheability /
  `KEN#` concept; only the coarse `flush_all` pulse and the `golden_l1`
  diagnostic exist. `icache` is fill-only, core-spine driven, also caches all.
* `ven_l2.sv` is **standalone, not instantiated** anywhere; it is a drop-in for
  the `ven_l1d.m_* → ven_axi_master.m_*` word-granular backing seam.
* **No snoop / coherence mechanism exists.** IDE bus-master DMA (`ven_ide`,
  `HAS_DMA=1`, real `dma_mem_*` port) and the fw_cfg DMA engine write DRAM with
  zero L1/icache invalidation; the differential suite only dodges staleness by
  **parking the core** (`core_mem_ack=0`) during a DMA burst. `ven_i8237` is
  **register-only** (no transfer engine yet).
* Two disjoint worlds: `ventium_soc.sv` wires `core` **directly** to memory
  (DMA-priority mux + VGA-fb intercept, RTL peripherals, the QEMU differential
  oracle); `ventium_kv260_core` uses `ventium_l1_axi` → PS-DDR with some
  peripherals PS-emulated. Neither has a cacheability map or DMA snoop.
* Port-I/O (`io_*`) is already a **separate bus** from `mem_*`, so it is
  inherently uncacheable. The only thing the caches must learn to *not* cache is
  **MMIO that lives in memory address space** (VGA aperture, BIOS/option-ROM
  windows, the PCI memory hole, APIC).

---

## 1. The coherence model (the heart of it)

Key invariant we get for free: **L1D is write-through**, so the CPU's L1 is
never *dirtier* than downstream ⇒ **L2 is the single coherence point for DRAM**.

| Master | Action | Requirement | Mechanism |
|---|---|---|---|
| CPU | r/w cacheable DRAM | normal | icache/L1D → L2 → DDR (`KEN#`=1) |
| CPU | r/w MMIO (mem-space) | never cache | `KEN#`=0 → bypass L1D **and** L2, straight to bridge/DDR |
| DMA | **read** DRAM | see latest (dirty L2) | DMA routed *through* L2 ⇒ coherent (L1 ⊆ L2 by write-through) |
| DMA | **write** DRAM | invalidate stale CPU copies | DMA write updates L2 **and** northbridge issues a **per-line snoop-invalidate** to L1D + icache |

Two new coherence primitives:
1. **A cacheability decoder** (`KEN#` generator) shared by icache, L1D, L2, and
   the bridge router — decided **once**, at the host-bus boundary, honored by all.
2. **A per-line snoop-invalidate port** on `ven_l1d` and `icache`, driven by the
   northbridge whenever a non-CPU master writes a cacheable line.

DMA masters become **arbitrated requesters on the L2 upstream port** (not a
parallel path to DDR): that makes reads coherent for free and gives one place to
hang the invalidations. Fine-grained snoop removes the need to park the core
during DMA (the core may keep running against L1/L2 while DMA proceeds).

---

## 2. `ven_cachemap` — "what to cache and what not to" (the TSC PAM model)

Combinational `addr[31:0] → {cacheable, region}`, modeled on the TSC PAM +
cacheable-region registers. Faithful default layout:

* `0x00000000 … TOM-1` — **cacheable WB DRAM**, minus the optional 15–16 MB ISA
  memory hole.
* `0x000A0000 … 0x000BFFFF` — VGA aperture / SMRAM: **uncacheable** (SMRAM
  cacheability is a config bit; default uncached).
* `0x000C0000 … 0x000FFFFF` — option-ROM + BIOS shadow, per **PAM0–PAM6** (each
  PAM nibble = one 16/32/64 KB segment, R/W-enable + cacheable, per the TSC datasheet).
* `TOM … 0xFFFDFFFF` — **PCI memory hole: uncacheable** (MMIO BARs, framebuffers,
  APIC `0xFEC/0xFEE`).
* `0xFFFE0000 … 0xFFFFFFFF` — top-of-4 G BIOS shadow: cacheable per PAM (the
  SeaBIOS 32-bit POST region already special-cased in the L1AXI remap).

* PAM / TOM / hole-enable registers live in **PCI config bus0:dev0 (host
  bridge)** — extend the existing PCI-config shim. BIOS programs them at boot; we
  ship sane reset defaults so bring-up doesn't depend on BIOS.
* One module, used in four places, so the decode can never disagree with itself.
* Unit-gated against a golden address→attribute table from the TSC datasheet.

---

## 3. Teaching the caches `KEN#` (L1D / icache edits — additive, default-inert)

* **`ven_l1d`**: add `cacheable` input — when `0`, no allocate / no hit-lookup,
  the access passes straight to the backing master and the ack is forwarded
  (uncacheable bypass). Add `snoop_inv_valid / snoop_inv_addr` that invalidates a
  matching line independent of the core port.
* **`icache`**: same `cacheable` gate on fills + same snoop-invalidate input
  (covers DMA-loaded code).
* Keep `flush_all` as the cosim fallback.

Regression contract: with `cacheable` tied 1 and snoop tied 0, every existing
gate stays **byte-identical**.

---

## 4. Target topology

```
            ┌──────────────────────────────────────────────────────────────┐
   core ───►│ icache (KEN#, snoop)        ven_l1d (KEN#, WT, snoop)         │
  mem_*     └───────────────┬───────────────────────┬───────────────────────┘
                            │ host backing port (one CPU requester)
                            ▼
        ┌──────────────────────── ven_northbridge (TSC/TDP) ────────────────────────┐
        │  ven_cachemap (PAM+TOM)   requester arbiter   snoop/invalidate generator   │
        │        │ cacheable           ▲   ▲                    │                     │
        │        ├─────────────► ven_l2 ──► ven_axi_master ─────┼──► AXI4 → PS-DDR     │
        │        │ uncacheable         │   │                    │                     │
        │        └─────────────► MMIO/bypass router ────────────┼──► DDR-direct/bridge │
        └───────────────────────────────┼───┼───────────────────┼──────────────────────┘
   io_* (port I/O, uncacheable) ────────┼───┼─ DMA master ports ─┘ (snoop-inv → L1/IC)
                                        ▼   │
        ┌──────────────────── ven_southbridge (PIIX) ───────────────────────┐
        │ PIC PIT RTC i8042 i8237(DMA) i8272 IDE(busmaster DMA) UART         │
        │ ACPI-PM port92 VGAregs  +  PCI-config (host PAM regs, IDE BAR)     │
        └────────────────────────────────────────────────────────────────────┘
```

`ven_northbridge` = TSC/TDP (host bus, cachemap, arbiter, L2, DDR master, snoop
generator). `ven_southbridge` = PIIX (the `rtl/soc/*` peripherals + PCI-config,
reused near-verbatim, exposing the DMA bus-master ports upward).

---

## 5. Implementation ladder (each phase independently gated)

* **Phase A — cachemap + `KEN#` in the caches.** `ven_cachemap` + unit gate; add
  `cacheable`/snoop ports to `ven_l1d` & `icache`; prove byte-identical with
  inert defaults. No topology change yet.
* **Phase B — L2 spliced behind L1D (cacheable path).** Rewire
  `ven_l1d.m_* → ven_l2.u_*` and `ven_l2.d_* → ven_axi_master.m_*` (the pure
  rewire the L2 was built for). Re-run existing L1AXI boot/differential gates
  (L2 transparent for cacheable) + add an L2 hit/eviction perf check.
* **Phase C — `ven_northbridge` wrapper + uncacheable bypass.** Wrap {cachemap,
  arbiter, L2, axi_master, bypass router}; route uncacheable mem-space (VGA
  aperture, BIOS, hole) around L2; fold the current VGA-fb intercept into the
  router so it works *with* caching on.
* **Phase D — `ven_southbridge` + DMA as coherent requesters + fine-grained
  snoop.** Wrap `rtl/soc/*`; lift `ven_ide.dma_mem_*` and a **new `ven_i8237`
  transfer engine** into the arbiter as upstream requesters **through L2**; drive
  per-line snoop-invalidate to L1D/icache on every cacheable DMA write; remove
  core-parking. Directed coherence gates here.
* **Phase E — unify the top.** New `ventium_system`:
  `core → L1/icache → ven_northbridge → {L2/DDR, ven_southbridge}`. Port the
  differential suite + FreeDOS boot onto it; prove byte-identical.
* **Phase F — hardening.** Real-BIOS-driven PAM; SMRAM cacheability bit; the
  `L2_DESIGN.md` §5 follow-ons (writeback buffer, burst writeback, SECDED ECC,
  prefetcher, L2 flush-walker); optional snoop-cycle timing fidelity
  (AHOLD/EADS#/HITM# on the modeled P5 bus).

---

## 6. Verification

* Every phase A–E keeps the existing suites **byte-identical** in the
  inert/default state, plus a **new directed gate** per feature.
* New gates: (1) cachemap golden-table; (2) `KEN#` bypass (uncacheable r/w
  correct, no allocation); (3) **DMA-write → CPU-read coherence**; (4) **DMA-read
  of dirty L2**; (5) icache invalidate on DMA'd code.
* Reuse `verif/l1/run-l2-*.sh` + the `ventium_soc` differential flow.

---

## 7. Risks / open issues

* **Single-outstanding L2 + multi-requester arbiter** — DMA bursts lock the
  arbiter for the burst (acceptable, mirrors bus mastering). Fine-grained snoop
  lets the core run concurrently; confirm the arbiter ↔ snoop ordering is
  race-free (a DMA write must invalidate before the CPU can re-read the line).
* **icache coherence vs existing SMC handling** — don't double-handle.
* **Two-worlds reconciliation** — the new top must preserve the differential
  oracle path or the regression suite can't run; keep `ventium_soc.sv` alive.
* **Fmax** — design is routing-bound ~35–50 MHz and the L2 is off the critical
  path; keep the cachemap/arbiter mux shallow/registered so the host path
  doesn't become critical.
