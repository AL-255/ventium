# P54C cache / TLB structural-fidelity spec (DEFERRED, multi-milestone)

Status: **SPEC ONLY — structural fidelity, multi-milestone, DEFERRED.** Captures
REVIEW_Jun5.md Limit #3 and Recommended-Next-Step 3 ("If structural, add a real
D-cache data/MESI/writeback model and a more P54C-shaped TLB"). This is a large
structural change that replaces correctness/timing models with data-holding
structures; it perturbs every cache/TLB-timing band and needs new microbenchmarks
and (for MESI/writeback) a bus integration. NOT implemented now.

Owner doc; touches no `rtl/` and no Makefile.

---

## 1. What exists today (verified against code)

### TLB — `rtl/mem/tlb.sv`
- **16-entry, DIRECT-MAPPED**, indexed by `lin[15:12]` (`tlb_idx`, line 80–82),
  one instance per side (`IS_D=0` I-TLB, `IS_D=1` D-TLB).
- Correctness model only: the 2-level page-walk FSM (PDE/PTE reads, A/D
  writeback, #PF/CR2/error-code) stays in the core spine; this module is just
  the arrays + combinational lookup + pulsed fill + CR3 flush (header lines 4–11).
- Supports 4 KiB and 4 MiB pages (`tlb_big`, `phys_of` overlay), D-bit re-walk.

### D-cache — `rtl/mem/dcache_timing.sv`
- **8 KB, 2-way, 32-byte line, 128 sets, true LRU — TIMING ONLY.** Header lines
  1–9: "there is NO data array — load data still comes from the BFM." It tracks
  only tag/valid/LRU so the core can decide WHEN a load completes (miss adds
  `dmiss`, misalign +3 per AP-500). No data, no MESI, no writeback, no write
  buffers, no store/load corner behavior.

Both are honest, validated approximations: the TLB is a correctness model, the
D-cache is a timing model. Neither is structurally P54C-shaped.

---

## 2. Documented P54C cache/TLB organization (cited)

Authoritative sources (cross-checked in
`ventium-refs/07-p5-emulation-harness/build/p5_timing_full.json:2319` and
`p5_timing_canonical.json:1239`, themselves citing the primary docs):

- **Pentium Processor Family Developer's Manual Vol.1 (241428-004), sec 2.5 /
  2.5.1** ("On-Chip Caches" / "Cache Organization"), index
  `ventium-refs/00-index/241428-004_..._Volume_1_Jul95.md`.
- **Alpert & Avnon, "Architecture of the Pentium Microprocessor," IEEE Micro
  1993, p.15 Fig.7** (`ventium-refs/.../alpert-avnon-pentium-ieee-micro-1993.md`).
- **AP-500 (241799), p.3** (`docs/ap500-pairing-table.md` derives from the same).
- MESI tables: Dev Manual Vol.1 Ch.3, p.81 Tables 3-3..3-6 (per the index).

### Caches (non-MMX P54C)
- Separate **8 KB code + 8 KB data** L1 (16 KB total), each **2-way
  set-associative, 128 sets × 2 lines × 32 bytes**, **true LRU** (MMX part uses
  pseudo-LRU — do NOT apply to P54C).
- D-cache is **8 banks interleaved on 4-byte boundaries**: both pipes can access
  simultaneously if to DIFFERENT banks; a bank conflict (address bits 2–4 equal)
  stalls the V-pipe access 1 clock, U-pipe priority (already modeled as a +1 in
  the pairing rules, `docs/ap500-pairing-table.md` §5.6.5).
- Cache tags **triple-ported** (1 snoop, 2 lookup); 64-bit external bus.
- CONFLICT NOTE (carried verbatim from the canonical JSON): AP-500 (1994) and the
  1997 Dev Manual both state **2-way** for the original P54C; some later steppings
  shipped 4-way I/D — the canonical original value is **2-way**.

### TLBs (Dev Manual sec 2.5, PDF p.49)
- **D-cache TLB:** **4-way set-associative, 64-entry** for 4 KB pages, **PLUS a
  separate 4-way set-associative 8-entry** TLB for 4 MB pages.
- **Code-cache TLB:** **one 4-way set-associative 32-entry** TLB for 4 KB pages
  (4 MB pages cached in 4 KB increments).
- **TLB replacement = pseudo-LRU** (3 bits per set, Intel486-style).
- (MMX part uses fully-associative TLBs — NOT P54C.)

---

## 3. What a P54C-shaped `tlb.sv` would look like

Replace the 16-entry direct-mapped array with parameterised set-associative
structures matching §2:

- **I-TLB:** 32 entries, 4-way → **8 sets × 4 ways**. Index = `lin[?]` chosen so
  8 sets (3 index bits) select the set; tag = remaining `lin[31:15]`-ish bits
  (exact split per the entry count). 4 KB pages only.
- **D-TLB (4 KB):** 64 entries, 4-way → **16 sets × 4 ways**. Index = 4 bits.
- **D-TLB (4 MB):** separate 8-entry, 4-way → **2 sets × 4 ways**, keyed on
  `lin[31:22]`. A linear address checks BOTH the 4 KB and 4 MB D-TLB structures
  (the 4 MB hit wins for a large page).
- **Replacement:** pseudo-LRU, 3 bits/set (replaces the current direct-mapped
  no-replacement scheme — a set-associative TLB must pick a victim way).
- **Keep the page-walk FSM in the spine** (unchanged) — only the array shape and
  fill/lookup change. The fill must now choose a victim way (pseudo-LRU) instead
  of overwriting the single direct-mapped slot.
- **CR3 flush** still clears non-global val bits (IA-32 §4.10).

Observable fidelity gain: TLB-miss timing patterns and conflict behavior would
match a real P54C (a hot set of >1 page no longer self-evicts as it does in a
direct-mapped 16-entry array). This is structural fidelity, not just
correctness — so it needs NEW TLB-pressure microbenchmarks (a working set that
exercises set conflicts and 4 MB vs 4 KB).

---

## 4. D-cache data / MESI / writeback model sketch

Promote `dcache_timing.sv` from a timing-only tag array to a real data cache.
This is the large, multi-milestone part:

1. **Data array:** add `8 KB` of storage (128 sets × 2 ways × 32 bytes). Loads
   read from the cache (on hit) instead of the BFM; the BFM becomes the
   *backing* memory reached on a miss/fill — this is the structural change the
   review asks for (`rtl/mem/dcache_timing.sv:3-9` "no data array").
2. **MESI state per line:** Modified / Exclusive / Shared / Invalid (Dev Manual
   Vol.1 Ch.3, Tables 3-3..3-6). Replaces the bare `val` bit. State transitions
   on local read/write and on bus snoop (inquire cycle).
3. **Write policy:** P54C default is **write-back with write-allocate**, also
   supporting write-through per-line via PWT/PCD and WB/WT# (Dev Manual sec 2.5).
   A store to a Modified/Exclusive line updates the cache; a dirty line is
   written back on eviction or snoop-hit (HITM#).
4. **Write buffers:** the P5 has write buffers between the pipes and the cache
   (Dev Manual Ch.3, "write buffers"). Model the buffer depth and the
   store-to-load forwarding / ordering corner cases.
5. **Bus integration:** writeback, snoop, inquire, and WB/WT# all require a real
   external bus path. The integrated BIU is currently a *protocol exerciser*
   only (REVIEW_Jun5.md Limit #4; `rtl/bus/biu.sv` — the core consumes
   combinational back-side memory independent of the BIU). A MESI/writeback
   D-cache therefore depends on FIRST closing the integrated-bus data-path gap,
   making this **multi-milestone**: (M-a) D-cache data array + LRU read; (M-b)
   MESI + write-back to BFM; (M-c) write buffers + ordering; (M-d) snoop/inquire
   over a real integrated bus.

Observable fidelity gain: real load data from the cache, dirty-line writeback
traffic on the pins, snoop/MESI behavior, and store/load ordering — none of which
the current timing-only model can show. Each sub-milestone needs its own
microbenchmarks (load-hit data correctness, writeback-on-eviction traffic,
store→load forwarding, snoop-induced state change) and must stay diff-clean vs
QEMU for the architectural load/store result.

---

## 5. Classification + RISK (Action 9 / Recommended-Step 3)

- **Until landed, label both blocks "timing model" / "correctness model," NOT
  "structurally faithful"** — exactly as the code comments already do. The README
  / sphinx claims should say "cache/TLB timing- and correctness-modeled, not
  structurally P54C-shaped" until §3/§4 land.
- **RISK — band perturbation.** A set-associative TLB and a real data D-cache
  change miss patterns, so the `dmiss`/`imiss` bands (`verif/m5_metrics.py`,
  `MISS_CPI_MIN`) and any cache-sensitive kernel must be re-baselined. New
  conflict/pressure microbenchmarks are required to gate the new structure.
- **RISK — bus dependency.** MESI/writeback is blocked on the integrated-bus
  data-path gap (Limit #4); attempting MESI before the bus carries real data
  would be unverifiable. Sequence §4 strictly after the bus work.
- **RISK — scope.** This is the single largest deferred item: a data cache +
  MESI + write buffers + snoop is effectively a new subsystem. Gate each
  sub-milestone (M-a..M-d) independently with `make verify`, the cache bands, the
  bus SVA corpus, and a progress note (Action 10).
