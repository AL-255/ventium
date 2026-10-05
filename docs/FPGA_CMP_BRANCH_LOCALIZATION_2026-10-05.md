# FPGA memory-CMP/conditional-branch localization — 2026-10-05 UTC

Production Quake timedemo and the requested complete 15 fps movie remain
**pending**. These are private cold diagnostics, not patched production Quake,
save-state repairs, or acceptance substitutes. The installed FPGA image,
clock, RTL, production BIOS and disk were not changed during these controls.

Current candidate gameplay IPC: **unmeasured**. Verified pre-candidate baseline:
**0.42633263**, build `5c2491f3`, cycles
**7,099,999,637–7,199,999,637**. Last measured physical core clock was
**39.999479 MHz**; the PS PL source is 100 MHz, not the core frequency.

## Hardware results

All controls retain the original full prelude, CPL3 mappings, congruent caller,
memory service and general exception logger. They use the same conditional
branch location `14565`, except the explicitly labelled JMP control.

| Control | Relevant change | Hardware result |
| --- | --- | --- |
| Memory-left CMP/JP | Original diagnostic ROM | #PF14/error4 at `00a7:14566`, FLAGS `887`, CR2 `493c6488`; two cases complete |
| Memory CMP/JMP | JP `7a13` → same-length JMP `eb13`; synthetic returns all1 | 64 cases pass |
| Original CMP/JP, separately stepped | Identical ROM; STEP suppresses U/V pairing | First three pairs correct; ordinary paired release fails on case4 at `14566`, FLAGS `46` |
| OR EDI,[EDX+10]/JP | Only ROM opcode at `14562`: `39` → `0b` | 64 cases pass; flags `2,2,86,46` |
| CMP EDI,[EDX+10]/JP | Opcode `39` → `3b`; first two memory inputs1 →3 | 64 cases pass; flags `93,93,86,46` |
| Reversed CMP/JP, overflow discriminator | Only prepared-memory immediate high byte `9d7`: `00` → `80` relative to the passing reversed-CMP ROM | 64 cases pass; QEMU/model flags `93,93,46,887` |
| Original CMP/JP, bad-boundary BP | Identical ROM; breakpoint only at wrong EIP `14566`, no STEP | Actual bad architectural EIP captured **before** ADC or #PF |

OR writes EDI; reversed CMP does not. Their data/arithmetic and warm histories
differ from the original control. They narrow the investigation but do not
prove a memory-left-only defect, forwarding failure, descriptor corruption,
synthesis bug, or physical timing cause.

## Coherent pre-fault bad-boundary capture

The existing debugger parks at **CS:a7/EIP14566**, with last primary retirement
**14562**. Hidden CS/DS/SS/ES bases are **10000000**; CPL is3. State was read
before manual HALT or late forensic reset:

```
EAX=00000043 ECX=00000108 EDX=00efe6cc EBX=002c403c
ESP=000e07f8 EBP=00000000 ESI=00000002 EDI=80000000
FLAGS=00000887 CR0=80000011 CR2=00000000 CR3=0007e000
CS=00a7 SS=DS=ES=00af FS=GS=0000
```

Actual aligned 16 MiB physical-RAM capture checks the original code
`397a107a138b4c241039`, two completed cases, caller3/checksum `9fff`, third-case
memory0/EDI80000000, original mappings, and an entirely zero 104-byte exception
record. JP has PF1 and must target **1457a**; even a correct not-taken branch
would go to **14567**, never14566. The later ordinary fault's displaced ADC
address independently reconstructs CR2 `493c6488`.

The breakpoint does not name intended V PC14565. The debugger's paired-V
boundary check would normally compare `14562+3=14565`, not14566. However,
other debugger-history perturbations are not excluded. The PC ring exposes
primary U retirement only: **no actual retained V descriptor, length, condition
bits, next-PC mux input, or FPGA cache contents have been read**. Its legacy
`lin=` selector-times16 display is wrong for this protected-mode hidden base;
use the captured hidden descriptor, not that display.

## Model/reference verification

Pinned QEMU Pentium independently checks all64 actual post-ALU states and JP
destinations for both new opcode controls, then reaches normal AL42 debug-exit
**133**, zero exception record, count64/caller64/checksum `d5540`.

Each new opcode control also ran32 bounded, assertion-enabled cached-model
jobs in parallel: randomized reset seeds1–32, AXI latency0/3/7/13, alternating
response gaps, one model thread per job. The separately corrected harness
establishes a real asynchronous reset edge and retains four reset clocks;
it never forces internal state or disables assertions. All179 frozen inputs
and native/model/source pins match before and after.

For **each** control, **32 native exits are0**, all64 architectural cases,
original prelude/seam pairs, qualified memory responses, exact raw211-bit U/V
packets, GPRs, flags and next PCs check correctly. **27 consumers return0**;
seeds **5,8,14,30,31 return3** because the additional warm retained
predicted-taken/actual-not-taken coverage conjunction is missing. These are
architectural passes with missing coverage, **not32 complete gate passes**.
The complete matrix returns3 and its enclosing verification wrapper returns1.
No SVA stops or native timeouts occurred. These models do not reproduce the
FPGA's actual XPM contents, clock crossing, physical mapping or delays.

The reversed-CMP builder's initial byte-offset receipt assertion failed even
though assembled bytes were correct. That exit1 is retained. A separately
named R2 receipt corrects offset `9c0` to actual `9c5` without changing or
reassembling the ROM; R2 exits0. Do not erase or relabel failed receipts.

## Sealed evidence

All paths below are under `/home/yukidama/external/tmp/` and must be preserved.
Each capture has an independent read-only audit, exact native invocation,
source/ROM/production pins, closed service receipts and full RAM evidence.

| Artifact directory | Native invocation | Capture files | Closed-capture manifest SHA-256 |
| --- | --- | ---: | --- |
| `ventium-private-memor-jp.FhwQES` | `cc9e4d485dc048d79e71ff3ddcc902b8` | 35 | `f2beb8891a561523536387c04b663be65a9efbe730c6d95ef8753327047ba9ae` |
| `ventium-private-reversecmp-jp.7IPNOW` | `be543a699ba54e59bceab1965f989f1c` | 35 | `ec4cd446f020f36d0eb07b1f949f3d333b5c2e9fda84e64b7e84e456895cd9b4` |
| `ventium-private-jp-bad-boundary.oE0Zzd` | `6a4c8cd84c114501a6918e9e3cc5c67d` | 37 | `a59bb0703d29097ab0d5d6e57f4a3375998e26a77d77f39371290030d5fce541` |
| `ventium-private-reversecmp-overflow.o9SjbO` | `ceac17fecb284b4dbb732d265e5ac3e8` | 35 | `c4b44755d1ec63eac318843160190102eac9018b90f236af452761c6d5415cec` |

ROM SHA-256: OR `c34416d37d2080927e6b88e6133405020507d1edd97f56e6df65ae75b5ff7bb4`;
reversed CMP `8c143eb2230400771976ec151c84a50eabcf4cba5909c8c3adb6a3a2563fdb13`;
original JP `e6b20263852628770d3d9de0e8834681a7da844cd2f88ece2a7bd8ec95195f8a`.
Overflow-control ROM:
`d3b796de70876c79c540a2982c7745a5b1b48bf19ed3390a5aac6e4ad630640b`.
Installed bitstream bin remains
`30b0178eb924eb2914bda6300f7ef3f3bef233b48d821ef77bf452349f8beefb`.

At the last capture all native workers and model matrices were closed; the
guest was held in SoC reset after the coherent state/RAM capture. No Vivado
instance was launched for these controls. Board root has very little free
space; diagnostics belong in bounded `/dev/shm` leaves, with sealed exports
retrieved to the external filesystem before pruning anything.

## Next discriminators and fix requirements

The additional one-immediate-byte overflow discriminator is now closed and
independently audited0. It retains every instruction location, all172 parent
payload bytes, JP NT/NT/T/T outcomes and GPR schedules; last-two memory inputs
become80000000. Pinned QEMU and the frozen model check actual flags
`93,93,46,887` for64 cases. Hardware reaches normal64/caller64/checksumd5540
with zero exception record and no BP/STEP. These checks weaken overflow alone
as an explanation; **per-case hardware FLAGS were not scanned**. Its32-job
matrix has the same32 native0,27 consumer0/five coverage-only3 results as the
other new controls. No production input or FPGA image changes.

The deployed **core observation ring is not an instruction/read-beat trace**.
Despite inherited comments, the frozen `ventium_l1_axi.sv:1569` assignment
captures only acknowledged **writes to VGA text page B8000–B8FFF**, with store
data. `rk_ao486_system_pl.v:314` wires that tap, not the available AXI-master
read-beat tap. The ring's populated-count output is unconnected; its reader
always returns the requested128 entries. A ring clear resets head/count but
does not erase BRAM. These private ROMs make no VGA writes, so their exported
`frozen-core-ring.txt` files show stale pre-control text stores, not current
branch or memory-service activity. Do not derive a current FSM state, cache
return, or instruction-byte identity from them. The independent capture audits
do not use those stale entries as correctness evidence. PC retirement ring and
coherent architectural scans are separate, still useful observations.

Similarly, outer AXI counters use global `rst`, **not** guest reset or debug
clear (`rk_ao486_system_pl.v:113`). Their large absolute values cannot be
charged to one private cold run. Performance analysis needs qualified interval
deltas and wrap handling, not mixed counter epochs.

## Private retained-packet observer preparation

Read-only native queries now bind the saved routed checkpoint to actual
physical FF pins. The checkpoint's companion binary is exactly the installed
`30b0178e...` image; checkpoint SHA-256 is
`86ebc6ec9abe6b0bb7dbc93dd7b7d321e0b183b5abc25dd68962c30edb5f50e3`.
The initial packet inventory finds158 U,139 V,32 owner-EIP, eight replicated
active and one pair FF: **338 raw physical bits**, not complete optimized
211-bit RTL structs. Never invent missing fields as zero or infer physical
selector bits from LUT/net aliases bearing similar names.

The R5 binding query closes native0/input-pins0, recording all32 management
read-data FFs, the seven original selector FFs and their replicas, and the
registered ARREADY FF. The R2 control-cone query also closes0/0. Its actual
LUT INITs prove the ARREADY **D input** is `R_IDLE && ARVALID`; the registered
ARREADY **Q output** is too late for a read-data D-input override. All32 old
read-data drivers each feed exactly their one management data FF; no CPU
functional sink is disconnected by the proposed insertion point.

A private observer plan uses181 LUTs, changes only those32 debug-data D inputs,
and adds observation loads to retained FF outputs. Selectors96/97 carry a new
signature/size header;98–108 expose the338 raw bits with an explicit physical
pin catalogue;109–127 return zero. Selectors0–95 and every non-2B0 CSR read
must remain transparent. Original FF clock, enable, reset and CPU control
connections are untouched. These selectors are **not available on the board
yet**, and this is not a functional processor repair.

Finite logic checks pass10,016 primitive truth cases,45,568 scan-bank cases,
1,048,576 address/selector/acceptance cases, and6,144 read-phase cases. A
separate consumer checks the actual native control cone over131,072 cases,
all eight external ARVALID source combinations, and32 exclusive old-data
sinks. These are observer-contract checks, not core differential gates or
timedemo acceptance. Two earlier offline consumer failures (record-kind and
active-register spelling) are retained; the separately named R3 plan passes.
The control-cone route inventory also explicitly has **ACTIVE count0** because
its pattern omitted `_q`; the eight active FFs remain bound by the independent
packet inventory. That route inventory alone is not a complete ECO proof.

Routing must preserve original branches on newly tapped, partially routed
nets: `route_design -preserve` alone protects only completed routes. Use
appropriate `FIXED_ROUTE` sections and verify physical preservation, as
documented by [AMD's route command reference](https://docs.amd.com/r/en-US/ug835-vivado-tcl-commands/route_design).
Only the32 old debug-data routes may be replaced; they have no other sink.
The private construction stage is bounded and produces no bitstream or board
deployment. Placement/routing, unchanged original-function/route evidence,
and private hardware controls are still required before using a new observer.

Sealed query artifacts under the external temporary root:
`ventium-debugscan-binding-r5.Zoz4qk` (closed manifest SHA-256
`f69dd3db4bf2317568516ace49af5d189764707545bebc6189676bac8de9e314`);
`ventium-debugscan-controlcone-r2.bo8imT` (
`f25637a50f81985f45db0f3b3b35db7eac674c2aa996f7cbe54211f7ce394c9b`);
`ventium-debugscan-contract.siewqF` (closed logic manifest
`ea1097c482bf158a959daf5b5b1b121628a540bf83d9f5e6b8d6b996a82007d2`).
Failed native query receipts are preserved separately; their checkpoints and
source pins remain unchanged. All native invocations use the sole-instance
guard, explicit external TMPDIR, resident-memory/swap/task limits and deadlines.

Construction attempts R1/R2 fail safely on native `LOCK_PINS` handling; R3–R5
reach their deadlines during route-guard preparation, **before creating any
observer cell or reconnecting any input**. All close native1/input-pins0 and
produce no new checkpoint, bitstream or deployment. R5 records390 sources and
1,884 affected old LUTs; its source-binding and lock-collection stages take
75.2s and242.2s respectively. These are tool-script failures, not DUT failures.
The original checkpoint and installed board image remain unchanged.

A separately checked constant-free observer graph removes132 GND/VCC input
edges by LUT cofactoring without changing the181-LUT bank or its338-bit
catalogue. It passes7,024 local exhaustive cases,45,568 bank cases and4,096
random envelope comparisons against the original plan. It avoids adding
loads to chip-global constant nets. Artifact:
`ventium-debugscan-cofactor.axp8n9/checks/`, native-plan SHA-256
`721a0795fcbba0f798dcc4801e28b8f6c8c75871ddaed889e052441284a3b590`.
The R6 constructor batches native property reads and identical per-cell
constraints; a mock-native check covers1,884 cells and rejects an incompatible
pre-existing lock without mutation. Its540s outer/510s inner deadline also
expires: native1/input-pins0, no added cell, reconnect, checkpoint or deployment.
Its mapping collection takes378.1s;1,350 guard rows are written before the
deadline. The mock did not reproduce native large-dictionary access overhead, so
this attempt is not evidence of a faster implementation.

A separate **read-only** native cost query closes0/0 in41.7s. Looking up50
native Vivado handles in the large cell dictionary and grouping them costs
2,016ms, versus0ms at millisecond resolution for grouping ordinary names.
A291-pin batch BEL query takes1ms;
the ordinary pin's `BEL` property is blank and **cannot** substitute for the
actual BEL-pin relation. Preserve exact native bindings; optimize bookkeeping
representations rather than weakening route guards. Sealed query:
`ventium-debugscan-query-cost.iWjcup/closed-query.sha256`.

The follow-up R3 native query closes0/0 in45.3s and corrects the initial
attribution: **large dictionary access**, not native handles themselves,
dominates these loops. Fifty cached REF lookups cost1,121ms with native
property elements and1,105ms after flattening them to ordinary strings.
The same fifty REF lookups through Tcl arrays, grouping their native handles,
and the native batch-property query each take0ms at millisecond resolution;
exact counts are checked. R2 retains native1/input-pins0 after an attempted
escaped-name lookup resolves no cells; it is not a passed complete query.
R7 replaces only the large cell/pin/snapshot dictionaries with arrays and
retains all actual binding, old-function/placement and route checks. These
host-script timings are **not** processor IPC or an FPGA performance gain.
Sealed successful query: `ventium-debugscan-query-cost-r3.bMwm08/closed-query.sha256`.

**R7 construction passes native0/input-pins0** and an independent closed-output
consumer. Guard collection finishes44.6s after entry, compared with378.1s in
R6; all connections finish56.9s after entry. The actual native graph checks181
new LUTs and889 input bindings, exactly32 debug-data D reconnects, unchanged
297,336 original primitives (reference/placement/old LUT function), and390
preserved original source groups. The3,794 affected original LUT input pins
are locked without moving any original cell. Output:
`ventium-debugscan-eco-build-r7.wfwxcG/native-output/scan_added_unplaced.dcp`,
SHA-256 `a4263464dd7e22d5cb031aae6463b027ae2e58dbede2ad653cfe3142617587e2`.
This is explicitly **unplaced/unrouted, not a bitstream or hardware repair**.
The first placement-only attempt fails before placing any cell: the native
help's `IS_OCCUPIED` example is not supported on this device's BEL objects.
That failed receipt is retained. R2 instead verifies vacancy through actual
BEL-to-cell relationships, empty SLICEL-site properties and the original cell
location inventory. **R2 placement passes native0/input-pins0:** all181 new
LUTs occupy separate empty sites, with889 verified physical input mappings.
All297,336 original primitive functions/placements and390 source routes remain
unchanged. Output:
`ventium-debugscan-place-r2.Y1ePCR/native-output/scan_added_placed_unrouted.dcp`,
SHA-256 `56eaac75640413090d9830b0c0434d496a024f6d2da6ece5f73972a6ddc14627`.
This is **placed but unrouted**, not a deployable bitstream. A separate bounded
affected-net routing script checks preserved original branch resources and
untouched routes. Its closed-placement consumer passes; the native routing
attempt is now running with one thread, an8GiB/no-swap cgroup and a540s outer
deadline. It is not yet accepted and cannot generate a bitstream or deploy.

The private reader at `ventium-private-scan-reader.tLwjM1/read_scan.py`
requires an already-quiescent, **non-frozen** core, the original execution-debug
capability, and the new bank signature/metadata. It writes only the selector
CSR and restores the previous selector on success or failure. Two complete
scan reads and before/after architectural scans must agree. It rejects an old
image before interpreting packet words, checks all unused bits/selectors,
and reports missing optimized packet fields as unknown. A retained owner EIP
other than `14562` is explicitly not attributable to the failing CMP.
Eight fake-MMIO tests pass, including338 one-hot physical-bit checks, four
no-write precondition rejections and nine post-write safety/coherence failure
cases. These are **offline tests only**: the new observer and reader have not
yet been qualified on the board.

Obtain causally useful retained-packet/next-PC evidence before selecting
a general fix. Do not disable pairing, single-step production Quake, suppress
faults, or patch its allocator to manufacture completion. Any eventual major
core/cache change must pass differential gates and the entire standard suite:
both CoreMark correctness seeds, Win95 boot-to-desktop, and completed Quake
timedemo. A 64-case private pass does not discharge that requirement.
