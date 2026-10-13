# x87 real/V86 environment-save layout repair

October 13, 2026. Private UV-fast candidate; **not promoted or programmed**.
The installed FPGA Doom startup failure and the canonical reference failures
are not waived by these directed results.

## Repair and tests

The preceding [pointer-restore repair](../fp_env_restore/README.md) exposed
incorrect 32-bit real/V86 FNSTENV/FNSAVE images. They used the protected-mode
offset/selector format. `prepare.py` changes exactly four packed pointer words
in the actual shared-FP top, following Intel Pentium Volume 3, figure 6-7:

- Bytes 12/20 contain the low 16 bits of FIP/FDP.
- Bits 27:12 of the words at bytes 16/24 contain the respective high 16 bits.
- Protected-mode output, 16-bit output, stack payload, command timing and
  state commit remain unchanged. No register, memory transaction, wait state,
  feature switch or application-specific behavior is added.

The input decoder and output checks are independent: mixed-size conversions
must lose or retain the correct pointer bits, rather than merely reproduce
the input image. The existing `seg_real` connection supplies the real format
for V86 as well. No ordinary FP-pointer capture or FOP repair is included.

`tb_restore.sv` instantiates the actual `ven_fp_top` under the frozen 152-define
profile. It checks 1,024 varied restore cases and 4,096 saves: all four layouts,
both restore operations, both save operations, both output sizes, 128 samples.
It checks internal restored pointers/state, serialized pointer words, extent,
physical-to-logical stack serialization and stable registered output after
live input changes. The unchanged parent fails `ENV-STORE32 mode=2 full=0
sample=0`; the repaired version passes. Both builds close in 10.03 seconds.
FOP remains the existing zero placeholder, not independently implemented here.

`restore.S` adds 192 cold BIOS cases: protected/real/V86 × two input sizes ×
two output sizes × FLDENV/FRSTOR × FNSTENV/FNSAVE × byte offsets 0/1/63/4090.
It constructs known inputs directly and checks saved pointers in guest code.
The old core passes 128 and fails all 64 real/V86 32-bit-output cases; the
new core passes **192/192 RTL self-checks**, with zero unexpected faults.
Both execute identical guest images. The new run closes in 22.12 seconds,
26,624 architectural records; the control takes 22.32 seconds.

Pinned QEMU fails all 192 native pointer checks, retaining the previously
diagnosed restore-pointer omission. **Zero of these cases passes the complete
QEMU differential gate**; its nonzero result is preserved. No comparator mask,
golden, reference binary or cycle band is changed. These are not page-fault
tests: an offset crossing 4096 with paging disabled does not qualify paging.

Follow-up: a [private QEMU environment-helper repair](../../qemu-trace/fp_env/README.md)
now passes all 192 unchanged images against these complete RTL traces. Its
matched unmodified control reproduces all old failures, and a deliberately
wrong V86 format is detected in 16 cases. The traces check saved pointers through
guest integer readback (`x87=false`), not direct x87-register tracing. This does
not replace the canonical reference, waive the original failed run, or qualify
the full standard suite or FPGA.

Unchanged regressions on the new core:

| Corpus | Result |
| --- | --- |
| Obsolete x87 basic | 32/32 complete QEMU differential passes; 1,912 records, 2.75 s |
| Original full-state save/restore fixture | 24/24 RTL self-checks; 0/24 differential passes; 2,938 records, 2.54 s |
| Canonical `make verify` | 7 functional PASS / 101 FAIL; native make exit 2, 400.52 s; all 20 complete cycle traces identical to the parent |
| Complete-record parent/candidate replay | 108/108, all 80,800 records identical, 78.48 s; not a reference-gate waiver |

The canonical gate remains red, including the independent cycle-band
requirements. These results cannot turn the mode driver's reference failures
into passes.

The independent read-only closure audit passes: **25,998 input/artifact pins**
rehashed, all 192 identical parent/candidate BIOS images checked, all 80,800
replay records re-compared and 972 replay artifacts hashed. All eight native
owners are terminal with MainPID 0. For guarded builds the receipt records
the inner scope invocation, which differs from the outer service invocation;
the audit joins both against the journal and the service's monotonic lifetime.
Peak memory in those actual scopes was 2,650,103,808 bytes (leaf) and
3,301,052,416 bytes (core), with zero recorded swap peak.

Key closure hashes:

- `store-leaf-r1/closed.json`: `001a674dc169aef3e55ab25dd2e9140231f13cd7df0ca2df89a2605d42c7eec1`
- `store-core-r1/build-closed.json`: `d2557bf3af6dd3a74553c8715f8b79f4a74a5669e32a206370c401f93a70cf0e`
- `store-modes-r1/closed.json`: `a896f3288b499d1c8ca75d483be54c949f2a27e0b50c016fb958cdc40134f772`
- `store-core-r1/verify-closed.json`: `67ead94a435cb6680958a351af416aba1810e515738445ec5105db1cb87674c5`
- `store-replay-r2/closed.json`: `99804773aa1e9c41e8c2ef03d5bb54ae1a25ee02c62bf60576dfad3015338679`

## Identity and reproduction

Evidence root: `/home/yukidama/external/tmp/ventium-fp-env.jCGwerGG`.
Parent `core-r1`, model `33173110a2463f6512326c56c47fb532357a2baf5596751df0a48a94ba62d0f3`.
New `store-core-r1`, model
`369a23b48abaebd54991533e8933094c9791d6b6d9a6a13edb1f128029c6b150`.
Exactly **one of 195 source files** changes; all **152 defines** remain.
Private host/header build: 20.26 s. UV/system/relocated fast paths and L1 AXI
remain enabled; these startup tests are not evidence of paired gameplay.

`run.py` derives the immutable previous native drivers through checked exact
replacements. It changes parent identity, fixture paths, case enumeration and
the expected leaf witness only. All native exit, source, resource and complete
trace comparison requirements remain. Its wrapper/derived source and commands
are retained outside the repository in each run's `.driver.*` files.

- `run.py leaf --parent CORE --out NEW_ROOT`: guarded 32-job build scope,
  10 GiB memory / 2 GiB swap, serial Verilator generation, external scratch.
- `run.py core --parent CORE --leaf CLOSED_LEAF --out NEW_ROOT`: requires
  the exact successful leaf and one-file transform, then builds a private model.
- `run.py modes --core CORE --out NEW_ROOT`: four native workers on CPUs8–15,
  systemd invocation, external `TMPDIR`; every native failure remains a failure.
- Run the unchanged `../obsolete_fp/run_repaired.py` basic/state phases.
- Run `../../issue_uv/run_fp_nomem_verify.py` and wait for native closure
  **before** `run.py replay --parent CORE --candidate NEW_CORE --out NEW_ROOT`.
- `audit.py --root EVIDENCE_ROOT`: read-only owner, hash, source and case audit.

One replay was mistakenly launched before canonical verification closed. Its
guard refused the missing `verify-closed.json`; **no replay RTL ran**. The
failed `store-replay-r1` wrapper/invocation is retained; separately named R2
ran successfully after the dependency closed. No stale receipt was substituted.

## Disk recovery and remaining acceptance

Only closed, reproducible compilation products were removed after lossless
archiving and `tar --diff` byte comparisons. All archives are under the evidence
root above: 17 files, approximately **0.708 GiB net freed**. No model binary,
RTL, media, dependency file or run evidence was
removed. The canonical model hash remains
`38049e59bd36f06756ac4d4c325f916331858ef5587561963ca14caaabd3713f`.

| Archive | Contents / extraction base | SHA-256 |
| --- | --- | --- |
| `closed-pch-oct13-store.tar.gz` | Four closed PCH caches; external volume root | `e1310e78c9743db9d5a3272622d193d4ec7a051db7dbd299f1398d7d9ddf4e98` |
| `store-leaf-r1-pch.tar.gz` | Four closed leaf PCH caches; this evidence root | `0eaacf30825a9c303062255231ed872785dc94e0805acfd9eef2809ef00a3b61` |
| `closed-canonical-cpp-oct13-store.tar.gz` | Nine generated C++ products; external `ventium_run/verif_tb/obj_dir` | `e898c18b96d769d50e8799ee1d911b044eb53c80e85dab6d1a2e12366d512749` |

Restore with `tar -xzf ARCHIVE -C EXTRACTION_BASE` before an incremental build
that needs archived products; a fresh Verilator generation recreates them.
The guarded compiler admission remains above 5 GiB free and the runtime floor
above 4 GiB. No active Vivado or FPGA programming accompanied this repair.

Still open: wrong-V86-mode native mutant, pending-exception and fault/retry
boundaries, ordinary real-mode FIP capture, FOP, complete reference-gate repair,
40 MHz synthesis/routed sign-off, full standard suite and physical FPGA
Win95/Quake validation. This candidate has no timing or gameplay measurement.
The older endpoint/SMSW unplaced estimate is **35.057 MHz**, below 40 MHz;
it does not measure this later candidate. No performance gain is claimed.

Candidate gameplay IPC is **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**; predates this candidate, not FPGA/Doom IPC.
