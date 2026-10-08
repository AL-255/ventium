# Raw-permission translation snapshot (experimental)

This extends the eight-entry experiment in `../prototype/`. It is **not enabled
in production** and is not a Quake fix, standard-suite pass, or CPU-frequency
qualification. U/V issue and the system fast load/store paths remain enabled.

The child stores the parent's raw `{US,RW,P}` alongside its exact page/PFN,
hit and dirty result. It never stores the access's success/failure, CPL, write
intent or CR0.WP. Current access policy is evaluated on every transaction.
Every parent fill/replacement, context flush and reset invalidates all children,
before capture. A child miss holds the existing translation pipeline before
any request or commit. This avoids the residual large-parent permission lookup
on the same-cycle query-to-permission-fault path without adding warm-hit bubbles.

Apply `core-permission.patch` **after** the original `core-integration.patch`
in a frozen private tree; replace that tree's `ven_fe_dtlb.sv` with this version.
Add only `VEN_FE_DTLB_PERM` to the already-tested eight-entry profile. It requires
`VEN_FE_PIPE` and `VEN_FE_DTLB_MULTI`. `VEN_PIPE_MEM_CHAIN` is deliberately
rejected: its lookahead capture has another owner and no corresponding raw
permission snapshot. That switch is absent from the tested 107-definition
hardware profile; no enabled fast path was removed to obtain a pass.

Run the leaf checks:

```sh
bash verif/fe_pipe/permission/run-leaf.sh
```

Run the two full-core QEMU regressions on an existing assertion-enabled model:

```sh
TMPDIR=/home/yukidama/external/tmp python3 -B verif/fe_pipe/permission/run-core.py \
  --tb /absolute/path/to/private/obj/tb_ventium
```

This runner does not compile the core. It checks the native build's fast-mode
definitions, runs both `--cycle-func` and `--cycle` at AXI latencies 0 and 7,
requires real V retirements, and compares complete architectural traces with
the pinned QEMU. `warm-ro.patch` warms read-only data through eight actual
same-clock load/ADD pairs before the protected write. `valid-handler-fs.patch`
reloads the handler's FS after outer IRET invalidates it; it does not disable
segment enforcement or change the faulting stack instructions. The original
test was written for a non-enforcing profile. These fixture changes live only
in the generated scratch copies.

The scoreboard checks permission payloads, aliases, reset, invalidation/capture
collisions and replacement. A second test connects the real P54-large parent,
checks positive/negative ownership through permission updates, same-set eviction
and 4 MiB overlays, and sweeps all current U/S, W/R and WP combinations.
The negative control suppresses fill invalidation and **must fail** on a stale
owner. These checks cannot replace full-core paging, fault precision and pairing
tests. The full-core integration also asserts parent/child equality and blocks
all requests/commits while an uncaptured translation is pending.

The bounded isolated physical comparison is preserved in `physical/`. To
reproduce, copy those three files plus this directory's `ven_fe_dtlb.sv` and
`rtl/mem/tlb_assoc.sv` into a fresh external scratch directory; run its
`run_synth.py` with `TMPDIR` set there. It compares direct, address-only eight
entries, and address+permission eight entries with identical live access-policy
inputs and output boundaries. Its exclusive Vivado scope is limited to 8 GiB,
one worker and 600 seconds. It cannot measure CPU Fmax or qualify a bitstream.

Measured results and remaining gates are in
[the permission-cut audit](../../../docs/UV_FAST_PERMISSION_CUT_2026-10-08.md).
