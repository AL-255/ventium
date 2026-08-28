# Ventium — architecturally UNSUPPORTED CPU behaviour

REVIEW2_aug2 H-19 requires that features left out of scope be *documented as unsupported
CPU behaviour* rather than merely halting. This file is that documentation. It lists
only things the hardware **cannot do**, not things that are merely untested.

REVIEW1_Aug3 R2-M03: entries are **classified**, because the old blanket claim that
every entry in this file reaches a loud halt was false while the same file listed
silent defects. The classes are:

- **§A unsupported-loud** — reaches a loud halt or an explicit error response with
  a readable tag. A freeze/error names the form.
- **§B known-silent-defect** — implemented behavior is WRONG in a way that does not
  announce itself. Each entry is either pinned by an expected-failure gate or named
  here; none of these is claimed correct anywhere else.
- **§C expected-failure-pin** — gates whose "pass" means the defect still
  reproduces. They are reachability evidence, not correctness passes
  (`run-verify-all.sh` reports them separately, REVIEW_Aug3 M-03).
- **§D configuration-absent** — a configuration or gate that does not exist in
  this checkout at all, so no claim about it can be verified.

---

## §A. Unsupported-loud

### A.1 System far transfers through unimplemented descriptor types

`rtl/core/core_seg_ljmp.svh` — a far JMP/CALL whose target selector names a system
descriptor the core does not implement halts, **after** the architecturally required
faults for that descriptor have been selected in the pinned oracle's precedence
(type/DPL classification before presence). The `VEN_DBG_CORE` tag is `0xD<type>`, so
the low nibble is the descriptor's own type field:

| tag | descriptor type | status |
|---|---|---|
| `0xD5` | **task gate** (type 5) | UNSUPPORTED — halts (after DPL → `#GP` and absence → `#NP` have been selected) |
| `0xD1` | **16-bit available TSS** (type 1) | UNSUPPORTED — halts (same precedence) |
| `0xD3` | **16-bit busy TSS** (type 3) | UNSUPPORTED — halts (same precedence) |
| — | **LDT descriptor** (type 2), data-in-system, interrupt/trap-gate, or reserved types as a far-transfer target | `#GP(selector)` — the pinned oracle's default case, present or not |
| `0xD9`/`0xDB` | 32-bit TSS (available/busy) | **supported** — hardware task switch (JMP, CALL, and NT-IRET forms; REVIEW_Aug3 C-04). Direct JMP/CALL additionally requires TI=0 and DPL ≥ max(CPL,RPL), both selected **before** presence; a busy TSS target of a direct JMP/CALL is `#GP`; absent TSS → `#NP` |
| `0xDC`/`0xD4` | call gates (32/16-bit) | **supported**, same and cross privilege, with and without parameters (see A.2). Gate DPL < max(CPL,RPL) → `#GP` **before** presence; absent gate → `#NP`; target DPL > CPL → `#GP` (R2-C01) |

**Consequence for guests.** Any OS that dispatches through a *task gate* — the classic
386 way to give a fault its own TSS, and what DOS extenders such as CWSDPMI use for the
double-fault handler — will halt rather than switch tasks. 16-bit TSS types are used by
286-era and some V86-monitor code.

**Why halting rather than faulting:** these are *legal* descriptor types that the
pinned oracle accepts. Raising `#GP` for the transfer itself would be architecturally
wrong — it would tell the guest its descriptor is malformed when in fact this CPU
simply does not implement the transfer. A halt is an honest "unimplemented", and the
tag says which one. (Descriptor classes the oracle itself rejects take its `#GP`.)
An NT-IRET whose back-link names anything but a busy 32-bit TSS also halts here.

### A.2 Cross-privilege call gates — PARTIAL

A call gate whose target CS.DPL is *less than* CPL requires a stack switch through
`TSS.SS<n>:ESP<n>` and a parameter copy. Status after REVIEW_Aug3 C-04 and
REVIEW1_Aug3 R2-C01:

| form | status |
|---|---|
| same-privilege call gate (JMP or CALL) | **supported** — with the R2-C01 DPL/RPL matrix: nonconforming targets require DPL == CPL && RPL ≤ CPL; conforming require DPL ≤ CPL |
| cross-privilege **CALL**, 32-bit gate, param count 0 | **supported** (stack switch via the interrupt-path machinery) |
| cross-privilege **JMP** to a more privileged nonconforming target | `#GP(selector)` — the architectural fault |
| target less privileged than the caller (DPL > CPL) | `#GP(selector)` (R2-C01) |
| conforming targets (either instruction) | **supported** — no privilege change, CPL kept (CS.RPL forced to CPL when DPL < CPL) |
| param count > 0 | **supported** (R2-H05) — `S_CG_PRD` copies 1–31 params off the old stack before the SS/CPL commit |
| 16-bit gate (same- or cross-privilege) | **supported** (R2-H05) — word-unit frames + params, `lc_callw`/`cg_wide` |

### A.3 Nested-task state (NT / backlink) — PARTIAL

Task gates remain unsupported (A.1), but the far-CALL/IRET nested-task machinery is
implemented (REVIEW2_aug2 H-08, REVIEW_Aug3 C-04/H-01):

- a far **CALL** to an available TSS performs the nesting switch: the outgoing TR
  selector is written to the incoming TSS backlink, NT is set in the incoming EFLAGS
  image, and the outgoing TSS stays busy;
- `IRET` with NT=1 performs the task return through the backlink, with the
  preconditions validated up front (valid busy TR, `tr_limit ≥ 1`, backlink non-null /
  TI=0 / in-GDT — `#TS` before any descriptor read);
- a far **JMP** to an available TSS keeps the non-nesting semantics (outgoing busy
  cleared, no backlink/NT).

### A.4 Non-DRAM routing in the no-L2 build

`rtl/mem/ventium_l1_axi.sv` (R2-H03): an access whose memory type routes away from
main memory (a PCI aperture, a memory hole, a disabled-PAM window) is **suppressed
and reported**: the request never reaches DDR (no aliasing of device space onto
RAM), a sticky `route_err` raises `bus_err`, and the core halts. Two explicit
platform overrides exist, and both are DDR-backed **by design**:

- the VGA aperture (0xA0000–0xBFFFF), which the KV260 serves from the DDR
  carveout (fb_vnc);
- region 6 (≥ TOM) **inside the declared RAM window** — the same envelope
  `ven_axi_master` enforces at the address fold (`ADDR_MASK`, plus the
  top-of-4G BIOS shadow ≥ 0xFFFE_0000). In the flat full-mask simulation that
  is the whole 32-bit space; on the KV260 (256 MiB mask) it is the carveout
  plus the BIOS shadow. Region 6 *outside* that envelope is a genuine
  PCI/unmapped access and takes the loud `route_err` path like any other
  non-DRAM region.

---

## §B. Known-silent-defects

| # | defect | class note |
|---|---|---|
| B.1 | ~~16-bit cross-privilege call-gate frame~~ **FIXED (R2-H05):** the gate width is staged (`cg_wide`) and the frame is built in gate-width units — word pushes (SS, SP, params, CS, IP) for a 16-bit gate, with the QEMU-exact wrap/ESP-mask semantics | resolved |
| B.2 | ~~linear-alias stale I-cache~~ **FIXED (R2-H09, 2026-08-04):** every line records its physical page tag (`ic_ptag`, captured at fill); CPU/DMA snoops carry physical addresses and match it, so a store through any alias drops every aliased copy; remaps are covered by the I-cache flush on `tlb_flush`, A20 by `a20_flush`, and decoded state dies under the same identity (the snoop match invalidates the uopcache `{set,way}`). The fetch lookup path is unchanged (VIPT), so there is no timing cost. `run-ic-alias-gate.sh` proves the fix and keeps a `VEN_IC_SNOOP_LINEAR` discrimination control | resolved |
| B.3 | ~~page-crossing fragment engine: read fragment-2 walk contamination~~ **FIXED (2026-08-04):** a read frag2 missing the D-TLB diverts to `S_WALK` with the engine armed; the walk's PDE latch sampled `fx_merged` and the restarted read re-#PF'd forever. The engine sequencer now freezes and all shaping outputs blank while `state==S_WALK` (`fx_walk_hold`, `rtl/core/core.sv`); `pxc04` (S_LGDT) is differentially EQUIVALENT and the gate is PASS-class | resolved |
| B.4 | ~~narrow read byte-exactness~~ **FIXED (R2-H01, second half):** a non-cacheable read is now fragmented into aligned power-of-two pieces, each its own single-beat AR at an exact ARSIZE — an unaligned byte/word read never touches the adjacent word, and no transaction can cross a 4 KiB boundary. Proven by the narrow gate's exact piece-shape checks (direct + 4 CDC ratios) | resolved |
| B.5 | **SMRAM isolation** — the guard mechanism is implemented and gated, now at BOTH seams (Aug4): the extent-aware backing deny on the no-L2 path (R2-H02) AND a pre-lookup core-seam deny (`core_smram_deny`: a non-SMM access to `[SMBASE,SMBASE+0xFFFF]` never enters ven_l1d, so a resident line filled while in SMM cannot leak and a write-hit cannot poison one), plus a conservative full I/D flush on SMM exit and SMBASE relocation (`smm_flush`, wired to ven_l1d and through `smm_flush_o` to the core's executable flush domain). `tb_l1axi_smram` proves the backing path and the residency attacks (golden_l1=0: fill in SMM, exit unflushed, non-SMM read/write-hit cannot observe or poison; relocation flushes; boundary extents). It stays inert in the shipping config (`NB_SMRAM=0`) because the remaining half is PLATFORM work, not core RTL: (a) the default SMBASE `0x30000` sits in conventional DOS memory, and every low-memory alternative collides with something on this platform (the VGA aperture is DDR-backed for fb_vnc; DRAM spans the flat 4 GiB map) — a non-conflicting carveout must be reserved by the BIOS/e820 side, which lives on the absent SoC worktree branch; (b) the chipset open/close/lock lifecycle needs a RUNTIME register, but `NB_SMRAM` is a compile-time parameter and this checkout has no PCI config-write path to the northbridge. Both pieces land with the SoC/L2 side (R2-H10) | cache boundary proven; enablement platform-blocked (R2-H11) |
| B.6 | **LOCK atomicity on L1/AXI** — **mechanism implemented (R2-H08, 2026-08-04):** `ventium_l1_axi` now takes fabric ownership on a locked read's ack and holds the local DMA requester (`nb_dma_req` suppressed) until the locked write completes, the sequence aborts (any unlocked core request — e.g. fault delivery), or reset; FSM-tested by `run-l1axi-lock-gate.sh` (adversarial per-cycle DMA write, completion/abort/reset release). **Residual:** in the no-L2 shipping config the DMA path is tied off, so the hold is inert today — it is live for the VEN_NB_DMA/northbridge configs; the end-to-end adversarial-completion case lands with the L2 restoration (R2-H10). AXI4-exclusive (AxLOCK/EXOKAY) deliberately not asserted (single local requester; the PS reaches DDR off-fabric). The pin-level biu_p5 path already held LOCK# across the pair (`make bus`) | mechanism in place; end-to-end case awaits the L2 hierarchy |
| B.7 | ~~16-bit / parameter-copy call gates~~ **FIXED (R2-H05):** param copy (`S_CG_PRD`, 1–31 units off the old stack pre-commit), width-correct cross-privilege frames, and the same-privilege gate-width audit (`lc_callw`: a gated far CALL pushes in the gate's width, not the caller's operand size) | resolved |

---

## §C. Expected-failure pins

**None remain.** Both former pins were fixed and converted to PASS-class
correctness gates (2026-08-04):

- `make xc04` — all six page-crossing producers complete crossings
  differentially clean, with no `PAGING/C-04` fatal, as a hard requirement
  (the read-frag2 `S_WALK` merge contamination is fixed by the engine's walk
  freeze, `fx_walk_hold`).
- `run-ic-alias-gate.sh` (inside `make l1`) — the B.2 stale-icache hazard is
  fixed by physical snoop tags (R2-H09); the gate asserts the fix and keeps a
  `VEN_IC_SNOOP_LINEAR` build as its discrimination control.

This section is kept so the classification structure (and the docs-status
gate's checks) have a stable home; a future pin belongs here.

---

## §D. Configuration-absent

| item | status |
|---|---|
| L2 / northbridge (`EN_L2=1`) | **disabled for now** — `ven_l2.sv`/`ven_northbridge.sv` absent; `make -C verif/tb l1axi_l2` is a stub (`check-nb` fails); the `g_l2` branch `$fatal`s at elaboration (task #43) |
| `verify-soc` | no such target/gate script in this checkout (`verif/soc/` holds only build artifacts); excluded + logged by `run-verify-all.sh` |
| m7 Quake lock-step / Win95 co-sim | producer artifacts gitignored; excluded + logged |
| `VEN_SEG_ENFORCE` | per-access segment limit/type checks, off by default — with R2-H07 (2026-08-04) the enforcement is architecturally complete over the gated surface: explicit `seg_pm_loaded` metadata at every load site (no attr-change inference), the decoded-extent fetch check (`cs_extent_fault`), the S_INT_PROBE staged-descriptor sourcing, and the seglog probe covering the probe state. The default flip is **deferred on the review's own precondition**: "only after the complete system and m7 matrices pass" — the m7 Quake/Win95 artifacts are absent in this checkout, so the flip cannot be validated here. `make seg` (the enforcement build) is green: positive + 40-test negative sweep |
| `VEN_X87_STKFLT` | **retired to a no-op (R2-H06, 2026-08-04):** the x87 stack-fault response is now UNCONDITIONAL — arm-independent detection (`det_*` descriptor covers the fast/cycle-mode arms), one `fp_commit_allowed` gating direct writeback / TOP updates / pipeline capture / deferred writes, masked responses (QNaN-indefinite results, unordered compare bits), unmasked #MF deferral. QEMU implements no stack faults, so the four corpus programs that deliberately wrap the stack (`tx_stack`, `tx_regform`, `tx_regform2`, `mb_fxch`) carry `x87_stkflt_arch` and compare with exactly the two oracle gaps masked (fstat IE|SF; the st* QNaN substitution), record-scoped to the measured fault ranges (A4-M02); the matrix itself is self-checked by `px87stk` |
| `VEN_X87_MF_STRICT` | pending-`#MF` checks at every waiting op, off by default — QEMU checks at exactly two sites; default-on would diverge from the oracle |
| `VEN_IC_ALIAS_SAFE` | conservative full I-cache flush per CPU store, off by default — the R2-H09 physical snoop tags made it unnecessary; kept as an experiment |

## Notes on properties now provided (previously listed here)

- **Single-access non-cacheable/MMIO reads**: provided for the no-L2 build
  (REVIEW_Aug3 C-01) — one 1- or 2-beat AXI transaction, beat counts through the
  CDC, D-side memory type in the default build, no priming duplicate, no burst
  across 4 KiB (R2-H01). The EN_L2 build is §D.
- **CR0.CD**: honored on BOTH instruction and data sides in the default build
  (R2-H12) — no allocation while CD is set; memory-type classification is
  extent-aware (R2-H02).
