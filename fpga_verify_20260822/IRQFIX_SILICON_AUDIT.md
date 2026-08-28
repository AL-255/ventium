# Repaired fast-path silicon audit — 2026-08-22

## Current result

**PASS for both the L1 bypass ownership repair and the protected far-pointer
LDS/LES repair; FAIL for complete Quake workload acceptance because a later
protected-mode page-fault/stack-corruption path remains.** The original
ownership image is
`fpga_run_20260822_l1bypown/rk_ao486_system.bit.bin`, SHA-256
`891881f6b7196023bf1d34a6433b7a53f7814166ce6a38dbeb31c0db5f15b5dc`.
It passed the reset-state nested IRQ/IRET diagnostic twice on silicon: all 256
software-handler entries and returns and all 256 POP-tail returns completed,
every bad counter remained zero, and both runs reached the success park. No CR0
cache workaround, blind extra AXI replay, global stall, cache flush, or Verilog
debug patch was used. This directly closes the request-A versus request-B
identity defect described below.

The source-repaired far-pointer image is
`fpga_run_20260823_lds2/rk_ao486_system.bit.bin`, SHA-256
`013396318e9c385b80c36d43422fa5795c3c50c65615126082ca5ff302eda4b9`.
With the clean unmodified disk, it executes beyond CWSDPMI
`0018:00001105`, enters Quake protected code, and therefore closes the earlier
LDS decode blocker on silicon. It still does not reach timedemo acceptance. A
clean, unfrozen 600-second run ended after 582 disk reads, including 205 seconds
of final disk inactivity, and the exact result checker printed
`QUAKE TIMEDEMO NOT COMPLETE (timeout)`. The disk retained SHA-256
`616d7c7ebf03b00b6c2031e1e81733e324adb859d91707dd3bf0f6772b2b50e2`.
No `QCONSOLE.LOG`, `TIMEDEMO`, `969 frames`, or `FLUSHWD` marker was present.

The final read-only handoff check found FPGA manager state `operating`, the same
bitstream and disk hashes above, no active `ven-quake-context-final` or
`ao486d` service, and no `ao486d` process. The last trap-status record from the
clean acceptance run had `frozen=0`; unlike the comparator captures, that run
did not deliberately freeze the guest.

Windows 95 independently **passes** the established headless desktop signature
on this same repaired-fast image. A pristine sparse disk was restored, the core
ran with reset-state `CR0=0x60000010` at a measured 3.125029 MHz, and two
read-only detector samples reached stable last-AR `0x001021c0` with the paired
System-VM idle EIPs `0x1e5/0x1e6`, live transitions, correct Windows IVT values,
and an advancing tick. B8000 was completely blank and a ten-second interval
retired 373,986 instructions with 142 IRQ acknowledgements. No input, flush,
freeze, guest patch, or stall workaround was used. The service was stopped and
confirmed inactive; exact logs and hashes are in `win95_l1bypown/README.md`.

### Current Quake blocker: protected-mode page fault after stack corruption

A live, CS-qualified EIP comparator on the repaired image captured vector 14.
It froze after the current ring reached `CS:EIP=00a7:0004d5dc`; a separate
capture reached DJGPP exception cleanup near EIP `0x4ee08` and then `exit(-1)`.
Two independently frozen high-memory snapshots have a byte-identical 448-byte
Quake stack region filled predominantly with ASCII-zero words (`0x30303030`).
The old LDS location is no longer the failure.

A historical July cosimulation has the same stack-string signature and reports a
client page fault at `0x55efd` after incorrect x87 EMPTY-source handling made a
dtoa loop overrun its stack buffer. That is a strong correlation, not present
silicon proof: the current DPMI client frame was cache-resident at freeze and its
original faulting EIP could not be recovered from DDR. Current RTL also contains
new stack-fault descriptor and QNaN-indefinite repairs that postdate the
historical run.

One concrete open race was found in the present `VEN_FP_PIPE` path: deferred
arithmetic captures RC but evaluates both split stages with live
`fctrl[9:8]` precision control. A following FLDCW/FLDENV/FRSTOR can therefore
change an in-flight result's precision unless a missing serialization invariant
is proved. Add the two PC bits to the existing immutable FP owner/request record
and use them at every stage if the focused gate confirms this. Do not add a
second evaluator or a separate control-word stall cone. Reproduce the exact FPGA
define profile first, record the final x87 operation/tag/control sequence, and
test both EMPTY-source propagation and issue-to-commit RC/PC stability. Full
evidence, uncertainty boundaries, and proposed gates are in
`quake_lds_repaired/README.md`.

### Closed Quake blocker: protected-mode operand-size-overridden LDS was decode-disabled

The captured CWSDPMI resident TSS at guest physical `0x30142` records
`irqn=0x0d`, `error=0x00000028`, `CS:EIP=0018:00001105`, `CR3=0x0007e000`,
and the original client register/segment image. Selector `0x18` has base
`0x00026d90`; therefore the faulting instruction is at physical `0x00027e95`.
The bytes are `66 67 c5 75 10`, decoded in CWSDPMI's 16-bit protected code as
`lds esi,[ebp+0x10]` (`m16:32`). The primary CWSDPMI r7 source identifies the
same instruction in `_ring0_iret`: it loads the old ring-3 `ESP:SS` pointer
from the call-gate frame before copying the five-dword IRET image.

The call-gate frame itself is correct. `SS=0x20` has base `0x0002c9d0`, and
`SS:[EBP+16]` at physical `0x3022a` contains old `ESP=0x00003484` and old
`SS=0x0033`. Selector `0x33` is the valid ring-3 protected data descriptor. The
captured GDT at `0x2d0d0` and IDT at `0x2d158` are internally consistent;
IDT vector 6 names valid ring-0 code selector `0x18`. The later `#GP(0x28)` is
the CWSDPMI exception path after the unsupported instruction first raises
`#UD`, not evidence that the far pointer contains selector `0x28`.

The pre-repair RTL cause was direct:

- `rtl/core/decode_stages.sv` accepted `LES/LDS` only when `seg_real`;
  protected mode set `d_unknown`, which system mode delivered as `#UD`.
- `rtl/core/core_exec.svh` already contained a protected-mode far-pointer
  segment-load route through `seg_mem_sel` and the shared `S_SEGLD` descriptor
  walker. That route was unreachable for opcodes C4/C5 solely because of the
  decoder gate.
- Simply deleting `&& seg_real` would not have been a complete repair. The old
  GPR writeback committed the pointer offset in `S_EXEC` before `S_SEGLD`
  validated the selector/descriptor. A null, out-of-table, not-present,
  privilege, page, or segment fault could therefore have left the destination
  GPR modified even though `LDS/LES/LSS/LFS/LGS` must commit the GPR and segment
  register as one restartable architectural operation.

The implemented repair requirements were both compact and precise:

1. Decode memory forms C4/C5 in real, V86, and protected modes; keep only
   `modrm_mod==11` as `#UD`. Preserve the existing operand/address overrides,
   default-segment selection (`EBP` means SS), and `q_w=2/4` first/second-beat
   widths.
2. Reuse one common far-segment-load transaction for C4/C5, 0F B2/B4/B5, and
   memory-source MOV Sreg. Do not add another descriptor walker or a private LDS
   validation cone: stage `{target_sreg, selector, optional_gpr_dst,
   optional_offset, width}` and feed the existing `S_SEGLD` table read and
   `seg_load_fault` decision.
3. Suppress the ordinary `S_EXEC` GPR write whenever a protected far-pointer
   segment load is pending. On the successful second descriptor beat, issue the
   GPR write and hidden-segment-cache writes in the same commit. On every
   descriptor/translation/segment fault, commit neither. The already-retained
   `mem_load_data` is the offset for both m16:16 and m16:32, so this should need
   control metadata rather than another 32-bit data register.
4. Fold POP-Sreg and MOV-Sreg memory selector sources into the same owner-tagged
   transaction where their architectural commit rules permit it. One request
   record and one commit mux should replace the repeated real/PM selector-source
   trees in `core_exec.svh`; retain a source-kind field for POP's stack-pointer
   commit semantics. This is an area reduction and prevents another decode/exec
   reachability mismatch.

Required regression coverage is a focused protected-mode gate plus the normal
system differential suite. It must execute the exact `66 67 C5 75 10` form from
a 16-bit DPL0 code segment with `SS:[EBP+16]={ESP,0x0033}`, then verify ESI, DS,
EIP, and the hidden DS cache against QEMU. Add m16:16 and m16:32 LES/LDS/LSS/LFS/
LGS cases using DS, SS-default, segment override, GDT and LDT selectors, a far
pointer split across a page, and selector/descriptor/page faults. Poison the GPR
destination before each fault and prove it is unchanged. Also require the exact
Quake disk to produce the 36-byte 969-frame result on silicon; startup alone is
not closure.

### Post-repair corner cases still open, with compact fixes

The far-pointer atomic-commit structure is correct, but a second source audit
found three adjacent cases that should be fixed before calling all protected
segment loads complete. They do not justify another descriptor walker or
per-opcode repair; each belongs in the same shared `S_SEGLD` request/commit
record.

1. **MOV/POP/LSS into SS does not create the architectural one-instruction IRQ
   shadow.** `irq_shadow` is set only by STI; a search of the RTL finds no
   successful SS-load event that sets it. Form one shared `seg_ss_commit` pulse
   from the protected `segld_commit_ok` event and the real/V86 direct SS-load
   event, and set `irq_shadow` there. Do not duplicate the condition in MOV
   Sreg, POP SS, and LSS opcode arms. Preserve the existing decode-boundary clear
   and prove exactly one following instruction retires while maskable IRQ
   delivery is inhibited.
2. **Protected POP Sreg advances ESP before descriptor validation.** The GPR
   writeback arm updates ESP in `S_EXEC` while the FSM explicitly defers the
   segment load to `S_SEGLD`. A later #GP/#NP/#SS/#PF therefore leaves the
   faulting POP with an architecturally visible stack adjustment. Add a
   `pop_sreg_pending` bit to the same staged transaction, suppress the protected
   `S_EXEC` ESP write, and commit `ESP += width` only on the shared success
   pulse. Real/V86 POP remains direct. Test null SS, table limit, type,
   privilege, not-present, and descriptor-page faults with a poisoned ESP.
3. **An out-of-table selector still performs and translates a descriptor access
   before #GP.** `segld_table_oob` is shared, but `bd_req` and `translatable`
   suppress only `seg_null_load`; the FSM checks the limit only after `mem_ack`.
   This can incorrectly raise #PF first and can set paging accessed state for a
   descriptor read the architecture must never make. Define one
   `segld_no_access = seg_null_load || segld_table_oob`, use it for both bus
   request and translation engagement, and make the `S_SEGLD` FSM deliver the
   limit #GP immediately without waiting for `mem_ack`. Reuse the already shared
   selector and table comparator; this removes useless traffic and should reduce
   rather than add control logic.

The follow-up gate should generate every source kind through one parameterized
harness and compare fault vector/error code, GPRs, ESP, visible segment selector
and hidden cache, page-table A/D bits, and IRQ-shadow duration. Keeping one
request record and one commit predicate is both smaller and safer than three
local fixes.

Old-LDS forensic artifacts and hashes are in `quake_final_log/README.md`.
Repaired-image fault evidence is in `quake_lds_repaired/README.md`. No Verilog
was changed during this deployment/debug pass.

The older `fpga_run_20260822_irqfix` image did fail before disk boot. Its failure,
the CR0 discriminator, and the path from the misleading HP0 hypothesis to the
exact RTL reproduction are retained below as historical evidence. Statements in
those historical sections that call silicon closure "pending" apply to that
earlier point in the investigation, not to the superseding ownership image.

## Full implementation compactness audit

### Verdict

**P0 — the design is functionally usable but structurally far too duplicated
for this FPGA.** Synthesis produces 364,029 CLB LUTs against 341,280 available
(106.67%). Cross-hierarchy optimization gets placement down to 316,176 LUTs
(92.64%), but that is still congestion territory: the placer explicitly reports
the design as highly congested, and routing reaches conflict iteration 100 before
finishing. Synthesis alone takes 3:02:39, peaks at 17.99 GB, placement takes
21:26, and route takes 41:04. The final route is legal and meets timing (WNS
+0.844 ns, WHS +0.013 ns, no unrouted nets), but successful routing at 92.64% is
not adequate area margin.

This cannot be solved primarily with a different Vivado strategy. Post-route
`report_qor_suggestions` offers only the small-SRL-to-register remap. The large
gain has to come from expressing the original P5 resource sharing explicitly in
RTL so synthesis sees one operator with input arbitration, rather than several
function calls or modules that happen to be mutually exclusive at run time.

### Fresh full-flow evidence after the shared protected-segment repair

The source-repaired 2026-08-23 image independently confirms the same conclusion.
Its exact Vivado 2025.2 build is `fpga_run_20260823_lds2`, with deployable binary
SHA-256 `013396318e9c385b80c36d43422fa5795c3c50c65615126082ca5ff302eda4b9`.
The shared LDS/LES/LSS/LFS/LGS validation and atomic-commit repair changes the old
image by only **+98 synthesized LUTs and +116 placed LUTs**; it retains all 1,265
DSPs. Correctness control is therefore not the area problem.

| Fresh full-flow measurement | Result |
|---|---:|
| synthesized CLB LUT | 364,127 / 341,280 (106.69%) |
| synthesized LUT as logic | 360,703 (105.69%) |
| placed CLB LUT | 316,292 / 341,280 (92.68%) |
| placed LUT as logic | 312,882 (91.68%) |
| occupied CLB | 41,589 / 42,660 (97.49%) |
| CLB registers | 42,385 (6.21%) |
| CARRY8 | 19,965 (46.80%) |
| BRAM tile / DSP48E2 | 85 / 1,265 |
| routed WNS/TNS | +1.966 ns / 0 |
| routed WHS/THS | +0.013 ns / 0 |
| routing | 415,339 fully routed; 0 errors |

Implementation combines 1,963 more LUTs during physical optimization and
eliminates about 48,000 primitive cells between synthesis and placement, but it
still cannot discover the architectural mutual exclusion needed to collapse the
four independent transcendental engines. The placer again declares the design
highly congested. Routing starts at congestion level 5, reaches conflict
iteration 100, and writes `iter_100_CongestedCLBsAndNets.txt` before eventually
converging. Final global routing is only 47.11% vertical and 47.90% horizontal;
the problem is localized packing and interconnect pressure caused by redundant
wide cones, not exhaustion of raw global wire count.

The synthesis area ordering also exposes repeated one-owner-at-a-time cones:
separate `mul128_*` arithmetic in the transcendental engines, FPATAN and FYL2X
significand/division paths, a private `fpu_fx_ppl`, and separate core signed and
unsigned multiply trees. These must be **physically combined**, not merely called
through similarly named functions or selected by a final-result mux. The intended
endpoint is one owner-tagged x87 arithmetic service, one scheduled 64x64
multiplier lane (two only after a measured throughput failure), one registered
coefficient-ROM service, one wide accumulator/round-pack path, one signedness-
controlled integer multiplier, and two addressed GPR write ports. Delete each
superseded client-local operator as its owner migrates; leaving it behind a mux
preserves both area and congestion.

Apply that consolidation aggressively while clients are architecturally
mutually exclusive. The sign-off question for every stage is whether the old
operator primitives disappeared from the complete synthesized hierarchy, not
whether the source now has a helper named "shared." Stop after synthesis for
each migration and reject a stage with no material full-design LUT/DSP drop.
Lower occupancy is itself a timing and turnaround feature here: getting below
85% placed LUT use removes the packing pressure that currently drives the
congested placement and 100-iteration router conflict, so it should reduce P&R
time and make timing less seed-sensitive. Preserve the true U/V and ordinary
pipelined-FP concurrency; serialize only the rare operations that already have
one architectural owner.

Six synthesized L1D predicate bits each have nominal fanout 1,396, while physical
optimization can legally touch only 157 loads. At 97.49% CLB occupancy, a broad
`FORCE_MAX_FANOUT` or replicated-buffer patch is likely to make packing worse.
Reduce consumers structurally with banked/addressed metadata and shared hit/snoop
decoders after removing the x87 duplication; use replication only as a measured
placement refinement on the smaller netlist.

The evidence files are under `compactness_reports/`. They are generated from the
exact routed and synthesized checkpoints by `../report_compactness.tcl` and
`../report_compactness_synth.tcl`; the two focused out-of-context experiments are
also preserved there.

### Measured ownership

| Hierarchy in the deployed build | Synth CLB LUT | Post-route CLB LUT | Registers | DSP48E2 |
|---|---:|---:|---:|---:|
| Ventium `core` total | 350,811 | 303,607 | 30,318 | 1,265 |
| `fpu_f2xm1` | 11,084 | 10,735 | 465 | 248 |
| `fpu_fpatan` | 60,301 | 59,339 | 1,321 | 516 |
| `fpu_top` attributed row | 122,148 | 78,721 | 780 | 0 |
| `fpu_writeback` | 6,080 | 5,908 | 0 | 16 |
| `fpu_fsincos` | 30,438 | 29,975 | 1,118 | 80 |
| `fpu_fyl2x` including `fpu_estdiv` | 23,370 | 22,890 | 1,818 | 387 |
| I-cache | 22,545 | 22,418 | 5,660 | 0 |
| GPR register file | 16,906 | 16,779 | 256 | 0 |
| BTB | 7,454 | 7,297 | 7,698 | 0 |
| SRT divider | 6,571 | 6,286 | 744 | 0 |
| logic attributed directly to `core` | 42,457 | 42,236 | 8,397 | 17 |

The x87-related leaf rows, including SRT and the small BCD converters, sum to
214,613 post-route LUTs, 67.9% of every placed LUT. The four transcendental
engines alone own 1,231 of 1,265 DSPs (97.3%). These are the dominant area and
congestion targets.

The 78,721-LUT `fpu_top` row must not be read as an enormous state register file.
An out-of-context synthesis of that exact module is only 3,421 LUTs and 781
registers. Vivado has absorbed cross-boundary x87 arithmetic, conversion,
round/pack, and writeback cones toward the state endpoints; the fall from 122,148
synth LUTs to 78,721 post-route LUTs further demonstrates cross-hierarchy
combining. Optimize the producers and commit muxes, then remeasure. Rewriting the
eight 80-bit state registers alone will not recover tens of thousands of LUTs.

### P0: one shared transcendental arithmetic service

`S_TRSC_BUSY` permits only one transcendental instruction and selects exactly one
of F2XM1, FPATAN, FSINCOS, and FYL2X. Nevertheless, each engine instantiates its
own `fx_add`/`fx_mul`, wide partial-product arithmetic, normalize, and round/pack
cones. The comments that call a multiplier "shared" refer only to sharing among
states inside one engine. They do not share it with the other three engines.

The existing `fpu_fx_ppl` name is especially easy to misread. The complete
hierarchy report proves there is only one instance, `u_fsincos/u_fx`, and that
instance alone is 6,145 placed LUTs, 219 registers, and 80 DSPs. F2XM1, FPATAN,
and FYL2X do not request it; their `fx_add`/`fx_mul` calls and `mul128_*`
functions elaborate locally. FPATAN is the clearest implementation witness:
it is 59,339 placed LUTs and 516 DSPs, retains its own combinational `estDiv`,
two six-iteration correction loops, and a local 128x128 multiplier, and then
uses a four-cycle multicycle exception to tolerate a 2,322-level cone. FYL2X
has already converted the analogous estimate divider to one sequential
`fpu_estdiv`, yet that instance is still private to FYL2X. This is partial
intra-engine sharing, not the original P5's global FPU resource reuse.

The repair should make sharing structural:

1. Add one core-owned floatx80 arithmetic service with registered
   `{valid, owner, op, a, b, rc, pc}` request and `{done, owner, result, flags}`
   response records. Put the single add/sub alignment path, the single multiply
   front end, and one round/pack back end in that service. The four existing
   engine FSMs retain their coefficient ROMs, iteration counters, and architectural
   corner-case decisions, but issue micro-operations to this service.
2. Add one shared 64x64 multiplier primitive below that service. Implement
   `mul128_hi`, `mul128_192`, and `mul128_256` as sequenced partial products and
   accumulated carries instead of elaborating two or four 64x64 multipliers in a
   combinational function. Because only one transcendental engine can own the
   service, no inter-engine throughput is lost. If a single lane measurably hurts
   the required x87/Quake throughput, use two shared lanes as the bounded fallback;
   do not return to four independently synthesized engine datapaths.
3. Move `(* use_dsp = "yes" *)` from whole modules to only the dedicated
   multiplier primitive. The current module-level attributes also map wide adds,
   subtracts, and normalization into dynamic DSP modes, producing five
   `DPREG-7` dynamic-OPMODE warnings and a large, scattered DSP fabric. Do an A/B
   after isolating the multiplier: DSP adders can save LUTs, so blindly disabling
   the attribute is not an accepted optimization.
4. After the transcendental engines use the service, route ordinary x87
   add/sub/mul through the same physical front/back datapath when the overlap
   profile proves those operations cannot execute concurrently. If an enabled
   overlap configuration requires one basic operation in parallel, retain one
   bounded basic lane, not a copy per commit arm.

Do the consolidation aggressively, in this order:

1. Move `fpu_fx_ppl` out of FSINCOS and make it core-owned. Give every x87
   client an explicit request/response owner. Delete every inline
   transcendental `fx_add`/`fx_mul` after its client is converted; leaving the
   old expression behind a result mux still synthesizes both datapaths.
2. Make the existing sequential `fpu_estdiv` a service operation and port
   FPATAN to it first. Replace FPATAN's two unrolled six-correction loops with
   the same one-step-per-cycle add/sub recurrence already proven by FYL2X.
   Remove the FPATAN multicycle exception after those paths become registered;
   a multicycle constraint is not area sharing and keeps a very large routed
   cone alive.
3. Implement 128x64 and 128x128 products as two and four scheduled 64x64
   partial products on the one multiplier lane. Keep a 192/256-bit accumulator
   register and perform one carry-propagating add per cycle. The focused OOC
   result says one 64x64 multiply costs 16 DSPs; the present four engines use
   1,231 DSPs. The target is therefore one 16-DSP lane, or at most two lanes
   after a measured throughput failure, rather than separately inferred wide
   products.
4. Pack the transcendental constants into one owner-indexed ROM. The four
   engines are mutually exclusive, so their coefficient case trees and the
   three F2XM1 65x80 tables do not need independent read fabrics. Prefer one
   dual-port BRAM/URAM ROM when a microstep needs two words; sequence the read
   when it needs more. Preserve the exact 80-bit constants and register the ROM
   result before arithmetic.
5. Once the services are stable, merge the four thin controllers into one
   x87-transcendental microsequencer with a shared context register bank. A
   decoded `{owner, phase, substep}` can select the unique coefficient and
   arithmetic operation. Do not retain four parallel next-state datapaths and
   mux only their final result—that saves little logic and keeps congestion.

The performance contract is asymmetric on purpose. Ordinary U/V integer issue
and ordinary pipelined x87 add/mul throughput must not regress. A rare
transcendental may take additional registered microsteps, especially where the
current implementation already waits four clocks per FPATAN state, provided
the 40 MHz workload measurement is no worse overall. This trades duplicated
hardware for latency only where the original design serialized ownership.

This refactor must preserve the exact `p5xtrans`/QEMU oracle bits. The service
owner token is mandatory: a bare shared `done` creates the same class of stale
response ownership bug just repaired in L1D.

The post-route RAM report makes the missed sharing visible. Of the x87
coefficient storage, Vivado infers block RAM only for F2XM1: two 65x68 tables
consume two RAMB36E2s and one 65x27 table consumes a RAMB18E2. No FPATAN,
FSINCOS, or FYL2X coefficient memory appears in the inferred-memory list; those
constants remain arithmetic/case mux logic. The device has 659 unused BRAM
tiles and all 112 URAMs unused, so this is exactly the right exchange: move
constant selection out of congested CLB fabric into a small shared ROM bank.

### P0: collapse the GPR writeback fabric to two addressed ports

The GPR storage is only 256 flip-flops, yet its hierarchy consumes 16,779 placed
LUTs and 651 MUXFs. Vivado's complexity report identifies it as the sole high-
complexity block: Rent exponent 0.69, average fanout 3.72, and 20,249 instances.
The cause is the per-register `gpr_we[8]` plus eight independently computed
`gpr_wd[8]` cones. The abstraction avoids an explicit priority mux in
`regfile.sv`, but moves a much larger distributed mux into every write-data bit.

The P5 can architecturally commit at most two GPR destinations in a clock. Replace
the eight write records with two addressed records
`{valid, addr[2:0], data[31:0]}`. Resolve all existing textual precedence before
the register file; if both ports target the same register, encode the current
last-write-wins result explicitly. Keep combinational reads and the two boot seed
modes unchanged. Add assertions that no third distinct destination is dropped and
that same-address resolution matches the old driver. This is resource sharing,
not serialization, so dual-issue and stack/MUL/DIV two-register commits retain
their current throughput.

### P1: retain exactly two integer execution lanes

The RTL currently has a complete slow-FSM ALU/flags/shift set plus the fast U and
V pipe sets. Only U and V can execute concurrently; the slow spine and fast issue
path are mutually exclusive. Mux the slow operands/control into the U physical
ALU/flag/shifter, leaving V as the second lane. Keep any result needed by a later
slow state in the existing registered result, rather than leaving a live
combinational dependency. This restores the original two-lane P5 resource shape
without sacrificing U/V dual issue.

Likewise, `ex_mul_p` and `ex_imul_p` are separate unsigned and signed products but
the opcodes are mutually exclusive. Use one multiplier with explicit signedness
operand conditioning and derive the two architectural interpretations from its
single product. The routed DRC names both independent DSP trees. The AAD 8x8
multiply in `uv_common` is rare and owns one more DSP; share an iterative BCD
multiply or use a measured LUT shift/add implementation instead of preserving a
dedicated DSP by default.

### P1: infer compact BTB storage without changing prediction timing

The BTB's 256 entries consume 7,698 registers and 7,297 LUTs because reset clears
tags and counters and two asynchronous lookup functions read the arrays. Only the
valid bits and replacement pointers require reset; invalid tags and counters are
don't-care. Pack `{tag,counter}` into storage duplicated for the U and V read
ports, write both copies from the single resolve port, and reset only validity.
Prefer replicated distributed RAM first because it preserves asynchronous D1
lookup. A synchronous BRAM version is acceptable only with an explicit one-stage
predict pipeline and cycle-gate proof; silently adding a fetch bubble is not.

The new routed control-set report strengthens this priority. The complete design
has 2,072 unique control sets; 1,199 are inside the Ventium core, and 576 of
those name `u_bpred_btb` alone. The report shows hundreds of one- or two-register
sets driven by per-entry/per-way `btb_ctr[*][*]` enables. That prevents dense
slice packing and is the register-array equivalent of duplicating a write
decoder beside every bit. An addressed memory write port removes those private
enables along with the LUT/register cost. Do not try to cure this with a broad
`CONTROL_SET_REMAP`: it can improve packing but preserves the duplicated decode
logic and does not create a memory.

### P1: remove repeated I-cache metadata comparisons

The distributed-RAM line store accounts for only 1,536 of the I-cache's 22,418
placed LUTs. The rest is mostly exposed metadata and repeated lookup/touch/snoop
logic. Make the following sharing explicit while preserving same-edge coherence:

- pass `{set, way}` for the three confirmed-hit LRU touches; the core already
  knows the hit way, so `do_touch` must not compare every tag again;
- compute each physical snoop's set/tag/way match once and reuse it for the valid
  clear, uop-cache hit output, and in-flight-fill poison decision;
- move linear tag/valid/victim lookup behind addressed I-cache ports instead of
  exporting every set and way to the core; and
- retain all three invalidation events in the same edge. Combining logic must not
  mux away a DMA snoop or either half of a cross-line CPU store. If a queue is ever
  used, it needs backpressure and a proof that executable data cannot be consumed
  before all queued invalidations retire.

The high-fanout report supports this priority: several I-cache carry nets fan out
to 1,500--2,027 loads. A six-bit synthesized L1D predicate has fanout 1,396 on
every bit, and physical optimization can consider only 157 loads because of
constraints or macro primitives. First reduce the repeated consumers; forced
replication should be a measured placement aid after the logical fanout is fixed,
not the primary area solution.

The same control-set report attributes another 333 unique sets to the I-cache.
Together, BTB and I-cache metadata account for 909 of the core's 1,199 control
sets (75.8%). This is independent evidence that addressed metadata memories and
one shared hit/snoop decoder will buy both LUT reduction and denser placement;
the optimization is not merely cosmetic hierarchy cleanup.

### Rejected shortcuts and acceptance thresholds

- Widened multiply syntax is not the problem. An out-of-context A/B of
  `{64'd0,a} * {64'd0,b}` versus `a * b` produces exactly 161 LUTs and 16 DSPs
  in both cases. Do not spend a repair round on that textual rewrite.
- `FP_PS_ALL`, globally disabling the fast path, forcing caching, or moving x87
  work to the PS can make the image fit, but none proves that the reconstructed
  P5 datapaths are correctly shared. They remain diagnostic/relief profiles, not
  the primary compactness fix.
- Do not serialize U and V, globally stall every store for I-cache snoops, or add
  bubbles to ordinary cache hits. Area saved by deleting the intended P5
  concurrency is a massive performance regression, not closure.
- Do not rely on hierarchy totals from an out-of-context module as the final area
  oracle. Compare synth and post-route reports from the complete design because
  the current build combines more than 47,000 core LUTs across boundaries.

The first compactness milestone is less than 85% placed CLB LUT use (at most
290,088) with no congested-router warning; the stretch target is less than 80%.
If the P0 sharing work does not remove at least 10% of the present placed design
(about 31,600 LUTs), inspect the post-synthesis primitive ownership before adding
more muxes or state. Each staged change must pass the focused unit oracle, five-
profile lint, `make verify`, `make verify-sys`, `make l1`, full `make verify-all`,
and full-system Quake/Win95 checks. Compare 40 MHz timing and workload throughput,
not only this deliberately slow 3.125 MHz diagnostic image.

Require a utilization delta after each structural stage. A change that merely
renames a helper, moves it to an include, or produces less than a measurable
full-design LUT/DSP reduction is not a compactness fix. Stop after synthesis to
inspect hierarchy and arithmetic primitive ownership before paying for full
place-and-route; proceed only when the old per-engine operators are absent and
the shared service is the sole owner. The area objective is not just a faster
route on this seed: it is enough removed logic that placement stays below 85%
without relying on cross-hierarchy LUT combining to rescue an over-capacity
106.67% synthesized design.

## Follow-up: exact failure reproduced and ownership bug repaired

The HP0-stale-data conclusion below was too strong. A source-matched full-system
Verilator run subsequently reproduced the **same reset-state ROM failure without
silicon**. At cycle 41,304,062, the physical IVT8 read at `0x00000020` received
`06c72600` (bytes from the immediately preceding instruction fetch) instead of
the resident IVT value `f000024d`; execution escaped to `CS=06c7`. This proves a
complete, deterministic failure mechanism inside the L1D/core request seam and
removes the need to assume that HP0 returned a nominally current transaction
with stale DDR data.

The defect was in `rtl/mem/ven_l1d.sv`. The normal hit path qualifies its
registered response with `rd_addr_q/rd_match`, but `L1_BYP` acknowledged any live
non-cacheable read and selected buffered data with the **live** `c_addr`. If the
core advanced from request A to request B while A's bypass response was visible,
the L1 acknowledged A's data as B. This is exactly the silicon IVT/IRET and VGA
option-ROM return signature.

The compact repair reuses the existing saved request address `fbase`, adds only
the saved four-bit read strobe/extent, and:

- asserts the bypass acknowledgement only when live `{req, read, noncacheable,
  address, strobes}` matches the saved owner; and
- selects the bypass window with saved `fbase[1:0]`, never live `c_addr[1:0]`.

An owner mismatch is discarded and the newer request retries from `L1_IDLE`.
The cache-hit path and every cacheable access remain unchanged; there is no
global bubble, cache flush, additional AXI replay, or serialization penalty.
`NARROW_REPLAY_SAFE` remains enabled in the first repaired FPGA build only to
hold the earlier silicon workaround constant during the A/B.

The new directed test `[9d]` in `verif/l1/tb_l1d.sv` launches a non-cacheable A
read containing `06c72600`, retargets the held request to IVT B at `0x20` in the
serve clock, rejects A's buffered response, and requires B to return
`f000024d`. It fails on the pre-repair RTL and passes at 128 sets, 64 sets, and
the deployed `VEN_L1_HONOR_CD` profile after the repair.

The exact unpatched reset-state ROM then completed the entire full-system model
run at cycle 82,340,000:

```text
[RMTEST] irq=1692 sw_enter=256 sw_return=256 nested=630 bad=0
         pop_return=256 pop_bad=0 pop_nested=670 main_bad=0
>>> done: cyc=82340000 retires=1096308 last cs=f000:eip=000001ce
```

Additional completed checks are:

| Check | Result |
|---|---:|
| five-profile structural lint | PASS (`LINT-GATE-OK`) |
| fast differential gate | 98/98 functional; all 20 cycle bands PASS |
| deployed KV260 CALL/RET + stack test | PASS, 67 retired |
| deployed cross-word / memory sweep | `XOK`, `MOK` |
| deployed cross-cache-line store | `XLOK` |
| L1/AXI differential | 98/98 user + 10/10 system equivalence |
| CDC-wrapped L1/AXI differential | 98/98 user + 10/10 system equivalence |

The canonical `build/` and L1 object directories point at an external ext4
volume that remounted read-only. The affected L1/AXI Makefile targets and gate
scripts now accept alternate object, work, and golden-cache directories; the
results above were rebuilt from current sources under
`fpga_verify_20260822/l1bypown_verify/`, not accepted from stale binaries.

Historical pre-deployment checkpoint: silicon closure was still pending here.
A new full Vivado implementation was running
under `fpga_run_20260822_l1bypown/`. In parallel, the old bitstream is running a
BIOS-only workaround (clear CR0.CD/NW before entering the unchanged production
BIOS) against the clean viewsize-30 disk, solely to obtain the first exact
969-frame timedemo. Neither that workaround nor the earlier blind replay will
be accepted as the underlying fix: the new image must pass the original
unpatched reset ROM, unpatched production BIOS, and an unpatched exact timedemo.

### Timedemo-result path correction and guest experiments

`-condebug` writes `QCONSOLE.LOG` in `\QUAKE\ID1`, not in `\QUAKE`. ID1 is
FAT16 cluster 138 on this disk, at physical disk LBAs 878-879. The early live
monitor read cluster 137/LBAs 876-877, which is only the parent directory, and
therefore could never observe the result. Rechecking the correct ID1 directory
on the still-running old-bitstream control showed only `PAK0.PAK` and
`CONFIG.CFG`; it had genuinely not reached console initialization after about
one hour.

Two reversible guest accelerators were tested before touching the board disk:

- an 82-byte `FASTTICK.COM` TSR replaces the long real-mode IRQ0 chain with a
  BIOS-tick update plus PIC EOI; and
- a two-byte Quake patch removes the back-edge of the historical
  `EIP=44d60..44d7e` heap-checksum loop.

Both preserve the exact demo sequence under QEMU. Pinned QEMU 8.2.2 with the
same CR0-clearing production BIOS completed the unchanged and FASTTICK disks at
exactly 969 frames (`156.3` and `163.4` fps). Stock QEMU 10.2.1 completed the
unchanged and two-byte-patched disks at exactly 969 frames (`184.7` and `187.7`
fps). The heap patch did not materially accelerate the host control and is not
the selected workaround. Exact binaries, disk hashes, and logs are under
`quake_fasttick/` and `quake_memscan_patch/`.

## Image built and deployed

The repaired current checkout was built with Vivado 2025.2 through the
source-controlled 3.125 MHz wrapper. The exact deployed artifact is:

| Artifact/check | Result |
|---|---:|
| raw bitstream | `fpga_run_20260822_irqfix/rk_ao486_system.bit.bin` |
| bytes | 20,944,064 |
| SHA-256 | `f8f69b38417a6039db64f38c691bb1c65111afc09f670b02042e09177c2d3bf1` |
| placed CLB LUTs | 316,250 / 341,280 (92.67%) |
| CLB registers | 42,339 / 682,560 (6.20%) |
| BRAM tiles | 85 / 744 (11.42%) |
| DSP48E2 | 1,265 / 3,528 (35.86%) |
| post-route WNS/TNS | +2.004 ns / 0 |
| post-route WHS/THS | +0.011 ns / 0 |
| route | 415,779 fully routed nets; 0 unrouted nets |

The repair is small relative to the preceding fast-path area build: +115
placed LUTs and -28 registers. It does not explain the existing high global
utilization, although 92.67% LUT occupancy leaves little future placement
margin.

Before running the guest, the host and board bitstream hashes matched, the
FPGA manager reported `operating`, the paired control path returned
`IDENT=A0486501`, and the core clock measured approximately 3.12533 MHz. The
final read-only check still showed the same bitstream hash and no active
`ao486d` or Quake service.

The repaired RTL had already passed the five lint profiles, the focused narrow
replay gate, `make verify`, `make verify-sys`, and all 22 `make l1` gates. This
is therefore a hardware/model coverage failure, not a substitute for a green
gate result.

## Test 1: reset-state focused diagnostic fails deterministically

The default ROM preserves the P5 reset value `CR0=60000010`, including CD/NW.
Its SHA-256 is
`0e82ce26a47f41b849169a954b2646e87d47a8e069fd976da18432294a3798fb`.
It performs 256 nested IRQ/IRET iterations, followed by 256 repetitions of the
VGA-tail ordering seam `STI; POP DX; POP AX; RET`.

The first run completed phase 1 but escaped during phase 2:

| Counter at guest `0000:0500` | Value |
|---|---:|
| IRQ count | 947 (`03b3`) |
| software-handler enter/return | 256 / 256 |
| phase-1 nested IRQ | 491 (`01eb`) |
| phase-1 bad/active | 0 / 0 |
| POP-tail return | 35 (`0023`) |
| POP-tail bad/active | 0 / 1 |
| POP-tail nested IRQ | 91 (`005b`) |
| main-register bad | 0 |

The 15-second low-memory capture is
`irqfix_silicon/irqfix_lowmem.bin` (SHA-256
`97a9e3b39499c035453ecf0e4a071536e51f334b47bac44661f1cdf0491d5cfd`).
A trace-polled 45-second rerun stopped at exactly the same counters; its capture
is `irqfix_silicon/irqfix_lowmem_trace_45s.bin` (SHA-256
`05c3f9368eeac916156d8f35c9c52df6a25ed3c163ba67e8fb7c92a32b0e4f0a`).
The identical terminal state rules out a merely slow diagnostic or a run-time
ceiling.

A separate comparator run failed after 16 otherwise clean phase-1 software
returns. Its low-memory image, ring, and daemon log are respectively:

- `irqfix_boundary_lowmem.bin` —
  `cb4d7531dccecf00e70a69f57beeb528e6559e9af46e435d81024a0d1eeabfc7`;
- `irqfix_boundary_ring.log` —
  `bf07aa9cfb4e9d0e56967c9e58136bb963c14537b5465e077048c2a1c6f82e1f`;
- `irqfix_boundary_daemon.log` —
  `fa173cb147f5eafab8bcdb8efa1df471e20521c5c9c827e5103114ae8edf3247`.

Both failure shapes preserve the expected nested interrupt frame in stack RAM.
For example, the phase-2 stack contains `024b f000 0283 1234 0172`: resume IP,
CS, FLAGS, saved AX, and caller return. The IVT and the architectural pushes are
therefore correct; the wrong value is introduced when a microcoded read is
served.

## Test 2: cacheable A/B passes on the same bitstream

The discriminator ROM differs only by clearing CR0.CD/NW after reset:

```asm
movl %cr0, %eax
andl $0x9fffffff, %eax
movl %eax, %cr0
```

Its SHA-256 is
`3c350ba8df5c46d309316156ae9f11e19b46e132627dc31a9dbdf8227e77695f`.
The repaired bitstream completed both phases exactly with live `CR0=00000010`:

| Counter | Value |
|---|---:|
| IRQ count | 577 (`0241`) |
| software-handler enter/return | 256 / 256 |
| phase-1 nested IRQ | 282 (`011a`) |
| phase-1 bad/active | 0 / 0 |
| POP-tail return | 256 (`0100`) |
| POP-tail bad/active | 0 / 0 |
| POP-tail nested IRQ | 259 (`0103`) |
| main-register bad | 0 |

The terminal EIP was the success park at `0000020f`. The low-memory capture is
`irqfix_cached_lowmem.bin` (SHA-256
`dec5cb6404cdd0f39f641754f062b829d5b414a6770be5c744a0e0dc25371159`),
and the daemon log is `irqfix_cached_daemon.log` (SHA-256
`e5cd71f00796a421163d05dc0f85020f30024f9420a3f5bd580d5095cc8f72c1`).

This is the decisive discriminator. The core's interrupt divert, real-mode
delivery, stack pushes, IRET state machine, and cacheable response handoff all
execute in both variants. Only the reset-state L1D non-cacheable narrow-bypass
path is avoided by the passing build.

## Test 3: production BIOS fails at the VGA option-ROM return

A diskless production-BIOS run was armed with the existing linear-data trap.
It froze before POST or disk access. The newest useful ring boundary is:

```text
[10] cs=2adb eip=00001cea
[11] cs=c000 eip=00001d69
[12] cs=c000 eip=00001d68
...
```

Older entries repeatedly show the valid VGA option-ROM sequence from
`C000:1D4B` through `C000:1D69`. After the correct `RET` at `C000:1D69`, the
return offset remains the expected `1CEA`, but the selector becomes `2ADB`
instead of `C000`; execution then walks sequential data under the bad segment.
The stack around `0000:FFD8` still contains the correct `1CEA C000` return, and
IVT8 remains `F000:FEA5`. `2ADB` is instead present in unrelated option-ROM
bytes, consistent with an old read response being consumed as the high half of
the return.

Evidence:

- `irqfix_post_ring.log` — SHA-256
  `855f1ff3cb2f9acce8cd2d0946519e5ab1d2420e71f19e1e1f07b0b5c26a37d1`;
- `irqfix_post_lowmem.bin` — SHA-256
  `03bb0aa45f0022e38738d10dd461b9415d17bd19b2d8befe41b207b8c4d1aac2`;
- `irqfix_post.log` — SHA-256
  `9e79d236e6f6209dfd19c8c77626840f38d16fca950e6ef54c7c559128000b04`.

This reproduces the original VGA-tail seam on the repaired image and prevents
FreeDOS from starting. Because the production BIOS does not clear CD/NW, the
cacheable diagnostic is not a guest workaround.

## Why the implemented repair is insufficient

Two changes were under test:

1. `NARROW_REPLAY_SAFE` discards one narrow HP0 response, reissues the same AR,
   and delivers the second response; and
2. `rm_read_armed` inserts a request-free core clock before `S_RMINT_RD` and
   each `S_RMIRET` read.

The directed gate models exactly one stale response followed by one correct
response. Silicon shows that the second response can still be stale or can be
associated incorrectly. A fixed one-clock gap and one blind replay therefore
encode an observed latency pattern, not a transaction-identity invariant.

There is also no address/ownership qualification at the final L1D bypass serve:
`ven_l1d` asserts `c_ack` whenever `st == L1_BYP` and indexes `bp_line` with the
live `c_addr`. It latches the starting address in `fbase`, but does not require
the completing request to be the same read and extent. Adding that qualification
is necessary seam hardening, although it cannot by itself detect an HP0 slave
that returns old data with a nominally valid current AXI ID.

The cacheable path's repeated full-line fills passing is useful but does not
prove the second AXI transaction is intrinsically safe: it has a different
burst shape, latency, buffering, and L1 serve path.

## Proposed repair and verification plan

P0 is to repair response ownership below the core; do not add another arbitrary
delay or a third blind read.

1. **Instrument before changing behavior.** Extend the build-paired auxiliary
   ring to record every accepted AR and R completion, including discarded
   priming reads: address, ARSIZE/ARLEN, internal transaction token, RID/RRESP/
   RLAST, data, and whether the response was discarded or delivered. The
   current `dbg_rd_valid` deliberately excludes priming traffic and cannot
   distinguish the failing sequence.
2. **Stress HP0 independently.** Alternate narrow reads between two or more DDR
   addresses holding unique sentinels, including back-to-back address changes,
   idle gaps, reset release, and a prior line burst. This must identify whether
   stale data originates before `ven_axi_master`, in the width/clock converter,
   or at the PS HP0 reset/outstanding boundary.
3. **Make reset and drain ownership explicit.** Hold request generation reset
   until every AXI converter/interconnect reset is synchronously released and
   no old R beat can remain. On shutdown/reset, stop new ARs and drain or reset
   all outstanding R-channel state before accepting a new transaction.
4. **Register a transaction-owned completion.** Latch returned data, response
   status, address/size token, and completion together; acknowledge the L1 from
   that registered record, not directly from the live `RVALID/RDATA` edge.
   With one outstanding read this costs one core clock, not global
   serialization, and removes a fragile combinational ownership seam.
5. **Harden `ven_l1d` bypass completion.** Latch the complete core request
   identity at bypass start and assert `c_ack` only while the live held request
   matches it (`req`, read/write, cacheability, base address, byte offset,
   strobes/extent). Select `bp_line` using the latched request, not live
   `c_addr`. Treat an identity change as a new request after returning to IDLE.
6. **Replace the first-stale-only gate.** Add cases with zero, one, and multiple
   delayed/stale-looking responses, A/B/A address changes, variable backpressure,
   reset during an outstanding read, and a line-fill-to-narrow transition. The
   invariant is that a completion can be consumed only by its owner; a test must
   not define success as “the second response wins.” Keep narrow replay disabled
   for targets with read side effects.
7. **Retest performance and correctness.** Require the default reset-state ROM
   to complete both 256-iteration phases repeatedly, then require repeated clean
   production POST before touching a disk. Only after that run the exact Quake
   timedemo and restore/run the pristine Win95 image. Re-run lint, `make verify`,
   `make verify-sys`, `make l1`, and the FPGA timing/utilization audit.

Globally disabling the fast path, forcing CR0 caching, flushing on every
interrupt, or adding unbounded retries would either hide the bug, violate guest
semantics, or impose the massive performance regression this repair was meant
to avoid.

## Historical board state at the end of the initial irqfix investigation

At the final read-only check:

- FPGA manager: `operating`;
- deployed bitstream SHA-256:
  `f8f69b38417a6039db64f38c691bb1c65111afc09f670b02042e09177c2d3bf1`;
- no active `ao486d`, `ven-quake`, or `ven-quake-nonfast` service;
- pristine Quake VHD SHA-256:
  `38e31d11c17fb739b7a3605e6e0d43f85707c2b94a237ed19c5fdd62d97f3c0d`;
- board root filesystem: 54 MiB free (97% used).

This snapshot is retained for provenance and is superseded by the current-result
and handoff sections at the top of this audit. The comparator freeze from that
old failed POST diagnostic could still hold that older PL core, so it required a
clean reprogram before the later experiments.
