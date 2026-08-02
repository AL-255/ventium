# Ventium — progress against REVIEW2_Aug1.md (session of Aug 1–2)

**State: 41 of 43 at the time of writing; ALL 43 after the REVIEW_aug2 round
(see the update in §6). `make verify-all` = 11/11 gates PASS.**

Written for a review run, so it leads with what to check and where I am least confident,
not with what went well.

---

## 0. Read this first — the verification set changed underneath everything

`make verify-all` ran **6 gates** at the start of this session and runs **10** now. That
matters for interpreting any earlier "the tree is green" claim, including my own: they
were made against a third of the gates that exist.

| gate | what it covers | status at session start |
|---|---|---|
| `verify` | m1–m5 differential func + cycle vs QEMU | ran constantly |
| `verify-sys` | 15 system-mode tests vs QEMU golden | **never run** until Aug 1 |
| `verify-srt` | radix-4 SRT divider | in umbrella |
| `m6` | 5 documented P5 errata | **never run**; had a FAIL *and* a vacuous PASS |
| `x87b` | x87 deferred-op loud-HALT boundary | **existed, invoked by nothing** |
| `a20` | A20 1 MiB alias wrap (new) | did not exist |
| `fenv` | FNSTENV masks all x87 exceptions (new) | did not exist |
| `l1` | 13 L1/TLB/BTB/AXI gates | **absent from the umbrella entirely** |
| `bus`, `bus-sva` | biu_p5 protocol + SVA corpus | in umbrella |

Four things were found purely by reconciling *gates that exist* against *gates that run*:

1. **m6 contained a vacuous PASS.** `is_moffs` is assigned nowhere in the RTL, so
   `errata_en[ERR_MOFFS]` is inert — the ON/OFF traces are byte-identical. A green
   "Erratum 59 reproduced" line was printed by a bit that does nothing. Check 4 now
   asserts the *withdrawal* and trips if it ever changes; the banner says 4 of 5.
2. **`run-l1axi-callret-gate.sh` could never pass in any tree state.** The tb exits via
   isa-debug-exit (`(0x42<<1)|1` = 133) even on success, and `set -eu` aborted the script
   before a single check ran. It had been failing on a *successful* run — and it is the
   only gate covering the deployed FPGA config.
3. **Twelve L1 gates were absent from the umbrella**, covering exactly the RTL that
   REVIEW2's cache findings touch.
4. **The corpus has 99 programs; the aggregate reported on 98.** `tx_deferred_halt` is
   correctly excluded from the differential gate and delegated to
   `run_x87_boundary.sh` — which nothing invoked. Covered by nothing.

---

## 1. Two oracle gaps — please sanity-check these, they change what is gradable

Both were measured, not inferred. If either is wrong, several conclusions below move.

### 1a. QEMU does not enforce segment limits

```
qemu-system-i386 -bios pseglim.bin   ->  exit 133   (#GP counter == 0, NO fault)
                                         exit 135 would mean the #GP fired
```

Measured with every intermediate layer removed — the test encodes its `#GP` counter into
the isa-debug-exit status, so no gdbstub, `gen_trace`, QMP or trace parsing is involved.
Everything about the test was verified first: descriptor bytes byte-identical to `pseg`'s
working idx3; `LSL` reports the effective limit as `0x0000FFFF`; `es=0x0018` at the
access; and the **linked** image disassembles to
`f01d3: 26 8b 15 00 00 01 00  mov %es:0x10000,%edx`.

**Consequence:** a *correct* Ventium diverges from the golden and is reported as a
regression. C-06 can only ever be graded by a self-check, never a diff.

### 1b. QEMU does not mask x87 exceptions on FNSTENV

`do_fstenv()` in `target/i386/tcg/fpu_helper.c` stores and returns; there is no
`fpuc |= 0x3f` anywhere in the tree, and `translate.c` adds nothing. The SDM requires
`FCW[5:0] <- 6'b111111` after the store.

Compounding it: the default CW `0x037F` **already** has bits[5:0] set, so the behaviour is
unreachable on the entire existing corpus. `make verify` passing 98/98 with the fix in
place proves nothing about it — hence `make fenv`, a self-check that first clears the mask
bits.

---

## 2. Findings closed (each validated by reintroducing the defect)

| finding | what it was | how it was validated |
|---|---|---|
| **C-01** | page permissions never blocked | #PF now blocks + delivers, I-side included |
| **C-02** | page-crossing access translates only the first page | `pxpage` went `0xccccaaaa` → `EQUIVALENT`; loads **and** stores |
| **C-09** (#UD half) | `LOCK` on a non-memory op silently accepted | m6 F00F ordering still passes |
| **M-01** (masking half) | FNSTENV did not mask exceptions | removing the fix → `CW=0340`; `make fenv` |
| **M-02** | SMM save map omitted DR6/DR7/TR/LDTR | removing `dr7 <= rsm_dr7` → handler's value leaks |
| **M-03** | A20 gate absent | `A=1111 B=3333 C=0000`; `make a20` with a control |
| **M-04** | `ven_l1d` ignored its own geometry params | pre-fix body passes at 128, **fails at 64** |
| **M-07** | alias detector was sim-only `$display` | inverting the condition → `bus_err` halts the core |
| **M-08** | RLAST mismatch reported but not recovered | stubbing the drain → "never returned to IDLE" |
| **H-16** (external-write half) | physical DMA snoop vs linear I-tags | conservative flush, gated on `paging_on` |
| **M-09 item 1** | 99th corpus program covered by nothing | `make x87b` added |
| **H-22** (`B:=ES` only) | FSW.B never mirrored ES | **inert** — see §4 |

### Worth scrutinising in C-02

The store half is **not** the load fix with `mem_we` flipped. A store that writes the first
page before the second is validated leaves memory partially modified if the second faults.
The sequence is **PROBE-2 → WRITE-1 → WRITE-2**: phase 0 translates and write-permission-
checks the second page with `mem_we=0`; phase 1 writes the first page; phase 2 writes the
rest. No rollback needed, nothing retires until phase 2 acks.

The acceptance criterion was the **mirror**, not the test: both `mem_addr` and `cur_lin`
carry the second-page redirect for loads and all three store phases, and verify-all
reports **zero `PAGING/C-03` firings**. Stores are on every code path, so that is the
number to re-check.

---

## 3. Two of my own fixes were wrong and green gates would have hidden both

Flagging these because they are the best evidence for how to read the rest.

- **H-17 (I-side cacheability).** I claimed CR0.CD was enforced. Driving the poison from
  `creg0[30]` **livelocks the core**: `retired 0 instructions in 8000 clocks (bus: 31997
  reads)`. CR0 resets to `0x6000_0010`, so CD is set out of reset, and the I-cache *is*
  the fetch datapath — the spine misses, fills, re-checks, fills again, forever. The unit
  test passed throughout because it drives the fill port directly and cannot see a
  feedback loop. Reverted; the measurement is recorded at the tie-off.
- **M-03 (A20).** My first mask sat inside `if (paging_on ...)`, so it never executed in
  real mode — where A20 matters most. Found by a probe that printed **nothing** while the
  run performed 52 writes. I twice read that zero as "my instrumentation is broken".

---

## 4. Things that are implemented but **inert** — do not read these as coverage

- **H-22 `B:=ES`.** Correct rule, single-sourced, applied at all three fstat commit
  points. But **ES is set in 0 of 10,165 fstat records** — nothing in the design ever
  raises the error summary. `make verify` 98/98 says nothing about it.
- **H-17 `fill_nocache`.** The mechanism exists and is unit-tested with a cacheable
  control, but is **tied to 0** because nothing can safely drive it (see §3).
- **`pseglim`** passes and is **deliberately out of every gate**: it exercises nothing
  until C-06's delivery lands. Re-add only when `ecx == 1`.

---

## 5. C-06 — the most instructive item, and still not fixed

Eight hypotheses. The five from reading code were all wrong; the three from
instrumentation were all right.

**Proven working** — the `#GP(0)` delivery fires on the real violation:
```
[FAULT] vec=13 pc=000f01cb dseg=3 dlimit=0000ffff q_ea=00010000 q_w=4 attr=92
```

**Two false positives found and fixed (kept in the tree, inert without delivery):**
1. *Empty descriptor cache.* `dlimit=00000000 attr=00` — every offset trivially exceeds a
   zero limit, producing a spurious `#GP` inside the Err79 handler that broke m6.
   `seg_off_over_limit` now requires `a[7]`; `seg_not_present` is tied off for the same
   reason `seg_null_sel` already was — this core has no "descriptor loaded" bit.
2. *Stale `q_ea`.* It held `0x600d600d`, a **sentinel data value**, not an address. The
   offset now derives from `cur_lin`, which mirrors the bus driver and which CHECK 5
   already asserts agrees with it.

**Third false positive remains**, which is why the delivery is reverted: a spurious `#GP`
still loops at `0xf020d`. All ten gates pass with the delivery live — so **the gates do
not cover it**, and shipping it would inject spurious `#GP`s into exactly the guest
software they cannot see.

**Structural read:** all three have the same shape — the check *reconstructs* the
addressing basis instead of *consuming* the one the bus driver builds. Each patch fixes
one reconstruction and reveals the next. That is what #65's per-access descriptor is for,
and C-02's split proved the structure works.

---

## 6. Remaining, with the specific blocker (not a restatement)

> **UPDATE (Aug 2, after the REVIEW_aug2 round).** Four of the items below were
> closed by that round, which numbers them differently. The mapping, verified by
> reading REVIEW2_Aug1.md out of git (`git show f6f6ced:REVIEW2_Aug1.md` — the file
> is no longer in the working tree):
>
> | REVIEW2_Aug1 | REVIEW_aug2 | closed by |
> |---|---|---|
> | **C-10** IRET restores privilege/flags without validation | C-07 | `87a7852`, gated by `pssiret` |
> | **C-07** stack address size does not follow SS.B | H-01 | `a83e199`, gated by `pstk16` |
> | **H-03** (nested-delivery / #DF escalation half) | H-04 | `140ff92`, gated by `pdf` |
> | **H-09** NMI cleared at IRET decode | H-05 | `c2b21ee`, gated by run-sys-golden step 7c |
>
> REVIEW2_Aug1 C-07 is closed for the PROTECTED-mode half and for retaining SS.B in
> the hidden SS cache (its stated "required direction"). One nuance is deliberately
> left: in steady-state V86 the stack ADDRESS wraps but the POINTER does not, because
> masking on `seg_real` truncates the monitor's ESP during a V86->CPL0 delivery
> (measured: pv86 n=705, expected 0x00087fc8 got 0x00007fc8). It is identity in
> practice and recorded in core.sv. See PROGRESS_REVIEW_aug2.md for the full round.
>
> **C-06 is now closed too** (`f36dd76`), so this review has no open criticals.
> All three false-positive causes were found by measurement (`+ven_seglog`, which
> logs would-be rejections without faulting):
>   1. the check ran on INSTRUCTION FETCHES against the DATA segment — all 19 sys
>      tests fired; qualifying on `cur_is_d` took 16 of 19 to zero;
>   2. descriptor-table reads are LINEAR, so subtracting a segment base underflowed.
>      The bus driver now publishes `cur_seg_rel` next to each address it builds from
>      a segment base and the check consumes it → 19 of 19 zero;
>   3. **the "spurious #GP looping at 0xf020d" was a TEST bug, not a core bug** — a
>      `.code16` left in force above pseglim's 32-bit handler, so `66 ff 06 00 07`
>      assembled as `incw (0x0700)` but executed as `inc dword [esi]` with garbage
>      ESI: a genuine out-of-limit access. The core was right.
> New `make seg` gate asserts both directions. Enforcement is still off by default,
> deliberately — 19 system tests is not real firmware, and m7 (Win95/Quake) is
> excluded from verify-all, so a spurious #GP there cannot be ruled out. Proven: with
> `+define+VEN_SEG_ENFORCE` the whole corpus passes, where previously all five of
> pseg/pmode/ppage/pcpl/pfcpl3 failed.

| finding | blocker |
|---|---|
| ~~**C-06**~~ | CLOSED — see the update above; `make seg` gates both directions |
| ~~**C-07**~~ | CLOSED as REVIEW_aug2 H-01 — see the update above |
| **H-16** (alias half) | needs physical I-tags or a reverse alias map |
| **H-17** | needs a **fetch bypass** — deliver bytes without a validated line |
| **H-21** | fix does **not** belong in `fpu_top.sv:218-257` where the finding points; `fpu_top` does not own `fstat` (full 16-bit replace from the spine). Belongs in `fpu_writeback.sv`. Blocked on H-22 — the unmasked branch has nowhere to go until `#MF` exists |
| **H-22** | needs per-arm masked/unmasked completion + an `#MF` route. **Do not** derive ES continuously: it is sticky, and FRSTOR loads it verbatim |
| **M-01** (env forms) | `S_FENV_ST/LD` walk **dword** beats; 14 bytes is 3.5 dwords |
| **M-05**, **M-09 item 3** | `ven_cachemap`, `ven_northbridge`, `ven_l2` have **no source in this checkout** — unbuildable at any effort |

---

## 7. New tooling

- `+ven_faultlog` — logs every `start_fault()` (vector/err/pc/state/v86, extendable with
  dseg/dlimit/q_ea/q_w/attr). `ifndef SYNTHESIS`, silent without the plusarg (0 lines
  across a full verify-all). It produced every correct C-06 finding.
- Sim-only page-crossing counter in `core_bus_driver.svh` — a permanent tripwire; reported
  **0** across all gates before `pxpage` existed, which is why C-02 survived.
- `axi_slave_bfm` RLAST fault injection (`RLAST_EXTRA` / `RLAST_EARLY`) — a compliant slave
  can never reach M-08's recovery path.
- New tests: `pxpage` (page-crossing, in the gate), `pseglim` (segment limit, out of the
  gate), `a20test`, `fenvtest`.

---

## 8. What I would question first in a review

1. **The C-02 store split** — it touches every store in the machine. Zero CHECK-5 firings
   is my evidence; verify it independently.
2. **The two oracle-gap claims (§1)** — if QEMU *does* enforce limits under some other
   configuration, C-06's whole verification strategy changes.
3. **`seg_not_present` tied to 0** — this removes a check the review may have wanted.
   Rationale is in the code, but it is a judgement call about an untrackable distinction.
4. **H-16's conservative flush** — correct but blunt; it flushes I-cache and uop cache on
   every paged DMA snoop. Gated on `paging_on` so real-mode boot is unaffected, but the
   performance cost under a paged DMA-heavy load is unmeasured.
5. **Anything I marked "inert" in §4** — those are the places a green gate means least.
