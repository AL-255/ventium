# PROGRESS2_aug2 — closing out REVIEW1_Aug2.md

**35 findings closed or partially closed · 3 claims refuted with citations · 0 open.**

`make verify-all` = 11/11 · `make l1` = 17 gates (was 13) · `verify-sys` = 19 tests.

Ten commits, `cf786ce` … `6f57615` on `ao486-mister-sim`. This document covers that
range; the per-finding detail lives in `PROGRESS_REVIEW1_Aug2.md` §4b–§4i.

---

## 1. What landed

| finding | what it actually was | evidence |
|---|---|---|
| **M-04** | 16-bit x87 env forms wrote the 28/108-byte image over a 14/94-byte object | 7 witnesses, all matching the harness QEMU |
| **H-11** | x87 stack over/underflow was not detected at all | IE+SF+C1 + the QNaN indefinite; graded vs the SDM |
| **H-12** | FSW.ES was derived and then consumed by nothing | `#MF` route; `M1=0001`, matching QEMU |
| **C-03** (part) | the crossing split covered only `S_LOAD`/`S_STORE` | extent layer + a loud assertion, now gated |
| **H-05** | linear I-tags are incoherent across CPU virtual aliases | hazard reproduced; `VEN_IC_ALIAS_SAFE` removes it |
| **H-06** | `ic_fill_nocache` tied to 0; no non-allocating fetch path | 22/60 images refetch; state byte-identical |
| **H-07** | `VEN_L1_HONOR_CD` served non-cacheable reads from the array | `a5a54200` (stale) → `deadbeef` (fresh) |
| **H-08** | SMRAM was reachable by non-SMM code on the config that ships | 4-case gate incl. two anti-vacuity controls |
| **H-09** | the L2 invalidation skid lost invalidations two ways | the old skid loses **5 of 8** requested sets |

### Four correctness modes ship default-off, with their cost measured

Each trades real performance for correctness the oracle cannot grade. Each is now
demonstrable rather than theoretical, and priced openly rather than shipped silently.

| define | what it buys | what it costs |
|---|---|---|
| `VEN_SEG_ENFORCE` | per-access segment limits | (pre-existing) |
| `VEN_X87_STKFLT` | x87 stack-fault semantics | 3 of 98 differential programs diverge — QEMU has none |
| `VEN_IC_ALIAS_SAFE` | I-cache alias coherence | a full I-cache refill per CPU store |
| `VEN_IC_FETCH_BYPASS` | non-allocating instruction fetch | `psmm` issues **2.4×** the fetches |

The real fixes for the last two are physical I-tags and a proper cacheability map;
neither is done, and both are recorded as such rather than as closures.

---

## 2. Three findings the oracle could not grade

`ventium-refs/.../qemu-system-i386` (the **harness** 8.2.2, not the system 10.2.1) is
the reference for everything here. Three findings sit outside what it models, so their
gates self-check against the SDM and record QEMU's measured output in the header:

- **H-11** — `fpush`/`fpop` never consult `fptags`, and `FPUS_SF` is defined at
  `fpu_helper.c:59` and used **nowhere** in the i386 target. QEMU prints
  `S1=3800 S2=3fff S3=0800`: TOP moved, nothing else.
- **H-05 / H-06** — cacheability and I-tag aliasing are not modelled at all.
- (**C-06/segment limits**, from the prior cycle, for the same reason.)

**H-12 was the opposite**, and the oracle decided the design. QEMU emits
`gen_helper_fwait` at exactly two sites — `translate.c:5538` (FWAIT) and `:4608` (FNOP)
— and nowhere else, while real hardware checks every waiting FP instruction. So those
two are checked unconditionally (differential-safe) and the architecturally complete
form sits behind `VEN_X87_MF_STRICT`. The no-wait forms
(`FNINIT`/`FNCLEX`/`FNSTSW`/`FNSTCW`/`FNSTENV`/`FNSAVE`) are never checked in either
mode — they are what a handler uses to read and clear FSW, so trapping them would make
an unmasked exception permanently unrecoverable.

---

## 3. What went wrong, and what it cost

This is the part worth reading. The failures were not in the fixes; they were in my
judgement about what was worth attempting and what a measurement proved.

### 3.1 Six wrong "blocked" calls, one root cause

C-09 · M-04's second half · C-03's reachability · H-08/H-09 · H-05 · H-07.

Every one had the same cause: **I reasoned from my own earlier summaries instead of
re-reading the source.**

- **M-04** — I wrote that the 94-byte register area "starts at offset 14, so it needs a
  byte-granular stride." **14 is even.** Every field in both 16-bit images is a word,
  and the core already emits a 2-byte strobe for FNSTCW. Nothing byte-granular was ever
  required; the beat *count* never even changes.
- **H-08/H-09** — I recorded "no source in this checkout" for several turns. The review
  text names `rtl/mem/ventium_l1_axi.sv:500-529` and
  `3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v:90-111`. **Both are in this tree.** Only
  the `EN_L2=1` half is on an unmerged branch (`b511932`, verified not an ancestor of
  HEAD).
- **H-05** — the review ends the finding with *"flushing all executable state on every
  CPU store would be correct but expensive."* I had not read that sentence, and the
  finding sat classified as structural for the whole cycle because of it.
- **H-07** — the tree recorded that the bypass FSM "deadlocks in the full-core+bridge
  context." The serve path the review asks for **already existed**
  (`c_ack = … || (st==L1_BYP)`, serving from a private buffer, consulting `rd_hit`
  nowhere). The recorded deadlock was caused by a *different* change — mine — that gated
  `rd_hit` itself, which the post-fill serve also consults. I took a symptom for a
  property of the FSM and repeated it all cycle.

### 3.2 I rebuilt a bug I had just fixed

H-09's invalidation skid lost data because **one entry cannot hold two pending items**.
Two commits later I gave H-06's fetch-bypass window one entry — and the fetch reads two
lines (`ic_rd_wayA` from `flin`, `ic_rd_wayB` from `flin_nl`) for straddling
instructions. The two lines evicted each other's window on every straddle: 10
instructions in 2089 clocks, ~820 bus reads per instruction against 8 for one line fill.

Same shape, ~30 minutes apart, applied to someone else's code and then reproduced in my
own.

### 3.3 Measurements that proved nothing, and one that was 94% noise

- **The wrong corpus.** I measured 68 images from `verif/sys/tests/` and reported "no
  false positives **and** no differential test regresses." The first was right; the
  second was a claim about `verif/tests/`, which I had never swept. Three of those
  programs drive the x87 stack past its ends deliberately, and enabling H-11's response
  failed `verify` and `l1` at 95 PASS / 3 FAIL.
  → *Measure the corpus the claim is about.*
- **The missing qualifier.** A generic page-crossing detector reported **47 unsplit
  crossings**, which reads as a serious reachable defect. Qualified on `paging_on` — with
  PG=0 the linear address *is* the physical one, so a straddling extent is one contiguous
  access — the real number is **0 of 3**. The other 47 were harmless real-mode boot
  traffic.
- **The uninformative comparison.** H-06's two-entry window matched the caching build
  exactly, which was consistent both with the bypass working and with the test not
  reusing lines. My first attempt to discriminate picked an image needing `--cosim`, so
  both builds returned the same trivial 10 instructions. Only the full-corpus sweep
  settled it: **22 of 60 images refetch more**, up to 2.4×.

### 3.4 Reversion is the only thing that proved a gate worth anything

Three witnesses **passed while the defect was present**:

| witness | why it passed anyway |
|---|---|
| `E3` (FLDENV round trip) | store and load were wrong in the *same* direction, so they agreed |
| `E7` (FRSTOR round trip) | same |
| SMRAM case `C` (non-SMM read) | case `B` had already clobbered the secret, so the read trivially differed |

A witness that depends on an earlier witness's failure proves nothing. What discriminates
is a *layout probe* (a field that differs between the two encodings) and a *poison
witness* past the object's end. Case `C` now re-seeds from SMM first.

### 3.5 An assertion nobody read

`PAGING/C-03` — the assertion that `cur_lin` (the TLB lookup) and `mem_addr` (the bus)
agree — appears in this repo **only in build artifacts**. Nothing under `verif/` grepped
for it. It has been the stated acceptance criterion for every address-path change this
cycle, and a real firing would have printed to a log and been ignored. Same class as the
M-08 exit-code bug: a check that exists, reports, and is not read. The seg gate's corpus
sweep now counts it and fails on a nonzero count.

---

## 4. Gates added

| gate | asserts |
|---|---|
| `run-l2inv-gate.sh` | lossless invalidation **and** that the old skid demonstrably is not |
| `run-l1axi-smram-gate.sh` | SMRAM denied to non-SMM, with SMM + ordinary memory as anti-vacuity controls |
| `run-ic-alias-gate.sh` | the alias hazard **still reproduces** in the default build |
| `run-icbypass-gate.sh` | the bypass refetches **and** changes nothing architecturally |
| `run-fenv-gate.sh` (extended) | 7 M-04 witnesses, 3 H-11 witnesses, 1 H-12 witness |
| `run-seg-gate.sh` (extended) | `PAGING/C-03` firings across the corpus |
| `run-l1d-gate.sh` (extended) | now runs `VEN_L1_HONOR_CD` — the config H-07 lives in |

Two of these assert something unusual and deliberate:

- **`run-ic-alias-gate.sh` requires the DEFAULT build to still misbehave.** If the hazard
  stops reproducing, the gate fails rather than quietly printing OK. A gate that cannot
  distinguish "fixed properly" from "no longer testing anything" is worse than no gate.
- **`run-icbypass-gate.sh` asserts both halves.** Checking only "it still runs" would be
  satisfied by a build that quietly kept caching — and that build still hits a stale
  executable line after CD is set, which *is* the finding.

---

## 5. What I would check first

1. **The three self-checked gates** (H-05, H-06, H-11). They assert against my reading of
   the SDM, not against an oracle. If a reading is wrong, the gate cements the error.
2. **`VEN_IC_FETCH_BYPASS`'s two-entry window.** Two entries were enough for this corpus.
   I have no argument that two is *sufficient* — only that one was demonstrably not.
3. **C-03's rework is still open** as a rework. The extent is now represented, the gap is
   measured (0 reachable under paging across 68 images), it is loud, and the assertion is
   gated — but the states that cannot split a page-crossing access still cannot.
4. **The default build is unchanged by all four correctness modes.** That is the property
   that kept this safe to iterate on, and it is worth re-verifying independently.
