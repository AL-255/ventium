# Win95 cold-boot ablation (2026-09-28, ongoing)

Latest status (2026-09-29): the combined candidate has **no verified Win95
desktop** or completed Quake timedemo. Its latest verified, visually checked
Quake gameplay IPC is **0.45746656** over cycles
1,150,151,638–1,400,151,638 on frozen binary `3237b652...` (retirements
466,144,730→580,511,370). The older pre-candidate build measured
`0.45738614` over a nearby 1.15B–1.4B window; their ~0.00008 IPC difference
is not evidence of a meaningful gain. An earlier window on the current
candidate measured 0.48518006 at 1.0B–1.1B and must not be compared to the
later baseline as a gain. Statements below that say a test was still running
record its status at that point in the investigation, not a newer result.

This is a diagnostic record, **not** a Win95 boot-to-desktop qualification.
The baseline `make verify` and
the focused `verif/rep_sfetch/run-prepsfetch-gate.sh` (QEMU-differential
REP STOSD/MOVSD page-fault restart) passed with scratch on the root volume.
The external scratch filesystem is nearly full; use an explicit root-volume
`TMPDIR` for additional gates.

## Reproduction contract

- Full-PC Ventium runs freeze their own simulator binary, ROMs, and sparse
  guest-disk copy, with SHA-256 receipts and one pinned host CPU per run, via
  `tools/run_win95_ablation.py`. Older logs and results live under
  `/home/yukidama/ventium-bg-sep28/`; new scratch runs use `/tmp`, not new
  top-level home directories. Absence of an error before the relevant
  protected-mode transition is **not** a pass.
- Failed source disk: `w95fresh.vhd`, SHA-256
  `cc68b00539f878de8b75b09d9b24a5eab00a763f2a015d4ef402bd80c971ccef`.
  Cache-enabled boot ROM hashes: `boot0` `dca915c5...`, `boot1`
  `fb0d673a...`. The ROM patch clears CR0.CD/NW at cold reset. All these runs
  use the same 32 MiB PC model and 45 MHz CPU/RTC unless a row says otherwise.
- A positive Win95 result requires a captured, recognisable desktop, not a
  text splash, no-VxD interval, V86 idle loop, or cycle-cap exit. In
  particular the September 27 300M cold checkpoint was still in real mode.

## Completed controls

| Control | Observation | Inference |
|---|---|---|
| `ff0a803` measured-gameplay IPC executable | Device 3/service B VxD error at ~175M cycles | The two later IPC commits are not its sole cause. |
| Full `b15cf9b` IPC candidate; same source with `VEN_P54_REGMEM_PRIME` off; same source with `VEN_P54_DUAL_BYTE_LOAD_PAIR` off | Same VxD error at ~175M | Neither recent pairing option alone explains the blocker. |
| Current-source gameplay-base profile | Same VxD error at ~175M | Not specific to the IPC define set. |
| Gameplay-base at 4 MHz CPU / 80 kHz RTC; gameplay-base without `FPGA_DDR=2`; gameplay-base with RTC date 2000 | Same VxD error | Those timing, DDR, and date differences are not sole causes. |
| Current-source gameplay-base with the explicit `WIN` line removed from a private disk copy | Same VxD error | The redundant AUTOEXEC command is not its sole cause. |
| Same no-menu failed disk but `SYSTEM.INI` restored to `pnpdrvr.drv` | Same VxD error | The display-driver fix is not its sole cause. |
| Exact archived September 27 disk, SHA-256 `e29261a8...` | Same VxD error later, ~275M cycles | Its earlier 300M splash/checkpoint was not a known-good boot. |
| ao486 platform L2 disabled (not Ventium `EN_L2`) | Same VxD error later, ~275M | Disabling that L2 is not a solution. |
| Gameplay-base minus `VEN_L1D_WINDOW_KEEP_STORE` | Same VxD error | That cache-window optimization alone is not causal. |
| Gameplay-base minus `VEN_REP_MOVS_STREAM`; gameplay-base minus `VEN_L1D_FILL_FORWARD` | Same VxD error | Neither streaming MOVS nor L1 fill-forwarding alone explains it. |
| Gameplay-base minus `VEN_L1D_HIT_UNDER_FILL` | Same VxD error | Hit-under-fill alone is not causal. |
| Gameplay-base minus `VEN_L1D_WINDOW_REUSE` | Same VxD error at the 175M text capture | Read-window reuse alone is not causal; do not adopt a disabling performance workaround. |
| Gameplay-base with stock cache-disabled BIOS ROMs (`CR0.CD/NW` left set) | Same VxD error at the 1.05B text capture, after ~24.8M retirements | The cache-enabling ROM patch is not necessary for the failure. This does not by itself prove every L1/L2 path is inactive. |
| Aug29, Aug31 and Sep05 historical sources at their 1B/900M/900M caps | Still in real mode; no desktop | Inconclusive, not known-good ancestors. |
| Original ao486 core, stock ROM and documented 4 MHz/80 kHz-RTC flow, at 1.1B cycles | Exited at cap with no graphics/desktop witness; keyboard delivery unproven | Not a passing platform control. |
| Conservative five-define no-uop bundle at its 300M cap | Exit 0, 21.5M retired instructions, still real mode | Inconclusive: it did not reach the current cold-run error point. Do not call this a fix. |

## Cross-run provenance and the matched failure path

The current `cc68b005...` cold-disk control displays the VxD error at about
175M cycles / 27M retired instructions. Its periodic CPU samples around the
message are in real mode; they do not establish that it took the protected-
mode path below. The detailed VMM trace below is a **different September 20
restored guest disk** (`ffac9c1c...`, different simulator settings) at about
256M cycles / 40M retires. A fresh trace of the *current* `cc68b005...` cold
run subsequently matched the decisive protected-mode sequence: `c0231c39`
at retire 24,804,216/cycle 157,545,808, `c023a505` at retire 24,804,310,
then `c00043cb` at retire 24,804,686/cycle 157,549,850. Thus the path
**does** recur on the current disk during a short protected-mode interval
between periodic real-mode samples, even though the disks and timing differ.
The current trace also confirms the resolver reads device 3/service B from
the inline tuple (retire 24,804,714/715) and finds DDB `c000e990` with a
zero next pointer (retire 24,804,721–728); it is not a malformed service
ordinal or a merely stale VGA text screen.
The two physical-address write watches were stopped before that match was
known; a focused current-disk breakpoint has now completed.
The matched trace completed to the 175M text/error checkpoint with exactly
3,170,357 `VTM` records (retire 24,000,000–27,170,356); its uncompressed
SHA-256 is `1971332c2e729736b7c94d8df0f3be274ec42cb77723d3a4e7703d78b1221708`.
It is stored losslessly as `run.log.gz` under
`/home/yukidama/ventium-bg-sep28/win95_cold_vtm_b15cf9b_sep28/` (50 MiB
compressed versus 578 MiB raw). This is a failure capture, not a boot pass.

In that *historical* trace, VMM requests device 3, service B before VPICD
appears in the active DDB chain. The VPICD DDB and service table exist in
RAM, but VMM's chain head still points only to VMM at the failing resolver.
The trace shows a page fault at a VMM `rep stosd` into `FFB01000` shortly
before the error. Its stopped PTE is non-present (`00000606`). Disassembly
places the service call at `c00043cb` inside VMM's fault path, so the missing
VPICD lookup may be secondary on this matched path. The directed REP
fault/restart gate passes; do not enable the default-off
`VEN_REP_STOS_STREAM` as a workaround.

A fresh pinned-QEMU 8.2.2 run (`-M pc -cpu pentium -m 32`, the current
`cc68b005...` source disk with a private snapshot overlay) hit **the same**
`c023a505` `rep stosd` with
`EDI=FFB01000`, `ECX=26`, `EAX=00005000`, and the VMM DDB still unlinked
(`*[c000e990]=0`). At that precise point its physical PTE was `0030b627`
(present); single-stepping one REP element changed it to `0030b667` (dirty),
advanced EDI by four and decremented ECX. The failed Ventium snapshot's
`FFB01000` PTE is `00000606` (non-present, at physical `00305c04` under
CR3 `00305000`). The mapping difference is earlier than the visible VxD
error. QEMU's SeaBIOS/platform layout differs from the ao486 full-PC harness,
and the historical Ventium guest-disk state differs too. This comparison
isolates a divergent *state* at the instruction, not a causal RTL operation.
No page-table or REP behavior has been changed.

In those respective VMM paths, the preceding call at `c023a4bb` returns
success (`EAX=1`) on both engines. Both execute `c0231c37: mov [ecx],eax`
with `ECX=FFBFEC04` (the
self-mapped PTE address) and `EAX=00000206`: the initial non-present PTE is
intentional. QEMU subsequently executes `c00059e3: mov [ebx],eax`, promoting
that entry to `0030b227`, before the call returns; the 400k-instruction
Ventium trace around the failure never executes this promoter. At
`c0231c39`, QEMU reads VMM global `*[c0010898]=80000188` and takes the
`test [c0010898],ebx` nonzero branch into that path. Ventium's recorded flags
show the *zero* branch to `c0231cac` with the same `EBX=A0060000`. The focused
**same-source, pre-fix** cold run stopped immediately before that `TEST` at
retire 24,804,214/cycle 157,545,742 and proved the mapped DDR value was
already `80000188` (linear `c0010898`, physical `0023a898`, CR3 `00306000`),
with EAX `00000206` and EBX `A0060000`. This rules out a later global update
as the explanation at this point. The optional write watch in that run was
configured for `00239898`, **not** the ultimately probed `0023a898`, so its
write records are not evidence about this global. It is not a justified cache
fix.

## Decoder root-cause candidate and directed red test

The slow decoder's `84`/`85` memory-form `TEST r/m,reg` arms set
`d_mem_read=1` but previously left `d_mem_dst=0`. In the core ALU operand
mux, that selects `gpr[q_dst_reg]` as the left operand and the memory load as
the right operand. Because these arms do not set `d_dst_reg`, the selected
register is EAX, **not** the ModR/M-encoded source register. At the failing
VMM instruction `TEST [c0010898],EBX`, EAX is `00000206` and EBX is
`A0060000`; with QEMU's observed `*[c0010898]=80000188`, EAX AND memory is
zero whereas EBX AND memory is nonzero. The recorded wrong ZF and skipped
PTE-promoter path are exactly what this decode bug predicts. The same-source
pre-fix DDR breakpoint confirms the nonzero flag word was already present
before execution; a corrected full-PC run must still establish that this is
the whole boot blocker.
The neighbouring read-only `CMP mem,reg` and `TEST mem,imm` arms already mark
memory as the ALU left operand, so this is a local omission rather than a new
memory-operation policy.
History narrows the introduction: both missing `d_mem_dst` bits are already
present in the original M2 integer decoder commit `8885f3fd` (2026-06-03).
Commit `8783ad15` changed only their effective-address length calculation,
and `2e9c41a1` copied the arms verbatim into `decode_stages.sv`. Thus this
is a latent ISA defect exposed by the Win95 path, not a regression introduced
by the recent CPI optimizations or the June decoder extraction.

The new `verif/tests/t_testmem` QEMU-differential test covers the Win95
shape, a complementary zero case, and 16-bit/8-bit `TEST mem,reg` forms. On
the unmodified decoder it fails at its first `TEST` (retire 3,
`pc=08048014`): QEMU EFLAGS `00000286`, RTL `00000246` (wrong ZF). The
two-arm candidate fix sets `d_mem_dst=1` without enabling a memory write or
changing any disabled cache/REP feature. The rebuilt RTL passes the expanded
test (36/36 QEMU records, including memory-unchanged checks). It remains
**unaccepted** as a system fix. `make verify` passed (106 functional programs,
all M4/M5 metric bands), and the `ppage` protected-mode/paging system
differential gate passed (134/134 records). The repaired direct-memory TB also
completed short 10-iteration CoreMark performance and validation seed runs
with the same data CRCs as pinned QEMU; both print CoreMark's expected
under-10-second duration error and **do not qualify** as the standard
CoreMark correctness test. A fresh same-binary Win95 cold control and Quake
timedemo cold run are in progress; neither has a desktop/completion result.
The fixed Win95 cold control crossed 159.9M cycles and 24,862,602
retirements without the old device-3/service-B VxD error (the pre-fix matched
call was at about 157.55M cycles/24,804,686 retires). It was still executing
protected-mode VMM code. By the 175M-cycle text capture, however, the guest
displayed **"Windows protection error. You need to restart your computer."**
and sat in a real-mode loop. Thus the decoder correction removes the old
visible error but exposes a *new or later* boot blocker; it is not a desktop
or complete-boot pass. No cache or REP-streaming switch has been changed.
The 180M-cycle cold checkpoint stopped normally at 30,132,094 retirements
with a 129 MiB native snapshot (SHA-256
`08a43af087ef71174cd01323231363ca141611c185cefd4896c4133a78af922f`).
That snapshot is after the error and is **diagnostic only**, not a boot
checkpoint to replay as if success. A new same-source, same-binary cold trace
captured exactly 2.6M retirements starting at retire 24.7M. Its uncompressed
SHA-256 is `6e0c3ef12c741c6af5aba670c6cff2ec643c65673e57284d4f2cf0312e4bd1df`;
the losslessly compressed `run.log.gz` is under
`/home/yukidama/ventium-bg-sep28/win95_testmem_fix_trace_sep28/`.
The frozen DDR at 180M under the last protected-mode CR3 `00306000` has a
present mapping for `FFB01000` (PTE `00309267`); the old failed checkpoint
had a non-present `00000606`. The VMM DDB head `*[c000e990]=c0028928` is
also now nonzero. Walking the actual `next` links under CR3 `00306000`
reaches `VCACHE -> PERF -> VPICD` (VPICD at `c002b9b8`) and continues
through the loaded devices to `SHELL`/null. This is stronger than merely
finding an orphan VPICD structure in RAM: the original unlinked
device-3/service-B condition was resolved. These state witnesses do not
diagnose the new protection error.
The new retire trace confirms the exact corrected branch: at retire
24,726,041/cycle 159,452,146, `c0231c39` retires with ZF clear
(`EFLAGS=00003086`, EAX `00000206`, EBX `A0060000`); the PTE promoter
`c00059e3` runs at retire 24,727,407, and `c023a505` `REP STOSD` advances
normally from `FFB01000` at retire 24,727,540 rather than faulting there.
The retirement counts differ from the pre-fix run because the corrected path
performs more work. This directly validates the decoder fix's intended
effect; the later protection error has a distinct cause.
The later trace supplies a specific upstream cause: the simulator logs
`FLT vec=6 fault_pc=c000272c cs=0028` while the guest bytes at
`c000272c` disassemble to `0F 02 F1` (`LAR ESI,CX`). This checkout's ISA
map explicitly labels `0F 02` as a decode gap, so the core's #UD is
consistent with its current implementation but not with a full P54C. The
simulator then logs `FLT vec=8 fault_pc=c0004357 cs=0028` during the VMM
exception handler. The VMM trace enters its exception-reporting routine
with `ESI=6` and then `ESI=8`; the later fatal path uses error code
`00010005`. This is a concrete **unsupported-ISA boot blocker** after the
`TEST` fix, not a reason to turn on the disabled REP-STOS stream or L2.
Implementing `LAR` (and checking adjacent descriptor-query opcodes) needs
its own QEMU-differential protected-mode tests before another full-PC claim.
The later trace reaches VMM's service resolver at retire 26,172,877–26,172,912
(`c0001546` through `c00043ec`) with device 1 and service `0x2f` and a
nonzero service-table slot. The resolved indirect branch enters `c0009bbb`,
then `c0009c37` calls the VMM error handler at `c000175d`; the subsequent
path enters `c0223b87`, issues shutdown notifications and jumps to the
real-mode shutdown path. The VGA protection message is therefore a deliberate
guest error path, not proof of an RTL exception at the screen update. The
service is invoked as part of the guest's fatal exception path. The trace
does not establish whether other faults remain after `LAR` is implemented.
Do not patch the service table or cache to conceal this fault. Although the
missing `LAR` decode is now identified, do not yet claim a desktop: neither
the earlier original-ao486 control nor the ten-minute pinned-QEMU SeaBIOS
control established a desktop on this guest image (the QEMU VGA text still
read `Starting Windows 95...` and `VENTIUM-AUTOEXEC-RAN` at timeout).
Their different platforms and cycle budgets do not make
them passing references for this exact failure.
The historical FPGA log (`ao486-sim/DISK_BOOT_STATUS.md`, updates 169 and
247) reports a Win95 desktop *signature* on older bitstreams using a file
named `w95fresh.vhd`. That is useful provenance but not a current same-hash,
same-platform desktop oracle; the log itself is labelled historical and
contains superseded conclusions.
The repaired full-PC simulator is frozen in both run directories with SHA-256
`45287efb27247ad5a1618e46851fd82b8f78c607f4e370e13a8ee0b6a8c0091d`.
The Quake runner's first attempt was stopped in early startup because its
long-lived build scope held the global compiler/verification lock; its private
guest disk was replaced from the unchanged `2df14ac9...` boot input, and the
same frozen simulator was restarted directly on one pinned CPU. No cross-build
native snapshot is used.
The ten-minute-capped `make verify-sys` run passed its completed QEMU
differentials and directed fragment-abort, RSM-flush and SMM hidden-metadata
gates, then timed out while compiling the later `pintslim`
`+VEN_SEG_ENFORCE` variant. Therefore **the full `verify-sys` target is not
claimed green**; its scope cleaned up without orphan compiler processes.

Correction (2026-09-29): that historical Startup Menu observation was **not**
from the current `cc68b005...` source disk, despite earlier text implying it
was. Direct read-only inspection of its FAT16 partition (offset 1,048,576)
shows `MSDOS.SYS` has `BootMenu=0`, `BootKeys=0`, `BootGUI=1`, and no
`WINDOWS/WNBOOTNG.STS` exists. The current unkeyed boot therefore does not
depend on selecting Normal mode at a Startup Menu. Earlier keyed runs and
their apparent menu timing must not be used as evidence about this exact
source disk; the separate `SYSTEM.INI` control remains a different disk
configuration.

## September 29 descriptor-query candidate (not yet boot-qualified)

The confirmed #UD site is `c000272c: 0F 02 F1` (`LAR ESI,CX`), with
`CX=003b` in the same-disk pre-fix retire trace. A general protected-mode
`LAR`/`LSL` implementation now decodes both register and 16-bit memory
selector sources, queries the GDT/LDT through the ordinary paging path,
checks table bounds/type/privilege, sets ZF, and writes the destination only
for a valid selector. It does not enable `VEN_REP_STOS_STREAM`, the disabled
Ventium L2, or any cache bypass. The Win95 candidate and frozen pre-LAR
control were cold-run on separate pinned CPUs from identical source disk
and ROM hashes under `win95_lar_candidate_sep29/` and
`win95_lar_prefx_control_sep29/`; neither reached a desktop. The
Verilator source manifests agree on all compiled RTL files except precisely
the seven LAR/LSL-edited files (`core.sv`, `decode_stages.sv`, and five
`core_*.svh` fragments); their effective `VEN_*` define sets are identical.
This makes the cold pair a narrow RTL ablation, not a cache-feature toggle.
A third candidate run on another CPU recorded a bounded 4M-retirement VTM
window starting at retirement 26M; it is a diagnostic trace, not an
additional boot pass, and was compressed after capture to control disk
usage.

The pre-LAR control reproduced the Windows protection-error text by 177M
cycles and was stopped after this decisive observation, rather than left
spinning to its 220M cap. The LAR candidate continued in protected-mode VMM past the former
`LAR` #UD position, but at cycle 169,520,000 / ~28.4M retirements it hit a
new hard `VEN_UOPCACHE_CHECK` assertion at `c00012b0`: the cached U/V
descriptors disagree bit-for-bit with the live byte decoder even though
the short printed length/read/write fields agree. This is **not** a Win95
pass. The checker is detecting a possible stale/wrong predecode; disabling
it is only a causal screen, never an accepted fix. A same-source
`VEN_UOPCACHE_CHECK`-off diagnostic run on another pinned CPU reached the
Windows protection-error screen (details below).
The checker-only fatal diagnostic was expanded to print full packed cached
and reference descriptors plus current bytes and mode context; a separate
checker-on binary reproduced the failure with those fields visible.
Two checker-on, same-source one-define screens (`VEN_UOP_CROSSPAIR` off and
`VEN_UOP_SLOW_LEN_HINT` off) completed separately. Neither flag removal
is an accepted performance/correctness fix unless a focused cause is proved
and the standard suite passes.

The candidate's bounded VTM trace ran from retirement 26M to 28,478,149
and is preserved losslessly under `win95_lar_trace_sep29/.../run.log.gz`
(uncompressed SHA-256
`e7094129b1d731916e0299a9a00059b9c0c15fcc259c592fa556e349beed8582`).
Its last retirements switch from protected-mode `CS=0028` at `c00013xx` to
V86-like `CS=04cb` near PC `0x140`, immediately before the checker fails
at `c00012b0`. This is a mode-transition clue, not proof of the checker
failure's cause.

A newly focused `verif/uopcache/run-uop-modeflip-guard-gate.sh` reproduces a
separate real one-cycle validity gap: immediately after `cur_def16` flips,
the registered old-mode predecode is still reported valid until the next
posedge. The test fails on the pre-fix source with “old-CS.D descriptor
exposed on mode-flip edge”. A narrow guard on both `rd_pdvalid` outputs
using the existing `d16_flush` makes that test pass, and the resync-corners
and cross-line unit gates still pass (210 and 525 checks respectively).
`make lint` passes all five configurations with no fatal structural warning.
This guard does not disable the uop cache or its
cross-line features. It is **not yet boot-qualified** and must not be called
the explanation for the `c00012b0` mismatch until the detailed checker
reproduction and post-guard cold run say so. In particular, turning the
checker off is only a diagnostic, not an acceptable workaround.
The checker-off cold diagnostic reached the **Windows protection error**
text at 175M cycles: it was still in protected mode near 169.4M, then
switched into a real-mode shutdown/error path by 169.9M. The separate
checker-on mode-guard run also reached that screen, although it crossed the
old `w16` assertion site without aborting. Thus the checker was not causing
the visible failure, and the guard is not a Win95 boot fix. Neither run is
a desktop-pass witness.
The UOP/BRAM/system-fastpath variant testbench with this guard passes all
106 functional `make verify` programs, but that configuration is not the
canonical cycle model: its M4/M5 cycle bands fail, as expected for that
variant. A separate post-guard default-configuration testbench was built
for the authoritative `make verify` cycle verdict. Do not report the
variant's cycle-band result as an RTL regression or a green gate.
That default-configuration testbench has now passed `make verify`: all 106
functional programs and every gated M4/M5 cycle band. The directed `plar`
QEMU system differential is also 78/78 in both the default and
UOP/BRAM/system-fastpath post-guard testbenches.
With that UOP/BRAM/system-fastpath testbench, the additional QEMU system
regressions `pseg` (90/90), `ppage` (134/134), `pcpl` (304/304), and
`pv86` (949/949) all match. These directed results are necessary but do
not substitute for a full Win95 desktop or completed Quake timedemo.
The production-style `run-uop-resync-gate.sh` also passes after the guard:
365/365 QEMU system records, exact one #UD with no double fault, and both
cycle-mode successor paths hit the uop cache (two witnessed entries).
The deployed-style L1/AXI + BRAM + uop-cache + checker testbench also ran
`pv86` in **cycle mode** through six V86 #GP/IRET transitions without a
checker assertion. Its 949 retired PC records exactly match the ordered
949-PC QEMU golden stream. This directly exercises the mode-switch path in
the timing implementation, beyond the functional-mode `pv86` differential.
The whole-core `run-uop-pf-redir-gate.sh` passes: invalid map entries do not
steer port B, while valid predicted-taken U hits retain the target read.
The old-source detailed checker run has now reproduced at 169,520,000 cycles.
At `c00012b0` the checker printed reference bytes `75 52` (short JNZ),
`CS=0028`, `def16=0`,
`V` is unavailable, and the **only** packed U-descriptor difference is bit
31 (`0x80000000`), the `fpd_t.w16` field: cached JNZ has `w16=1` while
the live decoder has `w16=0`. The failing path just returned from 16-bit
V86 code to 32-bit protected code. This precisely links the assertion to
an old-default-size descriptor escaping a mode transition. This mismatch is
potentially architectural, not merely checker noise: `core_fastpath.svh`
uses `pipe_u_eff.w16` to truncate both Jcc fallthrough and taken target to
16 bits, so executing this stale descriptor would be dangerous. The later
same-binary RAM snapshot established that the handler's actual bytes are
`60 be 34 ...` (`PUSHA; MOV ESI,0x34`); `75 52` belongs to the preceding
V86 code. The checker-off and post-guard architectural traces are identical
through this site and the later shutdown, so this mismatch was not the
visible Win95 failure in those runs.
The post-guard simulator also has its own cold FreeDOS/Quake run from the
unchanged `2df14ac9...` disk, stopping at a 1.4B-cycle same-binary snapshot
for gameplay inspection before a possible same-binary continuation to
timedemo completion. This is not yet a Quake pass or IPC measurement.
Both 1500-iteration CoreMark correctness seeds are running on the post-guard
UOP/BRAM testbench; their verdicts are pending.
An older pre-guard LAR-only testbench completed both 1500-iteration CoreMark
seeds with `Correct operation validated` (performance seed `0x25b5` final
CRC; validation seed `0xe230`). This is a useful control but does **not**
qualify the present V86/guard candidate.
The pre-guard and post-guard full-PC Verilator source manifests have the same
115 effective `VEN_*` defines; among compiled `rtl/` sources, only
`uopcache.sv` (the guard) and `core.sv` (simulation-only expanded checker
printing) differ. The latter does not alter execution. This is a narrow
same-configuration RTL comparison, not a feature-disable ablation.

The post-guard checker-on Win95 cold run crossed cycle 169,520,000 without
an assertion, proving the narrow guard prevents the old-mode `w16` descriptor
from being presented at that site. **It still displayed “Windows protection
error” at the 175M-cycle text capture**, with the same periodic retirement
counts and real-mode shutdown trajectory as the checker-off control from
169.9M onward. It was stopped after this decisive failure rather than
burning cycles to the 450M cap. Therefore the descriptor race was real but
was not the sole boot blocker; do not claim a desktop or confuse suppression
of the assertion with Windows correctness. The bounded post-guard and
checker-off traces subsequently finished and identify the earlier V86
CS-write `#GP` as the next focused candidate.
The bounded post-guard and pre-guard checker-off traces overlap across the
mode transition and shutdown. Their **1,000,001 complete VTM lines**,
retirements 28,000,000–29,000,000 inclusive, compare byte-for-byte,
including the V86 fault return through `c00012b0` and the fatal VMM call.
The guard suppressed the checker exposure without changing architectural
retirement on this failing path. This makes
it especially unsafe to attribute the Windows error to the `w16` mismatch;
the guest error decision is upstream or independent.
The completed bounded logs ended at their 185M/178M caps with no desktop;
their uncompressed SHA-256 values are `1f229079834690cc1205f03f725eda62dcab7fd34603549a620795cda487dd17`
(post-guard) and `13a0ab8011d8ff27b477ba8c8e8be6a70ffea46e0f759ba15e78ac0653a52303`
(checker-off). They are preserved as lossless `run.log.gz` files under their
respective run directories to avoid keeping 622 MiB + 190 MiB raw logs.
At retirement 28,480,322/cycle 169,531,408, the post-guard trace enters
`c000175d` from VMM service code `c0009c37` with `EAX=00010004`; by
retirement 28,480,775 it reaches `c0223b87`, the shutdown-notification
path. The precise earlier input or emulation error that made that service
fatal is still unresolved.
The fatal-path trace shows the VMM service resolver reaching `c0009bbb`
with service `0x2f`. In the subsequent VMM code, the current VM handle and
system VM handle compare equal (`EDX=EBX=c15200e8`), so the branch at
`c0009bcd` goes directly to `c0009c34` and its indirect call at `c0009c37`.
This identifies the system-VM shutdown branch, **not** why the VMM requested
it. The preceding V86 `#GP` at `04cb:0142` and the transition back through
`c00012b0` remain the earliest local events to inspect with a same-binary
snapshot. In particular, a distinct `w16` checker mismatch must not be
promoted to the root cause merely because it occurs near this transition.
The pinned-QEMU control's VMM code bytes at `c00012b0` disassemble as
`PUSHA; MOV ESI,0x34`, matching the candidate trace's PCs and register
changes there. Its V86 code at `04cb:0140` starts with `75 52` (`JNZ`), the
same two bytes the old-mode uop descriptor incorrectly exposed at the
protected-mode handler. A same-binary, V3 native snapshot at cycle
169,519,925 (retire 28,478,151) independently confirms the candidate's
own backing bytes: `c00012b0 = 60 be 34 00 00 00 ...`, whereas
`04cb:0140` (linear `00004df0`) = `75 52 2e 83 2e 10 00 08 ...`.
Thus the `75 52` comparator reference was the old V86 instruction, not the
handler instruction. The snapshot replay used the identical binary, ROM,
clock/DDR configuration and an independent copy of the flushed guest disk;
it did not modify the RTL or guest image to make this observation.

The next V86 instruction, at `04cb:0142`, is a CS-overridden write
(`2e 83 2e 10 00 08`, `SUB word [CS:0010],8`). This is legal in V86's
real-mode-style segment semantics. The full-PC trace instead logs `#GP(0)`
there. A new focused variant of the existing `pv86` bare-metal test
(`pv86cswrite`) performs a CS-overridden store/read before its normal V86
IOPL sequence. It checks both a plain CS-override store and the exact
Win95-shaped CS-override read-modify-write (`SUB word [CS:slot],8`). The
pinned QEMU golden completes 1,022 retirements; the
pre-fix RTL with `VEN_SEG_ENFORCE` faults on the exact `SUB` at V86 PC
`0x1c` and diverges at retirement 763 (CS/SS/VM flags switch to the
monitor). The RTL's
`seg_type_fault` applied protected-mode code-segment write permissions to
V86 because it checked `!real_mode` but not `!v86`. A narrow change now
uses `!seg_real` for that TYPE check only; extent and paging checks remain
active. The post-fix RTL is QEMU-equivalent for all 1,022 `pv86cswrite`
records with only the six expected IOPL-related V86 `#GP`s. The original
`pv86` test is likewise equivalent for 949/949 records against a fresh
pinned-QEMU golden. Its checked-in golden has stale reset EDX `0x663`
versus this pinned QEMU and RTL's `0x543`; comparing against it fails only
for the first four reset records, both before and after this fix. Cold Win95
verification is still pending, so this is a strongly evidenced candidate
cause, not a boot-pass claim.
The post-fix `make verify` run passed its 106 functional programs and the
gated M4/M5 cycle bands using the freshly built `VEN_SEG_ENFORCE` testbench.
With that same testbench and freshly generated pinned-QEMU goldens, `pseg`
and `ptaskv86` additionally pass 90/90 and 349/349 system retirements.
The five-configuration `make lint` matrix also passes with no fatal-class
findings (`LINT-GATE-OK`). A same-profile full-PC binary has been rebuilt
with the V86 fix, and a new private-disk cold Win95 run is in progress to a
180M-cycle same-binary checkpoint; no boot outcome is claimed yet.
The reusable `run-pv86cswrite-gate.sh` now generates a fresh pinned-QEMU
golden, compares all system retirements and insists on exactly six expected
IOPL `#GP`s. It passes on the fixed RTL and fails on the frozen pre-fix
testbench at the CS-write instruction; no stale checked-in golden is used.
The new full-PC binary is SHA-256 `f4ce56fd2c4256dd62b579ab38f4f3c388c77fce78a8e3f511edc294fe8a2714`.
Its Verilator manifest has the same `VEN_*` define inventory and same compiled
source hashes as the post-guard predecessor except `rtl/core/core.sv` (the
single V86 type-check edit); the build command's parallel job count also
changed from four to one. This is a source/profile-controlled cold comparison,
not a feature-off ablation.
The first fixed-profile Win95 cold run reached its 180,000,000-cycle V3
checkpoint with 31,459,671 retirements, still in protected mode at
`0028:c023337e`. The old `04cb:0142` `#GP`, real-mode shutdown by 169.9M,
and 175M Windows protection-error VGA text are absent; its 175M screen still
shows `Starting Windows 95...`. That proves the former boot blocker was
removed but **does not** prove a desktop. The exact same binary is now
continuing from that snapshot and a SHA-identical private copy of the
checkpointed disk toward a 250M-cycle checkpoint. No guest or RTL patch is
applied during continuation.
The gate was invoked with an explicit `TB_BIN` and local `TMPDIR`: this
checkout's canonical `verif/tb/obj_dir` and default `tmp/` resolve to the
external volume, which had only about 58 MiB free, so a prior attempt had
failed writing a precompiled header before correctness tests. No cache or
segment feature was toggled to obtain the pass.
The disk contains a hidden historical `BOOTLOG.TXT` with desktop-era entries,
but its SHA-256 is identical in the pristine source and this failed private
disk copy (`053d216a...`). It was **not updated by this run** and cannot be
used as a boot-pass witness or a current failure log.
The checker-on `VEN_UOP_CROSSPAIR`-off single-define diagnostic reproduces
the identical `w16`-only JNZ mismatch at cycle 169,522,000. Thus disabling
cross-line pairing neither removes this race nor provides a valid fix.
The independent `VEN_UOP_SLOW_LEN_HINT`-off diagnostic also reproduces the
same mismatch at cycle 169,520,000. Neither performance feature should be
disabled to address it.

The new `verif/sys/tests/plar` test was red on the pre-LAR RTL (QEMU had 55
retirements, RTL stopped at 35 at LAR). The current, expanded test has
78/78 QEMU-equivalent system retirements, covering register/memory selectors,
16-/32-bit destinations, null/out-of-table rejection, RPL visibility,
conforming code, a not-present data descriptor, and the exact Win95 `003b`
selector shape. It also remains 78/78
under a separate UOP-cache + BRAM I-cache + system-fastpath simulation
profile; this specifically checks that the full-PC frontend does not turn
the newly decoded opcode back into #UD. `make verify` passes
106 functional programs and all M4/M5 metric bands using the rebuilt
root-volume testbench; `make lint` passes all five configurations; `pseg`,
`ppage`, and `pcpl` remain QEMU-equivalent (90/90, 134/134, and 304/304).
The first ordinary
`make verify` attempt did not reach a verdict because its canonical object
directory is on the full external scratch filesystem. It was stopped and
re-run with an explicit, current-RTL `TB_BIN`; no RTL workaround was made.

There is a separate, pre-existing architectural gap: segment loads do not
write the descriptor accessed bit back to memory. A first version of `plar`
exposed it: QEMU's later LAR saw access rights `0x93`, while RTL read `0x92`
from the descriptor. The focused LAR test now starts its loaded data
descriptor with A=1 to isolate descriptor-query behavior. This is **not** a
fix for accessed-bit writeback and must not be misreported as such; a
separate differential regression and properly fault-atomic segment-load fix
are still needed if the boot depends on it.

## September 29 continuation: a second V86 far-return blocker

The V86 CS-write fix did not boot Windows to a desktop. Its same-binary cold
run reached 180,000,000 cycles (31,459,671 retirements) without the former
Windows protection error, then a same-binary continuation stopped retiring
at 38,553,467 instructions between cycles 201.5M and 202M. It remained
stopped through a 250M-cycle checkpoint at V86 `FF03:4613` in the host retire
display. The checkpoint's actual core state is `S_HALT` (state 8), with
`eip=q_pc=00004627`, no memory request/ack, and debug vector `E8`. The guest
bytes at linear `0x103657` (`FF03:4627`) are `CA 02 00`, i.e. `RETF 2`. Vector
`E8` is assigned only by the `SYS_RETF` dispatch guard when
`seg_real && paging_on`. Thus this is a deliberate unsupported-path halt, not
an AXI or cache-response deadlock. The `FF03:4613` display was the last
retired instruction and not the faulting `RETF` address. The earlier claim
that this might be a memory wait is superseded by the direct core-state read.

The guard was introduced by `8df2a86` (June 11) as an explicit out-of-scope
boundary for the then-real-mode-only M9.5 implementation; that commit says
V86+paging was unimplemented, not that a specific verification gate failed.
It predates the later paged far-transfer address/translation fixes. It
excluded an architectural V86 operation: V86 uses `sel<<4` segment
bases while CR0.PG remains on. The adjacent indirect far-CALL/JMP paths
already route V86 through `seg_real` independent of paging. The narrow change
routes immediate far CALL and RETF through their existing `S_LCALL`/`S_RETF`
paths for all `seg_real` cases; protected-mode descriptor validation and all
MMU/stack/fault logic remain unchanged. The host-only `--ven-state-*` output
now exposes `q_pc`, decoded kind, and `int_vec` to make future terminal halts
distinguishable without rebuilding RTL.

The new `verif/sys/tests/pv86far` differential gate deliberately failed
before this change: pinned QEMU completed 1,226 retirements to exit 0, while
the pre-fix RTL halted after 921 (identical prefix, missing remainder). The
test checks 16-/32-bit immediate and memory-indirect far CALL and RETF,
RETF `2` (the exact Win95 opcode) and `4` stack adjustment, and a far frame crossing the `0x2E000`/
`0x2F000` page boundary with page `0x2E000` remapped to physical `0x3E000`.
It reads back the remapped physical alias to catch a consistently wrong
push/pop translation. After the change it passes 1,226/1,226 architectural records with
exactly six expected IOPL `#GP`s and no other faults. The separate V86
CS-write gate remains 1,022/1,022. `make verify` passes 106 functional
programs plus M4/M5 cycle bands; fresh pinned-QEMU system diffs pass `pv86`
949/949, `ptaskv86` 349/349, `pseg` 90/90, `ppage` 134/134 and `pfarok`
1,126/1,126. These are directed/small gates, **not** a Win95 desktop or a
completed standard suite. The existing memory-indirect far-transfer gate also
passes 3,824/3,824 records, and `make lint` reports `LINT-GATE-OK` across all
five configurations. A same-profile full-PC rebuild is complete at SHA-256
`19381c7d17ae5bf622e24d01b17e6cfd08399bfbb920268dd2d157c7f575d93a`;
a new cold Win95 run is in progress using a private byte-identical copy of
the original disk. It has no boot outcome yet. Through the latest checked
~107M-cycle progress line, the old and new cold runs' cycle/retire/CS/EIP/
CR0/CR3/EFLAGS reports match byte-for-byte, a useful pre-change trajectory
control; that alone says nothing about behavior after the old 201.5M halt.
The candidate then passed that old halt and saved its own 210M-cycle V3
checkpoint with 47,496,553 retirements, still in protected-mode Windows code.
The former binary had permanently stopped at 38,553,467. No protection-error
text appeared, but the display still read `Starting Windows 95...`; this is
**not** a desktop pass. A same-binary continuation from the 210M snapshot and
a SHA-identical private disk copy is running toward 300M. The original
210M checkpointed disk remains untouched for repeatable replay.

The continuation reached a **new, later visible failure**: at 260M cycles
the VGA text changed to `While initializing device VDD: Windows protection
error. You need to restart your computer.` At 259,062,266 cycles the core
had retired 70,114,066 instructions and was still executing the guest; this
is not the earlier 38,553,467-retirement HALT. The log contains repeated
V86 `#UD` and `#GP` deliveries in the run-up, but their role is not yet
established. The V86 far-transfer fix therefore closes the proven terminal
halt, **not** Win95 boot-to-desktop. Further investigation must use the
preserved 210M checkpoint and same-binary replay, rather than broadening
the mode gate or claiming every V86 fault is a core defect.

The 250M old-binary checkpoint and its disk remain preserved at
`/home/yukidama/ventium-bg-sep28/win95_v86seg_resume180_sep29/`. It cannot
be restored into a changed RTL elaboration. Disposable diagnostic disk
copies and one diagnostic terminal snapshot were removed after preserving
their small logs and the source checkpoint; no original guest disk was
modified for the fix. The frozen pre-fix system testbench used for the red
`pv86far` comparison remains at
`/home/yukidama/ventium-bg-sep28/win95_v86seg_diag250_sep29/tb_before_v86far`.

## Open at the time of this note

- LAR/LSL, the V86 CS-write fix and paging-on V86 far transfers have directed
  QEMU coverage, but the new same-profile cold Win95 run reaches a later VDD
  protection error, **not** a desktop. Current-build CoreMark correctness and
  a completed Quake timedemo are also pending. Old snapshots cannot qualify
  the changed RTL.
- Descriptor accessed-bit writeback on segment loads remains open and has
  its own observed QEMU mismatch. Do not mask it inside LAR or turn on a
  default-off optimization as a workaround.

No disabled Ventium L2 or REP-STOS stream feature was enabled. Any RTL fix
must get a focused microtest, the differential gates, CoreMark correctness,
a real Win95 desktop, and a completed Quake timedemo before acceptance.

The LAR-only cold Quake control (`ao486sim_ven_ipc_lar_sep29`, binary SHA-256
`b2437351da4ffd183a74d7976114d9c57c20a66bdf4750f0f587ab7037d2e983`)
saved a 1.4B-cycle checkpoint and captured visible gameplay. Its hardware
counters report 466,103,984 retirements at 1.15B and 580,450,519 at 1.4B:
**verified gameplay IPC = 0.45738614** for that 250M-cycle window. This is
an older LAR-only build, not the current V86-CS/far-transfer candidate; the
near-identical value to the prior `ff0a803` 0.457219 baseline is not evidence
of a meaningful performance gain. The current candidate still has **no**
measured gameplay IPC or completed timedemo.

The later LAR+mode-guard control (`ao486sim_ven_ipc_lar_modeguard_sep29`,
binary SHA-256
`c2c4ad9badffe3f439c1db3270c44e754a6ab5852e96718d2a9c48e18141c892`)
also completed the 1.4B checkpoint with byte-identical captured gameplay
frame 14 and the same 466,103,984/580,450,519 counter endpoints. It is the
latest verified gameplay build: IPC `0.45738614` over cycles 1.15B–1.4B.
It still predates the current V86-far/IRET candidate and is not a completed
timedemo.

## Later V86 IRET defect under investigation

The new 210M-checkpoint replay reached a distinct error at 260M: `While
initializing device VDD: Windows protection error.` A bounded replay around
241M showed repeated V86 `#UD` at `FCB2:2FF7` and `#GP(FCB0)` at
`FF03:4323`, but fault counts alone do not establish causation. Source audit
identified a precise V86 IRET path mismatch: dispatch sends V86 IRET to
`S_IRET`; at the final pop, it unconditionally routes same-privilege returns
through the protected `S_INT_CS_RET` descriptor lookup, despite V86 CS being
a real-mode segment. The `S_RMIRET` path cannot simply be selected because
that state is excluded from paging translation.

The new `pv86iret` pinned-QEMU microtest runs with IOPL=3, paging on and a
non-identity page mapping under the cross-page stack frame. Its pre-fix red
result is unambiguous: QEMU exits after 899 records, whereas the RTL first
diverges at record 824 on 16-bit intra-V86 IRET, raises `#GP(0x0FFC)` for
the real-mode CS `0x0FFF`, and enters the protected fault handler. The RTL
candidate commits CS:EIP:EFLAGS in `S_IRET` only when already in V86, while
retaining translated stack reads and untouched protected-mode validation.
The final test additionally requests IOPL=0 in the 16-bit frame and clears
both VM and IOPL in the 32-bit frame; QEMU and RTL agree that a CPL3 V86
IRET preserves the current VM/IOPL rather than granting those changes.
The candidate is now green: `pv86iret` 899/899, `pv86far` 1,226/1,226,
`pv86cswrite` 1,022/1,022, plus `pv86` 949/949, `ptaskv86` 349/349,
`pfarok` 1,126/1,126, `ppage` 134/134 and `psoccallfmem` 3,824/3,824.
`make verify` passes 106/106 functional programs and its M4/M5 cycle bands;
five-profile lint prints `LINT-GATE-OK`. These are focused/system gates,
not the standard suite. A same-profile full-PC binary was rebuilt from the
old manifest's 115 defines (SHA-256
`bb86cb3f72dfcaea6e77c49db14a2cfaa947956243a07fb98db8317525acc0ff`),
and a cold Win95 run on a byte-checked copy of the original pristine disk is
running toward 300M cycles. The microtest's red/green result proves a core
defect, not that it alone caused VDD or now boots to desktop.

The final red/green artifacts are preserved under
`/home/yukidama/ventium-bg-sep28/pv86iret_redgreen_sep29/`: the pinned-QEMU
trace has 899 architectural records; the frozen pre-fix RTL differs first at
retirement 824 (and then runs to its 1,000-instruction cap), while the
post-fix RTL matches all 899. This is a one-path correction, not a request to
reenable any feature that was left off for verification reasons. In particular,
`EN_L2=0` and the default-off REP-STOS stream stay unchanged. The V86 far
CALL/RETF guard's introducing commit (`8df2a86`) explicitly describes that
path as then-unimplemented; its removal was accompanied by a red-before,
green-after QEMU gate rather than inferred from a successful boot prefix.
At cycle 139,921,467 the new IRET cold run and the frozen pre-IRET
far-transfer cold run report the identical 21,524,928 retirements and
CS:EIP/CR0/CR3/EFLAGS sample; cycle 169,421,467 also matches exactly at
28,447,167 retirements. By cycle 169,921,467 the periodic samples differ
slightly (28,581,890 versus 28,581,741 retirements), so this is an early
same-profile trajectory check, **not** a claim of lockstep through boot or
evidence about the later 260M VDD error.

The new cold run passed the old VDD display point: at 260,462,612 cycles it
remained in protected mode with paging (`CR0=80000011`, CS `0028`) and
70,759,071 retirements, with no `Windows protection error` text. The frozen
pre-IRET continuation was already in real mode (`CR0=00000010`) by its
260,062,266-cycle sample, and its 260M VGA dump contained the VDD protection
error. This is evidence that the narrow IRET change avoids that *observed*
failure path, not a desktop qualification; the new run is still progressing
through the 300M checkpoint and may encounter a later blocker.

## New blocker after the VDD path: stale PS/2 status read

The IRET candidate saved a 300M-cycle cold checkpoint at 80,173,207
retirements without the VDD error, but it was not at a desktop. From about
258M onward it repeatedly retired at VMM `C0034B28`–`C0034B30`. The guest
bytes, read from the checkpoint's translated page, disassemble to
`IN AL,64h; TEST AL,1; JZ exit; IN AL,60h; JMP retry`: a keyboard-controller
output-buffer drain, not a generic idle loop. A native same-binary replay
confirmed the guest receives `AL=75h` from port `64h` on every iteration.

A bounded, host-only 256-cycle controller witness on a SHA-identical private
disk copy found `status_outputbufferfull=0`, both FIFOs empty, and a stale
last keyboard data byte of `75h`. On each status read, the PS/2 block correctly
produced status `1Eh` at its read strobe, but its registered output changed
back to `75h` before the ao486 I/O bus's delayed `S_READ_CHK` sample. This
is an interface-timing defect, not evidence that the FIFO is infinitely
refilled. The exact reproducer in `verif/bus/tb_ps2_iobus.sv` was red on the
pre-fix platform (`port 64h returned stale data 75 with empty output FIFO`)
and green after holding the registered PS/2 read byte until the next read
strobe. Both default and deployed `VEN_KBD_AUTOACK`/`VEN_KBC_FAST` profiles
pass, including port-60h data behavior and the one-strobe-per-read check.
The bounded host observer was checked for non-perturbation: the frozen
pre-PS/2 executable and its host-only relink both restored the same 300M
checkpoint and saved byte-identical 300,000,512-cycle native states
(`SHA-256 924c49046710a76596fe3391a1adb47118a574fed3d6695d4718d99a3a0421f2`);
the private disk SHA remained `0dbb5b8d...`.
The expanded microtest also primes one real FIFO byte: both default and
production profiles report OBF=1, return that byte exactly once, and then
report OBF=0. `make bus` passed with the new gate integrated. The canonical
submodule overlay was updated and reverse-apply checked against the live
patched submodule. The diagnosed IRET-only Win95 continuation was stopped
after more than 383M cycles in the same 8042 loop; its untouched 300M source
checkpoint and disk remain preserved. The stopped diagnostic's private disk
and log were moved, without deletion, to
`/run/media/yukidama/Windows/ventium-checkpoints-2026-09-29/win95_v86iret_old_kbc_loop_resume300_sep29/`
to free 92 MiB on the nearly full root volume.

This is a platform peripheral change. The earlier CoreMark standalone and
full-PC Quake/Win95 runs predate it. A fresh full-PC PS/2 candidate has binary
SHA-256 `5e6fcf267f10385ac6156d40a05db6e78ee6489ef313dd31754b031a390b97cf`;
its effective set of 115 `VEN_*` defines matches the pre-PS/2 build exactly.
Fresh cold Win95 and Quake runs with this binary are underway on separate
private disks; neither uses the incompatible IRET-only snapshot. No desktop,
completed timedemo, or gameplay IPC is claimed yet for the combined candidate.
An additional, CPU-pinned Win95 cold ablation uses the same binary, ROMs and
`cc68b005...` source disk, changing only a `type:1,enter` keyboard script at
25M cycles; the unkeyed run is its control. This was launched under the
subsequently disproved assumption that this exact disk displays a Startup
Menu. It is a keyboard-perturbation run, **not** proof of a Normal-mode
selection. The FAT inspection correction above governs interpretation.

The current core's 1,500-iteration CoreMark performance seed completed
`exit_group(0)` after 542,165,382 retirements / 1,381,142,683 RTL clocks,
with reference data CRC `0x25b5` and `Correct operation validated`. This is
one of the two required correctness seeds, **not** a gameplay IPC result; the
validation seed and same-profile pre-IRET controls are still running.

The frozen **pre-IRET/pre-PS/2 V86-far control** reached its 1.4B-cycle
gameplay checkpoint with visible Quake gameplay. Its 1.15B and 1.4B retire
counters were 466,103,984 and 580,450,519: verified gameplay IPC is
**0.45738614** for that 250M-cycle window (binary SHA-256
`19381c7d17ae5bf622e24d01b17e6cfd08399bfbb920268dd2d157c7f575d93a`).
This agrees exactly with the earlier LAR+modeguard baseline; neither is a
measurement of the current combined IRET+PS/2 candidate. The checkpoint was
moved recoverably to
`/run/media/yukidama/Windows/ventium-checkpoints-2026-09-29/quake_v86far_candidate_1400m_sep29_gameplay.snap`
to recover 129 MiB of root-disk space; its original path remains a symlink.

A separate same-binary/same-source-disk 30M-cycle cold probe on CPU 25 sampled
the VGA text screen every 1M cycles. From boot through 29.25M cycles it showed
the BIOS messages and `Starting Windows 95...`, but **no Startup Menu** or
Normal/Safe-mode selection. Its executable SHA-256 was the combined candidate's
`5e6fcf...` and its source disk SHA-256 was `cc68b005...`; it exited cleanly
at its diagnostic cap, not at a desktop. Consequently the 25M-cycle
`type:1,enter` ablation cannot be described as having selected Normal boot.
The later direct FAT inspection found `BootMenu=0` and no `WNBOOTNG.STS` on
this exact source, so the unkeyed runs are the actual boot tests.

After the PS/2 read-hold fix the unkeyed cold run passed the old VMM
`C0034B28` drain-loop point, but from roughly 261M through at least 291M
cycles its samples instead remained in V86 BIOS `F000:4B5C`–`4B69`.
Disassembly of the exact `boot0.rom` bytes shows a poll of port `64h`
waiting for `(status & 0x21) == 0x21` (mouse-origin output-buffer byte).
The Ventium harness tied the mouse PS/2 pins high and had no external device,
whereas the legacy ao486 harness contains an opt-in, pin-level mouse model.
This is a **new observed wait**, not proof that the mouse model will fix it:
the BIOS could also have entered the poll spuriously. I ported that model
verbatim as an opt-in `--mouse` host-simulator diagnostic, leaving RTL and
default/no-mouse behavior unchanged. Mouse-enabled native snapshots are
rejected because external C++ device state is not serialized. A separate
same-source-disk, CPU-25 cold run (host binary SHA-256
`e13d073306aa395ee670a607703dee015a91b0fe25b41d55865f7ad9552151fc`)
is in progress to test whether a genuinely connected mouse changes the wait.
The opt-in host change was also tested **off** with a separate 30.05M-cycle
cold run on CPU 27: its last sampled state at cycle 29,775,040 was identical
to the original host binary (3,778,681 retires, CS:EIP `FF03:00007DBA`,
CR0 `00000010`, CR3 `0`, EFLAGS `00007246`), and the two private disk images
had identical SHA-256 `0aa7ca1852f6461a7ff0fb16169f8f884b45519611f00370c3bb9e380486af38`.
Thus merely adding the disabled-by-default mouse code did not perturb this
early no-mouse control. A deliberate `--mouse --save-at` invocation exited 2
with `SNAPSHOT-ERROR` before running, confirming the state-safety guard.
The scripted-key cold run also entered the same V86 `F000:4B5C` mouse-status
poll by cycle 259,957,846. Its key events were queued at 25.0M/25.5M, but
that is not a Normal-menu selection or a bypass of this wait; the exact
source disk has boot-menu selection disabled.
The focused real-PS/2-plus-I/O-bus gate was expanded to prime an auxiliary
FIFO byte and check that port `64h` reports bits 5+0, port `60h` delivers the
byte once, and a later status read clears both bits. It passes in both the
default and deployed `VEN_KBD_AUTOACK`/`VEN_KBC_FAST` profiles with no
compiler warnings. This verifies the controller's delayed read path for a
**present** mouse byte; it does not create an external device or explain why
the BIOS expects a byte when the mouse pins are idle.

## Sep 29 reboot and root-filesystem rerun

The host reboot stopped the previous cold full-PC runs and cleared their
`/tmp` build. Their private disks/logs had been placed on the external NTFS
volume, which now fails a read-only mount with an `$MFTMirr`/`$MFT` mismatch.
Per the user's direction, leave that volume untouched: do not run repair or
force a writable mount. The intact `w95fresh.vhd` source on the separate ext4
volume still hashes to `cc68b00539f878de8b75b09d9b24a5eab00a763f2a015d4ef402bd80c971ccef`.

The exact 115-define combined candidate was rebuilt after reboot at
`/tmp/obj_dir_ven_ipc_v86iret_kbc_reboot_sep29/` (binary SHA-256
`3237b6523e8ec4c2db59ae0ef59012de45729b4852dcbdf8b3c20b7bc568d66d`).
Matched cold Win95 controls with the same source disk, BIOS, binary, rate,
RTC and 350.5M-cycle cap now run from private `/tmp` copies on CPU 23
(no mouse) and CPU 25 (`--mouse`). Their output roots are
`/tmp/ventium_w95_root_off_sep29` and `/tmp/ventium_w95_root_mouse_sep29`.
A separate 3.005B-cycle Quake cold run uses CPU 22 and
`/tmp/ventium_quake_root_sep29`. These are active diagnostics, not completed
desktop/timedemo passes. The latest verified gameplay IPC remains **0.45738614**
on the pre-candidate V86-far build over cycles 1.15B–1.4B; the current
candidate has no verified gameplay IPC measurement.

At the user's request, scratch runs will no longer create folders directly
under `~/`. Forty-four inactive random-named pair-hit Verilator output trees
and eight inactive L1D code-buffer compiler-output trees were removed from
`~/` after checking their contents; no guest source disk, snapshot, or
Win95/Quake run archive was deleted. Root free space rose from 17 GiB to
30 GiB. Those deleted generated build trees are rebuildable, not recoverable
as-is. `ventium/tmp` currently points to the almost-full external ext4
volume, so these new runs use `/tmp` instead.

Two more isolated `/tmp` controls were started without changing the
production binary: `/tmp/ventium_w95_root_mouse_watch_sep29` on CPU 24
enables `--mouse` and a 256-cycle KBC internal-state sample beginning at
250M cycles; `/tmp/ventium_w95_root_mouse_long_sep29` on CPU 26 keeps
`--mouse` running toward a 1.2005B-cycle desktop check if the 350.5M
diagnostic cap proves too short. The `VEN_SEG_ENFORCE` CoreMark RTL
testbench rebuilt successfully under the one-job memory guard in
`/tmp/obj_dir_pv86iret_reboot_sep29`; its 1,500-iteration validation seed
is now running on CPU 27. None of these in-progress tests is a pass claim.

The first rebooted validation invocation accidentally selected `--cycle`,
unlike the earlier functional-mode reference-CRC runs; it was stopped before
completion. The replacement `ventium-coremark-validation-func-sep29`
uses the same RTL/image on CPU 27 without `--cycle`. The aborted run is
not counted as a failure or a pass. At 134M cycles the replacement had
52.8M retirements, not the 87.5M in the Sep 28 validation log. Therefore
the `--cycle` flag alone did **not** explain the throughput difference;
the old and new build profiles or other source differences must be compared
before interpreting any CoreMark performance delta. This correctness run
subsequently completed `exit_group(0)` after 541,458,790 retirements /
1,377,269,891 RTL clocks with `crcfinal=0xe230` and `Correct operation
validated`. This is the validation-seed correctness result, not a gameplay
IPC measurement or a throughput comparison. The matching 1,500-iteration
performance seed has now started on the same post-reboot direct-TB binary,
CPU 27, as `ventium-coremark-performance-func-sep29.service`; the earlier
`0x25b5` performance-seed result used a pre-reboot binary and is not being
silently substituted for this same-build check. Win95 desktop and Quake
timedemo remain unverified.

The matched rebooted Win95 pair has now reached the diagnostic point:
at 265.4M cycles the no-mouse control was at V86 BIOS `F000:4B63`, in
the previously disassembled `(status & 0x21) == 0x21` poll. In contrast,
the `--mouse` run logged real device commands `F3`, `F2`, `E6`, `F3`, `F4`
and by 260.9M cycles was again retiring Windows protected-mode code
(`CS=0028`, `EIP=C0234539`). This is evidence that an absent external
PS/2 mouse causes **this** BIOS wait; it is not yet proof of a desktop boot
or of the full standard suite. The separate mouse-state observer and long
mouse-enabled run remain in progress.

Because historical Win95 cold runs at roughly 1B cycles did not reach a
desktop, an additional private, mouse-enabled 3.005B-cycle qualification
started on CPU 28 at `/tmp/ventium_w95_root_mouse_desktop_sep29`. Its purpose
is desktop reachability; neither the 350.5M diagnostic nor the 1.2005B
screen is assumed to be long enough. `/tmp` and host memory were checked
before launch and remained well below capacity.

Three *same-binary, same-source-disk, mouse-enabled* `1,Enter` timing
ablations were briefly launched on CPUs 20, 21 and 30, starting at 10M,
30M or 50M cycles, with dense VGA text sampling. Read-only FAT inspection
then disproved the alleged boot-menu ambiguity for this source disk:
`BootMenu=0`, `BootKeys=0`, `BootGUI=1`, no `WNBOOTNG.STS`. All three were
stopped before their cap as irrelevant keyboard perturbations. They are
**not** Win95 qualification results, and their private disks are not
inputs to the ongoing unkeyed controls.

An original-ao486-core platform comparison now runs on CPU 20 in
`/tmp/ventium_w95_ao486_control_sep29`. It uses the same
`cc68b005...` source disk, frozen `dca915c5...`/`fb0d673a...` ROMs,
32 MiB, 45 MHz nominal CPU, connected mouse, VGA divider 4 with jitter 1,
and final `--ddrlat 2`. Its binary SHA-256 is
`556a49a281767bf5105f209a8474bd417828e977e6f42ae91c6c7f417522acc5`.
The legacy core/harness is not cycle- or peripheral-identical to the
Ventium swap, so a failure remains inconclusive; a desktop would establish
that this source can boot on the ao486 platform. Its legacy VGA capture was
changed to honor the per-run `--fb-out` prefix, avoiding writes into the
almost-full `ventium/tmp` symlink; a 1,000-cycle output-path smoke test
passed, and the throwaway frame was removed. No desktop result yet.

The first original-core run retains that harness's default 80 kHz RTC
despite the 45 MHz CPU rate; it is a *historical accelerated-RTC control*,
not an exact timebase match. A second original-core run on CPU 21 at
`/tmp/ventium_w95_ao486_rtc45m_sep29` adds `--rtc-rate 45000000` while
otherwise keeping the same binary, source disk, ROMs, mouse and DDR/VGA
settings. Both remain active; compare them separately before attributing
any difference to the CPU core.
At their latest checked samples the current-disk original-core 45 MHz runs
have passed 2.13B and 2.02B cycles, respectively. Both report graphics mode
with palette-address source disabled (`pas=0`) and have an all-black 640x480
frame. They continue running to 3.005B; this is stronger negative screen
evidence than the earlier 1.1B cap, but still not proof that the disk is
unbootable or that a particular RTL change caused it.

The archived `ao486-sim/REPRODUCE.md` names a stronger original-core
**configuration** reference: stock `boot0.rom` (`e70c8843...`), 4 MHz CPU,
80 kHz RTC, `--ddrlat 1`, deterministic 2000-01-01 clock, connected mouse,
and four Enter keys beginning at 550M cycles. It reports a visually captured
desktop around 0.75–0.96B cycles, but used an external `w95_200.vhd` whose
hash is not available here. The existing two original-core 45 MHz controls
above are timing/platform ablations, not reproductions of that passing
recipe. A separate CPU-17 reference now runs the documented settings with
the **current** `cc68b005...` disk, a private copy, frozen stock ROMs and a
1.1005B-cycle cap at `/tmp/ventium_w95_ao486_repro4m_sep29`. Its source
disk already has `[boot] display.drv=vga.drv`. This run has since exited
zero at its cap **without a desktop**: the final VGA state was graphics mode
but the 640x480 frame had no nonblack pixel. Its wrapper result is correctly
`clean_exit_unqualified`, not a Win95 pass or a VxD error.
A command/receipt audit confirms the reproduction's 4 MHz CPU, default
80 kHz RTC, DDR latency 1, 32 MiB, connected PS/2 mouse, four Enter keys
at 550M/120M gaps, stock `e70c8843...` BIOS, and UTC 2000-01-01 clock;
the time-shim shared object exists and no preload failure is logged. The
remaining material differences from `ao486-sim/REPRODUCE.md` are the current
disk image (`w95fresh.vhd` rather than the unlocated historical
`w95_200.vhd`), current simulator/RTL build, and the shorter cycle cap.
A desktop in this run would establish current-disk viability on the
original ao486 simulator, not a Ventium core pass.

The historical source itself is now also a controlled axis. A detached `/tmp`
worktree at commit `9db37a33526a0349da75e7c73b318144ab4fafc9` uses its
pinned ao486 submodule commit `e1bd7673...` plus its own documented
`ao486_MiSTer.patch`; it was built under the one-job memory guard without
changing the dirty current checkout. Binary SHA-256 is `ec408a06...`.
Two CPU-pinned 4B-cycle cold runs use this exact historical simulator with
the documented 4 MHz/80 kHz, stock-ROM, mouse and four-Enter setup:
`/tmp/ventium_w95_hist9db_jul13_sep29` on CPU 4 and
`/tmp/ventium_w95_hist9db_current_sep29` on CPU 3. The former uses the
private July 13 display-fixed disk (`64ed416f...`); the latter uses today's
`w95fresh.vhd` (`cc68b005...`). Both are active, not desktop results.
The historical host shim resolves its stock ROM via the working directory,
not the wrapper's `--bios0/--bios1` arguments; the current and historical
release ROM files were compared and have identical SHA-256 hashes.
The 1.1005B-cap reference had entered graphics mode but still rendered an
all-black frame after all four scheduled Enter events were queued, through
its cap. Because the older `w95_200.vhd` desktop range need not
apply to this disk, an otherwise identical original-core control with the
full documented 4B-cycle cap now runs concurrently on CPU 29 under
`/tmp/ventium_w95_ao486_repro4b_sep29`; this is a disk/platform viability
check, not a Ventium pass. The shorter control remains undisturbed.

A second original-core control tests one platform RTL change. The current
`3rd-party/ao486_MiSTer/rtl/soc/ps2.v` holds `io_readdata` after the read
strobe; the historical passing source updated it every selected cycle. A
scratch source copy under `/tmp/ventium_ao486_prehold_ps2_sep29.v` restores
only the historical two-line behavior, and its filelist redirects only this
module. A guarded single-job build produced binary SHA-256
`98610f6809640f5ed400e831f7f0b4281f14207d6f0d0c36491cf8f6f9ec4903`.
The CPU-17 run `/tmp/ventium_w95_ao486_prehold4m_sep29` uses the same disk,
stock ROMs, 4 MHz CPU/80 kHz RTC, 2000-01-01 clock, mouse, four Enter keys,
and 1.1005B cap as the completed all-black original-core reference. It is
active, not a result yet. A desktop there would isolate a PS/2 regression in
the original platform; another black cap would leave the disk/build
difference unresolved. This source copy and build live in `/tmp`, not `~/`.
Their sampled original-core trajectories are identical through 259.5M
cycles, then diverge near 260M when the PS/2 command path is active. Both
are still in VGA text mode at the matched 324,009,983-cycle sample. At the
matched 428,343,295-cycle sample the current read-hold control has entered
graphics mode (`gfx=1`, palette-address source off, no desktop), while the
historical-read variant remains in text mode (`gfx=0`); it is still text
mode past 505M cycles. This is evidence that the change matters on the current
disk, but does not show that it introduced the all-black desktop failure.
Await the cap and frame evidence
before accepting or rejecting the read-hold fix.

An additional disk-viability control uses the July 13 image
`/home/yukidama/external/ventium_run/tmp/w95_clean.vhd` (source SHA-256
`4a4a20d3...`, FAT16 partition at LBA 2048). Its original `SYSTEM.INI` had
`[boot] display.drv=pnpdrvr.drv`, matching the archived recipe's pre-fix
condition. Only a private `/tmp` copy was given the documented
`display.drv=vga.drv` fix; its resulting SHA-256 is `64ed416f...`.
After that fix, `SYSTEM.INI` and `WIN.INI` match the current disk byte for
byte, and `USER.DAT` has the same SHA-256 on both. The `SYSTEM.DAT` registry
hives differ (`45693d66...` current versus `d621b93d...` July), as do
`MSDOS.SYS` boot-key/menu settings and the current disk's explicit
`AUTOEXEC.BAT` `WIN` command. Removing that explicit command already failed
to fix the current-disk VxD error, so any July-versus-current outcome must
not be attributed to that line alone.
CPU 18 runs that copy on the same current original-ao486 binary and exact
4 MHz/80 kHz, stock-ROM, mouse, four-Enter setup as the 4B current-disk
control, at `/tmp/ventium_w95_ao486_jul13_disk4b_sep29`. It is active and
has a 4B-cycle cap. The historical `w95_200.vhd` is still unavailable, so
this is a distinct older disk, not a literal reproduction of its reported
desktop. A desktop here but not on `w95fresh.vhd` would make the current disk
a prime suspect; a black cap on both would keep the simulator/RTL changes in
scope.

For an actual same-disk CPU comparison without the stock-ROM cache-disabled
slowdown, CPUs 8 and 19 now run a second July-image pair at
`/tmp/ventium_w95_{ao486,ven}_jul13_patched4m_sep29`. Both use the private
`64ed416f...` disk, cache-enabled `dca915c5...` boot ROM, 4 MHz CPU/80 kHz
RTC, mouse, four Enter keys, DDR setting 0 and a 1.1005B-cycle cap. The
frozen original binary is `556a49a2...`; the Ventium binary is
`3237b652...`. The pair is active, with separate CPUs and disks, and neither
has a desktop result yet. Compare it to the otherwise same current-disk
CPU-14/15 pair to isolate a disk-versus-core effect.

The current legacy IDE host daemon has changed since the historical July 20
desktop commit `9db37a3`. A separate original-core binary
`11e0f12b54b0fb4560c559b9c7c77bc5268bb89ad44b8aee214b02a5d0681018`
uses that commit's `ao486-sim/ps/ide.cpp`, with current RTL and all other
current simulation sources. A `/tmp` compatibility definition supplies only
the newer snapshot-only `ide_img_rebind` symbol; the cold runs do not restore
snapshots or call it. CPUs 7 and 9 run this IDE variant against private July
and current disk copies, respectively, with the same patched-ROM 4 MHz/80 kHz
profile as the CPU-8/14 current-IDE originals. Both are active at
`/tmp/ventium_w95_ao486_oldide_{jul13,current}_sep29` and have no desktop
result yet. This isolates an IDE host-code regression separately from the
PS/2 RTL and guest-disk changes.

A distinct single-module ablation replaces only the current original-core
`rtl/soc/ide.v` with the historical July RTL. Its scratch copy adds only
two outputs wired to existing `disable_irq`/`sw_reset` registers to satisfy
current `system.v` debug ports; those observer wires do not alter device
behavior. The filelist redirects only `ide.v`. Guarded build binary SHA-256
is `be9f0ffe6d1c6e933a465711cc48889c207f4e437ca30c9320c26a9f26dd3438`.
CPUs 2 and 1 run it against the current and July disks, respectively, at
`/tmp/ventium_w95_ao486_oldide_rtl_{current,jul13}_sep29`, with the same
patched-ROM 4 MHz/80 kHz profile as the CPU-14/8 controls. Both are active,
not outcomes. This is separate from the historical **host** IDE daemon
variant above; a one-file result does not justify changing the other layer.

CPU 16 runs the frozen current Ventium binary with the same source disk,
stock ROM hashes, 4 MHz CPU, 80 kHz RTC, 2000-01-01 epoch, mouse, four-Enter
schedule, 32 MiB and 1.1005B-cycle cap at
`/tmp/ventium_w95_ven_repro4m_sep29`. Its bridge setting is the golden
`FPGA_DDR=0`, approximately corresponding to the original's `--ddrlat 1`,
but the two cores/harnesses are not cycle-identical. Both services are
confirmed active. Compare guest outcome and transition states, not cycle
counts or raw IPC, and do not adopt this historically accelerated RTC
profile as the final FPGA configuration merely because it boots faster.

The stock-ROM Ventium run immediately shows `CR0=60000010` (CD/NW set) and
only 135,270 retirements by 7M cycles. A prior stock-ROM Ventium control
reached only ~24.8M retirements by 1.05B cycles, so that configuration may
not reach the Windows transition by this pair's cap; a cap without a
desktop would be uninformative. For a more timely CPU comparison, CPU 14
now runs the original ao486 core and CPU 15 the current Ventium binary with
the **same cache-enabled boot0 ROM** (`dca915c5...`), boot1 ROM, disk,
4 MHz CPU/80 kHz RTC, mouse, four-Enter schedule, 32 MiB and 1.1005B-cycle
cap. Their roots are `/tmp/ventium_w95_ao486_patched4m_sep29` and
`/tmp/ventium_w95_ven_patched4m_sep29`; frozen disk/ROM hashes match and
both services are active. This is a diagnostic accelerated-timebase pair,
not the 45 MHz hardware acceptance profile.

The historical original-core desktop recipe also required four Enter keys
to dismiss first-boot dialogs. The current 45 MHz mouse-enabled long run has
no scripted keys and remained in protected-mode VMM code without a graphics
capture past 608M cycles. To separate a pending guest dialog from a CPU
fault, CPUs 13 and 12 run two additional private-disk, same-binary
(`3237b652...`), same-ROM 45 MHz ablations. They add only four Enter keys,
starting at 550M or 800M cycles respectively, with 120M-cycle gaps; caps
are 1.2005B and 1.4005B. The unkeyed CPU-26 long run is the control.
Both key variants are confirmed active. The earlier 10/30/50M key probes
addressed a disproved boot-menu hypothesis; these later inputs specifically
test first-boot dialog dismissal and are not interpreted as a Normal-boot
selection. No GUI result yet.

At 600M cycles the unkeyed CPU-26 run's VGA observer still reports text
mode (`attrib_graphic_mode=0`), but its character window is blank rather
than showing the earlier "Starting Windows 95..." text. The periodic
frame-capture path has emitted no PPM, because it only captures when the
VGA graphics-mode bit is set. Thus the blank screen is **not** a desktop
witness or proof of an error message; the core continues retiring VMM code
past 620M cycles. The longer run and key variants remain necessary.

One additional matched mouse-enabled Ventium ablation is active on CPU 23:
`/tmp/ventium_w95_mouse_platform_l2off_sep29` adds only `--l2dis 1`
to the same frozen binary (`3237b652...`), source disk, ROMs and clocks,
with a 500.5M-cycle cap. This switches off the **ao486 platform L2**, not
Ventium's already-disabled `EN_L2`; it is a diagnostic test of the later
Windows path, not a proposed performance workaround. No result yet.

A separate CPU-29 same-binary mouse-enabled run at
`/tmp/ventium_w95_vmm_trace_sep29` enables only bounded observers:
20,000 internal-state cycles beginning at 330M and 40,000 retirement
records beginning at retire 88M. Its purpose is to identify the later
`C000:31xx` protected-mode hot path without perturbing the qualification
runs. It too is not yet a completed result.

The bounded V86 trace later exposed two suspicious transfers into BIOS-shadow
addresses. **Interpretation corrected September 30:** the VTM callback reports
the retired instruction PC alongside **post-commit** segment selectors. Thus
the printed `FCBF:0193` and `FCB2:22E0` combinations cannot be mapped as source
instruction addresses without reconstructing their pre-execution CS. The
earlier ROM-string/zero-byte source interpretation is withdrawn. Predecessor
breakpoints must capture the original CS and actually fetched bytes. Both transfers
lead into the Windows fault handler and the guest continues; they are not by
themselves a terminal halt or proof of a core fault.
The existing breakpoint observer has one non-mutating linear-memory probe.
CPUs 6 and 5 now stop just before their respective predecessor instructions
at `04CB:0190` and `FFFF:2C1E`, probing `SS:SP` at linear `0x8EFF0` and
`0x8EFFA`. Their private cold-run roots are
`/tmp/ventium_w95_font_stack_{0190,2c1e}_sep29`. If a probed frame already
contains the odd destination, it is only a backing-memory observation: the
debugger reads DDR directly, which may omit dirty L1D/write-buffer data. Capture
the translated stack ACKs and latched return targets, ESP and SS.B before
deciding whether the input frame or transfer is wrong. These historical probes
were stopped without qualification; they are not active September 30.

The history narrows when this particular platform omission arose: the
legacy ao486 simulator's opt-in pin-level `ps2_mouse_drive()` was present
by commit `9db37a33` (2026-07-20). The Ventium-swapped simulator was
introduced in `f6f6ced0` (2026-08-02) with both mouse input pins tied
high and no device drive. Thus the no-mouse BIOS wait is not caused by the
recent IPC defines; it is a latent omission in the swapped full-PC harness.
The current `--mouse` port restores that *general PS/2 device* model as an
opt-in host feature. This provenance does not prove that every remaining
Win95 startup delay has the same cause.

The bounded KBC observer sampled cycles 250,000,000–250,000,255 before the
mouse command exchange: its FIFO was empty, `OBF=0`, and controller
`mouse_disabled=1`. This is only pre-command state and must not be used to
claim that the later `D4`/device-response handshake was traced. Its separate
mouse-enabled run subsequently left the old BIOS wait and re-entered
protected-mode Windows code by 265M cycles, reproducing the main mouse-on
result.

The matched 350.5M-cycle pair has now ended. Both simulators exited zero
without the old VxD error, but **neither is a desktop pass**. At their common
350,421,422-cycle sample, the no-mouse control had 86,858,939 retirements
and was still polling `F000:4B60`; the mouse-enabled control had 93,420,747
retirements and was executing `CS=0028, EIP=C000322B` in protected-mode
Windows code. No graphical desktop frame was produced at this cap. The
1.2005B- and 3.005B-cycle mouse-enabled qualifications remain active on
separate private disks.

Two further CPU-pinned, private-disk mouse-enabled ablations started on the
same frozen binary (`3237b652...`) and `cc68b005...` disk. CPU 24 at
`/tmp/ventium_w95_mouse_rtc80k_sep29` changes only the RTC timebase from
45 MHz to the legacy harness's 80 kHz; CPU 25 at
`/tmp/ventium_w95_mouse_ddr0_sep29` changes only the bridge model from
`FPGA_DDR=2` to the golden-latency model (`FPGA_DDR=0`). Both have 500.5M
cycle caps, started successfully under independent user services, and have
no outcome yet. These are causal timing ablations, not proposed final
configuration changes or completed desktop qualifications.

The long mouse-enabled run has now passed 510M cycles and continues retiring
in protected-mode VMM code (`CS=0028`, `CR0=8000001b`), with no graphics
frame or desktop yet. Its periodic `C0003212`/`C000322D` samples alone are
not a hang witness: bytes extracted from the older 300M DDR checkpoint
disassemble `C00031F7`–`C0003250` as callback-list traversal, and another
observed PC, `C0008F9F`, is in a VMM path that executes `STI; NOP; NOP;
CLI; JMP` at `C0008FC0`–`C0008FC4`. That is consistent with an interrupt-
waiting idle loop, but does not prove boot progress or correctness. The
bounded 330M internal-state/retire trace and the longer desktop run remain
the deciding evidence.

A new concrete V86 symptom is visible in the long run's debug-fault log:
`#UD` reports at `FCBF:2F27`, `FCB2:2FF7`, `FD4D:2647`, and other aliases
all form linear `0x000FFB17` (`CS<<4 + EIP`). The frozen 64 KiB `boot0.rom`
has bytes `63 38 6c 6c 38 cc 78 00` at offset `0xFB17`; these are in its
font-data area, not an ordinary BIOS instruction sequence. **September 30
correction:** this alone is not an invalid transfer: Windows deliberately
uses a ROM `ARPL` byte as a V86-to-VxD callback trap, with different CS:IP
aliases selecting different callbacks. The actual-frame evidence and primary
documentation are recorded below; no processor defect follows from these
targets alone. The first such messages appear
near the ~175M protected/V86 transition in the current log, but mixed
stdout/stderr buffering makes that timestamp approximate. To capture the
precise entry state, two same-binary, mouse-enabled, CPU-pinned runs on CPUs
30 and 31 arm existing EIP breakpoints at `0x2F27` and `0x2FF7` after retire
24M; CPU 18 records a bounded 3.5M-retirement trace from retire 27M. All
use private disk copies and have 220.5M/190.5M caps respectively. They are
active, not yet results.

The CPU-18 bounded trace has since finished its 27M–30.5M retirement
window. At retire 28,478,697/cycle 169,522,819, it records a V86
retirement at PC `22E0` with post-commit CS `FCB2` (not a proven source CS),
followed by entry to the protected-mode exception
handler at `0028:00002FF7` and then the VMM's `C00012xx`/`C0001Axx`
handler code. The latter computes the fault linear address `000FFB17` from
`FCB2:2FF7` before continuing; the same pattern recurs at retire 28,707,869.
This proves the `#UD` is delivered to guest VMM code and is not itself a
terminal core halt. It does **not** prove the V86 target is correct or that
the handler recovers without guest-visible damage. Stopped target-breakpoint
reports below settle the fetch address; predecessor probes remain necessary
before attributing it to a core defect.

Both stopped target-breakpoint reports are now available on the same frozen
binary and source disk. At retire 28,478,288, the next state is
`FCBF:2F27` after last-retired EIP `0193`; at retire 28,478,696 it is
`FCB2:2FF7` after last-retired EIP `22E0`. Both CS bases plus offsets yield
linear `000FFB17`; the debugger's page walk maps it to the **same physical**
`000FFB17`, whose next 32 bytes match BIOS font data beginning
`63 38 6C 6C 38 CC 78`. This removes address-alias/page-walk ambiguity for
the target, but not the cause of either transfer. Two new frozen-binary,
private-disk probes on freed CPUs 30/31 stop *before* executing the respective
predecessor EIPs `0193`/`22E0`, armed only after retire 28,478,000. Their
purpose is to capture the source instruction bytes and physical mappings;
until those reports arrive, do not label this a V86 IRET or cache bug.

The CPU-29 bounded observer has also completed its 40,000-retirement window
at cycles 329,383,002–329,538,002 and its 20,000 internal-state cycles at
330,000,000–330,019,999. Every retired PC in that window is in the
protected-mode `C00031xx`/`C00032xx` or `C0008Cxx`/`C0008Exx`/`C0008Fxx`
VMM loop; `C0008FC1`–`C0008FC4` occurs 455 times. The internal-state
observer sees memory acknowledgements and instruction retirement, so this
is a guest-side idle/poll loop rather than a core FSM frozen on one request.
The long run also logs repeated deliveries of vector 80 decimal (`0x50`) at
`C0008FC2`, the NOP inside the loop's `STI; NOP; NOP; CLI` interrupt window;
therefore interrupt delivery is not globally absent. The short bounded
window cannot identify which device sourced that vector, prove all expected
interrupts arrive, or establish useful boot progress. It is not a desktop.

The cold Quake run on the **current combined** V86-IRET/PS/2 candidate
(frozen full-PC binary SHA-256 `3237b6523e8ec4c2db59ae0ef59012de45729b4852dcbdf8b3c20b7bc568d66d`)
has reached visible gameplay. Frames `frame_00007.ppm` and
`frame_00009.ppm` under `/tmp/ventium_quake_root_sep29/` were visually
checked as in-game scenes (SHA-256 `936f2be9...` and `55fe1bf7...`). The
corresponding exact counter endpoints are 395,087,983 retirements at
1,000,151,638 cycles and 443,605,989 at 1,100,151,638 cycles. Thus the
**current verified candidate gameplay IPC is 0.48518006 over that 100M-cycle
window**. This is a different, earlier/shorter interval than the 0.45738614
pre-candidate baseline at 1.15B–1.4B; it cannot yet be interpreted as a
like-for-like IPC gain. The Quake timedemo has not completed, so the standard
suite remains open alongside Win95 desktop boot.

The same frozen current-candidate cold run has now reached a comparable
later gameplay window. Exact counters are 466,144,730 retires at
1,150,151,638 cycles and 580,511,370 at 1,400,151,638 cycles, yielding
**0.45746656 verified gameplay IPC** over 250M cycles. Frame 14 from this
run was visually inspected as in-game play, not a menu or splash. The older
pre-candidate `19381c7d...` run measured 0.45738614 in a 250M-cycle window
starting 325,029 cycles earlier; the 0.00008042 absolute IPC difference is
negligible at this resolution and the windows are not bit-identically
aligned. Neither run has completed the timedemo. The current candidate's
earlier 0.48518006 result remains valid for its own 1.0B–1.1B gameplay
window but is not the latest comparable measurement.

Historical `ao486-sim/DISK_BOOT_STATUS.md` UPDATES 169 and 247 report a
Win95 *hardware desktop signature* using a file named `w95fresh.vhd`:
graphics mode plus VMM fetch and the `0x1e5/0x1e6` V86 System-VM idle stub;
UPDATE 247 sampled this at about 1.226B hardware cycles. Those reports
did not pin the image SHA-256 or include a captured desktop frame, so they
are useful evidence that this platform once advanced much further, but not
an exact-source, exact-build positive control for the present
`cc68b005...` simulator run. In the current candidate at 555M simulated
cycles, the mouse-enabled long run is still retiring protected-mode VMM
code and has no graphics capture. Continue the long run; do not infer a
permanent hang from this shorter window or accept the historical signature
in place of a visual desktop witness.

Diagnostic replay acceleration is being implemented without touching RTL:
the native snapshot format v4 includes the entire host-side PS/2 mouse
state (receive/transmit phase, sampled clock, partial byte, command flags,
transmit bits and queued replies) and records mouse presence so mismatched
restores fail. Older v2/v3 files remain unchanged and mouse-enabled v3
snapshots are still rejected. A separately relinked same-RTL binary
(`513b2182...`, original qualification binary `3237b652...` left frozen)
passed byte-identical uninterrupted-vs-restored v4 full-state replay from
1.0M to 1.2M cycles with mouse enabled; a second run with private copies
of the `cc68b005...` disk also had byte-identical final snapshots **and
disk contents**. The same new binary passed both v2 and v3 no-mouse replay gates;
v4 restore without the saved mouse-presence flag and v3 save with mouse
both fail explicitly. These short checks cover snapshot format and idle
device state, **not** a mid-command PS/2 exchange or Win95 boot. To close
that gap, two independent CPU-10/CPU-11 cold runs of this v4 binary are
active with private disks and mouse enabled: save-stop at 258M (near the
observed real `F3/F2/E6/F3/F4` exchange) and 260M cycles. Once both
finish, replay the 258M snapshot plus its stopped disk to 260M and compare
both full state and disk to the uninterrupted 260M control before using
such snapshots for further Win95 diagnosis. No save-state result will count
as a desktop qualification; final boot acceptance remains a cold run.
The CPU-11 uninterrupted control has now cleanly saved its complete v4 state
at exactly 260,000,000 cycles (70,470,218 retirements; 134,918,905-byte
snapshot) with no VxD error; this is still not a desktop result. The CPU-10
258M source is still live, so the decisive replay comparison is pending.

## September 29 additional disk and I/O-bus controls (pending)

An original-ao486-core, one-file I/O-bus ablation is now live on CPU 11 at
`/tmp/ventium_w95_ao486_oldiobus_current_sep29`. Its binary SHA-256 is
`e6248c8311b3e8cd35d02488e83c24c758bfb40f7c98b7496b22999cddb760ac`.
The scratch filelist differs from `ao486-sim/rtl.f` only in the `iobus.v`
entry, which points to the pinned historical ao486 submodule commit
`e1bd7673f6dc485de615d09abe6df9d4ae654f9b`; all other current RTL and
host sources match the reference build's source timestamps. The run uses the
same current disk SHA `cc68b005...`, stock ROMs, 4 MHz CPU / 80 kHz RTC,
connected mouse, four Enter keys and 4B-cycle cap as the active current
original-core control on CPU 29. It has no result yet. The old I/O-bus read
FSM predates the added `S_READ_W2` settle cycle and single-strobe correction;
an early IDE regression is possible and would not be a reason to revert a
known-good read protocol. Only a matched boot outcome can identify a causal
platform difference.

For an independent disk-viability check, pinned QEMU 8.2.2 `-cpu pentium`
runs on CPU 0 with the current source disk behind `snapshot=on` (no source
disk writes), 32 MiB RAM and a 2000-01-01 guest RTC. The monitor socket and
captures are under `/tmp/ventium_w95_qemu_disk_sep29*`. Its first captured
screen showed DOS/Windows text startup; a later register sample was in
protected mode (`CR0=80000011`, `CR3=00308000`, `CPL=3`). It has **not**
yet shown a desktop. QEMU uses a different BIOS/platform and therefore can
establish disk viability if it reaches a desktop, but cannot by itself
identify the ao486/Ventium fault.

## Handoff snapshot — 2026-09-29 18:11 EDT

No Win95 run has a visually verified desktop, no Quake timedemo has completed,
and the introducing change is **not yet isolated**. The last verified Quake
gameplay IPC remains **0.45746656** over cycles
1,150,151,638–1,400,151,638 on frozen full-PC binary `3237b652...`;
that binary predates the current working-tree candidate, which has no newer
verified gameplay measurement. The same cold Quake service is still active
at about 1.448B cycles, with gameplay previously inspected. The same-build
CoreMark validation seed passed with CRC `0xe230`; its performance seed is
still active, so the full standard suite is open.

All cycle values below are the latest log samples at the handoff, not caps or
desktop claims. Existing services were confirmed active through the user
service manager; **no new runs should be launched pending further direction**.

| Live comparison / probe | Latest observation | What it establishes |
|---|---|---|
| Ventium, mouse-enabled current disk, no keys (`w95_root_mouse_long`) | 908.4M cycles, protected-mode VMM; no graphics/desktop | Longer than the prior 350M mouse probe, but not a pass. The separate 3.005B cap is at 618.4M. |
| Original ao486, documented stock-ROM 4 MHz / 80 kHz RTC (`w95_ao486_repro4b`) | 468.2M cycles, graphics mode has not yielded a desktop | Current disk viability on this platform remains open; the earlier 1.1B-cap control ended with a black frame. |
| Original ao486, July display-fixed disk (`w95_ao486_jul13_disk4b`) | 524.3M cycles, graphics mode with `pas=0`, all-black capture | Disk-content comparison remains open. |
| Original-core stock-ROM PS/2 read-hold vs historical read behavior | Matched current read-hold control reached graphics mode by 428.3M and ended black at 1.1B; historical-read variant is still in text mode at 610.8M | Read-hold changes boot trajectory but is not proven to cause the blank screen. The separate patched-ROM current control is at 826.3M and is not the matched PS/2 comparator. |
| Historical IDE host-only variant, current/July disks | 604.0M / 612.4M cycles; both reached graphics mode with blank output | Old host IDE logic alone has not produced a desktop. Historical IDE RTL-only variants are much earlier at 107.5M / 114.3M. |
| Exact July-20 historical platform, current/July disks | 189.8M / 161.0M cycles | Still too early to establish a known-good ancestor. |
| Historical `iobus.v` one-file variant (`w95_ao486_oldiobus_current`) | 24.1M cycles on CPU 11; binary `e6248c83...` | Build and isolated run are valid; no boot comparison yet. |
| Same-source Win95 v4 mouse snapshot source | 244.4M of 258M cycles on CPU 10 | The 260M uninterrupted control saved successfully; 258M→260M full-state and disk replay is still pending. |
| V86 predecessor/stack breakpoint probes | source `0193` at 156.4M, source `22E0` at 140.9M, stack `0190` at 73.9M, stack `2C1E` at 76.4M | Historical handoff only; September 30 actual-ACK ring evidence below supersedes the inference of an invalid BIOS-font fetch. |
| Pinned-QEMU `-cpu pentium` disk controls | Current and July disks both active on separate snapshot overlays; latest screens still show text startup, not a desktop | Current-disk QEMU reached paging/V86 execution. A different BIOS/platform limits causal interpretation even if it later boots. |

The source images and active Quake/CoreMark inputs were left intact. After
removing 18 completed failed runs' *private* disk copies from the old home
archive, its logs/results remain. At handoff, `/tmp` had about 5.9 GiB free;
host memory reported about 15 GiB available and 1.6 GiB swap used. The
repository's `tmp` symlink points to an external volume that is full and
read-only, so any future scratch must use `/tmp` until that condition changes.
Existing services were left running; this handoff neither qualifies Win95
nor authorizes treating a cycle-cap exit as a desktop.

## September 30 standard-candidate cold Win95 result — FAIL

The `ventium-standard-win95-sep30` service used the newly frozen raw-profile
full-PC binary SHA-256
`122d9e0f61f054af80639fd7e0edf8189663dbe6c3aa6f9bab4fc4e751c5186d`,
with a private copy of the same source disk
`cc68b00539f878de8b75b09d9b24a5eab00a763f2a015d4ef402bd80c971ccef`
and the pinned cache-enabled ROM hashes recorded above (`dca915c5...` /
`fb0d673a...`, not the original CD/NW-set stock boot ROM). It ran cold at 45 MHz CPU/RTC,
90 MHz VGA, 32 MiB RAM, with a connected PS/2 mouse and no injected keys.
The original source disk and ROMs were not changed. The invocation and input
hashes are recorded in
`/tmp/ventium-standard-sep30.qUCAcQ/win95/external__ao486sim_ven_standard/case.json`.

The first paged protected-mode progress sample was at 288,905,999 cycles.
The VGA character capture at 400,026,424 cycles began displaying
`While initializing device VDD:`. The next capture at **425,026,424 cycles**
displayed the complete terminal message:

```text
While initializing device VDD:
Windows protection error.  You need to restart your computer.
Press any key to continue...
```

There was no graphics frame and no recognizable desktop. This is a **failed
Win95 desktop gate**, not an inconclusive idle-loop observation. The visible
message identifies the failing boot stage, not the introducing RTL defect;
no stale progress-log PC/CS pair is used to attribute the cause.

A corrected independent media control used pinned QEMU 8.2.2, `-cpu pentium`,
the same `cc68b005...` source disk on a disposable overlay, 32 MiB RAM and
standard VGA, with `-icount shift=4,sleep=off`. At its bounded 180-second
capture, `/tmp/ventium-win95-qemu-control-3ieaz1iu/screen_180.png` visibly
shows the graphical Windows Display dialog explaining that the display
adapter is not configured properly, with OK/Cancel buttons. This is not
yet a verified desktop, but it proves that this media advances into a GUI
on the reference PC, without the Ventium run's terminal protection message.
The sampled BIOS `HLT` at physical `0xF6A0A` is normal GUI idle, not evidence
of boot failure. The earlier five-minute QEMU control omitted the required
instruction-count clock setting and is inconclusive. QEMU's different BIOS
and VGA platform prevent this comparison from assigning the RTL failure to
either the CPU or VGA implementation alone; the corrected control narrows
the investigation away from a media-only explanation. A separate bounded
reference UI continuation is pending and does not qualify the RTL.

Only after confirming that complete error message, the monitor created the
authorized generic host stop request at
`/tmp/ventium-standard-sep30.qUCAcQ/win95/stop.request`. The simulator honored
it at **437,410,973 cycles / 73,933,723 retirements**, printed `[HOST-STOP]`
and its normal `>>> done:` receipt, and finalized normally. The service was
subsequently confirmed inactive/dead with MainPID 0 and exit status 0; its old
process was no longer present. The full log scan found no engine fatal or
state-restore marker, but did find the guest protection error. Clean host
finalization does not erase the guest failure. The legacy wrapper's
`result.json` says `clean_exit_unqualified`, `exit_code: 0`, and
`vxd_error: false`; its narrow VxD detector missed this VDD/protection text,
so those fields must not be promoted to PASS.

The preserved log is
`/tmp/ventium-standard-sep30.qUCAcQ/win95/external__ao486sim_ven_standard/run.log`
(SHA-256 `ed8a0d15293d3e2b6a5dca54dbe48b6290e8ce2bce4bc005a63a6d62ac720f63`);
the complete error text is at lines 6817–6819 and the normal stop receipt
at lines 6845–6846. The private disk, case manifest, log, and wrapper result
remain available for diagnosis. No new run or RTL fix was started by this
monitor.

The latest verified gameplay IPC remains **0.45746656** on the older
`3237b652...` binary over cycles 1,150,151,638–1,400,151,638. It predates this
standard candidate, which has no gameplay measurement yet. The standard
suite is not complete while this Win95 desktop failure remains open.

### Focused IRET stack defects — independently reproduced, VDD causality open

Read-only inspection following the VDD failure found three generic IRET
defects. The pinned P5 manual (241430-004, Volume 3, section 21.1, printed
pages 21-1/21-2; PDF pages 532/533) distinguishes the stack descriptor's B
bit, which selects SP/ESP for implicit stack references, from 66H/67H
operation/address prefixes. The pinned QEMU `seg_helper.c` likewise wraps
the V86 IRET pop addresses with mask `0xffff`, and its `return_to_vm86`
path assigns the full popped `new_esp`.

The new generic `verif/sys/tests/pv86iretstack` fixtures boot cold into
paging-on V86 at IOPL=3. Relevant stack pages have nonidentity mappings;
physical-alias reads verify the actual frame contents rather than allowing
consistently untranslated stores/loads to pass. The success trap checks the
saved source CS:EIP, VM/IOPL and completion marker before issuing the host
debug exit. A V86 port write is not incorrectly assumed to bypass the TSS
I/O bitmap. Every golden completes its self-check; no snapshot, BIOS/guest
patch, relaxed comparison, or workload-specific condition is involved.

The **unchanged pre-fix** standalone binary is SHA-256
`3ef25add322d2b23f78a26be22c41164623c5b3e380e7de4843f5ceae5a41764`.
The final four-case red capture is `/tmp/ventium-pv86iretstack.vmBBiN/`,
using `--system --cosim`, actual port-debug-exit handling, and pinned QEMU
on port 41431. All cases together took seconds, inside the shared bounded
build scope with a 540-second outer limit; no RTL build was launched by
this gate.

| Case | Correct reference outcome | Pre-fix RTL evidence | Narrow general correction |
|---|---|---|---|
| 1: IRETD with ESP `DEADF008` | 727 records; returns with full ESP preserved | 699 matching prefix records, then `#SS(0)` at `66 CF`, source offset `0018`, state `S_IRET` | Apply the existing `stk16()` address mask to every 32-bit pop slot as well as word slots; keep the four-byte operation width. |
| 2: IRETD with ESP `00000008`, frame wrapping SP | 734 records; slots wrap `FFFC → 0000 → 0004` | 704 matching prefix records, then `#SS(0)` at source offset `0018` | The same address correction; this case has zero high ESP and independently checks slot wrap. |
| 3: word IRET FLAGS at the final two bytes of a mapped page, next page absent | 707 records; returns with ESP `DEADF000`, VM/IOPL unchanged | First divergence at record 679/source offset `0011`: false user-read `#PF`, CR2 `0002F000`; RTL exits failure 199 | Publish the actual two-byte `cur_size` **and** read strobes `0011`; dword pops remain size 4/strobes `1111`. Masking only the final value or segment extent does not prevent page overfetch. |
| 4: full nine-dword CPL0 → V86 return from SS.B=0 | 647 records; installs guest ESP `CAFEF000` | First divergence at record 626/source PC `000F0229`: ESP becomes `0000F000`; RTL exits failure 201 | Exempt only the successful final `S_IRET` V86-entry ESP restore from the generic old-stack high-half merge. Ordinary implicit updates and protected outer-stack rules remain unchanged. |

The separate ordinary low-ESP, nonwrapping IRETD control (case 5) already
passes on that same **pre-fix** binary: 727/727 complete architectural
records and actual RTL debug-exit status 133, under
`/tmp/ventium-pv86iretstack.kSFF0C/`. This qualifies the corrected fixture
exit and comparator handling independently of the new fixes. Earlier
initial fixture diagnostics remain preserved, but the final red bundle and
passing ordinary control are the authoritative harness evidence.

The root agent applied those three narrowly scoped RTL corrections without
adding FSM states or changing cache configuration. A fresh same-profile
testbench, SHA-256
`12851ddf6d2110b6d68acd2c317eaf3fa96e3c83c528f51cda5c3f64f1366a80`,
now passes **all five cases** under `/tmp/ventium-pv86iretstack.Fph7M6/`:
complete QEMU/RTL record counts are 727, 734, 707, 647 and 727 respectively,
all functionally equivalent, with actual RTL debug-exit status 133 in every
case. Every case has only its one deliberately expected terminal INT20
`#GP(0x102)`; the spurious stack/page faults are gone. Cases 1–3 also pass
all physical-alias frame-content checks, and case 4 preserves the full
`CAFEF000` guest ESP. The entire five-case qualification took seconds under
the same bounded scope, with no extra comparison masks or length exceptions.

These directed red-to-green results prove architectural fixes; they **do not
yet prove** that any one caused the live VDD protection error. That requires
a cold candidate run and a precommit fault/frame witness, not the older
mixed-owner post-retirement PC/CS reports. Win95 desktop and the complete
standard suite remain open. These witnesses are microbenchmarks, not a new
gameplay IPC measurement: the baseline remains **0.45746656** on older
`3237b652...` over cycles 1,150,151,638–1,400,151,638, and the current
candidate is unmeasured.

### IRET-fixed candidate — existing system-regression controls

The same new standalone binary (`12851ddf6d2110b6d68acd2c317eaf3fa96e3c83c528f51cda5c3f64f1366a80`)
also passes the following **ten existing test programs** against the pinned
QEMU 8.2.2 `-cpu pentium` reference. Every pair has complete equivalent
architectural traces under `compare.py --mode func --all`, with system-field
comparison engaged, and actual debug-exit status **133** from both simulators.
This is focused system regression evidence, not a full `verify-sys` or standard
suite pass.

| Existing image | QEMU / RTL records | Relevant regression coverage |
|---|---:|---|
| `pv86iret` | 899 / 899 | Paged nonidentity V86 stack, word/dword intra-V86 IRET; exactly one intentional final `#GP`. |
| `pv86far` | 1226 / 1226 | Word/dword direct/indirect far CALL/RETF, immediate stack adjustment, translated cross-page stack; exactly six intentional I/O `#GP`s. |
| `pseg` | 90 / 90 | Protected segmentation, hidden bases, POP DS, 16-bit protected-code LDS with 66/67 prefixes. |
| `plar` | 78 / 78 | Register/memory LAR/LSL, operand widths, selector eligibility and unchanged invalid destinations. |
| `pcpl` | 304 / 304 | Protected CPL0/CPL3 interrupt-stack switching and outer IRET. |
| `pssiret` | 656 / 656 | Rejected outer SS frames remain restartable; valid outer IRET control. |
| `pstk16` | 159 / 159 | SS.B=0 protected-stack address/pointer wrap and cross-privilege stack installation. |
| `pretfres` | 447 / 447 | Rejected same-privilege RETF preserves ESP; word outer return zero-extends SP. |
| `pretfoutpg` | 283 / 283 | Word/dword outer RETF with frame slots on nonidentity translated pages. |
| `pint16f` | 419 / 419 | Word protected interrupt/trap frames, cross-privilege IRETW, B=0 wrap, dword controls. |

The `pssiret` fault log separately confirms `#GP(0x30)`, `#GP(0x38)` and
SDM-correct `#SS(0x40)`, with no copied QEMU `#NP(0x40)` deviation. Its
additional `+ven_nmi_arm` probe exits 133 and records exactly **five** rejected
IRET faults with NMI still armed, as required by the existing gate.

All receipts are preserved under `/tmp/ventium-iret-controls.BWY8u3/` (4.4 MiB):
each case has its build log, exact golden/RTL traces, full fault log, comparator
output and `receipt.json`. The reviewed existing scripts support `TB_BIN`, but
the standalone V86 wrappers erase their temporary receipts and the generic
runner builds images into the source tree. For this qualification, the unchanged
fixture sources, linker scripts and Makefiles were copied into the receipt
directory, and the same pinned producer/comparator and original caps/checks
were applied there. No RTL/QEMU/canonical testbench build or processor-source
edit occurred. The complete invocation finished in seconds inside one shared
bounded build scope with a **540-second** outer limit; child QEMU generation
and RTL runs were individually capped at 90/30 seconds. The scope and session
were reaped normally and QEMU ports 41431–41440 released.

Source and binary provenance is recorded losslessly in `inputs.sha256`,
`fixtures.sha256`, `images.sha256` and the copied `compiled-verFiles.dat`.
All fixture-source hashes were checked again after the run. Aggregate SHA-256s:

- `inputs.sha256`: `02e9b5ad6400d55fb5f6b9a21f78ac9ceda1c4d13708bd3efa790ef7c61a3785`.
- `fixtures.sha256`: `60bb842db06fdca445c2901d824acecb00ad075b2cba87bbf9e194aa464f6190`.
- `images.sha256`: `99466e20a2b0c98acdafb541d213f59d15543a67db68607df9cf6d03bb661fe3`.
- `compiled-verFiles.dat`: `7ea9be11d60612f9936d67aeff808f6aaf7747ffed716fdd4b0c8c44f2db1711`.
- Isolated command script `run-controls.sh`: `eb575d227fa4659002583635c120d31c423064df23a528f47a5153c5d6d5c399`.

The run-start source hashes for the relevant RTL files were
`core.sv=3f657199264ead3e69fe46c82a1ff801c3fc7f7651ffa35fba04a1381faaaa35`,
`core_bus_driver.svh=03a8c23861c6983126412765d0ed4cf76db53c4f377916a96a471fd45c224ee8`,
`core_iret.svh=3a7a5839232093bbbdc98da46cf162fee6b2274831c98ca04e70783b25cbf2b1`
and `core_gpr_wb.svh=18d87225f85b528eb2c7abc6af789b2911370c84e8aa10a37a4a06df99db9e39`.
The shared V86 fixture source is
`pv86.S=adeb7ad136307f1388cf430e95e0327b3f98e20a98291b846e171f90c7d03448`;
the pinned QEMU executable is
`b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd`.

These controls show no regression in the surrounding verified stack/return
paths; they do not establish a causal explanation or cold-boot fix for VDD.
Win95 desktop remains unqualified. Gameplay IPC remains **0.45746656** on the
older `3237b652...` binary over cycles 1,150,151,638–1,400,151,638; this new
candidate still has no gameplay measurement.

### Sep30 cold fault ring — ROM callback witness, not a font-corruption diagnosis

The new cold full-PC candidate, SHA-256
`b7cfbec7ee31c7ff7f81abf994995431f3c660b913ae2a9d3176c6d22a2db0ae`,
includes the three generic IRET fixes and the separately qualified AXI
quad-combiner correction. Its receipts are under
`/tmp/ventium-standard-iret-axi-sep30.dTKJW7/win95/`. It still displays the
complete **VDD Windows protection error** at `VGATEXT @425026424`; the
nested `external__ao486sim_ven_standard/result.json` reports
`status=terminal_error`, `terminal_error="Windows protection error"` and
`exit_code=-15`. The wrapper stopped and reaped the simulator after observing
the error; this is not a normal simulator-finalization receipt or a desktop
pass. The IRET fixes therefore do not resolve this cold-boot failure.

The passive `faults.log` captured sixteen complete vector-6 events, then
reached its configured event cap. All sixteen actual pre-fault linear
addresses are `000FFB17`, starting at cycle **298,751,228**. The final file is
2,071,609 bytes, SHA-256
`1b127ceccd95daa081f407cc167f390ad7dfe6d308f05b136fab0f6338f7477a`.
These observations correct the earlier suggestion in this document that
executing the ROM font byte itself demonstrates an invalid control transfer.
Microsoft's [KB71264](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/71/264.HTM)
documents Windows searching the permanently available ROM range for a system
breakpoint. NuMega's primary [Using SoftICE manual, printed page 103](https://gbppr.net/cracking/softice/NuMega_-_Using_SoftICE.pdf)
explains that Windows 95 uses one ROM `ARPL` byte for V86-to-VxD callbacks,
varying the segment:offset alias to select callbacks. Microsoft's
[DDK, chapter 23](https://www.pcjs.org/documents/books/mspl13/win/w3ddkvxd/)
also documents the V86 callback segment:offset mechanism. Consequently,
`0x63` in BIOS font data and multiple aliases of that address are strongly
consistent with an **intentional callback trap**, not by themselves a CPU
corruption witness. No guest `SystemROMBreakPoint` workaround was applied.

Actual pre-rising-edge context and FSM-visible ACK operands establish the
following transfers without combining a retired PC with post-commit CS:

| Event | Actual IRET source / source stack | Final acknowledged frame slots | Observed return |
|---|---|---|---|
| 1 | `04CB:0193`, SS `8E00`, SP `0FF0` | Cycles 298751145/146/147, linear `8EFF0/8EFF2/8EFF4`, size 2/strobes `0011`, read data `FCBF2F27/0287FCBF/006D0287`; consumed low words `2F27/FCBF/0287` | `FCBF:2F27`, VM flags `23287`, ESP `0FF6`; actual pre-CS base `FCBF0` gives `FFB17`. |
| 2 | `FFFF:22E0`, SS `8E00`, SP `0FFA` | Cycles 298755737/738/740, linear `8EFFA/8EFFC/8EFFE`, size 2/strobes `0011`, read data `FCB22FF7/0046FCB2/69720046`; consumed low words `2FF7/FCB2/0046` | `FCB2:2FF7`, VM flags `23046`, ESP `1000`; actual pre-CS base `FCB20` again gives `FFB17`. |
| 4 | Protected `0028:C0001350`, SS `0030`, ESP `C13ADF94`, SS.B=1 | Cycles 315714933/934/935, linear `C13ADF94/98/9C` (physical `198F94/98/9C`), size 4/strobes `1111`, values `00002FF7/0000FCB2/00023000`; following six acknowledged slots restore ESP `1000`, SS `8E00`, and zero ES/DS/FS/GS | The same `FCB2:2FF7` ROM callback is explicitly installed by protected-mode IRETD; final successful restore is cycle 315714942. |

The return fields follow the acknowledged operands exactly. Events 4–16
repeat the protected-mode return to this fixed callback with VM flags
`23002`; this is not merely the BIOS word-IRET sequence recurring. Retained
protected-mode retirements also show the upstream `C000347F`/`C00034C4`–
`C000350D` path manipulating packed `ECX=FCB22FF7`, then its CS half
`0000FCB2` and IP `00002FF7`. No incorrectly consumed frame operand has
been identified in these events.

State numbers were decoded using this exact full-PC profile, including
`VEN_DBG_CORE` and the shared-FP conditional states: **45 is `S_IRET`**,
42 is `S_INT_GATE`, 41 is `S_WALK`, 28 is `S_PIPE`, and 2 is `S_DECODE`.
The frozen `Vsystem__verFiles.dat` is SHA-256
`d4abefdaa05f390d073c4cf52ee6602083dc1d6bba8c622a0321dc5e63e1ae2b`;
its compiled `core.sv` matches SHA-256
`3f657199264ead3e69fe46c82a1ff801c3fc7f7651ffa35fba04a1381faaaa35`.
Default standalone-testbench numeric state constants would misidentify
these records. The ring's DPI retirement selectors are explicitly
post-commit; only its edge/pre-fault context owns the source CS/base.

Each event retains 256 retirements and 64 changed-edge snapshots. The
first two frame producers and the early vector-6 handler lookup are outside
those windows; none of the 4,096 retained retirement entries covers
`C0001Axx`. The ring therefore does **not** independently qualify the full
callback dispatch, prove its owner, or identify the cause of VDD's later
failure. It does rule out treating this font-byte `#UD` alone as evidence
that IRET fetched a corrupted frame. Handler code references must remain
distinct from live cache/ACK operand evidence; no DDR-only stack read or
new run was used for this conclusion.

Preserved native snapshots provide a separate, stronger **code-reference**
confirmation of the callback mechanism, without restoring a model or treating
DDR-only stack/table data as current operands. The read-only host-prefix parser
in `tools/inspect_win95_ddb.py` identifies these historical snapshots:

- `/home/yukidama/ventium-bg-sep28/win95_modeguard_replay_169519925_sep29/handler.snap`,
  cycle 169,519,925 / retirements 28,478,151, SHA-256
  `9fab89408eec02b00c241699baa69d20eb34d9cf14a1d3e8a7cfbaf49576b10e`.
- `/home/yukidama/ventium-bg-sep28/win95_v86iret_cold300_sep29/after300.snap`,
  cycle 300,000,000 / retirements 80,173,207, SHA-256
  `446d58f00a40dcec1ea78a570d9485fdbe72e70718fb3aef6b6c2dec8177397f`.

Using their recorded protected context, CR3 `00306000` maps code
`C0001A00` to physical `0022BA00`. In **both** snapshots the first 28 code
bytes are identical (SHA-256
`30cf5140e157c84d00d394d30fe527ccb0fc3d36847d9b09676c8bb9db828936`):
`C0001A01` loads source CS from `[EBP+28]`, `C0001A07` loads source IP
from `[EBP+24]`, `C0001A0A/0D` computes `CS*16+IP`, and `C0001A0F`
explicitly compares that address with **`000FFB17`**. The matching path
subtracts `FCB1` from source CS at `C0001A16`, obtains callback refdata at
`C0001A1C`, then jumps through the corresponding eight-byte table entry at
`C0001A23`. Thus `FCB2` and `FCBF` select indices 1 and 14 respectively;
the ROM address and aliases are explicitly recognized by guest VMM code.
The allocation/dispatch code later in the page contains relocated table
addresses, so the entire 512-byte page excerpt is not claimed identical.

The upstream `C0003400`–`C000353F` code is byte-identical in the two
snapshots (320 bytes, SHA-256
`fbd972d966355685687c72325a7b9424dd8221786115a031b3842f973fba9276`).
It loads the packed callback pointer at `C000347F`, then explicitly swaps
its IP and CS halves into the saved client frame at `C0003507` and
`C0003510`. This explains the packed-pointer operations observed in the
new ring. These immutable references establish the intended callback
design; they do not substitute for new-run ACK evidence of a particular
callback-table entry or prove the later VDD initialization succeeds.

### Sep30 repeatable pre-VDD diagnostic checkpoint

An independent cold diagnostic used the same frozen `b7cfbec7...` binary,
untouched `cc68b005...` source disk and cache-enabled ROMs, with a private
writable guest and version-4 mouse/ATA/RTL checkpoint. It saved at exactly
**350,000,000 cycles / 64,048,077 retirements**, after 309 host disk reads,
then exited zero and was reaped. Wrapper status is `clean_exit_unqualified`,
not desktop success; its service is inactive/dead with MainPID 0.

Bundle: `/tmp/ventium-win95-vdd-checkpoint-sep30/`. Snapshot SHA-256:
`7c2e75d1c7f8cb02e293e3beb2cfbe3cfec86b45e4ffd102abd1e19e49417215`;
paired stopped private-disk SHA-256:
`f09340bae3807c173c852898981316030340c99457218aa9ed277435574ccd3a`.
Read-only inspection using the exact generated serializer checked 12,767
fields / 424,194 root-payload bytes, root checksum `37cbd860d382fbdf`,
empty-package checksum `e3b0c44298fc1c14`, identical repeated 56-byte contexts,
all host-field extents and the final trailer. The binary, serializer inputs,
snapshot and paired disk were unchanged before/after inspection.

CPU: CS `0028`, EIP `C001223B`, EFLAGS `00000212`, CR0 `80000011`,
CR3 `00306000`, SS/DS/ES/FS/GS `0030` with zero bases, state `S_STORE`.
ESP `C13ADE68`, EBP `C13ADF70`, ECX `000000B8`, EBX `C15200E8`.
Backing DDR's BDA pointer `000004A8` resolves through `C000:009F` to
`C000:64D2`, the correct frozen-ROM table. VDD-related backing globals
`C00356C0`, `C0035EA8`, `C0035EAC` are zero, consistent with capture before
hook installation, not the later failing BIOS loop. These DDR observations
are not claimed cache-coherent operands, nor does static checkpoint parsing
qualify restored execution equivalence or identify the VDD cause.

Do not enable the old `--ven-watch-walk-eip` probe blindly: its host observer
hard-codes `state == 40` for an older profile, whereas this candidate's
conditional FSM enumeration has `S_WALK == 41`. A missing walk report would
therefore be instrumentation error, not evidence that no page walk occurred.
Frozen generated C++ independently uses `0x29` for walker tracking
(`Vsystem___024root__24.cpp`, lines 533/539); state 40 is `S_HLTWAIT`.
The pending bounded instruction trace must use compatible observations;
breakpoint/fault-ring restore modes are separately rejected by the harness.
New focused QEMU/RTL launches await explicit approval after auto-review
rejected the RF fault-restart microtest under the older no-new-runs rule.

The frozen ROM provenance is intentionally explicit: `boot1.rom`
(`fb0d673a...`) matches the stock release; cache-enabled `boot0.rom`
(`dca915c5...`) does **not** match stock `e70c8843...`. Its reset trampoline
performs global WBINVD and clears CR0.CD/NW, with the accompanying checksum
change. This is not a VGA/Quake-specific guest workaround, but neither should
it be described as an unmodified stock BIOS. The acceptance commands boot
cold, without `--restore`; snapshot support is an opt-in host diagnostic,
not an execution prerequisite.

Static inspection of the current BIOS loop found no demonstrated register
width defect: `26 8A 07` reads `ES:[BX]` into AL, `43` increments BX16,
and `E2` decrements/tests CX16. These V86 operations use the reference FSM
in the frozen full-PC profile, not the functional-only prefix/MOV shortcut.
The IRQ/IRET engine does not implicitly write EBX/ECX. This does not exclude
incorrect handler software state or an unobserved restart defect; live
caller/register/return evidence is still needed. The old `FLT` print's CR2
is sampled before its nonblocking update, so it describes the previous
fault, not necessarily the operand of the instruction printed beside it.

Win95 desktop and the standard suite remain unqualified. Gameplay IPC
remains **0.45746656** on older `3237b652...`, cycles
1,150,151,638–1,400,151,638; this candidate has no gameplay measurement.
