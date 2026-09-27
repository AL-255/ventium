# Registered integer resident-read chain (source default off)

`VEN_PIPE_MEM_CHAIN` is source-default-off, but the 2026-09-27 full-PC
fairness/gameplay builds enable it. Its isolated gameplay contribution has
not been measured; it must not be described as a newly available or missing
optimization in those profiles.
It requires `VEN_L1_AXI`, `VEN_UOPCACHE` and its `VEN_IC_BRAM` prerequisite.
The existing functional profile remains unchanged when it is absent.

The existing returned uop-cache windows supply an arbitrary sequential next
packet after the oldest U or U/V packet. Architectural `eip`, `flin` and
`cur_lin` retain the oldest owner; no lookahead PC reaches faults or interrupts.
A read-only second DTLB query shares the existing entries and registers the
candidate physical address separately from the cache-data capture stage.
It cannot walk, update A/D bits, allocate a cache line or access a device.

The leaf keeps the old address-qualified registered response while its single
async array lookup examines the independent next address. Only oldest integer
commit plus next resident-ready accepts the candidate, replaces the existing
`pipe_mem_*` packet and captures the next data into the same `rd_window_q`.
The next candidate's successor can be prepared on that edge without consuming
old response data in its AGU. No cache arrays or response windows are duplicated.
`VEN_FE_PIPE` primes its existing page register from the accepted translation.

The first profile admits nonstack 8/32-bit integer reads (MOV and the existing
memory-ALU families), with optional legal register-only V pairing. Address RAW
against both outstanding packets, branch/FP/store/stack packets, debug/shadows,
raw pending events, code/TLB invalidation, MMIO, misses and cross-line operands
drain to the legacy path. Code lookahead stays in the current checked code page;
data pages need not match. Every candidate proves its full 33-bit segment
extent, including overflow at a full-limit segment. Rejection never delivers
a younger fault; the original checked path raises it after the older commit.

Pending acceptance tests (parent serializes all builds/simulations):

```sh
tools/build_scope.sh -- bash verif/l1/run-l1d-mem-chain-gate.sh
tools/build_scope.sh -- bash verif/issue_uv/run-mem-chain-policy-gate.sh
# Sustained twelve-packet full-core A/B, including candidate-U/V address RAW:
tools/build_scope.sh -- python3 verif/issue_uv/run-mem-chain-ab.py \
  --control /absolute/baseline/tb_ventium --candidate /absolute/candidate/tb_ventium
# Full-core TB compiled with the candidate plus the audited baseline defines:
TB_BIN=/absolute/candidate/tb_ventium CASE_ONLY=independent \
  ASM_SOURCE="$PWD/verif/issue_uv/t_mem_chain_ipc.s" \
  bash verif/issue_uv/run-load-issue-ipc.sh
# Fourteen full architectural #PF/retry fixtures, preserving older-load state:
tools/build_scope.sh -- python3 verif/issue_uv/run-alu-memory-fault.py \
  --control /absolute/baseline/tb_ventium --candidate /absolute/candidate/tb_ventium \
  --memory-chain
TB_BIN=/absolute/candidate/tb_ventium CASE_ONLY=dependent \
  ASM_SOURCE="$PWD/verif/issue_uv/t_mem_chain_ipc.s" \
  bash verif/issue_uv/run-load-issue-ipc.sh
TB_BIN=/absolute/candidate/tb_ventium CASE_ONLY=byte_high \
  ASM_SOURCE="$PWD/verif/issue_uv/t_mem_chain_ipc.s" \
  bash verif/issue_uv/run-load-issue-ipc.sh
```

`run-mem-chain-ab.py` uses the `SUSTAINED` assembly variant: twelve memory-plus-
register packets spanning two code lines and eight distinct data lines on two
pages. The original three short variants remain compatible with the general
load-issue driver. Its two RAW variants make packet 1's U or V write the address
used by packet 2, with a wrong-address sentinel restored on **every** iteration.
They require a warmed-up packet-0-to-packet-1 handoff with paired V, followed by
a packet-2 drain, so a wholly serialized fallback cannot qualify the hazard test.

The dedicated driver runs both full-core binaries in cycle and cycle-functional
mode, matches the **entire** retirement PC sequence to pinned QEMU, and compares
every observable architectural retirement-group snapshot. The current cycle
observer exposes pair-final state; this gate does not claim to check an absent
intermediate-U snapshot. It requires normal QEMU exit, all 1,000 loops, exactly
27 instructions per loop, and the exact final RTL exit instruction. Its default
instruction cap is 27,128, not the short fixture's 6,020; no loop suffix is dropped.
Both binaries execute the same 24,273-instruction post-warmup measurement window.
The independent case must use fewer candidate clocks. Each candidate case also
needs at least four consecutive distinct-line memory packets retiring one clock
apart: a trace-derived sustained-handoff witness, not a synthesized counter or a
claim about internal acceptance telemetry. Results and binary hashes are retained.
Use otherwise matched baseline/candidate build profiles differing only in
`VEN_PIPE_MEM_CHAIN` when attributing the A/B improvement to this change.

For assembly/layout validation without any simulation or RTL compilation:

```sh
python3 verif/issue_uv/run-mem-chain-ab.py --assemble-only \
  --control /unused/control --candidate /unused/candidate
```

Run the same fixed-work programs in the baseline TB and require complete
QEMU state equivalence and fewer independent-case clocks, not just a positive
acceptance counter. Leaf tests cover 144 consecutive different/same-address
handoffs, response backpressure, a line-end byte, miss/MMIO/crossing rejection,
store/read ordering, snoop/flush and reset. The core corpus additionally needs
precise next-owner page/segment faults, relocated full-limit wrap, SMC and
interrupt/debug-boundary witnesses. Those and broad functional/system gates,
Win95 and matched-work Quake qualification remain required. Nothing here
establishes >1 gameplay IPC or FPGA timing/area sign-off.
