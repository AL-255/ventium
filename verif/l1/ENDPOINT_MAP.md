# Parallel endpoint-map decode — October 13

Status: **implemented in an isolated full-core candidate, regression-checked,
transferred into the full-PC model and frozen for FPGA synthesis**. Both short
CoreMark seeds and strict hardware-profile CPU lint pass. There is **no timing,
standard-suite or physical-FPGA acceptance yet**; the canonical gate remains
red. This does not meet the 40 MHz requirement by itself.

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

`fpga/prepare_endpoint_map_synthesis.py` has generated, **not launched**, the
synthesis and read-only clock-audit controllers. The mapper, definitions,
clocks, exclusive Vivado launcher, timeouts, memory limits, disk admission and
stop/reap logic are retained from PRIME-REG. Admission checks this candidate's
own map/directed/replay evidence and short seeds; it does not pretend the
parent's separate FP/branch corpus was rerun. Any timing delta will include
both SMSW and endpoint-map changes. At closure, scratch had about **5.6 GiB**
free, below the unchanged synthesis admission requirement; no Vivado was
launched and no limit was weakened.

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

## Next required work

Recover sufficient safe scratch headroom, then measure the frozen four-file
candidate's whole-design timing/area under unchanged 40/100 MHz constraints
and resource guards. **No timing gain is attributed until measured.**
Continue resolving the canonical reference/RTL failures without weakening the
gate; complete the standard suite and physical UV-fast Win95/Quake validation.
The installed old Doom image still faults on SMSW; new Doom gameplay/FPS needs
a repaired, qualified bitstream. The repair/retry latency matrix and broader
fault/event corners are not inherited from the parent merely by matching these
directed traces.

Candidate gameplay IPC is **unmeasured**. Older verified **simulation** baseline:
**0.51030715 total U+V IPC**, build `2b4d7a48`, cycles
**1,200,065,237–1,300,065,237**. It predates this candidate and is not FPGA/Doom
IPC. The new composition has no Fmax measurement; 35.023816195 MHz belongs to
the earlier SMSW-free PRIME-REG candidate.
