# FPGA memory-CMP/conditional-branch localization — 2026-10-05 UTC

Production Quake timedemo and the requested complete 15 fps movie remain
**pending**. These are private cold diagnostics, not patched production Quake,
save-state repairs, or acceptance substitutes. The original control runs did
not change the installed FPGA image, clock, RTL, production BIOS or disk.
On October6 the preserved debug-only observer image was deployed, as recorded
below; it does not implement a processor fix. Production BIOS/disk and RTL
remain unchanged by this investigation.

Current candidate gameplay IPC: **unmeasured**. Verified pre-candidate baseline:
**0.42633263**, build `5c2491f3`, cycles
**7,099,999,637–7,199,999,637**. Last measured physical core clock was
**39.999877 MHz** on the observer image; the PS PL source is100 MHz, not the
core frequency. This held-reset clock sample has zero retirements and is not
a gameplay IPC measurement or timing sign-off.

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
bits, next-PC mux input, or FPGA cache contents had been read in this original
capture**. The later observer capture is described separately below. Its legacy
`lin=` selector-times16 display is wrong for this protected-mode hidden base;
use the captured hidden descriptor, not that display.

## October6 observer capture: preserved defect, inactive older packet

The deployed observer image reproduces the original wrong architectural EIP
**14566**, FLAGS887, CR2zero, last primary retirement14562 and
count2/caller3/checksum9fff before ADC/#PF. The original JP ROM, code bytes,
guest mappings and operands are unchanged; there is no STEP, intended-V
breakpoint, guest-memory repair or processor RTL fix. Reset and parked scans
both satisfy the signature, metadata, two-read coherence and selector-restore
protocol. Native invocation `4b1cc1fe7f9c4690a75728bf282c0dae` closes0 and
the independent host audit verifies all42 exported files and the architectural
and physical-RAM context.

The338-bit physical scan is **not the failing packet**. Retained owner EIP is
**14558**, all eight ACTIVE copies are0 and the retained PAIR bit is1. The
decoded known fields match the earlier `CMP [EDX+8],ECX; JNE +1d` in the
captured instruction bytes: U length low bits3, memory displacement8,
memory-left CMP; V length low bits2, condition5 and displacement1d. Unlisted
optimized fields, including length bit3, remain unknown. The failed CMP at
14562 instead uses displacement10 and JP conditionA/displacement13. Do not
attribute the retained V condition/length/target to that later CMP.

In the frozen RTL, ACTIVE0 selects the live `u_d/v_d` descriptors rather than
the retained packet (`core.sv:6155`). Retention is engaged when a new memory
request must wait (`core.sv:7473`). The parked observation therefore narrows
the missing evidence to the live/immediate-response execution path; it does
not by itself prove which dynamic packet selected the bad PC on the preceding
edge. No stale-packet-consumption, decoder, cache or next-PC root cause is
claimed. The OR and reversed-overflow passing controls are rerun on the
observer image below; they do not make this older packet attributable to the
failing CMP.

Evidence:
`ventium-private-observer-boundary.cj7i9A/exception-log-XEIuht-export/closed-capture.sha256`,
SHA-256 `c179ded78eec8103afe366b9c5aad730cc5e3c1272bab5e024e66def6c0b2aee`;
independent `audit-result.json` and `closed-audit.sha256` (SHA-256
`a7c6d0e6325a69becba638d3df8ab68c3a43e4c0a5567138e3a6927e3e027f51`).
This qualifies a coherent retained-state read at the reproduced private fault,
not a complete internal-state dump, ISA gate or completed Quake timedemo.

Both original passing controls also complete64 cases on the same observer
image: count64/caller64/checksumd5540, normal AL42/exit-HLT context and an
entirely zero104-byte exception record. Each closes native0/controller0,
retains the original ROM and production pins, and passes coherent reset and
terminal scans before late forensic reset. No STEP or breakpoint is used.
The independent host consumer verifies39 exported files per run and their
separate native invocations:

| Observer-image control | Native invocation | Closed-capture SHA-256 |
| --- | --- | --- |
| OR/JP | `917b3fd4d0db41fbbfdebb86f2dee47e` | `785625108da3f5ff8692d3d13baf56fd82e0efdef33aae1f3501b8fc50d4e6b0` |
| Reversed CMP/JP, overflow discriminator | `95699908015643d3a2e13e5af36c54cc` | `405af9f51b09efad2b0af9980645e3cc4c05db750bd2f1b050086496e4c10358` |

Artifacts are under `ventium-private-observer-controls.BFWmEY/`; the independent
consumer prints `PASS_PRIVATE_OBSERVER_CONTROLS_ONLY` and its sealed audit is
`closed-audit.sha256`, SHA-256
`4f9b8be7673ccd4420a615747ac462af07c2222cf792f7dbed0e660d5129c98d`.
The observer preserves the failing-case/passing-control distinction in these
tests. It is still not a processor repair or standard-suite acceptance.

To bound board RAM-disk usage, only the older closed `9loTuZ` run and its
duplicate export are removed after checking all35 sealed files, the exact
closed native invocation and the kept VHD seed. This recovers53,415,936 bytes;
full recoverable evidence remains at
`ventium-private-reversecmp-overflow.o9SjbO/exception-log-9loTuZ-export` on
the host. Production media, the original rollback BIN and the new observer
captures remain untouched.

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
untouched routes. Its closed-placement consumer passes. Initial native
attempts reject `-eco -nets` and `-preserve -nets` combinations **before any
routing**; both retain native1/input-pins0 and separate sealed receipts.
A bare no-project check closes0 but is inconclusive: every command requires
an open project. A disposable two-cell design then proves
`route_design -no_psir -nets` actually routes its selected net, while confirming
both incompatible combinations. That toy pass is not a processor gate.

R3 uses the accepted command with one thread, an8GiB/no-swap cgroup and a540s
outer deadline. Before routing it verifies415,680 unchanged physical roots,
reusing the pinned1,459,317,012-byte baseline instead of creating another copy.
The router runs52s but **fails native1/input-pins0**:21 unrouted nets and five
node overlaps. Five specific fixed address-net branches conflict with debug
read-data FF D inputs. Most reported blockages are override-output routes to
those debug FFs; one tapped core FF, `pipe_mem_u_q_reg[mem_disp][15]`, also
cannot reach the new observer LUT within the router's local search. The
post-failure DRC's zero errors does **not** override the failed route verdict.
No output checkpoint, bitstream or board deployment is produced. Preserve
`ventium-debugscan-route-r3.ZIbEj4/closed-routing.sha256`
(`f9cc971bedc05cffb5d94e60fffd09fa01bf2df3f316ea436ee1384f4a60da1e`).
Inspect the local physical wiring before another layout attempt; do not unlock
CPU routes or move CPU cells to manufacture observer routability.

A read-only footprint query closes native0/input-pins0. The blocked core tap
already reaches the `G6LUT/A2` input at `SLICE_X108Y209`; the adjacent G5 LUT
is vacant. Its existing G6 LUT is a conditional function, not a raw-bit buffer,
so that output cannot substitute for the observation. The proposed identity
buffer shares the already-routed A2 input instead. All32 management read-data
FF Q outputs have exactly one leaf consumer: the PS AXI response FIFO. There
are43 vacant LUT/FF pairs in slice halves containing a management FF with the
same clock, enable and active-low synchronous reset. Footprint receipt:
`ventium-debugscan-footprint.ECaRiY/closed-query.sha256`.

The revised adapter restores the32 legacy management FF D connections and
adds32 shadow response FFs, relocating only the new override LUTs beside them.
It retains the original response clock, enable, reset polarity and latency;
only the unused private scan selectors can change the returned word. The
identity buffer increases the observer to182 LUTs/890 input connections, with
the same338-bit catalogue. Offline checks pass43,520 bank cases,4,096 random
envelopes, two buffer truth cases and768 register-transition cases. These are
algebraic checks, not hardware qualification. Inputs and proof are under
`ventium-debugscan-shadow.99S7OI`.

The first native adapter attempt passes all32 control/polarity and exclusive
consumer preflights, then fails when a new wire would cross the protected
SoC hierarchy: native1/input-pins0, no output checkpoint or deployment.
Receipt: `ventium-debugscan-shadow-build.9p5jxq/closed-adaptation.sha256`
(`5cde42b748e390ff165400f4d97528c3976839ac4a70f330565a4e8e88a74db3`).
The follow-up reuses each existing hierarchy-crossing response wire and
changes only its source inside the management block. It does not clear
hierarchy protection or relocate original cells. R2 gets through all32
connection changes but placement rejects bit22: its vacant H6 LUT shares
inputs with an occupied H5 LUT. That failure is retained separately
(`ventium-debugscan-shadow-build-r2.AVq2Bq/closed-adaptation.sha256`,
`0242d074220a28558bf01827a685e50f508d6e0e09a258425597c3644a3f4a5b`).
The corrected inventory excludes occupied halves and finds42 complete pairs.
The same offline proof passes again under `ventium-debugscan-shadow-r3.mqjfbk`.

**R3 adapter placement passes native0/input-pins0**:297,336 original
primitive functions/placements unchanged,182 new LUTs,32 shadow FDREs,
890 verified logical/physical LUT input bindings, all32 legacy D connections
restored and exactly32 exclusive response-wire sources replaced. All32
shadow clock/enable/reset polarities match their legacy FFs, and all358
protected original source routes remain unchanged. The G5 buffer shares the
old G6 A2 input without changing that original LUT's mapping or function.
An independent closed-output consumer passes after correcting its own Tcl
carriage-return escape in an expected name; the failed consumer receipt is
retained and was not a native implementation failure. Placed **unrouted** DCP:
`ventium-debugscan-shadow-build-r3.UxQzHt/native-output/scan_shadow_placed_UNQUALIFIED.dcp`,
SHA-256 `be6049fa2e45c2d67fc286ad93240e1dee64d8d0bb53a66acabb70310dd1f8c7`.
Closed adaptation manifest:
`dc04067343c2c88649d917267f94d163f32634e513f35c42eb806c5ddf53462d`.
Routing qualification, a bitstream and board validation remain outstanding.

The shadow routing attempt checks415,645 unaffected physical roots against
the original baseline; all match. Its explicit exceptions are32 response
wires plus the common clock/enable/reset nets, whose original branch
resources are protected. It selects607 roots,361 protected source branches,
and removes only the32 obsolete response route trees before routing. Native
binding identifies the management FF clock as the core MMCM output, not a
separate assumed PS clock. The router remains near ten overlaps and hits its
540s deadline: native124/input-pins0, no output checkpoint or bitstream, scope
inactive and vendor process family gone. This is **not** route qualification.
Sealed attempt: `ventium-debugscan-shadow-route.fm39e5/closed-routing.sha256`,
`9f9635568da0b5175033b97ca4fa23b16501a4227763f7aba4b7fcd6c50873ea`.
Next inspect conflict details in a diagnostic copy rather than repeating
automatic routing or relaxing processor protections. The installed image
remains unchanged.

The bounded diagnostic copy closes native0/input-pins0, but is **not** route
qualification. Its full reports identify95 nets affected by invalid sites,
despite `report_route_status -return_nets -route_type CONFLICTS` returning an
empty list. DRC identifies two PDIL-1 errors: `SLICE_X20Y199/A6LUT` and
`SLICE_X24Y191/F6LUT` are logically vacant but already implement constant
route-throughs. Placing override bits20 and10 there conflicts with the old
physical configuration. Logical BEL-to-cell vacancy alone is insufficient;
future placement must also account for physical routing resources, and full
route/DRC reports remain mandatory.

Packing the local identity buffer beside its old G6 LUT also introduces one
physical-only VCC connection, reported at `INT_X73Y209/IMUX_W46`. The logical
observer plan has no explicit constant input, but that does **not** imply zero
physical constant-routing work after packing. Account for the new connection
explicitly without relaxing protections on original constant branches. The
diagnostic removes only32 obsolete response routes; all297,336 original
primitive functions/placements and361 protected source routes remain
unchanged. Diagnostic checkpoint (not deployable):
`ventium-debugscan-shadow-conflicts.AFIe4U/native-output/scan_shadow_debug_unrouted_DIAGNOSTIC.dcp`,
SHA-256 `5b78ace21230c9ef76b188a982cce03fdcfdf08b21e9276a0778d5046522d5df`.
Sealed diagnostic manifest:
`880bcfde6c96931254c47ffd986a487752e753cb6927f44a25a6a19645d0edab`.
No board programming, clock change or production Quake run follows this
diagnostic. A separate read-only native resource query is the next step.

That read-only query closes native0/input-pins0 in93.6s; an independent
closed-output consumer passes. Native `BEL.IS_USED` identifies exactly the
two route-through LUTs;40 of the42 logically vacant complete pairs remain
available. The output site pins' `IS_USED` flags are zero even for those two
route-throughs, so those flags cannot substitute for BEL configuration checks.
The query also inventories471 logical constant groups (228 POWER,243 GROUND)
sharing the two physical constant trees. `get_nets GLOBAL_LOGIC0/1` finds no
ordinary net object. Sealed query:
`ventium-debugscan-routeaware-query.2tDvQ7/closed-query.sha256`,
SHA-256 `0e70cc46a0d26adf6ff2340b6f68410b9ceb78a4b3e33231a59977a14ae01d25`.

R4 uses that physical inventory, repeats the unchanged offline bank/transition
proof, and checks both LUT halves plus both FF BELs before placement. Native
placement closes0/0 with the original297,336 primitive functions/placements
unchanged. The explicit, waiver-free PDIL-1 check reports zero violations;
an independent consumer checks the full report and excludes both conflicting
BELs. Output remains **placed, unrouted, not deployable**:
`ventium-debugscan-shadow-build-r4.7xf3Ok/native-output/scan_shadow_placed_UNQUALIFIED.dcp`,
SHA-256 `d0c77bc5b977bbcd4af9fd239712cd74a7e24fdf98ccc46b9dedb1dd86f9374f`.
Sealed placement manifest:
`b7f0f5825fdb388369f1ebbfc1ca65c0e3c7dd64d804ff79364af82bea8a3517`.
The next bounded route explicitly handles both physical constant trees,
preserves original branch resources and GND's exact route, checks all471
aliases, and saves a diagnostic checkpoint before routing. Twelve offline
guard tests pass, including rejection of removed old nodes/PIPs, changed GND,
inconsistent aliases and incomplete routes. These are guard tests, not DUT or
route-qualification results. No board image changes on these results alone.

That route attempt closes native124/input-pins0 at its540s deadline. Its
preflight verifies415,174 unaffected routes exactly, plus all471 original
constant aliases. Native protection covers106,722 GND nodes/103,141 PIPs and
70,881 VCC nodes/57,944 PIPs. The physical-constant route succeeds with zero
warnings/errors: GND remains exact, all old resources remain present, and VCC
gains exactly one node and one PIP. The separate607-net observer route still
oscillates around7–8 overlaps. It is **not qualified**; no bitstream or board
programming follows. The sole vendor scope closes inactive without OOM.
Sealed attempt:
`ventium-debugscan-shadow-route-r2.MSsmAL/closed-routing.sha256`,
SHA-256 `5d396e896a23b68060e7e2300fd4dea099284dabb12d8741d8354dea530e9c97`.
Its prepared diagnostic checkpoint is saved **before** either router pass:
`native-output/scan_shadow_route_prepared_UNQUALIFIED.dcp`, SHA-256
`d33b004e5678c027f04030be50899e16c7ef3e775fa962730558bbce1a3fbc98`.
Do not claim that saved checkpoint contains the later successful VCC extension.

Control-group follow-up: bit11's selected primary `EFF` at `SLICE_X14Y206`
has a secondary `HFF2` peer. They share the clock/reset half but not the CE
group. Same-half matching alone does not prove enable routability:
[AMD's UltraScale CLB guide](https://docs.amd.com/r/en-US/ug574-ultrascale-clb/Clock-Enables)
documents distinct primary/secondary CE groups. This is a **hypothesis** for
the remaining route blockage, not yet a confirmed cause. The read-only native
query captures all 32 new/peer control-pin mappings and the 64 FFs occupying
their 20 selected sites. Bit 11 uses `CKEN3`; its old `HFF2` peer uses `CKEN4`.
The clock/reset mappings match, and no old primary FF occupies that upper
half. The difference alone is therefore not evidence of a conflict.

That query closes native1/input-pins0 because its final `-to_load` report
requests an enable target absent from the existing route tree. Keep it as a
**partial query**, not a native pass. Sealed partial evidence:
`ventium-debugscan-controlgroups.HCFbdp/closed-partial-query.sha256`,
SHA-256 `bdd47e794419969644a972396bc62e0737cadd7eb0549faa76622ba1ab5bf6d3`.

The subsequent one-pin diagnostic closes native0/input-pins0. Routing only
the new bit 11 CE pin with PSIR disabled succeeds in 38 s with no warnings or
errors. Its native full enable-net report says ROUTED; the target
`INT_X10Y206/CTRL_W2` is present. All 247 old CE nodes/246 PIPs remain, with
exactly one new node/PIP. All 297,336 original primitive functions/placements
and the enable's logical sinks remain unchanged; waiver-free PDIL-1 is zero.
The enable-group difference does **not** explain the remaining routing stall.
The first independent consumer rejects a mistyped expected baseline hash;
the corrected consumer passes without changing the closed native evidence.
Sealed native diagnostic:
`ventium-debugscan-bit11-enable.P1jmVE/closed-enable.sha256`, SHA-256
`b3e44533e49351d63393fdc99658c41e6aeb1c50fb2e98a17c9bfc2385a938a6`.
Corrected closed-consumer manifest:
`41e853c1bfb4b0bf4a1a01c4fc96937a177a3c8b53edc0ae9e29146472c08ab6`.
Its saved `native-output/scan_one_enable_DIAGNOSTIC.dcp` has SHA-256
`21380ad3fb9b7c2ff03d710718b088423c0d049ad3dce4a99597c8d613debd36`.
It is **not** a complete routed or deployable design: only that enable branch
is qualified, not all unaffected routes or the observer. Next separate the 214
new observer/response nets from the original-source tap branches to localize
the remaining blockage. No synthesis, board programming, clock change or
production Quake run occurs on these diagnostic results.

Routing just the 214 new observer/response nets, without selecting any
protected original net, falls from 18 overlaps to one and stalls. A SIGINT to
the exact private Vivado PID cancels both `route_design` and its entire Tcl
source; the script's catch does not run. Native1/input-pins0 closes with **no
saved output checkpoint**. The router's cancellation-time DRC reports zero
errors, but that is not routing completion. Sealed attempt:
`ventium-debugscan-freshnets.pmb1NZ/closed-routing.sha256`, SHA-256
`4bc5e359edd0215c39b35e34efbdf684e7ee9ac1d847cfbfcbd4610cdb32a4d0`.
Save completed stages before a later router call; do not assume cancellation
will permit post-route checkpoint/report commands to execute.

The staged follow-up first routes the physical constants successfully, checks
all old constant nodes/PIPs, verifies GND's exact route, and verifies exactly
one new VCC node/PIP at `INT_X73Y209/IMUX_W46`. All 297,336 old primitive
functions/placements remain unchanged. It saves the completed constant stage
before trying the other 213 fresh nets, excluding `local_ff_buffer/O`.
That 213-net route also stalls at one overlap and is canceled; the exclusion
does not remove the blockage. Native1/input-pins0 closes; no 213-net result
is accepted. The earlier saved stage survives:
`ventium-debugscan-freshsplit.4KMxem/native-output/scan_constants_DIAGNOSTIC.dcp`,
SHA-256 `e1e49c6380f3f18e542506f28f87b1ca6b3f1c1bdb903f1db0d66e80c1d8e734`.
Sealed attempt: `ventium-debugscan-freshsplit.4KMxem/closed-routing.sha256`,
SHA-256 `46c4ffccfb50662930a9cb4d2750fb229d49aecdd7fb047762dca42ed82d262d`.
An independent consumer accepts only that preceding constant stage for
further diagnostics, explicitly not route or hardware acceptance. Next query
the actual used site routing resources and native router parameter inventory
without mutating this saved design. No further combined automatic pass or
processor-route relaxation is justified by these results.

The read-only resource query closes native0/input-pins0 in 57.6 s, enumerating
all 214 new outputs across 170 sites and their used site PIPs. It writes no
design checkpoint. Sealed query:
`ventium-debugscan-routeparams.6B5Xar/closed-query.sha256`, SHA-256
`18dd337fce7f71fe5d5cf137f724e2f2688d6cf3a5e4c18126698620ebd37b47`.
Separate native-help/report queries confirm 17 public parameters, none a
routing iteration limit; `report_param *route*` exposes no matching parameter.
Do not invent or set an undocumented iteration knob. Native help also
confirms that `-no_psir` disables **physical synthesis in the router**, not
site-internal routing. Keep it enabled; no processor synthesis optimization
is authorized as part of this observer-routing diagnostic.

The response-only follow-up closes native0/input-pins0. All 32 replacement
debug-response wires route in 32 s with zero final overlaps and no
warnings/errors. All 297,336 original primitive functions/placements, all 32
shadow-FF configurations and exclusive response sinks remain unchanged;
waiver-free PDIL-1 is zero. An independent consumer accepts only this
completed diagnostic stage, not the full design. Sealed attempt:
`ventium-debugscan-responses.zglMyD/closed-routing.sha256`, SHA-256
`16d2864f05e7a6b215e868f3814acfaedc7af6d6d66d3f3ca0c5ed86b8755e07`.
Saved `native-output/scan_responses_DIAGNOSTIC.dcp` has SHA-256
`97b4a41b5289c71ff4c3f8fc7fff53127c04f7fd766821852ba0d797381a323b`.
The next staged pass preserves those completed response routes and separates
32 final word muxes, three shared controls and 114 lower-level LUT nets,
saving each completed stage before proceeding. The observer remains
**unqualified and undeployed**; the production timedemo has not been restarted.

The first word-mux group still stalls at one overlap; that canceled attempt
does not produce a completed stage. Sealed attempt:
`ventium-debugscan-lutnetwork.1e21hj/closed-routing.sha256`, SHA-256
`5e13b34e18709d8a71fa985ee7a8b628e7917d361ae404620299125a9c66110f`.
An individual-pin pass then routes bits 0–6 successfully and naturally fails
at bit 7. Native reports a potential placement issue on
`word16_7/O` (`SLICE_X101Y188/A6LUT`) → `rdata_override_7/I1`
(`SLICE_X21Y196/B6LUT`, physical input `B2`, node `INT_X14Y196/IMUX_E9`).
Its failure-time zero-error DRC is not a routing pass. The native failure
closes input-pins0 and executes the final input-preservation checks. Sealed
attempt: `ventium-debugscan-wordpins.UsTX0t/closed-routing.sha256`, SHA-256
`0075571b02648491d9ad4b195d8a11c3784ee5e9b991cbafd6d970bb7ee8ed7e`.
Only the preceding checkpoint through bit 3 was saved; it does **not** contain
the later successful bits 4–6:
`native-output/scan_word_through_03_DIAGNOSTIC.dcp`, SHA-256
`d25ea021ca3e3006cae6a2a8e39d3a3929b4e0110f19aa7629ad15727a00593a`.

A read-only endpoint inventory closes native0/input-pins0 and its independent
consumer passes. Sealed query:
`ventium-debugscan-word7-resources.KKgpxY/closed-query.sha256`, SHA-256
`45f54a25bde816baa6d549f20ad5b6257beedaa5f17f98794aa180046d161df5`.
The source slice contains only the new word-7 LUT, has no used site PIPs,
and has a physically unused/unreserved/non-prohibited B6 LUT. This is a safe
observer-only placement candidate, **not** proof that its interconnect exits
are free. The initial site-pin neighbor query returns the endpoint nodes
themselves; it is not accepted as a routing-resource ownership proof.
Actual neighboring interconnect nodes are queried from those node objects
in the subsequent one-LUT diagnostic. Do not confuse logical vacancy, BEL
vacancy, and end-to-end routing feasibility.

Moving only new `word16_7` from A6 to B6 in the same source slice fixes its
single-pin route in 38 s (native0, ROUTED). The LUT INIT, locked logical pin
mapping and target remain identical. All 297,336 original primitive functions
and placements, all 214 observer configurations except that one BEL, the 32
completed response routes, and word routes 0–3 remain unchanged. The completed
stage is saved before the next router call:
`ventium-debugscan-word7-onefix.wEMoyB/native-output/scan_word7_source_B6_DIAGNOSTIC.dcp`,
SHA-256 `b68ed36bb156a6632c8554417ddebd7f185f35fd12aa04cb3819f45200f6147f`.

The remaining 27-word batch then naturally fails at another placement-blocked
connection: `word16_16/O` (`SLICE_X114Y197/A6LUT`) →
`rdata_override_16/I1` (`SLICE_X25Y189/B2`). The whole attempt closes
native1/input-pins0, not a 32-word pass. Its independent consumer accepts only
the earlier saved five-word stage (0–3 and 7) for further diagnostics. Sealed
attempt: `ventium-debugscan-word7-onefix.wEMoyB/closed-routing.sha256`,
SHA-256 `99a22150a8973b71ecaa5d6a41807bcfd881cf4ca796c205bacbd7cb84336538`.
The same guarded source A6→B6 relocation does **not** fix bit 16. That attempt
closes native1/input-pins0 without an output checkpoint and is discarded:
`ventium-debugscan-word16-onefix.qsAmmK/closed-routing.sha256`, SHA-256
`4e2c52558b13ee6947e7d10a7c5cd7b4b6ce5d12b276c715545df6bc282f5abc`.
Subsequent attempts return to the saved bit-7 checkpoint, keeping source16
at its original A6 placement.

The first target-pin remapping attempt is rejected by Vivado before routing:
changing `LOCK_PINS` on an already-placed, locked LUT requires unplacing it,
clearing the old lock, setting the new lock and replacing it. This is a
native API failure, not a routing pass. Its closed rejected manifest is
`ventium-debugscan-word16-pinfix.p9rf2C/closed-rejected-pin-update.sha256`, SHA-256
`1ee43483a77bf24d0924093b92e7a33b19ec4269765100641f98cddb83c44223`.

The corrected attempt unplaces **only** the new `rdata_override_16` observer
LUT, remaps logical I1 from physical A2 to A5, then replaces the LUT at the
same `SLICE_X25Y189/B6LUT`. Its logical INIT `16'h0ACA`, connectivity and
all other pin mappings remain unchanged. B5 shared-input resource vacancy is
checked first. The new endpoint is site pin B5 / node
`INT_X17Y189/IMUX_W27`; the old B2 endpoint used `IMUX_W9`. No processor cell
is unplaced, moved or unlocked. Bit16 now routes successfully, followed by
all remaining26 word connections.

This attempt closes native0/input-pins0 with all32 word connections routed,
PDIL-1 violations0, all297,336 original primitive functions/placements
unchanged, all32 response routes unchanged, and all214 observer configurations
unchanged except the explicitly checked I1 pin map. The independent consumer
prints `PASS_OBSERVER_WORDS_ONLY_NO_FULL_ROUTE_OR_HARDWARE_ACCEPTANCE`.
Saved checkpoint:
`ventium-debugscan-word16-pinfix-r2.vAieNW/native-output/scan_all_words_DIAGNOSTIC.dcp`,
SHA-256 `490de3a4a405274f5a67a230ae9d45fb99ece6f42598e3ef128dc5fc7d7e20e8`.
Sealed attempt: `ventium-debugscan-word16-pinfix-r2.vAieNW/closed-routing.sha256`,
SHA-256 `a00d1eea4622acea7211429c8a2e62d09763e2fc4137cecc91e4ef55b3d4d32b`.

These changes address **observer routing, not the silicon CMP/branch defect**.
The next stage protects all64 completed response/word routes and successfully
routes the three new control outputs and114 lower mux outputs, saving each
stage before the next router call. It closes native0/input-pins0; the independent
consumer prints `PASS_CONTROL_LOWER_STAGES_ONLY_NO_FULL_ROUTE_OR_HARDWARE_ACCEPTANCE`.
All297,336 original primitive functions/placements, all214 observer
configurations and all64 completed routes remain unchanged; PDIL-1 is0.
Saved lower-stage checkpoint:
`ventium-debugscan-lowerstage.9UEvMx/native-output/scan_lower_DIAGNOSTIC.dcp`,
SHA-256 `ce2753305b3f7e60d73f6ea3707e67d045b9e8e8bfe3c4215836f363295828f5`.
Sealed attempt: `ventium-debugscan-lowerstage.9UEvMx/closed-routing.sha256`,
SHA-256 `8d03f3f4c54ea4a6fd6c5f1f72ad510d6bbccd75ac9b3c350efc9581c09c243c`.

The complete native route report is still incomplete:34 unrouted nets and356
nets with unrouted pins, including the new address/control/tap inputs. A
staged mux-output pass is **not** a full routing pass. The next guarded attempt
protects all213 completed observer outputs (including32 local intrasite
outputs), the inherited physical constant trees, original source branches and
all unaffected original routes. It routes only pending original-source taps
and the new local buffer output, then requires full native route booleans,
full DRC and the complete original-route/resource/logical guards. No
full-route, timing, hardware or gameplay acceptance is yet claimed, and no new
image has been deployed.

The net-wide tap attempt verifies all415,174 unaffected original routes before
routing, protects the213 completed observer outputs, and saves its prepared
checkpoint. Routing390 pending source nets then stalls at seven overlaps;
the exact private Vivado process is interrupted, not left running. It closes
native1/input-pins0. Its pre-router checkpoint is diagnostic only, and there
is no accepted post-router result. Sealed attempt:
`ventium-debugscan-tapstage.VyT7YY/closed-routing.sha256`, SHA-256
`84b2775097fca0705b8c89aae68cb6509f07fcbb02ef657dceca62f23a7016e2`.

Pin-directed routing of741 observer/restored-debug inputs avoids that endless
net-wide overlap loop and identifies eight blocked loads across seven nets:

| Original source | New observer load |
| --- | --- |
| `dbg_arch_sel_reg[4]/Q` | `rdata_override_10/I3`, `rdata_override_18/I3` |
| `u_dbg/s_rdata[24]_i_1/O` | `rdata_override_24/I0` |
| `u_mgmt/s_rdata[28]_i_1/O` | `rdata_override_28/I0` |
| `u_mgmt/s_rdata[30]_i_1/O` | `rdata_override_30/I0` |
| `u_dbg/s_rdata[5]_i_1/O` | `rdata_override_5/I0` |
| `u_dbg/s_rdata[7]_i_1/O` | `rdata_override_7/I0` |
| Core retained U `is_nop/Q` | `word4_29_0/I1` |

The native full-route report now has five unrouted nets and two nets with
missing pins:225,195 of225,202 routable nets are complete. The router still
returns failure. Its saved checkpoint is **unqualified**, SHA-256
`5c6b63e245107d1099dc8241017e8e25783fd3540803b27cb25388b501c87995`.
Original primitive/function/placement, protected-source resource, completed
observer-route and constant-tree checks finish, but the550-second construction
deadline expires during the full original-route comparison. The independent
partial/full consumers must reject missing final preservation checks; do not
reuse this failure as a qualified routing pass. Sealed attempt:
`ventium-debugscan-tappins.O4Vwqw/closed-routing.sha256`, SHA-256
`7ec1508c5e80b7f4b188b25b4eae28ab575a0ce4a8d495e24f99413832555a27`.

All eight affected targets are new LUT4s, with two unused logical inputs in
their six-LUT placements. The next test returns to the sealed lower-stage
checkpoint rather than adopting the incompletely audited failure. It first
checks the paired fifth-input BEL's physical vacancy, then remaps only the
blocked logical input to A5 at the same LOC/BEL. Logical INIT, connectivity
and original cells/routes must not change. Nine incident **new observer**
routes may need temporary constraint removal during same-BEL replacement;
their full constraints and all213 completed output routes must be restored
exactly before tap routing continues. No original processor route is unlocked.
This is an observer repair candidate, not a processor fix or hardware pass.

The guarded eight-target remap completes its placement/configuration checks
and restores all213 completed observer outputs exactly. Seven blocked loads
now route; the retained U `is_nop/Q` load still fails at the new A5 endpoint.
The full native report has225,201 of225,202 routable nets complete, one net
with an unrouted pin and no wholly unrouted nets. The remaining connection is
`pipe_mem_u_q_reg[is_nop]/Q` at `SLICE_X106Y203/EQ` to
`word4_29_0/I1` at `SLICE_X115Y196/A5`
(`INT_X77Y196/IMUX_E26`). Its earlier A2 endpoint also failed; this does not
establish whether the source exit or destination entry is responsible.

Unlike the preceding deadline-expired attempt, this attempt completes the
entire preservation audit: all297,336 original primitive functions/placements
and415,174 unaffected original routes match, all607 source/sink groups match,
361 protected source branches retain their resources, both inherited constant
trees match, all890 new input bindings are verified, and all213 completed
observer output routes match. The only observer configuration differences are
the eight explicitly audited logical-input-to-physical-pin remaps; INIT,
connectivity and LOC/BEL do not change. Native closes1/input-pins0. The
independent consumer prints
`PASS_PRESERVED_PARTIAL_DIAGNOSTIC_ONLY_NO_FULL_ROUTE_OR_HARDWARE_ACCEPTANCE`.

This checkpoint is suitable only as the preserved base for the final tap
diagnostic, **not** for bitstream generation or deployment:
`ventium-debugscan-tappins-map8.3dDG0v/native-output/scan_taps_routed_UNQUALIFIED.dcp`,
SHA-256 `f426d3376aa1efc29c7d0498509f2f57acafbd933516162bc75ada3da46e4a84`.
Sealed attempt:
`ventium-debugscan-tappins-map8.3dDG0v/closed-routing.sha256`, SHA-256
`f8fcb832a5aac92b065d292620a1e76e3f887ae9b80a92c542544d7a57237130`.
Next inspect the original NOP source's actual routed receivers/exit and the
remaining target's physical entry resources before selecting a repair. A
duplicate FF with matching D/C/CE/R would not prove observation of the original
retained state and is not an acceptable replacement for that tap.

The first NOP endpoint inventory stops at an invalid net-name equality
assumption, before placement or routing; it closes native1/input-pins0.
Rejected query manifest:
`ventium-debugscan-nop-resources.7PTW3x/closed-rejected-query.sha256`, SHA-256
`7b170b093e75253f6b0891a490456ae8849de5487931e45c64c9ef4aca8f308b`.
The corrected read-only query exposes different hierarchical alias names for
the same physical connection. The target's unique driver is the actual
original U `is_nop/Q`; both aliases report identical ROUTE, FIXED_ROUTE, eight
physical nodes and seven PIPs. Alias names alone are not electrical identity.
Native closes0/input-pins0, and the separate alias-aware consumer passes.
Sealed query:
`ventium-debugscan-nop-resources-r2.ZNDDwj/closed-query.sha256`, SHA-256
`9fb3279e69876e037d835773597dbff2622349808a770927807a3a98d8c7b7b1`.
The initially pinned name-equality consumer is retained unchanged, not silently
edited into a pass. This query failure is not a processor defect.

The source has three original local receivers. Original LUT5
`u_icache/gpr[6][0]_i_31` occupies `SLICE_X106Y203/G6LUT`, with logical INIT
`32'h0000202A` and I0..I4 physically on A1,A5,A3,A4,A2. Its paired G5 BEL is
physically unused/unreserved/non-prohibited, and A5 already carries the true
NOP FF value. The proposed repair adds one identity LUT1 at G5, sharing that
input, and moves **only** the new observer load behind its output. It does not
duplicate a processor register or alter the reader's338-bit catalogue.

The offline proof checks all64 paired-LUT input assignments (32 original O6
cases with A6 high),43,520 scan-bank cases and4,096 random envelopes. The
compatible physical table is `64'h00022022ffff0000`: its low32 bits implement
O5=NOP and its high32 preserve the original O6 function. This requires the
physical G6 A6 input to be tied high; a native placement pass alone does not
discharge that condition. The bounded native ECO must verify the exact physical
VCC extension, original G6 logical INIT and all five physical input
mappings, unchanged original NOP route, all214 existing observer outputs,
the complete original-route audit, full native routing and full DRC before
bitstream generation. Offline proof only:
`ventium-debugscan-nop-buffer.McEzrg/checks/result.json`; native plan SHA-256
`39657e2a6ca9a2b4d3ad796e4faeed3b2d4c0479db258df24a8c71f994a71d6c`.
No image is deployed or hardware acceptance claimed at this point.

The first native NOP-helper attempt passes the exact shared-input/BEL checks
and inserts only that LUT and observer-input splice. The physical-constant
router returns0 with zero overlaps, but the required power-tree footprint
check rejects its result. The inherited GND route and both inherited constant
resource subsets are preserved through that check; this is **not** proof that
the new A6 tie exists. No two-pin signal route, full preservation audit,
accepted checkpoint, bitstream or deployment follows. It closes
native1/input-pins0. Rejected attempt:
`ventium-debugscan-nop-buffer.McEzrg/closed-rejected-constant-footprint.sha256`,
SHA-256 `2cb02b30efa43b42a1a1ded781161b900263f51d3807896174aeb197779fe548`.
The next diagnostic retains the same acceptance condition but saves an
unqualified post-physical-router checkpoint and reports the actual added
nodes/PIPs before rejecting a mismatch. Do not replace the required physical
tie proof with the router's successful exit or the earlier offline truth table.

The saved diagnostic resolves the footprint mismatch: GND is unchanged, and
POWER gains exactly `INT_X71Y203/VCC_WIRE` plus `INT_X71Y203/IMUX_E46`, with
the single PIP `INT_X71Y203/INT.VCC_WIRE->>IMUX_E46`. The required A6 node and
PIP are both present; all inherited resources remain. The correct new power
footprint is70,884 nodes/57,946 PIPs, not70,883/57,946. The earlier TAP76 tie
needed only one additional node because its tile's VCC driver node was already
represented; this tie also needs its local driver node. This is a guard-count
assumption error, not an unexplained processor/resource change.

The diagnostic closes native1/input-pins0, with no full route/hardware pass.
Its independent consumer accepts **only** the exact constant delta and sealed
diagnostic evidence. Checkpoint:
`ventium-debugscan-nop-buffer-r2.XTXcgs/native-output/scan_nop_physical_DIAGNOSTIC.dcp`,
SHA-256 `658970a80f44ed122055c39338117f30f608a3df36b31dc362a0606a442d8343`.
Rejected attempt manifest:
`ventium-debugscan-nop-buffer-r2.XTXcgs/closed-rejected-constant-footprint.sha256`,
SHA-256 `3f0cf0ed76ac7094759301f6f20a4fd43fc6139c2fd234eec0bb705665f1968b`.
The next full guarded attempt returns to the preserved pre-buffer checkpoint
and requires exactly those two added nodes and one added PIP, with no other
constant changes, before routing the two signal inputs and auditing the result.

The corrected full attempt closes **native0/input-pins0**. Both signal pins
route successfully; all225,203 routable nets are fully routed, with zero route
errors. Native `ROUTED_FULLY=1`, `ERRORS_IN_ROUTES=0`; full DRC has zero errors
and zero critical warnings. The lone router warning is the expected empty
`PDIL-1*` violation query, not a waived violation.

The full preservation audit passes:297,336 original primitive configurations/
placements and415,174 unaffected original routes match;361 protected source
branches retain all resources;471 constant aliases are verified against the
original immutable tree data;214 existing observer output routes match.
All608 source/sink groups match the explicitly spliced graph (the NOP source
exchanges only the unrouted observer load for the helper input), and891 new
input bindings are checked. The NOP source's original eight-node/seven-PIP
route is identical, all five original G6 input mappings and its logical INIT
remain identical, and the exact two-node/one-PIP power extension is verified
before and after signal routing. The observer totals183 LUTs/32 shadow FFs;
no processor FF is duplicated and no original route is unlocked.

The independent consumer prints
`PASS_PRIVATE_NOP_BUFFER_FULL_ROUTE_NO_STA_OR_HARDWARE_ACCEPTANCE`.
Full-route-verified checkpoint (the cautious filename remains unchanged):
`ventium-debugscan-nop-buffer-r3.V8pODG/native-output/scan_nop_buffer_routed_UNQUALIFIED.dcp`,
SHA-256 `ab46d01b9ab8562f35b3e2e1ac418bcd0970f2ed765fb568928a052c8347de78`.
Sealed attempt:
`ventium-debugscan-nop-buffer-r3.V8pODG/closed-routing.sha256`, SHA-256
`cf5ece336be88bf4ef31c4e3b56b902a0855d821db41858939b567ebf662b86f`.
This discharges the **observer's physical routing** gate, not timing, hardware,
the CMP/branch defect, gameplay IPC or timedemo acceptance. Generate only the
native raw BIN from this closed checkpoint; do not synthesize/reimplement the
processor, run bootgen or byte-swap the BIN. Board testing must still reproduce
the original failing case and the passing controls before packet attribution.

Native bitstream generation from that closed checkpoint also closes
**native0/input-pins0**. Opening it again confirms full routing, zero route
errors, zero full-DRC errors/critical warnings and the unchanged25 ns core
clock (40 MHz;100 MHz reference). No synthesis, placement, routing or clock
change is performed. `write_bitstream -bin_file` completes with zero warnings,
critical warnings or errors. The raw BIN is20,606,636 bytes, with native sync
`aa995566` at offset80; its `.bit.bin` copy is byte-identical, without bootgen
or byte swapping.

Native output:
`ventium-debugscan-bitgen.0Neit8/native-output/ventium_fpga40_debugscan.bit.bin`,
SHA-256 `3be5b6e464f27f1125540e3cb60c61dc0e45c8e5ce3f567a9802f40bc54ff14d`.
Sealed generation:
`ventium-debugscan-bitgen.0Neit8/closed-bitgen.sha256`, SHA-256
`75aa0cf36584d41a2a22d1e235d5822d8961ef4acc72923756e8ab4ff2248727`.
The independent consumer prints
`PASS_PRIVATE_NATIVE_RAW_BIN_ONLY_NO_STA_OR_HARDWARE_ACCEPTANCE`.
The original raw BIN is retained unchanged for rollback (SHA-256
`30b0178eb924eb2914bda6300f7ef3f3bef233b48d821ef77bf452349f8beefb`).
This is a bitgen/provenance pass, not a timing sign-off, silicon-clock
measurement, functional repair, gameplay measurement or completed timedemo.

The sealed native BIN is deployed on October6 with the original image retained
for rollback. Source and `/lib/firmware` hashes both match the generated BIN;
the manager independently reports `operating` and IDENT is `a0486501`.
The five-second read-only clock admission measures200,004,225 cycles over
5.000120971 seconds: **39.999877 MHz**, with zero retirements. `CTRL=1` and
`FRZINFO.frozen=0` remain true through100 guard checks and before/after the
sample. Production pins and uploaded files still match. Deployment closes0,
and the separate host consumer verifies all sealed deployment artifacts.
Evidence: `ventium-debugscan-deploy.BL9amZ/native-export/closed-deployment.sha256`,
SHA-256 `d19deb2b0424bd2e93ca7c1a5594a8b92281024608fdbf6c673872a585e03870`.
This proves image transport/manager identity and the held-reset core clock,
not CPU correctness or a successful Quake timedemo.

Board scratch cleanup removes only the closed `rC7oCB` run and its duplicate
board export, after checking native closure, all37 sealed files and the kept
VHD seed. It frees53,465,088 bytes. Full evidence remains in the host's
`ventium-private-jp-bad-boundary.oE0Zzd/exception-log-rC7oCB-export`; its omitted
private VHD is identical to the retained board seed. Production media and the
latest closed control remain untouched.

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
cases. These are **offline tests only**. The separate October6 board capture
now demonstrates coherent reset/bad-boundary reads and reproduces the defect;
it does not extend those eight fake-MMIO results into a full hardware or ISA
qualification.

Attribution caution: matching retained owner PC is necessary, **not sufficient**
to identify a dynamic instruction. In the frozen core, the packet FFs update
only when a new memory request must wait; immediate acknowledgements can use
the live decode without updating them (`core.sv:7473` and the effective-packet
mux at6155). Repeated executions of the same PC can also leave an older owner
with the same value. The ACTIVE copies report retained selection at capture,
not a history of which packet retired. Correlate the halt, retire evidence and
memory-transaction ownership before attributing a packet to the failing CMP;
do not turn an owner-PC match into a causal or timedemo acceptance claim.

## Live-input inventory and next diagnostic

The first read-only query finds only one of88 requested exact RTL net names.
That is not evidence that the missing signals are zero or absent: native
synthesis has renamed/merged their logical aliases. A second query follows
actual original primitive pins instead. Its initial attempt rejects on the
first flags-register D input because a valid `INTRASITE` connection has no
intersite nodes/PIPs; calling `get_property` on that empty object list is a
query-script error. Native exit1/input-pins0 and the unchanged parent DCP are
sealed in `ventium-debugscan-live-pins.qLSKml/closed-rejected-query.sha256`
(SHA-256 `47c9a894a73a3a1293cb342efd9aa2c6f79cd37f958d79f33698b7276b1a2f60`).

The corrected, separately pinned query closes native0/input-pins0 and its
independent consumer passes. It records251 matched primitives,1,137 pins and
14,604 net names; broad name categories include replicas/carry cells and are
**not** counts of distinct architectural registers. It finds the original
retire-valid FF, EIP/primary-PC pins, both retained-packet length inputs,
V-condition/displacement inputs, flags PF input and seven state bits. The
primary-PC FFs have no functional reset on their R pin, whereas retire-valid
does; do not copy a guessed generic reset. The absent `retire_pipe_valid` name
must not be used as a capture enable. Parent CPU logic, routes and board state
are unchanged by these inventories. Sealed query:
`ventium-debugscan-live-pins-r2.gJvNcj/closed-query.sha256`, SHA-256
`727769977cdf45b925a72138efa6921f14177d6d498967c808881fb432861925`.

The proposed general diagnostic samples original pre-edge inputs every clock,
then uses the **original registered retirement pulse** on the following clock
to retain those inputs together with actual original PC/EIP/PF outputs. This
aligns delayed memory, immediate memory and consecutive retirements without
mistaking a newly decoded next instruction for the retiring packet. It is new
diagnostic state, **not a duplicate FF claimed to prove an original FF's value**.
Length bit3 remains unobserved; raw live decoder inputs are not selected
effective-packet evidence when ACTIVE is set. No EIP-specific hardware filter,
pairing disable, CPU fix or additional observer deployment has been made.
Primitive simulation, scan truth-table/coherence checks and full physical
preservation/routing gates must precede any deployment of this extension.

### Two-edge sampler: offline proof and rejected physical attempts

The logical sampler now has84 pre-edge FFs and150 retirement-record FFs.
Its retained record includes actual original primary-PC/EIP/PF outputs plus
the preceding edge's raw EIP input, live length/condition/displacement inputs,
ACTIVE, EIP enable, PF input and seven state bits. Capture uses the original
registered retirement pulse through an identity-LUT enable buffer. Selectors
109–115 expose signature/metadata and150 bits; the original338-bit bank is
unchanged. This is general diagnostic state with no instruction-PC filter,
CPU RTL change or additional MMIO response cycle.

Installed Xilinx FDRE/LUT1 functional models pass8,168 checks, including all
eight-clock retirement patterns, consecutive retirements, per-bit propagation,
disabled-original-EIP-enable D/Q discrimination, halted retention and reset
priority. Independent scan checks pass31,424 cases. Existing64 model traces
contain4,096 committed CMP/JP windows:684 immediate and3,412 retained-memory
windows have the expected next-edge original PC/EIP/PF alignment. This replay
does **not** claim64 complete seed gates or hardware timing qualification.
Logical catalogue SHA-256:
`e5439cc145fc7f62c6b60e9300fc96560c0a6d2e0115d908bf5a419157696394`.
Offline closure: `ventium-debugscan-retire-plan.dlobDM/closed-offline-tests.sha256`,
SHA-256 `caab0b7771beddb9f313b7c1f01f50d2e8a9f99b931474f5a3079a490ae2af96`.

The dual-bank reader also passes10 fake-MMIO tests, with150 new and338 old
one-hot bit checks. It requires an already-halted, non-frozen core; writes
only the selector CSR; restores that selector on failure; checks signatures,
padding, unused selectors and two complete coherent reads; and compares a
valid record's actual PC/EIP/PF against independent original debug values.
An old retained-only image is rejected before payload interpretation. Its
seal is `ventium-private-retire-reader.vEoE1U/closed-reader-tests.sha256`,
SHA-256 `0148f0cf1a3d4dc62cc973c72b5794b493bd964e88ee700468fe4cb7ebd7c170`.
These remain offline protocol tests, not a deployed extension or CPU pass.

The first native preflight rejects a guessed reset inversion **before any
construction**. The original retire-valid R pin is non-inverted0 despite its
driver's misleading `core_reset_n` name. A matching reset0 vendor-model test
passes8,168 checks; its closure SHA-256 is
`813c1672e0f432e50f0db087bbb653200d7f8c47b81dc7a072acb7ace6a05665`.
Rejected preflight seal: `ventium-debugscan-retire-eco.nz8GFx/closed-rejected-preflight.sha256`,
SHA-256 `6a2f4790d73e0314797ff450b2c6b12239bc538fd899bc1b9b7e9f9be5f054ec`.

The reset0 physical attempt then packs16 independent diagnostic FF inputs per
fresh slice. Native routing reports overlapping/unreachable connections,
including record FF2 paths and the changed debug-response inputs. It reaches
the580-second bound: **native124/input-pins0**, not a routing pass. Its prepared
checkpoint must **not** be bitgenerated or deployed. The unchanged parent DCP
and board image remain available. Rejected routing seal:
`ventium-debugscan-retire-eco-r2.strCm2/closed-rejected-routing.sha256`, SHA-256
`e84631cff0bef67b28aac6a65f61fad7bf00b7a41e97dd1128b0aee78e223b70`.

The revised physical plan uses only eight FF1 lanes per fresh slice, each with
a matching identity6LUT data path:234 FFs and339 LUTs,573 new primitives total.
The logical catalogue/scan ABI is unchanged. Its vendor-model test again
passes8,168 checks;468 identity-buffer truth cases and31,424 independent scan
cases pass. Closure: `ventium-debugscan-retire-eco-r3.Co7axy/closed-buffer-tests.sha256`,
SHA-256 `1b4c81cc56e3cd5b9fd8fba7e7e271a368f06a0d0b25c3fb64caca306dcb24db`.
Only the completed **pre-construction baseline data** from the rejected
attempt is reused, with its seal, unchanged parent identity and all416,253
original net groups checked; the failed ECO is never treated as accepted.
The revised attempt closes **native1/input-pins0** on its550-second Tcl budget,
before construction: only original-pin/constraint inventory records exist,
with no new checkpoint. Its seal is
`ventium-debugscan-retire-eco-r3.Co7axy/closed-rejected-inventory.sha256`, SHA-256
`b402f3593ec15e15f76416596a41ac6252e903fb0eb80acd30c1ab3eb62ca448`.
The stack reports the budget check inside cached route loading; this attempt
has insufficient stage instrumentation to attribute all preceding time to one
query. A separate data-only check indexes all416,253 recorded names
in1.025 seconds and parses all415,782 nonconstant routes in2.270 seconds total.
The next attempt keeps the tested physical plan unchanged, resolves its
complete recorded name set against all native hierarchical nets, and adds
stage timestamps. No additional observer image has been deployed.

That next attempt matches all416,253 recorded names against587,412 native
hierarchical nets (native query20 ms, name matching5.571 seconds). It then
closes **native1/input-pins0** at the same550-second budget, still inside the
cached-route loader and before construction. This separates the successful
name lookup from the unresolved loader delay; it is not full route closure.
Seal: `ventium-debugscan-retire-eco-r4.dKUXqw/closed-rejected-cache-loading.sha256`,
SHA-256 `dcd1907af7dbc50506ad46ca9c3d268097d8bf2145d104bb1684989751e6305f`.

The array-lookup revision reaches the first constant alias promptly, but
rejects `get_property TYPE` because its value is an ordinary net-name string,
not an accepted native DB object. This is a **diagnostic-script object-cache
defect**, not an FPGA constant-tree or processor failure. It closes
**native1/input-pins0** before construction; no new checkpoint is written.
Seal: `ventium-debugscan-retire-eco-r5.1hMfQI/closed-rejected-object-handles.sha256`,
SHA-256 `aa73914ce2c88b7d9d5697433d11af57bf5d09a84805643cf3bc403e97315ae2`.
The subsequent revision retains native objects directly in the shared array,
with no ordinary dict/list return conversion. Its full preservation/route/DRC
gates are pending. The logical sampler, scan ABI and board image remain
unchanged by these rejected tooling attempts.

Board cleanup removes only the closed `mFdR81` and `XEIuht` private runs and
their duplicate board exports, after re-auditing both host recovery captures,
closed native invocation identities and every original/export file. It frees
109,256,704 bytes;264,998,912 bytes are available afterward. The latest
`KILHpq` control, production media, firmware, rollback and VHD seed are kept.
Complete captures remain under `ventium-private-observer-controls.BFWmEY`
and `ventium-private-observer-boundary.cj7i9A`; the omitted private VHDs match
the retained seed. Cleanup closes0 and its independent host audit passes.
Seal: `ventium-board-archived-cleanup.fyTzpg/closed-cleanup.sha256`, SHA-256
`d42a30898f27510a262bbaf9a5f5d9dca401decb738e1631df904b1144cf74de`.

Obtain causally useful retained-packet/next-PC evidence before selecting
a general fix. Do not disable pairing, single-step production Quake, suppress
faults, or patch its allocator to manufacture completion. Any eventual major
core/cache change must pass differential gates and the entire standard suite:
both CoreMark correctness seeds, Win95 boot-to-desktop, and completed Quake
timedemo. A 64-case private pass does not discharge that requirement.
