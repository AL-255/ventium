# PROGRESS — Aug 3, 2026

REVIEW2_aug2 close-out. **All 16 findings are now closed.** `verify-all` grew from 11
gates to **22** (the `l1` set itself grew from 17 sub-gates to 18), across 138 commits
on `ao486-mister-sim`.

This document records what changed, what it was measured against, and — deliberately —
the places where a first diagnosis was wrong, because in three cases the wrong diagnosis
was the expensive part and the fix was small once it was corrected.

---

## Summary

| Finding | State | Gate |
|---|---|---|
| H-08 — NT task return (IRET with EFLAGS.NT=1) | closed | `unimpl` |
| C-06 — far RETF to an outer privilege level | closed | `retfout` |
| C-06 — cross-privilege call gate (+ a gate-DPL bug found under it) | closed | `callxpl` |
| H-11 — non-cacheable reads amplified into line bursts | closed | `l1` (tb_l1d `[11e]`) |
| C-04 — paging lookup and bus address generated independently | closed | CHECK 5, always-on |
| H-13 — fetch cacheability ignores the physical memory type | closed | `mtype`, `l1` (`cachemap`, 25 datasheet checks) |

Ten further findings were closed earlier in this review; this document covers the six
that remained.

---

## H-08 — the NT task return

An `IRET` with `EFLAGS.NT=1` is a **task return** through the current TSS back-link, not
a stack return. `IRET` never examined NT, so such an instruction popped a frame that was
not there and the machine kept running in the wrong task — silently, which is why it had
carried a `[VEN-NTRET]` instrument.

Implemented by reusing the existing task-switch micro-sequence rather than adding one:
`S_NTRET_RD` reads the back-link at `tr_base+0` and hands the selector to `S_LJMP`;
`tsw_type_ok()` widens `S_LJMP`'s type tests to accept a **busy** TSS (`0xB`) under
`ntret_pend`; and H-04's busy-TSS `#GP` arm is qualified with `!ntret_pend`, because a
back-link names the *suspended outer task*, which never stopped being busy. That guard
was rejecting every NT return.

`S_TSW_BUSY` needed no change at all: beat 0 already clears the outgoing busy bit, and
beat 1's `attr | 8'h02` rewrites `B` over `B` for an already-busy incoming TSS. That is
why the change is ~15 lines of logic.

**The wrong diagnosis.** Two earlier attempts were reverted on the conclusion
"`S_LJMP` is never entered with `ntret_pend` set." A probe showed that was false — it
*is* entered, with the flag high and both descriptor beats acking. The real blocker was
in the **test**: `pntret` wrote GDT index 6 twice, clobbering the TSS_B descriptor with a
conforming code segment, so the core correctly took the far-jump path and the run ended
`cs=0x0030` — which reads exactly like "NT was ignored."

**Measured**, dispatch forced false vs live:

```
reverted  ebp=0x07000000  cr0=0x60000011
fixed     ebp=0x07000001  cr0=0x60000019   (CR0.TS set, as every task switch must)
```

`run-unimpl-gate.sh` had been holding the old answer on purpose and failed with the text
"restate it to assert 0x07000001." This is that restatement.

---

## C-06 — far RETF to an outer privilege level

A protected `RETF` whose popped `CS.RPL > CPL` returns to an **outer** privilege level:
the frame carries `ESP` and `SS`, and both must be popped and validated. Ventium reused
far-JMP semantics — it loaded CS and took CPL from the popped RPL but never touched
`SS:ESP`. Measured before the fix:

```
cs=0x001b  ss=0x0010  esp=0x00006ff8
```

Ring-3 code holding the **ring-0 stack pointer**. That is a privilege-escalation
primitive, not a wrong register, and it failed silently.

Implemented by reuse, not by a second cross-privilege path: `S_RETF` stages the frame
into the `iret_*` registers and hands off to `S_INT_CS_RET` (validates the returned-to
CS) and `S_IRET_SS` (validates the outer SS and commits CS/SS/EIP/EFLAGS/CPL/ESP on one
clock). The rules are identical for both instructions, so sharing them is what stops them
drifting apart.

The two instructions differ in exactly two places, both handled at the seam:

* **EFLAGS** — an IRET restores it from the frame, a RETF does not touch it. Staging
  `iret_eflags <= eflags` makes the shared commit a no-op for flags.
* **NMI** — `iret_retire_nmi()` is IRET-only semantics. A RETF that also cleared
  `nmi_in_progress` would re-open the NMI window inside a handler that never took an NMI.

The beat-1 ESP bump is suppressed for this case: it is not merely redundant (ESP is
*replaced* from the frame) — it would move the anchor the bus driver uses to address the
remaining ESP/SS pops.

**The witness is the stack, not the privilege level.** CPL takes the popped RPL in the
broken build too, so a test asking "did we reach ring 3" passes against the bug.

---

## C-06 — the cross-privilege call gate, and the bug hiding it

A far `CALL` through a call gate to a more privileged code segment must switch stacks:
`SS:ESP` from `TSS.ssN/espN`, then the caller's `SS:ESP` and the return `CS:EIP` pushed
on the new stack. This arm halted loudly (tag `0xDB`) rather than faking it.

**Two defects, and the second was only findable once the first was fixed.**

1. **The gate's DPL was read from the wrong bits.** The arm computed
   `gdpl = desc[45:44]`. The access byte is `desc[47:40]` and its DPL is bits `[6:5]`,
   i.e. `desc[46:45]`. `desc[45:44]` is `{DPL[0], S}`, and a system descriptor has `S=0`
   — so a DPL-3 gate decoded as DPL 2. `gdpl < cpl_r` then rejected **every DPL-3 gate
   called from ring 3** with `#GP(selector)`, and a DPL-3 gate is the only kind ring-3
   code can use.

   This is also why the `0xDB` "not implemented" halt had **never been observed by any
   corpus run**: the transfer died one check earlier. The halt was unreachable, not
   unreached. Worth stating plainly, because "0 observed across the corpus" was doing
   load-bearing work in this review, and here it was an artifact of a bug upstream of the
   thing being counted.

2. **The stack switch itself**, implemented by reusing the interrupt path exactly as this
   arm's own comment predicted: `S_INT_TSS` reads `TSS.ssN:espN`, `S_INT_SS` validates
   and loads the new SS and commits `cpl_r`, `S_INT_PUSH` builds the frame and is the
   single commit point for CS/EIP. Three things differ from an interrupt, all handled
   under `cg_xpl`: no EFLAGS word in the frame; EFLAGS is not masked on entry (clearing
   IF here would silently disable interrupts across every cross-privilege call); and the
   ESP drop is 16 bytes rather than 20.

**Measured** on the new `pcallxpl` image (ring 0 → ring 3 via the outer RETF fixed
above, then back in through a DPL-3 gate):

```
before  ebp=0x00000000 esi=0x00000000                    (spurious #GP; ring 0 never reached)
after   ebp=0x0CA60010 esi=0x00005000 esp=0x00005FF0 cs=0x0008
```

Callee on `TSS.SS0`, caller's ESP recovered *from the frame*, and ESP = `TSS.ESP0`
(0x6000) minus the 4-dword frame.

The arm was found unreachable by **probing** it: the first build after the
implementation showed a byte-identical 89-instruction run and a `$display` in the arm
printed nothing at all. That pointed at a fault upstream instead of at the new code.

**Still open, deliberately:** param count > 0 halts loudly with its own tag (`0xDA`).
Copying parameters needs a read/write beat pair per dword against the caller's stack, and
dropping them silently would corrupt the callee's arguments.

---

## H-11 — a non-cacheable read is one beat, not a line burst

A non-cacheable read reused the FILL burst, so one architectural read became a 32-byte
eight-beat request. For MMIO that is a **correctness** bug, not a performance one:
read-to-clear registers are cleared eight times over, FIFOs pop repeatedly, and seven
neighbouring addresses with unrelated side effects are touched.

The decline recorded at this code was a six-item work list rather than a judgement, and
every item was real:

1–2. `ven_axi_master`'s `m_axi_arlen = 8'(LINE_BEATS-1)` **constant** became `rbeats_q`,
     latched with `araddr_q` at accept. This was the crux — the L1D could not ask for
     fewer beats however it addressed the request, because the master decided, and it
     always decided "a whole line."
3.   `ventium_l1_axi` plumbs `m_rd_narrow`/`_2` through, but **only** on the L2-bypass
     path; with the northbridge in the datapath they are tied 0, so this makes no
     untested claim about a configuration whose gates do not run here.
4.   `ven_l1d` addresses the **word** containing `c_addr`. Addressing the line base was
     half the bug — it over-read seven neighbours *and* started at the wrong address.
5.   the `L1_BYP` serve indexes a 2-word window by `c_addr[1:0]`.
5b.  the priming double-read is unchanged and remains separate work: it is a documented
     workaround for a PS `S_AXI_HP` FIFO bug (task #24), not an oversight.
6.   an unaligned access still needs two beats, so "single beat" is really "one or two,
     by alignment." The seam carries no read *size*, so alignment alone decides —
     conservative in the safe direction.

**It subsumes two earlier workarounds.** H-19's cross-line bypass case and C-09's
seven-beat drain both existed only because the fetch was line-shaped. C-09's own note
offered "a real single-beat backing operation" as the alternative fix and took the drain
instead, because the seam could not express a single word. It can now.

**Measured** — no *data* assertion can see this, because serving the right word was never
the problem and every existing check passed with the amplification. New `tb_l1d` case
`[11e]` counts backing read beats:

```
aligned    8 beats -> 1
unaligned  8 beats -> 2   (data also checked: the 2-word window is new logic)
```

A seam mismatch surfaced while doing it: `ven_axi_master` latches only beat 0's address,
but `tb_l1d` has no master and serves each beat's `m_addr` directly. The cacheable fill
already presented an incrementing per-beat address to satisfy both; the narrow path now
does too.

---

## C-04 — one canonical request address

"Paging lookup and bus address are generated independently": 56 `cur_lin` arms in
`core.sv` against 62 `mem_addr` arms in `core_bus_driver.svh`, hand-maintained in
parallel and already not one-to-one. They had drifted repeatedly — `stk16()` applied on
one side only, fixed 4-byte strides vs `q_w`, GDT hard-coded vs `selector.TI`, states
present in one list and not the other — and every drift is a silent wrong-memory failure.

For a translatable state the architectural address **is** `cur_lin`: that is the address
the TLB looked up and the page walk filled. The bus driver now takes it directly, so
there is one generator and the second cannot disagree with it.

**Why this could be done safely** rather than as the big-bang refactor the earlier note
declined: CHECK 5 (added under REVIEW2 C-03) had been comparing the two generators on
every translatable request all along, and is green across the corpus — so the override is
a no-op on all reachable behaviour. That is *known*, not hoped. The prior claim
(`core.sv:1242`, "proven verbatim across the FSM arms") rested on reading 56 arms against
62 by eye, which is exactly the kind of load-bearing-by-inspection invariant this finding
is about.

Deliberately an **override**, not a deletion of the arms. They are now dead for
translatable states, and CHECK 5 is retargeted at them (`mem_addr_arm`) so it keeps
proving the equality per-state — which is what lets them be removed one at a time with
evidence. Comparing against the live `mem_addr` would be tautological and would destroy
that evidence.

**The check is live, not vacuous:** a positive control (`mem_addr_arm = mem_addr + 4`)
makes it fire on `pxpage`; the real arms leave it silent. Stated because "silent" and
"cannot speak" look identical in a log.

**A correction I nearly shipped as a blocker.** Adding the override draws an `UNOPTFLAT`
on `cur_seg_rel` — the bus driver's `always_comb` produces the segment identity `cur_lin`
consumes and would now also consume `cur_lin`. I had written that up as the structural
reason the collapse could not be done. Then I measured it: **the warning is pre-existing
at HEAD**, byte-identical, with no working changes at all. The cycle is real and predates
this work; it is recorded as its own issue rather than used to veto the change.

---

## H-13 — fetch cacheability follows the physical memory type

Instruction-fetch cacheability was driven by `CR0.CD` alone, with no notion of the
**memory type** of the address being fetched. A line in a region the chipset marks
non-cacheable was cached anyway, so later fetches from it were served from a stale copy.

This finding had two recorded blockers. The first was not technical: `ven_cachemap.sv`
lived only on `soc-northbridge-v1` (commit `c8dbf3b`, verified not an ancestor of HEAD),
so landing it was a decision about which branch state ships. **That decision was taken,
and the module is now on this branch** along with its 25-check datasheet gate.

The second blocker was real and is addressed directly: the existing D-side query
(`u_cmap_l1`) lives *inside* the `EN_L2` generate and therefore elaborates only with
`EN_L2=1`. An `is_code` query added there would be neither built nor tested by anything
in `verify-all`. The new I-side query is **outside** that generate, so it is in the
default build, and `ven_cachemap.sv` moved from `NB_RTL` into the common source list.

`is_code=1` matters and is not cosmetic: a PAM window set read-only (`RE=1, WE=0`) is
L1-cacheable for **code** reads and not for data, which is exactly the shadowed-BIOS case
the decoder exists to model.

The result is ORed into `ic_fill_nocache`, not substituted: `CR0.CD` and the memory type
are independent reasons not to retain a line, and either alone is sufficient. On cacheable
DRAM the map returns `l1_cacheable=1`, so the new term is 0 and the OR is inert — the
recorded CR0.CD perf figures are unaffected by construction.

**Measured** on the new `pmtype` image, which runs a reuse-heavy loop from `0xA8000`
(inside the SMRAM/VGA aperture, decoded `l1_cacheable=0` with SMRAM closed):

```
memory-type ON   clocks=37664  retired=2885  ebp=0x960
memory-type OFF  clocks=32896  retired=2885  ebp=0x960
```

Refetching, and architecturally identical. The gate asserts **both**, because one alone
is not enough: a clock-count-only check would pass while the fix silently broke
execution.

**Fallout, and it is the good kind — the build found it.** Six standalone L1AXI
testbenches instantiate `ventium_l1_axi` and went warning-fatal on the new pin the
moment it existed; their gate scripts list RTL explicitly and needed the new module; and
`ven_cachemap` carried `assign tom = {tom_mb4, 22'd0}` — 30 bits into a 32-bit net. The
*value* was right (max `255<<22` fits in 30 bits), but the module now builds in a
warning-fatal path, so the width is stated explicitly rather than suppressed.

**Two ways this test measured nothing before it measured something**, both recorded in
the gate header so the next person does not repeat them:

* Without `--l1-axi`, `l1axi_en=0`, the L1/northbridge path is inert and `core_req` never
  fires. First run: **56208 reads on both sides.**
* Without the image clearing `CR0.CD`, `ic_fill_nocache` is already 1 from the CR0 term
  — CR0 resets to `0x60000010` and no image in this corpus clears it — so the memory-type
  term ORs into an expression that is already true. Second run: **46752 reads on both
  sides.**

Both were caught by probing the actual signal (`core_addr=000a802f l1c=0 nocache=1
region=2`) rather than trusting the identical numbers.

---

## Method notes

Four habits accounted for most of the real progress, and each was earned by a mistake
earlier in the review:

1. **Probe the RTL's actual state; do not re-edit on a theory.** H-08 lost two attempts
   to a confident wrong diagnosis. The cross-privilege call gate was found unreachable
   because a `$display` in the new arm printed nothing.
2. **Verify every edit landed before trusting a build.** A `pkill -f "run-verify-all"`
   matched the shell running it and silently dropped an entire edit batch; the next step
   checked and found the edit count was 0.
3. **Confirm each witness discriminates by measuring the reverted build.** Every fix
   above has a measured before/after, not a predicted one.
4. **Check a blocker before believing it.** C-04 was one sentence away from being
   declined a second time over a combinational-loop warning that turned out to be
   pre-existing.

## Still open

* **Call-gate param count > 0** — halts loudly (tag `0xDA`); needs a per-dword copy
  micro-sequence. Fail-safe as it stands.
* **The dead bus-driver `mem_addr` arms** — delete one at a time, gated on CHECK 5
  staying silent for each state.
* **A pre-existing combinational cycle on `cur_seg_rel`** — measured at HEAD, unrelated
  to this work, newly recorded.

## Final state

`verify-all` — **22/22**:

```
verify  verify-sys  verify-srt  m6  x87b  a20  seg  fenv  intlim  tsslim
retfsel callsel     xc04        unimpl  retfout  callxpl  mtype  icbypass
ioperm  l1          bus         bus-sva
```

Excluded, unchanged: `verify-soc` (absent from this checkout, M-03/M-04) and the
artifact-dependent m7 Quake lock-step / Win95 co-sim runs.
