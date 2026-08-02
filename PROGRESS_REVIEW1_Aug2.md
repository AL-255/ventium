# Ventium — progress against REVIEW1_Aug2.md

**19 findings closed or partially closed, 3 claims refuted with evidence, 11 open.**
`make verify-all` = 11/11 gates. `make l1` = 14 gates (was 13). `verify-sys` = 19 tests.

Commits `a5bab55` … HEAD on `ao486-mister-sim`.

---

## 1. Closed

| finding | what it actually was | evidence |
|---|---|---|
| **C-01a** | a segment fault did **not suppress** the faulting access | witness `0x5eedf00d` survives; `0xcafebabe` reverted |
| **C-01b** | the access had no **segment identity** — string stores and all stack accesses used the wrong descriptor | 34–189 SS accesses/test now checked that were not checked at all |
| **C-01c** | no **type** check; expand-down had no upper bound | `edi=0x1111aaaa` vs `0x2222bbbb` reverted |
| **C-02** | the crossing-store "probe" was a real bus read and set Dirty early | 2812 vs 2816 reads, identical instruction/clock counts |
| **C-05** | the 4 KiB TLB fill **lied about Dirty** on a denied write | fixed to the leaf entry's own bit; 4 MiB was already right |
| **C-06** | same-privilege IRET committed EIP/EFLAGS/ESP before validating CS | ESP gap `0x24` correct vs `0x18` reverted, graded by the diff |
| **C-07** (part) | conforming targets caused a spurious privilege transition; TSS-supplied SS installed unvalidated | 19/19 sys tests; no false positive on any valid TSS |
| **C-08** (part) | the IDT-limit re-vector bypassed escalation entirely | + a real class-update bug of mine, found reading QEMU |
| **H-04** | the AXI alias check tested only the **first byte** | rejected set `{10000000}` → `{0ffffffe, 10000000}` |
| **M-01** | LOCK legality inferred from "has a memory operand" | per-opcode allow-list, fail-open; m6 + 98 programs green |
| **M-05** | the unpaired `VEN_UOPCACHE` build could decode stale uops | now refuses to elaborate/run |
| **M-08** | **a gate that reported failure and exited zero** | `exit 1` + an injectable self-test |
| **H-01** (part) | IRET read descriptors without checking the table limit; a null CS raised #NP not #GP(0) | oracle `v=0d e=0000`; `vec=11` reverted |
| **H-02** | far transfers checked neither the selector table limit nor the target CS limit | shares `sel_in_table()` with H-01 |
| **H-03** | 4 MiB PDE reserved bits silently discarded | #PF(RSVD) before A/D writeback or fill |
| **H-10** | the classic 8042 A20 route was not connected at all | `D=3333` with, `D=4444` reverted |
| **M-02** | V86 wrapped its stack ADDRESS but not its POINTER | `ss_b` made authoritative; pv86 949/949 |
| **M-03** | the TSS I/O bitmap was never consulted -- all CPL>IOPL I/O denied | no-op when no bitmap exists |
| **M-04** (part) | 16-bit x87 env forms wrote the 28/108-byte image over a 14/94-byte object | now loud instead of corrupting |
| **M-07** | port 0x92 bit 0 (fast reset) silently dropped | `fast_reset_req` output + `S_SHUTDOWN` |

### M-08 deserves separate attention

`run-l1axi-verify.sh` printed `L1AXI-VERIFY-FAIL` and returned **zero**, because `echo`
was the last command — so `make l1`, and therefore every "11/11 gates PASS" reported
before this, counted that sweep as passing regardless of its result.
`run-l1axi-cdc-verify.sh` `exec`s it, so both long sweeps lied identically. Same class
as the m6 vacuous PASS and the callret gate that could never pass.

The review saw `PASS=51 FAIL=47`; the current tree reports `98/98` and `10/10`. I cannot
tell from here whether those failures were fixed by intervening work or whether that run
differed in configuration, and I am not asserting either. What is certain is the exit
bug was real and could have hidden exactly that.

---

## 2. Two claims I did not implement, with the evidence

Both are recorded in the commits rather than silently skipped.

### C-08's first claim — contributory-then-page-fault must become #DF

It must not. SDM Vol.3A Table 6-5 has that pair as **handle normally**; the asymmetry is
deliberate, because a page fault taken while delivering a contributory exception is
often resolvable (the handler's stack page not yet present) and escalating it would turn
a recoverable case into a #DF. QEMU's `check_exception` implements exactly the
expression already in the file:

```c
if ((first_contributory && second_contributory)
    || (env->old_exception == EXCP0E_PAGE &&
        (second_contributory || (intno == EXCP0E_PAGE))))
    intno = EXCP08_DBLE;                    /* target/i386/tcg/excp_helper.c */
```

Implementing the claim would make Ventium diverge from both the SDM and the oracle.

**Checking it found a genuine bug of mine** two lines below: QEMU replaces the recorded
class only when the new exception supplies one. I overwrote it unconditionally, so a
benign fault during a contributory delivery erased the contributory context and a
subsequent contributory failed to escalate. Fixed.

### H-03's PS=1-with-CR4.PSE=0 example

The review lists "a PDE with PS=1 while CR4.PSE=0" as being wrongly treated as a normal
4 KiB PDE. That treatment is correct: the SDM has PDE bit 7 IGNORED when CR4.PSE=0, not
reserved, so `is_big = cr4_pse && pde[7]` is right and faulting it would introduce a bug.
The finding's *other* example -- reserved address bits in a 4 MiB PDE -- was real and is
fixed.

### C-05's livelock half

Traced, and I do not believe it exists in this tree. `perm_fault` is evaluated **before**
`xlate_miss` in the fault arm (REVIEW2 C-01 put it there), and after the fill the entry
hits with the permission bits copied from the PDE. Every way `walk_wr_ok_big` can be
false makes `perm_fault` true:

```
!(pde[2] || !usr)            => usr && !pd[2]                  -> perm_fault
!(pde[1] || (!usr && !wp))   => cur_is_w && !pd[1] && (usr||wp) -> perm_fault
```

so the access faults on the hit rather than re-walking. If the intended case is one
where the walk does not fill at all, that is a different mechanism and I could not
construct it. The *dirty-lie* half of C-05 was real and is fixed.

---

## 3. What the tests caught that review-by-reading would not

- **H-04's gate passed with the fix reverted.** I first asserted on `bus_err`, which is
  raised by more than one mechanism — a rejected request that never completes also trips
  the watchdog — so it read 1 in both builds. Only running the reversion exposed it. The
  gate now asserts on the set of addresses the alias detector rejects, which *is*
  discriminating.
- **C-02's obvious fix livelocks.** Suppressing Dirty during the probe means a write to
  a clean entry is treated as a miss forever, because that term exists precisely so the
  walker can set D. The probe now drops the *dirty* requirement while keeping the
  *permission* check.
- **My own C-06 arithmetic was wrong** (I wrote 24-correct/12-buggy, forgetting the
  12-byte frame the test itself pushes). The trace corrected it to 36/24.
- **`pseglim` had three DS-relative bugs** that only surfaced once the store case was
  added: the seed store ran with the limited DS and violated the limit itself (81
  faults), the handler reached its counter through whatever DS the fault happened to
  have (two counters, `ecx=1` for two faults), and with the handler forced flat it read
  its resume EIP from the wrong linear address (#UD at `0x00000508`).

---

## 4. Open — nothing here is claimed as done

**Structural, deliberately not attempted shallowly:**

- **C-03** page-crossing splitting covers only `S_LOAD`/`S_STORE`. Every other
  multi-beat state translates its starting address only. The fix belongs below FSM-state
  selection, at a canonical byte-addressed request layer — the same rework as C-01's
  remaining bullets.
- **C-09** hardware task switching: unpaged, unvalidated, incrementally committed.
- **C-04** implicit descriptor/TSS references use CPL3 page permissions; they need a
  supervisor access class carried with the request.
- **C-10** LOCKed RMW is not atomic against DMA.

**Remaining, and none of these is a small edit:**
- **H-05…H-09** — cache coherence across virtual aliases, I-side cacheability, the
  `VEN_L1_HONOR_CD` read path, the no-L2 config's cache map / coherent DMA / SMRAM
  isolation, and the ao486 L2 invalidation skid. Several reference modules that are not
  in this checkout.
- **H-11, H-12** — x87 stack under/overflow and empty-register semantics; exception
  masks, ES/`#MF` and FWAIT.
- **M-06** — task gates, 16-bit TSS types, and cross-privilege call gates. Three distinct
  ISA mechanisms.
- **M-04's real fix** — the 94-byte FNSAVE register area starts at offset 14, so it is
  2-byte aligned while the sequencer addresses `ea + 4*beat`. Needs a byte-granular
  stride in the FENV/FSAVE sequencers.

**Remaining inside partially-closed findings:**

- C-01: multi-beat extent (SGDT/FNSAVE/m80 validate one beat at a time);
  `seg_null_sel`/`seg_not_present` still tied off; **enforcement is still off by default**.
- C-07: `S_INT_TSS` does not check TR validity or `tr_limit`; the handler offset is not
  checked against the target CS limit; CS/CPL are still installed before the stack is
  read — that last one is the restructure the finding actually asks for.
- C-08: neither fix is gated (the class-update path needs a benign fault *during* a
  delivery, which I could not construct; the IDT-limit path needs a truncated
  `idt_limit`, which no test builds).
- M-01: the positive direction is unexercised — nothing runs a `lock` on a non-lockable
  memory opcode.

---

## 5. What I would check first

1. **The two refutations in §2.** If either reading is wrong, the fix is small but the
   current code is then wrong in a way a gate will not catch.
2. **C-01's fail-open edges** — the expand-down bound is exact for SS and falls back to
   4 GiB elsewhere; M-01's allow-list permits anything unrecognised. Both directions are
   deliberate and both can miss a violation.
3. **Segment enforcement is still not in the default build.** 19 system tests is not
   real firmware, and m7 (Win95/Quake) is excluded from `verify-all`, so a spurious #GP
   in a guest cannot be ruled out from here. With `+define+VEN_SEG_ENFORCE` the whole
   corpus passes — previously *all five* of pseg/pmode/ppage/pcpl/pfcpl3 failed.
4. **Anything in §4.** Those are the places a green gate means least.
