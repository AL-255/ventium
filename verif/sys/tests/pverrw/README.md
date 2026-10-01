# Standalone VERR/VERW witnesses and implementation proposal

Status: the parent-owned repaired all-ten gate passes on frozen TBfe4a in
`obj_dir_verrw_oct01.M2bz8N/pverrw-qualified-oct01.2/`. Cases1–8 pass full
pinned-QEMU architectural comparison;9/10 pass their explicit Intel-spec
contracts. The first all-ten run's CASE7 QEMU fixture failure is preserved.
The fixture author has run host checks and bounded CASE7 QEMU diagnostics, not
a DUT. Neither directed gate is Win95 evidence. The verified gameplay baseline is IPC
0.44499855 on cdcb over cycles 6.9–7.0B; it predates the current candidate,
which has no gameplay measurement.

Historical first-seven freeze, committed in `aafc924`: source SHA256
`56ef7b7ce06336951e6ee45fe60235914b2d9b2e003f1cc2640c6b75b1ddad0c`,
CASE1 image SHA256
`32e7a394c5fb649918aca419b78d75a7c3970b8633c77df286cc3fa6be1e4562`.
All seven host builds and ten original host contract tests passed, using CPU3,
512MiB virtual-memory limit and a 45-second timeout; no model was launched by
that build. The CASE8–10 extension keeps all seven original BIOS bytes exactly
unchanged, pinned independently by `test_build_contract.py`. That historical
receipt must not be confused with later parent-owned architectural results.

## CASE7 fixture repair: preserved failing evidence

The closed first gate is
`verif/tb/obj_dir_verrw_oct01.M2bz8N/pverrw-qualified-oct01.1/` on frozen TB
`fe4a21d733c5e7223e19ff3b2d2d30a71ff3a8f1cd6013456087a04ddb7c1e79`.
CASE7's private original `image.bin` remains there with SHA256
`9675f3548e4325a6e0f7f928f97d745248ff4de528d7775acefe7dfe9c2351e3`,
and its ELF SHA256 is
`717b9c8d3575df31f6fa7ed7bda55992de22944f4c5b12db58a50d33028126c1`.
Its free-QEMU receipt records actual exit135, no descendants and an empty log;
this was a fixture failure, not an RTL failure or permissible oracle mismatch.

The PM16 code descriptor high dword was incorrectly `000F9B00`: it encodes
base0/limitFFFFF, not the intended baseF0000/limitFFFF. The far jump's offset183
therefore fetched low RAM instead of BIOS. A bounded pinned-QEMU gdb trace in
`pverrw-case7-diag.Mao6OJ/failing-qemu.vtrace` preserved 592 records (SHA256
`5633fc9861402dff97841c2a91b4eed3c89bb503d798cd4e096f7758b2be694c`).
It shows CS58 at n128, low-RAM PC183/185 at n129/130, unchanged unstaged GPRs,
eventual #UD at PC508, and final EAX43/ECX0/EDI2. The original VERR/VERW
witnesses had never been reached; no opcode, prefix or flags check was waived.

CASE7 alone now writes descriptor high dword `00009B0F`, giving baseF0000,
byte limitFFFF and D=G=0. Its BIOS SHA256 is
`7531c9dfaf2a39c7cc96bbeed4547d20baf51dfba8e910cd1e386cb963166da4`;
ELF SHA256 is
`454cc325cfc289974e3e0ee8391ed1b1fe3c2af36e0f1375e1b0bd71ff5e8c22`.
A targeted pinned free-QEMU run actually reaped133 after this repair. All ten
host builds and16 contract tests passed, including a new byte-decoded GDT
base/limit/D/G assertion. The other nine BIOS images remain byte-identical.
Diagnostics used the default4GiB build scope, CPU3, explicit root-filesystem
TMPDIR and 90/30-second hard caps; no RTL, TB rebuild or failing artifact changed.
The parent's complete architectural rerun now passes all ten cases. This does
not qualify Win95 desktop, CoreMark or Quake timedemo acceptance.

Build only:

```sh
make -C verif/sys/tests/pverrw -j2 check-host
```

`manifest.json` lists all ten cases and exact terminal registers. Every
image is 64 KiB with its reset vector at FFF0. Every completed query checks all
seven non-ESP GPRs, ESP, and defined EFLAGS except exception-image RF; only
ZF may change. Source canaries and query-only GDT accessed bits must remain
unchanged. CASE3/4 handlers independently check saved fault PC, #PF error0,
CR2=21000, pre-query ZF1/ZF0 and all eight PUSHAL slots before skipping the
instruction. CASE5/6 validate each #UD source PC/length and saved context.
CASE6 deliberately names an unmapped selector-source page: the mode #UD
must win before any operand #PF.

These fixtures are not registered as a new standard-suite correctness pass.
After review, CASE1–8 use **pinned private** QEMU 8.2.2; CASE9/10 are explicitly
separate Intel-spec witnesses because QEMU omits the required LOCK and
per-access null/limit checks.
Use a caller-supplied frozen TB with reviewed compile metadata. Use
free-running QEMU's actual exit 133, complete generated system `.vtrace`,
actual native reap/debug-exit, full architectural comparison and the terminal
witnesses together. Do not rebuild the canonical TB, change guest media, or
treat an instruction cap/idle loop as completion. The ordinary
`gen_trace.py --system --image-mode bios` producer and `tracefmt.py` remain
the authority; no synthetic host record is DUT evidence.
Both native and QEMU debug-exit status must be **133** for AL42; AL43 fails
with status135. Instruction-cap, fatal, quiescent and incomplete closures fail.

## Qualified directed extensions

| Case | Completed queries | Exception events | Contract |
| --- | ---: | ---: | --- |
| 8 | 8 | 8 TF #DB traps | Valid and invalid VERR/VERW/LAR/LSL each trap after the query, saving its exact end PC and final ZF. |
| 9 | 0 | 4 #UD faults | LOCK VERR/VERW, register and 66/register, absent-page memory and 66/memory, fault before operand access. |
| 10 | 6 | 4 #GP(0), 2 #SS(0) faults | Null-DS and two-byte DS/SS limit crossings preserve pre-query flags/GPRs; legal SS override and word-at-limit controls execute. |

CASE8 uses a trap gate, clears competing DR7 enables and stale DR6 before each
probe, checks DR6.BS, all saved GPRs/ESP/CS/DS/SS and defined EFLAGS, and requires
saved RF=0 (TF #DB is trap-class, not a fault). The handler clears saved TF
before IRET, and each continuation verifies exact live flags/GPRs/ESP and
event count. LAR/LSL valid probes allow only their defined EAX destination;
invalid probes must preserve it. Intel1997 Vol3 §14.3.1.4, printed14-10,
specifies no trap on the POPF setting TF; the following query traps. Printed
14-9 specifies that trap-class delivery does not automatically set RF.
`db_handler` and all query/end PCs are ELF symbols. Native start-fault logs do
not count `arm_db` traps; qualify all eight handler entries from the complete
architectural trace plus the in-image counter, not a missing ordinary-fault log.

CASE9 puts both memory sources on absent page21000 and seeds CR2=77889900.
Each exact #UD source PC, unchanged CR2, old ZF1/ZF0, full saved/live GPRs,
ESP and selectors must match; any operand #PF or completed query fails.
Intel1997 Vol2 LOCK, printed3-273, restricts LOCK to its memory-modifying
allow-list; VERR/VERW are not legal. Pinned QEMU's legacy `translate.c`
`case 0x100` /4,/5 neither tests `PREFIX_LOCK` nor rejects it globally afterward.
Its NOP arm even records incomplete LOCK validation. Therefore CASE9 uses
the Intel-spec witness, not a relaxed differential or invented QEMU golden.
This is a source-established oracle limitation; no QEMU run was launched by
the fixture author to claim a measured mismatch.

CASE10 requires an actually compiled `VEN_SEG_ENFORCE` binary, not an inherited
environment declaration. GDT80/88 are D/B1, byte-granular data/stack descriptors
with limit9FFF. Word9FFE is legal; word9FFF crosses the limit. The short SS has
a safe ESP7000 so its own #SS frame remains within bounds (saved PUSHAL ESP6FF0);
other fault probes use ESP90000 (saved PUSHAL ESP8FFF0). Handlers use valid SS
for markers and validate vector/error0, exact source PC, flags except fault-
image RF, all eight PUSHAL slots and visible selectors before returning. Six
legal controls include explicit SS with null DS and exact two-byte DS/SS reads
at the limit. Both source canary sets must remain unchanged. Intel1997 Vol2,
VERR/VERW printed3-454, specifies these source #GP/#SS faults. Pinned QEMU's
`gen_lea_modrm`/`gen_ldst_modrm` only add segment bases and issue loads; they do
not enforce these per-access null/limit checks. CASE10 must never be treated
as a differential QEMU pass or worked around by relaxing architectural checks.

## Historical minimal general RTL design

The following proposal was written before the shared S_DQUERY repair. The
parent has since implemented the general route, including shared normal
retirement. These notes preserve the design obligations; they are not a claim
that every referenced old line still has its original implementation.

Primary semantics: Intel 1997 SDM volume 2, printed 3-453/454 (PDF 483/484), and
pinned QEMU `seg_helper.c` `helper_verr`/`helper_verw` at 2344/2382.

1. Add `SYS_VERR`/`SYS_VERW` to the existing sysop enum. Decode `0F 00 /4,/5`
   only for system protected mode with VM=0; real/V86 and illegal LOCK
   retain precise #UD. Both register and memory source are **16 bits**, even
   with 66. Account for actual ModRM/SIB/displacement and 66/67 prefix lengths.
   Set flag ownership, but no GPR write and no source-memory write.
2. Reuse the LAR/LSL descriptor route: register source directly to
   `S_DQUERY`; explicit memory source through fixed-width `S_LOAD` and then
   `S_DQUERY` (`core_fetch_decode.svh:693`, `core_load.svh:164`). Include the
   new sysops in the `load_beat_w=2` predicate. Do not pre-reject a selector
   before its explicit memory source has actually completed: that source can
   #GP/#SS/#PF even when its eventual value would be null.
3. Add explicit query type predicates, rather than falling into the current
   LSL system-type default. VERR permits data or **readable** code; VERW
   permits **writable data only**. Require S=1. Only readable conforming
   code for VERR bypasses both CPL and RPL tests. Otherwise require
   DPL>=max(CPL,RPL). **P is not a filter**: accessible P=0 descriptors may
   still set ZF; neither opcode loads a segment or sets descriptor A.
4. Reuse selector null/OOB prefilter, TI-directed GDT/LDT addressing,
   supervisor implicit descriptor paging and two-beat descriptor ownership.
   GDT index0/RPL0..3 is null; TI1/index0 is an ordinary LDT entry. Rejected
   selectors clear ZF without an implicit table read. Descriptor page faults
   remain precise and must leave the old ZF/GPRs unchanged. Publish ZF only
   on the complete, fault-qualified result; do not reuse destination merge.
5. **Do not copy the former bare S_DQUERY retirement as proof of correctness.**
   The pre-repair `core_seg_ljmp.svh:183–195` set ZF/EIP/retire directly and did
   not route issue-time TF through `arm_db`/the normal integer retirement
   helper. Both successful and ZF0 queries execute and need normal post-
   instruction trap handling; faulted explicit/implicit reads do not retire.
   Use the existing shared retirement path with merged flags and no GPR
   destination, and add directed #DB coverage before claiming that aspect.

This proposal is guest-independent. The same-binary native capture now proves
Win95's `00A7:CA60` bytes `0F 00 E8` are decoded with PE1/VM0/CPL3/AX0087,
yet the former decoder marks them unknown. See
`docs/WIN95_BITSTRING_FIX_2026-09-30.md` for exact capture receipts. A fresh
query-candidate cold boot is running; causality through desktop remains open.
No Quake, Win95, media, callback, saved-state or forced-EOI special case belongs
in this implementation.

Remaining limits are explicit in the manifest. CASE8–10 qualify initial TF,
source-segment and LOCK probes on the frozen direct-core model. Query
execution/data breakpoints, ES/FS/GS source combinations, source privilege/
#AC cases, and TF priority at an explicit/implicit read fault remain uncovered.
