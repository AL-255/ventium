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
  precise post-query flags/destination and #DB delivery. Implicit supervisor
  descriptor-read watchpoint behavior needs a separate oracle/spec witness;
  it is not yet established that these reads should be exempt. Directed
  witnesses must cover a
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

### October 1 live-suite followup

All four current native jobs were revalidated alive on their actual frozen
executables and CPUs: Win95/Quake `e572d518...` on 8/12, CoreMark
`fe4a21d7...` on 10/11. No new DUT run or RTL change accompanied this audit.
Win95's sampled `0028:C036F70C` startup loop is finite: the old `c0e5` cold
log and fresh run both enter it around 334.9M clocks and leave at 346.4M.
All 727 common CS/PC/retirement observations through 372.4M match exactly.
This rules out that observed loop as a newly introduced stuck state, not a
later boot defect. Fresh Win95 reached 400.9M clocks with no terminal error;
the old 457.3M VERW fault point and desktop acceptance remain ahead.
Both CoreMark seeds reached at least 469,762,048 clocks without an OOM.

The new latest verified gameplay baseline is **0.43107762** on the bit-string
repair binary `c0e5206ea2233f98dae7b60288a513e2dc5a3de5c9622d002e33d96b356b7958`.
Profile clocks **1,599,999,637–1,699,999,637** contain 43,107,762 retirements
(493,336,944–536,444,706), exactly U 33,045,867 + V 10,061,895 in 100M clocks.
Actual `/proc/623348/exe`, private executable, ROMs, command, CPU9 and zero
OOM counters were checked against the cold staging receipt; no live disk
was read. Complete raw 320×200 frames 08/09 were viewed without color changes
and show advancing gameplay (weapon/enemy action). Raw hashes:
`e526845465a74a632ec18aee82222493aa2efc08d85c7fe8d18c0b7b84b945e6` /
`574a4cc78e28c9f18357d40cb9b093936831038c0ced3fd3e48f0872ec39ddc2`.
The ignored local receipt is
`ao486-sim/obj_dir_standard_bitmem_sep30.S9VlV4/quake/gameplay-window-oct01-1p6-1p7.json`,
SHA256 `8ffa4438783255957157ab1f19ee11ee786910c1599821e7d5b1b119f43f5de3`.
It supersedes the older cdcb 6.9–7.0B number as the latest observed build/window;
the current query-repaired `e572` candidate is still unmeasured. Different
scenes do not establish a fix gain/regression, FPS or timedemo completion.

The independent closed-CoreMark grader must also reject `timed_out=True`:
the current matrix can otherwise accept a timeout race followed by a valid
guest report and graceful native exit 0. A transient unit's default
`Result=success` after unloading is not a historical wait result; retain the
exact invocation's terminal supervisor evidence. The loaded driver remains
unchanged while its seeds run.

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

## October 1: closed CoreMark PASS, new Win95 fatal return, targeted captures

The query-repaired candidate's **two full CoreMark correctness seeds PASS**.
Both run the unchanged 2000-byte standard workload for 1500 iterations, print
`Correct operation validated.`, match all five reference CRCs and actually
exit zero without timeout. Performance: 713,805,640 clocks / 542,165,430
retirements, **2.10141237 CM/MHz**; validation: 712,760,043 clocks /
541,458,819 retirements, **2.10449507 CM/MHz**. These counts and guest reports
are identical to the preceding bit-string repair's complete runs: no measured
CoreMark cycle regression from the query repair. They are not gameplay IPC/FPS.

Frozen TB SHA256 is `fe4a21d733c5e7223e19ff3b2d2d30a71ff3a8f1cd6013456087a04ddb7c1e79`.
Independent closed qualification is retained under
`verif/tb/obj_dir_verrw_oct01.M2bz8N/coremark-standard-oct01.rwe4r3/closed-qualified.json`,
SHA256 `0593bb8bb046dcf9ed8145d2e746f88d3c31f787a58a99229aff93534014a9b5`.
It binds both raw reports, actual native waits, exact loaded helper archive,
unchanged inputs/generated headers, zero OOM counters and the exact owner's
terminal supervisor receipt retained before unit collection. Ordinary native
file logs are observed functional evidence, not retroactive sticky-capture or
compiler-ancestry proof. The new closed checker and the repaired matrix acceptance
predicate pass **40 host tests**; commit `4a537f4` rejects guest errors, absent
validation, insufficient duration and graceful timeout/exit-zero races. The
explicitly authorized 60-minute seed cap is retained; no new DUT run was used
for that host-tool repair.

The fresh e572 Win95 cold boot avoids the former 457M VERW #UD, but then
**FAILS**, not boots to the desktop. Actual log line 20725 records #GP at
`0117:00006522`, error `0000ECC4`, printed between progress records for
488,163,870 and 488,663,870 clocks. Buffered fault stdout makes those records
an observation bracket, not an authoritative fault-cycle bracket.
Seven passive VGA text samples from 500,026,424 through 650,026,424 show
`A fatal exception 0D has occurred` at that same address. Fetched low bytes are
`66 CB` (prefixed RETF); effective width still requires CS.D. Error ECC4 alone
does not establish the raw popped CS/RPL, descriptor reason or root cause.

The failed run was gracefully stopped at 672,163,870 clocks / 155,079,575
retirements. Its actual native wait/EOF/sticky-capture receipt and unchanged
inputs are preserved. The original helper missed this fatal banner and reported
`clean_exit_unqualified`; it never established desktop acceptance. A separate
independent FAIL receipt, without rewriting the original result, is
`ao486-sim/obj_dir_standard_verrw_oct01.ckekDl/win95/fatal-0d-failure-qualification-oct01.json`,
SHA256 `fd1f61dac8d96a2b3807fd54b3a095b22e68d2c7b4877e171a2c84fd5c412daf`.
Closed log SHA256 is `d7dbd5f93c1af0fa776129fbb76657dea6c9acea2517da50ce4b3b7dcb1808ef`.
Live zero-OOM observations are recorded separately; final machine-persisted OOM
counters are unavailable after cgroup collection. The fatal banner proves FAIL
irrespective of that limitation. The vector6 fault ring saturated before 455M;
absence of the later GP from that ring proves nothing.

Two new same-e572 **cold diagnostics**, not acceptance passes, are actually
running under `ao486-sim/obj_dir_win95_retf_oct01.pP4BlM/`: CPU10 requested
480M save-stop/V4 (mouse state), CPU11 a 495M run with vector13 fault history
starting at retirement107740000. Invocations are
`0cc3c5957f094907961a5289571a29e5` / `ddbfbf6df34b4dcfa888398929d009a1`.
Both have fresh pristine-media copies, unchanged ROMs/native model/profile,
2GiB RAM/zero swap/32 tasks/one CPU, 4GiB per-file limits and 60-minute wall
caps plus whole-cgroup cleanup. No RTL, guest bytes or FPGA build was changed.
Future replay requires the actually closed pre-fault V4 snapshot paired with
its own closed disk, same executable/ABI/profile, and a new private replay disk.
It cannot reuse the failed 672M disk or enable fault-ring history on restore.
Actual save must precede 488,163,870; a requested save time is not proof.

The new diagnostic wrapper has a conservative final-census defect: it expects
only its Python worker in the cgroup but its known timeout supervisor also
remains until worker exit. The original script/runs remain unchanged. Native
diagnostic evidence will require independent closure grading with exact recorded
parent identities, actual native wait/EOF, unchanged pins/no OOM/no deadline and
the completed snapshot or target ring; neither wrapper exit nor that false
single-worker census is accepted as native success. This is a host qualification
issue, not an RTL repair or permission to ignore unexplained failures.

An independent word-sized LCALL/RETF extent/read-strobe defect is being given
focused differential fixtures; it is **not** yet proved causal for this RETF.
The standard suite is **CoreMark PASS / Win95 FAIL / Quake incomplete**.
Latest verified gameplay IPC remains **0.43107762**, `c0e5206e` profile clocks
1,599,999,637–1,699,999,637, predating e572. The e572 cold Quake run is live
with no verified gameplay measurement or completed timedemo yet.

## October 1: far-frame width repair, full directed matrix PASS

The independent word-frame defect is reproduced and repaired. The frozen
pre-fix TB `fe4a21d7...` delivered false #SS for legal word far CALL/RETF
at SS.limit (cases1/2), and false #PF for a word RETF ending at page boundary
(case4); DWORD control17 completed normally. The primary faults are present
in the separately captured `rtl.stdout`; their later quiescent exits are
not an absence of faults. Cascading #SS during exception-frame delivery exposed
another defect: the same-privilege DWORD-gate push address omitted `stk16`.
The final generic GPR writeback already preserves the high ESP half; no
independent ESP-writeback defect is claimed. A separate INT-frame fixture is
being prepared before changing that address path.

The width repair has three functional assignments, no new state, cache flush,
stall, guest patch or workload check: LCALL `cur_size=lc_callw`, all RETF slots
`cur_size=q_w`, and RETF read byte enables matching q_w. Existing DWORD
accesses keep their four-byte behavior. Word writes already had exact strobes;
their error was the segment-check extent. Word return reads needed both extent
and strobes so the fragment engine does not probe nonexistent tail bytes.

New source-controlled `pfarwordwidth` has32 independent CALL-only/RETF-only
cases: CS.D0/1, SS.B0/1, WORD/DWORD frames, and segment/page boundaries.
Based code descriptors keep16-bit return offsets valid; CS16 witnesses use
explicit address32 so absolute observations cannot silently truncate. Each
case requires actual free pinned-QEMU exit133, completed GDB trace, actual
native exit133, zero canonical faults, exact ESP/frame/control witnesses,
normal stop/footer/I/O closure and the complete existing architectural diff.
Twenty host mutation tests check these contracts; the gate never builds a
model or guest implicitly and is bounded below10 minutes.

Width-fixed TB SHA256
`ba8effe8167c3d88da2d95562256a29847047150eff391afe0af7d3fe3c0e17f`,
compile-record SHA256
`c9027d1a8656e6827af9a6680e8d0586f3930b678f3af1b1da87c343856c41ac`:
**all32 cases PASS**, all child exits133, zero faults and unchanged inputs.
Local summary SHA256
`a9be776af1f491db4f67ef381f279974639625639c72f60a967354e218b31bb6`,
under `ao486-sim/obj_dir_win95_retf_oct01.pP4BlM/design/pfarwordwidth-fixed-oct01.1/`.
The reviewed test sources at that run are archived under
`verif/tb/obj_dir_farwidth_oct01.FCKHi2/reviewed_test_sources.872uee/`.
`make verify` on this frozen TB passes108 functional programs and all19
gated timing bands; the20 reported per-instruction cycle divergences remain
non-gating diagnostics, not correctness passes. All five strict lint profiles
pass. The32-job,16GiB-capped build took68.3 seconds.

These legal frame tests do not cover outer-privilege returns or MMIO read
side effects. This fix is **not established as causal for Win95's prefixed
RETF failure**, and no new-candidate standard-suite pass is claimed. The
e572 checkpoint/vector13 runs remain unmodified; their intact progress prefixes
match the original failed boot through at least425M/433M clocks. Normal earlier
V86 faults are not a new cold-path divergence. Actual closed capture and
fault-edge ACK/selector evidence are still needed.

Latest verified gameplay IPC remains **0.43107762**, c0e5206e, profile clocks
1,599,999,637–1,699,999,637. It predates e572 and this width-fixed RTL; both
remain without a verified gameplay measurement. CoreMark's previous full-seed
PASS belongs to fe4a21d7, not the new ba8effe8 TB. The full standard suite
remains incomplete, particularly Win95 desktop and Quake timedemo completion.

## October 1: interrupt stack-address repair and qualified checkpoint

The secondary exception-delivery defect now has an independent reproducer.
Eight `pintstackwrap` cases vary WORD/DWORD interrupt gates, SS.B0/B1 and
low/wrapping stack placement. Before the address repair, DWORD/B0 cases1/5
produce #SS at `S_INT_PUSH` and quiescent exit0; all six controls pass. Handlers
check actual pushed IP/CS/FLAGS, adjacent sentinels, full handler ESP and full
ESP restored by IRET. No paging or error-code-frame coverage is claimed.

The repair applies `stk16` only to the same-privilege DWORD frame's subtracted
offset, before adding SS.base. Slot width, byte enables, cross-privilege frame
planning and writeback are unchanged. It adds no state, stall or guest-specific
condition. This INT3 witness proves the address defect independently of the
earlier far-frame width defect; neither is yet proved causal for Win95.

Combined model SHA256
`4f5e65cf828323161e8233913fabb5e08c07dae8188099167afcd170ebe7d1a3`,
compile record SHA256
`4bc4561a175b828512d0f724ba6c838930aca3c7bca8d8e5ffd0b5e93d31d7fc`:
all eight cases PASS with actual exit133, zero faults,83 records and824 clocks;
all32 far-frame cases PASS;108 functional programs,19 gated timing bands and
all five lint profiles PASS. The fresh32-job build took58.9 seconds.
Eighteen host-contract tests also pass, including refusal to overwrite/reuse
an existing or symlinked assembly-output directory. The originally reviewed
sources are preserved in `verif/tb/obj_dir_intstack_oct01.aBIBvx/pintstackwrap-reviewed-sources.sthi6s/`.
The final eight-case summary SHA256 is
`d5c3d708b7f32ed9940898d58bc88d46e3fe8bc67a2ca28ee41ce92a881e6dee`
(`design/pintstackwrap-fixed-oct01.2/`);32-case summary SHA256 is
`b847b4f4e51fa443a740a649208af2b40708366063f1d5d4e972fc7928fac719`
(`design/pfarwordwidth-intstack-fixed-oct01.3/`). Both are under the owned
`ao486-sim/obj_dir_win95_retf_oct01.pP4BlM/` parent. Two preceding four-worker
far-frame attempts had one QEMU GDB-stub connection failure apiece, not a DUT
mismatch; their FAIL receipts are retained. The complete two-worker retry
passed. The cause of those oracle-startup failures is not established.

The cold e572 checkpoint closed at exactly480,000,000 cycles /105,940,602
retires. Actual native wait0, EOF, unchanged input/source pins and OOM0 are
independently checked. Its wrapper really failed exit1 because its final
process census counted its still-owned timeout ancestor; that failed wrapper
status is preserved, not relabelled as a suite pass. Closed diagnostic proof
SHA256 `16a944a10dfaee285e4fbf94cdbf4b195a71dd670d77dd07f24f3cc10d9804d9`
permits passive inspection of only the exact snapshot and same-run closed disk.

The passive parser initially failed closed: an older helper treated serialized
FIFO entries as24bytes, but pinned e572 writes20bytes (uint32 address plus two
uint64 values). A FIFO-only adaptation, with nonzero-FIFO positive and negative
fixtures, passes17 host tests and the actual eight-entry capture. Extraction
SHA256 `98f6dd7aa0dff76274294f87b462d77505722e9230dbffd5aedee345f2a9cffe`
shows CPL3/VM0, CS0117.D0, SS0097.B0 and stateS_LOAD—not the RETF fault edge.
Sixteen sampled stack dwords agree across DDR/L1/platform-cache layers, without
overlapping pending writes. Pending reads and non-quiescent state are preserved.
This does not establish the later popped selector or exclude earlier corruption.

The completed vector13 ring contains three BIOS faults but misses the target
0117:6522/ECC4 event; target qualification FAIL is retained. Buffered fault
stdout cannot establish the exact cycle/retirement from its placement between
stderr progress records. Next diagnosis uses the same native checkpoint ABI,
a fresh copy of its paired disk and bounded host traces; it is replay evidence,
not cold-boot acceptance. A separate stale explicit-ESP decode-metadata #DB
writeback hypothesis still needs a dedicated witness before any correction.

Latest verified gameplay IPC remains **0.43107762**, c0e5206e, profile clocks
1,599,999,637–1,699,999,637, predating e572 and both frame repairs. No newer
candidate gameplay IPC or standard-suite completion is claimed. The e572
CoreMark full seeds passed previously; Win95 desktop remains FAIL and Quake
timedemo remains incomplete. The new combined frame model still requires the
complete standard suite before its integration can be declared complete.

## October 1: stale explicit-ESP ownership during a debug-trap frame

The dedicated MOV ESP / LEA ESP single-step witnesses confirm a third general
processor bug. On an SS.B=0 stack, the explicit instruction correctly changes
BEEF7000 to DEAD0000, but its retained `q_writes_reg`/`q_dst_reg` metadata then
incorrectly owns the implicit S_INT_PUSH update. The old ownership exemption
bypasses high-half preservation and commits handler ESP=DEACFFF4 instead of
DEADFFF4. Both old-model executions fail in the handler with actual exit135;
both pinned-QEMU executions pass. This is independent of the earlier address
wrap correction, which is required to reach the writeback corner at all.

The repair excludes S_INT_PUSH and S_RMINT_PUSH from the stale decoded-destination
ownership term. Explicit MOV/LEA ESP writes remain full-width; frame updates
retain their architectural stack-width behavior. No blanket metadata clearing,
extra serialization, guest change or workload-specific bypass is introduced.
The real-mode exclusion shares that invariant, but these new cases exercise
protected-mode same-privilege #DB, not every real-mode/V86 delivery path.

Frozen TB SHA256
`9a7976f79c824b7b00869d411af8ed4b3d60c41c0a5b27ad60e0001e77f17e4d`,
compile-record SHA256
`c15682778f3ad352ed33cc412b7244165cfb781caff4e44f4ef407671de0a937`:

- Both new cases PASS: 96 records / 936 clocks each, actual exit133, exactly
  one TF trap, correct saved frame/DR6/guards and full ESP after IRETD.
  Summary SHA256 `5acdae4374bf451ab55cb580e29d98f0b4045d452c3a696c27683cfd0612d061`.
- All eight INT3 stack-wrap regressions PASS; summary SHA256
  `04f2780d78501de0bcf024edd4e5bf2aa510ef00257c74c6d770f792a0d75395`.
- All 32 far-frame width regressions PASS; summary SHA256
  `76d0605e02ddd029a7d755167ad6841aeed7fa906da8b645bebab067d54a3b80`.
- Fast gate PASS: 108 functional comparisons and 19 gating timing bands;
  the 20 non-gating per-instruction cycle divergences remain separately reported.
  All five strict structural lint profiles PASS.

The 42 directed cases use complete standard functional differential with no
additional masks or row filtering. Existing defined/undefined EFLAGS masks
remain; new #DB witnesses explicitly inspect TF/RF, saved FLAGS/IP and DR6.
All directed summaries retain source/model pins and actual native closure.
Original reviewed test inputs are archived under
`verif/tb/obj_dir_espdebug_oct01.eo9QA1/pespdebug-reviewed-sources.85N32M/`.

The newer e572 cold Quake run now has a visually verified gameplay window:
**0.43107762 IPC**, profile clocks **1,599,999,637–1,699,999,637**. Its exact
retirement/U/V counters and endpoint frame hashes match c0e5; no IPC change
is measured in that corresponding window. Receipt SHA256
`bdc4190d6970f7b9a70033ace75114d0ce73ef39d714d0a5eb470a0108193603`.
This supersedes the earlier c0e5-labelled baseline, but e572 still predates all
three new frame repairs. Their gameplay and complete standard-suite results
remain unmeasured; prior full CoreMark success does not qualify the new build.
Win95 desktop and completed current Quake timedemo are still unproven.
