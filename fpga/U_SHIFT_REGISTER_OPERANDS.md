# Register-only fast-shift operand isolation — October 11, 2026

**Unqualified timing proposal. Latest measured parent: 26.14379 MHz;
required post-synthesis Fmax: at least 40 MHz. No new frequency or FPGA pass.**

The measured worst path reaches the U shifter through a memory ALU response
mux, then feeds forwarded branch flags and L1 replacement control. The decoder
admits only register shifts into the fast U path; memory shifts use the normal
sequencer. Nevertheless, the generic U ALU and shifter currently share the
memory-selected operand wire. See [the measured path breakdown](CARRY_ROTATE_TREE.md).

[The source recipe](../verif/issue_uv/prepare_u_shift_registers.py) changes only
the core's U operand block in the frozen carry-rotate derivative:

- Preserve the existing memory-selected ALU operands and all ALU flags.
- Compute fast shift result, count-minus-one result and carry from raw GPR
  operands, retaining high-byte selection, width masking, CL and zero-count
  behavior. The existing helpers are unchanged.
- Disconnect the now-unused generic `u_pipe` shift outputs in this instance;
  synthesis can remove that dead logic. Other users keep the same interface.
- Assert that any shift descriptor observed in `S_PIPE` is register-only.
  This is a simulation invariant, not a synthesis gate or new fallback rule.

No issue/retirement permit, cycle, cache configuration, clock constraint or
architectural behavior is deliberately changed. Descriptor ownership still
selects held U versus current U exactly as before. A future fast memory-shift
extension would have to change this contract explicitly.

Three exact-source recipe tests pass. The native test extracts the actual
old/new core operand blocks and `reg_read`, instantiates
the real decoder and flag-forwarding modules, sweeps primary opcodes/ModR/M
bytes and shift counts/widths/high-byte aliases, and checks held descriptors
while live decode changes. Negative controls deliberately corrupt byte
selection, zero-count state and memory ALU selection.

The first run, invocation `ca80d593047e49909cdd2ce1ed136a05`, passes its
937,216 positive comparisons but its controller fails: it expected Verilator's
negative-control assertion to abort, while this installed runtime returns 1.
The actual negative log contains the intended native mismatch; it is not a
timeout or compilation failure. That failed receipt and original runner source
are retained in `leaf-r1/`, without rewriting the result.

The corrected runner requires a compiled native assertion, its explicit
`U-SHIFT-MISMATCH` marker and no positive completion marker. `leaf-r2/` closes
successfully in **23.54 seconds**, unit
`ventium-u-shift-registers-leaf-r2-oct11.service`, invocation
`2d370b992d814bd88318427f5235eb68`. All input hashes remain stable:

| Native positive coverage | Comparisons |
| --- | ---: |
| All checks | **937,216** |
| Shift descriptors | 142,640 |
| Memory descriptors | 13,884 |
| High-byte shifts | 30,848 |
| Zero-count shifts | 17,176 |
| Held descriptor with changed live decode | 85,248 |

The three separately compiled corrupted variants each terminate with a native
assertion/exit 1. Closed-receipt SHA-256:
`d7162a9da5a536b95fafe8a16141d4f4b0864fc3cc1911f525ab2208ace85249`.
This establishes native old/new block equivalence for the stated corpus,
not whole-core correctness or all-input formal proof.

The [cold system fixtures](../verif/issue_uv/t_u_shift_registers.S) add high-byte,
word, ROR, zero-count, count-31, memory-ALU and ordinary RCR cases, across two
segment layouts and four line offsets. Their
[driver](../verif/issue_uv/run_u_shift_system.py) generates goldens sequentially,
then checks full architectural/cycle streams with parallel RTL jobs at AXI
latency 0/7. It requires actual paired shift/Jcc retirement, except for explicit
line-boundary and ISA-required slow-path controls. All **64 fixtures /256
model-latency measurements** pass on the **control model only** (both named
slots deliberately use the same model), invocation
`dc5ac5d25b3349c79d89e64cec59b28d`. This validates the fixtures, not the new RTL.

The owned queue, invocation `fbec52f0017f403197ac54da79ff39bc`, observes the
parent's complete canonical/A-B closure before building the new model. The
parent canonical gate closes **FAIL**, native exit 2; its 20 cycle streams and
108 complete same-input functional streams match its parent.

### Whole-core results and FPGA preparation

[The private core builder](../verif/issue_uv/build_u_shift_register_core.py)
closes successfully in **25.14 seconds**, native exit 0, invocation
`bb813ca4a3214859b05dd102fe0b3c0b`. It changes only `rtl/core/core.sv`, preserves
all 150 definitions and verifies the model-local harness object/header
dependency. All pins remain stable. Model SHA-256:
`ce54833f54ad48e002ad001b0eb7223ac81e910f5aca8400a04634babf948fa0`.

The **new model** then passes all **64 cold fixtures /256 model-latency
measurements**, invocation `d5a35a75e0714ee0a16a357015307346`. Full QEMU and
parent/candidate comparisons cover **33,280 architectural records and 33,280
cycle records**, with **1,792 paired shift/Jcc observations** across both
models. No state or timing record differs between models. Stable-input result
SHA-256: `be31aee65cb742011be57bf00a43342231480eb21d940dcf12fc69ade6d15c7d`.
The unchanged canonical gate is now running; 108-program same-input replay
follows. These are not complete standard-suite or FPGA results.

[The independent auditor](../verif/issue_uv/audit_u_shift_register_core.py)
will reopen those complete traces and verify exact source scope, owner
closures, original canonical cycles and 108 same-input programs. The
[PC builder](build_u_shift_register_soc.py) requires that closed audit and
reconstructs exactly the carry-rotate and register-operand transformations on
the measured branch-residency PC source, retaining 154 definitions and all 102
shared RTL files. It does not inherit a hardware pass from that source.

[The exporter](freeze_u_shift_register_rk_candidate.py) admits only the two
exact source deltas; six contract tests pass, including profile drift, lost
fast features, wrong source bytes and same-content inode replacement rejection.
The bounded preparation queue, invocation `61e6c68601cf415ba96615b44ad34a78`,
waits for actual check closure, then requests the independent audit, matched
PC build, export, source audit and strict CPU lint. **It launches no Vivado,
routing or deployment.** Those preparation steps are queued, not completed.

**880,645,526 bytes** of explicitly selected inactive compiler products are
losslessly archived, with verified member hashes and recovery commands in
`compiler-recovery*/`. Sources, binaries, headers, logs and traces are retained.
The corrected leaf runner archives only its two closed PCH caches after each
variant, preventing four small tests from retaining ~640 MiB of compiler cache.

Evidence root:
`/home/yukidama/external/tmp/ventium-u-shift-registers.XRngKRoW/`.
Whole-core differential checks, canonical gates, timing measurement, original
standard suite and physical FPGA acceptance remain open. In particular, no
syntactic depth estimate is substituted for synthesis or routed sign-off.

Gameplay baseline: **0.51030715 total U+V IPC**, simulated build `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**. It predates this proposal, which has no
gameplay measurement.
