# FP-only ACK dependency cut — 2026-10-10

Status: **private candidate; not 40 MHz, not a standard-suite or FPGA pass**.
The target remains at least 40 MHz synthesized Fmax with UV, system/relocated
fast pipeline and fast memory enabled, followed by routed and physical validation.
The preceding [L1 candidate](L1_LEGACY_CAPTURE_CUT.md) measured only **22.4916 MHz**
in unplaced diagnostic logic-only mapping. No timing exception is introduced.

## Why the first attempt was rejected

The actual mapped critical path traverses memory ACK / `pipe_mem_wait`, then
`fp_shared_direct`, and ends at the shared FPU bank enable. The V-response
capture paths also traverse that FP eligibility logic. An executable live x87
descriptor does not issue an integer load/store; an outstanding integer packet
must nevertheless exclude live FP execution.

Replacing `!pipe_mem_wait` in **`pipe_fp_live_arm` itself** was wrong. Despite
its name, that signal also permits integer address-dependency and reference
operand priming in `core_agi_resident_prime.svh` and
`core_ref_operand_prime.svh`. The broad replacement disabled these paths.

The rejected full-PC model `48ee44c0` passed CRCs but increased the short
CoreMark performance seed from **4,767,218 to 4,886,214 clocks: +2.496% clocks,
−2.435% throughput**. Its original full-core model was `14d3920a`.
Its focused FP tests missed the integer consumers; their passes are not overall
qualification. The old `prepare_fp_nomem_arm.py` recipe is retained only as
negative-control provenance, **not a recommended implementation**.

Evidence remains in external scratch `ventium-fp-nomem.anUKwu40`. Validation
seed execution was stopped by the failed performance check. Its attempted
synthesis controller failed a pathname precheck before launching Vivado; there
is no synthesis result for that rejected candidate. Original failures remain.

## Corrected implementation

[prepare_fp_nomem_exec.py](../verif/issue_uv/prepare_fp_nomem_exec.py) leaves the
shared `pipe_fp_live_arm` definition byte-for-byte unchanged. A separate
`pipe_fp_nomem_arm` preserves the state, frontend, ownership, stall and issue
guards, replacing only the irrelevant integer-memory ACK dependency with the
live decoder's non-integer-memory qualification. Only `pipe_fp_fast_exec_ok`
consumes it. Its consumers were checked recursively through the include files.
Fault/debug/trap checks, accepted edges, cache geometry and feature defines are
unchanged. Simulation assertions check the decoder and memory-wait invariants.

The private full-core binary is
`429fcf4dbb718a8b83da41fa4a3e28cd68b5328c0c2a7ba24fe377e66dc91c3a`;
changed `core.sv` SHA-256:
`93865328ee935db1f1bf0677fce39f6071af14f9ea4f98be44569c6d91a95f83`.
Root: `/home/yukidama/external/tmp/ventium-fp-exec-cut.MNkzxfBO`.
The parent is the source-qualified `de02d77f` L1 timing candidate, not the
rejected FP model or the unrelated dirty checkout.

## Regression evidence

- Four recipe tests require the exact two edits and reject source drift and
  reapplication.
- The actual-decoder/source-extracted leaf compares **4,653,056 samples per
  profile**, including hardware, strict-MF and legacy variants. It now also
  compares the shared permit on **integer** descriptors. All four deliberate
  owner/ACK/trap/shared-permit defects fail. Seven native runs close as expected.
- **72 cold paged FP/integer/memory cases**, six instruction offsets and both
  flat/relocated code, pass complete QEMU state checks at AXI latencies 0/7.
  Every candidate/control retirement state and cycle matches; actual pairing
  and early FP command acceptance are required, not inferred from defines.
- The TS/EM #NM fixture and five-case architectural-debug fixture pass native
  QEMU and complete A/B state/cycle checks. The deployed profile does not enable
  strict-MF; no whole-core strict-MF pass is claimed.
- [The new AGI regression](../verif/issue_uv/run_fp_nomem_agi.py) runs 12 cold
  flat/relocated address-dependency fixtures at AXI latencies 0/7. Corrected
  execution retains all **350 observed priming accepts**, identical states and
  clocks. The rejected model has **zero** accepts and fails all 12 complete
  cycle comparisons. This closes the specific coverage hole found by CoreMark.

The independent audit rechecks **6,687 pins**, **51,044 identical architectural
records and retirement cycles**, **7,268 early FP accepts** and **8,560 actual
V retirements** across the 86 cases. Audit SHA-256:
`cd12d757f2263ee988cd4627bac8b0adc24b5f44a990a92f043e49ad89ee2faa`.

The unchanged canonical differential gate closed with native make exit 2:
**7/108 functional passes**, and 12/19 scored cycle kernels outside their
bands, as on the parent. All 20 candidate/control complete cycle streams match.
No mask, golden or band changed; this is still **FAIL**, not a correctness pass.
Full-PC short CoreMark and synthesis are now closed below. The global timing
estimate regressed; the candidate does not meet the frequency requirement.

## Full-PC and hardware source match

The posted-16 full-PC model built with native exit 0 in 14.82 seconds:
`74f16acf1f21d8924b310eac9b91cda0fa2c3c651f21d223414d16009d20f615`.
All 102 shared RTL inputs match the directed model, with only the reviewed
`core.sv` delta from `467ff95f`; 154 simulation defines remain unchanged.
The 98 inherited platform structural warnings remain debt, not a lint pass.

The FPGA exporter rechecks 9,658 input pins, 190 payloads, 117 filelist units
and 49 include edges. Manifest SHA-256:
`4e045c450620b5cef603772399d97be269f8961ebb1e161cbd152b8795a9e91b`.
Its 156 hardware defines, full P5 L1s, platform L2, posted-16 transport and
40/100 MHz constraints are unchanged. Four exporter tests pass. Strict
CPU-hierarchy lint on the exact export closes native 0 in 2.37 seconds;
this does not cover full-SoC structural lint. A first export invocation used
the `external` symlink and was correctly rejected before writing any payload;
the successful invocation uses canonical physical paths without weakening
the no-symlink checks.

Both original short cold CoreMark seeds close with native exit 0 and original
CRCs, restoring the exact parent clocks:

| Seed (10 iterations) | Parent clocks | Corrected clocks | Actual V retirements |
| --- | ---: | ---: | ---: |
| Performance | 4,767,218 | 4,767,218 | 1,055,307 |
| Validation | 4,753,406 | 4,753,406 | 1,054,254 |

The independent audit checks all 9,501 source pins, original disks/ROMs, real
native argv/CPU-11 affinity, complete consoles and reaped children. No OOM;
scope peak 50,814,976 bytes. Controller invocation
`43c1da641f7f463b8171d0d0c6bce6f7` is terminal, native 0.
Audit SHA-256:
`0ce5802a1b98b03067004f6c0f017396904f536c2685906a286ec8c4f8bf7233`.
This is **0% measured cycle-throughput change relative to the original parent**,
not a duration-valid CM/MHz score or a physical performance result.

## Closed synthesis and timing: frequency requirement still fails

The bounded single-family controller `ventium-fp-exec-full-synth-oct10.service`,
invocation `752a5a9ce908438dade4d65999dde174`, closed native 0 at 23:59:37 UTC
on October 10, after **1,048.97 seconds**. The mapping remains the parent's
diagnostic `logic_only` / `-no_timing_driven` profile, one job, unchanged
40/100 MHz constraints. Peak RAM was 8,589,926,400 bytes and peak swap
1,268,727,808 bytes; no OOM or resource stop occurred.

The audit rechecked 9,874 pins and 148 native Verilog inputs. Synthesis emitted
zero errors, 1,567 warnings and one inherited critical warning concerning a
generated PS XDC `create_clock` pin; that warning is not waived. LUT usage rose
from **192,820 to 195,869 (+1.58%)**, registers from 54,581 to 54,610; BRAM
277.5 and DSP 47 are unchanged. Synthesis audit SHA-256:
`05fba70f0a120b118583384335bfe63ef683cc8ec31a19af22810180c436eabe`.

The separate native clock audit, invocation `29534b4722db4bb4852831b21e8f3848`,
closed native 0 in 249.59 seconds. It verifies the original 40/100 MHz clocks,
9,906 input pins and zero black boxes or structural DRC errors. This is not
full timing acceptance: eight no-clock endpoints remain reported, alongside
zero unconstrained internal endpoints. The unplaced core hold slack is
−0.101 ns. Timing audit SHA-256:
`b4644f0102a50dcf17e993b87e54499fd829a2cb7f7ac58473bb33755d64ecea`.

| Same diagnostic synthesis profile | Parent | FP-only cut |
| --- | ---: | ---: |
| Core setup WNS at 25 ns | −19.461 ns | −20.175 ns |
| Unplaced synthesized Fmax estimate | 22.4916 MHz | **22.1361 MHz** |

Thus global estimated Fmax **regressed by 1.58%**. The intended dependency
is removed: none of the new 30 worst paths traverses `fp_shared_direct`, and
the V-response capture path improves from −18.433 to −17.288 ns. However,
the new worst path ends at integer GPR data through late memory acceptance,
V carry selection and the V ALU. It has 160 logic levels, 44.964 ns data delay
(10.043 ns logic, 34.921 ns estimated routing). This exposes the next target;
it does not establish that one more local edit will achieve 40 MHz.

No placement, routing, bitstream generation or board programming was launched
for this candidate. The global regression is retained, not labelled an accepted
frequency optimization. See [the carry-payload follow-up](V_CARRY_PAYLOAD_CUT.md).

## Resource handling and acceptance limits

Removed only 26 enumerated, rebuildable PCH files from completed builds,
recovering **2,185,261,056 allocated bytes**. `pch-prune-plan.json` and
`pch-prune-closed.json` retain exact paths, hashes/inodes and terminal build
owners. Binaries, sources, logs, traces and media are preserved.

Latest verified gameplay baseline: **0.51030715 total U+V retirement-event
IPC**, model `2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates
this candidate, which has no gameplay measurement, completed timedemo, Win95
acceptance, duration-valid CoreMark score or physical FPGA qualification.

Separately, the still-running older `2b4d7a48` Win95 simulation visibly shows
a clean desktop, readable Welcome window, icons and taskbar in
`ventium-zero-c1-soc.FTbYSn0L/win95-cold-zero-c1-oct10.1/frame_00011.ppm`.
Raw frame SHA-256:
`0589d29b72d19308e5eb7eb4d62d0c96348cf6eb949d96c236f5d6a202f5f36c`.
The review PNG is a lossless format conversion with no color adjustment.
Native closure and UI interaction have not been accepted; this is not a pass
for the newer timing candidate or the physical board.
