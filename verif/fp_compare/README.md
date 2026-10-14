# Direct x87 compare-invalid classification

October 14, 2026 UTC. **Private timing proposal; synthesis running, not promoted
or installed.** Source-extracted comparisons, the qualified functional corpus,
same-input replay and short full-PC checks pass; the canonical gate is still
red. No timing gain is claimed.

## Why this change

The [current-tag synthesis](../l1/WINDOW_CURRENT_REUSE.md) misses 40 MHz:
33.028371371 MHz unplaced, −5.277 ns setup slack. Its worst reported path runs
from `q_pc` through fetch-length checks, address/map/cacheability, L1 response
selection, FP memory conversion and compare classification to `FSW.B`.
The final six carry stages feed the normalized operand exponent and then
invalid-operation classification. This is not a false-path waiver.

The old `ven_fp_top` computes compare invalid status from the already widened
80-bit operand. That unnecessarily gives integer absolute-value/normalization
logic a path to the invalid flag, sticky ES and B bits:

- A signed 16/32/64-bit integer always widens to a finite exact floatx80 value;
  it cannot contribute a NaN invalid exception.
- A binary32/binary64 memory value is NaN exactly when its raw exponent is all
  ones and its fraction is nonzero. Normalizing a denormal is unnecessary to
  answer that question.
- The existing default-size raw floatx80 path and FUCOM's signaling-NaN-only
  behavior must remain, including unusual byte-count/opcode combinations.

`prepare.py` changes only that classifier and one call site. Numeric condition
codes still use the original converted operand and shared comparator. Command
admission, ready/busy, state updates, C1, sticky status, stack exceptions,
retirement, queued FXCH, memory ordering and integer/FP overlap are untouched.
No extra cycle, state, port, feature switch or guest-specific handling is added.

This removes a **source-level dependency** from exception classification, not
necessarily every critical FP path: numeric comparison still includes format
conversion. The next-line tag candidate is the parent and remains independently
unqualified for timing. A new synthesis is not yet justified as a 40 MHz pass.

## Exact implementation and checks

One changed file: `fp_shared/ven_fp_top.sv`. Parent SHA-256
`05bfa2a4d6eb1a3d3911b31a71c7d8ce1ec161d0e60f2408c6ae0061efb77aeb`;
candidate SHA-256
`8f7749836fd2f7c744c450eecc63d3539baf447998a3e00939577cef1705b7e2`.
Two recipe tests verify the exact reversible delta and reject drift/reapplication.
Dirty root RTL and all existing frozen sources remain untouched.

Evidence root: `/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.

`fp-compare-leaf-r1` compiles the actual old/new compare blocks and helper
functions, not hand-reimplemented reference arithmetic. **425,984 native
comparisons pass** for the complete 16-bit status result and converted operand:

- All 65,536 signed 16-bit input patterns.
- Every binary32 and binary64 exponent, both signs, zero fraction and every
  one-hot fraction bit: normal, denormal, infinity, signaling and quiet NaN.
- Sixteen operation forms × all sixteen byte counts × 512 special/random
  combinations, including raw floatx80 fallbacks and noncanonical encodings.
- Random prior status words and varied ST0/ST(i). Observed overlapping counts:
  3,736 memory-NaN cases, 2,048 quiet-register-NaN cases and 61,440 finite-integer
  cases. These are leaf comparisons, not retired instructions or gameplay.

Four separately compiled mutations all fail natively: dropping signaling-NaN
payloads, letting integer memory bits signal NaN, making quiet FUCOM signal,
and dropping the default raw-m80 classification. Every native child is observed
on CPU12 and reaped. No X/Z or formal equivalence claim is made.

The leaf closes in **20.98 s**, peak RAM **2,559,721,472 bytes**, no swap/OOM;
152 unchanged defines, six hard structural lint classes, 32 build jobs.
Outer owner `ventium-fp-compare-leaf-oct14-r1.service`, invocation
`83dce66778da4010a29c13b9c0d665e9`, is terminal, MainPID 0 / exit 0.
Closed receipt SHA-256:
`74be22ce833e249fd80b292db9b2c468b25f8a243fc1701c948e80bea1e5b59b`.

Core preparation first stopped at the **unchanged 5 GiB disk guard**, before
creating its directory or launching a compiler. Only ten closed leaf `.gch`
files were subsequently removed (833,695,773 bytes): exact regular files,
not evidence-pinned, with no open handles. Sources, binaries, logs and all
receipt hashes were rechecked and retained. These generated precompiled
headers are regenerable; no guest media or older run was deleted.

`fp-compare-core-r1` then builds in **20.42 s**, native exit 0, all pins stable.
Exactly one of 195 source files changes from next-line model `97b11f3b`;
all 152 definitions, assertions, full-P5 L1, UV/system/relocated fast paths and
board single-fill policy remain. The unique host source is compiled against
its own generated header/object. Model SHA-256:
`5de1eb0813bb02f252c8aea444a41a4fdc121e028843aabbf6bcd9e41a4a62d8`.
Outer owner `ventium-fp-compare-core-oct14-r1.service`, invocation
`6e4d3872115c44288508f0e250017191`, is terminal, MainPID 0 / exit 0.

## Closed whole-core regression

`run_checks.py`, `run_same_input.py` and the independent `audit_checks.py`
retain the original comparators, masks, cycle bands and native exit codes:

| Check | Closed result |
| --- | --- |
| Qualified private-QEMU corpus | **108/108 PASS**, 80,800 records, 112.80 s |
| Same-input parent/candidate replay | **108/108 PASS**, 216 native executions, 80,800 completely unmasked records, 175.08 s |
| Canonical `make verify` | **FAIL**, make exit 2, 393.44 s; **7 functional PASS / 101 FAIL** |
| Canonical parent/candidate cycle traces | All **20** complete traces identical |

The independent auditor regrades all qualified-QEMU comparisons and reopens
complete replay traces. It finds 105 unmasked QEMU passes and the same three
existing masked stack/condition-code cases (`tx_regform`, `tx_regform2`,
`tx_stack`). Identical-input replay does not mask ESP or other architectural
state, and reproduces the candidate's original functional trace. All per-test
clock counts and paired-retirement counts agree; both models have 30,132
V retirements in this directed corpus. This is not a gameplay measurement.

The audit checks **18,674 input pins** and confirms terminal MainPID 0 for
functional owner `5de4b124538f42009d202ca97e3f84ef` (exit 0), replay owner
`2b4f1a9388ea4a3aa18f7780c84e45bf` (exit 0), and canonical owner
`3e9721f66e284fc39fefa0fa28974ee1` (wrapper exit 1, preserving make exit 2).
The canonical functional and cycle-band failures are not waived by these
other passes. The subsequent full-PC transfer is recorded below; no board
programming followed.

| Receipt | SHA-256 |
| --- | --- |
| `fp-compare-core-r1/build-closed.json` | `484e9048953931f80b91109890a4f3e1cd2ca9ede9f9c9e9dec36ee00aac7b99` |
| `fp-compare-func-r1/closed.json` | `00f8fe4d7c24eec984671c4fc029b13aa35453893fdd0cd73fe86ca59b954484` |
| `fp-compare-same-input-r1/closed.json` | `e16966b474c8e92d15cf0430c9391d90000ac8b0507fe04ca8856f5d90d34857` |
| `fp-compare-core-r1/verify-closed.json` | `29cdef3508ebfdf723996dfa5d6ca55a8c0b93e02958ac4d6fdc9f62b9c507f4` |
| `fp-compare-regression-audit.json` | `20ec2c93635ad2548b1977e30065e64f910a3630f545385e9fcc2e48bdf36732` |

## Full-PC transfer and pending synthesis

The classifier and parallel next-line lookup are transferred together from
the tested core onto the current-tag PC parent. **All 102 shared RTL sources
match**; exactly `fp_shared/ven_fp_top.sv` and `rtl/mem/ven_l1d.sv` change.
The three transfer tests reject missing, drifted, reapplied and unrelated edits.
All 156 simulator definitions, UV/system/relocated fast paths, full P5 caches,
single-fill policy and posted-16 transport are retained. No feature is disabled.

`fp-compare-soc-r1` builds in **26.41 s**, native exit 0 with stable inputs and
its own compiled host/header. Model SHA-256:
`81edc510dab23425c3935e68b4ac9b5c0d84620e2df9f99e47a0a162f1c8f76a`.
The 98 existing platform structural warnings are unchanged, not waived as a
full-SoC lint pass. Separate strict CPU-hierarchy hardware lint passes all six
structural classes in **4.03 s**.

`fp-compare-env-fault-r1` passes **44 unchanged cold x87 environment-store
fixtures**, each compared against complete QEMU traces at AXI latencies 0/7
(88 differential comparisons), in **16.42 s**. Actual backing-memory activity
and V retirement are required; all children exit and no OOM occurs. This does
not cover every outstanding fault class.

Both ten-iteration CoreMark seeds finish with their reference CRCs and exactly
**4,767,218 / 4,753,406 ticks**, respectively. Thus measured cycle gain is
**0%**, as intended for these cycle-neutral timing cuts. V retirements are
1,055,307 / 1,054,254. These short controls are **not duration-valid scores or
full standard-suite acceptance**. The independent auditor rechecks 20,739
source pins, native CPU12 ownership, reaping and zero OOM.

| New closed receipt | SHA-256 |
| --- | --- |
| `fp-compare-soc-r1/build-closed.json` | `3462e34aa0f6a3979464194878a63e8c846b1394546b9af438de2658256f54aa` |
| `fp-compare-env-fault-r1/closed.json` | `d9414c25d297d332502853544a499d29fbf838aea1dca5d539337e4f885c6913` |
| `fp-compare-lint-r1/closed.json` | `c8359d74ba28043b22ffac29bcf7386dc7aae90398606561f1edb02032340a99` |
| `fp-compare-soc-r1/coremark/audit.json` | `41e4ca56f591df5477cb7ff55cdcaf11e38e481b68ac7ad827f2d1115a5db6f0` |

The frozen FPGA manifest is
`296ff7367ef6af0324c47a09615f09f2c02a700a3de411efc617f598c03c001b`:
190 payloads, 170 matched HDL inputs, 158 hardware definitions, unchanged
40/100 MHz constraints and mapper. The single synthesis launched at
**2026-10-14 00:43:51 UTC**, owner `ventium-fp-compare-synth-oct14-r1.service`,
invocation `f5d5293b365841b7bf83dee6be726874`; scope invocation
`a1f0bc8567784b4389a60b35e14168be`. It has **no timing result yet**.
RAM/swap limits remain 8/6 GiB, 48 tasks, native 45-minute bound, disk stop
floor 4 GiB and the unchanged twice-measured-growth admission check.
The independent clock audit is prepared, **not launched**; routing/programming
are not part of these controllers. The matched parent is **33.028371371 MHz
unplaced**, not a 40 MHz pass. Neither isolated area nor timing gain is assumed.

To recover scratch space, 13 unpinned compiler-cache/link-archive files from
closed builds were removed (**919,876,614 bytes**, regenerable). Sources,
model binaries, generated C++/headers, logs and current evidence pins remain.
Twenty older timing reports/August Win95 RAM snapshots were losslessly archived:
1,385,095,168 allocated bytes became a 36,991,890-byte tar.gz, every decompressed
SHA verified. **No guest disk was removed.** The archive and explicit restore
manifest are `closed-reports-august-win95{.tar.gz,-plan.json}` in the evidence
root. Current and immediate-parent DCPs and the latest timing reports remain.

Broader precise faults, a green canonical gate, the full standard suite, timing
and physical Win95/Quake qualification remain open.
The existing FPGA/Doom image was not replaced; **Doom FPS is unavailable**.

Gameplay IPC for this candidate is **unmeasured**. Latest verified baseline:
**0.49236929 total U+V**, FP-repair simulation model `c7b95b78`, cycles
**900,065,237–1,000,065,237**; [counter evidence](../../fpga/FP_REPAIR_EXPORT.md).
That older model's timedemo is still active, and this is not FPGA or Doom IPC.
