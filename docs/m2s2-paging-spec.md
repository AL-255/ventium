# M2S.2 — paging + TLBs + MMU

Second system-mode RTL stage, building on M2S.1 (real mode + protected-mode
segmentation). Adds the **2-level paging MMU** so linear→physical translation
works, gated against the `qemu-system-i386` golden. The gate is largely already
in place: the **`pmode` test** (M2S.0) enables paging (`CR3` load @n=1072,
`CR0.PG` 0→1 @n=1075) and runs paged code; its RTL `--system` diff was **skipped**
through M2S.1 — M2S.2 un-skips it.

## Scope

1. **Control regs:** `CR3` (page-directory base / PDBR + PCD/PWT), `CR0.PG`
   enable, `CR4.PSE` (4 MB pages). `MOV` to/from these (the regs already exist
   from M2S.1; M2S.2 makes them active).
2. **2-level walk:** linear → `CR3`→PDE→PTE → physical. 4 KB pages; 4 MB pages
   when `CR4.PSE` & `PDE.PS`. Honor `P` (present), `R/W`, `U/S` for the
   permission decision.
3. **TLBs:** model split I/D TLBs (fill on walk, hit→translate). Functionally the
   translation must be exact; TLB *timing* is an M5-class concern — here the TLB
   is for correctness + A/D-bit update behavior, not cycle accuracy.
4. **A/D bits:** set `Accessed` on PDE/PTE use and `Dirty` on write, as memory
   writes to the page tables (qemu-system does this; match it).
5. **`#PF`:** compute the page-fault *decision* + set `CR2` (faulting linear addr)
   + the error code — but **delivery through the IDT is M2S.3** (a raised `#PF`
   HALTs / sets `exc` for now, like the M2S.1 segmentation faults). The `pmode`
   test is identity-mapped and does **not** fault, so the clean path is what's gated.

When `CR0.PG=0`, linear == physical (paging off) — must keep the M2S.1 segmentation
path and (critically) the `boot_mode=user` flat path bit-identical.

## Trace + gate

- The `.vtrace` sys fields already include `cr2/cr3/cr4` (M2S.0). The RTL TB
  already emits them; M2S.2 makes them carry real paging values. No format change.
- **Un-skip `pmode`'s RTL `--system` diff** in `run-sys-golden.sh` (it was
  `SKIPPED for 'pmode'` at M2S.1). M2S.2's gate: `pmode` RTL `--system` trace
  EQUIVALENT to the golden across all 1084 records (the real→PM→**paging-enable**→
  paged-execution sequence), cr0..cr4 + selectors + GPRs + eflags + eip.
- Optionally add a focused paging test (`verif/sys/tests/ppage/`): distinct PDE/PTE
  permission cases, a non-identity mapping (linear ≠ physical so a base-only bug is
  caught), 4 MB pages if PSE — clean (non-faulting) so it's fully gated now.

## Gates (hard)

- **`make verify` (boot_mode=user) GREEN** — unchanged; paging is gated behind
  `CR0.PG` & `sys_mode`, never touches user mode.
- **`make verify-sys` pseg (M2S.1) stays green** AND **`pmode` RTL diff now green**
  (paging works) — plus `ppage` if added.
- Never fake a sys-diff; honest done-partial OK (e.g. 4 KB pages + identity/non-
  identity working, with 4 MB-page or A/D-corner cases deferred + documented).
  Next stage: M2S.3 (interrupts/exceptions — turns the deferred #PF/#GP *decisions*
  into real IDT-delivered faults).
