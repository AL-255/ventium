# FPGA build and hardware-verification guide

This is the operating procedure for the Ventium-swapped `ao486_MiSTer` system on
the RK-XCZU15EG-F board. It covers the current build, deployment, test, and
debug tools as inspected through **2026-08-23**, with the safety preflight
updated through **2026-10-05 UTC**. Historical clocks, binaries and results below are
not certification of the currently installed image.

> **Current status (2026-10-08 21:10 UTC):** UV+fast-pipe remains mandatory.
> The installed **ABI-5** bank64 image is `fe9f539d`, measured **39.9998 MHz**.
> Its original cold Quake run completes **969 frames in 289.1 seconds (3.4 FPS)**,
> with native daemon/capture/watcher exits 0/0/0 and a fresh closed-disk result.
> A post-demo coherent ring proves real fast U/V pairing. The complete sampled,
> raw-color 15 fps movie is available (18.5 MB). No U-only/slow
> fallback, STEP, breakpoint, snapshot or guest-payload patch was used.
> Newer closed write-profile diagnostic: **primary/U IPC is 0.167990963**, across 59
> intervals within cycles **2,648,748,396–5,129,027,099**, with a fresh
> 969-frame / 288.6-second result. This is a different sampled scene window,
> not a fix gain. Total U+V IPC is not
> exposed; this is not a meaningful performance improvement. The generic gate
> and full standard suite remain unclosed. See the
> [deployment, movie, mode witness and closure caveats](docs/UV_FAST_BANK64_2026-10-08.md).
> Historical image `53f129e9` measured 0.165995778 primary/U IPC within cycles
> 8,721,490,845–19,169,282,165; the intervening `1c8f20ac` ECO failed cold Quake.
> The older entries below are historical, not the current deployment status.

Current movie: `/home/yukidama/external/tmp/ventium-bank64-cold-final.eu514F/movie-r4/recording-15fps.mp4`.
Board guest reset is held at the 40 MHz profile; all run workers have exited.
For this cold controller, precreate both the FIFO and `producer.stderr` with
root:riguke ownership/mode 0640. The daemon's `--secs` counts nominal 1 ms loop
iterations **plus polling overhead**, not wall time: use the qualified **600**
budget with the 3,600-second watcher, not equal 3,600/3,600 limits. Require
natural daemon exit before reading its final disk: killing buffered stdio left
the final result sector unflushed in the preceding run. No flush workaround
or guest modification is part of the accepted procedure.

**New candidate (2026-10-08 20:25 UTC):** the
[banked RAM-layout U/V-fast build](docs/UV_FAST_BANK64_2026-10-08.md) has completed
synthesis and implementation at **40 MHz core / 100 MHz PL**. All 226,200
routable nets are connected without routing errors. Final utilization is
186,039 LUTs, 34,763 CLBs (81.49%), 59,380 registers, 221 BRAM tiles and 127 DSPs.
Routed core setup remains negative: **20.399 MHz worst-path estimate**, not
measured frequency or guaranteed domain Fmax. There is no 40 MHz timing sign-off
despite the subsequent diagnostic deployment. The bounded read-only routed-checkpoint audit completed
with unchanged inputs; no critical CDC findings, two retained vendor CDC
warnings, and the same setup violations. The
first bank64 attempt hit its intentional combined-memory guard (not OOM);
recovery retained identical RTL/defines/clocks within the existing 20/8 GiB
RAM/swap ceiling and closed successfully without OOM. Implementation preserved
those inputs and closed in **2:51:36**, without swap or OOM. The candidate
removes the measured eight-page capacity cliff in bounded tests; no gameplay
performance gain or full-system acceptance is claimed. See the newer runtime
status above; this paragraph records physical-build qualification only.

**Debug-tool compatibility (2026-10-08):** the combined source candidate in
[the freeze/retry record](docs/UV_FAST_COMBINED_FREEZE_2026-10-08.md) uses debug
ABI **5**, not the historical ECO observer's ABI **9**. Do not carry over its
owner-scan/filter controller. The base `ven_board_probe.py` refuses unsupported
execution-debug ABIs before writing. ABI 5 does not read back the STEP pulse;
absence of a readable STEP bit is not proof of no stepping. Preserve the
controller commands and verify paired fast-path execution separately.

The probe's `perf` output now says `primary_u_ipc` and
`cycles_per_u_retirement`, with `total_uv_ipc=unavailable` and
`gameplay_qualified=false`. Update console parsers that used the ambiguous old
`ipc`/`cpi` names. JSON retains `counters.retirements` for compatibility and adds
`retirement_counter_kind=primary_U_not_total_UV`. A backwards 64-bit counter
sample is rejected as reset/clear, not interpreted as wraparound. This probe
alone neither qualifies gameplay nor measures total U+V instruction throughput.
Host-only regression: **49 tests pass** across capability refusal, raw counter
labels, capture stop/error handling and UV-fast runtime guards. These are tool
tests, not hardware or CPU acceptance; the live board's old pinned probe has
not been silently replaced.

For a **freshly programmed ABI-5** source image, the base probe now provides
`prepare-cold`. First independently verify the bitstream hash/source profile,
DDR reservation, held reset and actual 40 MHz clock; then run this command as
root before daemon initialization. It refuses an unsupported ABI, released
reset, nonzero retirement count, frozen capture or non-reset CR0 **before any
write**. On admission it requests a manual halt, clears/disables the execution
breakpoint and disarms comparator/threshold freeze triggers. It never releases
reset/execution, clears evidence counters, changes clocks or writes guest RAM.
Start the matching capture and cold-media daemon, then use a separate `run`
command to release the debugger; prove real fast pairing independently.
Do not run `prepare-cold` on an ABI-9 observer image. The command is host-tested
(**51 probe/capture/UV-guard tests total**) and now executed on the new ABI-5
source image. Its successful admission is not CPU or workload acceptance.

The read-only `ven_uv_fast_guard.require_running` now requires an explicit
ABI-5 capability and **readback**, not a previously written command word.
Reserved bits (including the write-only STEP/BP-clear positions) and unknown
ABIs are rejected. A zero word proves only the observed running state; the
returned result explicitly does **not** qualify UV-fast execution or establish
an unstepped history. Preserve the complete controller command record. The
separate paired-ring witness also requires this build's explicit `S_PIPE` enum
value and a coherent capture, never an assumed universal state number.
**54 host tests pass** after these guard changes; no board execution or processor
acceptance is implied.

The source-image clock admission is now available as
`fpga/board-tools/ven_cold_clock.py`, alongside the matching `ven_board_probe.py`.
Run it as root **after programming and before daemon initialization**. It reads
the counter for five seconds while repeatedly requiring ABI 5, held reset,
reset CR0, no forensic freeze and zero primary retirements. It rejects
backwards counters and requires the read-time-bounded frequency range to lie
within **39.5–40.5 MHz**. It never changes a clock/reset/debug register and does
not qualify U/V execution, gameplay IPC or STA. **61 host tests pass** including
the seven new clock-admission tests; the deployed ABI-5 image now passes this
held-reset admission at measured 39.9998 MHz.

An unlaunched ABI-5 cold-run package is prepared under
`/home/yukidama/external/tmp/ventium-abi5-cold-package.ffgy8R`.
It removes the ABI-9 owner-scan/filter operations, uses the current probe and
explicit-capability running guard, and gives the cold daemon a **3,600-second**
envelope rather than the old 600-second diagnostic cutoff. Capture still
starts before release and stops on a complete-record SIGUSR1 boundary.
`prepared.json` pins the ten syntax-checked helper files; it is **not** native
controller or CPU acceptance. The actual bitstream/hash, board run root,
preprogram/postprogram manifests and guarded host FIFO reader must still be
bound before launch. No board upload/programming was performed for this package.

Use the host-side `fpga/board-tools/ven_record_stream.py` for its FIFO reader:

```sh
# Create the root-owned board FIFO and its read permissions first. The host
# output directory must be a fresh, owned leaf under external/tmp.
python3 -B fpga/board-tools/ven_record_stream.py \
  --board-root /dev/shm/ventium-quake-abi5-run.ACTUALTOKEN \
  --output-dir /home/yukidama/external/tmp/ACTUAL_CAPTURE_DIRECTORY
```

It starts the exact non-PTY `/bin/cat -- FIFO` reader that the board launcher
checks, before the producer/guest release. Its **4,500-second total / 650-second
idle** limits replace the old diagnostic reader's 1,500-second cutoff. Raw
RGB332 bytes are retained in a lossless gzip archive without resizing, color
changes or sample dropping; buffering is limited to roughly two frames.
It requires 3 GiB initially and retains a 2 GiB disk reserve, with explicit
raw/quota and 512 MiB compressed-output bounds. Never reuse an output leaf.
Both complete frame records **and a successful reader exit** are required;
early whole-record EOF is transport closure, not proof of timedemo coverage.
The board producer's native exit and closed-disk 969-frame result must still
be verified independently. All **82** capture/debug/clock/transport host tests
pass, including 21 new grammar, resource-limit and native-child lifecycle tests. The 275-frame
historical failed-run prefix validates byte-for-byte with the new parser, but
remains only that old prefix, not current-image or full-movie evidence.

After successful transport closure, stream the recording to a lossless RGB
movie without expanding the gzip archive or retaining all frames in RAM:

```sh
python3 -B fpga/board-tools/ven_encode_recording.py \
  --capture-dir /home/yukidama/external/tmp/ACTUAL_CAPTURE_DIRECTORY \
  --output-dir /home/yukidama/external/tmp/FRESH_MOVIE_DIRECTORY
```

Both directories must already be owned leaves under external/tmp. The output
is `recording-15fps.mp4`: every accepted RGB332 frame, expanded by the original
bit-replication palette, at **320×200 / 15 fps**, with no color manipulation,
resampling or frame dropping. Lossless `libx264rgb` output is decoded back and
its complete RGB byte sequence is hashed against the capture; native metadata
must match dimensions, frame count, cadence and duration. The helper validates
frame CRCs/order, complete gzip closure, raw-stream hash and the reader receipt.
FFmpeg stages are bounded to two codec threads, 512 MiB address space and
600 seconds each; output is limited to 512 MiB with a 2 GiB disk reserve.

`movie.json` deliberately says **`PASS_LOSSLESS_RECORDED_FRAMES_ONLY`**, with
`full_timedemo=false` and `acceptance=false`. A valid movie can depict a failed
guest: separately prove the native producer/guest closures, 969 engine-frame
completion, source clock/mode/identity and full coverage. Do not relabel the
codec receipt as CPU acceptance. **97 host tests pass**, including 15 movie
parser/native-codec tests, an exact-color round trip and a streaming input
larger than the old prefix converter's 32 MiB limit. No new board capture is
implied by those host tests.

> **Latest localization (2026-10-05 UTC):** private memory-OR/JP and
> reversed-memory-CMP/JP controls each pass64 cases on the unchanged40MHz
> image. The original CMP/JP ROM is also caught at actual **00a7:14566 before
> any exception**, FLAGS887/CR2=0; correct JP destination is1457a. The new
> [localization report](docs/FPGA_CMP_BRANCH_LOCALIZATION_2026-10-05.md) records
> exact state, sealed captures, model coverage gaps and the remaining causal
> limits. This is not a production fix or timedemo acceptance. Candidate
> gameplay IPC remains **unmeasured**; pre-candidate baseline **0.42633263**,
> build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> The additional reversed-CMP overflow discriminator also passes64 hardware
> cases, with QEMU/model flags93/93/46/887. The installed **core observation
> ring captures only VGA text stores**, not instruction reads or a live L1
> waveform; its old entries are invalid for these no-VGA-write private ROMs.
> Outer AXI counters also have a different reset epoch from debug counters.
> See the report before interpreting either diagnostic.

> **Single-step localization (2026-10-05 UTC):** a new cold control reuses the
> **identical JP ROM** from the full exception capture below. Existing hardware
> breakpoints park at U=14562, then two host steps execute memory CMP and JP
> separately. Cases1/2 produce CMP FLAGS2/EIP14565 then JP **14567** (PF0/NT).
> Case3 produces FLAGS887/EIP14565 then JP **1457a** (PF1/T). Every step has
> exactly **one** retirement, preserves the expected GPRs/selectors/CRs and
> records a coherent architectural scan with completed-step stop cause.
>
> After those three pairs, RUN restores ordinary **pair-enabled** execution.
> Case4 captures #PF14/error4 at **00a7:14566**, saved FLAGS **46**, CR2
> **493c6488**, ESP/SS **e07f8/af**. PF1 requires JP target1457a. Actual RAM
> independently confirms three completed cases, caller4/checksum **d554**,
> fourth-case memory0/EDI0, original code/caller/logger and mappings. The same
> displaced `ADC ECX,[EBX+3910244c]` bytes again reconstruct CR2 exactly.
> The logger runs normally; HALT/state/aligned16MiB RAM precede late freeze.
> Native closes **0**, controller **1** means the captured diagnostic fault,
> not a reader crash or successful workload. No restart or first-fault trigger.
>
> `audit_step_capture.py` independently passes all **63** sealed files and
> the six exact retirement deltas. Invocation:
> `f7d731be624e463e95a6f87dcaf00160`; capture manifest SHA-256:
> `c929178104a82e58e608477318f9e1d020c6152fcc1418697a18e2e139cb650c`.
> Artifacts: `/home/yukidama/external/tmp/ventium-private-jp-single-step.0lsd9u/`.
> Stepping suppresses pairing and changes warm history. Case4 fails after
> pair-enabled release, but the ring does **not directly expose the V packet
> or prove its retirement**. Combined with JMP64 success, this focuses the
> investigation on memory-CMP/conditional-branch pairing, forwarded flags and
> descriptor/length/next-PC selection; it does not yet establish the RTL cause.
> No RTL, bitstream, clock or production-media modification. Full production
> timedemo/movie remains **pending**. Candidate gameplay IPC **unmeasured**;
> pre-candidate baseline **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**.

> **Conditional-branch discriminator (2026-10-05 UTC):** the unchanged FPGA
> completes all **64** private memory-CMP/JMP cases, both congruent-pointer
> owners and all four memory/EDI/flag schedules. Only JP at14565 becomes
> same-length JMP `eb13`; the synthetic expected-return setup also becomes1.
> The remaining **171** payload bytes, bootstrap, caller and general exception
> logger stay identical. This is not a production Quake patch or acceptance.
> The recovered coherent scan is CS8/EIPf0258, EAX42, ESP6fec, FLAGS46,
> CR080000011/CR2=0/CR37e000 (CR2 is **0**, not a fault address).
> Actual RAM checks software-count64, caller-count64, checksum **d5540**,
> a zero 26-word exception record, exact executable/caller/logger bytes and
> mappings. The late frozen U-ring ends with normal OUTf0256/HLTf0257.
>
> The first controller closes **1**: it incorrectly polls physical113f00
> through the probe's **1 MiB** convenience mapping. Preserve that bounds
> failure; do not restart the guest. The same invocation
> `96404c08cd9d46eeb24372a25c1b4c9c` closes native0. Separately named recovery
> takes HALT/state/full aligned 16 MiB RAM before late forensic freeze.
> Normal-counter completion is verified from recovered RAM, **not observed
> live**. `audit_jmp_capture.py` independently passes all **33** sealed files;
> manifest SHA-256:
> `b4565a90570db97901e331c68d40bc73b9333dfb9095c4f3abb3d16e9a4b05b4`.
> Artifacts: `/home/yukidama/external/tmp/ventium-private-memcmp-jmp.V2edQ6/`.
> For counters above1MiB, map the full reserved guest RAM read-only, use
> naturally aligned u32 reads and validate bounds. Do not enlarge the probe's
> global low-memory window or use short Device-memory slice copies.
>
> Pinned Pentium QEMU completes64 with expected AL42 debug-exit **133**.
> The initial randomized 32-job model matrix has **11 consumer passes**,
> **19 startup SVA stops**, one observer-bound abort and one further consumer
> failure; it is not31/32. A passive phase trace localizes seed2's SVA stop to
> reset clock0: raw rst=0, internal seam reset still random1, error latches
> still random. The frozen model initializes previous input levels during its
> first eval; starting at rst=0 does not create an asynchronous reset edge.
> A separately named harness first settles at clk0/rst1, asserts rst0 and
> retains the original four reset clocks, **never disabling assertions**.
> No generated RTL/model state is forced or recompiled.
>
> That corrected-reset matrix has **28 native0**, four native**124** at their
> 180-second caps, and no SVA stops. The original phase consumer was too strict
> when seam reset already started0: the master clears on the first held reset
> clock, not an absent internal falling edge. A separately named offline R2
> consumer keeps the original grades and checks that exact behavior. Results:
> **25 passes**, **3 architectural passes missing retained-prediction coverage**
> (consumer3), **4 incomplete functional-lat13/gap jobs** (consumer1).
> The complete suite remains **1**; these are not32 correctness passes.
> Sources, native binaries and all179 frozen inputs remain pinned.
> Reset-control artifacts:
> `/home/yukidama/external/tmp/ventium-private-reset-edge.LHADfg/`.
>
> A bounded native Vivado leaf control reproduces all six early implicit/
> redeclaration warnings around the frozen `uv_common` interface. Late and
> early typed connections synthesize to the **same nonconstant LUT5 driver**;
> mismatch is GND. An independent post-synthesis condition-table/shift oracle
> passes **360,464** checks. Native synthesis and post-simulation exits/pins are0.
> Artifacts: `/home/yukidama/external/tmp/ventium-vivado-forward-decl-r3.UMMkDc/`.
> This weakens an inherent declaration-order/scalar-width explanation; it is
> **not full-core netlist or hardware forwarding proof**. The original failed
> path guard and OBUF receipt consumer attempts remain separately preserved.
> No production project was rebuilt or FPGA image/clock/media changed.
>
> JMP success versus the separately captured JP wrong-boundary fault narrows
> attention toward conditional-branch/paired-retirement handling, but altered
> branch/input schedules mean it does not prove a flag-forwarding root cause.
> Single-step intentionally suppresses U/V pairing and may change warm history;
> it is a diagnostic, never a general-processor fix or acceptance workaround.
> Full production timedemo/movie remains **pending**. Candidate gameplay IPC
> is **unmeasured**; pre-candidate baseline **0.42633263**, build **5c2491f3**,
> cycles **7,099,999,637–7,199,999,637**.

> **Full private exception capture (2026-10-05 UTC):** a general private ROM
> logger now records the exception/error frame, original ESP/SS, all integer
> registers, selectors and CR0/CR2/CR3 before any reset. Its 26-word record at
> physical **100** publishes its magic last. Ordinary supervisor interrupt
> gates handle both error-code and no-error-code exceptions; the logger then
> emits OUT F4 and HLT. This stops a diagnostic fault; it does not repair a
> guest, patch production Quake/BIOS, restore a snapshot or disable pairing.
>
> Four pinned Pentium QEMU controls validate CPL0/CPL3 #UD and #PF frames.
> Reference/native exits are **0/1**, with native 1 the expected
> `isa-debug-exit` AL0 result. All 24 bounded frozen-model frame controls match
> the exact decoded reference fields at AXI latencies 0/3/7, paired and
> functional. The eight original-workload controls have seven consumer passes;
> functional latency13 closes native 0 at its 2M-cycle cap after observing the
> terminal boundary, before the required 200K-clock idle window. Its consumer
> remains **1**, not a coverage pass or a demonstrated DUT failure. The complete
> 32-job matrix therefore remains exit **1**. All 179 frozen inputs match.
>
> On the unchanged FPGA, directed CPL3 #UD and #PF records match the pinned
> reference, including seeded registers, selectors, exact FLAGS=2 and both
> privilege-transition stack frames. The first #UD PS reader closes **135 /
> SIGBUS** while copying a 104-byte Device-memory mmap slice. That original
> failure is preserved. Naturally aligned 32-bit reads recover the complete
> record from the **same native invocation**, without restarting the guest.
> The separately named R2 reader uses only aligned dwords, packs bytes in PS
> memory and confirms a stable second read; subsequent #PF/workload controllers
> close 0. Do not use a short mmap-slice memcpy for this Device-memory record.
>
> The original memory-CMP/JP private workload now captures **#PF14 / error4**
> at **00a7:14566**, saved FLAGS **887**, ESP/SS **e07f8/af**,
> CR2 **493c6488**, CR3 **7e000**, CR0 **80000011**. Pre-fault registers are
> EAX=43, ECX=108, EDX=efe6cc, EBX=2c403c, EBP=0, ESI=2, EDI=80000000.
> Actual physical RAM independently checks two completed cases, caller-count
> **3**/checksum **9fff**, third-case inputs, linked payload/caller/logger and
> original mappings (only the logger PTE's accessed bit changes). The complete
> client code and caller remain unchanged relative to the JP parent; logger
> bootstrap/IDT changes mean this is a new cold history, not an identical run.
>
> **14566 is the displacement byte of JP `7a13` at14565.** PF1 requires target
> **1457a**; even correct fallthrough would be **14567**, neither14566. Decoding
> from the captured byte yields `13 8b 4c 24 10 39`,
> `ADC ECX,[EBX+3910244c]`; the actual client descriptor's DS base10000000 plus
> captured EBX2c403c and that displacement equals **CR2=493c6488** exactly.
> This corroborates a mid-instruction memory decode, not merely a suspicious
> fault-PC label. It still does not reveal the actual retained V packet,
> instruction-cache contents or the cause of the wrong boundary.
>
> The late frozen U-ring contains logger OUT/HLT and preceding U=14562. Its
> transition entry CS8/EIP14566 mixes handler CS with fault source; do not grade
> it as successful CPL0 retirement of the ADC. The coherent post-handler scan
> and 16 MiB physical-RAM dump were obtained **before** late forensic freeze
> held SoC reset. No first-fault reset trigger, target BP or STEP intervened.
>
> `check_board_captures.py` independently closes 0 on all three sealed exports:
> manifests, actual RAM/code/mappings/frames, live-to-closed invocation identity
> and production pins. This is evidence integrity, **acceptance=false**.
> Artifacts are in `/home/yukidama/external/tmp/ventium-private-exception-log.8jCJnt/`;
> workload capture manifest SHA-256:
> `867e612c7c9ee4d6e3c496d59d04884ebd96e27a6030551bf23598ded765e3fe`.
> Native workers are closed and the guest is forensically held reset. No RTL,
> Vivado, bitstream, clock or production-media change occurred. Next trace
> retained descriptor/length, frontend read identity and next-PC selection;
> forwarding warnings alone do not establish a scalar-width or timing cause.
> Full production timedemo/movie acceptance remains **pending**. Candidate
> gameplay IPC is **unmeasured**; verified pre-candidate baseline **0.42633263**,
> build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **First-fault capture (2026-10-05 UTC):** the existing hardware
> `dbg_cmp_cfg[22]` trigger is now exercised before releasing a private cold
> control. The fixed profile is **01400000**: threshold `cfg[31:24]=1`,
> fault-freeze enabled, retire comparator/divide trigger disabled. It detects
> the first `start_fault` count; this is not every possible #DB/software-INT
> path. **It also counts ordinary external IRQ delivery through `start_fault`:**
> the October7 cold production control froze on real-mode IRQ0/vector8 at
> C000:082E, not a double fault. Never equate this counter with unexpected
> processor faults. For Quake's page-fault history, the captured DPMI IDT's
> vector14 points to 0018:3AB8; a qualified retired-PC trigger there preserves
> an earlier trail than the DJGPP 4D5DC stub, but early loader page faults must
> still be distinguished from the failing workload. The PS helper refuses to arm unless HALTED at the reset context with
> BP disabled. A host fixture checks its exact writes and rejection guards.
> It writes only CFG at **A0**, not the aliased readback or a range/flush toggle.
> IDENT orders the write; it is not a readable CFG confirmation. A forensic
> match preserves the frame/rings and then holds the guest in **SoC reset**.
>
> Before this run, the same private JP ROM was tried with BP **14577**, without
> naming nominal V **14565**. The BP command closes **2** for its park timeout;
> subsequent HALT also times out, controller **1**, native **0**. Invocation
> `d64eab2b09854b0bb9edff9952842761` is closed, not restarted on observation
> timeout. Its missing BP does not exclude visiting 14577 outside a parkable
> issue boundary. After preserving live RAM/status, a late manual freeze records
> last-retire **00a7:14562 / ESP=e07f8 / FLAGS=887**, fault source **14566**,
> last vector **13**, state **10**, CR0 **80000011**. The actual configured
> enum has 64 states; six-bit state 10 is unambiguously **S_SHUTDOWN**, not an
> assumed optimized-register encoding. Fault PC is `int_src_pc`; this late
> frame does not identify the initial exception. Capture manifest SHA-256:
> `8afa3ed1c1b693da884f8f1be4b564ba6400e2c957f01951c0359e267ea1ce7c`.
>
> The new first-fault control reuses the **identical JP ROM**, original memory
> CMP, caller and mappings. Old evidence is sealed before holding reset,
> disarming and clearing forensic rings for the explicitly new cold run.
> Invocation `32ae5f9a521f4022b32f36328862e3bb` closes native/controller **0/0**;
> its intended diagnostic freeze, not native exit 0, is the result. No target
> BP or instruction step intervenes. The first snapshot is **vector14/#PF**,
> fault source **14577**, state **42/S_INT_GATE**, CR0 **80000011**.
> Last-retire context is **00a7:14562 / ESP=e07f8 / FLAGS=2**; this is not a
> raw V packet or a complete pre-fault architectural scan. Live CR0 after
> freeze is reset **60000010**, not the saved fault context.
>
> Actual 16 MiB physical RAM verifies **one** completed software case,
> caller-count **2**/checksum **6aaa**, second-case memory=1/EDI=0 and the
> original linked payload/caller/PTEs. Correct JP for that case is **NT** to
> **14567**; its encoded taken target is **1457a**, not **14577**. The captured
> fault source is inside original `83 c4 10` at **14576**. Newest primary
> retirement is 14562; no guest IRQ acknowledgment occurred. Last AR **6007c000**
> is a page-table read, not proof of CR2. The earlier uninterrupted JP control
> completed two cases before stalling on caller three, so the failing case is
> **not fixed across invocations**. Neither arithmetic truncation nor a uniform
> condition-bit fault follows from these observations.
>
> `check_capture.py` closes 0 for evidence integrity and reports
> **acceptance=false**. All 25 exported files and nine native inputs are
> pinned; closed-capture manifest SHA-256:
> `9c73436cd46b2b67cc56d1d43cd9b879b1b01ecefca26dbba4e9e6bf45e3c712`.
> Artifacts: `/home/yukidama/external/tmp/ventium-jp-firstfault.oZMhYP/`;
> late-capture audit: `ventium-jp-badpc.dPlbOD/`. CR2/error frame/full pre-fault
> GPRs and actual retained V/cache contents remain unavailable in this frame.
> The general private exception-handler follow-up is recorded above; these
> earlier reset-held snapshots remain preserved. Do not patch production
> Quake or promote these diagnostics to timedemo acceptance.
>
> The native worker is closed and the guest is now forensically frozen/reset.
> No Vivado, RTL, programming or clock change occurred; production input hashes
> still match. Full production timedemo/movie acceptance remains **pending**.
> Candidate gameplay IPC is **unmeasured**; verified pre-candidate baseline
> **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**.

> **Memory-CMP condition controls (2026-10-05 UTC):**
> `ventium-memorycc.8Zlcft` retains the original memory CMP at **14562** and
> changes only production opcode 75 at **14565** to **76/JBE** or **7a/JP**.
> Each retains 171/172 payload bytes, full prelude and congruent caller geometry.
> Synthetic memory/EDI schedules are `1,1,0,0` / `0,0,80000000,0`; exact CMP
> flags are **2,2,887,46**, and both new branches require **NT/NT/T/T**.
> The third expected-return setup is corrected to 1, independently checked in
> linked bytes. Native x86 and pinned Pentium QEMU execute matching flag and
> SETBE/SETP oracles. No production code/media is patched.
>
> Four reused-frozen-model jobs run in parallel within one guarded
> 10 GiB/64-task scope, each capped at 180 s/2M cycles/64K rows. All native and
> consumer exits are **0**; all 179 frozen inputs match before/after. Each paired
> job checks **64 exact memory-CMP/Jcc pairs**, 64 preceding cross-line pairs,
> 126 earlier retained packet snapshots, exact flags/address/data/registered
> joins and **14 warm predicted-T/actual-NT cases per owner**, with no missing
> coverage. These checks do not model the FPGA's actual XPM/CDC/timing.
>
> **JBE on unchanged hardware passes three cases, then fails the fourth:**
> counter=3, caller-count=4/checksum=d554, EAX=EE, and U-ring
> **14562 → 14567**. Thus the third CF1/OF1/ZF0 case reaches its required target,
> but the fourth equality/ZF1 case incorrectly falls through, as JE did.
> Invocation `bc5d2dd76c9f48c6a6d16c8a0eff82a6` closes native/controller **0/0**.
> Sealed 16 MiB RAM, payload/caller/mappings and final halted scan are checked;
> native exit 0 is not a DUT pass. Closed-capture manifest SHA-256:
> `8a5d70521f5fbc21245e034dc771cc9c94c2295752729ce1ae5f83dcb2ed40c4`.
>
> **JP is an incomplete hardware stall, not a software pass/fail verdict:**
> counter=2, caller-count=3/checksum=9fff, stored EDI=80000000; newest primary
> retirement is **14562**, last AXI fetch is guest **840**. HALT times out with
> `exec_ctrl=1`; two later read-only samples confirm HALT requested but not
> acknowledged, freeze clear, no retirement/AR progress while cycles advance.
> The last fetch is consistent with an exception-table path, **not proof of a
> fault vector, branch target, forwarded PF or final architectural state**.
> Invocation `d58118f0adb8403897e6c75f2ffd70e1` closes native **0**, controller
> **1**. It was not restarted on timeout. There is no final architectural scan
> or quiescent ring; a separately named live physical-RAM copy is explicitly
> noncoherent and not a cache snapshot. Partial-capture manifest SHA-256:
> `3c923e404bcffc2944a1917657b46538b3cdfa1f0aa44172285cf8c8af3755e6`.
>
> `check_board_memorycc.py` independently closes 0 for evidence integrity and
> reports **JBE DUT FAIL / JP INCOMPLETE / acceptance=false**. The newest
> historical core-observation entry is not treated as a live FSM-state probe.
> Artifacts are under `/home/yukidama/external/tmp/ventium-memorycc.8Zlcft/`.
> Next capture the private branch's actual fault context with a general guest
> exception logger, validated separately for no-error/error-code exception
> frames before use. Do not patch production Quake, disable pairing or claim
> a uniform flag/condition corruption from these partial observations.
>
> Both board daemons and all four model workers closed; at this capture the JP
> guest remained stalled with HALT pending. The later first-fault control above
> supersedes that live-state description. No Vivado, RTL, programming or clock change occurred.
> Production hashes remain unchanged. Full timedemo/movie acceptance remains
> **pending**. Candidate gameplay IPC is **unmeasured**; verified pre-candidate
> baseline **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**.

> **Warm immediate-CMP hardware control (2026-10-05 UTC):** the new private
> control in `ventium-cpl3-warmcaller-je-imm.HWLFnN` changes only the three CMP
> bytes at **14562**, `397a10 → 83ff00`, relative to the sealed memory-CMP/JE
> parent. JE remains at **14565**; instruction lengths, full prelude, CPL3/
> IF0/IOPL0 policy and one readonly congruent caller page remain in place.
> Relative to production Quake, 168/172 payload bytes are unchanged; this is
> explicitly a private control, not a replacement Quake image.
>
> Native x86 and pinned Pentium QEMU agree on arithmetic flags; the exact RTL
> schedule is **46,46,86,46**, with JE outcomes **T/T/NT/T**. Both frozen-model
> jobs close native/consumer **0/0**. Paired coverage checks all **64 exact U/V
> pairs** and seven warm predicted-T/actual-NT cases for each owner. Immediate
> CMP has no retained memory owner; the borrowed caller helper's legacy
> retained-memory narration is explicitly inapplicable, not new ACK coverage.
>
> The **unchanged FPGA passes all 64 software cases**, caller-count=64,
> checksum=**d5540**, EAX=**42**. Invocation
> `ed6a4bd02bf045318692969a4f98efba` closes native/controller **0/0**. Final
> scan is halted at **0008:f027a / EFLAGS=46**, BP disabled, freeze clear.
> The final U-only ring contains adjacent `14562 → 1457a`, with no separate U
> entry for 14565; that is consistent with the last JE pairing, not a capture
> of all 64 hardware V packets. The independent `check_board_immediate.py`
> audit closes 0, checks the actual 16 MiB RAM, linked payload/caller/mappings,
> counters, same-invocation lifecycle and sealed simulation/capture hashes,
> and reports **PASS_PRIVATE_IMMEDIATE_CONTROL / acceptance=false**.
>
> ROM SHA-256:
> `52ccd12296be98e9559cb525f6a96bb5691cf0a609dc87c6742291610e561285`.
> Closed-capture manifest:
> `6a1e03ffb4592851a53a2ac491628c1b81875bdda1a5464afe66eae8bd48a2fe`.
> This narrows the failing memory-CMP/JE comparison to its memory/retained
> context; it does **not** prove a cache, flag-bus, condition-packet or timing
> cause. The subsequent memory-CMP JBE/JP results are recorded above.
> No RTL, programming or clock change occurred; production hashes match.
> Full Quake timedemo/movie acceptance remains **pending**. Candidate gameplay
> IPC is **unmeasured**; verified pre-candidate baseline **0.42633263**, build
> **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Implemented ZF follow-up (saved routed image, 2026-10-04):** the joint
> four-level inspection in `ventium-fpga40-zf-commit-r4.rdrRvv` closes
> native/post-pin checks **0/0**. It records seven physical roots, **214 LUT/mux
> gates**, 76 sequential leaves, 344 deeper cuts and one unsupported primitive.
> The exact architectural ZF FDRE has CE tied to VCC. Cell inversion parameters
> read empty; the actual netlist pins independently report **D/R/C inversion=0**.
> Empty parameters were not treated as zero. Pin-polarity interpretation follows
> [AMD UG903 case-analysis semantics](https://docs.amd.com/r/2025.1-English/ug903-vivado-using-constraints/Case-Analysis).
>
> The separate R2 consumer closes **0** on this sealed receipt. Under 15 explicit
> nominal retained-CMP/JE bindings, selected ZF equals the arithmetic flag input
> and JE selects that ZF; both mismatch queries are UNSAT. Nonreset integer
> commit and ZF1 commit remain feasible, avoiding a vacuous proof. The other
> three queries—commit/forward disagreement and the two wrong branch
> directions—remain **SAT in the partial model**. With unconstrained deeper
> controls, this is **inconclusive**, not a demonstrated RTL defect or a captured
> hardware witness. Receipt SHA-256:
> `6bf64c69d24ded908283c1406f1994dc2c203ef54dbab69127e36958dc761249`.
>
> The three preceding joint inspections remain native **1**, post-pin **0**:
> `zf-commit.zCcrbx` lost a Vivado object handle through an `expr` conditional;
> `zf-commit-r2.GKmGSl` exceeded the data-net segment cap on the clock network;
> `zf-commit-r3.Ko2v6S` reached its 768-gate cap at depth six. None is a DUT
> verdict. The first R4 consumer also remains exit **1** for an unquoted Tcl
> path expression; the separately pinned R2 consumer corrects only that parser
> issue, without rerunning the native query or modifying its sealed sources.
>
> A subsequent wiring-only query in `ventium-fpga40-state-aliases-r2.GXPpfZ`
> closes **0/0**, recording **83 state FDREs / 51 distinct transition signatures**.
> Equal actual D/CE/R wiring, clock and pin polarity support 12 additional Q
> equalities in three relevant groups **after a common enabled clock edge**.
> The consumer closes 0, but the same three partial-model mismatch queries
> remain SAT. Register names were not used to invent an FSM encoding or live
> value; this is not evidence of actual physical replica divergence. Its initial
> query remains native 1/post-pin 0 after a global constant net exceeded the
> segment cap; R2 instead resolves one top electrical net and its unique driver.
>
> `ventium-fpga40-forward-flag-wires.Mj8QfF` closes **0/0**. Only one synthetic
> `u_uv_common/u_flags_eff1` net survives the bounded name inventory, with five
> checked sinks. **No named `u_flags[6]` connection was recovered**; optimized
> names cannot prove an absent wire or resolve the implicit-declaration warning.
> Next compare a warm paired register/immediate-CMP/JE control with the original
> memory-CMP/JE on the unchanged board, retaining the forwarding dependency.
>
> All artifacts above are under `/home/yukidama/external/tmp/`. One guarded
> Vivado worker at a time, 6 GiB/zero swap; no synthesis, implementation, RTL,
> programming, core release or clock change occurred. Fresh board readback is
> still halted at **00a7:14567 / EFLAGS=46**, newest U=`14562`; all eight
> production hashes match. No vendor worker remains live. Full production
> timedemo/movie acceptance remains **pending**. Candidate gameplay IPC is
> **unmeasured**; verified pre-candidate baseline **0.42633263**, build
> **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **OF/ZF hardware discriminator (2026-10-04 23:25 UTC):** the new private ROM
> keeps the JE diagnostic's 171 original payload bytes plus its one opcode
> mutation unchanged. Its synthetic memory schedule remains `1,1,0,0`; actual
> prelude EDI inputs become `0,0,80000000,0` through palette/index data, not a
> register value that the original prelude would overwrite. Native x86 and
> pinned QEMU `-cpu pentium` independently agree on CMP flags `2,2,887,46`.
> Correct JE outcomes are NT/NT/NT/T; JO would be NT/NT/T/NT.
> ROM SHA-256:
> `a7b7800444a11c7c51ce2502be626b8be10dd05fcfb4201fb97c9a03654d2a23`.
>
> Both bounded frozen-107-model runs close native **0**. The first paired
> consumer exits 1 because it incorrectly requests GPRs from sparse cycle
> trace rows. A separate read-only regrade uses registered-state observer
> joins, without rerunning or changing the sealed inputs/results. Functional
> consumer **0** checks all 64 architectural CMP results. Paired consumer
> **3/MISSING**, not a complete coverage pass: all 64 CMP/JE pairs, seam pairs,
> raw descriptor/ACK joins and 126 prior retained snapshots are correct, but
> neither owner supplies predicted-T/actual-NT coverage with this new schedule.
>
> The unchanged FPGA passes all software checks on the third (OF1/ZF0) input,
> then **fails on the fourth (ZF1)**: counter=3, caller-count=4/checksum=d554,
> EAX=EE, with U-ring `14562 → 14567` instead of the required taken path.
> Uninterrupted invocation `6afb26fa520247038308fabb1015b74b` closes native 0.
> A separately closed boundary control at **14567**, not V's 14565, captures
> CMP flags **2,2,887,46**. Third EDI=80000000/OF1/ZF0 correctly falls through;
> fourth EDI=0/ZF1 incorrectly falls through, newest U retirement 14562.
> The earlier three one-instruction MOV steps perturb scheduling; they do not
> execute the CMP/Jcc under single-step. Control invocation
> `3eaa2190eb224f5ca4d5c470a5a607df` closes native 0.
> The initial setup invocation `ef882dfef6794095bc1882ff8b467e33` is retained
> as **UNRUN**: initialization completed, but no core release occurred before
> its service closed. Later releases/captures use a bounded automatic controller.
>
> This behavior does **not** match universal JE→JO with correctly forwarded OF;
> it still does not reveal actual V metadata/forwarded flags or eliminate
> combined/intermittent metadata faults or physical timing. The follow-up
> joint forwarded-ZF/architectural-ZF audit is recorded above; its deeper
> comparison remains inconclusive. Fix only a demonstrated common-path mismatch,
> preserving pairing;
> do not substitute pairing disablement, guest patches or save-state workarounds.
> No RTL, programming or clock change occurred; production hashes remain
> unchanged. Board is halted at the fourth private JE fallthrough, services
> closed. Full production timedemo/movie acceptance is still **pending**.
>
> Artifacts: `/home/yukidama/external/tmp/ventium-cpl3-warmcaller-je-of.PgXWG7/`.
> `check_board_of.py` exits 0 for evidence integrity while explicitly reporting
> **DUT FAIL**, not correctness acceptance. Candidate gameplay IPC is
> **unmeasured**; verified pre-candidate baseline **0.42633263**, build
> **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Implemented condition-selector audit (2026-10-04):** the actual named
> branch net is under Vivado's rebuilt `u_icache` hierarchy, not the original
> `u_uv_common` boundary searched earlier. Two recursive inspections stopped at
> their 1,024-cell caps; both native exits 1 and post-pin exits 0 are retained.
> An earlier host-path check stopped before opening the DCP. These are inspection
> failures, not DUT failures or passes. The bounded four-level query closes
> native/post-pin checks **0**, recording **26 LUT/mux gates**, six sequential
> leaves and 45 deeper physical cuts from the same pinned routed checkpoint.
>
> Offline Z3 checks of that receipt pass all **six** obligations: under nine
> explicit **nominal, not captured** retained-packet bindings, the selector's
> output is its forwarded flag-data input XOR V's condition bit 0. Thus JE and
> JNE select that input with the expected polarity; the stale architectural ZF
> can differ without replacing it. The 94-variable model preserves shared
> physical inputs and LUT `I0`-least-significant truth-table indexing. It does
> **not** prove the deeper arithmetic input equals the correct CMP ZF, actual
> retained U/V contents, the handshakes/CDC, timing or Quake correctness. Do not
> promote this conditional selector proof into a complete forwarding or
> scalar-truncation verdict. Next isolate upstream flag production versus
> retained condition capture; an OF=1/ZF=0 diagnostic can distinguish a lost
> condition bit 2 (JE/JNE becoming JO/JNO) from a zero/stale-ZF hypothesis.
>
> Artifacts: `/home/yukidama/external/tmp/ventium-fpga40-branch-local.VHONmO/`;
> receipt SHA-256
> `b3e60f998c2ae7731e85f00d080f9b30ae63d18a680d2e78c017d94bb52304f8`;
> `grade_selector.tcl`, `selector-proof.smt2`, `selector-grade.tcllist`.
> No synthesis, implementation, programming or clock change occurred. No
> Vivado worker remains live; the board remains halted on the private JE ROM.
> All eight production-file hashes still match. Full timedemo/movie acceptance
> remains **pending**. Candidate gameplay IPC is **unmeasured**; verified
> pre-candidate baseline **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**.

> **PS readback feasibility correction (2026-10-04):** exact matching kernel
> build artifacts were located at
> `/home/yukidama/external/RK-XCZU15EG-F-Template/build/src/linux`, HEAD
> `7e47ae4ab22ed45a8326203c863f826423978f89`, generated release
> `6.12.0-g7e47ae4ab22e`. Generated headers, `modpost` and full `Module.symvers`
> exist; modules are enabled, MODVERSIONS/module signatures and FPGA-manager
> debugfs are disabled. `zynqmp_pm_fpga_read` is GPL-exported. Missing board-side
> headers therefore do not establish that a matching-host wrapper cannot be
> built. No wrapper was built or loaded and no firmware command was issued.
>
> Generic configuration readback is **not** a proven live-state capture path.
> UltraScale/UltraScale+ CLB capture uses MASK/CTL1 bit 23, not GCAPTURE; associated
> user clocks must be stopped/disabled throughout capture. CPU architectural
> HALT is not proof of that clock contract. Correct decoding also needs the
> matching `.ll` mapping, padding and inverted CLB values.
> [XAPP1230](https://download.amd.com/docnav/documents/XAPP1230.pdf),
> [UG570 CTL1](https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Control-Register-1-11000).
> Reference `xilinx_v2025.1` data readback emits SHUTDOWN/RCRC/RCFG, then
> START/RCRC/DESYNC, without capture enable; failure can bypass START. Register
> readback is narrower and does not issue SHUTDOWN/START. Neither preservation
> of all live state nor compatibility with the deployed PMU firmware is proved.
> [Reference PCAP implementation](https://raw.githubusercontent.com/Xilinx/embeddedsw/xilinx_v2025.1/lib/sw_services/xilfpga/src/interface/zynqmp/xilfpga_pcap.c),
> [UG570 commands](https://docs.amd.com/r/en-US/ug570-ultrascale-configuration/Command-Register-00100).
> The exact kernel manager allocates `S+512+100` bytes and requests `(S+100)/4`
> words, using firmware's returned offset as a word index. Validate status,
> lengths, offset bounds and image-size provenance; its SG write path does not
> set the stored size. Reference PMUFW returns zero for data-read offset, not a
> calculated padding offset. Raw firmware debugfs calls do not supply coherent
> DMA storage or these checks.
> [Exact kernel manager](https://github.com/Xilinx/linux-xlnx/blob/7e47ae4ab22ed45a8326203c863f826423978f89/drivers/fpga/zynqmp-fpga.c),
> [Reference PMUFW](https://raw.githubusercontent.com/Xilinx/embeddedsw/xilinx_v2025.1/lib/sw_apps/zynqmp_pmufw/src/pm_core.c).

> **Read-only implemented-logic audit (2026-10-04):** two bounded queries of
> the saved routed checkpoint closed native/post-query pin checks **0**. Neither
> performed synthesis, implementation, programming or clock changes. The first
> query matched U158/V139 retained cells but its numeric-only name classifier
> accepted none: Vivado preserves struct member names, e.g. `[cc][2]`, instead
> of flat packed-bit indices. This was an inspection limitation, **not evidence
> of removed hardware**. The corrected query captures all **297 FDREs**, each
> physical Q/D pin and immediate D driver, including V's four condition bits,
> conditional-branch control and U's flag-write/shift controls. Frozen hardware
> ties `cycle_mode=1`; ordinary retained-packet capture is not disabled.
>
> The first query also captures 240 address pins on the eight exact Icache
> RAMB36E2s (15 pins per port; bit 15 is not present). All four read slices share
> physical address drivers within each A/B copy. Seven write-address comparisons
> use distinct LUT drivers. A strict physical-identity-only checker exits 1;
> this does **not** establish an address error. The corrected query records only
> those seven pairs' LUT4 truth tables and immediate input identities. Offline
> enumeration proves **7/7 equivalent** for all 16 cut assignments per pair,
> **112 assignments total**. This is relative binary combinational equivalence,
> not absolute address/way correctness, dynamic memory, collision or timing proof.
>
> Native synthesis reports early implicit-wire/redeclaration warnings for the
> flag-forwarding connections, without a corresponding port-width diagnostic.
> The routed `u_uv_common` boundary and named flags nets were flattened; these
> queries therefore **neither prove nor disprove scalar flags truncation**.
> Missing names must not be graded as a correctness pass or a causal bug.
> The raw receipt SHA-256 is
> `ef1869c5fd48aa0b71bf9e43e2cc51614a762c754bcbf99383afd08f0acf0fbb`;
> artifacts/checker: `/home/yukidama/external/tmp/ventium-fpga40-branch-inventory-r2.v9F36d/`,
> `grade_address_cuts.tcl`. The original query/failed identity-only audit remain
> preserved in `ventium-fpga40-branch-inventory.IXhbIg/`.
> No Vivado worker remains live. The FPGA is still halted on the private JE
> diagnostic below; no production-media or RTL change was made. Full timedemo
> and current-candidate movie acceptance remain **pending**. Candidate gameplay
> IPC is **unmeasured**; verified pre-candidate baseline **0.42633263**, build
> **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Opposite-condition diagnostic (2026-10-04 21:18 UTC):** the warm-caller ROM
> was changed at exactly one original payload byte: `14565`, JNE `75` to JE `74`.
> Its other 171 payload bytes, caller, mapping and `1,1,0,0` input schedule remain
> unchanged; test-only expected returns are reversed. This is a synthetic
> diagnostic, **not patched Quake or original-byte acceptance**. ROM SHA-256
> `6ae2e38530d9170b43092d7fd26b6f76db57276a445e0cf5e69e1b4883d9005c`.
> Both bounded, frozen-107-profile simulations (paired latency 3 and functional
> latency 3) closed native/consumer **0**. The paired run checks 64 exact CMP/JE
> pairs, 64 preceding seam pairs, 126 prior retained-packet snapshots and 14
> retained predicted-T/actual-NT witnesses per owner after eight warm-up cases.
>
> The unchanged 40 MHz FPGA **fails** this ROM too. Uninterrupted run invocation
> `7395f5383eee48239ac3cdbaa4ac3172` closes native 0, but guest returns `EAX=EE`;
> invocation 2 follows `14562 → 14567` and fails its expected-return check.
> A separate cold control sets the existing breakpoint at **14567**, not V's
> 14565. First two captures have EFLAGS=2. One STEP after each executes only
> `MOV ECX,[ESP+16]`, then the breakpoint is rearmed. The third capture has
> **EIP=14567/EFLAGS=46 (ZF=1)** with newest primary retirement 14562; JE should
> take 1457a instead. DDR counter=2/caller-count=3/checksum=9fff, exact JE bytes
> and operand zero are preserved. Control invocation
> `c286060fe51b4159877f829c2ecaf5ed` closes native 0. The initial 20-second setup
> invocation was never released from reset and is retained as **UNRUN**, not
> a guest result; later controls wait for the daemon's initialization marker.
>
> Artifacts: `/home/yukidama/external/tmp/ventium-cpl3-recurrent-warmcaller-je.5ngqBz/`;
> `check_board_je.py` audits closed captures and reports **DUT FAIL**. Both JNE
> and JE now contradict committed ZF1 on the third warm invocation. This
> excludes a JNE-only or universal always-taken explanation as sufficient, but
> does not expose raw V metadata or distinguish logic from physical timing.
> Earlier debugger halts/steps perturb scheduling. No RTL, bitstream, clock or
> production-media change was made; the board is halted at the JE fallthrough.
> Full timedemo/movie acceptance remains pending. Candidate gameplay IPC is
> **unmeasured**; verified pre-candidate baseline **0.42633263**, build
> **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **New failing hardware reproducer (2026-10-04):** a narrower private ROM
> adds only one read-only congruent caller page before the unchanged 172-byte
> original prelude. ROM SHA-256
> `639edebb2acc6a9776d6f189d3c37b8d74741669aec5efc5e7a1fc46adac07d9`.
> All three bounded frozen-model simulations (paired latency 0/3, functional
> latency 3) closed native/consumer **0**. Both paired cases contain 64 qualified
> CMP/JNE pairs, 64 preceding cross-line pairs, and 16 retained predicted-T /
> actual-NT witnesses per pointer owner; latency 3 also checks 126 prior retained
> descriptor snapshots. Functional control checks all 128 caller effects.
> The same ROM on unchanged hardware **fails**: native service closes 0 but
> guest software reports `EAX=EE`. Its U-only ring and DDR case counter identify
> invocation 2 (the third invocation), which reaches taken target `1457a`
> instead of the expected NT path and fails the returned-EAX check.
>
> A separately closed cold control uses the existing breakpoint at **1457a**,
> not the V instruction at 14565. The first two target captures show EFLAGS=2.
> After each, exactly one STEP executes target MOV EAX,1, then the target
> breakpoint is rearmed. The third target capture shows **EFLAGS=46 (ZF=1)**,
> with newest primary retirement **14562** and no epilogue executed yet. JNE
> should fall through with this flag state. Capture service invocation
> `86a08052f2a84210b33e7401b9a05807` closes native 0; the existing scanner, ring
> and DDR dump preserve the contradiction. Offline evidence audit exits 0 and
> explicitly labels the **DUT FAIL**, not a correctness pass.
> Artifacts: `/home/yukidama/external/tmp/ventium-cpl3-recurrent-warmcaller.WkLUKW/`;
> checker `check_board_warmtarget.py`. The board is halted at the third target.
> This is synthetic IF0 code with debugger perturbations, not a reproduction
> of natural Quake's mid-instruction 14577 jump. The ring does not expose the
> V packet/cache bytes; DDR does not prove the actual load response. Logic
> versus physical timing remains unresolved. No RTL, bitstream, clock or
> production-media change was made. Full timedemo/movie acceptance is pending.
> Candidate gameplay IPC is **unmeasured**; verified pre-candidate baseline
> **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**.

> **Additional debug evidence (2026-10-04):** the existing halt/register scanner
> and U-retirement ring captured a successful private 64-case cache-conflict
> ROM on the unchanged 40 MHz image: `CS=8/EIP=f02b0/EAX=42`, all expected
> terminal scalars, native service exit 0, no IRQ-count increment. Invocation
> `c9b96d872b774eceb0a842c80e14c658`; ROM SHA-256
> `7ef04f3c3eb0e99760d14f3d535b9a213629ea9ebf9f4d1010c008008b7f76a8`.
> Its original 172-byte Quake prelude is unchanged. Software checks three
> read-only congruent code-page sweeps before each invocation. Frozen paired
> simulations at latency 0/3 finish correctly but grade **MISSING** for retained
> CMP-owner/predicted-T/actual-NT overlap; this is not full coverage or Quake
> acceptance. The first functional control timed out (124); a separately named
> bounded control completed and checked all 2,304 conflict instructions.
> Artifacts: `/home/yukidama/external/tmp/ventium-cpl3-recurrent-icconflict.pxdooO/`.
> Production BIOS/media remain unchanged; the FPGA is halted on this private
> diagnostic, not running Quake. No bitstream or clock change was needed.
>
> Read-only inspection of board kernel `6.12.0-g7e47ae4ab22e` finds
> `CONFIG_FPGA_MGR_DEBUG_FS` **not set** and no FPGA-manager debugfs image file.
> The `zynqmp_fpga` readback parameter exists (`N`), but does not itself expose
> configuration/BRAM data. The separate firmware `pm` debug file is not a safe
> drop-in replacement: the documented driver readback allocates coherent DMA
> storage before requesting firmware data. No firmware command, parameter
> write, kernel change or raw readback was attempted. See the
> [Xilinx 6.12 driver](https://github.com/Xilinx/linux-xlnx/blob/xlnx_rebase_v6.12/drivers/fpga/zynqmp-fpga.c).
> Existing architectural selectors do not expose cache ways or retained U/V
> packets; DDR bytes and a U-only ring cannot prove their contents.
> Candidate gameplay IPC is **unmeasured**; verified pre-candidate baseline
> **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**. Full timedemo/movie acceptance remains pending.

> **Latest status (2026-10-04 19:25 UTC):** the checkpoint continuation closed
> with actual native exit **0**, including native bitstream generation. No
> Vivado worker remains live. The unchanged native BIN was deployed to the RK
> board; its SHA-256 is
> `30b0178eb924eb2914bda6300f7ef3f3bef233b48d821ef77bf452349f8beefb`.
> A held-core counter measurement gives **39.999479 MHz**; it is a physical-clock
> measurement, not guest throughput or timing sign-off. Raw routed timing
> reports remain preserved; this debug phase uses the same image and clock.
> The first cold FreeDOS/Quake run failed with a page fault at `00a7:00014577`.
> A second cold run used the existing **quiescent breakpoint**, not forensic
> freeze, to intercept that EIP before execution. Code, descriptors and page
> mappings in the saved DDR dump are valid; the preceding `CMP` has equal
> operands and architectural **ZF=1**, so its `JNE` should fall through to
> `0x14567`. Instead execution reached `0x14577`, inside `ADD ESP,16`.
> One hardware single-step then reproduced **CR2=0x10000043** and entered the
> CWSDPMI page-fault handler. The control-flow cause remains under investigation;
> correct DDR bytes do not prove correct cache/fetch bytes at issue time.
> A further cold run reproduced the same wrong EIP with different data pointers.
> An unpaired debugger control correctly stepped
> `14562 → 14565 → 14567 → 1456b → 1456e → 14570`.
> Six reduced-profile, frozen-source simulations passed the exact three-byte
> memory-CMP/two-byte-JNE test with both flag outcomes and memory-response delays.
> All **12** full-107-define simulations passed the original and last-word
> variants at AXI latency 0/3. CPL3 tests with Quake-like segment/paging geometry
> passed 64 rounds, and data-cache-conflict stress passed 256 rounds, including
> actual same-clock U/V pairs in cycle traces. The combined I/D-conflict case
> retains its pairing-coverage failure (0/256 pairs), despite correct
> architectural outcomes; it is not an all-pass result.
> The **same 40 MHz FPGA image** completed the original and last-word 16-case
> ROMs, the 64-round CPL3 geometry ROM, and the 256-round D-conflict ROM. The
> latter two ended at the linked kernel HLT boundary with
> `EAX=42, EBP=3, ECX=0, ESI=0`. These private diagnostic ROMs are synthetic,
> not restored Quake snapshots or full-system acceptance. A further ROM preserves
> all 38 original bytes at `14554..14579`, including the `1455d/14560` line
> seam and the first `14562` port-B-to-A transition. Its 13 trained invocations
> passed the FPGA scalar/HLT contract. Both cycle simulations at latency 0/3
> show 40/40 actual pairs; the tiny host TB stops pre-OUT/S_IO and does not itself
> observe OUT/HLT. Original terminal-checker failures are retained separately.
> A rapid real-Quake control also caught `14562 → 14567` with primary delta 1,
> IRQ delta 0 and ZF=1 in about 25 microseconds. This is a post-halt boundary
> witness, not uninterrupted-error recovery or direct V-retirement capture.
> Its operand is word 3; the repeated bad-PC captures use word 7. Mixed FP and
> interrupt context remain separate test axes.
> A bounded board-local derivative (15 host lifecycle tests passed) then selected
> the **second** real Quake CMP encounter, operand offset `0xe7c0fc`, word 7.
> Its single rapid resume reached `14567`, primary delta 1, IRQ-ACK delta 0,
> ZF=1, in about **19 microseconds**. Full per-encounter scans/rings are saved as
> `paired-word7-quake.json`, SHA-256
> `443aeb51c033df1e64fcd9013591e2a652c7a457f1a26c05b46d250e9b19c440`.
> This excludes word-7 position alone as sufficient to reproduce the fault;
> it does not reproduce the uninterrupted failing context (EAX here is 3,
> versus `0xae` in the later repeated failure). The probe exited 0 and confirmed
> final quiescent HALT; the guest daemon was explicitly operator-stopped after
> archiving. This is not native timedemo completion or cold-run acceptance.
> Four interrupt-chain simulations have now closed: each simulator exited 0;
> the control checker passed, while all three IRQ checkers initially failed.
> A read-only audit found three observation assumptions: completed interrupt
> delivery emits a trace record stamped with its saved return PC; the handler's
> frame-witness NOP can retire as V, outside a primary-only observer; and the
> registered retirement appears one clock after the pre-edge final-ACK sample.
> Preserve those initial failures. The retained-owner records nevertheless show
> six pending-IRQ CMP episodes in each A variant completing as actual U/V pairs,
> then interrupting at the correct boundary. All 35 observed IRET snapshots
> restore their saved integer/segment/control state exactly. This synthetic
> fixed-vector evidence does not clear the natural FPGA failure, and the missing
> frame-observer coverage is not a passed frame-capture test.
> The full-chain ROM with a preceding `FDIVP` also passed its 13-invocation
> integer/FP terminal contract on the unchanged FPGA. Its result checks use
> synthetic FCW `0x0c7f` (24-bit precision, truncate), then reset the x87
> environment. Hardware terminal state is not evidence of live FP/INT overlap.
> The latency-0 cycle simulation observed 39 integer commits with FP busy;
> latency 3 observed none and retains its overlap-coverage **failure**, despite
> correct arithmetic and 40/40 integer pairs. Original failed checks and the
> separately named precision-corrected regrades remain preserved.
> Read-only routed-DCP inspections opened the exact checkpoint but exited
> **1**: the first script incorrectly required `RAM_MODE`. RAMB36E2
> derives SDP from width properties; the installed primitive has no such
> required parameter. The second query confirmed A0's correct width orientation
> but stopped at a guard limiting the global clock tree to 128 net segments.
> The third query used local clock metadata but still matched legacy output pin
> names, not RAMB36E2's `DOUTADOUT`/`DOUTBDOUT`, and failed the output-count guard.
> All failures are preserved. The fourth query, aligned to the installed E2
> primitive's full pin declaration, exited **0** on the unchanged routed DCP.
> It establishes eight distinct SDP slices and 512 non-aliased output drivers;
> an independent offline grade confirms all 512 named output connections follow
> the intended A-natural/B-word-reversed swizzle, and all 512 DIN connections
> use the correct replicated 32-bit fill-data bit. All 16 four-byte write-enable
> groups are internally consistent. Only two of eight reversed A/B word-selector
> pairs share identical nets: six distinct LUT cones remain Boolean-unverified,
> not demonstrated failures. No RAM-content dump, implementation, clock change
> or bitstream rebuild occurred. These are structural wiring checks, not cache
> collision/functional-equivalence or Quake acceptance.
> A fifth bounded read-only query exited **0**, but all six selector pairs
> reached its eight-edge fan-in depth limit: **0/6 complete cones, all UNPROVED**.
> Native process success is not Boolean equivalence. No solver verdict follows
> from the truncated records, and no additional CAD run was launched.
> That remained the R5 outcome; a later **separately named R6** read-only query
> cut only at exact immediate physical driver pins, avoiding expansion of the
> common fill-enable cone. Root reviewed its full sources and reran 30 new
> synthetic checks plus 27 inherited checks before the single guarded query.
> R6 exited native **0** and collected all 12 LUT4 roots / 48 inputs using only
> 16 unique cells. Each corresponding A/B root has identical truth table and
> ordered driver pins: the same three `pf_word` Q pins and common fill-enable
> LUT output. The separately executed offline exhaustive grade exited **0**:
> **6/6 pairs equivalent**, each over all 16 independent binary assignments.
> Together with R4's two identical nets, all eight reversed selector pairs now
> have static combinational-equivalence evidence. This is not memory-content,
> collision, timing, full cache functional-equivalence or Quake causal proof.
> No implementation, netlist export, constraint/clock/RTL change or rebuild ran.
> R6 used the exclusive guard: 6 GiB RAM, zero swap, 48 tasks; native peak
> **4381.246 MB**, then scope inactive/dead. Routed DCP hash remained unchanged.
> Receipt is in `/home/yukidama/external/tmp/ventium-fpga40-wefront-r6.WzNL8H/`;
> `native-output/one-hop-frontier.tcllist` SHA-256 is
> `0bfbe376187ed80dece87de8a3d3f2d12f82275ea300e14202229682681fe094`.
> Read-only history analysis uses hidden CS base and the actual saved PD/PTs,
> not the ring's real-mode `lin` field. The two natural failures and the clean
> word-7 capture share their newest 64 primary PCs; repeat failure and success
> share 78, including the same x87 prelude. No x87 instruction appears in their
> last 31 primary entries, but V retirement and in-flight ownership remain
> unobserved. The omitted immediate prelude contains a pointer load followed by
> `ADD ESP,4`; the longer prelude also stores across global word 7/next-line word
> 0. The two exact-byte reproducers now assemble/link successfully as separate
> 65,536-byte private ROMs, with native symbol/payload/PTE checks. They preserve
> either 50 or 134 prelude bytes plus the original 38-byte chain, but use explicit
> synthetic input data and IF=0. All four existing-107-model cycle simulations
> (two ROMs, AXI latency 0/3) now closed native/checker **0**. Each proves the
> actual `14530 U / 14534 V` load/ADD pair and four original CMP/JNE pairs.
> Full-prelude store coverage correlates `144ef → physical 1c7f7c` (value 108)
> and `14500 → 1c7f80` (value 0) with qualified ACK and following registered/DPI
> retirement. Coverage is measured, not inferred from setup or readback.
> Both ROMs also ran on the **same 40 MHz BIN**, direct daemon native exit **0**.
> The existing debugger captured HALTED `CS=8/EIP=f024b`, `EAX=42` and every
> expected terminal integer/control scalar; both offline scalar checks exited 0.
> Native captures/receipts are in
> `/home/yukidama/external/tmp/ventium-cpl3-real-prelude.wPvcvn/`.
> These IF0 single-case results do not recreate the uninterrupted failing
> context, prove hardware V/store-ACK coverage, or clear the Quake failure.
> No additional RTL/bitstream/clock change was made for those controls.
> A new recurrent fixture preserves all **172 original bytes** (134-byte
> prelude plus 38-byte chain), selects both observed indexed-pointer contexts,
> and runs **64 synthetic invocations** with T,T,NT,NT third-branch outcomes
> per owner. Four frozen-107-model runs (paired/functional, AXI latency 0/3)
> closed native/initial-checker **0**. Each paired trace has 64 final-CMP ACKs,
> 64 indexed-pointer-load ACKs and 16 retained predicted-T/actual-NT witnesses
> per owner. A separately named R2 consumer joins each ACK to its actual
> invocation, qualified same-cycle request and next registered/DPI retirement;
> all four closed traces regrade **0** without new simulations. Both paired
> cases also prove 64 preceding cross-line `1455d U / 14560 V` pairs and 64
> semantically decoded original CMP/JNE descriptors. Latency 3 provides 126
> prior retained descriptor/effective-address/pair snapshots and 189 owned
> physical-request checks; latency 0 has no prior active snapshot, so it does
> not independently prove multi-cycle stability. Flag-dependent V `br_taken`
> is excluded from packet-stability comparison. **24** pure-consumer outcomes
> (four positives plus twenty adversarial edits) matched their expected
> pass/missing/wrong statuses; root independently reran them, exit 0. Consumer
> SHA-256 `23fa0ac2ba0c0711ab5d718cce9c475824af2910a8d239af9534c1fbb20e7d70`.
> Raw packets cover owner `14562` only; the seam uses exact retirement/EIP,
> not internal BRAM tag snapshots. These results are not a causal reproduction.
> The same ROM, SHA-256
> `b68b2ed61d93b804c5f9a3fcbb4b3e5b82f162db2358eb613e0e7340f1955aff`,
> also closed native **0** on the unchanged 40 MHz FPGA, invocation
> `4c901d773fde4b1bbd41eba06fdb3ea4`, MainPID 0 / Result success. The existing
> halt/register scanner captured `CS=8/EIP=f025f/EAX=42` and all expected
> terminal integer/control scalars; the offline consumer exited 0. Capture
> SHA-256 is `cf2a157a4b1a37b97e05741da3bc22262a590076e6f089ba86e73911fb2796c9`.
> Artifacts: `/home/yukidama/external/tmp/ventium-cpl3-recurrent-prelude.NGNHgd/`.
> Its original native assembly worker exited **1** only after producing the ROM:
> its byte checker mistakenly compared a 134-byte span to the aggregate
> 172-byte hash. That failure/empty proof remain preserved. A separately named
> R2 checker verified both exact spans and linked symbols, exit 0; no ROM retry
> or byte change was made. The software checks all 64 returns, but hardware
> terminal scans/U-only history do not prove V pairing. Inputs and taken-target
> epilogue are synthetic, IF=0/IOPL=0; simulation stops pre-OUT. This excludes
> the tested recurrence/owner/outcome combination alone as sufficient, not
> natural Quake failure, full timedemo/movie or standard-suite acceptance.
> A subsequent IF1/IOPL0 recurrent fixture retains the same 172 original
> bytes and both pointer contexts, adds a real CPL3 interrupt gate/frame/IRET,
> and requests vector `40` after registered U `1455d`. Four bounded parallel
> simulations reused the unchanged frozen 107-define model: all native exits
> were **0**; both matched no-injection controls (AXI latency 0/3) graded **0**.
> The IRQ latency-3 case graded **0**, with 64 actual INTAs, frame captures and
> exact IRET restorations, 64 qualified final-CMP ACK/U+V pairs, and **63**
> episodes with internal IRQ pending before the final ACK. Both pointer owners
> supplied 16 predicted-taken/actual-not-taken pairs with that conjunction.
> The IRQ latency-0 case graded **3 (coverage missing)**: its architectural
> prefix and 64 interrupts passed, but no earlier pending-before-ACK witness
> existed. The aggregate therefore remains **3**, not a four-case coverage pass.
> Input/model hashes matched before and after; no RTL/model regeneration,
> FPGA programming, clock change, guest snapshot or production-file patch.
> Artifacts: `/home/yukidama/external/tmp/ventium-cpl3-recurrent-irq.IwcC9i/`.
> Consumer SHA-256
> `3487ca1f472eb53f6895136b0943f534db3931a9cef7cd7cdb8395168aa50557`.
> This proves the measured simulated IRQ/cache-response/retirement conjunction,
> not FPGA V visibility or the natural Quake failure. These cases contain no FP
> operations, do not prove asynchronous FP overlap, and do not independently
> qualify every prelude store or the indexed-load's V partner. The FPGA remains
> halted after the IRQ-contaminated after-third control described below; no
> daemon or Vivado worker is running. Full timedemo/movie acceptance is pending.
> A separate closed-file audit (root read and independently reran it, actual 0)
> confirms all 64 interrupt-frame markers are valid **V** retirements and
> reproduces the exact delivery/frame/IRET joins and missing/pass grades. Eleven
> in-memory adversarial edits returned their expected grades. That supplementary
> audit also qualifies **512 U-store receipts per case** (eight original PCs ×
> 64 invocations), including physical address, data, strobes, complete ACK and
> next registered U retirement. This is distinct from the immutable consumer's
> narrower coverage; raw retained store packets and backing-memory coherence
> remain unproven, and indexed-load-V/V-store coverage remains zero. Audit source
> SHA-256 `213f9806a0cf592bdd7e1ffa763ecf851e3d49f084cdb026ab9c74c27f068e3a`;
> receipt `CLOSED_OFFLINE_AUDIT.md` in the same leaf. All 24 original outputs and
> consumer/runner pins stayed unchanged; no additional simulation was needed.
> **Geometry clarification:** the immutable checker field `exact_word7_pairs`
> is a legacy fixture label, not a cache-position assertion. With captured CS
> base `10000000` and 32-byte lines, final CMP `14562` is offset **2 / word 0**
> of line `10014560`, paired with JNE `14565`. The preceding CMP `1455d` is
> offset **29 / word 7** of the previous line and pairs across the seam with
> JNE `14560`. Interpret all above coverage by its explicit PCs; neither checker
> nor original outputs were changed to rename that historical field.
> The saved x87 environment was also checked against each natural-fault DDR
> capture, rather than guessing that FP remained busy. The **first** capture's
> FIP is `117db`, bytes `DF E0` (`FNSTSW AX`), FDP `100939e8`; the **repeat**
> capture's FIP is `117b3`, bytes `DD D8` (`FSTP ST(0)`), FDP `100939e0`.
> Both translate through PDE `7c227` / PTE `110a67`; the complete 64/128-byte
> surrounding contexts are identical between dumps. Frozen-source decoding,
> async-owner admission and shared response paths show these operations drain
> older arithmetic owners and cannot themselves allocate deferred arithmetic
> owners. Consequently this last recorded routine is not a source-supported
> explanation for FP still overlapping the allocator's CMP/JNE. This does not
> prove global absence of later FP: environment pointers can be suppressed,
> stale, restored or corrupt, and HALT drains pending work. No artificial FP
> fixture was launched on that assumption. Root independently rechecked input
> hashes, page translations, actual opcodes and complete contexts, exit 0.
> Report `/home/yukidama/external/tmp/ventium-natural-fp-offline.9rAvfT/report.json`,
> SHA-256 `228692c05b7c9690f6933af066e29a0b5b6966cdf3ebec6ffd834b40c6f45cc7`.
> A further read-only integration audit distinguishes the passing core fixtures
> from the hardware backend. The CPU Icache directly infers BRAM; it does **not**
> instantiate the platform `altsyncram` XPM wrapper. Closed R4 records all eight
> CPU RAMs with `DOA_REG=0/DOB_REG=0`, consistent with the one-edge data/returned
> `{set,way}`/collision pipeline. Both returned ports are searched and collided
> buffers rejected. Predicted B can duplicate A; the comment claiming different
> sets is not an invariant. A relocated-CS prefetch limitation exists: B steering
> uses relative branch targets without CS base for hit-way lookup. This can lose
> prefetch efficiency, but live presence/returned-way gates reject the wrong way;
> no resulting incorrect retirement was demonstrated.
> Platform RAM simulation has a genuine fidelity gap: registered-address plus
> combinational output exposes newly written bytes on collision, while native
> XPM `READ_FIRST` returns old bytes. The ordinary L2 refill schedules a write,
> performs it in `READCACHE_OUT`, then reads/raises ready in `READONE`; stream
> responses use a retained bypass. No examined path exposes that colliding old
> word as acknowledged response. This is not a proven Quake cause.
> The **ao486 platform L2 is enabled** (`rk_ao486_system_pl.v`, `l2_disable=0`),
> independently of core `EN_L2=0`. The hardware then traverses `ven_ddram_axi`,
> a 64-bit async AXI converter (40 MHz to approximately 100 MHz), and a 64→128
> width converter to HP0. Core microfixtures omit those backend crossings. The
> frozen outer DDR adapter still unconditionally discards/reissues its first
> read and ignores `RRESP/BRESP`; its dormant write-barrier comments are not an
> active barrier (`wr_bar` rearms to zero). These are integration/error-handling
> risks, not measured natural-fault causes. Preserve them as verification gaps;
> neither the shim's single-fill flag nor core microfixture passes remove or
> validate that separate adapter workaround. No RTL change or new CAD run was
> made from these audits.
> A bounded source-parity audit also ran only `verilator -E` (four variants,
> each native 0; no elaboration, model build or CAD). It found the deferred
> legacy x87 fault-latch driver at frozen `core.sv:8829..8838` inside the outer
> `ifndef SYNTHESIS` begun at 8592. This is a real source guard defect, but
> **not a demonstrated cause here**: `VEN_FP_SHARED` removes every consumer
> in the deployed profile; both latches have only declaration/driver references
> in 107-define preprocessing and neither appears in its generated model header.
> No active fetch/CMP/JNE/retained-owner semantic exclusion was found in this
> focused audit. `VTM_NO_DPI` removes observation callbacks, not the architectural
> retirement-counter update. Wrapper/XPM, optimized tie values and full-profile
> equivalence are outside this proof. All 179 frozen input hashes stayed equal;
> root independently rechecked the closed outputs. Report:
> `/home/yukidama/external/tmp/ventium-synthesis-guard-audit.H0oe3F/report.json`,
> SHA-256 `f1d18eafd3d2292fc8a3a73f13dccb6c0e6210bd60e56d1bec6cfc213ebb3f1c`.
> Its initial external-path guard failed before invoking the preprocessor;
> the corrected guard verified both literal and resolved external paths. No RTL
> repair or FPGA rebuild was performed on the strength of this inactive defect.
> A subsequent cold, private-disk Quake diagnostic used the existing V-candidate
> breakpoint at `14565`: this suppresses pairing with preceding CMP `14562`,
> parks at the original JNE, steps exactly that instruction and rearms. Its
> bounded window checked **4,096 events** in **113.020 seconds**, all with ZF=1,
> correct next EIP `14567`, primary-retirement delta 1 and IRQ-ACK delta 0 per
> step. The helper checks integer/context/flags invariance; a separate read-only
> audit also passed the saved compact records and event sequencing. Operand
> positions include **1,807 word-7** encounters. **93** events have `EAX=43`;
> event **2,680** matches the first natural failure's `EAX=43, EBX=2c403c,
> EDX=efe6cc, ESP=e07f8, EFLAGS=3246, CR3=7e000`, yet reaches `14567`.
> A full recursive comparison against `bp14577-state.json` (SHA-256
> `c26faaa8f7c8879b765ea2d3883530f77e3ba43b69788a95386ce03fe8a8e0ce`)
> finds **EIP is the only differing exposed architectural field**: every GPR,
> flag/control/debug/table scalar, nested hidden segment and all eight x87
> physical/logical records plus environment match exactly. Both root and an
> independent read-only audit verified this against the actual nested state.
> This does not establish identical cache, in-flight, FP or interrupt timing.
> No `EAX=ae` encounter was reached: native probe exit
> **3 / MISSING**, not an all-pass verdict. Its native guest service subsequently
> reached its wall-time guard (**timeout, signal 15**), not native completion.
> The board remains quiescent HALTED at `00a7:14567`; both services have MainPID 0.
> Probe invocation `917e5dc74b104910963de15cad787bbd` and guest invocation
> `2803d990435d42c68d0ac5fd9c4979aa` are preserved with their actual statuses.
> Artifacts are in
> `/home/yukidama/external/tmp/ventium-jne-pair-suppress.davGkW/`;
> `probe.jsonl` SHA-256 is
> `89d51facd2c4b33f0ae12eef560599ab3865b053cd7c26e5e9c565b88a04f951`.
> **Not acceptance or a production workaround:** halt drains owners, step
> suppresses U/V pairing and defers asynchronous recognition. The U-only ring
> cannot directly prove V admission or retirement. No architecture/DDR patch,
> cache flush, clock change, RTL change or bitstream rebuild was used.
> An independent **after-third-branch** halt control then armed `14567` before
> a private cold guest was released. Unlike the earlier JNE-target breakpoint,
> this target does not suppress pairing of original CMP `14562` with JNE `14565`.
> Sixteen host safety-test methods passed. The first cold stop reached `14567`
> with ZF=1, EAX=3 and newest U=`14562` (source-consistent pair inference, not
> direct V proof). The next target `14570` arrived after **236 primary
> retirements and one IRQ acknowledgement**, not the required clean 2/3-retire
> interval. The helper stopped once at **61.690 seconds**, native exit **3**,
> zero completed rounds / coverage MISSING, and confirmed final manual HALT.
> No retry, stepping, interrupt mask or guest-state patch was applied. Guest
> service invocation `344a2ebfbd6147438895cf79623a37d1` was operator-stopped;
> it is not a native-completion/acceptance receipt. Probe invocation
> `2ae0bae976b54e77aeca1205e746f504` remains closed MainPID 0 / exit 3.
> Host leaf `/home/yukidama/external/tmp/ventium-after-third-control.h1MOTw/`,
> `after-third-probe.jsonl` SHA-256
> `3240d924c80963e9df432d21b27c85c73883378b976590a1d19c961ec6c59336`.
> This demonstrates why uninterrupted IRQ history cannot be inferred from a
> halt-resume boundary. It does not establish that this interrupt caused the
> original invalid-PC failure. No daemon/probe remains live; the core is halted.
> The earlier interrupted VCAP was also decoded read-only: all **3,207** complete
> 320×200 records validate, with **82 distinct CRCs**. Selected original-pixel
> PNGs show real Quake 3D gameplay/HUD, but this is a partial, halt-contaminated
> diagnostic recording, not a completed timedemo or a measured FPS result.
> PNGs/receipt are under the prelude leaf's `diagnostic-frames/`; only the existing
> RGB332 expansion and lossless PNG encoding were used, without color adjustment.
> A separate minimal L1D response-owner fix, **`0f12b20`**, is committed/pushed:
> critical-word data now uses the same address-owner match as its ACK. Its new
> regression passed **27 cases / 11 configurations**; the original source fails
> all 16 retarget cases while passing the hold controls. The existing L1D gate
> passed all **17 configurations**, and `make verify` passed. The production
> collision and a causal connection to Quake remain unproven. This fix is
> **not in the deployed BIN**; no FPGA rebuild or clock change was made.
> A frozen-source producer audit further narrows that result: the unit failure
> changes an unacknowledged primary request B into A. Normal fast DATA loads
> retain B until ACK, consuming and clearing its one-clock early-response pulse
> before A can be captured. Thus background-fill overlap alone does not establish
> this schedule on the inspected production path. Exceptional cancellation and
> other producers are not exhaustively excluded; the cache-interface fix remains
> valid, but is not an established explanation of this Quake failure.
> Host `/tmp` has a per-user tmpfs quota in addition to its global free-space
> limit. A failed, unstarted guard-marker leaf was archived; only the empty
> owned `/tmp/ventium-build-scope` directory was replaced by a symlink to
> `/home/yukidama/external/tmp/ventium-build-scope`. The shared lock and cgroup
> admission limits remain unchanged. Recheck this ephemeral path after reboot;
> do not delete unrelated `/tmp` work or bypass the guard to recover quota.
> Debug artifacts are in
> `/home/yukidama/external/tmp/ventium-fpga40-capture.VMIAgs/`.
> The closed 3,207-frame diagnostic recording includes halted duplicates and
> is **not** a complete timedemo movie. A narrow PS-side capture derivative
> skips malformed non-target boot-mode geometry; 33 host tests passed. This
> changes neither guest pixels nor RTL and is not functional acceptance.
> Candidate standard-suite acceptance and the requested full movie remain
> pending. Candidate gameplay IPC is **unmeasured**; verified pre-candidate
> baseline **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**.

> **Historical status (2026-10-04 02:44 UTC):** the corrected fresh checkpoint
> continuation is live, native session **43591**, worker PID **53971**, under
> `/home/yukidama/external/tmp/ventium-fpga40-dcp-route-top.5ptYzr/`.
> Its actual loader positively verified loaded-module `TOP=rk_ao486_bd_wrapper`,
> exact part `xczu15eg-ffvb1156-2-i`, **40 MHz core / 100 MHz AXI** constraints
> and full placement. Default `route_design` is in Global Iteration 1; the
> worker remains CPU-active. This reuses the preserved physical-opt DCP and
> does not repeat synthesis, optimization or placement. The aborted old project and first
> failed checkpoint-launch directory remain untouched.
> Root and independent host-only regressions both passed **59 cases** after
> separating the native design display name from its module `TOP`. The Tcl
> pin is `7715271b225e62839996deef377bb35a0c2ba8b0c8f07c8280b7d26d2e5a4d0c`;
> these tests are control-flow mocks, not native routing or guest acceptance.
> The sole Vivado family remains bounded to **12 GiB RAM / 2 GiB swap / 48
> tasks**, `memory.high=max`, one worker and an **8-hour safety bound**.
> Observed OOM/limit counters and swap use are zero. All new artifacts are
> under external/tmp. Fresh read-only SSH/root preflight confirmed boot ID
> `2861e4e8-cd4c-48cd-9f44-7f7d8a991ebb`, the full reserved guest aperture with
> no System RAM overlap, and unchanged root-owned cold-launch/capture helper
> hashes. The board is idle on the historical image; no guest was released.
> The root observation is retained under external/tmp in
> `ventium-fpga40-capture.VMIAgs/board-readonly-preflight-024325.json`; it is
> not authority for a changed boot/deployment. Refresh before guest-DDR use.
> Full route, native bit/bin, STA/hold/DRC/CDC/bus-skew
> review, measured physical clocks, timedemo and full movie remain pending.
> Candidate gameplay IPC is unmeasured; verified pre-candidate baseline
> **0.42633263**, build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Historical status (2026-10-04 02:26 UTC):** the first non-project checkpoint
> continuation closed with actual native exit **1**, handle **10721**, under
> `/home/yukidama/external/tmp/ventium-fpga40-dcp-route.AzqGe7/`.
> It is loading the preserved physical-opt DCP, SHA-256
> `1099e8ce07371b9ee1f907077521f3322f562350da942e4468b34fa02e0cea5b`.
> Native output confirms successful restoration of the netlist, timing,
> constraints and physical databases in **32 seconds**. It stopped before
> routing because the initial top check incorrectly treated `current_design`
> `NAME` as the HDL module name. Vivado names this restored design
> `checkpoint_rk_ao486_bd_wrapper_physopt`. The check is being corrected to
> query the loaded design's `TOP`; the part, checkpoint SHA and frozen inputs are
> unchanged. The family has exited and the scope is inactive. Preserve this
> failed launch; do not reuse/reset it. The old interrupted project is untouched;
> no synthesis, optimization or placement was repeated.
> All **179** frozen payload hashes/sizes and the manifest/delta/define pins
> were independently rechecked. Root and independent host-only Tcl regressions
> both passed **59** cases; these are mock control-flow checks, not native
> routing or functional acceptance.
> The exclusive guard admitted one Vivado family with **12 GiB RAM / 2 GiB
> swap / 48 tasks**, `memory.high=max`, one worker and an **8-hour safety
> bound**. All observed memory/OOM event counters are zero. External has about
> **27 GiB** available. New logs, temporary files and outputs use external/tmp.
> A fresh SSH check found the board reachable and idle, FPGA manager operating
> on the historical image; no deployment or new physical-clock result is claimed.
> The target remains **40 MHz core / 100 MHz AXI**. Complete routing,
> native bit/bin closure, report review and the fresh timedemo/movie are pending.
> Candidate gameplay IPC is unmeasured; verified pre-candidate baseline
> **0.42633263**, build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Historical status (2026-10-04 02:13 UTC):** the host session/reboot interrupted
> the native implementation. The old Vivado family is gone and its scope is
> inactive; the controller records `Terminated`, not a successful native closure.
> Its last worker log is incomplete in Global Iteration 2, at 1,010 overlaps.
> No completed route or deployable bitstream is claimed. Preserve the failed
> run; do not reset it or interpret its earlier zero-overlap iteration as success.
> Completed synthesis, placement and physical-optimization checkpoints remain
> under `/var/tmp/ventium-fpga40-srtctrl-native.eMTOMg/`. The physical-opt DCP is
> `output/rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_physopt.dcp`.
> The unchanged candidate targets **40 MHz core / 100 MHz AXI**; deployment,
> fresh hardware-clock measurement and the completed timedemo/movie are pending.
> Cache-only cleanup removed **336 external + 280 root-disk GCC PCH files**,
> freeing **50.2 GiB**. Ordinary source/headers, executables, logs, snapshots,
> media and checkpoints were not deletion targets. These compiler caches can
> be regenerated by rebuilding. External has about **27 GiB** available and
> the root filesystem about **42 GiB** available after cleanup.
> All new temporary work must use `/home/yukidama/external/tmp`, with explicit
> `TMPDIR`, a writable-mount/capacity preflight and the single-Vivado guard.
> Repository symlinks into `external/ventium_run` still back active workspace
> storage; do not delete that entire tree. No replacement Vivado run is live.
> Candidate gameplay IPC remains unmeasured; verified pre-candidate baseline
> **0.42633263**, build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Historical status (2026-10-04 01:16 UTC):** the current control-factored
> candidate's synthesis has actually closed with native exit **0** (handle
> **38563**, observed 22:06:04 UTC), `synth_design` elapsed **1h24m11s**,
> zero errors/critical warnings. Its synthesized use is **185,581 LUTs
> (54.38%) / 58,863 FFs / 221 BRAM tiles / 127 DSPs**, 1,601 fewer LUTs than
> the previous candidate. These are not routed figures. The checkpoint and
> all **179** frozen payload hashes were checked after closure.
> A fresh implementation is now live, native **46772**, under
> `/var/tmp/ventium-fpga40-srtctrl-native.eMTOMg/`: one Vivado family,
> **19 GiB RAM / 8 GiB swap / 48 tasks**, `memory.high=max`,
> **RuntimeOptimized** (Default without the crashing `bram_power_opt` pass),
> one worker and an **8-hour safety bound**, not a completion estimate.
> The actual worker script confirms that directive; `opt_design` completed
> successfully at 22:08 UTC. There was no synthesis rerun or failed-run reset.
> At 22:31 UTC the same worker had reached post-placement timing optimization,
> with zero recorded OOM events and no swap use. The initial physical-synthesis
> estimate is WNS **−22.247 ns**, not final STA or an achieved frequency.
> Placement has now completed successfully in **29m31s**, with **184,716 LUTs /
> 58,947 FFs / 34,457 CLBs (80.77%)**, 221 BRAM tiles and 127 DSPs.
> Compared with the previous placement, LUTs fell by 1,608 but CLBs rose by
> 764. The placer warns of high congestion; reduced LUT count is not proof of
> reduced congestion. Physical optimization completed in **2m47s** and routing
> started on the same worker. At 23:03 UTC it remained active in **Global
> Iteration 1**; the router reports **level-6 (64×64)** global/short and timing
> congestion. No OOM events or swap use have been observed. This is not full
> routing or a new frequency result.
> At 23:48 UTC the same worker remained active after **1h40m48s**. Its logged
> overlapping-node counts have fallen **277,221 → 71,244 → 23,097 → 8,292**,
> still within Global Iteration 1. These are convergence observations, not a
> percent-complete estimate or evidence of a deployable image.
> At 01:16 UTC Global Iteration 1 reached **zero overlaps**, elapsed
> **2h34m50s**, and the same worker began **Global Iteration 2** with 3,032
> reported overlaps. This is not completed routing. Its intermediate timing
> summary is WNS **−31.031 ns / WHS +0.002 ns**; no achieved Fmax is inferred.
> The unchanged constraints target **40 MHz core / 100 MHz AXI**. The scope
> uses approximately **6.70 GB RAM / zero swap**, with zero OOM events.
> A separate host check found **8.94 GB available memory** and zero recent
> memory-pressure averages; low immediately free RAM is not itself an OOM.
> The four Vivado-named PIDs are the expected controller/worker and shell
> wrappers of this one family; no new inspector or build was launched.
> Fresh residual tag-net congestion evidence and the locally proven,
> not-yet-integrated sharing proposal are documented in
> `docs/FPGA_CONGESTION_ANALYSIS_2026-10-03.md`.
> Full routing, bitstream, STA/hold/DRC/CDC/bus-skew review, fresh measured
> clocks and the hardware timedemo/movie remain pending.
> A fresh read-only board check confirmed the guest DDR reservation and the
> pinned daemon, pristine Quake disk, both ROMs, loader and rollback image.
> The FPGA manager reports `operating`; no guest/capture process is running.
> These checks do not qualify the historical image as the new candidate.
> A small candidate-bound source tree for later standard-suite simulation is
> prepared under `/var/tmp/ventium-f-standard-sources.krURBA/candidate/`.
> Seven root host checks plus independent source/mode/107-define dry-run
> checks passed; no simulator model, guest media or old acceptance was copied.
> No heavyweight simulator/compiler has been launched beside Vivado.
> **40 MHz remains the core target, not a new silicon measurement.**
> Candidate gameplay IPC is unmeasured; verified pre-candidate baseline
> **0.42633263**, build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Historical status (2026-10-03 21:43 UTC):** the implementation retry ended
> with actual native exit **124**, observed at **20:08:29 UTC**: its four-hour
> safety timeout expired during Global Iteration 2. Global Iteration 1 reached
> zero overlaps, but routing did not finish. No routed checkpoint, bitstream
> or binary exists; the optimization, placement and physical-optimization
> checkpoints and logs are preserved. That retry's Vivado family has exited;
> this attempt had zero recorded memory/OOM events. Do not deploy it.
> A generic shared-FPU RC/PC control-cone factoring change has passed focused
> verification. Strict FPU lint, the 172-check top regression and all four
> arithmetic-stream modes passed with both bundled and production SRT engines.
> Source-extracted four-state selector tests passed 332,599 base and 332,604
> streaming comparisons; actual whole-FPU old/new tests passed all 12 RC/PC
> combinations (396 checks each in base, stream and stream-forwarding modes)
> with the production divider.
> No registers, operand capture or latency were added;
> live rounding/precision behavior is retained. These tests do not establish
> routed timing or full-system acceptance. A new 179-payload freeze at
> `/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-srtctrl.3M3DsT/` passed
> independent hash/size checks: 178 unchanged, one explicit FPU replacement,
> unchanged 110 defines/full P5 caches. Its candidate qualification is
> deliberately `UNQUALIFIED`, with no inherited model/suite acceptance.
> Fresh synthesis is now live, native handle **38563**, under
> `/var/tmp/ventium-fpga40-srtctrl-native.eMTOMg/`: one Vivado family,
> **19 GiB RAM / 8 GiB swap / 48 tasks**, `memory.high=max`, successful
> reserve-preserving admission. Routing/bitstream and full-system tests remain
> pending; no new deployment is claimed.
> At 21:38 UTC timing optimization finished and technology mapping began.
> The same native handle was freshly polled live at 21:43 UTC. Scope RAM peaked
> at its unchanged 19 GiB cap and swap reached approximately 8 GiB; RAM/swap
> limit events occurred, but all recorded OOM/kill counters remain zero.
> The cap was not raised because the conservative live headroom predicate
> failed. Current memory pressure had subsided; continued monitoring is required.
> No full-PC simulation is currently running. Its historical cold Quake run
> took 17h09m20s, distinct from synthesis and the still-pending placement/routing.
> The candidate-bound movie helpers passed an independent, host-only,
> 512 MiB / 180-second gate (native exit 0, handle 31368). They retain unchanged
> pixels/dimensions and 15 fps presentation, and reject the previous candidate
> or a mismatched delta-to-input-manifest link. These synthetic tests do not
> prove a hardware capture or full timedemo; the single-BRAM drain/rearm gaps
> still require independent whole-timedemo temporal coverage evidence.
> **40 MHz is the target, not a new silicon measurement.** Candidate
> gameplay IPC is unmeasured; verified pre-candidate baseline **0.42633263**,
> build **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Historical status (2026-10-03 19:39 UTC):** the frontend-factored candidate's
> full-chip synthesis completed with native exit **0** (handle **48145**):
> `synth_design` elapsed **1h37m15s**, about **1h38m** for the complete run.
> Its checkpoint is under
> `/var/tmp/ventium-fpga40-icfrontspan-nothrottle.3ZFR9t/output/rk_ao486_system/rk_ao486_system.runs/synth_1/`
> (`rk_ao486_bd_wrapper.dcp`, SHA-256
> `d922c518b1299faaeea812d64caeb6d8b5cd2893b670a22a9b623d06c0ddf0c1`).
> Synthesized utilization is **187,182 CLB LUTs (54.85%)**, down **16.94%** from
> the prior full-chip synthesis; **58,867 FFs**, **221 BRAM tiles**, **127 DSPs**,
> **18,912 MUXF7** and **7,471 MUXF8**. These are not routed sign-off figures.
>
> The separate read-only inspection closed with native exit **0** (handle
> **59007**) and confirmed synthesis **100% / Complete / not stale**, with
> **40 MHz core / 100 MHz PS-AXI** constraints. Its reports are under
> `/var/tmp/ventium-icfrontspan-synth-inspection.I1YvlZ/reports/`.
> Pre-route timing still fails (**WNS −22.317 ns / WHS −0.108 ns**); no
> routed Fmax or physical clock measurement is inferred from these estimates.
> After the inspector's family exited, a single existing-project implementation
> launched at **15:57:46 UTC**, native **67512**, through the exclusive guard:
> **20 GiB RAM / 8 GiB swap / 48 tasks**, one worker, `memory.high=max`.
> It reuses the completed synthesis, frozen 179 payloads, exact 110 defines,
> full P5 caches and unchanged 40/100 MHz profile. Its controller log is under
> `/var/tmp/ventium-icfrontspan-implementation.d26ux9/`. This run stopped at
> **16:01:27 UTC**, native exit **1**: the worker segfaulted in
> `libxv_pwropt.so` cleanup after a fan-in/fan-out-limit exception during the
> default `opt_design` power-optimization pass. Placement never began; the
> completed synthesis remains intact. Failed `impl_1` logs and crash stack are
> preserved, not reset. The installed 2025.2 help documents `RuntimeOptimized`
> as default optimization without `bram_power_opt`; older `NoBramPowerOpt`
> documentation is not applicable. A separately named **`impl_nobram_power`**
> retry launched at **16:08:38 UTC**, native **79488**, after independent static
> review and fresh admission through the same single-Vivado guard. Its script
> clones and checks all original step arguments, enable flags and hooks, then
> changes only `opt_design` to `RuntimeOptimized`. The actual generated script
> confirms that directive, `AltSpreadLogic_high` placement, default physical
> optimization/routing, with `general.maxThreads=1` and `-jobs 1` configured.
> The retry has passed optimization and placement. `place_design` completed
> successfully in **24m03s**, with **186,324 LUTs (54.60%) / 33,693 CLBs
> (78.98%)**, **58,963 FFs**, **221 BRAM tiles** and **127 DSPs**. The placer
> still warns of high congestion and estimates WNS **−19.167 ns**; these are
> not routed sign-off/Fmax results. The placed checkpoint is preserved.
> Pre-route physical optimization completed successfully in **28m06s**,
> with no errors/critical warnings and estimated WNS **−18.626 ns**.
> Its preserved checkpoint is **75,298,446 bytes**, SHA
> `6c1baf744db1bf4cb9a1af47981b7a9dcfbd92ab826294b29cc7f91258d3903e`.
> The same CPU-active worker is in rip-up/reroute, **Global Iteration 1**, with
> intermediate overlap counts falling **286,033 → 75,853 → 25,087 → 9,137
> → 4,228 → 2,348 → 1,537 → 1,108 → 825 → 587 → 397 → 299 → 270
> → 212 → 166 → 134 → 89 → 63 → 51**,
> global/short congestion **level 6**, and timing congestion
> **level 7**. This is not a completed or terminal
> routing result. It has no swap or memory/OOM
> events. The latest count was observed at **19:37:32 UTC**; at **19:39:02 UTC**
> the same worker had **3h30m19s** actual CPU time. Full routing, bitstream and
> final frequency qualification remain
> pending; do not launch an inspector while this family is live.
> A fresh root hash check and independent provenance audit found **179/179**
> frozen payloads unchanged and **no drift in all 164 mapped RTL sources**.
> Only the documented current launcher/runtime-probe differences remain;
> source hashes alone do not prove native input consumption or artifact validity.
> Six host-only Tcl launcher tests subsequently passed; they test
> control flow, not native implementation semantics. Physical QoR may differ;
> this is a supported crash-avoidance experiment, not a routing/timing pass.
> Logs/helpers are under `/var/tmp/ventium-icfrontspan-nobram-retry.cvKzwq/`.
> The 20 GiB RAM / 8 GiB swap / 48-task guard remains active; do not overlap
> an inspector or another Vivado family. There is no new bitstream,
> deployed candidate, hardware timedemo or movie. The current candidate's full
> standard suite is pending and gameplay IPC is unmeasured. Verified
> pre-candidate simulation gameplay baseline: **0.42633263**, build
> **5c2491f3**, cycles **7,099,999,637–7,199,999,637**.

> **Historical retry record (2026-10-03 14:32 UTC):** the congestion retries did not
> produce a new bitstream. The board is reachable and idle, still holding the
> historical image. A source-level frontend factoring candidate has passed
> focused byte-span tests, strict hardware-profile lint, and default/BRAM
> differential gates. Its isolated OOC frontend uses 88.05% fewer LUTs; that is
> not yet a whole-chip gain or timing result. Fresh 40 MHz synthesis-only work
> retains frozen sources under `/var/tmp/ventium-fpga40-icfrontspan.yqNVao/`, with unchanged
> full P5 caches and 110 hardware defines. Full-system acceptance is pending;
> the frontend change/tests are committed as `659b4c0`. A separately
> committed synthesis-only segment-extent driver repair is `f24909e`. Do not
> deploy the failed-route checkpoints or interpret their timing as Fmax. See
> `docs/FPGA_QUAKE_DEPLOYMENT_2026-10-02.md` for the retained evidence.
> A root-owned scalar helper has now cleared all reserved 256 MiB of guest DDR
> in 4,096 ordered 64 KiB chunks (14.839 seconds, actual exit 0), with the core
> held throughout and two zero boundary readbacks. Guest disks were untouched.
> This does not qualify full-byte readback, the daemon's single-map clear,
> cold startup or the timedemo. The first frontend-factored synthesis was
> **OOM-killed at 12:50:43 UTC** during technology mapping: the kernel records
> `CONSTRAINT_MEMCG`, 20 GiB RAM and 2 GiB swap at their limits. Its runner
> closed with native exit **143**; no synthesis DCP or bitstream was produced.
> The next unchanged-source attempt, native **32041** under
> `/var/tmp/ventium-fpga40-icfrontspan-memretry.Gdis4N/`, also stopped: at
> **13:56:52 UTC**, **systemd-oomd killed its 17-process family**, with native
> exit **137**, a 16.6 GiB RAM peak and 8 GiB swap peak. This was a userspace
> pressure-policy kill, distinct from the first run's kernel hard-cap OOM.
> Its finite 90% `MemoryHigh` coincided with sustained reclaim/PSI; that is
> not proof that this was the sole cause. No DCP or bitstream was produced.
> A controlled unchanged-source retry launched at **14:11:30 UTC**, native
> **48145**, under `/var/tmp/ventium-fpga40-icfrontspan-nothrottle.3ZFR9t/`.
> Guard commit **`830c1a9`** removes the automatic soft throttle, while keeping
> hard **18 GiB RAM initially / 8 GiB swap / 48 tasks** and the same host
> admission reserves. Actual cgroup `memory.high=max`, one Vivado family,
> one synthesis worker and exact 110 XPR/generated-Tcl defines were checked.
> **20 host-only guard tests** pass; these do not guarantee a completed build.
> Neither system OOM policy nor source/clock/cache settings were changed.
> At **14:32:04 UTC**, this same live scope's RAM cap was raised **18 → 20 GiB**
> within the reviewed ceiling, after checking full remaining live capacity
> plus the 2 GiB host reserve. Swap/task caps and `memory.high=max` stayed
> unchanged. The original launch environment still requests 18 GiB: do not
> invoke nested guards/inspectors until the existing family has closed.
> No new bit exists.
> Stopped-attempt caches were separately archived and verified before removing
> 622 exact `.rtd`/`.tim` files, reclaiming approximately **2.69 GiB** net.
> The live build, logs, guest media, other cache files and all 179 source
> payloads were preserved. The recovery archive is under
> `/var/tmp/ventium-oomd-synth-cache-cleanup.nbwlSY/`; the dated deployment log
> records hashes and actual checks.
> The movie bundle was separately re-pinned for this candidate under
> `/var/tmp/ventium-fpga-quake-oct02.rc0wVn/icfrontspan-movie-bundle.UKUNF0/`.
> Its bounded synthetic host gate exited **0**, including rejection of the
> actual previous candidate's manifest. The original `runtime-movie-bundle`
> still binds the previous source snapshot and must not certify this candidate.
> These are helper tests, not an FPGA recording or timedemo pass. At the maximum
> 32,768 records, raw 320×200 RGB332 capture occupies 1.954 GiB; the same-filesystem
> raw/normalized/movie workflow requires at least **6.908 GiB**, including
> the 2 GiB movie allowance and 1 GiB free reserve. Recheck after implementation;
> the output-size cap is not a guarantee every full-quota stream will compress.
> Verified simulation gameplay IPC baseline is **0.42633263**, build
> **5c2491f3**, cycles **7,099,999,637–7,199,999,637**; this predates the
> current candidate, whose gameplay IPC is unmeasured.

> **Historical build status (2026-10-03 04:40 UTC):** replacement synthesis has
> closed with native exit **0** (2h26m), and the separate read-only checkpoint
> inspection also exited **0**. Preliminary area is **66.04% LUT / 29.70%
> BRAM**. Clock constraints are **40 MHz core / 100 MHz PS-AXI**, but pre-route
> timing is not a pass: WNS **−23.863 ns**, WHS **−0.108 ns**, including a
> 195-level EIP-to-FPU-SRT cone with substantial unplaced-route delay.
> The original placement completed in **29m10s**, with **65.73% LUT / 89.11%
> CLB occupancy**. Vivado warns that the design is highly congested; its
> post-placement WNS estimate is **−22.180 ns**, not a routed timing pass.
> Pre-route physical optimization also completed successfully in **17m42s**;
> routing subsequently **failed** with `Route 35-3` / `Route 35-4445`.
> The runner closed with native exit **1**, observed at **01:37:35 UTC**;
> no new bitstream exists. This was **congestion, not OOM**: retained build
> resource events are zero, with no build swap. Regional routing demand
> reaches **158.487% north / 135.603% south**, and the failed live router
> has **1,153,331 node overlaps**. Zero DRC errors do not prove routing.
> A separate error-checkpoint diagnostic closed with native exit **0**,
> but reports **242,219 unrouted nets**; its timing is not routed sign-off.
> Preserve the failed run and reuse completed synthesis for a separate
> congestion-focused implementation retry; do not force bitstream output.
> The corrected new run **`impl_area_cong2`** launched at **02:00:14 UTC**
> reusing `synth_1` with `ExploreArea` optimization and
> `AlternateCLBRouting`. High-spread placement/default pre-route physical
> optimization were retained controls; RTL/defines/full P5 caches are unchanged.
> Retry placement completed in **30m52s**: **218,494 LUTs (64.02%)** and
> **37,885 CLBs (88.81%)**, reductions of only **2.60% / 0.34%** versus
> the original placed report. High-congestion warnings persist, with larger
> north/south estimated regions; placed WNS is **−24.487 ns**. Pre-route
> physical optimization completed in **1h04m50s**, with zero errors/critical
> warnings and WNS **−23.574 ns**. Alternate routing also failed with global
> congestion level 6 and **1,125,751 node overlaps**; native session 8229 closed
> with actual exit **1** at **04:00:40 UTC**. There is no new bitstream or
> 40 MHz timing pass. A fresh **`impl_area_medium`** launched at **04:04:20 UTC**,
> changing only high to medium placement spreading after renewed source,
> synthesis-DCP and actual 110-define XPR checks. It is live under the exclusive
> guard, retaining the other directives, 40/100 MHz clocks and one-worker limits.
> Medium placement completed successfully in **27m45s**, with zero errors:
> **218,526 LUTs (64.03%) / 37,513 CLBs (87.93%)**. This saves 372 occupied
> CLBs (0.98%) versus high spreading, but F7/F8 mux counts remain unchanged
> and the high-congestion warning persists. Standalone pre-route physical
> optimization is now live; there is still no routed frequency qualification.
> A tiny same-part native probe accepted the router directive (exit 0), but
> does not prove this full design will route. The retry retains one CPU job,
> 20 GiB hard / 19 GiB soft RAM and 2 GiB swap, with a phase-local 64-task
> cushion; its four-hour guard is not a finish-time prediction.
> At 00:32 UTC the original run's task cap was extended **48 → 64** after observing
> 45 occupied slots (mostly sleeping vendor threads); the future launch guard
> remains fixed at 48. RAM, swap, job count and source were unchanged. The
> previous mapping-only 8 GiB swap exception ended at closure.
> Preserve actual routed timing/CDC evidence and add `report_bus_skew` before
> sign-off; no timing waiver or blind latency-changing DSP pipeline fix was
> added. The earlier inspection helper passed 120 host-only stub checks; the
> new run-bound copy additionally requests both-corner `min_max` bus skew and
> has not run natively. Real post-route inspection is still required, only after
> implementation closes. Logs/receipts are in the dated deployment document. No new bitstream,
> silicon clock, cold startup, timedemo or movie is accepted yet. Verified
> simulation gameplay IPC is **0.42633263**, build **5c2491f3**, cycles
> **7,099,999,637–7,199,999,637**; it predates the unmeasured FPGA candidate.

> **Deployment update (2026-10-02 19:41 UTC):** administrative authentication
> is resolved. The board rebooted with a minimal boot-DT change reserving
> **`[0x60000000, 0x70000000)` (256 MiB)** as non-reusable `no-map` memory.
> Root verified the effective DT, non-overlapping `/proc/iomem`, and boot log;
> CMA now occupies a separate interval. The original DT is retained as
> `/boot/firmware/system.pre-ventium-oct02.dtb`. The recovered August 29
> capture image (`279bc2c0…895064fd`) is programmed, manager state is
> `operating`, and IDENT is `a0486501`. It is a historical 3.125 MHz image,
> **not** the current simulation build. Cold startup presently fails with
> ARM-side `SIGBUS` during guest-RAM clearing, before core release. No FPGA
> timedemo or movie is accepted yet. Do not remove the reservation to bypass
> this mapping/access failure; use the image-matched tools described in
> `docs/FPGA_QUAKE_DEPLOYMENT_2026-10-02.md`.

> **Fresh-build update (2026-10-02 20:35 UTC):** the user requested a current
> **40 MHz** image. Synthesis is now running from a frozen source snapshot,
> using the verified 5c simulator's exact 107 defines plus three hardware-only
> defines, not the legacy FPGA defaults. `VEN_FPGA_CORE_MHZ=40` selects a real
> 100 MHz × 10 / 25 MMCM clock (1 GHz VCO). PIT/RTC/VGA and keyboard transport
> timing follow the physical clock. Use the documented preset-free PCAP flow
> on the already-booted board, retain native 128-bit HP0, and invoke only
> `fpga/run_vivado_exclusive.sh`. During timing optimization the same run's
> whole-family budget was extended after host-headroom checks. After Chrome
> exited, measured headroom allowed 18 GiB hard / 17 GiB soft memory, retaining
> 2 GiB swap and 32 tasks. Synthesis recovered to about one productive CPU
> core with no OOM; no route or new bitstream is complete. The Device-safe daemon
> successor is staged and passes control-only IDENT, not cold startup yet.
> Build/deployment acceptance is still pending;
> see the dated deployment document for frozen hashes and exact status.
> The current MMCM clock is named `mmcm_clk`; the tested implementation-resume
> reporter handles that name. Set `VEN_FPGA_CORE_MHZ=40` for this checkpoint
> and reuse completed synthesis rather than recreating the project.
> Verified simulation gameplay IPC is 0.42633263 on 5c2491f3, clocks
> 7,099,999,637–7,199,999,637; this is not a measurement of the new FPGA image.

> **Build recovery (2026-10-02 21:59 UTC):** the original synthesis helper
> deadlocked during partial board-catalog thread-pool initialization after
> reaching its 32-TID cgroup limit. Root diagnosed it with bounded read-only
> debugger attachments, then stopped that family (native exit 143, scope and
> all recorded PIDs gone). The corrected host guard fixes **TasksMax=48**,
> still one synthesis job and `general.maxThreads=1`; twelve host-only guard
> tests pass. A new run uses unchanged frozen RTL/110 defines/40 MHz MMCM,
> **18 GiB hard / 17 GiB soft / 2 GiB swap**, with output under
> `/var/tmp/ventium-fpga-quake-oct02.rc0wVn/fpga40-task48-retry.5ZayIg/`.
> Use that owned directory as the Vivado **working directory**, not only
> TMPDIR/output: the repository `.Xil` symlink points at the full external
> volume. Do not edit a running shell launcher's source. Synthesis completion,
> routed timing, deployment and cold timedemo/movie acceptance remain pending.
> Verified simulation IPC remains 0.42633263 on 5c2491f3, clocks
> 7,099,999,637–7,199,999,637; it predates this unmeasured FPGA candidate.

> **Live-resource update (2026-10-02 22:13:50 UTC):** after a fresh host
> available-memory check above 5 GiB, root changed only the live cgroup to
> **19 GiB `MemoryHigh` / 20 GiB `MemoryMax` / 2 GiB `MemorySwapMax` / 48
> `TasksMax`**. The launch environment remains
> `VENTIUM_VIVADO_MEMORY_MAX=18G`. `memory.events.high` is 16; all OOM counters
> remain zero. This is neither synthesis completion nor timing, fit, deployment,
> or hardware-performance qualification. Verified simulation gameplay IPC remains
> 0.42633263 on frozen 5c2491f3, clocks 7,099,999,637–7,199,999,637; it predates
> the unmeasured FPGA candidate.

> **Mapping-resource update (2026-10-02 23:25 UTC):** timing optimization
> finished and technology mapping is actively progressing on the same run.
> Its temporary parent/helper working set filled the swap allowance. Root
> extended only the live scope swap from 2 to 4, then **8 GiB**, keeping
> **19 GiB soft / 20 GiB hard RAM / 48 tasks**. No source, running launcher or
> launch environment changed; the future guard remains at 2 GiB swap. No OOM,
> max or task-limit event was observed. The dated deployment document records
> exact readbacks and the resource receipt. Synthesis, routing and hardware
> acceptance are still pending. Verified gameplay IPC remains 0.42633263 on
> simulation build 5c2491f3, cycles 7,099,999,637–7,199,999,637; it predates
> the unmeasured FPGA candidate.

> **Board availability recheck (2026-10-02 22:02/22:07 UTC):** the retained
> key-only, read-only receipt records manager `operating`, the same boot ID, and
> 374 MiB free on the shared root/tmp filesystem; staged daemon, probe, and cold
> disk hashes match the dated deployment record. Root's separate 22:07 recheck
> confirmed the reserved interval in root IOMEM, with no guest running. At
> 22:19 root additionally verified the live DT node's exact base/size and
> `no-map` property, unchanged boot ID, and non-overlapping IOMEM interval.
> This does not identify a new bitstream or qualify
> a clock, cold startup, Quake, Win95, or FPGA IPC.

The short version is:

1. Record the exact source state.
2. Pass the relevant simulation gates.
3. Build the AArch64 board daemon.
4. Validate the Vivado block design, then build the full bitstream.
5. Sign off timing, DRC, and utilization from the final reports.
6. Hash the artifacts, preflight the board, and program the PL through Linux.
7. Prove the control path with `IDENT`, then test POST, disk boot, Quake, and
   Win95 in that order.
8. Keep logs and hashes. `fpga state: operating` alone is not proof that the
   intended bitstream is running.

> **Historical result (2026-08-23):** the superseding L1 request-ownership
> image passes the reset-state IRQ/IRET ROM twice, boots production BIOS and
> FreeDOS, and reaches CWSDPMI. The source-repaired
> `fpga_run_20260823_lds2` image also executes beyond the old protected-mode
> `66 67 C5 75 10` LDS blocker and enters Quake code. Quake still fails later:
> direct capture shows vector 14 after deterministic stack corruption, and a
> final clean 600-second run produced no exact 969-frame result. See
> `fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md` and
> `fpga_verify_20260822/quake_lds_repaired/README.md` for evidence and proposed
> fixes.

The same `l1bypown` image cleanly passed the established headless Win95
VMM/System-VM desktop signature on 2026-08-23 with reset-state CR0 and no input,
flush, freeze, or guest patch. See
`fpga_verify_20260822/win95_l1bypown/README.md`.

## 1. Scope and sources of truth

Use these paths on the current development host:

```bash
VENTIUM=/home/yukidama/github/ventium
FLOW=/home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system
TEMPLATE=/home/yukidama/external/RK-XCZU15EG-F-Template
BOARD=riguke@10.0.0.214
SSH_CONFIG=/dev/null
```

The repositories have distinct roles:

| Location | Role | Authority |
|---|---|---|
| `$VENTIUM` | Ventium RTL, ao486 file lists, simulation gates, BIOS ROMs | Functional RTL and verification |
| `$FLOW` | RK board top, PL/PS bridges, Vivado project generator, daemon, deploy helpers | Actual FPGA integration |
| `$TEMPLATE` | Board PS preset, Linux/FPGA-manager flow, complete BSP and SD-image build | Board and Linux reference |
| `$VENTIUM/ao486-sim/DISK_BOOT_STATUS.md` | Append-only bring-up and forensic record | Historical evidence, not an operating procedure |

The board reference is the local checkout of
[AL-255/RK-XCZU15EG-F-Template](https://github.com/AL-255/RK-XCZU15EG-F-Template).

Important reproducibility limitation: `$FLOW` is currently an **untracked
directory** in the separate `/home/yukidama/github/ao486_MiSTer` checkout. At
the time of inspection:

```text
Ventium HEAD                 4a643c164e80 (with a dirty working tree)
standalone ao486_MiSTer HEAD ddadd507564d
RK template HEAD             08b0b171d77b
flow status                  ?? fpga/rk-ao486-system/
```

A clean clone therefore does not reproduce the hardware flow. Before treating
this as a release-quality flow, commit or otherwise archive `$FLOW`, including
its source, constraints, software, and scripts. Do not archive generated
`build/`, Vivado journals, binaries, or disk images.

The flow's own `README.md` is historical and is not authoritative for current
commands or results. It describes old first-fetch blockers and a nonexistent
`scripts/build.sh`. The source now implements a `/32`, approximately 3 MHz core
clock; an older 2026-08-01 artifact ran at 5.966 MHz and is only a comparison
baseline. The latest source-matched hardware outcomes are stricter than the
historical forensic log. The timing-valid non-fast control image reached the
established Win95 VMM/System-VM desktop signature on 2026-08-21. The first
repaired-fast `irqfix` image still corrupted real-mode BIOS control flow after
the valid VGA option-ROM return. The superseding `l1bypown` image fixes that
request-A versus request-B ownership defect and boots FreeDOS. The later `lds2`
image repairs the protected far-pointer decode/atomic-commit gap and crosses its
exact silicon discriminator, but Quake then exposes the page-fault/stack-
corruption path described in the stop condition. No current image has completed
the exact 969-frame timedemo; never convert startup/progress into a pass.

## 2. Hardware architecture

The design targets `xczu15eg-ffvb1156-2-i` and uses the running Linux system on
the Zynq UltraScale+ PS:

```text
Linux/A53 PS
  M_AXI_HPM0_FPD -> AXI-Lite -> control/mgmt at 0xA000_0000 (64 KiB)
  S_AXI_HP0_FPD  <- 128-bit converter <- 64-bit Ventium memory AXI
                                      -> guest RAM at 0x6000_0000 (256 MiB)
  FPGA manager/PCAP programs the PL at runtime

PL
  ao486_MiSTer system + Ventium core
  control/mgmt bridge + DDRAM-to-AXI bridge + custom debug block
  LED pins are the only external PL I/O and keep the design structurally anchored
```

Guest RAM is PS DDR, not the board's separate PL DDR4. Stock Linux leaves the
PS `pl0_ref` clock at approximately 100 MHz. `clk_div32.v` cascades BUFG
divisions of `/8` and `/4`, so silicon runs the core at `/32`, approximately
3.125 MHz. The local wrapper must model that clock tree; older reports that
show 95.456 MHz / 2.983 MHz are under-constrained for this running platform.
For a deliberately slower diagnostic run, the source-controlled board probe
can select the PS IOPLL `/16` profile: 93.75 MHz PL and approximately
2.9297 MHz after `/32`. That profile is timing-safe for an image routed at
95.456/2.983 MHz. Do not select the superficially matching RPLL `/11` profile
on stock Linux: the live RPLL rate differs from the Vivado preset and was
measured at 3.0303 MHz after `/32`, faster than that image's constraint.

The HP0 path is deliberately 128 bits at the PS boundary. An explicit AXI
clock converter and 64-to-128-bit width converter avoid a previously observed
PS-side 128-to-64-bit data-duplication failure. Do not simplify that path based
only on block-design validation.

The current memory bridge also contains a build-specific priming/double-read
workaround for stale HP0 data. It is not a complete repair: the 2026-08-22
silicon A/B proves that one discarded narrow response followed by one replay
can still deliver stale reset-state data. Do not increase the replay count as
an acceptance fix; capture transaction ownership and root-cause the HP0 reset,
drain, and converter path. The current debug ring has been repurposed more than
once during bring-up. Consequently, a daemon, bitstream, and debug decoder must
be treated as one versioned set.

## 3. Safety rules

- Before **any guest-DDR mapping**, prove that the full 256 MiB aperture is
  excluded from Linux System RAM by the actual boot-time reservation. Require
  a covering, non-reusable `no-map` reserved-memory region, not a CMA pool,
  and inspect unmasked root `/proc/iomem` for overlap. A runtime device-tree
  overlay or an apparent address-space gap alone is not proof that pages
  were excluded at boot. CMA can contain movable allocations, including page
  cache; never write the aperture on the assumption that `cma=512M` owns it.
  See the kernel's [CMA implementation](https://raw.githubusercontent.com/torvalds/linux/v6.12/kernel/dma/contiguous.c)
  and [boot-time reserved-memory handling](https://raw.githubusercontent.com/torvalds/linux/v6.12/drivers/of/of_reserved_mem.c).
  Changing the boot reservation and rebooting requires separate approval and
  a recoverable boot configuration. Recheck the effective device tree, memory
  map and boot log **after** reboot; a proposed DT source is insufficient.
- Reprogramming the PL disrupts the current guest immediately. Check for an
  existing `ao486d` first and stop it deliberately before loading a bitstream.
  Process absence does **not** mean the guest is idle: the daemon can exit after
  releasing the core, leaving the PL running. Read `CTRL`/`STATUS` with
  `ao486d --ident` as well. `CTRL=0x102` means RUN+IRQ are still enabled.
- A normal `ao486d` run holds/resets the core, zeros all 256 MiB of guest RAM,
  loads BIOS state, and then releases the core. It destroys the current guest
  session even when no disk is supplied.
- Win95 writes its disk image. Restore or clone a known-good image before a
  repeatable run.
- `ven_board_probe.py clock ...` writes the PS `PL0_REF_CTRL` register. Stop
  `ao486d` first and reset/reinitialize the guest afterward. Every other probe
  mode remains read-only.
- The board root filesystem was 95% full with about 79 MiB free at the
  2026-08-09 inspection.
  The 2 GiB Win95 VHD is sparse. Never send it with ordinary `scp`, which can
  materialize the holes and fill the filesystem. Use `rsync -S --inplace`.
- `--inject-keys` changes guest BDA memory and triggers a cache flush.
  `--stall-flush` is explicitly a workaround. A run that needs either option
  is diagnostic evidence, not a clean correctness pass.
- Omitting those flags is insufficient for older daemon binaries: the
  inspected September board shim also rewrites BDA LED state at `0x497` and
  flushes L1 by default. Clean acceptance requires a source-audited daemon
  without that intervention. Do not infer cleanliness from a binary name.
  The isolated October 2 replacement passes compile/link and stubbed-host
  checks only; this guide does not certify it or the retained September 5
  bitstream as a hardware-qualified matched set.
- Trace freeze and comparator modes can stop or reset the core. Use them only
  after a normal run has failed or when the run is intentionally diagnostic.
- Never access the PL AXI-Lite window through `/dev/mem` unless
  `/sys/class/fpga_manager/fpga0/state` is exactly `operating`. An access to an
  unconfigured PL address can leave the PS interconnect waiting indefinitely
  and take the board off the network. The source-controlled board probe checks
  this condition; use its `quake --precheck-only` mode for disk-only checks.
- Do not put passwords in new scripts or logs. The existing deploy helpers use
  password-oriented defaults and disable strict host-key checking; prefer SSH
  keys and a normal `known_hosts` entry for manual/release use.
- No local serial or JTAG device (`ttyUSB*`/`ttyACM*`) was attached at the
  2026-08-09 inspection. The current flow has no Xilinx ILA/VIO/debug bridge. Its
  “mini-ILA” is a custom AXI-Lite register/ring block, not Vivado ILA.

### JTAG capability boundary

The deployed flow is deliberately **PCAP-only**: Linux's FPGA manager loads a
raw bitstream through the ZynqMP PS and does not establish a JTAG transport.
The current image contains neither a Xilinx debug hub/ILA/VIO core nor an
`.ltx` probe map, and the available AXI-Lite forensic registers are not a JTAG
scan chain.  The deployed image cannot scan arbitrary fabric state,
preserve-and-resume the core, single-step it, or restore a captured machine
state. The in-tree debug-image work described below adds an AXI-Lite
instruction-boundary halt/step facility, but it is still not JTAG and does not
change this deployment boundary.

The RK board itself has physical JTAG headers (base-board 2x5 standard and
core-board 1x6 at 3.3 V).  Full Vivado JTAG therefore requires an attached,
authorized Xilinx-compatible cable reachable from this host or an explicitly
configured remote `hw_server`/XVC endpoint.  Neither is present in this setup.
Adding ILA/VIO, a debug hub, or BSCANE2/Virtual-JTAG logic is a debug-bitstream
change and requires a matching `.ltx` plus a new timing/sign-off run; it cannot
be enabled against the deployed bitstream by a board-side script.  Prefer the
source-controlled AXI capture and simulator save/restore procedures below
until that hardware and a debug image are explicitly authorized.

## 4. Host prerequisites

The inspected host has the expected toolchain:

```text
Vivado 2025.2, build 6299465
/tools/Xilinx/2025.2/Vivado/bin/vivado
aarch64-linux-gnu-g++ (Ubuntu GCC 15.2.0)
ssh, scp, rsync, sha256sum
```

The inspected host also has an unsafe system SSH fragment,
`/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` (owned by `nobody`, mode
`0777`). OpenSSH refuses to start with that file. The explicit commands below
use `-F "$SSH_CONFIG"` to bypass the broken system configuration while retaining
normal user identity and host-key files. An administrator should instead restore
the fragment's intended owner and permissions. Do not work around it by disabling
host-key checking.

Initialize the Xilinx environment before building hardware or the daemon:

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
vivado -version
aarch64-linux-gnu-g++ --version
```

The project generator hard-codes `$VENTIUM` and `$TEMPLATE`; moving either tree
requires updating `hw/create_project.tcl`. The template supplies
`board/XCZU15EG_Base_Config.tcl`, which configures PS DDR/MIO/clocks. The running
board was booted from the template's Linux/BSP flow and already provides:

```text
/usr/local/bin/load-bitstream.sh
/sys/class/fpga_manager/fpga0
configfs device-tree overlays
dtc
```

Normal Ventium iteration does **not** require rebuilding `BOOT.BIN`, the kernel,
rootfs, or SD-card image. Rebuild those from `$TEMPLATE` only when changing or
repairing the PS/Linux platform; see its `docs/03-build-guide.md` and
`docs/04-bitstream-from-ps.md`.

## 5. Record provenance before building

Create a run directory outside generated Vivado output and capture at least:

```bash
date -Ins
git -C "$VENTIUM" rev-parse HEAD
git -C "$VENTIUM" status --short
git -C /home/yukidama/github/ao486_MiSTer rev-parse HEAD
git -C /home/yukidama/github/ao486_MiSTer status --short -- fpga/rk-ao486-system
git -C "$TEMPLATE" rev-parse HEAD
vivado -version
sha256sum "$VENTIUM/rtl_ven_core.f" "$VENTIUM/rtl_ven_soc.f"
```

If any RTL or flow source is dirty, save the diff with the test results. A
commit ID by itself is insufficient. Also record the exact synthesis defines;
`hw/create_project.tcl` is the authority. The inspected configuration includes
`VEN_CORE`, `VEN_L1_AXI`, `VEN_L1_HONOR_CD`, the iterative/FPU options,
`VEN_DBG_CORE`, `VEN_FAST_RETRACE`, `VEN_KBD_AUTOACK`, and `VEN_KBC_FAST`.

## 6. Run pre-hardware verification

Hardware should be the last stage of verification, not the first. From
`$VENTIUM`, run the gates appropriate to the change:

```bash
cd "$VENTIUM"
make verify
make l1
make verify-all
```

`verif/run-verify-all.sh` is the authority for what `verify-all` includes in
this branch. It explicitly excludes some historical SoC/Quake/Win95 suites that
are absent here, so a green umbrella is necessary but not proof of a full-PC
boot. For system-mode or memory changes, also run the corresponding directed
gates rather than relying only on the fast differential gate.

Do not use a cache-disable, blanket serialization, periodic reset, forced
flush, or retry loop to turn a failing hardware run green unless the purpose is
fault isolation. Such a run must remain labeled diagnostic.

## 7. Build the board daemon

The daemon reuses the MiSTer PS x86/disk code from
`$VENTIUM/ao486-sim/ps`. It must be a static AArch64 binary because the board's
glibc is older than the cross toolchain's:

```bash
cd "$FLOW"
make -C sw
file sw/ao486d
sha256sum sw/ao486d
```

Expected output is an AArch64 statically linked executable. If the compiler
prefix differs, pass `CROSS=<prefix>-` to `make`.

## 8. Build and sign off the FPGA image

### 8.1 Validate the block design

```bash
cd "$VENTIUM"
"$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
  -source fpga/create_project_3mhz_wrapper.tcl \
  -tclargs bd "$VENTIUM/fpga_run_<tag>"
```

This creates and validates the block design but does not synthesize it. It is a
quick check for missing files, interface inference failures, address conflicts,
and PS/AXI width propagation errors. Confirm the log reports HP0 at 128 bits.

### 8.2 Run synthesis, implementation, and bitstream generation

#### Mandatory single-run guard

Use `fpga/run_vivado_exclusive.sh` for **every** Ventium Vivado launch. It
holds an exclusive host lock and, before each new build, stops the prior named
Vivado cgroup and terminates any remaining same-user Vivado/VRS process family,
including generic descendants. It waits for the complete family to disappear
before starting the replacement. `VEN_FPGA_JOBS` must be exactly `1`: there is
one complete Vivado process family and one synthesis worker on the host.

This is intentionally host-global and destructive to another active Vivado
job.  Do not launch `vivado -mode batch ...` directly, do not run two FPGA
commands in separate terminals, and do not bypass the guard with a background
shell.  The launcher records the PID/command line it terminates and escalates
from `SIGTERM` to `SIGKILL` if a stale process survives 45 seconds.

#### Current 40 MHz staged candidate flow

The October 3 candidate uses an explicit, frozen 110-define profile, full P5
caches, MMCM-derived **40 MHz core / 100 MHz PS-AXI**, and the `balanced`
implementation profile. The legacy command below defaults to 3.125 MHz and is
not the current 40 MHz deployment recipe. A copied historical PASS receipt
does not qualify a changed candidate.

`fpga/freeze_rk_candidate.py` creates an explicitly `UNQUALIFIED` derivative
of a pinned 179-payload parent. Supply exact parent-manifest/define hashes and
an explicit path/hash for each replacement; use `--help` for the arguments.
The output must be an already-created, empty directory outside the parent and
live source roots. Independently verify all resulting payload hashes/sizes,
defines and the delta receipt before launching. The current freeze and hashes
are recorded in `docs/FPGA_QUAKE_DEPLOYMENT_2026-10-02.md`.

The Oct 8 **experimental combined UV-fast** bundle has an explicitly reviewed
extension: `--fe-dtlb-source` plus `--fe-dtlb-sha256` adds one translation module
and exactly FE_PIPE/MULTI/PERM, producing 180 payloads / 113 hardware defines.
It requires explicit core/filelist replacements and retains all no-symlink,
source-pin and `UNQUALIFIED` checks. Its source audit, static guards and remaining
acceptance requirements are in
[`docs/UV_FAST_COMBINED_FREEZE_2026-10-08.md`](docs/UV_FAST_COMBINED_FREEZE_2026-10-08.md).
This bundle is not the installed bitstream and has no gameplay IPC measurement.

From the repository, focused FPU checks are available as:

```bash
python3 -B fp_shared/tb/run_ven_fp_srt_controls.py
tools/build_scope.sh -- bash fp_shared/tb/run_srt_top_ab_gate.sh
python3 -B fpga/test_freeze_rk_candidate.py
python3 -B fpga/test_impl_resume_tcl.py
```

The first gate extracts old/new control blocks from pinned actual sources and
checks settled four-state behavior. The second builds actual old/new FPU tops
with the production SRT divider; its base, stream and stream-forwarding runs
have bounded build/run time. Neither replaces the standard suite.

For a verified frozen-input directory, create a **fresh** native output tree:

```bash
fpga_inputs=/absolute/path/to/verified/frozen-inputs
fpga_run_root=$(TMPDIR=/home/yukidama/external/tmp \
  mktemp -d /home/yukidama/external/tmp/ventium-fpga40-native.XXXXXX)
mkdir "$fpga_run_root/tmp"
cd "$fpga_run_root"
TMPDIR="$fpga_run_root/tmp" \
VEN_FPGA_JOBS=1 VEN_FPGA_CORE_MHZ=40 VEN_FPGA_BUILD_PROFILE=balanced \
VEN_FPGA_SKIP_PRESET=1 \
VEN_FPGA_SOURCE_ROOT="$fpga_inputs/ventium" \
VEN_FPGA_FLOW_ROOT="$fpga_inputs/flow" \
VEN_FPGA_TEMPLATE_ROOT="$fpga_inputs/template" \
VEN_FPGA_DEFINE_FILE="$fpga_inputs/defines.txt" \
VENTIUM_VIVADO_MEMORY_MAX=19G VENTIUM_VIVADO_MEMORY_SWAP_MAX=8G \
timeout --signal=TERM --kill-after=60s 4h \
  "$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
  -log "$fpga_run_root/synthesis.log" -journal "$fpga_run_root/synthesis.jou" \
  -source "$fpga_inputs/ventium/fpga/create_project_3mhz_wrapper.tcl" \
  -tclargs synth "$fpga_run_root/output"
```

The selected cap must pass actual RAM/swap admission while preserving the
guard's host reserves. Do not disable admission or launch a second family to
inspect a live run. The four-hour synthesis bound is not an ETA. Require native
exit zero and completed, non-stale synthesis before implementation.

Pin the current `fpga/launch_impl_existing.tcl` separately from the historical
frozen launcher. For a fresh, never-started `impl_1`, invoke that pinned launcher
through the same exclusive guard with `VEN_FPGA_CORE_MHZ=40` and
`VEN_FPGA_OPT_DIRECTIVE=RuntimeOptimized`, passing the completed project's
absolute XPR path. The latter is installed Vivado 2025.2's documented Default
optimization without `bram_power_opt`, which previously crashed. It does not
reset failed runs or force bitstream generation. Require actual native
bitstream completion, full routing, DRC/CDC/bus-skew/timing review and regular
bit/bin hashes; its `IMPL OK` marker is not timing or silicon sign-off.

#### Continue an interrupted route from a preserved physical-opt checkpoint

Use `fpga/route_checkpoint_40mhz.tcl` when the saved, independently pinned DCP
contains the complete placed **40/100 MHz RK-XCZU15EG-F** design. Preserve the
aborted project and its logs; never reset it or copy completion markers. Verify
the DCP's ancestry against the frozen inputs, not just its filename. The native
loader checks Vivado 2025.2, part `xczu15eg-ffvb1156-2-i`, top
`rk_ao486_bd_wrapper`, both clock periods and full placement before routing.

After setting `checkpoint` and `checkpoint_sha` to the independently verified
input and its exact SHA-256, create a fresh external output tree:

```bash
fpga_run_root=$(TMPDIR=/home/yukidama/external/tmp \
  mktemp -d /home/yukidama/external/tmp/ventium-fpga40-dcp-route.XXXXXX)
mkdir "$fpga_run_root/tmp"
cd "$fpga_run_root"
TMPDIR="$fpga_run_root/tmp" \
VENTIUM_VIVADO_LOCK_DIR=/home/yukidama/external/tmp \
VENTIUM_VIVADO_MEMORY_MAX=12G VENTIUM_VIVADO_MEMORY_SWAP_MAX=2G \
timeout --signal=TERM --kill-after=60s 8h \
  "$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
  -log "$fpga_run_root/route.log" -journal "$fpga_run_root/route.jou" \
  -source "$VENTIUM/fpga/route_checkpoint_40mhz.tcl" \
  -tclargs "$checkpoint" "$checkpoint_sha" "$fpga_run_root/output"
```

The cap must pass the existing admission reserves; 12 GiB is a routing-only
profile, not a synthesis recommendation. The script opens the DCP without
overriding part or dropping timing, uses default routing, preserves a fresh
routed DCP before reporting, emits the same 16 unfiltered reports, then writes
native `.bit` and `.bin` without `-force`. Require actual native exit zero,
positive full-routing/no-error checks, nonempty regular artifacts and independent
report review. Its completion marker is not timing or silicon acceptance.
The old project-run-only collector cannot certify this standalone flow: its
aborted `impl_1` remains aborted. Do not fabricate project completion metadata.

Host-only failure regression (no Vivado, synthesis or simulation):

```bash
TMPDIR=/home/yukidama/external/tmp \
  python3 -B fpga/test_route_checkpoint_40mhz.py
```

The test is bounded to 512 MiB / 115 seconds and checks successful control flow,
all 16 report-command errors, hashes, part/top/clocks, placement/routing,
missing/empty native artifacts and closure failure. Its synthetic fixtures are
not native checkpoints or deployable images.

#### Legacy 3.125 MHz diagnostic flow

```bash
"$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
  -source "$VENTIUM/fpga/create_project_3mhz_wrapper.tcl" \
  -tclargs all "$VENTIUM/fpga_run_<tag>"
```

The local wrapper evaluates the external authoritative Tcl after correcting
its stale 6 MHz interface metadata to 3 MHz, models the running board's IOPLL
`/15` 100 MHz PL clock, enables the verified `VEN_SYS_FASTPATH` plus its narrow
equal-common-base `VEN_SYS_FASTPATH_RELOC`, full-limit DS/SS
`MOV r32,[...]` `VEN_SYS_FASTLOAD_FLAT`, and matching non-page-crossing
`MOV [...],r32` `VEN_SYS_FASTSTORE_FLAT` extensions. The read/write forms are
differential-tested with a common non-zero base and non-identity paging; the
store path also has a protected #PF/restart test and deliberately leaves a
4 KiB-crossing dword on the mature fragment engine (not `VEN_SYS_FASTPATH_ALL`),
caps Vivado at one thread, and selects `AreaOptimized_high`. The direct
upstream script still labels the `/32` clock as `/16`/6 MHz and imports a PS
clock configuration that does not match stock Linux; do not bypass the wrapper
for this image. A BD preflight should report
approximately 99.999 MHz for `pl_clk0`; the final clock summary must report
approximately 3.125 MHz for the divided core.

Two environment knobs support controlled implementation experiments:

```bash
# Diagnostic A/B: omit both system-fast-path defines, leave every other define unchanged.
VEN_FPGA_FASTPATH=0 VEN_FPGA_JOBS=1 \
  "$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
    -source "$VENTIUM/fpga/create_project_3mhz_wrapper.tcl" \
    -tclargs all "$VENTIUM/fpga_run_<tag>"
```

`VEN_FPGA_FASTPATH` defaults to `1`; setting it to `0` removes the system
fast-path defines. `VEN_FPGA_RELOC_FASTPATH` also defaults to `1`; setting it
to `0` retains the stricter base-zero subset. `VEN_FPGA_FASTLOAD` defaults to
`1`; setting it to `0` retains the system register/control path but sends all
memory loads (and therefore dependent fast stores) to the slow FSM for a
source-identical diagnostic A/B. `VEN_FPGA_FASTSTORE` defaults to `1`; setting
it to `0` leaves the read path enabled but returns only the compact system
stores to the slow FSM. It cannot be enabled when `VEN_FPGA_FASTLOAD=0`.
`VEN_FPGA_JOBS` defaults to `1` and the wrapper rejects every other value.
The generated Tcl sets `general.maxThreads 1`; the named systemd scope uses
`KillMode=control-group`, so a replacement launch terminates the parent, VRS,
and every descendant together. Always verify the generated synthesis Tcl output
rather than trusting an output-directory label.

### 8.2.1 Preset-free PCAP fallback

On the currently installed Vivado 2025.2/IP catalog, the external template's
board-level PS preset can be rejected during project creation (incompatible
MIO/DDR settings) before RTL synthesis begins. The wrapper supports the
upstream script's documented preset-free fallback for this **PCAP-only** case:

```bash
VEN_FPGA_SKIP_PRESET=1 VEN_FPGA_FASTPATH=0 VEN_FPGA_JOBS=1 \
  "$VENTIUM/fpga/run_vivado_exclusive.sh" -mode batch \
    -source "$VENTIUM/fpga/create_project_3mhz_wrapper.tcl" \
    -tclargs bd "$VENTIUM/fpga_run_<tag>"
```

It retains the wrapper's explicit GP0, HP0, and PL-clock configuration; the
already booted Linux/FSBL owns the PS configuration when loading a raw PL
bitstream through PCAP. The BD preflight must still validate with HP0 at 128
bits and `pl_clk0` near 100 MHz. Do not use this switch to export an XSA,
rebuild BOOT.BIN, or change the PS/Linux platform. It is a compatibility
fallback for raw runtime PL images only.

The mode behavior is subtle:

- `bd`: create and validate the BD, then return.
- `all`: synthesize, implement through `write_bitstream`, and copy the results.
- Any other string, including the advertised `xsa`, runs synthesis but does not
  emit a useful XSA. Do not depend on `xsa` mode in this flow.

The canonical outputs are:

```text
$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit
$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit.bin
$VENTIUM/fpga_run_<tag>/rk_ao486_system/rk_ao486_system.runs/impl_1/
```

`write_bitstream -bin_file` creates the raw `.bin`; the flow copies it to the
`.bit.bin` name. Do not run the template's `bit2bin.sh` on it again.
Do not byte-swap it either: the October 3 board-loader audit confirms that
the loader copies the bytes unchanged. Before staging a new candidate, hash
the native `.bin` and its renamed copy and inspect the initial bytes; the
known-working raw image contains the Xilinx sync bytes `aa 99 55 66` at
offset `0x50`. This is a format sanity check, not proof of correct routing,
hardware operation or timedemo completion.

### 8.3 Sign-off checks

Do not accept `## IMPL OK` or a single WNS line as complete sign-off. Review the
final post-route/post-physical-optimization reports:

```bash
IMPL="$VENTIUM/fpga_run_<tag>/rk_ao486_system/rk_ao486_system.runs/impl_1"

rg -n -A 12 'Design Timing Summary|Clock Summary' \
  "$IMPL/rk_ao486_bd_wrapper_timing_summary_postroute_physopted.rpt"

rg -n 'CLB LUTs|LUT as Logic|CLB Registers|Block RAM Tile|DSPs|URAM' \
  "$IMPL/rk_ao486_bd_wrapper_utilization_placed.rpt"

sed -n '1,80p' "$IMPL/rk_ao486_bd_wrapper_drc_routed.rpt"
```

Acceptance criteria:

- setup and hold WNS are non-negative;
- TNS and THS are zero with no failing endpoints;
- all user timing constraints are met;
- routed DRC contains no Error or Critical Warning;
- utilization is plausible and routability margin has not collapsed;
- the reported clocks match the intended PS and divided core clocks; and
- the sign-off record states both the constrained clock frequencies and a
  measured on-board core frequency.  WNS/WHS demonstrate timing closure at a
  constraint; they are not a frequency measurement.

Warnings still require review. The inspected routed DRC had no errors, but had
many DSP pipelining warnings plus a clock-buffer cascade and one no-load
warning. Do not blindly waive new warning classes.

The 2026-08-29 passive-VGA-capture build is the current board image.  It has
route/timing/DRC sign-off and its clocks were measured while the normal guest
boot was running, but it is not a workload-acceptance result yet:

| Metric | Value |
|---|---:|
| raw image SHA-256 | `279bc2c0caa14cbea169ddf1b25a60407ef0b44bbc3a92186d96e251895064fd` |
| constrained PL / divided / core clock | 100.000 MHz / 12.500 MHz / **3.125 MHz** |
| measured live core clock | **3.125179 MHz** over 2.000085 s (separate 1.000072 s sample: 3.125326 MHz) |
| WNS / TNS | +4.521 ns / 0 |
| WHS / THS | +0.014 ns / 0 |
| CLB LUT | 315,981 / 341,280 (92.59%) |
| CLB registers | 42,984 / 682,560 (6.30%) |
| BRAM tiles | 101 / 744 (13.58%) |
| DSP | 1,264 / 3,528 (35.83%) |
| route | 415,938 routable nets; fully routed |
| silicon status | passive recorder is armed; cold boot reaches FreeDOS, then returns to the real-mode `C:\QUAKE>` prompt without a 969-frame timedemo result (workload acceptance blocked) |

The two counter samples use the retired-cycle counter and elapsed host interval,
so their small difference is measurement jitter rather than an overclock claim.
Use **3.125 MHz** as the implementation frequency and quote the measured value
with its sampling interval when reporting silicon results.

The workload blocker above is not a clock-rate inference. Read-only samples
show the live real-mode FreeDOS/BIOS path (`CR0=0x00000010`) through firmware
(`f000:xxxx`), IO.SYS (`0070:xxxx`), and the command interpreter (`05f7:xxxx`).
A simultaneous 1.000071 s counter interval retired 181,638 instructions at
**3.125329 MHz** but issued zero new AXI reads; the last completed disk-read
count was 527. The sparse core-observation reconstruction contains a recent
`C:\QUAKE>` prompt. It therefore establishes that the timedemo command has
returned to DOS, not that Quake ran or that a disk/CPU hang occurred. The exact
error/exit cause remains open. This diagnosis neither resets nor changes the
guest, disk image, or passive recorder.

The latest corrected-clock repaired candidate was built and deployed on
2026-08-22. It is the current implementation reference, but **not a functional
acceptance image**:

| Metric | Value |
|---|---:|
| raw image SHA-256 | `f8f69b38417a6039db64f38c691bb1c65111afc09f670b02042e09177c2d3bf1` |
| WNS / TNS | +2.004 ns / 0 |
| WHS / THS | +0.011 ns / 0 |
| PS clock / core clock | 99.999 MHz / 3.125 MHz |
| CLB LUT | 316,250 / 341,280 (92.67%) |
| CLB registers | 42,339 / 682,560 (6.20%) |
| BRAM tiles | 85 / 744 (11.42%) |
| DSP | 1,265 / 3,528 (35.86%) |
| route | 415,779 fully routed nets; 0 unrouted nets |
| silicon result | FAIL: reset-state non-cacheable narrow read returns stale data before POST |

The cacheable A/B ROM passes both 256-iteration interrupt phases on this exact
image, while the default reset-state ROM fails deterministically. Treat timing,
DRC, and utilization sign-off as necessary conditions only; this is the current
counterexample showing why the focused silicon gate must precede workloads.
See `fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md`.

The source-matched `AreaOptimized_high` candidate built on 2026-08-20/21 had
the following implementation results. This table is retained as historical
utilization evidence, but the image is **not timing-valid on stock Linux**:

| Metric | Value |
|---|---:|
| WNS / TNS | +1.606 ns / 0.000 ns |
| WHS / THS | +0.010 ns / 0.000 ns |
| PS clock / core clock | 95.456 MHz / 2.983 MHz |
| CLB LUT | 315,780 / 341,280 (92.53%) |
| LUT as logic | 312,370 (91.53%) |
| CLB | 41,933 / 42,660 (98.30%) |
| CLB registers | 42,367 (6.21%) |
| BRAM tiles | 85 (11.42%) |
| DSP | 1,265 (35.86%) |
| route | 415,264/415,264 routable nets complete; 0 errors/overlaps |

All ten CDC bus-skew constraints pass (minimum slack +9.637 ns), all internal
endpoints are constrained, routed DRC/bitgen have zero errors and zero critical
warnings, and the deployable `.bit.bin` SHA-256 is
`fce0eb3f431c5ea813cc5fca832d5c0d5f89d1a2eb2333a6f4a6f9a51af49a5d`.
This image was internally clean at its reported clocks but had only 1.70% CLB
headroom. It must not be used as a board acceptance image: a source-controlled
counter sample later measured the live core at 3.125041 MHz, faster than the
2.983 MHz constraint. Preserve the warning/congestion audit in
`FPGA_RUN_Aug20.md`, and require a new route against the real clock.

The 2026-08-21 corrected-clock non-fast attempt used the same current sources
with `VEN_FPGA_FASTPATH=0` and modeled 99.999 MHz / 3.125 MHz. Synthesis and
placement succeeded with zero errors, but the 90.70% LUT / 96.55% CLB design
was not legally routable: after 3 h 17 min, `route_design -directive Explore`
ended with 592 node overlaps and reported 935 signals affected by congestion.
Vivado wrote only `rk_ao486_bd_wrapper_routed_error.dcp`; no bitstream was
generated or deployed. An intermediate positive WNS is not usable when route
verification fails.

For comparison, the older **host artifact** built on 2026-08-01 had:

| Metric | Value |
|---|---:|
| WNS / TNS | +1.470 ns / 0.000 ns |
| WHS / THS | +0.012 ns / 0.000 ns |
| PS clock / core clock | 95.456 MHz / 5.966 MHz |
| CLB LUT | 298,463 / 341,280 (87.45%) |
| LUT as logic | 292,297 (85.65%) |
| CLB | 40,875 / 42,660 (95.82%) |
| CLB registers | 34,672 (5.08%) |
| BRAM tiles | 85 (11.42%) |
| DSP | 1,262 (35.77%) |
| URAM | 0 |

This is a comparison baseline, not an evergreen pass result. It predates the
current dirty Ventium RTL and cannot validate those changes.

Finally hash the deployable set:

```bash
sha256sum \
  "$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit.bin" \
  "$FLOW/sw/ao486d" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot0.rom" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot1.rom"
```

## 9. Board preflight

All commands in this section are read-only:

```bash
ssh -F "$SSH_CONFIG" "$BOARD" 'hostname; uname -a; df -h / /tmp'
ssh -F "$SSH_CONFIG" "$BOARD" 'cat /sys/class/fpga_manager/fpga0/state'
ssh -F "$SSH_CONFIG" "$BOARD" 'cat /proc/cmdline; ls -ld /proc/device-tree/reserved-memory'
ssh -F "$SSH_CONFIG" "$BOARD" 'pgrep -a -x ao486d || true'
ssh -F "$SSH_CONFIG" "$BOARD" 'ls -lh /tmp/ao486 2>/dev/null || true'
ssh -F "$SSH_CONFIG" "$BOARD" \
  'sha256sum /tmp/ao486/rk_ao486_system.bit.bin /tmp/ao486/ao486d 2>/dev/null || true'
```

For a DDR-using launch, also obtain the actual reserved-memory node's `reg`,
`no-map` and pool/reuse properties, unmasked **root** `/proc/iomem`, and boot
reservation evidence. Decode `reg` using the tree's address/size cell counts;
verify coverage of `[0x60000000, 0x70000000)` and absence of every overlapping
System RAM interval. Non-root `/proc/iomem` can report all-zero addresses:
that is masked evidence, not an empty memory map or permission to proceed.
On the initial October 2 inspection the node was absent, the memory node
covered the aperture, and the boot arguments contained only `cma=512M`.
That boot was not admitted for guest DDR use. After the authorized reboot at
19:35 UTC, boot ID `2861e4e8-cd4c-48cd-9f44-7f7d8a991ebb` has the full
non-reusable `no-map` reservation and root `/proc/iomem` excludes the aperture
from System RAM. Recheck all of this for each subsequent boot; the retained
receipt does not authorize a different boot or memory map.

If the staged daemon is the one built from the inspected `board_shim.cpp`, its
`--ident` path only reads the control/debug registers (it does not hold/reset,
zero RAM, mount a disk, or release the core):

The older implementation nevertheless attempts to **map guest DDR** during
`--ident`. Do not use that binary on the blocked October 2 boot. A genuinely
control-only IDENT path must be confirmed in the exact replacement source and
binary; the isolated replacement is not yet hardware/deployment-qualified.

```bash
ssh -F "$SSH_CONFIG" -t "$BOARD" 'sudo /tmp/ao486/ao486d --ident'
```

Run that command only after the preceding FPGA-manager check reports
`operating`; “read-only” does not make an access to an unconfigured PL address
safe. Recheck the implementation before assuming a future daemon's `--ident`
is read-only.

On 2026-08-09, the board was `rk-xczu15eg-f`, ran Linux 6.12 on AArch64,
reported FPGA state `operating`, and had about 79 MiB free on a 95%-full root
filesystem. No `ao486d` process existed, but the read-only IDENT probe returned
`STATUS=0x100` and `CTRL=0x102`: the core was still released and running. The
staged files were:

```text
host bitstream  45207ed279f67a431b8782f57ad902c7428fc9f99ea9df87645c46cacd6de01b
board bitstream 2d71598087053eecdb62a53c8380de2209597a3682692ff0312d4a997d6e0d0f
host/board ao486d f42b49b964209265933b133fe7f9cd385169224228c878aca2043dac72e2bdba
```

The bitstreams did **not** match. Therefore the board's `operating` state was
not validation of the current host artifact. Always repeat the comparison for
the run being reported.

A five-second read-only `perf.py` sample on that unmatched board image measured
6.250 MHz, IPC 0.0582, and 94.2% no-retire cycles. The compared 2026-08-01 host
artifact instead described a 5.966 MHz core, while the later under-constrained
candidate described 2.983 MHz. This is additional evidence that the staged board image and both host
artifacts are different builds. Treat any board-local script's hard-coded
expected-frequency text as build-specific; use raw interval deltas unless its
source and bitstream are explicitly paired.

## 10. Program and smoke-test the PL

### 10.1 Preferred explicit sequence

The explicit sequence makes every mutation visible and avoids transferring a
disk image:

```bash
ssh -F "$SSH_CONFIG" "$BOARD" 'mkdir -p /tmp/ao486'

scp -F "$SSH_CONFIG" \
  "$VENTIUM/fpga_run_<tag>/rk_ao486_system.bit.bin" \
  "$FLOW/sw/ao486d" \
  "$VENTIUM/fpga/board-tools/ven_board_probe.py" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot0.rom" \
  "$VENTIUM/3rd-party/ao486_MiSTer/releases/boot1.rom" \
  "$BOARD:/tmp/ao486/"

ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /usr/local/bin/load-bitstream.sh /tmp/ao486/rk_ao486_system.bit.bin &&
   sudo /usr/local/bin/load-bitstream.sh --status &&
   sudo chmod +x /tmp/ao486/ao486d &&
   sudo /tmp/ao486/ao486d --ident'
```

The loader copies the raw bitstream to `/lib/firmware`, applies a configfs
device-tree overlay to `&fpga_full`, and programs through the ZynqMP FPGA
manager/PCAP. It falls back to the legacy manager sysfs interface if necessary.
The current loader only warns when the manager is not `operating`; its exit
code alone is insufficient. Read the manager state independently and require
the matching IDENT before releasing the core. For a new clock image, also
measure the held-reset core clock; constraint reports do not prove silicon MHz.

For the frozen October 3 MMCM candidate, the CPU and `perf_cyc` share the same
clock: `MMCM -> system.clk_sys -> ven_ao486_shim -> ventium_top -> core`.
There is no downstream divide-by-four or clock enable; the output buffer is
enabled only by MMCM lock. Thus a held-core `perf --seconds 5` counter interval
can establish the physical core clock pin frequency before guest release,
but cannot establish CPU throughput. The October 3 held historical image
measured **3.125067 MHz**, with zero retirements and `CTRL=1` before/after;
this is not a measurement of the new 40 MHz candidate. Repeat after programming.
Require and record **`CTRL=0x0001`** and **`FRZINFO.frozen=0`** before and after
the interval, with no concurrent owner issuing clear/control writes. Preserve
the raw 64-bit cycle endpoints and actual monotonic elapsed time; about 200M
cycles over five seconds with **zero retirements** is the expected held-reset
40 MHz result. The probe uses rollover-safe reads, but this is not a precision
calibration or STA proof. A stopped/incorrect counter or a changed hold/freeze
state fails preflight; do not release the guest based only on a clock label.

Smoke passes only when both conditions hold:

```text
fpga manager state = operating
IDENT               = A0486501
```

An IDENT mismatch means the PL/control-map/daemon set is wrong even if the FPGA
manager says `operating`.

### 10.2 Existing smoke helper

From `$FLOW`, this is the equivalent convenience command:

```bash
scripts/deploy.sh smoke
```

Review it before use. It rebuilds the daemon, copies the deployable set,
programs the PL, and runs `--ident`, but currently embeds password-based
automation and disables strict host-key checking. It also does not pass
`-F /dev/null`, so it currently aborts on the inspected host's unsafe system SSH
fragment. Until that system file is repaired or the helper is corrected, use
the explicit sequence above.

## 11. Verification ladder

Run one stage at a time and preserve its log. A later-stage failure must not
erase the last known-good lower stage.

### Mandatory UV + fast-pipe acceptance mode

Processor repairs must pass with dual U/V issue and the system fast pipeline
enabled. U-only, single-stepped, pairing-disabled, or globally slow-path
controls are diagnostic results only, never a repair or standard-suite pass.
The RK build wrapper rejects fast-path disabling environment options, missing
system fast load/store/relocation or FP-pipeline defines, and a shim without
the unique `.cycle_mode(1'b1)` connection. Explicit frozen profiles are checked
too. `fpga/test_uv_fast_profile.py FROZEN_BUILD` exercises those source guards
without invoking Vivado; set `TMPDIR=/home/yukidama/external/tmp` first.

Source configuration alone is insufficient. During the measured workload,
require no debugger STEP, intended-V breakpoint, HALT request or forensic freeze,
and retain evidence of execution through the paired fast path. The read-only
helpers in `fpga/board-tools/ven_uv_fast_guard.py` check execution controls and
adjacent primary-retirement entries across independently decoded test pairs;
`test_ven_uv_fast_guard.py` includes slow/unpaired/wrong-target rejection tests.
The ring witness is local execution evidence, not an every-cycle pairing rate.
Ordinary ISA-required serialization and slow handling of unsupported fast-path
instructions remain valid; do not force unsafe operations to pair.

The current board `perf_retired` counter increments on primary retirement,
not both U and V. Its ratio is **primary/U retirement IPC**, even when U/V mode
is enabled. Never label that ratio total architectural U+V IPC or claim a
performance target has passed without a suitable complete retirement count.

### 11.1 BIOS/POST without a disk

After staging/programming in section 10, run the daemon explicitly for 60
seconds with BIOS and text reporting:

```bash
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --secs 60 --text'
```

Look for core release, advancing memory/retirement counters, BIOS text, disk
detection state, and no watchdog/forced-flush rescues. With no disk, reaching a
clean boot failure after POST is expected; random reset, frozen counters, or an
IDENT/control failure is not.

After the host SSH fragment is repaired (or the script learns the same `-F`
option), `scripts/deploy.sh post` is the convenience equivalent that also
reprograms the PL.

### 11.2 Trace a POST or boot failure

**Historical diagnostic daemon only.** These commands apply to the legacy
`/tmp/ao486/ao486d`, not the pinned `ao486d.device-safe-oct02`. The production
CLI rejects `--loadonly`, the listed diagnostic/intervention options, and
negative `--secs`; its legacy held-startup branch is unreachable. Use the
supported private-VHD cold launch in §11.3 for the current candidate.

```bash
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --secs 25 --text --trace'
```

or add selected daemon options:

```text
--trace                 dump the PC and auxiliary rings at the end
--freeze CYCLES         freeze after this many no-retire cycles
--tracesecs N           freeze rings after N seconds
--cmpcfg VALUE          configure retire comparator/freeze
--cmprng VALUE          comparator EIP range
--peek ADDR             dump guest RAM while core remains held after load
--peekrun ADDR          dump guest RAM after the run
--loadonly              initialize memory/BIOS, leave core held, exit
```

These modes are intrusive. The ring format is build-specific; decode it against
the exact `rk_ao486_system_pl.v`, `ven_soc_dbg.sv`, and `board_shim.cpp` used to
build the bitstream/daemon.

### P5 cache-enable boot ROM bootstrap

The upstream ao486 `boot0.rom` assumes a CPU that ignores the reset values of
`CR0.CD` and `CR0.NW`. Ventium intentionally honours both cache-disable bits.
Therefore the unmodified ROM leaves the I- and D-cache disabled indefinitely;
do **not** paper over that firmware defect with `VEN_L1_IGNORE_CD` or a
workload-specific RTL exception.

`tools/patch_boot0_cache_enable.py` is a deliberately narrow bootstrap while
the legacy `bcc`/`as86` firmware toolchain is unavailable. It accepts only the
known 64 KiB release ROM (`e70c8843…84c4331e`), verifies the reset vector and
the all-zero POST padding, inserts `WBINVD` plus a serializing `MOV CR0` that
clears only CD/NW, replays the displaced `xor ax,ax`, and recomputes the BIOS
checksum. It refuses any other ROM rather than silently modifying a future
source-built image.

```bash
python3 tools/patch_boot0_cache_enable.py \
  3rd-party/ao486_MiSTer/releases/boot0.rom \
  /tmp/boot0-cache-enable.rom
sha256sum /tmp/boot0-cache-enable.rom
# dca915c5483793a710ee118c5232aad01ef3191bea7d50c2befb1a47d2dd26a3
```

The full-PC simulation must first demonstrate a post-POST CR0 with CD/NW
clear. The 2026-08-31 hardware check likewise changed from
`CR0=e0000019`, 0.010076 IPC at 45.0007 MHz to `CR0=80000019`, 0.0582 IPC
during the RAM-backed Quake boot (and 0.0732 IPC after the daemon exited).
This proves the cache transition; it is not a Quake acceptance result.

If the board root filesystem is full, do not create a second ROM there or
delete forensic artifacts speculatively. Stage the generated ROM and a rollback
copy in `/dev/shm`, hash both, then have an operator overwrite the existing
same-size `/tmp/ao486/boot0.rom` in place and verify its output hash before any
reset. A normal `ao486d` cold boot is still destructive to guest RAM; use a
copy of the VHD in `/dev/shm` for diagnostics that must not modify a persistent
disk. Retain the original ROM hash/image until a source-built replacement is
available.

### 11.3 Quake

The board already has `/tmp/ao486/qk_td.vhd`. The current `deploy.sh quake`
tries to copy a host image from
`$VENTIUM/ao486-sim/run_eipfix/qk_td.vhd`, which is absent. Reuse the
board-staged disk and run explicitly after verifying it:

```bash
ssh -F "$SSH_CONFIG" "$BOARD" \
  'stat /tmp/ao486/qk_td.vhd; sha256sum /tmp/ao486/qk_td.vhd'
scp -F "$SSH_CONFIG" \
  "$VENTIUM/fpga/board-tools/ven_board_probe.py" \
  "$BOARD:/tmp/ao486/"
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ven_board_probe.py quake \
     --disk /tmp/ao486/qk_td.vhd --precheck-only'
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --hdd /tmp/ao486/qk_td.vhd --secs 600 --text' \
  |& tee quake-board.log
```

The precheck reads only the disk and must print `QUAKE DISK PRECHECK CLEAN`.
Do **not** run the normal Quake probe alongside the daemon: its current
implementation rereads the complete 64 MiB disk image on every interval, which
is needlessly intrusive and can distort a slow hardware run.  Let `ao486d`
finish, then run the probe once without `--precheck-only`; it requires an exact
969-frame result and prints `QUAKE TIMEDEMO COMPLETE`. PC movement, disk reads,
or a nonzero retired count alone does not prove Quake completed.

Once CWSDPMI has installed Quake's live page tables, `quake-progress` is the
non-intrusive progress probe. It walks PDE/PTE entries in guest RAM and reads
Quake's own counters; it never scans or modifies the disk:

```bash
sudo /tmp/ao486/ven_board_probe.py quake-progress \
  --cr3 0x7e000 --ds-base 0x10000000 --samples 10 --interval 5
```

Those defaults match the current instrumented timedemo only. A non-present
PDE/PTE or a different DPMI layout is a hard error. `demo_frames` is progress
evidence; the 36-byte disk record remains the acceptance authority. In the
automatic command-line path `td_startframe == 0` is valid: the tool therefore
uses active demo playback plus a non-null demo file, rather than the truthiness
of `td_startframe`, to decide whether `host_framecount - td_startframe - 1` is
real progress.

For a failing run, the existing external-freeze path can stop the on-die rings
as soon as CWSDPMI finishes formatting an exception:

```bash
sudo /tmp/ao486/ven_board_probe.py trap-cwsdpmi-exception \
  --start 0x20000 --end 0x50000 --timeout 900
sudo /tmp/ao486/ven_board_probe.py dump-ring --depth 128
```

The scan is read-only until a complete register record matches, then it pulses
the debug block's external freeze. That freeze is deliberately intrusive and
sticky: archive RAM/rings first and reprogram the same hashed bitstream before
the next clean workload. Its displayed vector can be stale; parse the guest's
saved exception frame/TSS before assigning an architectural vector.

Do not arm this text trigger immediately after a preceding frozen experiment.
A PL reload does not by itself make DDR a trustworthy fresh-guest witness: a
previous CWSDPMI formatter string can remain visible while the next daemon is
starting. The probe waits for an absent-record sample before it will fire, but
the safe operating rule is stronger: arm this trigger only after a clean boot
has reached the audited client phase, and treat an early boot-stage hit as
suspect until its rings and reset epoch agree. It is a forensic aid, never an
acceptance-run monitor.

For the dedicated `QUAKE_FAULT_FRAME_LOGGER.EXE` diagnostic disk, use the
cache-aware fault-frame trigger instead. The guest patch copies its exception
frame to its reserved client-data slot; the host tool translates that slot
through the live Quake page tables and watches both DDR *and* the existing
core-observation ring. The ring is essential: a client store can still be in
L1 when external freeze prevents it reaching DDR.

```bash
sudo /tmp/ao486/ven_board_probe.py trap-quake-fault-frame \
  --cr3 0x7e000 --ds-base 0x10000000 --offset 0x90b80 \
  --words 16 --timeout 1800 --interval 0
```

Run it only with the matching patched diagnostic executable and an explicitly
disposable disk. On a hit it reports whether DDR or the core ring supplied the
witness, freezes the FPGA, and prints the captured dwords/ring stores. Copy a
compact `capture` bundle off-board before reprogramming. A zero-valued raw DDR
slot does **not** disprove that the logger ran; it can be a cache-visibility
artifact. The production, unmodified-disk timedemo must run without this
trigger and still requires the exact 969-frame record.

For the pinned October7 CWSDPMI layout, `fpga/board-tools/watch_dpmi_pf.c`
provides a **post-fault diagnostic halt**, not a processor workaround. The
native loop watches read-only DDR for vector14 plus two matching complete
CPL3 fault frames; only afterward does it request the quiescent manual HALT.
It never steps, arms an execution breakpoint, changes the clock, writes guest
RAM or enables the reset-producing comparator. A1ms Python watcher proved
too slow: exception dispatch had already removed the error code and reused
the frame. The native frame checks reject that stale shape.

This tool is deliberately pinned to physical3166c/2ff4a and CSa7/SSaf. Do not
reuse these addresses for a different guest/layout. Its launcher must validate
the reserved DDR, exact image, guest inputs and debug-helper hashes first.
Use `--self-test` for a no-device parser/UV-guard test; the root-only
`--post-fault-halt-pinned-oct07` action is bounded300s and rejects STEP/BP,
an existing HALT/freeze, and observed counter reset. After it halts, preserve
`dump-state`, `dump-ring --allow-live`, observer banks and aligned RAM **before**
any forensic freeze or reset. Task-saved GPRs and frame bytes still require
independent decoding; a trigger match/native0 is not workload acceptance.
The qualified October7 capture and limitations are recorded in
`docs/FPGA_CMP_BRANCH_LOCALIZATION_2026-10-05.md`.

Some DPMI-client failures return normally to DOS and never format that
exception record.  If read-only evidence has already established that the
failure is a particular protected-mode exit, the selector-independent CR0
trigger can capture its boundary.  Do **not** use it merely because a sample
shows real-mode selectors: CWSDPMI makes legitimate protected/real-mode round
trips during Quake startup, and freezing the first `PE=1 -> 0` transition can
turn healthy progress into an apparent exit.  Delay and qualify the trigger
against a preceding uninterrupted run; it arms on CR0.PE=1 and freezes on the
first transition back to real mode:

```bash
sudo /tmp/ao486/ven_board_probe.py trap-pe-exit \
  --delay 300 --timeout 900
sudo /tmp/ao486/ven_board_probe.py dump-ring --depth 128
```

`trap-pe-exit` also accepts `--arm-cs 0xa7` to defer arming until a particular
protected-mode client selector has retired.  This is a useful guard against
pre-client extender setup, but it is **not** by itself a terminal-failure
detector for DOS Quake: its normal demand-page path at `00a7:000010bc` enters
CWSDPMI and legitimately returns to real mode.  A 2026-08-23 capture froze
exactly on that expected `00a7:000010bc -> 26d9` transition.  Use a
CS/EIP-qualified comparator for a known late fault window, or establish a
more specific state predicate from a preceding read-only run; never infer an
abort merely from the first client-qualified PE exit.

If the failing workload remains protected but leaves a known code-selector
set, use the narrower stateful selector-boundary trigger instead.  It ignores
startup, arms only after the audited protected selector/EIP has retired, and
freezes on the first retire outside the protected selector set:

```bash
sudo /tmp/ao486/ven_board_probe.py trap-protected-exit \
  --enter 0x26d9 --allow 0x0018,0x00d9,0x26d9 \
  --enter-eip-min 0x3000 --delay 300 --require-pe --timeout 900
sudo /tmp/ao486/ven_board_probe.py dump-ring --depth 128
```

The selector, EIP, and delay values are workload/build-specific; derive them
from a preceding read-only `sample --all` run rather than copying them to
another guest. `--require-pe` rejects real-mode segments that happen to have
the same numeric value and fires when the captured protected-mode session
clears CR0.PE. The
trigger is a diagnostic write: once it fires the external freeze is sticky,
so archive the ring and RAM before reprogramming.

For a still-running daemon, the source-controlled comparator utility can arm a
narrow late-failure window without holding the core or clearing its rolling
prehistory:

```bash
scp -F "$SSH_CONFIG" \
  "$VENTIUM/fpga/board-tools/ven_board_trace_arm.py" \
  "$BOARD:/tmp/ao486/"
ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo python3 /tmp/ao486/ven_board_trace_arm.py \
     --cs 0x00a7 --eip-lo 0xd5c4 --eip-hi 0xd611 --live'
```

Use `python3` explicitly because `scp` need not preserve the executable bit.
`--live` refuses a non-operating FPGA, wrong `IDENT`, held core, or already
frozen trace. It disables the comparator while changing the range and makes the
enable/freeze write last; it does not clear either ring. A successful arm for
the example above prints:

```text
IDENT=a0486501 live=1 core_held=0 frozen=0 cmp_cfg=000f00a7 cmp_range=d611d5c4
```

This debug block compares only the low 16 bits of EIP. Never arm an EIP range
without a known CS, and derive both from a preceding read-only sample. An EIP
above 64 KiB aliases its low word; the example catches `00a7:0004d5c4` only
because CS and the narrow late-run interval jointly qualify it. The default
mode, without `--live`, is the safer pre-load procedure: it holds the core,
clears a previous sticky freeze, and arms before the daemon loads/releases the
guest.

After a match, the sticky freeze holds the guest reset and cannot be resumed.
First archive `trap-status`, rings, and required RAM. Then reprogram the exact
same hashed bitstream before any clean rerun; merely disabling the comparator is
not a reset of the failed experiment.

On 2026-08-23 the earlier tools captured `CS:EIP=0018:00001105`, bytes
`66 67 c5 75 10`, and a correct old `ESP:SS=00003484:0033` call-gate pointer.
The subsequently repaired image crosses that location. A live, CS-qualified
comparator then captured vector 14 in the later Quake window and a repeatable
ASCII-zero stack overwrite. Exact old-blocker evidence is in
`fpga_verify_20260822/quake_final_log/README.md`; current repaired-image evidence
and fix guidance are in
`fpga_verify_20260822/quake_lds_repaired/README.md` and
`fpga_verify_20260822/IRQFIX_SILICON_AUDIT.md`.

The board-local `/tmp/ao486/qk_board_mon.sh` scans guest RAM/logs for this
signature. It is a useful monitor, but it is not source-controlled and must be
archived with its hash when used as evidence.

Use a direct retained transient service, not `ao486d | grep`: a shell pipeline
can report grep's exit instead of a failed daemon. Omit `--text`; normal
device-safe runtime logging is substantially smaller and can be filtered on
the host without affecting the daemon. After programming the correct image,
held-clock/identity checks and media/DDR preflight, a board-shell command shape
is shown below. First prepare a root-owned expected-hash manifest, in a
root-owned directory, from the accepted deployment receipts. It must pin the
input VHD, device-safe daemon, both ROMs, final raw `.bit.bin` and matched probe;
all manifest entries must use absolute board paths.
do not manufacture expected hashes from unchecked live files. Set
`quake_input_manifest` to that manifest's absolute board path. Preserve the
input VHD; run only its uniquely named writable copy. This example's 600-second
nominal loop budget is **not** a wall-time or completion prediction, and the
outer runtime bound must be recorded for the actual run.

The pinned device-safe CLI accepts this unsigned `--secs 600` cold path, not
legacy `--loadonly`. `--mem 16` validates only the backend setting: startup
still maps and scalar-clears **all 256 MiB** at `[0x60000000,0x70000000)`.
The earlier held scalar sweep is not qualification of that complete startup.

```bash
set -euo pipefail
: "${quake_input_manifest:?Set the root-owned current deployment manifest first}"
sudo sha256sum -c "$quake_input_manifest"
quake_run_dir=$(sudo mktemp -d /tmp/ao486/quake-cold-run.XXXXXX)
sudo chown root:root "$quake_run_dir"
sudo chmod 0700 "$quake_run_dir"
quake_unit="ventium-$(basename "$quake_run_dir")"
sudo cp --reflink=never /tmp/ao486/quake-cold-oct02.vhd \
  "$quake_run_dir/run.vhd"
sudo cmp /tmp/ao486/quake-cold-oct02.vhd "$quake_run_dir/run.vhd"
sudo sha256sum /tmp/ao486/quake-cold-oct02.vhd "$quake_run_dir/run.vhd"
sudo systemd-run --unit="$quake_unit" \
  -p Type=exec -p RemainAfterExit=yes -p PrivateTmp=no \
  -p KillMode=control-group -p MemoryMax=512M -p MemorySwapMax=0 -p TasksMax=32 \
  -p RuntimeMaxSec=8100s -p TimeoutStopSec=30s \
  -p "StandardOutput=append:$quake_run_dir/daemon.stdout" \
  -p "StandardError=append:$quake_run_dir/daemon.stderr" \
  -- /tmp/ao486/ao486d.device-safe-oct02 \
     --membase 0x60000000 --mem 16 --bios /tmp/ao486 \
     --hdd "$quake_run_dir/run.vhd" --secs 600
```

The launch returns before daemon completion. Later, only after independently
observing actual `MainPID=0`, record closure and read the logs:

```bash
systemctl show "$quake_unit.service" \
  -p InvocationID -p ActiveState -p SubState -p MainPID -p Result \
  -p ExecMainCode -p ExecMainStatus -p ExecMainExitTimestamp
sudo tail -20 "$quake_run_dir/daemon.stderr"
```

Do not use `--wait` or `--collect` for this retained unit. An outer timeout or
signal termination is a failed/unqualified run, not clean native completion.
Its main process is
closed only after observing `MainPID=0` plus actual exit properties; successful
`active/exited` is not a live daemon. Unexpected debug freeze can also make
this daemon return zero, so read/report `R_DBG_FRZINFO[31]`, CTRL and retained
logs; zero alone is not a guest pass. Avoid checking for closure with
`is-active`, which remains true after retained successful completion.

Do not run the normal `quake` probe concurrently: it rereads the entire disk
on every interval. If control-flow evidence is needed, use only a short read-only
`sample` run against the newest on-die PC-ring entry. After `ao486d` exits, run
the normal probe once; only `QUAKE TIMEDEMO COMPLETE` with exactly 969 frames is
an acceptance result.

Run the one-shot disk check only after actual daemon closure and a fresh
no-writer check, then sync and retain a stable closed VHD copy. A raw
`--allow-existing` result is not evidence of a fresh run: join the prelaunch
input hash, cold release, native exit, current bitstream/held-clock receipt
and closed-disk console checker. The dated deployment document describes the
strict current-candidate helper and capture provenance; do not certify a new
run using the historical image's markers or an old-source movie bundle.

### 11.4 Windows 95

Current known result: the procedure below passed on the repaired-fast
`l1bypown` image at 3.125029 MHz on 2026-08-23. The source-controlled detector
held `last_ar=0x001021c0` for all 1,500 samples, observed both idle EIPs
`0x1e5/0x1e6`, 553 live transitions, correct Windows IVT values, and an advancing
tick; the old `vga-text` DDR-aperture check read 2,000 zero cells. That does
not establish a blank VGA text screen on this platform, because B8000 is VGA
MMIO rather than guest DDR. This remains a headless control-flow proxy, not
rendered-pixel proof.

The board has `/tmp/ao486/w95fresh.vhd`; it is a sparse, mutable 2 GiB image.
Restore it from the local pristine sparse backup before a reproducible run:

```bash
rsync -S --inplace -e "ssh -F $SSH_CONFIG" \
  "$FLOW/disk-backup/w95fresh.pristine.vhd" \
  "$BOARD:/tmp/ao486/w95fresh.vhd"

ssh -F "$SSH_CONFIG" -t "$BOARD" \
  'sudo /tmp/ao486/ao486d --membase 0x60000000 \
     --bios /tmp/ao486 --hdd /tmp/ao486/w95fresh.vhd --secs 21600 --text' \
  |& tee win95-board.log
```

`scripts/restore_w95.sh` performs the same sparse-aware restore but contains
fixed credentials/host values; the explicit command is preferred.

The current headless hardware flow has no connected video output. The best
available automated proxy is the board-local `/tmp/ao486/w95det.py`, which
samples for the known desktop-idle EIP/fetch-region signature. Treat that as a
control-flow proxy, not as proof of a correctly rendered desktop. Stronger
evidence would require adding a reproducible framebuffer/video capture path.

Expected lower-level signs include:

- BIOS reports an HDD and the BDA hard-disk count becomes at least one;
- a valid `0x55aa` boot sector is loaded at guest `0x7c00`;
- IDE read/write counts advance without uniform/corrupt data warnings;
- the core continues retiring after protected-mode entry;
- no workaround-only `FLUSHWD`/rescue path is required.

## 12. Available tools

### Host-side flow tools

| Tool | Purpose | Important caveat |
|---|---|---|
| `hw/create_project.tcl` | Creates BD, synthesizes, implements, writes `.bit`/raw `.bin` | Hard-coded paths; only `bd` and `all` are useful modes |
| `sw/Makefile` | Cross-builds static AArch64 `ao486d` | Pulls PS sources from the Ventium tree |
| `scripts/deploy.sh` | `smoke`, `post`, `trace`, `quake`, `win95` orchestration | HDD source paths are absent; dense `scp` is unsafe for Win95; current host SSH config blocks it |
| `scripts/deploy_nohdd.sh` | Programs/runs while reusing a board-staged HDD | Correct disk strategy, but current host SSH config blocks it until repaired/patched |
| `scripts/restore_w95.sh` | Sparse restore of pristine Win95 image | Fixed credentials/host; explicit `rsync -S --inplace` is cleaner |
| template `scripts/bit2bin.sh` | Converts an ordinary `.bit` to raw `.bit.bin` | Not needed for this flow's already-generated `.bit.bin` |
| template full build | Rebuilds XSA, DT, boot chain, kernel, rootfs, SD image | Platform recovery/change only, not normal PL iteration |

### Reference-template recovery tools

These commands belong to `$TEMPLATE`, not to the normal Ventium PL iteration.
They are relevant when rebuilding or repairing the board's PS/Linux platform:

| Command | Output/use |
|---|---|
| `make sources` | Fetch pinned Xilinx bootloader, kernel, and device-tree sources |
| `make hw` / `make hw MODE=xsa` | Rebuild the template example hardware/XSA; not the Ventium PL |
| `make devicetree` | Generate `system.dtb` with overlay symbols from the selected XSA |
| `make boot` | Build bitstream-free `BOOT.BIN` by default |
| `make kernel` | Build the Linux 6.12 image and modules with FPGA-manager support |
| `make rootfs` | Build the Debian/Ubuntu AArch64 root filesystem |
| `make sdcard` | Assemble the boot and root partitions into `sdcard.img` |
| `make all` | Run the platform pipeline using the template's golden XSA; it does not run `make hw` |
| `scripts/bit2bin.sh FILE.bit` | Convert a normal Vivado bitstream for FPGA-manager loading |

Do not substitute `make hw` in the template for the Ventium build in section 8;
the actual Ventium block design is generated by `$FLOW/hw/create_project.tcl`.

### Board-side platform tools

| Tool | Purpose |
|---|---|
| `/usr/local/bin/load-bitstream.sh FILE [--partial]` | Programs PL through FPGA manager/PCAP |
| `/usr/local/bin/load-bitstream.sh --status` | Reports FPGA-manager state |
| `/sys/class/fpga_manager/fpga0/state` | Direct manager state (`operating` is necessary, not provenance) |
| configfs overlay `rk-fpga-full` | Runtime `&fpga_full` region/firmware binding |
| `dtc` | Builds the temporary overlay used by the loader |
| `/dev/mem` | MMIO and guest-RAM mapping used by root-only daemon/diagnostics |

There is no `devmem` utility on the inspected image. Use the daemon or the
existing Python `mmap` diagnostics instead.

### `ao486d` modes

The following table describes the historical diagnostic daemon, **not** the
clean profile. Diagnostic options cannot be used to claim clean acceptance.

| Option | Purpose |
|---|---|
| `--ident` | Read IDENT, status, control, and basic debug state; does not initialize/run the guest |
| `--bios DIR` | Directory containing `boot0.rom` and `boot1.rom` |
| `--hdd IMAGE` | Mount image as primary-master HDD |
| `--membase 0x60000000` | Must match the PL guest-RAM base |
| `--secs N`, `--text` | Run duration and VGA-text dump |
| `--loadonly`, `--peek`, `--peekrun` | Controlled memory/load diagnostics |
| `--trace`, `--freeze`, `--tracesecs` | Ring/freeze diagnostics |
| `--cmpcfg`, `--cmprng` | Retire comparator diagnostics |
| `--inject-keys` | PS-side BIOS-keyboard-buffer injection plus cache flush; diagnostic, visible only to BIOS-buffer consumers |
| `--stall-flush` | Stale-line watchdog workaround; never a correctness pass |

### Clean board-daemon profile (October 2: offline qualification only)

[The reusable patch](fpga/patches/ao486d-clean-admission-20261002.patch)
targets `$FLOW/sw/board_shim.cpp` with original SHA
`e92326c629183330a4d05745a2f9b2e7268ca0e3217d47228e768fb705a71740`.
Its qualified result has SHA
`e5a378f9d2960dbad583dd04df05e38f3ae5049d0e5d0fb4b2a0ed7faaa5150e`.
The canonical external flow remains unchanged; the tested build used an
isolated source copy. Check the exact source pin and patch applicability before
preparing another copy. Do not apply it to a running verification input.

The profile removes the default BDA LED rewrite/cache flush, rejects intervention
flags/environment, requires an operating FPGA manager, rejects guest-DDR overlap
with System RAM, and makes `--ident` control-only. It validates ROM/media geometry,
tracks complete startup ROM reads, and keeps reset held on startup failure.
Shared-memory callbacks now check lower bounds and the complete transfer extent
before forming pointers or copying; null buffers and overflow/underflow are
rejected. Cold mode requires explicit `--bios` and `--hdd`; `--mem` accepts only
**16**, matching the unchanged backend, not the full-PC simulation's 32 MiB.
Compile without `VEN_IDE_RB_DIAG`; the original diagnostic Makefile is unsuitable.

The final static AArch64 ELF at
`/var/tmp/ventium-fpga-quake-oct02.rc0wVn/clean-daemon/build-cross.89xNA1T6/ao486d.clean`
has SHA `3feafe09a07b397cec4a61b435383f8c603f6e60db267e10958388ccad3e931c`.
It compiled/linked successfully and was **never executed**. The
[host-only fixture](fpga/board-tools/tests/test_ao486d_clean_guard.cpp) passed
**135 cases**, with actual native exit0 and no OOM; it interposes all 31 declared
I/O entrypoints and links no real PS backend. It deliberately uses fake ROM,
media, manager, memory-map and MMIO state: neither that test nor the ELF build
proves physical reservation, cache coherence, guest boot or timedemo completion.
For reproduction, place the byte-exact fixture under an isolated `tests/`
beside the patched `src/board_shim.cpp` and pinned `src/ps/` inputs; never
execute the production daemon as a unit test. Exact commands, wrap list, waits
and proof limits are retained in that leaf's `README.md`,
`qualification-receipt.json` and `build-host.IKHMZFGU/`.

Dependency/header and static-library hashes observed after compilation establish
post-build stability only, not loaded-header ancestry. Runtime IDE media-error
handling and attach mode remain outside this gate. The board's missing RAM
reservation, administrative access and image/register/clock compatibility must
still be resolved before hardware use. No FPGA rebuild is implied by this
PS-side software preparation.

`ao486d` must run as root because it maps `/dev/mem`.

### Source-controlled board workload probe

`fpga/board-tools/ven_board_probe.py` is paired with the current debug map. Its
workload probes are read-only. `quake --precheck-only` proves that a disk contains no
pre-existing result without touching PL MMIO. Normal `quake` monitoring accepts
only an exact 969-frame result. `win95` requires the known VMM last-AXI-AR proxy
and idle-EIP signature, transitions between both idle EIPs, and an advancing
BDA tick before printing `DESKTOP SIGNATURE PRESENT`. Register `0x70` is not a
live fetch PC; it holds the last accepted AXI read address, so this remains an
empirical signature rather than a direct proof of the currently executing
instruction. Every MMIO mode first requires
FPGA-manager state `operating` and then validates `IDENT=A0486501`.

`quake-progress` is also read-only: it translates Quake linear symbols through
the live guest CR3 and reports the timedemo counters. `trap-cwsdpmi-exception`
is intentionally not read-only end-to-end; it scans RAM without writes, then
pulses external freeze after a full exception record appears. It requires an
observed clear scan first, but retained/noncoherent DDR still makes it unsafe to
arm blindly across a previous frozen run. `trap-quake-fault-frame` is the
dedicated patched-Quake diagnostic trigger: it recognizes the logger's stores
in both DDR and the core-observation ring, so it remains useful when L1 hides
the store from a raw DDR read.
`trap-pe-exit` and `trap-protected-exit` likewise use the external freeze: the
former catches a delayed CR0.PE 1->0 transition, while the latter waits for an
audited protected-mode selector and catches a silent return outside its
selector allow-list. `dump-ring` requires a frozen trace unless `--allow-live`
is explicit. Treat these as paired forensic trigger/readout tools, not as
acceptance instrumentation.

### Passive video capture: whole-record stop

The matching client supports `vga-capture --stream --stop-on-sigusr1`.
Send **one SIGUSR1** to the verified live capture main PID after the required
endpoint has been recorded. It finishes any in-flight frame and its output
before stopping; it does not abort the FPGA recorder or touch guest RAM.
Timeouts, MMIO faults and broken pipes remain failures. Keep an outer deadline:
the stop request cannot interrupt a blocked drain/write. SIGINT/SIGTERM are
not equivalent clean-stop requests, and closing a mapping does not cancel
the recorder's arm W1P.

The raw stream still declares the original requested quota. Retain that raw
file and actual exits; normalize only complete validated records. A clean
stop, quota exhaustion or codec pass is not full timedemo/movie acceptance.
For a clean full-movie claim, require actual producer **and** reader exits 0,
the fresh closed-disk 969-frame result, a start-before-gameplay anchor, and an
end-after-demo anchor. One end anchor uses only existing records: retain the
board daemon's `ExecMainExitTimestampMonotonic` (positive microseconds, normal
exit/status 0), find an accepted record whose board `host_monotonic_ns` is
later, then retain its **successor** before requesting SIGUSR1. The first
timestamp is taken after BRAM drain, so that record alone might depict an
earlier raster; its successor is armed only after that timestamp/write/flush
and therefore depicts a post-closure raster. Require the same board boot and
CLOCK_MONOTONIC namespace: record `/proc/PID/ns/time` against board PID 1 while
the producer is live, and preserve its unchanged PID/invocation. Host SSH
timestamps are not substitutes. If this kernel omits `/proc/PID/ns/time`,
do not infer a namespace match from two missing paths: require the live
producer PID and retain the running kernel's `/proc/config.gz` evidence that
`CONFIG_NAMESPACES` or `CONFIG_TIME_NS` is disabled. The October 7 board has
`CONFIG_NAMESPACES` disabled, so all processes use the global monotonic clock.
Review the capture-completion-cycle span and
maximum gaps separately: this causal endpoint does not prove the first gameplay
frame or gap-free scanout. Ensure quota/deadline permits the successor record.
Tests: `python3 -B fpga/board-tools/test_ven_board_capture_stop.py` (native
POSIX signal delivery with mocked MMIO/transport, not board qualification).

### Hosted PS/2 keyboard device

The original board wrapper ties both keyboard pins high, so `--inject-keys`
only alters the BIOS Data Area and is invisible to software such as Quake that
reads the 8042/IRQ1 path directly. Patch
`fpga/patches/0003-hosted-ps2-keyboard.patch` adds a versioned, device-side
PS/2 endpoint. It serializes ordinary Set-2 make/break bytes over the existing
8042 pins; it does not write guest RAM, alter the disk, or patch guest code.

Apply the patch after the passive-capture patches to `$FLOW`, build and deploy a
matching image, then copy the matching board probe. The probe refuses to send
any byte unless the hardware capability at `0x3a0` is `0x564b0001`.

```bash
cd "$VENTIUM"
git -C /home/yukidama/github/ao486_MiSTer apply --check fpga/patches/0003-hosted-ps2-keyboard.patch
git -C /home/yukidama/github/ao486_MiSTer apply fpga/patches/0003-hosted-ps2-keyboard.patch

env CCACHE_DISABLE=1 verilator --binary --timing -Wall -Wno-fatal \
  --top-module ven_ps2_kbd_inject_tb -Mdir /tmp/ven_ps2_kbd_inject_tb_obj \
  fpga/ven_ps2_kbd_inject_tb.sv \
  "$FLOW/src/ven_ps2_kbd_inject.v" \
  3rd-party/ao486_MiSTer/rtl/soc/ps2.v \
  3rd-party/ao486_MiSTer/rtl/common/simple_fifo.v && \
  /tmp/ven_ps2_kbd_inject_tb_obj/Vven_ps2_kbd_inject_tb
```

After programming, use the normal device transport, not `--inject-keys`:

```bash
sudo /tmp/ao486/ven_board_probe.py ps2-keys '~timedemo demo1' --enter
```

`ps2-keys` accepts the lowercase ASCII map used by the simulation keyboard;
`ps2-raw` sends deliberate raw Set-2 bytes for diagnostic keys. Each command
waits for the one-byte hardware transport before issuing the next byte, so it
cannot silently reorder a make, `f0`, break sequence. It remains an operator
input facility, not a correctness oracle: acceptance still requires the
unmodified disk's exact 969-frame timedemo result.

### Frozen forensic capture and simulation replay

The source-controlled probe now provides a capture bundle for a **frozen**
execution.  It records the current debug CSRs, counter values, the complete
128-entry architectural PC ring, the paired core/L1 observation ring, and any
explicitly selected physical guest-RAM ranges in a versioned `manifest.json`.
It refuses to mix a live CPU with RAM/ring reads unless `--allow-live` is
supplied, and refuses to overwrite an existing destination.  Copy the bundle
off the board before the next run: the board's root filesystem is small and a
freeze is sticky.

```bash
# Run only after a trap has frozen the CPU.  The first range keeps IVT/BDA/DOS
# state; the second covers the historical protected-mode stack-fault window.
sudo /tmp/ao486/ven_board_probe.py capture \
  --output /tmp/ao486/capture-$(date +%Y%m%d-%H%M%S) \
  --range 0:0x100000 --range 0xe0000:0x20000

# A one-off high-RAM dump is read-only and is useful for a page discovered from
# CR3/PDE/PTE inspection.  Copy the output off-board with scp afterwards.
sudo /tmp/ao486/ven_board_probe.py dump-ram \
  --start 0xe0000 --length 0x20000 --output /tmp/ao486/stack.bin

# Separate from the architectural PC ring: core/L1 address/data observations
# with retire/INTA/FSM metadata sampled at the same ring index.
sudo /tmp/ao486/ven_board_probe.py dump-core-ring --depth 128
```

`--full-ram` deliberately captures all `--ram-size` bytes (16 MiB by default),
but should only be used after checking free space and arranging an immediate
copy to the host.  A capture is an evidence bundle, not a claim of complete
architectural state: the deployed bitstream does **not** expose GPRs, segment
descriptor caches, CR2/CR3/CR4, debug registers, x87 state, cache/TLB content,
or in-flight bus/pipeline state.  The manifest names these unavailable fields
explicitly so an offline analysis cannot confuse absent data with zeros.  A
debug image advertises the latched freeze-context frame with
`0x56440001` at read offset `0x200`; only then does the probe include
`{CS,EIP,ESP,EFLAGS,fault_PC,CR0,state,vector}`.  Any other read value means
that frame is unavailable, not that the machine state is zero.

There is no true FPGA single-step or restore operation in the **deployed**
debug fabric. A comparator or external freeze is one-way and holds the guest;
it cannot resume the captured state. Replay therefore happens in source-matched
Verilator, which already serializes the SoC, guest DDR, DDR read FIFO/write
burst state, and Verilated RTL state:

```bash
cd "$VENTIUM/ao486-sim"

# Take a baseline only at a quiescent point: after POST and outside an IDE/FDD
# transaction.  Re-use the exact disk and executable build for restoration.
./obj_dir_ven/ao486sim_ven --ide /path/to/qk_td.vhd \
  --save-at 250000000 --save-file quake-baseline.snap --cycles 300000000

# Iterate from the saved state rather than cold-booting.
./obj_dir_ven/ao486sim_ven --ide /path/to/qk_td.vhd \
  --restore quake-baseline.snap --cycles 600000000
```

`--save-every N` makes cycle-stamped periodic simulator snapshots. Snapshot
files are build- and model-specific; do not restore them after RTL, Verilator,
or harness-layout changes, and do not treat an FPGA RAM capture as a simulator
restore file. This is a hardware change, not something a board-side `/dev/mem`
script can emulate.

For a direct cold-boot forensic window that does **not** use a save-state, build
an isolated trace-enabled cosim directory and request a bounded architectural
retire trace. `VERILATOR_BUILD_JOBS` is explicit so this diagnostic build cannot
silently consume all host cores; the canonical `obj_dir_ven` remains untouched:

```bash
make -C "$VENTIUM/ao486-sim" ven \
  VEN_OBJDIR=ao486-sim/obj_dir_ven_diag \
  VEN_EXE=ao486sim_ven_diag VERILATOR_BUILD_JOBS=4

cd "$VENTIUM/ao486-sim"
./obj_dir_ven_diag/ao486sim_ven_diag --ide /path/to/qk_td.vhd \
  --cycles 43000000 --vtm-dump-start 422000 --vtm-dump 4096 \
  2> retire-window.log
```

`--vtm-dump-start` is the absolute post-reset retirement number and
`--vtm-dump` is the maximum number of `VTM` records. Omitting the start captures
from the first retirement. The trace reflects a source-matched simulator build,
not FPGA state, and is a diagnosis aid rather than an acceptance result.

### Quiescent execution debugger (deployed 2026-10-04 image)

The deployed 40 MHz debug image advertises `0x56450005` at read offset `0x2c0`. It routes
the core's existing debug hold mechanism to AXI-Lite; it does **not** gate the
PL clock and does **not** assert the forensic `frozen` reset. `halt` parks at
the next quiescent issue boundary: either `S_DECODE` on the slow path or
`S_PIPE` on the dual-issue fast path, or an already-idle `S_HLTWAIT`. The park
uses one shared issue-block
predicate, so it suppresses all fast-path mirrors together (GPR/x87 writeback,
BTB/L1 metadata, and speculative memory requests). An already-issued
multi-cycle or pipelined x87 operation is allowed to complete; HALTED is not
reported until its deferred architectural writeback has drained. Pending
SMI/NMI/INTR requests remain pending and are delivered after `run`; a host
`step` deliberately defers them until its one requested instruction retires.
An interrupt pending while a manual halt owns `S_HLTWAIT` is not acknowledged
until `run`, so no PIC event is silently consumed by the debugger.

After deploying a bitstream carrying that capability and copying the matching
probe to the board, use this workflow:

```bash
# Safe halt: no guest reset and no global clock gate.
sudo /tmp/ao486/ven_board_probe.py halt --timeout 5

# Full integer/system state at the parked boundary. This leaves the core halted.
sudo /tmp/ao486/ven_board_probe.py dump-state

# Execute one *retired instruction* and park again. A REP instruction is one
# architectural step even if its microcode takes a long time to retire.
sudo /tmp/ao486/ven_board_probe.py step --count 1 --timeout 30

# Pre-issue full-32-bit EIP breakpoint. --wait prints the same stopped state.
sudo /tmp/ao486/ven_board_probe.py breakpoint 0x00002bd2 --wait --timeout 30

# Disable the breakpoint, clear its sticky latch, and resume normal execution.
sudo /tmp/ao486/ven_board_probe.py run
```

`dump-state --halt` combines the first two operations. The probe refuses all
execution-control commands unless `0x2c0` carries the capability marker, so a
new host tool cannot accidentally operate an older image. A step is accepted
only after a verified halt and the probe checks that exactly one retirement
occurred before the core re-parks. It forcibly suppresses U/V pairing (including
the special folded x87 `FLD; FXCH` case); a breakpoint at a candidate V slot
also suppresses that pair so the requested EIP stops before it executes.
Single-step deliberately does not manufacture an instruction from an
already-idle `HLT`: leave the core stopped until an external event is intended,
then use `run` rather than expecting a step to wake it.

The selector state dump stays deliberately compact: a seven-bit selector and
one 32-bit data word keep the wrapper interface narrow, while a halted dump
includes EAX..EDI, about-to-issue EIP, EFLAGS, CS/SS/DS/ES/FS/GS, CR0..CR4,
DR0..DR3/DR6/DR7, and the complete x87 physical stack. Each 80-bit physical
FPR is read as three words; the host probe uses the captured TOP and tag bits
to print both the physical slots and logical `ST(i)` view, explicitly marking
EMPTY slots. It also returns x87 control/status/tag and FIP/FDP/FCS/FDS
environment pointers, every segment's hidden base/limit/access/B-bit cache,
GDT/IDT base and limit, and the complete LDTR/TR descriptor caches (selector,
base, limit, validity, and TR access byte). It is not a full internal scan:
cache/TLB arrays and in-flight bus/pipeline state remain unavailable. The
last selector also reports whether the current stop was a manual halt,
breakpoint, or completed single-step.
The older freeze-context page at `0x200` remains the right tool for a terminal
forensic event; `capture` still requires that sticky freeze and should not be
used to claim a halt-state RAM snapshot is atomic.

#### Using the debugger to localize a real failure

The 2026-10-04 investigation intercepted an invalid Quake EIP **before** its
instruction executed. First archive `dump-state`, then the primary PC ring
(`dump-ring --allow-live --depth 128`) while HALTED remains set. `--allow-live`
here means the separate forensic-freeze bit is clear; it does not make a ring
read atomic while execution is running. A quiescent `dump-ram` is a DDR image,
not a scan of dirty cache contents, TLBs or admitted transactions.

For a suspected CMP/Jcc pair, use two different controls:

- Single-step from the CMP and record each returned EIP/EFLAGS. This deliberately
  disables pairing, so success establishes only the **unpaired control**.
- Re-arm a different breakpoint at the expected next U boundary to resume
  normally. Record the primary retirement delta and ring history. A breakpoint
  matching the V instruction suppresses the very pair being investigated.
  Check CS as well: the hardware breakpoint matches EIP only.

The FPGA PMU and PC ring count **primary/U retirement only**, not total U+V
instructions. An uninterrupted paired CMP/Jcc should increment that counter by
one and leave the CMP as the newest primary PC. A separately recorded Jcc or
intervening handler means this is not that clean paired experiment. For example,
one `14562 → 14567` resume on 2026-10-04 retired 236 primary instructions and
visited CWSDPMI: its correct fallthrough did **not** validate a direct pair.

For a lower-overhead control, keep one board-local MMIO mapping open. At the
first halt hold manually with `DBG_EXEC=0x001`, program/read back the expected
next U EIP, leave the architectural selector on EIP, then release with the
single ordered `DBG_EXEC=0x202` write. Poll HALTED and EIP in that same process;
do not require observing HALTED fall, since an immediate re-park can be shorter
than the PS read interval. Reject a still-stale original EIP. Grade only the
new target, unchanged CS/CR3, primary delta 1, IRQ-ACK delta 0, and newest CMP
ring entry. This remains an inferred boundary witness: no CSR exposes direct
V retirement. The pre-CMP halt drains FP work and clears AGI bookkeeping, so
even a clean pass does not refute the natural uninterrupted failure.

Guest x86 DR breakpoints, TF and RF also force the slow/unpaired path in this
profile. They are not alternatives for observing this pair. Do not clear
`CTRL[8]` to suppress guest IRQs: it gates **PS disk-service notification**,
not PIT/PIC/core INTR. Pending guest IRQs continue to accumulate while halted.

Do not interpret `dump-core-observe-ring` as a branch waveform in this image:
the frozen tap records acknowledged **VGA-text writes** only. Neither ring
exposes decoded lengths, raw I-cache bytes, branch decisions or forwarded flags.
Also, the JSON CS `b` field reports `seg_b[CS]`, not the separate effective
`cs_d` used by decoding; interrupt entry can update the latter without updating
the former. A descriptor/default-size mismatch in that field alone is not proof
that the handler decoded in the wrong mode.
The ring's `real_mode_linear_if_applicable` (printed as `lin`) is only
`(CS << 4) + EIP`; it is **not** the protected-mode segment-base-derived
linear address. Use the hidden CS base and paging tables for that calculation.

Keep breakpoint/single-step tests separate from acceptance. This investigation
used a private diagnostic ROM on the unchanged FPGA, preserving the production
ROMs and media; a diagnostic pass is not a cold Quake timedemo pass. Do not use
the intrusive comparator/forensic freeze to resume a stopped guest: it drives
SoC reset, unlike the quiescent debugger.

Before a hardware build, run the focused AXI-Lite regression from the host. It
also verifies that a `STEP` command cannot alias the old ring-clear command:

```bash
iverilog -g2012 -s ven_mgmt_debug_tb -o /tmp/ven_mgmt_debug_tb.vvp \
  /home/yukidama/github/ao486_MiSTer/fpga/rk-ao486-system/src/ven_mgmt_axil.v \
  fpga/ven_mgmt_debug_tb.sv && vvp /tmp/ven_mgmt_debug_tb.vvp
```

`fpga/board-tools/ven_board_trace_arm.py` is the paired, deliberately small
write utility for the raw retire comparator. Its default mode holds the core,
clears the sticky debug freeze/rings, and arms before guest load. `--live` is the
late-window mode documented in section 11.3: it requires an already-running,
non-frozen core, preserves rolling prehistory, writes the range while disabled,
and enables/freeze-arms last. It accepts only a 16-bit CS plus an optional
16-bit EIP range; it is not a general MMIO writer. Invoke the copied file with
`python3` so deployment does not depend on its executable bit.

`vga-text` reads the *DDR aperture* at B8000 and reports printable/nonblank
bytes. It is not a rendered-text capture: on the deployed ao486 platform,
B8000 is a VGA device mapping, so all-zero DDR data says nothing about the
visible display. Do not use it as Win95/FreeDOS visual evidence.

`vga-ring-text --depth 128 --allow-live` is a separate, explicitly sparse
best-effort decoder for recent core-side B8000 accesses. It writes only the
debug ring's read-index selector, restores it to zero before returning, and
never changes guest memory or execution. Its output is useful for a recent
prompt or error (the 2026-08-29 run reconstructed `C:\QUAKE>`), but is not a
framebuffer and must not be presented as an image. Use `vga-capture` for a
passive rendered-pixel frame; its 512-KiB RGB332 private BRAM holds a complete
720x400 text scanout (288,000 bytes) as well as Mode 13h. Larger modes report
overflow rather than emitting a truncated image.

For the current frontend-factored candidate and whole-record SIGUSR1 closure,
use `/tmp/ao486/ven_board_probe.sigusr1-oct03.py`, SHA-256
`fd0a83fe16ab6ccce42d6adcaef971c740119326932ec478d21b0393e33c5f68`.
The older `/tmp/ao486/ven_board_probe.wide-oct02.py` has the matching widened
capture ABI but lacks `--stop-on-sigusr1`; do not use it for this workflow.
Retain its separate frozen hardware-ancestry pin (`cd2842…`) in provenance,
and do not use either widened client to certify the historical August image.
Verify the final bitstream/source/client identity and held clock before capture.
The October6 startup-filter client is separately installed as
`/tmp/ao486/ven_board_probe.startup-r2.py`, SHA-256
`426f793fb280133fd35ea19ed37e9229dd4f54badcc6562ac0176ddad6cffa0d`.
With explicit dimensions and `--skip-unmatched`, it can discard malformed
**non-requested** startup rasters before the first accepted requested frame,
without draining or emitting their payload. The retry phase is bounded.
Malformed requested-mode frames, impossible metadata, and metadata errors
after accepted capture starts remain fatal. Its26 mock/signal tests pass;
that is not hardware/timedemo qualification. Keep the older client and its
receipts intact and use separately re-pinned movie helpers for the new client.
The separately pinned `ven_board_probe.startup-r3.py` additionally permits
an **all-zero** pre-target raster: the recorder can complete a VSYNC interval
with no active video during mode setup. Partial-zero metadata still fails.
Source SHA-256 `8ff672d0af63ecc18b8519b6e7fdfe2f1137c9284b7eeb99867b28de0012b6a3`;
its28 tests pass. This client retrieves a complete320x200/64,000-pixel board
frame, but a single post-run image is not a full timedemo movie.
The subsequent generic client permits an exact`0x0/pixels0` empty interval
also after accepted capture starts: display blanking is not a malformed image.
With explicit dimensions and`--skip-unmatched`, it re-arms without reading
stale BRAM or emitting a replacement frame. A bounded consecutive-gap deadline
also limits later capture waits and resets only after a complete requested
image. Partial-zero metadata, nonempty post-start corruption and transport
errors still fail. All33 tests pass; source SHA-256
`9b60a741522dc6519ace852d4e338fc09cbcafd12d6e3c5167cdd1532984c8cd`.
Historical client pins/receipts remain unchanged; install this under a new
name and re-pin its movie helpers instead of overwriting closed-run tools.
The October6 original-media diagnostic completes969 frames at measured37.5MHz
and yields6,505 validated recording samples. The full raw-colour15fps movie
and exact-palette GIF are verified back to the captured RGB sequence; the GIF
is the README hero. This **does not qualify40MHz**, which retains the separate
CMP/Jcc defect. See the [closed capture evidence](docs/FPGA_CMP_BRANCH_LOCALIZATION_2026-10-05.md#completed-cold-recording-r4).
Use canonical scratch paths for the receipt-bound movie helpers when
`external/tmp` is a symlink. Bound FFmpeg input/output codec threads and filter
threads explicitly;`MALLOC_ARENA_MAX=2` allows the installed encoder stack to
run under the same512MiB address-space cap without thread-allocation failure.
Generate a full-source palette in a separate pass, then apply it without
dithering; buffering an entire full capture behind one split/palette graph is
unnecessary. No gamma, contrast, brightness, dimensions or frame-rate change
is used. Keep raw streams, closed producer/transport statuses and decoder
hashes; a movie is not proof of every physical/engine frame or workload
acceptance at a different core clock.
Stream binary pixels over
non-PTY SSH to a host-owned run directory rather than accumulating frames on
the board. Root's two actual-board synthetic FIFO tests passed byte integrity
and correctly exposed producer failure after consumer loss; they are transport
tests only, not hardware captures. Their receipt and exact pins are recorded
in `docs/FPGA_QUAKE_DEPLOYMENT_2026-10-02.md`.

The current host capture workspace is
`/home/yukidama/external/tmp/ventium-fpga40-capture.VMIAgs/`.
Its `bundle/` contains source-only derivatives of the candidate-bound
normalizer, movie assembler and closed-console checker. The only source
changes are storage guards: new raw captures, closure receipts, normalized
streams and movies must lie beneath this resolved external directory. The
console checker still reads its separately pinned historical baseline; that
baseline and all candidate/tool hashes are unchanged.
Do not write a new raw stream under `/var/tmp` and normalize across filesystems:
raw retention deliberately uses a hard link. Capture directly into external
storage, then normalize and assemble there. These helpers preserve source
colors/dimensions and each accepted record, with byte-exact FFV1/RGB verification
and **15 fps** presentation; they do not establish full temporal coverage.
Independent and root bounded synthetic microgates exited zero after this
relocation. The root rerun replaced the runner's fixed microtest log, so use
`root-helper-verification.json` for the current log/hash binding; the original
`derivative-receipt.json` retains source ancestry and historical test context.
No hardware frames, native timedemo or movie acceptance is asserted by either
host receipt.

Start the FIFO reader first. Run the producer directly in a retained root
transient service (`Type=exec`, `PrivateTmp=no`, `RemainAfterExit=yes`, separate
stdout/stderr, bounded `TimeoutStartSec` and `RuntimeMaxSec`). Omitting
`--collect` alone does **not** retain a successful transient unit. Do not use
`--wait` with `RemainAfterExit`; observe actual main exit, then reader EOF/exit,
and record both before cleanup. A retained `active/exited`, `MainPID=0` service
is closed, not a live capture. A header or successful SSH reader can coexist
with a failed producer and is not acceptance. The real producer needs
`--frame-timeout 600`; choose its total running-service bound separately to
cover cold startup, workload and closure margin. Keep all colors, dimensions,
and accepted records unchanged; 15 fps is the movie presentation rate, not
measured gameplay FPS or a capture-rate limit.

There is no reliable positive pre-release arm acknowledgment in this capture
ABI. `CAP_STATUS.ACTIVE` excludes the private pending-arm latch, and holding
the core also resets the SoC/VGA, preventing the VSYNC edge that starts capture.
Do not wait for ACTIVE/READY before releasing a cold guest. Record the initial
status, start the FIFO reader and producer, check the producer is still live
with no early error, then release before its frame timeout. Require READY with
a changed sequence after release; neither the stream header nor a live service
PID proves that the hardware accepted an arm. This ordering does not prove
capture of the very first physical raster or every engine frame.

For final timedemo disk evidence, use the separately audited closed FAT-console
procedure in `docs/FPGA_QUAKE_DEPLOYMENT_2026-10-02.md` ("Separate closed
FAT-console evidence"). It reads the actual QCONSOLE file through the held
original VHD descriptor, not deleted raw clusters, and compares against the
immutable pre-run console. The old log already contains a demo1 marker but no
result; that marker alone cannot establish fresh playback. Fourteen focused
host tests pass, including pathname substitution, bounded parsing, malformed
numeric records and cross-line regex false positives. These are verifier
tests, not a hardware timedemo. Its exit 0 validates **console evidence only**;
native closure, cold reset, no snapshots, exact image/source/clock identity and
full movie coverage still need independently observed root evidence. Never
manufacture simulator log grammar to make the simulation-only checker pass
an FPGA run.

Its `perf --seconds N` mode reads the split cycle/retirement counters, AXI
event counters, state slots, I/O-cycle counter, and external-interrupt-
acknowledgement counter twice and reports raw interval deltas, measured clock,
IPC, and I/O ratio. It writes no control or ring-index register. Prefer this
source-controlled mode over volatile board-local performance scripts.

The checked `fpga/patches/0004-passive-axi-read-profiler.patch` image reuses the two invalid legacy state bins as passive outer-AXI timing counters. It observes only the existing 45 MHz `m_axi_*` handshakes: `0x1a0` is the sum of accepted-AR through accepted-RLAST occupancy cycles and `0x1b0` is the sum of accepted-AR through first accepted-R latency cycles. With `A=AR handshakes` and `B=read beats`, the residual inter-beat bubbles are `0x1a0 - 0x1b0 - (B-A)`. Read these counters only with the matching profiler bitstream:

```bash
sudo /tmp/ao486/ven_board_probe.py perf --seconds 5 --axi-read-profiler
```

The flag is deliberately opt-in so an older image is never relabeled as a latency measurement.

### DDRAM AXI write-channel correctness gate

The DDRAM-to-HP0 bridge must accept AXI write address (`AW`) and write data
(`W`) independently.  The historical bridge advanced to `B` as soon as the
final `W` beat handshook.  If an AXI clock converter accepted `W` before `AW`,
that left `AWVALID` asserted in `S_B` and could issue the same address more
than once while the response was delayed.  This is a correctness defect, not a
throughput shortcut.

Apply `fpga/patches/0005-ddram-axi-independent-aw-w.patch` to the external
flow, then run the directed gate before synthesis:

```bash
git -C /home/yukidama/github/ao486_MiSTer apply --check \
  fpga/patches/0005-ddram-axi-independent-aw-w.patch
git -C /home/yukidama/github/ao486_MiSTer apply \
  fpga/patches/0005-ddram-axi-independent-aw-w.patch
bash fpga/run-ven-ddram-axi-aw-w-gate.sh
```

The gate compiles the exact external `ven_ddram_axi.v` and proves AW-first,
W-first, simultaneous AW/W, and delayed-B cases.  Do not replace this with an
AW-first-only BFM: the downstream `axi_clock_converter` is permitted to skew
the channels.  The patch keeps the existing AW-first timing and enters `S_B`
only after both channels have handshaken, so it fixes protocol ownership
without adding a queue or hiding memory latency.

Two current wrapper defects constrain interpretation. The deployed feature set
numbers `S_PF=26` and `S_PIPE=27`, while `ven_soc_dbg.sv` hard-codes state 23
and 24 into offsets `0x1b0` and `0x1a0`; the probe therefore calls them
`fsm_slot_1b0`/`fsm_slot_1a0`, not PF/PIPE. Also, the wrapper ties
`io_pending` to zero, so `perf_io` is not a valid S_IO measure. Fix the hardware
by routing semantic state flags rather than copying feature-dependent enum
numbers. The PC ring samples `dbg_state` only on a retirement, so a moving ring
of state-27 entries means normal fast-path retirement in this build; it is not
a live FSM sample and must not be mistaken for the later F00F-hang enumerator.

The explicit `clock PROFILE` subcommand is one allow-listed write mode. It
accepts only audited `PL0_REF_CTRL` values rather than exposing a general
`/dev/mem` writer:

| Profile | Register | Intended use |
|---|---:|---|
| `iopll-93m` | `0x01011000` | 93.75 MHz PL / ~2.9297 MHz core; conservative fallback for the routed 95.456 MHz non-fast image |
| `iopll-100m` | `0x01010f00` | Restore the current 100 MHz IOPLL `/15` profile |
| `rpll-95m` | `0x01010b02` | Reproduce the Vivado PS preset only; not timing-safe on the inspected stock-Linux clock tree |

Run it only with `ao486d` stopped, then measure the resulting hardware counter
rate before accepting the image:

```bash
sudo /tmp/ao486/ven_board_probe.py clock iopll-93m
sudo /tmp/ao486/ven_board_probe.py perf --seconds 5
```

The other write modes are fixed on-chip forensic traps, not workload probes:

| Mode | Effect |
|---|---|
| `trap-zero` | Arms `cfg=0x000f0000`, range `0x00030000`; freezes on the first retired `CS=0,EIP=0..3` |
| `trap-badcs` | Arms a fixed `CS=0x3107` boot-derail comparator; this selector was observed once but is not deterministic |
| `trap-status` | Read-only report of the sticky freeze snapshot |

Comparator configuration bit 19 is the freeze-mode bit. A value such as
`0x00070000` can match without freezing; the `trap-zero` value is deliberately
`0x000f0000`. A trap holds the guest in reset after a match and is never valid
during a clean acceptance run.

### Board-local diagnostics

The following have been found under `/tmp/ao486` on earlier board boots. `/tmp`
is volatile; for example, `perf.py` was absent after the 2026-08-21 recovery.
They are useful when present but are not in the source-controlled flow, so
inspect and hash them before citing their output:

| Tool | Purpose |
|---|---|
| `perf.py [seconds]` | Interval cycles, retired instructions, IPC, stall, I/O, IRQ metrics; its expected-frequency text is build-specific |
| `stall.py` | Simple stall-percentage sampling |
| `hot.py` | Samples last-EIP and fetch pages to find hot loops |
| `ring.py` | Reads the PC ring; writes the non-destructive ring-index selector |
| `rdring.py` | Reads the build-specific auxiliary/debug ring; writes the same index selector |
| `w95det.py [samples]` | Win95 desktop-idle control-flow proxy |
| `qk_board_mon.sh` | Searches guest RAM for the Quake timedemo/FPS signature and rewrites its monitor log |
| `run_w95.sh`, `run_long.sh` | Long board-local orchestration |

The last two run helpers kill processes and reprogram the PL, and their comments
refer to old build labels. Prefer the explicit procedure above.

### Additional closed debugging checks (2026-10-04)

The existing debugger was used again without resetting, stepping, reprogramming
or changing the clock. `--ident` reported `STATUS=00000100`, `CTRL=00000102`
and an idle outer bridge. The halted architectural scan remained at
`00a7:14570`, CR3 `0007e000`, EAX `3`, with all x87 stack entries empty.
The separately retrieved 128-entry primary ring begins `1456b`, `14567`, then
the CWSDPMI interrupt-return path. This preserves the earlier **IRQ-contaminated
control**, not a new clean paired-CMP pass. Exports are in
`ventium-after-third-control.h1MOTw/held-{ring,state}-oct04-current.*` beneath
the external temporary directory. Their SHA-256 hashes are respectively
`196729b56114287a9ca9cb4d359c67b69ac1e2a9528ae63bef5522bee1d3cd59` and
`b444b77db3adebaf130b0e2e2627061e7ffaa6c2268a78559e8e63c869c5ae77`.
Both native probe exits were zero. Ring `lin` fields remain inappropriate for
protected-mode addresses; use the scanned hidden segment base and page tables.

The deployed daemon's existing `--attach --hdd ...` mode skips cold reset,
guest-RAM zeroing and BIOS loading. **Do not assume idle IDE status makes
reattachment transparent.** The newly created host backend defaults to 16
sectors per multiple operation and image-derived geometry; prior guest
`SET MULTIPLE` (`0xc6`) and `INIT DEVICE PARAMS` (`0x91`) settings are not
reconstructed. It also cannot recover a pending data-phase buffer. No attach
was launched for this held guest while those settings remain unknown. Never
use a normal cold daemon launch as a resume operation.

A bounded test of the exact frozen outer `ven_ddram_axi.v` completed with
native compile/runtime exits zero in `ventium-outer-ddram-response.jFLtzn`.
It checked held request addresses, discarded priming reads, second-read data,
and independently stalled AW/W channels. Its negative witnesses show that
second-read SLVERR/DECERR payloads are published as ordinary DDR data and a
write SLVERR releases BUSY: the adapter ignores RRESP/BRESP. This is a concrete
error-handling defect, **not evidence that HP0 returned an error in Quake**.
The test has no vendor CDC/width-converter/HP0 model and is not acceptance.

The positive backend comparison in `ventium-frozen-backend-path.omzmPt`
adds that exact outer adapter to the frozen master → Avalon bridge → platform
L2 path. Both behavioral RAM and Verilator's XPM-fidelity wrapper completed
48 line reads (384 checked words), all 16 byte-strobe patterns, and an exact
2048-word final backing-memory check. Both builds, native runs and the closed
consumer exited zero: identical 2,219 read clocks / 2,463 total clocks,
17 DDR commands, 34 outer ARs, 272 outer R beats, 136 forwarded DDR beats.
AW-first/W-first/simultaneous write counts were 6/5/5; AR stalls, gapped reads
and delayed write responses were exercised. There were 32 observed RAM
read/write-collision edges per case, zero collision results consumed without
the streaming bypass, and 80 bypass replies. This narrows the wrapper-collision
hypothesis **only for this stimulus**, not all cache or live-hardware cases.
All responses were OKAY and clocks synchronous; vendor CDC/width conversion,
HP0 and the full guest remain outside this test.

The first invocation failed before compilation because the runner supplied an
inconsistent installed `VERILATOR_ROOT`; both exits 1 and the not-launched
receipts remain intact. The separately named R2 runner unsets that variable
and uses the same pinned installed frontend's own root detection. It retained
the original RTL, TB and BFM unchanged, with two `-j2` builds in one fixed
10-GiB/64-task guarded scope, a 120-second outer deadline and 20-second native
runtime caps. R2 source-manifest SHA-256:
`4e9d9175880a81ca77538dc5ca3f8145ba05b42aab75519549be2ce0fbec141f`.
This is a directed diagnostic pass, not a Quake or FPGA acceptance pass.

The board also exposes four PS AXI performance monitors through root-only
`/dev/uio*`. The read-only capability scan in
`ventium-ps-apm-capability.teCx1O` completed with native exit zero. DDR monitor
`uio1` maps registers at `0xfd0b0000`; its six-slot advanced configuration
provides counters but no event log. Slot 3 combines HP0 and DisplayPort, so it
is neither an exclusive core traffic measurement nor an address/data trace.
Counters were disabled (`CTL=0`) and zero: **no latency or bandwidth result
was measured**. `SICR=0x100` enables reset on sample-register reads; avoid
reading sample offset `0x2c` during a passive scan. The second UIO mapping is
the kernel driver's parameter page, not a trace FIFO. No monitor configuration
was changed. These monitors do not expose AXI response-error classifications.
Register interpretation was checked against the primary
[Xilinx AXI performance-monitor register definitions](https://github.com/Xilinx/embeddedsw/blob/master/XilinxProcessorIPLib/drivers/axipmon/src/xaxipmon_hw.h)
and [Linux UIO driver](https://github.com/Xilinx/linux-xlnx/blob/master/drivers/uio/uio_xilinx_apm.c),
as well as the board's actual device-tree and read-only parameter page.

Candidate gameplay IPC remains unmeasured. The verified pre-candidate baseline
is **0.42633263**, build `5c2491f3`, cycles
`7,099,999,637–7,199,999,637`; none of these debugger or bus tests replaces
the pending native Quake timedemo/movie or standard-suite acceptance.

## 13. Custom debug/control register map

The AXI-Lite window starts at `0xA0000000`. Every implemented 32-bit register is
at a `0x10` boundary because other 32-bit lanes were observed to drop accesses
in this block design.

| Offset | Read meaning | Write meaning |
|---:|---|---|
| `0x000` | IDENT `0xA0486501` | — |
| `0x010` | management address | management address |
| `0x020` | control | bit 0 hold reset, bit 1 run, bit 8 PS disk-service notification enable (not guest IRQ masking) |
| `0x030` | auxiliary ring data high | management write data/pulse |
| `0x040` | management read data | — |
| `0x050` | IDE/FDD/core status | — |
| `0x060` | saturating DDR/AR/R counters and bridge state | — |
| `0x070` | last accepted memory-read address | — |
| `0x080` | last retired EIP | ring index, clear, external freeze |
| `0x090` | frozen flag/vector/state/count | freeze threshold |
| `0x0a0` | EIP at freeze | comparator configuration |
| `0x0b0` | PC ring EIP | comparator range |
| `0x0c0` | PC ring state/CS | — |
| `0x0d0` | auxiliary ring address | — |
| `0x0e0` | auxiliary ring data low | — |
| `0x0f0` | no-retire/stall counter | — |
| `0x100/0x110` | cycle counter low/high | — |
| `0x120/0x130` | retired counter low/high | — |
| `0x140` | intended cycles in I/O; tied to zero in the current wrapper | — |
| `0x150` | external interrupt acknowledgements | — |
| `0x160` | live CR0 | — |
| `0x170` | accepted AXI read beats | — |
| `0x180` | AXI AR handshakes, including priming reads | — |
| `0x190` | AXI B responses | — |
| `0x1a0` | legacy: invalid hard-coded state-24 bin; profiler image: sum of accepted AR-to-RLAST occupancy cycles | — |
| `0x1b0` | legacy: invalid hard-coded state-23 bin; profiler image: sum of accepted AR-to-first-R latency cycles | — |
| `0x1c0` | build-specific tagged state/value count; decode from exact source | — |
| `0x1d0` | cycles in all other states | — |
| `0x200` | snapshot capability (`0x56440001` = context-frame format 1) | — |
| `0x210` | frozen CS | — |
| `0x220` | frozen context EIP (same-edge retire aware) | — |
| `0x230` | frozen ESP | — |
| `0x240` | frozen EFLAGS | — |
| `0x250` | frozen core fault-PC tap | — |
| `0x260` | frozen CR0 | — |
| `0x270` | frozen state in bits `[15:10]`, vector/halt tag in `[7:0]` | — |
| `0x280` | execution status: `[0]` halt-request, `[1]` breakpoint-enable, `[2]` quiescent halt (`S_DECODE`, `S_PIPE`, or `S_HLTWAIT`) | write `[0]` halt request, `[1]` breakpoint enable, `[8]` one-step pulse, `[9]` clear breakpoint latch |
| `0x290` | pre-issue full-32-bit breakpoint EIP | write breakpoint EIP |
| `0x2a0` | compact architectural state selector (`0..75`: integer/system, x87 stack/environment, segment/task/debug state, stop cause) | write selector |
| `0x2b0` | selected architectural word (valid only while `0x280[2]`) | — |
| `0x2c0` | execution-debug capability (`0x56450005` = format 5, seven-bit selector, x87/segment/task/debug state plus stop cause) | — |

**Candidate-only live total-U+V counter (Oct 8):** the updated shim reserves
selectors **76/77** for the existing 64-bit total retirement counter low/high,
and **78** for capability **`0x55563634` (`UV64`)**. Unlike architectural words
0–75, these words may be read while running. The installed `fe9f539d` image
does **not** contain this extension; execution ABI 5 alone does not imply it.
Use `fpga/board-tools/ven_total_retire.py::read_total_retire` with exclusive
selector ownership: it requires the capability, uses high/low/high rollover
checks, and restores the previous selector. It never halts/steps the core or
clears counters. Both total and legacy primary counters retain REP-element
events; neither is a deduplicated x86 macroinstruction count. This extension
has passed selector/reader tests and hard-class shim lint, not FPGA deployment
or timing qualification. Legacy primary/U-only counter registers are unchanged.

**Candidate-only posted transport:** `VEN_DDR_POSTED` additionally needs
`fpga/patches/0010-posted-ddr-transport.patch` applied to a new flow source copy,
the candidate bridge and shim, and an explicit frozen define profile. The
current opt-in profile selects **16 retained write slots** (the earlier
eight-slot experiment is recorded separately). The launcher checks the exact
depth and coupled wiring. Packed `cpu_dbg_cmp[109:107]` carries
hardware-origin `{fault, capability, drained}`; these are not host controls.
The shim holds port I/O, STEP admission and externally advertised HALTED until
both inner AXI and outer DDR are drained. Scan selector **79**, safe live,
returns `0x50440000 | {fault, capability, drained}` in low bits 2:0 (zero when
not compiled). A transport fault is fail-stop and requires diagnosis; do not
reset only the CPU to discard it or claim that an inner-idle flag drained DDR.
Bridge reset is the AXI-domain reset, not the guest-reset control. This path is
microbench-tested, including the real memory path and vendor functional leaf
netlists, but **not deployed, full-system accepted or full-core timing-qualified**.
The standalone mapping and simulator procedures and their limits are recorded
in [the current candidate log](docs/UV_FAST_BANK64_2026-10-08.md).

**Posted-image cold startup must drain before modifying RAM.** Guest reset
does not cancel the bridge's outstanding writes. Do not use the old daemon's
reset-then-immediate-zero path on this image. Apply
`fpga/patches/ao486d-posted-reset-drain.patch` with `--fuzz=0` to an isolated copy
of the Device-safe daemon source (SHA
`1b9486c52438dc255903420b9ed0b05961c4f74f869204f84809081d2505f3c9`), and copy
`fpga/board-tools/ven_posted_reset_guard.h` beside `src/board_shim.cpp`.
Preserve its exact PS backend and scalar Device-memory implementation.
The guard requires CTRL=1 and two clean scan-79 drained samples separated by
1 ms, bounded to 1,000 polls. Unsupported image, sticky AXI fault, timeout,
interrupted wait or detected reset/selector interference refuses startup before
RAM initialization. Keep all other reset/scan writers stopped throughout cold
initialization; readback checks are not an interprocess lock.

The derivative binary and its 25 helper / 144 daemon host checks are pinned in
the candidate log linked above; they are **not yet hardware qualification**.
The guard is mandatory for this candidate's cold path, not a runtime performance
fallback. It does not flush caches, discard queued writes or repair guest state.

The auxiliary ring is **not generically an AXI read-beat ring or a per-cycle
waveform** in the frozen 2026-10-04 deployed source. Its exact valid predicate is
`core_req & core_we & core_ack & (core_addr[23:12] == 12'h0B8)`: accepted stores
in the B8000 page. Address/data are `core_addr/core_wdata`; the wrapper adds
state/primary-retire/INTA bits to the high word. It cannot reveal the Quake CMP's
load response or in-flight U/V state. Nearby load-serve/mini-ILA comments describe
older taps. Recheck the exact build source before interpreting any later image.

## 14. How to interpret failures

| Symptom | First checks |
|---|---|
| FPGA state is not `operating` | raw `.bit.bin`, overlay/manager availability, loader output, correct part/build |
| FPGA is operating but IDENT is wrong | artifact hash, daemon/bitstream version pairing, control address, lane-0 map |
| IDENT works but no reads/retirement | reset/run bits, `0x060/0x070`, core clock, first fetch |
| AR advances but R does not | HP0 clock/width converter, reset domain, AXI bridge state |
| Wrong/repeated 64-bit halves | verify HP0 remains 128-bit and explicit 64-to-128 converter remains present |
| POST differs run-to-run | first capture source/artifact hashes and rings; do not immediately add retries or flushes |
| `VEN_SYS_FASTPATH` loses real-mode CS/EIP before FreeDOS | run at a measured timing-safe clock, then inspect `fp_irq_divert`/`inta`; both must use one fast-eligible accepted-divert predicate |
| Reset-state ROM fails but the CD/NW-cleared A/B passes | isolate `ven_l1d` non-cacheable bypass and HP0 AR/R ownership; capture discarded priming responses; do not add another blind replay |
| `L1_BYP` serves a value after the core request changes | require the live request to match a latched address/type/extent token and select data with that latched token |
| Disk detected but no boot sector | management request service, image geometry, sector signature, BDA HDD count |
| Guest stalls with high no-retire count | `perf.py`, `0x1a0..0x1d0`, PC/aux rings, CR0 cache bits |
| Win95/Quake passes only with injection/flush | still failing clean correctness; isolate PS-to-PL coherence or guest-input need |
| Vivado has enough LUTs but cannot place | inspect CLB occupancy/congestion; current baseline is already 95.82% CLBs |

When reporting a hardware result, include:

- Ventium commit and dirty diff;
- standalone ao486 commit and a snapshot/archive of the untracked flow;
- Vivado version and synthesis defines;
- bitstream, daemon, BIOS, and disk hashes;
- final timing, DRC, and utilization report excerpts;
- exact deployment command and daemon options;
- FPGA state plus IDENT;
- complete log and explicit workload pass signature;
- whether any injection, flush, retry, cache-disable, or debug-freeze mode was used.

That bundle distinguishes a reproducible verification result from “some
bitstream was operating on the board.”
