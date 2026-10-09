# Resident read-ahead during instruction fill — October 9

Experimental, default-off `VEN_L1D_PRIME_UNDER_IFILL`. **Not selected for the
running full-PC candidate, FPGA or standard-suite acceptance.** Last verified
gameplay is **0.39002079 total U+V IPC**, code-word model `f3be9a11`, cycles
1.2–1.3B, predating this change and the combined candidate. The
≥0.48 target remains open. Earlier full direct-memory CoreMark is
2.10736/2.11041 CM/MHz; latest combined full seeds are still running.

## Cause and limited change

The independently qualified D-under-I-fill path permits an ordinary resident
data read while the physically separate instruction staging buffer fills.
However, the existing `c_next_*` resident-read hint still rejects every I fill.
Its eventual ordinary demand therefore pays an avoidable capture clock.

The recipe changes **one predicate in `ven_l1d.sv`**, retaining the old clause
when disabled. During an I fill, a resident D hint can use the same physical
set because the fill writes only `code_line_q`, not D banks/tags/LRU. During a
D fill, the old different-set restriction remains. Admission still requires
no demand/registered/critical-response/stream owner, no poisoned/bypass fill,
current tag hit, cacheability, supported byte/dword extent, no flush/snoop and
an actual `c_next_commit`. An instruction-shaped live payload selector blocks
the new I-fill case. No backing transaction, RAM port, buffer or cache entry
is added. Ordinary registered response matching owns the returned data.

Required tested profile: existing code buffer, data-under-I-fill,
prime-under-D-fill, registered read priming and memory chaining. This is not a
general multithreaded/nonblocking cache or speculative memory read.

## Closed evidence

Root: `external/tmp/ventium-prime-ifill.AYpEQ7Nz`.

- Three recipe guards: exact reversible change, missing/duplicate/already
  applied/dependency drift rejection, isolated source-copy preservation.
- `leaf-r3`: control, candidate-disabled and candidate-enabled, each at reset
  seeds 1/7/101. Each retains the existing 150 memory-chain requests, 51
  instruction-word tests and 659 ordinary D-under-I-fill checks.
- **661 new checks per run**. All eight frozen backing phases, same/different
  D sets, every contained aligned dword and every byte offset: **640** primed
  reads return on the first demand clock when enabled. Control waits another
  clock for ordinary capture. Uncommitted hints leave owners/backing unchanged.
  Further checks reject D-fill same-set accesses, misses, MMIO, crossings,
  partial strobes, live demand and instruction-shaped selectors. Snoop/flush/
  reset kill captures/responses; every coincident I beat, including final
  same-set publication, preserves D data and LRU.
- `negatives-r2`: two actual RTL mutations independently fail the expected
  assertion: removing the D-fill set restriction; ignoring the live instruction
  selector. Both compile successfully first. This is checker sensitivity, not
  functional acceptance of a mutant.
- Full board-profile build `e20fb6088ff4ff87148f156fd9912aec440e9bc3c7da0d503fed9236c958cd09`;
  user-profile build `15fe0f87e9ba8544b843b166299054fccd88e5a0d518493289f45ab6cb99d93e`.
  Both native exit zero, private generated-header ownership, stable source
  pins and six structural hard-error classes.
- `system-matrix`: **76 full QEMU architectural comparisons**, including
  exact functional parent parity, across 19 existing fixtures and AXI latency
  0/7. Both preserve U/V operation.
- Canonical UV-fast/AXI `make verify` remains **FAIL**, native exit 2, stable
  pins: 7/108 functional PASS, 101 terminal-record mismatches; unchanged hard
  depadd/indepadd/dmiss/imiss failures (CPI 1.133/0.639/5.000/13.003).
  No comparator, oracle, record trimming, mask or timing-band change.

Failed attempts are retained. `leaf-r1` exhausts the inherited 1-ms simulation
watchdog after appending the second exhaustive fill matrix; `leaf-r2` rejects
the replacement anchor before compiling. `leaf-r3` uses a bounded 3-ms aggregate
watchdog, unchanged per-transaction checks and unchanged 30-second native cap.
The first negative runner rejects an ambiguous second mutation anchor after
the first mutant correctly fails; r2 uses the exact full priming clause.

The observed one-clock saving is a **leaf protocol result**. Full-core tests
prove the selected cases remain correct, not a representative gameplay gain
or frequency improvement. Actual full-PC use/performance, latest full standard
suite, generic gate closure and FPGA timing/resource checks remain open.

## Reproduction

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/l1/test_prime_under_ifill.py
python3 -B verif/l1/prepare_prime_under_ifill.py --source PARENT --out CANDIDATE
# In the bounded ipc_parallel32 build scope; fresh external scratch output:
python3 -B verif/l1/run_prime_under_ifill.py \
  --control-source PARENT --candidate-source CANDIDATE \
  --profile PARENT_DEFINES_TXT --out FRESH_LEAF_OUTPUT
```

The profile file is one `VEN_*` macro per line, without the new flag. The runner
adds it only to the candidate and builds all three variants with 32 jobs.
Keep CoreMark/full-PC service CPUs and their SMT siblings out of build affinity.

## Current-stack integration check (October 9, later)

Retested atop the WBUF admission-handoff model, without changing the core or
any other RTL. Root: `external/tmp/ventium-current-prime-ifill-r2.QNLjtZqp`.
Model **`d6d85104401ab79926da629fe8d0a476f11f8672b66461b40ce82e37c10dc37c`**.
All nine leaf runs pass (three reset seeds for parent, disabled and enabled);
each retains 150 memory-chain requests, 51 code-word checks, 659 D/I overlap
checks and 661 prime checks. The enabled variant has 640 first-demand-clock
prime completions per run; disabled controls have zero.

Both short CoreMark seeds retain all five CRCs, exact retirement counts and
unchanged direct-memory clocks. AXI clocks improve only **5,241,779→5,241,661**
and **5,235,258→5,235,140**: 118 clocks each, about **0.0023%**, not a useful
CoreMark target gain. These are not score-eligible duration runs. Native exit0,
zero OOM/swap, all children reaped; short-run service invocation
`a5fe63929b5941ce9973584a846e1368` closed successfully.

The unchanged generic gate still fails: 101 terminal-length comparisons and
the existing four hard cycle bands. Fresh same-input replay matches all108
complete parent architectural traces. That parity is not a generic-gate pass.
No full-PC promotion, physical result or deployment is claimed for this variant.

Failed preparation attempts remain: the first rejected mixed compiler options
in the macro-list field; the next completed its leaf suite but its nested build
wrapper waited on its own inherited lock after Python closed that descriptor.
Only those waiting wrapper processes were terminated. `build_r3.py` reuses the
unchanged leaf-qualified sources through one actual shared build-scope owner;
the fresh build and its private header/object ownership checks pass.

Latest verified gameplay remains **0.44183623 total U+V IPC**, `652de481`,
clocks **1,200,000,000–1,300,000,000**, predating this integration candidate.
The ≥0.48 target and this candidate's gameplay qualification remain open.
