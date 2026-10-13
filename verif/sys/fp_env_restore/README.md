# x87 environment-pointer restore repair (isolated, unpromoted)

October 13, 2026. FLDENV/FRSTOR pointer restoration is implemented in a private
UV-fast candidate. **Canonical verification remains red; no FPGA build or
programming occurred. This is not standard-suite acceptance.**

The parent defect and failed original fixture are documented in
[FP_ENV_RESTORE_GAP.md](../obsolete_fp/FP_ENV_RESTORE_GAP.md). The repair uses
the existing pointer commit ports on the same acceptance edge as CW/SW/TOP/tags
and, for FRSTOR, stack registers. It adds no memory transaction, wait state,
port, feature flag or guest-specific rule. This is a structural observation,
not a measured area/timing or gameplay improvement.

## Exact scope

`prepare.py` accepts only these pinned parent inputs:

- `fp_shared/ven_fp_top.sv`: decode saved FIP/FDP and selectors using all four
  Intel layouts, and multiplex them onto the existing pointer ports when the
  fully collected environment is committed. Current-command pointers must
  not replace saved ones. Ordinary pointer updates retain their prior path.
- `rtl/core/core.sv`: pass `seg_real` (real mode **or V86**) instead of
  `real_mode` to the shared-FP environment-format input.

The source authority is Intel Pentium Processor Family Developer's Manual,
Volume 3, order 241430-004: section 6.2.1.6 and figures **6-6 through 6-9**,
printed pages **6-17/6-18**, PDF **156/157**; FLDENV and FRSTOR entries on PDF
**733–734/746–747**. These complete relevant pages were extracted and visually
reviewed with the PDF skill. In particular, the 32-bit real-mode pointer's high
16 bits occupy bits 27:12 of a separate word; it is not a protected-mode
selector. V86 uses the real-mode layouts.

The repair deliberately does **not** claim to fix all FP environment behavior.
Still open:

1. **32-bit real/V86 environment stores use the protected-mode layout in this candidate.** The
   new cold roundtrip tests reproduce this in 16 cases. Fix the existing
   `env_image32` pointer-word construction using figure 6-7, without changing
   the protected layout or stack payload. Then test mixed operand-size
   save/restore conversions so two mutually wrong codecs cannot pass by
   simply reproducing their own input bytes. The subsequent isolated
   [store-layout repair](../fp_env_store/README.md) now passes all 192 cold
   mixed-size self-checks, versus 128 on this parent; it remains unpromoted
   with reference, full-system and hardware acceptance open.
2. The separate legacy absence of an FOP register and normal real-mode FIP
   address capture are outside this change. Reserved bits/FOP are not part
   of the new pointer-only cold test's assertions; this is explicit scope,
   not a change to any canonical comparator mask.
3. Pending-exception summary recomputation against restored CW, full tag
   classification semantics and arbitrary cross-mode state conversions need
   independent qualification. Existing implementations are not automatically
   authoritative merely because they agree.
4. Page/segment late-fragment faults, retries, debug/interrupt boundaries,
   blocked acceptance behind older FP operations, pointer-specific mutants,
   and full-PC/standard-suite/hardware qualification remain required.

The existing operand collector and fault paths are unchanged. The leaf proves
no change with `cmd_valid=0` and no post-accept live-bus corruption; that is not
a proof of every core memory-fault or in-flight-command ordering case.

## Results

Evidence root: `/home/yukidama/external/tmp/ventium-fp-env.jCGwerGG`.
Parent core is `ventium-load-read-ack.GyWDDtiI/obsolete-fp-core-r1`, model
`2fc497047dc64848f28a920522a6fa4ec1e8ef0c686179394576d6237402acb2`.
New `core-r1` model:
`33173110a2463f6512326c56c47fb532357a2baf5596751df0a48a94ba62d0f3`.
Source closure: **195 files, exactly two changed, 152 unchanged defines**.
The model-specific private host/header build closed in **20.36 seconds**.
Normal U/V, system fast paths and the L1 AXI backend remain enabled. These
directed tests are not evidence of gameplay pairing or performance.

| Evidence | Result | Limits |
| --- | --- | --- |
| `leaf-r2` | **1,024 actual shared-FP top cases pass**; unchanged parent fails the first pointer check; both builds finish in 9.80 s | Four layouts × two restore operations × 128 varied pointer/state samples; checks all pointer outputs, control/status/TOP/empty tags, physical/logical stack values, nonidentity stack mapping, idle and post-accept buses. Not a whole-core or queue-admission test. |
| `state-r1` | **24/24 RTL self-checks**, formerly 0/24; **0/24 full differential passes**, 2,938 RTL records, 2.95 s | Unchanged original 108-byte FNSAVE/FRSTOR fixture, including integer-NOP, obsolete-op, pending-exception, FNOP and LOCK cases. Pinned QEMU still fails its native checks. |
| `basic-r1` | **32/32 RTL and complete QEMU differential passes**, 1,912 records, 3.23 s | Unchanged obsolete-x87 real-mode EM/TS/prefix/FNOP regression images. |
| `modes-r2` | **32/48 RTL self-checks**, **0/48 differential passes**, 6,576 RTL records, 6.49 s | Both restore instructions; PM0, real and V86; 16/32-bit operands; byte offsets 0/1/63/4090. All 16 PM cases and eight each real-16/V86-16 pass. Sixteen real-32/V86-32 stores remain wrong. No fault delivery in this corrected fixture. |
| `modes-parent-r2` | **0/48 RTL self-checks**, 6,192 RTL records, 6.55 s | Identical images on the unchanged parent; QEMU also fails all 48 native checks. |
| Canonical `make verify` | **7 PASS / 101 FAIL**, native make exit 2, 403.72 s | All 20 complete cycle traces identical to parent. Goldens, masks, bands and backends unchanged; gate remains red. |
| `replay-r1` | **108/108 same-input replays**, 80,800 identical complete architectural records, 77.93 s | Regression evidence, not a substitute for QEMU correctness. |

The native drivers use `--cycle-func --l1-axi`, AXI latency 7, and existing
complete system-trace generation/comparison. No per-retirement x87 trace
fields are requested; guest memory assertions check the saved state. A trace
match with two native failure exits is **not** counted as correctness. The
state and mode drivers correctly exit 1; reference discrepancies are retained.

Same-size V86 roundtrips alone cannot prove correct internal mode selection:
two matching wrong encoders can reproduce an image. The source guard and
direct leaf output checks supplement those cases; mixed-size conversions and
a wrong-mode native mutant remain required after the real-32 store repair.

## Reproduction and failed attempts

- `run_leaf.py --parent CORE --out NEW_ROOT` builds old/repaired actual FPU
  tops in the frozen filelist/profile; it requires the existing locked
  `ipc_parallel32` build scope, 32 C++ jobs, 10 GiB memory / 2 GiB swap, no
  Vivado and external scratch. Generation uses `--verilate-jobs 1`.
- `build_core.py --parent CORE --leaf CLOSED_LEAF --out NEW_ROOT` requires
  the leaf receipt and exact source transform before calling the unchanged
  private-host core builder. It does not inherit acceptance.
- The original `../obsolete_fp/run_repaired.py` runs both the `basic` and
  unchanged original `state` fixtures against the new model.
- `run_modes.py --core CORE --out NEW_ROOT` changes only fixture paths and
  case enumeration in that same driver. Native exits, fault checks, full
  comparator and final success requirements remain unchanged.
- `run_regression.py` checks exact source/define deltas before the existing
  complete-record parent/candidate comparator. `test_prepare.py` checks
  recipe scope and rejects source drift/reapplication.

`leaf-r1` failed in compilation with `cc1plus: posix_spawn: Resource temporarily
unavailable`: combined generation/build worker processes exhausted the fixed
task cap. No RTL simulation ran. The rerun serializes only generation, retains
32 C++ jobs and does not raise the process/memory caps. Its original driver is
retained as `leaf-r1/driver_source.py`, SHA-256
`a212958574de3e732b08660019ea7ac0c59f390b719099639a5e890abe7beca1`.

The first `modes-r1`/`modes-parent-r1` fixture omitted a usable V86 I/O bitmap,
so RTL faulted at its exit port after the checks. The corrected fixture
provides a bounded TSS bitmap permitting only port F4 with a deny-all sentinel;
no processor I/O permission was bypassed. This fixture does not qualify the
separate IOPL/I/O-bitmap policy. The original source is retained as
`restore-r1.S`, SHA-256
`86b45d7fe89419eea5383a60aabd30410d6007ad85cb181e29e42c004d250589`.
Those initial runs are not the corrected mode qualification above.

## Terminal owner receipts

All services below are terminal with MainPID 0. Closure hashes identify
`closed.json`, `build-closed.json` or `verify-closed.json` as appropriate.

| Service suffix (`ventium-fp-env-…`) | Invocation | Exit | Closure SHA-256 |
| --- | --- | --- | --- |
| `leaf-oct13-r2` | `ac43c21739c0444c854cbc1454f2d825` | 0 | `fb1bbfba39b49bfe66f2340850f0b21b2790cb3593fb39a1f6db3b7c47b7e4d6` |
| `core-oct13-r1` | `b2db90c1a7bb4e97ac4a4b5de59cf392` | 0 | `c8f282891aa9533c8cfd6adcdd5e8c811eaa5d9343e9caa18d7cf00e8a067bc4` |
| `basic-oct13-r1` | `36527c601e974dcbbff6a97b697c0e29` | 0 | `483bd9251ef882b6682b114ece24c127bb8642c2398ae2cc3a8a3f7371332b54` |
| `state-oct13-r1` | `450b606bd19a4748a52db065e27b0b80` | 1 | `3ef17c0465be9050256f59d4ce6840fa188c57838449283dc92d00c42a44b5de` |
| `modes-oct13-r2` | `503affb085d54f0cb6fb41058912b73f` | 1 | `49f7a91524e0b2d6211bcadf03b4cc7075aa9805b3d8136239678e29387b04bd` |
| `modes-parent-oct13-r2` | `610c0cef522448008f82ab377a43a70b` | 1 | `1c3c61a90fea721d63e42386ca2c75b8321fa2511094c8483a79dc1dc45ff190` |
| `verify-oct13-r1` | `1673d799d2394d07937ae3d89af96327` | 1 | `99fa2c27382f71ec8cb1945783cea5b8474709547fb3bf55801d422732ac2490` |
| `replay-oct13-r1` | `cdd93c104cdd4837a137f4c116357c7e` | 0 | `bf5f3ab7b0f6eb454fd0c06e698cada08a1bee67402748e48834e8c1cb298da5` |

## Resource cleanup and outstanding acceptance

Eight closed-build PCH caches were archived, byte-compared, then pruned,
freeing **0.558 GiB net**. Models, source, dependencies, media and logs remain.
Two archives are under this evidence root: `leaf-r1-closed-pch.tar.gz` (2
members, SHA `a35cac6942525d32f1e35576387af211ada018bb0b4af0f650f1f6e12c8817ba`)
and `leaf-r2-closed-pch.tar.gz` (4 members, SHA
`3b71256765d97c1fb1ef1c2979934a14552fc8493f6549de113f437b934af41f`).
The third is under `ventium-load-read-ack.GyWDDtiI`:
`obsolete-fp-soc-closed-pch-oct13.tar.gz` (2 members, SHA
`281880439f893b5edfb03d5c1861d52db4848c6823c9e8d0ac6959a13b170193`).
Restore each archive with `tar -xzf ARCHIVE -C ITS_EVIDENCE_ROOT`.

The candidate has no synthesis, full-PC, standard-suite or physical-FPGA
qualification. The older endpoint/SMSW synthesis estimate remains **35.057 MHz**
(unplaced, below the required 40 MHz); it does not measure this candidate.
The installed FPGA bitstream and its Doom SMSW failure are unchanged.

Candidate gameplay IPC: **unmeasured**. Older verified simulation baseline:
**0.51030715 total U+V**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. Predates this candidate; not FPGA/Doom IPC.
