# UV-fast candidate source-closure repair — Oct 8, 2026

**Not FPGA/Quake acceptance.** The deployed `1c8f20ac` image and both candidates
below have no qualified gameplay IPC. Historical `53f129e9` measured
**0.1659957781052303 primary/U-counter IPC**, not total U+V, across 127 qualified
intervals with gaps within cycles 8,721,490,845–19,169,282,165, frames 37–898,
at 37.499869765 MHz. That baseline predates these candidates.

## An omitted committed repair, not a newly discovered production defect

The frozen 107-definition source tree inherited by the recent translation and
permission experiments contained the Oct 3 L1, **omitting committed repair
`0f12b208`**. Their tests do not establish equivalence to the current checkout.
The production `rtl/mem/ven_l1d.sv` already has that repair; no new production
cache change was needed for this integration step.

The old payload mux selected `early_rdata_q` whenever **any** critical response
was armed. ACK instead checked its exact address/strobe/code owner. With
hit-under-fill enabled, a different resident request can be captured on the
same edge that arms the miss's critical response. The old implementation then
ACKs the resident request but returns the miss's data. Selecting critical data
with **`early_match`**, as ACK already does, repairs that mismatch without
changing ACK timing, issue policy, cache capacity or the FSM.

This is **not evidence that it caused the observed FPGA CMP invalid-next-PC
failure**. That causal connection remains unproven.

## Native reproduction and integration

Evidence root:
`/home/yukidama/external/tmp/ventium-l1-payload-cut.4ZJPf9`.
Despite its initial directory name, this stage makes **no payload-factoring
optimization**. Its only source difference from `ventium-fe8-perm-uv.ZKQfBa`
is restoring the complete, byte-identical committed `ven_l1d.sv`:
`e24b9140f6c1c36dbc4478c88e09596787fcf40388b96197c90ad0a3bc418572`.
Both build scripts require `git show 0f12b208:rtl/mem/ven_l1d.sv | cmp ...`
before compilation; the exact source and binary inputs are pinned before/after.

`owner-ab/result.json`: the unchanged `tb_l1d_early_retarget.sv` under the exact
110-definition simulator profile, assertions enabled, **no SYNTHESIS waiver**:

- Old source: hold-until-ACK passes; data and code retarget controls fail with
  `ACK carries data belonging to a different request`.
- Repaired source: all three pass. Expected failing controls are not correctness
  passes. Pair ports are inactive in this cache leaf; it is not a U/V execution
  test by itself.

New SoC model:
`f111006715a2c72e9d3fa02e62bbc1da48170f008cf91be436a380345dc053dd`.
User model:
`723d595566e85316057f5e7a66256f39d665f39553c75b2227f5d2b32bfe3db3`.
The exact 110 defines retain FE_PIPE/MULTI/PERM and all prior fast paths; the
user model removes only `VEN_KV260_SOC`. Unique harness basenames and checked
local objects/header dependencies prevent stale cross-model linking.

## Closed checks, UV + fast pipe throughout

- **40 full candidate/QEMU state comparisons pass** at AXI latencies 0/7:
  eight paging/fault fixtures (16), eleven additional system fixtures (22),
  corrected FS stack fixture (2). No comparator masks or state removal.
- Original system cycle matrix: 16 candidate/control comparisons preserve the
  same final clock count and number of paired V retirements.
- **48/48** intermediate U/V retirement-state cases and **32/32** shift/Jcc
  cases pass: `ventium-uv-retire-pairs.6z0n7gyg` and
  `ventium-uv-shift-branch.a_2mfa54`.
- CPL3/dirty-task matrix **12/12** passes, with 640 checked CMP/JNE pairs.
- Permission/stack replay `ventium-fe-permission-core.ifbysise` passes four
  QEMU diffs plus four cycle checks. The warm read-only fixture has eight real
  same-clock load/ADD pairs per cycle trace; the stack fixture has 70 paired V
  retirements, three fast reads and one fast write.

Required UV-fast `make verify` closed **FAIL**, exit 2: seven functional passes,
101 length-only divergences at the terminal exit/cap boundary, and the existing
`mb_dmiss` cycle band (4,154 versus 20,524). The failed gate is retained; no
slow-mode control substitutes for it. Both CoreMark seeds, Win95 desktop and
the original cold 40 MHz FPGA Quake timedemo/movie remain unqualified here.

Subsequent audit established that this generic run selected direct memory,
not AXI. Its 4,154-clock result is not a physical-cache miss measurement; see
the [backend configuration repair](UV_FAST_VERIFY_BACKEND_2026-10-08.md).

The board's read-only five-second probe measured **40.000339 MHz**, zero new
retirements and zero AXI activity. The previous failed run remains stopped;
this is not a gameplay measurement. No bitstream, clock or guest mode changed.

Disk cleanup removed eight enumerated, closed-build GCC PCH caches:
735,845,275 bytes (701.76 MiB), rebuildable. Binaries, source, objects, logs,
traces and build identities were preserved and their hashes rechecked.
