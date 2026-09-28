# Resident slow-decode handoff: bounded A/B qualification

The default-off `VEN_PIPE_SDECODE` path captures an already-returned,
identity-checked 16-byte instruction window at an eligible `S_PIPE` slow
handoff, then enters the **ordinary** `S_DECODE`. It removes one redundant
`S_FETCH` transition without changing the decoder, cache capacity or
architectural event owner. This is a directed CPI experiment, not a gameplay
measurement or a production promotion.

Two fresh full-core binaries were built from `rtl/core/core.sv` SHA-256
`4bdd3f990222657ab2a409b463238b503f811ebbafe6f0137839e2a59cd20e47`
with identical `VEN_L1_AXI`, `VEN_UOPCACHE`, `VEN_IC_BRAM`, `VEN_UOP_SFETCH`,
`VEN_SFETCH_RESIDENT`, `VEN_FAST_MEM_ADD`, banked L1D, code buffer and code
stream flags. Only the candidate added `VEN_PIPE_SDECODE`. Both builds used
32 bounded compiler jobs and finished in under 10 minutes; binary SHA-256s
are `1fc19960e96cf3904eb9839feceb832c040a457157ff0aef3ed63b5cf9ed1055`
(control) and
`235d061ba3e3a10c3401a28ef188b86c45005b369ba915eb` (candidate).

`run-pipe-sdecode-ab.py` passed pinned-QEMU architectural comparisons at all
32 instruction-line offsets, including 192 source/opcode self-modifying-code
visits. The matched control had 9,151 complete QEMU-equivalent groups and the
candidate 9,155 (different same-cycle grouping, not a different guest-PC
sequence). Its fixed-work windows sum to:

| Window group | Control cycles | Candidate cycles | Change |
| --- | ---: | ---: | ---: |
| Contained offsets 0–16 | 9,185 | 7,425 | −19.2% |
| All offsets 0–31 | 27,280 | 22,715 | −16.7% |

These are sums of **separate directed windows**; they are not one application
run or gameplay IPC. The matched guard microgate also passed. It covers
returned-way mismatch, same-edge BRAM collision/snoops and executable flush,
near-CS-limit/33-bit overflow, V86/real/16-bit/functional exclusions, and
page-contained versus page-crossing windows. Artifacts:
`/tmp/p54-sdecode-{control,candidate}-build.log`,
`/tmp/p54-sdecode-ab-r1.log`,
`tmp/build-tmp/ventium-pipe-sdecode.rtqw_pyo/`, and
`/tmp/p54-sdecode-guard-r1.log`.

The flag remains default-off. Before promotion it needs the deferred full
differential/system gates, exact-build Quake/Win95 qualification, a gameplay
IPC comparison, and FPGA area/routed-timing evidence. Resident handoff must
never bypass page/segment/fault checks merely to save a cycle.

## Composed memory-ALU check

A third build added only `VEN_FAST_MEM_ALU` to the slow-handoff candidate
(binary SHA-256
`8f116e66eb8ccc995c5d07f90ba6006ffced507745a2f29905f9cfeb6b325445`).
The existing 14-case pinned-QEMU memory-ALU A/B passed with full architectural
state. Each case retired the same 2,090 instructions and matched 2,442 QEMU
completion groups. ADD was unchanged at **6,985 cycles**; each other operator
and both carry inputs took **7,810 control versus 6,985 candidate cycles**.
Thus the two opt-in mechanisms compose in this bounded profile without a
directed regression. This is still neither a gameplay measurement nor a
general P54 timing claim. Log:
`/tmp/p54-sdecode-memalu-ab-r1.log`; artifacts:
`tmp/build-tmp/ventium-alu-memory-ab.hsrlpihk/`.

The 22-case 32-job cache/front-end/resource sweep also completed after a
host-only correction: the single-threaded Verilated model now requests one
runtime thread instead of silently creating a 32-thread pool per simulator.
The named build scope retained its **16 GiB memory and 128-task limits**; the
first attempts hit `pids.max` (with `oom=0`), while the corrected run passed
with all candidate/control architectural traces equal. The diagnostic runner
now prints exact cgroup pressure if thread creation ever fails again. This
change affects only simulator concurrency, not RTL clocks or architectural
behavior. Corrected binary SHA-256s are
`2be07098f7ba1067d49171296f5d639dd7e7e6482a1e47563e95e13346d0ee4e`
(slow-decode control) and
`f537374a3ca27d3ba0a7cfeb306b09d043e408a4c13c612e1499d8a1e026`
(slow-decode plus memory-ALU); see
`/tmp/p54-ipc-sdecode-memalu-r7/results.json`.

For that latter candidate, fixed-work loop costs remain **5 clocks / four
instructions for independent paired-load candidates**, **6 clocks / four
instructions for paired-store candidates**, and **7 clocks / four instructions
for the resident line-straddling frontend case**. Distinct-bank and same-bank
load/store cases are identical: the core still rejects V-memory pairing even
though the banked L1D has an isolated dual-hit interface. Six new memory-ALU
families improve from 11 to 5 clocks / four instructions. These observations
identify the next structural throughput work; they do not predict gameplay IPC
or justify bypassing P54 pairing, translation, or fault rules.

## Resident memory pipeline ladder

The next matched builds add the **already full-PC-enabled**
`VEN_PIPE_MEM_CHAIN` and then `VEN_PIPE_REG_LOAD_PRIME` to the composed profile.
The separate sustained twelve-packet memory-chain gate passes complete pinned
QEMU PC/group/state comparison, including U/V address-RAW drain witnesses:
24,273 fixed-work instructions take **35,061 control versus 27,869 candidate
clocks**, or 0.6923 versus 0.8710 directed IPC. The candidate has a six-packet
consecutive memory-retirement witness; the control has one. This is an
interaction check, **not** a new production/gameplay improvement, because the
historical full-PC profile already includes chain and priming. Log:
`/tmp/p54-sdecode-memalu-chain-ab.log`.

With the chain already present, adding only priming changes two of the 22
fixed-work loops: register-to-load goes **5→4 clocks** and register-U/memory-V
goes **4→3 clocks** per four-instruction iteration; all candidate/control
architectural traces match. Those builds hash to
`472b97fe72102830c3af5a99ed787174d25f37bf18ca44027e4144489f8f0a15`
(chain) and
`499495c6834dbbdd523145add3bfb86994ccc3ca76416db8bcc51c6dd9c062a8`
(chain+prime). Artifacts: `/tmp/p54-ipc-sdecode-chain-prime-r1/`.

The one **new, still default-off** cache option in this ladder is
`VEN_L1D_WINDOW_REUSE`. Adding it to chain+prime improves seven resident
memory-ALU families and same-line loads **4→3 clocks**, and memory-U/register-V
and memory-ALU-U/integer-V **3→2 clocks** per four-instruction loop; the other
cases are unchanged and all architectural A/B traces match. The reuse binary
hashes to
`7052a66205e567aabe1fdb9e7282ff29e7d162febde7bcdd9f428bc4376fcf94`;
artifacts are `/tmp/p54-ipc-sdecode-reuse-r1/`. Its separate current-source
cache-local window/coherence/stream gate passes. The matched FPGA L1D leaf
cost is **+658 LUTs, −3 FFs**, with synthesis WNS +16.908 ns at a 45.0 MHz
constraint versus base +17.621 ns; see the
[L1D synthesis record](../../fpga/P54_L1D_LEAF_SYNTH_2026-09-27.md).
This is not routed core Fmax or gameplay throughput. Even with reuse, two
distinct-bank loads remain at **4 clocks / four instructions**, two stores at
**6**, and a line-straddling frontend loop at **7**. A genuine V memory lane,
ordered store admissions, and a staged byte frontend remain the structural
work, not another same-line response shortcut.
