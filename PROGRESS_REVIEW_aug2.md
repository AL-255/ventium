# Ventium — progress against REVIEW_aug2.md

**Nine findings closed (C-01…C-05 previously, then C-07, H-05, H-06, H-01, H-04),
plus REVIEW2_Aug1's last critical made actionable (§8).
`make verify-all` = 10/10 gates. `verify-sys` grew from 15 tests to 19.**

Written for a review run, so it leads with what to attack and where I am least
confident, not with what went well.

---

## 0. The one-paragraph version

Everything below was gated by writing the test **first**, confirming it failed for
the predicted reason, then fixing, then re-running with the defect reintroduced. That
process caught **two of my own fixes** mid-flight (§3) and turned up **two defects
nobody had reported** (§4). The single most useful new habit: before fixing anything,
instrument the core and *count* how often the corpus reaches the code — twice this
session the answer was **zero**, which changes what "verify-all is green" means.

---

## 1. Closed, with the evidence for each

| finding | what it was | how it was proven |
|---|---|---|
| **C-07** | inter-priv IRET committed EIP/EFLAGS/ESP, then CS+CPL, then installed SS with **no checks at all** | `pssiret`; two independent reversions (§2) |
| **H-05** | NMI re-armed at IRET **decode**, so a faulting IRET re-enabled NMI | `+ven_nmi_arm` counter: **3** with the fix, **0** without |
| **H-06** | INVD/WBINVD executable at CPL3; RDTSC ignored CR4.TSD | `ppriv` golden; RTL half **ungated** — see §5 |
| **H-01** | 16-bit PM stack wrapped its **address** but not its **pointer** | `pstk16`; reversion reproduces `0xdeacfffc` |
| **H-04** | no delivery-depth state; a fault during delivery could loop forever | `pdf`; and the original infinite cascade now terminates |

### C-07 is the one to scrutinise

It restructured every inter-privilege IRET in the machine. The frame now commits at
**one** point (`S_IRET_SS`) after the SS passes the SDM checks; CS is *staged* rather
than installed. The rule is written **once** (`iret_ss_ok` / `iret_ss_commit` in
`core.sv`) because the FSM and the ESP writeback are different `always` blocks —
giving each its own copy is exactly the mirror drift that produced the C-05 family.

Two reversions, because the fix has two independent halves:

```
remove the validation   -> ss=0x0033 (the READ-ONLY descriptor installed as the
                           stack), cs=0x001b, eflags=0x246, DS/ES/FS/GS nulled
restore the old order   -> the fault is delivered at esp=0x00087fe8, i.e. on the TSS
                           stack — proving CPL had already dropped before the check
```

The second signature is the whole design of `pssiret`: the CPL0 boot stack (0x90000)
and the TSS stack (0x88000) are deliberately far apart, so **the handler's own ESP
alone decides** whether the frame had already committed.

---

## 2. Oracle gap #3 — please sanity-check this one

Measured on **both** the gate's oracle (harness qemu 8.2.2) and the system qemu
10.2.1. For a **not-present stack segment** on an outer-level IRET, QEMU raises
**#NP (11)**; the SDM requires **#SS (12)**.

```c
/* target/i386/tcg/seg_helper.c, helper_ret_protected() */
if (!(ss_e2 & DESC_P_MASK)) {
    raise_exception_err_ra(env, EXCP0B_NOSEG, new_ss & 0xfffc, retaddr);
}
```
observed: `v=0b e=0040 i=0 cpl=0`

SDM Vol.2A IRET → RETURN-TO-OUTER-PRIVILEGE-LEVEL says `#SS(SS selector)`, and
Vol.3A 6.15 lists "RET or IRET to a different privilege level" under #SS. **Ventium
follows the SDM.** To keep the case differentially gradable anyway, vectors 11 and 12
share one IDT entry in `pssiret`, so both oracles run a byte-identical instruction
stream; the vector number itself is graded against the RTL fault log in a new step 7b:

```
fault log: #GP(0x30)=1  #GP(0x38)=1  #SS(0x40)=1  #NP(0x40)=0
```

If the SDM reading is wrong, that step 7b assertion is backwards and should be
inverted rather than deleted.

---

## 3. Two of my own fixes were wrong, and the tests caught them

Both were H-01, both found by measurement rather than review of my own diff.

1. **I masked ESP on `stk16()`'s own condition** (`seg_real || !ss_b`). That breaks
   V86: during a V86→CPL0 delivery the frame goes on the **32-bit monitor stack**
   while `v86` — hence `seg_real` — is still set. `pv86` diverged at n=705,
   `expected 0x00087fc8 got 0x00007fc8`. The pointer now masks on
   `real_mode || (!seg_real && !ss_b)`.
2. **The mask applied to every ESP write, including explicit ones.** SS.B governs
   push/pop/call/ret arithmetic; it does not make `MOV ESP, imm32` 16-bit. `pstk16`
   diverged on its own *setup* instruction. Qualified by `!esp_arch_dst`. **The old
   `real_mode`-only condition had the same flaw** and simply never showed it, because
   real-mode code writes SP, not ESP.

Also **not shipped**: I believed `d_is_nop` (declared, wired, read by nothing) would
stall the slow FSM on FWAIT and the `0F 1E/1F` hint-NOPs. I wrote a directed probe
and measured it both ways — `esi` reaches `0x33333333` with **and** without a retire
arm — so the arm fixed nothing reachable and was reverted rather than shipped as
untested code.

---

## 4. Two defects found that REVIEW_aug2 does not list

Both are tracked; neither is fixed.

- **`--soc-en` is a no-op in the default TB build.** `top->soc_en = args.soc_en`
  sits inside `#ifdef VEN_KV260_SOC`, and `ventium_top` ties the core's `soc_en` to
  `1'b0` in the non-KV260 generate branch. Any test needing CPUID/RDTSC/INVD/WBINVD
  therefore cannot run under the plain sys TB — they decode to `d_unknown` and the
  core takes #UD. **This is what keeps H-06's RTL half ungated.**
- **With a 16-bit SS, the cross-privilege IRET returns to the wrong EIP.** Both
  traces agree on everything through the handler and its IRET, then:
  ```
  golden n=290  pc=0x000f01ea   (the instruction after the INT)
  RTL    n=290  pc=0x000f01e0   (the top of user_entry — re-entered)
  ```
  Found by a `pstk16` case that was then **removed from the image**, because keeping
  it would have made the H-01 gate red for an unrelated reason. The removal and the
  measurement are recorded in the test source.

---

## 5. Implemented but **ungated** — do not read these as covered

- **H-06's RTL half.** Correct and live wherever `soc_en=1` — which is the *deployed*
  config, so it is where it matters — but no gate exercises it (see §4). `ppriv`'s
  golden is fully graded and the runner prints the reason step 7 is skipped.
- **The `ss_b` capture at cross-privilege delivery / task switch (H-01 half 2).**
  Implemented in `core_tss_priv.svh` and `core_tsw.svh`. `+ven_h01` reports
  `new SS.B captures: 0` across the entire corpus. Gating it needs §4's IRET bug
  fixed first.
- **`pseglim`** (from the previous round) remains deliberately out of every gate.

---

## 6. What "measured unreachable" bought

Two fixes were instrumented *before* being written:

```
H-05:  nothing in the corpus drives the core's nmi input at all
       (sys/verify TBs tie it low; soc_en gates nmi_take)
H-01:  16-bit PM-stack ESP writebacks: 0   new SS.B captures: 0
       — for every one of the 16 existing system tests
```

In both cases the fix would have been correct **and completely inert**, with no gate
able to distinguish it from the defect. H-05 got a stimulus plusarg (`+ven_nmi_arm`,
silent by default, identical to the synthesis path when absent) and a counter that is
**3 with the fix and 0 without**; H-01 got `pstk16`, which moves its counter 0 → 3.
This is the check I would apply to every prior "fixed" claim in the tree.

---

## 7. New tooling

- `+ven_nmi_arm` — forces `nmi_in_progress` out of reset so the "a faulting IRET must
  not re-arm NMI" property is *reachable*; the core counts faults delivered from an
  IRET state while NMI is still armed. Gated as run-sys-golden step 7c.
- `+ven_h01` — counts 16-bit PM-stack ESP writebacks and new SS.B captures.
- `+ven_faultlog` now prints `depth=`, which is what made the H-04 cascade legible.
- run-sys-golden **step 7b** (fault-vector grading against the RTL fault log) and
  **step 7c** (H-05), for properties the trace diff structurally cannot see.
- New tests: `pssiret`, `pstk16`, `pdf` (all in `RTL_SYS_TESTS`); `ppriv`
  (golden-graded, RTL skipped with the reason printed).

---

## 8. REVIEW2_Aug1 reconciliation (the earlier review), and its last critical

The two reviews number several of the same defects differently. Verified by reading
`REVIEW2_Aug1.md` out of git (`git show f6f6ced:REVIEW2_Aug1.md` — it is no longer in
the working tree):

| REVIEW2_Aug1 | REVIEW_aug2 | closed by |
|---|---|---|
| **C-10** IRET restores privilege/flags without validation | C-07 | `87a7852`, `pssiret` |
| **C-07** stack address size does not follow SS.B | H-01 | `a83e199`, `pstk16` |
| **H-03** (nested-delivery / #DF escalation half) | H-04 | `140ff92`, `pdf` |
| **H-09** NMI cleared at IRET decode | H-05 | `c2b21ee`, step 7c |

That leaves **C-06 (per-access segment protection)** as its last open critical, and
this session moved it from unexplained to actionable.

`+ven_seglog` logs every access the limit check *would* reject, without faulting. It
found the third false positive immediately, and it is not subtle:

```
[SEGCHK] st=1 dseg=2 sel=0000 lim=0000ffff cur_lin=000f0066 off=000f0066 pc=00000066
```

`st=1` is **S_FETCH**. The whole block reads `seg_attr[dseg]`/`seg_limit[dseg]` and
derives its offset from the data segment's base — it describes a *data* access — but
was never qualified on the access being one, so **every instruction fetch was
limit-checked against DS**. That is the "spurious #GP looping at 0xf020d" the previous
round reverted delivery for. Qualifying on `cur_is_d` takes **16 of 19 tests to zero**.

The three that remain are one class — `pseg` 6, `pv86` 78, `ptaskv86` 18 — all
descriptor-table reads (`cur_lin` 0x528 = GDT, 0x1068 = IDT). They address memory
**linearly**, so subtracting the data segment's base underflows (`off=fffe0528`) and
every one trivially exceeds the limit. They are data-side, so `cur_is_d` cannot
separate them.

**The blocker is now exactly one bit: "is this access segment-relative."** Writing it
here as a state list would recreate the very mirror that caused this family —
`seg_chk_base` already *is* such a copy of the bus driver's base selection, which is
precisely why it is wrong for these states. It belongs in the per-access descriptor.
Delivery stays off; the diagnostic ships. Acceptance test for the descriptor work:
`+ven_seglog` reports **zero** across all 19 sys tests.

---

## 9. What I would question first in a review

1. **The C-07 restructure** — it moved when *every* inter-privilege IRET commits. The
   evidence is `pssiret` plus 19 green sys tests; verify it independently.
2. **Oracle gap #3 (§2)** — if the SDM reading is wrong, step 7b asserts the wrong
   thing.
3. **`stk_ptr16`'s exclusion of V86** (§3.1). It is a deliberate narrowing with a
   measured reason, but it leaves steady-state V86 wrapping the address and not the
   pointer. Identity in practice; not proven so.
4. **H-04's depth clearing point.** It clears where control reaches the handler's
   first instruction. If a delivery can complete through a path I did not touch, that
   depth stays set and a later benign fault would escalate spuriously. I found two
   completion sites (protected + real mode); a third would be a bug.
5. **Anything in §5.** Those are the places a green gate means least.
