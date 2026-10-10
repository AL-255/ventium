# Protected-client prefix fast path — October 10

**Private candidate only; not standard-suite or FPGA acceptance.** Latest
verified gameplay is **0.49038392 total U+V retirement-event IPC**, parent
`958f7ec4`, clocks 1,700,048,811–1,800,048,811. All six consecutive 100M
windows from 1,200,048,811 average **0.489820525**, retaining the earlier dip.
The new prefix candidate has no gameplay measurement. Cache-backed CoreMark
parent short ratios remain 1.96212548/1.96640592, not duration-valid scores.

## Measured missing backport and change

The cache-backed CoreMark trace includes word-register shifts and compares
in S_EXEC even though `VEN_P54_PREFIX66_REG` is enabled. Its original
`p54_prefix66_context_ok` explicitly rejects every system-mode client; the
feature only benefits flat Linux-user tests, not the PC/FPGA environment.

`prepare-prefix66-system.py` changes **only** `core_prefix66_d1.svh` under
new default-off `VEN_P54_PREFIX66_SYSTEM`. It adds the same checked protected,
32-bit flat/relocated client context used by ordinary register fast issue.
Real/V86/16-bit/SMM, architectural debug, host STEP and older memory/FP/fragment
owners stay excluded. The existing raw decoder, register-only whitelist,
word-width merge, U/V pairing and explicit parent-register RAW/WAW rules are
unchanged. A prefixed U still pays one actual no-issue D1 clock; prefixed V,
memory, repeated prefixes and prefix+0F remain excluded.

The existing 32-bit token records linear `flin` instead of offset EIP in the
enabled profile. No extra register, cache, decode port, stage or SRAM is added.
A different CS base cannot reuse a paid token at the same EIP. Context-changing
instructions cannot execute while this register owner is held in S_PIPE;
state departure, invalidation, events, debug and consumption cancel the token.
The ordinary fetch permission/CS-extent and event authorities still apply.
This is not a claim that those system interactions are all qualified yet.

## Closed tests

Root: `external/tmp/ventium-prefix66-system.Gv8TOU2v`. The core model is
**16ab1312**, derived from **3dcf4cbb**, with exactly one RTL file and one define
changed. Its private C++ basename/header is checked, all source pins stable,
assertions and six structural hard errors enabled. Production RTL is unchanged.

- Three host recipe tests pass (exact inverse, preserved guards, bad anchors,
  reapplication and overwrite refusal).
- Actual candidate D1 leaf passes **174** context/token checks, including
  all 128 context-veto combinations, paged relocated mode, old user-mode
  behavior, paid-clock ownership, changed linear base, event/STEP/TF/RF/DR7
  cancellation, lost returned bytes, older owners and reset. This is a leaf
  state test, not an actual interrupt/page-fault delivery qualification.
- `prefix66-system.S` cold resets and enters paged protected mode. Eight forms
  cover shifts, compares, arithmetic, RAW, explicit SP/ESP WAW, a prefixed V,
  memory fallback and repeated-prefix fallback. Flat/relocated clients at all
  32 line positions, AXI latencies 0/7, control/candidate: **2,048 complete
  QEMU architectural comparisons**, plus corresponding cycle executions.
  Full GPR/CR/segments/flags and PC/length sequences are compared without new
  masks or terminal trimming. All native results, fault counts and pins pass.
- Eligible prefixed U/V pairs are actually observed (6,124 candidate V
  retirements), not inferred from configuration. All RAW/WAW/prefixed-V
  rejection cases and both fallback classes remain correct. Every warm
  tested prefix result is at least two clocks after its predecessor.
- Of **1,024 matched** warm-loop comparisons, **256 improve, 768 equal**,
  none regress. Across whole cold fixtures, **256 improve, 8 equal, 760 are
  slower**; those startup costs are retained, not hidden behind warm results.
  At aligned layout, CMP/Jcc improves five to four clocks per loop; two
  consecutive prefixed operations improve six to five. Shift/independent-MOV
  and ADD/independent-MOV preserve four-clock loop cost despite moving the pair.

The unchanged canonical `make verify` remains **FAIL**, native make exit 2,
seven functional passes / 101 failures and hard legacy cycle-band failures.
No generic acceptance mask, terminal record, golden or timing band changed.
Passing microtests do not qualify that red gate or the broader processor.

## Full-PC measurement and remaining work

Full-PC model **320c4232** is the exact **958f7ec4** source closure plus only
this tested leaf and define. Root `ventium-prefix66-system-soc.uLbhxUAh`.
Build native 0; own harness headers/pins verified; the same 98 inherited
platform structural warnings remain, with no additions. This is not a clean
whole-platform lint pass. Full P5 L1s, 256 KiB L2, posted16 and UV/system/relocated
fast load/store mode remain unchanged.

The first cold CoreMark launcher used TasksMax=32, below the simulator's
initial thread requirement, and aborted before guest execution with
`std::system_error: Resource temporarily unavailable`. It was **not OOM**;
the failed `coremark/` logs and zero-OOM receipt remain. The separate
`coremark-r2/` retry completed both seeds correctly, but the independent audit
rejected its CPU-confinement claim: systemd's configured `AllowedCPUs=3` did
not restrict the native affinity on this user manager. Both failed audit
attempts and the original results are retained, not relabelled as passes.

`coremark-r3/` repeats both seeds through explicit `taskset -c 3`, with verified
child affinity `[3]`, TasksMax=128, 2 GiB RAM, zero swap, a 13M guest-clock cap
and a 240-second native bound per seed. Same unchanged disks/ROMs, 40/40/80 MHz
timebases and ordinary cold reset. Both children exit 0 and are reaped; all
five CRCs per seed match QEMU. Results exactly reproduce R2:

| Ten-iteration seed | Parent TSC clocks | Candidate TSC clocks | Short CM/MHz ratio | Throughput gain |
| --- | ---: | ---: | ---: | ---: |
| Performance | 5,096,514 | 5,013,253 | 1.994712814 | 1.660818% |
| Validation | 5,085,420 | 5,001,043 | 1.999582887 | 1.687188% |

The measured savings are **83,261 / 84,377 clocks**, not a projection from
microtests. These remain **short diagnostic ratios, not duration-valid scores**;
the duration errors are preserved, and both are below 2.1. This does not qualify
either the standard suite or the physical board. Independent `coremark-r3/audit.json`
rechecks 284 pins, real V retirements, native exits, actual affinity, no OOM,
and the retained closed supervisor invocation
`3598cf6b1de34ff6b052c00356a781ec` (MainPID=0, exit 0, released cgroup).

Before promotion: actual interrupt/debug/fault/SMC interleavings and CS/page
boundary fixtures, unchanged user/default-off regression, generic gate repair,
both full CoreMark seeds, Win95 desktop, complete Quake timedemo, current
gameplay measurements and hardware area/timing/deployment. No snapshot or
guest-specific workaround is introduced by this proposal.

## Boundary tests and cold Quake follow-up

`prefix66-boundary.S` / `run-prefix66-boundary.py` add ordinary-reset RAM-code
probes for mapped page crossings, an absent instruction-tail page which the
guest #PF handler maps and retries, a CS-truncated immediate, and a CPU-store
SMC revisit at the same EIP. These are actual architectural deliveries/stores,
not forced token inputs. Flat and relocated clients run against both models
with AXI latency 0/7 and complete untrimmed traces in both observer modes.

**The aggregate boundary gate is not green.** The initial `boundary/` run
passes six of eight fixtures but both CS-limit fixtures fail the ordinary
QEMU self-check, exit 135 rather than 133. A separate `cs-limit-diagnostic/`
records both RTL models correctly delivering exactly one #GP(0), preserving
the faulting AX and younger EBX, and closing 133. QEMU executes beyond that CS
limit instead; it cannot serve as this case's differential oracle. This is
retained as a failed oracle case, not a masked architectural comparison.

`boundary-mapped/` expands the other three classes: **18/22 fixtures pass**,
72 complete architectural comparisons plus 72 cycle runs, including actual
page-tail #PF recovery and four observed prefixed V retirements. Four SMC
fixtures (offset 4094/4095, both bases) fail native QEMU's self-check before
RTL grading. At offset 4094 the native QEMU instruction log re-executes old
immediate 1234 after the store to 4321; the GDB-stepped golden and both native
RTL models execute 4321 and complete 133 (`smc-diagnostic/`). This demonstrates
an execution-mode-sensitive oracle problem, not proof of its full root cause.
No successful single-stepped oracle result substitutes for failed free-running
QEMU acceptance. Source, failed logs and complete diagnostic traces remain.

The prefix-only SoC has now started a fresh ordinary cold Quake run:
`ventium-prefix66-system-soc.uLbhxUAh/quake-cold-prefix66-oct10.1`;
service `ventium-prefix66-quake-oct10.service`, invocation
`2e3e2dd5c8064373926d93d42703ac55`, actual native PID 516043 on CPU 6.
The full compiled closure, unchanged media, real affinity and UV-fast mode
are pinned; the supervisor is retained after exit. Its first IPC window is
preselected at periodic samples 12/13, retaining every subsequent consecutive
window. **No gameplay result, completed timedemo or suite pass yet.**
