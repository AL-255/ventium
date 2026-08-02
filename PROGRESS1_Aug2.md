# Ventium — fixes landed Aug 1–2

Nine code commits, `e24c472` … `f36dd76`, on `ao486-mister-sim`.

**`make verify-all` = 11/11 gates PASS** (was 10). **`verify-sys` = 19 tests** (was 15).
**REVIEW2_Aug1 has no open findings; REVIEW_aug2 has no open criticals.**

Every fix below was landed the same way: write or extend the test **first**, confirm it
fails for the predicted reason, fix, then re-run with the defect deliberately
reintroduced. Where a fix could not be reached by any existing test, the core was
instrumented and the reachability **counted** before writing code — twice the answer
was zero.

---

## 1. The fixes

| # | finding | what was actually wrong | how it was proven |
|---|---|---|---|
| 1 | **C-01** | the crossing-store "probe" ran *after* the original store had already committed | `pxpage` extended to read the foreign frame: `esi expected 0x0ff1ce00 got 0x0ff11234` |
| 2 | **C-02** | split-transfer state survived page faults into the handler | `xp_pend`/`xs_act`/`xs_ph` cleared in `start_fault` |
| 3 | **C-03** | the split-load merge was written to one consumer; MOVS/OUTS/far-pointer read the raw second beat | one `ld_val`, read by every arm |
| 4 | **C-04** | a permission-denied TLB-miss write set Dirty *before* faulting | write-permission predicate evaluated from the walked entries |
| 5 | **C-05** | the paging address mirror drove wrong translations in ~8 states | every row fixed; zero `PAGING/C-03` firings |
| 6 | **C-06** *(REVIEW2 numbering)* | inter-priv IRET reloaded SS from stack **data**, not its descriptor | fixed in `cee6c3c` |
| 7 | **C-07** | IRET committed EIP/EFLAGS/ESP, then CS+CPL, then installed SS **unvalidated** | `pssiret`; two independent reversions |
| 8 | **H-07** | the AXI alias detector *recorded* a bad request instead of rejecting it | gates the read start, write start and write-barrier capture |
| 9 | **H-05** | NMI re-armed at IRET **decode**, so a faulting IRET re-enabled it | `+ven_nmi_arm` counter: **3** with the fix, **0** without |
| 10 | **H-06** | INVD/WBINVD executable at CPL3; RDTSC ignored CR4.TSD | `ppriv` golden — RTL half **ungated**, see §4 |
| 11 | **H-01** | 16-bit PM stacks wrapped the **address** but not the **pointer** | `pstk16`; reversion reproduces `0xdeacfffc` |
| 12 | **H-04** | no delivery-depth state — a fault during delivery could loop forever | `pdf`; the original infinite cascade now terminates |
| 13 | **C-06** *(segment limits)* | three separate false positives, delivery reverted twice | `make seg`, both directions |

---

## 2. The four worth reading in detail

### C-07 — one commit point instead of three

An inter-privilege IRET committed its frame in the order the bytes arrived off the bus:
`EIP/EFLAGS/ESP` at `S_IRET` beat 4, `CS`+`CPL` in `S_INT_CS_RET`, `SS` in `S_IRET_SS`
**with no checks at all**. A frame naming an unusable stack had already redirected
execution and *lowered CPL* before anything looked at it.

CS is now *staged*; `CS/SS/EIP/EFLAGS/CPL/ESP` all commit on one clock in `S_IRET_SS`
after the SS passes the SDM checks. The rule is written **once** (`iret_ss_ok` /
`iret_ss_commit` in `core.sv`) because the FSM and the ESP writeback are different
`always` blocks — giving each a copy is the mirror drift that produced the C-05 family.

Two reversions, one per half:

```
remove the validation   -> ss=0x0033 (the READ-ONLY descriptor installed as the stack),
                           cs=0x001b, eflags=0x246, DS/ES/FS/GS nulled
restore the old order   -> the fault arrives at esp=0x00087fe8, i.e. on the TSS stack,
                           proving CPL had already dropped before the check ran
```

That second signature is the whole design of `pssiret`: the CPL0 boot stack (0x90000)
and the TSS stack (0x88000) are deliberately far apart, so **the handler's own ESP alone
decides** whether the frame had already committed.

Two more bugs fell out while reading the surrounding code: `core_gpr_wb.svh` still
carried a `!int_gate_op16` gate that `core_iret.svh` no longer had (so a 16-bit
outer-level return read its ESP/SS slots from the wrong offsets), and `ss_b` was never
updated on an inter-priv return, so the stack width came from the *previous* descriptor.

### H-04 — #DF escalation, from a real cascade

There was no delivery-depth state. Not hypothetical — an undefined opcode against a
sparse IDT produced, measured:

```
vec=6  err=00000000     #UD
vec=11 err=00000032     IDT[6] not present  -> #NP (6*8+2)
vec=11 err=0000005A     IDT[11] not present -> #NP (11*8+2)
vec=11 err=0000005A     ... forever
```

The core now tracks `dlv_depth` **and the class** of what is being delivered, because
IA-32 Table 6-5 escalates only for contributory-during-contributory and the page-fault
combinations — benign faults and software `INT n` nest normally, so "a delivery is in
flight" is not by itself enough to decide. Same image now:

```
vec=6  depth=0    benign, delivered normally
vec=11 depth=1    contributory, but the previous one was BENIGN -> no escalation
vec=11 depth=1    contributory during contributory -> becomes #DF
vec=11 depth=2    IDT[8] absent, err 0x42 = 8*8+2 -- the #DF delivery WAS attempted
                  -> SHUTDOWN
```

`pdf` grades the case that has a trace to diff: vectors 13 and 8 name the **same**
handler and differ only in the present bit, so control reaches it either way and what is
graded is the **pushed error code** — 0 for a real #DF, 0x6A for a merely-delivered #NP.

### C-06 — three false positives, one of them not ours

Delivery had been reverted twice. A new diagnostic (`+ven_seglog`, which logs would-be
rejections without faulting anything) found all three:

1. **The check ran on instruction fetches against the DATA segment.** All 19 sys tests
   fired, floor of 12 — systematic. Qualifying on `cur_is_d` took 16 of 19 to zero.
2. **Descriptor-table reads are linear.** `cur_lin` 0x528 is the GDT, 0x1068 the IDT;
   subtracting a segment base underflowed (`off=fffe0528`). The bus driver now
   *publishes* `cur_seg_rel` next to each address it builds from a segment base and the
   check consumes it → 19 of 19 zero. It went **there**, not into `core.sv`, because
   `seg_chk_base` already *is* a remote copy of the driver's base selection and that is
   exactly why it was wrong.
3. **The "spurious #GP looping at 0xf020d" was a TEST bug, not a core bug.** A
   `.code16` for the reset stub was left in force above `pseglim`'s 32-bit `gp_handler`,
   so the assembler emitted 16-bit encodings — and with D=1 the same bytes mean
   something else:
   ```
   66 ff 06 00 07  ->  incw (0x0700)     as assembled (16-bit)
                   ->  inc dword [esi]   as executed  (32-bit)
   ```
   ESI holds garbage on entry, so the handler dereferenced it and took a **genuine**
   out-of-limit #GP before it could do anything. The core was right the whole time.

The delivery also had to move: first restored in the `S_DECODE` arm, where it never
fired because `seg_access_fault` asserts in `S_LOAD` one state later. It now sits beside
`perm_fault` at the access, ordered **ahead** of it — segmentation precedes paging, so an
out-of-segment offset must #GP without producing a linear address to translate.

### H-01 — the pointer, not just the address

`stk16()` masked the stack **address**; the GPR writeback masked ESP on `real_mode`
alone. On a 16-bit protected stack a push at SP=0 accessed SS:FFFC and then committed
`ESP=FFFFFFFC` instead of preserving `ESP[31:16]`. `pstk16` uses `ESP=0xDEAD0000` because
the sentinel separates three implementations: `0xDEADFFFC` correct, `0xDEACFFFC` a
32-bit stack (the borrow out of SP), `0x0000FFFC` a mask-everything version.

---

## 3. Two of my own fixes were wrong, and the tests caught them

Both in H-01, both found by measurement rather than by re-reading my own diff.

1. I masked ESP on `stk16()`'s own condition (`seg_real || !ss_b`). That breaks V86:
   during a V86→CPL0 delivery the frame goes on the **32-bit monitor stack** while `v86`
   — hence `seg_real` — is still set. `pv86` diverged at n=705,
   `expected 0x00087fc8 got 0x00007fc8`.
2. The mask then applied to **every** ESP write. SS.B governs push/pop/call/ret
   arithmetic; it does not make `MOV ESP, imm32` 16-bit. `pstk16` diverged on its own
   *setup* instruction. The old `real_mode`-only condition had the same flaw and simply
   never showed it, because real-mode code writes SP, not ESP.

**Also not shipped:** I believed `d_is_nop` (declared, wired, read by nothing) stalled the
slow FSM on FWAIT and the `0F 1E/1F` hint-NOPs. A directed probe measured it both ways —
`esi` reaches `0x33333333` with **and** without a retire arm — so the arm fixed nothing
reachable and was reverted rather than shipped as untested code.

---

## 4. Deliberately incomplete — do not read these as covered

- **Segment-limit enforcement is not in the default build.** Zero false positives across
  19 system tests is not zero across real firmware, and the m7 Win95/Quake gates are
  artifact-dependent and excluded from `verify-all`. A spurious #GP in Win95 would be a
  worse regression than the missing check. *Proven:* with `+define+VEN_SEG_ENFORCE` the
  whole corpus passes, where previously **all five** of pseg/pmode/ppage/pcpl/pfcpl3
  failed. Flipping the default is one line once m7 can be run.
- **H-06's RTL half is ungated.** Correct and live wherever `soc_en=1` — the *deployed*
  config — but `--soc-en` is a no-op in the default TB build (§5), so no gate reaches it.
  `ppriv`'s golden is graded; the runner prints why step 7 is skipped.
- **The `ss_b` capture at cross-priv delivery / task switch** is implemented but ungated:
  `+ven_h01` reports `new SS.B captures: 0` across the whole corpus. Gating it needs the
  IRET bug in §5 fixed first.
- **V86 stack pointers** still wrap the address and not the pointer. Identity in
  practice, narrowed deliberately (§3.1), recorded in `core.sv` rather than hidden.

---

## 5. Defects found that neither review listed

Both tracked, neither fixed.

- **`--soc-en` is a no-op in the default TB build.** `top->soc_en = args.soc_en` sits
  inside `#ifdef VEN_KV260_SOC`, and `ventium_top` ties the core's `soc_en` to `1'b0` in
  the non-KV260 generate branch. Anything needing CPUID/RDTSC/INVD/WBINVD therefore
  cannot run under the plain sys TB — measured: the core took #UD on a CPL0 `WBINVD`.
- **With a 16-bit SS the cross-privilege IRET returns to the wrong EIP.** Both traces
  agree through the handler and its IRET, then `golden pc=0x000f01ea` (the instruction
  after the INT) vs `RTL pc=0x000f01e0` (the top of `user_entry`, re-entered). Found by a
  `pstk16` case that was then **removed from the image**, because keeping it would have
  made the H-01 gate red for an unrelated reason; the removal and the measurement are
  recorded in the test source.

---

## 6. Oracle gaps (three now)

QEMU is the oracle for the differential gates, and it is wrong in three places. Each was
measured, not inferred, and each changes what can be graded by diff.

1. **QEMU does not enforce segment limits.** `pseglim` exits 133 there (counter 0).
   → C-06 can only ever be a self-check.
2. **QEMU does not mask x87 exceptions on FNSTENV.** No `fpuc |= 0x3f` anywhere.
   → `make fenv` is a self-check.
3. **NEW: QEMU raises #NP(11) where the SDM requires #SS(12)** for a not-present stack
   segment on an outer-level IRET (`seg_helper.c`, `EXCP0B_NOSEG`; observed
   `v=0b e=0040`). Verified on **both** the harness 8.2.2 and the system 10.2.1. Ventium
   follows the SDM; `pssiret` gives vectors 11 and 12 one shared IDT entry so both oracles
   run a byte-identical stream, and the vector itself is graded against the RTL fault log.

A fourth, version-specific: **system qemu 10.2.1 permits INVD/WBINVD at CPL3** where the
harness 8.2.2 raises #GP. I measured against the wrong binary first and got one fault
where I predicted three — the design was right and the binary was wrong.

---

## 7. What was added

**Gates** — `verify-all` 10 → 11; `verify-sys` 15 → 19 tests.

| new | what it grades |
|---|---|
| `pssiret` | inter-priv IRET SS validation **and** that a rejected frame commits nothing |
| `pstk16` | 16-bit PM stack address *and* pointer |
| `pdf` | #DF escalation, graded by the pushed error code |
| `ppriv` | INVD/WBINVD/RDTSC privilege — golden only, RTL ungated (§4) |
| `make seg` | segment limits, positive **and** negative directions |

**Instrumentation** (all sim-only, silent by default, identical to the synthesis path
when absent):

- `+ven_seglog` — logs every access the segment check *would* reject, without faulting.
  Found all three C-06 causes.
- `+ven_nmi_arm` — forces `nmi_in_progress` out of reset so H-05's property is
  *reachable* at all; the core then counts faults delivered from an IRET with NMI armed.
- `+ven_h01` — counts 16-bit PM-stack ESP writebacks and new SS.B captures.
- `+ven_faultlog` now prints `depth=`, which is what made the H-04 cascade legible.
- run-sys-golden **step 7b** (fault vectors vs the RTL fault log) and **step 7c** (H-05)
  — for properties the trace diff structurally cannot see.

---

## 8. The habit that paid

Before fixing H-05 and H-01, the core was instrumented and the reachability counted:

```
H-05:  nothing in the corpus drives the core's nmi input at all
H-01:  16-bit PM-stack ESP writebacks: 0   new SS.B captures: 0
       — for every one of the 16 system tests that existed then
```

Both fixes would have been **correct and completely inert**, with no gate able to tell
them from the defect. H-05 got a stimulus plusarg and a counter that reads 3 with the fix
and 0 without; H-01 got `pstk16`, which moves its counter 0 → 3.

That check — *count the reachability before writing the fix* — is the one I would apply
to every prior "fixed" claim in this tree.
