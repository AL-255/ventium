# FP-only wide-response timing cut

Private derivative of the audited PAYLOAD-REGION source, **not accepted RTL or
a qualified FPGA image**. The immediate target remains **at least 40 MHz
post-synthesis Fmax with UV + fast-pipe retained**. The latest measured parent
is **34.113392918 MHz**, setup **−4.314 ns**, core hold **−0.101 ns**, unplaced;
this proposal has **no timing measurement yet**.

## Why this change

The parent's 30 worst reported paths traverse EIP/decode, paired branch
lookahead, address/DTLB permission checks, next-request arbitration, wide-load
validity and finally FP register-bank enables: 100 logic levels. All four
next-request offers require `mc_boundary_ok`, hence `S_PIPE`. The sole wide-FP
load consumer requires the distinct `S_FLOAD` state.

`prepare_fp_wide_context.py` adds a separate contextual high-valid signal,
omitting **only** next-request arbitration. The ordinary high-valid output is
unchanged. The new signal travels through the existing seam/top and is used
only by `fp_load64_take`; its `S_FLOAD`, page extent, fragment, debug, width
and ownership restrictions remain unchanged. Residency, complete saved-line,
cacheability, reset, snoop, flush, route, SMRAM and CD checks remain intact.
There are no added registers, cycles, feature flags, clock exceptions or guest
special cases. Old high-valid/ACK/FP-command assertions remain; new assertions
check next-request exclusion and equality in the FP context.

**The contextual output is not a general grant.** It intentionally differs
when a next request arbitrates the read port. Wiring it to other consumers
without proving their context is incorrect. The independent captured-V path
was also failing at **−3.804 ns**; fixing the FP endpoint alone cannot establish
40 MHz.

## Closed preflight evidence

Evidence root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `fp-wide-context-leaf-r1`: source-extracted Icarus comparison, three profiles
  (chain with/without paired stores and no chain), **3,057,600 checks each**
  (**9,172,800 total**, 20.610 seconds). Each profile exercises **81,062**
  actual leaf wide-take events. Seven separately compiled mutants fail:
  lost residency, lost window owner, wrong line extent, lost consumer state,
  wrong page extent, narrow command without ACK, and denied-request leakage.
  No core state is injected. State exclusion is an explicit leaf assumption,
  separately addressed below.
- `fp-wide-context-proof-r1`: actual source guard/enum inspection plus an
  over-approximated Boolean SMT contract. Five positive queries are UNSAT;
  general-grant misuse and each of four unguarded offers produce SAT
  counterexamples. Six source mutations removing domination are rejected.
  This is **not** automatic formal elaboration of the entire RTL or a
  sequential ISA proof.
- `fp-wide-context-cache-r1`: two native full-size cache builds, **18.001
  seconds**. Positive A/B passes **747,037 both-edge checks / 463 next-port
  samples**, including every compared enabled output, bank, tag, valid/LRU
  entry and saved owner. **735,545 uncontended samples / 139,486 valid high
  samples** agree; **384** contended differences demonstrate why the signal
  cannot replace a general grant. Existing wide-window and 51-case fresh-pair
  coverage remains. Deliberately removing arbitration from the ordinary grant
  fails at `PARALLEL-CACHE-MISMATCH output c_rdata_hi_valid`.
- `fp-wide-context-core-r1`: native build passed in **21.325 seconds**, with
  all **195 source files** audited and exactly **four RTL deltas**, unchanged
  **152 defines**, 32-job guard, unique private C++ basename and matching
  generated-header dependency check. Model SHA-256:
  `0a6bbdb15f7ed7994641ab7ea1934a0d830b5f50d857853e5bbea29140a18e4f`.
- Seven host tests pass in `test_fp_wide_context.py`: exact reversible scope,
  all seven source pins, fail-closed guard parsing, retained old assertions,
  full cache/private-builder safeguards, unchanged architectural test plan and
  unchanged complete FP/boundary/fault/replay plan.

Closure SHA-256 values, respectively:

```text
leaf  5df58f11fbf5f34e7f8e100cf37ea400e74b9873464bf2fdd53f2fa210b72531
proof 2e23ad1f0a51977cc8ed07bb26bbf83578658d111bf61d37b790515c5807a740
cache b7a482f752960f705198f895fafa60b412cd230e3935d736f73d9f89b57d9915
build 390005f7122453ee917492b159172a0cc463f87bac64b248011a59af751f2752
```

Owner services: `ventium-fp-wide-cache-oct13` (invocation
`c095680a51cd4c8c8b2e16d39b472058`) and `ventium-fp-wide-core-oct13`
(`941ac4e62d7148348e39fcc02410ae0e`) are closed successfully. Their child
guard-scope invocations, recorded in native receipts, are respectively
`2fe80cdceaa14c929ba15c58cce601e6` and
`c97bf7deb4d643448acf8d487fc0dec1`; do not confuse service and scope IDs.

Closed compiler products were byte-verified into recoverable `.tar.zst`
archives, freeing **507,513,801 bytes**. The receipt
`fp-wide-context-compiler-archive.json` records exact restore commands;
executables, headers, dependency files, sources and all **3,912 protected
input pins** were retained unchanged. Do not relaunch a completed build.

The eight-corpus native core A/B **passed in 310.893 seconds**, service
`ventium-fp-wide-checks-oct13.service`, service invocation
`d97ebc4da21d449caeb74036ce3524f8`, scope invocation
`682579ef4e414462b119648d4fa1475d`. Load/store, held, branch, integer, short FP,
AGI, reference-prime and AGI/store corpora all passed full native comparisons.
Coverage: **4,240 probes / 21,190,336 aggregate clocks**, 18,172 AGI offers,
24,352 reference offers, 282,808 prime offers, 5,616 pair intents, 3,072 pair
requests, 1,872 pair accepts and 1,536 shape-only exclusions. Complete
architectural/cycle comparisons and the original expected counts are unchanged.
Closure SHA-256:
`b6704a394c8f7d606869d2b83b4abbd2b391a3f99161d155fe604342c8e6d788`.

The closed corpus text is recoverable in
`closed-fp-wide-context-checks.tar.gz`: **38,352 entries**, **969,260,352 →
87,640,794 bytes**, archive SHA-256
`ba9a4bc3f6d23795eb68d1cd3decabbb26be60eac153e47bbd312649648d6d30`.
Every member was byte-verified before removing the unpacked copy. Restore with
`tar -xzf closed-fp-wide-context-checks.tar.gz -C` followed by the evidence root.
All sources, models, manifests, receipts and protected inputs remain unpacked.

## Closed regression and FPGA transfer evidence

The unchanged canonical gate closed in **402.535 seconds**, native `make`
exit **2**, **7 PASS / 101 FAIL**, unwaived. All **20 complete cycle traces**
match the parent; no masks, goldens or bands changed. Owner:
`ventium-fp-wide-verify-oct13.service`, invocation
`24ccd90ca4af49feb4c23d79f9a94f6f`; audit SHA-256
`f4418abe2644c5e5728039e11c16cebdf8c91e50b14846a94d0cdc155e2f33ee`.

The dependent queue `ventium-fp-wide-fp-queue-oct13.service`, invocation
`7fa5f09d82804207afd88c73b507eee3`, has closed successfully:

- Full FP: **384 fixtures / 1,536 measurements**, complete x87/system state,
  QEMU and latency 0/7 checks, **768 zero-cycle deltas**, **69.990 seconds**.
  Closure SHA-256:
  `48e4ce520dc11b3fdcc587dc9365d6474bed79315618fe4a2214984512f556e7`.
- All **12 regression groups** passed in **628.449 seconds**: six boundary
  offsets, faults, integer, memory, held requests, branches and the complete
  **108-case / 80,800-record same-input replay**. This replay establishes
  equivalence to the parent, **not** a repaired canonical gate. Closure:
  `389109c4855e39b6ec786f594a35f2be468d2f853c133c96eca5a2b7248dbe31`.

The closed FP text (11,916 files) and unpinned regression text (36,984 files)
are losslessly archived as `closed-fp-wide-context-fp-text.tar.gz` and
`closed-fp-wide-context-regressions.tar.gz`, saving **1,262,247,922 bytes**.
Each member was byte-verified before removing its unpacked copy; all 128
protected fault artifacts remain. The FP archive restores relative to
`/home/yukidama/external/tmp`; the regression archive relative to the evidence
root. See their `*-closed.json` receipts for SHA-256 and recovery details.

`fpga/build_fp_wide_context_soc.py` transferred exactly four changes across
the **102 shared RTL sources** and preserved all **156 simulation defines**.
The native full-PC build passed in **25.133 seconds**, with a unique private
C++ harness and checked generated-header dependency. Its **98 inherited
structural warnings are unchanged**, not waived into a full-SoC lint pass.
Model SHA-256:
`0a91843cf2f9a5f050db8ab5358d4e43f24b704aacb5dd165c1e39e17d73183b`.
Owner `ventium-fp-wide-context-pc-oct13.service`, invocation
`858f5c8c993a413ca366d0870433c09a`, is closed successfully.

`fpga/freeze_fp_wide_context_rk_candidate.py` exported **190 payloads / 170
shared HDL inputs**, with exactly the same four changes, **158 hardware
defines**, full P5 caches and original **40/100 MHz** clocks. Manifest SHA-256:
`6c60993a794d840af5e97398f7379754a8a4a2a2dc0aeff8ef6f0f582cc18e06`.
Strict hardware-profile **CPU-hierarchy** lint passed in **4.230 seconds**;
all six structural error classes remain fatal. This is not full-SoC lint.

Seven additional host tests check exact FPGA source transfer, preserved
regression admission, matched parent DCP and unchanged synthesis resource
watchdog/clock policy. `fpga/prepare_fp_wide_context_synthesis.py` prepares
the matched synthesis/report controllers without launching Vivado.

## Remaining qualification

Both short cold-boot CoreMark seed checks are running under
`ventium-fp-exec-cm10-fp-wide-context-oct13.service`, invocation
`54627764e07f415396f287da62fb0e54`, on CPU 11. They are preflight comparisons,
not duration-valid scores or standard-suite acceptance. Synthesis has not
started; no candidate Fmax is yet measured.

Still required: matched single-Vivado synthesis/timing reaching **40 MHz**,
canonical gate repair, complete standard-suite and real FPGA acceptance.
None of the equivalence/preflight evidence above resolves the canonical
oracle/architectural debt or establishes FPGA boot/timedemo correctness.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V retirement events/cycle**, model `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA or
full-timedemo IPC.
