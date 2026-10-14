# Cross-page translated-block invalidation in pinned QEMU

## Status

The original prefix-boundary gate is still **failed**, not waived. A bounded
native investigation identifies two distinct reference defects: stale
cross-page translated code after a guest store, and missing finite-CS-limit
enforcement. An exact upstream backport for the first is prepared; **it has
not yet been compiled or qualified by native execution**. The canonical QEMU,
guest BIOSes, RTL and comparison rules are unchanged.

The current prefix-payload candidate remains gameplay-unmeasured. Latest
verified gameplay baseline is **0.50430455 total U+V IPC**, older simulation
model `c7b95b78`, cycles **1,800,065,237–1,900,065,237**. This investigation
does not establish processor performance, standard-suite or FPGA acceptance.

## Native evidence

`verif/fe_pipe/run_prefix_boundary_forensics.py` uses six **unchanged** BIOSes
from the failed `prefix-payload-boundary-r1` gate: the two flat/relocated
finite-CS cases at offset 4093 and all four self-modifying-code (SMC) failures
at offsets 4094/4095. Each runs normally, with passive TCG logging, and with
one instruction per TCG block plus logging. There is no GDB stepping, register
write, replacement guest instruction or RTL modification.

All **18 native executions** return guest failure (`isa-debug-exit` status
135, versus the original success status 133), including the one-instruction
controls. The R2 diagnostic closes in **0.275 s**, with actual CPU12–15
affinity observed and all children waited/reaped. R1 failed before executing
QEMU because an image identity check compared a symlink spelling with its
resolved path; that failed attempt remains retained separately.

An independent read-only audit checks **40 input pins and 67 artifact hashes**,
the closed owner, all 18 exits, and the native logs themselves:

- In all four SMC cases, the same host translated block is reused after the
  real guest store changes the ADD immediate from `0x1234` to `0x4321`.
  Both executions leave `EAX=0x12349235`; the second must instead produce
  `0x1234C322` from the unchanged input `0x12348001`.
- Both CS cases execute the four-byte ADD at `EIP=0x2FFFD`, despite CS limit
  `0x2FFFF`, and reach `EIP=0x30001` with the arithmetic result committed.
  This is separate from the SMC defect and is not repaired by the backport.

Evidence root:
`/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X`.
Owner `ventium-prefix-boundary-forensic-oct14-r2.service`, invocation
`b25adb6f58a042868afba199e0296b08`, has MainPID 0 / exit 0: that means the
diagnostic completed, **not** that the guest tests passed.
`prefix-boundary-forensic-r2/closed.json` SHA-256:
`ceddea6dec6d2ee48d691af77085fc4af3b6a66fa7e98fd556fcadefc9e05cfd`.
The independent check is `audit_prefix_boundary_forensic.py`; its result is
`prefix-boundary-forensic-r2/audit.json`.

## Exact upstream correction

Pinned `accel/tcg/tb-maint.c` computes `pindex1` from **paddr0**, not paddr1,
in both system-mode `tb_record` and `tb_remove`. Therefore their distinct-page
condition can never hold, and the translated block is not registered against
its second page for store invalidation. The native evidence above is consistent
with this cause. QEMU upstream fixes precisely these two lines in
[commit 3b279f73](https://github.com/qemu/qemu/commit/3b279f73fa37bec8d3ba04a15f5153d6491cffaf).

`prepare.py` requires the complete pinned parent hash
`74759be530fcc681f732c52f2492a86d3b6eb2d432169779be5bb31e58b8dae7`
and changes only those two second-page index expressions. It rejects source
drift, partial application and reapplication. No x86 instruction behavior,
exception policy, debugger or observer change is included.

## Qualification procedure

Eight host tests pass:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s verif/qemu-trace/tb_page -p 'test_*.py' -v
```

These check the exact two-line delta, drift guards, page-index counterexamples,
compiler/header flags, unique object substitution and explicit outcome policy.
They are **not native QEMU qualification**.

1. After the current Vivado family closes, run `build.py --out FRESH_ROOT`
   through `tools/build_scope.sh`, in a bounded user unit with actual
   `taskset -c 8-15` and external TMPDIR. It refuses a live Vivado process or
   absent build lock. It compiles just the real `tb-maint.c` translation unit
   twice and privately relinks control/candidate against the original Ninja
   objects. Headers, thin-archive members, canonical binary and all source
   inputs are hashed before/after; no canonical build output is overwritten.
2. Run `run_native.py --build BUILD_ROOT --original ORIGINAL_BOUNDARY_ROOT
   --out FRESH_NATIVE_ROOT` in a bounded 512 MiB/no-swap user unit with
   `taskset -c 12-15`. This executes all 30 original BIOSes, both private QEMUs,
   using their original commands and success/failure byte contract. Each
   child is limited to 20 seconds and observed on its assigned CPU.
3. Require all four cross-page SMC failures to become genuine guest passes,
   all other formerly passing cases to remain passes, and the eight separate
   finite-CS failures to remain explicitly recorded. The driver always sets
   `original_boundary_gate_passed=false`; it does not turn those failures
   into a green aggregate processor gate.
4. Rerun complete architectural trace comparisons against both unchanged
   UV-fast RTL models, including delayed memory. Separately resolve finite-CS
   oracle coverage and the other canonical-gate failures before promotion.

Steps 1–4 remain pending. No new native build was launched concurrently with
the running synthesis. This repair is not a new golden-cache policy or a
substitute for original failing workload verification.
