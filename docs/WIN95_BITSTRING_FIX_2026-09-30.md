# Win95 interrupt-bitmap investigation — 2026-09-30

## Finding

Memory-form `BT/BTS/BTR/BTC r/m16|32,r16|32` is accepted by the decoder,
but the implementation masks the bit index without advancing the effective
address. This is a general ISA bug, not a Win95-specific workaround.

Win95's actual `Enable_Global_Trapping` binding is `10097 -> C0003B6C`.
Its instruction at `C0003BA5` is `0F AB 15 24 AF 00 C0`:
`BTS dword [C000AF24],EDX`. Port indices 32/33 must modify `C000AF28`;
160/161 must modify `C000AF38`. The bug aliases these to the first dword.
The same routine also updates global and per-VM trapping bitmaps, so repairing
only the live TSS bytes would leave corrupted guest state.

Evidence on the unmodified cold-run inputs:

- Pinned QEMU, explicit `pentium,-vme`, original read-only Win95 disk and private
  overlay: post-access write-watch stops at `C0003BAC`, EDX 32 then 33, with
  `C000AF28` changing to `01` then `03`. The preceding code window contains
  the BTS above; the watch alone does not prove an instruction-start boundary.
- At the matching first virtual-interrupt setter, QEMU's PIC-port bitmap bytes
  are `03` (denied); Ventium's are `00` (allowed), with the same TSS base,
  limit and map offset. QEMU reaches the owner return with virtual IRR/ISR
  cleared; Ventium's qualified following 1M-cycle trace retains them.
- Closed Ventium origin and terminal canonical memory both contain
  `FFFFFFFF` followed by twenty zero bytes at `C000AF24..C000AF3B`.
  Resident/backing layers agree, with no overlapping pending owner. These
  canonical bytes are not substituted for historical served operands.
- The existing `verif/tests/directed/bt_mem_bigindex.s` reproduces the bug on
  the current direct-core binary: bit index 40 yields CF=1 and the good branch
  under pinned QEMU, but CF=0 and the bad branch under RTL. That old test does
  not initialize ESP, so its raw whole-trace comparison is not a passing gate.

The matched QEMU run closed in 3.417 seconds: actual waited exit 0, pipe EOF,
unchanged inputs/driver and zero OOM events. It is diagnostic evidence, **not**
Win95 desktop acceptance or a historical OUT/#GP trace.

## Repair and verification requirements

Adjust the decoded memory EA once by `(signed(index) >> 5) * 4` for dwords,
or `(signed(index16) >> 4) * 2` for words. Apply address-size wrapping before
segment-base addition. Retain modulo bit selection within the chosen operand;
immediate-index and register-destination forms must remain unchanged. The
existing captured `q_ea` must feed both read and write, without another request
address generator or extra serialization.

Also test write-fault precision: a readable but read-only RMW operand can reach
execution before its store faults. BT-family CF must not become architectural
before successful store completion. Cover positive/negative indices, both
operand widths, address-16 wrapping, aliases, immediate controls, LOCK,
adjusted-address page faults and cross-page stores.

The repaired direct-core candidate passes all eight `pbitmem` cases with full,
untrimmed architectural-state comparisons against pinned QEMU. In particular,
pre-fix CASE4/5 first diverge at retirement 7,235, PC `F0195`: QEMU EFLAGS `87`,
RTL `86` (lost CF after the write #PF). QEMU exits with EAX `42`, EDI `0`;
old RTL finishes with EAX `43`, EDI `2`. After staging CF, both complete with
7,272 matching retirements and the passing terminal witnesses. This is not a
whole-system acceptance claim.

Candidate TB SHA-256:
`6aeaff4b132b0d13fcfdb3c1a7aec3a6806c68c3a711dc64fac29161cce81608`.
Private microtest evidence: `verif/tb/obj_dir_bitmem_sep30.aUqHZB/pbitmem/`.
The 32-job, bounded build completed in 58.650 seconds. `make verify` passes
all 108 functional programs (including the new `t_bitmem`) and all 19 timing
bands. The five strict structural lint configurations pass. The existing
20 non-gating per-instruction timing divergences remain explicitly reported;
they are not functional passes.

The matching full-PC build completed in 39.035 seconds. Its executable is
`c0e5206ea2233f98dae7b60288a513e2dc5a3de5c9622d002e33d96b356b7958`,
compile record `3ed2c826e182c554d3c7eddb70650c1d8628e3e5f78266388f8cad9a180cf723`.
Both unchanged 1,500-iteration CoreMark seeds completed on the new TB,
CPUs 4/5, under a 2 GiB/no-swap/160-task/60-minute-per-seed envelope.
Their private matrix is `obj_dir_bitmem_sep30.aUqHZB/ventium-coremark-matrix.ism35yfq`.
Fresh cold OS acceptance is pending. These binaries include the pre-existing
local worktree changes; the bit-string commit is scoped and does not silently
stage those unrelated changes.

An old Win95 snapshot already contains incorrectly
initialized bitmaps; restoring it after an RTL fix cannot prove boot repair.
Acceptance requires a fresh cold boot to the desktop, both CoreMark correctness
seeds, completed Quake timedemo and the relevant differential gates.

## October 1: cold acceptance and evidence collection

At 04:22 UTC the repaired candidate's CoreMark seeds have passed, Win95 has
closed with a guest protection error, and cold Quake is still running.
Their private full-PC parent is
`ao486-sim/obj_dir_standard_bitmem_sep30.S9VlV4/`:

| Run | User service | Invocation ID | Native CPU |
| --- | --- | --- | --- |
| Both CoreMark seeds | `ventium-standard-bitmem-coremark-sep30.service` | `c8fb53fb3f044949b4be4fcae04c3a73` | 4 / 5 |
| Win95 cold boot | `ventium-standard-win95-bitmem-sep30.service` | `0f3faba5b45d4d7d8807429e83b1bf34` | 8 |
| FreeDOS Quake cold timedemo | `ventium-standard-quake-bitmem-sep30.service` | `52726767e6d74984b47c1715f2b7f8ff` | 9 |

The OS wrappers start with a clean environment, private disk/executable/ROM
copies, 45 MHz core/RTC, 90 MHz VGA, 32 MiB and `FPGA_DDR=2`. No guest
patches, write dropping, keyboard bypass, old snapshots or forced EOI are used.
Each OS unit has a 2 GiB/no-swap/32-task, one-CPU envelope; the CoreMark unit
has two CPUs and 160-task headroom. Actual `/proc` executable hashes, affinities,
unit invocations and cgroup OOM counters were checked. The Win95 unit's large
memory accounting is predominantly inactive disk-copy file cache, not anonymous
simulator growth; no OOM events are recorded.

Win95 now uses the reviewed held-inode `CapturedLog` collector rather than
letting the child write the evidence file. Final screening requires the actual
child wait, pipe EOF, absent child process group, complete normal engine footer,
stable log hash and unchanged observed source/input hashes. The 49 combined
collector/Win95 host tests pass. A zero exit remains `clean_exit_unqualified`,
not desktop acceptance: a verified desktop and error-free evidence are still
required. Observed Python source hashes are not misrepresented as proof of the
exact loaded text. Setup-exception cleanup and disk hashing after an unproved
process-group closure remain harness limitations; such results cannot qualify
acceptance. The running source files are frozen for their before/after checks.

The candidate's first 194 complete Quake progress records through 97,348,660
clocks, including the 97 logged startup page faults, match the original `cdcb`
run exactly. Those faults are not evidence of a new regression; startup is
advancing, but is not gameplay IPC or timedemo completion. The unchanged startup
comparison now spans 765 complete records, clocks 97,848,660–479,848,660.
CoreMark correctness passes; Windows desktop and Quake completion do not.

### Closed CoreMark correctness

Both seeds completed with actual native wait status0 and guest exit0, all five
reference CRCs, 1,500 iterations, and the full 2,000-byte dataset (666 bytes per
kernel). The summary is SHA-256
`2da143393c452651d5f78dde6388081498ac5ba91e9f0ce924692a21c2c4500e`.
Frozen executable, compile record, generated headers and input images remained
unchanged. This qualifies CoreMark only, not the entire standard suite.

| Seed | Whole-program RTL clocks | CM/MHz (conservative) | CRCs: seed / list / matrix / state / final |
| --- | ---: | ---: | --- |
| Performance | 713,805,640 | 2.10141237 | e9f5 / e714 / 1fd7 / 8e3a / 25b5 |
| Validation | 712,760,043 | 2.10449507 | 18f2 / e3c1 / 0747 / 8d84 / e230 |

The score denominator is measured RTL clocks, not synthetic guest seconds or
host time. Supplementary two-clock-query scores are 2.10162988 / 2.10469241;
the conservative whole-program scores remain the defaults. Host durations were
2,347.821 / 2,369.045 seconds. The service closed normally; retained live OOM
counters were zero, but no post-collection final cgroup counter receipt exists.

### Windows protection error: acceptance FAILED

The current cold boot prints `Windows protection error. You need to restart
your computer.` at cycle475,026,424, then `Press any key to continue...`.
The collector detected the error and intentionally terminated its owned child;
actual native return=-15, pipeEOF and absent process group are proved. The
result correctly says `terminal_error`, never desktopPASS. The closed result
hash is `c4af22ce5c905897aeb8c1ac7718e155fa202c3416bad97863a99e7483cafed0`,
log `563861f1517028d80bf90ca33eea73f947d3cde9c4505c1ed2e2059f458cb062`
(2,109,763 bytes), private disk
`b81054e1dfdb759d77976afbe5ecf9ae07b95b8acf83ba379cc13303409b5b11`.
Observed input/source hashes are unchanged and no desktop frame exists.

The guest switches from protected mode at457,663,870 (CS28:C0223C4B,
CR0=80000011) to real mode by458,163,870 (CSc000:2138, CR0=10), then displays
the error. Coarse stdout also shows a preceding PF atC0265C04 and UD at
00A7:CA60; their causality is unproved. Buffered mixed stdout/stderr and the
fault-edge CR2 timing preclude reconstructing precise execution from these
lines. BOOTLOG.TXT/PRV on the closed disk are byte-identical to the clean source
and stale, so their old successful InitComplete entries are not this boot's
evidence. The first16-event fault ring exhausted during BIOS startup and says
nothing about absence of later faults.

A cold, unmodified-media diagnostic has closed on the same c0e5 binary in
`ventium-win95-pf-diagnostic-oct01.service`, invocation
`79a721719b954b059df07fb56c760a30`, nativeCPU8. It passively captures page-fault
history after90M retirements and requests a normal settled V4 checkpoint after
the reported CS28:C0265C04 delivery event. It has a500M-clock/120-minute cap,
2GiB/no-swap/32-task envelope, and no old restore, guest patch or forced EOI.
Its private directory is `S9VlV4/pf-diagnostic-oct01/`. Actual native wait0,
pipeEOF, absent process group and stable inputs are proved. The settled V4
checkpoint is at457,124,651/94,568,277 retirements, one clock and zero
retirements after its requested trigger. Snapshot SHA
`34ac908eeb341b0d215125d91e595e0c3fcb20488d1724d7bd3fa561b3f6b62b`;
paired closed disk SHA
`4e3be27663cc605a98ee9c01e4b1f37447350aa39ac7ee88439c168bbc762c7e`.
CR2 BFF7003C corresponds to a not-present PTE; this capture does not prove a
cache or walker corruption. A diagnostic snapshot is never desktop acceptance.

### Precise protected-mode VERW defect and general repair

Two bounded same-executable native diagnostics establish the later #UD's
actual instruction context, not its handler's post-delivery selectors.
At clock457,295,459 the installed decode is CS00A7:CA60, bytes `0F 00 E8`
(`VERW AX`), AX0087, CR0=8000001B (PE1), EFLAGS=00000212 (VM0), CPL3,
stateS_DECODE. The old decoder nevertheless sets `d_unknown=1`, and the next
clock raises #UD. VERW is an unprivileged protected-mode instruction; this is
a general missing ISA implementation, not a legitimate real/V86 rejection.

The observer-OFF replay and passive FETCH replay finish with the exact same
closed disk SHA as the original failed boot (`b81054...b11`). The exact decode
capture requests and saves clock457,295,459 with zero overshoot; snapshot SHA
`a97f3e01a0c14a862956ac0442cb6626e9aa7524bea8ee4352819b28b4bc9d16`,
analysis SHA
`8d1d99d0983e73420e638e573cb0fd1fc4841eb4fa3e84c1cad84320cccfbc0a`.
All restores use the same c0e5 executable/native ABI and paired private disks;
none is a cross-RTL restore or cold-desktop acceptance.

The candidate implements VERR/VERW through the shared descriptor-query engine
with LAR/LSL: explicit r/m16 source width, GDT/LDT paging, null/out-of-bounds
ZF0 without descriptor reads, precise source/descriptor faults, descriptor
type and privilege checks, ignored descriptor Present bit, and no segment or
GPR writes. ZF commits only after a completed query, through the ordinary
integer retirement path so TF single-stepping is retained. Real/V86 and LOCK
forms still raise #UD. There is no guest-specific bypass or new SRAM engine.

Frozen direct-core TB SHA
`fe4a21d733c5e7223e19ff3b2d2d30a71ff3a8f1cd6013456087a04ddb7c1e79`:
108 functional programs and19 cycle bands pass; five strict lint profiles pass.
The ten-case directed gate's first run passed cases1–6 and8–10. Cases1–6/8
had full pinned-QEMU architectural comparisons, including all eight TF traps;
LOCK and segment-extent cases9/10 are explicitly Intel-spec-only because the
pinned QEMU omits those checks. CASE7 failed on QEMU's own independent fixture
exit before RTL, so the historical aggregate remains FAIL, not ten passes.
The closed rerun in `M2bz8N/pverrw-qualified-oct01.2/` now
passes all ten: CASE7's code descriptor encoded base0 instead of baseF0000,
so QEMU fetched low RAM before reaching the queries. Correcting that descriptor
alone preserves the other nine images;16 host contract tests pass, and CASE7
now matches QEMU in full. Separate stdout/stderr, actual debug-exit133, complete trace
and zero-desynchronization I/O footers are required;26 negative host-grader
tests pass. No new query-candidate CoreMark/desktop/timedemo acceptance exists
yet. The isolated full-PC executable is
`e572d51811463a4fea5980278d47b77bcf2bef08b207e7995bdddce04f88b69c`,
compile record
`acdc0ff654d83e968bc468f908ba6c352e09e8d1e9667c58e340d69789a93763`.
Its107-macro strict shim lint passes. The historical source inventory omitted
four active host headers; the final closure adds them and force-recompiles
their owners, with unchanged source/model receipts. No RTL snapshot is reused.
Fresh cold Win95 is running in
`ao486-sim/obj_dir_standard_verrw_oct01.ckekDl/win95/`, service
`ventium-standard-win95-verrw-oct01.service`, invocation
`3b7cbea3cca6422a8deb0a12cfd0073e`, nativePID676623/CPU8,2GiB/no-swap,
32tasks/oneCPU/24h cap. It starts from the pristine cc68 disk/unchanged ROMs,
not the diagnostic saved state. Its late #UD ring is passive; an ordinary
zero exit or cap alone cannot qualify desktop acceptance.
Fresh cold FreeDOS Quake/demo1 is also active in the same parent, `quake/`,
service `ventium-standard-quake-verrw-oct01.service`, invocation
`d3457cb526014b788428eb6d33dbf9da`, nativePID678486/CPU12. Actual `/proc` SHA
matches e572; pristine source diskSHA2df14ac9...36e4c/ROMs,45/45/90MHz,
32MiB/DDR2/mouse,2GiB/no-swap/32tasks/oneCPU/72h cap, no restore or guest
patches. Retained live OOM counters are zero for both new units. Completion
and error-free closed evidence are still required, not merely gameplay.
The new55-generic-plus-plar sweep was prepared but not launched: its agent's
execution request was rejected. Those candidate system regressions remain
open; no old-model sweep is substituted for them.
Both new CoreMark standard seeds are now active on frozen TBfe4a, native
PIDs679926/679927 on CPUs10/11. Service
`ventium-standard-coremark-verrw-oct01.service`, invocation
`cf6f39f53a80434084314ac7030fac6a`,2GiB/no-swap/160tasks/twoCPU,
60minutes per seed. Parent
`verif/tb/obj_dir_verrw_oct01.M2bz8N/coremark-standard-oct01.rwe4r3/`,
matrix `ventium-coremark-matrix.k43qjdzq/`. Original1500-iteration/2000-byte
images, all five reference CRCs and limits are unchanged. The launcher
archives and executes the exact pinned matrix-driver bytes; initial actual
cgroup admission, source/executable/input hashes and zero OOM counters are
recorded. Final wait/CRC/pin/OOM/child-group closure receipts are pending;
there is no new completed score yet.
Its gameplay IPC is unmeasured; the labelled pre-repair baseline remains
0.44499855 on cdcb, clocks6,899,999,637–6,999,999,637.

The broader `make verify-sys` invocation on the frozen repaired TB stopped with
exit 2 at `pselnull`, not at its timeout. That historical fixture deliberately
reads through a null DS, relying on QEMU softmmu's missing per-access segment
validation. Both the original and repaired measured compile profiles enable
`VEN_SEG_ENFORCE`: a protected-mode null-DS access must instead raise #GP(0).
The fixture's null-DS handler then faults recursively, so the remaining system
gates did not run. This is not a green system-gate result, and no measured
old-binary control is claimed. Fix the test contract while preserving its
five selector/task/paging obligations and add precise null-segment read/write
witnesses; do not disable CPU segment enforcement to make it pass.

The new `pnullseg` Intel-spec witness now passes on frozen TB6ae: four exact
GP0/no-effect read/write cases and six legal alternate-segment controls,
actual debug-exit status85, 481 legacy DPI records in4,548 clocks, complete
footer and stable inputs. Artifact directory `aUqHZB/pnullseg-oct01.2/`;
witness SHA `ba748a588863a3261f7ed3c32518b682387f92f0e1a1f09527352e0985c38492`.
All22 host grader tests pass. The initial `.1` host-grading failure is retained:
the existing DPI stream reports fault-delivery events at the original faultPC,
not committed null accesses. The corrected local grader validates each marker
and adjacent handler's unchanged GPRs/flags/selectors and exact stack depth;
no RTL or global differential mask was changed.

Standard pselnull A/E now use legal SS-qualified sentinels plus visible-null
checks, while B/C/D retain the existing TI/error/task-switch witnesses. The
historical unenforced hidden-base diagnostic is an explicit optional legacy
artifact, not a standard image. LegalSS accesses do not prove a hidden nullDS
base of0. A first integration attempt exposed the runner's grep-based image
parser matching a nested legacy `image` key; that key is now `artifact`.
Closed-return/footer grading now passes all21 host tests. Fresh standard
`pselnull` evidence in `aUqHZB/pselnull-oct01.2/` completes with actual native
status133, 607 legacy records in5490 clocks, zero I/O desynchronization,
exactly GP4 then TS4 and all five terminal witnesses. QEMU independently
completes its604-record flow with the existing case-D postcommit task-switch
gap explicitly retained; no full-stream equality is claimed for that gap.
The full system umbrella is not yet green.

## October1 enforcing-profile system followup

All55 generic `verify-sys` recipes were run against frozen TB6ae in
`aUqHZB/system-generic-oct01.1/`: 53 returned their expected success markers,
and `pdescprec`/`pxwrap` failed. This is not55 RTL correctness passes:
`ppriv` still explicitly skips its RTL leg and some existing gates are
witness/partial-oracle checks. Standalone structural/profile gates remain
separate obligations.

`pdescprec` was another illegal-null-DS fixture use, not an IRET defect.
Both traces agree through the outer IRET at oldPCF0668, returning DS0 as
required after the handler loaded DPL0 DS. The following default-DS store at
oldPCF0501 must GP0, whereas QEMU softmmu allowed it. Two register-only DS23
reloads now precede the next data accesses. All17 descriptor cases, handlers,
frame offsets and expected error codes remain unchanged. Fresh full-stream
comparison in `aUqHZB/system-followup-oct01.2/pdescprec/` passes2572 records;
an additional normal-I/O run reaps133 after2572 records/21110 clocks, with
exactly8 GP,8 NP,1 SS and no other faults. Closed trace SHA:
`0d7fb774af7cc0a3805b2a1ebb06b838f01a11110324425c2d090214825e3e55`.

The same frozen model also passes the three focused paging-on V86 QEMU
comparisons: `pv86cswrite`1022 records/six intended GP, `pv86far`1226/six GP,
and `pv86iret`899/one GP. These directed paths are not Win95 desktop proof.

The retained `pxwrap` native log proves its stop was not a host timeout or
clock cap: it quiesces after76407 reported records/729574 clocks following a
fault cascade. Case304 uses a single dword at stack offsetFFFFFFFE with
limitFFFFFFFF; its byte extent exceeds the segment limit. Intel's pinned
1997 Vol3§4.3 requires this extent rejection; QEMU's missing check cannot
justify disabling RTL enforcement. The fixture-only repair is now qualified:
relocate the offset toFFFFFFFC under SS.base2, preserving the same linear
FFFFFFFE-to0 wrap, page matrix and CR2 expectations. Fresh pinned QEMU/TB6ae
comparison passes112630 complete records in `aUqHZB/pxwrap-legal-oct01.1/`;
canonical grading finds exactly348 PF2,332 GP60 and the intended V86 GP0,
with no escalation. Eight host invariants independently preserve all351
cases and every original linear byte/page/CR2. This does not replace the
standard suite. The preceding PF belongs to completed legal case303, not the
invalid case304; no PF-before-SS defect is demonstrated. A separate explicit
segment-rejection witness is still needed for that invalid-offset shape.

## Evidence receipts

Artifacts are under the ignored
`ao486-sim/obj_dir_win95_ioperm_native_sep30.ePtDku/` directory:

| Artifact | SHA-256 |
| --- | --- |
| `qemu-firstsetter-reference-sep30.2/receipt.json` | `35111f62303a2c7611fc5f441487a5e27db71d17dd9831a08d6706aa57077185` |
| Reference observed driver | `2112287ba9407edcff83dc70d226807834bdecb9eeb01ad5aee13d5eef603841` |
| `firstsetter-bitmap-code.json` | `c836ec66dc6a80fba71b5fb036f81f6651bd743fbd5e9c669e0d71795c83aaf9` |
| Offline resource receipt | `c8679c86caaf8b1d38fb3fc70f69b74314cf2a2b5d429fbe011fd9113b483660` |

Reference invocation: `41eb81749f8149be9684b4eec4c4828d`, CPU 3 / 2 GiB /
no swap / 16 tasks / 300-second hard cap. Offline invocation:
`d57bf0a31992430291028462a3b8372f`, CPU 3 / 512 MiB / no swap / 16 tasks /
120-second cap; actual closure 20.632 seconds, zero OOM events.

Latest verified gameplay IPC is **0.44499855**, `cdcb`, cycles **6.9–7.0B**:
clocks 6,899,999,637–6,999,999,637, retirements 2,792,702,587–2,837,202,442.
The 44,499,855 retirements reconcile with U 33,541,392 + V 10,958,463
in 100M clocks; raw frames 61/62 advance gameplay. Different demo scenes do
not establish a code-change gain or regression.
It predates the bit-string and selector-query repairs; neither repair has a
qualified gameplay measurement.
No FPS gain or full-suite pass is claimed.

## Separate open fidelity issue

The frozen query candidate still has two pre-existing limitations found in the
read-only followup. Neither has been demonstrated as a Win95 boot failure;
do not replace the running acceptance binary or claim the ten microcases cover
these paths.

- Explicit memory-query reads do not invoke a DR7 read/write data-breakpoint
  check. `S_LOAD` hands off to `S_DQUERY`, whose shared retirement handles TF
  and execution breakpoints, not read watchpoints. A general repair needs a
  fault-qualified read-range match latched until architectural completion,
  precise post-query flags/destination and #DB delivery, and no watch on the
  implicit supervisor descriptor reads. Directed witnesses must cover a
  successful word query, null/OOB query with a real explicit operand, crossing
  operand/descriptor faults, and TF/data-breakpoint combinations before a
  broader read-debug change is accepted.
- `desc_limit16()` keeps only the low16 bits of a scaled LDT limit. LLDT and
  task-switch staging use that value: a byte-granular limit10017 becomes17
  and falsely rejects TI1 selector1C (entry bytes24–31); a granular limit10
  becomes0FFF rather than10FFF. This statically differs from pinned QEMU's
  full cached limit. Intel1997 Vol3§4.3.2 explicitly calls LDTR's limit32bit,
  while§2.4.2 says16bit, so do not claim a measured P54 silicon result from
  the prose alone. Proposed general repair: retain the full scaled limit
  through LLDT, staged task reload, SMM/RSM and debug scan, keeping GDT/IDT's
  architectural16bit limits distinct. Add independent large/G1-LDT query and
  segment-load witnesses, null-LDTR/no-access controls, task-switch and SMM
  roundtrip coverage; never wrap a limit modulo65536.

The new CoreMark matrix's CLI return0 also does not alone prove correctness:
its final required-fields check omits the guest validation banner. Closed
acceptance must independently require both standard seeds, all five exact
CRCs, the validated/no-ERROR report, original1500/2000-byte contract, actual
normal waits, unchanged inputs and the final resource/child-closure receipt.
The currently loaded driver is frozen; any driver tightening waits for its
owned jobs to close, rather than altering their provenance mid-run.

Current CPUID advertises MMX although this non-MMX P54C implementation does not
implement it, and reports family 5/model 4 instead of the P54C model 2 identity.
A coordinated target/oracle profile and capability tests are needed. Do not
blindly enable VME, change ongoing frozen runs, or suppress CPUID differences.
This issue is separate from the demonstrated memory bit-string addressing bug.

The bit-family audit also found that reserved `0F BA /0..3` encodings are
accepted instead of raising #UD, and read-only BT does not check read/write
data breakpoints. These pre-existing defects are not repaired or claimed covered
by the eight address/write-fault cases. Non-flat/finite-segment and post-store
#DB coverage are also still needed.
