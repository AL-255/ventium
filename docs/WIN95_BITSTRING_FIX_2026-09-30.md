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

## October 1: POP memory destination corrupts the Win95 RETF frame

A closed, same-build diagnostic replay now locates the Win95 error precisely,
superseding the earlier coarse around-488M attribution. At cycle480553474,
CS0117.D0 decodes `67 66 8f 44 24 08; 66 cb` with ESP0001A208,
SS013F.B0. The implicit POP source is physicalC55208. The explicit `[ESP+8]`
destination must use the incremented pointer, yielding linear1A214 / physical
C55214. The original implementation instead ACKs its write at C55210 on
cycle480553479. That overwrites the following DWORD RETF's selector slot:
the selector read ACKs C55210 on cycle480553489, faults on the next clock,
and eventually delivers #GP at0117:6522 with errorECC4.

The replay is diagnostic-only, not a cold-boot pass. Closed native log SHA256
`75d94bf68f01bbcc0a0b5e63f53131daa99eabb6dc4befe02ac40f7ac88a5a87`;
independent terminal receipt
`db290aafeaf0fa608d8faa0fce55701db2c8a51cca3043fc7e5f7fb6a255ce6c`,
under `ao486-sim/obj_dir_win95_retf_oct01.pP4BlM/replay-480m-edge-oct01.1/`.
The replay retained actual native wait, pipe EOF, empty owned process group,
unchanged input pins and zero OOM events. No cross-build snapshot was used.

Two independent fixtures reproduce the defect against the pinned Pentium
QEMU: the exact CS16 thunk with a following RETF, and a CS32 destination
sentinel without a RETF dependency. On frozen TB9a7976f7, both free QEMU
executions exit133 and both RTL executions exit135. The first corrupts the
return selector; the second leaves the intended destination untouched. Closed
red summary SHA256
`39c4dff71415c5a3641b6117dbb9a37f9be82b4609103a43973c0715ccdb6d39`.

The repair adjusts only the memory POP destination EA in the central decoder,
adding the operand width when the address32 SIB base is ESP. Implicit source
addressing and architectural ESP remain unchanged until successful final store
commit; address16 and register POP ESP are unaffected. No early ESP mutation,
second address generator, extra pipeline state, serialization, guest patch,
or workload-specific exception is introduced. The SS.B0-wrap destination
choice follows the pinned QEMU profile; later Intel manuals describe that
write location as processor-family-specific. The actual Win95 pointer does
not wrap, so its diagnosis does not depend on that ambiguity.

Both **unchanged original images** pass the original complete136-record goldens
on frozen repaired TB80d89a33, with actual RTL133 and unmodified
`compare.py --mode func --all`. Closed green summary SHA256
`e1f93416a77e5342a42f4f121f9ea8ec8e0cea4f95222c608f8eebeccdbd0bd0`.
This is directed evidence, not Windows95 desktop acceptance. The expanded
fault/cross-page matrix is still being qualified. Its first draft used DFA
instead of FFA for the crossing displacement: its apparent CASE14 pass was
an ordinary noncrossing write at2DFE, **not** evidence about page splitting.
The original failed fixtures/results are preserved rather than relabelled.

## October 1: POP write-watchpoints used the implicit source segment

An independent non-ESP POP matrix proves that S_STORE's data-write debug
check incorrectly used `dbase`, the implicit SS source base, rather than
`stbase`, the explicit destination's segment base. Frozen TB80d89a33 fails
the based-FS DWORD and based-DS WORD positive traps, and incorrectly traps
at the old SS-relative alias in the negative case. An ordinary SS-default
EBP-based control passes. All four pinned-QEMU executions exit133.

The repair changes the debug address calculation to `stbase + st_addr`;
string destinations retain their existing ES-relative calculation. The
underlying store, ACK, MMU and instruction timing are unchanged. Four isolated
fixtures at `verif/sys/tests/ppopwatch/` deliberately avoid ESP-based addressing
and verify committed memory, post-POP ESP, saved nextIP/CS/FLAGS, DR6.B0 and
IRET. Their checker retains the existing delivery marker and first-handler
instruction as distinct adjacent rows; neither is filtered. The initial
checker incorrectly required a unique handler PC, was corrected using closed
golden evidence, and its original source/failure receipt is archived locally.

Frozen TB4b81d6a5 / compile-record6c274d9a passes all four with actual133,
zero ordinary faults, exact trap counts, normal I/O/retirement footers and
the complete unmodified architectural differential (98/100/98/78 records).
All source/model/fixture pins remain unchanged. Red summary SHA256
`382a6675322ee0ead19bd2c56da8ba3e44344e9c022a050b6daad74b5d072e18`;
green summary SHA256
`36aa43400a7843911a681ea44893a1ababbc591f75b5bfe45963273f082ed7e6`.
Fourteen host contract tests separately pass; they are not DUT qualification.

Latest visually verified gameplay baseline is now **0.44240609 IPC**, e572,
profile clocks **2,399,999,637–2,499,999,637**: 44,240,609 retirements equals
33,816,593 U plus10,424,016 V events. Endpoint raw frames16/17 visibly
advance; actual executable, counters, frame hashes, held log prefix and owner
invocation were checked, with zero OOM events. Live-window receipt SHA256
`93a79361d56a08c186cb5ea5ae7b7b4ebc3aa6c348836cc4616eed94aebe3a67`.
This is scene-dependent measurement, not an isolated fix gain, FPS or completed
timedemo. e572 predates all current frame/POP repairs. Their gameplay remains
unmeasured, and **the current standard suite has not passed**.

### October1: corrected split-store witness and final candidate

The earlier CASE14 fixture selected2DFE, not a page boundary; its PASS was
not cross-page evidence. Corrected CASE14 selects2FFE..3001 and enforces
that geometry in assembly and host checks. On frozen TB4b81d6a5 it exposes
a second independent defect: one POP retires with ESP2008 rather than
QEMU's ESP2004. S_STORE's GPR writeback acted on both the preliminary
first-page ACK and final whole-store ACK. The sequencer itself retired once.

`core_gpr_wb.svh` now gates its S_STORE arm with
`mem_ack && (!xs_eff_act || xs_eff_ph == 2'd2)`, matching the existing
sequencer/store-lock commit. The repair preserves old GPRs until all store
fragments complete; ordinary unsplit stores are unchanged. There is no
new FSM, extra stall or workload-specific condition. Closed red summary
SHA256 `8941a876aa43683302b768842eca91ccad23c92d7033f260beff65895fb9df0a`.

Final TB SHA256
`2ce6ac0aab75fd27aa1e0f8abd5d6b7f1561a7a42ea5d8711f5fcfa980a98c5c`,
compile-record SHA256
`65bab2283a020e8babc5e21b80ab743b31a145990c13152fc8f9074a68944963`,
passes all16 corrected POP cases:15 full fresh-QEMU architectural
differentials and one explicit Intel SS-limit spec-only check (CASE13).
The split success is3237 records/25306 clocks, ESP2004; the second-page
read-only fault verifies no partial write. Native exits133, actual child
waits/groups/footers close and all pins remain unchanged. Final summary
SHA256 `9c0d585b4abbe35df2c3781d1d13e10ea1a26f59c6ebfeb054572793bc4e272e`.

CASE13 is not counted as a QEMU correctness pass: the pinned oracle omits
per-access SS-limit enforcement and exits135, while the compiled
VEN_SEG_ENFORCE model exits133 with the exact #SS witness. Separately,
the automatic fault-RF policy requires the Pentium-specific clarification
below; the earlier blanket Intel-fidelity-gap classification was too broad.
These fixtures check exact savedFLAGS2 for the current profile, never mask
flags or claim RF-retention qualification.

The same final TB passes make verify (108 functional programs and19 timing
bands) and all five strict lint configurations; actual outer waits are0.
The20 reported structural cycle divergences remain non-gating diagnostics,
not correctness passes. Log SHA256 values:
`ffb35c514a41d773815dd5ec92f6d975c12f3e0f12169e713af6f43ef6bb57ee`
(verify) and `9c7bb86c80ea3a03095564b47e278ab7cee1a8ed390aeb1742c69116702e49a2`
(lint). All four destination-segment watchpoint differentials also pass
on this TB, summary `2d8090a68555af59c001f04a556012798ae79f7b9ec4d437679a7d8433608064`.

The prior frame/trap repairs also retain all42 full differential passes on
the final TB:8 INT stack-wrap,32 far-frame-width and2 ESP-debug cases.
Alongside the4 watchpoint cases this is46 fresh differentials with184
closed child receipts, native/free QEMU133 and generator/comparator0,
no surviving descendants and unchanged input/artifact pins. Summary hashes
are `b86c3f330f1256f579200e5b9a304256a9fdeb76697ce3d6633f2549a2b5bfdc`
(INT), `25e439fe0c7cc7f0cb82096c20882a7fe78262aed3bcc3d61b2ae6ddeabb2cf6`
(far), and `e9293f506f2800b59d8e826b8d497f4990f5d4376183eaa2ad608c14f2ec2e23`
(ESP debug). These are directed regression results, not OS completion.

The final full-PC model is SHA256
`c611cf03f6e7a9d48a1b24fcc4e6b17e44533a3e33dd9a1ac82e70311c5253de`,
compile-record `5627099a0e9e9dcadeabe58c0c291a55e88832b77bd0509594cba46b7b955d31`.
Its uncached build retained275 input pins; independent prerequisite audit
covered all156 RTL and53 non-generated C++ inputs. It starts a new
unmodified-media Win95 cold boot in
`ventium-standard-win95-popwatch-oct01.service`, invocation
`72e81207798d471cb4eb1715a4e3faf4`, worker787847/native787860 on CPU8.
Actual executable/cgroup/argv admission is checked, memory2GiB/no-swap,
tasks32, nine-billion-cycle/72-hour native bounds; no snapshots, guest edits
or injected input. Startup advances normally and OOM counters are0.
Only separate closed visual/error-free review can qualify desktop.

Latest verified gameplay IPC remains **0.44240609**, e572, clocks
**2,399,999,637–2,499,999,637**, predating all current frame/POP repairs.
The final candidate has no gameplay/FPS measurement. Its full standard
suite remains incomplete; previous builds' results do not qualify it.

### October1: final-candidate standard suite is running

All three required components now have actual live native processes, not
just prepared launchers. No previous-build snapshots or guest modifications
are used. Win95 and Quake use final full-PC c611; CoreMark uses final TB2ce6.

| Component | Unit / invocation | Actual native PID / CPU |
| --- | --- | --- |
| Win95 cold boot | `ventium-standard-win95-popwatch-oct01.service` / `72e81207798d471cb4eb1715a4e3faf4` |787860 /8|
| CoreMark both1500 seeds | `ventium-standard-coremark-popstore-oct01.service` / `fe7d60fd6ddd4e3fb9d6d33c73e0c5ea` |796941 /11;796942 /10|
| FreeDOS Quake demo1 cold boot | `ventium-standard-quake-popstore-oct01.service` / `948ff446e9e04db7bb68478e90d6c3b5` |800886 /13|

CoreMark runs the unchanged1500-iteration/2000-byte workloads in parallel,
each capped at3600s, with exact reference CRCs and the corrected matrix
acceptance predicate. Forty host contracts pass. Its actual native admission
receipt SHA256 is `78b52f391357b8f600330a26391c4de2b37227f22a30c806e4bc2abe8713226e`;
a separate read-only D-Bus unit reference retains the real terminal status
for independent closed grading. Current heartbeats advance; neither seed
is qualified until actual error-free completion.

The Quake wrapper executes the exact archived canonical lossless collector
and checker; six host contracts pass. Its actual admission SHA256 is
`3bacc06c366715a71826fb8ba8bb35687e14380a0bd1b0cbb32d49852721b5e0`.
The pristine disk hash remains2df14ac9, clocks45/45/90MHz, DDR2,32MiB,
30B clocks/72h bounds. All three owned cgroups have zero OOM events.
Win95 has reached284M clocks without a detected fatal banner; this is
startup, not desktop proof or gameplay IPC. **No final suite PASS yet.**

Additional system-gate scrutiny found an inherited acceptance hole:
non-cosim OUT goes to S_HALT, so the old runner could report an equal
architectural trace while discarding native exit0/quiescence instead of
requiring the fixture's I/O success exit133. The original strict audit is
retained as FAIL, not rewritten. A separately labelled I/O-enabled pseg
diagnostic (`--system --cosim`) exits133, closes normally and matches all90
unchanged QEMU rows, summary
`55e142036fe72ed7361df72a9b05cb5b33f2785d991b6d7d768c953fc0fd184c`.
This is verification-profile evidence, not a new RTL workaround or whole
system-gate acceptance. Broader strict mode/completion checks are in progress.

Verified gameplay baseline remains **0.44240609 IPC**, older e572,
**2,399,999,637–2,499,999,637**. Final c611 is gameplay-unmeasured.

### October1: explicit real-I/O system completion audit

A separate closed audit of twelve existing system images on final TB2ce6
passes full, unfiltered architectural comparison: pseg, pmode, ppage, pcpl,
pintr, pfault, pfarok, pstk16, psoccallfmem, pcgpg, pxwalkd and pdebug.
Each native invocation explicitly uses `--system --cosim`, exits133 as
the fixture requires, and retains matching normal I/O/retirement footers;
free QEMU exits133 and each unchanged `compare.py --mode func --all`
returns0. The additional pcgpg rerun verifies ordered page faults
`(14,2), (14,0)`. Actual child waits and process-group closure are retained,
and input/artifact pins remain stable. Summary SHA256:
`70117c17110f76a54ca1b329a31c5c46cfa8804959c85026974e42013967aa1b`,
under `verif/tb/obj_dir_storecommit_oct01.RxNbj7/verify-sys-core-cosim-final-oct01.1/`.

This qualifies only those twelve image contracts, not all system gates or
the standard suite. Existing oracle limits remain explicit: pxwalkd avoids
observing probe A-bit timing; pdebug does not verify DR7.GD firing.
The original non-cosim FAIL archive remains unchanged. A verifier-only
repair of the ordinary system runner is being reviewed to make actual
completion mandatory, keep diagnostics and preserve failure receipts;
there is no new RTL or guest workaround.

Gameplay baseline is still **0.44240609 IPC**, older e572, clocks
**2,399,999,637–2,499,999,637**. Final c611 remains gameplay-unmeasured;
its Win95 desktop and completed Quake timedemo are not yet qualified.

### October1 11:48 UTC: final-candidate CoreMark closes successfully

Both unchanged standard1500-iteration seeds complete on final TB2ce6.
The independent closed checker returns0/PASS with all five reference CRCs,
matching raw guest reports and native footers, unchanged binary/image/header
pins, zero OOM events and no remaining owner/native processes. Performance
uses713805640 clocks/542165430 retirements (**2.10141237 CM/MHz**);
validation uses712760043/541458819 (**2.10449507 CM/MHz**). Guest durations
10.888s/10.871s exceed the ten-second requirement. These cycle counts are
unchanged from the preceding qualified build: no CoreMark regression is
observed from the frame/POP/store-commit repairs.

Closed qualification is
`verif/tb/obj_dir_storecommit_oct01.RxNbj7/coremark-standard-popstore-oct01.1/closed-qualified.json`,
SHA256 `2526babe48be446a8f0a4de5b5f2ae8f42e6bc881d1d5d7b6336b7628d7e4d41`.
The exact invocation's terminal supervisor receipt was retained by the
read-only unit observer before metadata collection: actual owner exit0,
`ExecMainCode=1`, inactive/dead, SHA256
`3e5df29cace8e631c70748581fa6cbe3d70ba1d3c5ef4e0a0b4b0477cab031fb`.
The checker independently verifies25 files. Its stated limitation remains:
ordinary CoreMark log files provide observed complete functional evidence,
not a historical lossless pipe-capture proof or compiler-ancestry proof.

The final c611 Win95 cold run separately advances beyond its predecessor's
480.55M POP/RETF failure checkpoint. The independently observed complete
2182119-byte log prefix reaches486720805 clocks/107032640 retirements,
CS0028:EIP C001EABE, with no fatal-error banner and zero OOM events;
prefix SHA256 `cc8dffeef4dd3fde756de21573ff8de4000f7499bf352391e8f16addeca84949`.
It subsequently reaches522M clocks without the old fatal screen. This is
live progress only: no closed visual desktop acceptance yet. Quake remains
live from cold reset. **Only CoreMark, not the whole standard suite, passes.**

Verified gameplay IPC remains **0.44240609**, older e572, clocks
**2,399,999,637–2,499,999,637**; final c611 is gameplay-unmeasured.

### October1: ordinary system gate requires closed native success

The ordinary step7 and pcgpg fault rerun now use
`verif/sys/run-native-system.py`: real I/O mode, exact manifest debug-exit,
contiguous functional/system trace fields, matching normal stop/retirement
and zero-desync I/O footers, unchanged input pins and actual child wait.
The unchanged full architectural comparator runs only after this native
acceptance. Separate stdout/stderr and fresh per-invocation native leaves
preserve diagnostics and earlier evidence. Each native invocation is capped
at90s/16MiB per output inside the verified build scope. The ordinary runner's
existing scope-entry hunk is a required integration prerequisite.

Forty host-only contracts exercise the production checker/launcher and
pass, including a byte-identical architectural trace with failed native
exit, timeout handlers returning0 or133, missing/duplicate/truncated
footers, replay/desync, signal death, leaked descendants, input deletion,
fast-exit admission and admission/census exceptions. The unreaped child
anchors any group cleanup before final wait; cleanup errors stay negative.
Containment explicitly assumes a non-escaping dedicated native group and
uses the enclosing build-scope cgroup for the broader tree. Host summary
SHA256 `2a7284a9854709605e96392819705056e55d7aabed4404f8976d956e842ddca2`.

The modified canonical runner then passes existing pseg, pmode and pcgpg
on final TB2ce6, including the actual pcgpg fault rerun and unchanged full
differentials. All four native receipts retain exit133, actual wait,
closed groups and matching footers; outer gates return0 and input pins
remain stable. Canonical summary SHA256
`f6efda50089017d4b0d1fa460aeb33f76efbb66a597a9c4a915967266b7c05f4`,
under `verif/tb/obj_dir_storecommit_oct01.RxNbj7/canonical-native-final-oct01.1/`.

No RTL, model, guest, golden, comparator mask or special SMM/witness branch
was changed for this repair. It is not full verify-sys acceptance. The local
psgdtpg/pbytemovpg manifests currently lack explicit exit_method/exit_port;
the helper rejects that missing contract rather than inferring success.
Their metadata and the untouched special/golden branches require separate
review. Gameplay baseline remains **0.44240609 IPC**, older e572, clocks
**2,399,999,637–2,499,999,637**; final c611 remains unmeasured.

### October1: graphics startup and standard-suite qualification scope

The same c611 Win95 cold run produces its first640x480 planar graphics
frame at600M clocks (black screen/hourglass), then a700M frame showing
"Building driver information database" at0%. Neither is a desktop or
closed-run PASS. Raw frame SHA256 values are
`26b50f0a0a1152196f40a3ec9c1085c8acf90e392160248a3431390acbcd9ef7`
and `6e1f06351799119e26cb4732f94569be47fd1db1c172743d80a5e2e5244c9e91`.
Inspection PNGs preserve every RGB byte, without color effects. Read-only
inspection of the original source image confirms pre-existing
`[boot] display.drv=vga.drv` and `shell=Explorer.exe`: this is an unchanged
configured cc68b005 baseline, not stock unconfigured installation media.
No display-fix script or during-run guest patch was applied.

Standard qualification must keep its declared profiles distinct: CoreMark
passes on TB2ce6's user/register-image, syscall-emulation/direct-memory
profile; Win95 and Quake run from cold reset on full-PC c611. All25 TB
defines occur among the107 full-PC defines, and149 common RTL/fp_shared
input pins match, but these are not identical compiled profiles or proof
of compiler ancestry. CoreMark's PASS does not alone verify the additional
full-PC cache/FP configuration. Only Win/Quake carry the cold-reset/no
snapshot/no during-run guest-patch claim.

Win95 acceptance still requires recognizable desktop frames in the closed
inventory, clean complete held capture, actual native wait/group closure,
final input/resource pins and supervisor terminal evidence. Use its owned
stop-request handshake only after observing desktop; prematurely stopping
the launcher service would disrupt final receipt generation. Quake still
requires the current cold run's closed969-frame timedemo and both canonical
and outer PASS receipts. **The full standard suite remains incomplete.**
Gameplay baseline is **0.44240609 IPC**, older e572, clocks
**2,399,999,637–2,499,999,637**; current c611 remains unmeasured.

### October1: RF authority correction and continuing GUI evidence

The generic1997 SDM (243192-001, section14.3.1.1, printed14-9) and the
July1995 Pentium manual (241430-004, section17.3.1.1, printed17-7/17-8)
describe different automatic fault-RF behavior. Pentium Specification Update
242480-041, clarification10, printed59/PDF67, explicitly makes the hardware
RF-setting circumstances implementation-specific. Therefore a blanket
RF0-to-RF1 change for every fault is not justified for this P54C target.
The original report's blanket automatic-RF bug classification is withdrawn,
not silently treated as a repaired or oracle-qualified behavior.

A separate source-supported issue remains: core_fetch_decode.svh clears
incoming RF during decode, before instruction success. Later32-bit fault
frames use those live flags. The Pentium successful-completion rule and
pinned QEMU's fault-frame save before handler RF clearing support testing
**incoming RF1 retention across a failed instruction**. Short RF0/RF1,
fault-versus-success fixtures are being prepared against existing finalTB2ce6;
no red run, RTL repair, flag mask or automatic-RF policy change is yet claimed.
IRETD/task-transfer entry-RF1 oracle behavior needs separate qualification.

The unchanged c611 Win95 cold run reaches the driver-information dialog
at15% in the1B-clock frame and16% at1.1B, still not desktop. Raw frame SHA256s:
`6afaa71f5e0e55e1f0538c0bc99a168bb5479675f0ad47772c7b774e479c1b0d`
and `221ea3b06f438907d56c45e03b7c8432bc60b69c19864e75513ce3e452821ec7`.
Inspection PNGs are byte-for-byte identical in RGB pixels. Independent
capture review finds the planar decoder identical to the legacy decoder,
but not equivalent to full VGA scanout: address/row/pan/mask/Color Select
and coherent frame-boundary assumptions are not established by FBCAP logs.
Thus the odd cursor does not yet demonstrate native pixel or RTL corruption.
Current build inputs and all three c611 executable copies still match pins;
Win/Quake are live, with no closure/standard-suite PASS. Gameplay baseline
remains **0.44240609 IPC**, older e572, clocks
**2,399,999,637–2,499,999,637**; current c611 is unmeasured.

### October1: incoming-RF retention is reproduced, not repaired

Four short cold CPL0/protected32 fixtures run on existing finalTB2ce6 without
any RTL/model rebuild. RF0 followed by UD2 and RF1 followed by one successful
MOV then UD2 pass complete architectural comparison. RF1 followed immediately
by UD2 or divide-by-zero is **RED**: the handler reads savedEFLAGS00000002,
where pinned QEMU preserves00010002. Both failures first diverge in EBP at
the full saved-flags read, then also differ at the handler's IRETD. All
59/59 records (60/60 for the MOV control) are retained and compared; no custom
RF mask, record removal, state restore or workload bypass was used.

Every native and separately free-running QEMU child actually exits133;
native debug-exit/retirement/I/O footers, actual waits and closed groups
qualify. Generator and comparators retain their own separate statuses;
generator0 is not presented as actual free-QEMU133. The driver returns1
and records RED, not a correctness PASS. Inputs remain pinned. Summary
SHA256 `79364258fde71ae7d7ae8e133a41c88d9d0615c9173ce953f673cfe2c500f90d`,
under `verif/tb/obj_dir_storecommit_oct01.RxNbj7/rf-retention-oct01.1/run-red-oct01.1/`.
Independent closed review rechecks all25 child receipts/groups,26 input
pins,50 stdout/stderr hashes and eight trace hashes. Observed source hashes
are provenance, not independently proven loaded-byte/compiler ancestry.
The unchanged canonical fault logger emits zero entries for direct UD2
staging and one for DIV's start_fault route; the fixtures explicitly install
only their intended IDT vector and verify the exact saved instruction PC.

Proposed general repair: preserve live RF until semantic instruction success
inside the existing EFLAGS owner, rather than restoring a stale issue-time
bit in only some fault paths. Account separately for synthetic interrupt/SMI
records, REP element versus terminal boundaries, after-execution debug traps,
IRETD/task-transfer/RSM exceptions and ordinary RETF sharing an IRET state.
PUSHFD must still mask RF/VM in its memory image. Additional boundary tests
and implementation remain required; no repair or complete standard-suite
acceptance is claimed. Win95/Quake's c611 cold runs remain unchanged/live.
At13:11UTC, Win95's1.3B-clock frame shows17% driver-database progress;
Quake's1.1B frame still shows the demo-loading console, not gameplay.
Gameplay baseline remains **0.44240609 IPC**, older e572, clocks
**2,399,999,637–2,499,999,637**; current c611 remains unmeasured.

### October1: successful-completion RF repair — directed checkpoint

The reproduced incoming-RF retention defect is now repaired in the working
candidate. Decode still snapshots issue-time RF/TF for debug decisions, but
does not clear architectural RF. `complete_reference_rf()` consumes RF in
the existing EFLAGS sequential owner only after ordinary instruction success,
including the final logical store completion and existing after-execute #DB
boundary. Its bit-select nonblocking assignment follows any whole-EFLAGS
assignment, preserving the newly produced condition flags. Ordinary outer
RETF consumes RF even though it shares an IRET state; genuine IRET, task
transfers and RSM remain flags-install/preserve paths. PUSHFD masks RF/VM in
its memory image independently of live fault-frame flags. This adds no new
pipeline state, flags owner, stall, workload recognition or snapshot repair.
It does **not** change the withdrawn blanket automatic fault-RF policy.

REP needed an additional correction: a provisional terminal-only RF clear
failed the pinned oracle at the first successful element of a two-element
REP. The current candidate consumes RF at the existing successful-element
retirement boundary, never an operand acquisition, page probe or partial
store acknowledgement. Both intermediate and terminal records then match.
This is differential qualification of the existing REP record contract, not
independent silicon proof for every REP/event boundary. The original RED
receipt is retained under `obj_dir_rf_boundary_oct01.VURRTw` (summary SHA256
`4d9d1de551a1f76e32dfc372e68260fbfc1ce4186d27eca8fec964208088d249`);
it is not relabelled as PASS.

Two reusable standalone suites are added under `verif/sys/tests/`:

- `prfcompletion`: RF0/RF1 immediate #UD, RF1 #DE, successful MOV, STC,
  POPFD and memory BTS. The already-set BTS bit is a CF/RF witness, not a
  changed-memory-value witness. Complete traces contain59/59/59/60/60/61/62
  records; saved flags include incomingRF on failures and retain new CF or
  whole-flags results on successes.
- `prfcompletion_fp`: successful FNINIT, FLD32, FNSTCW and FNSTENV28 after
  RF1 restoration, followed by #UD. Complete traces contain68/69/70/72
  records; selected stored fields are CW037F, SW0 and TAGFFFF. These are
  integer/system (`x87=false`) RF/completion witnesses, not complete x87
  datapath or environment-byte qualification.

Both suites use the independently prebuilt DUT and pinned Pentium QEMU,
compare complete `func --all` traces with RF included, require actual native
and separate free-running QEMU exits133 plus closed process groups, and
retain before/after input pins. No custom RF mask, filtered record, model
state edit, guest patch or snapshot is used. They are standalone multi-image
suites, not yet entries in the generic single-image system gate runner.

Actual October1 directed results:

| Model/profile | Integer RF7 | FP RF4 |
| --- | --- | --- |
| `a48fe77e` TB,25 defines, legacy FP | PASS | PASS |
| `03e19a08` TB,53 defines, shared FP subset | PASS | PASS |

Legacy summary SHA256s are `2e4a1371f8aa4cad88964493026d665eac1c2b9dbd15422376a8dcb564e1110e`
and `8936df7c6c5400f6adedea3723648998a3b04d04bf4ee5361a05aa39a77c403c`.
Shared-FP summary SHA256s are `fbd4a81775a374f15411367118fa28281c6388ac399f8078d867447cd2357baf`
and `8e357aff780a30d7035e3e0955f6fdd81e5962351915657538a77d82d0a85080`.
The shared-FP test build explicitly uses the existing probe's required
`--public-flat-rw` visibility; an earlier build without it failed to compile
because an optimized-away internal signal was absent. No RTL workaround was
introduced. The53-define directed profile is not the107-define full-PC build.

The PUSHFD/REP2/REP0 boundary suite also passes on a48f (summary SHA256
`593a610b4e42aa9b7e730c9c7ed01dd4e4746dc3a6aa38ebc8cd1cb3aa5a903d`).
Its actual waits/closed groups qualify;22 transport receipts nevertheless
retain a default `result=FAIL` metadata label. Those labels are not silently
rewritten or counted as22 PASS receipts. The a48f fast gate passes108
functional and19 metric comparisons;20 visible instruction-cycle differences
remain nongating, not exact cycle equivalence. All five lint profiles pass.
These are directed checkpoints, **not RF-general acceptance**: faulting
memory/REP phases, asynchronous events, RF1 HLT, debug/task/RSM corner cases
and complete FP-state equality need separate qualification.

### October1: fresh repaired-candidate standard suite is running

A fresh cold full-PC candidate was actually built and reaped successfully:
`ao486-sim/obj_dir_ven_rfcomplete_oct01.5mZtCG/ao486sim_ven_standard`, executable SHA256
`4092c92a9f626157c9a0fa872f0a09f031b32f49f9b0cfa20d192a9a46835cc8`.
It retains all107 c611 full-PC defines. Its275 unique declared input files
remain pinned; all152 actual common RTL prerequisites match the a48f TB
inputs. The broader input manifests have two identical filelist aliases;
277 raw entries must not be described as277 unique files. These binaries were
built from the pinned working checkout, including other retained local changes;
a selective RF-only commit is not itself a reproducer for every build input.
Component profiles and matching pins are not compiler/loaded-byte ancestry proof.

The repaired candidate's standard runs are independent of the still-live
older c611 Win95/Quake controls:

- CoreMark: a48f, both unchanged standard1500-iteration seed images, CPUs11
  (performance) and10 (validation), unit
  `ventium-standard-coremark-rfcomplete-oct01.service`, invocation
  `f3f484e2694b4403a93cc78ddea7a58a`, started14:19UTC. Actual live admission
  checks native `/proc` executable/argv/start identities, source/seed pins,
  two CPUs,2GiB/no-swap caps and OOM0. No seed completion or score yet.
- Win95:4092, unchanged cc68b005 source image copied to a private disk,
  CPU14, unit `ventium-standard-win95-rfcomplete-oct01.service`, invocation
  `74bd87ca8cfc49fe8916cbbb3946e1e8`, started14:25UTC. Cold reset; no
  snapshot, during-run guest patch or forced cache override. Desktop and
  clean closed-run acceptance are still pending.
- Quake:4092, unchanged FreeDOS/demo1 qk_td source image and private disk,
  CPU15, unit `ventium-standard-quake-rfcomplete-oct01.service`, invocation
  `b099b59a17634ce2acb8508c0e5fa0fd`, started14:25UTC. Cold reset; no
  snapshot/hook/guest patch. A969-frame timedemo and clean closed receipts
  remain required. Reaching gameplay alone will not count as PASS.

Only the CoreMark component uses its declared user/register-image plus
syscall-emulation/direct-memory profile. Win95/Quake use the full-PC shared
FP/cache configuration at45MHz core/RTC and90MHz VGA. Each OS native is
single-CPU capped at2GiB with swap disabled. The CoreMark metadata observer
holds the actual supervisor invocation and may discard idle RemainAfterExit
state only after normal owner exit, actual zero-child receipts, absent PIDs
and an empty cgroup; it does not stop a live DUT or manufacture a wait tuple.
All three standard components must actually close and pass before this
repair is declared complete. **The full standard suite remains incomplete.**

The latest verified gameplay measurement supersedes the old e572 baseline:
**0.42689244 IPC**, c611 executable `c611cf03`, profiler clocks
**1,399,999,637–1,499,999,637**,100M clocks with42,689,244 legacy retire events
(31,813,033 U +10,876,211 V). Raw frames6/7 visibly advance world/camera,
weapon and pickup state. The measurement receipt is
`obj_dir_ven_popwatch_oct01.52WV37/quake-cold-oct01.1/gameplay-window-1p4-1p5.json`
(SHA256 `19eef64d3e639bce6b5222940a0609079c4b42ff01a3193ae7e032a0b228404b`).
This is a held live-prefix gameplay observation, not completed timedemo FPS,
closed sticky-capture evidence, REP-normalized architectural IPC or a matched
before/after performance comparison. **c611 predates the RF repair; current
a48f/4092 candidates remain gameplay-unmeasured.**

### October1 14:59UTC: repaired-candidate CoreMark component CLOSED PASS

Both a48f standard seeds finished normally in approximately40 host minutes,
within their60-minute caps. The unchanged independent closed checker actually
returns0 and qualifies both complete raw reports, all five CRCs per seed,
native waits0, normal guest exit_group(0), input/source pins, empty child
groups, OOM0 and exact supervisor invocation. The metadata observer retained
the actual f3f484e2 invocation through normal owner exit; only after all three
recorded PIDs and the cgroup were absent did it discard idle service state.
The preserved actual terminal tuple is inactive/dead/MainPID0/success/1:0,
not an unloaded unit's default success response.

| Standard seed | Total program clocks | CM/MHz, total program | CM/MHz, measured clock window |
| --- | ---: | ---: | ---: |
| performance1500 | 713,805,640 | 2.10141237 | 2.10162988 |
| validation1500 | 712,760,043 | 2.10449507 | 2.10469241 |

Performance CRCs are e9f5/e714/1fd7/8e3a/25b5; validation CRCs are
18f2/e3c1/0747/8d84/e230 (seed/list/matrix/state/final). This qualifies the
CoreMark correctness component; scoring remains a separate observation.
The closed qualification receipt SHA256 is
`7da3529e8d8c14883b791e01cc6480b504ca29090a3cfb65d9497442cc3c2f4d`,
under `verif/tb/obj_dir_rfcomplete_elem_oct01.dskIXX/coremark-standard-rfcomplete-oct01.1/closed-qualified.json`.
The root-observed supervisor receipt SHA256 is
`84b8a32b8cb9fa414a21c275980c0797ba36ae7412c9707d48cb4421af04aca3`.
Ordinary file logs still lack historical sticky pipe-loss receipts; this is
observed closed functional evidence, not retroactive lossless-capture proof.

RF repair, fixtures and directed checkpoint were selectively committed and
pushed as5882b8b; unrelated local edits and artifacts were not included.
Win95/Quake remain live and unqualified. The older c611 Win95 control's
latest inspected frame shows driver-database progress60%, not desktop.
The newer4092 run is still early boot, with no accepted desktop frame.
**Standard suite: CoreMark PASS, Win95 pending, Quake timedemo pending.**
Current verified gameplay IPC remains **0.42689244** on pre-RF c611, clocks
**1,399,999,637–1,499,999,637**; the repaired candidate is unmeasured. These
CoreMark scores are not Quake IPC, FPS or a matched before/after Quake gain.

### October1 15:09UTC: existing system regressions on shared-FP candidate

The prebuilt03e19 shared-FP TB passes the16 existing ordinary system gates
`pseg pmode ppage pcpl pintr pfault pfarok pstk16 psoccallfmem pcgpg pxwalkd
pdebug ptask ppopf psysfpreloc psysfpload`. They compare all18,329 architectural
records using the unchanged full `func --all` comparator. All16 canonical
runners actually return0; all17 strict native invocations, including pcgpg's
separate fault rerun, exit133 with normal footers, unchanged inputs and closed
groups. Free-running QEMU exits133 in each gate. The pcgpg rerun has exactly
one destination write-probe #PF(2) and one source-read #PF(0), no other fault
or escalation. Independent read-only audit confirms traces, waits, receipts,
empty groups and all109 input pins plus16 post-run pin checks.

Evidence is retained under
`verif/tb/obj_dir_rfcomplete_fp_public_oct01.OPhKB9/ordinary-system-oct01.QaRFuX/`.
Input-inventory SHA256 is `561509a7c0cb7c10c18008b3a439e66391bc556a53c2cfc08f6fa6741a990b99`;
actual outer-wait TSV SHA256 is `9016346894ee01174d95bd5e04c5231c21a7bd8f2bd5b31b6858384ddd124d1b`.
Only the selected tiny guest images may assemble, one job; TB_BIN suppresses
RTL rebuilds and the pinned QEMU builder skips. An earlier wrapper namespace
failed its input-pin preflight on a nonexistent file before any VM launch;
it is retained separately and not counted as a DUT failure or PASS.
This is a named16-gate subset, **not complete verify-sys, RF-general or
standard-suite acceptance**. No source/model/guest state workaround was added.
CoreMark is closed PASS; Win95 desktop and Quake timedemo remain pending.
Gameplay IPC remains **0.42689244**, pre-RF c611, clocks
**1,399,999,637–1,499,999,637**; the repaired candidate remains unmeasured.

### October1 16:00UTC: Win95 closed-run qualification tooling

`tools/check_win95_standard_closed.py` is a host-only checker; it never runs,
modifies or stops a guest. An externally reviewed expectation SHA binds the
original unit/invocation, admissions, model, launcher, exact loaded helper
archives, ROMs and complete frozen input map. A **separate externally pinned
manual review of actual closed raw desktop frames is mandatory**. It does not
recognize a desktop automatically. A clean `CLOSED_UNQUALIFIED` wrapper result,
live screenshot, snapshot or observer exit0 alone never becomes PASS.

Before opening runtime logs, frames or disks, the checker requires the actual
successful inactive/dead supervisor tuple for the exact original invocation,
absent recorded owner/native PIDs and an absent or recursively empty cgroup.
If systemd has collected the unit, use the independently reviewed and SHA-pinned
historical supervisor receipt; an unloaded unit's default success is not proof.
It then requires actual native wait0/group closure, lossless pipe EOF/byte/hash/
inode receipts without sticky errors, complete cold header/footer and progress,
the owned graceful HOST-STOP, no cap/error/hook/snapshot, unchanged source/input
pins, resources/OOM0, unique native-published raw frame inventory and closed
private-disk hash. PID/cgroup absence is checked again afterward. The output
qualifies **Win95 only**, never the entire standard suite.

Run it only after normal guest/owner closure, with `--expect`,
`--expect-sha256`, `--visual-review`, `--visual-review-sha256`; add
`--supervisor-closure` and `--supervisor-sha256` for a collected unit. Never
manufacture manual desktop authority from setup progress or prepare a PASS
review while the run is live. The current checker SHA256 is
`d4dd8deb3eb9b376aa02d6259e37f347b4ffa6d4fff12f4d6b88d84308541537`.

Root actually ran all17 `tools/test_check_win95_standard_closed.py` host tests
after full source review and independent peer review. They pass, with actual
service wait0, invocation `7448244972d4496eb0c82d4fa8bdce2f`,169ms runtime,
20.2MiB peak and swap0. This uses synthetic files in standard TMPDIR or `/tmp`,
not the full external `tmp` symlink. The2GiB disk reads are mocked; the real
reader's wrong-size rejection is separately tested. Present PID rejection is
real; recursive-cgroup negative coverage uses an injected refusal, not a sysfs
integration fixture. Tests are checker contracts, **not Win95 desktop tests**.
Test-source SHA256 is
`f0c2a5f715ba92aad18796d0ec11dc547e2b89196c4464121c6f26493f4af593`.

### October1 16:00UTC: host scheduling and retained live OS identities

RF Win95's native858151 shared CPU14 with an older, preserved Quake run450409.
Its approximately50% host CPU use and runqueue delay occurred without cgroup
CPU throttling; this is host contention, not evidence of a DUT regression.
Only the owned RF Win95 service's runtime `CPUWeight` was raised to1000.
Its original invocation74bd87ca, owner858124, CPU14 affinity, CPU quota1s,
2GiB/no-swap/32-task/file-size caps and guest/model/clock inputs are unchanged.
The before/after property receipts are retained in its run directory. A later
346.576705s host interval recorded315.399316s native CPU time, **91.0042% host
CPU use**. This is not guest IPC, FPS or a hardware performance improvement.

Four small metadata observers now hold the two Win95 and two Quake original
supervisor invocations. They do not signal, restart or stop guests, execute
models/checkers, or read live disks. Actual terminal metadata is retained only
after normal closure; idle service cleanup must wait for absent PIDs/empty
cgroups. Observers themselves never qualify a guest. Their individual caps are
128MiB/no-swap/16 tasks/5% CPU/73h+120s, not changes to the DUT caps.

The root-inspected old c611 Win95 raw frame23 now shows78% driver-database
setup, **not the desktop** (raw SHA256
`bfc3c01cc3ed70e6ff90ff16c9fc752a8042028e15ce11993611cc9e6b2033b9`).
The PNG preview preserves every RGB pixel. RF4092 Win95 and Quake remain live;
no new RTL/build/guest run was launched for this host-tooling checkpoint.
CoreMark is PASS; both OS components remain pending. Latest verified gameplay
IPC is **0.42689244**, c611 clocks **1,399,999,637–1,499,999,637**, predating RF;
the RF candidate remains unmeasured. There is still **no matched pre/post IPC
fix Quake FPS result**. The old11.7FPS@70MHz projection is not candidate FPS
or a measured fix gain; CoreMark improvements do not establish a Quake gain.

Both Win95 run directories now contain a prepared `closed-expectation.json`.
Root and an independent peer reviewed all identities, admission-byte hashes
and each complete16-pin map against the frozen before receipts. Their reviewed
expectation SHAs are c611
`873ede4a2bc72f6e4dfb60dca550f0990b17b2b9565b11b20a4f7ac91e2c401a`
and RF4092
`6d3a9537bbb7b2a111a227ef5d262abc2971a46cf191600c8f24e1ff82ae5424`.
This is prepared future authority, not a fresh disk/source qualification or
Win95 PASS; root did not read a live private disk and no manual desktop review
exists.
At that16:00 checkpoint, root also inspected RF Quake raw frames0/1: startup
console and THE NECROPOLIS loading. Those frames were not gameplay evidence.

### October1 19:18UTC: repaired candidate gameplay measurement

This supersedes the earlier pre-RF gameplay baseline and the statements that
4092 is gameplay-unmeasured. Root independently qualifies **0.43038841 IPC**
on executable `4092c92a9f626157c9a0fa872f0a09f031b32f49f9b0cfa20d192a9a46835cc8`,
profiler clocks **2,199,999,637–2,299,999,637**: 43,038,841 legacy retire events
in100M clocks, exactly32,873,263 U plus10,165,578 V. Actual raw frames14/15
advance the gameplay scene. Root verified both complete counter rows and their
hashes, the held750378-byte log prefix and collector inode, process starts,
actual executable/ROM/compile pins, raw-frame hashes and exact PNG/RGB equality.

The root receipt is
`ao486-sim/obj_dir_ven_rfcomplete_oct01.5mZtCG/quake-cold-oct01.1/root-qualified-gameplay-window-2p2-2p3.json`,
SHA256 `0946daf8a669cc8c56e23cb6822f4ea98c70c8b782415c1e4c2ec84cfd70fb0d`.
Its fully reviewed parent receipt SHA256 is
`f859b0212386dd2e18d8cbd30363b44c8940eef61c160f19779558d2629fa8b0`.
This measures **the current RF-repaired build**, not startup or a target IPC.
It is still a live-prefix observation: no closed timedemo, sticky-capture/EOF
acceptance, REP-normalized instruction CPI, matched-work fix gain or FPS is
established. The old11.7FPS@70MHz projection remains an older-control estimate.

The c611/4092 cold Quake prefix also matches through1.2B clocks: all four
complete profiler rows at0.9/1.0/1.1/1.2B and raw frames0–4 agree byte-for-byte.
The concatenated profiler-row SHA256 is
`6b80724fa35dcb2bf5d8bbc59645110c27839d6d62a5a48790fdbbaa828b76f5`.
Those frames are loading, not gameplay; this is prefix non-regression evidence,
not a full-run or performance qualification.

### October1 19:18UTC: old Win95 control closes with a real display error

The c611 control reached the graphical error:
“Your display adapter is not configured properly.” It offers the Hardware
Installation wizard, **not an error-free desktop**. Root viewed raw frame38
before requesting closure and independently viewed it again after closure.
Frames33–39 share SHA256
`84c4d37305a89ac9404ac4032ce50b37b58d5c69bae70c945c6c6832a857f01e`.

Only after that actual error, root created the owned empty0600 `stop.request`.
The native honored normal HOST-STOP at4,505,310,439 clocks/531,255,089 retires
and exited0; its owner reaped it and closed at18:38:20UTC. Both PIDs and the
recursive cgroup were absent before idle service cleanup. A metadata observer
retained the original invocation72e81207 through actual inactive/dead/MainPID0,
success/1:0; root did not stop a live DUT or use unloaded systemd defaults.

Retained evidence under `obj_dir_ven_popwatch_oct01.52WV37/win95-cold-oct01.1/`:

- `result.json`: `336e99e835b2bd2242ca8bb7a39eee4e4c16c6c2d01cb16ad96e4eccc3e33e4e`.
- `supervisor-closure.json`: `e0427534d8730f3ceb16fc34cdf50c1ef5153424179cfdea49e90a43aa2bb86f`.
- `root-closed-display-error-review.json`:
  `4f4467114e688e917ec282b92be605779d7b3bf8638c2155092dbeba442b4ae6`.
- Closed private2GiB disk:
  `23a6f75bd3044dd7d00096c4c0087b17b7996003a4c7b1f6de53b32c18d17f07`.

Captured/persisted log bytes both equal17,855,741, with normal EOF/wait and no
sticky error; all40 raw frames match the closed inventory. Nevertheless,
`CLOSED_UNQUALIFIED`/native0 is not desktop PASS. Root actually ran the closed
Win checker against the independently pinned **negative** visual review: it
returns2 at `missing/early/unbound manual desktop authority`. The bounded
host check took2.284s/58.6MiB/no swap, invocationed0580bd; it did not mutate or
execute a guest. The visual failure is on c611; RF4092 is not relabelled failed
from an older model's result.

### October1 19:18UTC: display fixture diagnosis, not a CPU workaround

Only after old Win95's proven closure, root read its FAT16 files through mtools
at the independently checked partition offset1048576. `SYSTEM.INI` already
selects `vga.drv` and `Explorer.exe`. Its Cirrus description label alone is
not proof of a loaded driver. `BOOTLOG.TXT` is **stale**: its19975 bytes and
SHA256 `053d216aca468844d60e21dec5c919388813a52f83a360ac34194dd305372f8c`
are identical to the pristine source; its date is June3. Its driver failures
must not be attributed to this current boot.

A bounded read-only CREG reader now resolves actual linked hierarchy entries,
not string hits or physical record order. Root read the
[libcreg format](https://github.com/libyal/libcreg/blob/main/documentation/Windows%209x%20Registry%20File%20%28CREG%29%20format.asciidoc)
and relevant primary implementation, reviewed all code, and ran17 host contracts
successfully (92ms/16.4MiB/no swap, invocation3c9de832). Tests distinguish
linked versus orphan/alternate bindings and cover sparse IDs, bounds, cycles,
parent/hash/identifier disagreement, overlapping navigation records and the
observed singleton-NUL logical-root encoding. Only that exact root encoding is
normalized; raw bytes and offsets remain reported and nonroot/double-NUL names
still fail. Unknown layouts fail rather than recover guessed strings.

The scratch reader/test SHA256 values are
`f4120812c7be4731f1b32778055c5075e994262f356b0217f702b039173b4c13` /
`4e51d7410ae8f77d57df6b017dfb8bd5b5685f07c9f1158b0067032d927c6d2e`,
under the52WV37 build directory. An earlier strict reader rejected the real
root encoding; that is a host-reader limitation, not a Windows/CPU failure.
The corrected real-hive diagnostic actually exits0 without writes. Its output
is explicitly **non-acceptance** and requires caller-attested SYSTEM.DAT
provenance plus an independent byte SHA; CREG alone does not name its hive.

Closed SYSTEM.DAT is345136 bytes,
`eb5e5b1c0509dce27565a8afc5c6b41a1b63f3a9e447f314ce1835a50bbe7b01`,
with2442 linked keys/10 data blocks/no unlinked live records. Pristine
SYSTEM.DAT has the same size,2440 linked keys and SHA256
`45693d669d01aa796b01b829f01883df385bc44d8c5c05175e8d35a0f374a674`.
**Both** store the same display binding:

```
Enum\Root\*PNP0905\0000.Driver = Display\0000
Services\Class\Display\0000.InfSection = Cirrus
Services\Class\Display\0000\DEFAULT.drv = cirrus.drv
Services\Class\Display\0000\DEFAULT.minivdd = cirrus.vxd
Control\IDConfigDB.CurrentConfig = 0001
Config\0001\Display\Settings = 800,600 / 4 bits
```

Thus the stored Cirrus configuration predates all these runs. Static bindings
do not by themselves identify the currently loaded driver. The ao486 VGA has
ET4K-style extensions, not a complete Cirrus adapter; text-source inspection is
not proof of loaded-ROM ancestry. The disk's native MSDISP.INF supplies a normal
standard-VGA installation section with640×480×16 colors and `vga.drv`/`*vdd`.
The historical INI-only script does not update these registry bindings.

Root also independently viewed the existing closed pinned-QEMU control's
`screen_180.ppm`/pixel-identical PNG: the **same cc68 source** produces the same
display-adapter dialog on QEMU's standard VGA. Raw frame SHA256 is
`c6913e6b9b5663d2e11a6c289ec5525f854881d37e760d0af327bb555eb34cbf`;
its closed reference receipt SHA256 is
`ecbb26c2087d25fcdb67f8a73f76ce2404193ee9c526ee6b3fc724b2dfa28b5c`.
That control reports normal reaped0 and unchanged source. Its different PC
firmware/VGA prevent a CPU-causal conclusion or a Ventium standard-suite PASS.

Next action: prepare a **separate** disk through Windows' own standard-VGA
installer, retain the original immutable source and configuration evidence,
then require a fresh no-snapshot/no-input Ventium cold boot without errors.
No hand-patched registry, dialog dismissal counted as acceptance, forced CPU
state, guest-code patch or workload-specific hardware bypass is justified.
The live4092 Win95 disk has not been read or modified; its latest root-viewed
frame17 still shows60% driver-database setup, not a desktop. Current4092 Quake
remains live in advancing gameplay and has no completed timedemo/FPS result.
**Standard suite remains incomplete: CoreMark PASS, Win95 pending, Quake pending.**
Current verified gameplay IPC is **0.43038841**,4092 clocks
**2,199,999,637–2,299,999,637**; this checkpoint adds no measured performance gain.

### October1 20:21UTC: normal VGA configuration and fresh cold qualification

The original cc68 disk is retained unchanged. On a **new private QEMU overlay**,
root used Windows' own Display Properties to replace the existing adapter:
Settings → Change Display Type → Adapter Change → Show All Devices →
`(Standard display types)` → `Standard Display Adapter (VGA)`. The earlier
manual Add New Hardware attempt reported a resource conflict; root cancelled
it instead of installing a second adapter. No guest-code patch, hand-edited
registry, CPU-state injection, snapshot or saved-state resume was used.

Root viewed the old Cirrus binding in frame17, the installed
`Standard Display Adapter (VGA)` / `vga.drv,*vdd` in frame25, Windows' restart
prompt in frame27, and the post-restart desktop without the display error in
frame29. Root then selected normal Windows shutdown. Native QEMU exited0 at
19:56:55UTC, before its19:58:02 hard cap. Root retained the original invocation
`f6b0902aee1140fc8caac46fcc468e84`, actual exited0 tuple and absent native PID /
recursive cgroup **before** cleaning the already-exited service; the actual
`systemd-run --wait` subsequently returned0. Its longer displayed service
runtime includes idle `RemainAfterExit` retention, not a native timeout.
The final poweroff screen/QMP poweroff event was not captured: frame31 failed
because the native process had already exited. Terminal cgroup OOM counters
were not retained after group removal; they are not retrospectively invented.

Preparation artifacts are under
`ao486-sim/obj_dir_ven_rfcomplete_oct01.5mZtCG/qemu-vga-fixture-4VSF7/`.
The original source still hashes to cc68. Closed overlay SHA256 is
`af2c9c48067f845060d5d38421e758edbfad9ef63dbdb7927bff1d4fe8afed3f`.
After actual closure, a bounded `qemu-img convert` exported a **new**, independent
2GiB raw disk, SHA256
`37f5db14225f753aa357e321606e75273726fe330a2b7bcd954a61f9337b1a56`;
it did not overwrite, repair, commit into or rebase the original source.
Export native/actual wait both returned0; original source and overlay hashes
remained unchanged. The preparation receipt `fixture-closed.json` hashes to
`7b8c57e780fd36647dc0e915b9d0a7ef7eb07a87c106c659fcc132bfaf7ab579`.

Root read only the closed export's SYSTEM.DAT, SHA256
`4275e35b08202af74e15428df0e474cb98a08bd7b51aa2e77e98017d2bbc4293`.
The linked CREG reader resolves the existing Enum instance to `Display\0000`:
HardwareID now `*PNP0900`, `MSDISP.INF` / `InfSection=VGA`, DEFAULT
`4,640,480` / `vga.drv` / `*vdd`, selected Config0001 `640,480` /4 bits.
Native installer changes to driver/registry configuration are intentional;
this is **not** a claim that the configured guest disk is byte-identical to cc68.

A separate fresh QEMU cold reference then used that immutable37f5 source,
explicit read-only file/raw nodes, a new writable overlay, `-cpu pentium`
with no VME override, standard VGA, and **no UI input**. Both root-viewed raw
frames show the desktop with the ordinary Welcome window, not the display
error. QMP quit closed native0 at20:17:35UTC before its20:18 hard cap; original
PID/cgroup absence preceded idle cleanup, actual wait returned0, and source
SHA remained37f5. `qemu-vga-fixture-vVGAk/cold-reference-closed.json` hashes to
`539cbd5edc78c71f324426908379b20bb1f35005c9b0f3ed6ba1b4d1aab8ba7f`.
This is fixture sanity evidence on different PC firmware/VGA, **not a Ventium
CPU differential or standard-suite PASS**. Its disposable cold-reference
overlay is not the source of the next DUT run.

The separate Ventium cold run is now actually live: unit
`ventium-standard-win95-vga-rfcomplete-oct01.service`, invocation
`5d4961061292401d87e951ddf44ece07`, owner1024147 / native1024191,
starts20587448 /20587784, CPU20, unchanged RF executable4092. Fresh private
copy SHA matched37f5 before execution; no runtime input, snapshot, state hook,
guest patch, clock/cache override or new RTL is involved. The frozen new
launcher `run_win95_vga_cold.py` hashes to
`734354ba031f51a33e2be4211d51ceef394cee05e0756bf466ba24f523d4ffad`.
Root independently checked all17 source/archive pins and actual native
lifetime, parent/session/group, executable SHA, affinity and command.
Prepared `root-closed-expectation.json` SHA is
`d8c1a0095cb642d9984afb5d9b775c4162e413fbabfed7a6f2e8e59e18d9c9ce`;
it is future acceptance authority, not a closed result or desktop review.
The metadata-only observer holds the original unit reference, binds actual
`RemainAfterExit=no`, and never changes properties or stops/restarts the DUT.
At20:20UTC the new run has85,713,983 clocks /6,511,986 retire events;
OOM / OOM-kill / OOM-group-kill counters are0, although the staging file cache
has reached the2GiB cap. The original-source RF Win95 and both Quake runs are
preserved; root and monitoring agents did not read or hash live private DUT
disks.

The closed Win95 checker only adds the exact second launcher basename to its
existing externally SHA-pinned allowlist. Cold command/environment, resource,
input/ROM/helper, actual closure, lossless-log, complete-frame inventory and
manual error-free desktop requirements are unchanged. All20 host-only checker
contracts passed, including the new valid configured-source case and rejection
of unknown launcher names, forged launcher SHA and post-pin launcher, configured
source and preparation-receipt mutation. The final20-test host run returned0
in192ms /20.5MiB / no swap (invocation `0d2ee3ec5e7740d4bcf8ec27ebc2e3e9`). The
configured QMP helper separately passed all17 mock-only contracts. Neither
host test is a guest boot pass.

Disk headroom briefly fell below the launcher's8GiB floor. Root losslessly
packed only this completed build's two generated `.gch` compiler caches,
verified expanded SHA equality, then removed the two raw cache files under
the heavy-build lock. Their `.gch.gz` copies can restore the exact bytes;
approximately150MiB was reclaimed. Binaries, models, sources and acceptance
artifacts were untouched, and the new launch passed the unchanged headroom
guard. The packing receipt is `pch-lossless-pack.json` in the build directory.

**Suite remains incomplete: CoreMark PASS; configured Win95 boot pending;
Quake timedemo pending.** Current verified gameplay IPC remains
**0.43038841**,4092 clocks **2,199,999,637–2,299,999,637**. No new FPS or matched
before/after Quake performance gain is claimed.

### October1 21:04UTC: advancing cold boots, unchanged tested sources

Root revalidated the same three candidate native processes and original unit
invocations; all remain live. The complete `compile-inputs.before.sha256`
check returned0 against current files (manifest SHA256
`e170cbbc5bb5abdecf75df4a007a5087654a7a75128c024ef995e91ff3ce5db6`).
All three actual `/proc/<pid>/exe` hashes remain4092; no compile-input drift or new
model is introduced by this checkpoint.

The original cc68-fixture RF Win95 run has advanced from82% through84% and86%
to **90% driver-database setup**. Root viewed published raw `frame_00027.ppm`,
SHA256 `7af24e5156f7b2c465ba12831e6bf644a268e237c0a710093451a0385986b249`,
after checking the held regular file's identity, exact921615-byte P6 file,
stable content metadata and pixel-identical PNG conversion. This is setup,
not a desktop or manual closed acceptance. The configured37f5 cold run remains
live at505,299,072 clocks /111,830,349 retire events, without a published
frame or closure marker at the21:03 poll. Root did not read a live private disk.
The already-running canonical Quake launcher does make internal advisory FAT
console probes; its loaded checker cannot return PASS for a live probe. The
runner waits for native exit, proves process-group absence and finishes log
capture before requesting the final stopped-disk check. This is existing
frozen behavior, not a new probe or a live-observation acceptance shortcut.

The literal `tb: FLT` debug label is not an exception classifier:
`core_fetch_decode.svh:143–147` sends ordinary maskable INTR through
`start_fault(inta_vector,...)`, whose common debug print is `core.sv:9741`.
Thus vector94 logs alone do not prove a CPU exception. Likewise the documented
`FCB2:2FF7` / `0078cc386c6c3863` ROM callback trap is not standalone CPU
corruption evidence (see `WIN95_ABLATION_2026-09-28.md:1585–1596,1652–1658`).
Neither observation qualifies an error-free desktop.

CoreMark remains closed PASS; Win95 desktop and Quake timedemo remain pending.
Current verified gameplay IPC remains **0.43038841**,4092 clocks
**2,199,999,637–2,299,999,637**, with no completed timedemo/FPS or matched-work
performance gain established.

### October1 21:24UTC: configured fixture enters graphics, not desktop

The configured37f5 RF run remains live and has published raw frames0/1.
Root checked their held file identities, complete P6 lengths/headers, stable
content metadata, raw hashes and pixel-identical PNG previews. Frame0 shows
the loading cursor on black (SHA256
`26b50f0a0a1152196f40a3ec9c1085c8acf90e392160248a3431390acbcd9ef7`);
frame1 shows the teal initialization background and cursor, without Explorer
icons, taskbar or Start button (SHA256
`ca069cd82b5166f6bbefdb0bf8d4c83f539f03c156920308f5c2f0983d5a3909`).
Neither is a desktop review or stop condition. The original cc68 RF run's
root-viewed frame28 has advanced to92% driver-database setup, not desktop
(SHA256 `51ca760ef63f6f1d5b19842be8e4140420bb945fc98e76d49d2d0f74073baba1`).
No new run, guest input, snapshot or model change was introduced.

CoreMark is closed PASS; Win95 desktop and Quake timedemo remain pending.
Current verified gameplay IPC remains **0.43038841**,4092 clocks
**2,199,999,637–2,299,999,637**; no new FPS/performance gain is claimed.

### October1: closed Win95 failures and precise-fetch investigation

Both RF4092 Win95 runs have now closed after root directly inspected definite
visual errors. Neither is an error-free desktop or standard-suite PASS. The
raw P6 files were held with complete lengths, stable inode/content metadata
and pixel-identical PNG previews, then rechecked and viewed after native closure.

- The original cc68 disk reached98% driver-database setup, then a loading
  background, and finally the **Display adapter is not configured properly**
  dialog in frame33. Its raw SHA256 is
  `84c4d37305a89ac9404ac4032ce50b37b58d5c69bae70c945c6c6832a857f01e`,
  exactly the older c611 control's error pixels. Root created only the owned
  empty0600 host-stop request at22:12:28UTC. Native and owner closed with zero
  exit status at22:12:35UTC, at **3,924,310,439 clocks /432,212,683 retire
  events**. The8,052,616-byte held log has EOF, equal captured/persisted counts
  and no sticky capture error. Input pins and final zero OOM counters passed
  the frozen launcher. Only after actual PID absence and an empty/absent
  original cgroup did root clean the idle RemainAfterExit service. The observer
  retained the original invocation `74bd87ca8cfc49fe8916cbbb3946e1e8` as
  inactive/dead, code1/status0. The closed checker actually rejected the
  negative manual desktop authority with exit2; native exit0 is not desktop
  acceptance.
- The prepared37f5 standard-VGA disk showed **Explorer: This program has
  performed an illegal operation and will be shut down** in frame6, raw SHA256
  `b51c3d5a6ead8cef1b0fcb102be82a82e5efa4c49b44ff69931f8d7067ccf1e7`.
  This differs from the display-configuration failure. Root requested normal
  host closure at22:16:43UTC without clicking the dialog or injecting input.
  Native exited0 at **1,231,125,405 clocks /212,440,507 retire events**; the
  4,471,360-byte held log reached EOF without a sticky error. The frozen launcher
  retained unchanged input pins, final zero OOM counters and `CLOSED_UNQUALIFIED`.
  Separately, the **owner/supervisor exited120**, not zero. The observer retained
  that failed/failed state under original invocation
  `5d4961061292401d87e951ddf44ece07`, after actual PID/cgroup absence. Its cause
  is not proved by the native closure receipt or missing old launch-tool handle;
  it is not waived. The closed checker actually rejected this supervisor with
  exit2. The successful cold QEMU fixture sanity remains a different-platform
  fixture check, not evidence that this DUT boot passed.

Original-run receipts under `5mZtCG/win95-cold-oct01.1/`:
`result.json` SHA256
`733a178b851404d0947ce840cb8faae73ad93357c3bc76f73ebd442b53bfbd81`,
`supervisor-closure.json`
`7d923df6fb1931b38032472bdb90c9f64ca3fc063667ef28596b8ee466f2152b`,
and `root-closed-display-error-review.json`
`49553b03161e45460d613e301be7b507ca86193d79805f54958738d72a995f3f`.
Configured-run receipts under `5mZtCG/win95-cold-vga-rfcomplete-oct01.1/`:
`result.json` SHA256
`2c3374f065e8eae9b9611ed5eda56111155d1cc0151af4628c5df8b98aab6355`,
`supervisor-closure.json`
`fa0d58728fd6e1053d77ce43bb28664ff05e3f235a64a6990ae8f379a329eee0`,
and `root-closed-explorer-error-review.json`
`21cba7da1b94ef07f67c597ee029750de113e04586592feea44a68d89b7edda4`.

The configured log has a concrete suspicious sequence at lines39030–39031:
user-CS0137 #PF stamped with kernel-looking `fault_pc=c00013d1`, followed by
#GP at that same PC, error927c, while the updated CR2 is00408000. Source review
finds that generic permission faults and `walk_fault_pc` capture use
`S_PIPE ? pipe_commit_eip : q_pc`; **S_FETCH has not yet captured the upcoming
instruction's q_pc**. A slow instruction fetch can therefore retain the prior
IRET/transfer owner's restart PC. This is a general precise-fetch-restart
defect candidate, not yet a proved explanation of Explorer's crash. A directed
essential-byte fetch/page-fault regression is being prepared before RTL edits.
Incidental16-byte overfetch across an absent page is a separate correctness
question and must not be hidden by merely fixing the restart address.

The common `tb: FLT ... cr2=` print reads pre-nonblocking-assignment CR2:
`core_walk.svh` writes `creg2 <= walk_lin` on the same edge that invokes
`start_fault`, so that printed CR2 is not necessarily this event's address.
Use the registered post-edge context or explicit walk address before assigning
individual fault addresses. Ordinary PIC/callback traps remain nonfatal by
themselves. No RTL, guest-code patch or extra DUT run accompanies these closed
failure receipts. CoreMark remains closed PASS; current Quake remains live and
its timedemo is uncompleted. Current verified gameplay IPC remains
**0.43038841**,4092 clocks **2,199,999,637–2,299,999,637**, with no new FPS or
matched-work gain established.
