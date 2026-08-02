# Ventium — progress against REVIEW1_Aug2.md

**33 findings closed or partially closed, 3 claims refuted with evidence, 1 attempted
and reverted with its measurement, 2 open (H-06, H-07 — one shared bypass).**
`make verify-all` = 11/11 gates. `make l1` = 17 gates (was 13). `verify-sys` = 19 tests.

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
| **M-04** | 16-bit x87 env forms wrote the 28/108-byte image over a 14/94-byte object | all 7 witnesses match the harness QEMU |
| **M-07** | port 0x92 bit 0 (fast reset) silently dropped | `fast_reset_req` output + `S_SHUTDOWN` |
| **C-03** (part) | the crossing split covered only `S_LOAD` | `S_LOAD2` added; extent layer + a LOUD assertion for the rest, now gated |
| **C-04** | implicit descriptor/TSS refs used CPL3 paging class | **86** reclassified per pv86 run |
| **C-09** | task switch unpaged, unvalidated, incrementally committed | all four parts; ptask/ptaskcpl/ptaskv86 EQUIVALENT |
| **C-10** (part) | the core never *requested* a locked transaction | `bp_req_lock` driven; AXI side deliberately not |
| **H-12** | FSW.ES was never derived, and once derived was never CONSUMED | `SW=8081` vs `0001`; `#MF` `M1=0001` matches QEMU |

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

- **C-03** the canonical request-layer REWORK is still not done: the states that
  cannot split a page-crossing access still cannot. What changed is that the extent is
  now represented (`cur_size` beside `cur_lin`), the gap is MEASURED rather than
  assumed (0 reachable under paging across 68 images), it is LOUD rather than silent,
  and the assertion guarding it is finally enforced by a gate. See §4e.
- **C-09** hardware task switching: unpaged, unvalidated, incrementally committed.
- **C-04** implicit descriptor/TSS references use CPL3 page permissions; they need a
  supervisor access class carried with the request.
- **C-10** LOCKed RMW is not atomic against DMA.

**Remaining, and none of these is a small edit:**
- **H-06 / H-07** — these two DO share a datapath: a non-allocating bypass that can
  deliver bytes without allocating a line. H-06 needs it on the fetch side
  (`ic_fill_nocache` is tied to 0; the I-cache is also the fetch datapath, so merely
  poisoning the fill livelocks). H-07 needs it on the L1D read side
  (`BYPASS_RD_EN=0` under `VEN_L1_HONOR_CD`). H-07 was attempted directly, DEADLOCKED
  the core, and was reverted with its measurement (§3).
  **H-05 was NOT part of this** — see §4g; that framing was mine and it was wrong.
- **M-06** — task gates, 16-bit TSS types, and cross-privilege call gates. Three distinct
  ISA mechanisms.

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

## 4b. M-04 — a diagnosis I got wrong, and what it cost

I closed M-04's second half as structurally blocked and wrote, in this document:

> the 94-byte FNSAVE register area starts at offset 14, so it is 2-byte aligned while
> the sequencer addresses `ea + 4*beat`. Needs a byte-granular stride.

**14 is even.** Every field in both 16-bit images is a word, so the whole transfer is a
stride of 2 with a 2-byte strobe — which the core already emits for m16 (`S_FSTORE`
does exactly this for FNSTCW). Nothing byte-granular was ever required. What actually
differs between the forms is the field LAYOUT, and the beat COUNT is identical at seven:

```
32-bit, 28 bytes            16-bit, 14 bytes
  +0  CW                      +0  CW
  +4  SW                      +2  SW
  +8  TW                      +4  TW
  +12 FIP                     +6  IP[15:0]
  +16 {FOP, CS}               +8  protected: CS   real: {IP[19:16],0,FOP}
  +20 FDP                     +10 DP[15:0]
  +24 FDS                     +12 protected: DS   real: {DP[19:16], 0}
```

The 94-byte form is the same object plus the 8 ST registers — the SAME 640 bits the
108-byte image carries, gathered 40 words at a time instead of 20 dwords. 47 beats, so
`f_seq_step` went to 6 bits and `env_tmp` to 47 entries. That was the whole blocker.

Both halves now share two single-source signals, `fenv_off` (the beat's byte offset) and
`fenv_last` (the final beat index), read by the FSM, the bus arm and the commit block
alike. Open-coding either in two places is precisely the defect C-03 exists to catch.

### What the witnesses caught that a round trip would not

Seven witnesses, all graded against the harness QEMU (`E1=ffff E2=eeee E3=037f E4=3fff
E5=eeee E6=eeee E7=0003`); Ventium prints the same.

The **round-trip witnesses passed under reversion.** E3 (FLDENV reload) reported PASS
with the 14-byte fix reverted, because the store and load halves were wrong in the same
direction and therefore agreed with each other. A gate built only from "save it, load it,
check it came back" would have been decorative here. What discriminates is:

- a **layout probe** — the word at +4, which holds TW in the narrow form and SW in the
  wide one, values FNINIT makes distinguishable. Reading +0 proves nothing: CW is at +0
  in both layouts.
- a **poison witness** past the object's end, which is the corruption itself.

The oracle also caught two arithmetic errors in my own test before Ventium ever ran it:
I placed the 94-byte layout probe at +36 instead of +4, and sized the poison loop at 138
bytes when it needed 228, so the overrun witness sat outside the poisoned region and read
as uninitialised memory. Writing the expected values down first and asking QEMU before
looking at Ventium is what surfaced both.

---

## 4c. H-11 — right fix, wrong default, and a measurement I over-read

`we_push` wrote `fpr[ftop-1]` without consulting `fptag`, and `we_pop` advanced TOP
without checking: a 9th push silently DESTROYED a live register, and popping an empty
stack handed back whatever bits were in the slot. Neither raised anything.

Implemented per SDM Vol.1 8.5.1 + Table 8-4 — IE+SF, C1 giving the direction (1
overflow, 0 underflow), and on a MASKED fault the destination receiving the QNaN
indefinite rather than the value. Detection sits at the resolved `fp_we_push` /
`fp_we_pop` signals, so all ~10 drive sites funnel through one check.

### The oracle cannot grade this

```c
static inline void fpush(CPUX86State *env)
{ env->fpstt = (env->fpstt - 1) & 7; env->fptags[env->fpstt] = 0; }
```

No tag check. And `#define FPUS_SF (1 << 6)` at `target/i386/tcg/fpu_helper.c:59` is the
**only** occurrence of that symbol in QEMU's entire i386 target — defined, never used.
Measured, the harness QEMU prints `S1=3800 S2=3fff S3=0800`: TOP moved, nothing else.

### The measurement I over-read

I measured 68 images from `verif/sys/tests/` — zero stack faults — and reported both
"no false positives" AND "no differential test regresses." The first was right. The
second was a claim about a corpus I had not measured: the m1–m5 differential programs
live in `verif/tests/`. Three of them (`tx_stack`, `tx_regform`, `tx_regform2`) drive
the stack past its ends ON PURPOSE — `tx_stack`'s own header says "push 8 deep + wrap,
then unwind to empty" — and turning the response on failed `verify` AND `l1` at
95 PASS / 3 FAIL.

Disassembly confirmed Ventium was RIGHT, not over-firing:

```
8048003..8048011   eight pushes (fld1, fldl2t ... fld %st(1))
8048013..804801d   fxch/fadd/fmul/fsub/fdiv/frndint  -- none of these pop
804801f            fld1        <- a 9th push, with fptag=00 (all eight slots live)
```

### So it is DEFAULT-OFF, and that is a limitation, not a completion

`VEN_X87_STKFLT` follows the `VEN_SEG_ENFORCE` precedent this repo already set for the
identical situation with segment limits:

- default build: QEMU-equivalent, so the 98-program differential keeps its meaning
- DETECTION is unconditional, so `+ven_stklog` still measures reachability in the
  shipping build (it counts 1 overflow + 1 underflow on the gate's own image there)
- gate build: `+define+VEN_X87_STKFLT`, self-checked against the SDM

**The FPGA build Win95 and Quake run on therefore does NOT get stack-fault semantics.**
I judged that trading a working 98-program differential for a feature correct code never
exercises (0 firings across 68 system images) was the wrong trade — but that is a
judgement call, and it is recorded here as one rather than as "H-11 closed."

---

## 4d. H-12's remainder — the oracle decided the design

FSW.ES was derived by H-12's first half and then **consumed by nothing**: an unmasked
exception was raised and ignored forever. A pending one must be delivered as #MF
(vector 16) before the next WAITING FP instruction, with CR0.NE selecting the route
(NE=1 internal #MF; NE=0 the external FERR#/IGNNE# path this core does not model, so
NE=0 behaviour is unchanged).

The real question was WHERE to check, and I let the oracle answer it rather than
guessing. Real hardware checks on every waiting FP instruction. QEMU does not — it emits
`gen_helper_fwait` at exactly two sites, `translate.c:5538` (FWAIT) and `:4608` (FNOP,
commented "FreeBSD FPU probe"), and nowhere else. So:

- **FWAIT + FNOP**: unconditional. Matches the oracle, differential-safe, and it is the
  path real software uses to synchronise.
- **every other waiting op**: behind `VEN_X87_MF_STRICT` (elaborates and runs clean).
- **the no-wait forms** (`FNINIT`/`FNCLEX`/`FNSTSW`/`FNSTCW`/`FNSTENV`/`FNSAVE`): never
  checked, in EITHER mode. This is the detail that decides whether the feature is usable
  at all — they are precisely what a handler uses to read and clear the status word, so
  trapping them would make an unmasked exception permanently unrecoverable.

Unlike the stack faults, QEMU implements this one, so the witness is graded
DIFFERENTIALLY: both print `M1=0001`.

`M1` counts handler entries and must be exactly 1, which tests both directions from a
single number: **0** = ES set but never consumed (the finding); **2+** = the handler's
FNCLEX did not clear ES, so the second FWAIT faulted again — an unrecoverable loop in
real software. Reversion gives 0.

---

## 4e. C-03 — an unenforced assertion, and a number that was 94% noise

Two things surfaced here that matter more than the code I wrote.

### CHECK 5 was firing into the void

`PAGING/C-03` — the assertion that `cur_lin` (the TLB lookup) and `mem_addr` (the bus)
agree — appears in this repo ONLY in build artifacts. Nothing under `verif/` greps for
it. It has been the stated acceptance criterion for every address-path change this
session, and a real firing would have printed to a log and been ignored. That is the
same class as the M-08 exit-code bug: a check that exists, reports, and is not read.
The seg gate's corpus sweep now counts it and fails on a nonzero count.

### The measurement I nearly published

A generic detector over every translatable state found **47 unsplit page-crossing
beats** — which reads as a serious reachable defect. It is not. I had not qualified on
`paging_on`, and with PG=0 the linear address IS the physical one: a straddling extent
is one contiguous access, there is no second translation to get wrong and no #PF owed.

| | crossing beats | UNSPLIT |
|---|---|---|
| unqualified | 50 | 47 |
| **paging enabled** | **3** | **0** |

All three are in split-capable states. So the remaining half of C-03 is UNREACHABLE
across the 68-image system corpus — now an evidence-backed statement rather than an
assumption. Had I reported the 47, it would have been a real-sounding number that was
94% real-mode boot traffic.

### What landed

`(cur_lin, cur_size)` is the (start, length) pair a canonical byte-addressed request
layer carries, defined per-state right beside `cur_lin` so the two cannot drift. The
detector covers EVERY translatable state, not the three that can split, and the
remaining gap is now loud: if Win95 or Quake drives a straddling extent through a state
that cannot split, the assertion names the state, address and extent instead of
corrupting a page and continuing.

Self-tested by removing `S_LOAD` from the split-capable set: fires exactly once on
`pxpage`, so it discriminates rather than decorates.

**The rework itself is still open.** This makes the gap measurable, loud and gated; it
does not close it.

---

## 4f. H-08 / H-09 — I was wrong that these were unfixable here

I wrote "no source in this checkout" for H-08 and H-09 across several updates. That was
wrong, and it came from paraphrasing my own earlier summary instead of reading
REVIEW1_Aug2.md. **Both findings name files that are in this tree.**

- H-08 targets `rtl/mem/ventium_l1_axi.sv:500-529` — the `EN_L2=0` branch, i.e. the one
  that BUILDS. Only its `EN_L2=1` half references the northbridge modules.
- H-09 targets `3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v:90-111`, a live submodule.

Even the northbridge sources exist — on an unmerged branch
(`worktree-agent-ae43c03eda066c796` @ `b511932`, verified NOT an ancestor of HEAD, and
`rtl/northbridge/` has history in this repo but is absent from HEAD's tree). So the
accurate statement was never "absent"; it was "the L2-enabled half lives on a branch
this one does not contain."

That is the FOURTH time this round I called something blocked that was not (C-09,
M-04's second half, and C-03's reachability were the others).

### H-09 — the skid lost invalidations two ways, and one was silent

```
port FREE, one PENDING, a fresh pulse arrives:
  sequential : `else if (l2_inv_pend && !update_tag_we)` -> l2_inv_pend <= 0
  combinational: l2_inv_go_a = l2_inv_pulse ? fresh : pending   -> FRESH wins
  result     : the pending set is retired WITHOUT being applied
```

Case 1 (a colliding pulse overwriting the held address) at least printed a warning.
This one had none. A dropped invalidation leaves a stale L2 line valid, so a later read
returns data another master has overwritten — silent memory corruption.

Replaced with a **pending bitmap**, one bit per set. This works because invalidation
here is IDEMPOTENT and SET-INDEXED: duplicates collapse with no loss of meaning, so the
state needed is 128 bits rather than a queue of addresses. Lossless at any pulse rate
with no producer contract — which is exactly what the review said was missing.

The gate runs BOTH directions. The original skid loses **5 of 8** requested sets.

### H-08 — SMRAM was reachable on the configuration that ships

`smm_active` was consumed only inside the `EN_L2=1` branch. On the buildable path,
ordinary code could read and rewrite the SMM handler and its saved state at A0000-BFFFF,
which is the entirety of SMM's security model.

Added the 82437FX DEN/DOPEN rule (`DRAM iff DEN && (DOPEN || in SMM)`) to the buildable
path. Denied accesses complete as an unbacked aperture rather than stalling — deliberate,
because withholding the ack is precisely how the H-07 attempt hung the core. Inert at the
default `NB_SMRAM=0x00`.

### A test that passed for the wrong reason

My first SMRAM test had case C (non-SMM read) passing EVEN IN THE BROKEN BUILD: case B
had already clobbered the secret, so the read trivially differed from it. C was not
independent of B. Re-seeding from SMM before the read makes it discriminate — the
reverted build now fails both B and C rather than only B. Same lesson as E3/E7 in §4b:
a witness that depends on an earlier witness's failure proves nothing.

---

## 4g. H-05 — the review named a remedy I had not read

I had been describing H-05/H-06/H-07 as "one shared bypass datapath seen from three
angles". H-06 and H-07 genuinely do share one. **H-05 does not** — it is I-cache tag
aliasing, and the review ends it with an explicitly acceptable remedy:

> Use physical I-tags or maintain a reverse alias mechanism; flushing all executable
> state on every CPU store would be correct but expensive.

I had not read that sentence. The finding sat classified as structural for the whole
cycle because I was working from my own summary again.

### The hazard, now reproduced

The I-cache is LINEAR-tagged and a CPU store snoops with the store's LINEAR address
(`ventium_l1_axi.sv:333`, `icache_snoop_addr1 = core_lin`). With one physical page
mapped by two linear addresses, a store through alias B invalidates only B, and a stale
EXECUTABLE copy stays resident under A and is fetched and executed. Self-modifying code,
a loader writing code through a scratch mapping, and A20 mask changes all produce it.

`VEN_IC_ALIAS_SAFE` is the review's third option: every CPU store flushes executable
state. Self-contained in `icache.sv` because `flush_all` already existed.

  - default: a store invalidates only its own linear line. Fast, wrong under aliasing.
  - `+VEN_IC_ALIAS_SAFE`: correct under any aliasing, and expensive — every store costs
    a full I-cache refill, on a core where S_FETCH is already 52% of all clocks.

**The real fix is physical I-tags and is NOT done.** This makes the correct behaviour
available and tested rather than leaving the hazard with no way to demonstrate or avoid
it, and prices it explicitly instead of shipping it silently.

### The gate asserts the DEFAULT build still misbehaves

| build | assertion |
|---|---|
| default | alias A MUST survive a store through alias B — the hazard reproduces |
| `+VEN_IC_ALIAS_SAFE` | alias A MUST be dropped |

If the default ever stops reproducing it, the gate FAILS rather than continuing to print
OK. That is the M-08 lesson applied forward: a gate that cannot tell "fixed properly"
from "no longer testing anything" is worse than no gate. Both directions also run the
control (a store to a line invalidates THAT line), so a build that cached nothing could
not pass either direction by accident.

### A testbench written against an interface that does not exist

My first attempt assumed `icache` had `fetch_req`/`fetch_valid` ports. It does not — it
is array-exposed and driven by the core's FSM. Rebuilt on `tb_icache_snoop`'s proven
harness, which also has the useful property of driving snoop PORT 1 — the CPU store port
that gate deliberately ties off, and which therefore had no coverage at all until now.

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
