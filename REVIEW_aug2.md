# Ventium code review — 2026-08-02

## Executive summary

This review does **not** support the statement in `PROGRESS_aug2.md` that 41 of 43
findings are closed. A substantial fraction of the changes are useful partial fixes,
but several of the most safety-critical claims are contradicted by the active RTL.

I found **9 critical, 15 high, and 7 medium** remaining defects or incomplete
architectural paths. The highest-risk results are:

1. The new page-crossing store sequence does not probe first. It performs the original,
   unsplit write, waits for its acknowledgement, and only then enters the advertised
   probe/write/write sequence. `pxpage` passes because it checks the two intended frames
   but never checks the foreign physically-adjacent frame that the first write corrupts.
2. Split load/store state is not cleared on a fault. A second-page fault leaves
   `xp_pend` or `xs_act` live while the exception handler runs, so a later handler memory
   instruction can be interpreted as the continuation of the faulted transfer.
3. A denied write that initially misses the TLB sets the PTE/PDE Dirty bit before page
   permissions are checked. The access itself is later squashed, but the page table was
   already modified.
4. `cur_lin` still disagrees with the bus address for paged XLAT, CMPXCHG8B, 16-bit
   PUSHA/POPA, 16-bit interrupt/IRET frames, and LDT-backed interrupt targets. LGDT/LIDT
   bypass paging; SGDT/SIDT can instead use the D-TLB lookup for linear address zero.
5. Inter-privilege IRET's `S_IRET_SS` state reads the current stack, not the popped SS
   descriptor. IRET also commits EIP/EFLAGS/ESP before validating CS/SS.
6. LOCK remains a functional no-op, all per-access segment protection remains disabled,
   and the advertised I-cache/D-cache cache-disable behavior is still incomplete.

The current green umbrella is real but narrower than these failures: `make
-j$(nproc) verify-all` passed all 10 included gates, while explicitly excluding the SoC
gate and the artifact-dependent Quake/Win95 runs. `make -C verif/tb l1axi_l2` fails
immediately because the three northbridge/L2 RTL sources are absent.

## Review baseline and method

- Reviewed branch: `ao486-mister-sim`
- Reviewed commit: `f6f6ced` (`REVIEW2: close 41 of 43 findings; verify-all 6 -> 10 gates`)
- Reconciled against: `PROGRESS_aug2.md`, `REVIEW2_Aug1.md`, and the live source rather
  than relying on status comments.
- The worktree already contained dirty submodules:
  `3rd-party/ao486_MiSTer` and
  `verif/fpu87/extern/berkeley-softfloat-3`. They were not modified by this review. The
  ao486 L2 finding below describes the live dirty submodule code and is therefore not
  necessarily part of commit `f6f6ced`.
- No product RTL was changed. This file is the only review output.

Verification run during this review:

| Command | Result | Important qualification |
|---|---:|---|
| `make -j$(nproc) verify-all` | PASS, 10/10 | Excludes `verify-soc`, Quake lock-step, and Win95 co-sim |
| `make -C verif/tb l1axi_l2` | FAIL | Missing `ven_cachemap.sv`, `ven_l2.sv`, and `ven_northbridge.sv` |
| `git diff --check 219c124..HEAD` | RTL clean | Two trailing-whitespace reports are in `ao486-sim/DISK_BOOT_STATUS.md` |

The findings below are source-proven unless explicitly labeled as a configuration or
coverage risk. Line numbers refer to the reviewed snapshot.

---

## Critical findings

### C-01 — The crossing-store “probe” occurs after the original store already committed

`rtl/core/core_bus_driver.svh:187-218` drives every initial `S_STORE` request with
`mem_we=1`. The probe behavior is conditional on `xs_act`, but `xs_act` is false when a
crossing store first enters the state. `rtl/core/core_store_useq.svh:20-23` does not set
`xs_act` until **`mem_ack` for that original request**:

```systemverilog
if (mem_ack && xs_cross_now && !xs_act) begin
  xs_act <= 1'b1;
  xs_ph  <= 2'd1; // "probe just completed"
end
```

No probe completed. The completed request was the original full-width write translated
only through its first page. The actual sequence is:

1. unsplit full store using page 1's translation;
2. write the page-1 fragment;
3. write the page-2 fragment.

Consequences:

- Bytes beyond the first physical frame are modified before page 2 is translated or
  permission-checked.
- A not-present or read-only second page cannot make the store atomic; memory was already
  changed.
- With non-adjacent frames, a foreign physical frame is corrupted even when the final
  architectural result appears correct.
- The intended first-page write is redundantly performed a second time.

The passing test is specifically blind to this. `verif/sys/tests/pxpage/pxpage.S:236-247`
checks that the low bytes reach physical `0x800ffe` and the high bytes eventually reach
physical `0x900000`; it does **not** re-read physical `0x801000`, which the initial
unsplit request corrupts. It also has no second-page #PF or read-only case.

Required direction: detect and latch the split before the first request can assert
`mem_we`; probe both translations/permissions before either write is exposed.

### C-02 — Split-transfer state survives page faults and contaminates the handler

`xp_pend` is cleared only at reset and after a successful second load beat
(`core_load.svh:27-34`). `xs_act/xs_ph` are cleared only at reset and successful store
completion (`core_store_useq.svh:27-28`). `start_fault()` at
`rtl/core/core.sv:4777-4829` clears neither set.

Therefore a second-page not-present or permission fault leaves the split transaction
armed while exception delivery and handler code execute:

- The next handler `S_LOAD` is redirected to the stale second page and merged with stale
  `xp_lo`.
- The next handler `S_STORE` can inherit stale `xs_ph`, `xs_first`, and old transaction
  context.
- Even if the handler repairs the mapping and IRET restarts the same instruction, page 1
  is not re-read, so the restart can consume pre-fault data even if the handler changed
  it.

This is exactly the fault case the split mechanism exists to support. Add one canonical
“abort in-flight memory microsequence” action to every fault/diversion path, then test a
handler that performs ordinary loads and stores before returning.

### C-03 — The split-load fix is not used by direct consumers and covers only one state

`rtl/core/core_load.svh:27-34` correctly builds merged value `m` into
`mem_load_data`, but several consumers in the same acknowledgement arm still read the
raw second beat:

- MOVS captures `str_store_data <= mem_rdata` at lines 43-44.
- OUTS captures `ins_data <= wmask(mem_rdata, q_w)` at lines 49-50.
- Far JMP/CALL memory pointers consume `mem_rdata` at lines 67-100.

A page-crossing MOVSW/MOVSD/OUTSW/OUTSD or far pointer therefore forwards the page-2 beat,
not the reconstructed operand.

More broadly, `xp_cross` is limited to `state==S_LOAD` and `xs_cross_now` to
`state==S_STORE` (`rtl/core/core.sv:979-980`). Other byte-addressed, multi-byte accesses
still translate only the starting page, including fast-path `S_PIPE` loads, `S_LOAD2`,
`S_FLOAD/S_FSTORE`, `S_FENV_ST/LD`, `S_USEQ`, `S_ENTER`, far call/return stacks,
interrupt/IRET frames, and SGDT/SIDT operands. Some issue repeated dword beats, but any
individual unaligned beat at page offset `0xffd..0xfff` still crosses a page.

The fix must apply to a shared access layer, not two hand-selected FSM states.

### C-04 — A permission-denied TLB-miss write sets Dirty before it faults

Permission checks run only on a TLB hit (`rtl/core/core.sv:6313-6322`). On a miss, the
walker uses `walk_is_write` to set Dirty before filling:

- 4 MiB PDE D is written at `core_walk.svh:45-49` and
  `core_bus_driver.svh:262-266`.
- 4 KiB PTE D is written at `core_walk.svh:100-101` and
  `core_bus_driver.svh:268-271`.
- The TLB is then filled and the original state resumes; only on the following cycle
  does `perm_fault` see RW/US and raise #PF.

Thus a CPL3 write to a supervisor page, or a write to a read-only page with the relevant
WP semantics, can dirty the leaf entry despite no architectural write. The comment at
`core_bus_driver.svh:488-490` claiming that a permission fault causes “no A/D writeback”
is true only when the translation was already resident.

Permission must be evaluated from the walked PDE/PTE before setting D. Accessed-bit
semantics should be handled separately; Dirty must correspond to an allowed write.

### C-05 — The paging address mirror still drives wrong translations

`cur_lin` and the bus address remain independently reconstructed, and the new assertion
does not make untested states correct. Confirmed mismatches include:

| State/path | Bus address | `cur_lin` | Failure |
|---|---|---|---|
| XLAT in `S_LOAD` | DS + BX/EBX + AL (`core_bus_driver.svh:43-54`) | `opbase+q_ea` (`core.sv:4993-5004`) | Paged XLAT translates an unrelated page |
| CMPXCHG8B `S_USEQ` | `dbase+q_ea+step*q_w` (`core_bus_driver.svh:221-225`) | stack address (`core.sv:5083-5087`) | Successful paged CMPXCHG8B writes the wrong physical page |
| 16-bit PUSHA/POPA | `q_w` spacing plus `stk16()` (`core_bus_driver.svh:226-245`) | fixed 4-byte spacing, no `stk16()` | Wrong lookup at most beats and at SP wrap |
| LDT-backed interrupt/IRET CS | GDT or LDT from selector TI (`core_bus_driver.svh:281-283,364-366`) | always GDT (`core.sv:5092-5094`) | Bus and TLB use different linear pages |
| 16-bit interrupt push | 2-byte stride (`core_bus_driver.svh:324-339`) | fixed 4-byte stride (`core.sv:5095-5101`) | Wrong translation/page at stack boundary |
| 16-bit IRET pop | 2-byte stride (`core_bus_driver.svh:353-362`) | fixed 4-byte stride (`core.sv:5103-5104`) | Wrong stack translation |
| Stack loads in `S_LOAD` | `stk16(ESP/EBP)` (`core_bus_driver.svh:33-37`) | raw ESP/EBP (`core.sv:4994-4996`) | Wrong page for 16-bit stacks |

There are two additional state-selection failures:

- LGDT/LIDT is an ordinary linear memory operand, but `S_LGDT` is excluded from both
  `translatable` and post-translation (`core.sv:5133-5158`,
  `core_bus_driver.svh:463-467`). Under paging it reads a physical address directly.
- SGDT/SIDT has no `cur_lin` or `translatable` case, yet it is **not** excluded from the
  bus post-stage. With paging enabled, `mem_xlate()` consumes the D-TLB lookup driven by
  default `cur_lin=0`. If page zero hits, the pseudo-descriptor can be written through
  page zero's translation; if it misses, the operand silently bypasses paging.

`CHECK 5` at `core.sv:6614-6628` is simulation-only and the current gates do not execute
these combinations. The durable fix is a single per-request linear address/width/write
descriptor consumed by the TLB, permission checker, segment checker, bus, and split
engine.

### C-06 — Inter-privilege IRET reloads SS from stack data, not its descriptor

`S_IRET_SS` is described as an outer-SS descriptor load in
`rtl/core/core_iret.svh:164-186`, but the bus driver groups it with `S_IRET`:

```systemverilog
S_IRET, S_IRET_SS: begin
  mem_addr = seg_base[SG_SS] + gpr_o[R_ESP] + int_step*4;
end
```

There is no `iret_ss[2] ? ldt_base : gdt_base` descriptor address. After beat 4 has
already installed the popped outer ESP, the state reads two dwords from the old SS base
plus that outer ESP and interprets them as a descriptor. It then installs arbitrary
stack bytes as SS base/limit/attributes and retires.

This makes ordinary ring-0-to-ring-3 IRET structurally incorrect independent of the
missing validation discussed next.

### C-07 — IRET commits architectural state before validating the frame

Same-privilege IRET writes EIP and EFLAGS at `core_iret.svh:55-63` before reading and
validating the returned CS descriptor. Inter-privilege IRET also commits EIP/EFLAGS and
outer ESP at beats 4/its GPR writeback before CS/SS validation
(`core_iret.svh:71-81`, `core_gpr_wb.svh:628-645`).

`S_INT_CS_RET` then blindly installs selector/base/limit/attributes and CPL
(`core_iret.svh:139-160`), with no checks for null selector, table limit, presence,
code type, DPL/RPL, conforming semantics, or target EIP limit. `S_IRET_SS` similarly
installs its input without writable-data/present/RPL/DPL checks.

Further 16-bit defects:

- `iret_eip <= {eip[31:16], mem_rdata[15:0]}` preserves the old high EIP at line 23;
  a 16-bit control transfer must load a 16-bit target, as the real-mode IRET and RETF
  paths already do with zero-extension.
- `!int_gate_op16` gates the entire inter-privilege branch at lines 50-53. A valid
  16-bit protected-mode outer-level IRET is treated as same-privilege and does not pop
  SP/SS.

A fault after the early commits is not restartable. Stage the full frame and both
descriptors, validate all of it, then commit in one architectural step.

### C-08 — Per-access segment protection remains disabled

The attempted C-06 delivery was explicitly removed at
`rtl/core/core_fetch_decode.svh:257-287`; `seg_off_over_limit` is only lint-sunk at
`core.sv:6347-6362`. Null-selector and not-present state are also forced off at
`core.sv:4389-4411` because the design lacks hidden-cache validity metadata.

Consequently the core still allows accesses that should fault, including:

- reads through execute-only code segments;
- writes through read-only data segments;
- use of a null DS/ES/FS/GS selector;
- not-present cached segments;
- expand-up/expand-down limit violations;
- stack limit/type violations that should raise #SS rather than #GP.

These checks must be attached to the final access descriptor, after the actual segment,
offset, width, and access type are known, and before any request or cache mutation.

### C-09 — LOCK does not make RMW operations atomic

The decoder calls LOCK a functional no-op for CMPXCHG, XADD, and CMPXCHG8B
(`rtl/core/decode_stages.sv:614-616,638-639,683-684`). The P5 bridge hardwires
`bp_req_lock = 0` (`rtl/bus/biu.sv:159`), and the L1/AXI path has no transaction grouping
or exclusion protocol spanning the read and write halves.

In-order, single-core execution does not make an RMW atomic with respect to DMA, the PS,
or another coherent bus master. Those agents can modify the line after the read and
before the write. XCHG with a memory operand is implicitly locked and is affected even
without an F0 prefix.

The standalone `biu_p5` lock test proves that the lower bus block can model a locked
group; it does not prove that the core ever requests one—the integrated bridge ties the
request low.

---

## High-severity findings

### H-01 — 16-bit protected-mode stacks are only partially implemented

`ss_b` is updated only on the ordinary segment-load path
(`rtl/core/core_seg_ljmp.svh:105`). It is not updated when SS is installed by:

- cross-privilege interrupt delivery (`core_tss_priv.svh:112-115`);
- outer-level IRET (`core_iret.svh:183-186`);
- task switch (`core_tsw.svh:112-135`);
- V86 transition/RSM hidden-state restoration.

Even when `ss_b` is correct, only the **address** goes through `stk16()`. The final GPR
writeback masks ESP high bits only when `real_mode` is true
(`rtl/core/core.sv:4127-4132`), not when protected-mode `ss_b==0`. A 16-bit protected
stack push at SP=0 therefore accesses SS:FFFE but can commit ESP=FFFFFFFE instead of
preserving ESP[31:16] and changing only SP.

This affects push/pop/call/ret/interrupt/IRET/PUSHA/POPA/ENTER and can become a wrong-page
bug when paging is enabled.

### H-02 — Task-switch TSS/GDT traffic still bypasses paging

The source comments acknowledge this directly. All `S_TSW_SAVE/READ/LDT/SEG/BUSY`
states are excluded at `rtl/core/core_bus_driver.svh:459-467`, and there are no matching
`cur_lin` cases. TSS and descriptor-table bases are linear architectural addresses.

With paging and non-identity mappings, task switch can:

- save the outgoing task into unrelated physical memory;
- load CR3/EIP/GPRs/selectors from the wrong image;
- update busy bits in the wrong GDT copy;
- fail to produce required page faults.

### H-03 — Interrupt privilege-stack and task-switch validation is incomplete

`S_INT_TSS` reads TSS.ssN/espN without checking `tr_valid` or the TSS limit. The source
explicitly says `S_INT_SS` loads the new SS unconditionally
(`rtl/core/core_tss_priv.svh:92-116`). Missing checks include selector/table bounds,
SS.RPL/DPL, writable data type, and presence.

`S_INT_CS` checks present/code and a simple DPL relation, but does not check a null
selector, GDT/LDT limit, or full conforming-code rules
(`rtl/core/core_int_deliver.svh:96-117`). Its #GP/#NP error code incorrectly forces the
IDT bit (`...3'b010`) even though the failing selector names GDT/LDT.

Task switching has similar holes:

- a target TSS is accepted without checking its minimum limit;
- the current TR is not validated before outgoing state is saved;
- the incoming LDTR and six segment descriptors are loaded without required
  type/present/privilege/table-limit validation (`core_tsw.svh:71-137`);
- `ss_b` is not loaded from the incoming SS descriptor.

Malformed system state can therefore be installed and used for memory addressing before
the architecture raises the required #TS/#NP/#SS/#GP.

### H-04 — Faults during delivery do not escalate to #DF or shutdown

`start_fault()` can re-vector an IDT-limit failure to #GP, and `S_INT_GATE` can re-vector
bad gate attributes, but there is no delivery-depth state. The source explicitly calls
this a “single re-vector” (`core_int_deliver.svh:57-60`, `core.sv:4815-4821`).

A fault while delivering a contributory exception, followed by another fault while
delivering the replacement, can loop through `S_INT_GATE` or repeatedly reinterpret bad
tables rather than raise #DF. A fault while delivering #DF has no modeled shutdown/triple
fault behavior. This is especially dangerous because the IRET/SS/TSS validation paths
above can themselves fault during delivery.

### H-05 — NMI is unblocked when IRET is decoded, even if IRET faults

`rtl/core/core_fetch_decode.svh:531-545` decrements `nmi_nest` or clears
`nmi_in_progress` at IRET decode. Stack reads, descriptor validation, and commit occur
later. A faulting IRET therefore re-enables NMI prematurely, allowing a second NMI to be
accepted while the original NMI frame is still active.

The nesting counter fixes the maskable-interrupt-inside-NMI case only when every IRET
completes. Re-arm NMI at successful IRET commit after the frame has been validated.

### H-06 — Remaining privilege checks allow incorrect CPL3 execution

The centralized CPL0 list at `rtl/core/core.sv:6288-6292` omits at least:

- RDTSC when CR4.TSD=1. The decoder explicitly says the check is not modeled
  (`decode_stages.sv:711-723`).
- INVD and WBINVD. They become anonymous `d_is_nop` operations in system mode
  (`decode_stages.sv:725-734`), leaving no predicate for `priv_fault` to reject at CPL3.

The TSS I/O bitmap is also not consulted (`core.sv:6293-6296`). That omission is
fail-closed for privilege—it rejects some legal user I/O rather than granting extra
access—but it breaks protected-mode applications and V86 monitors that rely on per-port
permissions.

### H-07 — The remap alias detector reports an access but does not reject it

`alias_bad` sets sticky `alias_err` at `rtl/mem/ven_axi_master.sv:173-183`, but neither
FSM start condition tests it:

- read starts at line 327 on `m_req && !m_we && !shutdown && !rd_hold`;
- write starts at line 409 on `m_req && m_we && !shutdown`.

The same clock that records the error also latches the remapped read/write address. A
write then proceeds through AW/W/B and can corrupt the aliased low DDR location before
the delayed `bus_err` halts the core. This is still detection, not the claimed
“rejected at the access.” Gate both start paths with `!alias_bad` and provide a local
fatal response that cannot launch AXI.

### H-08 — Linear I-cache tags still allow stale executable aliases

The code acknowledges the paged virtual-alias half at
`rtl/core/core.sv:5492-5495`: a CPU store invalidates only the store's linear tag. If
linear A and B map to the same physical page, modifying through A leaves executable B
resident and stale.

There is a second alias class introduced by A20. The mask is applied only to final
physical `mem_addr` (`core_bus_driver.svh:498-524`), while CPU SMC invalidations use
unmasked `core_lin` (`rtl/mem/ventium_l1_axi.sv:296-335`). With A20 off, a store through
`0x001xxxxx` physically aliases `0x000xxxxx` but invalidates only the high linear I-tag;
cached low-alias code remains stale. The real-mode DMA path also avoids the conservative
paging flush because it assumes linear==physical, an assumption A20 masking invalidates.

Physical I-tags or a physical reverse-alias/global-invalidate mechanism is required.

### H-09 — Keyboard-controller A20 control is not connected

The core implements only port 0x92 (`rtl/core/core_io.svh:26-45`). The top-level
platform override is tied high (`rtl/ventium_top.sv:488-501`), and no RTL signal connects
8042 output-port commands to `a20_gate`.

Real BIOS/DOS software commonly controls A20 through commands on ports 0x60/0x64. Those
commands may be handled by the PS/co-sim peripheral, but they cannot alter the core's
mask in this RTL. The `a20` umbrella test exercises only port 0x92, so it cannot catch
this integration failure.

### H-10 — I-side cacheability remains tied off

`ic_fill_nocache` is explicitly tied to zero at `rtl/core/core.sv:5294-5318` because
driving it from CR0.CD livelocks the fetch path. Consequently instruction fetches are
still allocated and hit while CD is set, and there is no executable-region cacheability
query for PAM/SMRAM/MMIO.

The unit test proves only that the poison input can suppress validation. It does not
provide the required non-allocating fetch datapath. Implement a fetch bypass that can
deliver bytes without requiring a valid I-cache line.

### H-11 — `VEN_L1_HONOR_CD` deliberately ignores CD for reads

Under `VEN_L1_HONOR_CD`, `BYPASS_RD_EN=0`
(`rtl/mem/ven_l1d.sv:223-241`) and the non-cacheable read branch is compiled as
`if (1'b0)` (`ven_l1d.sv:411-420`). Reads continue to hit and allocate even when
`cacheable=0`; only write allocation behavior changes.

This can serve stale resident data under CR0.CD and can duplicate/suppress MMIO read side
effects when the cache map is present. Comments label it “correct” because it returns a
fresh line on a miss, but a hit does not fetch a fresh line and allocation itself is
architecturally wrong for uncacheable memory.

### H-12 — The ao486 L2 invalidation skid still loses requests

In the live dirty ao486 submodule,
`3rd-party/ao486_MiSTer/rtl/cache/l2_cache.v:90-111` has two loss cases:

1. A second colliding pulse overwrites `l2_inv_pend_addr`; the warning is simulation-only.
2. On a free cycle with both a pending invalidation and a fresh pulse,
   `l2_inv_go_a` selects the fresh pulse while the sequential block clears
   `l2_inv_pend`. The older pending invalidation is never applied.

There is no ready/credit signal and one entry cannot prove losslessness for an
unconstrained pulse producer. Use a queue with explicit acceptance/backpressure or
define and assert a producer contract that prevents these combinations.

### H-13 — x87 stack underflow/overflow and empty operands are not implemented

`rtl/fpu/fpu_top.sv:237-272` pushes, pops, and pops twice unconditionally. It does not
check whether the destination of a push is already non-empty or whether a popped/source
register is empty. `fpu_writeback.sv` performs arithmetic, compares, exchanges, and
stores from `fp_st[]` without tag-based operand faulting.

Required stack faults—IE+SF, C1 direction, indefinite results for masked faults, no
write/pop for unmasked faults—are therefore absent. Stale register bits are treated as
valid operands after underflow.

### H-14 — x87 exception masks, ES/#MF, and FWAIT remain nonfunctional

Most x87 arms write the result/stack operation and merely OR sticky IE/ZE/OE/UE/PE flags
(`rtl/core/fpu_writeback.sv`, e.g. lines 743-785 and 901-922). They do not branch on
FCW mask bits to suppress the destination/pop for unmasked faults, generate masked
indefinite results, or set sticky ES at the correct event.

`fpu_top.sv:164-180` only mirrors B from ES; it explicitly does not derive ES. There is
no `start_fault(16,...)` #MF route. FWAIT is an unconditional NOP
(`decode_stages.sv:1039-1043`, `fpu_writeback.sv:698`), and the FWAIT-specific #NM rule
for CR0.TS && CR0.MP is absent (`core_fetch_decode.svh:473-475`).

The existing default-masked corpus cannot validate any of these behaviors.

### H-15 — Available/deployed no-L2 paths do not enforce SMRAM isolation

`smm_active` is exported, but it is consumed only inside the `EN_L2` branch by the
missing cachemap/northbridge modules (`rtl/mem/ventium_l1_axi.sv:412-457`). The available
`EN_L2=0` branch at lines 500-529 is a transparent DDR bypass and ignores `smm_active`.

Therefore the source configuration that can actually build does not prevent ordinary
non-SMM accesses to the SMRAM save area. The H-24 wiring is an interface stub until the
northbridge source exists and is enabled; it is not end-to-end isolation.

---

## Medium-severity findings

### M-01 — Illegal LOCK prefixes on memory operands are still accepted

`rtl/core/decode_stages.sv:1729-1750` rejects LOCK only when an instruction has no memory
operand. It explicitly leaves LOCK on non-lockable memory operations unresolved. For
example, `LOCK MOV [mem],reg` has a memory operand and is silently executed instead of
raising #UD. Add an explicit `lock_ok` decode property to the legal RMW opcodes.

### M-02 — Only the 28/108-byte x87 environment formats exist

`S_FENV_ST/LD` always transfers full dword beats
(`rtl/core/core_bus_driver.svh:165-173`), with last beats 6 or 26
(`fpu_writeback.sv:497-541`). The 16-bit operand-size formats are 14-byte FNSTENV/FLDENV
and 94-byte FNSAVE/FRSTOR images. They cannot be represented by the current fixed dword
sequence and will read/write beyond the architectural object.

### M-03 — Plain `VEN_UOPCACHE` still selects stale port A after redirect

The H-15 fix is conditional on `VEN_IC_BRAM`. Without it,
`rtl/core/core.sv:2931-2937` hardwires `uc_u_in_b=0`, while predicted-target prefetch can
place the needed line in port B. Thus the advertised plain `VEN_UOPCACHE` configuration
can decode stale port-A predecode state after a redirect. Either require the paired
defines at elaboration or carry an address tag for both modes.

### M-04 — The L1 line-size parameter remains falsely advertised

The implementation and AXI master are fixed to 32-byte/8-beat lines, with elaboration
fatals for other values (`rtl/mem/ven_axi_master.sv:135-142`; corresponding fixed slicing
exists in `ven_l1d.sv`). Set-count parameterization improved, but line-size
parameterization is not real. Remove the parameter from public configuration or make all
offset/tag/burst logic derive from it.

### M-05 — Northbridge/L2 configurations are unbuildable in this checkout

`rtl/northbridge/ven_cachemap.sv`, `ven_l2.sv`, and `ven_northbridge.sv` are absent while
`ventium_l1_axi.sv` and verification targets instantiate them. The directed build fails
at `verif/tb/Makefile:126` before compilation. This also makes claims about MMIO routing,
PAM, cacheability, SMRAM, coherent DMA, and the native Ventium L2 unverifiable from this
repository snapshot.

### M-06 — Unsupported system descriptors halt instead of taking architectural paths

The interrupt path rejects task gates as #GP even though task gates are valid IDT entry
types (`core_int_deliver.svh:61-76`). The far-transfer path terminally halts on task gates,
16-bit TSS descriptors, and remaining system descriptors
(`core_seg_ljmp.svh:199-205`), and halts on a valid cross-privilege call gate rather than
performing the required stack switch (`core_seg_ljmp.svh:212-225`).

These are intentionally loud omissions, not silent corruption, so they are lower
severity than the incorrect paths above; they remain guest-visible ISA/system bugs.

### M-07 — Port 0x92 fast reset is ignored

`rtl/core/core_io.svh:26-29` implements A20 bit 1 but explicitly ignores bit 0, the fast
reset control. Software that requests a reset through System Control Port A will simply
continue executing. If reset is intentionally delegated to the platform, expose and wire
a reset request rather than silently discarding it.

---

## Verification and review gaps

The 10/10 umbrella result should be retained—it is valuable regression evidence—but it
does not exercise the failure predicates above.

### Specific blind spots

- `pxpage` proves eventual split destination bytes only. It does not check the adjacent
  foreign frame, second-page not-present/RO behavior, restartability, handler memory
  operations, MOVS/OUTS/far pointers, or any state other than `S_LOAD/S_STORE`.
- Paging tests do not inspect page tables after a denied first-touch write, so premature
  Dirty updates are invisible.
- There are no paged tests for XLAT, CMPXCHG8B success, 16-bit PUSHA/POPA, 16-bit stack
  wrap, LDT-backed interrupt targets, 16-bit gates/IRET, LGDT/LIDT, or SGDT/SIDT.
- There are no negative IRET/IDT/TSS/SS tests: null/out-of-limit/not-present/wrong-type/
  bad-DPL selectors, faults during delivery, #DF escalation, or a faulting IRET in NMI.
- LOCK tests exercise `biu_p5` in isolation, not a core RMW competing with DMA/PS traffic.
- A20 tests cover only port 0x92 memory aliasing. They do not cover 8042 control,
  executable aliases, page-walk/cache interactions, or port-0x92 reset.
- I-cache `fill_nocache` tests drive the mechanism directly; they cannot detect the full
  core livelock or prove a fetch bypass that does not exist.
- x87 tests overwhelmingly use the default masked control word. They do not cover stack
  faults, unmasked completion suppression, ES/#MF, FWAIT, or 14/94-byte images.
- `verify-all` says so explicitly: no `verify-soc`, no artifact-dependent Quake lock-step,
  and no Win95 co-sim. The missing northbridge sources also prevent the L2/NB target from
  elaborating.
- The ordinary `verify` run still prints structural per-instruction comparator
  divergences as diagnostic/non-gating output; architectural final equivalence should
  not be read as proof that intermediate control/cache state agrees.

### Tests to add before declaring closure

1. A split-store atomicity suite with non-adjacent frames, a sentinel in the physically
   adjacent frame, page-2 NP/RO cases, and a #PF handler that performs loads/stores.
2. A table-driven paging-address suite that runs every memory state at offsets
   `0xffc..0xfff`, compares `cur_lin` to the bus pre-address, and checks both physical
   frames and fault order.
3. First-touch permission tests that examine PDE/PTE A/D bits after rejected reads,
   writes, and fetches at CPL0/CPL3 with CR0.WP both ways.
4. IRET/interrupt/task-switch negative matrices, including 16-bit stacks/gates, LDT
   selectors, fault-during-delivery escalation, and successful ring transitions.
5. An integrated LOCK/DMA arbitration test that attempts an external write between the
   read and write halves of every lockable RMW, including implicit-lock XCHG.
6. Physical-alias executable tests for paging aliases and A20 aliases, plus 8042 A20
   commands.
7. Uncacheable instruction/data tests that repeatedly change backing memory and MMIO
   side-effect counters while CD/cache-map attributes are active.
8. x87 stack and exception matrices for all six exception classes, mask on/off, empty/
   full stack, FWAIT, and #MF delivery.

---

## Recommended fix order

1. **Stop memory corruption first:** fix crossing-store arm timing, clear split state on
   every abort, and reject aliasing AXI requests before either FSM captures them.
2. **Replace address mirrors:** introduce one access descriptor carrying linear address,
   segment identity/offset, width/strobes, read/write/fetch classification, and split
   phase. Make TLB, permissions, segmentation, bus, breakpoints, and cache snoops consume
   it. Keep an assertion at the single handoff, not between two reconstructed trees.
3. **Make page-walk permission ordering precise:** validate walked permissions before D
   writeback/fill; distinguish A from D side effects and verify page-table memory.
4. **Rebuild IRET/delivery as validate-then-commit:** stage the whole frame and
   descriptors, implement selector/limit/type/presence/privilege checks, update `ss_b`,
   and add delivery-depth/#DF/shutdown state.
5. **Implement a real locked transaction contract** through core, L1, AXI/P5, and all
   external masters.
6. **Close executable coherence/cacheability:** physical tags or a safe conservative
   alias strategy, non-allocating I/D bypasses, A20-aware invalidation, and an actual
   8042 A20 connection.
7. **Then finish x87 and optional configurations:** stack faults, mask-aware completion,
   #MF/FWAIT, legacy env sizes, uop-cache port identity, and restore the missing
   northbridge/L2 source so the SoC path can be reviewed and gated end-to-end.

## Bottom line

The new work improves several isolated mechanisms and greatly improves the regression
umbrella, but the safety properties claimed for paging, IRET, cacheability, and
coherence are not yet established. In particular, the crossing-store implementation is
actively non-atomic and corrupts a foreign frame in the very passing test used to claim
closure. Treat the current snapshot as a useful development checkpoint, not a closed
system/SoC correctness milestone.
