# Ventium i586 RTL review — August 1, 2026

## Executive summary

This is a continuation and current-tree consolidation of the July review, with
special emphasis on the newly enabled system/boot fast path and on cache/SoC
coherence. I reviewed the dirty worktree at `219c124` on branch
`ao486-mister-sim`; no product source was changed. All new experiments and
build output are under `tmp/`.

The immediate boot regression is identified and reproduced in the complete
core. **System-fast instructions reach the S_PIPE retirement arm, advance EIP,
and can retire in pairs, but the extracted GPR writeback block still contains
the old `sys_mode` bailout. Register-writing instructions therefore retire
without writing their destination.** This is the direct explanation for the
existing bisect in `ao486-sim/DISK_BOOT_STATUS.md`: decoder and U-pipe tests
pass, while permitting register-writing 16-bit fast operations breaks POST.

The smallest reproducer is:

```asm
mov ax, 0x1234
cmp ax, 0x1234
jne bad
```

The normal system core takes the good path. A build with
`VEN_SYS_FASTPATH`/`VEN_SYS_FASTPATH_ALL` retires the MOV, CMP, and JNE but
takes `bad`; AX never received `0x1234`. This is not a cycle-accounting-only
problem.

The root cause is broader than the one stale guard. The issue condition is
manually mirrored in the spine, GPR writeback, BTB resolve, I-cache LRU, and
D-cache/load logic. Those copies have already drifted apart. A one-line change
to the GPR guard would expose a second architectural failure: the decoder can
admit a 32-bit register-base load in eligible system mode, while the memory
request remains hard-gated by `!sys_mode`; the instruction can retire with no
request and eventually write stale `mem_rdata`.

The cache/SoC review also produced six deterministic race/protocol
reproductions: three L1D stale-data races, an I-cache fill/snoop resurrection,
a two-cycle I/O read strobe that consumes two floppy result bytes, and a
shutdown status that reports the AXI master idle while a CDC command is queued.

The consolidated open register below contains **6 critical, 20 high, 17
medium, and 5 low-severity findings**. Some earlier July findings have been
fixed; those are listed separately so this report does not present obsolete
results as current bugs.

## Scope and method

The active source scope was:

- all HDL under `rtl/` (25,821 lines in the current tree), including every
  core include, decode/issue/writeback unit, MMU/TLB, cache, AXI/CDC block,
  FPU/x87 unit, and top-level integration;
- the active first-party ao486 shim and AXI/Avalon bridge under
  `ao486-sim/ven/`;
- the modified integration-relevant ao486 RTL, especially `system.v`,
  `l2_cache.v`, `iobus.v`, and side-effecting I/O devices;
- build/filelist and verification code under `verif/`, plus the prior review
  and boot-investigation records.

The combined RTL/integration/verification text considered is approximately
95,309 lines. Generated Verilator/Vivado output, disk images, ROM data tables,
and unmodified upstream implementation detail were not treated as authored
Ventium design source.

The current worktree already contained 63 modified first-party files (2,080
insertions and 279 deletions), modified submodules, and multiple untracked
source/test trees. This review preserved that state. Three currently referenced
northbridge files and the advertised `rtl/soc/` and `sw/` trees are absent from
this checkout; pending copies in another worktree were inspected only to assess
integration risk and are explicitly labeled as such below.

Methods included static line-by-line control/data-flow tracing, comparison of
the system-fast and slow retirement paths, full-core differential
reproduction, focused Verilator testbenches for cache/CDC/I/O races, existing
L1 gates, compile-configuration checks, and review of verification blind spots.

Severity used here:

- **Critical:** breaks fundamental execution, address correctness, or
  architectural isolation in a supported mode.
- **High:** deterministic architectural corruption, stale memory, major
  exception omission, or deployed integration failure.
- **Medium:** protocol fragility, significant fidelity/performance defect,
  verification escape, or reproducibility gap.
- **Low:** maintainability, diagnostics, documentation, or configuration-risk
  issue that materially makes future bugs harder to prevent.

## Root cause of the boot fast-mode failure

### C-01 — System-fast register writes are unconditionally discarded

**Evidence:** `rtl/core/core_fastpath.svh:323-329` versus
`rtl/core/core_gpr_wb.svh:693-760`, especially `:723`.

The sequential S_PIPE spine was changed from:

```systemverilog
else if (!u_d.simple || sys_mode) ...
```

to, under `VEN_SYS_FASTPATH`:

```systemverilog
else if (!u_d.simple || (sys_mode && !sys_fp_ok)) ...
```

That permits a simple instruction to reach the integrated issue/retirement
arm in eligible system mode. The separately extracted GPR writeback mirror was
not changed. Its empty guard remains:

```systemverilog
else if (!u_d.simple || sys_mode) begin end
```

Consequently, the spine commits flags/EIP/retirement and records AGI writes,
but `gpr_we` remains zero. MOV, ALU, LEA, shift, and load destinations are
dropped. Branches then consume the old registers/flags and diverge.

The full-core reproduction in `tmp/review_aug1/fastboot_gpr_repro.S` boots a
64-KiB BIOS image at F000:FFF0 and checks two 16-bit MOVs. The slow system core
retired nine instructions in 144 clocks and followed:

```text
fff0, 0000, 0003, 0006, 0008, 000b, 000f, 0011, 0014  (good HLT)
```

The system-fast build retired six instructions in 102 clocks and followed:

```text
fff0, 0000, 0003, 0006, 0017, 001a  (bad HLT)
```

The decoder suite still passes all 24 checks and the U-pipe suite passes all
530 checks, because neither drives the integrated S_PIPE GPR writeback mirror.
This exactly matches the prior `VEN_D16_NOWREG` bisect, where rejecting all
register-writing fast operations was the first variant to reach POST.

**Required direction:** create one canonical combinational `pipe_issue_fire`
predicate and consume it for retirement, GPR/flags writes, BTB resolve, cache
touches, trace, and every other issue side effect. Do not repair this by editing
only line 723. Add an assertion that any retiring `u_d.wreg` instruction has
the expected GPR write-enable and a full-core slow/fast architectural-state
comparison.

## Other critical findings

### C-02 — Paging permissions are calculated and discarded

**Evidence:** `rtl/core/core.sv:5485-5500` computes `perm_fault`; the value is
sent only to the lint sink at `:5529-5551`.

The D-TLB carries effective U/S and R/W permission bits, and the logic detects
user access to supervisor mappings and writes to read-only mappings. The bus
request is not blocked and no protection `#PF` is delivered. Instruction-fetch
permissions are not checked at all. CR0.WP behavior is therefore also not
architectural. Ring separation cannot be relied upon.

**Required direction:** check both I- and D-side permissions before request
issue, suppress all side effects on failure, set CR2 and the complete page-fault
error code, and deliver the fault precisely.

### C-03 — Segment-limit enforcement is a dead and incomplete calculation

**Evidence:** `rtl/core/core.sv:3946-3952` computes
`seg_off_over_limit`; `:5529-5536` only consumes it as a lint sink.

Over-limit accesses continue to memory. The expression assumes a four-byte
access, does not implement expand-down segments, does not distinguish SS from
other segments, and does not cover instruction fetches or the endpoints of
string operations. The hidden segment limits are therefore largely
decorative.

**Required direction:** use the real access width and segment type at linear
address generation, cover fetch/stack/string endpoints, and raise precise
`#SS` or `#GP` before a transaction.

### C-04 — Paging lookup and bus address are still generated independently

**Evidence:** compare `cur_lin` in `rtl/core/core.sv:4382-4470` with
`mem_addr` in `rtl/core/core_bus_driver.svh:15-428`.

Several earlier mismatches were repaired, but important copies still differ:

- S_LOAD stack reads use raw ESP/EBP in `core.sv:4392-4395`, while the bus
  applies `stk16()` at `core_bus_driver.svh:30-36`.
- S_USEQ uses fixed four-byte spacing in `core.sv:4438-4442`, while the bus
  uses `q_w`, `stk16()`, and also has a CMPXCHG8B store arm.
- S_INT_CS/S_INT_CS_RET use GDT unconditionally in `core.sv:4447-4449`, while
  the bus honors selector.TI at `core_bus_driver.svh:253-255,336-338`.
- The lookup side still uses fixed four-byte interrupt/IRET strides in several
  arms while the bus has 16-bit-gate two-byte forms.

The TLB can therefore walk one linear page and apply that translation to an
access generated from another address. Cross-page 16-bit stack operations are
especially exposed.

**Required direction:** remove the duplicate generator. One architectural
linear address/width record must feed limits, permissions, TLB lookup, page
walk, and post-translation. Assert equality until the duplication is gone.

### C-05 — Privileged and I/O-sensitive instructions lack CPL/IOPL enforcement

**Evidence:** system decode in
`rtl/core/decode_stages.sv:360-451,658-709,1375-1474` and dispatch in
`rtl/core/core_fetch_decode.svh:227-320`.

There is no general CPL0 check for LGDT/LIDT, MOV CR/DR, LTR/LLDT, HLT, INVD,
or WBINVD. CLI/STI do not generally enforce `CPL <= IOPL`; protected-mode
IN/OUT and INS/OUTS neither enforce IOPL nor consult the TSS I/O bitmap. The
V86 special guard covers a subset of flag/control instructions and omits port
I/O. RDTSC ignores CR4.TSD. Harness switches such as `sys_mode`, `soc_en`, and
`cosim_en` are not architectural privilege checks.

**Required direction:** centralize privilege validation before side effects
and add CPL0-3, V86, IOPL, CR4.TSD, and TSS bitmap negative tests.

### C-06 — Descriptor, TSS, and task-switch structures bypass paging

**Evidence:** the explicit exclusions in
`rtl/core/core_bus_driver.svh:415-428` and
`rtl/core/core.sv:4481-4495`.

GDT/LDT descriptor reads, LTR, TSS stack lookup, and task-switch state accesses
are treated as physical under an identity-map assumption. IA-32 defines these
bases as linear addresses. Once paging is enabled with non-identity mappings,
the core reads or writes the wrong physical structures. This also bypasses
normal paging protection and fault delivery.

**Required direction:** translate all architecturally linear system-structure
accesses and make their faults precise; keep only page-table-walk and defined
physical save-map operations physical.

## High-severity fast-path findings

### H-01 — A system-fast load can retire without issuing a memory request

**Evidence:** `rtl/core/decode.sv:181-190` can mark a 32-bit register-base MOV
load simple; the S_PIPE spine permits eligible system instructions at
`core_fastpath.svh:323-329`. But `pipe_load_req` is hard-gated by `!sys_mode`
at `rtl/core/core.sv:2839-2840`, and `u_load_acc` repeats that exclusion at
`:4544-4547`.

Today C-01 suppresses the destination write too. If only the stale GPR guard is
fixed, a protected flat 32-bit system load can reach retirement with no D-side
request and write whatever happens to be on `mem_rdata`.

**Required direction:** until a fast load uses the same segmented, checked,
translated request path as the slow FSM, exclude all memory forms from system
fast mode. Then test faults, page crossings, segment overrides, MMIO, and cache
misses before enabling them.

### H-02 — 16-bit fast shifts commit 32-bit SF/OF and zero tests

**Evidence:** `rtl/core/core_fastpath.svh:405-416` manually constructs EFLAGS
with `u_sh[31]` and `u_shm1[31]`, and compares all 32 result bits for zero.

For a 16-bit shift, SF and OF derive from bit 15 and ZF derives from the low
16 bits. The width-aware `u_flags` produced by `u_pipe` is not used here. This
is why 530/530 U-pipe checks do not validate the actual committed flags.

**Required direction:** commit the width-aware shared flag result rather than
duplicating shift flag construction in the spine.

### H-03 — Ordinary 16-bit fast EIP advance and fallthrough do not wrap

**Evidence:** special FP retirement received 16-bit wrapping at
`rtl/core/core_fastpath.svh:311-321`, but ordinary integer issue computes
full-width `post_eip` at `:450`, full-width branch fallthrough at `:455,469`,
and assigns it at `:485`.

Sequential or not-taken control flow crossing offset FFFF continues into the
next 64-KiB linear region instead of wrapping the 16-bit IP. Taken branch
targets were separately fixed, which makes the remaining asymmetry easy to
miss.

### H-04 — Uop-cache predecode has no operand-size/default-size input

**Evidence:** the live decoders receive `.def16(def16)` at
`rtl/core/core.sv:2743-2750`. The predecode walker instantiates the same decoder
without `def16` at `rtl/mem/uopcache.sv:218-224`; the V reference decoder in
`core.sv:2729-2730` also omits it.

With `VEN_UOPCACHE` plus system fast mode, a 16-bit line is walked with an
unconnected/default size and stores wrong boundaries/uops. A configuration
warning already reports the missing pin.

**Required direction:** carry default operand/address size into predecode and
include it in uop-cache validity/tagging, or invalidate on CS.D changes. Add a
real-mode/uop-cache boot test.

## High-severity cache, coherence, CDC, and SoC findings

### H-05 — L1D hit capture races a same-line snoop and later returns stale data

**Evidence:** `rtl/mem/ven_l1d.sv:172-179,289-303,445-455`.

`do_rd_cap` is not suppressed by `snoop_inv_valid`. On a registered hit and
same-cycle snoop, the old window is captured and `rd_armed` is set while the
array valid bit is cleared. The next response uses `rd_match`, not current
tag/valid, and acknowledges the stale captured word.

Directed result:

```text
REPRO HIT_SNOOP_RACE stale=11110000 backing=22220000
```

### H-06 — L1D global flush during a fill does not cancel the fill

**Evidence:** fill state at `rtl/mem/ven_l1d.sv:401-417`; flush only clears
current valid bits at `:431-435`.

A flush in the middle of an eight-beat line fill is forgotten. Later beats
continue and the final beat validates the victim, potentially creating a mixed
pre/post-flush line.

```text
REPRO FLUSH_DURING_FILL stale=11110000 backing=22220000
```

### H-07 — L1D snoop during a fill does not poison or cancel that fill

**Evidence:** `rtl/mem/ven_l1d.sv:401-417,445-455`.

The victim tag/valid are installed only on the final beat, so a snoop arriving
earlier cannot match it. Even a same-cycle final-beat snoop compares the old
tag/valid because of nonblocking assignment semantics, despite the comment
claiming last-write wins.

```text
REPRO SNOOP_DURING_FILL stale=11110000 backing=22220000
```

### H-08 — I-cache fill completion can resurrect a snooped line

**Evidence:** allocation at `rtl/mem/icache.sv:289-309` and snoop at
`:315-324`.

On `fill_done` plus same-line snoop, the snoop compares pre-edge tag/valid and
does not clear the newly assigned valid bit. A snoop earlier in the fill has
the same lost-invalidation problem.

```text
REPRO ICACHE_FILL_SNOOP_RACE line_remains_valid=1
```

Because the uop cache is invalidated/populated around I-cache fill completion,
this race can amplify stale instruction bytes into stale predecode state.

### H-09 — Two independent instruction invalidations collapse into one address

**Evidence:** `rtl/mem/ventium_l1_axi.sv:285-296`.

The I-cache has one invalidation address:

```systemverilog
valid = l1d_snoop_valid | core_we;
addr  = l1d_snoop_valid ? l1d_snoop_addr : core_lin;
```

A DMA snoop and CPU store in the same cycle are two independent events, but the
CPU-store line is dropped. Also, an unaligned CPU store crossing a 32-byte
instruction line invalidates only its first line. Both leave executable stale
bytes resident.

### H-10 — I-cache has no cacheability/KEN input

**Evidence:** `rtl/mem/icache.sv` exposes fill, lookup, snoop, and flush ports
but no cacheability decision; the L1D receives cacheability from the
northbridge path in `rtl/mem/ventium_l1_axi.sv:270-405`.

Instruction fetches from uncacheable or MMIO regions can still allocate in L1I.
The I- and D-side memory-type behavior is therefore inconsistent.

### H-11 — L2 invalidation loses collisions and does not cancel fills

**Evidence:** modified vendor
`3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v:75-81,351-415`.

The dirty/tag RAM mux gives `update_tag_we` priority over `l2_inv_pulse`. The
comment assumes the pulse only occurs while the CPU is idle, but the interface
does not enforce this. An invalidation during FILLCACHE is not recorded or
used to cancel the fill; the final fill tag update can revalidate stale data.
An exact write-port collision drops the invalidation outright.

### H-12 — Shutdown can report idle while a CDC command is pending

**Evidence:** `m_idle` is only the AXI master FSM state in
`rtl/mem/ven_axi_master.sv:247-259`. The command/response FIFO occupancy and
CDC FSM state in `rtl/mem/ven_axi_cdc.sv:71-170` are not included in the status
exported by `ventium_l1_axi`.

```text
REPRO CDC_SHUTDOWN_IDLE cdc_busy=1 master_idle=1
CDC_PENDING_COMMAND_HIDDEN_BY_M_IDLE
```

The overlay may therefore be declared safe to remove before a queued command
reaches the AXI master.

### H-13 — One logical I/O read asserts the device read strobe for two clocks

**Evidence:** modified vendor `3rd-party/ao486_MiSTer/rtl/soc/iobus.v:88-101`
asserts `bus_read` in both S_READ and S_READ_W.

```text
REPRO IOBUS_READ_STROBE high_cycles=2
IOBUS_DOUBLE_READ_REPRODUCED
```

Several devices edge-detect or tolerate the level. The floppy does not:
`floppy.v:233,246,465,631,657` directly consumes `io_read` to clear state,
decrement `reply_left`, and shift the reply FIFO. A single guest FDC data-port
read therefore consumes two result bytes and can clear IRQ/busy early.

### H-14 — A20 masking is performed after the L1 caches

**Evidence:** `ao486-sim/ven/ven_ao486_shim.sv:102-105,257-264` masks AXI
addresses after Ventium's L1 hierarchy.

With A20 disabled, addresses that alias at physical memory can occupy distinct
L1 lines and return different data. A20 must participate before cache lookup,
tagging, invalidation, and fills.

### H-15 — DMA coherence and architectural cache-disable behavior remain incomplete

**Evidence:** the current default L1 integration ties the snoop source off at
`rtl/mem/ventium_l1_axi.sv:466`; CR0.CD behavior is conditional/partial around
`:228-270,374-405` and in `ven_l1d.sv:306-321`.

There is no deployed general DMA snoop path, and CD can suppress selected write
allocation behavior while reads continue allocating. This is not the i586
cache-disable model and cannot maintain coherence with external writers.

### H-16 — Non-cacheable cross-line reads return zero high bytes

**Evidence:** `rtl/mem/ven_l1d.sv:212-231,250-264` zero-extends the bypass
buffer and explicitly reports that split access is not implemented.

This fixed an out-of-range/tool-dependent select, but not the architecture.
An unaligned read at offsets 29-31 requires data from the following line; the
current implementation deterministically returns zero for those high bytes.

## Other high-severity architectural findings

### H-17 — Protected control transfers, returns, and task state are incomplete

The current implementation has gained substantial interrupt/call-gate/task
logic, but still relies on well-formed-corpus assumptions and computes several
required checks only for lint. TSS validity/limit checks are explicitly called
out as not delivered at `rtl/core/core.sv:5557-5567`. Not-present, selector,
privilege, nested-task, and partial-frame fault cases are not uniformly
restartable or precise.

### H-18 — x87 stack tags do not guard stack use

Tag state exists, but arithmetic/load/store paths generally consume physical
stack data without turning empty-stack use or stack overflow into the required
stack-fault condition. Stale physical values can participate in later results.

### H-19 — Unmasked x87 exceptions are recorded but not delivered

The x87 path updates status/control bookkeeping but does not provide the
architectural exception-delivery behavior expected after unmasked faults and
WAIT/FWAIT interaction. Guests that unmask exceptions can silently continue.

### H-20 — x87 environment images and arithmetic edge behavior remain inaccurate

Environment save/restore and several exceptional/transcendental/remainder
paths retain corpus-driven approximations. The current `VEN_FP_PC_RELAX`
choice can prefer silent excess precision over a halt rather than enforce the
x87 precision-control result. These are architectural state defects, not only
timing differences.

## Medium-severity findings

### M-01 — Fast-path side effects use divergent hand-copied issue predicates

**Evidence:** besides C-01, BTB `issue_arm` still requires `!sys_mode` at
`rtl/core/core.sv:2941-2950`, and `ic_int_issue` repeats the old system guard at
`:4700-4703`.

Eligible system-fast branches never train the BTB and committed system-fast
instructions do not touch I-cache LRU. These are primarily performance and
replacement defects today, but they prove that side-effect equivalence is not
structural. The same pattern caused C-01 and H-01.

### M-02 — The cycle gate is architecturally blind and can be false-green

Cycle traces contain PC/cycle/pipe metadata but omit GPRs, EFLAGS, memory
effects, exceptions, segment state, and most x87 state. The full-core fast
reproducer visibly retires MOV/CMP/JNE and looks structurally plausible while
its AX write is missing. Unit decode and U-pipe checks also pass. A PC-only
comparison cannot establish functional equivalence.

The verification scripts also distinguish informational cycle divergence from
gating failures, so nonzero comparison outcomes are not consistently fatal.

### M-03 — AXI read completion ignores RLAST

**Evidence:** `rtl/mem/ven_axi_master.sv:298-315` leaves R_DATA by beat count
and only asserts RLAST alignment at `:411-415`.

For a compliant slave this is equivalent. With early RLAST, the master waits
for beats the slave considers complete; with late/missing RLAST, it drops
RREADY after its count. A sticky watchdog reports the failure but cannot make
the channel protocol-correct or retract an outstanding transaction.

### M-04 — AXI-to-Avalon read bridge has no elastic response storage

**Evidence:** `ao486-sim/ven/ven_axi2avalon.sv:89-110,125-154` forwards Avalon
data only while state is S_RD_DATA and assumes AXI RREADY never backpressures.

A zero-latency Avalon slave that asserts `readdatavalid` on the same cycle the
S_RD_CMD command is accepted loses that beat because state changes only after
the edge. Any future AXI backpressure also loses data. The current registered
L2 happens to hide this latent contract mismatch.

### M-05 — Multiple same-cycle I-cache LRU touches do not compose as true LRU

**Evidence:** `rtl/mem/icache.sv:304-314` can call `touch_way`/`do_touch`
multiple times in one `always_ff` block. Each task sees pre-edge ages and uses
nonblocking assignments; later calls overwrite earlier updates rather than
operating on the state produced by the previous touch. Replacement order can
therefore differ from the documented U → straddle → V sequence.

### M-06 — Global I-cache flush is unconnected in non-L1-AXI variants

**Evidence:** `rtl/core/core.sv:4724-4763` connects `.flush_all(ic_flush_all)`
only under `VEN_L1_AXI`; the else branch supplies snoop pins and omits the
required flush pin. Verilator reports the missing connection in the default
full-core configuration. The deployed L1-AXI top does connect it at
`rtl/ventium_top.sv:500`.

### M-07 — There is no end-to-end SoC verification gate

The current verification aggregate more honestly excludes unavailable SoC
work than the earlier script, but it still does not build and execute the
documented northbridge/L2/device path. Cache, bridge, CDC, interrupt, and
device-side effects therefore lack a single mandatory integration test.

### M-08 — The documented L2/SoC build is incomplete in this checkout

The current filelists reference `rtl/northbridge/ven_cachemap.sv`,
`ven_l2.sv`, and `ven_northbridge.sv`, but they are absent. `rtl/soc/` and
`sw/` are also absent. Pending versions exist only in another worktree. The
active checkout cannot independently reproduce the advertised SoC.

### M-09 — Invalid encodings and long prefix sequences are not decoded precisely

Several system/control decodes use only the opcode and ModR/M reg field while
ignoring required ModR/M mode restrictions or reserved encodings. The fetch
window/prefix machinery also imposes a short fixed window, so otherwise valid
long-prefix instructions can be rejected rather than reaching architectural
15-byte handling. Negative `#UD` coverage is sparse.

### M-10 — Valid address-size and cross-boundary semantics remain truncated

Several specific address bugs have been fixed (including XLAT and some
second-read translations), but 16-bit stack wrapping, cross-page operands,
descriptor-table choices, and non-cacheable split reads remain implemented in
separate ad hoc arms. C-04 and H-16 are concrete examples of the larger risk.

### M-11 — CPUID advertises behavior that is not consistently implemented

The fixed CPUID table and reset signature are harness/configuration dependent,
while advertised features are not all backed by complete exception/control
semantics. Software can select paths based on capabilities the core only
partially supports.

### M-12 — CR0.CD, INVD, WBINVD, and external flush semantics contradict one another

Cache disable is partly interpreted as a KEN/write-allocation hint, global
flush behavior depends on build configuration, and cache-management
instructions do not consistently implement writeback/invalidate semantics
across L1I, L1D, and L2. These need one architectural cache-control contract.

### M-13 — `VEN_FP_PC_RELAX` trades a halt for silent excess precision

The relaxed configuration keeps execution moving when precision-control
handling is incomplete, but can commit a result with the wrong x87 precision.
Configuration should not silently choose between two architecturally wrong
outcomes.

### M-14 — Fixed IRQ mode intentionally ignores guest PIT programming

The fixed IRQ option drives a host-selected cadence rather than the guest's
programmed PIT behavior. It is useful as a bring-up mode but is not i586/PC
platform fidelity and should not be enabled in correctness claims.

### M-15 — The pin-bus integration does not carry a complete functional data path

The exposed pin/timing seam primarily models bus activity and does not provide
a complete independent functional data return/ownership path. It cannot yet
serve as an external-memory correctness implementation without the internal
memory model.

### M-16 — Device MMIO can silently fall back into DDR

**Evidence:** `rtl/mem/ventium_l1_axi.sv:414-423` merges the northbridge MMIO
master back into the DDR path when `VEN_NB_MMIO` is absent. An unmapped/device
access can therefore read or modify ordinary memory instead of faulting or
reaching a device.

### M-17 — The standalone L1D gate is stale against the module interface

The current `verif/l1/tb_l1d.sv` omits the added `dbg_serve` pin and the normal
warning-fatal flow stops at build time. Other L1 gates pass, so the most
important cache block can be accidentally skipped while integration results
still appear healthy.

## Low-severity and engineering findings

### L-01 — Lint is nonfatal despite numerous width/latch/configuration warnings

Warnings include the missing uop-cache `def16` and default-build I-cache
`flush_all` connections, in addition to many existing width/latch warnings.
Those two warnings correspond to real defects in this report. A ratcheted
warning baseline is needed.

### L-02 — Generated output and large artifacts are mixed into source areas

Verilator objects, snapshots, disk images, and experimental outputs coexist
with authored sources. This obscures the real dependency set and makes review
and clean reproduction harder.

### L-03 — Comments and documentation assert assumptions the implementation violates

For example, `rtl/core/core.sv:788-794` says the fast path's missing 16-bit and
segment assumptions are already implemented, while the memory request,
writeback mirrors, uop-cache predecoder, flags, and EIP advance remain
inconsistent. Similar “last wins” cache comments ignore pre-edge tag/valid
semantics.

### L-04 — Configuration variants are not tested as a matrix

`VEN_SYS_FASTPATH`, `VEN_SYS_FASTPATH_ALL`, `VEN_UOPCACHE`, `VEN_L1_AXI`,
`VEN_AXI_CDC`, BRAM/combinational cache options, and FP relaxation materially
change behavior. Tests cover favored combinations rather than compiling and
running all supported interactions.

### L-05 — Assertions report several protocol violations without making them recoverable

RLAST alignment, watchdog, and many protection values are monitored or sunk,
but the design continues or halts after side effects rather than preventing
the invalid transaction. Assertions are useful diagnostics, not substitutes
for functional gating and precise exception paths.

## Directed validation results

### Full-core fast-mode reproduction

Source: `tmp/review_aug1/fastboot_gpr_repro.S`

Slow/core-default command:

```sh
verif/tb/obj_dir/tb_ventium \
  --image tmp/review_aug1/fastboot_gpr_repro.bin \
  --system --cycle --max-insn 12 --max-cycles 5000 --quiesce 64
```

Result: good HLT, 9 retired instructions, 144 clocks.

Fast build used `VEN_SYS_FASTPATH` and `VEN_SYS_FASTPATH_ALL`; result: bad HLT,
6 retired instructions, 102 clocks. The retirement traces are
`tmp/review_aug1/slow_rerun.vtrace` and
`tmp/review_aug1/fast_rerun.vtrace`.

Negative controls:

```text
DECODE16: PASS  (24 checks, 0 failures)
UPIPE16: PASS   (530 checks, 0 failures)
```

### Cache/SoC race tests

Sources are under `tmp/review_cache_soc_jul29/` and were rebuilt against the
current RTL:

```text
REPRO HIT_SNOOP_RACE stale=11110000 backing=22220000
REPRO FLUSH_DURING_FILL stale=11110000 backing=22220000
REPRO SNOOP_DURING_FILL stale=11110000 backing=22220000
L1D_COHERENCE_RACES_REPRODUCED

REPRO ICACHE_FILL_SNOOP_RACE line_remains_valid=1
ICACHE_FILL_SNOOP_RACE_REPRODUCED

REPRO IOBUS_READ_STROBE high_cycles=2
IOBUS_DOUBLE_READ_REPRODUCED

REPRO CDC_SHUTDOWN_IDLE cdc_busy=1 master_idle=1
CDC_PENDING_COMMAND_HIDDEN_BY_M_IDLE
```

Existing steady-state I-cache snoop, L1-AXI, CDC-ratio, and AXI-watchdog gates
pass. They do not exercise the collision windows above. The standalone L1D
gate fails to build because its testbench interface is stale. Several deployed
cross-line/SoC gates cannot build because the referenced northbridge sources
are missing.

`git diff --check` is clean. No product source was modified by this review.

## Findings resolved since the July report

The following July findings are no longer reported as open in their original
form:

- dual-issue `FSTP ST(i)` copy/pop ordering was repaired;
- fast A2/A3 moffs stores are rejected from the unsupported fast arm;
- `AAM imm8=0` now raises divide error;
- large-page first-write handling now sets PDE D as well as A;
- TLB/INVLPG invalidation was expanded (currently conservative/over-flushing);
- REP INS count-zero side effects were repaired;
- XLAT address-size and bit-string indexing errors were repaired;
- cache-golden keys were strengthened;
- a global I-cache flush input was added and connected in the L1-AXI top;
- the non-cacheable cross-line out-of-range select was made deterministic.

The last two are only partial: M-06 documents the unconnected non-L1 variant,
and H-16 documents the still-wrong high bytes of the cross-line read.

## Recommended repair order

1. **Unify fast issue/commit.** Introduce one `pipe_issue_fire` record and use
   it for every architectural and microarchitectural side effect. Disable all
   system-fast memory forms until they share the checked slow-path address
   pipeline.
2. **Add an architectural differential gate.** Compare GPRs, EFLAGS, segments,
   exceptions, memory stores, and x87 state after every retire in slow versus
   fast mode. Include real-mode 16-bit, protected 16-bit, protected flat 32-bit,
   and UOPCACHE configurations.
3. **Fix 16-bit integrated commit semantics.** Use shared width-aware flag and
   EIP helpers; thread `def16` through uop predecode and validity.
4. **Make invalidation transactional.** Track fill line/tag and an
   invalidate/flush generation; cancel or poison an in-flight fill, clear
   captured hit windows, cover both lines of split stores, and arbitrate
   simultaneous invalidations without loss.
5. **Fix quiesce and I/O strobes.** Export CDC-empty/core-idle plus AXI-idle as
   the shutdown condition, and make device reads one-cycle pulses (or make every
   device consume an explicit acceptance edge).
6. **Unify linear address and protection.** One address record should feed
   segment limits, paging permissions, lookup/walk, and bus translation; then
   make CPL/IOPL/TSS/descriptor faults precise.
7. **Restore a reproducible SoC gate.** Bring the referenced source set into
   the checkout, repair stale standalone tests, and run compile/runtime matrices
   for every supported define combination.

## Overall assessment

The current design has a substantial compatibility corpus and many targeted
repairs, but the new system fast mode is not functionally equivalent to the
multi-cycle path. The immediate boot failure is a proven stale writeback guard,
and the same duplicated-predicate architecture already contains another
latent corrupting load case plus BTB/cache drift. The cache hierarchy and SoC
boundary also contain reproducible lost-invalidation and side-effect races.

The safest short-term boot fix is to keep system execution on the slow FSM, or
permit only a small, explicitly register-only fast subset behind a single
canonical commit predicate. Broad system-fast enablement should wait for
architectural state differential tests and transactional invalidation.
