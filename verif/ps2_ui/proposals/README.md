# PS/2 input-loss repair proposal

Status, 2026-10-02: **isolated microtests pass; not applied to production RTL**.
The live current5c Quake and separate Win95 UI experiment are unchanged. This
proposal is not desktop/UI acceptance, full-suite qualification or FPGA evidence.

## Change and tested inputs

The patch retains one already translated RX byte and one pending headless ACK,
with scan > ACK > controller-reply arbitration. Only an actual selected FIFO
write retires a producer. Full-FIFO credit requires a real keyboard read, not a
mouse-priority read. A selected I/O write executes once until its strobe goes
low. The actual platform iobus supplies low cycles between accepted writes.
Headless AUTOACK does not start a nonexistent physical keyboard SEND; the
AUTOACK-off keyboard and both profiles' mouse paths still use physical pins.
No larger FIFO, replay, guest modification or application-specific condition.

The staged tested controller SHA is
`7ebf00b9b982d7441f32ae6f79cb8944b5e981f4322c39c529bd38fa86e64726`.
Original controller SHA:
`1e4920f53d5a9616d6b121a7148906490a3edd166d2aaecca5fa0ec9439fcf2d`.
Unchanged simple_fifo SHA:
`aff3ebc275191351eb582f2624cb056712d392331a951f1ed778360ca81f3bf4`.
The C++ TB and read-only SV probe here are byte-exact copies of the tested
sources. Exported patch has repository-relative headers and complete final-hunk
context; `git apply --check` succeeds, **without applying it**. The initial
staged diff lacked that EOF context; only the export was corrected.

## Actual execution

Four independent new outputs under
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/` retain actual compiler/test waits,
closed logs, source-pin observations, supervisor identities and resources:

| Profile | Output leaf | Invocation ID | Peak bytes |
| --- | --- | --- | ---: |
| Fixed headless | `qualified-ps2-fixed-autoack.tgzc_32q` | `a1cd45aac3e54422b5348594b45a5657` | 511766528 |
| Fixed physical | `qualified-ps2-fixed-physical.jx_0io_c` | `e5bdcd8ec14e48d999a877b3ca60bd00` | 454373376 |
| Legacy headless | `qualified-ps2-legacy-autoack.5x1dojk8` | `bc8071bdcad04e6681adbd64a69040be` | 355753984 |
| Legacy physical | `qualified-ps2-legacy-physical.7ejr5c_u` | `ea42d42b4b6641d6844f6306d327cb9f` | 348692480 |

All compiler/test/owner/wrapper statuses are zero. Each phase has 2GiB RAM,
swap0,64tasks,two-CPU affinity28/30 and a deadline below590seconds. Before/after
65 input and10 staged artifact pins hold; all memory-cap/OOM counters are zero.
The successful retained exited units were cleared only after MainPID0, absent
cgroups and no stop hooks, releasing the waiting systemd wrappers normally.

Both fixed profiles pass ordinary translated/raw streams at32/64/1875/2917
half-periods, parity rejection/recovery, translated skid retention under full
FIFO, producer order, held-write/rearm ownership, reset/self-test cancellation
and physical mouse host data/parity/stop/ACK. Physical-off also exercises the
keyboard's real host transmission. Headless tests additionally check exact
make/raw/break/F0 collisions, full+read ACK credit versus mouse-priority exclusion,
a retained65th ACK/IBF and the natural LED-timeout prefix defect.
The legacy headless run **reproduces expected bugs**, not correctness; its
zero status confirms the red-witness specification. Legacy physical control
checks ordinary physical transmission.

First fixed attempts fail **before compilation** because the proposed runner
uses unsupported `--makeflags`. Their receipts are retained. New root runner
uses locally documented `-MAKEFLAGS`; RTL/TB and manifests are unchanged.
No failed result or expectation was retroactively relabelled.

For future reproduction use Verilator5.046, top `ps2_loss_probe`, the selected
controller, unchanged `simple_fifo.v`, this probe and C++ TB, `--assert`,
`+define+VEN_KBC_FAST`, and explicit C++ macros `PS2_TEST_AUTOACK=0|1` and
`PS2_TEST_LEGACY=0|1`. Add `VEN_KBD_AUTOACK` exactly when AUTOACK=1, and
`PS2_LEGACY_CONTROL` exactly when LEGACY=1. Never use a reused full-PC model
to claim changed-controller execution. Use a new bounded output, -j2 and
structural lint errors as in the checked-in PS2 UI flow.

## Still open before integration

- Mid-frame self-test test releases device pins immediately after AA. It does
  not prove resynchronization if a device continues the interrupted frame.
  Review the receive FSM's immediate IDLE reset and debounce history; test a
  compliant device's inhibit/abort/retry across each frame phase before applying.
- One-entry RX retention assumes the device honors host clock inhibition.
  The TB refuses an overrun, but its send helpers wait for readiness; continuous
  sender/inhibition-boundary coverage is still needed.
- Actual iobus delayed-read integration is not instantiated here; only the
  static write-strobe contract and isolated I/O behavior are checked.
- One-entry controller-reply storage and mouse full-FIFO RX retention are not
  general pipelined-command guarantees or repairs in this proposal.
- Path pin checks are before/after observations, not atomic compiler-loaded
  ancestry. Native admission logs do not prove a GUI action succeeded.

Production integration needs a new full-PC identity and fresh visible Win95
interaction plus full standard-suite/differential verification. Do not apply
the proposal while the frozen current runs are live.

Verified gameplay baseline: **0.43038841 IPC**, older4092c92a, cycles
**2,199,999,637–2,299,999,637**. It predates current5c2491; the current candidate
and this isolated controller have no verified gameplay measurement.
