# Ventium post-fast-path review 2 — August 1, 2026

## Executive summary

This is a fresh review of the current dirty worktree at `219c124` on branch
`ao486-mister-sim`, after the comprehensive fast-path repair. No product RTL
was changed by this review.

The repair closes the earlier system-fast GPR-loss bug, the independently
drifting interrupt-side-effect guards, the 16-bit shift/advance errors, and
several cache fill/invalidation races. Those are not repeated here as open
issues. The current tree still has **10 critical, 24 high, and 9 medium
findings**. The most important remaining risks are:

1. Paging and segmentation are not protection boundaries yet. Page
   permissions and per-access segment checks are computed but discarded;
   instruction permissions are not checked; a page-crossing operand translates
   only its first page; and system-structure accesses frequently bypass or
   misdrive translation.
2. Ring protection is broadly absent. CPL/IOPL checks are missing for control
   registers, descriptor tables, I/O, interrupt control, HLT, cache-control
   instructions, and RDTSC. IRET can restore unvalidated selectors and raw
   EFLAGS. This is direct privilege escalation, not merely an obscure
   compatibility corner.
3. The repaired fast path still has three boundary bugs: its SMI divert does
   not capture the interrupted EIP or reset the SMM sequencer, an interrupt
   shadow can cover a two-instruction pair, and interrupt acceptance can occur
   while an x87 occupancy transaction is only half complete.
4. I-side coherence remains unsafe under paging and concurrent invalidation.
   The I-cache is linearly tagged while DMA snoops are physical, two SMC snoop
   ports do not poison an in-flight fill, and the registered uop-cache ports are
   consumed without matching the returned port to the current fetch address.
5. x87 stack faults, exception masks, `#NM`, and `#MF` are not implemented.
   Empty-stack operations consume stale register contents, a full-stack push
   overwrites live data, CR0.TS/EM do not trap, and FWAIT is a no-op.

The highest-value correction is to make one checked access descriptor
`{linear address, width, read/write/fetch, segment class, CPL}` feed segment
validation, page permissions, page splitting, translation, and the bus. The
current duplicated `cur_lin`/`mem_addr` scheme is the source of several
independent critical failures.

## Scope and method

I reviewed all current HDL under `rtl/`, the active ao486 integration and L2
changes under `3rd-party/ao486_MiSTer` and `ao486-sim`, the cache/AXI testbenches,
the file lists, and the two earlier August reports. Particular attention was
given to the post-fix fast path, privilege transitions, paging, interrupt/SMM
boundaries, cache fill/snoop concurrency, and x87 state transitions.

The tree was already heavily modified and continued to contain untracked
source and verification material. I preserved it. Line references below name
the current files as reviewed; nearby comments sometimes describe a finding as
“deferred” or retain obsolete pre-fix prose, but the executable statements were
the source of truth.

### Fresh checks

- `make -j$(nproc) verify`: **51 pass / 47 fail** at the top level. All 20 cycle
  kernels passed. Every reported functional failure occurred because the
  golden trace generator failed first (`gen_trace.py failed (golden)`), so this
  run did not observe an RTL mismatch but also did not provide 47 valid
  comparisons.
- `CCACHE_DISABLE=1 bash verif/l1/run-l1d-gate.sh`: pass.
- `CCACHE_DISABLE=1 bash verif/l1/run-icache-snoop-gate.sh`: pass.
- `make -C verif/tb l1axi_l2`: fails before simulation because
  `rtl/northbridge/ven_cachemap.sv`, `ven_l2.sv`, and
  `ven_northbridge.sv` are absent.
- `tb_l1d_coherence.sv`: 8/8 as written, but its serve-edge snoop test samples
  after the nonblocking updates. At the actual core sampling edge the old
  registered `c_ack`/`c_rdata` are still visible; see H-13.

Severity means:

- **Critical:** breaks fundamental address correctness, architectural
  isolation, or precise state in a supported mode.
- **High:** deterministic corruption, stale execution, major exception loss,
  or a concurrency failure in an enabled configuration.
- **Medium:** substantial compatibility/configuration defect, protocol
  fragility, or verification gap that can conceal a high-impact bug.

## Critical findings

### C-01 — Present-page permissions are calculated and then discarded

**Evidence:** `rtl/core/core.sv:5679-5709` computes `perm_fault` from the
D-TLB's U/S and R/W bits, CPL, access type, and CR0.WP. The source explicitly
states at `:5695` that the access is not blocked. `perm_fault` and
`itlb_lk_perm` are consumed only by the lint sink at `:5730-5760`.

A CPL3 read/write can therefore access a present supervisor page, writes can
modify a read-only page, and CPL3 instruction fetch can execute a supervisor
page. No `#PF(P=1)`, CR2 update, or permission error code is generated. This
removes the page-level privilege boundary completely.

**Required direction:** perform I- and D-side permission checks before any bus,
cache, page-table A/D, or architectural side effect; issue a precise page fault
with the correct P/W/U bits; add CPL3 supervisor-fetch/read/write and CR0.WP
tests.

### C-02 — A page-crossing access translates only its first page

**Evidence:** `rtl/core/core.sv:4554-4700` selects one `cur_lin` and performs one
TLB lookup/walk per state access. `rtl/core/core_bus_driver.svh:447-449` then
replaces the whole request address with that one translation. The memory port
returns a four-byte window from an arbitrary byte address, and `ven_l1d.sv`
supports unaligned cached windows at `:122-155`.

A word or dword at the end of a 4-KiB page can touch the following page, but the
second page's mapping, presence, permissions, and A/D bits are never examined.
The high bytes are taken from the physically adjacent page. This returns or
writes the wrong memory when the virtual pages map to nonadjacent frames and
suppresses a required second-page `#PF`. Fetch windows have the same issue when
a four-byte fetch beat begins near page end.

**Required direction:** split every access by both page and cache-line boundary,
translate/check each piece independently, and commit stores only after every
piece has passed its checks.

### C-03 — The paging address mirror still disagrees with the bus driver

**Evidence:** compare `cur_lin` in `rtl/core/core.sv:4554-4647`, the
`translatable` list at `:4650-4700`, and the real request generator in
`rtl/core/core_bus_driver.svh:15-414`.

Current mismatches include:

- `S_LCALL` and `S_RETF` have live bus accesses at
  `core_bus_driver.svh:101-117` but no `cur_lin` case and are absent from the
  translatable list. Protected-mode paging is allowed for these states.
- `S_FENV_ST`/`S_FENV_LD` have `cur_lin` cases at `core.sv:4600-4601` but are
  absent from the translatable list, so a TLB miss never walks.
- `S_LOAD` uses raw ESP/EBP at `core.sv:4569-4571`; the bus applies `stk16()` at
  `core_bus_driver.svh:33-37`.
- `S_USEQ` hard-codes four-byte spacing at `core.sv:4614-4618`; the bus uses
  `q_w`, `stk16()`, and a separate CMPXCHG8B form at
  `core_bus_driver.svh:192-218`.
- `S_INT_CS`/`S_INT_CS_RET` hard-code the GDT at `core.sv:4623-4625`; the bus
  honors selector.TI at `core_bus_driver.svh:254-256,337-339`.
- `S_INT_PUSH` and `S_IRET` use fixed dword strides at
  `core.sv:4626-4635`, while the bus implements two-byte same-privilege gates
  and IRETW at `core_bus_driver.svh:258-335`.

On a miss, some states emit an untranslated linear address. On a coincidental
hit for the mirror address, `mem_xlate()` returns the physical address produced
for the wrong `cur_lin`, not the physical form of the real `mem_addr`. Both are
silent wrong-memory failures.

**Required direction:** delete the mirror. Generate the architectural linear
request once and use it for the TLB lookup, page walk, post-translation, debug
address, and bus transaction. Until then, assert `cur_lin == pre_xlate_mem_addr`
for every translatable request.

### C-04 — Descriptor tables and TSS/task-switch memory bypass paging

**Evidence:** `rtl/core/core_bus_driver.svh:416-429` explicitly excludes
`S_LGDT`, `S_SEGLD`, `S_LJMP`, `S_LTR`, `S_INT_SS`, `S_INT_TSS`, and every
`S_TSW_*` state from translation. The comments acknowledge that GDT/TSS
structures are architecturally linear but are being treated as physical.

With a nonidentity mapping, descriptor loads, privilege stack lookup, TSS state
save/load, and busy-bit writes access the wrong physical memory and cannot page
fault. A task switch may corrupt arbitrary physical memory while simultaneously
loading a different task image than the one named by the descriptor.

**Required direction:** translate every architecturally linear system-structure
access. Only page-table walks and the architecturally physical SMM save map
should bypass ordinary translation.

### C-05 — Most privileged and I/O-sensitive instructions have no CPL/IOPL check

**Evidence:** system decode in `rtl/core/decode_stages.sv:405-460,680-710` and
dispatch in `rtl/core/core_fetch_decode.svh:479-535` use build/mode switches,
not architectural CPL. CLI/STI execute in `rtl/core/core_exec.svh:20-32`; the
negative guard in `core_fetch_decode.svh` is primarily the V86 special case.
Port I/O dispatch at `core_fetch_decode.svh:282-327` does not consult ordinary
protected-mode CPL/IOPL or the TSS I/O bitmap.

At CPL3, software can currently execute MOV CR, LGDT/LIDT, LTR/LLDT, INVLPG,
CLI/STI, HLT, IN/OUT/INS/OUTS, INVD/WBINVD, and MOV DR paths. RDTSC ignores
CR4.TSD (`decode_stages.sv:687-699`). A guest can replace CR3, disable paging,
load its own descriptor tables, perform device I/O, or halt the machine.

**Required direction:** centralize CPL/IOPL/TSS-bitmap validation before
dispatch and cover every privileged opcode with negative tests at CPL1-3 and
V86.

### C-06 — Per-access segment protection is not enforced

**Evidence:** `rtl/core/core.sv:4111-4128` computes only
`q_ea + 3 > seg_limit[dseg]`; the result is lint-sunk at `:5730-5743`. It uses a
fixed width, covers only one data-EA shape, and ignores expand-down semantics,
fetches, stack operations, and string endpoints. No access path validates the
segment's readable/writable/code type, null-selector state, or present state.

Writes through read-only data segments, reads through execute-only segments,
accesses through null DS/ES/FS/GS, SS-limit violations, and CS-limit violations
can all reach memory. Required `#SS` versus `#GP` distinctions are absent.

**Required direction:** validate the exact access width and class before
linearization, including expand-down limits and null/type/present checks.

### C-07 — Protected-mode and V86 stack address size does not follow SS.B

**Evidence:** `rtl/core/core.sv:751-760` masks stack offsets only in pure real
mode and explicitly says V86 is unhandled. The core stores the D/B bit for CS
(`cs_d`) but has no corresponding hidden SS.B state. Stack width is therefore
not available to `stk16()`.

A 16-bit protected-mode stack segment and every V86 16-bit stack use full ESP
and fail to wrap SP at 64 KiB. Conversely, stack address size must be selected
by SS.B, not the code segment's operand/address default. Boundary pushes,
interrupt frames, calls, returns, and task transitions address the wrong memory.

**Required direction:** retain SS.B in the hidden SS cache and use it for all
stack address and SP/ESP writeback calculations.

### C-08 — Fast-path SMI entry does not initialize the SMM save transaction

**Evidence:** the slow boundary at
`rtl/core/core_fetch_decode.svh:154-158` clears the request, captures
`smm_resume_eip <= eip`, resets `smm_step`, and enters `S_SMI_SAVE`. The new
fast boundary at `rtl/core/core_fastpath.svh:64-69` only clears
`smi_pending` and changes state.

On the first fast-path SMI after reset, the save map receives the reset
`smm_resume_eip` value zero instead of the interrupted EIP. On a later entry it
can reuse a stale resume value or sequencer position. RSM then resumes the wrong
instruction. This is a direct regression in the otherwise repaired fast
interrupt path.

**Required direction:** factor SMI acceptance into one task/transaction-start
signal used by both boundaries and assert that `S_SMI_SAVE` is entered with
`smm_step==0` and a resume EIP captured from the accepted boundary.

### C-09 — LOCK and implicit memory-XCHG atomicity are absent

**Evidence:** `pfx_lock` is decoded but reaches only the F00F erratum check and
the lint sink (`rtl/core/core.sv:5731`). The comments for CMPXCHG, XADD, and
CMPXCHG8B explicitly call LOCK a functional no-op at
`rtl/core/decode_stages.sv:582-614,645-660`. Memory XCHG is also split into a
load and later store. The P5 bus wrapper ties `req_lock=0` in
`rtl/bus/biu.sv:159`, and the AXI/L1 interface exposes no lock/reservation.

The “in-order single core” justification is insufficient because DMA,
northbridge agents, the PS/co-sim store path, and device masters can access
memory between the read and write phases. Locked RMWs and implicitly locked
memory XCHG are not atomic with respect to those agents; CMPXCHG8B's two stores
can also be observed partially.

**Required direction:** serialize coherent external requesters across a locked
group or implement a cache-line reservation/atomic transaction at the
northbridge. Reject illegal LOCK prefixes with `#UD`.

### C-10 — IRET can restore privilege and flags without architectural validation

**Evidence:** `rtl/core/core_iret.svh:132-160` loads a returned CS descriptor
without table-limit, selector, executable, present, DPL/RPL, or conforming-code
checks. The outer SS is loaded without the required RPL/DPL/writable/present
checks at `:162-200`. The 32-bit path writes raw popped EFLAGS at `:33-58` and
`:69-79`.

A same-privilege CPL3 IRET can change IOPL/IF and control bits that should be
masked by privilege. Invalid CS/SS values are installed rather than producing
`#GP`, `#SS`, or `#NP`; the inter-privilege decision is made from unvalidated
CS.RPL. Together with C-05 this permits privilege escalation and corrupts the
exception-return boundary.

**Required direction:** validate the complete return frame before committing
any state, apply CPL/IOPL-aware EFLAGS masks, and make faults restartable from
the original IRET.

## High-severity findings

### H-01 — Task-switch and RSM context changes do not flush the TLBs

**Evidence:** `tlb_flush` at `rtl/core/core.sv:4261-4277` fires only for
S_EXEC INVLPG and MOV CR0/CR3/CR4. Task switch commits a new CR3 at
`rtl/core/core_tsw.svh:146-177`; RSM restores CR0/CR3/CR4 at
`rtl/core/core_smm.svh:98-129`. Neither path invalidates the I- or D-TLB.

The incoming task or restored SMM context can therefore reuse translations
from the previous address space, including supervisor/user and writable bits.

### H-02 — MOV CR/DR accepts memory encodings and invalid register numbers

**Evidence:** `rtl/core/decode_stages.sv:440-460` explicitly ignores the ModRM
`mod` field for MOV CR/DR although these instructions require `mod==11`.
`rtl/core/core_exec.svh:44-58` maps any CR write other than CR0/2/3 to CR4;
the readback mirror similarly defaults unsupported indices.

Illegal CR1/5/6/7 encodings and memory-form encodings execute as valid control
register operations instead of raising `#UD`, potentially changing CR4.

### H-03 — Interrupt delivery omits IDT/type/table-limit and nested-fault rules

**Evidence:** `rtl/core/core_int_deliver.svh:33-68` checks gate present and
software-INT DPL, but never checks `idt_limit` or validates that the type is a
supported interrupt/trap gate. `S_INT_CS` at `:82-104` lacks descriptor-table
limit and conforming-code rules. The code at `:57-60` explicitly provides only
a single re-vector rather than architectural nested-delivery and double-fault
escalation.

An out-of-limit or malformed gate is fetched and interpreted; faults during
delivery can recurse incorrectly instead of becoming `#DF` or shutdown.

### H-04 — LTR/LLDT, privilege-stack loads, and task switches commit unchecked descriptors

**Evidence:** `rtl/core/core_tss_priv.svh:9-35` loads LTR/LLDT descriptors
without selector, GDT-limit, type, present, or privilege checks and omits LTR's
busy-bit write. `S_INT_TSS`/`S_INT_SS` at `:38-89` ignore `tr_valid`, the TSS
limit, SS type, DPL/RPL, and present state; `tr_valid/tr_limit` are lint-sunk at
`core.sv:5765-5776`. `rtl/core/core_tsw.svh:71-135` reloads the new LDT and all
segments without architectural negative checks. `S_LJMP` accepts both
available and busy TSS types at `core_seg_ljmp.svh:125-146`, although a JMP to
a busy TSS must fault.

Malformed task state is installed and later used for memory addressing instead
of producing the required `#TS`, `#NP`, or `#GP`.

### H-05 — The one-instruction interrupt shadow can cover two fast instructions

**Evidence:** `pipe_pair` is formed without `irq_shadow` at
`rtl/core/core.sv:2888-2902`. The issue arm uses `do_v=pipe_pair` and retires U
and V at `rtl/core/core_fastpath.svh:367-375,535-580`, then clears the shadow
once at `:538-559`.

After STI or MOV SS, the next boundary correctly blocks INTR, but that clock can
retire two instructions. The architectural shadow protects only the first
following instruction; an interrupt must be recognizable between U and V.
Force U-only issue whenever the registered shadow is set.

### H-06 — Interrupts can divert while an x87 occupancy transaction is pending

**Evidence:** the S_PIPE interrupt branch is first at
`rtl/core/core_fastpath.svh:39-77`. A multi-cycle x87 operation marks
`fp_occ_pending` at `:266-286` and clears/commits only at `:287-303`. The
interrupt predicate at `rtl/core/core.sv:3027-3034` does not exclude that
pending state.

NMI/INTR/SMI can therefore enter a handler after x87 issue but before the
instruction retired or advanced EIP. The pending occupancy state survives into
the handler and after return, so a handler x87 operation or the restarted
instruction can skip occupancy, commit against the wrong PC, or execute twice.

### H-07 — A 16-bit paired V instruction is decoded from the unwrapped address

**Evidence:** fetch linear address is `CS.base + eip` at
`rtl/core/core.sv:2677-2679`. V bytes/slots use `flin + u.len` at
`:2761-2775,2811-2823`; pairing is not disabled at the 64-KiB IP boundary.
Commit PC wrapping was added in `core_fastpath.svh:487-493,576`, but the bytes
were already selected from the full-width successor.

If U ends at offset FFFF, V should decode from CS:0000. It instead decodes bytes
at `CS.base+0x10000` and then reports a wrapped V PC. The folded FXCH path's
`q_pc2` at `core_fastpath.svh:328` is also still unwrapped.

### H-08 — EFLAGS.RF can remain set indefinitely on the fast path

**Evidence:** RF is snapshotted and cleared only in slow S_DECODE at
`rtl/core/core_fetch_decode.svh:88-101`. The fast bailout predicate
`fp_dbg_active` at `rtl/core/core.sv:3036-3055` includes TF and DR enables but
not RF.

With RF set and no active breakpoint, fast instructions retire without the
architectural one-instruction RF clear. Later debug behavior and saved EFLAGS
are wrong.

### H-09 — NMI blocking is cleared at IRET decode, not successful outer return

**Evidence:** every decoded IRET clears `nmi_in_progress` immediately at
`rtl/core/core_fetch_decode.svh:458-472`, before any stack read or descriptor
validation.

A faulting IRET re-enables NMI. More seriously, a maskable interrupt nested
inside an NMI handler can execute its own IRET and clear the only block bit
before the outer NMI handler returns. Track the delivery source/nesting and
clear only when the successful return unwinds the NMI frame.

### H-10 — HLT does not wake for SMI

**Evidence:** `rtl/core/core.sv:3824-3838` checks only NMI and maskable INTR in
`S_HLTWAIT` and explicitly labels SMI out of scope.

A pending SMI must wake a halted processor and enter SMM. The current core can
remain halted forever.

### H-11 — Generic unknown/invalid opcodes halt instead of delivering #UD

**Evidence:** `rtl/core/core_fetch_decode.svh:381-414` sends `d_unknown`
directly to terminal `S_HALT`. Only specifically decoded UD2 takes vector 6.
Many decode branches in `rtl/core/decode_stages.sv` deliberately use
`d_unknown` for invalid encodings and unimplemented system/x87 forms.

An OS cannot catch or emulate unsupported/invalid instructions, and malformed
user code can halt the whole machine instead of receiving `#UD`. At minimum,
system mode must deliver vector 6 for architecturally invalid encodings; legal
but unsupported instructions should either be implemented or exposed as a
clearly defined product limitation rather than a silent CPU hang.

### H-12 — SMC snoop ports 1 and 2 do not poison an in-flight I-cache fill

**Evidence:** normal invalidation applies all three ports at
`rtl/mem/icache.sv:377-385`, but `snoop_hits_fill` and the first/final-beat
poison checks at `:194-201,339-369` inspect only `snoop_inv_valid`/port 0.
`rtl/mem/ventium_l1_axi.sv:327-332` drives ports 1 and 2 from CPU
self-modifying stores.

A CPU store to a line while that line is filling, including on the final beat,
can be overwritten by the fill and left valid with stale instruction/uop data.
Fold all three ports into the transactional poison predicate.

### H-13 — An already-armed L1D hit can acknowledge stale data on the snoop edge

**Evidence:** `rtl/mem/ven_l1d.sv:178-191` suppresses *new capture* during a
snoop, but registered `c_ack` at `:300-306` is `rd_match && !flush_all` and is
not gated by a snoop hitting either line in the captured window. The
combinational-ack variant at `:287-293` is also not snoop-gated.

If a hit is armed in the prior cycle and a DMA snoop arrives on the serve edge,
the core's sequential logic samples the pre-NBA `c_ack=1` and stale
`rd_window_q` while the cache clears valid at that edge. The current coherence
test samples after `#1`, sees the newly cleared ack, and therefore misses what
the core sampled. Gate the response itself on a matching snoop and assert the
value at the consumer sampling edge.

### H-14 — The uop predecode walker has no accepted-request handshake

**Evidence:** `rtl/mem/uopcache.sv:242-275` accepts `pd_start` only in W_IDLE;
the core ignores `pd_busy` at `rtl/core/core.sv:5001-5015` and emits a one-clock
start pulse for every completed I-cache fill at `:4983-4997`. W_WRITE installs
and validates the old walk at `uopcache.sv:312-321` after the general
invalidation statements.

A fill completing while the walker is busy is dropped. If it targets the same
set/way on W_WRITE, the old walk's final `store_pdv<=1` can override the new
fill's invalidation, pairing new instruction bytes with stale predecoded uops.
Use ready/valid or a queue and make refill/invalidation dominate old completion.

### H-15 — Registered uop-cache output A is consumed even when the current line is in port B

**Evidence:** the uop cache has synchronous A/B reads with no returned address
tag at `rtl/mem/uopcache.sv:117-180`. I-cache fetch-ready correctly accepts the
current line in either registered buffer at `rtl/core/core.sv:2701-2735`, but
U decode always consumes `uc_slotsA`, `uc_bsA`, and `uc_pdvA` at
`:2761-2789`.

Predicted-target prefetch deliberately places a taken target in port B at
`core.sv:2690-2695,2954-2969`. After redirect, I-cache data can be ready from B
while U reads stale predecode data from A. If A happens to report a valid
boundary at the same offset, the wrong uop issues. Tag both returned uop ports
and select the one that actually matches the current line/way.

### H-16 — Linear I-cache tags cannot maintain physical coherence or aliases

**Evidence:** `rtl/mem/ventium_l1_axi.sv:293-301` documents that CPU SMC uses a
linear address while DMA snoops remain physical and approximate. I-cache tags
are formed directly from the linear fetch address.

Under paging, a DMA write to physical page P will not match a resident line
tagged by virtual page V. A CPU can also execute one virtual alias and modify
the same physical page through another alias; invalidating only the store's
linear alias leaves executable stale bytes in the first alias.

**Required direction:** use physical I-cache tags after translation, maintain a
reverse alias map, or conservatively flush all I/uop state on external writes
and potentially aliased SMC.

### H-17 — Instruction cacheability is not derived from the memory type

**Evidence:** the I-cache has no cacheable input and validates every fill. In
`rtl/mem/ventium_l1_axi.sv:410-416`, cache mapping is queried only for the
core data path with `.is_code(1'b0)`. CR0.CD and northbridge PAM/SMRAM/MMIO
attributes do not control I-side allocation.

Instruction fetches from mutable/side-effecting or disabled-cache regions can
be retained indefinitely. This compounds H-16 because there is no reliable
invalidate for every such producer.

### H-18 — `VEN_L1_HONOR_CD` still caches and hits reads while CD is set

**Evidence:** the enabled branch at `rtl/mem/ven_l1d.sv:343-352` explicitly
disables the bypass-read path with `if (1'b0)`. `rd_hit`/`c_ack` are not gated by
`cacheable` at `:287-306`.

CR0.CD can therefore return an old cached hit and every read miss allocates.
With the optional cache map, noncacheable MMIO reads can also enter this path,
duplicating or suppressing device side effects.

### H-19 — Noncacheable unaligned reads that cross a line return zero high bytes

**Evidence:** `rtl/mem/ven_l1d.sv:249-268` builds the bypass window from one
line and explicitly warns that offsets 29-31 are not split; bytes beyond the
line are zero.

Word/dword reads across a 32-byte boundary return corrupt data in precisely
the path intended for MMIO/CD bypass. Split the access or reject an unsupported
width before issuing a partial value.

### H-20 — ao486 L2 invalidation can be dropped or overwritten by a fill

**Evidence:** `3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v:75-81` gives the
state-machine tag write priority over `l2_inv_pulse`, based on a comment that
the harness pulses only while the CPU is idle. The actual co-sim generates the
pulse immediately after FPU store processing at
`ao486-sim/sim_main.cpp:1834-1859`, with no L2-idle handshake. FILLCACHE writes
data and validates the victim at `l2_cache.v:395-413`.

An invalidation colliding with `update_tag_we` is lost. An invalidation during
a fill can also be followed by fill completion that makes the line valid again
with old/mixed contents. Queue invalidations or poison fills; do not rely on
test-harness scheduling as a coherence protocol.

### H-21 — Empty/full x87 stack conditions are not enforced

**Evidence:** `fptag` is read for FXAM and environment images, but normal
arithmetic/moves read `fst()` regardless of its tag. `rtl/fpu/fpu_top.sv:218-257`
blindly pushes/pops and modifies tags without checking full or empty slots.

An empty-stack operand consumes stale `fpr` data, and a push to a full stack
overwrites a live value. The required IE/SF/C1 behavior, masked indefinite
result, and unmasked exception path are absent.

### H-22 — x87 exception masks and `#MF` are not implemented

**Evidence:** arithmetic helpers compute IE/ZE/OE/UE/PE, but no execution path
uses `fctrl[5:0]` to decide masked versus unmasked completion. FWAIT is a no-op
at `rtl/core/fpu_writeback.sv:681`. There is no x87 `#MF` delivery path.

Unmasked exceptions still write results and retire, ES/B are not derived from
pending unmasked exceptions, and WAIT cannot report a pending exception.

### H-23 — CR0.EM/TS/MP do not govern x87 execution or `#NM`

**Evidence:** x87 dispatch at `rtl/core/core_fetch_decode.svh:416-421` enters
the FPU paths without inspecting CR0.EM or TS. Task switch sets CR0.TS at
`rtl/core/core_tsw.svh:165`, but the next x87 instruction still executes.
FWAIT is decoded as a harmless operation.

Lazy FPU switching is therefore impossible: EM/TS should raise vector 7
`#NM`, and WAIT has MP/TS-specific behavior. There is also no CLTS implementation
visible in the system decode.

### H-24 — SMM/SMRAM isolation is disconnected from the memory hierarchy

**Evidence:** both cache-map and northbridge instances hard-wire
`.smm_active(1'b0)` at `rtl/mem/ventium_l1_axi.sv:412-429`; the core's live
`smm_active` state is not exported to them.

SMRAM cannot be opened exclusively for SMM and protected outside it. Normal
code/DMA can access the save map or handler region, and SMM accesses receive
ordinary non-SMM cache/PAM treatment. This also makes the SMM save/restore path
vulnerable to stale cache state.

## Medium-severity findings

### M-01 — x87 environment formats are fixed to 28/108 bytes

**Evidence:** decode does not retain the environment operand size at
`rtl/core/decode_stages.sv:1518-1521,1633-1635`.
`rtl/core/core_fenv.svh:6-28,38-45` hard-codes 28-byte FNSTENV/FLDENV and
108-byte FNSAVE/FRSTOR sequences. The source also states that FNSTENV has no
post-store side effect; `rtl/core/fpu_writeback.sv:522-527` implements only the
FNSAVE reset.

The 16-bit operand-size forms require 14- and 94-byte layouts. FSTENV/FNSTENV
also masks all x87 exception-mask bits after storing the old environment. Both
behaviors are missing.

### M-02 — The SMM save map omits live architectural system/debug state

**Evidence:** the save image layout and serializer in
`rtl/core/core.sv:722-730,4486-4550`
and consumed in `core_smm.svh` includes the main CRs, GPRs, segments, and table
bases, but omits the newly implemented DR6/DR7 state and complete TR/LDTR hidden
state. The code itself retains only a custom compact save map.

An SMM handler that changes debug/task state cannot round-trip it
architecturally. Define and test the intended Pentium save-state layout rather
than extending a private image ad hoc.

### M-03 — The A20 gate is absent

**Evidence:** `rtl/core/core.sv:2672-2676` explicitly notes no A20 masking, and
there is no top-level A20 control feeding address generation.

When A20 is disabled, accesses that should alias at 1 MiB remain distinct in
memory and in the caches. This is a material BIOS/legacy-OS compatibility gap.

### M-04 — `ven_l1d` parameters are hard-coded to 128 sets and 32-byte lines

**Evidence:** despite `L1_SETS`/`L1_LINE` parameters,
`rtl/mem/ven_l1d.sv:107-139` hard-codes seven set bits `[11:5]`, a 20-bit tag,
offset bit 5, and flat `{set,way}` addressing. `rtl/ventium_top.sv:952` does not
pass the core's `VEN_CACHE_HALF` geometry into `ventium_l1_axi`.

Overriding the parameter to 64 can index beyond the array and uses the wrong
tag split. The advertised half-cache configuration therefore does not shrink
the functional AXI L1D and is unsafe if wired naively.

### M-05 — The advertised L2/northbridge configuration does not build

**Evidence:** `rtl/mem/ventium_l1_axi.sv:409-449` instantiates
`ven_cachemap`, `ven_l2`, and `ven_northbridge` when EN_L2 is enabled, but the
three referenced source files under `rtl/northbridge/` are absent. The focused
`l1axi_l2` target fails on these missing prerequisites.

This leaves the coherent DMA/cacheability configuration unbuildable in the
reviewed checkout and means its claimed gates are not reproducible.

### M-06 — Without `VEN_NB_MMIO`, device space silently becomes DDR

**Evidence:** `rtl/mem/ventium_l1_axi.sv:458-472` merges the northbridge MMIO
request back onto the ordinary AXI backing port when the external MMIO fabric
is not compiled.

Device accesses then read/write RAM at the device address instead of faulting
or reaching a device. This can make firmware appear to run while silently
losing all device side effects. Prefer an explicit configuration error or bus
fault.

### M-07 — The KV260 address mask aliases the entire 4-GiB space into 256 MiB

**Evidence:** `rtl/ventium_top.sv:933-945` sets
`L1AXI_ADDR_MASK=0x0FFF_FFFF` and documents the fold.

The BIOS shadow workaround makes every physical address with the same low 28
bits collide. Guest RAM above 256 MiB, PCI apertures, and high aliases can
overwrite unrelated low memory. Treat this as a platform memory-map limit and
reject unsupported RAM/aperture configurations.

### M-08 — AXI read completion ignores RLAST after merely asserting it in simulation

**Evidence:** `rtl/mem/ven_axi_master.sv:298-315` exits solely on the local beat
count. RLAST alignment is checked only by simulation assertions at `:411-415`.

An early RLAST leaves the master waiting for beats a slave will not send; a
late RLAST lets it return idle and potentially launch a new transaction while
the old burst is incomplete. AXI requires a compliant slave, so this is not a
normal-path functional failure, but robust hardware should convert either
case into a sticky fatal bus error and drain/recover deterministically.

### M-09 — Current verification can report green while missing consumer-edge races

The fresh run has three important blind spots:

1. Forty-seven functional cases never compared RTL because golden generation
   failed, yet the aggregate can be mistaken for RTL regressions or ignored as
   unrelated noise.
2. `tb_l1d_coherence.sv` samples the serve/snoop race after nonblocking updates,
   not at the core's sampling edge, masking H-13.
3. The focused L2 target cannot compile, so H-20 and the optional northbridge
   behavior have no current executable regression gate.

Fix the golden infrastructure, sample handshakes in the same clocking region as
the consumer (or use clocking blocks/SVA), and make every advertised feature
configuration compile in CI.

## Fix priority

1. **Restore architectural isolation first:** C-01 through C-07 and C-10.
   Build one canonical access/check/translate transaction and one centralized
   privilege validator. These changes remove multiple bugs at once.
2. **Make interrupt boundaries precise:** C-08, H-01, H-03 through H-10.
   Add directed fast-SMI, shadowed-pair, nested-NMI/IRQ, faulting-IRET, changed-CR3
   task-switch, and changed-CR3 RSM tests.
3. **Close coherence races before trusting FPGA boots:** C-09 and H-12 through
   H-20/H-24. Use transaction poison/queues and physical coherence identity.
4. **Complete x87 architectural traps:** H-21 through H-23 and M-01. Test empty,
   full, masked/unmasked exceptions, TS/EM/MP, WAIT, and both env sizes.
5. **Repair the verification envelope:** M-05/M-09, then rerun the full suite
   and the relevant synthesis configurations.

## Targeted regression matrix

At minimum, add the following tests before calling the system path robust:

| Area | Required directed case |
|---|---|
| Paging | CPL3 fetch/read/write of supervisor page; RO write with WP=0/1; each scalar width crossing a page into noncontiguous/not-present/RO page |
| Address generation | Assertion that lookup linear equals bus pre-translation linear in every state, including LCALL/RETF, FENV, IRETW, PUSHAW/POPAW, LDT descriptors |
| Segmentation | Null data selector, execute-only read, read-only write, expand-down boundary, CS and SS limit endpoints |
| Privilege | Every privileged opcode at CPL3; CLI/STI and IN/OUT for CPL/IOPL combinations; TSS I/O bitmap allow/deny |
| Return/delivery | Bad/out-of-limit IDT gate, malformed type, bad target CS, bad outer SS, nested delivery fault to #DF, CPL3 IRET attempting IOPL change |
| Task/SMM | Task switch and RSM changing CR3; busy-TSS JMP; invalid LTR/LLDT; fast-path SMI resume-EIP; HLT+SMI |
| Fast boundary | STI/MOV-SS followed by pairable U/V with IRQ between them; RF-only fast stream; NMI handler with nested IRQ/IRET; IRQ during x87 occupancy |
| Coherence | SMC port1/2 on every I-cache fill beat; armed L1D serve plus same-edge snoop; virtual aliases; DMA physical write to virtually tagged code |
| Uop cache | Fill while walker W_WALK/W_WRITE, same-way refill, predicted target resident only in port B, redirect every registered-read phase |
| Locked RMW | DMA collision at every load/store gap for XCHG, LOCK XADD/CMPXCHG/CMPXCHG8B, including failed compare |
| x87 | Empty operand, full push, stack under/overflow, each exception masked/unmasked, CR0.EM/TS/MP, FWAIT, 14/28/94/108-byte environments |

The existing fast-path canonical predicates are a good model for the broader
repair: derive a semantic decision once, consume it everywhere, and assert that
no mirrored address, permission, or side-effect predicate can drift from it.
