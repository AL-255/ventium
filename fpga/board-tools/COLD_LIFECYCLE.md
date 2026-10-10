# Cold diagnostic lifecycle — October 10

The prepared controller had a failure-path ownership bug: its sampling loop
checked systemd InvocationID, but cleanup stopped a service by name and then
reset/switched the board clock. A replacement invocation could therefore be
killed and have its hardware state reset. MMIO/guest-map and startup receipt
failures were also outside the cleanup block; recorder timeout could leave a
live recorder during final HALT/RAM capture.

`ven_cold_owners.py` admits an exact service Id, InvocationID and native MainPID.
Every stop/signal is checked before and after. Closure requires PID zero and
no remaining tasks. A cleared InvocationID is admitted only after this helper's
own successful synchronous stop. Failure on one owner still attempts cleanup
of the other known owner; an unknown or replaced owner is never adopted.

`ven_cold_watch.py` puts mapping/start publication inside cleanup coverage,
handles SIGTERM/SIGINT as stop requests, checks recorder native completion and
reaps both workers before final debug/RAM operations. Identity failure refuses
reset and clock writes, retaining an explicit failure receipt. It does not
manufacture a zero IPC on an invalid observation or claim timedemo acceptance.

`ven_cold_start.py` checks identities through watcher handoff and closes an
admitted watcher first on startup failure. The launcher itself never switches
the clock or resets hardware from an incompletely owned failure path. A failed
handoff leaves an explicit **requires inspection** receipt, not a success.

## Verification and limits

```sh
python3 -B -m unittest discover -s fpga/board-tools -p 'test_ven_cold_*py' -v
```

All **36 tests pass**: 12 ownership, 10 tests executing the real watcher's
cleanup/selected try paths, 7 executing the real launcher's failure cleanup,
and 7 existing held-clock tests. Six original tests execute the prepared
watcher's sampling block and also pass. These are host tests with fake services
and MMIO, not full physical systemd/MMIO integration tests.

A bounded actual host user-service check confirmed synchronous stop behavior:
InvocationID clears, MainPID becomes zero and TasksCurrent becomes `[not set]`;
repeated closure checks pass. Receipt:
`external/tmp/ventium-cold-owner-native.jTEHr571/result.json`. No board MMIO
was accessed by that check.

The new immutable 14-file runtime package is
`external/tmp/ventium-posted16-cold-package-r3.a8URqYr9/`. Its preparation
verifies every old r2 input hash, preserves unchanged bytes, substitutes
`watch_cold.py`/`start_once.py` from these repo files and adds the owner helper.
The historical r2 package is unchanged. `prepared.json` and both test logs
record pins/results; no upload, guest launch or bitstream admission is implied.
The retained historical `stage_helpers.py` must not be rerun over this package.

These identity checks are **not atomic systemd transactions**. Exclusive board
and unique service-name ownership remain required. A launcher failure after a
child starts but before its identity is published can leave an unobserved,
bounded child requiring inspection; do not blindly kill its unit by name.
SIGKILL, power loss and kernel faults cannot run Python cleanup. Recheck actual
native services and held reset before any later hardware write/retry.

Latest verified gameplay remains **0.50058134 total U+V retirement-event IPC**,
model `86731249`, clocks 3.6B–3.7B; the complete 1.2B–3.7B average is
**0.4788804468**. This predates `958f7ec4` and the C1/FST candidates, which have
no gameplay result. Lifecycle tests neither improve nor qualify CPU performance.
