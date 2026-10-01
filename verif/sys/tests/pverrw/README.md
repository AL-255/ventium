# Standalone VERR/VERW witnesses and implementation proposal

Status: **no QEMU or DUT execution has been launched**. The seven images are
host-built BIOS fixtures, not passing architectural gates or Win95 evidence.
The current gameplay baseline is IPC 0.46960514 on cdcb over cycles 6.0–6.1B;
the repaired c0e5 full-PC build has no gameplay measurement.

Build only:

```sh
make -C verif/sys/tests/pverrw -j2 check-host
```

`manifest.json` lists all seven cases and exact terminal registers. Every
image is 64 KiB with its reset vector at FFF0. Every completed query checks all
seven non-ESP GPRs, ESP, and defined EFLAGS except exception-image RF; only
ZF may change. Source canaries and query-only GDT accessed bits must remain
unchanged. CASE3/4 handlers independently check saved fault PC, #PF error0,
CR2=21000, pre-query ZF1/ZF0 and all eight PUSHAL slots before skipping the
instruction. CASE5/6 validate each #UD source PC/length and saved context.
CASE6 deliberately names an unmapped selector-source page: the mode #UD
must win before any operand #PF.

The seven host-built variants are not registered as a new standard-suite
correctness pass. After review, first qualify each with **pinned private**
QEMU 8.2.2, then obtain a red result from the caller's frozen 6ae TB. Use
free-running QEMU's actual exit 133, complete generated system `.vtrace`,
actual native reap/debug-exit, full architectural comparison and the terminal
witnesses together. Do not rebuild the canonical TB, change guest media, or
treat an instruction cap/idle loop as completion. The ordinary
`gen_trace.py --system --image-mode bios` producer and `tracefmt.py` remain
the authority; no synthetic host record is DUT evidence.

## Minimal general RTL design (proposal only)

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
5. **Do not copy bare S_DQUERY retirement as proof of debug correctness.**
   `core_seg_ljmp.svh:183–195` currently sets ZF/EIP/retire directly and does
   not route issue-time TF through `arm_db`/the normal integer retirement
   helper. Both successful and ZF0 queries execute and need normal post-
   instruction trap handling; faulted explicit/implicit reads do not retire.
   Use the existing shared retirement path with merged flags and no GPR
   destination, and add directed #DB coverage before claiming that aspect.

This proposal is guest-independent. The logged Win95 `00A7:CA60` bytes
`0F 00 E8` resemble VERW AX, but only an actual pre-fault VM/PE/context witness
can establish whether that #UD was erroneous or contributed to boot failure.
No Quake, Win95, media, callback, saved-state or forced-EOI special case belongs
in this implementation.

Remaining coverage limits are explicit in the manifest: TF/#DB, source
segment #GP/#SS and illegal LOCK are not qualified by these first seven cases.
