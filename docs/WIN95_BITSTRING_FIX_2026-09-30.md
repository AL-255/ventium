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
Both unchanged 1,500-iteration CoreMark seeds are running on the new TB,
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

At 03:51 UTC the repaired candidate's two CoreMark seeds and both cold OS
runs are actually running, not merely queued. Their private full-PC parent is
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
advancing, but is not gameplay IPC or timedemo completion. Both CoreMark seeds
have reached their 536,870,912-clock checkpoints; neither has a closed CRC
verdict yet. Win95 has not produced a verified desktop frame. All three
standard-suite requirements therefore remain pending.

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

Latest verified gameplay IPC is **0.43641547**, `cdcb`, cycles **5.7–5.8B**:
clocks 5,699,999,637–5,799,999,637, retirements 2,260,946,143–2,304,587,690.
The 43,641,547 retirements reconcile with U 32,959,242 + V 10,682,305
in 100M clocks; raw frames 49/50 advance gameplay. Different demo scenes do
not establish a code-change gain or regression.
It predates this bit-string repair; the repair has no gameplay measurement.
No FPS gain or full-suite pass is claimed.

## Separate open fidelity issue

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
