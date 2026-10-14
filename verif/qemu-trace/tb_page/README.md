# Cross-page translated-block invalidation in pinned QEMU

## Status

The original prefix-boundary gate is still **failed**, not waived. A bounded
native investigation identifies two distinct reference defects: stale
cross-page translated code after a guest store, and missing finite-CS-limit
enforcement. The exact upstream backport for the first now passes the original
SMC native witnesses and complete RTL trace comparisons described below. The canonical QEMU,
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

Ten host tests pass:

```sh
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  python3 -B -m unittest discover -s verif/qemu-trace/tb_page -p 'test_*.py' -v
```

These check the exact two-line delta, drift guards, page-index counterexamples,
compiler/header flags, unique object substitution and explicit outcome policy.
The boundary adapter's tests verify that the original execution, comparison
and result bodies remain byte-for-byte unchanged apart from explicitly binding
the original option-ROM directory for relocated QEMU binaries. Fixtures still
import from their original directory.
They are **not native QEMU qualification**.

1. After the current Vivado family closes, run `build.py --out FRESH_ROOT`
   through `tools/build_scope.sh`, in a bounded user unit with actual
   `taskset -c 8-15` and external TMPDIR. It refuses a live Vivado process or
   absent build lock, then lowers its real scope to 2 GiB RAM / no swap and
   checks those effective limits. It compiles just the real `tb-maint.c` translation unit
   twice and privately relinks control/candidate against the original Ninja
   objects. Headers, thin-archive members, canonical binary and all source
   inputs are hashed before/after; no canonical build output is overwritten.
2. Run `run_native.py --build BUILD_ROOT --original ORIGINAL_BOUNDARY_ROOT
   --out FRESH_NATIVE_ROOT` in a bounded 512 MiB/no-swap user unit with
   `taskset -c 12-15`. This executes all 30 original BIOSes, both private QEMUs,
   retaining their original machine options and success/failure byte contract;
   `-L` explicitly names the original, hash-pinned option-ROM directory. Each
   child is limited to 20 seconds and observed on its assigned CPU.
3. Require all four cross-page SMC failures to become genuine guest passes,
   all other formerly passing cases to remain passes, and the eight separate
   finite-CS failures to remain explicitly recorded. The driver always sets
   `original_boundary_gate_passed=false`; it does not turn those failures
   into a green aggregate processor gate.
4. Run `run_boundary.py --qemu-build BUILD_ROOT --native-result NATIVE_ROOT`
   with the original driver's `--control`, `--candidate` and fresh `--out`
   arguments. This checks native-backport prerequisites and binds only the
   QEMU identity; retain all 30 cases by omitting kind/offset filters. Its
   original fixture, expected exits, full architectural comparison, UV cycle
   controls, latencies 0/7 and aggregate failure semantics are unchanged.
   Observe actual child affinity in the bounded owner. The eight finite-CS
   cases are expected to keep this complete gate **red**. Separately resolve
   that oracle coverage and the other canonical-gate failures before promotion.

Steps 1–4 have now run; the complete boundary gate remains red on the separate
finite-CS cases. No native build ran concurrently with synthesis. This repair
is not a new golden-cache policy or a substitute for original workload testing.

## Native backport and full-trace closure

The shared lock released only after Vivado exited. The private relink then
closed in **6.159 s**, with **564,637,696 bytes** peak scope RAM, zero swap and
zero OOM. It retains exactly the two upstream changes:

- Control QEMU: `1ba6c94cf995f23123920649114d47a4fe0bf5fae1bd24c8b921f5a478d93efc`.
- Candidate QEMU: `2ffb2a1b70cba672df34c765a504dc9725bf5810831c48febc35f066a02be8f8`.
- Build supervisor invocation: `1a0f2e704f1e4aa5a12f1cdffecc7a12`.
  Its **distinct inner scope** invocation is
  `4c00612a4a89440bbae9d4f308e9d1b8`; both are independently checked.

The first native run failed before guest execution: a relocated QEMU binary
could not find `kvmvapic.bin` and `vgabios-stdvga.bin`. That failure is retained
as `qemu-tb-page-native-r1`. R2 supplies the original `pc-bios` directory to
both QEMUs, pins all its files, and changes no ROM, BIOS test or expected exit.

R2 executes **30 original BIOSes × two QEMUs = 60 native runs** in **1.673 s**.
The control reproduces all **12** original failures. The candidate repairs
exactly the four cross-page SMC failures; its **eight finite-CS failures
remain**. Both retain all 18 previously passing cases. Every native child is
waited/reaped and observed on its assigned CPU12–15. Owner
`ventium-qemu-tb-page-native-oct14-r2.service`, invocation
`ae20c799c3cd4cb1912d34a4ac2b7d1d`, is terminal with exit 0; this qualifies
the narrow backport outcome, not the full processor gate.

Two complete boundary reruns each finish **22 cases / 176 native RTL
executions / 88 full QEMU comparisons** at latencies 0/7. Each retains **5,540
candidate functional records and 428 V retirements**. Complete parent and
candidate architectural records **and cycle records are identical**. The
original BIOS bytes match the original failed run; no trace trimming or extra
field mask is used. Both full gates correctly return **exit 1** on the eight
finite-CS reference failures, before RTL execution of those eight cases.

R1/R2 take **6.395 / 6.311 s**, owner invocations
`bd002c149abd4ecab3429fed634f7f51` and
`9ba194e46c404d0ab0b6edb836a9232b`. Per-child affinity was **not** captured for
these full gate runs: the R2 external observer hit a `/proc/<pid>/exe`
permission error and terminated; the gate itself continued to its ordinary
failed closure. Do not relabel this as complete affinity observation.

`audit_qemu_tb_page.py` independently verifies both closed gate owners, the
exact source delta, 60 native QEMU outcomes, unchanged input/artifact hashes,
all full comparisons, fault counts and parent/candidate state/clock equality.
`qemu-tb-page-audit.json` SHA-256:
`fadcaf48d5d4b1a326be2da7b3de17bc25ccd7836a983993394d73ac02785628`.
The canonical oracle is not promoted, and finite-CS coverage, canonical
gates, full standard suite and physical acceptance remain open.
