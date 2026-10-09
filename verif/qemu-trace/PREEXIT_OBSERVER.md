# Actual terminal-state observation — October 9

**Verification proposal, not a processor/performance fix or a green generic
gate.** Latest verified gameplay remains **0.37798811 total U+V IPC**, model
`4b5fb92f`, cycles **1.2–1.3B**, predating the FP/under-fill, LRU and XPM-fidelity
candidates. Their gameplay is unmeasured. Current-core direct-memory CoreMark
is **2.10736 / 2.11041 CM/MHz**; FPGA throughput and 0.48 gameplay IPC stay open.

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
