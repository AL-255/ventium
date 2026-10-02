# Fetch guard predicate leaf gate

This standalone test compiles the exact production right-hand sides extracted
from `rtl/core/core.sv`. It is not a second implementation of the fetch guards.
Extraction fails on absent or ambiguous assignments, and strict structural lint
fails on unmodelled dependencies. Source, extracted expressions, binary and logs
are hash-bound before/after the bounded run.

Coverage:

- A demand-fetch completion cursor beyond an inclusive CS limit is not an access.
- Each essential one-to-four-byte demand beat checks its first and last byte.
- A legal instruction ending at CS.limit is accepted; the next byte is rejected.
- An overlength decoder `d_len == 0` is not subtracted into a phantom extent fault.
- Overlength page probes yield to accepted debugger, SMI, NMI and INTR events.
- Latched boundary and live in-page opcode-header faults suppress provisional
  decoded extents and overlength EA probes.
- The probe names the first atomically overrun field's endpoint page, not later
  unused fields.
- A held, already-admitted pipeline memory packet is exempt from fetch handoff.

Run from the repo root after checking disk space and creating an owned, fresh
output directory:

```sh
out="$(mktemp -d /tmp/ventium-fetchguard.XXXXXX)"
bash verif/fetchguard/run-gate.sh --out "$out"
```

The gate requests 32 compiler jobs inside the existing serialized
`ipc_parallel32` build scope (16 GiB memory, 128 tasks), with a 540-second deadline.
It builds only this small combinational leaf, not a core or PC model. Logs and
receipts remain in the supplied directory; it performs no automatic deletion.

This does not prove delivery priority across the complete FSM, sequential held
packet completion, TLB authorization, or guest correctness. The differential
gates and the complete standard test suite remain required. A source-linked
predicate pass cannot be promoted into a Windows desktop, Quake timedemo, or
CoreMark correctness pass.
