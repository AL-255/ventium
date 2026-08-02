# Ventium i586 RTL review — July 29, 2026

## Executive summary

This review found **5 critical, 14 high, 12 medium, and 5 low-severity
issues** in the current worktree. The most serious problems are architectural
protection mechanisms that are calculated but deliberately not enforced:
present-page U/S and R/W permissions, segment limits, privilege checks on
system and I/O instructions, and several protected-mode control-transfer
rules. As a result, this is not presently a safe or generally correct i586
implementation for rings other than the narrow, well-formed boot/test paths
used by the regression suite.

There are also two confirmed architectural corruptions in the dual-issue
fast path. `FSTP ST(i)` fails to copy ST0 when `i != 0`, and `MOV moffs,AL/eAX`
does not write memory at all. These are not just an abstract timing-model
problem: the ao486 integration hard-wires `cycle_mode=1` in
`ao486-sim/ven/ven_ao486_shim.sv:180-188`.

The current `make verify` result is misleadingly green. All 98 functional
jobs passed, but **all 20 cycle comparators returned exit 1 and printed
`RESULT: DIVERGENT`**. The aggregate ignores that nonzero result unless it is
specifically labeled a control-flow mismatch, then grades only aggregate
metric bands. Cycle traces also omit registers, flags, x87 state, and memory,
which is why the two confirmed fast-path corruptions can escape the gate.

The current checkout is not independently reproducible as the documented
SoC. The L2/northbridge build references three absent RTL files, the advertised
`rtl/soc/` and `sw/` trees are absent, no FPGA project-creation source exists in
`fpga/`, and the actual Ventium/ao486 build depends on a heavily modified
vendor submodule plus untracked filelists and integration sources.

I recommend treating the current design as a corpus-driven compatibility
prototype, not yet as an architectural i586 replica. The first repair phase
should make protection checks fault precisely, remove architectural behavior
from the timing-only fast path, and make every nonzero comparator result fail
the gate.

## Scope and method

I reviewed the current dirty worktree rather than just `HEAD`. The worktree
already contained extensive modified and untracked RTL before this review.
No product source was changed by the review.

The primary line-by-line scope was all first-party HDL and filelists under
`rtl/`: 67 files and **25,178 lines**, including the core spine and includes,
both decoders, MMU/TLB, caches, bus units, x87 implementation, AXI/CDC path,
and top-level integration. I also systematically inspected the build and
verification code under `verif/`, the first-party ao486 shim/bridge and its
filelists, root build files, and integration-relevant documentation.

Generated Verilator C++, Vivado output, binary/disk artifacts, ROM constant
tables, and upstream third-party source were not treated as first-party design
code. The modified ao486 `system.v` integration boundary and first-party shim
around it were reviewed. That distinction matters because generated and
vendor trees account for a large fraction of the checkout but are neither a
maintainable source of Ventium behavior nor independently reviewable as
Ventium-authored logic.

Validation combined:

- static control/data-flow tracing across the FSM, bus driver, TLB, decoder,
  writeback, cache, and integration boundaries;
- Verilator lint of the canonical core/filelist with warnings nonfatal;
- the unified differential gate and focused arithmetic gates;
- three directed assembly reproductions under `tmp/review_jul29/`;
- syntax checks over the first-party shell and Python verification tooling;
- explicit existence and dry-run checks for documented build inputs.

Severity means:

- **Critical:** breaks isolation, address correctness, or fundamental execution
  in a normal architectural mode;
- **High:** deterministic architectural corruption, major missing exception
  behavior, or a deployed integration defect;
- **Medium:** significant ISA/integration inaccuracy, verification escape, or
  reproducibility failure;
- **Low:** narrower fidelity, maintainability, or diagnostic weakness.

## Critical findings

### C-01 — Paging permissions are calculated and then discarded

**Evidence:** `rtl/core/core.sv:5368-5397`, especially the explicit statement
at `:5384` that the access is not blocked, and the lint sink at
`rtl/core/core.sv:5420-5430`.

The TLB stores effective `{US,RW,P}` permissions, and `perm_fault` correctly
recognizes a CPL3 access to a supervisor page and a prohibited write to a
read-only page. Nothing consumes that decision. The memory request proceeds
and no present-page `#PF` is delivered.

The check is also D-TLB-only (`p = dtlb_lk_perm` and
`paging_on && cur_is_d && dtlb_lk_hit`). Instruction fetch permissions are
never enforced. A CPL3 task can therefore read, write (subject only to the
discarded test), and execute supervisor mappings. CR0.WP does not protect
read-only supervisor pages from kernel writes either. This defeats the central
isolation property of protected paging.

**Required direction:** make permission checking part of the request-issue
predicate for both I and D accesses. On failure, suppress the request, set CR2
and the complete `#PF` error code (`P=1`, `W/R`, `U/S`, and instruction-fetch
where applicable), and enter fault delivery before any architectural write.
Add CPL3 supervisor-page, CR0.WP, and user-execute tests.

### C-02 — Segment-limit enforcement is a dead calculation

**Evidence:** `rtl/core/core.sv:3866-3883` and the lint sink beginning at
`rtl/core/core.sv:5420`.

`seg_off_over_limit` is calculated and ignored. Every over-limit data or stack
access continues to memory. Even the calculation is not a usable architectural
check: it always assumes a four-byte access, does not use the actual operand
width, does not implement expand-down bounds, does not distinguish stack
faults, and does not validate string endpoints or instruction fetches.

This permits a less-privileged task to reach memory outside its segment and
means SS limit violations do not raise `#SS`. It also makes descriptor limits
largely decorative outside the few descriptor-load checks.

**Required direction:** generate width- and segment-type-aware checks in the
linear-address generation stage, including expand-down segments, stack/string
accesses, and code fetch. Block the bus transaction and deliver `#GP` or `#SS`
precisely.

### C-03 — The paging lookup address disagrees with the address driven on the bus

**Evidence:** compare `cur_lin` in `rtl/core/core.sv:4300-4391` with the actual
bus address in `rtl/core/core_bus_driver.svh:30-72`,
`:181-207`, and `:225-329`.

The TLB lookup and page-walk launch use `cur_lin`, while the bus driver
independently recomputes the address. Several arms are not equivalent:

- `S_LOAD` uses raw ESP/EBP in `rtl/core/core.sv:4312-4318`, but the bus applies
  `stk16()` in `rtl/core/core_bus_driver.svh:30-36`. A 16-bit stack can walk one page and
  access another.
- `S_USEQ` in `rtl/core/core.sv:4358-4362` assumes only PUSHA versus POPA and hard-codes
  four-byte spacing. The bus separately handles `CMPXCHG8B` stores and uses
  `q_w` plus `stk16()` for PUSHAW/POPAW
  (`rtl/core/core_bus_driver.svh:181-207`). Under paging, the equal `CMPXCHG8B` store and
  16-bit PUSHA/POPA can use the wrong physical page.
- `S_INT_CS`, `S_INT_CS_RET`, and `S_INT_SS` hard-code the GDT in
  `rtl/core/core.sv:4367-4369,4388-4389`; the bus honors selector.TI and can use the LDT
  (`rtl/core/core_bus_driver.svh:231-233,314-329`).
- `S_INT_PUSH` and `S_IRET` use four-byte strides in
  `rtl/core/core.sv:4370-4379`; the bus uses two-byte slots for a 16-bit gate/IRETW
  (`rtl/core/core_bus_driver.svh:274-312`).

The post-translation function assumes these values are identical
(`rtl/core/core.sv:3903-3910`). On a mismatch it can translate the wrong page
while retaining the bus address's offset, or launch a walk for a page the bus
does not access. Cross-page stack frames and operands are especially exposed.

**Required direction:** eliminate the duplicate address generator. Produce one
architectural linear address and width, feed that exact value to protection,
TLB lookup, page walk, and the bus post-translation, and assert equality at the
boundary until duplication is removed.

### C-04 — Privileged and I/O-sensitive instructions do not enforce CPL/IOPL

**Evidence:** decode and dispatch in
`rtl/core/decode_stages.sv:406-451,658-700,1364-1365,1432-1465` and
`rtl/core/core_fetch_decode.svh:227-320`.

There is no CPL0 check for LGDT, LIDT, MOV CR, MOV DR, LTR/LLDT, HLT, INVD, or
WBINVD. CLI/STI do not enforce `CPL <= IOPL`. Plain protected-mode IN/OUT and
INS/OUTS do not enforce IOPL or consult a TSS I/O bitmap. The V86 guard covers
CLI/STI/PUSHF/POPF/INT/IRET but explicitly omits IN/OUT
(`rtl/core/core_fetch_decode.svh:227-247`). RDTSC explicitly ignores CR4.TSD
(`rtl/core/decode_stages.sv:678-690`).

`sys_mode`, `soc_en`, and `cosim_en` are harness/configuration switches, not
architectural privilege. Gating execution on them cannot substitute for CPL,
IOPL, or TSS checks. A ring-3 task can reprogram paging/control registers, load
descriptor tables, stop the processor, manage caches, or access devices.

**Required direction:** centralize instruction privilege checks before side
effects and deliver `#GP(0)`/`#UD` as specified. Add CPL0–3, V86, IOPL, CR4.TSD,
and TSS I/O-bitmap negative tests.

### C-05 — Descriptor/TSS/task-switch structure addresses bypass paging

**Evidence:** `rtl/core/core_bus_driver.svh:393-406` and
`rtl/core/core.sv:4380-4389,4394-4415`.

GDT, LDT, TSS, LTR/LLDT, interrupt stack-switch, and task-switch accesses are
explicitly treated as physical under an “identity-map convention.” IA-32
stores linear bases in GDTR, LDTR, and TR; these accesses must pass through
paging. With a non-identity mapping the core reads or writes unrelated physical
memory, potentially loading attacker-controlled descriptors or corrupting
ordinary RAM.

This is not merely theoretical. The repository's boot investigation records a
real Quake failure caused by a TSS/GDT access landing at the wrong physical
address (`ao486-sim/DISK_BOOT_STATUS.md`, the non-identity task-structure
diagnosis around updates 144–149).

**Required direction:** include every descriptor-table and TSS state in the
same translated linear-access mechanism as normal data. Handle faults during
delivery/task switching, including double-fault escalation, rather than
assuming identity mappings.

## High-severity findings

### H-01 — Dual-issue `FSTP ST(i)` drops the copy and only pops

**Evidence:** fast decode `rtl/core/decode.sv:351-356`, fast writeback
`rtl/core/fpu_writeback.sv:438`, correct slow decode
`rtl/core/decode_stages.sv:1627-1633`.

Every `DD D8+i` is classified as `FK_FSTP0`. Its commit action only pops the
x87 stack. That is correct solely for `FSTP ST(0)`; for `i != 0`, x87 requires
copying ST0 into ST(i) before the pop.

A directed program in `tmp/review_jul29/fstp_sti.s` loaded ST0=3 and ST1=1,
executed `fstp %st(1)`, stored the new ST0, and branched on the result.
Functional mode reached the good PC `0x08048020`; cycle mode reached bad PC
`0x08048019` with value 1. The shipping ao486 shim enables this path by
hard-wiring `cycle_mode=1`.

**Fix:** only fast-path `DD D8` (i=0), or implement the indexed write before
the pop. Add every `i=0..7` to a fast/slow architectural-equivalence gate.

### H-02 — Dual-issue A2/A3 moffs stores retire without writing memory

**Evidence:** `rtl/core/decode.sv:234-249` explicitly says it models only
retirement/pairing; the issue/commit block in `rtl/core/core_fastpath.svh`
contains no moffs store.

A directed program in `tmp/review_jul29/moffs_cycle.s` stored `0x12345678`
with A3 and read it back. Functional mode made four byte-enabled writes and
reached good PC `0x0804801d`; cycle mode made zero writes and reached bad PC
`0x08048016`.

The fast path must never substitute a timing-only record for an architectural
operation. This can change later control flow and corrupt a deployed guest.

**Fix:** send moffs stores through the normal store FSM, while attaching timing
metadata to the retirement, or implement a real fast store handshake that
cannot retire until accepted.

### H-03 — `AAM imm8=0` executes instead of raising `#DE`

**Evidence:** acceptance at `rtl/core/decode_stages.sv:1028-1030`, zero guard
at `rtl/core/uv_common.sv:92-95`, and the explicit deferral at
`rtl/core/core.sv:2108-2116`.

`AAM 0` must raise divide error. The RTL instead produces AX=0, updates flags,
and retires. The directed trace `tmp/review_jul29/aam0.vtrace` shows the AAM
retiring at PC `0x08048005`, followed by execution of a `0xdeadbeef` sentinel.

**Fix:** detect zero at decode/execute, suppress AX/flag/EIP commit, and invoke
the same precise `#DE` delivery used by DIV/IDIV.

### H-04 — Large-page writeback sets A but omits D in memory

**Evidence:** the walker expects A+D at
`rtl/core/core_walk.svh:45-72`, and the TLB fill fabricates A+D in
`rtl/core/core.sv:3981-3990`; the actual bus write at
`rtl/core/core_bus_driver.svh:209-221` writes only `walk_pde | 0x20`.

On the first write to a clean 4 MiB page, the TLB records the page as dirty but
the PDE in memory remains clean. Software reading the page tables sees the
wrong dirty state; after TLB invalidation the core repeatedly rediscovers and
“sets” a bit it never wrote. An OS that depends on dirty tracking can lose
writeback/accounting information.

**Fix:** include bit 6 in the step-1 PDE write when `PS && walk_is_write`, and
gate a read-back test for both 4 KiB and 4 MiB A/D transitions.

### H-05 — TLB invalidation is incomplete

**Evidence:** `rtl/core/core.sv:4016-4021`; `rtl/mem/tlb.sv:25-31,115-134`.

Both TLBs flush only on MOV CR3. MOV CR0 transitions that enable/disable paging
and MOV CR4 changes affecting PSE do not invalidate entries. Thus disabling and
re-enabling paging can resurrect translations from the prior address-space
state, and changing PSE can reinterpret a cached page-size mapping incorrectly.
There is also no INVLPG implementation.

**Fix:** invalidate on architecturally relevant CR0/CR4 transitions and
implement INVLPG before claiming general protected-mode compatibility.

### H-06 — Protected control transfers, interrupt returns, and task state are not precise

This is a cluster of related partial implementations:

- CS validation in `rtl/core/ventium_sys_pkg.sv:134-166` only requires
  present/S/code. It omits conforming/nonconforming DPL/CPL/RPL rules.
  `S_LJMP` then sets CPL directly from selector.RPL
  (`rtl/core/core_seg_ljmp.svh:154-166`), allowing illegal privilege changes.
- `S_LJMP` lacks the GDT/LDT limit check that `S_SEGLD` has
  (`rtl/core/core_seg_ljmp.svh:50-105,117-168`).
- IDT delivery has no IDT-limit check or complete gate type/S/reserved-bit
  validation. Present and software-DPL checks do exist at
  `rtl/core/core_int_deliver.svh:52-67`, but conforming-code semantics are
  still wrong and CPL is always assigned target DPL at `:94-120`.
- LTR/LLDT load arbitrary descriptor contents without selector/table-limit,
  type, present, or privilege validation, and LTR omits the required GDT busy
  bit update (`rtl/core/core_tss_priv.svh:9-35`).
- Cross-privilege entry reads TSS state without `tr_valid`/`tr_limit` checks and
  loads the new SS unconditionally, despite comments documenting the missing
  rules (`rtl/core/core_tss_priv.svh:38-87`).
- IRET commits EIP/EFLAGS before validating the returned CS, then
  unconditionally loads CS/SS descriptors and CPL
  (`rtl/core/core_iret.svh:16-79,132-200`). Invalid frames can partially mutate
  state instead of faulting precisely. EFLAGS privilege restrictions are
  incomplete as well.
- Protected far CALL/RETF adjust ESP before target descriptor validation
  (`rtl/core/core_seg_ljmp.svh:172-233` and
  `rtl/core/core_gpr_wb.svh:538-549`).

These defects make malformed descriptors/frames unsafe and prevent reliable
ring transitions or recovery from faults during delivery.

**Required direction:** stage all candidate state in temporaries, fully
validate bounds/type/present/privilege first, and atomically commit only after
validation. Add negative-path tests, including faults during fault delivery.

### H-07 — x87 stack tags do not protect stack operations

**Evidence:** `fptag` is consulted for numeric classification only at
`rtl/core/fpu_writeback.sv:695-704`; pushes, arithmetic, compares, and pops at
`:650-725` operate unconditionally.

Pushing onto a full x87 stack, reading an empty ST register, or popping an
empty stack should signal invalid-operation stack fault (IE+SF with the
specified C1 behavior), with masked-indefinite behavior where appropriate.
Instead, stale register contents are consumed or overwritten and TOP/tags are
advanced as if the operation were valid.

**Fix:** make tag checks part of every x87 source/destination operation and add
overflow/underflow tests for all masked/unmasked combinations.

### H-08 — Unmasked x87 exceptions are never delivered

**Evidence:** arithmetic writeback only ORs sticky bits in
`rtl/core/ventium_x87_pkg.sv:371-385`; FWAIT is a NOP at
`rtl/core/decode_stages.sv:1006-1010` and
`rtl/core/fpu_writeback.sv:662-668`.

The control-word mask bits do not suppress/alter commit, the status ES/B
summary is not maintained as required, no `#MF`/FERR path exists, and FWAIT
never reports a pending exception. Programs that unmask IE, ZE, OE, UE, or PE
silently continue with a committed result.

**Fix:** implement masked versus unmasked completion semantics, pending
exception state, ES/B, FWAIT, and the Pentium-compatible exception-delivery
interface.

### H-09 — A20 masking occurs after both L1 caches

**Evidence:** `ao486-sim/ven/ven_ao486_shim.sv:101-105,254-267`.

The core's I-cache and D-cache tag unmasked physical addresses. A20 is cleared
only after the L1/AXI subsystem, immediately before the Avalon bridge. With A20
disabled, addresses 0 and 1 MiB can occupy two distinct L1 tags while mapping
to the same backing bytes. A write through one alias does not invalidate or
update the other cached alias, yielding stale data or instructions.

**Fix:** apply A20 before every cache/tag/snoop comparison, or explicitly
invalidate both aliases on A20 changes and every aliased write. The former is
substantially safer.

### H-10 — DMA is disconnected and cache-disable behavior is not architectural

**Evidence:** ignored `cache_disable` at
`ao486-sim/ven/ven_ao486_shim.sv:20-21`; DMA tie-off at
`ao486-sim/ven/ven_ao486_shim.sv:39-47,74-77`; CR0.CD handling at
`rtl/mem/ventium_l1_axi.sv:434-443` and `rtl/mem/ven_l1d.sv:283-303`.

ISA DMA requests are discarded, so floppy and SB16 DMA cannot work and cannot
snoop the caches. The integration's `cache_disable` input is ignored. Even
with `VEN_L1_HONOR_CD`, only write allocation is effectively avoided; reads
are explicitly allowed to allocate because the bypass FSM is disabled. The
internal instruction cache remains active. This is not CR0.CD/NW behavior.

**Fix:** connect DMA through a coherent requester/snoop path and make cache
disable affect both L1s and all allocations/hits as the selected Pentium
cache-control model requires.

### H-11 — Instruction-cache replacement can lose true-LRU ordering

**Evidence:** `rtl/mem/icache.sv:239-266,293-303`.

`touch_way` uses nonblocking assignments based on the pre-edge age array.
`always_ff` can invoke it for fill plus as many as three U/straddle/V touches in
one cycle. Multiple touches to the same set do not compose; later calls still
read old ages and overwrite only some prior assignments. This can leave
duplicate ages, no way at age `IC_WAYS-1`, and a default victim of way 0. The
problem exists even at the default two ways (e.g. sequential touches to both
ways in one edge).

**Fix:** compute next ages in one combinational fold with an explicitly defined
touch order, then perform one write per way. Assert that every valid set's ages
form a permutation.

### H-12 — External cache flush does not invalidate the I-cache

**Evidence:** `flush_all` enters `ventium_l1_axi` at
`rtl/ventium_top.sv:940-948` but connects only to `ven_l1d` at
`rtl/mem/ventium_l1_axi.sv:470-483`. I-cache invalidation receives only DMA/CPU
store snoops (`rtl/mem/ventium_l1_axi.sv:278-286`,
`rtl/core/core.sv:4674-4681`). The ao486 daemon explicitly uses this pulse for
PS-to-PL coherence (`ao486-sim/ven/ven_ao486_shim.sv:164-207`).

PS/external writes that change code can leave a valid stale I-cache line after
the advertised “flush all.” This is particularly dangerous because the same
integration exists to support host-modified guest RAM.

**Fix:** define whether the signal is D-only or all-L1; for its current API and
use, invalidate I-cache state as well and make the uop-cache unable to hit
until the refilled I-line has been re-predecoded.

### H-13 — Non-cacheable cross-line reads use an out-of-range part-select

**Evidence:** `rtl/mem/ven_l1d.sv:212-249`, especially the explicit
out-of-scope statement at `:217-219`.

The cacheable path builds a `{next,current}` window, but `L1_BYP` extracts four
bytes only from a single 32-byte `bp_line`. At byte offsets 29–31 the variable
part-select crosses the vector boundary. An unaligned word/dword MMIO or
uncacheable memory access can return X/zero/tool-dependent data rather than
performing the required split access.

**Fix:** split every bus access by the actual byte span, including
non-cacheable accesses, and merge the two responses.

### H-14 — x87 environment images and several arithmetic edge cases are wrong

The x87 environment path has multiple architectural errors:

- FCS/FDS are hard-coded constants rather than live selectors, and FDP records
  `segment_base + EA` instead of the required pointer form
  (`rtl/core/fpu_writeback.sv:462-476`).
- FLDENV/FRSTOR reload CW/SW/TOP/tags/registers but omit FIP/FCS/FDP/FDS
  (`rtl/core/fpu_writeback.sv:479-504`).
- Only 28/108-byte formats exist; operand-size-dependent 14/94-byte formats are
  absent (`rtl/core/core_fenv.svh:4-44`).
- FNSTENV does not mask exceptions after the store, explicitly by design
  (`rtl/core/core_fenv.svh:12-15`).

Additional value errors are visible in ordinary x87 operations:

- FSCALE flushes every underflow to signed zero and every overflow to infinity,
  ignoring gradual underflow and RC-dependent overflow results
  (`rtl/core/fpu_writeback.sv:820-852`). ST1 NaN/infinity/conversion-invalid
  cases are not handled.
- FPTAN hard-codes RNE in its final divide instead of using `fctrl[11:10]`
  (`rtl/core/fpu_writeback.sv:948-961`).
- FPREM/subnormal packers clamp large right shifts to 63
  (`rtl/fpu/fpu_fprem.sv:144-150`,
  `rtl/fpu/fpu_srt_div.sv:513-517`), which loses correct zero/sticky/rounding
  behavior for much tinier results.

These should be split into individually gated fixes, but together they mean
the current x87 state is not portable across save/restore and special values
are not reliably Pentium-compatible.

## Medium-severity findings

### M-01 — The cycle gate is false-green and architecturally blind

**Evidence:** cycle records intentionally contain only
`{n,pc,cyc,pipe,paired}` at `verif/tb/dpi_retire.cpp:422-448`.
`verif/lib/verify_worker.sh:243-254` records the comparator exit code but always
marks the trace usable. `verif/verify.sh:305-309` changes a metric PASS to FAIL
only when the string contains `CONTROL-FLOW DIVERGENCE`.

In the reviewed run, all 20 `*.cycle_cmp.txt` files said
`RESULT: DIVERGENT` and all 20 worker result files recorded `exit=1`; none was
a control-flow mismatch. Total-cycle differences ranged from -3.31% to +1.20%
and the separate metric bands passed, so the top-level gate passed.

There are two distinct problems:

1. The explicitly requested structural/per-instruction comparator verdict is
   discarded unless it is a PC/order mismatch.
2. Registers, flags, x87 state, and memory are absent, so a wrong operation can
   retire at the right PC and appear valid. H-01 and H-02 demonstrate exactly
   that escape.

**Fix:** make unexpected comparator exit 1 fail, or explicitly define and
report a different non-gating diagnostic. More importantly, run an
architectural equivalence stream alongside cycle mode and require identical
post-state/memory.

### M-02 — Golden-cache keys omit most inputs that define a golden

**Evidence:** `verif/lib/verify_worker.sh:101-109,184-200`.

Functional cache keys contain only source SHA, x87 flag, and max count. Cycle
keys contain only source SHA. They omit the produced ELF/flat bytes, compiler
and binutils versions, linker/load/entry settings, CPU model, QEMU binary,
GDB/plugin code and options, manifest semantics, trace generator, and
comparator format version.

A toolchain, plugin, load address, or oracle change can therefore reuse a stale
golden and produce a convincing but invalid comparison.

**Fix:** hash the final ELF or flat image plus a versioned serialization of all
oracle inputs and tool identities.

### M-03 — `verify-all` claims to run `verify-soc` but silently omits it

**Evidence:** `verif/run-verify-all.sh:5-21` lists `verify-soc` as included, but
the actual `GATES` array at `:41-49` does not contain it. The success message at
`:84-86` still claims every routine gate passed.

This can report a clean umbrella result while the documented SoC regression is
never invoked.

**Fix:** add the gate or move it to an explicit exclusion with a reason; derive
the documentation/summary from the executable list.

### M-04 — The documented L2/SoC/FPGA build is not present in this checkout

**Evidence:**

- `verif/tb/Makefile:111-128` references
  `rtl/northbridge/{ven_cachemap,ven_l2,ven_northbridge}.sv`; none exists.
- README advertises `sw/`, while README/docs extensively reference `rtl/soc/`;
  both directories are absent.
- `fpga/` contains journals/build products but no maintained
  `hw/create_project.tcl`.
- `ao486-sim/Makefile` builds the ao486 path; the working Ventium recipes are
  reconstructed in `ao486-sim/DISK_BOOT_STATUS.md` using untracked
  `rtl_ven_core.f`, `rtl_ven_soc.f`, and untracked `ao486-sim/ven/` sources.
- The actual ao486 vendor submodule is dirty, so its exact integration cannot
  be recreated from the parent commit alone.

A dry run of `make -C verif/tb l1axi_l2` confirms that the missing paths are
passed directly to Verilator.

**Fix:** commit one canonical source manifest and project-generation flow,
pin/record vendor patches, remove stale directory claims, and validate from a
fresh clone in CI.

### M-05 — Decoder accepts invalid encodings and rejects valid long-prefix instructions

**Evidence:** `rtl/core/decode_stages.sv:188-214,381-392,431-451,995-999,
1132-1158`.

- Prefix scanning stops after four prefixes, while any redundant legacy-prefix
  sequence fitting the 15-byte instruction limit must be decoded.
- The entire 0F 1E/1F space is accepted as NOP, including encodings not valid
  on a Pentium and invalid `/r` forms.
- MOV CR/DR ignores ModRM.mod and accepts reserved CR/DR numbers.
- C6/C7 accept every ModRM.reg instead of only `/0`.
- 8F accepts every ModRM.reg instead of only `/0`.
- LOCK is recorded but broadly ignored; invalid LOCK/instruction combinations
  do not raise `#UD`.
- Most invalid opcodes park the core in `S_HALT` rather than raising `#UD` in
  system mode.

This changes both exception behavior and instruction length/stream
synchronization for legal or malformed software.

### M-06 — Several valid addressing semantics are knowingly truncated

**Evidence:**

- Memory BT/BTS/BTR/BTC with a register index masks within one operand instead
  of adding the signed word/dword offset to the effective address
  (`rtl/core/decode_stages.sv:513-538`).
- Address-size-16 XLAT always uses EBX rather than BX
  (`rtl/core/decode_stages.sv:1347-1354`,
  `rtl/core/core_bus_driver.svh:42-43`).
- SGDT/SIDT are disabled whenever paging is on even though they are legal
  (`rtl/core/decode_stages.sv:416-422`).

These are deterministic wrong-address or false-`#UD`/halt cases, not merely
missing performance features.

### M-07 — CPUID advertises capabilities the core does not implement

**Evidence:** leaf 1 EDX=`0x008003bd` and hypervisor leaves at
`rtl/core/core_gpr_wb.svh:290-327`; CPUID itself is artificially gated by
`rtl/core/decode_stages.sv:658-690`.

The feature word advertises FPU, DE, PSE, TSC, MSR, MCE, CX8, APIC, and MMX.
MSR, MCE, APIC, and MMX instruction/state support is absent or falls into the
unknown/halt path. The table also claims a TCG hypervisor vendor on hardware.
Conversely CPUID and RDTSC are valid Pentium instructions but halt unless
`cosim_en || soc_en`.

Guest feature discovery can select an instruction or OS path the processor
cannot execute. Feature bits must describe this implementation, not just copy
the QEMU Pentium oracle.

### M-08 — CR0.CD support and cache-management instructions contradict each other

INVD/WBINVD retire as NOPs and do not invalidate either cache
(`rtl/core/decode_stages.sv:692-700`). `VEN_L1_HONOR_CD` still allocates read
lines (H-10). The core therefore advertises/decodes cache-control behavior
without performing the cache state transitions software relies upon.

At minimum, WBINVD/INVD and CR0.CD/NW changes need a coherent policy across
I-cache, D-cache, external writes, and outstanding transactions.

### M-09 — REP INS can perform an unintended port read at count zero

**Evidence:** the I/O request driver suppresses a degenerate REP INS only when
the full ECX is zero (`rtl/core/core_io_driver.svh:35-42`), while the FSM
correctly tests CX for address-size-16 at `rtl/core/core_io.svh:56-68`.

With CX=0 but ECX[31:16] nonzero, `io_req` is asserted. The FSM recognizes the
degenerate instruction and performs no store, but a device can still observe a
read strobe and consume FIFO/status state.

**Fix:** use the same `q_cnt16 ? ECX[15:0] : ECX` predicate in both places,
preferably a single shared signal.

### M-10 — `VEN_FP_PC_RELAX` chooses between halt and silent excess precision

**Evidence:** `rtl/core/core_fp_exec.svh:31-54`; equivalent fast-path gates in
`rtl/core/core_fastpath.svh`.

Without the define, ordinary arithmetic at PC=24 or PC=53 halts. With it—the
documented deployed configuration—the core computes full 64-bit extended
precision and ignores PC narrowing. The boot log confirms the missing define
caused a real Quake halt, after which deployment enabled the inaccurate path.

This is a configuration-selected correctness compromise, not a Pentium
precision-control implementation. The verification corpus mostly uses PC=64,
so neither behavior is adequately covered.

### M-11 — The fixed IRQ option intentionally violates guest PIT programming

**Evidence:** `rtl/ventium_top.sv:423-469`.

`VEN_RTL_IRQ_FIXED` replaces PIT IRQ0 with a configurable but initially
4,000-core-cycle square wave specifically to preempt a software reflector.
The comments acknowledge that guest time runs fast and that the real
programmed PIT cannot produce this cadence.

This is a workload workaround that changes interrupt timing and system
semantics. It should be a diagnostic build flag, never part of a
“Pentium-faithful” deployed configuration or timing result.

### M-12 — The pin-bus integration does not carry the core's data

**Evidence:** `rtl/bus/biu.sv:23-44,95-153`.

In `bus_mode=1`, the core receives combinational data/ack directly from the
back-side memory. `biu_p5` runs in parallel only as a protocol exerciser, and
the data returned on its pins is generally for a subsequent address. The
source explicitly states there is no address/data correspondence.

This can validate pin timing assertions but cannot validate that functional
reads/writes traverse the Pentium pin bus. Claims that this mode proves a
pin-level functional replica should be narrowed accordingly.

## Low-severity and engineering findings

### L-01 — Lint is nonfatal despite extensive width/latch warnings

The canonical Verilator flow uses `-Wall -Wno-fatal`
(`verif/tb/Makefile:79-86`). A direct lint of the core/filelist completed only
with warnings nonfatal and emitted 922 lines of diagnostics, including WIDTH,
UNUSED, and LATCH groups around large combinational blocks.

Some latch reports may be tool artifacts from block-local temporaries and
function/task structure, but the current policy makes real incomplete
assignments indistinguishable from accepted noise. Establish a warning
baseline, eliminate or narrowly waive each class, and make new warnings fatal.

### L-02 — MMIO silently falls through to DDR without an external device fabric

When L2 is enabled without `VEN_NB_MMIO`, device-space traffic is merged back
onto the ordinary AXI backing and treated as DDR
(`rtl/mem/ventium_l1_axi.sv:404-427`). That preserves an old test setup but
hides missing device decode and can turn a device access into ordinary RAM.

Expose an error/unsupported response or require an explicit “MMIO-as-RAM test
mode” flag.

### L-03 — Generated build output is mixed into source areas

Large generated `obj_dir` and Vivado products coexist with source and, in some
cases, appear tracked. This makes inventory, review, and clean-rebuild
validation unnecessarily difficult and encourages stale-binary execution.
Generated artifacts should live under one ignored build root.

### L-04 — Documentation contains stale or contradictory implementation status

Examples include `rtl/core/core_int_deliver.svh:20-27`, which says gate-present/DPL and
target-CS checks are deferred even though later lines implement a subset;
`verif/tb/Makefile` comments that describe older failing divider configurations
that now pass focused gates; and `run-verify-all.sh`'s nonexistent `verify-soc`
entry. Several README directory maps also describe absent trees.

Treat status comments as generated/checkable metadata where possible, and make
tests the source of truth.

### L-05 — Configuration variants are not covered as a matrix

Behavior changes materially under `VEN_L1_AXI`, `VEN_EN_L2`,
`VEN_FE_PIPE`, `VEN_UOPCACHE`, `VEN_IC_BRAM`, `VEN_FP_PIPE`,
`VEN_FP_PIPE2`, `VEN_SRT_ITER`, `VEN_FP_PC_RELAX`,
`VEN_L1_HONOR_CD`, `VEN_RTL_IRQ_FIXED`, and transcendental/offload flags.
The base functional gate does not exercise the deployed combination, while the
deployed project source is absent.

Define a small supported configuration matrix, compile every row, and run
architectural equivalence—not just build/lint—on the exact shipping row.

## Validation results

| Check | Result | Interpretation |
|---|---:|---|
| Canonical RTL inventory | 67 HDL/filelist files, 25,178 lines | Entire first-party RTL scope reviewed |
| `make verify` functional jobs | 98/98 PASS | Good coverage of the existing user-mode corpus, not proof of system/protection behavior |
| `make verify` cycle jobs | 20/20 traces and metric bands accepted | All 20 structural comparators nevertheless returned exit 1 / `DIVERGENT` |
| Cycle total difference | -3.31% to +1.20% | Aggregate totals are close; individual retire costs are not within the requested tolerance everywhere |
| Directed `AAM 0` | Reproduced | Retires AX=0 and executes following sentinel; no `#DE` |
| Directed `FSTP ST(1)` | Reproduced in cycle mode | Functional path produces 3; cycle/deployed fast path leaves 1 |
| Directed A3 moffs store | Reproduced in cycle mode | Functional path writes; cycle/deployed fast path performs zero writes |
| Iterative IDIV | PASS, 80,000 randomized vectors | No issue found in the focused divider arithmetic |
| SRT divide / sqrt | PASS, 609×2 divide cases and 8,000×4 sqrt cases | Retracts stale comments suggesting every iterative vector fails |
| BCD/FBLD/FP pipeline focused gates | PASS | Findings concern uncovered exceptions/special forms, not these passing vectors |
| Shell/Python syntax scan | PASS | No syntax error found in first-party verification scripts |
| L2/NB source existence | FAIL | All three Makefile-named northbridge files absent |

The directed test sources and traces are under `tmp/review_jul29/`. They are
scratch evidence, not product changes.

## Recommended repair order

1. **Stop false retirement and enforce precise faults.** Remove timing-only
   architectural execution from the fast path; fix H-01/H-02/H-03; make page
   permissions and segment limits suppress the bus request before adding the
   appropriate fault.
2. **Unify address generation.** One linear address/width should feed segment
   checking, TLB lookup/walk, and the bus. Translate descriptor/TSS accesses.
3. **Close privilege transitions.** Implement CPL/IOPL checks and atomically
   validated CS/SS/IDT/TSS/IRET/task-switch state.
4. **Make verification honest.** Require cycle comparator success, add
   architectural state/memory checks in cycle mode, strengthen golden keys,
   and actually run `verify-soc`.
5. **Repair cache coherency/control.** Move A20 ahead of caches, connect DMA,
   invalidate I-cache on external flush, implement CR0.CD and INVD/WBINVD
   coherently, and fix compositional LRU.
6. **Complete x87 architectural state.** Tags/stack faults, exception masks and
   FWAIT, environment formats/pointers, PC precision, and special-case
   rounding should each receive directed QEMU/SoftFloat and hardware-oriented
   tests.
7. **Restore reproducibility.** Commit the source manifests, northbridge/SoC
   sources or remove their claims, the exact FPGA project generator, and a
   clean vendor patch series. Validate the shipping configuration from a fresh
   clone.

## Overall assessment

The codebase has substantial useful engineering: the ordinary functional
corpus is broad, focused arithmetic gates are strong, many comments accurately
identify intentional deferrals, and a number of difficult boot-path defects
have clearly been traced and repaired. Those strengths also explain the core
risk: development has optimized for keeping existing corpus behavior
byte-identical, frequently by gating new correctness behind mode flags or by
calculating a fault and leaving delivery for later.

For an i586 replica, architectural negative paths are not optional edges.
Protection, exception precision, cache aliasing, and malformed encodings are
part of the processor contract. Until the critical and high findings above are
fixed and tested, successful boot/workload demonstrations and aggregate cycle
matches should not be interpreted as general Pentium correctness.
