# Parallel endpoint-map decode — October 13

Status: **implemented in an isolated full-core candidate, regression-checked,
transferred into the full-PC model and frozen for FPGA synthesis**. Both short
CoreMark seeds and strict hardware-profile CPU lint pass. Synthesis and its
independent timing audit are closed: **35.056967572 MHz unplaced estimate**,
still below 40 MHz. There is **no timing closure, standard-suite or physical-FPGA
acceptance**; the canonical gate remains red, and cold Doom startup stalls.

## Change

The [PRIME-REG timing report](PRIME_REG_FLAGS.md) identifies a 99-level
`q_pc` → memory-owner path passing through the last-byte address addition,
cache-map decode, paired-store admission and ACK. Its synthesized/unplaced
estimate is **35.023816195 MHz**, not 40 MHz sign-off.

`prepare_endpoint_map.py` changes only `rtl/mem/ventium_l1_axi.sv` on top of the
compiled SMSW + PRIME-REG composition. The cache map has no boundary within a
32-byte line, and a producer's extent is at most four bytes. The replacement:

- Decodes the current and next line in parallel, using the existing two map
  instances. A six-bit low-address/extent sum selects the final-byte result.
- Precomputes complete endpoint routing permission when `ADDR_MASK` covers
  whole lines. For arbitrary masks that split a line, it retains the original
  byte-exact PCI aperture check.
- Preserves `core_d_last` exactly, including zero-strobe read fallback,
  zero-strobe writes and 32-bit wraparound. Arbitrary SMBASE comparisons retain
  this original full byte address.
- Changes no cache capacity, state, request, ACK, permission, fault, pairing,
  clock, mode or latency rule. Simulation assertions compare the original
  final-byte map and routing expressions continuously after reset.

The isolated parent/candidate source sets contain the same **195 files** and
**152 UV-fast definitions**. Exactly one file differs. Root RTL and unrelated
worktree changes were not overwritten. Source/hash drift and reapplication are
rejected; three recipe tests pass.

## Closed verification

| Check | Result | Scope |
| --- | --- | --- |
| Exact-source map miter | 720,896 vectors, 11,534,336 comparisons | Both snapshot-map parameter values × eight physical address masks; dynamic chipset configuration; all strobe/direction combinations at every map boundary; random inputs |
| Coverage witnesses | 9,088 wraps; 171,531 line crossings; 22,581 zero-strobe reads | Counts are input vectors, before the 16-profile multiplier |
| Negative variants | All three rejected | Lost tail map, lost subline-mask fallback, lost legacy read extent |
| Symbolic arithmetic | Two UNSAT equivalence queries; three SAT witnesses | All address/strobe/direction values and arbitrary masks under the stated line-mask premise; **not** a whole-RTL sequential proof |
| Full-core build | Native exit 0, 20.46 s | Unchanged UV-fast profile, assertions, 32 compile jobs, private host object/header, 10/2 GiB RAM/swap cap |
| Six-harness route/extent/CD gate | Parent and candidate pass, 13.36 s combined | Actual L1/AXI/CDC with the existing memory-only gate profile; VGA, PAM, holes, TOM, BIOS shadow and RAM-window boundaries |
| Initial SMSW differential | 88 cases / 6,556 records pass | Real/protected mode, ordinary-store controls, prefixes and crossing stores |
| CPL3/V86 differential | 60 cases / 11,250 records pass | Unmodified QEMU system-state comparison |
| Fault differential | 25 paging passes; 20 reference disagreements | The LOCK/segment cases still satisfy RTL Intel-spec self-checks but differ from pinned QEMU; full fault driver exits **1**, not a pass |
| Canonical `make verify` | **7 PASS / 101 FAIL**, native make exit **2**, 404.29 s | No mask, golden, comparator or band change; all 20 cycle traces exactly match the parent |
| Exact-input canonical replay | 108 cases / 80,800 records identical, 77.03 s | Parent/candidate/original-candidate complete records agree; this **does not** make the QEMU gate green |

The canonical shell forces one worker despite the controller requesting four.
The focused CPL3/V86 and fault tests run parallel workers with explicitly
checked CPU affinity. The 173 directed differential passes are executions of
existing fixtures, not newly invented independent cases.

`audit_endpoint_map.py` independently checks source/artifact hashes, terminal
owner invocations and native outcomes. It re-compares all **193 directed cases /
22,891 records** against the composed parent, plus every canonical replay and
cycle record. Its successful audit retains both red-gate statuses explicitly.
All run owners are terminal; no Vivado run or FPGA programming occurred.

Two launch errors are retained separately: the first leaf service omitted the
build guard's required `--` and exited before starting any test; the first
fault service supplied 16 CPUs where the existing driver requires eight and
exited before creating its output. Corrected launches did not alter a guard or
fixture. Neither refusal is counted as a DUT result.

## Full-PC and FPGA source transfer

`fpga/build_endpoint_map_soc.py` copies the closed PRIME-REG PC source set and
applies exactly the three hash-gated SMSW transformations plus the endpoint-map
transformation. All **102 shared core sources** match the directed-tested core.
It retains 156 simulation definitions, UV-fast mode, full P5 caches and the
posted-16 board transport. The private harness is compiled against its own new
generated header. Native compilation closed in **24.33 s**, with the existing
32-job build scope reduced to 10/2 GiB RAM/swap before compilation.

The unchanged PC builder finds the same **98 platform structural warnings** as
its parent; this is not clean full-SoC lint. Separately, the frozen CPU hierarchy
passes all six hard structural-warning classes with the exact **158 hardware
definitions**, native exit 0 in **3.88 s**. The freeze checks all **170 common
native HDL inputs**, retains the same 190 payloads and 117-unit/49-include source
closure, and passes the unchanged Tcl source contract at **40/100 MHz**.

Both unchanged ten-iteration CoreMark seed disks cold-booted in the new PC model:

| Seed | Reference CRCs | Candidate and PRIME-REG parent ticks | Native runtime |
| --- | --- | ---: | ---: |
| Performance | e9f5 / e714 / 1fd7 / 8e3a / fcaf | 4,767,218 | 211.49 s |
| Validation | 18f2 / e3c1 / 0747 / 8d84 / c64e | 4,753,406 | 210.45 s |

Both native processes exited 0 and were reaped; the retained owner reports no
OOM, with 59,809,792 bytes peak memory. V retirement is nonzero in both runs.
These short checks show **0% fixed-clock throughput change** on those fixtures,
not a duration-valid CM/MHz score, gameplay IPC or a completed standard suite.
No save-state, media patch, mode fallback or reference relaxation was used.

`fpga/audit_endpoint_map_transfer.py` independently rechecks the source/freeze,
lint, native identities, short-seed audit and all three terminal invocations.
Five host transfer/controller tests pass, including wrong-source/fifth-file
rejection and unchanged synthesis resource lifecycle. An initial host test
compared a changed explanatory docstring as executable structure; that test
was corrected to exclude docstrings, without changing the freeze guard.

`fpga/prepare_endpoint_map_synthesis.py` generated the
synthesis and read-only clock-audit controllers. The mapper, definitions,
clocks, exclusive Vivado launcher, timeouts, memory limits, disk admission and
stop/reap logic are retained from PRIME-REG. Admission checks this candidate's
own map/directed/replay evidence and short seeds; it does not pretend the
parent's separate FP/branch corpus was rerun. Any timing delta will include
both SMSW and endpoint-map changes. At the transfer audit's closure, scratch had about **5.6 GiB**
free, below the unchanged synthesis admission requirement; no Vivado was
launched at that point and no limit was weakened.

### Guarded synthesis — launched 12:49 UTC, now closed

The subsequent recoverable archive below raised free scratch space to
**7,329,439,744 bytes**, above the unchanged **7,208,493,056-byte** measured-growth
admission requirement. The sole synthesis family is now launched:

- Controller: `ventium-endpoint-map-synth-oct13.service`, invocation
  `dc86176c8f614a6cb6b789a4427b637b`.
- Native scope: `ventium-vivado.scope`, invocation
  `0ac5491be1d54e76b5318fede569fe47`, 8 GiB RAM / 6 GiB swap / 48 tasks.
- Actual 40/100 MHz constraints, unchanged logic-only mapper and frozen source
  manifest. A 45-minute native timeout, 4 GiB disk floor, 2 GiB host RAM/swap
  floors, OOM-event checks and 13 GiB combined-memory stop remain active.

At the 12:54 UTC observation, the native process family is live, using about
6.7 GiB RAM and no swap, with no OOM event. **This is not a synthesis result**.
No placement, routing, bitstream generation, programming or timing pass has
occurred. The read-only clock audit must wait for successful native closure
and the independent synthesis/DCP audit; it must not replace a live Vivado run.

The separate `fpga/run_endpoint_map_doom_smoke.py` is cold-booting a private
copy of the exact original Doom disk with this PC model. It is limited to
100 million cycles / 30 minutes, CPU12, 512 MiB RAM and no swap, with a 4 GiB
disk floor. It preserves original media, EXE/WAD hashes, native argv/cgroup and
frame/log evidence; it neither restores snapshots nor alters the guest code.
Unit `ventium-endpoint-map-doom-smoke-oct13-r1.service`, invocation
`3a9dacbd8cb84ae7b7609f1d5aff8dd8`, is live at the same observation. Its output
is `endpoint-map-doom-smoke-r1`. Four host tests ensure diagnostic observations
do not conflate native exit zero, an echoed command, graphics capture, a guest
return or an invalid-opcode report with timedemo success. No Doom FPS or guest
completion is established by this startup run so far.

### Closed timing/area result

Synthesis naturally closed with exit 0 in **1,919.77 seconds**, with unchanged
inputs and no OOM. The independent audit checks all **19,971 input pins**, the
actual 158 definitions, 148 native HDL reads and DCP integrity. The native
diagnostics remain visible: 0 errors, 1 critical warning, 1,571 warnings. The
critical warning is the PS-generated XDC's unknown clock pin; the subsequent
native project audit confirms the required actual clocks rather than ignoring
the warning or inventing replacement constraints.

The serial read-only timing audit then closed in **475.10 seconds**, peak
4,795,453,440 resident bytes / no swap / no OOM. It checks 18,300 input pins,
40/100 MHz clocks, zero black boxes and zero multiple-driver/logic-loop DRC
errors. Both retained owners are terminal with MainPID 0. No Vivado remains.

| Metric | SMSW-free PRIME-REG parent | SMSW + endpoint candidate |
| --- | ---: | ---: |
| Unplaced core estimate | 35.023816195 MHz | **35.056967572 MHz** |
| Setup slack at 40 MHz | −3.552 ns | −3.525 ns |
| Hold slack | −0.101 ns | −0.101 ns |
| LUTs | 187,311 | 187,333 |
| Registers | 55,006 | 54,966 |
| BRAM tiles / DSPs | 277.5 / 47 | 277.5 / 47 |
| V-response capture path | 96 levels / −2.793 ns | 93 levels / −2.425 ns |

The overall estimated frequency gain is only **0.09465%**. The capture cone
shrinks from 71,262 to 70,374 cells, but reachability is not exclusive area
ownership. The whole-design worst path is now 97 levels from `q_pc[0]` to
`gpr[4][16]`, traversing fetch/prefix/decode → demanded byte count → segment and
fragment control → code-access/store-pair admission → AXI ACK → register write.
It does **not** meet 40 MHz. These are synthesized, unplaced estimates, not
routed sign-off or board measurements; no isolated endpoint-only gain is
claimed because the comparison also adds SMSW.

### Cold Doom diagnostic: stalled, not passed

The original 100-million-cycle smoke run closed after **1,570.06 seconds**,
native exit 0 with its child reaped, no OOM and unchanged original media/code.
It boots FreeDOS and launches Doom, but retirement freezes at **4,135,554**,
`16F0:DAF0`, `EFLAGS=0x86` (IF clear). The frozen profile identifies state 40
as `S_HLTWAIT`. Samples from cycles **33,276,784–100,000,000** have the same
retirement count, with explicit no-retirement warnings up to 65 million cycles.
There are no graphics captures and `DEMO3.LOG` is empty. V retirement is zero;
this real-mode startup cannot establish UV-fast gameplay acceptance.

The original runner's narrow `native_error_observed=false` field does not
detect `[STALL]`; it is **not** a clean guest result. The separate read-only
`fpga/audit_endpoint_map_doom.py` catches and reports the stall while checking
17,950 input pins, all artifacts and the exact closed invocation. Two new host
tests ensure a zero native exit never becomes guest acceptance.

`prepare_endpoint_map_doom_trace.py` prepares a new, shorter **34-million-cycle /
15-minute** cold diagnostic with the existing passive fault ring (eight events,
4 MiB cap), a bounded 40,000-instruction trace and 20,000-cycle state window.
It retains the smoke runner's source/media/resource/stop-reap guards and adds
no breakpoint, STEP, save-state, guest patch or model rebuild. Two recipe tests
pass. Unit `ventium-endpoint-map-doom-smoke-trace-oct13-r1.service`, invocation
`60c81cd66a8643d18cf62322fd1da3da`, now naturally closes exit 0 / MainPID 0 in
**565.02 seconds**, without OOM. Its output is `endpoint-map-doom-trace-r1`.
The first captured fault after the four-million-retirement filter is #UD on
**`LMSW AX` (`0F 01 F0`) at `24C7:032A`**, cycle 32,709,048. The live fetched
bytes, AX=0x0011, CR0=0x10 and matching explicit decoder omission identify the
next general missing instruction. This evidence is not inferred from a stale
registered vector. Later faults end at the same HLT/count as the smoke run.
Eight new [LMSW instruction probes](../sys/lmsw/README.md) pass on pinned QEMU
and reproduce #UD on the candidate; eight MOV-CR fixture controls pass both.
LMSW is **not repaired**, and neither run establishes gameplay or FPS.

## Identity and evidence

Root: `/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI`.

- `endpoint-map-core-r1/obj/tb_ventium`:
  `164e17003b2ec03cd7b92cc8bbe89b576e5f440becc4204e37368e075c87e8df`.
- Changed seam source:
  `4e923bc360a388c113c0ee9936e5f39e90411707aeb2c59806683398e3a610ec`.
- Parent model (`smsw-prime-reg-core-r1`):
  `42bd14c86eff5e33d98753cd07d34bf1340e804989daec237e42fd499565cfa5`.
- `endpoint-map-audit-r1.json`:
  `0165e78d169a5a582fc1878ee0b97b414b40900000f2ab32b3e7e5adff70f5b5`.
- Full-PC binary, `endpoint-map-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted`:
  `d8f72e2ca622b46c1ee8b0ec92197d4a6b9cd682411ed91c09ecb5488e7c052c`.
- Frozen `endpoint-map-fpga-r1/input-manifest.json`:
  `c45c29a6b2ae32fdd34defe85a6922e8560b2ccb9054b5d1563ae773a9040bd1`.
- `endpoint-map-transfer-audit-r1.json`:
  `f5e418d6cc37fcf58208440fe7dee892292d4a5110eef32db1bbf5359afb34a7`.
- Synthesis DCP: `b84da6e30f8b87f26bcc86f03d23a8df44644fb272af8713316d3472721d2d12`.
- Synthesis audit: `dbe0b27c97d35d13c41f3069f455f3a4a72ad0032c83441b9a757e678d08dc6b`.
- Clock audit: `cbab17a851639504ddbb05ec2d2a78bc942c8888a23372ce654a15ce85fee92f`.
- Doom smoke closure: `82bbb148bb3665fbbe88b6ec99c08ca25d2f8a452981a3506bce1aaf588c40df`.
- Leaf, route, SMSW, privilege, fault and replay evidence uses the corresponding
  `endpoint-map-*-r1` directories. The core contains `build-closed.json`,
  `verify-closed.json`, `generic.log`, complete traces and original commands.

Closed leaf compiler products (146 files, 662,616,986 bytes) were losslessly
archived to 84,534,901 bytes after byte comparison. Sources, headers, binaries,
logs and every pinned artifact remain expanded. Recovery commands and member
hashes are in `endpoint-map-leaf-r1/compiler-archive.json`. The route driver
similarly retains per-build recoverable compiler archives.

The two closed endpoint/SMSW-composition core builds also had **450 generated
compiler intermediates**, 464,742,033 bytes, compressed to 73,594,701 bytes in
`closed-endpoint-model-products.tar.gz`, SHA-256
`4fbe78a9ea10b07e813dcfcc2670ab3bca0b01f882123afe13affdaadae29d77`.
Every member was byte-verified before unlinking its expanded copy. Binaries,
headers, sources, traces, receipts and every current input pin remain expanded.
The adjacent plan/verified/closed JSON receipts contain member hashes and the
recovery command, restoring under `/home/yukidama/external/tmp`.

To admit synthesis without weakening its disk floor, another **196,125**
explicitly inventoried outputs from 24 closed predecessor test directories
were byte-verified and archived to `closed-endpoint-old-fixtures.tar.gz`:
982,398,182 source bytes (1,543,897,088 allocated), 62,348,832 archive bytes,
SHA-256 `525982527dd3e1ea7e1527e93ddb04a9f9d6cff9a376c88f5475c215e1ff7a04`.
All current transfer/timing pins, models, sources, media and aggregate receipts
remain expanded and unchanged. Old failed runs remain failed. Their older raw
artifact audits may require restoring this archive first; member hashes and
the restore command are in the adjacent plan/verified/closed JSON receipts.

## Next required work

Analyze the remaining fetch/decode-to-memory/commit critical path before
another synthesis; the measured endpoint change is insufficient for 40 MHz.
Implement and qualify the now-reproduced general LMSW repair, retaining the
passive Doom fault/retire trace and directed controls. Do not substitute
simulation or a partial window for physical timedemo acceptance.
Continue resolving the canonical reference/RTL failures without weakening the
gate; complete the standard suite and physical UV-fast Win95/Quake validation.
The installed old Doom image still faults on SMSW; new Doom gameplay/FPS needs
a repaired, qualified bitstream. The repair/retry latency matrix and broader
fault/event corners are not inherited from the parent merely by matching these
directed traces.

Candidate gameplay IPC is **unmeasured**. Older verified **simulation** baseline:
**0.51030715 total U+V IPC**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA/Doom
IPC. The composition's **35.056967572 MHz** is an unplaced synthesis estimate;
40 MHz timing closure remains open.
