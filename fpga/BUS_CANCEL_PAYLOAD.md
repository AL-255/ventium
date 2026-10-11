# Bus cancellation and payload selection — October 11, 2026

**Private timing experiment; not a 40 MHz, canonical-gate or FPGA pass.**
The latest measured parent remains **26.55408 MHz**, below the required
40 MHz. There is no synthesis, area or gameplay result for this change.

## Measured motivation and exact change

The [shift candidate's timing report](U_SHIFT_REGISTER_OPERANDS.md) shows a
134-level path from fetch address/length and access-fault handling through
fragment/request shaping, cache-response selection and the shared SRT input.
Its separate memory-capture path already limits the parent to about 28.09 MHz,
so [balanced SRT normalization](SRT_INPUT_NORMALIZATION.md) alone is insufficient.

[The exact-source recipe](../verif/issue_uv/prepare_bus_cancel_payload.py)
changes only `rtl/core/core_bus_driver.svh`. Paging miss/pending/permission
and synchronous-access/REP cancellation still suppress the request with the
same equations. They no longer clear unused direction/address/data/strobes.
Translation prepares the address independently of the late paging-fault
condition; A20 masks the physical payload even when invalid. State arms,
pre-squash observers and the final asynchronous-FP request hold are unchanged.
No clock, register, cycle, permission waiver or slow-mode fallback is added.

Parent header SHA-256:
`6bfa6c0e5f2e4e4e71535dd32c4334796e19facb60f7f97e488a617079587f8b`.
Candidate header SHA-256:
`e892403371c601c2e2c2660565fb8d4bf8ed7408efe3c0bf271015da63bf7ba1`.
The transform rejects drift and reverses to the exact parent header.

The intended benefit is removal of cancellation from payload-selection logic,
**not yet a measured timing improvement**. Invalid payload may differ. Issued
transactions, consumed responses and architectural/cycle behavior must not.
In particular, a low request signal alone is not a whole-system proof:
retained responses, fragment starts/aborts, A20, SMM, denied reads and faulting
writes need their own checks. The existing fragment-start equation retains
all miss/permission/access-fault/pending guards. No ACK equation is changed.

## Closed evidence

Evidence root: `/home/yukidama/external/tmp/ventium-bus-cancel-payload.Fzx7hUyD/`.

- Three host tests pass. The SMT proof uses an arbitrary pure translation
  function and all binary address/data/strobe/control inputs. Requests and
  pre-squash observations match unconditionally; issued payloads match when
  the request is valid. Deliberate permission, A20 and observer defects each
  produce a counterexample. This is a bus-tail algebra proof, not whole-RTL formal.
- `leaf-r1/`: the actual old/new source-extracted header tails pass **532,480
  native comparisons**, including **8,192 X/Z cases**, **12,117 accepted
  requests** and **490,011 inactive payload differences**. All three separately
  compiled defective variants fail their required assertions. The source
  state arms and translation function are abstracted in this leaf test.
  Native closure: **11.01 seconds**, invocation
  `06581fc3eb1d425a9f7986e17e1d0b32`, exit 0, unchanged pins.
  Receipt SHA-256:
  `2feab63fee6b91e621dfe46c9a0f300514ab44a1a4c9b0f7920f692210703d6d`.
- [The private core builder](../verif/issue_uv/build_bus_cancel_core.py)
  preserves all **195 source files except this one header**, all **150 UV-fast
  definitions**, and a private C++ harness/generated-header dependency. Four
  host admission tests pass. The guarded-32 build waits for the preceding
  canonical run's shared lock, then closes native 0 in **21.42 seconds**,
  invocation `3be50ec78f394d3b9ba002d000410db9`, with stable pins.
  Model SHA-256:
  `f2797f8c17cb6c7d8668432ae69dd42d427d25a3e3d3b3cd1452de8d6582b4bf`.
  Build receipt SHA-256:
  `8d0c627957725de1706e2f1ffa9e1321dded2c3cb016f09893c57cabc263cbbf`.

## Whole-core continuation and remaining acceptance

[The cold system runner](../verif/issue_uv/run_bus_cancel_system.py) builds
original fixtures privately: `pxfrag`, `pxc04`, `pxc04e`, `pxc04f`, `pfault`,
`pfetchlim`, `prsmflush`, `a20test`, and `a20cmdtest`. It requires real guest
exit, precise-fault/wrap witnesses, full QEMU architectural comparison and
identical parent/candidate functional/cycle streams at AXI latency 0/7.
Golden generation is serialized within the 32-worker matrix to avoid the
previous port-allocation race. Three host witness contract tests pass.
The first native matrix closes **FAIL** after 60.13 seconds, invocation
`94a3e5a9781c465893adea933c2745df`; its receipt and artifacts are retained.
Only `pfault` and `a20cmdtest` complete all four model/latency measurements,
with complete QEMU/parent comparisons and identical cycles. Five cases stop
on a **driver error**: architectural-register witnesses were incorrectly
applied to cycle-only records, which contain no GPR fields. Two original
fixtures also need their documented contracts respected: `pfetchlim` is an
existing non-differential, enforcement-witness gate (QEMU exits 135, not 133);
legacy `a20test` writes 0x02 to the 8042 output port, asserting active-low
reset as well as enabling A20. QEMU consequently does not reach the expected
exit with `-no-reboot`. The pinned QEMU `hw/input/pckbd.c` explicitly requests
reset when output-port bit 0 is clear. None is evidence of a candidate RTL
regression, but none can count as a completed candidate check either.
R1 receipt SHA-256:
`51600d9a7a7b6bf48f9615d013602882453b193d88f41ce8e4b3bb8f0bd38a81`.
This is not SMM or reset-injection coverage.

Full downstream/core verification, actual mapped timing, the original standard
suite and physical FPGA Win95/Quake validation remain required. The existing
canonical gate remains **FAIL**; a parent/candidate match cannot turn it green.
Neither this change nor SRT/ALU sharing has been merged into production RTL.

Disk safety: four exact inactive SRT precompiled-header caches were losslessly
archived and member-compared before removal, recovering **286,179,117 bytes**.
`compiler-recovery-r1/` contains member hashes, archive hashes and recovery
commands. Binaries, sources, ordinary headers, objects and logs are retained;
all protected input pins remain stable. No broad directory deletion was used.

Verified gameplay baseline: **0.51030715 total U+V IPC**, simulated model
`2b4d7a48`, cycles **1,200,065,237–1,300,065,237**. It predates this experiment,
which has no gameplay measurement, new bitstream or physical-board pass.
