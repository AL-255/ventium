# Shared U arithmetic result and flags — October 11, 2026

**Directed-core-tested proposal, not a processor or FPGA qualification.** The
completed register-shift synthesis does **not** contain this change. The latest
completed unplaced post-synthesis estimate is **26.55408 MHz**, below the
required **40 MHz**. No area, frequency or IPC gain is claimed here.

## Change and scope

The existing U datapath calls `alu_result` and `flags_next` separately. The
latter recomputes add/subtract/ADC/SBB to obtain carry or borrow. The
[exact-source recipe](../verif/issue_uv/prepare_u_alu_shared.py) makes their
sharing explicit: one 33-bit arithmetic expression produces both the full
result and the width-selected carry/borrow. Synthesis might already share
parts of the original expressions; mapped results must establish any benefit.

The recipe changes only `u_pipe.sv`, against parent SHA-256
`a93bbe5f4a29df896fd4be1d92807889030d432ab6bb1ef6d1b9b7712e5ff222`.
It preserves the module ports, immediate/INC/DEC operand selection, shifter,
full unmasked result and complete original EFLAGS policy. No clock stage,
issue restriction, cache change or slow-path fallback is added. The slow
and V-pipe helpers are untouched. Three recipe tests verify exact scope,
reversibility and refusal of source drift or reapplication.

Subtraction complements **all 33 bits**; the selected extended-result bit
then has the original borrow meaning for byte, word and dword operations.
INC/DEC preserve CF. A four-state test caught a prototype mistake: deriving
the carry index as `msb+1` and selecting SF directly by that index did not
preserve the original unknown-width behavior. The corrected proposal keeps
the original independent carry-index expression and `sbit` helper. The
failed first prototype and its receipts remain available.

## Closed native evidence

Evidence root: `/home/yukidama/external/tmp/ventium-u-alu-shared.CYwhaU6V/`.
The unchanged arithmetic oracle is `ventium_alu_pkg.sv`, SHA-256
`d99bb02a29042157b87b7cb0451d7aa6c6e3751873fd7674b5a040e01f5d1156`.

- `r2/closed.json`: **2,066,080** binary comparisons pass in **67.86 s**:
  all 32 operation encodings and eight helper-width encodings on boundary
  inputs, exhaustive byte arithmetic operands/carry for operations 0–13,
  and 100,000 deterministic random cases. Three compiled negative controls
  catch corrupted SBB borrow, INC carry preservation and word overflow.
- `r2/fourstate-r1/closed.json`: **9,216** X/Z comparisons pass against the
  unchanged helpers. No undefined flags are masked to obtain equality.
- `component-r2/closed.json`: the **actual original and transformed U-pipe
  modules** pass **65,664** complete six-output comparisons in **10.06 s**.
  Coverage includes every operation, byte/word descriptor combination,
  immediate/register selection, CL/literal count selection, all shift forms,
  carry values, boundary operands and 128 X/Z descriptor-width cases.
  All 154 PC definitions are retained. Compiled negative controls terminate
  with native mismatch/exit 1 for SBB borrow (case 6,145), immediate selection
  (case 257) and shift count (case 129).

The first component attempt (`component-r1/`) times out after 180 seconds
with two module instances in one Icarus process. It is retained as **FAIL**.
Bounded scheduler isolation shows each untouched module advances separately;
the combined native executable still does not finish. The corrected
[fixture](../verif/issue_uv/tb_u_alu_shared.sv) therefore runs the original
and candidate in separate processes. The original writes all 134 output bits
for each case; the candidate reads and case-compares every bit, including X/Z.
No synthesized input or RTL logic is changed to accommodate the simulator.

Component invocation: `7e1f3e64860d4f73b5060a074434c405`.
Closed-receipt SHA-256:
`8b00416b235d2a18ae9a435e128f4440ac60fdfea0b0c5093d2aa1f098ac2f5c`.
Original 65,664-record reference SHA-256:
`7db335b2290f49897628fa4b20899c3001380e69e667f10918fe6169463b9d3e`.
Source pins remain unchanged through native closure. This is bounded
component equivalence, not all-input formal proof or a QEMU/core gate.

To repeat the component test, use a fresh output directory under the mounted
external scratch filesystem and the same frozen source and definitions:

```bash
TMPDIR=/home/yukidama/external/tmp PYTHONDONTWRITEBYTECODE=1 \
  U_ALU_PARENT=/home/yukidama/external/tmp/ventium-u-shift-registers.XRngKRoW/soc/source/rtl/core/u_pipe.sv \
  python3 -B verif/issue_uv/test_u_alu_shared.py

# Launch run_u_alu_shared.py in a bounded user unit: CPU 10, 512 MiB RAM,
# no swap, 32 tasks, 1,080-second outer cap. Native children are individually
# capped at 180 seconds; compilations at 30 seconds. Required arguments:
# --source /home/yukidama/external/tmp/ventium-u-shift-registers.XRngKRoW/soc/source
# --defines /home/yukidama/external/tmp/ventium-u-shift-registers.XRngKRoW/soc/defines.txt
# --out <fresh external-scratch directory>
```

The [runner](../verif/issue_uv/run_u_alu_shared.py) uses Icarus, not Vivado or
a heavy Verilator build, and refuses an output outside external scratch or
less than 4 GiB free space.

## Cold system fixture preflight (original model only)

The new [assembly corpus](../verif/issue_uv/t_u_alu_shared.S) boots independently
through real mode, protected mode and paging into flat/relocated segments. It
checks byte/high-byte/word/dword arithmetic, ADC/SBB carry input, INC/DEC carry
preservation, NEG overflow, logical operations, MOV/NOT flag preservation and
a memory-source ADD. Each subject is followed by a condition-code consumer,
at four instruction-line offsets, over eight cold-to-warm iterations.

[The driver](../verif/issue_uv/run_u_alu_system.py) uses the pinned system QEMU
and native AXI-backed UV-fast core. It compares complete architectural and
cycle streams at AXI latency 0/7, without saved state, debug stepping or
omitted terminal records. Goldens run sequentially; four native workers
exercise the existing binary without launching a heavy compiler.

`system-control-r2/` closes successfully in approximately **52 seconds**,
invocation `73fb476143fb48c0b22790e053e876b4`, native exit 0, unchanged inputs,
197,656,576-byte peak unit memory. Coverage: **128 cold fixtures /512
model-latency measurements**, **66,304 architectural plus 66,304 cycle
records**, **3,328 actual paired subjects**. Both named model slots deliberately
use original shift-candidate core `ce54833f54ad48e002ad001b0eb7223ac81e910f5aca8400a04634babf948fa0`.
**This validates the fixtures; it does not test a whole core containing the
shared-ALU proposal.** Receipt SHA-256:
`ebdda0f990de1a7845cba8e93862945d74c906f978ef56f13f5181d16d37fbeb`.

The first fixture preflight is retained as **FAIL** in `system-control-r1/`:
its test incorrectly required NEG, NOT and non-accumulator TEST-immediate to
pair. Their architectural comparisons passed, but that pairing expectation
contradicted [AP-500's NP classification](../docs/ap500-pairing-table.md) and
the existing golden timing model. The corrected test does not force those
instructions to pair: it **asserts no pairing** and checks **504 warm
one-clock handoffs** from these subjects to Jcc. The ordinary pairable
register cases still require actual paired U/V retirement. No RTL or model
configuration was changed to obtain the corrected preflight result.

## Whole-core preparation and serialized continuation

[The builder](../verif/issue_uv/build_u_alu_shared_core.py) separates source
preparation from compilation. `core-r2/prepared.json` records all **195 source
files**, **480 direct input pins** and unchanged **150 definitions**. Exactly
`rtl/core/u_pipe.sv` differs from the independently audited shift model, and
its bytes match the component-tested transformation. The harness has a private
per-model basename; compilation must verify its object and generated-header
dependency. Preparation itself launches no compiler. Four
[host contract tests](../verif/issue_uv/test_u_alu_core_builder.py) pass for
source drift, symlink rejection, missing live build ownership and repeat-build
refusal.

Prepared manifest SHA-256:
`385415139bf21752199c6cd8e015a3d99b282d818ba802786f1ad285b53209f7`.
Candidate U-pipe SHA-256:
`0d27e79c88bc0e1fa9ff94efa1e5b271aa5933f5cd102fc6f5f26e56c6a8df8b`.
The earlier uncompiled `core-r1/` preparation and original builder are retained;
`core-r2/` adds explicit build-start bookkeeping, command-relocation checking
and the required compiler-version probe. R2 now builds successfully as recorded
below; R1 remains an uncompiled preparation.

One owned continuation is launched at **09:10:25 UTC**, invocation
`b7e09cbb9d19449494c53c42577e3589`, unit
`ventium-u-alu-core-queue-oct11.service`. It waits for the **exact** active shift
clock queue (`490247bb20b74c5497766c041e810334`) to close and pass its audit.
It does not restart that queue or overlap the current Vivado family. If the
measured shift candidate already reaches 40 MHz, this optional derivative is
deferred. Otherwise it runs the guarded-32 core build, real parent/candidate
cold arithmetic tests, unchanged canonical gate and complete same-input replay.
The 5 GiB build/4 GiB run disk guards remain intact. A red canonical result
remains red. This continuation launches **no FPGA synthesis, route or deploy**;
the mapped critical path still decides the next hardware experiment.

The shift clock audit closes at **26.55408 MHz**, so the guarded ALU build
proceeds. It closes native 0 in **19.82 seconds**, invocation
`6fda6babe3fd473e932c8ef45f01aad7`, with unchanged source pins and the private
harness/header dependency checked. Model SHA-256:
`ac967960c2c5006819135b571b35f5de084c7c3b25b814bd8881c25a8a9c13c9`.
This actual new model passes all **128 cold arithmetic fixtures /512
model-latency measurements**, invocation `f5c00ad50bb044fd95424c60df96eee3`.
Full architectural and cycle comparisons pass at AXI latency 0/7, including
the pairable U/V and explicitly non-pairable fast unary cases. Receipt SHA-256:
`e45814075422aa07fe7db17567c8a3fb13fcdec503de05f702d779efcd5f6ab6`.
The canonical gate is currently running under invocation
`30e27bc65b224ebeb5a4fefad4f28c13`; complete same-input replay follows it.
No ALU-sharing synthesis, frequency gain or gameplay gain is established.

## Remaining acceptance

Use the closed register-shift timing report to choose the next measured
change; do not assume this proposal fixes the next critical path. Whole-core
differential testing, unchanged-cycle checks, mapped area/timing, the full
standard suite and physical FPGA acceptance are still required before adoption.
The existing canonical gate remains **FAIL**; these component passes do not
change that status. No timing exception, permission check or architectural
state comparison has been weakened.

Gameplay baseline: **0.51030715 total U+V IPC**, simulated model `2b4d7a48`,
cycles **1,200,065,237–1,300,065,237**, predating this proposal. The proposal
has no gameplay measurement.
