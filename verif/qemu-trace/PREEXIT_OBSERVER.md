# Actual terminal-state observation — October 9

**Verification proposal, not a processor/performance fix or a green generic
gate.** Latest verified gameplay is **0.49083588 total U+V IPC**, model
`86731249`, cycles **1.2–1.3B**, predating the pending, unmeasured x87 C1 repair.
Full direct-memory CoreMark is **2.107843209 / 2.110905243 CM/MHz** on
`b5453f16`; cache-backed throughput, full timedemo and FPGA acceptance remain
open. Historical results below retain their original build/window scope.

## Problem and implementation

QEMU linux-user destroys its CPU on `exit`/`exit_group` before the ordinary
single-step stop can expose the final INT's actual architectural state.
`gen_trace.py` correctly stops on the `W` reply; it cannot read registers after
process destruction. UV-fast RTL emits that real retirement. This accounted
for most of the existing 101 length-only failures.

`prepare_preexit_observer.py:transform()` adds an **opt-in debug observation**
at the two normal process-exit sites in a private QEMU 8.2.2 source copy. When
`VTM_QEMU_GDB_PREEXIT=1`, the existing `gdb_handlesig` API exposes the live CPU
before cleanup. The unmodified trace producer reads its actual `g` packet and
emits the record through `tracefmt.py`; resuming produces the real `W` reply.

No register, guest memory, return value, instruction pointer, syscall number,
RTL trace or comparator is edited. There is no synthesized terminal state or
terminal-record filtering. The observer is disabled by default, ignores values
other than the literal `1`, and does nothing without an attached debugger.
It is not called for individual-thread teardown or fatal-signal cleanup. Scope
qualified here: the single-threaded i386 corpus and ordinary RSP step/read;
multi-thread debugger signal delivery is not qualified.

**The canonical pinned source/binary and default gate remain untouched.**
Do not replace the pinned oracle merely because this experimental functional
subgate has fewer failures. Never share a golden cache between observer modes:
the current worker's cache signature includes the binary but not this opt-in
environment setting. Every experiment below uses a fresh, mode-specific cache.

## Private matched builds

Root: `/home/yukidama/external/tmp/ventium-qemu-preexit-r2.81Yu1ixT`.
`build.py`, `started.json`, both `*-source.json` inventories and native
configure/build logs retain the complete procedure. The original dirty QEMU
source changes are preserved in both copies and recorded separately.

| Build | Executable SHA-256 |
| --- | --- |
| Matched control | `c179d82fd029890affbc96cb2cda7fa7c7b2d8b38baa887fd1d87b63bff55a83` |
| Opt-in observer | `52a9ca27d2d1bb40a360a7c2e881b8fe63b0795f285ae823b96e33e75ef0ff31` |

Configuration preserves i386-linux-user, plugins, system/tools/docs disabled;
downloads are additionally prohibited. Both build natively with 32 compiler
jobs in the bounded shared build scope, taking about 9.7 seconds each after
configuration. Sources and canonical inputs remain unchanged across compilation.

The first attempt, `ventium-qemu-preexit.JTRKgwLI`, fails because current host
glibc also declares `struct sched_attr`. Its failed receipt remains. The second
attempt applies `host_compat()` identically to both copies: it renames QEMU's
six private C type-tag uses, preserving every field, layout and target ABI.
The only control-to-observer delta is the debug hook. No canonical host-compat
patch is applied.

## Closed tests

Six source-recipe guards pass, including exact reversible changes, refusal of
missing/ambiguous/drifted anchors and double application. Run with:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B \
  verif/qemu-trace/test_preexit_observer.py
```

`run_preexit_observer.py` runs **24 native microcases**: exit 1/252, codes
0/7/255, two x87 states, and two CF/DF settings. The fixture sets up its own
stack and registers normally, performs a real `write`, and exits. There are
no debugger register writes or save states.

For every case:

- Pinned QEMU, matched control and disabled/invalid-option observer produce
  exactly identical complete architectural records, including x87 state.
- The enabled observer adds exactly one real terminal record; all earlier
  records remain identical, without field masks or register normalization.
- An independent raw-RSP run reads the entire real register packet before and
  after INT, verifies that only actual EIP changes, then observes the real `W`
  reply and native process exit. All expected integer/x87 state is retained.
- A count-limited run before exit is unchanged; no-debugger native runs retain
  the same output and status with the observer both enabled and disabled.

`micro-r1/closed.json`: **24/24 pass**, stable pins. Deliberately supplying the
unpatched control as the observer fails **24/24** in `negative-unpatched`.
This proves an ignored environment option is not accepted as feature support.
Example, inside the bounded build scope with a fresh output directory:

```sh
python3 -B verif/qemu-trace/run_preexit_observer.py \
  --pinned /path/to/original/qemu-i386 \
  --control /path/to/private/control/qemu-i386 \
  --observer /path/to/private/observer/qemu-i386 \
  --out /home/yukidama/external/tmp/FRESH_MICRO_OUTPUT --jobs 24
```

The separate `prefix-audit-r2` compares all **108 actual corpus ELFs** across
pinned QEMU, matched control and observer, with identical guest environments.
All original records match **every field exactly**, without oracle masks or
register normalization. The observer adds 101 actual terminal records; seven
count-limited traces remain unchanged. The first audit, `prefix-audit-r1`,
incorrectly required an immediate `W` reply even when the new terminal record
exactly reached the producer's instruction cap. Its five failures are retained.
The corrected audit independently reruns those five ELFs with one more allowed
record: it observes the actual original exit code, **identical full traces and
zero extra instructions**. No exit reply or terminal state is fabricated.

## Full functional subgate: 106 pass, two remain failing

`functional-r1` invokes the **unchanged** canonical worker and comparator on all
108 programs, with the qualified observer in a separate golden cache. Core
model `e3d9aa69` retains UV + system/relocated fast path, `--cycle-func`, the
AXI backend, assertions and exact frozen under-fill source. It passes 105/108.

`mb_jmppair`'s old 5,000-instruction cap stops inside a U/V retirement pair,
leaving 5,001 RTL records but 5,000 QEMU records. Its source actually executes
**5,204 instructions**: one setup, 200 × 26 loop instructions, three exit
instructions. The manifest now allows 6,000, covering the complete unchanged
program. **All 5,204 architectural records match**, including the terminal INT;
no record is removed or artificially inserted. The native log retains 2,500+
real paired issue clocks. This is more test coverage, not a weakened comparison.

`functional-r2` repeats all 108 programs: **106 pass / two FAIL**, with stable
pins. The failures are newly observable persistence of the already documented
x87 oracle gaps into the actual terminal record:

| Test | Terminal record / PC | Golden FSW | RTL FSW |
| --- | --- | --- | --- |
| `mb_fxch` | 923 / `0x08048039` | `0x0000` | `0x0041` |
| `tx_fprem` | 300 / `0x08048415` | `0x0020` | `0x0320` |

The pre-existing exact masks stop at records 922 and 299, respectively. They
have **not been extended**; no comparator, x87 state, test instruction or timing
band has been relaxed to label this green. QEMU lacks the stack-fault response
exercised by `mb_fxch` and the FPREM1 quotient condition-code result documented
by `tx_fprem`. Independent architectural proof and a deliberate oracle policy
are still needed for terminal propagation; these are not silently waived.

The prior five hard cycle-band failures (depadd, indepadd, dmiss, imiss, nearbr)
also remain open. This observer experiment does not fix or requalify timing,
the whole generic gate, the standard suite, FPGA execution or gameplay IPC.

### Additional architectural finding; do not extend the masks blindly

The later [exact-FSQRT witness](../../fp_shared/tb/FSQRT_C1_PERSISTENCE.md)
demonstrates a real RTL C1-persistence defect after FPREM1, independently of
QEMU's missing quotient flags. Native hardware clears C1 for exact `sqrt(1)`;
current shared-FP RTL retains it. C0/C2/C3 are undefined after FSQRT and are
not compared by this witness. Thus the `tx_fprem` terminal discrepancy cannot
be closed merely by extending its old quotient-flag mask. No masks were changed.
Latest verified gameplay is now0.49083588 U+V IPC on `86731249`, cycles1.2B–1.3B;
that measurement does not close this correctness issue.

### FXCH throughput fixture corrected — October 10

The original `mb_fxch` had no initial stack partner; it was not a legal
ordinary-throughput workload. One setup `FLD1` and one teardown `FSTP ST(0)`
keep its unchanged loop within depths 1–8. Its stack-fault/value masks are now
removed, not extended. On unchanged `b5453f16` UV-fast/AXI, all 926 records
including the true terminal record compare without added masks. The original
still fails unmasked at its first FXCH and is retained, with separate invalid
exchange coverage in `px87stk` and the shared-FP testbench.
See [the fixture evidence](../tests/mb_fxch/STACK_FIXTURE.md).

This is not a rerun of all 108 programs, a repair of `tx_fprem`, or canonical
gate acceptance. The observer remains opt-in; timing bands are unchanged.

## Current combined candidate — October 10, 18:57 UTC

The private observer was rerun on directed core `1139570b`, which contains
the current FP correctness repairs and code-buffer payload selector. The
unchanged canonical worker runs all **108 current programs** at real AXI
read/write latency 7, UV + system/relocated fast paths and `--cycle-func`.
An isolated enabled-observer cache is used; the pinned oracle and canonical
gate are untouched. Four workers are bound to four actual CPUs, with 2 GiB
RAM, no swap, 128 tasks and a ten-minute outer bound.

Root: `ventium-code-payload-preexit.n35jOl39` under external tmp. The run
closes in 88.60 seconds: **98 PASS / ten FAIL**, native controller exit 1,
invocation `0f8a5fd9c2424d75a77eefe630ed149a`. All 108 workers were waited
for and reaped; no OOM. Independent `audit.json` rechecks 5,617 source pins,
all **80,800 records** and the actual closed supervisor. Every trace length
matches. Re-running the original comparator with `--all` retains every
divergence and the original masks:

| Program | Differing fields/records reported |
|---|---:|
| `tx_addsub` | 1 |
| `tx_chain` | 5 |
| `tx_cmp` | 2 |
| `tx_fp_denorm` | 79 |
| `tx_fprem` | 58 |
| `tx_fxam` | 3 |
| `tx_muldiv` | 3 |
| `tx_round` | 8 |
| `tx_sqrt` | 1 |
| `tx_unifdiv` | 5 |

The 165 differences are FSW bit 9 (C1), FSW bit 8 (C0), or bit 9 copied into
EAX/ECX by the original instructions. This classification is not a waiver.
In particular, simply masking FSW would not validate status copied into GPRs.

[`check_preexit_c1_native.py`](../../fp_shared/tb/check_preexit_c1_native.py)
executes the exact unchanged ELFs with the existing passive native observer.
All ten **first-divergence** sites have matching input operands/control words.
Seven arithmetic sites agree with an independent exact-rational result/C1
check; the other three are exact, nonempty `FSTP ST0` operations, whose
native pop/tag behavior is checked and whose expected C1 is zero. Native C1
and RTL agree at all ten; QEMU disagrees. This includes `tx_cmp`, `tx_fxam`
and the now-earlier register-pop difference in `tx_fprem`. Invalid-ELF and
unreached-PC controls still fail closed; four host tests cover the new
register-store oracle branch. Evidence: `native-first-sites/result.json`.

The native host is **not P54 silicon**, and these ten selected sites do not
independently validate all 165 differences. No mask, golden, test instruction
or timing band changed. Canonical `make verify` remains FAIL; this diagnostic
does not substitute for it or the standard suite. Latest verified gameplay
is **0.46555093 U+V retirement-event IPC**, older `bfb867f7`, cycles
4,300,065,237–4,400,065,237; all 32 windows average 0.494922360. The combined
candidate has no verified gameplay measurement yet.

## Repaired candidate: all remaining reported fields observed natively

On October 10, the [zero-C1/BCD-sign candidate](../../fp_shared/tb/ZERO_C1_BCD_SIGN.md)
`f74dd76b` reran the unchanged functional worker with the private exit observer:
**98 PASS / ten FAIL**, all 80,800 records, in 44.17 seconds. Differences fall
from 165 to **161**: the four independently confirmed FLD errors are gone.
Root `ventium-zero-c1-preexit.8NudGMAo`, invocation
`a5932c288d0b498ead84477445262c4b`; independent `audit.json` rechecks 6,226 input
pins, all trace lengths and every remaining comparison. No OOM or new masks.

The new [`prepare_native_gpr_observer.py`](../../fp_shared/tb/prepare_native_gpr_observer.py)
derives a separate passive native observer without modifying the pinned old
helper. It reads real GPRs before/after the selected instruction. Enabling
`PTRACE_O_TRACEEXIT` also permits an actual live stop at an exiting INT before
the task disappears; that event is explicitly identified in the output.
The child resumes to its natural zero exit and is reaped. There are no guest
patches, register writes, injected instructions or synthetic terminal packets.
Terminal GPR syscall semantics are **not** qualified by this test; the terminal
comparison here is FSW only.

All **117 distinct instruction sites** contributing the remaining differences
were executed using their unchanged gate ELFs on native x87. Independent audit
compares the **entire reported field values**, not just disputed bits:

| Field | Reported differences | Native value equals RTL | Native value equals QEMU |
|---|---:|---:|---:|
| FSW | 91 | 91 | 0 |
| EAX | 38 | 38 | 0 |
| ECX | 32 | 32 | 0 |
| Total | **161** | **161** | **0** |

The final `tx_fprem` INT at record 300 yields native and RTL FSW **0x0120**,
versus QEMU **0x0020**. This includes C0 persistence; agreement on the modern
native host does **not** turn architecturally undefined bits into P54 guarantees.
Likewise, these selected fields are not a replacement full-ISA native oracle.

Controls independently check known GPR values across INC, unchanged registers
across FNOP and seeded FSW across the real exit event. Non-ELF and unreached-PC
controls fail closed. Two host recipe tests also pass. Native root
`ventium-preexit-gpr-native.14cUSbOf/{started.json,result.json,audit.json}`,
invocation `843f705846a64cb09777b4c285a05c77`, closes zero with stable pins and
no OOM; the C derivative, GCC command, fixture, all raw witnesses and driver
are retained there. Run the host tests with:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=fp_shared/tb python3 -B -m unittest -v \
  test_native_gpr_observer
```

No new RTL defect is demonstrated by these remaining 161 fields. The canonical
pinned-QEMU gate nevertheless remains **FAIL**, including its independent cycle
failures. Its oracle policy must be resolved explicitly; neither dropping a
terminal record nor blindly extending masks is an accepted fix. FPGA and full
standard-suite acceptance are still pending. Latest verified gameplay remains
older simulated `bfb867f7`: **0.53765810 U+V event IPC**, cycles
4,500,065,237–4,600,065,237; the repaired candidate remains gameplay-unmeasured.

## Cache-mode aliasing reproduced and privately repaired — October 12

The production worker remains untouched because the active FPGA synthesis pins
it. Its cache signature identifies the QEMU executable, but **not**
`VTM_QEMU_GDB_PREEXIT`. Consequently a shared cache can silently reuse the
disabled-observer trace while the observer is enabled, or vice versa. This is
an evidence-selection bug, separate from the remaining x87 oracle differences.
The cycle worker also searches the obsolete source-only functional filename,
omitting the ELF and oracle signatures that actual functional cache files use.
It therefore normally falls back to its default ESP instead of finding the
matching loader-established ESP.

[`prepare_observer_cache_key.py`](../lib/prepare_observer_cache_key.py) makes a
private exact-parent worker copy. It changes only cache identity/lookup:

- Normalize the observer setting exactly like the existing native hook: literal
  `1` enables it; unset and all other values are disabled.
- Include that mode in the signature and deliberately version out old keys.
- Use the identical source/ELF/oracle/x87/instruction-limit functional key for
  the cycle worker's ESP lookup.

It does not enable the observer, alter the pinned QEMU, synthesize a terminal
record, change any trace/compare/mask, or adjust RTL mode or timing bands.
Three source/shell-equation tests pass, including reversible scope, drift and
reapplication rejection, invalid-option normalization, deliberate old-key
invalidation and exact functional/cycle key agreement.

The [native regression](../lib/run_observer_cache_key.py) uses the **real worker,
qualified private QEMU binary, unchanged `smoke` assembly and prebuilt UV-fast
AXI model** `e65a06e1`. There is no fake producer or testbench. The four original
worker invocations reproduce the bug; four repaired functional invocations
and one repaired cycle invocation verify the change:

| Worker / cache sequence | Observer setting | Golden records | Cache hit | Functional verdict |
| --- | --- | ---: | ---: | --- |
| Original, disabled first | 0 → 1 | 21 → 21 | 0 → 1 | FAIL → FAIL |
| Original, enabled first | 1 → 0 | 22 → 22 | 0 → 1 | PASS → PASS |
| Repaired, shared cache | 0 → 1 → 1 → 0 | 21 → 22 → 22 → 21 | 0 → 0 → 1 → 1 | FAIL → PASS → PASS → FAIL |

All RTL executions retain all 22 records. Disabled-mode failures remain the
original terminal-length mismatch; they are required witnesses, not suppressed
failures. Original enabled-first reuse produces a PASS using a trace from the
wrong oracle mode. The repaired cycle invocation uses the matching golden's
actual **ESP `0x40800250`**, with **eight actual V retirements** and unchanged
control flow. Its cycle comparison still fails the original timing tolerance
(47 reference vs 448 RTL clocks); this test qualifies cache/argument transport,
**not timing-band acceptance**.

Evidence: `ventium-load-read-ack.GyWDDtiI/observer-cache-r1` under external tmp.
Owner `ventium-observer-cache-key-oct12`, invocation
`9d97c7bfb58644ffb7ddf3400c3f4146`, closes native zero in **3.57 seconds**,
with stable input hashes. It is a CPU12-only light job, 768 MiB RAM/no swap,
128 tasks, concurrent with (not part of) the one guarded Vivado family.
The original worker, canonical cache and active synthesis inputs are unchanged.
Applying this private repair to the canonical worker remains pending; it must
not invalidate an in-flight build's pins. Even after promotion, the canonical
QEMU policy, 101 functional failures and independent cycle failures remain
unresolved; no green gate or FPGA pass is claimed.

Latest verified gameplay baseline is **0.51030715 total U+V simulated
retirement-event IPC**, older `2b4d7a4`, cycles
**1,200,065,237–1,300,065,237**. The current timing candidate is unmeasured.

## Closed-trace GPR propagation audit — October 12

The 70 reported GPR differences above now have an independent, read-only
dataflow check, separate from the native-host agreement check.
[`audit_preexit_gpr_flow.py`](../../fp_shared/tb/audit_preexit_gpr_flow.py)
reads the **unchanged** closed `f74dd76b` traces and their reported differences.
On both QEMU and RTL separately, it verifies complete 32-bit equations:

- FNSTSW AX copies the **prior** status into AX and preserves EAX's upper half.
- MOVZX ECX,AX zero-extends the prior AX into the whole ECX register.
- The admitted intervening opcodes do not write that GPR, and its complete
  value remains unchanged. An unchanged XOR alone is not accepted as proof.

All **70 fields pass**: **6 FNSTSW AX copies, 5 MOVZX copies, 59 preserved
values**. Every reported native field still equals the entire RTL field, and
all 40 input pins were rehashed before and after analysis. The tool rejects
unreported/unexplained differences, unsupported preserving opcodes, missing
records, and full-register corruption even when both traces retain the same
disputed-bit XOR. **Five host tests pass**, including such negative controls
and deliberately changed *post*-FNSTSW status, which must not be confused with
the instruction's input status.

Primary source checked visually: Intel **241430-004**, Volume 3, Table 6-4
(printed p. 6-12; PDF p. 151), FST/FSTP (25-138; PDF p. 755), and FSTSW/FNSTSW
(25-143/144; PDF pp. 760/761). The latter explicitly stores the prior ESC's
status but lists its own subsequent condition codes as undefined. Likewise,
FSQRT and FST/FSTP do not define C0/C2/C3. Native agreement on such bits is
therefore not a P54 guarantee. The local source is
`ventium-refs/01-intel-canonical/241430-004_Pentium_Processor_Family_Developers_Manual_Volume_3_Jul95.pdf`,
SHA-256 `63c27628292de539eb6ea9089404fe7b5d1fca9d292021a4493dce044e9aa988`.

Evidence: external tmp `ventium-p54-status-origin.MVDMtGws/gpr-flow.json`,
SHA-256 `13461b8786ba977c55ee508c556b3ac08d6cbad8419899035175817bf8f04005`.
Unit `ventium-preexit-gpr-flow-oct12`, invocation
`691aad402947419e9d5d80f69e44e2b0`, closed native 0 at **00:30:55 UTC**,
peak memory **16,498,688 bytes**, under a 384 MiB/no-swap limit and CPU12
`taskset`. No guest, simulator or QEMU run was launched; this lightweight
analysis ran alongside the existing sole Vivado synthesis family.

This establishes that those reported integer discrepancies are copied x87
status discrepancies, **not independent GPR-copy defects**. It does not establish
which underlying C1 value is architecturally correct, qualify undefined bits,
or replace the remaining **91 FSW-field** checks. No RTL, golden, mask, fixture,
cycle band or active synthesis input changed. The canonical gate remains red,
and the current candidate still needs full standard-suite and physical FPGA
acceptance. Current candidate gameplay IPC remains **unmeasured**; older
simulation baseline **0.51030715 U+V IPC**, `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**, predates it.
