# Saved-window FP upper-word selection — October 10

**Private, default-off candidate; not FPGA or standard-suite acceptance.**
`VEN_L1D_HIGH_PAYLOAD_SELECT` changes only the payload selector in
`rtl/mem/ven_l1d.sv`. The parent hardware's independently audited 163-level
critical path still crosses the younger tag/lookup decision through
`shadow_reuse` into `c_rdata_hi` and the shared FP/SRT control. Its 21.130 MHz
unplaced estimate is **not this candidate's timing result**.

## Implementation and safety obligation

The [recipe](prepare_high_window_payload.py) chooses shadow payload using its
registered validity and physical-line identity, retaining the code-access
exclusion. Every removed qualification is already required by the **unchanged**
`c_rdata_hi_valid`. ACK, permissions, coherence, request/extent checks, all
sequential state and SRAM ports remain unchanged. The supported profile requires
two saved windows and registered responses; incompatible profiles fail loudly.
No additional pipeline stage, fallback mode or duplicate arithmetic is added.

Unlike the low-word optimization, this selector must **not** exclude an exact
primary `rd_match`: its primary dword may be valid while an upper bank belongs
to a different read. Preserve shadow priority even when both owners match.
The recipe requires exact valid/reuse/source anchors and refuses repeated or
ambiguous application. Assertions compare every valid high beat's owner and
data with the original mux. The host Boolean/offset lemma is only a
combinational check, not a sequential cache proof.

## Closed leaf and build evidence

Scratch prefix: `/home/yukidama/external/tmp/`.

- `ventium-high-window-payload.WjAngfp4`: original, feature-disabled and
  feature-enabled leaves all exit 0. All per-clock interface observations are
  identical, SHA256 `2c30a260529f2023baf9756f172341fa4beca8d67f45e5d71eaf4fc2b486fc22`.
  The logs are losslessly retained as `*/cycles.txt.gz`.
- Each checks **66,339 valid upper words** against independent backing memory:
  42,254 shadow / 24,085 primary, 25 duplicate-owner events and 152 blocked
  partial-bank events. New vectors cover every legal unaligned 64-bit offset
  0–24, high-word rejection at 25–28 and rejected younger lookahead. All earlier
  memory-chain, coherent-store, snoop and partial-owner vectors remain intact.
- Two deliberately incorrect implementations (wrong high data and missing
  physical shadow identity) each fail natively with the required high-word
  assertion. A zero exit with fatal text would not pass. No DUT state is forced.
- The five-profile leaf run closes in 40.74 seconds with all source pins stable.
  Six host recipe/adapter tests pass. The first adapter-test assertion used
  the integer corpus's variable name for the FP corpus; it was corrected to
  require each corpus's actual **complete cycle-list equality**, without
  changing either comparator or native corpus.
- `ventium-high-window-core.dPpq7VRd`: model
  `a74573e1cc380e05e15077163cb126eeac21efde26c8d0b5be26a15950cc3657`
  builds natively in 15.24 seconds, with a unique private C++ harness/header.
  Only `ven_l1d.sv` and one define differ from parent `3c3ab215`. UV and all
  system/relocated fast-path flags remain enabled.

Full-core cold paged FP/integer A/B comparisons close at **17:31:58 UTC**:
`verification/` under that core root, service
`ventium-high-window-core-verify-oct10.service`, invocation
`3cc0c16fb503414d9b31f54ed8043028`. All **2,656 full QEMU architectural
comparisons** pass and **1,328 complete cycle-record pairs** are identical.
The main matrix covers 384 FP and 256 integer cold-reset cases, both protected
relocations, all 32 instruction alignments and AXI latency 0/7. There are 24
additional cases at operand offsets 0, 1, 24, 25, 29 and 4093, proving both
high-response eligibility and cross-line/page fallback. Actual V retirement,
normal native exit and unchanged observation timing are checked throughout.
The unchanged canonical `make verify` is now running with
both AXI backends at latency seven. Existing canonical failures are not waived.
Eight native workers fit the fixed task envelope; builds use 32 compiler jobs.

## Reproduce and acceptance boundary

Run `test_high_window*.py` with unittest discovery in this directory.
`run_high_window_payload.py --parent <frozen-core-root> --fixture-root
<closed-response-r3-root> --out <fresh-external-dir>` requires the shared
`ipc_parallel32` build guard and `TMPDIR` equal to that output directory.

`run_high_window_core.py --suite fp|integer --control <parent-bin>
--candidate <candidate-bin> --out <fresh-external-dir> --workers 8` requires
`TMPDIR=/home/yukidama/external/tmp` and the same guard. It archives its exact
adapted corpus. The only feature-admission change is this experiment's define;
all original QEMU and cycle checks are preserved.

Latest verified gameplay remains **0.51469855 U+V retirement-event IPC** on
older `bfb867f7`, clocks **3,600,065,237–3,700,065,237**; its full 2.5B-clock
observed aggregate is **0.4940587592**. That model's own duration-valid
CoreMark scores are **2.101890118 / 2.107616105 CM/MHz**. None transfers to
this unmeasured candidate. Complete timedemo, green differential gates,
standard suite and physical FPGA remain open; REP events are not P54
macroinstructions. The separate C1/FST correctness repairs are not in this
one-file experiment.
