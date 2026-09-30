# V86 scalar I/O permission bitmap

This focused fixture targets the rule that **V86 port I/O checks the TSS bitmap
regardless of IOPL**. P5 July 1995 Vol.3 §15.3.2 (printed page 15-7), IN/OUT
operation pseudocode, and pinned QEMU 8.2.2 `gen_check_io()` independently
specify VM=1 OR CPL>IOPL.

Cases 1–12 deny scalar IN/OUT byte/word/dword, both DX and immediate forms, at
V86/IOPL3. Word accesses start at 87h; dwords at 85h: the leading bits are clear,
only trailing port 88h is denied. Cases 13–15 are clear-map V86/IOPL3 OUT,
protected CPL3/IOPL3 OUT bypassing a denied map, and V86/IOPL0 denied OUT.
Allowed inputs are deliberately absent, so no golden device-data skew is used.

The assembly self-checks target #GP(0), fault EIP, saved VM/IOPL/flags, all
non-SP GPR sentinels, SS:SP and the V86 segment frame. It advances only the
expected faulting instruction, restores the frame, and checks the preserved
state again on a generic final HLT #GP. Successful exit is 133; failure is 135.
The host checker additionally verifies actual RTL I/O counters: denied cases
consume no device transaction except the monitor's final debug-exit OUT.
Canonical producers and the functional differential comparator remain the
architectural authority; traces are never hand-formatted.

Use a frozen approved direct TB, never the canonical model output:

```sh
TB_BIN=/tmp/obj_dir_cm_p54_iret_sep30/tb_ventium EXPECT_RED=1 \
  bash verif/sys/tests/pv86iop3/run-pv86iop3-gate.sh
```

For a fixed candidate omit EXPECT_RED, for example:

```sh
TB_BIN="$PWD/verif/tb/obj_dir_v86_iop3_sep30.nhltiM/tb_ventium" \
  bash verif/sys/tests/pv86iop3/run-pv86iop3-gate.sh
```

The runner uses a verified serialized
scope (2 GiB/no swap/64 tasks), up to four independent tiny-case workers
(`JOBS=1..4`), a 540-second whole guarded deadline (lock waiting excluded)
and a 20-second per-DUT deadline. Scratch is a real
root-filesystem `obj_dir_artifacts` directory, not the external `tmp` symlink.
Each case has a private artifact stem and its own QEMU port, base+case-1.
Before acquiring the guard or creating artifacts, duplicate `CASES` IDs are
rejected; `EXPECT_RED=1` requires at least one denied case from 1–12.
These later safeguards passed 23 host-only input checks; retained RED/GREEN
receipts keep the earlier runner hash. No DUT rerun was needed for this
prelaunch-only validation change.
Retained expected RED must identify an illegal V86/IOPL3 I/O retirement,
missing target #GP and the matching actual device transaction; compile errors,
timeouts, unrelated exits and control failures are not accepted as known RED.

The 2026-09-30 frozen old-TB negative qualification completed in
`obj_dir_artifacts/pv86iop3.RnGPxU`. All 15 pinned-QEMU self-checks passed.
All 12 V86/IOPL3 denied forms are clean expected RED: RTL exits 135, retires the
denied I/O in V86, consumes the matching forbidden device transaction, and
misses the target #GP. The first functional divergence is exactly at target
EIP 2Ah: EAX for inputs, saved ESP for outputs. Comparator exit is 1, never a
malformed-trace exit 2. The three controls pass exact functional differential
comparison: 255/198/302 records for cases 13/14/15. All sources and the frozen
TB remain hash-stable; the structured receipt records limits and identities.
This is negative qualification, not a fixed-candidate correctness PASS.

Frozen TB SHA-256:
`12851ddf6d2110b6d68acd2c317eaf3fa96e3c83c528f51cda5c3f64f1366a80`.
The minimal scalar fix adds `v86 ||` to `ioperm_needed`, preserving its
system/real-mode guards and the existing bitmap FSM. The matched fixed direct
TB completed all 15 cases GREEN in `obj_dir_artifacts/pv86iop3.U7a53q`:
all QEMU/RTL self-checks and exact functional comparisons pass, totaling 4,389
records. All 15 ELF and image hashes are identical to the old RED inputs.
Cases 1–12 and 15 perform no device I/O except the monitor's debug-exit OUT;
allowed controls 13/14 perform exactly one additional OUT. All port/size
desynchronization counts are zero. The terminal runner exit is 0; each RTL
self-check exits 133. Its structured `receipt.json` preserves per-case trace,
image, limit and binary identities.

Fixed TB SHA-256:
`8c3b6954ff139b8e8b535e57e6401798ccbd09170d2444f7cf2184c618292e35`.
The build audit in `verif/tb/obj_dir_v86_iop3_sep30.nhltiM/` proves exact
Verilator-argument/define agreement with the old direct model, apart from its
output directory. The matched full-PC model likewise retains all 107 defines.
Reversing only the predicate and three comment blocks in memory reproduces
both prior full-file source hashes: there is exactly one functional change,
not an incidental rewrite of existing dirty code. The new dependency manifest
contains 340 path entries representing 227 distinct files, including the
previously omitted C++ header dependencies; all captured build inputs remain
hash-stable. Historical hashes absent from the old manifest are not invented.

OUTS has a separate dispatch bypass and is not fixed or qualified by this
scalar fixture.

This does not qualify OUTS/INS/REP strings,
page-fault priority, absent/16-bit TSS behavior, VME, interrupt delivery or the
Win95 wait cause. The saved 450M Win95 TSS bitmap permits the PIC ports, so
this ISA defect is not evidence that denied PIC I/O caused that wait.
It does not replace the standard suite.

Latest verified gameplay baseline: 0.42089513 on build 2e63, cycles 3.0B–3.1B,
predating IDE-fixed build 3120 and the V86 I/O candidate (full-PC cdcb6faa).
Those candidates have no gameplay measurement yet.
