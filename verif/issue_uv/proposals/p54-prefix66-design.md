# Transient operand-size-prefix D1 integration (2026-09-29)

Implemented as optional, default-off `VEN_P54_PREFIX66_REG`. This is not an
execution-descriptor cache: the only new retained state is a **33-bit paid-D1
token** (valid + full owner PC). No new SRAM port or `fpd_t` field is required.

The measured corrected combined candidate is **2.100583059 performance-seed /
2.103951178 validation-seed CoreMark/MHz**, short diagnostics rather than an
official-duration score. The predecessor COMMON was 2.053795: the combined
PREFIX66/MOV-ACK/actual-target-reader step improved its performance-seed score
by approximately **2.28% / reduced cycles by 2.23%**. These three techniques
were bundled; this is not an isolated PREFIX66 percentage. Gameplay IPC
remains the older **0.45746656**
baseline, build `3237b652`, cycles 1,150,151,638–1,400,151,638; no current
candidate gameplay measurement exists.

## Architectural rule and initial subset

Intel AP-500 section 5.5 charges one D1 clock for each ordinary prefix. A
prefixed UV/PU instruction becomes PU: after that real prefix clock it may
lead a legal U/V pair, but cannot fill V. The implementation spends a real
no-issue clock before admitting each prefixed U. It does not grant a
zero-cost prefix or speculative last-EX overlap.

The initial subset is one `66` in flat default-32-bit user code: register MOV,
ordinary ALU/TEST/INC/DEC, and immediate/one-bit SHL/SAL/SHR/SAR. Byte operands,
memory, LEA, stack, x87, branches, CL shifts, `0F`, LOCK, address/segment
overrides, and multiple prefixes remain on the existing reference path. The
following V is limited to an otherwise legal register instruction or ordinary
Jcc. Existing parent-register RAW rules and flag forwarding still apply.
**All explicit parent-register WAW is forbidden, including SP/ESP**: the
legacy `issue_uv` implicit-stack ESP exception does not apply to this subset
(AP-500 sections 5.6.3–5.6.4).

## Production implementation

- [core_prefix66_decode.svh](../../../rtl/core/core_prefix66_decode.svh)
  reuses the existing single combinational U decoder. Input selection depends
  **only** on raw `66` and architectural default width, never issue/cache
  permission. The explicit register whitelist then validates the decoded
  shape, adds one byte to length, and marks the instruction PU. The maximum
  admitted instruction is five bytes. Unsupported shifted forms emit an
  inert fast descriptor and follow the ordinary reference decoder.
- [core_prefix66_d1.svh](../../../rtl/core/core_prefix66_d1.svh) owns the 33
  token bits. Its live predicate requires the current tagged, returned byte
  window, no delayed memory/fragment/FP owner, and flat user context. It blocks
  every shared fast side-effect mirror through `fp_issue_block`. A consume,
  changed PC, lost frontend ownership, flush, accepted event, mode/debug
  departure, or snoop cancels the token. Same-PC loop revisits pay again.
- [core.sv](../../../rtl/core/core.sv) adds `fp_code16(...)` for **IP-width
  uses only**. Macro-on it returns architectural `def16`; macro-off it returns
  the historical descriptor `.w16`. The ten fast fallthrough/paired-PC/wrap
  sites and profiler mirror use this helper. Operand merges, flags and shift
  widths still use operand `.w16`; the two existing near-branch target masks
  keep their separate operand-size semantics.
- [core_fastpath.svh](../../../rtl/core/core_fastpath.svh) handles real prefix
  D1 after branch debt and before AGI. It writes no architectural state,
  request, or retirement and leaves the same live owner for the next clock.
  The profiler separately counts bucket 13 `PREFIX_D1`; prefix-disallowed V
  shapes and explicit WAW use a dedicated prefix-V-subset pair bucket.

There is deliberately no wide context key or new `fpd_t.ip16`. Initial
admission requires `!sys_mode`, `!soc_en`, `!cosim_en`, `!def16`, `!paging_on`,
`!smm_active`, and `fbase==0`: offset PC equals linear PC, and CS/default width
cannot change while this S_PIPE owner remains live. All relevant departures
kill the token. Global `def16` is stable through the owned fast packet; CS.D
changes in reset/system-transfer/interrupt/task/SMM paths, not during that
packet. Legacy unprefixed `.w16==def16`, so using code width there preserves
the old behavior. Extending admission to system/nonflat/delayed-memory modes
will require a new ownership proof, not silently weakening this invariant.

Candidate qualification also fails closed on the six **registered** older
owner flags `pipe_mem_active_q`, `fp_async_pending`, `fp_occ_pending`,
`xp_pend`, `xs_act`, and `fx_act`. This avoids exposing a simple new prefix
when its paid-D1 contract cannot run; the wider core may legally allow
ordinary integer work while asynchronous FP remains pending. It also avoids
misclassifying an old memory packet's commit from unrelated live raw bytes.
These flags qualify the final descriptor, not raw decoder input selection;
no request/ACK/fault cone feeds the raw decoder mux.

### Snoop and cold-fetch safety

Only independent external-DMA snoop port 0 can feed the common issue blocker.
CPU own-store snoops 1/2 derive current requests and must not close a
request→snoop→blocker→request loop; they cancel the token sequentially. A
qualified consume has register U and register/Jcc V, no active memory or FX
owner, so it cannot itself produce an own-store snoop. Assertions check that
real D1 has no request/writeback and a consume has a paid matching owner.

Cold or missing cross-line bytes do **not** arm the prefix blocker: frontend
residency/returned ownership must first be ready. This preserves the normal
fill path rather than suppressing the prefix's own required fetch. The option
explicitly rejects `VEN_UOPCACHE`; no persistent decoded cache is used.

## Qualification and reproduction

The corrected actual production-include leaf passed:

```
P54-PREFIX66-LEAF-OK admitted=9864 checks=10375 token=48 pairing=69
```

Artifacts: `/tmp/ventium-prefix66-leaf-4908pnk_`. The leaf covers all 65,536
opcode/ModR/M combinations, matching admitted encodings to the actual
reference decoder and width-aware U datapath; prefix-free/default16 descriptor
equality; real `issue_uv` plus the actual extracted production pair qualifier
for all 8×8 explicit writer-parent combinations; RAW/flag-forwarding cases;
and paid-token cold, cross-line, PC/context, flush, own/external snoop,
debug/event, hold, and all six registered older-owner probes. The latter
includes an old memory commit without a false new-prefix assertion.
Run [run-p54-prefix66-leaf.py](../run-p54-prefix66-leaf.py) through its capped
shared build guard.

The previous combined binary
`/tmp/obj_dir_cm_p54_combo_sep29/tb_ventium` passed the original 11 focused
whole-core cases: complete QEMU architectural state at actual
retirement-group ends, paid D1+EX spacing, legal independent pairing,
RAW/WAW/prefixed-V rejection, word upper-half preservation, carry/flags,
reference-only memory/multiple-prefix forms, an actual writable-code SMC
store, and full 32-bit PC progression `0x0804fffe→0x08050001`.
Artifacts: `/tmp/ventium-prefix66-combo-qualify-sep29/prefix-*-pad00`.
**Those initial passes predate the narrow explicit-SP/ESP-WAW and older-owner
fixes.** The corrected binary
`/tmp/obj_dir_cm_p54_combo_fixed_sep29/tb_ventium` then passed the new explicit
SP/ESP no-pair case 11, and all fourteen COMMON-mask full-state/AGI cases:
`/tmp/ventium-prefix66-fixed-quick-sep29/summary.json`.

Its complete 12-case × 32-pad matrix finished in **40.46 seconds**:
**382/384** QEMU architectural/actual-spacing checks passed. Two fixtures
did not reach RTL comparison because the golden gdbstub connection was
refused: case 7/pad 4 (port 42228), and case 11/pad 18 (port 42370).
No RTL/checker mismatch or assertion failure was observed in the other 382
cases. This is **not a fully green 384-case gate**. The user requested a stop
after the active run, so neither failed golden launch was retried.
The selected listener range 42000–42383 overlaps the host ephemeral range
32768–60999; collision with a previous gdb client's socket is a plausible
startup explanation, **not a confirmed diagnosis**, because the existing
golden generator discards QEMU startup stderr. For the next authorized retry,
use listener ports outside that range (for example `--port-base 62000`) and
preserve startup stderr. Do not reinterpret an unavailable golden as a pass.

The matrix summary and byte-exact losslessly compressed traces occupy 52 MiB
under `/tmp/ventium-prefix66-fixed-matrix-sep29`; binary SHA-256 is
`75e3d944c98c7d498d00457b9828894cbf136d11356ee2c0e705abbbd8592736`.
The shared scope cleaned up and no run remains active.

The parent also completed the fast gate on the corrected binary: **107
functional programs and all 20 cycle metric bands passed**. The 20 exact cycle
trace comparisons were diagnostic/non-gating and diverged; metric-band success
does not imply an exact silicon-cycle trace match. No system gate or full
standard suite was run.

GNU-as inline-comment and writable-ELF-layout mistakes were fixture-only and
were corrected. SMC uses [prefix66_rwx.ld](../prefix66_rwx.ld), a page-congruent
writable executable golden segment, not a guest or saved-state hack. Earlier
leaf attempts found harness-only missing `reg_merge` declaration and INC's
reference constant-one operand before the first successful leaf.

Example (rebuilt prebuilt binary; unique port required for fan-out):

```bash
TB_BIN=/path/to/corrected/tb_ventium CASE_ONLY=11 PORT=41425 \
  bash verif/issue_uv/run-p54-prefix66-reg.sh
```

[run-p54-prefix66-reg.sh](../run-p54-prefix66-reg.sh) supports cases 0–11 and
line-placement `LOOP_PAD=0..31`. The shared checker is
[check-p54-prefix66-reg.py](../check-p54-prefix66-reg.py).
[run-p54-prefix66-matrix.py](../run-p54-prefix66-matrix.py) stages up to 32
workers through assembly, distinct-port QEMU goldens, both RTL trace modes,
and the same checker inside the reviewed shared scope. It requires the named
ipc_parallel32 profile, caps the task-heavier golden stage to 24 active trees,
and bounds commands by a 540-second whole-matrix deadline; the launcher must
also apply an outer 540-second timeout. Successful exact trace
files are losslessly compressed to avoid retaining GBs of repetitive JSON.
Case 8's fixed `0x0804fffe` wrap PC ignores padding, so its 32 runs repeat one
placement rather than test 32 distinct placements.
The two golden-launch retries, matched CoreMark feature on/off measurement,
default-off full-core
regression, and later standard suite remain pending. Leaf forced-invalidations
are not a substitute for system-mode/page/CS/debug standard-suite acceptance.
No Win95 or Quake run has been launched for this feature, and the major
integration is **not yet declared complete**.

The older standalone proposal `.sv` modules are historical prototypes, not
production authorities. The production includes and runners above supersede
their wide-key/IP-field integration proposal.
