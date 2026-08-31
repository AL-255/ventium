`default_nettype wire  // Vivado project-flow: reset nettype (files compile as one unit; prevents `none` leak)
// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// core/core.sv — the Ventium integer/pipeline spine (R1 modularization,
// docs/rtl-refactor-plan.md). Renamed from intcore.sv: it now wires the
// extracted blocks (decode / issue_uv / ventium_alu_pkg / ventium_decode_pkg /
// fpu_x87_pkg) and runs the pipeline FSM + retire/DPI point. Functional spine:
// single-issue, in-order, multi-cycle integer core (PLAN.md §7,
// docs/m2-isa-spec.md), diff-clean vs QEMU user-mode.
//
// FSM skeleton (one instruction at a time, multi-cycle):
//   S_RESET  -> latch init_eip/init_esp/reset arch state
//   S_FETCH  -> read a 16-byte window at EIP (4 word reads)
//   S_DECODE -> combinational prefix+length+operand decode
//   S_LOAD   -> read a memory source / RMW dst / [ESI] or [EDI]
//   S_LOAD2  -> CMPS second memory operand ([EDI])
//   S_EXEC   -> compute result + EFLAGS; commit or hand off to a store/micro op
//   S_STORE  -> write a memory destination / push word
//   S_USEQ   -> micro-sequenced ops (PUSHA/POPA/POPF/string REP iterations)
//   S_HALT   -> int $0x80 or out-of-scope opcode: stop retiring
//
// Out-of-scope opcodes raise d_unknown and HALT loudly (no mis-execution).

// d_sysop's enum type. Promoted from an in-`core` typedef to compilation-unit
// ($unit) scope (R3) so the extracted core/decode_stages.sv decoder can declare
// its `output sysop_e d_sysop` port with the SAME type these wires (q_sysop /
// d_sysop) + the svh `q_sysop==SYS_*` compares use. Enumerators are unchanged
// (verbatim relocation; the inline copy in `core` was removed).
typedef enum logic [4:0] {
  SYS_NONE, SYS_LGDT, SYS_LIDT, SYS_MOVCR_TO, SYS_MOVCR_FROM,
  SYS_MOVSREG_TO, SYS_MOVSREG_FROM, SYS_LJMP,
  // REVIEW_Jul29 H-05 — INVLPG (0F 01 /7). Was NOT decoded at all, so it fell to
  // d_unknown and LOUD-HALTED the core; any guest that edits page tables and then
  // invalidates (DPMI hosts, Win95) would wedge. Implemented conservatively as a
  // FULL TLB flush: IA-32 permits invalidating more than the named page, so a
  // whole-TLB flush is a legal (just slower) implementation of INVLPG.
  SYS_INVLPG,
  // M2S.4 — LTR (load TR from a GDT TSS selector) and STR (store TR selector).
  SYS_LTR, SYS_STR,
  // M2S.6 — MOV r32,DRn (0F 21) and MOV DRn,r32 (0F 23). The DR index is in
  // d_sys_creg (reused: ModR/M.reg), the GPR in d_dst_reg / d_src_reg.
  SYS_MOVDR_FROM, SYS_MOVDR_TO,
  // M9.5 — real-mode far CALL ptr16:16/32 (0x9A) and RETF (0xCB / 0xCA imm16).
  // Reuse d_ljmp_off/d_ljmp_sel for the call target and d_ret_imm for RETF imm16.
  SYS_LCALL, SYS_RETF,
  // M9.5 — SGDT (0F 01 /0) / SIDT (0F 01 /1): store the 6-byte GDTR/IDTR
  // pseudo-descriptor to memory (the reverse of LGDT/LIDT's S_LGDT read).
  SYS_SGDT, SYS_SIDT,
  // PM segmentation — LLDT (0F 00 /2): load the LDTR base/limit from a GDT LDT
  // descriptor (reuses the S_LTR descriptor-read FSM, branched in core_tss_priv.svh).
  // CWSDPMI runs its code/handlers from LDT selectors, so every CS/SS/seg descriptor
  // read must pick (sel[2] ? ldt_base : gdt_base).
  SYS_LLDT,
  // REVIEW_Aug3 — SLDT (0F 00 /0): store the LDTR selector. The core has tracked
  // ldt_sel since REVIEW2 M-02; the ptaskpg differential reads it back to witness
  // the incoming task's LDTR after a task switch. Register form only (mirrors STR).
  SYS_SLDT
} sysop_e;

// The pipeline FSM state enum. Promoted from an in-`core` typedef to compilation-
// unit ($unit) scope (R3) so the extracted core/fpu_writeback.sv driver can declare
// its `input state_e state` port with the SAME type core's `state`/`walk_ret_state`
// use (core.sv precedes fpu_writeback.sv in rtl/ventium.f). Enumerators are
// unchanged (verbatim relocation, all `ifdef members preserved; the inline copy in
// `core` was removed). M7.3c: widened 5->6 bits to admit S_INS (the prior 32 states
// exactly filled a [4:0] enum).
typedef enum logic [5:0] {
    S_RESET, S_FETCH, S_DECODE, S_LOAD, S_LOAD2, S_EXEC, S_STORE, S_USEQ, S_HALT,
    // REVIEW1_Aug2 M-03: the TSS I/O-permission bitmap consult. Two beats -- the I/O
    // map base at TSS+0x66, then the bitmap byte that covers the port.
    S_IOPERM,
    // REVIEW_aug2 H-04: a fault while delivering #DF. Architecturally the CPU
    // enters SHUTDOWN; here it parks with no retire, which is what the loud HALT
    // already means to the TB, so a triple fault STOPS instead of looping.
    S_SHUTDOWN,
    S_ENTER,    // nested ENTER (level>0): read-display + push micro-sequence
    S_FLOAD, S_FEXEC, S_FSTORE,
`ifdef VEN_FP_SHARED
    // The area-shared x87 owns architectural state behind an irrevocable
    // command/response boundary.  This state waits for that response; the
    // decoder routes every x87 op through the slow path in this profile.
    S_FP_SHARED_WAIT,
`endif
`ifdef VEN_SRT_ITER
    S_FP_BUSY,   // wait for the iterative SRT FDIV/FSQRT engine
`endif
`ifdef VEN_IDIV_ITER
    S_DIV_BUSY,  // wait for the iterative integer DIV/IDIV engine
`endif
`ifdef VEN_BCD_ITER
    S_BCD_BUSY,  // wait for the iterative FP->packed-BCD (FBSTP) engine
    S_FBLD_BUSY, // wait for the iterative packed-BCD->FP (FBLD) engine
`endif
`ifdef VEN_TRANSCENDENTAL
    S_TRSC_BUSY, // wait for the iterative x87 transcendental engine (F2XM1, #11)
`endif
`ifdef VEN_FPREM
    S_FPREM_BUSY, // wait for the iterative exact partial-remainder engine (FPREM)
`endif
`ifdef VEN_FP_PIPE
    S_FEXEC_EX,  // slow-arm FP-execute 2nd stage: f_eval from the registered
                 // operands (captured in S_FEXEC) -> commit (we_wabs) + retire IN
                 // THE SAME CLOCK, so the per-retire arch-state check is exact.
`endif

`ifdef VEN_PS_PROXY
    S_SYSCALL_WAIT,   // PS-bridge (F4): hold the int-0x80 proxy until syscall_resp_valid
`endif
`ifdef VEN_FPTRAP
    S_FPTRAP_WAIT,    // PS-trap (F4): hold FPATAN until the PS writes fptrap_result
`endif
    S_FENV_ST, S_FENV_LD,   // M11b: env/state store (FNSTENV/FNSAVE) & load (FLDENV/FRSTOR)
    // M7.3b Win95 co-sim port I/O: the IN/OUT bus handshake state (cosim only).
    S_IO,
    // M7.3c INS (port-input string): per-element IN handshake, then store to [EDI]
    // (reuses the K_STR S_STORE element/retire/loop path). Cosim only.
    S_INS,
    S_PF, S_PIPE, S_F00F_HANG,
    // M2S.1 system-mode descriptor + table micro-sequences:
    S_LGDT, S_SEGLD, S_LJMP,
    // M9.5 real-mode far CALL / RETF (2-beat stack push / pop of CS:IP). Reuse
    // seg_step as the beat counter (mutually exclusive with the seg/ljmp states).
    S_LCALL, S_RETF,
    // M9.5 SGDT/SIDT: 2-beat store of the 6-byte GDTR/IDTR pseudo-descriptor.
    S_SGDT,
    // F3 real-mode IVT interrupt delivery: read the 4-byte IVT entry, push the
    // 16-bit FLAGS:CS:IP frame, then IRET pops it back. (Pure real mode, PE=0;
    // V86/PM keep the existing 8-byte-gate S_INT_* / S_IRET path.)
    S_RMINT_RD, S_RMINT_PUSH, S_RMIRET,
    // F3 interruptible HLT (system mode): HLT retires + parks here until a maskable
    // INTR / NMI wakes the core and is delivered (IRET resumes after the HLT). Real
    // firmware (SeaBIOS yield = sti;hlt) busy-waits on the timer IRQ this way. User
    // mode keeps the loud terminal S_HALT (no wake) so make verify is byte-identical.
    S_HLTWAIT,
    // M2S.2 paging: the 2-level page-walk micro-sequence (PDE read -> PTE read ->
    // optional A/D writeback -> TLB fill -> resume the diverted memory state).
    S_WALK,
    // M2S.3 IDT delivery micro-sequence (gated sys_mode). A fault DECISION (the
    // M2S.1 segment faults + M2S.2 #PF, now DELIVERED) or a software INT/INT3/
    // INTO/UD2 vectors through IDT[v]:
    //   S_INT_GATE : read the 8-byte IDT gate descriptor (offset+selector+attr)
    //   S_INT_CS   : read the 8-byte GDT code descriptor named by the gate sel
    //   S_INT_PUSH : push the exception frame (EFLAGS, CS, EIP[, error code])
    // then load CS:EIP from the gate, clear IF/TF (interrupt gate), and retire.
    // S_IRET pops EIP/CS/EFLAGS (near, same-privilege); S_INT_CS_RET reloads the
    // returned-to CS descriptor and retires the IRET.
    S_INT_GATE, S_INT_CS, S_INT_PUSH, S_IRET, S_INT_CS_RET,
    // M2S.4 — TR/TSS + cross-privilege machinery:
    //   S_LTR     : LTR — read the GDT TSS descriptor (base/limit), set busy bit,
    //               load TR. (STR is a register write, handled in S_EXEC.)
    //   S_INT_TSS : cross-priv delivery — read TSS.ssN:espN (N = target CS.DPL).
    //   S_INT_SS  : cross-priv delivery — read + load the new SS descriptor.
    //   S_IRET_SS : inter-priv IRET — reload the popped (outer) SS descriptor.
    S_LTR, S_INT_TSS, S_INT_SS, S_INT_PLAN_ARM, S_INT_PLAN, S_IRET_SS,
    // M2S.4b — HARDWARE TASK SWITCH micro-sequence (far JMP/CALL to a TSS, gated
    // sys_mode; IA-32 SDM Vol.3 §7.3). A far JMP whose target GDT descriptor is a
    // SYSTEM (S=0) available/busy 32-bit TSS (type 9/B) runs:
    //   S_TSW_SAVE : SAVE the outgoing task state into the CURRENT TSS (tr_base):
    //                EIP@0x20, EFLAGS@0x24, the 8 GPRs@0x28..0x44, the 6 segment
    //                selectors@0x48..0x5C, LDTR@0x60 (one dword write per beat).
    //   S_TSW_READ : LOAD the incoming task state from the NEW TSS (named by the
    //                jump selector): CR3@0x1C, EIP@0x20, EFLAGS@0x24, GPRs, the 6
    //                selectors, LDTR (one dword read per beat, latched in tsw_*).
    //   S_TSW_SEG  : reload the hidden descriptor (base/limit/attr) of each of the
    //                6 incoming segment selectors from the GDT (like a seg load).
    //   S_TSW_BUSY : toggle the descriptor busy bits — a JMP CLEARS the outgoing
    //                TSS busy bit (type B->9) and SETS the incoming one (9->B) —
    //                then COMMIT (new TR, CR0.TS=1, incoming EIP) and retire ONCE.
    S_TSW_SAVE, S_TSW_READ, S_TSW_LDT, S_TSW_SEG, S_TSW_BUSY,
    // M2S.5 — SMM / RSM (gated sys_mode; docs/m2s5-smm-spec.md):
    //   S_SMI_SAVE : SMI# entry — save the CPU state to the SMRAM save-state map
    //                (P5 Table 20-1 offsets @ SMBASE+0x8000+offset), then enter
    //                SMM (clear CR0.PE/PG/EM/TS; CS base=SMBASE sel=SMBASE>>4;
    //                EIP=0x8000; large limits) and retire ONCE in the SMM context.
    //   S_RSM      : RSM (0F AA) — read the whole save map back, then commit the
    //                restored state (honoring a handler-modified SMBASE/resume EIP)
    //                in one clock and resume the interrupted context.
    S_SMI_SAVE, S_RSM,
    // M2S.6 — the extra data-watchpoint handler-entry record (the qemu gdbstub
    // single-step quirk: a DATA breakpoint #DB re-reports the post-delivery state
    // stamped at the handler entry PC before the handler's first instruction).
    S_DB_EXTRA,
    S_NTRET_RD,
    // REVIEW1_Aug3 R2-C04: probe the complete new-stack frame extent (translate +
    // write-permission, NO bus transaction) between S_INT_SS's SS validation and
    // S_INT_PUSH's frame writes, while SS/CPL are still STAGED. A page fault on
    // any frame word can no longer observe new SS/CPL with old CS/EIP and a
    // partially written frame.
    S_INT_PROBE,
    // REVIEW1_Aug3 R2-H05: call-gate parameter copy. Reads the caller-stack
    // params (old SS still installed — nothing committed yet, so a faulting
    // source read is delivered in the OLD context with zero frame bytes
    // written) into cg_params[] before the staged SS/CPL commit, which then
    // happens on this state's last beat.
    S_CG_PRD
} state_e;

module core
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;
#(
    parameter logic [31:0] EFLAGS_RESET = 32'h0000_0202, // bit1 reserved-1 + IF
    parameter logic [15:0] SEG_CS = 16'h0023,
    parameter logic [15:0] SEG_SS = 16'h002b,
    parameter logic [15:0] SEG_DS = 16'h002b,
    parameter logic [15:0] SEG_ES = 16'h002b,
    parameter logic [15:0] SEG_FS = 16'h0000,
    parameter logic [15:0] SEG_GS = 16'h002b
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [31:0] init_eip,
    input  logic [31:0] init_esp,

`ifdef VEN_SNAPSHOT_RESTORE
    // Simulation-only checkpoint seed.  These ports exist only in the
    // dedicated profiler build; a normal processor always cold-resets.
    input  logic        snapshot_restore,
    input  logic [31:0] snapshot_eax, snapshot_ecx, snapshot_edx, snapshot_ebx,
    input  logic [31:0] snapshot_ebp, snapshot_esi, snapshot_edi,
    input  logic [31:0] snapshot_eflags,
    input  logic [15:0] snapshot_cs, snapshot_ss, snapshot_ds, snapshot_es,
    input  logic [15:0] snapshot_fs, snapshot_gs,
    input  logic [31:0] snapshot_ss_base, snapshot_ds_base, snapshot_es_base,
    input  logic [31:0] snapshot_fs_base, snapshot_gs_base,
    input  logic [15:0] snapshot_fctrl, snapshot_fstat,
    input  logic [7:0]  snapshot_fptag,
    input  logic [2:0]  snapshot_ftop,
    input  logic [31:0] snapshot_fip, snapshot_fdp,
    input  logic [15:0] snapshot_fcs, snapshot_fds,
    input  logic [639:0] snapshot_fpr_flat,
`endif

    // M2S.1 (docs/m2s1-segmentation-spec.md "dual-boot-mode"): selects the COLD
    // RESET state. DEFAULT 0 = USER (M0-M6 unchanged: reset to init_eip/init_esp,
    // flat 4 GB segments, the post-loader linux-user state). 1 = SYSTEM: cold
    // reset matching qemu-system-i386 (CS:EIP=F000:FFF0, REAL mode CR0.PE=0,
    // cr0=0x60000010, EDX=0x00000663, eflags=0x00000002, real-mode selectors).
    // The whole system-mode segmentation datapath below is gated on this input;
    // with boot_mode==0 every segment base is 0 and real_mode is 0, so the
    // fetch/data addressing reduces EXACTLY to the flat user-mode core and
    // `make verify` is bit-for-bit unaffected.
    input  logic        boot_mode,

    // M4: when high, the core's fast path may issue two simple instructions per
    // clock (dual U/V issue) and reports pipe/paired for the cycle trace. When
    // low (the M1/M2/M3 functional gates), the fast path retires ONE instruction
    // per clock — architecturally identical, no pairing — so the func traces are
    // bit-for-bit unaffected by the pipeline. Tied 0 by default (lint-safe).
    input  logic        cycle_mode,

`ifdef VEN_L1_AXI
    // P1-1: high when the core's mem port sits behind the REAL (stalling) L1+AXI
    // subsystem (ventium_top l1axi_en / bus_mode=2). It arms the fast-path
    // MISS-STALL gates — the dual-issue fast path otherwise latches mem_rdata the
    // same clock it asserts the request (the BFM's same-cycle-ack assumption), which
    // a real L1 cannot honor on a miss. Tied 0 in bus modes 0/1; the whole port +
    // its gates are absent in the default build (no VEN_L1_AXI) -> byte-identical.
    input  logic        real_bus,
    // P1-1 #34: a FATAL bus fault from ven_axi_master (a watchdog timeout on a stuck
    // DDR/bridge, or a SLVERR/DECERR response). The core PARKS in S_HALT + asserts
    // cpu_hung (the PS observes it + resets) instead of executing the aborted line's
    // garbage. A #MC exception delivery is a later refinement (needs the IDT up).
    input  logic        bus_err,
    // Phase D.6: per-line snoop-invalidate from the northbridge (a DMA write to a
    // line that may hold code) — routed to u_icache so DMA-loaded code is coherent.
    // Tied 0 in bus modes 0/1; absent in the default build → byte-identical.
    input  logic        ic_snoop_valid,
    input  logic [31:0] ic_snoop_addr,
    // REVIEW Aug-1 H-09: two further independent invalidation events per clock
    // (SMC store first line; its second line when the store crosses an I-line).
    input  logic        ic_snoop_valid1,
    input  logic [31:0] ic_snoop_addr1,
    input  logic        ic_snoop_valid2,
    input  logic [31:0] ic_snoop_addr2,
    // REVIEW_Jul29 H-12: external "flush all" must reach the I-cache too, not just
    // ven_l1d — otherwise a PS/host write that changes CODE leaves stale lines valid.
    input  logic        ic_flush_all,
`endif

    // M6: errata-enable bus (docs/m6-errata-spec.md). DEFAULT 0 = clean core
    // (M0-M5, bit-exact vs QEMU). When a bit is set, the core reproduces the
    // corresponding DOCUMENTED P5/P54C silicon defect (a "buggy stepping"). The
    // flag fully gates each bug: with errata_en==0 the datapath is unchanged, so
    // `make verify` stays GREEN. Bit assignment (ERR_* localparams below):
    //   [0] FDIV/SRT divide flaw      (Erratum 23)
    //   [1] FIST/FISTP overflow       (Erratum 20)
    //   [2] F00F LOCK CMPXCHG8B reg    hang (Erratum 81)
    //   [3] MOV moffs A2/A3 non-pair   (Erratum 59, cycle-mode only)
    //   [4] erroneous #DB on V86 POPF/IRET with a #GP fault (Erratum 79, M6B)
    input  logic [4:0]  errata_en,

    // ------------------------------------------------------------------------
    // M7.1 Quake user-mode lock-step int-0x80 PROXY + %gs base
    // (docs/m7-lockstep-spec.md). DEFAULT 0 = INERT — with proxy_en==0 the core
    // is byte-identical to the M0-M6 user core (int 0x80 still HALTs; gs_base is
    // unused; user %gs stays flat base 0), so `make verify` is bit-for-bit
    // unaffected. When proxy_en==1 (TB --quake-image / --lockstep mode):
    //   * an `int 0x80` (cd80) in USER mode does NOT halt: the core raises
    //     syscall_active for one clock exposing the upcoming retire `n`
    //     (syscall_n); the TB combinationally drives back the GOLDEN sys_call
    //     effects for that record — syscall_eax (kernel ret -> eax),
    //     syscall_resume_eip (the golden's NEXT-record pc; QEMU's one-insn-per-tb
    //     step folds the instruction following cd80, so the resume EIP comes from
    //     the golden, not from decoded length), and an OPTIONAL %gs TLS base
    //     (syscall_apply_gs + syscall_gs_base from set_thread_area). The core
    //     applies eax, the (latched) gs_base, advances eip to resume_eip, RETIRES
    //     the int-0x80 record (so the RTL trace has the row compare.py grades),
    //     and resumes — it never executes the kernel.
    //   * a user-mode `mov gs, sel` with the TLS GDT selector (0x33) installs the
    //     latched gs_base as seg_base[GS]; any other user selector stays flat
    //     (base 0). The kernel writes are applied by the TB directly to its
    //     memory model when it services syscall_active.
    input  logic        proxy_en,         // M7.1: enable the int-0x80 proxy + %gs base
    output logic        syscall_active,   // 1-clock: core hit cd80 in proxy mode
    output logic [63:0] syscall_n,        // the retire `n` this int-0x80 will get
    input  logic [31:0] syscall_resume_eip, // golden NEXT-record pc (post-syscall EIP)
    input  logic [31:0] syscall_eax,      // golden sys_call.ret -> eax
    input  logic        syscall_apply_gs, // 1: this syscall set a new %gs TLS base
    input  logic [31:0] syscall_gs_base,  // the resulting %gs base (set_thread_area)
`ifdef VEN_PS_PROXY
    // PS-bridge (F4): on real HW the PS answers the int-0x80 microseconds later, so
    // the proxy must STALL (S_SYSCALL_WAIT) and commit only when the PS has filled
    // syscall_eax/gs/resume AND written the kernel memory effects to the DDR carveout.
    input  logic        syscall_resp_valid,
`endif
`ifdef VEN_FPTRAP
    // FP-op PS-trap (F4): FPATAN (D9 F3) has no HW engine (the iterative transcendental
    // unit is ~2x over LUTs on the xck26). The core STALLS in S_FPTRAP_WAIT exposing the
    // floatx80 operands ST0/ST1; the PS computes atan2 and writes fptrap_result + asserts
    // fptrap_resp_valid; the core then commits ST1<-result, pops, retires. Inert unless
    // proxy_en + the op is decoded (VEN_FPTRAP). fptrap_op selects which op (0=FPATAN).
    output logic        fptrap_active,       // 1-clock: core entered S_FPTRAP_WAIT
    output logic [6:0]  fptrap_op,           // 0 = FPATAN; under VEN_FP_PS_ALL = full fxop_e
    output logic [79:0] fptrap_st0,          // ST0 (x)  floatx80
    output logic [79:0] fptrap_st1,          // ST1 (y)  floatx80
    input  logic        fptrap_resp_valid,   // PS wrote the result
    input  logic [79:0] fptrap_result,       // atan2(ST1,ST0) as floatx80
`ifdef VEN_FP_PS_ALL
    // FP_PS_ALL: the FULL x87 compute datapath is PS-trapped. Expose the extra
    // operand context (memory operand, control word, st-index, pop flag) and accept
    // the generalized result vector (res0/res1/fstat + a 4-bit stack action).
    output logic [79:0] fptrap_mem,          // f_mem80 (memory operand for FADD m32, etc.)
    output logic [15:0] fptrap_fctrl,        // control word (RC/PC) for the PS to honor
    output logic [15:0] fptrap_fstat,        // live status word (PS ORs sticky flags + cc onto it)
    output logic [2:0]  fptrap_sti,          // q_f_sti (ST(i) index for reg-form ops)
    output logic        fptrap_pop,          // q_f_pop (the instruction has a pop suffix)
    output logic [2:0]  fptrap_aluop,        // q_f_aluop (0=ADD 1=MUL 2=COM 3=COMP 4=SUB 5=SUBR 6=DIV 7=DIVR)
    input  logic [79:0] fptrap_res1,         // secondary result (FSINCOS cos / FPTAN 1.0)
    input  logic [15:0] fptrap_res_fstat,    // PS-computed status word (cond codes + flags)
    input  logic [3:0]  fptrap_action,       // stack-commit action (see core_fp_exec.svh)
`endif
`endif

    // M14: syscall ARGS exposed at the syscall_active pulse (read-only). For the
    // TB's free-run syscall EMULATOR (--emulate-syscalls): the TB samples these
    // the same clock as syscall_active to compute the real kernel effect, instead
    // of replaying a golden. Pure combinational regfile reads — completely INERT
    // to core behaviour (no feedback path), so every existing gate is unchanged.
    // i386 Linux syscall ABI: nr=eax, args=(ebx,ecx,edx,esi,edi,ebp).
    output logic [31:0] syscall_arg_eax,  // gpr_o[EAX] = syscall number
    output logic [31:0] syscall_arg_ebx,  // arg0
    output logic [31:0] syscall_arg_ecx,  // arg1
    output logic [31:0] syscall_arg_edx,  // arg2
    output logic [31:0] syscall_arg_esi,  // arg3
    output logic [31:0] syscall_arg_edi,  // arg4
    output logic [31:0] syscall_arg_ebp,  // arg5

    // ------------------------------------------------------------------------
    // M7.3b Win95 system co-sim port-I/O bus (docs/m7-lockstep-spec.md M7.3).
    // DEFAULT 0 = INERT: with cosim_en==0 the core's IN/OUT decode is the
    // M0-M6/M2S behaviour — an `out 0xf4` is the isa-debug-exit terminator (HALT,
    // no extra retire, preserving every sys gate byte-for-byte) and any OTHER
    // IN/OUT HALTs loudly (the corpus never uses port I/O), so the io_* bus below
    // is never exercised and `make verify` + the sys gates are unaffected.
    //
    // When cosim_en==1 (TB --win95-image / --lockstep mode) the core EXECUTES
    // IN/OUT through this bus, MIRRORING the mem_* protocol:
    //   * an IN raises io_req with io_we=0, io_addr=<port>, io_size=<1/2/4>; the
    //     TB drives back the matching golden dev_in[] VALUE on io_rdata + io_ack,
    //     and the core writes it width-aware into AL/AX/eAX. This is the ONLY
    //     environment input injected (the integrity crux — never a CPU register/
    //     flag/eip is fabricated; only the device-read value the CPU cannot
    //     compute on its own).
    //   * an OUT raises io_req with io_we=1, io_addr=<port>, io_size, io_wdata=
    //     <AL/AX/eAX>; the TB consumes it (and the cosim isa-debug-exit `out 0xf4`
    //     keeps terminating the run there). The CPU COMPUTES the OUT value itself.
    // The reset edx P5 stepping signature also follows the co-sim CPU model (see
    // the reset arm): cosim uses qemu `-cpu pentium` (edx=0x543), the existing sys
    // gates keep the unchanged 0x663. cosim_en implies boot_mode (system).
    // ------------------------------------------------------------------------
    input  logic        cosim_en,         // M7.3b: enable the Win95 co-sim port-I/O bus
    output logic        io_req,           // I/O bus request (IN or OUT)
    output logic        io_we,            // 1 = OUT (CPU drives), 0 = IN (CPU reads)
    output logic [15:0] io_addr,          // the 16-bit I/O port
    output logic [2:0]  io_size,          // access width in BYTES (1/2/4)
    output logic [31:0] io_wdata,         // OUT data (AL/AX/eAX, width per io_size)
    input  logic [31:0] io_rdata,         // IN data (the golden dev_in value)
    input  logic        io_ack,           // I/O response strobe (combinational-OK)

    // ------------------------------------------------------------------------
    // M8.1 EXTERNAL INTERRUPT pins (docs PROGRESS_Jun04.md "M8" + the M8.0
    // design). DEFAULT INERT: the whole external-interrupt divert below is
    // gated on `soc_en` (a NEW input that defaults 0 here and is tied 0 in
    // ventium_top), so with soc_en==0 these pins are dead — the core is
    // byte-for-byte identical to the M0-M7 core (every existing gate +
    // `make verify` unaffected). This is the proven additive pattern
    // (boot_mode / cycle_mode / errata_en / proxy_en / cosim_en all default
    // inert). When soc_en==1 (the M8 ventium_soc) an EXTERNAL maskable INTR
    // from the 8259 master, or an edge NMI, is delivered at the next
    // instruction boundary through the EXISTING verified S_INT_GATE ->
    // S_INT_CS -> S_INT_PUSH IDT FSM via the int_sw=0 (hardware) path:
    //   * intr        — LEVEL request from the 8259 master INT (held until
    //                   serviced). Delivered only when EFLAGS.IF=1 and the
    //                   one-instruction STI/MOV-SS shadow is clear.
    //   * nmi         — NON-MASKABLE edge. Latched on a rising edge, delivered
    //                   regardless of IF, vector 2, and blocks a further NMI
    //                   until the IRET that ends the handler.
    //   * inta        — 1-clock INTERRUPT-ACKNOWLEDGE strobe pulsed in the same
    //                   clock the core accepts a maskable INTR. The PIC drives
    //                   inta_vector COMBINATIONALLY off this strobe (its second
    //                   INTA cycle), which the core latches as the delivered
    //                   vector. NMI does NOT pulse inta (vector is fixed 2).
    //   * inta_vector — the 8-bit vector the PIC supplies on the inta strobe.
    //   * inta_valid  — the PIC asserts this with a meaningful inta_vector
    //                   (reserved for a future spurious-IRQ refinement; the
    //                   master 8259 always supplies a vector, so the current
    //                   divert latches inta_vector unconditionally).
    // ------------------------------------------------------------------------
    input  logic        soc_en,           // M8.1: enable the external-interrupt divert
    input  logic        intr,             // level: pending maskable INTR (8259 master)
    input  logic        nmi,              // edge: non-maskable interrupt request
    output logic        inta,             // 1-clock INTERRUPT-ACKNOWLEDGE strobe
    input  logic [7:0]  inta_vector,      // PIC-supplied vector (combinational on inta)
    input  logic        inta_valid,       // PIC has a meaningful inta_vector

    // REVIEW2 M-03: the A20 gate. Was ABSENT -- no masking in the core, no top-level
    // control -- so with A20 disabled, accesses that must ALIAS at 1 MiB stayed
    // distinct in memory and in the caches. 1 = A20 enabled (normal, no masking);
    // 0 = A20 forced low, so the physical address wraps at 1 MiB. Applied to the
    // POST-TRANSLATION physical address in core_bus_driver.svh, which is where the
    // gate sits on real silicon (on the address pins). The gate itself is a PLATFORM
    // function (port 0x92 / the keyboard controller), so it is an input here and is
    // driven by ventium_top; only the masking belongs in the core.
    input  logic        a20_gate,
    // REVIEW1_Aug2 M-07: pulsed high when software requests the port-0x92 fast
    // reset. The core also stops (S_SHUTDOWN); a platform that wires this to a
    // reset controller gets the architectural behaviour.
    output logic        fast_reset_req,
    // REVIEW2_aug2 C-08: the memory hierarchy has to know where SMRAM ACTUALLY is.
    // The guard was hard-coded to 0xA0000-0xBFFFF (the 82437FX video aperture) while
    // this core's SMBASE is 0x30000 -- so it protected a range this core does not use
    // and left the real handler and save map unprotected.
    output logic [31:0] smbase_o,
    // REVIEW2_aug2 H-18: INVD/WBINVD must reach the D-side/L2 too; flush_all is a
    // top-level input, so the core exports the request instead of driving it.
    output logic        cache_inv_req,
    // REVIEW2 H-24: SMRAM isolation needs the core's live SMM state at the memory
    // hierarchy (the cache map opens SMRAM exclusively for SMM and protects it
    // outside SMM). Part of the unconditional core contract: SMM exists in every
    // configuration, so the export does too -- configurations without a memory
    // hierarchy sink it.
    output logic        smm_active_o,
    output logic        mem_req,
    output logic        mem_we,
    // ---- REVIEW1_Aug2 C-10: the core now REQUESTS a locked transaction ------------
    // LOCK was a decoder-level no-op for implemented RMW ops, and every bus wrapper
    // hardwired its lock pin low, so the integrated core never asked the interconnect
    // for atomicity at all. This carries the architectural intent out to the bus for
    // the whole RMW: asserted from the read beat through the write beat of a locked
    // read-modify-write, so a wrapper can hold the bus across both.
    output logic        mem_lock,
    // REVIEW2_aug2 H-13: the physical MEMORY TYPE of the line being fetched, from the
    // chipset cacheability map (ven_cachemap in ventium_l1_axi). 1 = do not retain this
    // line in the icache. Tied 0 in builds with no L1AXI/northbridge in front of the
    // core, where there is no region information to have.
    input  logic        ic_mtype_nc,
    output logic [31:0] mem_addr,
    // task #51: the PRE-TRANSLATE linear address for the SAME access mem_addr describes. The
    // I-cache is LINEAR-tagged (flin = seg_base[SG_CS] + eip) but the self-modifying-code snoop
    // in ventium_l1_axi drives the PHYSICAL core_addr, so with paging on it invalidates the wrong
    // line. Exporting the linear address lets that snoop match the tags it is actually clearing.
    // When paging is off cur_lin == mem_addr, so real-mode behaviour is bit-identical.
    output logic [31:0] mem_lin,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    // REVIEW1_Aug3 R2-C03: the raw bus side. The FSM-visible mem_ack/mem_rdata
    // are derived inside (the fragment engine gates the ack and merges read
    // fragments); everything pre-existing reads the internal wires unchanged.
    input  logic [31:0] bus_rdata,
    input  logic        bus_ack,

    // M6: raised (and latched) when the core enters the F00F hang state
    // (Erratum 81). Lets the TB observe the documented "system hang" without the
    // core ever retiring the offending instruction or a clean #UD.
    output logic        cpu_hung,

    output logic        retire_valid,
    output logic [31:0] retire_pc,
    output arch_state_t retire_state,

    // x87 post-commit architectural state (M3). Valid in the same cycle as
    // retire_valid. `retire_x87_touched` is 1 iff the retired instruction was an
    // x87 op (so ventium_top calls vtm_retire_x87 only then). st0..st7 are in
    // TOP-relative order (st0 = register at TOP), each canonical floatx80[79:0].
    // fstat already has TOP overlaid in bits[13:11]; ftag follows QEMU's
    // user-mode gdbstub convention (constant 0x0000).
    output logic        retire_x87_touched,
    output logic [15:0] retire_fctrl,
    output logic [15:0] retire_fstat,
    output logic [15:0] retire_ftag,
    output logic [79:0] retire_st0, retire_st1, retire_st2, retire_st3,
    output logic [79:0] retire_st4, retire_st5, retire_st6, retire_st7,

    // ------------------------------------------------------------------------
    // M4 cycle-trace attribution (docs/m4-pipeline-spec.md "RTL cycle-trace
    // producer", trace-format §2.3). The dual-issue pipeline raises these in the
    // SAME clock as retire_valid, conveying which pipe each retiring instruction
    // issued to and whether it issued paired. A paired issue retires TWO
    // instructions in one clock: retire_valid+retire2_valid both high, the U
    // insn carries retire_pipe=U/paired=0 and the V insn retire2_pipe=V/paired=1.
    // ventium_top turns each high retire(2)_valid into a vtm_retire(+_cycle) call.
    // pipe encoding: 0=U, 1=V, 2=none. (Func mode ignores all of this.)
    // ------------------------------------------------------------------------
    output logic        retire_pipe_valid,   // primary retirement carries pipe info
    output logic [1:0]  retire_pipe,         // 0=U 1=V 2=none for the primary insn
    output logic        retire_paired,       // primary insn issued paired (always U=0 here)

    output logic        retire2_valid,       // a SECOND insn retired this same clock
    output logic [31:0] retire2_pc,
    output arch_state_t retire2_state,
    output logic [1:0]  retire2_pipe,        // pipe for the second insn (V=1)
    output logic        retire2_paired,      // second insn paired with the first (1)

    // ------------------------------------------------------------------------
    // M2S.1 system-mode retire payload (docs/m2s1-segmentation-spec.md "TB sys
    // emission"). Valid in the same clock as retire_valid. retire_sys is high
    // only for a system-mode core (boot_mode=1); ventium_top then calls the
    // vtm_retire_sys DPI hook carrying cr0..cr4 (and the selectors, which are
    // already in retire_state). In user mode retire_sys stays low and these are
    // never read, so the user trace is byte-for-byte identical.
    // ------------------------------------------------------------------------
    output logic        retire_sys,          // this retirement carries system state
    output logic [31:0] retire_cr0, retire_cr2, retire_cr3, retire_cr4
`ifdef VEN_DBG_CORE
    ,
    // ------------------------------------------------------------------------
    // Debug observability taps (VEN_DBG_CORE). PURE OBSERVERS of existing FSM/
    // arch registers — add no logic to any datapath, never feed back, so a
    // +VEN_DBG_CORE build is cycle-identical. With no define, none of this exists
    // and the default/deploy build is byte/cycle-identical.
    //   dbg_state    — FSM micro-state (state_e): WHERE/why the core is parked.
    //   dbg_int_vec  — last delivered exception/interrupt vector (#UD=6/#GP=13/
    //                  #PF=14/ext IRQ); holds the last value.
    //   dbg_fault_pc — source EIP of that exception/interrupt (int_src_pc).
    //   dbg_cr0      — live CR0: PE(bit0)/PG(bit31) reveal real/protected/paging.
    // (single-step / breakpoint control ports are added below once the FSM
    //  issue-boundary hold is wired — see the dbg_hold block.)
    // ------------------------------------------------------------------------
    output logic [5:0]  dbg_state,
    output logic [7:0]  dbg_int_vec,
    output logic        dbg_div_fault,  // sticky: a divide #DE (vector 0) was delivered -> freeze the PC ring
    output logic [7:0]  dbg_fault_cnt,  // count of all exception deliveries (for the fault-freeze skip)
    output logic [31:0] dbg_fault_pc,
    output logic [31:0] dbg_cr0,
    output logic [15:0] dbg_fctrl,      // live x87 control word (PC=[9:8],RC=[11:10])
    output logic [5:0]  dbg_fxop,       // q_fxop currently in flight (halt-cause probe)
    output logic [63:0] dbg_ibuf,       // 8 fetch-window bytes at the committed EIP (PM-wedge disasm)
    output logic [63:0] dbg_seg,        // [31:0]=GDTR base, [32]=CS.D (PM-wedge descriptor probe)
    output logic [63:0] dbg_de_num,     // divide-#DE tap: faulting dividend (EDX:EAX), snapshot at #DE
    output logic [63:0] dbg_de_info,    //   {divisor[31:0], eip[15:0], w[2:0], decnt[12:0]}
    // Single-step / instruction-breakpoint control (the ONLY debug signals that
    // affect execution, and ONLY when the PS arms them — see the dbg_hold block).
    // Park owns a quiescent S_DECODE/S_PIPE/S_HLTWAIT boundary.  It has priority
    // over external delivery, which remains pending until the debugger resumes.
    input  logic        dbg_halt_req,   // level: park at the next instruction boundary
    input  logic        dbg_step,       // pulse: release for exactly ONE instruction
    input  logic        dbg_bp_en,      // enable the PC breakpoint
    input  logic [31:0] dbg_bp_addr,    // park when the about-to-issue EIP == this
    input  logic        dbg_bp_clr,     // pulse: clear a latched breakpoint (resume)
    output logic        dbg_halted,     // 1 = parked at an instruction boundary
    // Compact architectural-state scan port.  The selector is deliberately
    // consumed *inside* the core so an x87 8x80-bit state dump does not create a
    // 640-bit cross-hierarchy route to the FPGA wrapper.  It is read only while
    // dbg_halted, after all effects of the preceding instruction have committed.
    input  logic [6:0]  dbg_arch_sel,
    output logic [31:0] dbg_arch_data,
    // ---- Patchable opcode-capture hook (generalises the divide-#DE tap): the PS
    // arms dbg_hook_cfg to select WHICH instruction class to record; on each match
    // the core bumps dbg_hook_seq and latches a snapshot {eip, opA, opB, meta} the PS
    // reads back (poll the seq counter for a new capture). Purely observational — never
    // affects execution. cfg[0]=enable, cfg[1]=class:DIV/IDIV, cfg[9:2]=opcode (future
    // raw-opcode match), cfg[10]=match-opcode, cfg[13:11]=modrm.reg, cfg[14]=modrm-care.
    input  logic [15:0] dbg_hook_cfg,
    output logic [7:0]  dbg_hook_seq,   // capture counter: increments on each match (ven_soc_dbg rings on change)
    output logic [31:0] dbg_hook_eip,   // the matched instruction's EIP
    output logic [63:0] dbg_hook_opa,   // operand A (DIV/IDIV: dividend EDX:EAX)
    output logic [31:0] dbg_hook_opb,   // operand B (DIV/IDIV: divisor)
    output logic [31:0] dbg_hook_meta   // {opcode/subop[7:0], cs[15:0], 5'b0, width[2:0]}
`endif
);

  // ===========================================================================
  // Architectural state
  // ===========================================================================
  logic [31:0] eip;
  logic [31:0] eflags;
  // R3: the architectural GPR file now lives in the `regfile` submodule (its own
  // synchronous dual-boot-mode reset + per-register write bus). The spine drives
  // gpr_we/gpr_wd from the writeback driver below; gpr_o is the registered read-
  // out (combinationally visible), used everywhere the old `gpr` array was read.
  logic [NUM_GPR-1:0] gpr_we;          // per-register write enable
  logic [31:0]        gpr_wd [NUM_GPR]; // per-register write data
  logic [31:0]        gpr_o  [NUM_GPR]; // registered read-out (eax..edi)

  regfile u_regfile (
    .clk       (clk),
    .rst_n     (rst_n),
    .boot_mode (boot_mode),
    .cosim_en  (cosim_en),
    .init_esp  (init_esp),
`ifdef VEN_SNAPSHOT_RESTORE
    .init_restore(snapshot_restore && !boot_mode),
    .init_eax  (snapshot_eax), .init_ecx(snapshot_ecx),
    .init_edx  (snapshot_edx), .init_ebx(snapshot_ebx),
    .init_ebp  (snapshot_ebp), .init_esi(snapshot_esi),
    .init_edi  (snapshot_edi),
`endif
    .gpr_we    (gpr_we),
    .gpr_wd    (gpr_wd),
    .gpr_o     (gpr_o)
  );

  // ===========================================================================
  // M2S.1 system-mode architectural state (docs/m2s1-segmentation-spec.md).
  // ALL of this is INERT when boot_mode==0 (user): the selectors mirror the
  // SEG_* params, every base is 0, real_mode is 0, and creg0/creg2/3/4 are not
  // emitted. The addressing functions below fold the bases in additively, so a
  // base of 0 is the unchanged flat user-mode address. sys_mode latches
  // boot_mode at reset so the gating is a single registered bit.
  // ===========================================================================
  logic        sys_mode;          // latched boot_mode (1 = system-mode core)
  logic [31:0] creg0;             // CR0 (PE bit0, ..., PG bit31). Only PE active.
  logic [31:0] creg2, creg3, creg4;   // present; untouched this stage (paging=M2S.2)
  // Segment selectors (visible part). Index order = SEG_KEYS: cs ss ds es fs gs.
  logic [15:0] seg_sel  [NUM_SEG];
  // Hidden descriptor cache: base + limit (byte granular, expanded) + the access
  // byte (P/DPL/S/type) per segment. limit/attr are the home for the protection
  // checks computed at descriptor load (seg_load_fault); the pseg corpus loads
  // only clean descriptors so the decision is always "no fault" — but it IS
  // computed (NOT just declared), per docs/m2s1-segmentation-spec §3.
  logic [31:0] seg_base [NUM_SEG];
  logic [31:0] seg_limit[NUM_SEG];   // hidden limit (byte granular; limit checks)
  logic [7:0]  seg_attr [NUM_SEG];   // descriptor access byte: P|DPL[1:0]|S|type[3:0]
  // REVIEW2_aug2 H-05: the descriptor's B/D bit, PER SEGMENT. The core cached it only
  // for SS (ss_b) and CS (cs_d), so a non-SS expand-down data segment had no upper
  // bound available and fell back to 4 GiB -- fail-open. Defaults to 1 (= the old 4 GiB
  // bound) so any load path not yet covered keeps EXACTLY today's behaviour: this can
  // only start catching violations it used to miss, never invent one.
  logic        seg_b   [NUM_SEG];
  // CPL = the current privilege level, derived from CS.RPL on a CS load (far
  // jump). Reset/real mode: 0. Used as the EFFECTIVE privilege in the DPL checks.
  logic [1:0]  cpl_r;
  // GDTR / IDTR (loaded by LGDT/LIDT).
  logic [31:0] gdt_base;
  logic [15:0] gdt_limit;
  // LDTR (loaded by LLDT from a GDT LDT descriptor). TI=1 selectors index this table.
  // REVIEW2 M-02: the SELECTOR was not kept at all -- LLDT and the task switch loaded
  // base/limit and threw the selector away. It is architectural state (SLDT reads it
  // back, and the SMM save map has a slot for it), so it could be neither reported nor
  // round-tripped through RSM. TR has always kept its selector; LDTR now matches.
  logic [31:0] ldt_base;
  logic [15:0] ldt_limit;
  logic [15:0] ldt_sel;
  logic [31:0] idt_base;
  logic [15:0] idt_limit;
  // M2S.4 — TR / TSS. LTR loads the task register from a GDT TSS descriptor; the
  // hidden cache holds the TSS linear base + limit (and the selector for STR).
  // tr_valid records whether a TSS has been installed (so cross-priv delivery
  // can read TSS.ssN:espN; if no TR is loaded a cross-priv attempt would #TS,
  // but the pcpl corpus always LTRs first).
  logic [15:0] tr_sel;
  logic [31:0] tr_base;
  logic [31:0] tr_limit;
  logic        tr_valid;
  // M2S.4b — the OUTGOING TSS descriptor access byte (captured at LTR), so a task
  // switch can clear its busy bit (type B->9) without re-reading the descriptor.
  logic [7:0]  tr_attr;
  // REVIEW_Aug3 H-11b: the LTR architectural side effect. IA-32 marks the loaded
  // TSS descriptor BUSY (type 9->B) in the GDT before the instruction completes;
  // omitting it let software read the descriptor as available and LTR the same
  // selector twice without fault. ltr_busy_q runs the extra bus beat (the byte
  // write at descriptor+5) and the ltr_*_q scratch holds the validated descriptor
  // fields until the write lands -- TR commits only after it, so a fault on the
  // busy write leaves TR untouched. lldt_null_q marks a null LLDT at dispatch:
  // no descriptor read at all (see the S_LTR arm).
  logic        ltr_busy_q;
  logic [15:0] ltr_sel_q;
  logic [31:0] ltr_base_q, ltr_limit_q;
  logic [7:0]  ltr_attr_q;
  logic        lldt_null_q;
  // M2S.5 — SMM / RSM (docs/m2s5-smm-spec.md). SMBASE holds the base of the SMRAM
  // region (reset default 0x30000; RSM may relocate it from the SMBASE save slot).
  // smm_active = the CPU is currently in System Management Mode (HF_SMM); set on
  // SMI# entry, cleared by RSM. It gates the addressing-context overrides AND the
  // RSM decode (RSM is #UD outside SMM). smi_pending latches a recognised SMI#
  // (the APIC self-IPI with delivery-mode=SMI in the psmm corpus) so it is taken
  // at the NEXT instruction boundary, exactly like qemu's deferred SMI dispatch.
  // (The interrupted CR0 — incl. PE/PG — is saved to the SMRAM map at SMI# entry
  // and read back from it on RSM, so no separate "saved PE" register is kept; the
  // SMM addressing context is driven directly by CR0.PE==0 + the SMM CS/base set
  // up at entry.)
  logic [31:0] smbase;            // SMRAM base (default 0x30000)
  assign smbase_o = smbase;       // C-08: exported so the L1/AXI guard tracks it
  assign cache_inv_req = cache_inv_go;   // H-18: INVD/WBINVD -> invalidate the hierarchy
  logic        smm_active;        // in SMM (1 = HF_SMM)
  assign smm_active_o = smm_active;   // REVIEW2 H-24: export to the memory hierarchy
  logic        smi_pending;       // a recognised SMI# is waiting for an insn boundary
  // M2S.5 scratch for the SMI-save / RSM-restore micro-sequences (state-save map
  // at SMBASE+0x8000+offset, P5 Table 20-1 layout — see S_SMI_SAVE / S_RSM).
  logic [5:0]  smm_step;          // beat counter across the save/restore sequence
  logic [31:0] smm_resume_eip;    // EIP to save (next insn after the SMI boundary)
  // RSM read-back holding registers: the restore reads the whole map into these,
  // then commits the architectural state in one clock on the final beat so a
  // half-restored context is never observable mid-sequence.
  logic [31:0] rsm_cr0, rsm_cr3, rsm_cr4, rsm_cr2;
  logic [31:0] rsm_eflags, rsm_eip;
  logic [31:0] rsm_gpr [NUM_GPR];
  logic [15:0] rsm_sel  [NUM_SEG];
  logic [31:0] rsm_base [NUM_SEG];
  logic [31:0] rsm_limit[NUM_SEG];
  logic [7:0]  rsm_attr [NUM_SEG];
  // REVIEW2 M-03: the A20 latch, written by an OUT to port 0x92 bit 1 (see
  // core_io.svh for why it lives here and not in ventium_top). Reset 1 = A20
  // ENABLED, matching post-reset hardware and keeping every existing configuration
  // bit-identical until software actually clears it.
  logic        a20_r;
  logic       kbc_d1_armed;  // REVIEW1_Aug2 H-10: 8042 0xD1 seen, next 0x60 write carries A20
  // Effective gate = the platform override AND the software latch. Either can
  // disable A20; both must agree to enable it.
  logic        a20_on;
  assign a20_on = a20_gate && a20_r;

  // REVIEW2_aug2 H-14: the I-cache is LINEAR-tagged, but A20 masking is applied to the
  // FINAL PHYSICAL address. Toggling A20 therefore changes which physical byte a fixed
  // linear fetch denotes WITHOUT changing its tag, so a line filled with A20 enabled can
  // be executed after A20 is disabled, or the reverse. Nothing invalidated on the
  // transition. This is the same class as H-05 (linear tags vs aliases), and the same
  // conservative remedy applies: flush executable state on the EDGE. A20 changes are
  // rare -- the BIOS/DOS enable-disable sequence, and HIMEM -- so the cost is bounded,
  // unlike flushing on every store.
  logic a20_on_q, a20_flush;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) a20_on_q <= 1'b1;        // matches a20_r's reset value (enabled)
    else        a20_on_q <= a20_on;
  assign a20_flush = (a20_on != a20_on_q);

  // REVIEW_Aug4 A4-H02: ONE executable-state flush domain. The I-cache, the
  // uopcache/predecode, and the fetch-bypass (icbp) validity must die on the
  // same events -- the flush expression used to be written out per consumer,
  // which is exactly how the bypass's validity drifted out of the domain
  // (DMA writes, TLB remaps, A20 changes, and cache invalidations all left
  // stale non-cacheable bytes executable). cache_inv_go is declared below;
  // the assign is order-independent.
  // invalidation must win over CONSUMPTION as well as insertion: while the flush
  // is asserted (this cycle, before the clearing edge) the arrays still expose
  // their pre-flush valids, so a fast path could issue/retire from a line the
  // flush is killing -- the deterministic case is RSM, where smm_flush is high
  // the cycle after exit and a cached SMRAM line could retire one stale
  // instruction. exec_issue_ok gates every fast-serve decision (sfetch_fast,
  // pipe_bytes_ok, v_bytes_ok, uop_hit) so a flush cycle always takes the
  // refetch path. (ic_present itself stays raw: the byte-gather/decode path
  // consumes it, and gating there closes a comb loop through cache_inv_go.)
  //
  // tlb_flush enters the domain through tlb_flush_q (one registered cycle):
  // the raw signal is combinational from the delivery/RSM states' mem_ack, and
  // gating the serve decisions on it directly closes a real loop (pipe_* ->
  // cur_lin -> the fragment engine's mem_ack -> tlb_flush). The TLB-internal
  // flush (fe_*_v, u_itlb/u_dtlb) keeps the raw edge; the executable arrays
  // die one cycle later, on the same edge the remapped fetch would first
  // consume them -- the consumption gate bridges exactly that window.
  logic tlb_flush_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) tlb_flush_q <= 1'b0;
    else        tlb_flush_q <= tlb_flush;
`ifdef VEN_L1_AXI
  logic exec_flush_all;
  assign exec_flush_all = ic_flush_all || (ic_snoop_valid && paging_on)
                       || a20_flush || cache_inv_go || tlb_flush_q;
`else
  logic exec_flush_all;
  assign exec_flush_all = a20_flush || cache_inv_go || tlb_flush_q;
`endif
  logic exec_issue_ok;
  assign exec_issue_ok = !exec_flush_all;

  // REVIEW2_aug2 H-12: SELF-MODIFYING-CODE SNOOP, GENERATED IN THE CORE.
  //
  // ic_snoop_valid1/2 (the CPU store snoop) are connected in ventium_top ONLY inside
  // `ifdef VEN_L1_AXI, because the snoop was generated by ventium_l1_axi. In the
  // DEFAULT build those core ports are UNCONNECTED, so the I-cache never learns about
  // CPU stores at all -- self-modifying code is stale regardless of aliasing, and
  // VEN_IC_ALIAS_SAFE (H-05, mine) keys on a signal that is constant 0 there. That is
  // why enabling that define produced a BYTE-IDENTICAL binary: it had nothing to hook
  // onto. My unit gate drove port 1 directly, so it passed while the shipping build
  // could never exercise it.
  //
  // The core does not need the L1 to tell it about its own stores. The snoop is
  // derived from the store this core is issuing (the physical beat address --
  // see the note at smc_a1 below), and cur_is_w marks the write.
  //
  // The second port covers a store whose bytes cross an I-cache line boundary.
  logic        smc_v1, smc_v2;
  logic [31:0] smc_a1, smc_a2;
  assign smc_v1 = mem_req_pre_sq && cur_is_w && fe_translatable;
  // REVIEW1_Aug3 R2-H09: the snoop now carries the beat's PHYSICAL address --
  // mem_addr is the post-translate bus address (the bus driver's tail runs
  // mem_xlate in place), per-fragment under the fx engine (a page-straddling
  // store snoops each page's physical line on that fragment's beat), and the
  // icache matches it against the per-line PHYSICAL tag (ic_ptag). A store
  // through ANY alias of a physical line therefore drops every aliased copy --
  // the linear-alias stale-executable hazard is closed. Over-invalidation
  // (a TLB-miss clock passes the linear through; the probe beat snoops page 2)
  // costs a refill, never correctness. Supersedes task #51's linear workaround.
  assign smc_a1 = mem_addr;
  assign smc_v2 = smc_v1 &&
                  ((mem_addr[4:0] + {1'b0, cur_size}) > 6'd32);   // crosses the line end
  assign smc_a2 = {mem_addr[31:5], 5'd0} + 32'd32;

  // R2-H09: the muxed CPU-store snoop (the L1's external view OR the core's own),
  // physical domain -- one definition shared by the icache port map and the
  // non-cacheable fetch bypass clear, so the two cannot drift apart.
  logic        icsnp_v1, icsnp_v2;
  logic [31:0] icsnp_a1, icsnp_a2;
`ifdef VEN_L1_AXI
  assign icsnp_v1 = ic_snoop_valid1 || smc_v1;
  assign icsnp_a1 = ic_snoop_valid1 ? ic_snoop_addr1 : smc_a1;
  assign icsnp_v2 = ic_snoop_valid2 || smc_v2;
  assign icsnp_a2 = ic_snoop_valid2 ? ic_snoop_addr2 : smc_a2;
`else
  assign icsnp_v1 = smc_v1;  assign icsnp_a1 = smc_a1;
  assign icsnp_v2 = smc_v2;  assign icsnp_a2 = smc_a2;
`endif
`ifndef SYNTHESIS
  // A snoop that never fires is the bug this finding IS. Count it.
  int ven_smc_n; logic ven_smclog_en;
  initial begin ven_smclog_en = $test$plusargs("ven_smclog") != 0; ven_smc_n = 0; end
  always_ff @(posedge clk) if (rst_n && smc_v1) ven_smc_n <= ven_smc_n + 1;
  final if (ven_smclog_en) $display("[SMCSNOOP] core-generated store snoops: %0d", ven_smc_n);
`endif

  // REVIEW2_aug2 H-18: INVD/WBINVD retired as privileged NOPs, invalidating nothing.
  // QEMU's flat cache model is not an oracle for FPGA cache state: firmware and OSes
  // issue WBINVD across cache/memory-type transitions, and leaving L1I/L1D/L2 contents
  // resident preserves exactly the stale code/data the instruction exists to discard.
  //
  // The I-cache is invalidated here (the core owns it). The D-side/L2 flush is a
  // top-level input the core cannot drive, so the request is EXPORTED and ventium_top
  // ORs it into the L1's flush_all -- the same shape M-01 uses for fast_reset_req.
  //
  // NOT the full fix the review asks for: it does not SEQUENCE a writeback and retire
  // only once the hierarchy is quiescent. Ventium's L1D is write-through, so there are
  // no dirty lines to write back and invalidate-only is the whole of WBINVD's effect
  // here; a write-back cache would need the sequenced form.
  logic cache_inv_go;
  assign cache_inv_go = d_cacheinv && (state == S_DECODE) && !d_unknown;
`ifndef SYNTHESIS
  int ven_cinv_n; logic ven_cinvlog_en;
  initial begin ven_cinvlog_en = $test$plusargs("ven_cinvlog") != 0; ven_cinv_n = 0; end
  always_ff @(posedge clk) if (rst_n && cache_inv_go) ven_cinv_n <= ven_cinv_n + 1;
  final if (ven_cinvlog_en) $display("[CACHEINV] INVD/WBINVD invalidations: %0d", ven_cinv_n);
`endif
`ifndef SYNTHESIS
  // Reachability probe: a fix that never fires is not a fix. +ven_a20log counts the
  // transitions, so "the a20 gate is green" cannot be mistaken for "this does anything".
  int ven_a20_edges;
  logic ven_a20log_en;
  initial begin ven_a20log_en = $test$plusargs("ven_a20log") != 0; ven_a20_edges = 0; end
  always_ff @(posedge clk) if (rst_n && a20_flush) ven_a20_edges <= ven_a20_edges + 1;
  final if (ven_a20log_en)
    $display("[A20FLUSH] I-cache flushes on an A20 transition: %0d", ven_a20_edges);
`endif

  logic [31:0] rsm_gdtb, rsm_idtb, rsm_smbase;
  logic [15:0] rsm_gdtl, rsm_idtl;
  // REVIEW2 M-02: the save map omitted DR6/DR7 and the whole of TR/LDTR, so an SMM
  // handler that touched debug or task state could not round-trip it -- RSM silently
  // resumed the interrupted context with the HANDLER's breakpoints and task register.
  logic [31:0] rsm_dr6, rsm_dr7;
  logic [15:0] rsm_tr_sel, rsm_ldt_sel, rsm_ldt_limit;
  logic [31:0] rsm_tr_base, rsm_tr_limit, rsm_ldt_base;
  logic [7:0]  rsm_tr_attr;
  logic        rsm_tr_valid;
  // ({cs_d, cpl} are restored directly from the final read-back beat, not staged
  // in a holding reg — see S_RSM commit.)

  // ===========================================================================
  // M8.1 — EXTERNAL INTERRUPT recognition latches (mirror the smi_pending block).
  // ALL of these are INERT when soc_en==0: they are only ever written inside a
  // `soc_en`-gated branch, so with the pins tied off (ventium_top) they hold
  // their reset value (0) forever and never affect the datapath — every existing
  // gate stays bit-identical. (Like smi_pending, the recognition is sampled at
  // the S_DECODE instruction boundary so an external interrupt is taken BEFORE
  // the about-to-run instruction executes, i.e. it restarts at the current EIP.)
  // ===========================================================================
  logic        intr_pending;      // a maskable INTR (8259) is asserted (level-mirror)
  logic        nmi_pending;       // an NMI edge has been latched, awaiting delivery
  logic        nmi_prev;          // previous-clock nmi level, for rising-edge detect
  logic        irq_shadow;        // the STI / MOV-SS one-instruction interrupt inhibit
                                   // (HF_INHIBIT_IRQ): set for exactly the ONE
                                   // instruction following an STI, cleared at the next
                                   // S_DECODE boundary, so an INTR cannot interpose
                                   // between STI and the next instruction.
  logic        nmi_in_progress;   // an NMI handler is running: blocks a further NMI
  // REVIEW2 H-09: interrupt frames stacked INSIDE the NMI handler. NMI blocking must
  // be released by the IRET that unwinds the NMI's OWN frame -- but every IRET was
  // clearing it, so a maskable interrupt taken inside an NMI handler could execute
  // its own IRET and re-arm NMI while the outer NMI handler was still running.
  // Count deliveries that nest inside the NMI and let their IRETs decrement instead.
  logic [3:0]  nmi_nest;
                                   // until the IRET that ends it (NMI masking, IA-32).

  // P5 SMRAM State Save Map — register offsets (Pentium Dev. Manual Vol.3
  // Table 20-1, 510\60 variant). The ABSOLUTE save-map address of a field is
  // smbase + 0x8000 + offset; the map spans offset 0x7E00..0x7FFC (absolute
  // SMBASE+0xFE00..SMBASE+0xFFFC). The architecturally-named, writeable/restored
  // fields the round-trip needs are below; the segment HIDDEN descriptor state
  // (base/limit/attr) is saved into the reserved areas (the exact P5 reserved-slot
  // encoding is stepping-specific / not publicly documented, so the hidden-state
  // layout here is this RTL's internal convention — see the DONE-PARTIAL note in
  // the README). All fields land in the documented map window so RSM round-trips.
  // Table 20-1 also defines DR6 @ 0x7FCC, DR7 @ 0x7FC8, TR (selector) @ 0x7FC4,
  // and LDT Base @ 0x7FC0. All four are saved and restored (SMO_DR6/DR7/TR/LDTR
  // below, filled into the real architectural slots per REVIEW2 M-02; the
  // save/restore beats are in core_smm.svh). LDTR is the selector slot only --
  // there is no LDT-base register field in this map, so the incoming LDT
  // descriptor is re-read from the GDT on any later use, as outside SMM.
  localparam logic [15:0] SMO_CR0    = 16'h7FFC;
  localparam logic [15:0] SMO_CR3    = 16'h7FF8;
  localparam logic [15:0] SMO_EFLAGS = 16'h7FF4;
  localparam logic [15:0] SMO_EIP    = 16'h7FF0;
  localparam logic [15:0] SMO_EDI    = 16'h7FEC;
  localparam logic [15:0] SMO_ESI    = 16'h7FE8;
  localparam logic [15:0] SMO_EBP    = 16'h7FE4;
  localparam logic [15:0] SMO_ESP    = 16'h7FE0;
  localparam logic [15:0] SMO_EBX    = 16'h7FDC;
  localparam logic [15:0] SMO_EDX    = 16'h7FD8;
  localparam logic [15:0] SMO_ECX    = 16'h7FD4;
  localparam logic [15:0] SMO_EAX    = 16'h7FD0;
  // REVIEW2 M-02. These four dwords are ARCHITECTURAL slots in the P5 SMRAM state
  // save map (Pentium Dev. Manual Vol.3 Table 20-2), and they sat as an unused HOLE
  // between EAX (0x7FD0) and GS (0x7FBC) -- the map jumped straight over them. So
  // DR6/DR7/TR/LDTR were neither saved nor restored, and the review's "define the
  // intended Pentium layout rather than extending a private image ad hoc" is
  // satisfied by filling the real slots rather than appending to the reserved block.
  localparam logic [15:0] SMO_DR6    = 16'h7FCC;
  localparam logic [15:0] SMO_DR7    = 16'h7FC8;
  localparam logic [15:0] SMO_TR     = 16'h7FC4;   // TR selector
  localparam logic [15:0] SMO_LDTR   = 16'h7FC0;   // LDTR selector
  localparam logic [15:0] SMO_GS     = 16'h7FBC;   // selector (upper 2 bytes rsvd)
  localparam logic [15:0] SMO_FS     = 16'h7FB8;
  localparam logic [15:0] SMO_DS     = 16'h7FB4;
  localparam logic [15:0] SMO_SS     = 16'h7FB0;
  localparam logic [15:0] SMO_CS     = 16'h7FAC;
  localparam logic [15:0] SMO_ES     = 16'h7FA8;
  localparam logic [15:0] SMO_IDTB   = 16'h7F94;   // IDT base
  localparam logic [15:0] SMO_GDTB   = 16'h7F88;   // GDT base
  localparam logic [15:0] SMO_AHALT  = 16'h7F02;   // Auto-HALT restart slot (word, bit0)
  localparam logic [15:0] SMO_REVID  = 16'h7EFC;   // SMM revision identifier (RO)
  localparam logic [15:0] SMO_SMBASE = 16'h7EF8;   // SMBASE relocation slot
  // RTL-internal reserved-area convention for the segment HIDDEN descriptor cache
  // + the GDT/IDT limits (so RSM restores the full hidden state bit-exactly). The
  // SDM reserved window 0x7E00..0x7EF7 is private to the implementation; we lay
  // the 6 segments' {base,limit,attr} + the table limits there.
  localparam logic [15:0] SMO_HID    = 16'h7E00;   // base of the hidden-state block
  // P5 SMM revision identifier value written by SMI# (Pentium Dev. Manual Vol.3
  // §20.1.5.1, Fig 20-3). Lower word = base-SMM-architecture version; upper word =
  // extensions. On the Pentium 510\60/567\66: bit 16 (I/O-Instruction-Restart) = 0
  // (not supported), bit 17 (SMBASE/jump-vector relocation support) = 1 — §20.1.5.3
  // states "Since bit 17 of the SMM Revision Identifier is set in the Pentium
  // processor (510\60, 567\66) ...". So the faithful P5 value is 0x00020000. (The
  // §20.2.2 remark that the 510\60 "revision ID is 0" refers to the upper-word
  // EXTENSION version number being 0 — it becomes 2 on the 735\90+ when the I/O-
  // restart extension is enabled — not to bit 17, the relocation-support flag,
  // which is independent.) qemu-system-i386 agrees: target/i386 SMM_REVISION_ID =
  // 0x00020000 for the 32-bit target (smm_helper.c). The slot is read-only / not
  // restored by RSM, so this is benign for the round-trip but is the correct value.
  localparam logic [31:0] SMM_REV_ID = 32'h0002_0000;
  // Final beat index of the save/restore sequence (0-based). 53 beats: see the
  // S_SMI_SAVE / S_RSM beat map. The bus arm + the restore latch both walk
  // smm_step 0..SMM_LAST in lockstep so save & restore are symmetric.
  //
  // REVIEW2 M-02 added beats 44..51 (DR6, DR7, TR sel, LDTR sel, then the TR/LDTR
  // HIDDEN base/limit/attr in the private block). They are inserted BEFORE the
  // {cs_d,cpl} beat, which MUST stay last: S_RSM commits it straight out of
  // mem_rdata on the final beat rather than latching it, because a latched copy
  // would not become visible until a clock that never comes.
  localparam logic [5:0]  SMM_LAST   = 6'd52;

  // real_mode = system-mode core with CR0.PE==0. In real mode the addressing is
  // linear = (sel<<4)+offset (and the CS default operand size is 16-bit).
  logic        real_mode;
  assign real_mode = sys_mode && !creg0[0];

  // ===========================================================================
  // M7.2 VIRTUAL-8086 MODE (V86 / method-1, VME-OFF). docs/m7-lockstep-spec §M7.2.
  // ===========================================================================
  // v86 = system-mode core with EFLAGS.VM (bit17) set. V86 runs with PE=1 & PG=1
  // (paging/TLB stay live — the M2S.2 walk path is unchanged) but uses real-mode
  // sel<<4 segment bases and a FORCED architectural CPL of 3 (USER). EVERYTHING
  // gated on `v86` is INERT when eflags[17]==0 (so make verify + every prior sys
  // gate stays byte-identical): EFLAGS.VM is 0 across all of user mode and the
  // whole pre-V86 sys corpus, so v86==0 there and all V86 arms below are dead.
  // iopl = EFLAGS.IOPL (bits 13:12). Under v86 with iopl<3 the IOPL-sensitive ops
  // (CLI/STI/PUSHF/POPF/INT n/IRET/IN/OUT) #GP(0) to the CPL0 monitor (method-1);
  // at iopl==3 they execute normally. The pv86 corpus runs at IOPL=0 so all six
  // IOPL-sensitive ops in the V86 task trap.
  logic        v86;
  assign v86 = sys_mode && eflags[17];
  logic [1:0]  iopl;
  assign iopl = eflags[13:12];
  // seg_real = "addressing uses a sel<<4 segment base" — real mode OR V86. The
  // MOV-sreg / far-jump base computation + the decode routing both key on this.
  logic        seg_real;
  assign seg_real = real_mode || v86;
  // Real-mode (16-bit SS) stack-pointer wrap. In real mode the stack pointer is
  // 16 bits, so a push/pop crossing the 0/64k boundary must stay inside the SS
  // segment (a push at SP=0 -> ss_base+0xFFFE, NOT ss_base-2). stk16 masks a stack
  // ADDRESS offset to 16 bits when real_mode; identity in user/PM (real_mode=0) so
  // every user-mode gate stays byte-identical. The matching ESP-register wrap is a
  // post-mask in the gpr-writeback always_comb. (V86 stacks unhandled here — the
  // DOS-Quake path is real mode; CWSDPMI runs the client in 32-bit PM.)
  // REVIEW2 C-07: stack address size follows SS.B, not the code segment's default and
  // not real_mode. This masked ONLY in pure real mode and the comment said V86 was
  // unhandled -- so every V86 16-bit stack and every 16-bit PROTECTED-mode stack used
  // full ESP and never wrapped SP at 64 KiB. Boundary pushes, interrupt frames, calls,
  // returns and task transitions all addressed the wrong memory.
  //
  // Two independent sources, because they need different evidence:
  //   * seg_real (real mode OR V86): SS.B is architecturally 0 in both, with no
  //     descriptor involved. Provable without any new plumbing -- this alone closes
  //     the V86 half that the old comment called out as unhandled.
  //   * ss_b: the SS descriptor's D/B bit for protected mode, captured on the
  //     descriptor load exactly as cs_d captures desc[54] for CS. Resets to 1 (32-bit)
  //     so user mode and pre-load PM behave exactly as before.
  logic ss_b;
  // REVIEW_Aug4 A4-H07: the pre-SMI hidden-state shadows. RSM used to rebuild
  // provenance from the restored CR0.PE (seg_pm_loaded <= rsm_cr0[0]) and left
  // seg_b[]/ss_b wherever the SMM handler left them. Both are wrong: a PE-set-
  // but-not-yet-reloaded window has real-mode hidden caches the restored PE
  // bit would mislabel PM-loaded, and an SMM handler that changes modes or
  // reloads segments must not leak its D/B into the resumed context. Shadowed
  // on SMI entry, restored verbatim on RSM (the architectural map covers
  // selector/base/limit/attr/cs_d -- provenance and D/B are not in it).
  logic        smm_pml_q [NUM_SEG];
  logic        smm_seg_b_q [NUM_SEG];
  logic        smm_ss_b_q;
  // ---- REVIEW_aug2 H-01: ONE definition of "this stack is 16-bit" -------------
  // stk16() masked the stack ADDRESS on (seg_real || !ss_b), but the ESP writeback
  // masked on `real_mode` alone. Three ways for those to disagree, all of them live:
  //   * V86 (seg_real=1, real_mode=0): the address wrapped, ESP did not.
  //   * a 16-bit PROTECTED stack (ss_b=0): the address wrapped, ESP did not.
  //   * so a push at SP=0 accessed SS:FFFE and then committed ESP=FFFFFFFE instead
  //     of leaving ESP[31:16] alone and changing only SP -- and with paging on, the
  //     NEXT access off that ESP lands on an entirely different page.
  // Both sites now read this one signal.
  logic stk_is16;
  assign stk_is16 = seg_real || !ss_b;
  // The POINTER writeback cannot simply reuse stk_is16, and the reason is measured,
  // not theoretical. During a V86 -> CPL0 delivery the frame is pushed on the 32-bit
  // monitor stack (TSS.SS0:ESP0) while v86 -- and therefore seg_real -- is STILL 1,
  // because v86 clears as part of the delivery commit. Masking ESP there truncates
  // the monitor's stack pointer: pv86 diverged at n=705 with
  //     field=esp: expected(A)=0x00087fc8 got(C)=0x00007fc8
  // So the pointer masks on real mode (as before) OR a 16-bit PROTECTED stack, which
  // is exactly the case H-01 identifies, and V86 is left byte-identical.
  // (REVIEW1_Aug2 M-02 closed the V86 gap this comment used to describe.)
  logic stk_ptr16;
  // REVIEW1_Aug2 M-02: ss_b is now authoritative for EVERY stack -- real mode, V86 and
  // protected -- because every SS install sets it: the ordinary segment load, the
  // cross-privilege delivery, the task switch, the outer IRET, and (new here) V86
  // entry, which leaves it 0 because a V86 stack is 16-bit.
  //
  // That removes the reason stk_ptr16 had to exclude V86 by name. The old exclusion
  // existed because masking on `seg_real` truncated the CPL0 MONITOR's ESP during a
  // V86 -> monitor delivery, while v86 was still set. The real distinction was never
  // "are we in V86" but "which stack is this" -- and ss_b answers that directly: it is
  // 0 for the V86 guest stack and 1 for the 32-bit monitor stack the moment S_INT_SS
  // loads it. So steady-state V86 now wraps its POINTER as well as its address, which
  // is the half M-02 says was left open.
  assign stk_ptr16 = real_mode || !ss_b;
  // ...and it applies only to IMPLICIT stack updates. SS.B governs the STACK
  // POINTER arithmetic of push/pop/call/ret/enter/leave/interrupt; it does not make
  // an explicit write to ESP 16-bit. `MOV ESP, imm32` stores all 32 bits whatever
  // SS.B says. Without this qualifier the mask swallowed exactly that: pstk16's
  // `movl $0xDEAD0000,%esp` committed 0x00090000 (the old high half kept, the new
  // one thrown away) and the test diverged at its very first instruction. The old
  // `real_mode`-only condition had the same flaw; it simply never showed, because
  // real-mode code writes SP, not ESP.
  logic esp_arch_dst;
  assign esp_arch_dst = (q_writes_reg && (q_dst_reg == R_ESP))
                     // VEN_SYS_FASTPATH can reach the same explicit register
                     // writes without populating q_writes_reg/q_dst_reg.  Every
                     // GPR write produced by S_PIPE is an explicit instruction
                     // destination (implicit push/pop/call/ret stay on the slow
                     // FSM), so exempt an ESP destination in either issue slot
                     // from the SS.B stack-pointer merge as well.  The outer
                     // gpr_we[R_ESP] guard at the post-process still decides
                     // whether this clock actually writes ESP; these decode
                     // terms therefore do not duplicate the issue predicate or
                     // create a gpr_we -> predicate combinational feedback path.
                     || ((state == S_PIPE)
                         && ((u_d.wreg && (u_d.dst == R_ESP))
                             || (pipe_pair && v_d.wreg && (v_d.dst == R_ESP))))
                     // The inter-privilege IRET's outer-ESP restore is an
                     // architectural ESP write in the same sense: its masking
                     // follows the OUTER stack's B bit (QEMU's SET_ESP(sp,
                     // get_sp_mask(ss_e2))), applied in the S_IRET_SS arm
                     // itself -- the generic post-process must not merge the
                     // old handler ESP's upper half into it.
                     || ((state == S_IRET_SS) && iret_ss_commit);
  function automatic logic [31:0] stk16(input logic [31:0] off);
    stk16 = stk_is16 ? {16'd0, off[15:0]} : off;
  endfunction
  // REVIEW1_Aug3 R2-H05: stk16 with an EXPLICIT B bit. stk16 reads the LIVE
  // ss_b, which during a staged cross-privilege switch (S_INT_SS/S_INT_PROBE/
  // S_CG_PRD) is still the OLD stack's -- the new stack's B sits in int_ss_b.
  function automatic logic [31:0] stk16b(input logic [31:0] off, input logic b);
    stk16b = b ? off : {16'd0, off[15:0]};
  endfunction
  // The frame page-plan lookup: a push whose linear page matches a captured
  // plan entry translates through the captured frame -- no DTLB lookup, no
  // walk, no fault after the staged context commits.
  logic        frm_pg_hit;
  logic [19:0] frm_pg_hitphys;
  always_comb begin
    frm_pg_hit     = 1'b0;
    frm_pg_hitphys = 20'd0;
    if (state == S_INT_PUSH && paging_on)
      for (int i = 0; i < 4; i++)
        if (frm_pg_val[i] && (frm_pg_lin[i] == cur_lin[31:12])) begin
          frm_pg_hit     = 1'b1;
          frm_pg_hitphys = frm_pg_phys[i];
        end
  end
  // eff_cpl = the EFFECTIVE current privilege. In V86 it is architecturally 3
  // (USER) regardless of the CS selector's RPL (the CS selector is a real-mode
  // segment value, e.g. 0x1000, so cs&3 is NOT the CPL). Outside V86 it is cpl_r.
  // Used wherever the privilege level governs a protection/paging decision.
  logic [1:0]  eff_cpl;
  assign eff_cpl = v86 ? 2'd3 : cpl_r;

  // cs_d = the CS descriptor D/B bit (code default operand+address size, 1=32).
  // It governs the EFFECTIVE operand/address size default, NOT real_mode: right
  // after CR0.PE=1 but BEFORE the far jump loads a 32-bit CS, the segment is
  // still 16-bit (CS.D=0), so the bootstrap's `66 ljmp ptr16:32` correctly means
  // a 32-bit offset. Reset/real-mode CS.D=0; a PM far jump to a D=1 code segment
  // sets it. def16 = "16-bit is the default" = system-mode core with CS.D==0.
  logic        cs_d;
  logic        def16;
  assign def16 = sys_mode && !cs_d;

  // ---- task #55: let SIMPLE instructions use the dual-issue fast path in SYSTEM mode ----
  // core_fastpath.svh sent EVERY sys_mode instruction to the slow multi-cycle FSM because the
  // fast-path decoder "assumes 32-bit/flat and is unaware of real-mode 16-bit defaults + segment
  // bases". That is the whole of the measured 13.7-15.9 cyc/instr on hardware (user/flat mode
  // microbenchmarks run the same core at 1.05-1.25).
  //
  // Rather than teach the fast path segmentation in one step, this gate enables it exactly when
  // its existing assumptions are LITERALLY TRUE, so no behaviour changes -- only the path taken:
  //   * !real_mode : no 16-bit real-mode operand/address defaults
  //   * cs_d       : CS is a 32-bit (D/B=1) segment, so the 32-bit default is correct
  //   * flat bases : the fast-path AGU adds NO segment base, so every segment it can address
  //                  through must have base 0. CS/DS/SS/ES cover the fast path's operands
  //                  (FS/GS require an override prefix, which is not `simple`).
  // Most flat clients satisfy this with literal base zero.  CWSDPMI also creates
  // a *relocated* flat client: CS/DS/SS/ES share one nonzero base.  The optional
  // relocation profile below admits the fast decoder's register-only subset;
  // the sole load encoding is independently full-limit/DS-read checked below.
  // It is deliberately not the broad
  // VEN_SYS_FASTPATH_ALL experiment: real mode, 16-bit code, mixed bases, FS/GS
  // overrides, and every memory form remain on the proven slow FSM.
  logic sys_fp_ok;
  // VEN_SYS_FASTPATH_ALL: the two things core_fastpath.svh's bail-out comment says the fast path
  // is "unaware of" turn out to be ALREADY IMPLEMENTED elsewhere:
  //   * 16-bit defaults  -> decode_stages.sv:217-218  eff_opsize/eff_addr = pfx ^ def16
  //   * segment bases    -> core_bus_driver.svh:23    mem_addr = seg_base[SG_DS] + checked DS EA
  //                         (and core.sv:4364 for cur_lin), comment "M2S.1: add the DS base"
  // So the sys_mode bail-out may simply be a STALE conservative guard from M2S.1 that was never
  // relaxed after the support landed. This variant tests that hypothesis empirically.
`ifdef VEN_SYS_FASTPATH_ALL
  assign sys_fp_ok = 1'b1;
`elsif VEN_SYS_FASTPATH_RELOC
  // Every admitted integer fast form is register/immediate/relative-control
  // only (decode.sv); LEA computes an offset and the optional fast MOV load is
  // independently rejected by sys_fp_load_ok below.  CS fetch uses its own
  // fbase path, so a common nonzero client base does not leak into this path.
  // Requiring all four conventional bases equal retains the flat-client
  // invariant and excludes a partial/heterogeneous segment setup.
  assign sys_fp_ok = !real_mode && cs_d
                   && (seg_base[SG_CS] == seg_base[SG_DS])
                   && (seg_base[SG_CS] == seg_base[SG_SS])
                   && (seg_base[SG_CS] == seg_base[SG_ES]);
`else
  assign sys_fp_ok = !real_mode && cs_d
                   && (seg_base[SG_CS] == 32'd0) && (seg_base[SG_DS] == 32'd0)
                   && (seg_base[SG_SS] == 32'd0) && (seg_base[SG_ES] == 32'd0);
`endif

  // The original system fast path correctly keeps all memory forms on the
  // slow FSM: its initial target included 16-bit BIOS/DPMI code, for which the
  // fast decoder's 32-bit register-indirect access is not faithful. A 32-bit
  // flat client is a materially narrower case. Its audited MOV read/write
  // families use DS/SS base{+disp8|+disp32} plus the non-stack SIB no-disp/
  // disp8 forms, and the existing S_PIPE request already flows through cur_lin,
  // the D-TLB/page walker, permissions, and the page-fragment engine. Do not
  // widen this based merely on CS.D/base=0: a finite default-segment limit
  // would still require the slow path's checked access.
`ifdef VEN_DBG_CORE
  // task #102 IRET-trace plusarg gates (inert unless +ven_iretdbg is passed).
  logic        ven_iretdbg_en;
  logic [63:0] ven_iretdbg_lo, ven_iretdbg_hi;
  initial begin
    ven_iretdbg_en = $test$plusargs("ven_iretdbg");
    ven_iretdbg_lo = 64'd0;
    ven_iretdbg_hi = 64'hFFFF_FFFF_FFFF_FFFF;
    void'($value$plusargs("ven_iretdbg_lo=%d", ven_iretdbg_lo));
    void'($value$plusargs("ven_iretdbg_hi=%d", ven_iretdbg_hi));
  end
  // task #102 segment-load #GP/#NP triage (inert unless +ven_segfaultdbg). Used by
  // the S_SEGLD limit/desc fault arms (core_seg_ljmp.svh) to dump the mode context
  // (seg_real/v86/cr0/eflags/gdt-limit) when a PM seg-load faults — distinguishes a
  // spurious PM-walk of a real-mode segment value from a genuine bad PM selector.
  logic        segfaultdbg;
  initial segfaultdbg = $test$plusargs("ven_segfaultdbg");
  // task #102 data-store-under-paging micro-TLB forensic trace (inert unless
  // +ven_tlbdbg is passed). Watches a single linear page (+ven_tlbdbg_lin=) and
  // dumps the translate state of every D access to it: mem_addr/we/cur_lin/
  // fe_dtlb_{v,page,phys,hit,dirty}/paging_on/cur_is_d plus whether xlate_miss
  // (S_WALK divert) and fe_xlate_pend (pend stall) are asserted this clock.
  logic        ven_tlbdbg_en;
  logic [63:0] ven_tlbdbg_lin;
  logic        ven_tlbdbg_cpl3w;            // also trace ALL CPL3 (cs RPL=3) writes
  logic [63:0] ven_tlbdbg_lo, ven_tlbdbg_hi;
  initial begin
    ven_tlbdbg_en  = $test$plusargs("ven_tlbdbg");
    ven_tlbdbg_lin = 64'hFFFF_FFFF;   // a page that never matches by default
    ven_tlbdbg_cpl3w = $test$plusargs("ven_tlbdbg_cpl3w");
    ven_tlbdbg_lo  = 64'd0;
    ven_tlbdbg_hi  = 64'hFFFF_FFFF_FFFF_FFFF;
    void'($value$plusargs("ven_tlbdbg_lin=%h", ven_tlbdbg_lin));
    void'($value$plusargs("ven_tlbdbg_lo=%d", ven_tlbdbg_lo));
    void'($value$plusargs("ven_tlbdbg_hi=%d", ven_tlbdbg_hi));
  end
`endif

  // SEG_KEYS index constants (cs ss ds es fs gs) for the seg_* arrays.
  localparam int SG_CS = 0, SG_SS = 1, SG_DS = 2, SG_ES = 3, SG_FS = 4, SG_GS = 5;

  // ===========================================================================
  // M2S.2 PAGING MMU + split I/D TLBs (docs/m2s2-paging-spec.md).
  // ===========================================================================
  // paging_on = system-mode core with CR0.PG (creg0[31]) set AND CR0.PE set
  // (paging only takes effect in protected mode). When 0, linear == physical
  // (real mode, flat PM-before-PG, and ALL of user mode) so the M2S.1 path and
  // the user-mode path are bit-identical. CR4.PSE (creg4[4]) enables 4 MiB pages
  // when a PDE has PS (bit 7) set.
  logic paging_on;
  assign paging_on = sys_mode && creg0[31] && creg0[0];
  assign mem_lin = cur_lin_nat;   // task #51: linear mirror of mem_addr (pre-mem_xlate).
  // R2-C03: the mirror reports the NATURAL (per-state) linear address, not the
  // fragment engine's redirected page-2 address -- the SMC snoop's invalidation
  // identity is the architectural access's line.
  // REVIEW2 C-03: the architectural bus address BEFORE mem_xlate (driven in
  // core_bus_driver.svh). Diagnostic only -- nothing in the datapath reads it.
  logic [31:0] mem_addr_pre;
  // ===========================================================================
  // REVIEW2 C-02: PAGE-CROSSING LOAD SPLIT.
  // ===========================================================================
  // A load whose bytes span a 4 KiB boundary used to issue ONE request, translated
  // with the FIRST page's mapping, and take the high bytes from the physically
  // adjacent frame -- which belongs to a different mapping whenever the two virtual
  // pages are not contiguous in physical memory. verif/sys/tests/pxpage demonstrates
  // it: expected 0xbbbbaaaa, got 0xccccaaaa.
  //
  // The access is now split into TWO translated beats. Beat 1 uses the natural
  // address (its LOW bytes are the first page's, which is exactly what we keep);
  // beat 2 re-issues at the SECOND page's base so it gets its own TLB lookup / walk
  // / permission check, and its low bytes supply the high half.
  //
  // xp_first = how many of the access's bytes live in the first page.
  logic [31:0] ld_val;
  logic [31:0] ld2_val;   // REVIEW1_Aug2 C-03: the merged S_LOAD2 value         // REVIEW_aug2 C-03: the merged load value (see core_load.svh)
  logic        xp_pend;        // beat 2 is the one in flight
  logic [31:0] xp_lo;          // beat 1's data (low bytes are the first page's)
  logic [2:0]  xp_first;       // bytes taken from the first page (1..3)
  logic [2:0]  xp_w;           // the access width this split was computed for
  // ---- STORE side (REVIEW2 C-02, second half) --------------------------------
  // A crossing STORE cannot simply be two write beats: writing the FIRST page before
  // the SECOND page's translation and permissions are known good leaves memory
  // PARTIALLY MODIFIED if the second page faults -- exactly what the review forbids
  // ("commit stores only after every piece has passed").
  //
  // So the sequence is PROBE-2 -> WRITE-1 -> WRITE-2:
  //   phase 0  probe the SECOND page: a translated access with cur_is_w=1 (so the
  //            WRITE permission is checked) but mem_we=0, so NOTHING is written.
  //   phase 1  write the FIRST page's bytes. If THIS faults, the second page has only
  //            been probed, so again nothing is left half-written.
  //   phase 2  write the SECOND page's bytes. It cannot fault: phase 0 just proved it
  //            translatable and writable, within the same instruction.
  // That ordering needs no rollback, which is why it was chosen over write-then-undo.
  logic [1:0]  xs_ph;          // 0=probe page2, 1=write page1, 2=write page2
  logic        xs_act;         // this store is a crossing one
  logic [2:0]  xs_first;       // bytes of the store that live in the first page

  // ===========================================================================
  // REVIEW1_Aug3 R2-C03: THE GENERIC FRAGMENT ENGINE ("fx").
  //
  // One byte-extent request engine below ALL FSM producers, replacing the
  // per-state page-crossing split the review forbade extending case-by-case.
  // Any translatable state whose current beat straddles a page boundary gets a
  // probe-then-execute fragment sequence instead of driving the tail bytes
  // through the physically adjacent frame:
  //
  //   READ  beat: frag1 at the natural linear (page 1's bytes) -> frag2 at the
  //         page-2 base (own TLB lookup / walk / permission check) -> the FSM
  //         sees ONE ack with the merged dword.
  //   WRITE beat: probe page 2 (translated, WRITE-permission checked, NO bus
  //         transaction -- xs phase 0 generalized) -> write page-1 fragment ->
  //         write page-2 fragment. No byte is committed before both pages are
  //         proven, so a fault never leaves a partial write.
  //
  // The engine interposes INSIDE the core: the bus driver's outputs are renamed
  // bd_* and the engine produces the mem_* ports; the FSM's mem_ack/mem_rdata
  // are gated/merged versions of the bus ack/data. S_LOAD/S_LOAD2/S_STORE keep
  // their proven xp_pend/xs machinery (excluded below) — the engine covers the
  // producer states the review named (S_LGDT, S_INT_GATE, S_INT_PUSH, S_FSTORE,
  // S_FENV_ST, S_TSW_SAVE) and every other translatable slow state generically.
  //
  // fx_ph encoding: reads -- 0: frag1 out, 1: frag2 out.
  //                 writes -- 0: probe page 2, 1: write frag A, 2: write frag B.
  logic        bd_req, bd_we;
  logic [31:0] bd_addr, bd_wdata;
  logic [3:0]  bd_wstrb;
  logic        fx_act;         // a fragment sequence is in flight
  logic        fx_wr;          // 1 = write sequence, 0 = read sequence
  logic [1:0]  fx_ph;
  logic [31:0] fx_lo;          // read frag1 data (its low fx_first bytes are valid)
  logic [2:0]  fx_first;       // bytes of the beat that live in page 1 (1..3)
  logic [31:0] fx_wdata_q;     // write beat's original data/strobes (lane-0 form)
  logic [3:0]  fx_wstrb_q;
  // One-cycle abort request, written ONLY by the main FSM block (pulsed by
  // start_fault, cleared by its per-cycle default) and consumed ONLY here --
  // the fragment registers keep exactly one procedural owner each, and the
  // abort still takes effect at the fault-taking edge (the shaping kill on
  // the output stage covers the request cycle, so no fragment beat escapes
  // while the state clears).
  logic        fx_abort_q;

  // the states with their own proven split machinery — the engine must NOT
  // engage for them (their arms drive the xp_pend/xs phases themselves).
  logic fx_state_ok;
  assign fx_state_ok = fe_translatable
                    && (state != S_LOAD) && (state != S_LOAD2) && (state != S_STORE)
                    && (state != S_WALK) && (state != S_SMI_SAVE) && (state != S_RSM);

  // crossing detection: reads measure by cur_size, writes by the driven strobes
  // (lane-0 convention: the byte at cur_lin is strobe lane 0).
  logic [2:0]  fx_wr_hi;       // highest set strobe lane of the write beat
  always_comb begin
    fx_wr_hi = 3'd0;
    for (int b = 0; b < 4; b++) if (bd_wstrb[b]) fx_wr_hi = 3'(b);
  end
  logic [12:0] fx_rd_end;
  assign fx_rd_end = {1'b0, cur_lin_nat[11:0]} + {9'd0, cur_size};
  logic        fx_cross;
  assign fx_cross = bd_we
                 ? ({1'b0, cur_lin_nat[11:0]} + {10'd0, fx_wr_hi} > 13'hFFF)
                 : (fx_rd_end > 13'h1000);
  logic        fx_start;
  assign fx_start = fx_state_ok && mem_req_pre_sq && paging_on
                 && (!fx_act || fx_abort_q) && fx_cross
                 && !xlate_miss && !perm_fault && !seg_access_fault && !fe_xlate_pend;

  // engine phase controls (combinational `_e` forms live at the output stage,
  // after the bus-driver include, so the first clock of a crossing beat is
  // already shaped -- REVIEW_aug2 C-01's xs_eff lesson).
  // the probe must not set the TLB Dirty bit (the write may still fault on page 1);
  // consumed beside xs_probing at the walk dispatch.
  logic fx_probing;

  logic [31:0] fx_merged;
  assign fx_merged = (fx_lo & ~(32'hFFFF_FFFF << ({2'd0, fx_first} << 3)))
                   | (bus_rdata << ({2'd0, fx_first} << 3));

  // the engine sequencer. The FSM arms are untouched: they see exactly one ack
  // per beat (the last fragment's) with merged read data.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fx_act <= 1'b0; fx_wr <= 1'b0; fx_ph <= 2'd0; fx_lo <= 32'd0;
      fx_first <= 3'd0; fx_wdata_q <= 32'd0; fx_wstrb_q <= 4'd0;
    end else if (fx_abort_q && !fx_start) begin
      // FAULT ABORT (start_fault pulses fx_abort_q in the main FSM block):
      // highest priority after reset. Completes as soon as no new crossing
      // start is pending this clock; the output-stage kill (fx_abort_q terms
      // on every fx_act-based shaping signal) covers the request cycle, so no
      // fragment shaping hijacks the fault delivery's first beat.
      fx_act <= 1'b0; fx_ph <= 2'd0;
    end else if (state == S_WALK) begin
      // FROZEN (pxc04/S_LGDT, VCD-proven by the xc04 conversion): a frag2 that
      // misses the D-TLB diverts the FSM to S_WALK WITH THE ENGINE STILL ARMED.
      // Unfrozen, the walk's own PDE/PTE acks advanced the frag phases (the
      // default case disengaged on the walk's first ack) and fx_merge_e fed the
      // walk's PDE latch the half-merged producer read -- measured
      // walk_pde = (true PDE << 16) | frag1[15:0], so the PTE read issued at a
      // garbage physical and the restarted access re-faulted forever. The walk
      // is a DETOUR of the producer's beat: hold every engine register here
      // (the output shaping is separately blanked by fx_walk_hold below), and
      // the frag sequence resumes when the walk returns to the producer state.
    end else if ((!fx_act || fx_abort_q) && fx_start) begin
      // (fx_abort_q && fx_start): a delivery beat that itself crosses replaces
      // the aborted sequence outright -- an aborted probe wrote nothing, and
      // the new beat is shaped by the fx_start terms this same clock.
      fx_act     <= 1'b1;
      fx_wr      <= bd_we;
      fx_first   <= 3'(13'h1000 - {1'b0, cur_lin_nat[11:0]});
      fx_wdata_q <= bd_wdata;
      fx_wstrb_q <= bd_wstrb;
      // A write starts at the PROBE (fx_probe_e suppresses the port request
      // combinationally on this same clock, so nothing escapes unmasked).
      // A read's frag1 is the natural request going out this clock; if the
      // memmodel acks combinationally (same clock), capture it NOW and move
      // straight to frag2.
      if (!bd_we && bus_ack) begin
        fx_lo <= bus_rdata; fx_ph <= 2'd1;
      end else
        fx_ph <= 2'd0;
    end else if (!fx_act) begin
      // idle (no start this clock)
    end else begin
      unique case ({fx_wr, fx_ph})
        // write probe: complete when page 2 resolves clean (a miss diverts to
        // S_WALK via xlate_miss and returns here; a fault is delivered by the
        // FSM's generic arms and start_fault resets the engine).
        // In VEN_FE_PIPE, xlate_miss is deliberately suppressed while the
        // registered page-2 translation is still settling.  Do not mistake
        // that suppression for a successful write probe and advance to frag A.
        {1'b1, 2'd0}: if (!fe_xlate_pend && !xlate_miss && !perm_fault && !seg_access_fault)
                            fx_ph <= 2'd1;
        {1'b1, 2'd1}: if (bus_ack) fx_ph <= 2'd2;   // frag A written
        {1'b1, 2'd2}: if (bus_ack) begin fx_act <= 1'b0; fx_ph <= 2'd0; end  // frag B
        // read: frag1 ack -> frag2; frag2 ack -> present merged, done.
        {1'b0, 2'd0}: if (bus_ack) begin fx_lo <= bus_rdata; fx_ph <= 2'd1; end
        default:      if (bus_ack) begin fx_act <= 1'b0; fx_ph <= 2'd0; end
      endcase
    end
  end

  // Architectural crossing test for the CURRENT S_LOAD access, off the PRE-translate
  // linear. Uses the operand width, not the bus's 4-byte fetch: a 1-byte load at
  // offset 0xFFF does not architecturally cross.
  // REVIEW1_Aug2 C-03: the byte EXTENT of the beat the current state is issuing.
  // cur_lin gives the START of the access; this gives its LENGTH, and the (start,
  // length) pair is exactly what a canonical byte-addressed request layer carries.
  // Declared beside cur_lin's own machinery so the two cannot drift apart.
  logic [3:0]  cur_size;
  // Canonical width of the current S_LOAD/S_LOAD2 beat.  q_w is the decoded
  // offset/operand width, not necessarily the memory width: an m16:16 far
  // pointer is four bytes in its first (and only) load, while the selector beat
  // of an m16:32 pointer is only two bytes.  One value drives translation
  // extent, page splitting, segment checks, and the L1 narrow-read strobes.
  logic [2:0]  load_beat_w;
  always_comb begin
    load_beat_w = q_w;
    if ((state == S_LOAD) && (q_w == 3'd2)
        && (q_jmpf_mem || q_callf_mem || (q_seg_load && !q_seg_load_lo)))
      load_beat_w = 3'd4;
    else if ((state == S_LOAD2)
             && (q_jmpf_mem || q_callf_mem || (q_seg_load && !q_seg_load_lo)))
      load_beat_w = 3'd2;
  end
  // REVIEW2_aug2 H-05 (sixth bullet): the segment check's extent, which is NOT always
  // cur_size. cur_size is the CURRENT BEAT's byte count, which is right for the address
  // mirror and the page-crossing layer but wrong for a limit check on a MULTI-BEAT
  // access: beat 0 passes, beats commit, and a later beat discovers the violation with
  // the earlier ones already in memory. For the x87 memory states the WHOLE object size
  // is known up front (q_f_mbytes = 2/4/8/10), so the check covers the entire object at
  // the FIRST beat and is suppressed afterwards -- a violation anywhere in the operand
  // now faults before ANY of it is written.
  // seg_ext_ovr is an OVERRIDE, not an independent value. The first version of this
  // defaulted seg_ext_size to a fixed 4, which silently WIDENED the check on every
  // state that narrows cur_size to 1 or 2 bytes -- measured at 96 such beats across the
  // corpus, all fail-CLOSED (a check covering more bytes than the access can invent a
  // violation). That is precisely the false-positive class this finding's delivery was
  // reverted for twice. seg_ext_size now follows cur_size unless a state explicitly
  // says the object is bigger than this beat.
  logic [7:0]  seg_ext_ovr;    // whole-object extent, when a state knows it
  logic        seg_ext_ovr_v;  // 1 = use seg_ext_ovr instead of cur_size
  logic        seg_ext_skip;   // this beat is inside an already-checked extent
  wire  [7:0]  seg_ext_size;   // extent the LIMIT check uses (resolved below)

  logic        xp_cross;
  logic [12:0] xp_end;
  assign xp_end   = {1'b0, cur_lin[11:0]} + {10'd0, load_beat_w};
  // REVIEW1_Aug2 C-03: S_LOAD2 splits too. The crossing predicate was bound to a
  // single FSM state, so every other multi-byte access translated only its STARTING
  // page: bytes in page 2 were read from the frame page 1 happened to select. S_LOAD2
  // is the reachable one -- CMPS's second operand, BOUND's and CMPXCHG8B's high word,
  // and both far-pointer reads all land there -- and it takes the SAME engine as
  // S_LOAD, because it is the same shape: one access, re-issued at the second page.
  // The bus driver and the cur_lin mirror carry the identical `xp_pend` redirect for
  // both states (CHECK 5 asserts they agree), and the S_LOAD2 arm latches and merges
  // exactly as S_LOAD does.
  assign xp_cross = ((state==S_LOAD) || (state==S_LOAD2))
                 && !xp_pend && (xp_end > 13'h1000);
  // Crossing STORE detect. st_strb is the byte-enable the store drives, so its
  // population count is the true architectural width (POP r/m16, string stores and
  // the 8F form all differ from q_w).
  logic [2:0] xs_w;
  assign xs_w = (q_kind==K_STR) ? q_w
              : ({2'd0, st_strb[0]} + {2'd0, st_strb[1]}
               + {2'd0, st_strb[2]} + {2'd0, st_strb[3]});
  // REVIEW_aug2 C-01: the crossing test MUST key off the NATURAL store address, not
  // cur_lin. cur_lin carries the phase redirect (page+1 on phases 0/2), so testing it
  // would be a combinational loop AND would mis-measure the offset once redirected.
  logic [31:0] st_lin_nat;
  assign st_lin_nat = (q_kind==K_STR) ? dbase_edi+str_store_addr : stbase+st_addr;
  logic [12:0] xs_end;
  assign xs_end = {1'b0, st_lin_nat[11:0]} + {10'd0, xs_w};
  logic xs_cross_now;
  assign xs_cross_now = (state==S_STORE) && (xs_end > 13'h1000);
  // EFFECTIVE phase, used by BOTH cur_lin and the bus driver.
  //
  // THE BUG THIS FIXES (REVIEW_aug2 C-01): the phase logic was gated on the REGISTERED
  // xs_act, which is 0 on the clock a crossing store first enters S_STORE. So the very
  // first request went out as the ORIGINAL, UNSPLIT, full-width write translated only
  // through page 1 -- committing bytes into the physically adjacent frame -- and only
  // its mem_ack armed the "probe". There was never a probe; the sequence was
  // unsplit-write / write-page-1 / write-page-2. Measured: pxpage's foreign frame at
  // phys 0x801000 came back 0x0ff11234 instead of 0x0ff1ce00.
  //
  // Deriving the phase COMBINATIONALLY makes the first request the probe, which is what
  // "commit stores only after every piece has passed" actually requires.
  logic       xs_eff_act;
  logic [1:0] xs_eff_ph;
  assign xs_eff_act = xs_act || xs_cross_now;
  assign xs_eff_ph  = xs_act ? xs_ph : 2'd0;   // not yet armed => phase 0 = PROBE
`ifndef SYNTHESIS
  // REVIEW2 C-02 exposure measurement (see core_bus_driver.svh). Sim-only.
  logic       c02_xpage_hits;
  logic [2:0] c02_bytes;
  int unsigned c02_count;
  // Access width for the crossing test: writes carry a strobe, reads are the
  // operand width the state requested. 4 is the conservative default (the widest
  // single beat this bus issues), so the count never UNDER-reports.
  // REVIEW_aug2 C-01 follow-up: this read the DRIVEN mem_we/mem_wstrb, which now depend
  // on the store phase, so Verilator reported circular combinational logic. Use the
  // pre-driver operand width instead -- same measurement, no feedback path.
  assign c02_bytes = cur_is_w ? ((st_strb==4'b0001) ? 3'd1 :
                                 (st_strb==4'b0011) ? 3'd2 : 3'd4)
                              : 3'd4;
  always_ff @(posedge clk) if (rst_n && c02_xpage_hits) c02_count <= c02_count + 1;
  final if (c02_count != 0)
    $display("[xpage] page-crossing translated accesses (paging on): %0d -- each handled by the per-page split (probe/merge machinery)", c02_count);
`endif
  logic cr4_pse;
  assign cr4_pse = creg4[4];

  // Split I/D TLBs (correctness model, NOT cycle timing — spec §3). Each is a
  // small direct-mapped array keyed on the linear page number. An entry caches
  // the translated physical frame + the effective P/RW/US permission of the page
  // (AND of PDE & PTE) + a 4 MiB-page flag (so the offset width is right) +
  // whether the page's A/D bits have already been set in memory (so a repeat use
  // does not re-write them, matching qemu-system which sets A/D once per state).
  localparam int TLB_ENTRIES = 16;          // direct-mapped; index = lin[15:12]
  // The TLB ARRAYS + lookup + fill-commit + flush now live in the parameterized
  // `tlb` module (rtl/mem/tlb.sv), instantiated TWICE below: u_itlb (IS_D=0,
  // fetch) and u_dtlb (IS_D=1, data). The whole S_WALK page-walk micro-sequence
  // STAYS in this spine and drives the fill ports. These nets carry the two
  // instances' combinational lookup outputs (read by xlate_miss / perm_fault /
  // mem_xlate) and the spine-driven fill/flush inputs. See the instantiation +
  // fill driver near the bus-translate block below.
  // The lookup is at cur_lin; mem_xlate reuses it because cur_lin == the bus
  // mem_addr in every translatable state (proven verbatim across the FSM arms).
  // I-TLB (instruction fetches) lookup outputs.
  logic        itlb_lk_hit;   logic [31:0] itlb_lk_phys;
  logic [2:0]  itlb_lk_perm;  logic        itlb_lk_dirty;
  // D-TLB (data accesses) lookup outputs — Dirty tracked so a write marks D.
  logic        dtlb_lk_hit;   logic [31:0] dtlb_lk_phys;
  logic [2:0]  dtlb_lk_perm;  logic        dtlb_lk_dirty;

  // +VEN_FE_PIPE: page-keyed micro-TLB register. Translation is per-4 KiB-page, so
  // we register the {i,d}tlb lookup keyed on the page (cur_lin[31:12]); xlate_miss /
  // mem_xlate then read the REGISTERED result, lifting the combinational hit_of
  // carry-chain off the issue path (the ~41 MHz full-SoC eip-cone binder). A page
  // crossing sets fe_xlate_pend for 1 clock (the only added latency) while the
  // register samples the new page. fe_xlate_pend is tied 0 in the default build, so
  // every `... && !fe_xlate_pend` gate folds away -> default is byte/cycle-identical.
  // Fmax-only demonstrator contract (cycle bands not claimed); functionally arch-exact.
  logic fe_xlate_pend;
  // Module-scope mirror of the `translatable` predicate computed in the xlate_miss
  // always_comb: 1 iff THIS state issues a genuine paged memory access (the access
  // whose linear == cur_lin). Hoisted to module scope so the FE_PIPE micro-TLB
  // re-registration (a separate always_ff) can gate on it — a NON-translatable
  // state (e.g. a task-switch TSS save S_TSW_SAVE, S_LTR, or an idle default) drives
  // cur_lin=0 with cur_is_d=1, and must NOT pollute the page-keyed micro-TLB.
  logic fe_translatable;
`ifdef VEN_FE_PIPE
  logic [19:0] fe_itlb_page, fe_itlb_phys;  logic fe_itlb_hit,  fe_itlb_v;
  logic [19:0] fe_dtlb_page, fe_dtlb_phys;  logic fe_dtlb_hit,  fe_dtlb_dirty, fe_dtlb_v;
`endif

  // Page-walk micro-sequence registers. The walk is a small FSM living inside
  // S_WALK: it reads the PDE, then the PTE (4 KiB) — writing A/D bits back to the
  // page tables as memory writes — fills the proper TLB, then returns to the
  // diverted memory state (walk_ret_state, declared with the FSM enum below).
  // walk_for_d selects the D-TLB (else I).
  logic [31:0] walk_lin;           // the linear address being translated
  logic        walk_for_d;         // 1 = data access (D-TLB), 0 = fetch (I-TLB)
  logic        walk_is_write;      // H-02: the resumed access is architecturally a
                                   // WRITE -> the #PF error code's W/R bit
  logic [2:0]  walk_step;          // 0=read PDE,1=write PDE A,2=read PTE,3=write PTE A/D
  logic [31:0] walk_pde;           // latched PDE
  logic [31:0] walk_pte;           // latched PTE
  logic [31:0] walk_pde_addr;      // physical addr of the PDE
  logic [31:0] walk_pte_addr;      // physical addr of the PTE
  logic        walk_pf;            // a page-fault DECISION was reached (delivery=M2S.3)
  // M2S.2 #PF DECISION outputs (delivery is M2S.3): the faulting linear address is
  // latched into CR2; the error code (P/RW/US) is computed. For the clean gate
  // tests this is never asserted.
  logic [2:0]  pf_errcode;         // {US, RW, P} of the faulting access

  // ===========================================================================
  // x87 FPU architectural state (M3)
  // ===========================================================================
  // R2: the x87 architectural STATE FILE (the 8x80-bit physical stack fpr[8],
  // TOP, control/status/tag words, the synchronous reset, and the ftop-relative
  // st(i) read addressing) is now OWNED by the fpu_top module (rtl/fpu/fpu_top.sv),
  // instantiated as u_fpu_state below. The spine keeps the DATAPATH (the
  // fpu_x87_pkg value computations), the M5 FP scoreboard, the S_FEXEC/S_FSTORE
  // FSM, and FNSTSW->gpr_o[EAX]; it computes each value and drives it onto the
  // module's write ports (the fp_we_* combinational driver near the u_fpu_state
  // instance), and reads the registered state back through these combinational
  // wires (st(i) = fp_st[i], ftop/fctrl/fstat/fptag = the module's *_o outputs).
  // st(i) = fpr[(ftop+i)&7]. Push decrements TOP then writes; pop increments TOP
  // (leaving the stale value, so the trace's "empty" st-slots keep their last
  // contents — matches QEMU). fstat keeps the TOP field (bits[13:11]) ZERO
  // internally (overlaid from ftop on read, mirrors helper_fnstsw); fptag bit i =
  // tag for fpr[i] (1=empty) — drives FXAM, NOT reported in the trace.
  logic [79:0] fp_st [8];        // fp_st[i] = ST(i) = fpr[ftop+i] (module read port)
  logic [79:0] fp_st0_phys;      // = fpr[ftop] (physical ST0, for fstore_val)
  logic [2:0]  ftop;             // = u_fpu_state.ftop_o
  logic [15:0] fctrl;            // = u_fpu_state.fctrl_o (control word; reset 0x037f)
  logic [15:0] fstat;            // = u_fpu_state.fstat_o (RAW; TOP not overlaid)
  logic [7:0]  fptag;            // = u_fpu_state.fptag_o (bit i = tag for fpr[i])
  logic [31:0] fip, fdp;         // = u_fpu_state.fip_o/fdp_o (M11 env-image only)
  logic [15:0] fcs, fds;         // = u_fpu_state.fcs_o/fds_o
  logic [639:0] fpr_flat;        // = u_fpu_state.fpr_flat_o (physical fpr[7..0])
  logic        x87_touched_r;   // retired insn touched the FPU (drives DPI call)

  // ===========================================================================
  // M6 errata-enable bit positions (docs/m6-errata-spec.md). Each gates exactly
  // one documented defect; all default OFF (errata_en==0 == clean M0-M5 core).
  // ===========================================================================
  localparam int ERR_FDIV  = 0;   // Erratum 23  : FDIV/SRT divide flaw
  localparam int ERR_FIST  = 1;   // Erratum 20  : FIST/FISTP overflow undetected
  localparam int ERR_F00F  = 2;   // Erratum 81  : LOCK CMPXCHG8B reg-dst hang
  localparam int ERR_MOFFS = 3;   // Erratum 59  : MOV moffs A2/A3 non-pairing
  // M6B (242480-041 Erratum 79): "Erroneous Debug Exception on POPF/IRET
  // Instructions with a GP Fault". In virtual-8086 mode at IOPL<3, a POPF or IRET
  // is IOPL-sensitive and #GP(0)-traps to the monitor WITHOUT accessing the stack.
  // If a DATA breakpoint is armed on the SS:ESP linear address, the breakpoint
  // must NOT trigger (the stack was never touched) — but on the affected P5
  // steppings an ERRONEOUS #DB is delivered IN ADDITION to the #GP, with the
  // saved CS:EIP pointing at the FIRST instruction of the #GP handler (the
  // documented Implication). Default OFF -> only the #GP is delivered (clean).
  localparam int ERR_DBGP  = 4;   // Erratum 79  : erroneous #DB on V86 POPF/IRET #GP

  // ===========================================================================
  // FSM
  // ===========================================================================
  // state_e (the pipeline FSM enum) is declared at compilation-unit ($unit)
  // scope at the TOP of this file (promoted from an in-`core` typedef, R3) so the
  // extracted core/fpu_writeback.sv driver can take it as a port type. The
  // `state`/`walk_ret_state` declarations below use that one $unit type.
  state_e state;
  // M2S.2 page-walk return state (declared here so it can use state_e).
  state_e walk_ret_state;          // state to resume after a page walk

  // M6 Erratum 81: latched once the core enters the F00F hang (never clears
  // until reset). Drives the cpu_hung output and keeps the FSM parked.
  logic hung_r;
  assign cpu_hung = hung_r;

`ifdef VEN_DBG_CORE
  // ---- VEN_DBG_CORE observability taps (pure combinational observers) -------
  // No logic added to any datapath; these never feed back into the FSM.
  assign dbg_state    = 6'(state);
  assign dbg_int_vec  = int_vec;
  assign dbg_fault_pc = int_src_pc;
  assign dbg_cr0      = creg0;
  assign dbg_fctrl    = fctrl;             // live x87 control word (PC = [9:8])
  assign dbg_fxop     = 6'(q_fxop);        // x87 sub-op currently in flight
  assign dbg_ibuf     = {ibuf[7],ibuf[6],ibuf[5],ibuf[4],ibuf[3],ibuf[2],ibuf[1],ibuf[0]};
  assign dbg_seg      = {31'd0, cs_d, gdt_base};   // [31:0]=GDTR base, [32]=CS.D (PM-wedge descriptor probe)

  // Halted architectural scan.  FPR words name the *physical* fpu_top slots;
  // TOP (selector 18) converts them to logical ST(i) without introducing an
  // 8x80-bit debug bus.  Word order is little-endian: lo[31:0], mid[63:32],
  // hi[79:64] in bits [15:0].  This is an observer only and has no path back
  // into decode, issue, cache, or the x87 state file.
  always_comb begin
    unique case (dbg_arch_sel)
      7'd0:  dbg_arch_data = gpr_o[R_EAX];
      7'd1:  dbg_arch_data = gpr_o[R_ECX];
      7'd2:  dbg_arch_data = gpr_o[R_EDX];
      7'd3:  dbg_arch_data = gpr_o[R_EBX];
      7'd4:  dbg_arch_data = gpr_o[R_ESP];
      7'd5:  dbg_arch_data = gpr_o[R_EBP];
      7'd6:  dbg_arch_data = gpr_o[R_ESI];
      7'd7:  dbg_arch_data = gpr_o[R_EDI];
      7'd8:  dbg_arch_data = eip;
      7'd9:  dbg_arch_data = eflags;
      7'd10: dbg_arch_data = {seg_sel[SG_SS], seg_sel[SG_CS]};
      7'd11: dbg_arch_data = {seg_sel[SG_ES], seg_sel[SG_DS]};
      7'd12: dbg_arch_data = {seg_sel[SG_GS], seg_sel[SG_FS]};
      7'd13: dbg_arch_data = creg0;
      7'd14: dbg_arch_data = creg2;
      7'd15: dbg_arch_data = creg3;
      7'd16: dbg_arch_data = creg4;
      7'd17: dbg_arch_data = {fstat, fctrl};
      7'd18: dbg_arch_data = {21'd0, ftop, fptag};
      7'd19: dbg_arch_data = fpr_flat[  0 +: 32];
      7'd20: dbg_arch_data = fpr_flat[ 32 +: 32];
      7'd21: dbg_arch_data = {16'd0, fpr_flat[ 64 +: 16]};
      7'd22: dbg_arch_data = fpr_flat[ 80 +: 32];
      7'd23: dbg_arch_data = fpr_flat[112 +: 32];
      7'd24: dbg_arch_data = {16'd0, fpr_flat[144 +: 16]};
      7'd25: dbg_arch_data = fpr_flat[160 +: 32];
      7'd26: dbg_arch_data = fpr_flat[192 +: 32];
      7'd27: dbg_arch_data = {16'd0, fpr_flat[224 +: 16]};
      7'd28: dbg_arch_data = fpr_flat[240 +: 32];
      7'd29: dbg_arch_data = fpr_flat[272 +: 32];
      7'd30: dbg_arch_data = {16'd0, fpr_flat[304 +: 16]};
      7'd31: dbg_arch_data = fpr_flat[320 +: 32];
      7'd32: dbg_arch_data = fpr_flat[352 +: 32];
      7'd33: dbg_arch_data = {16'd0, fpr_flat[384 +: 16]};
      7'd34: dbg_arch_data = fpr_flat[400 +: 32];
      7'd35: dbg_arch_data = fpr_flat[432 +: 32];
      7'd36: dbg_arch_data = {16'd0, fpr_flat[464 +: 16]};
      7'd37: dbg_arch_data = fpr_flat[480 +: 32];
      7'd38: dbg_arch_data = fpr_flat[512 +: 32];
      7'd39: dbg_arch_data = {16'd0, fpr_flat[544 +: 16]};
      7'd40: dbg_arch_data = fpr_flat[560 +: 32];
      7'd41: dbg_arch_data = fpr_flat[592 +: 32];
      7'd42: dbg_arch_data = {16'd0, fpr_flat[624 +: 16]};
      7'd43: dbg_arch_data = fip;
      7'd44: dbg_arch_data = fdp;
      7'd45: dbg_arch_data = {fds, fcs};
      // Hidden segment cache.  The visible selectors above are insufficient
      // to diagnose a protected-mode fault: the base/limit/attributes, not
      // merely CS/DS values, determine the access.  Keep these at the final
      // selector values so the established x87 map remains stable.
      7'd46: dbg_arch_data = seg_base[SG_CS];
      7'd47: dbg_arch_data = seg_base[SG_SS];
      7'd48: dbg_arch_data = seg_base[SG_DS];
      7'd49: dbg_arch_data = seg_base[SG_ES];
      7'd50: dbg_arch_data = seg_base[SG_FS];
      7'd51: dbg_arch_data = seg_base[SG_GS];
      7'd52: dbg_arch_data = seg_limit[SG_CS];
      7'd53: dbg_arch_data = seg_limit[SG_SS];
      7'd54: dbg_arch_data = seg_limit[SG_DS];
      7'd55: dbg_arch_data = seg_limit[SG_ES];
      7'd56: dbg_arch_data = seg_limit[SG_FS];
      7'd57: dbg_arch_data = seg_limit[SG_GS];
      7'd58: dbg_arch_data = {seg_attr[SG_ES], seg_attr[SG_DS],
                               seg_attr[SG_SS], seg_attr[SG_CS]};
      7'd59: dbg_arch_data = {10'd0, seg_b[SG_GS], seg_b[SG_FS],
                               seg_b[SG_ES], seg_b[SG_DS], seg_b[SG_SS], seg_b[SG_CS],
                               seg_attr[SG_GS], seg_attr[SG_FS]};
      7'd60: dbg_arch_data = gdt_base;
      7'd61: dbg_arch_data = idt_base;
      7'd62: dbg_arch_data = {idt_limit, gdt_limit};
      7'd63: dbg_arch_data = {tr_sel, ldt_sel};
      // Debug registers and the hidden task/LDT descriptor caches are not
      // implied by visible selectors.  Keep them in the expanded scan bank
      // rather than exporting another wide debug bundle through the FPGA.
      7'd64: dbg_arch_data = dr0;
      7'd65: dbg_arch_data = dr1;
      7'd66: dbg_arch_data = dr2;
      7'd67: dbg_arch_data = dr3;
      7'd68: dbg_arch_data = dr6;
      7'd69: dbg_arch_data = dr7;
      7'd70: dbg_arch_data = tr_base;
      7'd71: dbg_arch_data = tr_limit;
      7'd72: dbg_arch_data = {23'd0, tr_valid, tr_attr};
      7'd73: dbg_arch_data = ldt_base;
      7'd74: dbg_arch_data = {16'd0, ldt_limit};
      // Latched only at a debugger stop.  This is intentionally part of the
      // compact scan rather than another FPGA-wide debug route.
      7'd75: dbg_arch_data = {30'd0, dbg_stop_reason_q};
      default: dbg_arch_data = 32'd0;
    endcase
  end

  // ---- single-step / instruction-breakpoint hold ---------------------------
  // dbg_block_issue, when 1, parks the NEXT instruction boundary.  That boundary
  // is S_DECODE on the slow FSM, S_PIPE on the dual-issue fast path, or the
  // already-idle S_HLTWAIT state.  The
  // shared fp_issue_block predicate below gates every fast-path side-effect
  // mirror, so a park cannot advance EIP while still writing a GPR/FPR, updating
  // the BTB/LRU, or launching a speculative translation.  Existing multi-cycle
  // work is allowed to retire first; the scan only advertises HALTED after its
  // deferred x87 commit has drained.
  logic dbg_bp_latched;   // breakpoint fired; sticky until the PS pulses dbg_bp_clr
  logic dbg_step_q;       // permit exactly ONE issue while parked (single-step)
  logic dbg_bp_hit;
  logic dbg_bp_v_hit;
  logic dbg_block_issue;  // 1 = park an instruction boundary
  logic dbg_fast_hold;    // S_PIPE may stop issuing (not an FP occupancy retire)
  logic dbg_pair_block;   // force exactly one x86 instruction for host single-step
  logic dbg_arch_quiescent;
  logic dbg_step_permit;  // release the park only until the requested retire is visible
  logic dbg_halt_req_q;   // sampled level, so a halt at an already-idle boundary records a cause
  // 0=none/running, 1=manual halt, 2=EIP breakpoint, 3=completed host step.
  // Kept sticky through a halt so `step` remains distinguishable from the
  // halt-request level it necessarily leaves asserted for the re-park.
  logic [1:0] dbg_stop_reason_q;
  wire  dbg_step_active = dbg_step_q;
  // pre-execution PC breakpoint: the instruction about to issue sits at `eip`
  // at either architectural issue boundary.  A V-slot match is handled below by
  // suppressing that pair, then catches on the following U boundary.
  assign dbg_bp_hit = dbg_bp_en && (eip == dbg_bp_addr) &&
                      ((state == S_DECODE) || (state == S_PIPE)) && !dbg_step_q;
  wire   dbg_park   = dbg_halt_req | dbg_bp_latched;
  // retire_valid is a registered pulse.  Keep the step latch set through the
  // execution edge (so pairing remains disabled), but reassert the hold during
  // the following visible-retire cycle.  Without this, the clear NBA arrives
  // one edge late and a second S_PIPE instruction can issue.
  assign dbg_step_permit = dbg_step_q && !retire_valid;
  assign dbg_block_issue = (dbg_park | dbg_bp_hit) & ~dbg_step_permit;
  assign dbg_fast_hold = dbg_block_issue && (state == S_PIPE) && !fp_occ_pending;
  assign dbg_pair_block = dbg_step_q || dbg_bp_v_hit;
`ifdef VEN_FP_PIPE
`ifdef VEN_FP_PIPE2
  wire dbg_fp_commit_pending = fpp_valid || fpp2_valid;
`else
  wire dbg_fp_commit_pending = fpp_valid;
`endif
`else
  wire dbg_fp_commit_pending = 1'b0;
`endif
  assign dbg_arch_quiescent = ((state == S_DECODE) || (state == S_HLTWAIT) ||
                               ((state == S_PIPE) && !fp_occ_pending)) &&
                              !dbg_fp_commit_pending;
  assign dbg_halted = dbg_block_issue && dbg_arch_quiescent;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_bp_latched <= 1'b0;
      dbg_step_q     <= 1'b0;
      dbg_halt_req_q <= 1'b0;
      dbg_stop_reason_q <= 2'd0;
    end else begin
      dbg_halt_req_q <= dbg_halt_req;
      if (dbg_bp_hit)        dbg_bp_latched <= 1'b1;        // latch a breakpoint hit
      else if (dbg_bp_clr)   dbg_bp_latched <= 1'b0;        // PS clears it to resume
      if (dbg_step && dbg_park) dbg_step_q <= 1'b1;         // arm one single-step
      else if (dbg_step_q && retire_valid) dbg_step_q <= 1'b0; // consume after one retire

      // Stop cause reflects the completed stop, not merely the live request
      // levels.  In particular, a step holds dbg_halt_req high so it re-parks;
      // report STEP after that requested retirement rather than MANUAL.
      if (dbg_bp_clr)                       dbg_stop_reason_q <= dbg_halt_req ? 2'd1 : 2'd0;
      else if (dbg_step_q && retire_valid) dbg_stop_reason_q <= 2'd3;
      else if (dbg_bp_hit)                 dbg_stop_reason_q <= 2'd2;
      else if (dbg_halt_req && !dbg_halt_req_q) dbg_stop_reason_q <= 2'd1;
    end
  end
`else
  // No debug build: every inserted park/pair guard is false, preserving the
  // original fast and slow paths exactly.
  wire dbg_block_issue = 1'b0;
  wire dbg_fast_hold = 1'b0;
  wire dbg_pair_block = 1'b0;
  wire dbg_step_active = 1'b0;
  wire dbg_step_permit = 1'b0;
`endif

  // M7.1 int-0x80 proxy state. gs_base_r holds the latched %gs TLS base captured
  // from the proxy (set_thread_area's sys_call.gs_base); it is installed into
  // seg_base[GS] the moment a user-mode `mov gs, 0x33` selector load happens.
  // cn mirrors the retire counter so syscall_n can name the upcoming record (the
  // TB cross-checks it against its own retire count). Both are INERT (untouched,
  // base stays flat) unless proxy_en is set, so existing user tests are
  // byte-identical. The combinational syscall_active pulse is produced in the
  // S_DECODE int-0x80 arm (see below); the apply happens on that same clock.
  logic [31:0] gs_base_r;          // latched %gs TLS base (0 = flat / unset)
  logic [63:0] cn;                 // core-side retire counter (drives syscall_n)
  logic [63:0] tsc;                // F3: free-running time-stamp counter (RDTSC 0F 31)
`ifdef VEN_DBG_WD
  logic [23:0] dbg_stall;          // sim-only: cycles since last retire (hang watchdog)
`endif
`ifdef VEN_TRACE_IRQ
  logic        dbg_if_q;            // sim-only: prev EFLAGS.IF, for IF-transition trace
  logic [15:0] dbg_cs_q;           // sim-only: prev CS selector, for CS-change trace
  logic [31:0] dbg_csb_q;          // sim-only: prev CS base, for CS-change trace
`endif
`ifdef VEN_PS_PROXY
  logic [3:0]  q_proxy_len;        // int80 length latched at S_SYSCALL_WAIT entry (eip
                                   // parks at cd80, so this is the only thing the wait
                                   // arm needs to advance eip on the late commit).
`endif
  // M7.1 folded-instruction state: after proxying an int-0x80 we execute the
  // instruction following cd80 and emit ONE retire that stands in for the golden
  // int-0x80 record. fold_pending_r marks "the next retire is that syscall record"
  // and fold_pc_r holds the int's pc to stamp on it (so the retire's pc matches
  // the golden, not the folded insn's address). Inert unless proxy_en.
  logic        fold_pending_r;
  logic [31:0] fold_pc_r;
  logic        syscall_active_c;   // combinational: this clock decodes cd80 in proxy mode
  assign syscall_n      = cn;
  // syscall_active is high for exactly the S_DECODE clock that proxies an
  // int-0x80: the TB samples it to apply the kernel writes + drive back the
  // golden ret/resume-eip/gs effects this same clock (combinational, like the
  // mem bus). Gated on proxy_en + d_int80 so it is 0 in every non-proxy run.
  // (state/proxy_en/d_int80 are all declared above this point.)

  localparam int IWORDS = 4;
  logic [7:0]  ibuf [16];
  logic [2:0]  fetch_word;
`ifdef VEN_UOPCACHE
  // One-shot token for a cycle-mode uop-cache miss. It lets S_FETCH reuse the
  // exact registered I-cache window that proved the miss's bytes resident,
  // rather than launching the normal four-word slow fetch.
  logic        sfetch_uop_q;
`endif
`ifdef VEN_SFETCH_RESIDENT
  // The full-profile extension uses the same endpoint-recheck for every
  // S_PIPE-to-S_FETCH producer.  It is a token only: no byte data or predicted
  // tag crosses the state boundary.
  logic        sfetch_resident_q;
`endif

  // ===========================================================================
  // M4 dual-issue fast-path pipeline state (docs/m4-pipeline-spec.md §"How to
  // evolve the core"). A 32-byte prefetch buffer feeds a 2-wide decode + pairing
  // checker; simple/pairable instructions execute through it at up to 2/clock
  // with AGI interlock + a 256-entry/4-way BTB & 2-bit predictor. Anything the
  // fast path does not recognise falls back to the proven multi-cycle FSM
  // (S_FETCH..) so functional behaviour is preserved exactly.
  // ===========================================================================
  // 8 KB 2-WAY set-associative instruction cache (128 sets x 2 ways x 32 B line =
  // 256 lines), the P5 L1 I-cache geometry (Alpert & Avnon, docs/p5-timing-model.md).
  // M5 finding [med]: the oracle's I-cache is 2-WAY / 128-set / LRU
  // (verif/qemu-plugins/p5trace.c:61-65 L1_SETS=128 L1_WAYS=2, l1_access 2-way
  // LRU); a DIRECT-MAPPED I-cache gives a DIFFERENT hit/miss SEQUENCE for any
  // conflict-prone or partially-resident working set (wrong-way / replacement
  // divergence). The I-cache must use the SAME associativity/index/tag/LRU as the
  // oracle (and as the RTL D-cache) so the miss sequence — not just the aggregate
  // — agrees. set = addr[11:5] (128 sets), tag = addr[31:12] (20 bits). The fast
  // path decodes combinationally out of the cache; a miss triggers a line fill
  // (8 word reads = imiss penalty) in S_PF, allocating the 2-way LRU victim.
  //
  // The default build is byte/cycle-identical: with IC_IDXW=7, addr[5 +: 7] is
  // exactly addr[11:5] and addr[12 +: 20] is exactly addr[31:12].
  // The integrated core is deliberately pinned to the 8 KiB P5 I$ geometry.
  // Parameterized icache leaf-module tests remain useful, but compile-time cache
  // resizing must not create a second hardware configuration with different
  // performance and coherence behaviour.
  localparam int IC_SETS = 128;
  localparam int IC_WAYS = 2;
  localparam int IC_IDXW = $clog2(IC_SETS);     // set-index width: 7
  localparam int IC_TAGW = 32 - 5 - IC_IDXW;    // tag width:      20
  localparam int IC_LINE = 32;
  localparam int IC_WAYW = (IC_WAYS <= 1) ? 1 : $clog2(IC_WAYS);  // way-index width (1 @2-way)
  // The I-cache ARRAYS + per-word fill + fill-complete MRU + up-to-3 LRU touches
  // + synchronous reset now live in the `icache` module (rtl/mem/icache.sv, R2
  // extract), instantiated as u_icache below. The arrays are EXPOSED READ-ONLY as
  // these outputs so the combinational probes (ic_present / ic_hit_way / ic_byte)
  // read the REGISTERED PRE-edge state directly, UNCHANGED. The fill is sequenced
  // by the spine regs below (pf_fill_addr/pf_fill_way/pf_word + the ic_victim_o
  // victim, which STAY here); the module never recomputes the victim.
  // icache addressed line-read interface (replaces the whole-array ic_data_o:
  // the fetch window spans only 2 consecutive lines — A=flin's line, B=next).
  logic [IC_IDXW-1:0]  ic_rd_setA, ic_rd_setB;
  logic [IC_WAYW-1:0] ic_rd_wayA, ic_rd_wayB;
  logic [IC_LINE*8-1:0] ic_rd_lineA, ic_rd_lineB;
  // KV260 BRAM cross-port read-during-write collide flags (icache module): set when
  // the registered read of A/B launched in the SAME cycle a fill wrote that {set,way}.
  // The spine must NOT consume a collided buffer (silicon RAMB36 returns garbage there,
  // invisible to Verilator) — it gates fetch-ready / the ic_byte select to force a
  // clean re-read. Tied 0 on the async (distributed) path.
  logic        ic_rd_collA, ic_rd_collB;
`ifdef VEN_IC_BRAM
  // +VEN_IC_BRAM: the icache read ports are REGISTERED (BRAM mandates a synchronous
  // read), so ic_rd_lineA/B in cycle T hold the line for the read ADDRESS presented
  // in cycle T-1. We register that address as a TAG (rdA_set_q/rdA_way_q for A,
  // rdB_* for B) so ic_byte can CONTENT-ADDRESS the two registered line buffers
  // (pick whichever buffer holds the needed set) instead of comparing against the
  // live ic_rd_setA. A line is "fetch-ready" iff a buffer's tag matches what flin
  // needs THIS cycle. Sequential fetch keeps flin in one line for ~8 insns (tag
  // matches, no stall), and a sequential line-crossing finds the new line ALREADY in
  // buffer B (it read flin's next line last cycle) — so sequential fetch is
  // bubble-free; only a redirect to an un-buffered line costs a 1-cycle refill.
  logic [IC_IDXW-1:0]  rdA_set_q, rdB_set_q;
  logic [IC_WAYW-1:0] rdA_way_q, rdB_way_q;
  logic        ic_fetch_ready;   // the line(s) the current decode window needs are buffered
  // 2b — predicted-taken-target PREFETCH: when a predicted-taken branch sits in the
  // current (non-straddling) window, we're about to REDIRECT, so the sequential next
  // line (port B's normal job) won't be needed — repurpose port B to read the branch
  // TARGET line, so it is buffered BEFORE the redirect and the back-edge costs no
  // bubble. Driven in the fast-path comb block (where the BTB prediction is known).
  logic        pf_redir;
  logic [31:0] pf_redir_tgt;
`endif
  logic [IC_TAGW-1:0] ic_tag_o  [IC_SETS][IC_WAYS];   // addr[31:5+idx]
  logic        ic_val_o  [IC_SETS][IC_WAYS];
  logic [IC_WAYW-1:0] ic_victim_o [IC_SETS]; // replacement (LRU) way per set (== ~ic_lru @2-way)
  logic [31:0] pf_fill_addr;         // line base currently being filled
  logic [IC_WAYW-1:0] pf_fill_way;     // victim way chosen for the fill (LRU)
  logic [2:0]  pf_word;              // refill word counter (8 words = 32 bytes)

  // BTB: 64 sets x 4 ways, 2-bit saturating counters (Alpert & Avnon / AP-500).
  // The arrays (btb_tag/btb_ctr/btb_val/btb_rr), the pure-comb btb_lookup() and
  // the single btb_update_taken() now live in the bpred_btb module (R2 extract,
  // rtl/core/bpred_btb.sv). The spine drives two combinational predict ports
  // (btb_u_query_pc -> btb_u_pred / btb_v_query_pc -> btb_v_pred, PRE-update
  // state) and the single synchronous resolve port (btb_resolve_valid/pc/taken).
  localparam int BTB_SETS = 64;
  localparam int BTB_WAYS = 4;
  logic [31:0] btb_u_query_pc;   // comb U predict pc (= eip)
  logic        btb_u_pred;       // comb: U predicted-taken (PRE-update state)
  logic [31:0] btb_v_query_pc;   // comb V predict pc (= eip + u_d.len)
  logic        btb_v_pred;       // comb: V predicted-taken (PRE-update state)
  logic        btb_resolve_valid;// comb: a branch resolves this clock (U or V)
  logic [31:0] btb_resolve_pc;   // comb: resolving branch pc
  logic        btb_resolve_taken;// comb: resolving branch taken decision

  // AGI tracking: gpr index written in the immediately-PREVIOUS issue clock.
  // -1 (bit8 set) = none. Updated each fast-path issue clock.
  logic [8:0]  agi_wr0, agi_wr1;     // up to two regs written last fast clock

  logic [2:0]  mispred_bubbles;      // remaining flush bubbles to burn

  // ===========================================================================
  // M5 cycle-accuracy state (docs/m5-cycle-spec.md). Two timing models, both
  // EMERGENT (real SM / real scoreboard), using the SAME geometry/penalty as the
  // p5model oracle (build/p5trace.so: imiss=8, dmiss=8, 8KB/2-way/32B, misalign
  // +3) so the cycle COMPONENTS agree, not a formula copied from the oracle.
  // ===========================================================================
  // Free-running core-clock counter (the timeline the FP scoreboard lives on).
  // Mirrors the TB's cyc = clock-count-at-retire; advances every clock.
  logic [31:0] core_cyc;

  // x87 FP latency/throughput scoreboard (p5model g.fp_ready). Holds the cycle at
  // which the x87 top-of-stack result of the most recent FP producer/rmw becomes
  // readable. A dependent FP consumer (fp_role>=2) must stall until then; this is
  // what turns a dependent fadd chain into CPI~3 (lat 3) while independent FP
  // pipelines at throughput 1 (the latency is overlapped by other work).
  //
  // #6 DESIGN DECISION (owner-confirmed 2026-06-09, "keep fixed P5 lat"): the
  // scoreboard is driven by the FIXED P5 latencies `u_d.fp_lat`/`fp_occ` (the
  // p5trace.c oracle's per-op constants), NOT by the iterative engines' real
  // `done`. The two are RUNTIME-EXCLUSIVE arms: this fast/cycle arm is the M4/M5
  // cycle-accuracy model graded against the p5model golden (the mb_* bands), while
  // the iterative SRT/BCD/transcendental engines live on the SLOW functional arm
  // (S_FP_BUSY/S_BCD_BUSY/S_TRSC_BUSY). Those engines' done-latency is an
  // implementation artifact (radix-4 SRT count, ~20-clk microcode), tuned for
  // bit-exactness/area — NOT real-P5 cycle timing — so feeding it back here would
  // diverge from the oracle and move the bands. The fixed `fp_lat`/`fp_occ`
  // constants stay the cycle-fidelity source of truth. (#6 closed as by-design.)
  logic [31:0] fp_ready_cyc;

  // FP pipe OCCUPANCY hold (p5model pipe_free_at = issue + occ). An FP op holds
  // the in-order pipe for `occ` clocks: even a FOLLOWING INDEPENDENT integer op
  // cannot issue until the FP op's occupancy expires (fdiv occ 39, fmul occ 2,
  // fsqrt occ 70). This is DISTINCT from result latency (fp_ready_cyc), which
  // only stalls a dependent FP CONSUMER. fp_occ_pending marks "occupancy clocks
  // are being burned; commit+retire when stall_cnt reaches 0"; fp_issue_cyc is
  // the cycle occupancy began (so fp_ready = issue + lat is anchored correctly).
  logic        fp_occ_pending;
  logic [31:0] fp_issue_cyc;
`ifdef VEN_FP_OVERLAP
  // GAP1 (FDIV/integer overlap, mirrors p5trace.c g.fp_busy_until): the cycle the
  // single x87 exec unit is free again. A FOLLOWING FP op (is_fp, NOT FXCH) waits
  // on it; integer ops never reach the FP arm, so they overlap the FDIV shadow.
  // The FP op itself holds the INTEGER pipe only P5_FP_ISSUE_OCC clocks (retires at
  // issue+2 like oracle pipe_free_at=issue+P5_FP_ISSUE_OCC), while the real occ-long
  // exec window lives on fp_busy_cyc.
  logic [31:0] fp_busy_cyc;
  localparam logic [6:0] P5_FP_ISSUE_OCC = 7'd2;
`endif

  // L1 D-cache TIMING model: 8 KB / 2-way / 32 B line / 128 sets, LRU. Data still
  // comes from the BFM (mem_rdata); this only gates WHEN a load completes. A read
  // miss adds dmiss; a misaligned access adds +3 (AP-500). Matches p5_mem() +
  // l1_access() in verif/qemu-plugins/p5trace.c (read-allocate, 2-way LRU).
  // The package owns this P5-geometry constant so the timing model and functional
  // AXI L1D cannot drift into different cache shapes.
  localparam int DC_SETS = ventium_pkg::L1D_SETS_DEF;
  localparam int DC_WAYS = 2;
  // The dc_tag/dc_val/dc_lru state + the dc_hit() lookup + the dc_access()
  // allocate/LRU SM + the synchronous reset now live in the dcache_timing module
  // (rtl/mem/dcache.sv), instantiated below. The spine keeps the penalty policy
  // (pending_mem_pen / P5_DMISS / P5_MISALIGN) + the cycle_mode gating, and drives
  // the module's combinational lookup (dc_lu_addr -> dc_lu_hit) + the single
  // funnelled posedge access port (dc_acc_valid / dc_acc_addr).
  logic [31:0] dc_lu_addr;   // comb lookup address (= this clock's access address)
  logic        dc_lu_hit;    // comb: line resident in its set (PRE-access state)
  logic        dc_acc_valid; // comb: an access/allocate fires this clock
  logic [31:0] dc_acc_addr;  // comb: the access address
  // I-cache miss penalty (imiss=8) is materialised EMERGENTLY by the existing
  // S_PF line-fill (8 word reads = 8 clocks), so it needs no constant here.
  localparam logic [6:0] P5_DMISS = 7'd8;   // D-cache miss penalty (plugin arg)
  localparam logic [6:0] P5_MISALIGN = 7'd3;// misaligned data access (AP-500)

  // Deferred D-cache penalty (p5model g.pending_mem_pen): a load's miss/misalign
  // penalty is charged to the NEXT instruction's issue (the model defers the
  // data stall by one retire). We replicate that one-instruction defer so the
  // per-instruction cyc deltas line up with the oracle.
  logic [6:0]  pending_mem_pen;

  // Multi-clock stall countdowns used to MATERIALISE a penalty as real clocks
  // (so cyc = clock-count-at-retire grows by exactly the penalty). Only one is
  // ever non-zero at a time; S_PIPE burns them before issuing.
  logic [6:0]  stall_cnt;             // remaining stall clocks before next issue

  // ALU op encoding (ALU_ADD..ALU_NOT) lives in ventium_alu_pkg (imported above).
  // op-class enum (kind_e), micro-sequencer enums (smk_e/st_e/ctk_e), and the
  // x87 decode enum (fxop_e) live in ventium_decode_pkg (imported above).

  // ===========================================================================
  // Decoder outputs (combinational)
  // ===========================================================================
  logic [3:0]  d_len;
  logic        d_halt;
  logic        d_cacheinv;   // REVIEW_aug2 H-06: INVD/WBINVD (CPL0-only)
  logic        d_int80;   // M7.1: decoded `int 0x80` (cd80) — the proxy site
  logic        d_unknown;
  // M2S.3 software/conditional interrupt + return decode (gated sys_mode in the
  // FSM; in user mode INT n still HALTs as before). d_int_n carries the vector.
  logic        d_int;            // INT n / INT3 / INTO -> IDT delivery (a TRAP)
  logic [7:0]  d_int_vec;        // the vector for d_int
  logic        d_int_imm;        // M7.2: this is the INT n IMMEDIATE form (0xCD ib)
                                 // — the IOPL-sensitive one in V86 (INT3/INTO are
                                 // NOT IOPL-controlled; they always vector to the
                                 // monitor). Distinguishes 0xCD 0x03 from 0xCC.
  logic        d_int_cond_of;    // INTO: deliver only if OF (eflags bit 11) set
  logic        d_iret;           // IRET (CF): pop EIP/CS/EFLAGS
  logic        d_ud2;            // UD2 (0F 0B) -> #UD (vector 6) in sys mode
  // M2S.5 RSM (0F AA): leave SMM, restore the saved CPU state from the SMRAM save
  // map + resume the interrupted context. Only legal inside SMM (smm_active);
  // outside SMM it is #UD (user mode HALTs as before — RSM is a system op).
  logic        d_rsm;
  // M6 Erratum 81 (F00F): decoded the invalid LOCK CMPXCHG8B-with-register-dst
  // form (F0 0F C7 /reg, mod==11). Set ALONGSIDE d_unknown (so the clean core,
  // errata off, still HALTs loudly on this invalid opcode); when errata_en[
  // ERR_F00F] is set the FSM routes it to the documented hang instead.
  logic        d_f00f;
  logic        d_is_branch;
  logic        d_branch_taken;
  logic [31:0] d_rel;
  logic [4:0]  d_alu_op;
  logic        d_writes_reg;
  logic        d_writes_flags;
  logic        d_mem_read;
  logic        d_mem_write;
  logic        d_mem_dst;
  logic [2:0]  d_dst_reg;
  logic [2:0]  d_src_reg;
  logic [31:0] d_imm;
  logic        d_use_imm;
  logic        d_is_push;
  logic        d_is_pop;
  logic        d_is_lea;
  logic        d_is_mov;
  logic        d_is_nop;
  logic        d_is_fwait;   // REVIEW1_Aug2 H-12
  // REVIEW1_Aug2 H-12: the "no-wait" x87 forms -- the N in FNINIT/FNCLEX/FNSTSW/
  // FNSTCW/FNSTENV/FNSAVE. These do NOT check for a pending unmasked exception,
  // because they are exactly the instructions software uses to READ the status and
  // CLEAR it. Trapping them would make an unmasked exception unrecoverable: the
  // handler could not read FSW to find out what happened, nor FNCLEX it away.
  // (FLDCW / FLDENV / FRSTOR have no N and DO wait.)
  logic        fx_nowait;
  assign fx_nowait = (d_fxop == FX_FNINIT)   || (d_fxop == FX_FNCLEX)
                  || (d_fxop == FX_FNSTSW_M) || (d_fxop == FX_FNSTSW_AX)
                  || (d_fxop == FX_FNSTCW)   || (d_fxop == FX_FNSTENV)
                  || (d_fxop == FX_FNSAVE);
  logic [31:0] d_ea;
  logic [2:0]  d_w;
  logic        d_dst_high8;
  logic        d_src_high8;
  kind_e       d_kind;
  logic [2:0]  d_shrot;
  logic        d_shift_cl;
  logic        d_shift_one;
  logic [4:0]  d_shift_imm;
  logic        d_shrd;
  logic [2:0]  d_md;
  logic        d_imul_3op;
  logic [31:0] d_imul_imm;
  logic        d_ext_signed;
  logic [2:0]  d_ext_srcw;
  logic [3:0]  d_cc;
  logic        d_bit_imm;
  logic [2:0]  d_bit_op;
  logic        d_conv_cdq;
  smk_e        d_sm;
  st_e         d_st;
  logic        d_str_loadsi;   // reads [ESI]
  logic        d_str_storedi;  // writes [EDI]
  logic        d_str_scandi;   // reads [EDI] for compare
  ctk_e        d_ct;
  logic [15:0] d_ret_imm;
  logic        d_cld;
  logic        d_std;
  logic        d_clc;          // CLC (F8): CF<-0
  logic        d_stc;          // STC (F9): CF<-1
  logic        d_cmc;          // CMC (F5): CF<-~CF
  logic        d_cli;          // CLI (FA): IF<-0  (M2S.1)
  logic        d_sti;          // STI (FB): IF<-1  (M2S.1)
  logic        d_cnt16;        // 0x67 address-size: LOOP/JCXZ use CX (low 16)
  // M7.3b: a 16-bit-operand-size NEAR branch (real-mode Jcc/JMP rel16, or the
  // rel8 forms in 16-bit mode). The taken target truncates EIP to 16 bits (IA-32:
  // a near jump under a 16-bit operand size masks EIP to IP). 0 in 32-bit mode, so
  // every prior gate is unchanged. Set by the operand-size-aware branch arms.
  logic        d_br16;

  // ---- M7.3b IN/OUT port-I/O decode (docs/m7-lockstep-spec.md M7.3) ----------
  // The Win95 system co-sim needs real port I/O: IN reads a device value the CPU
  // cannot compute (replayed from the golden's dev_in via the io bus), OUT drives
  // a port/value out to the TB (consumed there; the existing isa-debug-exit `out
  // 0xf4` terminator is preserved). Opcodes:
  //   E4 ib  IN  AL, imm8        E5 ib  IN  eAX, imm8
  //   E6 ib  OUT imm8, AL        E7 ib  OUT imm8, eAX
  //   EC     IN  AL, DX          ED     IN  eAX, DX
  //   EE     OUT DX, AL          EF     OUT DX, eAX
  // Width: byte for the AL forms (E4/E6/EC/EE), else eff-opsize (word in real
  // mode / dword in 32-bit). The port is an imm8 (E4-E7) or DX[15:0] (EC-EF).
  // d_io_w reuses the wmask width code (1=byte, 2=word, 4=dword). These are 0 for
  // every non-IN/OUT instruction, so the dispatch below is inert elsewhere.
  logic        d_lock;          // REVIEW1_Aug2 C-10: LOCK prefix on this insn
  logic        q_lock;          // ...latched for the whole RMW
  logic        d_io;            // this instruction is IN/OUT
  // ---- REVIEW1_Aug2 M-03: TSS I/O-permission bitmap consult -----------------------
  // Needed only when the instruction is port I/O AND the current privilege exceeds
  // IOPL. At CPL <= IOPL the access is unconditionally allowed and no TSS read happens,
  // so the common case costs nothing. tr_limit must also be large enough to HOLD a map
  // base field (offset 0x66..0x67); a TSS too small to contain one denies all I/O,
  // which is the architectural behaviour.
  state_e      ioperm_ret;      // where to resume once the bitmap says yes
  logic [15:0] ioperm_port;     // the port being checked
  logic [15:0] ioperm_base;     // TSS.io_map_base, read on beat 0
  // REVIEW2_aug2 C-07(c): the bits this access actually covers. The beat-1 read is a
  // byte-addressed dword at tr_base+base+(port>>3), so bit j of it is port
  // (port & ~7) + j; port p+i therefore sits at port[2:0]+i. A 4-byte access needs at
  // most bits port[2:0]..port[2:0]+3, and port[2:0]+3 <= 10, so every covered port is
  // inside the one dword already fetched.
  // REVIEW_Aug3 M-01: the last port is computed in 17 bits. The 16-bit form
  // WRAPPED at port 0xFFFF: a word/dword access beginning at 0xFFFE/0xFFFC
  // produced an ioperm_last below ioperm_port, so the bitmap limit check passed
  // vacuously and the permission mask indexed bits belonging to ADJACENT bitmap
  // memory (ports past the end of the I/O space). An access whose extent crosses
  // the 16-bit I/O-space boundary is rejected outright -- the wraparound form
  // (split the check at the wrap) is the other legal reading, but no real OS
  // depends on it and an explicit deny is the fail-safe choice.
  logic [16:0] ioperm_last17;   // the HIGHEST port this access covers (unwrapped)
  assign ioperm_last17 = {1'b0, ioperm_port} + {14'd0, q_io_w} - 17'd1;
  logic        ioperm_wrap;     // the access runs past port 0xFFFF
  assign ioperm_wrap = ioperm_last17[16];
  logic [15:0] ioperm_last;     // the HIGHEST port this access covers
  assign ioperm_last = ioperm_last17[15:0];
  logic [31:0] io_perm_mask;
  always_comb begin
    io_perm_mask = 32'd0;
    for (int i = 0; i < 4; i++)
      if (i < int'(q_io_w))
        io_perm_mask[{2'd0, ioperm_port[2:0]} + i[4:0]] = 1'b1;
  end
  logic        ioperm_needed;
  assign ioperm_needed = sys_mode && !real_mode && d_io && (eff_cpl > iopl);
  logic        d_io_write;      // 1 = OUT (CPU drives the port), 0 = IN (CPU reads)
  logic        d_io_imm;        // 1 = port is the imm8 byte (E4-E7), 0 = DX (EC-EF)
  logic [7:0]  d_io_port_imm;   // the imm8 port (when d_io_imm)
  logic [2:0]  d_io_w;          // I/O width code (1=byte, 2=word, 4=dword)

  // ---- M2S.1 system-mode decode (docs/m2s1-segmentation-spec.md) ------------
  // d_seg : which segment the memory operand uses (SG_CS..SG_GS). Default DS
  //   (=SG_DS); stack ops force SS; a 26/2E/36/3E/64/65 override prefix selects
  //   ES/CS/SS/DS/FS/GS. In user mode this is ignored (all bases 0).
  // d_sysop : a decoded system instruction (LGDT/LIDT/MOV CRn/MOV sreg/far JMP).
  // d_def16 : the real-mode default operand/address size is 16-bit (so a 0x66
  //   prefix means 32-bit). Computed at decode from real_mode ^ pfx.
  logic [2:0]  d_seg;          // segment index for the data memory operand
  // sysop_e (the SYS_* enum) moved to core/decode_stages.sv at $unit scope so the
  // d_sysop output port and these wires (+ the svh q_sysop==SYS_* compares) share
  // one type. The enumerator list is identical; this is a pure relocation.
  sysop_e      d_sysop;
  logic [2:0]  d_sys_sreg;     // target/source segment register index (mov sreg)
  logic [2:0]  d_sys_creg;     // CR index (0/2/3/4) for MOV CRn
  logic [31:0] d_ljmp_off;     // far-jump target offset
  logic [15:0] d_ljmp_sel;     // far-jump target selector
  logic        d_seg_load;     // M9.5 LES/LDS/LSS/LFS/LGS: also load a seg reg from [mem]+2
  logic [2:0]  d_lseg;         //   target segment register index for the seg-load
  logic        d_push_sreg;    // F3 PUSH sreg (06/0E/16/1E): push data = seg_sel[d_sys_sreg]
  logic        d_pop_sreg;     // F3 POP sreg (07/17/1F): pop writes seg_sel/base[d_sys_sreg]
  logic        d_seg_load_lo;  // F3 MOV Sreg,[mem]: selector = LOW 16b of the 2-byte read
  logic        d_store_sreg;   // F3 MOV [mem],Sreg: store data = seg_sel[d_sys_sreg]
  logic        d_xlat;         // XLATB (D7): AL <- [DS:(E)BX + zero-extend(AL)] (byte load)
  logic        d_callf_mem;    // F3 FF /3 CALLF m16:16 (far indirect call through memory)
  logic        d_jmpf_mem;     // F3 FF /5 JMPF  m16:16 (far indirect jump through memory)
  logic        d_pfx_seg_en;   // a segment-override prefix is present
  logic [2:0]  d_pfx_seg_idx;  // which segment the override selects

  // ---- x87 decode (M3) ------------------------------------------------------
  // x87 sub-op encoding (fxop_e: FX_*) lives in ventium_decode_pkg. The decoder
  // classifies each escape (D8..DF + ModR/M) into one of these and supplies the
  // addressing (d_f_mem_read/write + d_f_msize) and operand index (d_f_sti).
  fxop_e       d_fxop;
  logic        d_is_x87;
  logic        d_f_mem_read;     // x87 op reads a memory operand
  logic        d_f_mem_write;    // x87 op writes a memory operand
  logic [2:0]  d_f_msize;        // memory operand bytes: 2/4/8/10 (encoded as 2,4,8,10 won't fit 3b)
  logic [3:0]  d_f_mbytes;       // memory operand size in bytes (2,4,8,10)
  logic        d_f_pop;          // pop the stack after the op (1 pop)
  logic        d_f_pop2;         // pop twice (FCOMPP/FUCOMPP)
  logic [2:0]  d_f_sti;          // st(i) index operand
  logic [2:0]  d_f_aluop;        // 0=add 1=mul 4=sub 5=subr 6=div 7=divr (x87 group)
  logic [2:0]  d_f_const;        // ROM-constant selector for FLDCONST

  // ===========================================================================
  // ModR/M + SIB helpers
  // ===========================================================================
  // The ModR/M+SIB scratch (m_idx/modrm_mod/modrm_rm/has_sib/sib_*/mrm/sibb) and
  // the prefix scratch (pfx_len/pfx_opsize/op0/op1/two_byte) moved INTO the
  // extracted decode_stages module (R3). The fields the spine/FSM still reads are
  // kept here as plain wires DRIVEN BY the u_decode_stages instance below:
  //   modrm_reg, pfx_rep, pfx_seg, pfx_lock, pfx_addr, eff_opsize, eff_addr.
  logic [2:0]  modrm_reg;

  // mfl() (ModR/M field length) lives in ventium_decode_pkg.

  // ===========================================================================
  // Prefix machine (now in core/decode_stages.sv; these are its outputs)
  // ===========================================================================
  logic       pfx_addr, pfx_seg, pfx_lock;
  logic [1:0] pfx_rep;          // 0 none, 2 F2, 3 F3

  // is_prefix() lives in ventium_decode_pkg.

  // M2S.1: EFFECTIVE operand/address size (driven by u_decode_stages). In REAL
  // mode the default is 16-bit, so a 0x66/0x67 prefix means 32-bit (inverted vs
  // protected/flat). The spine/FSM reads these, so they stay here as wires.
  logic eff_opsize, eff_addr;

  // ===========================================================================
  // SLOW-PATH DECODER — extracted to core/decode_stages.sv (R3,
  // docs/rtl-refactor-plan.md). The prefix machine, eff_opsize/eff_addr, the
  // sreg_idx helper, and the ~1400-line combinational decoder moved VERBATIM
  // into the decode_stages module; it drives every d_* wire (and the leaked
  // prefix/ModR/M intermediates modrm_reg/pfx_rep/pfx_seg/pfx_lock/pfx_addr/
  // eff_opsize/eff_addr) the q_* latch + FSM consume. Pure refactor (netlist-
  // identical; gated byte-for-byte vs the QEMU goldens).
  // ===========================================================================
  decode_stages u_decode_stages (
    // inputs (architectural + fetch state the decoder reads)
    .ibuf          (ibuf),
    .gpr           (gpr_o),
    .eflags        (eflags),
    .sys_mode      (sys_mode),
    .def16         (def16),
    .seg_real      (seg_real),
    .smm_active    (smm_active),
    .paging_on     (paging_on),
    .cosim_en      (cosim_en),
    .soc_en        (soc_en),
    // leaked prefix/ModR/M intermediates the spine/FSM also reads
    .modrm_reg     (modrm_reg),
    .pfx_rep       (pfx_rep),
    .pfx_seg       (pfx_seg),
    .pfx_lock      (pfx_lock),
    .pfx_addr      (pfx_addr),
    .eff_opsize    (eff_opsize),
    .eff_addr      (eff_addr),
    // decoded fields (the d_* the q_* latch consumes)
    .d_len         (d_len),
    .d_halt        (d_halt),
    .d_cacheinv    (d_cacheinv),
    .d_int80       (d_int80),
    .d_unknown     (d_unknown),
    .d_int         (d_int),
    .d_int_vec     (d_int_vec),
    .d_int_imm     (d_int_imm),
    .d_int_cond_of (d_int_cond_of),
    .d_iret        (d_iret),
    .d_ud2         (d_ud2),
    .d_rsm         (d_rsm),
    .d_f00f        (d_f00f),
    .d_is_branch   (d_is_branch),
    .d_branch_taken(d_branch_taken),
    .d_rel         (d_rel),
    .d_alu_op      (d_alu_op),
    .d_writes_reg  (d_writes_reg),
    .d_writes_flags(d_writes_flags),
    .d_mem_read    (d_mem_read),
    .d_mem_write   (d_mem_write),
    .d_mem_dst     (d_mem_dst),
    .d_dst_reg     (d_dst_reg),
    .d_src_reg     (d_src_reg),
    .d_imm         (d_imm),
    .d_use_imm     (d_use_imm),
    .d_is_push     (d_is_push),
    .d_is_pop      (d_is_pop),
    .d_is_lea      (d_is_lea),
    .d_is_mov      (d_is_mov),
    .d_is_nop      (d_is_nop),
    .d_is_fwait    (d_is_fwait),
    .d_ea          (d_ea),
    .d_w           (d_w),
    .d_dst_high8   (d_dst_high8),
    .d_src_high8   (d_src_high8),
    .d_kind        (d_kind),
    .d_shrot       (d_shrot),
    .d_shift_cl    (d_shift_cl),
    .d_shift_one   (d_shift_one),
    .d_shift_imm   (d_shift_imm),
    .d_shrd        (d_shrd),
    .d_md          (d_md),
    .d_imul_3op    (d_imul_3op),
    .d_imul_imm    (d_imul_imm),
    .d_ext_signed  (d_ext_signed),
    .d_ext_srcw    (d_ext_srcw),
    .d_cc          (d_cc),
    .d_bit_imm     (d_bit_imm),
    .d_bit_op      (d_bit_op),
    .d_conv_cdq    (d_conv_cdq),
    .d_sm          (d_sm),
    .d_st          (d_st),
    .d_str_loadsi  (d_str_loadsi),
    .d_str_storedi (d_str_storedi),
    .d_str_scandi  (d_str_scandi),
    .d_ct          (d_ct),
    .d_ret_imm     (d_ret_imm),
    .d_cld         (d_cld),
    .d_std         (d_std),
    .d_clc         (d_clc),
    .d_stc         (d_stc),
    .d_cmc         (d_cmc),
    .d_cli         (d_cli),
    .d_sti         (d_sti),
    .d_cnt16       (d_cnt16),
    .d_br16        (d_br16),
    .d_io          (d_io),
    .d_lock        (d_lock),
    .d_io_write    (d_io_write),
    .d_io_imm      (d_io_imm),
    .d_io_port_imm (d_io_port_imm),
    .d_io_w        (d_io_w),
    .d_seg         (d_seg),
    .d_sysop       (d_sysop),
    .d_sys_sreg    (d_sys_sreg),
    .d_sys_creg    (d_sys_creg),
    .d_clts        (d_clts),          // REVIEW2 H-23
    .d_ljmp_off    (d_ljmp_off),
    .d_ljmp_sel    (d_ljmp_sel),
    .d_seg_load    (d_seg_load),
    .d_lseg        (d_lseg),
    .d_push_sreg   (d_push_sreg),
    .d_pop_sreg    (d_pop_sreg),
    .d_seg_load_lo (d_seg_load_lo),
    .d_store_sreg  (d_store_sreg),
    .d_xlat        (d_xlat),
    .d_callf_mem   (d_callf_mem),
    .d_jmpf_mem    (d_jmpf_mem),
    .d_pfx_seg_en  (d_pfx_seg_en),
    .d_pfx_seg_idx (d_pfx_seg_idx),
    .d_fxop        (d_fxop),
    .d_is_x87      (d_is_x87),
    .d_f_mem_read  (d_f_mem_read),
    .d_f_mem_write (d_f_mem_write),
    .d_f_msize     (d_f_msize),
    .d_f_mbytes    (d_f_mbytes),
    .d_f_pop       (d_f_pop),
    .d_f_pop2      (d_f_pop2),
    .d_f_sti       (d_f_sti),
    .d_f_aluop     (d_f_aluop),
    .d_f_const     (d_f_const)
  );


  // M7.1: syscall_active pulses for the S_DECODE clock that proxies an int-0x80.
  // The slow FSM reaches the d_halt/int-0x80 arm in S_DECODE; gating on
  // (state==S_DECODE && d_int80 && proxy_en) makes this exactly the clock the
  // proxy applies its effects, so the TB samples the same edge. 0 in all
  // non-proxy runs (proxy_en==0).
  assign syscall_active_c = (state==S_DECODE) && d_int80 && proxy_en;
  assign syscall_active   = syscall_active_c;

`ifdef VEN_FPTRAP
  // FP PS-trap outputs: high while stalled in S_FPTRAP_WAIT exposing ST0/ST1 to the PS.
  assign fptrap_active = (state==S_FPTRAP_WAIT);
  assign fptrap_st0    = fp_st[0];      // ST0 = x
`ifdef VEN_FP_PS_ALL
  // Expose the SECOND operand as ST(q_f_sti) for reg-form ops (FADD ST0,ST(i) /
  // FCOM ST(i) / FADDP ST(i),ST0). The implicit-ST1 ops (FCOMPP/FUCOMPP/FPATAN/
  // FYL2X/FYL2XP1) decode with q_f_sti==0, so fall back to ST1 there. No legitimate
  // op uses ST(0) as its second operand (that is ST0 itself), so this is unambiguous.
  assign fptrap_st1    = (q_f_sti != 3'd0) ? fp_st[q_f_sti] : fp_st[1];
`else
  assign fptrap_st1    = fp_st[1];      // ST1 = y
`endif
`ifdef VEN_FP_PS_ALL
  // Carry the full fxop identity so the PS knows which op to compute (FPATAN==FX_FPATAN
  // here, so the legacy 0-means-FPATAN handler still works once it switches on fxop).
  assign fptrap_op     = 7'(q_fxop);
  assign fptrap_mem    = f_mem80;
  assign fptrap_fctrl  = fctrl;
  assign fptrap_fstat  = fstat;
  assign fptrap_sti    = q_f_sti;
  assign fptrap_pop    = q_f_pop;
  assign fptrap_aluop  = q_f_aluop;
`else
  assign fptrap_op     = 7'd0;          // 0 = FPATAN (the only PS-trapped FP op)
`endif
`endif

  // M14: expose the syscall args (regfile values at the cd80 decode) so the TB
  // free-run emulator can read nr+args off the same edge as syscall_active. Pure
  // combinational reads of gpr (layout: eax ecx edx ebx esp ebp esi edi) — no
  // feedback into the core, inert in every replay/non-proxy run.
  assign syscall_arg_eax = gpr_o[0];
  assign syscall_arg_ecx = gpr_o[1];
  assign syscall_arg_edx = gpr_o[2];
  assign syscall_arg_ebx = gpr_o[3];
  assign syscall_arg_ebp = gpr_o[5];
  assign syscall_arg_esi = gpr_o[6];
  assign syscall_arg_edi = gpr_o[7];

  // ===========================================================================
  // M8.1 — external-interrupt ACCEPT predicates (combinational). These mirror the
  // exact priority of the S_DECODE divert (see below) so the `inta` strobe and the
  // sequential delivery agree on the SAME clock. ALL are 0 when soc_en==0, so the
  // core is byte-identical to the M0-M7 core.
  //
  // Priority at the instruction boundary: SMI# (smi_take) > NMI > maskable INTR.
  //   smi_take : the recognised SMI# the S_DECODE smi_pending block takes FIRST.
  //   nmi_take : an NMI edge, NON-maskable (ignores IF/irq_shadow), blocked only
  //              while an NMI handler is already running (nmi_in_progress) or by a
  //              pending SMI.
  //   intr_take: a maskable INTR — only when EFLAGS.IF=1, the one-instruction
  //              STI/MOV-SS shadow is clear (irq_shadow=0), and neither a higher-
  //              priority NMI nor SMI is being taken this boundary. (NMI in progress
  //              does NOT mask INTR — the IA-32 NMI block applies to NMI only.)
  // The level INTR / NMI edge are sampled into intr_pending / nmi_pending (the
  // sequential block) exactly like smi_pending, then consumed here.
  // ===========================================================================
  logic smi_take, nmi_take, intr_take;
  assign smi_take  = smi_pending && sys_mode && !smm_active;
  assign nmi_take  = soc_en && nmi_pending && !nmi_in_progress && !smi_take;
  assign intr_take = soc_en && intr_pending && eflags[9] && !irq_shadow
                     && !nmi_take && !smi_take;
  // INTERRUPT-ACKNOWLEDGE strobe: pulse for exactly the S_DECODE clock the core
  // accepts a maskable INTR (the PIC drives inta_vector combinationally off this).
  // NMI carries the fixed vector 2 and does NOT pulse inta. 0 whenever soc_en==0.
`ifdef VEN_SYS_FASTPATH
  // task #57: the fast path now accepts INTR at S_PIPE instruction boundaries, so the
  // PIC's acknowledge must pulse from there too -- otherwise the 8259 never sees the
  // INTA, never advances its ISR, and the vector is delivered forever.
  assign inta = (((state==S_DECODE) || (state==S_HLTWAIT)) && intr_take && !dbg_block_issue)
              || ((state==S_PIPE) && fp_irq_divert && intr_take);
`else
  assign inta = ((state==S_DECODE) || (state==S_HLTWAIT)) && intr_take && !dbg_block_issue;
`endif

  // ===========================================================================
  // Latched decoded fields
  // ===========================================================================
  logic [3:0]  q_len;
  logic        q_is_branch, q_branch_taken;
  logic [31:0] q_rel;
  logic [4:0]  q_alu_op;
  logic        q_writes_reg, q_writes_flags, q_mem_read, q_mem_write, q_mem_dst;
  logic [2:0]  q_dst_reg, q_src_reg;
  logic [31:0] q_imm;
  logic        q_use_imm, q_is_push, q_is_pop, q_is_lea, q_is_mov;
  logic [31:0] q_ea, q_pc;
  logic [2:0]  q_w;
  logic        q_dst_high8, q_src_high8;
  // CMPXCHG (0F B0/B1) mem-form: latched equality decision. Computed in S_EXEC
  // (before the conditional accumulator update mutates EAX) and consumed in
  // S_STORE's store-operand resolution, so the write data stays stable across
  // the S_EXEC->S_STORE clock even though gpr_o[R_EAX] changes on the not-equal
  // path. 1 => store src (equal); 0 => write the original temp back unchanged.
  logic        cmpxchg_wrsrc_r;
  kind_e       q_kind;
  logic [2:0]  q_shrot;
  logic        q_shift_cl, q_shift_one;
  logic [4:0]  q_shift_imm;
  logic        q_shrd;
  logic [2:0]  q_md;
  logic        q_imul_3op;
  logic [31:0] q_imul_imm;
  logic        q_ext_signed;
  logic [2:0]  q_ext_srcw;
  logic [3:0]  q_cc;
  logic        q_bit_imm;
  logic [2:0]  q_bit_op;
  logic        q_conv_cdq;
  smk_e        q_sm;
  st_e         q_st;
  logic        q_rep, q_repne, q_str_loadsi, q_str_storedi, q_str_scandi;
  // M7.3c INS: the IN value captured in S_INS, carried into the S_STORE element.
  logic [31:0] ins_data;
  ctk_e        q_ct;
  logic [15:0] q_ret_imm;
  logic        q_cld, q_std;
  logic        q_clc, q_stc, q_cmc;
  logic        q_cli, q_sti;
  logic        d_clts, q_clts;   // REVIEW2 H-23: CLTS (0F 06)
  logic        q_cnt16;
  logic        q_br16;   // M7.3b: 16-bit near-branch (taken target masks to 16 bits)

  // latched M7.3b IN/OUT port-I/O decode (see d_io_* above). q_io_port holds the
  // resolved 16-bit port (imm8 zero-extended, or DX[15:0]); q_io_w the width.
  logic        q_io;
  logic        q_io_write;
  logic [15:0] q_io_port;
  logic [2:0]  q_io_w;

  // latched M2S.1 system decode
  sysop_e      q_sysop;
  logic [2:0]  q_sys_sreg, q_sys_creg, q_seg;
  logic        q_pfx_seg_en;   // executing insn HAD a segment-override prefix (clean: set only by 26/2E/36/
                               // 3E/64/65 in the prefix decoder, NOT by the BP->SS default in the addressing
                               // block — so it distinguishes a real SS override from BP-ModRM contamination).
  logic [31:0] q_ljmp_off;
  logic [15:0] q_ljmp_sel;
  logic        q_seg_load;        // M9.5 LES/LDS/LSS/LFS/LGS: also load a seg reg
  logic [2:0]  q_lseg;            //   target segment register index for the seg-load
  logic        q_push_sreg;       // F3 PUSH sreg latch
  logic        q_pop_sreg;        // F3 POP sreg latch
  logic        q_seg_load_lo;     // F3 MOV Sreg,[mem] low-half seg-load latch
  logic        q_store_sreg;      // F3 MOV [mem],Sreg store-selector latch
  // PM memory-source MOV Sreg: S_EXEC latches the loaded selector here + sets
  // q_seg_from_mem so S_SEGLD walks the descriptor for it (target = q_lseg).
  logic        q_seg_from_mem;    // S_SEGLD selector source = seg_mem_sel (not a GPR)
  logic [15:0] seg_mem_sel;       //   the selector loaded from memory
  logic        q_xlat;            // XLATB latch (AL <- [DS:(E)BX + AL])
  logic        q_callf_mem;       // F3 FF /3 CALLF m16:16 latch
  logic        q_jmpf_mem;        // F3 FF /5 JMPF  m16:16 latch
  logic        seg_step;          // SEGLD descriptor-fetch beat counter (0/1)
  // bug#6 CALL GATE: set when S_LJMP re-vectored through a call gate, so the second
  // descriptor pass knows the transfer arrived via a gate. That changes the CPL rule
  // (a gate selector's RPL is NOT the new privilege) and enables the cross-privilege
  // check — see core_seg_ljmp.svh.
  logic        gate_via;
  logic [31:0] retf_off;          // M9.5 RETF: the popped IP/EIP held between beats
  logic [31:0] gdt_lo;            // first dword of the in-flight 8-byte descriptor

  // -------------------------------------------------------------------------
  // M2S.3 IDT delivery state (latched when a fault/INT vectors). The delivery
  // micro-sequence (S_INT_GATE -> S_INT_CS -> S_INT_PUSH) reads the gate, reads
  // the target CS descriptor, and pushes the exception frame, then loads
  // CS:EIP. The frame is pushed at the gate's target privilege stack (here:
  // same-privilege, so the current SS:ESP — cross-priv stack switch via TSS is
  // M2S.4). All of this is INERT when !sys_mode.
  // -------------------------------------------------------------------------
  // ===========================================================================
  // M2S.6 DEBUG REGISTERS + #DB (docs/m2s6-debug-spec.md). ALL of this is INERT
  // when !sys_mode: the DR file is never written (MOV DRn is a SLOW-FSM-only
  // sys op), the #DB delivery latches never arm, and TF/RF are only inspected on
  // a system-mode core. User mode (boot_mode=0) is byte-identical.
  //
  // DR0..DR3 = linear breakpoint addresses; DR6 = debug status (B0..B3, BD, BS,
  // BT + the 0xFFFF0FF0 reserved-1 read pattern); DR7 = control (Ln/Gn enables,
  // LE/GE, GD, the R/Wn 2-bit type + LENn 2-bit length per breakpoint). DR4/DR5
  // alias DR6/DR7 when CR4.DE=0. Reset (Vol.3): DR6=0xFFFF0FF0, DR7=0x00000400.
  // ===========================================================================
  logic [31:0] dr0, dr1, dr2, dr3;   // linear breakpoint addresses
  logic [31:0] dr6;                  // debug status (sticky B0..B3/BD/BS/BT)
  logic [31:0] dr7;                  // debug control (Ln/Gn, R/Wn, LENn, GD)
  // DR6/DR7 reserved-bit fixed patterns (P5 Vol.3). On WRITE the CPU forces these
  // reserved-1 bits; the read-back therefore always carries them. In 32-bit mode
  // qemu's DR_RESERVED_MASK (upper 32 bits) never bites, so all 32 bits writable.
  localparam logic [31:0] DR6_FIXED_1 = 32'hFFFF_0FF0;   // DR6 reserved-1 pattern
  localparam logic [31:0] DR7_FIXED_1 = 32'h0000_0400;   // DR7 bit10 reserved-1
  // DR6 status-bit positions.
  localparam int DR6_B0 = 0, DR6_B1 = 1, DR6_B2 = 2, DR6_B3 = 3;
  localparam int DR6_BD = 13, DR6_BS = 14;
  // DR7.GD (general-detect) lives at bit 13 (mirrors DR6.BD).
  localparam int DR7_GD = 13;

  // ---- #DB delivery model (M2S.6). A #DB raised as a CONSEQUENCE of an
  // instruction (TF single-step = DR6.BS, a data breakpoint = DR6.Bn, or an
  // instruction breakpoint hit on the committed next-EIP = DR6.Bn) is launched
  // FROM that instruction's RETIRE boundary via arm_db(): the qemu gdbstub
  // single-step fuses the instruction and its synchronous #DB into ONE record
  // (the instruction's PC + the post-delivery state), so the instruction does NOT
  // emit a separate retire — arm_db() diverts straight to the IDT delivery FSM.
  // ---- TF / RF issue-time snapshot. The #DB checks run at the triggering
  // instruction's RETIRE boundary, but must use the flags the instruction RAN
  // UNDER (sampled at its S_DECODE dispatch), not the post-modified ones — so a
  // POPF that SETS TF does not itself step-trap (the trap fires after the NEXT
  // instruction). RF (bit16) suppresses an instruction breakpoint for exactly one
  // instruction; the CPU clears it once that instruction retires (we clear it at
  // S_DECODE so the post-retire EFLAGS shows RF=0, matching qemu's
  // x86_debug_check_breakpoint behaviour).
  logic        tf_at_issue;       // TF the in-flight instruction runs under
  logic        rf_at_issue;       // RF the in-flight instruction runs under (suppress)
  // ---- Data-watchpoint extra-record flag. The qemu gdbstub single-step emits an
  // EXTRA record for a DATA breakpoint #DB: after the delivery record (stamped at
  // the store's PC, post-frame-push), it re-reports the SAME state stamped at the
  // HANDLER entry PC (the resumption point, BEFORE the handler's first instruction
  // runs), then the handler proceeds. (Instruction-bp / TF traps do NOT do this.)
  // Set when arm_db is launched for a data-write breakpoint; consumed in
  // S_INT_PUSH -> S_DB_EXTRA to emit that one extra fused-resumption record.
  logic        db_wp_extra;       // emit the data-watchpoint handler-entry record
  // ---- M6B Erratum 79 (errata_en[ERR_DBGP], default OFF). When a V86 POPF/IRET
  // #GP(0)-traps at IOPL<3 (the IOPL guard below) AND a DATA breakpoint is armed
  // on the SS:ESP linear address, the affected stepping ERRONEOUSLY delivers a
  // #DB right after the #GP handler is entered, with the saved CS:EIP = the #GP
  // handler's first instruction. We latch `err79_pending` + the matched DR6.Bn
  // bits at the IOPL guard; the #GP delivery's S_INT_PUSH final beat then CHAINS
  // an arm_db() (saved CS:EIP = int_gate_off = the #GP handler entry) instead of
  // returning to S_PIPE. INERT unless errata_en[ERR_DBGP] is set (so make verify
  // + every sys gate is byte-identical). It also requires v86 — which is 0 on the
  // entire non-V86 corpus — so even ON it is dead outside a V86 task.
  logic        err79_pending;     // chain an erroneous #DB after this V86 #GP
  logic [3:0]  err79_dr6_bits;    // the SS:ESP data-bp DR6.Bn bits that "fire"
  // GD general-detect FIRING is DEFERRED (documented). qemu 8.2.2 does NOT model
  // DR7.GD, so the committed pdebug golden takes EXACTLY 3 #DB deliveries. Firing
  // GD here would make the RTL take a 4th #DB the golden lacks -> the differential
  // diff would DIVERGE, and there is no TB hook to run a separate GD-enabled
  // structural trace. So the GD DECISION is computed below but its #DB fire is held
  // behind this default-off localparam (a future structural self-check can flip it
  // for an RTL-only trace, the psmm precedent). See StructuredOutput "deferred".
  localparam logic DBG_GD_ENABLE = 1'b0;

  logic [7:0]  int_vec;           // the vector being delivered (0..255)
  logic [31:0] int_ret_eip;       // EIP to PUSH (faulting EIP for a FAULT, next
                                  // EIP for a TRAP / software INT)
  logic [31:0] int_src_pc;        // the q_pc to stamp on the delivery retire
                                  // record (the faulting/INT instruction's PC)
  logic        int_has_err;       // push a 32-bit error code for this vector
  logic [31:0] int_err;           // the error code value (selector / #PF bits)
  logic [3:0]  int_step;          // beat counter within S_INT_GATE/_CS/_PUSH
                                  // (4-bit: the M7.2 V86 push needs 10 beats 0..9)
  // A real-mode IVT/IRET read may immediately follow an acknowledged fetch or
  // the preceding stack word on the shared memory response seam. Keep the new
  // request absent for one clock before accepting a response at its new address;
  // otherwise a lingering ack/data window can be consumed as the IVT/stack word.
  logic        rm_read_armed;
  logic [31:0] int_gate_off;      // assembled handler offset from the IDT gate
  logic [15:0] int_gate_sel;      // gate's code selector
  // REVIEW2_aug2 C-06 (descriptor half): the far-CALL target's validated CS, STAGED.
  // A protected far CALL used to push its return frame FIRST and validate the target
  // descriptor afterwards in S_LJMP, so a rejected descriptor faulted with CS:next_eip
  // already on the stack. SYS_LCALL now runs S_LJMP in a NO-COMMIT pass that validates
  // everything (present / code / DPL / conforming / gate resolution / offset vs limit),
  // parks the result here, and only then goes to S_LCALL to push and commit.
  logic        ntret_pend;
  // REVIEW2_aug2 C-06: a far RETF to an OUTER privilege level. retf_out marks the
  // pop-and-validate sequence in flight; retf_ob is its extra-beat counter (0=ESP,
  // 1=SS). retf_out stays set through S_INT_CS_RET/S_IRET_SS so the shared commit
  // can tell a RETF from an IRET -- see the NMI note there.
  logic        retf_out, retf_ob;
  // REVIEW_Aug3 H-02: a same-privilege PROTECTED RETF must be restartable. ESP used
  // to advance on the CS-pop acknowledgement (core_gpr_wb.svh), BEFORE the popped
  // target reached S_LJMP and was validated -- so a null, out-of-bounds, non-code,
  // non-present, wrong-privilege, or offset-past-limit target faulted with ESP
  // already moved and the frame already consumed. The advance is now STAGED at the
  // beat-1 handoff (retf_same / retf_esp_adj) and fires only on retf_commit_w --
  // the S_LJMP pass accepting the target (the iret_cs_commit pattern: one shared
  // commit predicate consumed by both the FSM arm and the ESP writeback).
  logic        retf_same;
  logic [31:0] retf_esp_adj;
  logic [63:0] retf_desc_w;
  logic [7:0]  retf_attr_w;
  logic        retf_commit_w;
  assign retf_desc_w = {mem_rdata, gdt_lo};
  assign retf_attr_w = desc_attr(retf_desc_w);
  // The commit condition mirrors the S_LJMP final (code-descriptor) arm exactly,
  // for the case retf_same names: present/code/privilege-validated by
  // seg_load_fault, and the popped offset within the target limit. A RETF never
  // sets gate_via or lcall_pend, so the gate branches cannot intervene.
  // REVIEW1_Aug3 R2-C01: include the new DPL/RPL matrix -- without it the staged
  // ESP advance would fire on a target the FSM now rejects.
  assign retf_commit_w = (state == S_LJMP) && mem_ack && seg_step && retf_same
                      && desc_s(retf_attr_w)
                      && !seg_load_fault(1'b1, 1'b0, q_ljmp_sel, retf_attr_w, cpl_r)
                      && (retf_attr_w[2] ? (desc_dpl(retf_attr_w) <= cpl_r)
                                         : (desc_dpl(retf_attr_w) == q_ljmp_sel[1:0]))
                      && ({1'b0, q_ljmp_off} <= {1'b0, desc_limit(retf_desc_w)});
  // REVIEW2_aug2 C-06 (call-gate half): this cross-privilege delivery is a far CALL
  // through a call gate, not an interrupt. It reuses S_INT_TSS/S_INT_SS/S_INT_PUSH,
  // and cg_xpl is what tells those shared states the things that differ:
  // the frame has NO EFLAGS word and EFLAGS is not masked on entry.
  // REVIEW1_Aug3 R2-H05: the frame is (4 + cg_pcount) slots in cg_wide units --
  // 16 bytes for the legacy 32-bit, zero-param case.
  logic        cg_xpl;
  // The gate's PARAMETER COUNT (descriptor high dword bits [4:0]). Captured when the
  // gate is resolved, because by the time the cross-privilege arm runs the descriptor
  // being examined is the TARGET CS, not the gate.
  logic [4:0]  cg_pcount;
  // REVIEW1_Aug3 R2-H05: the gate's WIDTH (1 = 32-bit gate, desc type 4'hC; 0 =
  // 16-bit, type 4'h4), staged for the same reason as cg_pcount. A 16-bit gate
  // builds a WORD-unit frame (SS, SP, params, CS, IP) regardless of the caller's
  // operand size or the target's D bit.
  logic        cg_wide;
  // R2-H05: parameter copy. The caller-stack params are read into this buffer by
  // S_CG_PRD BEFORE the staged SS/CPL commit (so a faulting source read is
  // delivered in the old context with nothing written), then S_INT_PUSH's cg_xpl
  // beats store them. cg_beat counts the cg_xpl frame beats (max 4+31 = 35, too
  // wide for int_step[3:0]).
  logic [31:0] cg_params [31];
  logic [5:0]  cg_beat;
  logic        lcall_pend;      // 1 = this S_LJMP pass is the far CALL's probe
  // REVIEW_Aug3 C-04: the far-transfer KIND must be explicit. The shared S_LJMP
  // lost two distinctions: a far CALL to an available TSS ran the JMP task-switch
  // form (no back-link, no NT, outgoing busy CLEARED -- breaking nested-task
  // return), and a far JMP through a call gate to a more privileged target entered
  // the CALL stack-switch path and pushed a return frame. tsw_call latches "this
  // task switch is a CALL" from lcall_pend at the TSS-descriptor beat: S_TSW_BUSY
  // then writes the outgoing TR selector into the incoming TSS back-link, leaves
  // the outgoing descriptor BUSY, and the commit sets NT in the incoming EFLAGS
  // image. (The review's full XFER_* enum replacing every boolean is the structural
  // direction; the kind is made explicit at the decision points it affects.)
  logic        tsw_call;
  logic [31:0] lc_cs_base, lc_cs_limit;
  logic [7:0]  lc_cs_attr;
  logic        lc_cs_d;
  logic [1:0]  lc_cs_cpl;
  // REVIEW1_Aug3 R2-H05: a SAME-PRIVILEGE far CALL through a call gate pushes
  // its return frame in the GATE's width, not the caller's operand size (QEMU
  // helper_lcall_protected: PUSHW/PUSHL follow shift = gate type). gate_via is
  // cleared at the probe->S_LCALL handoff, so park both bits with lc_cs_*.
  logic        lc_gate;
  logic        lc_gw;
  // The one S_LCALL push width, shared by the bus arm, the cur_lin mirror and
  // the ESP writeback (CHECK 5 territory -- define once). seg_real far CALLs
  // never pass a gate; lc_gate is stale there and qualified out.
  logic [2:0]  lc_callw;
  assign lc_callw = (!seg_real && lc_gate) ? (lc_gw ? 3'd4 : 3'd2) : q_w;
  // REVIEW2_aug2 C-03 (first bullet): the target CS HIDDEN state, STAGED. S_INT_CS
  // used to write seg_base/limit/attr[SG_CS] and cs_d the instant the descriptor was
  // accepted, so every later step of a cross-privilege delivery -- the TSS bound
  // check, the new-SS validation, and the frame push itself, any of which can fault --
  // ran with the handler's CS already installed. These hold it until the delivery is
  // committed alongside eip at the end of S_INT_PUSH. Same device as iret_cs_*.
  // (The SELECTOR needs no new register: int_gate_sel already carries it.)
  logic [31:0] int_cs_base;
  logic [31:0] int_cs_limit;
  logic [7:0]  int_cs_attr;
  logic        int_cs_d;
  // REVIEW1_Aug3 R2-C04: the STAGED new-stack context for a cross-privilege (or
  // V86-entry) delivery. S_INT_SS validates the new SS descriptor and parks the
  // result here; S_INT_PROBE then pre-probes the COMPLETE frame extent (both
  // pages when it straddles) before seg_*[SG_SS]/ss_b/cpl_r are installed and
  // S_INT_PUSH writes. A page fault on any frame word can therefore no longer
  // observe new SS/CPL with old CS/EIP and a partially written frame.
  logic [31:0] int_ss_base, int_ss_limit;
  logic [7:0]  int_ss_attr;
  logic        int_ss_b;
  // The frame-slot plan. One plan serves the probe sequencer, the push-address
  // mirror and the ESP writeback, so a frame's shape cannot drift among
  // formulas: slot k sits at offset (esp - (k+1)*unit), wrapped by the staged
  // stack's B bit; nslots/wide are latched at staging (S_INT_SS) from the frame
  // kind. A frame that wraps its SP window occupies TWO offset chunks, and
  // because SS.base need not be page aligned each chunk can itself straddle a
  // page -- up to four distinct pages for a <= 140-byte frame. S_INT_PROBE
  // walks the slots in push order and probes every distinct page BEFORE the
  // staged context commits (the old first/last-offset probe missed the middle
  // pages of a wrapped layout).
  logic [5:0]  int_frm_nslots;   // frame slots (header + params + errcode)
  logic        int_frm_wide;     // slot unit: 1 = dword, 0 = word
  // The frame PAGE plan: the distinct pages the (possibly wrapped) layout
  // touches, in push order, deduplicated -- at most four for any current
  // frame shape (two offset chunks, each a contiguous linear range < 145
  // bytes, each spanning at most two pages). S_INT_PROBE validates each page
  // ONCE and captures its physical frame; the D-mark phase then sets Dirty
  // pre-commit where a clean page needs it; and S_INT_PUSH translates through
  // the captured frames -- so no post-commit walk (hence no post-commit
  // fault) is possible. Probing alone could not promise that: the two chunks
  // of a wrapped 16-bit frame sit ~64 KiB apart and share a direct-mapped
  // DTLB index, so a later probe could evict an earlier proof.
  logic [19:0] frm_pg_lin   [4];   // linear page numbers (push order)
  logic [31:0] frm_pg_addr  [4];   // probe address per entry (CR2 fidelity)
  logic [19:0] frm_pg_phys  [4];   // captured physical frame
  logic [3:0]  frm_pg_val;         // entry valid
  logic [3:0]  frm_pg_mid;         // entry is a page-base probe (extent covered by the preceding slot-start entry)
  logic [3:0]  frm_pg_dirty;       // entry's mapping had D=1 at validation
  logic [2:0]  frm_pg_n;           // distinct page count (1..4)
  logic [2:0]  frm_pg_i;           // S_INT_PROBE: entry under proof/mark
  logic        frm_pg_markd;       // phase D (marking clean pages), not validation
  // Slot k's offset under the staged SP/B. Push order is slot 0 first
  // (highest offset). The mask is the stack window: 16-bit stacks wrap at
  // 64 KiB, 32-bit stacks wrap naturally at 4 GiB.
  function automatic logic [31:0] frm_slot_off(input logic [31:0] esp,
                                               input logic [5:0]  k,
                                               input logic        wide,
                                               input logic        b32);
    logic [31:0] raw;
    raw = esp - (({26'd0, k} + 32'd1) << (wide ? 2 : 1));
    frm_slot_off = b32 ? raw : {16'd0, raw[15:0]};
  endfunction
  logic        int_gate_trap;     // 1 = trap gate (leave IF), 0 = interrupt gate
  logic        int_gate_op16;     // 1 = 16-bit gate/IRET (6-byte IP:CS:FLAGS frame,
                                  // 2-byte slots, ESP +/-6); 0 = 32-bit (the legacy
                                  // path). Set from the IDT gate SIZE bit (gattr[3]:
                                  // 0x6/0x7 = 16-bit) on a gated INT delivery, or from
                                  // the IRET's effective operand size (eff_opsize) on
                                  // an IRET. Only the SAME-PRIV push/pop arm honours it.
  // REVIEW_Aug4 A4-H03: ONE frame-width decision for the whole delivery. It comes
  // from the GATE TYPE (int_gate_op16) alone -- never the caller's code size and
  // never SS.B (a 16-bit gate onto a 32-bit TSS stack still pushes a WORD frame).
  // V86 frames are always dword. Every consumer -- the probe extent, the cur_lin
  // slot addresses, the push strobes/data, the ESP writeback, and the final
  // frame size -- keys on this one wire (the call gate's own width is cg_wide).
  logic        int_frm16;
  assign int_frm16 = int_gate_op16 && !from_v86;
  // ---- REVIEW_aug2 H-04: delivery-depth escalation (#DF and shutdown) ---------
  // There was NO delivery-depth state at all. start_fault() could re-vector an
  // IDT-limit failure and S_INT_GATE could re-vector bad gate attributes, but each
  // was a documented "single re-vector", so a fault while delivering a fault just
  // started another ordinary delivery. Measured on a real image (verif/sys/tests/
  // ppriv before soc_en was understood): an undefined opcode with an empty IDT gave
  //     [FAULT] vec=6  err=00000000   (#UD)
  //     [FAULT] vec=11 err=00000032   (IDT[6] not present  -> #NP, 6*8+2)
  //     [FAULT] vec=11 err=0000005A   (IDT[11] not present -> #NP, 11*8+2)
  //     [FAULT] vec=11 err=0000005A   ... forever
  // A real CPU raises #DF at the second one and shuts down at the third.
  //
  //   dlv_depth 0 = not delivering, 1 = delivering an exception, 2 = delivering #DF.
  // IA-32 6.15 Table 6-5: escalate to #DF when a CONTRIBUTORY fault arrives during
  // delivery of a contributory one, or when a page fault arrives during delivery of
  // a page fault or of a contributory one. Everything else (benign, and software
  // INT n) nests normally, which is why the class of what is CURRENTLY being
  // delivered has to be tracked, not merely the fact that a delivery is in flight.
  logic [1:0] dlv_depth;
  logic       dlv_ctrb;   // what we are delivering is CONTRIBUTORY
  logic       dlv_pf;     // ...or is a page fault
  function automatic logic vec_contributory(input logic [7:0] v);
    // #DE(0), #TS(10), #NP(11), #SS(12), #GP(13). #DF itself is handled by depth.
    vec_contributory = (v==8'd0) || (v==8'd10) || (v==8'd11) || (v==8'd12) || (v==8'd13);
  endfunction

  logic        int_sw;            // delivery is a SOFTWARE INT n/INT3/INTO (the
                                  // gate DPL>=CPL privilege check applies; HW
                                  // faults / external INTs bypass it)
  // The error-code EXT bit's event class, latched at the delivery origin:
  // 1 only while the delivered event is an EXTERNAL interrupt (NMI/INTR); 0 for
  // software INT and every synchronous exception, including a fault raised
  // while delivering an earlier one (no inheritance). int_sw's "not software
  // INT" is NOT this bit -- a synchronous #UD/#DE/#GP is not an external event
  // (P5 SDM: EXT marks events such as NMI or INTR).
  logic        dlv_ext;
  logic [31:0] int_lo;            // first dword of the in-flight 8-byte gate/desc
  logic [31:0] iret_eip;          // IRET-popped EIP (held until ESP/CS settle)
  logic [15:0] iret_cs;           // IRET-popped CS selector
  logic [31:0] iret_eflags;       // IRET-popped EFLAGS (held until SS/ESP settle)
  // M2S.4 cross-privilege delivery scratch. When the target CS.DPL < CPL the
  // delivery loads SS:ESP from TSS.ssN:espN (N = target DPL) and pushes the
  // LARGER 5-word frame (old SS, old ESP, EFLAGS, CS, EIP[, errcode]) on the NEW
  // stack. xpl_active marks the in-flight delivery as cross-privilege so the
  // S_INT_PUSH frame layout + ESP math switch to the larger form.
  logic        xpl_active;        // this delivery is cross-privilege (stack switch)
  logic [15:0] int_old_ss;        // the interrupted task's SS (pushed in the frame)
  logic [31:0] int_old_esp;       // the interrupted task's ESP (pushed in the frame)
  logic [15:0] int_old_cs;        // the interrupted task's CS (pushed in the frame)
  // M7.2 V86 delivery scratch. from_v86 marks an in-flight delivery whose SOURCE
  // was V86 (EFLAGS.VM was set when the fault/INT fired). It is latched at delivery
  // start (S_INT_CS, where the cross-priv decision is made) so the S_INT_PUSH frame
  // switches to the 9-WORD V86 layout (GS,FS,DS,ES,SS,ESP,EFLAGS,CS,EIP) and, on
  // the final beat, EFLAGS.VM is cleared + DS/ES/FS/GS are zeroed (IA-32 V86 entry
  // to a PM handler). The interrupted V86 segment selectors are frozen for the push.
  logic        from_v86;          // this delivery's source was V86 (9-word frame)
  logic [15:0] int_old_ds, int_old_es, int_old_fs, int_old_gs;  // V86 frame segs
  logic [31:0] int_old_eflags;    // the V86 EFLAGS image pushed (VM still set)
  logic [1:0]  int_new_cpl;       // target privilege level (= target CS.DPL)
  logic [15:0] int_new_ss;        // new SS selector from TSS.ssN
  logic [31:0] int_new_esp;       // new ESP from TSS.espN
  // The rare cross-privilege frame page plan is deliberately sequential.  Its
  // completion is copied into the existing probe/push contract before any
  // staged context becomes architectural state.
  logic        frame_plan_start, frame_plan_busy, frame_plan_done;
  logic [19:0] frame_plan_lin [4];
  logic [31:0] frame_plan_addr [4];
  logic [3:0]  frame_plan_val, frame_plan_mid;
  ven_frame_plan u_frame_plan (
      .clk(clk), .rst_n(rst_n), .start(frame_plan_start),
      .stack_base(int_ss_base), .stack_ptr(int_new_esp),
      .stack_b32(int_ss_b), .wide(int_frm_wide), .nslots(int_frm_nslots),
      .busy(frame_plan_busy), .done(frame_plan_done),
      .page_lin(frame_plan_lin), .probe_addr(frame_plan_addr),
      .page_valid(frame_plan_val), .page_mid(frame_plan_mid)
  );
  // M2S.4 inter-privilege IRET scratch. When the IRET-popped CS.RPL > current
  // CPL the return is to a LESS-privileged level: additionally pop ESP/SS, switch
  // to the outer stack, and null any data segment not accessible at the new CPL.
  logic        iret_interpriv;    // this IRET returns to a lower privilege
  logic [15:0] iret_ss;           // IRET-popped SS selector (inter-priv)
  logic [31:0] iret_esp;          // IRET-popped ESP (inter-priv)

  // ---- REVIEW_aug2 C-07: whole-frame IRET commit -----------------------------
  // An inter-privilege IRET used to commit its frame in three separate places, in
  // the order the bytes happened to arrive: EIP/EFLAGS/ESP at S_IRET beat 4, CS in
  // S_INT_CS_RET, SS in S_IRET_SS. So a frame whose SS was bad had ALREADY installed
  // a new EIP, EFLAGS and CS (i.e. a new CPL) by the time anyone looked at the SS --
  // the fault was raised from a half-updated architectural state, which is both
  // wrong and the more dangerous half (CPL had already dropped).
  //
  // Now the CS descriptor is STAGED here instead of installed, and every part of the
  // frame commits at ONE point: the success branch of S_IRET_SS. Nothing architectural
  // moves until the whole frame has been validated.
  logic [31:0] iret_cs_base, iret_cs_limit;
  logic [7:0]  iret_cs_attr;
  logic        iret_cs_d;

  // ONE definition of "the outer SS descriptor on the bus this cycle is acceptable",
  // consumed by the FSM commit (core_iret.svh) AND the ESP writeback
  // (core_gpr_wb.svh). These are two different always blocks; giving each its own
  // copy of the rule is exactly the mirror-drift that produced the C-05 family of
  // bugs, so the predicate is written once, here.
  //   desc = {mem_rdata, int_lo}  =>  access byte (desc[47:40]) = mem_rdata[15:8].
  logic [7:0] iret_ss_attr_w;
  logic       iret_ss_present, iret_ss_wellformed, iret_ss_ok, iret_ss_commit;
  assign iret_ss_attr_w  = mem_rdata[15:8];
  assign iret_ss_present = iret_ss_attr_w[7];
  // Everything EXCEPT presence. The SDM checks P last, so a descriptor that is both
  // not-present AND malformed some other way is #GP, not #SS; splitting the predicate
  // here is what makes the vector choice in core_iret.svh order-faithful without
  // sequencing the checks.
  assign iret_ss_wellformed = (iret_ss[15:2] != 14'd0)      // not the null selector
                   &&  iret_ss_attr_w[4]                     // S=1 (not a system descriptor)
                   && !iret_ss_attr_w[3]                     // type[3]=0 => DATA, not code
                   &&  iret_ss_attr_w[1]                     // type[1]=1 => WRITABLE
                   && (iret_ss[1:0]        == iret_cs[1:0])  // SS.RPL == return CPL
                   && (iret_ss_attr_w[6:5] == iret_cs[1:0]); // SS.DPL == return CPL
  assign iret_ss_ok = iret_ss_wellformed && iret_ss_present;

  // ---- REVIEW1_Aug2 C-06: the SAME-PRIVILEGE return needs the same treatment ----
  // C-07 staged the inter-privilege frame, but the same-privilege path still wrote EIP
  // and EFLAGS at S_IRET beat 2 and advanced ESP by 6/12 on that clock, while CS was
  // not read or validated until S_INT_CS_RET. A frame carrying a null, non-code,
  // wrong-privilege or not-present CS therefore faulted with EIP already redirected to
  // the rejected target, EFLAGS already replaced by the popped image, and ESP already
  // past the frame -- not restartable, and exactly the atomicity failure C-07 removed
  // from the other path.
  //
  // Same shape as iret_ss_ok: written ONCE here because the FSM arm and the ESP
  // writeback are different always blocks. The rule is the CS-return validation that
  // already lived in S_INT_CS_RET, lifted out verbatim.
  // ---- REVIEW1_Aug2 H-01: a selector must be INSIDE its descriptor table ---------
  // IRET read the popped CS/SS descriptor without ever consulting gdt_limit/ldt_limit,
  // so a selector past the end of the table read arbitrary memory AS a descriptor --
  // and then validated whatever came back. The check has to happen BEFORE the read,
  // not as another term in iret_cs_ok/iret_ss_ok, because the read itself is the
  // defect. A descriptor occupies sel[15:3]*8 .. +7, so its last byte must be <= limit.
  // REVIEW2_aug2 H-07: every FAR-TRANSFER selector dereference needs the same
  // null/TI/table-limit test before the descriptor read is issued. The dispatch arm
  // for SYS_LJMP had it (H-02) and the call gate's embedded target got it, but far
  // CALL and RETF reach S_LJMP after stack activity and were still unguarded, so a
  // selector past the table end read arbitrary memory AS a descriptor -- and under
  // paging that read can take a #PF, delivering the wrong exception ahead of the
  // architecturally prior #GP. Named once here so the four remaining entries into
  // S_LJMP cannot drift apart. sel_in_table() already picks LDT vs GDT off TI; the
  // null test is separate because a null selector indexes offset 0, which is inside
  // any non-degenerate table and therefore passes the bounds test.
  function automatic logic sel_in_table(input logic [15:0] sel);
    sel_in_table = ({16'd0, sel[15:3], 3'd7} <=
                    {17'd0, (sel[2] ? ldt_limit : gdt_limit)});
  endfunction

  // REVIEW_Aug3 C-02: same bounds test but against an EXPLICITLY supplied LDT limit
  // instead of the live one. The task-switch segment reload (S_TSW_SEG) validates
  // the INCOMING task's TI=1 selectors while the incoming LDT is still staged --
  // the live ldt_limit there is the OUTGOING task's, so sel_in_table() would bound
  // the new task's selectors against the old task's table.
  function automatic logic sel_in_table_st(input logic [15:0] sel,
                                           input logic [15:0] ldt_lim);
    sel_in_table_st = ({16'd0, sel[15:3], 3'd7} <=
                       {17'd0, (sel[2] ? ldt_lim : gdt_limit)});
  endfunction

  // REVIEW2_aug2 H-08: which TSS types may be switched TO. A far JMP/CALL may target
  // only an AVAILABLE TSS (0x9); an IRET-with-NT task RETURN targets its back-link,
  // which is necessarily BUSY (0xB). Stated once so the three S_LJMP arms that test it
  // cannot drift apart.
  function automatic logic tsw_type_ok(input logic [7:0] a, input logic ntret);
    tsw_type_ok = (desc_type(a) == 4'h9) || (ntret && (desc_type(a) == 4'hB));
  endfunction

  // REVIEW1_Aug3 R2-C02: null is index 0 AND TI=0 (is_null_selector); a TI=1
  // index-0 selector names LDT entry 0 and is bounded against the LDT like any
  // other selector.
  function automatic logic far_sel_bad(input logic [15:0] sel);
    far_sel_bad = is_null_selector(sel) || !sel_in_table(sel);
  endfunction

  // REVIEW1_Aug3 R2-C02: a NULL protected segment load performs NO descriptor
  // read. The old flow read GDT[0] twice and installed whatever hidden state
  // those bytes held -- under paging an access the architecture never makes, and
  // arbitrary hidden state if software has written GDT[0]. CS/SS null faults
  // without a descriptor (seg_load_fault needs none for the null case); a null
  // DS/ES/FS/GS installs an explicit null hidden cache. One predicate, used by
  // the bus-arm suppression, the translation predicate, and the FSM commit.
  logic [15:0] segld_sel;
  logic [2:0]  segld_tgt;
  logic [63:0] segld_desc;
  logic [7:0]  segld_attr;
  logic        segld_is_ss, seg_null_load, segld_table_oob;
  logic        segld_desc_fault, segld_commit_ok;
  assign segld_sel  = q_seg_from_mem ? seg_mem_sel : gpr_o[q_src_reg][15:0];
  assign segld_tgt  = q_seg_from_mem ? q_lseg      : q_sys_sreg;
  assign segld_desc = {mem_rdata, gdt_lo};
  assign segld_attr = desc_attr(segld_desc);
  assign segld_is_ss = (segld_tgt == 3'(SG_SS));
  assign seg_null_load = (state == S_SEGLD) && is_null_selector(segld_sel);
  // Reuse the one table-extent comparator used by the other far-transfer
  // paths; do not synthesize a private add/compare cone for S_SEGLD.
  assign segld_table_oob = !seg_null_load && !sel_in_table(segld_sel);
  assign segld_desc_fault = seg_load_fault(1'b0, segld_is_ss, segld_sel,
                                           segld_attr, cpl_r);
  // One success predicate is consumed by BOTH architectural writeback domains.
  // This avoids duplicating the descriptor protection cone merely to make a
  // protected far-pointer load atomic.
  assign segld_commit_ok = (state == S_SEGLD)
                        && ((seg_null_load && !segld_is_ss
                             && (segld_tgt != 3'(SG_CS)))
                            || (mem_ack && seg_step && !segld_desc_fault));


  // H-08: the target CS limit from the descriptor BEING READ, granularity-scaled.
  // Deliberately NOT the staged iret_cs_limit above: that one is REGISTERED at the
  // commit stage, so consuming it here -- in a combinational term evaluated during the
  // read -- would test the PREVIOUS descriptor. Same source and same _w convention as
  // iret_cs_attr_w, which is the value this check must agree with.
  logic [31:0] iret_cs_limit_w;
  assign iret_cs_limit_w = desc_limit({mem_rdata, int_lo});
  logic [7:0] iret_cs_attr_w;
  logic       iret_cs_ok, iret_cs_desc_ok, iret_cs_commit;
  assign iret_cs_attr_w = mem_rdata[15:8];   // access byte of {mem_rdata, int_lo}
  // REVIEW_Aug3 H-03: split the predicate into its two reasons. The descriptor
  // half (selector/table/type/privilege/present) carries the SELECTOR as the
  // error code on failure; the offset half (popped EIP past CS.limit) is #GP(0)
  // per the SDM. The combined form reported #GP(selector) for an EIP-limit
  // failure on a perfectly valid descriptor.
  assign iret_cs_desc_ok = (int_gate_sel[15:2] != 14'd0)  // not the null selector
                   &&  iret_cs_attr_w[7]                  // P=1
                   &&  iret_cs_attr_w[4] && iret_cs_attr_w[3]   // S=1 and CODE
                   && (int_gate_sel[1:0] >= cpl_r)        // must not RAISE privilege
                   && (iret_cs_attr_w[2] ? (iret_cs_attr_w[6:5] <= int_gate_sel[1:0])
                                         : (iret_cs_attr_w[6:5] == int_gate_sel[1:0]));
  assign iret_cs_ok = iret_cs_desc_ok
                   // REVIEW2_aug2 H-08: the popped EIP must lie within the TARGET CS's
                   // limit. Class and privilege were checked; the OFFSET was not, and
                   // the commit then wrote it unconditionally -- so an IRET frame whose
                   // EIP is past the handler segment's limit resumed OUTSIDE it instead
                   // of raising #GP. Far transfers got this check under REVIEW1_Aug2
                   // H-02; IRET is the same dereference and was missed.
                   && (iret_eip <= iret_cs_limit_w);
  // The same-privilege commit clock: CS descriptor read complete and accepted, and the
  // return is NOT dropping privilege (the inter-priv path commits in S_IRET_SS).
  assign iret_cs_commit = (state == S_INT_CS_RET) && mem_ack && (int_step != 4'd0)
                       && iret_cs_ok && !iret_interpriv;
  assign iret_ss_commit = (state == S_IRET_SS) && mem_ack
                       && (int_step != 4'd0) && iret_ss_ok;
  // M7.2: IRET from CPL0 with the popped EFLAGS.VM set = a RETURN INTO V86 (the
  // monitor resumes the V86 task). Pops the full 9-word frame (EIP,CS,EFLAGS,ESP,
  // SS,ES,DS,FS,GS), forces CPL=3, sets EFLAGS.VM, and loads every segment base as
  // sel<<4 with NO descriptor read. iret_v86_* hold the popped V86 segments.
  logic        iret_to_v86;       // this IRET returns into V86 (9-word pop)
  logic [15:0] iret_v86_es, iret_v86_ds, iret_v86_fs, iret_v86_gs;

  // M2S.4b HARDWARE TASK SWITCH scratch (gated sys_mode; far JMP/CALL to a TSS).
  // tsw_step beats through the SAVE (write current TSS) / READ (read new TSS) /
  // SEG (reload incoming segment descriptors) / BUSY (toggle the GDT busy bits +
  // commit) phases. The new TSS descriptor (base/limit/sel/access) is captured in
  // S_LJMP from the GDT read; tr_attr holds the OUTGOING TSS descriptor access so
  // its busy bit can be cleared without a re-read. The incoming task state is read
  // into the tsw_* holding regs, then committed atomically on the final beat.
  logic [4:0]  tsw_step;          // beat counter within the task-switch phases
  logic [31:0] tsw_new_base;      // incoming TSS base (from its GDT descriptor)
  logic [31:0] tsw_new_limit;     // incoming TSS limit
  logic [15:0] tsw_new_sel;       // incoming TSS selector (the jump target)
  logic [7:0]  tsw_new_attr;      // incoming TSS descriptor access (busy set => |2)
  logic [31:0] tsw_save_eip;      // outgoing EIP to save (next insn after the jmp)
  // REVIEW1_Aug3 R2-H04: the outgoing EFLAGS IMAGE to save (NT cleared for an NT
  // return, staged at the S_LJMP arm instead of mutating live eflags mid-switch).
  logic [31:0] tsw_save_eflags;
  logic [31:0] tsw_eip;           // incoming EIP   (from new TSS @0x20)
  logic [31:0] tsw_eflags;        // incoming EFLAGS(from new TSS @0x24)
  logic [31:0] tsw_cr3;           // incoming CR3   (from new TSS @0x1C)
  logic [31:0] tsw_gpr [NUM_GPR]; // incoming GPRs  (@0x28..0x44)
  logic [15:0] tsw_new_ldt;       // incoming LDTR selector (from new TSS @0x60)
  logic [15:0] tsw_sel [NUM_SEG]; // incoming selectors CS/SS/DS/ES/FS/GS (loaded)
  logic [31:0] tsw_seg_lo;        // low dword latch for the SEG descriptor read

  // latched x87 decode
  fxop_e       q_fxop;
  logic        q_is_x87;
  logic        q_f_mem_read, q_f_mem_write;
  logic [3:0]  q_f_mbytes;
  logic        q_f_pop, q_f_pop2;
  logic [2:0]  q_f_sti, q_f_aluop, q_f_const;
  logic [3:0]  f_step;             // x87 memory beat counter
  // REVIEW1_Aug2 M-04: 6 bits, not 5. The 94-byte FNSAVE/FRSTOR forms take 47 WORD
  // beats (7 env + 40 register), so the counter has to reach 46; at 5 bits it wrapped
  // at 31, which is why the 16-bit form was left as a loud #UD rather than half-done.
  logic [5:0]  f_seq_step;         // M11b: wide beat counter (0..26 dwords / 0..46 words)
  logic [31:0] env_tmp [47];       // M11b: FLDENV/FRSTOR read-back regs (27 dwords / 47 words)
  logic [79:0] f_mem80;            // assembled memory operand (m16/32/64/80)

  logic [31:0] mem_load_data, mem_load_data2;
  logic [3:0]  step;            // micro-sequence step counter
  // nested ENTER (level>0) micro-sequence state: ent_k = current push index (1..level+1),
  // ent_rd = this beat reads the display source [SS:EBP-(k-1)*w] before the push,
  // ent_val = the value to push (EBP / read display entry / FrameTemp).
  logic [5:0]  ent_k;
  logic        ent_rd;
  logic [31:0] ent_val;
  logic [31:0] str_next_eip;    // EIP target after a string element commit
  logic [31:0] str_store_addr;  // [EDI] (pre-increment) for a MOVS/STOS store
  // FIX (Quake task #20 2nd bug): FULL pre-advance ESI/EDI/ECX for a MOVS/STOS element, snapshot in S_EXEC
  // (from gpr_o, so the a16 high halves are preserved — str_edi/str_esi mask them off, which would corrupt
  // ESI/EDI[31:16] on a 16-bit restore). On a demand-page #PF of the string store, ESI/EDI/ECX (advanced in
  // S_EXEC) are rolled back to these so the IA-32 string restart re-does the faulting element (else lost).
  logic [31:0] str_pre_esi;
  logic [31:0] str_pre_edi;
  logic [31:0] str_pre_ecx;
  logic [31:0] str_store_data;  // value to store this string element
  logic [31:0] pusha_esp;       // original ESP latched for PUSHA

  // ===========================================================================
  // Register read/merge with partial semantics
  // ===========================================================================
  // r is the PHYSICAL gpr index (decode already maps AH..BH -> EAX..EBX);
  // high8 selects bits [15:8] for 8-bit ops.
  function automatic logic [31:0] reg_read(input logic [2:0] r, input logic [2:0] w, input logic high8);
    begin
      if (w==3'd1) begin
        if (high8) reg_read = {24'd0, gpr_o[r][15:8]};
        else       reg_read = {24'd0, gpr_o[r][7:0]};
      end else if (w==3'd2) reg_read = {16'd0, gpr_o[r][15:0]};
      else reg_read = gpr_o[r];
    end
  endfunction

  function automatic logic [31:0] reg_merge(input logic [31:0] cur, input logic [31:0] res,
                                            input logic [2:0] w, input logic high8);
    begin
      if (w==3'd1) begin
        if (high8) reg_merge = {cur[31:16], res[7:0], cur[7:0]};
        else       reg_merge = {cur[31:8], res[7:0]};
      end else if (w==3'd2) reg_merge = {cur[31:16], res[15:0]};
      else reg_merge = res;
    end
  endfunction

  // ARCHITECTURAL segment selector for a seg index — the value the RETIRE trace
  // reports (see the `snap` mux): the LIVE seg_sel[] in system/proxy mode, else
  // the flat-user SEG_* reset constants (plain user mode does not maintain the
  // live seg_sel[] array). PUSH FS/PUSH GS / PUSH sreg must push THIS so the
  // pushed selector equals the traced one in every mode.
  function automatic logic [15:0] arch_seg_sel(input logic [2:0] idx);
    if (sys_mode || proxy_en) arch_seg_sel = seg_sel[idx];
    else unique case (idx)
      3'(SG_CS): arch_seg_sel = SEG_CS;  3'(SG_SS): arch_seg_sel = SEG_SS;
      3'(SG_DS): arch_seg_sel = SEG_DS;  3'(SG_ES): arch_seg_sel = SEG_ES;
      3'(SG_FS): arch_seg_sel = SEG_FS;  default:   arch_seg_sel = SEG_GS;
    endcase
  endfunction

  // ALU result + EFLAGS (alu_result/flags_next) and the shift/rotate datapath
  // (shrot_result/shrot_cf, shld_result/shld_cf) live in ventium_alu_pkg.

  // ===========================================================================
  // EXEC combinational operands
  // ===========================================================================
  logic [31:0] dst_cur, a_op, b_op, alu_out, flags_out;
  logic [5:0]  sh_cnt;
  logic [31:0] sh_val, sh_out, sh_shm1;
  logic        sh_cfout;
  // Memory-RMW shift/rotate store value, LATCHED at S_EXEC. A memory-dst shift stores its result
  // in S_STORE (a later cycle), but st_data=sh_out is a COMBINATIONAL function of eflags[0], and the
  // K_SHIFT S_EXEC arm has ALREADY committed eflags<=fl (overwriting CF with the rotate's OWN cf_out).
  // So by S_STORE, sh_out recomputes with the wrong (post-commit) cfin — for RCL/RCR (which read cfin
  // for the RESULT) that silently drops the incoming carry (e.g. the FAT cluster->sector multiword
  // shift `rcl dx,1 / rcl word ss:[0x607],1`, losing the high word -> COMMAND.COM LBA truncation).
  // Latching sh_out at S_EXEC (with the correct pre-commit cfin) and storing THAT fixes it. SHL/SHR/
  // SAR don't read cfin for the result, so they were already correct; the latch keeps them identical.
  logic [31:0] sh_out_st_r;

  always_comb begin
    // SHLD/SHRD (K_SHLDRD) memory RMW: the shifted operand is [mem] for a memory dst
    // (q_mem_dst). Register ops (q_mem_dst=0) keep gpr_o[q_dst_reg]. K_ALU/K_SHIFT mem RMW
    // use a_op/sh_val (already mem-aware) and skip the gpr write under q_mem_write, so this
    // only changes the K_SHLDRD result/flag source for the memory form.
    dst_cur = (q_mem_read && q_mem_dst) ? wmask(mem_load_data,q_w) : gpr_o[q_dst_reg];
    a_op = (q_mem_read && q_mem_dst) ? wmask(mem_load_data,q_w) : reg_read(q_dst_reg,q_w,q_dst_high8);
    if (q_use_imm) b_op = wmask(q_imm,q_w);
    else if (q_mem_read && !q_mem_dst) b_op = wmask(mem_load_data,q_w);
    else if (q_alu_op==ALU_INC || q_alu_op==ALU_DEC) b_op = 32'd1;
    else b_op = reg_read(q_src_reg,q_w,q_src_high8);
    alu_out   = alu_result(q_alu_op, a_op, b_op, eflags[0]);
    flags_out = flags_next(q_alu_op, a_op, b_op, alu_out, eflags, q_w);

    // ---- BCD / ASCII-adjust override (AAA/AAS/DAA/DAS/AAM/AAD). The AX result +
    // DEFINED flags are computed in the dedicated bcd_* always_comb below; here we
    // just route them onto alu_out (written via q_w=2 -> AX) and flags_out.
    if (q_alu_op >= ALU_AAA && q_alu_op <= ALU_AAD) begin
      alu_out   = {16'd0, bcd_ax};
      flags_out = bcd_flags;
    end

    sh_val = (q_mem_read && q_mem_dst) ? wmask(mem_load_data,q_w) : reg_read(q_dst_reg,q_w,q_dst_high8);
    if (q_shift_one) sh_cnt = 6'd1;
    else if (q_shift_cl) sh_cnt = {1'b0, gpr_o[R_ECX][4:0]};
    else sh_cnt = {1'b0, q_shift_imm};
    sh_out   = shrot_result(q_shrot, sh_val, sh_cnt, eflags[0], q_w);
    sh_cfout = shrot_cf(q_shrot, sh_val, sh_cnt, eflags[0], q_w);
    // shm1 = the operand shifted by (count-1), per QEMU CC_SRC for SHL/SHR/SAR.
    sh_shm1  = (sh_cnt==6'd0) ? sh_val : shrot_result(q_shrot, sh_val, sh_cnt-6'd1, eflags[0], q_w);
  end

  // ===========================================================================
  // R3 HOIST: MUL/IMUL/DIV/IDIV + SHLD/SHRD shared datapath.
  // These values were formerly computed TWICE — once in the EXEC FSM arm
  // (core_exec.svh K_MULDIV/K_SHLDRD, for flags/#DE/eip) and once in the gpr
  // writeback driver (core_gpr_wb.svh, for the register write VALUE). That
  // duplicated the multiplier (`*`) and divider (`/`/`%`) in the FPGA build.
  // Hoisting them here computes each ONCE; both sides read these signals. They
  // are pure functions of pre-edge state (gpr_o/mem_load_data/q_*), so they may
  // compute every cycle (dead when not in S_EXEC/K_MULDIV/K_SHLDRD — that's the
  // point: ONE shared unit). The divides stay guarded against /0 (no new X).
  // ---------------------------------------------------------------------------
  logic [31:0]        ex_srcv;          // MUL/DIV source operand (`/7 sign-ext base)
  logic [63:0]        ex_mul_p;         // MUL (unsigned) 64-bit product
  logic signed [63:0] ex_imul_p;        // IMUL (one-operand, signed) product
  logic [31:0]        ex_shld_r;        // SHLD/SHRD result word
  // SHLD/SHRD shift count (q_shift_cl ? CL : imm8); used by both the FSM arm
  // (cnt==0 guard + flags) and the driver (cnt==0 guard + ex_shld_r select).
  logic [5:0]         ex_shld_cnt;
  assign ex_shld_cnt = q_shift_cl ? {1'b0,gpr_o[R_ECX][4:0]} : {1'b0,q_shift_imm};
  always_comb begin
    ex_srcv = q_mem_read ? wmask(mem_load_data,q_w) : reg_read(q_src_reg,q_w,q_src_high8);

    // ---- MUL (unsigned, /4) : ONE multiplier shared by flags(core_exec) + EAX/EDX(driver)
    if (q_w==3'd1)      ex_mul_p = {48'd0, ({8'd0,gpr_o[R_EAX][7:0]}*{8'd0,ex_srcv[7:0]})};
    else if (q_w==3'd2) ex_mul_p = {32'd0, ({16'd0,gpr_o[R_EAX][15:0]}*{16'd0,ex_srcv[15:0]})};
    else                ex_mul_p = {32'd0,gpr_o[R_EAX]}*{32'd0,ex_srcv};

    // ---- IMUL one-operand (signed, /5) : ONE multiplier shared
    if (q_w==3'd1)      ex_imul_p = $signed({{8{ex_srcv[7]}},ex_srcv[7:0]}) * $signed({{8{gpr_o[R_EAX][7]}},gpr_o[R_EAX][7:0]});
    else if (q_w==3'd2) ex_imul_p = $signed({{16{ex_srcv[15]}},ex_srcv[15:0]}) * $signed({{16{gpr_o[R_EAX][15]}},gpr_o[R_EAX][15:0]});
    else                ex_imul_p = $signed(ex_srcv) * $signed(gpr_o[R_EAX]);

    // ---- SHLD/SHRD result : ONE shifter shared by flags(core_exec) + dst(driver)
    ex_shld_r = shld_result(q_shrd, dst_cur, reg_read(q_src_reg,q_w,1'b0), ex_shld_cnt, q_w);
  end

`ifndef VEN_IDIV_ITER
  // ---- Native DIV/IDIV (/6, /7) : ONE divider (`/`/`%`) shared by the FSM #DE
  // check (core_exec.svh) and the EAX/EDX write (core_gpr_wb.svh). The FPGA
  // VEN_IDIV_ITER path uses the iterative ven_idiv engine instead (eng_int_*),
  // so this whole block is compiled out there. Results are widened to 64 bits;
  // each side slices the bits it formerly computed. Divides are guarded against
  // a zero divisor (qq/rr forced 0 -> no X), mirroring the original structure
  // where the body under `if(srcv!=0)` is the only place `/`/`%` appears.
  logic [63:0] ex_div_qq,  ex_div_rr;    // DIV  (unsigned) quotient / remainder
  logic        ex_div_dfault;            // DIV  #DE (div-by-zero OR quotient overflow)
  logic [63:0] ex_idiv_qq, ex_idiv_rr;   // IDIV (signed)   quotient / remainder
  logic        ex_idiv_dfault;           // IDIV #DE
  // The per-branch num/den/qq/rr scratch is declared inside conditional arms
  // (a different width per arm), so no single path assigns every one of them;
  // each is only read inside its own arm after assignment. Verilator's latch
  // analysis flags the pattern anyway, so it is waived for this block only.
  /* verilator lint_off LATCH */
  always_comb begin
    // --- DIV (unsigned) ---
    ex_div_qq=64'd0; ex_div_rr=64'd0; ex_div_dfault=1'b0;
    if (q_w==3'd1) begin
      logic [15:0] num, qq, rr;
      num=gpr_o[R_EAX][15:0];
      if (ex_srcv[7:0]==8'd0) ex_div_dfault=1'b1;
      else begin
        qq=num/{8'd0,ex_srcv[7:0]}; rr=num%{8'd0,ex_srcv[7:0]};
        if (qq[15:8]!=8'd0) ex_div_dfault=1'b1;
        ex_div_qq={48'd0,qq}; ex_div_rr={48'd0,rr};
      end
    end else if (q_w==3'd2) begin
      logic [31:0] num,qq,rr;
      num={gpr_o[R_EDX][15:0],gpr_o[R_EAX][15:0]};
      if (ex_srcv[15:0]==16'd0) ex_div_dfault=1'b1;
      else begin
        qq=num/{16'd0,ex_srcv[15:0]}; rr=num%{16'd0,ex_srcv[15:0]};
        if (qq[31:16]!=16'd0) ex_div_dfault=1'b1;
        ex_div_qq={32'd0,qq}; ex_div_rr={32'd0,rr};
      end
    end else begin
      logic [63:0] num,qq,rr;
      num={gpr_o[R_EDX],gpr_o[R_EAX]};
      if (ex_srcv==32'd0) ex_div_dfault=1'b1;
      else begin
        qq=num/{32'd0,ex_srcv}; rr=num%{32'd0,ex_srcv};
        if (qq[63:32]!=32'd0) ex_div_dfault=1'b1;
        ex_div_qq=qq; ex_div_rr=rr;
      end
    end

    // --- IDIV (signed) ---
    ex_idiv_qq=64'd0; ex_idiv_rr=64'd0; ex_idiv_dfault=1'b0;
    if (q_w==3'd1) begin
      logic signed [15:0] num,den,qq,rr;
      num=$signed(gpr_o[R_EAX][15:0]); den=$signed({{8{ex_srcv[7]}},ex_srcv[7:0]});
      if (ex_srcv[7:0]==8'd0) ex_idiv_dfault=1'b1;
      else begin
        qq=num/den; rr=num%den;
        if (qq != $signed({{8{qq[7]}}, qq[7:0]})) ex_idiv_dfault=1'b1;
        ex_idiv_qq={{48{qq[15]}},qq}; ex_idiv_rr={{48{rr[15]}},rr};
      end
    end else if (q_w==3'd2) begin
      logic signed [31:0] num,den,qq,rr;
      num=$signed({gpr_o[R_EDX][15:0],gpr_o[R_EAX][15:0]}); den=$signed({{16{ex_srcv[15]}},ex_srcv[15:0]});
      if (ex_srcv[15:0]==16'd0) ex_idiv_dfault=1'b1;
      else begin
        qq=num/den; rr=num%den;
        if (qq != $signed({{16{qq[15]}}, qq[15:0]})) ex_idiv_dfault=1'b1;
        ex_idiv_qq={{32{qq[31]}},qq}; ex_idiv_rr={{32{rr[31]}},rr};
      end
    end else begin
      logic signed [63:0] num,den,qq,rr;
      num=$signed({gpr_o[R_EDX],gpr_o[R_EAX]}); den=$signed({{32{ex_srcv[31]}},ex_srcv});
      if (ex_srcv==32'd0) ex_idiv_dfault=1'b1;
      else begin
        qq=num/den; rr=num%den;
        if (qq != $signed({{32{qq[31]}}, qq[31:0]})) ex_idiv_dfault=1'b1;
        ex_idiv_qq=qq; ex_idiv_rr=rr;
      end
    end
  end
  /* verilator lint_on LATCH */
`endif

  // ===========================================================================
  // BCD / ASCII-adjust datapath (AAA/AAS/DAA/DAS/AAM/AAD) — matches QEMU
  // int_helper.c helper_aaa/aas/daa/das/aam/aad EXACTLY. Computes the AX result
  // (bcd_ax) + the DEFINED EFLAGS (bcd_flags); the EXEC block above routes these
  // onto alu_out/flags_out when the op is BCD. Architecturally-undefined flags
  // (OF always; SF/ZF/PF for AAA/AAS; CF/AF for AAM/AAD) are left cleared and are
  // removed from the differential by tracefmt.eflags_undefined_mask. AAM base 0
  // is a #DE this core defers (like native DIV-by-zero); the divide is guarded to
  // avoid an X (the corpus never executes AAM 0). Outputs default unconditionally
  // (no latch); the `default` arm computes AAA and also covers every non-BCD
  // q_alu_op (harmless dead compute — bcd_* are consumed only for BCD ops).
  // ===========================================================================
  logic [15:0] bcd_ax;
  logic [31:0] bcd_flags;
  // BCD / ASCII-adjust datapath extracted to core/uv_common.sv (R3,
  // behaviour-preserving). The spine forwards gpr_o[R_EAX] low 16, the imm8,
  // q_alu_op, and EFLAGS; the EXEC block above routes bcd_ax/bcd_flags onto
  // alu_out/flags_out for AAA/AAS/DAA/DAS/AAM/AAD.
  uv_common u_uv_common (
    .eflags        (eflags),
    .bcd_eax16     (gpr_o[R_EAX][15:0]),
    .bcd_imm8      (q_imm[7:0]),
    .bcd_alu_op    (q_alu_op),
    .bcd_ax        (bcd_ax),
    .bcd_flags     (bcd_flags),
    .u_d           (u_d),
    .v_d           (v_d),
    .u_flags       (u_flags),
    .u_sh          (u_sh),
    .u_shm1        (u_shm1),
    .u_shcf        (u_shcf),
    .v_br_taken_eff(v_br_taken_eff)
  );

  // ---- CMPXCHG (0F B0/B1) combinational compute -----------------------------
  // accumulator = AL/eAX; temp = the destination operand (memory load for the
  // mem form, the GPR for the reg form). Flags = CMP accumulator,temp (i.e.
  // accumulator - temp), reusing the canonical ALU_CMP flag computation.
  logic [31:0] cmpxchg_acc, cmpxchg_temp, cmpxchg_flags;
  logic        cmpxchg_eq;
  always_comb begin
    cmpxchg_acc  = reg_read(R_EAX, q_w, 1'b0);
    cmpxchg_temp = (q_mem_read && q_mem_dst) ? wmask(mem_load_data, q_w)
                                             : reg_read(q_dst_reg, q_w, q_dst_high8);
    cmpxchg_eq   = (cmpxchg_acc == cmpxchg_temp);
    cmpxchg_flags= flags_next(ALU_CMP, cmpxchg_acc, cmpxchg_temp,
                              cmpxchg_acc - cmpxchg_temp, eflags, q_w);
  end

  // ===========================================================================
  // Retire snapshot
  // ===========================================================================
  logic [31:0] next_eip;
  assign next_eip = q_pc + {28'd0, q_len};

  arch_state_t snap;
  always_comb begin
    snap.eflags=eflags;
    snap.eax=gpr_o[0]; snap.ecx=gpr_o[1]; snap.edx=gpr_o[2]; snap.ebx=gpr_o[3];
    snap.esp=gpr_o[4]; snap.ebp=gpr_o[5]; snap.esi=gpr_o[6]; snap.edi=gpr_o[7];
    if (sys_mode) begin
      // System-mode core: the selectors are the LIVE seg_sel[] (real-mode
      // segment values, or protected-mode descriptor selectors). User mode is
      // unchanged (the constant SEG_* params the M0-M6 corpus expects).
      snap.cs=seg_sel[SG_CS]; snap.ss=seg_sel[SG_SS]; snap.ds=seg_sel[SG_DS];
      snap.es=seg_sel[SG_ES]; snap.fs=seg_sel[SG_FS]; snap.gs=seg_sel[SG_GS];
    end else if (proxy_en) begin
      // M7.1 proxy: report the LIVE user selectors (seeded to the SEG_* constants
      // at reset, then updated by a user-mode `mov gs, 0x33` -> seg_sel[GS]=0x33).
      // Quake only ever changes %gs (musl TLS); the others stay at SEG_*.
      snap.cs=seg_sel[SG_CS]; snap.ss=seg_sel[SG_SS]; snap.ds=seg_sel[SG_DS];
      snap.es=seg_sel[SG_ES]; snap.fs=seg_sel[SG_FS]; snap.gs=seg_sel[SG_GS];
    end else begin
      snap.cs=SEG_CS; snap.ss=SEG_SS; snap.ds=SEG_DS; snap.es=SEG_ES; snap.fs=SEG_FS; snap.gs=SEG_GS;
    end
  end
  assign retire_state=snap;
  // M7.1: a folded-syscall retire (the instruction after cd80) is stamped with the
  // int-0x80's pc (fold_pc_r) so it aligns with the golden int-0x80 record. Inert
  // unless proxy_en && fold_pending_r, so non-proxy retires use q_pc verbatim.
  assign retire_pc = (proxy_en && fold_pending_r) ? fold_pc_r : q_pc;

  // M2S.1 system retire payload. retire_sys mirrors retire_valid in system mode
  // (every retirement carries the control-register block); 0 in user mode.
  assign retire_sys = sys_mode && retire_valid;
  assign retire_cr0 = creg0;
  assign retire_cr2 = creg2;
  assign retire_cr3 = creg3;
  assign retire_cr4 = creg4;

  // Second retirement (paired V issue). In cycle mode only `pc` is compared, so
  // retire2_state mirrors the primary snapshot (well-formed, never gate-checked
  // for the V member); retire2_pc is registered at issue.
  logic [31:0] q_pc2;
  assign retire2_state = snap;
  assign retire2_pc = q_pc2;

  // ===========================================================================
  // String addressing + direction
  // ===========================================================================
  logic        df;
  assign df = eflags[10];
  logic [31:0] str_step;        // +/- width
  assign str_step = df ? (32'd0 - {29'd0,q_w}) : {29'd0,q_w};
  // F3 — a16 string pointers (q_cnt16 == latched eff_addr): with 16-bit
  // addressing the EA uses SI/DI (low 16 bits, mod-64K wrap) and the high
  // halves of ESI/EDI are NOT address inputs. Without the mask, a backward
  // (DF=1) copy whose SI/DI crossed 0 went 32-bit negative and every later
  // string EA landed 64 KiB low (FreeDOS SYSINIT's relocate-high copy left
  // holes the flow later fell into). q_cnt16=0 in every 32-bit flat gate.
  wire [31:0] str_esi = q_cnt16 ? {16'd0, gpr_o[R_ESI][15:0]} : gpr_o[R_ESI];
  wire [31:0] str_edi = q_cnt16 ? {16'd0, gpr_o[R_EDI][15:0]} : gpr_o[R_EDI];
  // R3 HOIST: post-decrement ECX (ECX-1, a16-wrapped). This single decrementer
  // is SHARED by every arm that decrements the count register and also writes it
  // back — the REP string arms (K_STR core_exec.svh, S_INS core_io.svh) and the
  // LOOP/LOOPE/LOOPNE arm (K_CTRL/CT_LOOP). The FSM side uses it for the
  // taken/last_iter test + new_eip; the gpr writeback driver (core_gpr_wb.svh)
  // writes it to ECX — instead of each side recomputing `gpr_o[R_ECX]-1`. These
  // states are mutually exclusive, so one decrementer suffices.
  wire [31:0] dec_cx = q_cnt16 ? {gpr_o[R_ECX][31:16], gpr_o[R_ECX][15:0]-16'd1}
                               : (gpr_o[R_ECX] - 32'd1);

  // ===========================================================================
  // Store-operand resolution (combinational) used in S_STORE.
  // The per-op store address/data/strobe are computed from latched fields.
  // ===========================================================================
  function automatic logic [3:0] strb_of(input logic [2:0] w);
    if (w==3'd1) return 4'b0001; else if (w==3'd2) return 4'b0011; else return 4'b1111;
  endfunction

  logic [31:0] st_addr, st_data;
  logic [3:0]  st_strb;
  logic [31:0] call_target;

  // Slow-path data-LOAD address (mirrors the S_LOAD bus-driver address selection)
  // so the sequential block can run the D-cache timing SM on it (M5 finding [med]).
  logic [31:0] slow_dmem_addr;
  always_comb begin
    if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
        (q_kind==K_STKMISC && q_sm==SM_POPF))      slow_dmem_addr = gpr_o[R_ESP];
    else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)  slow_dmem_addr = gpr_o[R_EBP];
    else if (q_xlat)                               slow_dmem_addr = gpr_o[R_EBX]+{24'd0,gpr_o[R_EAX][7:0]};
    else if (q_kind==K_STR) begin
      if (q_st==ST_SCAS)                           slow_dmem_addr = str_edi;
      else                                         slow_dmem_addr = str_esi;
    end else                                       slow_dmem_addr = q_ea;
  end

  logic [31:0] call_t16;  // 0x66 near-CALL truncated target (declared at top to
                          // avoid an inferred latch on a branch-local var)
  always_comb begin
    // default store: a memory destination (RMW / mov [m],r / setcc [m])
    st_strb = strb_of(q_w);
    st_addr = q_ea;
    st_data = 32'd0;
    call_t16 = next_eip + q_rel;

    // resolve store data by op kind
    if (q_is_push) begin
      st_addr = stk16(gpr_o[R_ESP] - {28'd0,q_w});
      // F3 PUSH sreg: data = the 16-bit selector (zero-extended; strb_of(q_w) keeps
      // 2 bytes for a 16-bit push, 4 for a 0x66-prefixed 32-bit push).
      st_data = q_push_sreg ? {16'd0, arch_seg_sel(q_sys_sreg)}
              : q_use_imm   ? q_imm
              : (q_mem_read ? mem_load_data : reg_read(q_src_reg,q_w,1'b0));
    end else if (q_kind==K_CTRL && (q_ct==CT_CALLREL || q_ct==CT_CALLIND)) begin
      // Near CALL pushes the next-IP at the operand width: 4 bytes (32-bit) or
      // 2 bytes for a 0x66-prefixed 16-bit near CALL.
      st_addr = stk16(gpr_o[R_ESP] - {28'd0,q_w});
      st_data = next_eip;
      st_strb = strb_of(q_w);
    end else if (q_kind==K_STKMISC && q_sm==SM_PUSHF) begin
      st_addr = stk16(gpr_o[R_ESP] - {28'd0,q_w});
      st_data = eflags;
    end else if (q_kind==K_STKMISC && q_sm==SM_ENTER) begin
      // ENTER level 0: the single push writes EBP at [ESP-w].
      st_addr = stk16(gpr_o[R_ESP] - {28'd0,q_w});
      st_data = gpr_o[R_EBP];
    end else if (q_kind==K_SETCC) begin
      st_data = {31'd0, cond_true(q_cc, eflags)};
      st_strb = 4'b0001;
    end else if (q_kind==K_SHIFT) begin
      st_data = sh_out_st_r;   // LATCHED at S_EXEC (see decl) — NOT the post-commit-eflags recompute
    end else if (q_kind==K_SHLDRD) begin
      st_data = ex_shld_r;          // SHLD/SHRD memory destination RMW result
    end else if (q_kind==K_BITTEST) begin
      // BTS/BTR/BTC memory RMW: write the bit-modified [mem] value (dst_cur is mem-aware).
      logic [4:0] bidx; logic [31:0] bcur, bsrcv;
      bcur  = wmask(dst_cur,q_w);
      bsrcv = reg_read(q_src_reg,3'd4,1'b0);
      bidx  = q_bit_imm ? q_imm[4:0] : bsrcv[4:0];
      if (q_w==3'd2) bidx = {1'b0, bidx[3:0]};
      unique case (q_bit_op)
        3'd5:    st_data = bcur | (32'd1<<bidx);   // BTS
        3'd6:    st_data = bcur & ~(32'd1<<bidx);  // BTR
        3'd7:    st_data = bcur ^ (32'd1<<bidx);   // BTC
        default: st_data = bcur;                   // BT (no write; harmless)
      endcase
    end else if (q_kind==K_XCHG) begin
      st_data = reg_read(q_src_reg,q_w,q_src_high8);
    end else if (q_kind==K_CMPXCHG) begin
      // CMPXCHG mem-dst: store src (reg operand) if equal, else write the
      // original temp back UNCHANGED (keeps the locked RMW atomic, per QEMU).
      // Uses the LATCHED equality (cmpxchg_wrsrc_r) — by S_STORE gpr_o[R_EAX] may
      // have been updated on the not-equal path, so the live cmpxchg_eq is stale.
      st_data = cmpxchg_wrsrc_r ? reg_read(q_src_reg,q_w,q_src_high8)
                                : wmask(mem_load_data,q_w);
    end else if (q_is_pop) begin
      // POP m: write the popped stack word to the memory destination.
      st_data = mem_load_data;
    end else if (q_is_mov) begin
      // F3 MOV [mem],Sreg: store the 16-bit selector (strb_of(q_w=2) writes 2 bytes).
      st_data = q_store_sreg ? {16'd0, seg_sel[q_sys_sreg]}
              : q_use_imm    ? q_imm : reg_read(q_src_reg,q_w,q_src_high8);
    end else begin
      // ALU RMW / NEG / NOT / INC / DEC to memory
      st_data = alu_out;
    end

    // CALL/JMP indirect target
    if (q_ct==CT_CALLIND || q_ct==CT_JMPIND) begin
      call_target = q_mem_read ? mem_load_data : gpr_o[q_src_reg];
      // F3: a 16-bit-operand indirect CALL/JMP loads IP from r/m16 and zeroes
      // EIP[31:16] (same convention as CT_RETN below). Without the mask, EIP's
      // high half took table-adjacent memory bytes / stale upper register bits.
      // q_w==2 only under eff_opsize -> every flat gate is byte-identical.
      if (q_w==3'd2) call_target = {16'd0, call_target[15:0]};
    end
    else if (q_kind==K_CTRL && q_ct==CT_CALLREL && q_w==3'd2)
      // 0x66 near CALL: operand-size-16 truncates the target EIP to 16 bits.
      call_target = {16'd0, call_t16[15:0]};
    else
      call_target = next_eip + q_rel;
  end

  // ===========================================================================
  // String element operand (combinational): value to write/compare this iter.
  // ===========================================================================
  logic [31:0] str_wdata;    // value to store at [EDI]
  logic [31:0] str_a, str_b; // SCAS/CMPS compare operands
  logic [31:0] str_flags;
  always_comb begin
    // value to store:
    //  MOVS -> [ESI] (mem_load_data)
    //  STOS -> AL/AX/EAX
    unique case (q_st)
      ST_MOVS: str_wdata = mem_load_data;
      ST_STOS: str_wdata = reg_read(R_EAX,q_w,1'b0);
      ST_INS:  str_wdata = ins_data;   // M7.3c: the IN value captured in S_INS
      default: str_wdata = mem_load_data;
    endcase
    // SCAS: compare EAX(width) - [EDI];  CMPS: [ESI] - [EDI]
    if (q_st==ST_SCAS) begin str_a = reg_read(R_EAX,q_w,1'b0); str_b = wmask(mem_load_data,q_w); end
    else /*CMPS*/        begin str_a = wmask(mem_load_data,q_w); str_b = wmask(mem_load_data2,q_w); end
    str_flags = flags_next(ALU_CMP, str_a, str_b, str_a - str_b, eflags, q_w);
  end

  // ===========================================================================
  // x87 combinational execution (M3)
  // ===========================================================================
  // st(i) read helper on the physical regfile (st0 = fpr[ftop]). The physical
  // index fri(i)=ftop+i is unchanged; fst(i) now reads the fpu_top module's
  // TOP-relative read ports (fp_st[i] = fpr[ftop+i]), zero added latency.
  function automatic logic [2:0] fri(input logic [2:0] i); return ftop + i; endfunction
  function automatic logic [79:0] fst(input logic [2:0] i); return fp_st[i]; endfunction

  // x87 INSTRUCTION-LEVEL pure helpers (fcom_codes/fst_eq/fst_lt, fx_is_nan/
  // fx_is_snan/fcom_ie, apply_cmp, fconst, fxam_codes, f_mem_as_float/_int,
  // f_arith/f_div_by_zero/f_zero_over_zero/f_eval/f_arith_fstat) were extracted
  // VERBATIM to ventium_x87_pkg (R2 modularization). They wrap the fpu_x87_pkg
  // floatx80 ops and use no module state, so the move is a netlist no-op.
  // fri()/fst()/fp_bop() stay here (they read module state ftop/fp_st[]/gpr_o[]).

  // ===========================================================================
  // x87 retire snapshot (TOP-relative st0..st7, fstat with TOP overlaid)
  // ===========================================================================
  assign retire_x87_touched = x87_touched_r;
  assign retire_fctrl = fctrl;
  assign retire_fstat = (fstat & ~16'h3800) | ({13'd0, ftop} << 11);
  assign retire_ftag  = 16'h0000;       // QEMU gdbstub abridges ftag to 0
  assign retire_st0 = fp_st[0];
  assign retire_st1 = fp_st[1];
  assign retire_st2 = fp_st[2];
  assign retire_st3 = fp_st[3];
  assign retire_st4 = fp_st[4];
  assign retire_st5 = fp_st[5];
  assign retire_st6 = fp_st[6];
  assign retire_st7 = fp_st[7];

  // ===========================================================================
  // M4/M5 fast-path decoder — extracted to the `decode` leaf module
  // (rtl/core/decode.sv), instantiated as u_decode / v_decode above. It decodes
  // the simple/pairable instruction subset (fpd_t producer); anything else
  // leaves d.simple=0 and the core falls back to the multi-cycle FSM.
  // ===========================================================================

  // second ALU operand for a fast-path ALU/mov insn: imm, or the source reg, or
  // a fixed 1 for INC/DEC (matching the slow path's b_op selection).
  function automatic logic [31:0] fp_bop(input fpd_t d);
    if (d.alu_op==ALU_INC || d.alu_op==ALU_DEC) fp_bop = 32'd1;
    else if (d.use_imm) fp_bop = d.imm;
    else fp_bop = reg_read(d.src, 3'd4, 1'b0);
  endfunction

  // pairing checker — extracted to the `issue_uv` leaf module
  // (rtl/core/issue_uv.sv), instantiated as u_issue near the decode instances.
  // It takes the U decode + V candidate decode and drives `pipe_pair_ok`.

  // icache presence: is the 32-byte line containing `addr` resident in EITHER way
  // of its set? (2-way, mirrors the oracle / the RTL D-cache lookup.) Reads the
  // module's READ-ONLY array outputs (ic_val_o/ic_tag_o) — PRE-edge registered
  // state, VERBATIM the old inline probe (only the array names gained the _o).
  function automatic logic ic_present(input logic [31:0] addr);
    logic [IC_IDXW-1:0] set; logic [IC_TAGW-1:0] tag; logic p;
    begin
      set = addr[5 +: IC_IDXW]; tag = addr[5+IC_IDXW +: IC_TAGW];
      p = 1'b0;
      for (int w=0; w<IC_WAYS; w++)
        if (ic_val_o[set][w] && ic_tag_o[set][w]==tag) p = 1'b1;
`ifndef VEN_IC_NO_FETCH_BYPASS
      // H-06: the non-cacheable line just filled is readable ONCE without being valid.
      for (int i=0; i<2; i++)
        if (icbp_v[i] && (set == icbp_set[i]) && (tag == icbp_tag[i])) p = 1'b1;
`endif
      ic_present = p;
    end
  endfunction
  // which way holds the line (assumes ic_present(addr)). The hitting way wins; if
  // none hits (speculative/stale read) it defaults to the last way (IC_WAYS-1) —
  // at IC_WAYS==2 this is exactly the old `!(way0 hit)` (0 iff way0 hits, else 1).
  function automatic logic [IC_WAYW-1:0] ic_hit_way(input logic [31:0] addr);
    logic [IC_IDXW-1:0] set; logic [IC_TAGW-1:0] tag; logic [IC_WAYW-1:0] hw;
    begin
      set = addr[5 +: IC_IDXW]; tag = addr[5+IC_IDXW +: IC_TAGW];
      hw = IC_WAYW'(IC_WAYS-1);
      for (int w=0; w<IC_WAYS; w++)
        if (ic_val_o[set][w] && ic_tag_o[set][w]==tag) hw = IC_WAYW'(w);
`ifndef VEN_IC_NO_FETCH_BYPASS
      for (int i=0; i<2; i++)
        if (icbp_v[i] && (set == icbp_set[i]) && (tag == icbp_tag[i])) hw = icbp_way[i]; // H-06
`endif
      ic_hit_way = hw;
    end
  endfunction
  // icache byte read (assumes ic_present(addr)): from whichever way hit. STALE-BY-
  // DESIGN: a speculative V-decode of a NON-RESIDENT line still reads ic_data_o
  // (whatever is there); only ic_val_o gates correctness.
  function automatic logic [7:0] ic_byte(input logic [31:0] addr);
    // read from the addressed line buffers (rd_lineA = flin's line, rd_lineB =
    // next line); the fetch window spans only these two sets and the hit way is
    // baked into each line (ic_rd_wayA/B), so there is no per-byte way mux.
    logic [IC_LINE*8-1:0] ln;
`ifdef VEN_IC_BRAM
    // content-addressed by (set, WAY): pick whichever REGISTERED buffer holds addr's
    // (set,way). ic_fetch_ready (below) gates issue on the SAME (set,way) predicate,
    // so the two MUST agree. A set-ONLY match was STALE-BY-WAY: after a fill
    // re-allocated addr's line into the other 2-way victim, rdA_set_q still matches
    // addr's set for ~1 window while rdA_way_q / ic_rd_lineA still hold the OLD way's
    // bytes — returning a wrong opcode byte -> a len-1 misdecode -> next-EIP off by 1
    // -> derail (the F4 board Quake __init_libc retire-557 freeze; only over L1AXI +
    // IC_BRAM, where the multi-cycle AXI fill opens the way-stale window). Neither
    // buffer holds (set,way) => not buffered, stale-by-design (gated by ic_fetch_ready
    // / the V-candidate path), so fall back to A.
    logic [IC_IDXW-1:0] icb_s;
    logic [IC_WAYW-1:0] icb_w;
    icb_s = addr[5 +: IC_IDXW];
    icb_w = ic_hit_way(addr);
    // A collided buffer (rd_coll*) holds BRAM-garbage on silicon — skip it so the
    // select matches ic_fetch_ready (which also rejects collided buffers); the spine
    // stalls one cycle and re-reads cleanly.
    ln = (rdA_set_q == icb_s && rdA_way_q == icb_w && !ic_rd_collA) ? ic_rd_lineA
       : (rdB_set_q == icb_s && rdB_way_q == icb_w && !ic_rd_collB) ? ic_rd_lineB
       : ic_rd_lineA;
`else
    ln = (addr[5 +: IC_IDXW] == ic_rd_setA) ? ic_rd_lineA : ic_rd_lineB;
`endif
    ic_byte = ln[{addr[4:0],3'b000} +: 8];
  endfunction

  // A resident line is not by itself safe to read during S_FETCH with the BRAM
  // frontend: the synchronous I-cache buffers may still hold a different way.
  // This is the same returned-address predicate used by ic_fetch_ready, factored
  // for the longer (16-byte) slow-decoder window. It is used solely by the
  // uop-overflow hand-off below; ordinary slow fetches retain P5-calibrated bus
  // timing.
  logic sfetch_uop_fast, sfetch_resident_fast;
`ifdef VEN_UOPCACHE
`ifdef VEN_IC_BRAM
`ifdef VEN_UOP_SFETCH
  function automatic logic ic_buffered(input logic [31:0] addr);
    logic [IC_IDXW-1:0] ib_set;
    logic [IC_WAYW-1:0] ib_way;
    begin
      ib_set = addr[5 +: IC_IDXW];
      ib_way = ic_hit_way(addr);
      ic_buffered = ic_present(addr)
                 && ((rdA_set_q == ib_set && rdA_way_q == ib_way && !ic_rd_collA)
                  || (rdB_set_q == ib_set && rdB_way_q == ib_way && !ic_rd_collB));
    end
  endfunction
  // The token records a miss detected in S_PIPE only after ic_fetch_ready was
  // true. Recheck BOTH endpoints here rather than relying on that history:
  // S_FETCH copies 16 bytes (not the fast path's 12), and a stale/predicted B
  // buffer must fall back to the original bus fetch, never supply old bytes.
  assign sfetch_uop_fast = sfetch_uop_q && (state == S_FETCH) && (fetch_word == 3'd0)
                       && exec_issue_ok
                       && ic_buffered(flin)
                       && ic_buffered(flin + 32'(IWORDS*4 - 1));
`ifdef VEN_SFETCH_RESIDENT
  // These tokens are set only by the three S_PIPE branches below the
  // pipe_bytes_ok/ic_fetch_ready gates.  Recheck the complete slow-decoder
  // window here; any changed way, collision, flush, or straddle ambiguity
  // immediately returns to the original bus fetch.
  assign sfetch_resident_fast = sfetch_resident_q && (state == S_FETCH)
                            && (fetch_word == 3'd0) && exec_issue_ok
                            && ic_buffered(flin)
                            && ic_buffered(flin + 32'(IWORDS*4 - 1));
`else
  assign sfetch_resident_fast = 1'b0;
`endif
`else
  assign sfetch_uop_fast = 1'b0;
  assign sfetch_resident_fast = 1'b0;
`endif
`else
  assign sfetch_uop_fast = 1'b0;
  assign sfetch_resident_fast = 1'b0;
`endif
`else
  assign sfetch_uop_fast = 1'b0;
  assign sfetch_resident_fast = 1'b0;
`endif

  // ---- task #54: SERVE THE SLOW PATH'S FETCH FROM THE I-CACHE ---------------
  // VEN_PERF_PROFILE measured the booting cosim (25.5M clocks, CPI 8.26) and found
  // S_FETCH is 52.2% of ALL core clocks -- 13,308,217 of 25,499,675, which is 8.03
  // clocks for EVERY instruction the fast path hands to the slow FSM. The reason is
  // that S_FETCH re-reads the 16-byte instruction window through the DATA port, one
  // word per bus ack (core_bus_driver.svh:18), for every such instruction.
  //
  // Those bytes are already in the I-cache. The fast path fetched them from there
  // this very clock -- the S_PIPE chain rejects `!pipe_bytes_ok` (bucket 1) BEFORE it
  // reaches the fp_sys_bail hand-off (bucket 9), so a hand-off only happens with
  // flin's line resident. So when the whole window is resident, copy it out of the
  // I-cache in ONE clock and go straight to S_DECODE.
  //
  // ic_byte() reads the two addressed line buffers -- rd_lineA is flin's line
  // (ic_rd_setA = flin[5+:IDXW]) and rd_lineB is the next line (flin_nl) -- which is
  // exactly the span a 16-byte window at flin can cover. So residency of the two
  // endpoints is the complete test.
  //
  // SAFETY: this skips a bus transaction, not a check. The I-cache line was filled
  // through the normal translated S_PF path, and the fast path is already executing
  // out of these same bytes via ic_byte(), so the shortcut is exactly as safe as
  // S_PIPE itself. If the line is NOT resident we fall through to the original
  // word-by-word fetch unchanged.
  //
  // NOT ENABLED UNDER VEN_IC_BRAM: there ic_rd_lineA/B are REGISTERED (valid the
  // clock after the address) and correctness depends on ic_fetch_ready's (set,way)
  // predicate. Serving a fetch combinationally from them would reintroduce exactly
  // the way-stale window that ic_fetch_ready exists to close.
  logic sfetch_fast;
`ifdef VEN_FAST_SFETCH
`ifdef VEN_IC_BRAM
  assign sfetch_fast = 1'b0;   // see note above
`else
  // *** DEFAULT OFF, AND IT MUST STAY OFF. Enabling it makes the core FASTER THAN A
  // *** REAL PENTIUM, which is a fidelity REGRESSION, not an optimisation. ***
  //
  // Measured both ways with the 98-program + 20-band gate:
  //
  //                        default (no shortcut)        with shortcut
  //     mb_div8    abs-cyc     +0.20%  PASS               -15.59%  FAIL
  //     mb_mul     abs-cyc     +0.31%  PASS               -24.65%  FAIL
  //     mb_imul2   abs-cyc     +0.15%  PASS               -24.76%  FAIL
  //
  // The default configuration reproduces p5model -- the P5 timing oracle this
  // project calibrates against -- to within a THIRD OF A PERCENT on these kernels.
  // So the 8 clocks S_FETCH spends per slow-path instruction are not waste relative
  // to a Pentium: whatever their internal distribution, the TOTAL is what a P5
  // costs. Removing them does not close a gap, it overshoots the target by 15-25%.
  //
  // I originally reasoned the other way -- that a real P5 fetches from its prefetch
  // buffers so this cost "cannot be P5 behaviour", and therefore the modelled MUL/DIV
  // occupancy must be ~25% short and needed re-deriving. The numbers above refute
  // that: the occupancy is not short, the total is already right. Recorded because
  // the wrong version is the intuitive one and someone will have it again.
  //
  // What the shortcut IS good for: it isolates how much of the slow path's cost is
  // instruction fetch, which is how S_FETCH was identified as 52.2% of all core
  // clocks (VEN_PERF_PROFILE, DISK_BOOT_STATUS UPDATE 303). Keep it as an
  // instrument. Do not ship it.
  assign sfetch_fast = (state == S_FETCH) && (fetch_word == 3'd0)
                    && exec_issue_ok      // a flush cycle always fetches fresh
                    && ic_present(flin)
                    && ic_present(flin + 32'(IWORDS*4 - 1));
`endif
`else
  assign sfetch_fast = 1'b0;
`endif

  // icache LRU update on a confirmed HIT now lives in the icache module: the spine
  // drives up to 3 touch ports (U / U-straddle / V) on the issue arm — see the
  // ic_tch*_* combinational driver near the u_icache instantiation. Each replaces
  // an old ic_touch(addr) call (oracle l1_access() hit path: s->lru = hit way).

  // D-cache hit test + access/allocate now live in the dcache_timing module
  // (rtl/mem/dcache.sv): the comb lookup is dc_lu_hit (off dc_lu_addr) and the
  // single posedge access fires when dc_acc_valid is high (on dc_acc_addr). The
  // combinational drivers for those ports are in the dc_acc_* always_comb below.

  // BTB lookup (pure-comb btb_lookup) + update (btb_update_taken) + the arrays
  // now live in the bpred_btb module (R2 extract, rtl/core/bpred_btb.sv): the
  // comb predicts are btb_u_pred (off btb_u_query_pc) and btb_v_pred (off
  // btb_v_query_pc), reading PRE-update state; the single posedge resolve fires
  // when btb_resolve_valid is high (on btb_resolve_pc/btb_resolve_taken). The
  // combinational drivers for those ports are below (predict assigns at the
  // u_pred_taken/v_pred_taken use sites; resolve in the branch-resolution arm).

  // ===========================================================================
  // M4 fast-path combinational pipeline evaluation (S_PIPE). Decodes the U
  // instruction (and the V candidate at off+lenU) from the prefetch buffer,
  // runs the pairing checker + AGI detect, and computes each insn's post-commit
  // result with the SAME helpers the slow path uses. The sequential S_PIPE block
  // below consumes these to issue 1 or 2 instructions per clock.
  // ===========================================================================
  fpd_t        u_d, v_d;             // U insn + V candidate decodes
  logic        pipe_bytes_ok;        // U (+ V candidate) bytes resident in icache
  logic [31:0] pf_miss_fa;           // I-cache fill line address for a current miss
  logic        pf_miss;             // a fill-word-0 fetch is needed this S_PIPE clock
  logic        pipe_pair;            // U and V issue together this clock
  logic        moffs_falsedep;       // M6 Err59: A2/A3 moffs U + EAX-using V follower
  logic        v_bytes_ok;           // V candidate's full bytes resident in I-cache
  logic        pipe_agi;             // U has an AGI hazard (addr reg written last clk)
  logic        pipe_load_req;        // U is a checked DS/SS memory read (drives the bus)
  logic        pipe_store_req;       // U is an audited DS/SS MOV store (drives the bus)
  // A fast U-side memory instruction may not retire until the seam has returned
  // its architectural result.  This is normally zero in the single-cycle BFM,
  // but the generic page-fragment engine deliberately hides the first fragment
  // acknowledgement and exposes only the merged final beat.  Keeping this as a
  // named issue predicate makes the spine and every commit-side mirror wait for
  // the same completion event (rather than accidentally treating a fragment-1
  // word, whose tail is physically adjacent garbage, as a completed load).
  logic        pipe_mem_wait;
  logic [2:0]  pipe_load_base;
  logic [2:0]  pipe_mem_seg;         // DS or SS selected by the decoded base
  logic [31:0] pipe_load_addr;
  logic [31:0] v_lea_addr;
  logic [31:0] pipe_store_data;
  logic [31:0] u_alu, u_flags, u_sh, u_shm1; logic u_shcf;
  logic [4:0]  u_shift_cnt;
  logic [31:0] v_alu, v_flags;
  logic [31:0] u_target, v_target;
  logic [31:0] u_tgt_raw, v_tgt_raw;   // task #56 step G: pre-truncation branch targets   // branch targets
  logic        u_pred_taken, v_pred_taken;
  logic        v_br_taken_eff;       // V branch taken using U's flags (uv_common)
  logic [7:0]  ub [6];               // U decode bytes (icache, possibly 0 if cold)
  logic [7:0]  vb [6];               // V candidate decode bytes (at eip+lenU)
`ifdef VEN_UOPCACHE
  // P0-11 predecoded µop-cache fast-path read wires (driven by u_uopcache). NSLOT
  // fast-path insns covered per 32-byte line; a denser line overflows -> those
  // offsets read uc_bv*=0 and the spine re-predecodes (perf, not correctness).
  localparam int NSLOT = 8;
  fpd_t        uc_slotsA [NSLOT], uc_slotsB [NSLOT];
  logic        uc_bvA [IC_LINE],  uc_bvB [IC_LINE];   // byte offset is a boundary
  logic [2:0]  uc_bsA [IC_LINE],  uc_bsB [IC_LINE];   // ...maps to this slot
  logic        uc_pdvA, uc_pdvB;                      // line is predecoded-valid
  logic        uop_hit, uc_v_avail;                   // flin on boundary / V resident
  logic        uc_u_in_b;                            // H-15: U's line is in port B
`endif

  // M2S.1: the FETCH LINEAR address. The architectural `eip` carries the
  // segment OFFSET (the value reported as `pc` in the trace); the bytes are
  // fetched from linear = CS.base + eip. In user mode (and any flat segment)
  // CS.base==0 so flin==eip and EVERY fetch/icache reference below is numerically
  // unchanged. `flin` substitutes for `eip` ONLY in the fetch + I-cache path;
  // the retire pc, the eip<-eip+len advance, and all branch math stay in offset
  // space (so far jumps that reload CS.base shift the fetch window correctly).
  // NOTE (deferred corner, M2S.x): this is a full 32-bit add with NO 20-bit
  // real-mode wrap and NO A20 masking. With A20 ENABLED (the qemu-system default
  // the bootstrap runs under) a real-mode access does NOT wrap at 1 MiB, so this
  // is correct for the gate; the A20-masked 1 MiB wrap (and the seg:off overflow
  // case) is unmodeled. The pseg corpus never exercises wrap.
  logic [31:0] fbase, flin;
  assign fbase = seg_base[SG_CS];
  assign flin  = fbase + eip;

  // icache addressed line-read drives: line A = flin's 32-byte line, line B = the
  // next line (the fetch/V window can straddle into it). The per-line hit way is
  // baked in (stale-by-design on a miss, matching the old ic_byte). flin is a
  // stable continuous signal, so flin -> addr -> line -> ic_byte settles cleanly.
  logic [31:0] flin_nl;
  assign flin_nl    = {flin[31:5], 5'd0} + 32'd32;     // next aligned 32-byte line
  assign ic_rd_setA = flin[5 +: IC_IDXW];
  assign ic_rd_wayA = ic_hit_way(flin);
`ifdef VEN_IC_BRAM
  // port B normally prefetches flin's next (straddle) line; 2b repurposes it to the
  // predicted branch target when pf_redir (set in the fast-path comb block). The read
  // is REGISTERED in the icache module, so this drives NEXT clock's rd_lineB — no
  // combinational loop through the decode that computes pf_redir.
  assign ic_rd_setB = pf_redir ? pf_redir_tgt[5 +: IC_IDXW] : flin_nl[5 +: IC_IDXW];
  assign ic_rd_wayB = pf_redir ? ic_hit_way(pf_redir_tgt) : ic_hit_way(flin_nl);
`else
  assign ic_rd_setB = flin_nl[5 +: IC_IDXW];
  assign ic_rd_wayB = ic_hit_way(flin_nl);
`endif

`ifdef VEN_IC_BRAM
  // Register the read ADDRESS as a tag, in lock-step with the icache module's
  // registered data (both clocked by clk on the same edge): in cycle T, ic_rd_lineA
  // holds the line for (rdA_set_q, rdA_way_q). Reset to a sentinel so a cold buffer
  // never false-matches a real flin (presence is gated separately by pipe_bytes_ok).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rdA_set_q <= '1; rdA_way_q <= '1;
      rdB_set_q <= '1; rdB_way_q <= '1;
    end else begin
      rdA_set_q <= ic_rd_setA; rdA_way_q <= ic_rd_wayA;
      rdB_set_q <= ic_rd_setB; rdB_way_q <= ic_rd_wayB;
    end
  end
  // fetch-ready: the line containing flin (and, when the decode window straddles, the
  // next line) is currently held in one of the two registered buffers. A buffer holds
  // a line iff its registered tag (set+way) equals what flin needs now. The two
  // buffers always hold DIFFERENT sets (flin's line and flin's next line differ by 1),
  // so a set match uniquely identifies the buffer; the way is checked to reject a
  // post-fill way change. ic_byte (below) does the matching content-addressed select.
  logic ic_fa_avail, ic_fb_avail, ic_win_straddle;
  always_comb begin
    logic [IC_IDXW-1:0] fa_set, fb_set; logic [IC_WAYW-1:0] fa_way, fb_way;
    fa_set = flin[5 +: IC_IDXW];        fa_way = ic_hit_way(flin);
    fb_set = flin_nl[5 +: IC_IDXW];     fb_way = ic_hit_way(flin_nl);
    // A buffer whose registered read COLLIDED with a fill (rd_coll*) holds BRAM-garbage
    // on silicon — exclude it so the fetch stalls and re-reads cleanly next cycle.
    ic_fa_avail = (rdA_set_q==fa_set && rdA_way_q==fa_way && !ic_rd_collA)
                || (rdB_set_q==fa_set && rdB_way_q==fa_way && !ic_rd_collB);
    ic_fb_avail = (rdA_set_q==fb_set && rdA_way_q==fb_way && !ic_rd_collA)
                || (rdB_set_q==fb_set && rdB_way_q==fb_way && !ic_rd_collB);
    // the fast-path decode window is at most 12 bytes (ub 6 + vb up to len 6 + 6);
    // it straddles into the next line iff flin's byte offset + 12 > 32.
    ic_win_straddle = ({1'b0,flin[4:0]} + 6'd12) > 6'd32;
    ic_fetch_ready  = ic_fa_avail && (!ic_win_straddle || ic_fb_avail);
  end
`endif

`ifdef VEN_UOPCACHE
  // ===========================================================================
  // P0-11 PREDECODE-ON-FILL: the twelve 32:1 byte selects (the ub[]/vb[] gather
  // above) — the architectural MUXF congestion wall — are DELETED from the fast
  // path. decode.sv ran on the multi-cycle fill walker (u_uopcache below) and the
  // results are stored as fixed-width fpd_t indexed by SLOT. Here the fast path
  // just READS the slot the current flin lands in (an ~8:1 slot mux over the
  // registered uop-line), and because predecode CHAINED the boundaries, the V
  // candidate is literally U's NEXT slot — so the flin+lenU V-base serialization
  // is gone too. The only flin-indexed select left is the small byte->slot map
  // lookup (uc_bsA[flin[4:0]], 32:1 over 3 bits) — not a 32:1 over 256-bit data.
  //
  // br_taken is the ONLY flag-dependent decode field (cond_true): predecode froze
  // it with the fill-time EFLAGS, so re-evaluate it from the opcode-derived cc
  // against the LIVE eflags — exactly what the V resolution path already does
  // (v_br_taken_eff). Every other fpd_t field is opcode/operand-derived => the
  // stored value IS the live value (structural bit-exactness).
  fpd_t        u_d_raw, v_d_raw;
`ifdef VEN_UOPCACHE
`ifndef VEN_IC_BRAM
  // REVIEW1_Aug2 M-05: refuse to elaborate the unpaired configuration. Without
  // VEN_IC_BRAM the uop decode reads I-cache port A unconditionally (see the `else
  // branch below), so a redirect whose target line landed in port B decodes STALE
  // predecode/uop data -- the wrong uop issues. That is not something to ship behind a
  // comment.
  // Elaboration-time (IEEE 1800 s20.11): $error inside a generate scope is evaluated
  // during elaboration, so the unpaired configuration fails to BUILD rather than
  // failing at time 0. The `initial $fatal` is kept alongside it as the belt-and-braces
  // runtime stop for any tool that only honours the procedural form.
  if (1) begin : g_m05_cfg_guard
    $error("VEN_UOPCACHE requires VEN_IC_BRAM (REVIEW1_Aug2 M-05): the uop decode reads I-cache port A unconditionally without the rdA/rdB tracking registers, which is stale after a redirect.");
  end
  initial $fatal(1, "VEN_UOPCACHE requires VEN_IC_BRAM: without the rdA/rdB tracking registers the uop decode cannot tell which I-cache port holds the current line and reads port A unconditionally, which is stale after a redirect (REVIEW1_Aug2 M-05).");
`endif
`endif
  logic [4:0]  uc_uoff, uc_voff;
  logic [2:0]  uc_uslot, uc_vslot;
  logic        uc_v_in_a;
  always_comb begin
    // REVIEW2 H-15: the uop cache's A/B reads are SYNCHRONOUS and carry NO returned
    // address tag, so the consumer must decide which buffer actually holds the current
    // line. ic_fetch_ready already does this correctly for the I-cache (ic_fa_avail
    // accepts fa_set/fa_way in EITHER buffer) -- but the uop decode below always read
    // port A. Predicted-target prefetch deliberately places a taken target in port B,
    // so after a redirect the I-cache data could be ready from B while U decoded STALE
    // predecode state from A; if A happened to report a valid boundary at the same
    // offset, the WRONG UOP ISSUED.
    //
    // Select the port whose registered (set,way) matches the fetch line, using the
    // same rdA/rdB_*_q comparison ic_fa_avail uses, so the two cannot disagree.
    // fa_set/fa_way are block-local to the ic_fetch_ready always_comb, so recompute
    // them from the SAME source (flin) rather than reaching into that block -- the
    // derivation is one line and duplicating the SOURCE is safe; duplicating the
    // DECISION would not be.
`ifdef VEN_IC_BRAM
    begin
      logic [IC_IDXW-1:0] uc_fa_set; logic [IC_WAYW-1:0] uc_fa_way;
      uc_fa_set = flin[5 +: IC_IDXW];
      uc_fa_way = ic_hit_way(flin);
      uc_u_in_b = !(rdA_set_q==uc_fa_set && rdA_way_q==uc_fa_way && !ic_rd_collA)
                &&  (rdB_set_q==uc_fa_set && rdB_way_q==uc_fa_way && !ic_rd_collB);
    end
`else
    // Without VEN_IC_BRAM there are no rdA/rdB_*_q tracking registers -- the I-cache
    // reads are asynchronous, so nothing records which buffer last latched which line,
    // and there is no honest way to choose the port. Port A unconditionally is the
    // pre-existing behaviour and it is WRONG after a redirect: predicted-target
    // prefetch deliberately parks a taken target in port B, so the I-cache data can be
    // ready from B while the uop decode reads stale predecode state from A.
    //
    // REVIEW1_Aug2 M-05: this used to be a comment saying so. A configuration that can
    // issue the wrong uop must not be silently buildable, so the pairing is now
    // enforced at ELABORATION -- +VEN_UOPCACHE requires +VEN_IC_BRAM. Anyone who wants
    // the unpaired build has to implement tagged selection first, which is the actual
    // fix. Neither define is in the deployed set, so nothing shipping changes.
    uc_u_in_b = 1'b0;
`endif
    uc_uoff  = flin[4:0];
    uc_uslot = uc_u_in_b ? uc_bsB[uc_uoff]  : uc_bsA[uc_uoff];
    u_d_raw  = uc_u_in_b ? uc_slotsB[uc_uslot] : uc_slotsA[uc_uslot];
    // V begins right after U; predecode put it in the next slot of the SAME line,
    // unless U+lenU crosses the 32-byte line boundary (then V's first byte is in
    // line B, looked up by its in-B offset).
    uc_voff  = uc_uoff + {1'b0, u_d_raw.len};
    uc_v_in_a = ({1'b0,uc_uoff} + {2'b0,u_d_raw.len}) < 6'd32;
    if (uc_v_in_a) begin
      // H-15: V in U's line -> same buffer U came from, not unconditionally A.
      uc_vslot = uc_uslot + 3'd1;
      v_d_raw  = uc_u_in_b ? uc_slotsB[uc_vslot] : uc_slotsA[uc_vslot];
    end else begin
      uc_vslot = uc_bsB[uc_voff];
      v_d_raw  = uc_slotsB[uc_vslot];
    end
    // re-evaluate the flag-dependent Jcc taken bit against the LIVE eflags.
    u_d = u_d_raw;
    if (u_d_raw.is_branch && u_d_raw.br_cond) u_d.br_taken = cond_true(u_d_raw.cc, eflags);
    v_d = v_d_raw;
    if (v_d_raw.is_branch && v_d_raw.br_cond) v_d.br_taken = cond_true(v_d_raw.cc, eflags);
  end
  // uop_hit: flin's line is predecoded AND flin lands on a recorded instruction
  // boundary. A miss (cold predecode, or a branch INTO the middle of an insn as
  // walked-from-line-start) is handled by the spine: stall + re-predecode (the
  // S_PIPE !uop_ready arm). uc_v_avail mirrors the old v_bytes_ok residency for
  // the chained/straddle V slot.
  // H-15: validity must come from the SAME port the slots were read from.
  assign uop_hit    = exec_issue_ok &&   // a flush cycle is never a predecode hit
                      (uc_u_in_b ? (uc_pdvB && uc_bvB[flin[4:0]])
                                 : (uc_pdvA && uc_bvA[flin[4:0]]));
  // A V candidate is usable only when its OWN instruction boundary was stored.
  // In particular, the 3-bit `uc_uslot + 1` arithmetic wraps slot 7 to slot 0;
  // without this boundary check, an instruction in the final slot could pair
  // with an unrelated first slot from the same line.  The map check also covers
  // a sparse/overflowed walker tail, where U is covered but its successor was
  // deliberately not predecoded.
  assign uc_v_avail = uc_v_in_a
                    ? ((uc_uslot != 3'(NSLOT-1)) &&
                       (uc_u_in_b ? uc_bvB[uc_voff] : uc_bvA[uc_voff]))
                    : (uc_pdvB && uc_bvB[uc_voff]);
`ifdef VEN_UOPCACHE_CHECK
  // Structural-equivalence gate: keep the live ub/vb gather + reference decoders
  // and assert the slot read matches them for every issued flin. SIM-ONLY (this
  // path is NOT in the synth-probe build — that build defines VEN_UOPCACHE alone,
  // so the byte gather is truly absent from the netlist).
  fpd_t u_d_ref, v_d_ref;
  always_comb begin
    for (int i=0;i<6;i++) ub[i] = ic_present(flin+i[31:0]) ? ic_byte(flin+i[31:0]) : 8'd0;
    for (int i=0;i<6;i++) vb[i] = ic_byte(flin+{28'd0,u_d_ref.len}+i[31:0]);
  end
  decode u_decode_ref (.ib0(ub[0]),.ib1(ub[1]),.ib2(ub[2]),.ib3(ub[3]),.ib4(ub[4]),.ib5(ub[5]),
                       .iflags(eflags), .def16(def16), .cycle_mode(cycle_mode), .uop(u_d_ref));
  decode v_decode_ref (.ib0(vb[0]),.ib1(vb[1]),.ib2(vb[2]),.ib3(vb[3]),.ib4(vb[4]),.ib5(vb[5]),
                       .iflags(eflags), .def16(def16), .cycle_mode(cycle_mode), .uop(v_d_ref));

  // The uop cache is an optional timing implementation, not an alternate ISA
  // decoder.  When this diagnostic profile is selected, stop at the first
  // resident predecode that is not bit-for-bit identical to the live byte
  // decoder.  This is deliberately gated by both residency and uop_hit: during
  // a cold fill the registered read ports hold an unrelated previous line, and
  // that is a re-walk/performance condition rather than an incorrect issue.
  //
  // `VEN_UOPCACHE_CHECK is never enabled by an implementation build, so this
  // assertion and its reference byte muxes cannot affect the FPGA netlist.
  always_ff @(posedge clk) begin
    if (rst_n && (state == S_PIPE) && pipe_bytes_ok && uop_hit &&
        ((u_d !== u_d_ref) || (uc_v_avail && (v_d !== v_d_ref)))) begin
      $display("[UOPCHECK] decode mismatch flin=%08x eip=%08x U(slot=%0d len=%0d reads=%02x writes=%02x) ref(len=%0d reads=%02x writes=%02x) V(slot=%0d len=%0d reads=%02x writes=%02x) ref(len=%0d reads=%02x writes=%02x)",
               flin, eip, uc_uslot, u_d.len, u_d.reads, u_d.writes,
               u_d_ref.len, u_d_ref.reads, u_d_ref.writes,
               uc_vslot, v_d.len, v_d.reads, v_d.writes,
               v_d_ref.len, v_d_ref.reads, v_d_ref.writes);
      $fatal(1, "VEN_UOPCACHE_CHECK: predecoded slot differs from live decode");
    end
  end
`endif
`else
  // R1 phase-3: the fast-path decoder is now the `decode` leaf module
  // (rtl/core/decode.sv), instantiated once per slot (U + V candidate). The
  // byte windows are gathered combinationally below (U at flin, V at flin+lenU),
  // exactly as the in-line `fp_decode(...)` calls read them. u_d/v_d are driven
  // by the instances; everything downstream consumes them unchanged.
  always_comb begin
    for (int i=0;i<6;i++) ub[i] = ic_present(flin+i[31:0]) ? ic_byte(flin+i[31:0]) : 8'd0;
    for (int i=0;i<6;i++) vb[i] = ic_byte(flin+{28'd0,u_d.len}+i[31:0]);
  end

  decode u_decode (
      .ib0(ub[0]), .ib1(ub[1]), .ib2(ub[2]), .ib3(ub[3]), .ib4(ub[4]), .ib5(ub[5]),
      .iflags(eflags), .def16(def16), .cycle_mode(cycle_mode), .uop(u_d)
  );
  decode v_decode (
      .ib0(vb[0]), .ib1(vb[1]), .ib2(vb[2]), .ib3(vb[3]), .ib4(vb[4]), .ib5(vb[5]),
      .iflags(eflags), .def16(def16), .cycle_mode(cycle_mode), .uop(v_d)
  );
`endif

  // R1 phase-3: the pairing checker is now the `issue_uv` leaf module
  // (rtl/core/issue_uv.sv). pipe_pair_ok is the bare can-pair RULES decision;
  // pipe_pair below ANDs in cycle_mode + V-bytes-resident exactly as before.
  logic pipe_pair_ok;
  issue_uv u_issue (.iu(u_d), .iv(v_d), .pair_ok(pipe_pair_ok));

  always_comb begin
    // M5 finding [med] (I-cache straddle): U is decodable+chargeable correctly iff
    // the line containing eip is resident AND, only when the instruction actually
    // crosses the 32-byte line boundary, the line containing its LAST byte too.
    // The oracle charges a second I-miss exactly when (vaddr&31)+size > 32
    // (verif/qemu-plugins/p5trace.c:428); it must NOT pre-charge a second-line
    // miss for a short instruction near the line end. The 6-byte fast-path decode
    // window can read into the next line, so require that straddle line for a SAFE
    // decode whenever the window crosses the boundary, but use the real decoded
    // length to decide whether a straddle miss is genuinely charged.
    pipe_bytes_ok = exec_issue_ok         // a flush cycle forces the refetch path
                    && ic_present(flin)
                    // window-straddle: need the next line present to decode safely
                    && (({1'b0,flin[4:0]} + 6'd5 < 6'd32) || ic_present(flin + 32'd5))
                    // instruction-straddle: its last byte's line must be resident
                    && (({1'b0,flin[4:0]} + {2'b0,u_d.len} <= 6'd32)
                        || ic_present(flin + {28'd0,u_d.len} - 32'd1));
    // V candidate sits right after U (decoded by the v_decode instance above,
    // from the vb[] byte window gathered at flin+lenU).

    // I-cache fill line address for a current miss (flin's line first, else the
    // decode-window straddle line, else the instruction-straddle line) and the
    // condition under which the S_PIPE miss branch fires THIS clock (so the bus
    // driver can issue the fill's word-0 read on the detection clock — removing
    // the wasted transition clock, finding [med] I-miss off-by-one).
    pf_miss_fa = !ic_present(flin)         ? flin
               : !ic_present(flin + 32'd5) ? (flin + 32'd5)
               : (flin + {28'd0,u_d.len} - 32'd1);
    // !fp_issue_block: an interrupt or external debugger park abandons this clock
    // before S_PIPE issues, so it never enters S_PF and words 1..7 / fill_done never arrive. If
    // the fill were still started, the victim way would receive word 0 of the NEW line
    // while keeping the OLD line's tag/valid -- silently corrupting the first dword of
    // a still-resident, still-valid line. Do not start a fill we cannot finish.
    pf_miss = (state==S_PIPE) && !fp_issue_block && (stall_cnt==7'd0) && !pipe_bytes_ok;

    // AGI: a base/index reg used by U was written in the IMMEDIATELY-preceding
    // fast-path issue clock (tracked in agi_wr0/agi_wr1; bit8=none).
    pipe_agi = 1'b0;
    if (u_d.addr_mask != 8'd0) begin
      if (!agi_wr0[8] && u_d.addr_mask[agi_wr0[2:0]]) pipe_agi=1'b1;
      if (!agi_wr1[8] && u_d.addr_mask[agi_wr1[2:0]]) pipe_agi=1'b1;
    end

    // pairing decision: V can pair only when U leads, no hazards, AND the V
    // candidate's FULL bytes are resident in the I-cache. A V branch can pair (it
    // fills V); a U branch never leads a pair (pairs_first=0).
    //
    // M5 (control-flow correctness): the V candidate is decoded combinationally
    // from ic_byte(), which returns whatever is in the array even for a NON-RESIDENT
    // line. If the V instruction STRADDLES into a cold line, its decode (opcode /
    // displacement / immediate) uses stale bytes — and a stale Jcc would be
    // mispaired and resolved with a wrong target/decode, diverging from the oracle's
    // instruction stream (reproduced: a `test(U); jz(V)` where the jz at offset 31
    // straddles a cold next line was resolved not-taken vs the oracle's taken). So
    // require the V instruction's first byte AND its last byte to be in resident
    // lines before pairing; otherwise V is not paired this clock — it becomes the
    // next U, the cold line fills via S_PF, and it issues with correct bytes.
    v_bytes_ok = exec_issue_ok &&
                 ic_present(flin + {28'd0,u_d.len}) &&
                 ic_present(flin + {28'd0,u_d.len} + {28'd0,v_d.len} - 32'd1);
    // REVIEW2 H-05: the STI / MOV-SS shadow protects exactly ONE instruction. If the
    // clock after the shadow is set retires a PAIR, two instructions execute inside a
    // one-instruction shadow and the interrupt that should have been recognised
    // between U and V is delayed past both. Force single-issue while the registered
    // shadow is set; it is one clock, so the cost is nil.
    // REVIEW2 H-07: the V byte window is gathered at flin + u_d.len with NO 16-bit
    // wrap (vb[] above, and the uop-cache slot chain likewise). If U ends at offset
    // FFFF, V must decode from CS:0000, but it would decode bytes at CS.base+0x10000
    // and then retire under a wrapped PC -- right PC, wrong instruction. Wrapping the
    // gather would mean sourcing V from a different cache line than U, so instead do
    // not pair across the wrap: V becomes the next U and is fetched correctly from
    // the wrapped flin. One lost pairing opportunity per 64 KiB of 16-bit code.
`ifdef VEN_DBG_CORE
    // The host breakpoint names a single architectural EIP.  If it names the
    // candidate V instruction, issue U alone and let V become the next U, where
    // dbg_bp_hit parks it before execution.  Likewise a host STEP is one x86
    // instruction, never a U/V pair.
    dbg_bp_v_hit = dbg_bp_en && !dbg_step_q && (state == S_PIPE) &&
                   ((eip + {28'd0, u_d.len}) == dbg_bp_addr);
`endif
    pipe_pair = cycle_mode && v_bytes_ok && pipe_pair_ok && !irq_shadow && !dbg_pair_block
`ifdef VEN_UOPCACHE
             // In a predecoded build, the V slot must have a recorded boundary.
             // `v_bytes_ok` proves the raw I-cache bytes are resident, not that
             // the registered uop-cache slot selected above represents them.
             && uc_v_avail
`endif
             && !(u_d.w16 && (({1'b0,eip[15:0]} + {13'd0,u_d.len}) > 17'h0FFFF));

    // M6 Erratum 59 (MOV moffs A2/A3 fails to pair): when errata enabled, an
    // A2/A3 moffs store (the U member) followed by an instruction that uses
    // (e)AX (as a source, base/index, or destination) triggers a FALSE EAX
    // dependency in the instruction unit, so the pair is suppressed. We detect
    // "V references EAX" as: V reads EAX (reads[EAX]) OR V writes EAX
    // (writes[EAX]) OR V's address uses EAX (addr_mask[EAX]). The clean core
    // (errata off) pairs them normally — that contrast is the self-check.
    moffs_falsedep = u_d.is_moffs &&
                     (v_d.reads[R_EAX] || v_d.writes[R_EAX] || v_d.addr_mask[R_EAX]);
    if (errata_en[ERR_MOFFS] && moffs_falsedep)
      pipe_pair = 1'b0;

    // FIX (Quake task #25 CWSDPMI cascade): gate on !sys_mode.  u_d is the FAST-PATH
    // decoder (decode.sv), which has NO D-bit input and ALWAYS decodes 32-bit. In
    // system mode the OS/DPMI runs 16-bit code (CS.D=0): a 16-bit insn like the JMP
    // 0x3e98 at cs=0018:0x3f49 (`e9 4c ff`) is followed by `8b 1e ..` which the 32-bit
    // fast decoder reads as `mov ebx,[esi]` (a register-base LOAD) instead of the 16-bit
    // `mov bx,[disp16]`. That spurious u_d.is_load drove a D-side bus request +
    // translation (core_bus_driver.svh:23, cur_is_d=pipe_load_req core.sv:4155) for
    // ds:[esi]; on a paged CWSDPMI task-switch resume (esi=0x11b354 -> lin 0x147a54,
    // unmapped) the speculative page-walk FAULTED, nesting #PFs whose CPL0-stack push
    // eventually overflowed into TSS0070 and set cr3:=2 -> total paging collapse. The
    // fast-path load COMMIT (u_load_acc, core.sv:4407) is already !sys_mode-gated, so in
    // sys_mode this request/translation was pure never-committed speculation; suppress it
    // so the slow S_FETCH/S_DECODE/S_LOAD path (which honors CS.D) handles every sys load.
    // REVIEW Aug-1 H-01: the `u_d.simple && !sys_mode` above is now carried by the
    // canonical fp_sys_bail (which folds in `sys_mode && u_d.is_mem`), so request
    // issue and issue eligibility can no longer drift apart. Bit-identical today --
    // the point is that it is now structural rather than a hand-copy.
    // !fp_issue_block: do not start a speculative translation/page-walk on a
    // clock whose instruction is being abandoned (cf. task #25 cascade).
    pipe_load_req  = (state==S_PIPE) && !fp_issue_block && pipe_bytes_ok && !fp_sys_bail &&
                     u_d.is_mem && !u_d.is_store && !pipe_agi && (mispred_bubbles==3'd0);
    pipe_store_req = (state==S_PIPE) && !fp_issue_block && pipe_bytes_ok && !fp_sys_bail &&
                     u_d.is_store && !pipe_agi && (mispred_bubbles==3'd0);
    pipe_load_base = u_d.base;
    pipe_mem_seg   = u_d.mem_ss ? 3'(SG_SS) : 3'(SG_DS);
    pipe_load_addr = (u_d.mem_base_en ? gpr_o[u_d.base] : 32'd0) + u_d.mem_disp
                   + (u_d.mem_index_en ? (gpr_o[u_d.mem_index] << u_d.mem_scale) : 32'd0);
    // LEA uses the same integer AGU arithmetic as a checked U-side memory
    // access, but never asserts a memory request.  Keep a V-side equivalent
    // because LEA is UV-pairable; using only its base would silently corrupt
    // a paired disp/SIB LEA.
    v_lea_addr = (v_d.mem_base_en ? gpr_o[v_d.base] : 32'd0) + v_d.mem_disp
               + (v_d.mem_index_en ? (gpr_o[v_d.mem_index] << v_d.mem_scale) : 32'd0);
    pipe_store_data = gpr_o[u_d.src];

    // U datapath extracted to core/u_pipe.sv (R3, behaviour-preserving):
    // u_alu/u_flags/u_sh/u_shm1/u_shcf are driven by the u_pipe instance below
    // from the pre-read U operands. The eip-relative branch target stays here.
    // task #56 step G: in 16-bit operand mode a near JMP/Jcc computes
    //   EIP = (next_eip + rel16) & 0xFFFF
    // (decode_stages.sv models this as d_br16; its 0xE8 arm comments it explicitly). The fast
    // path added a 32-bit rel to a 32-bit EIP with NO truncation, so every taken 16-bit branch
    // landed at an untruncated address and the guest wandered -- observed as cs=f000:eip=0x16
    // with no POST progress (UPDATE 281). w16 is 0 in user mode, so this is inert there.
    u_tgt_raw = (eip + {28'd0,u_d.len}) + u_d.rel;
    u_target  = u_d.w16 ? {16'd0, u_tgt_raw[15:0]} : u_tgt_raw;
    // BTB U predict: drive the module's comb predict port at this clock's U pc
    // (= eip) and read back its PRE-update predicted-taken (bpred_btb).
    btb_u_query_pc = eip;
    u_pred_taken = btb_u_pred;

    // V datapath (independent of U by the pairing rule, so reading the OLD gpr
    // state is correct for both).
    // V datapath extracted to core/v_pipe.sv (R3): v_alu/v_flags are driven by
    // the v_pipe instance below. The eip-relative V target stays here.
    v_tgt_raw = ((eip + {28'd0,u_d.len}) + {28'd0,v_d.len}) + v_d.rel;
    v_target  = v_d.w16 ? {16'd0, v_tgt_raw[15:0]} : v_tgt_raw;
    // BTB V predict: drive the module's comb predict port at the V pc
    // (= eip + u_d.len) and read back its PRE-update predicted-taken (bpred_btb).
    btb_v_query_pc = eip + {28'd0,u_d.len};
    v_pred_taken = btb_v_pred;

`ifdef VEN_IC_BRAM
    // 2b — predicted-taken-target PREFETCH driver. When a predicted-taken branch is in
    // the current window AND the window does not straddle (so port B is not needed for
    // this clock's decode), repurpose port B to read the predicted TARGET line so it is
    // registered BEFORE the redirect — the back-edge of a hot loop then costs no fetch
    // bubble. A U branch is unpaired (a U branch never leads a pair); a paired V branch
    // uses v_target. Gated on !ic_win_straddle so a straddling branch keeps port B for
    // its own (correct) decode, and so a prefetch that does not redirect cannot strand
    // the straddle line. The read is registered (next-clock effect) — no comb loop.
    pf_redir = 1'b0; pf_redir_tgt = 32'd0;
    if (!ic_win_straddle) begin
      if (u_d.is_branch && u_pred_taken) begin
        pf_redir = 1'b1; pf_redir_tgt = u_target;
      end else if (pipe_pair && v_d.is_branch && v_pred_taken) begin
        pf_redir = 1'b1; pf_redir_tgt = v_target;
      end
    end
`endif

    // U->V EFLAGS forwarding + paired-V branch resolution (v_br_taken_eff)
    // extracted to core/uv_common.sv (R3): driven by the u_uv_common instance.
  end

  // `mem_ack` is the fragment-engine/FSM-visible acknowledgement, not the raw
  // external bus acknowledgement.  For a non-crossing BFM access it is high on
  // the request clock; for a crossing operation it remains low through fragment
  // one and rises only with the correctly translated, merged fragment two.
  assign pipe_mem_wait = (pipe_load_req || pipe_store_req) && !mem_ack;

  // ---- canonical fast-path issue predicate (REVIEW Aug-1 C-01/H-01/M-01) ----
  // ONE signal decides "this instruction bails to the slow functional FSM". Every
  // consumer of that decision -- the S_PIPE spine (core_fastpath.svh), the extracted
  // GPR writeback mirror (core_gpr_wb.svh), the BTB resolve arm, the I-cache LRU
  // touch arm, and the D-side request -- reads THIS signal instead of re-typing the
  // condition.
  //
  // Hand-copying it is what produced the boot failure. task #55 relaxed the spine's
  // `sys_mode` bail-out to `(sys_mode && !sys_fp_ok)` but the four mirrors kept the
  // old text. The GPR mirror (core_gpr_wb.svh:723) therefore left gpr_we==0 while the
  // spine retired the instruction and advanced EIP: MOV/ALU/LEA/shift destinations
  // were silently DISCARDED, and the next branch consumed stale registers. That is
  // exactly why the VEN_D16_NOWREG bisect -- which rejected register-writing fast ops
  // -- was the only variant that reached POST, and why decode16 (24/24) and upipe16
  // (530/530) both passed: neither unit test drives this mirror.
  //
  // H-01 is folded in here too. decode.sv can mark a checked 32-bit DS data read
  // `simple`, and in protected flat 32-bit sys mode sys_fp_ok holds, so such a read
  // could reach the issue arm -- but the D-side request is separately !sys_mode-gated
  // (pipe_load_req below), so it would retire with NO bus request and commit whatever
  // was left on mem_rdata.  The narrowly checked system fast-read profile below
  // changes that only for full-limit DS effective-address forms, which retain
  // cur_lin, D-TLB, permission, page-walk and fragment-engine handling.
  // ---- canonical fast-path INTERRUPT DIVERT --------------------------------
  // Found by re-reviewing the fast path after C-01. Task #57 added interrupt
  // acceptance as a NEW FIRST ARM of the S_PIPE spine's else-if chain:
  //
  //     if (smi_take || nmi_take || intr_take) begin ...divert... end
  //     else if (stall_cnt != 0) ...
  //
  // but added it ONLY to the spine. Every side-effect mirror still began its chain
  // at `stall_cnt`, so on an accepted interrupt they fell straight through to their
  // ISSUE arm while the spine issued nothing:
  //
  //   * core_gpr_wb.svh  committed gpr_we for an instruction that did NOT retire.
  //     The spine does not advance EIP on the divert, so after IRET that same
  //     instruction runs AGAIN -- `inc eax` increments twice, `add eax,ebx` adds
  //     twice. Silent architectural corruption on every interrupt taken while a
  //     fast-path-eligible instruction was at the head.
  //   * fpu_writeback.sv committed x87 state (fpr/ftop/fstat/fptag) the same way,
  //     so an x87 op double-executed and the stack drifted.
  //   * BTB resolve trained on a branch that never resolved; the I-cache LRU
  //     touched for an instruction that never issued (pollution, not corruption).
  //   * the D-side request still fired, so a divert clock could start a
  //     speculative translation/page-walk -- the exact mechanism behind the task
  //     #25 CWSDPMI #PF cascade.
  //
  // This is C-01's failure mode a second time: a guard chain reproduced by hand in
  // several files, extended in only one of them. So it gets the same treatment --
  // ONE signal, consumed everywhere, never re-typed.
  logic fp_irq_divert;
  // A fast-path boundary can be abandoned either for an architecturally
  // delivered interrupt or for the external quiescent debugger.  Every mirror
  // of the S_PIPE issue arm consumes this one predicate; do not reproduce the
  // guard in individual writeback/cache/request paths.
  logic fp_issue_block;
`ifdef VEN_SYS_FASTPATH
  // REVIEW2 H-06: an x87 op that burns occupancy clocks marks fp_occ_pending at issue
  // and only retires (advancing EIP and clearing the flag) when the occupancy is
  // spent. Diverting in between enters the handler with the instruction neither
  // retired nor restartable: the pending occupancy survives into the handler, so a
  // handler x87 op can skip occupancy or commit against the wrong PC, and on return
  // the instruction can execute twice. An interrupt is only architecturally taken at
  // an INSTRUCTION BOUNDARY, and mid-occupancy is not one -- so hold the divert for
  // the few clocks until the op retires. Interrupts are level-held, so nothing is
  // lost; this delays acceptance, it does not drop it.
  assign fp_irq_divert = (state == S_PIPE) && !fp_occ_pending && !dbg_fast_hold && !dbg_step_active
                      && (smi_take || nmi_take || intr_take);
`else
  // Without the sys fast path the spine has no interrupt arm at all (S_PIPE is
  // user-mode only there, and intr_take is gated on soc_en=0), so this is inert.
  assign fp_irq_divert = 1'b0;
`endif
  assign fp_issue_block = fp_irq_divert || dbg_fast_hold;

  // ---- debug facilities the fast path does NOT implement --------------------
  // core_fastpath.svh contains ZERO references to TF or to DR0-3. Both are handled
  // only by the slow FSM: tf_at_issue is latched at S_DECODE
  // (core_fetch_decode.svh:98) and the single-step #DB is raised in S_EXEC
  // (core_exec.svh:886). So with the fast path live in sys_mode, setting TF or
  // arming a breakpoint register produced NO #DB at all -- a debugger single-
  // stepping the guest would watch instructions execute silently.
  //
  // The tempting fix is to reimplement the checks in the spine. That is exactly how
  // C-01, the #57 divert, and the irq_shadow starvation all happened: a facility
  // implemented twice, then maintained once. So instead, hand the whole instruction
  // to the slow FSM whenever debugging is ARMED. TF and enabled breakpoints are rare
  // (essentially never during a boot or a game), so this costs nothing measurable,
  // and it is impossible for the fast path to silently skip a debug event.
  //
  // dr7[7:0] are the L0/G0..L3/G3 enables; nonzero means at least one breakpoint is
  // armed. eflags[8] is TF.
  logic fp_dbg_active;
  // REVIEW2 H-08: EFLAGS.RF must also send the instruction to the slow FSM. RF is
  // snapshotted AND CLEARED only in S_DECODE (core_fetch_decode.svh:99-100); it
  // suppresses an instruction breakpoint for exactly one instruction and the CPU
  // clears it on retire. A fast path that never enters S_DECODE leaves RF set
  // indefinitely, so later debug behaviour and every saved EFLAGS image are wrong.
  // Same class as the irq_shadow starvation, same conservative remedy.
  assign fp_dbg_active = eflags[8] || eflags[16] || (dr7[7:0] != 8'd0);

  // The system fast-read profile admits a data form only when ITS decoded
  // default segment is a present, writable, full 4 GiB 32-bit segment.  The
  // selector is carried from decode through the bus driver and address
  // generator, so an EBP/ESP base can never accidentally be checked as DS.
  logic sys_fp_load_ok;
`ifdef VEN_SYS_FASTLOAD_FLAT
  assign sys_fp_load_ok = sys_fp_ok && !real_mode && cs_d
                     && (seg_limit[pipe_mem_seg] == 32'hFFFF_FFFF)
                     && seg_attr[pipe_mem_seg][7] && seg_attr[pipe_mem_seg][4]
                     && !seg_attr[pipe_mem_seg][3] && seg_attr[pipe_mem_seg][1];
`else
  assign sys_fp_load_ok = 1'b0;
`endif

  // A system fast store has the same narrow segment contract as a fast load,
  // but it is deliberately a distinct opt-in: a write must preserve precise
  // #PF restart semantics, page-two validation before a split write, and the
  // D-bit timing. The shared S_PIPE producer already supplies all three:
  // pipe_store_req selects the DS/SS identity and cur_is_w drives the page walk
  // and P|W error code. The fragment engine can probe page two before either
  // write fragment escapes, but system-mode stores intentionally retain the
  // mature S_STORE path at a 4 KiB boundary until a dedicated system-crossing
  // differential workload exists. The common non-crossing case is the hot
  // general-purpose client path. verif/sys/run-pfaststore-gate.sh and
  // run-sysfpload-gate.sh prove both a protected-page restart and common-base,
  // non-identity DS/SS traffic. Keep this independently defined so a build
  // that admits fast loads cannot accidentally admit stores.
  logic sys_fp_store_ok;
  logic [31:0] sys_fp_store_lin;
  // Do NOT use cur_lin here: cur_lin is driven from pipe_store_req, which is
  // itself gated by fp_sys_bail/sys_fp_store_ok. This direct pre-request sum
  // is the same DS/SS base-plus-offset arithmetic without a combinational loop.
  assign sys_fp_store_lin = seg_base[pipe_mem_seg] + pipe_load_addr;
`ifdef VEN_SYS_FASTSTORE_FLAT
  assign sys_fp_store_ok = sys_fp_load_ok && (sys_fp_store_lin[11:0] <= 12'hFFC);
`else
  assign sys_fp_store_ok = 1'b0;
`endif

  logic fp_sys_bail;
`ifdef VEN_SYS_FASTPATH
  assign fp_sys_bail = !u_d.simple
                    || (sys_mode && !sys_fp_ok)
                    // H-01: memory forms remain slow except the explicitly
                    // audited flat 32-bit DS/SS effective-address profiles above.
                    // Their bus requests are translated/permission-checked exactly
                    // as S_LOAD/S_STORE; neither is a physical or unchecked bypass.
                    || (sys_mode && u_d.is_store && !sys_fp_store_ok)
                    || (sys_mode && u_d.is_mem && !u_d.is_store && !sys_fp_load_ok)
                    || (sys_mode && fp_dbg_active); // TF / DR armed -> slow FSM
`else
  assign fp_sys_bail = !u_d.simple || sys_mode;
`endif

  // ---- U-pipe datapath (core/u_pipe.sv, R3) --------------------------------
  // Pre-read U operands; the fast path always reads full dwords, so these are
  // exactly reg_read(idx,3'd4,1'b0) == gpr_o[idx]. The u_pipe instance drives
  // u_alu/u_flags/u_sh/u_shm1/u_shcf consumed by the eval above + S_PIPE commit.
  logic [31:0] u_dst_val, u_src_val;
  assign u_dst_val = (u_d.is_mem && !u_d.is_load && !u_d.is_store && u_d.mem_lhs)
                   ? mem_rdata : reg_read(u_d.dst, 3'd4, 1'b0);
  assign u_src_val = (u_d.is_mem && !u_d.is_load && !u_d.is_store && !u_d.mem_lhs)
                   ? mem_rdata : reg_read(u_d.src, 3'd4, 1'b0);
  u_pipe u_upipe (
    .u_d       (u_d),
    .u_dst_val (u_dst_val),
    .u_src_val (u_src_val),
    .eflags    (eflags),
    .u_alu     (u_alu),
    .u_flags   (u_flags),
    .u_sh      (u_sh),
    .u_shm1    (u_shm1),
    .u_shcf    (u_shcf),
    .u_shcnt   (u_shift_cnt)
  );

  // ---- V-pipe datapath (core/v_pipe.sv, R3) --------------------------------
  // Pre-read V operands (full dwords == reg_read(idx,3'd4,1'b0)). The v_pipe
  // instance drives v_alu/v_flags consumed by the eval above + S_PIPE commit.
  logic [31:0] v_dst_val, v_src_val;
  assign v_dst_val = reg_read(v_d.dst, 3'd4, 1'b0);
  assign v_src_val = reg_read(v_d.src, 3'd4, 1'b0);
  v_pipe u_vpipe (
    .v_d       (v_d),
    .v_dst_val (v_dst_val),
    .v_src_val (v_src_val),
    .eflags    (eflags),
    .v_alu     (v_alu),
    .v_flags   (v_flags)
  );

  // ===========================================================================
  // BTB resolve port (R2 extract, bpred_btb). The single per-clock BTB update
  // fires on the posedge ONLY when the S_PIPE issue arm executes AND a branch
  // resolves — exactly where the inline btb_update_taken() NBA used to fire.
  // This comb block reconstructs that issue-gate (the S_PIPE else-if chain's
  // final issue arm) and the VERIFIED mutually-exclusive U/V if-else-if mux,
  // driving the single resolve port:
  //   * U branch       -> resolve at (eip, u_taken)
  //   * else paired-V branch -> resolve at (eip+u.len, v_taken)
  // At most ONE write/clock (the if/else-if guarantees mutual exclusion; a
  // paired V branch and a U branch cannot both resolve — a U branch is unpaired
  // in this path). btb_lookup-vs-update is read-before-write: the predict ports
  // above read the PRE-update arrays this clock; this resolve applies next edge.
  always_comb begin
    // Issue-arm gate: the final `else` of the S_PIPE chain (matches the spine).
    // Branches are simple + non-FP, so the FP/precision/!simple arms never apply
    // to a resolving branch; the guards below are the chain conditions that gate
    // reaching the issue arm at all.
    logic issue_arm;
    logic u_res_taken, v_res_taken;
    logic [31:0] v_res_pc;
    // !fp_issue_block: an abandoned clock resolves no branch, so it must not train the BTB.
    issue_arm = (state==S_PIPE) && !fp_issue_block && !xlate_miss && !pipe_mem_wait && (stall_cnt==7'd0) &&
                pipe_bytes_ok && (pending_mem_pen==7'd0) && !u_d.is_fp &&
                // REVIEW Aug-1 M-01: canonical predicate (was `u_d.simple && !sys_mode`,
                // which left eligible system-fast branches untrained in the BTB).
                !fp_sys_bail && (mispred_bubbles==3'd0) && !pipe_agi;

    // U taken: unconditional => 1, conditional => its architectural taken.
    u_res_taken = u_d.br_cond ? u_d.br_taken : 1'b1;
    // V member branch (paired): taken via U-forwarded flags (v_br_taken_eff).
    v_res_pc    = eip + {28'd0,u_d.len};
    v_res_taken = v_br_taken_eff;

    btb_resolve_valid = 1'b0;
    btb_resolve_pc    = 32'd0;
    btb_resolve_taken = 1'b0;
    if (issue_arm) begin
      if (u_d.is_branch) begin
        btb_resolve_valid = 1'b1;
        btb_resolve_pc    = eip;
        btb_resolve_taken = u_res_taken;
      end else if (pipe_pair && v_d.is_branch) begin
        btb_resolve_valid = 1'b1;
        btb_resolve_pc    = v_res_pc;
        btb_resolve_taken = v_res_taken;
      end
    end
  end

  bpred_btb #(.BTB_SETS(BTB_SETS), .BTB_WAYS(BTB_WAYS)) u_bpred_btb (
    .clk            (clk),
    .rst_n          (rst_n),
    .u_query_pc     (btb_u_query_pc),
    .u_predict_taken(btb_u_pred),
    .v_query_pc     (btb_v_query_pc),
    .v_predict_taken(btb_v_pred),
    .resolve_valid  (btb_resolve_valid),
    .resolve_pc     (btb_resolve_pc),
    .resolve_taken  (btb_resolve_taken)
  );

  // recover the 4-bit condition code of a V conditional branch from its decode
  // (Jcc rel8 opcode low nibble was consumed into br_cond/br_taken; we re-derive
  // it from the opcode byte stored implicitly). Since fp_decode does not keep the
  // raw cc, evaluate against the V's own br_taken when no forwarding is needed
  // and only override via this helper when U forwards flags.
  function automatic logic [3:0] v_br_cc(input fpd_t d);
    // Not reachable for non-branches; the cc is encoded in br fields. We stored
    // the architectural taken under the OLD flags; to re-evaluate under new
    // flags we need the cc. fp_decode is extended to carry it below.
    v_br_cc = d.cc;
  endfunction

`ifdef VEN_DBG_CORE
  // freeze-on-#DE: sticky flag set when a divide #DE (vector 0) is delivered
  // (core_exec.svh DIV/IDIV start_fault) -> drives the PC-ring freeze in ventium_top.
  logic dbg_div_fault_q;
  assign dbg_div_fault = dbg_div_fault_q;
  // fault-capture: counter + last-fault {vec,eip,cs,ibuf}, latched in start_fault.
  logic [7:0]  dbg_fault_cnt_q;
  assign dbg_fault_cnt  = dbg_fault_cnt_q;
`endif
  // ===========================================================================
  // Main sequential FSM
  // ===========================================================================
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state<=S_RESET;
      gate_via <= 1'b0;   // bug#6 call-gate re-vector flag
`ifdef VEN_DBG_CORE
      dbg_div_fault_q <= 1'b0;
      dbg_fault_cnt_q <= 8'd0;
`endif
      // ----- M2S.1: dual boot-mode reset (docs/m2s1-segmentation-spec.md) -----
      sys_mode<=boot_mode;
      // A20 is enabled after reset in every supported platform configuration.
      // This must not be limited to system boot: the user-mode loader commonly
      // places its initial stack above 1 MiB, and an uninitialised user-reset
      // latch aliases that stack by clearing physical address bit 20.  Keeping
      // the reset assignment outside the boot-mode split also makes the A20
      // reset value agree with a20_on_q's reset baseline.
      a20_r<=1'b1;
      if (boot_mode) begin
        // SYSTEM cold reset, matching qemu-system-i386: CS:EIP=F000:FFF0, real
        // mode (CR0.PE=0, cr0=0x60000010), EDX=0x00000663 (P5 stepping sig),
        // eflags=0x00000002. The reset CS hidden base is 0xFFFF0000 on a real
        // P5, but qemu-system reports EIP=0xFFF0 and the bare-metal image is
        // loaded at the LOW alias 0x000F0000; the reset stub immediately
        // far-jumps to segment 0xF000 (base 0x000F0000), so we seed CS.base =
        // 0x000F0000 here (fetch linear = 0x000F0000 + 0xFFF0 = 0x000FFFF0,
        // exactly where the TB loads the image's last 16 bytes).
        eip<=32'h0000_FFF0; eflags<=32'h0000_0002;
        // GPR reset (system: EDX = CPUID sig 0x543/0x663, others 0) lives in
        // u_regfile's own synchronous rst_n arm now (R3) — driven by boot_mode/cosim_en.
        creg0<=32'h6000_0010; creg2<=32'd0; creg3<=32'd0; creg4<=32'd0;
        xp_pend<=1'b0; xp_lo<=32'd0; xp_first<=3'd0; xp_w<=3'd0;  // REVIEW2 C-02
        xs_ph<=2'd0; xs_act<=1'b0; xs_first<=3'd0;                // REVIEW2 C-02 store
        for (int s=0;s<NUM_SEG;s++) begin
          seg_sel[s]<=16'h0000; seg_base[s]<=32'd0; seg_limit[s]<=32'h0000_FFFF;
          // real-mode segs behave as present R/W data (attr only matters in PM):
          // P=1 DPL=0 S=1 type=writable-data (0x93).
          seg_attr[s]<=8'h93;
          seg_b[s]<=1'b1;   // 4 GiB bound until a descriptor says otherwise
          seg_pm_loaded[s]<=1'b0;   // R2-H07: nothing PM-loaded out of reset
        end
        seg_sel[SG_CS]<=16'hF000; seg_base[SG_CS]<=32'h000F_0000;
        seg_attr[SG_CS]<=8'h9B;   // CS: present readable code (P=1 S=1 type=0xB)
        cpl_r<=2'd0;              // reset CPL = 0
        gdt_base<=32'd0; gdt_limit<=16'd0; idt_base<=32'd0; idt_limit<=16'h03FF;
        ldt_base<=32'd0; ldt_limit<=16'd0; ldt_sel<=16'd0; q_seg_from_mem<=1'b0;
        dbg_de_cnt_r<=13'd0;
`ifdef VEN_DBG_CORE
        dbg_de_num<=64'd0; dbg_de_info<=64'd0;   // ports exist only under VEN_DBG_CORE
        dbg_hook_seq<=8'd0; dbg_hook_eip<=32'd0; dbg_hook_opa<=64'd0; dbg_hook_opb<=32'd0; dbg_hook_meta<=32'd0;
`endif
        cs_d<=1'b0;   // real-mode CS: 16-bit default operand/address size
      ss_b<=1'b1;   // C-07: default 32-bit stack (user mode / pre-descriptor PM)
      end else begin
        eip<=init_eip;
`ifdef VEN_SNAPSHOT_RESTORE
        eflags<=snapshot_restore ? snapshot_eflags : EFLAGS_RESET;
`else
        eflags<=EFLAGS_RESET;
`endif
        // GPR reset (user: ESP = init_esp, others 0) lives in u_regfile's own
        // synchronous rst_n arm now (R3) — driven by boot_mode/init_esp.
        creg0<=32'd0; creg2<=32'd0; creg3<=32'd0; creg4<=32'd0;
        for (int s=0;s<NUM_SEG;s++) begin
          seg_sel[s]<=16'h0000; seg_base[s]<=32'd0; seg_limit[s]<=32'hFFFF_FFFF;
          seg_attr[s]<=8'h93;   // flat present R/W (unused in user mode; benign)
          seg_b[s]<=1'b1;   // 4 GiB bound until a descriptor says otherwise
          seg_pm_loaded[s]<=1'b0;   // R2-H07
        end
        // M7.1 proxy: seed the LIVE selectors to the linux-user SEG_* constants so
        // the proxy snap can report them live (a later `mov gs,0x33` updates GS).
        // Bases stay 0 (flat) so addressing is byte-identical until GS is set.
        // INERT when proxy_en==0: seg_sel[] stay 0 (the snap uses the SEG_*
        // constants in that path), so non-proxy user runs are bit-identical.
`ifdef VEN_SNAPSHOT_RESTORE
        if (snapshot_restore) begin
          seg_sel[SG_CS]<=snapshot_cs; seg_sel[SG_SS]<=snapshot_ss;
          seg_sel[SG_DS]<=snapshot_ds; seg_sel[SG_ES]<=snapshot_es;
          seg_sel[SG_FS]<=snapshot_fs; seg_sel[SG_GS]<=snapshot_gs;
          seg_base[SG_SS]<=snapshot_ss_base; seg_base[SG_DS]<=snapshot_ds_base;
          seg_base[SG_ES]<=snapshot_es_base; seg_base[SG_FS]<=snapshot_fs_base;
          seg_base[SG_GS]<=snapshot_gs_base;
        end else if (proxy_en) begin
`else
        if (proxy_en) begin
`endif
          seg_sel[SG_CS]<=SEG_CS; seg_sel[SG_SS]<=SEG_SS; seg_sel[SG_DS]<=SEG_DS;
          seg_sel[SG_ES]<=SEG_ES; seg_sel[SG_FS]<=SEG_FS; seg_sel[SG_GS]<=SEG_GS;
        end
        seg_attr[SG_CS]<=8'h9B;
        cpl_r<=2'd0;
        gdt_base<=32'd0; gdt_limit<=16'd0; idt_base<=32'd0; idt_limit<=16'd0;
        ldt_base<=32'd0; ldt_limit<=16'd0; ldt_sel<=16'd0; q_seg_from_mem<=1'b0;
        dbg_de_cnt_r<=13'd0;
`ifdef VEN_DBG_CORE
        dbg_de_num<=64'd0; dbg_de_info<=64'd0;   // ports exist only under VEN_DBG_CORE
        dbg_hook_seq<=8'd0; dbg_hook_eip<=32'd0; dbg_hook_opa<=64'd0; dbg_hook_opb<=32'd0; dbg_hook_meta<=32'd0;
`endif
        cs_d<=1'b1;   // user mode: flat 32-bit (def16 is gated off by !sys_mode)
        ss_b<=1'b1;   // C-07: user-mode stack is 32-bit -> stk16 stays identity
      end
      fetch_word<=3'd0; retire_valid<=1'b0; step<=4'd0;
`ifdef VEN_UOPCACHE
      sfetch_uop_q<=1'b0;
`endif
`ifdef VEN_SFETCH_RESIDENT
      sfetch_resident_q<=1'b0;
`endif
      // x87 reset = FNINIT state (control 0x037f, status 0, TOP 0, all empty) now
      // lives in u_fpu_state's own rst_n arm (rtl/fpu/fpu_top.sv) — ftop/fctrl/
      // fstat/fptag/fpr[] are reset there. Only the spine-side touch flag here.
      x87_touched_r<=1'b0; f_step<=4'd0; f_seq_step<=5'd0;
      hung_r<=1'b0;   // M6 Erratum 81: not hung out of reset.
`ifdef VEN_SNAPSHOT_RESTORE
      gs_base_r<=snapshot_restore && !boot_mode ? snapshot_gs_base : 32'd0;
`else
      gs_base_r<=32'd0;
`endif
      cn<=64'd0;   // M7.1 proxy: no TLS base yet; retire count 0
      tsc<=64'd0;                    // F3: time-stamp counter zeroed at reset (RDTSC)
`ifdef VEN_TRACE_IRQ
      dbg_if_q<=1'b0; dbg_cs_q<=16'hF000; dbg_csb_q<=32'h000F_0000;
`endif
`ifdef VEN_DBG_WD
      dbg_stall<=24'd0;
`endif
`ifdef VEN_PS_PROXY
      q_proxy_len<=4'd0;
`endif
      fold_pending_r<=1'b0; fold_pc_r<=32'd0;   // M7.1: no folded syscall in flight
      fx_abort_q<=1'b0;                         // no fragment abort in flight
      // (fpr[] cleared in u_fpu_state's rst_n arm.)
      // M4 pipeline state.
      pf_fill_addr<=32'd0; pf_word<=3'd0; pf_fill_way<='0;
      agi_wr0<=9'h100; agi_wr1<=9'h100; mispred_bubbles<=3'd0;
      // M5 cycle-accuracy state.
`ifdef VEN_TEST_CYCWRAP
      core_cyc<=32'hFB000000;   // TEST-ONLY: wrap core_cyc ~84M cyc (during Quake FP code) to
                                 // reproduce the HW core_cyc-wrap FP-scoreboard S_PIPE stall in sim.
`else
      core_cyc<=32'd0;
`endif
      fp_ready_cyc<=32'd0; pending_mem_pen<=7'd0; stall_cnt<=7'd0;
      fp_occ_pending<=1'b0; fp_issue_cyc<=32'd0;
`ifdef VEN_FP_OVERLAP
      fp_busy_cyc<=32'd0;
`endif
`ifdef VEN_FP_PIPE
      fpp_valid<=1'b0; fpp_stkflt<=1'b0;
`ifdef VEN_FP_PIPE2
      fpp2_valid<=1'b0; fpp2_stkflt<=1'b0;
`endif
`endif
      // D-cache timing arrays (dc_tag/dc_val/dc_lru) are reset inside the
      // dcache_timing module's own rst_n arm (rtl/mem/dcache.sv).
      retire2_valid<=1'b0; retire_pipe_valid<=1'b0;
      retire_pipe<=2'd0; retire_paired<=1'b0;
      retire2_pipe<=2'd0; retire2_paired<=1'b0;
      // BTB arrays (btb_tag/btb_ctr/btb_val/btb_rr) are reset inside the
      // bpred_btb module's own rst_n arm (rtl/core/bpred_btb.sv).
      // I-cache arrays (ic_data/ic_tag/ic_val/ic_lru) are reset inside the icache
      // module's own rst_n arm (rtl/mem/icache.sv) — u_icache.
      // M2S.2 paging: the TLB arrays are reset inside the tlb module's own rst_n
      // arm (rtl/mem/tlb.sv) — u_itlb / u_dtlb. Only the page-walk FSM regs (which
      // stay in the spine) are reset here.
      walk_ret_state<=S_PIPE; walk_lin<=32'd0; walk_for_d<=1'b0;
      walk_is_write<=1'b0; walk_set_dirty<=1'b0; walk_usr_lat<=1'b0; walk_step<=3'd0; walk_pde<=32'd0; walk_pte<=32'd0;
      walk_pde_addr<=32'd0; walk_pte_addr<=32'd0; walk_pf<=1'b0; pf_errcode<=3'd0;
      // M2S.3 IDT delivery state idle out of reset.
      int_vec<=8'd0; int_ret_eip<=32'd0; int_src_pc<=32'd0; int_has_err<=1'b0;
      int_err<=32'd0; int_step<=4'd0; rm_read_armed<=1'b0;
      int_gate_off<=32'd0; int_gate_sel<=16'd0;
      int_gate_trap<=1'b0; int_gate_op16<=1'b0; int_lo<=32'd0; iret_eip<=32'd0; iret_cs<=16'd0;
      int_cs_base<=32'd0; int_cs_limit<=32'd0; int_cs_attr<=8'd0; int_cs_d<=1'b0;
      int_ss_base<=32'd0; int_ss_limit<=32'd0; int_ss_attr<=8'd0; int_ss_b<=1'b0;
      int_frm_nslots<=6'd0; int_frm_wide<=1'b0; frame_plan_start<=1'b0;
      frm_pg_val<=4'd0; frm_pg_markd<=1'b0; frm_pg_i<=3'd0; frm_pg_n<=3'd0;
      for (int i = 0; i < 4; i++) begin
        frm_pg_lin[i]<=20'd0; frm_pg_addr[i]<=32'd0; frm_pg_phys[i]<=20'd0;
        frm_pg_mid[i]<=1'b0; frm_pg_dirty[i]<=1'b0;
      end
      ntret_pend<=1'b0; retf_out<=1'b0; retf_ob<=1'b0; retf_same<=1'b0; cg_xpl<=1'b0; cg_pcount<=5'd0;
      cg_wide<=1'b0; cg_beat<=6'd0;   // R2-H05
      lcall_pend<=1'b0; tsw_call<=1'b0; lc_cs_base<=32'd0; lc_cs_limit<=32'd0;
      lc_cs_attr<=8'd0; lc_cs_d<=1'b0; lc_cs_cpl<=2'd0; lc_gate<=1'b0; lc_gw<=1'b0;
      int_sw<=1'b0; dlv_ext<=1'b0;
      ioperm_ret<=S_IO; ioperm_port<=16'd0; ioperm_base<=16'd0;
      dlv_depth<=2'd0; dlv_ctrb<=1'b0; dlv_pf<=1'b0;  // REVIEW_aug2 H-04
      // M2S.4 TR/TSS + cross-priv + inter-priv IRET state idle out of reset.
      tr_sel<=16'd0; tr_base<=32'd0; tr_limit<=32'd0; tr_valid<=1'b0; tr_attr<=8'd0;
      ltr_busy_q<=1'b0; ltr_sel_q<=16'd0; ltr_base_q<=32'd0; ltr_limit_q<=32'd0;
      ltr_attr_q<=8'd0; lldt_null_q<=1'b0;
      // M2S.4b task-switch scratch idle out of reset (the tsw_* holding regs are
      // fully written by S_TSW_READ/_SEG before being committed in S_TSW_BUSY).
      tsw_step<=5'd0; tsw_new_base<=32'd0; tsw_new_limit<=32'd0; tsw_new_sel<=16'd0;
      tsw_new_attr<=8'd0; tsw_save_eip<=32'd0; tsw_save_eflags<=32'd0; tsw_eip<=32'd0; tsw_eflags<=32'd0;
      tsw_cr3<=32'd0; tsw_seg_lo<=32'd0;
      iret_eflags<=32'd0; xpl_active<=1'b0; int_old_ss<=16'd0; int_old_esp<=32'd0;
      int_old_cs<=16'd0; int_new_cpl<=2'd0; int_new_ss<=16'd0; int_new_esp<=32'd0;
      iret_interpriv<=1'b0; iret_ss<=16'd0; iret_esp<=32'd0;
      // M7.2 V86 delivery scratch idle out of reset.
      from_v86<=1'b0; int_old_ds<=16'd0; int_old_es<=16'd0; int_old_fs<=16'd0;
      int_old_gs<=16'd0; int_old_eflags<=32'd0;
      iret_to_v86<=1'b0; iret_v86_es<=16'd0; iret_v86_ds<=16'd0;
      iret_v86_fs<=16'd0; iret_v86_gs<=16'd0;
      // M2S.5 SMM/RSM idle out of reset. SMBASE = the P5 default 0x30000; not in
      // SMM; no SMI pending. (RSM read-back regs are scratch — left uninit; they
      // are fully written by S_RSM before being committed.)
      smbase<=32'h0003_0000; smm_active<=1'b0; smi_pending<=1'b0;
      smm_step<=6'd0; smm_resume_eip<=32'd0;
      // M8.1 external-interrupt latches idle out of reset (all INERT when soc_en==0).
      intr_pending<=1'b0; nmi_pending<=1'b0; nmi_prev<=1'b0;
      irq_shadow<=1'b0; nmi_nest<=4'd0;
`ifdef SYNTHESIS
      nmi_in_progress<=1'b0;
`else
      // REVIEW_aug2 H-05 stimulus: +ven_nmi_arm pretends an NMI handler is already
      // running so the "a faulting IRET must not re-arm NMI" property is REACHABLE.
      // Without the plusarg this is identical to the synthesis path.
      nmi_in_progress    <= ven_nmi_arm_en;
      ven_h05_armed_faults <= 0;
`endif
      // M2S.6 debug registers idle out of reset (Vol.3 power-on values). The DR
      // file resets identically in user mode — it is just never written there.
      dr0<=32'd0; dr1<=32'd0; dr2<=32'd0; dr3<=32'd0;
      dr6<=DR6_FIXED_1; dr7<=DR7_FIXED_1;
      tf_at_issue<=1'b0; rf_at_issue<=1'b0; db_wp_extra<=1'b0;
      // M6B Erratum 79: no erroneous-#DB chain pending out of reset.
      err79_pending<=1'b0; err79_dr6_bits<=4'd0;
    end else begin
      // per-cycle default: the fragment-abort request is a one-cycle pulse
      // (start_fault re-raises it; the engine block only reads it).
      fx_abort_q <= 1'b0;
      frame_plan_start <= 1'b0;
      // REVIEW1_Aug3 R2-H07: the PE-drop backstop for the now-EXPLICIT
      // seg_pm_loaded (every load site writes it directly; see the case arms).
      // Leaving protected mode clears every segment's loaded bit -- real-mode
      // hidden state is legitimate until a PM reload (the measured pseg
      // transition-window semantics). No PM load site runs with PE=0, so this
      // never races a site write; textual order would give the site the win
      // anyway.
      if (!creg0[0])
        for (int i = 0; i < NUM_SEG; i++) seg_pm_loaded[i] <= 1'b0;
      // M7.1 proxy: mirror ventium_top's retire_n on the SAME posedge it counts
      // (the registered retire_valid/retire2_valid of the PREVIOUS clock). cn thus
      // equals the number of retirements already emitted, so an int-0x80 in
      // S_DECODE this clock names its own upcoming record as syscall_n=cn. INERT
      // when proxy_en==0 (cn is simply never read). The folded-syscall retire (the
      // insn after cd80) is the one that clears fold_pending_r — after it the
      // overridden pc is no longer needed.
      if (retire_valid) begin
        cn <= cn + (retire2_valid ? 64'd2 : 64'd1);
        fold_pending_r <= 1'b0;
      end

      // F3: the time-stamp counter free-runs at the core clock (one tick / clk),
      // independent of retirement. RDTSC samples it. INERT for the user-mode corpus
      // (no test executes RDTSC, so the reg is never read and the trace is identical).
      tsc <= tsc + 64'd1;

`ifdef VEN_DBG_WD
      // sim-only hang watchdog (opt-in via +define+VEN_DBG_WD): dump the wedged FSM
      // state after a long no-retire stall.  It re-arms periodically, so a true
      // deadlock is distinguishable from a transient long-latency operation.
      // state.name() localises the wedge (S_FETCH=icache fill hang,
      // S_USEQ=microcode loop, S_LOAD/2=data-load wait, S_WALK=page walk, ...).
      if (retire_valid || retire2_valid) dbg_stall <= 24'd0;
      else if (dbg_stall >= 24'd1000000) begin
        dbg_stall <= 24'd0;   // re-arm so a persistent stall keeps reporting
        $display("[VEN-WD] STUCK state=%s eip=%08h csbase=%08h | mem_req=%b mem_ack=%b mem_addr=%08h | ds_sel=%04h ds_base=%08h ds_lim=%08h | cr0=%08h v86=%b real=%b sysm=%b eflags=%08h cpl=%0d",
                 state.name(), eip, seg_base[SG_CS], mem_req, mem_ack, mem_addr,
                 seg_sel[SG_DS], seg_base[SG_DS], seg_limit[SG_DS],
                 creg0, v86, real_mode, sys_mode, eflags, cpl_r);
      end
      else dbg_stall <= dbg_stall + 24'd1;
`endif

`ifdef VEN_TRACE_IRQ
      // sim-only IRQ-entry forensic trace (opt-in via +define+VEN_TRACE_IRQ): the
      // FreeDOS interrupt-delivery derail. Print the EXACT state at each maskable-IRQ
      // accept (state==S_DECODE && intr_take), so we can see whether the interrupted
      // eip exceeds the CS limit (the no-wrap / big-real question) and whether IF was
      // legitimately 1. Also log every IF transition with its eip to find the last
      // STI/CLI before the fatal frame. Inert unless the define is set.
      if (state==S_DECODE && intr_take) begin
        $display("[IRQ-TAKE] t=%0t vec=%02x eip=%08x cs_sel=%04x cs_base=%08x cs_lim=%08x cs_attr=%02x eflags=%08x IF=%b ip_trunc=%b",
                 $time, inta_vector, eip, seg_sel[SG_CS], seg_base[SG_CS],
                 seg_limit[SG_CS], seg_attr[SG_CS], eflags, eflags[9], |eip[31:16]);
      end
      if (eflags[9] != dbg_if_q) begin
        $display("[IF-CHG]  t=%0t IF %b->%b eip=%08x cs_sel=%04x", $time, dbg_if_q, eflags[9], eip, seg_sel[SG_CS]);
        dbg_if_q <= eflags[9];
      end
      if (seg_sel[SG_CS] != dbg_cs_q || seg_base[SG_CS] != dbg_csb_q) begin
        $display("[CS-CHG]  t=%0t state=%s cs_sel %04x->%04x cs_base %08x->%08x eip=%08x eax=%08x edx=%08x dsb=%08x",
                 $time, state.name(), dbg_cs_q, seg_sel[SG_CS], dbg_csb_q, seg_base[SG_CS], eip,
                 gpr_o[R_EAX], gpr_o[R_EDX], seg_base[SG_DS]);
        dbg_cs_q  <= seg_sel[SG_CS];
        dbg_csb_q <= seg_base[SG_CS];
      end
      // real-mode IRET pop: show the CS/IP/FLAGS it restored + the stack it read from.
      if (state==S_RMIRET && mem_ack && int_step==4'd2) begin
        $display("[RMIRET]  t=%0t pop cs=%04x ip=%04x flags=%04x  (SS:SP read @ %08x)",
                 $time, iret_cs, iret_eip[15:0], mem_rdata[15:0],
                 seg_base[SG_SS] + (gpr_o[R_ESP] + {27'd0, int_step, 1'b0}));
      end
      // real-mode INT push: show the CS/IP it pushed onto the stack.
      if (state==S_RMINT_PUSH && mem_ack && int_step==4'd2) begin
        $display("[RMPUSH]  t=%0t push cs=%04x ip=%04x (int_ret_eip=%08x) -> resume gate cs=%04x:%04x",
                 $time, seg_sel[SG_CS], int_ret_eip[15:0], int_ret_eip, int_gate_sel, int_gate_off[15:0]);
      end
`endif

`ifdef VEN_DBG_CORE
      // ------------------------------------------------------------------
      // task #102 — IRET frame-sizing forensic trace (mirrors VEN_RETDUMP /
      // VEN_WATCH: env/plusarg-gated, inert by default). Catches the ONE
      // transition IRET where Ventium sizes the popped frame 6 bytes (16-bit
      // IRETW) but qemu uses 12 (32-bit), reading cs_d / int_gate_op16 /
      // eff_opsize at the deciding instruction. Enable with the +ven_iretdbg
      // plusarg; bracket the retire window with +ven_iretdbg_lo / +ven_iretdbg_hi
      // (defaults open). Also logs every mov-cr0 PE toggle (where cs_d is NOT
      // reloaded) so a stale cs_d crossing a real<->PM transition is visible.
      if (ven_iretdbg_en) begin
        // mov cr0 with a PE transition (CWSDPMI real<->PM crossing): cs_d is NOT
        // updated here today. ALWAYS log (these are rare) so a stale cs_d crossing
        // is visible regardless of the retire window.
        if (state==S_EXEC && q_sysop==SYS_MOVCR_TO && q_sys_creg==3'd0 &&
            (gpr_o[q_src_reg][0] != creg0[0])) begin
          $display("[IRETDBG] cn=%0d MOVCR0 pe %b->%b cs_d=%b(stale) cs=%04x eip=%08x esp=%08x",
                   cn, creg0[0], gpr_o[q_src_reg][0], cs_d, seg_sel[SG_CS], eip, gpr_o[R_ESP]);
        end
        // S_IRET (PM / V86) same-priv commit: int_step 2, the frame-size choice.
        // ALWAYS log (PM IRETs are comparatively rare vs the RMIRET timer storm).
        if (state==S_IRET && mem_ack && int_step==4'd2) begin
          $display("[IRETDBG] cn=%0d S_IRET cs=%04x eip=%08x cs_d=%b op16=%b eff_opsize=%b real=%b pe=%b esp_before=%08x delta=%0d csbase=%08x",
                   cn, seg_sel[SG_CS], eip, cs_d, int_gate_op16, eff_opsize,
                   real_mode, creg0[0], gpr_o[R_ESP],
                   (int_gate_op16 ? 6 : 12), seg_base[SG_CS]);
        end
        // S_RMIRET (pure real-mode) commit: int_step 2, always +6. Windowed
        // (the timer-IRQ storm floods this) by ven_iretdbg_lo/hi.
        if (state==S_RMIRET && mem_ack && int_step==4'd2 &&
            cn >= ven_iretdbg_lo && cn <= ven_iretdbg_hi) begin
          $display("[IRETDBG] cn=%0d S_RMIRET cs=%04x ip=%04x cs_d=%b real=%b pe=%b esp_before=%08x delta=6 csbase=%08x",
                   cn, iret_cs, iret_eip[15:0], cs_d, real_mode, creg0[0],
                   gpr_o[R_ESP], seg_base[SG_CS]);
        end
      end
      // task #102 micro-TLB data-store translate forensic (inert by default).
      // Fires on every clock a translatable D access whose LINEAR page OR whose
      // (registered/translated) PHYSICAL page matches the watch — so a store that
      // drives the WRONG physical (linear==watch but mem_addr!=watch, or vice
      // versa) is caught. Also logs mem_wdata so the actual stored value is seen.
      if (ven_tlbdbg_en && paging_on && cur_is_d && mem_req &&
          cn >= ven_tlbdbg_lo && cn <= ven_tlbdbg_hi &&
          ((cur_lin[31:12]  == ven_tlbdbg_lin[31:12]) ||
           (mem_addr[31:12] == ven_tlbdbg_lin[31:12]) ||
           (ven_tlbdbg_cpl3w && cur_is_w && (seg_sel[SG_CS][1:0] == 2'b11)))) begin
`ifdef VEN_FE_PIPE
        $display("[TLBDBG] cn=%0d st=%0d cs=%04x eip=%08x cur_lin=%08x is_w=%b mem_req=%b mem_we=%b mem_addr=%08x wdata=%08x | fe_v=%b fe_page=%05x fe_phys=%05x fe_hit=%b fe_dirty=%b | xlate_miss=%b fe_pend=%b walk_step=%0d lk_hit=%b lk_phys=%08x lk_dirty=%b",
                 cn, state, seg_sel[SG_CS], eip, cur_lin, cur_is_w,
                 mem_req, mem_we, mem_addr, mem_wdata,
                 fe_dtlb_v, fe_dtlb_page, fe_dtlb_phys, fe_dtlb_hit, fe_dtlb_dirty,
                 xlate_miss, fe_xlate_pend, walk_step, dtlb_lk_hit, dtlb_lk_phys, dtlb_lk_dirty);
`endif
      end
`ifdef VEN_FE_PIPE
      // task #102 MISTRANSLATE assertion: a translatable D access PROCEEDS this
      // clock (mem_req, not diverted/stalled) but the registered micro-TLB physical
      // (driven onto mem_addr) DISAGREES with the fresh combinational lookup at the
      // SAME cur_lin -> a wrong-physical event (the data-store-under-paging class).
      // Inert unless +ven_tlbdbg; reusable to catch any future regression of this
      // exact failure mode (the mem_xlate page-match guard makes it unreachable).
      if (ven_tlbdbg_en && paging_on && fe_translatable && cur_is_d && mem_req &&
          !xlate_miss && !fe_xlate_pend && dtlb_lk_hit &&
          (mem_addr[31:12] != dtlb_lk_phys[31:12]) &&
          cn >= ven_tlbdbg_lo && cn <= ven_tlbdbg_hi) begin
        $display("[TLBMISXLAT] cn=%0d st=%0d cs=%04x eip=%08x cur_lin=%08x is_w=%b mem_addr=%08x(BAD) lk_phys=%08x(GOOD) | fe_v=%b fe_page=%05x fe_phys=%05x fe_hit=%b",
                 cn, state, seg_sel[SG_CS], eip, cur_lin, cur_is_w,
                 mem_addr, dtlb_lk_phys, fe_dtlb_v, fe_dtlb_page, fe_dtlb_phys, fe_dtlb_hit);
      end
`endif
`endif

      retire_valid <= 1'b0;
      retire2_valid <= 1'b0;
      retire_pipe_valid <= 1'b0;
      // x87-touched defaults low each cycle; only the x87 retire paths
      // (S_FEXEC / S_FSTORE) raise it, so the DPI x87 hook fires only for FPU
      // instructions. (ventium_top gates vtm_retire_x87 on this.)
      x87_touched_r <= 1'b0;

      // M5: advance the free-running core-clock counter (the timeline the FP
      // scoreboard + miss-stall countdowns live on). It tracks the TB's
      // cyc=clock-count-at-retire 1:1 (core_cyc is the count of completed clocks
      // before this edge; a retire on this edge stamps cyc=core_cyc+1).
      core_cyc <= core_cyc + 32'd1;

`ifdef VEN_FP_PIPE
      // +VEN_FP_PIPE: advance the 1-deep FP-execute pipeline. A pipelined FK_ARITH
      // issued this clock (fp_pipe_cap) latches its operands; fpp_valid is the
      // in-flight bit consumed next clock by the we_wabs deferred commit. Exactly
      // one capture per clock (the fast arm issues at most one FP op), so the
      // register is consumed (committed) and reloaded in the same clock cleanly.
      fpp_valid <= fp_pipe_cap;
      if (fp_pipe_cap) begin
        fpp_aluop <= fp_cap_aluop; fpp_a <= fp_cap_a; fpp_b <= fp_cap_b;
        fpp_rc    <= fp_cap_rc;    fpp_pc  <= fp_cap_pc;
        fpp_err   <= fp_cap_err;   fpp_dst <= fp_cap_dst;
        fpp_stkflt <= fp_cap_stkflt;   // R2-H06
      end
`ifdef VEN_FP_PIPE2
      // Stage 1 -> stage 2: register the f_eval_s1 result one clock after capture.
      // A captured op (fpp_valid this clock) advances into the stage-2 slot; its
      // we_wabs commit fires the NEXT clock from fpp2_s1. At most one op per clock
      // enters each slot (the fast arm issues <=1 FP op), so the two stages never
      // collide.
      fpp2_valid <= fpp_valid;
      if (fpp_valid) begin
        fpp2_s1  <= fp_s1_next;
        fpp2_rc  <= fpp_rc;
        fpp2_pc  <= fpp_pc;
        fpp2_dst <= fpp_dst;
        fpp2_stkflt <= fpp_stkflt;   // R2-H06
      end
`endif
`endif

      // -------------------------------------------------------------------
      // M8.1 — sample the external-interrupt pins (mirror smi_pending). Done
      // every non-reset clock, BEFORE the state machine, so the S_DECODE divert
      // sees the current request. ALL gated on soc_en: with the pins tied off
      // (soc_en==0, ventium_top) intr_pending/nmi_pending hold 0 forever and the
      // divert is dead — the core is byte-identical to the M0-M7 core.
      //   * intr is a LEVEL request (the 8259 holds INT until serviced): mirror it
      //     into intr_pending. The divert consumes it (delivers) only when IF=1 +
      //     no shadow; the PIC drops INT after the inta, so intr falls and
      //     intr_pending clears naturally on the next sample.
      //   * nmi is an EDGE request: latch nmi_pending on a rising edge (nmi_prev
      //     remembers the last level). Once latched it is sticky until the NMI
      //     divert consumes it; a further edge while a handler runs is held by
      //     nmi_in_progress, re-armed by the IRET (S_DECODE d_iret).
      // -------------------------------------------------------------------
      if (soc_en) begin
        intr_pending <= intr;                       // level mirror
        nmi_prev     <= nmi;                        // remember the level for edge detect
        if (nmi && !nmi_prev) nmi_pending <= 1'b1;  // latch a rising edge
      end

      // -------------------------------------------------------------------
      // M2S.2 PAGING DIVERSION: when paging is on and the current state's
      // translatable memory access MISSES the relevant TLB, run a 2-level page
      // walk (S_WALK) FIRST, then resume this state (it then hits the TLB and
      // completes against the physical address). The walk reads the PDE and PTE
      // from physical memory, sets A (and D on a write) in the tables, and fills
      // the TLB. The normal state body is skipped this clock (no mem_ack
      // processed) because the bus this clock is the PDE read, not the access.
      // -------------------------------------------------------------------
      // REVIEW2 C-01: PERMISSION #PF (page PRESENT but US/RW protection fails).
      // Mutually exclusive with xlate_miss by construction -- this fires only on a TLB
      // HIT, that one only on a miss -- but ordered first so the exclusion is stated,
      // not inferred. CR2 = the faulting linear address; the error code carries P=1,
      // which is what distinguishes this from the S_WALK not-present fault.
      // ---- REVIEW2_Aug1 C-06: SEGMENT limit violation, delivered AT THE ACCESS ----
      // Ordered BEFORE the paging faults on purpose: segmentation precedes paging, so
      // an offset outside the segment must #GP without ever producing a linear address
      // to translate, let alone a #PF. Delivered here, beside perm_fault, because this
      // is where a per-access fault belongs -- the decode arm runs a state too early
      // (measured: seg_access_fault asserts in S_LOAD, st=3).
      // #GP(0): every access that reaches here is one whose governing descriptor dseg
      // provably names (core_bus_driver.svh excludes the far-transfer stack states,
      // whose base is SS but whose dseg does not follow it).
`ifdef VEN_SEG_ENFORCE
      if (seg_access_fault) begin
        // REVIEW2_aug2 H-05: a violation of an SS-based access is #SS(0), not #GP(0)
        // (IA-32: stack-segment limit and presence violations use vector 12). Every
        // violation was delivered as #GP, so a handler distinguishing the two -- which
        // is the normal way software grows a stack -- saw the wrong one.
        start_fault((cur_seg_idx == 3'(SG_SS)) ? 8'd12 : 8'd13, 1'b1, 32'd0, q_pc);
      end else if (cs_fetch_fault || cs_extent_fault) begin
        // An instruction fetched from outside CS.limit is #GP(0), and like the data
        // side it precedes paging: no linear address should be translated for it.
        // Both forms stamp eip (the offending instruction; q_pc still lags it).
        start_fault(8'd13, 1'b1, 32'd0, eip);
      end else
`endif
      if (perm_fault) begin
        creg2 <= cur_lin;
        // S_PIPE has not staged q_pc: a D-TLB permission fault on a fast
        // load (or an I-side fill fault) must save the current instruction,
        // not the prior retired instruction.
        start_fault(8'd14, 1'b1, perm_err, (state==S_PIPE) ? eip : q_pc);
      end else if (xlate_miss) begin
        walk_ret_state <= state;
        walk_lin       <= cur_lin;
        walk_for_d     <= cur_is_d;
        // REVIEW1_Aug2 C-02: a walk triggered BY THE PROBE must not set Dirty --
        // the store may still fault on page 1 and never happen. Phase 2 walks
        // again for the real write and sets it then.
        // REVIEW2_aug2 H-02: ONE signal was doing TWO jobs. `!xs_probing` exists so a
        // phase-zero crossing-store PROBE does not set Dirty -- but walk_is_write also
        // feeds the #PF error code's W/R bit, so an architectural WRITE whose second
        // page is non-present or reserved reported W/R=0, i.e. a READ fault. A handler
        // doing copy-on-write on that report would map the page read-only and loop.
        // Split the two meanings; only the Dirty decision keeps the probe suppression.
        walk_is_write  <= cur_is_w;                   // architectural class -> #PF W/R
        // R2-C03: the fragment engine's write probe is the same excluded class.
        // The frame-probe VALIDATION phase (S_INT_PROBE, frm_pg_markd=0) is the
        // same not-a-write class; its D-mark phase (frm_pg_markd=1) sets D
        // deliberately, pre-commit.
        walk_set_dirty <= cur_is_w && !(xs_probing || fx_probing || fp_store_probing
                                        || ((state==S_INT_PROBE) && !frm_pg_markd));    // may set D -> probe excluded
        walk_usr_lat   <= acc_usr;   // REVIEW1_Aug2 C-04: latch the requester's class
        walk_step      <= 3'd0;
        walk_pf        <= 1'b0;
        // PDE physical address = (CR3 & ~0xFFF) + PDIndex*4, PDIndex = lin[31:22].
        walk_pde_addr  <= {creg3[31:12], cur_lin[31:22], 2'b00};
        state          <= S_WALK;
      end else if (fe_xlate_pend) begin
        // +VEN_FE_PIPE page-crossing stall: HOLD 1 clock (no state/eip/issue/bus this
        // edge) while the fe_*_q micro-TLB register samples cur_lin's translate (the
        // separate always_ff below). Next edge the register is valid -> proceed.
        // Inert in the default build (fe_xlate_pend tied 0 -> this arm is unreachable).
      end else
      unique case (state)
        // dual-issue fast-path + icache-fill arms (S_RESET / S_PF / S_PIPE) —
        // relocated VERBATIM into core_fastpath.svh (RAW case-arms, the first run
        // right after the `unique case (state)` header; pasted here in the FSM).
        `include "core_fastpath.svh"

        // fetch + decode-dispatch arms (S_FETCH / S_DECODE) — relocated VERBATIM
        // into core_fetch_decode.svh (RAW case-arms, pasted here in the FSM).
        `include "core_fetch_decode.svh"

        // data-load arms (S_LOAD / S_LOAD2 / S_FLOAD) — relocated VERBATIM into
        // core_load.svh (RAW case-arms, pasted here in the FSM).
        `include "core_load.svh"

        // integer execute/commit arm (S_EXEC — the largest) — relocated VERBATIM
        // into core_exec.svh (RAW case-arm, pasted here in the FSM).
        `include "core_exec.svh"

`ifdef VEN_IDIV_ITER
        // -----------------------------------------------------------------
        // S_DIV_BUSY: wait for the iterative integer DIV/IDIV engine, then
        // commit quotient/remainder to EAX/EDX (or deliver #DE on a zero
        // divisor / quotient overflow). Mirrors S_FP_BUSY; the busy-wait
        // serialises so the next insn reads the committed EDX:EAX.
        // -----------------------------------------------------------------
        S_DIV_BUSY: begin
          if (eng_int_done) begin
            if (eng_int_derr) begin
              // #DE (vector 0): no result, EFLAGS unchanged. sys_mode delivers
              // through the IDT; user mode loud-HALTs (matches the inline path).
`ifdef VEN_DBG_CORE
              // divide-#DE tap: snapshot the (start-latched) faulting operands.
              dbg_de_cnt_r <= dbg_de_cnt_r + 13'd1;
              dbg_de_num   <= dbg_de_num_r;
              dbg_de_info  <= {dbg_de_den_r, dbg_de_eip_r[15:0], dbg_de_w_r, (dbg_de_cnt_r + 13'd1)};
              $display("tb: DIVDE w=%0d eip=%08x num=%016x den=%08x",
                       dbg_de_w_r, dbg_de_eip_r, dbg_de_num_r, dbg_de_den_r);
`endif
              if (sys_mode) start_fault(8'd0, 1'b0, 32'd0, q_pc);
              else begin state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hEC; `endif end
            end else begin
              // R3: EAX/EDX quotient/remainder commit moved to the gpr writeback
              // driver (core_gpr_wb.svh, S_DIV_BUSY arm).
              // P5 occupancy residual so issue->next-issue == occ (DIV 17/25/41,
              // IDIV 22/30/46). The engine's real clocks cover most of it; top up
              // (tuned vs make m5). q_md 3'd7 = IDIV.
              pending_mem_pen <= (q_md==3'd7) ? 7'd6 : 7'd1;
              eip<=next_eip; retire_valid<=1'b1; state<=S_PIPE;
            end
          end
        end
`endif

        // M7.3 port-I/O arms (S_IO / S_INS) — relocated VERBATIM into
        // core_io.svh (RAW case-arms, pasted here in the FSM).
        `include "core_io.svh"
`ifdef VEN_PS_PROXY
        // PS-bridge (F4): the int-0x80 proxy parks here until the PS fills the
        // response. Commit only on syscall_resp_valid — IDENTICAL to the zero-latency
        // S_DECODE arm (eip still at cd80, so fold_pc_r<=eip and eip<=eip+q_proxy_len
        // are the same), just deferred. Else spin, consuming nothing (no retire_valid
        // -> cn frozen -> syscall_n/args stable for the PS the whole wait).
        S_SYSCALL_WAIT: begin
          if (syscall_resp_valid) begin
            // R3: EAX<=syscall_eax moved to the gpr writeback driver (S_SYSCALL_WAIT).
            if (syscall_apply_gs) gs_base_r <= syscall_gs_base;
            eip            <= eip + {28'd0, q_proxy_len};
            fold_pending_r <= 1'b1;
            fold_pc_r      <= eip;
            fetch_word     <= 3'd0;
            state          <= S_FETCH;
          end
        end
`endif
`ifdef VEN_FPTRAP
        // FPATAN PS-trap: stall until the PS writes fptrap_result. The ST1<-result+pop
        // commit is driven by the fp_we_* block above on the same clock; here we retire
        // + advance EIP (mirrors the S_TRSC_BUSY HW-engine path).
        S_FPTRAP_WAIT: begin
          if (fptrap_resp_valid) begin
`ifdef VEN_FP_PS_ALL
            // FP_PS_ALL store-after-trap: a narrowing-store op (FST m32/m64, FIST,
            // FBSTP) waited here for the A53 to convert ST0 to the destination width.
            // The PS returns the packed bytes in fptrap_result (low 80b) + the status
            // word in fptrap_res_fstat. Latch both and run the memory write (S_FSTORE);
            // fstore_val draws f_trap_store_q so no conversion sits on the PL store path.
            if (f_ps_store_trap) begin
              f_trap_store_q <= fptrap_result;
              // the PS-computed status word is committed to fstat this same clock by
              // the generalized trap-commit in fpu_writeback (fp_we_fstat <= res_fstat).
              state<=S_FSTORE; f_step<=4'd0;
            end else
`endif
            begin
              eip<=next_eip; retire_valid<=1'b1; x87_touched_r<=1'b1; state<=S_PIPE;
            end
          end
        end
`endif
        // store / micro-sequence arms (S_STORE / S_USEQ) — relocated VERBATIM
        // into core_store_useq.svh (RAW case-arms, pasted here in the FSM).
        `include "core_store_useq.svh"

        // M2S.1 descriptor-table read + far-jmp arms (S_LGDT / S_SEGLD / S_LJMP)
        // — relocated VERBATIM into core_seg_ljmp.svh (RAW case-arms, FSM-pasted).
        `include "core_seg_ljmp.svh"
        // M2S.3 IDT-delivery arms (S_INT_GATE / S_INT_CS / S_INT_PUSH /
        // S_DB_EXTRA) — relocated VERBATIM into core_int_deliver.svh (FSM-pasted).
        `include "core_int_deliver.svh"

        // IRET pop + CS/SS reload arms (S_IRET / S_INT_CS_RET / S_IRET_SS) —
        // relocated VERBATIM into core_iret.svh (RAW case-arms, FSM-pasted).
        `include "core_iret.svh"

        // F3 real-mode IVT delivery + IRET arms (S_RMINT_RD/_PUSH / S_RMIRET).
        `include "core_rmint.svh"

        // LTR + cross-priv stack/SS arms (S_LTR / S_INT_TSS / S_INT_SS) —
        // relocated VERBATIM into core_tss_priv.svh (RAW case-arms, FSM-pasted).
        `include "core_tss_priv.svh"

        // ===================================================================
        // M2S.4b hardware task-switch arms (S_TSW_SAVE/READ/SEG/BUSY) — relocated
        // VERBATIM into core_tsw.svh (RAW case-arms, pasted here in the FSM).
        `include "core_tsw.svh"

        // M2S.5 SMM entry (S_SMI_SAVE) + RSM (S_RSM) arms — relocated
        // VERBATIM into core_smm.svh (RAW case-arms, pasted here in the FSM).
        `include "core_smm.svh"

        // x87 execute/commit arms (S_FEXEC / S_FSTORE) — relocated VERBATIM into
        // core_fp_exec.svh (RAW case-arms, pasted here in the FSM).
        `include "core_fp_exec.svh"

        // M11b x87 env/state save+restore arms (S_FENV_ST / S_FENV_LD).
        `include "core_fenv.svh"

        // -------------------------------------------------------------------
        // M2S.2 page-table walk arm (S_WALK) — relocated VERBATIM into
        // core_walk.svh (RAW case-arm, pasted here in the FSM).
        `include "core_walk.svh"

        S_HALT: state<=S_HALT;
        // REVIEW_aug2 H-04: triple fault. Terminal, like S_HALT -- no retire, no
        // wake. Separate from S_HALT so the two are distinguishable in a trace.
        S_SHUTDOWN: state<=S_SHUTDOWN;

        // F3 INTERRUPTIBLE HLT wait (system mode). EIP already points past the HLT
        // (advanced when it retired), so start_fault's pushed return = the instruction
        // after HLT. Mirror the S_DECODE instruction-boundary divert priority
        // NMI > maskable INTR; the `inta` strobe also pulses here (see assign inta).
        // Stay parked until one fires. SMI from HLT is out of scope (FreeDOS path).
        S_HLTWAIT: begin
          // REVIEW2 H-10: a pending SMI must wake a halted processor and enter SMM.
          // This checked only NMI and INTR and explicitly called SMI out of scope, so
          // a HLT with interrupts masked and only an SMI pending stayed halted
          // FOREVER. Priority SMI > NMI > INTR, matching both instruction boundaries.
          // smi_enter() captures the resume EIP so RSM returns after the HLT.
          // A debugger halt owns the already-quiescent HLT state as well.  Do
          // not acknowledge/consume an interrupt while it is stopped: the
          // request must still be present when RUN releases this state.
          if (dbg_block_issue) begin
            state <= S_HLTWAIT;
          end else if (smi_take) begin
            smi_enter(eip);
          end else if (nmi_take) begin
            nmi_pending     <= 1'b0;
            nmi_in_progress <= 1'b1;
            start_fault(8'd2, 1'b0, 32'd0, eip);
          end else if (intr_take) begin
            start_fault(inta_vector, 1'b0, 32'd0, eip);
          end
          // else remain in S_HLTWAIT (halted, awaiting an interrupt).
        end

        // M6 Erratum 81 (F00F): the locked CMPXCHG8B-with-register-destination
        // form never starts the #UD handler because the bus stays locked — the
        // processor HANGS. We model that as a parked state that NEVER retires and
        // keeps cpu_hung asserted (documented "system hang"). Unlike S_HALT this
        // is reached ONLY with errata_en[ERR_F00F] set; the clean core decodes
        // 0F C7 /reg as an unknown opcode and HALTs loudly (no retire) instead.
        S_F00F_HANG: begin hung_r<=1'b1; state<=S_F00F_HANG; end

        default: begin state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hED; `endif end
      endcase
`ifdef VEN_L1_AXI
      // P1-1 #34: a fatal bus fault overrides every state arm (last-write-wins NBA) —
      // park in S_HALT + assert cpu_hung. Inert when bus_err=0 (the entire verified
      // 77/77+10/10 path), so it is byte-identical; absent in the default build.
      if (real_bus && bus_err) begin hung_r <= 1'b1; state<=S_HALT; `ifdef VEN_DBG_CORE int_vec<=8'hEE; `endif end
`endif
    end
  end

  // ===========================================================================
  // GPR WRITEBACK DRIVER (R3) — the per-register write bus (gpr_we/gpr_wd) that
  // feeds u_regfile. This combinational block re-derives EVERY architectural GPR
  // write the FSM used to commit (the `gpr[idx] <= expr` NBA writes that lived in
  // the main always_ff above + its `included case-arms). It mirrors the FSM's
  // EXACT gating: the same outer xlate_miss / fe_xlate_pend skip, the same
  // `case (state)` arms, and per-arm the same conditions — but keeps ONLY the
  // gpr writes (every eflags/eip/seg/cr/retire/store statement is stripped).
  //
  // Per-register bus semantics: two writes to DIFFERENT registers the same clock
  // (e.g. dst + ESP on a pop; EAX + EDX on MUL/DIV) assert both gpr_we lines; two
  // writes to the SAME register in one arm resolve last-blocking-assignment-wins
  // (same as the FSM's last-NBA-wins). DEFAULT is no write (gpr_we=0), so a clock
  // that the FSM left a register unchanged leaves gpr_we[idx]=0 -> regfile holds.
  //
  // Reads use gpr_o[] (the registered, pre-edge value) exactly as the FSM did, so
  // read-modify-write values (reg_merge(gpr_o[i],...), gpr_o[R_ESP]+w, ...) are
  // byte-identical. Block-local temporaries that an arm computed to produce a gpr
  // write VALUE are recomputed here from module-level signals (pure functions).
  // ===========================================================================
  always_comb begin
    gpr_we = '0;
    gpr_wd = '{default:'0};
    if (!rst_n) begin
      // reset GPR seed is u_regfile's own synchronous arm; nothing to drive here.
    end else if (perm_fault) begin
      // REVIEW2 C-01: permission-#PF clock -- the FSM diverts to the fault, so the
      // faulting instruction must not commit a register (it will be restarted).
    end else if (xlate_miss) begin
      // page-walk diversion clock: the FSM skips the whole case body -> no gpr write.
    end else if (fe_xlate_pend) begin
      // +VEN_FE_PIPE page-cross stall clock: FSM holds -> no gpr write.
    end else begin
      case (state)
        `include "core_gpr_wb.svh"
        default: ;
      endcase
    end
    // 16-bit SS: wrap the ESP writeback within 64k (SP-only changes; the high half of
    // ESP is preserved). Pairs with stk16() on the stack ADDRESS so a wrapping
    // push/pop writes and reads the SAME ss_base+0xFFFx slot.
    // REVIEW_aug2 H-01: the condition was `real_mode` alone, so a 16-bit PROTECTED
    // stack wrapped its ADDRESS but not its POINTER -- a push at SP=0 accessed
    // SS:FFFE and then committed ESP=FFFFFFFE instead of changing only SP. It now
    // reads stk_ptr16 (see its definition above, including why it is not simply
    // stk_is16). Identity in user mode and on a 32-bit PM stack, so make verify is
    // byte-identical.
    if (stk_ptr16 && gpr_we[R_ESP] && !esp_arch_dst)
      gpr_wd[R_ESP] = {gpr_o[R_ESP][31:16], gpr_wd[R_ESP][15:0]};
  end
`ifndef SYNTHESIS
  // REVIEW_aug2 H-01 measurement (see ven_h01 above). Observation only -- a separate
  // always_ff so the writeback's combinational block is untouched.
  always_ff @(posedge clk) begin
    if (!rst_n) begin ven_h01_ptr16 <= 0; ven_h01_ssb <= 0;
                      ven_seg_chk_n <= 0; ven_seg_chk_ss <= 0; ven_seg_chk_es <= 0;
                      ven_h01_ssb_prev <= 1'b1; ven_h01_state_prev <= S_PIPE; end
    else begin
      if (gpr_we[R_ESP] && stk_ptr16 && !real_mode) ven_h01_ptr16 <= ven_h01_ptr16 + 1;
      if (cur_is_d && cur_seg_rel && mem_req_pre_sq && sys_mode && !real_mode) begin
        ven_seg_chk_n <= ven_seg_chk_n + 1;
        if (cur_seg_idx == 3'(SG_SS)) ven_seg_chk_ss <= ven_seg_chk_ss + 1;
        if (cur_seg_idx == 3'(SG_ES)) ven_seg_chk_es <= ven_seg_chk_es + 1;
      end
      // Attribute an ss_b CHANGE to the new sites by looking at the state it came
      // from -- exact, and independent of the beat encoding inside each sequence.
      ven_h01_ssb_prev  <= ss_b;
      ven_h01_state_prev <= state;
      if ((ss_b != ven_h01_ssb_prev) &&
          ((ven_h01_state_prev == S_INT_SS) || (ven_h01_state_prev == S_TSW_SEG)))
        ven_h01_ssb <= ven_h01_ssb + 1;
    end
  end
`endif

  // ===========================================================================
  // x87 store-operand value + exception flags (combinational). `fstore_val`
  // holds the word-aligned bytes to write; `fstore_pe`/`fstore_ie` carry the
  // precision (inexact) / invalid status QEMU latches on a rounding/overflowing
  // store (helper_fst*/helper_fist* -> merge_exception_flags). fstat is trace-
  // compared, so these must be set whenever QEMU would. Rounding honors RC.
  //   FST  m32/m64 : PE if the floatx80->float32/64 narrow rounds (inexact).
  //   FIST m16/m32/m64 : PE if the rounding-to-int loses a fraction; IE +
  //     integer-indefinite if the result is out of the destination's range.
  //   FST m80 / FNSTCW / FNSTSW m16 : exact, no exception.
  // ===========================================================================
  logic [79:0] fstore_val;
  logic        fstore_pe;
  logic        fstore_ie;
  logic        fstore_oe;        // FST m32/m64 narrowing overflow -> Inf (OE)
  logic        fstore_ue;        // FST m32/m64 narrowing underflow -> denormal (UE)
  always_comb begin
`ifdef VEN_FP_SHARED
    // Conversion, exception merging, and masked-stack indefinite selection are
    // performed once by ven_fp_top before it emits this registered response.
    // Keeping S_FSTORE a byte serializer removes the old wide conversion cones
    // from the shared implementation and avoids a second status mutation.
    fstore_val = fp_shared_store_data_q[79:0];
    fstore_pe = 1'b0; fstore_ie = 1'b0;
    fstore_oe = 1'b0; fstore_ue = 1'b0;
`else
    logic [79:0] s0;
    logic [81:0] rb;             // FBSTP: {ie, pe, bcd} converter result
    logic [34:0] r32;            // {oe, ue, pe, float32}
    logic [66:0] r64;            // {oe, ue, pe, float64}
    logic [65:0] ri;             // {invalid, inexact, value}
    rb = 82'd0;
    s0 = fp_st0_phys;             // ST0 (= fpr[ftop], u_fpu_state read port)
    // REVIEW_Aug4 A4-H01: a MASKED stack fault on a store (FST/FIST/FBSTP of an
    // EMPTY ST0) stores the operation's masked response -- the QNaN real
    // indefinite (the narrowing/int conversions below turn it into the f32/f64
    // quiet NaN / the integer indefinite) -- not the stale empty-slot bits
    // (SDM Vol.1 Table 8-4). fp_flt_q was latched at the S_FEXEC dispatch.
    if (fp_flt_q && fctrl[0] && (state == S_FSTORE))
      s0 = {1'b1, 15'h7fff, 1'b1, 63'h4000000000000000};   // QNaN real indefinite (fpu_writeback.sv's QNAN_INDEF)
    r32 = 35'd0; r64 = 67'd0; ri = 66'd0;
    fstore_val = 80'd0; fstore_pe = 1'b0; fstore_ie = 1'b0;
    fstore_oe = 1'b0; fstore_ue = 1'b0;
    if (fp_flt_q && fctrl[0] && (state == S_FSTORE)) begin
      // the destination-specific indefinite, ahead of every registered
      // converter result -- the BCD engine's fbcd_result_q and the PS trap's
      // f_trap_store_q are computed FROM the empty slot and must not replace
      // the masked response. (The local conversions of the substituted s0
      // produce these same constants; naming them keeps the PS_ALL/BCD_ITER
      // configurations, which lack those converters, on the same response.)
      unique case (q_fxop)
        FX_FST_M32:  fstore_val = {48'd0, 32'hFFC00000};            // QNaN32
        FX_FST_M64:  fstore_val = {16'd0, 64'hFFF8000000000000};    // QNaN64
        FX_FIST_M16: fstore_val = {64'd0, 16'h8000};                // int indefinite
        FX_FIST_M32: fstore_val = {48'd0, 32'h80000000};
        FX_FIST_M64: fstore_val = {16'd0, 64'h8000000000000000};
        FX_FBSTP:    fstore_val = 80'hFFFFC000000000000000;         // packed-BCD indefinite
        default:     fstore_val = {1'b1, 15'h7fff, 1'b1, 63'h4000000000000000};
      endcase
    end else
`ifdef VEN_FP_PS_ALL
    // FP_PS_ALL: the narrowing-store conversion runs on the A53 (store-after-trap).
    // fstore_val draws the converted bytes straight from the registered PS result
    // (f_trap_store_q), so the deep fx_to_f32/f64/int/bcd cones are NOT instantiated
    // on the PL store path. The exact-image stores (m80 / CW / SW m16) plus FNSTSW_AX
    // stay in PL (no conversion), handled in the case below. Sticky-flag bits are
    // carried by the latched status word (fp_we_fstat driven at the trap-store commit),
    // so fstore_pe/ie/oe/ue stay 0 here.
    if (f_ps_store_trap) begin
      fstore_val = f_trap_store_q;
    end else
`endif
    unique case (q_fxop)
`ifndef VEN_FP_PS_ALL
      FX_FST_M32: begin
        r32 = fx_to_f32_ex(s0, fctrl[11:10]);
        fstore_val = {48'd0, r32[31:0]};
        fstore_pe = r32[32]; fstore_ue = r32[33]; fstore_oe = r32[34];
      end
      FX_FST_M64: begin
        r64 = fx_to_f64_ex(s0, fctrl[11:10]);
        fstore_val = {16'd0, r64[63:0]};
        fstore_pe = r64[64]; fstore_ue = r64[65]; fstore_oe = r64[66];
      end
`endif
      FX_FST_M80:  fstore_val = s0;
      // M10 FBSTP: round ST0 to int (per RC), pack 18-digit BCD + sign byte.
      // {ie,pe,bcd} -> IE on BCD-range overflow (indefinite image), PE on an
      // inexact round-to-int (oracle-confirmed: FBSTP of 2.5 sets PE).
`ifndef VEN_FP_PS_ALL
      FX_FBSTP: begin
`ifdef VEN_BCD_ITER
        // iterative engine result, latched in S_BCD_BUSY (see ven_bcd).
        fstore_val = fbcd_result_q[79:0]; fstore_pe = fbcd_result_q[80]; fstore_ie = fbcd_result_q[81];
`else
        rb = fx_fx_to_bcd(s0, fctrl[11:10]);
        fstore_val = rb[79:0]; fstore_pe = rb[80]; fstore_ie = rb[81];
`endif
      end
`endif
      // M6 Erratum 20: FIST[P] m16int/m32int (NOT m64) miss the overflow on
      // the documented positive operands in nearest/up rounding -> store ZERO,
      // no IE. fx_to_int_errata reproduces that when errata_en[ERR_FIST] is set;
      // otherwise it is identical to fx_to_int_ex (clean core unchanged). The
      // three widths are kept as SEPARATE constant-width calls on purpose: the
      // constant `width` lets synth constant-fold each conversion's range-check
      // (a runtime-width merge measured +8.8K LUT, defeating that folding).
`ifndef VEN_FP_PS_ALL
      FX_FIST_M16: begin
        ri = errata_en[ERR_FIST] ? fx_to_int_errata(s0, 16, fctrl[11:10])
                                 : fx_to_int_ex     (s0, 16, fctrl[11:10]);
        fstore_val = {64'd0, ri[15:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FIST_M32: begin
        ri = errata_en[ERR_FIST] ? fx_to_int_errata(s0, 32, fctrl[11:10])
                                 : fx_to_int_ex     (s0, 32, fctrl[11:10]);
        fstore_val = {48'd0, ri[31:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
      FX_FIST_M64: begin
        ri = fx_to_int_ex(s0, 64, fctrl[11:10]);
        fstore_val = {16'd0, ri[63:0]}; fstore_pe = ri[64]; fstore_ie = ri[65];
      end
`endif
      FX_FNSTCW:   fstore_val = {64'd0, fctrl};
      FX_FNSTSW_M: fstore_val = {64'd0, (fstat & ~16'h3800) | ({13'd0,ftop}<<11)};
      default:     fstore_val = 80'd0;
    endcase
`endif
  end

  // ===========================================================================
  // M11b: the FNSTENV/FNSAVE environment+state image, assembled as a flat 864-bit
  // little-endian byte vector (dword j = fenv_image[j*32 +: 32]). Dwords 0..6 are
  // the 28-byte protected-mode env (CW/SW/FTW/FIP/FCS|FOP/FDP/FDS); dwords 7..26
  // are the 8 ST registers (logical order ST0..ST7, 10 bytes each, empty->0). The
  // 10-byte slots straddle dword boundaries -- the flat-vector dword slice handles
  // it. FOP is hardwired 0 (oracle). The graded trace is unaffected (this feeds
  // only the store bus arm, read back from memory into a GPR).
  // ===========================================================================
  logic [863:0] fenv_image;
  logic [15:0]  fenv_ftw;
  logic [639:0] fenv_streg;

  // REVIEW1_Aug2 M-04: the 16-bit (14-byte) environment image. With a 66h operand-size
  // prefix FNSTENV/FLDENV move a 14-byte object, not a 28-byte one, and every field is
  // a WORD. Writing the 28-byte image over it corrupted 14 bytes past the object; the
  // decoder was made to reject the form so the omission was at least loud. It is now
  // implemented: SAME seven beats, stride 2 instead of 4, one word per beat.
  //
  // The layout is NOT a narrowing of the 32-bit one -- fields 4 and 6 differ by mode:
  //   +0 CW  +2 SW  +4 TW  +6 IP[15:0]
  //   +8  protected: CS selector      real: {IP[19:16], 1'b0, opcode[10:0]}
  //   +10 DP[15:0]
  //   +12 protected: operand selector real: {DP[19:16], 12'b0}
  // FOP stays 0 to match the oracle, exactly as the 32-bit image does.
  // 47 words: [0..6] the 14-byte env, [7..46] the 80-byte ST region (FNSAVE only).
  logic [751:0] fenv_image16;
  always_comb begin
    fenv_image16 = { fenv_streg,                                     // w7..46 (ST0..7)
                     real_mode ? {fdp[19:16], 12'd0} : fds,          // w6 +12
                     fdp[15:0],                                      // w5 +10
                     real_mode ? {fip[19:16], 1'b0, 11'd0} : fcs,    // w4 +8
                     fip[15:0],                                      // w3 +6
                     fenv_ftw,                                       // w2 +4
                     (fstat & ~16'h3800) | ({13'd0,ftop}<<11),       // w1 +2
                     fctrl };                                        // w0 +0
  end

  // REVIEW1_Aug2 M-04 + C-03: the beat's byte offset, defined ONCE. cur_lin (the TLB
  // lookup) and mem_addr (the bus) both derive from this signal rather than each
  // open-coding the stride -- which is the exact defect C-03 exists to prevent, and
  // would fire CHECK 5 the moment the two shifts disagreed.
  // REVIEW1_Aug2 M-04: the LAST beat index, defined once. core_fenv.svh (both arms)
  // and fpu_writeback.sv's commit all read this rather than re-deriving it.
  //   env only  (FNSTENV/FLDENV): 7 beats  -> 6
  //   full state (FNSAVE/FRSTOR): 27 dwords -> 26, or 47 words -> 46
  // REVIEW1_Aug2 H-11: x87 stack over/underflow, detected in fpu_writeback.
  logic fp_stk_ovf, fp_stk_unf;
  // REVIEW_Aug4 A4-H01: the issue-time stack-fault decision, latched at the
  // S_FEXEC dispatch and replayed into fpu_writeback at the DEFERRED commit
  // (S_FP_BUSY / S_TRSC_BUSY / S_FPREM_BUSY / S_FPTRAP_WAIT / S_FSTORE) -- the
  // writeback-local predicate cannot span those states on its own.
  logic fp_flt_q, fp_flt_ovf_q;

  logic [5:0] fenv_last;
  always_comb begin
    if (q_fxop == FX_FNSAVE || q_fxop == FX_FRSTOR)
      fenv_last = (q_f_mbytes == 4'd2) ? 6'd46 : 6'd26;
    else
      fenv_last = 6'd6;
  end

  logic [31:0] fenv_off;
  assign fenv_off = (q_f_mbytes == 4'd2) ? {25'd0, f_seq_step, 1'b0}    // 16-bit: x2
                                         : {24'd0, f_seq_step, 2'b00};  // 32-bit: x4
  always_comb begin
    int pidx;
    for (int p = 0; p < 8; p++)
      fenv_ftw[p*2 +: 2] = ftw_field(fptag[p], fpr_flat[p*80 +: 80]);
    for (int i = 0; i < 8; i++) begin
      pidx = (ftop + i) & 7;                                  // ST(i) = physical fpr[ftop+i]
      // qemu do_fsave dumps the RAW register bytes for every slot, even empty ones
      // (do_fstt is unconditional) -- an empty reg keeps its stale floatx80 content.
      fenv_streg[i*80 +: 80] = fpr_flat[pidx*80 +: 80];
    end
    fenv_image = { fenv_streg,                                       // dw7..26 (ST0..7)
                   {16'd0, fds},                                     // dw6 +24 FDS
                   fdp,                                              // dw5 +20 FDP
                   {5'd0, 11'd0, fcs},                               // dw4 +16 {FOP=0, FCS}
                   fip,                                              // dw3 +12 FIP
                   {16'd0, fenv_ftw},                                // dw2 +8  FTW
                   {16'd0, (fstat & ~16'h3800) | ({13'd0,ftop}<<11)},// dw1 +4  SW (TOP overlaid)
                   {16'd0, fctrl} };                                 // dw0 +0  CW
  end

  // ===========================================================================
  // M2S.1 data segment base. For a slow-path data access the linear address is
  // seg.base + offset. The base depends on which segment the access uses:
  //   - stack ops (push/pop/call/ret/leave/pushf/popf) use SS
  //   - string source ([ESI]) uses DS, dest ([EDI]) uses ES
  //   - LGDT/LIDT pseudo-descriptor read uses DS
  //   - everything else uses q_seg (DS default, or a segment-override prefix)
  // In USER mode every seg_base[]==0 so dbase==0 and the linear address is the
  // unchanged flat offset (so make verify is bit-for-bit unaffected).
  // ===========================================================================
  logic [31:0] dbase, dbase_edi;
  logic [2:0]  dseg;              // which segment supplies dbase (for the limit check)
  always_comb begin
    if (q_is_pop || q_is_push || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
        (q_kind==K_CTRL && (q_ct==CT_CALLREL || q_ct==CT_CALLIND)) ||
        (q_kind==K_STKMISC && (q_sm==SM_POPF || q_sm==SM_PUSHF ||
                               q_sm==SM_LEAVE || q_sm==SM_PUSHA || q_sm==SM_POPA)))
      dseg = 3'(SG_SS);
    else if (q_kind==K_STR)
      // BUGFIX (Win95 relocation): the MOVS/LODS/CMPS SOURCE [ESI] segment is DS BY DEFAULT but is
      // SEGMENT-OVERRIDABLE. The old code hardcoded SG_DS, IGNORING the override -> FreeDOS's
      // `rep cs movsb` (relocate IO.SYS via CS:SI) read DS:SI instead. On HW DS=0xF000 (base 0xF0000),
      // so the copy read the BIOS/high kernel copy (whose off 0x2af is a scancode TABLE) instead of the
      // loaded IO.SYS at CS:SI=0x700 (off 0x2af = entry CODE) -> RETF to 8000:0x2af hit the table -> derail
      // at cs=8000:0x3a0. Use q_seg (= override?override_idx:DS) for the source; SCAS/[EDI] stays ES.
      // Bit-identical for non-override string ops (q_seg==SG_DS); correct for overridden ones.
      // BUGFIX2 (memcpyb "Bad drive type"): the string SOURCE segment is the OVERRIDE (if a seg-prefix is
      // present) else DS. q_seg is UNSAFE here: for a no-override string op the 16-bit addressing block
      // (decode_stages.sv:327-352) runs unconditionally and misreads the byte AFTER the opcode as a ModRM,
      // forcing d_seg=SS for a BP-like rm (memcpyb `rep movsb` is followed by `pop si`=0x5E -> rm=110/mod=01
      // -> SS). That made get_boot_vector's copy read seg 0/IVT -> "Bad drive type". Use the CLEAN prefix-
      // override latch q_pfx_seg_en (set only by an actual 26/2E/36/3E/64/65 prefix) to pick override-vs-DS;
      // q_seg is correct FOR the override case (the BP->SS default is gated on !d_pfx_seg_en). SCAS=[EDI]=ES.
      dseg = (q_st==ST_SCAS) ? 3'(SG_ES) : (q_pfx_seg_en ? q_seg : 3'(SG_DS));
    else
      dseg = q_seg;
    dbase     = seg_base[dseg];    // dseg is now clean (override via q_pfx_seg_en, else DS) — no hazard
    dbase_edi = seg_base[SG_ES];   // string/[EDI] destination uses ES
  end

  // M7.1: the OPERAND segment base for an indirect CALL/JMP's memory-operand READ.
  // The dbase comb above forces SS for a CALL (its primary stack PUSH uses SS),
  // but the indirect target is fetched from the OPERAND's own segment — which
  // matters when the call carries a segment override, e.g. musl's vsyscall
  // `call dword ptr gs:[0x10]`: the pointer is read at %gs (the TLS base), while
  // the return address is still pushed on SS. opbase supplies seg_base[q_seg] for
  // that operand read. GATED on (proxy_en && !sys_mode): in flat user/sys mode
  // q_seg's base equals SS's base (both 0), so this is bit-identical everywhere
  // the gates run; only the user-proxy gs-override call changes.
  logic [31:0] opbase;
  always_comb begin
    // F3: PUSH r/m (FF /6) with a MEMORY source reads the operand from its OWN
    // segment (DS default, or an override) — only the stack WRITE uses SS. The dbase
    // comb forces SS for every push, which is correct for the stack but wrong for the
    // source read: SeaBIOS's __farcall16 does `push dword [eax+0x20]` with DS!=SS and
    // got 0 (reading SS:off instead of DS:off) -> iret to 0:0. Flat user/sys mode has
    // seg_base[q_seg]==seg_base[SS] (both 0) so make verify is bit-identical.
    if (q_is_push && q_mem_read)
      opbase = seg_base[q_seg];
    else if ((q_ct==CT_CALLIND || q_ct==CT_JMPIND) && q_mem_read)
      // F3: the function-pointer READ of an indirect call/jmp uses the operand's
      // own segment (DS default / override / the new EBP->SS rule), NOT the SS
      // that dbase forces for the return-address PUSH. Was gated proxy_en &&
      // !sys_mode, so the SoC (sys_mode=1) read `call word [bx]` pointers from
      // SS:EA. Flat gates: seg_base[q_seg]==seg_base[SS] -> byte-identical.
      opbase = seg_base[q_seg];
    else
      opbase = dbase;   // unchanged path (SS for a call, etc.)
  end

  // F3: the STORE-side mirror of opbase. POP r/m (8F) reads the stack word (SS, via
  // the S_LOAD q_is_pop branch) but WRITES the popped value to its memory OPERAND,
  // which uses the operand's own segment (DS default / override) — not SS. dbase
  // forces SS for every pop, so a `pop word [eax]` with DS!=SS (SeaBIOS's call32
  // forward path) wrote the struct to the wrong segment. Flat mode: q_seg base == SS
  // base (0), so make verify is bit-identical. Every other store keeps dbase.
  logic [31:0] stbase;
  always_comb begin
    if (q_is_pop && q_mem_write) stbase = seg_base[q_seg];
    else                         stbase = dbase;
  end

  // M2S.1 — protected-mode segment LIMIT-check DECISION (spec §3, computed not
  // delivered). For an expand-up data/code segment the last byte of an access at
  // segment offset `off` must satisfy off <= seg_limit. We compute this for the
  // current data access (effective address q_ea against dseg's hidden limit) so
  // the limit check is genuinely COMPUTED — but, like seg_load_fault, delivery
  // (#GP) is M2S.3, so a positive decision can only be observed here / HALT in a
  // later stage. The pseg corpus's top-of-segment access (offset 0xFFFC dword in
  // the 64 KiB based segment) is exactly in-bounds, so this is always 0 for the
  // gate. Only meaningful in protected mode (sys_mode & !real_mode); flat/user
  // segments have seg_limit=0xFFFFFFFF so it is trivially 0 there too.
  logic [31:0] dlimit;
  // REVIEW2 C-06: the old computation was `q_ea + 3 > dlimit`, lint-sunk. It used a
  // FIXED width (so a byte access near the limit false-positived and a dword past it
  // could be missed once other shapes were considered), covered one data-EA shape, and
  // ignored expand-down segments, null selectors, present, and type entirely.
  //
  // The computation below is width-accurate and handles expand-down / not-present.
  // It remains LINT-SUNK. The delivery was written, TESTED against make verify-sys,
  // found broken, and REMOVED rather than shipped behind a flag -- see the long note in
  // core_fetch_decode.svh for the measured reason (it read q_* while being delivered
  // for the d_* instruction, and was not gated on the instruction actually making a
  // memory access, so it faulted on `mov cr0,eax` with ea = CR0's VALUE).
  //
  // Not covered at all: fetch limits, the #SS/#GP distinction on every path, string
  // endpoints, and null-selector detection (which needs a "loaded in PM and was null"
  // bit the core does not track -- testing showed the selector VALUE is not sufficient,
  // because the real->protected transition window legitimately runs with DS=SS=0 and
  // valid cached descriptors). All of it is #65's access descriptor.
`ifndef SYNTHESIS
  // REVIEW2 C-06 instrumentation: log every fault delivery, enabled with +ven_faultlog.
  // Added because FIVE successive hypotheses about why the C-06 #GP broke m6's Err79
  // were wrong; the interaction has to be OBSERVED, not reasoned about.
  logic ven_faultlog_en;
  initial ven_faultlog_en = $test$plusargs("ven_faultlog") != 0;

  // ---- +ven_frmpglog: per-delivery frame page-plan counters ------------------
  // Sim-only observability for the page-plan probe contract: one validation
  // beat per DISTINCT frame page (not per slot), one D-mark beat per plan
  // page when any validated page was clean, and no page walk once the frame
  // pushes run (the pushes translate through the captured plan frames). One
  // line is printed per completed planned delivery, at the S_INT_PUSH exit:
  //   [FRMPG] nslots=<n> npages=<n> val=<n> dm=<n> pushwalk=<n>
  logic       ven_frmpglog_en;
  logic [7:0] fpl_val, fpl_dm, fpl_walk;
  logic [2:0] fpl_np;
  logic [5:0] fpl_ns;
  logic       fpl_push, fpl_planned;
  initial ven_frmpglog_en = $test$plusargs("ven_frmpglog") != 0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fpl_val <= 8'd0; fpl_dm <= 8'd0; fpl_walk <= 8'd0;
      fpl_np  <= 3'd0; fpl_ns <= 6'd0;
      fpl_push <= 1'b0; fpl_planned <= 1'b0;
    end else begin
      if (state == S_INT_GATE) begin // every delivery enters here; a faulted
        fpl_val <= 8'd0; fpl_dm <= 8'd0; fpl_walk <= 8'd0;  // plan is gone by
        fpl_push <= 1'b0; fpl_planned <= 1'b0;              // the new delivery
      end
      if (state == S_INT_SS) begin   // a planned delivery stages here (the
        fpl_val <= 8'd0; fpl_dm <= 8'd0; fpl_walk <= 8'd0;  // call-gate path
        fpl_push <= 1'b0;           // never passes S_INT_GATE, so reset here)
        fpl_planned <= 1'b1;
      end
      // one SUCCESSFUL probe beat per plan entry (a TLB miss diverts to the
      // walk and the beat retries; only the resolving beat counts)
      if (state == S_INT_PROBE && !xlate_miss && !perm_fault) begin
        if (frm_pg_markd) fpl_dm  <= fpl_dm  + 8'd1;
        else              fpl_val <= fpl_val + 8'd1;
        fpl_ns <= int_frm_nslots;  // latched at staging; settled by the probe
      end
      if (fpl_planned && state == S_INT_PUSH) begin
        fpl_push <= 1'b1;
        fpl_np   <= frm_pg_n;      // the plan is cleared at the last beat
      end
      if (fpl_push && state == S_WALK) fpl_walk <= fpl_walk + 8'd1;
      if (fpl_push && state != S_INT_PUSH && state != S_WALK) begin
        fpl_push    <= 1'b0;
        fpl_planned <= 1'b0;
        if (ven_frmpglog_en)
          $display("[FRMPG] nslots=%0d npages=%0d val=%0d dm=%0d pushwalk=%0d",
                   fpl_ns, fpl_np, fpl_val, fpl_dm, fpl_walk);
      end
    end
  end

  // ---- REVIEW1_Aug2 C-03 instrumentation --------------------------------------
  // The page-crossing SPLIT exists only for S_LOAD/S_LOAD2/S_STORE. Every other
  // multi-beat state translates the page its access STARTS in and then drives the
  // whole extent through that one translation -- so an access straddling a page
  // boundary writes the tail bytes through the WRONG physical page, silently, and
  // never raises the #PF the second page might owe.
  //
  // The finding asks for a canonical byte-addressed request layer BELOW the FSM-state
  // selection, which is a rework. (cur_lin, cur_size) is the (start, length) pair such
  // a layer carries, and this counts the beats where the pair straddles a boundary in
  // a state that CANNOT split -- i.e. exactly the reachable half of the finding.
  //
  // Counting before rebuilding is the point: extending the split state-by-state is
  // what C-03 exists to stop, and a measurement says which states are reachable at all.
  assign seg_ext_size = seg_ext_ovr_v ? seg_ext_ovr : {4'd0, cur_size};

  logic [12:0] cur_ext_end;
  logic        cur_crosses, cross_split_capable, cross_unhandled;
  assign cur_ext_end         = {1'b0, cur_lin_nat[11:0]} + {9'd0, cur_size};
  assign cross_split_capable = (state == S_LOAD) || (state == S_LOAD2) ||
                               (state == S_STORE);
  // QUALIFIED ON paging_on. With PG=0 the linear address IS the physical one and a
  // straddling extent is a single contiguous access -- there is no second translation
  // to get wrong and no #PF to owe, so it is not a defect. Counting it would have
  // reported 47 "unsplit crossings" that are all harmless real-mode boot traffic.
  // REVIEW1_Aug3 R2-C03: the fragment engine covers every translatable state
  // outside the three with their own machinery (fx_state_ok), so an "unhandled"
  // crossing should now be impossible; the $fatal below stays as the proof (and
  // the guard against a future state that escapes fx_state_ok).
  assign cur_crosses         = paging_on && fe_translatable && mem_req_pre_sq &&
                               !xp_pend && (cur_ext_end > 13'h1000);
  assign cross_unhandled     = cur_crosses && !cross_split_capable && !fx_state_ok;

`ifndef SYNTHESIS
  logic ven_xlog_en;
  int   ven_cross_n, ven_cross_unh_n;
  initial begin
    ven_xlog_en = $test$plusargs("ven_xpagelog") != 0;
    ven_cross_n = 0; ven_cross_unh_n = 0;
  end
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (cur_crosses) ven_cross_n <= ven_cross_n + 1;
      if (cross_unhandled) begin
        ven_cross_unh_n <= ven_cross_unh_n + 1;
        if (ven_xlog_en)
          $display("[XPAGE] UNSPLIT state=%0d lin=%08h size=%0d pc=%08h",
                   state, cur_lin, cur_size, q_pc);
      end
    end
  end
  final if (ven_xlog_en)
    $display("[XPAGESTAT] page-crossing beats: total=%0d UNSPLIT=%0d",
             ven_cross_n, ven_cross_unh_n);

  // The remaining half of C-03 is now LOUD instead of silent. Measured across the
  // 68-image system corpus this NEVER fires (3 crossing beats under paging, all of
  // them in split-capable states), so it costs nothing today -- but if Win95 or Quake
  // ever drives a straddling extent through a state that cannot split, this names the
  // state and the address instead of corrupting a page and carrying on. Same principle
  // as making the 16-bit env forms a loud #UD before they were implemented: a visible
  // omission beats silent corruption.
  //
  // NOT an $fatal: it is a diagnostic for a gap, not a broken invariant like CHECK 5.
  // REVIEW2_aug2 C-04: this was a NON-FATAL $error, so a firing could be scrolled past
  // in a long run -- and the finding rightly notes that "0 reachable in 68 images" is
  // corpus coverage, not architectural unreachability. An unsplit crossing sends tail
  // bytes to the physically adjacent frame and drops a fault page two owed; that is
  // memory corruption, not a warning. $fatal so it cannot be ignored, and so any future
  // reachable case stops at the point of corruption instead of continuing past it.
  //
  // Safe to make fatal precisely BECAUSE it does not fire today: verified 0 firings
  // across the corpus (seg gate section 5 counts them and fails on nonzero). If it ever
  // does fire, stopping is the correct response.
  // ---- C-04 STATUS, traced rather than labelled --------------------------------
  // The finding's text says this diagnostic "is simulation-only and is not fatal".
  // The first half is still true and unavoidable here; the second is NOT -- it is a
  // $fatal, and the seg gate counts PAGING/C-0* firings across the corpus and fails on
  // a nonzero count, so it is read rather than printed into a log nobody greps.
  //
  // The REST of C-04 is the canonical request layer, and there is no smaller true step
  // inside it -- the same test that re-opened C-06's selector half and confirmed
  // H-11's decline:
  //   * Extending the split state-by-state is explicitly what this finding exists to
  //     stop; each added state is a new copy of the same logic, so a partial version
  //     makes the divergence it warns about WORSE, not smaller.
  //   * "Probe/translate every page before stores commit" is the layer itself.
  //   * The one genuinely separable piece is TEST work: directed boundary cases per
  //     request producer, to turn "0 reachable across 68 images" (corpus coverage)
  //     into a per-producer reachability answer.
  //
  //     ATTEMPTED AND NOT LANDED, so the next attempt does not restart from zero. I
  //     built a probe on top of pxpage (paging already on, low 4 MiB identity-mapped)
  //     targeting first an FSTP m64 and then an LGDT at linear 0x20FFE, both crossing
  //     into 0x21000, both in states absent from cross_split_capable. NEITHER fired
  //     the assertion, and in both cases the run stalled on the FIRST instruction I
  //     added after CR0.PG is set -- pc=0x000F011A (fldz) and pc=0x000F0117 -- which
  //     points at the scaffold, not at C-04. What it needs first:
  //       - pxpage installs NO IDT, so ANY fault (including a #PF from an unmapped or
  //         read-only target) stalls the core with nothing reported. A usable probe
  //         needs an IDT before it can distinguish "crossed undetected" from "faulted".
  //       - the write permissions of the identity map over the target page were never
  //         confirmed; the probe writes its operand there first.
  //     Separately observed and NOT diagnosed: `fldz` did not retire at all in that
  //     context, with CR0=0xE0000011 (PE|PG set, EM/TS/MP clear), under both --system
  //     and --system --cosim. That is its own question, not C-04's, and it is recorded
  //     rather than asserted -- with no IDT present it may simply be a fault that
  //     cannot be delivered.
  always_ff @(posedge clk)
    if (rst_n && cross_unhandled)
      $fatal(1, "PAGING/C-04: UNSPLIT page-crossing access in state %0d -- lin=%08h size=%0d ends at %03h, past the page end. This state translates only the page the access STARTS in, so the tail bytes go through the WRONG physical page and any #PF the second page owes is never raised. pc=%08h",
             int'(state), cur_lin, cur_size, cur_ext_end, q_pc);

`ifdef VEN_C03_PROBE
  // REVIEW2_aug2 H-05 (multi-beat): count beats where the LIMIT check covers MORE than
  // the beat moves -- i.e. where the whole-object extent is doing work cur_size cannot.
  always_ff @(posedge clk)
    if (rst_n && cur_is_d && cur_seg_rel && sys_mode && !real_mode
        && ({25'd0, seg_ext_size} != {29'd0, cur_size}))
      $display("[H05-MB] state=%0d ext=%0d cur_size=%0d skip=%0b lin=%08h",
               int'(state), seg_ext_size, cur_size, seg_ext_skip, cur_lin);
  // REVIEW2_aug2 H-05: does the canonical extent actually DIFFER from q_w on a
  // segment-checked access? If it never does, swapping the limit check onto cur_size
  // is a no-op dressed as a fix. Measured separately from correctness, as ever.
  always_ff @(posedge clk)
    if (rst_n && cur_is_d && cur_seg_rel && sys_mode && !real_mode
        && ({29'd0, cur_size} != {30'd0, q_w}))
      $display("[H05-SZ] state=%0d seg=%0d cur_size=%0d q_w=%0d ext=%0d skip=%0b lin=%08h",
               int'(state), cur_seg_idx, cur_size, q_w, seg_ext_size, seg_ext_skip, cur_lin);
`ifdef VEN_C03_PROBE
  // separate counter for the H-05 multi-beat extent: how often does the LIMIT check
  // look at more bytes than the current beat moves?
`endif
`endif
`endif

  // ---- REVIEW1_Aug2 H-11 instrumentation --------------------------------------
  // Counts x87 stack over/underflows, so "the fix is in and verify-all is green"
  // cannot be mistaken for "the fix does anything". Several fixes this session would
  // have been correct-but-INERT (H-05's nmi was never driven; M-03's I/O bitmap was
  // never consulted), and the only way to tell is to count the events BEFORE relying
  // on the repair. A stack fault should be RARE in correct code -- a nonzero count
  // across the ordinary corpus would mean the detector has false positives, which is
  // the failure mode that matters here.
`ifndef SYNTHESIS
  logic ven_stklog_en;
  int   ven_stk_ovf_n, ven_stk_unf_n;
  initial begin
    ven_stklog_en = $test$plusargs("ven_stklog") != 0;
    ven_stk_ovf_n = 0; ven_stk_unf_n = 0;
  end
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (fp_stk_ovf) begin
        ven_stk_ovf_n <= ven_stk_ovf_n + 1;
        if (ven_stklog_en)
          $display("[STKFLT] OVERFLOW  pc=%08h ftop=%0d fptag=%02h im=%0b",
                   q_pc, ftop, fptag, fctrl[0]);
      end
      if (fp_stk_unf) begin
        ven_stk_unf_n <= ven_stk_unf_n + 1;
        if (ven_stklog_en)
          $display("[STKFLT] UNDERFLOW pc=%08h ftop=%0d fptag=%02h im=%0b",
                   q_pc, ftop, fptag, fctrl[0]);
      end
    end
  end
  final if (ven_stklog_en)
    $display("[STKSTAT] x87 stack faults: overflow=%0d underflow=%0d",
             ven_stk_ovf_n, ven_stk_unf_n);
`endif

  // ---- REVIEW_Aug4 A4-H01: the deferred stack-fault latch -------------------
  // The operand-read fault decision is made at S_FEXEC (the writeback module's
  // det_* descriptor), but engine/PS/store commits happen states later. Latch
  // the decision at every S_FEXEC and replay it (fp_flt_q/fp_flt_ovf_q -> the
  // writeback's fp_flt_i/fp_flt_ovf_i) so the deferred commit applies the same
  // masked/unmasked response a direct commit would: an unmasked fault no
  // longer mutates ST/TOP from S_FP_BUSY/S_TRSC_BUSY/S_FPREM_BUSY/
  // S_FPTRAP_WAIT/S_FSTORE, and a masked fault substitutes the QNaN indefinite
  // instead of engine output computed from empty-slot bits. Cleared on any
  // retire; re-evaluated at every S_FEXEC, so a non-faulting op clears it too.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fp_flt_q <= 1'b0; fp_flt_ovf_q <= 1'b0;
    end else if (state == S_FEXEC) begin
      fp_flt_q     <= fp_stk_ovf || fp_stk_unf;
      fp_flt_ovf_q <= fp_stk_ovf;
    end else if (retire_valid) begin
      fp_flt_q     <= 1'b0; fp_flt_ovf_q <= 1'b0;
    end
  end

  // ---- REVIEW_aug2 H-05 instrumentation ---------------------------------------
  // The H-05 property is "a FAULTING IRET must not re-arm NMI". Nothing in the test
  // corpus drives the core's nmi input (the sys/verify TBs leave it tied low and
  // soc_en gates nmi_take), so without stimulus the fix would be correct-but-INERT
  // and no gate could tell the two behaviours apart.
  //
  // +ven_nmi_arm forces nmi_in_progress out of reset, i.e. "pretend an NMI handler is
  // running". ven_h05_armed_faults then counts faults delivered FROM an IRET state
  // while NMI is still armed -- which is exactly the observation that discriminates:
  //
  //   re-arm at COMMIT (correct): the faulting IRET has not touched the NMI state, so
  //       every one of pssiret's three rejected frames is counted.
  //   re-arm at DECODE (the bug): the first IRET disarmed NMI before it ever reached
  //       its stack reads, so the count is 0.
  //
  // The end state is IDENTICAL either way (each faulting IRET is followed by a handler
  // IRET that commits), which is why the count, not the final register value, is the
  // thing worth measuring.
  // ---- REVIEW_aug2 H-01 instrumentation ---------------------------------------
  // Counts the cases the H-01 fix actually CHANGES, so "verify-all is green" cannot
  // be mistaken for "this is covered":
  //   h01_ptr16 : ESP writebacks masked by stk_ptr16 that the OLD `real_mode`
  //               condition would have left unmasked -- i.e. a genuine 16-bit
  //               PROTECTED-mode stack push/pop.
  //   h01_ssb   : times the new SS.B captures (cross-priv delivery / task switch)
  //               actually changed ss_b.
  // Printed only with +ven_h01, so a normal run is byte-identical and silent.
  logic ven_seglog_en;
  initial ven_seglog_en = $test$plusargs("ven_seglog") != 0;
  logic ven_h01_en;
  initial ven_h01_en = $test$plusargs("ven_h01") != 0;
  int   ven_h01_ptr16, ven_h01_ssb;
  // REVIEW1_Aug2 C-01: how many accesses the segment check actually EXAMINES, split by
  // governing segment. "Zero rejections" is only meaningful alongside a non-zero
  // examined count -- otherwise the check could be passing by not running.
  int   ven_seg_chk_n, ven_seg_chk_ss, ven_seg_chk_es;
  logic ven_h01_ssb_prev;
  state_e ven_h01_state_prev;
  // REVIEW1_Aug2 C-04 measurement: accesses whose paging class the fix CHANGES --
  // CPL3 implicit system-structure references that used to be checked as user data.
  // REVIEW1_Aug2 C-09 measurement: task-switch accesses that now TRANSLATE. Zero would
  // mean the corpus never performs a task switch with paging on, i.e. the fix is
  // correct but unexercised.
  int ven_c09_n;
  always_ff @(posedge clk) if (!rst_n) ven_c09_n <= 0;
    else if (paging_on && mem_req_pre_sq &&
             (state==S_TSW_SAVE || state==S_TSW_READ || state==S_TSW_LDT ||
              state==S_TSW_SEG  || state==S_TSW_BUSY)) ven_c09_n <= ven_c09_n + 1;
  final if (ven_seglog_en)
    $display("[C09] paged task-switch accesses translated: %0d", ven_c09_n);

  int ven_c04_n;
  always_ff @(posedge clk) if (!rst_n) ven_c04_n <= 0;
    else if (paging_on && cur_is_d && mem_req_pre_sq && (eff_cpl == 2'd3) && !cur_seg_rel)
      ven_c04_n <= ven_c04_n + 1;
  final if (ven_seglog_en)
    $display("[C04] CPL3 implicit system references reclassified: %0d", ven_c04_n);

  int ven_ioperm_n;
  always_ff @(posedge clk) if (!rst_n) ven_ioperm_n <= 0;
    else if (ioperm_needed && state == S_DECODE) ven_ioperm_n <= ven_ioperm_n + 1;
  final if (ven_seglog_en)
    $display("[IOPERM] bitmap consults required: %0d", ven_ioperm_n);
  final if (ven_seglog_en)
    // Tag deliberately NOT "SEGCHK...": run-seg-gate.sh counts per-access rejections
    // with `grep -c SEGCHK`, and a summary line sharing that prefix was counted as
    // a 19th rejection. Distinct prefix so the two can never be confused.
    $display("[SEGSTAT] segment-relative accesses examined: %0d  (SS %0d, ES %0d)",
             ven_seg_chk_n, ven_seg_chk_ss, ven_seg_chk_es);
  final if (ven_h01_en)
    $display("[H01] 16-bit PM-stack ESP writebacks: %0d   new SS.B captures: %0d",
             ven_h01_ptr16, ven_h01_ssb);

  logic ven_nmi_arm_en;
  initial ven_nmi_arm_en = $test$plusargs("ven_nmi_arm") != 0;
  int   ven_h05_armed_faults;
  final if (ven_nmi_arm_en)
    $display("[H05] faults delivered from an IRET with NMI still armed: %0d",
             ven_h05_armed_faults);
`endif
  logic        seg_off_over_limit, seg_null_sel, seg_not_present, seg_expand_down;

  // REVIEW2_aug2 H-05: the "descriptor has been loaded IN PROTECTED MODE" bit that
  // seg_not_present and seg_null_sel were tied off for want of.
  //
  // The measured objection to both checks was the real->protected TRANSITION WINDOW: at
  // the instant CR0.PE goes 0->1 the segment registers still hold real-mode values
  // (DS=SS=0x0000) with their real-mode hidden descriptors cached and valid, and IA-32
  // says the HIDDEN DESCRIPTOR governs until a reload. Faulting there killed every one
  // of pseg/pmode/ppage/pcpl/pfcpl3, and an empty descriptor cache (attr=00) is
  // indistinguishable from "a descriptor that says not-present" without this bit.
  //
  // REVIEW1_Aug3 R2-H07: WIRED, not derived -- every hidden-state load site
  // writes seg_pm_loaded directly (the attr-change inference could not see a
  // same-attr reload or an already-zero null load). Cleared wholesale on a
  // return to real mode (the backstop at the top of the FSM body), where the
  // question is moot.
`ifndef SYNTHESIS
  // H-06 reachability: does any test actually take the same-priv 16-bit gate?
  logic ven_h06_hit; int ven_h06_n; logic ven_h06log_en;
  initial begin ven_h06log_en = $test$plusargs("ven_h06log") != 0; ven_h06_n = 0; end
  always_ff @(posedge clk) if (rst_n && ven_h06_hit) ven_h06_n <= ven_h06_n + 1;
  final if (ven_h06log_en) $display("[H06GATE] same-priv 16-bit gate pushes: %0d", ven_h06_n);
`endif
  logic        seg_pm_loaded [NUM_SEG];
`ifndef SYNTHESIS
  // A check that is "live" but whose enable never sets is just a tie-off with extra
  // steps. Count 0->1 transitions of the explicit loaded bit.
  int ven_pmld_n; logic ven_pmldlog_en;
  logic [NUM_SEG-1:0] ven_pmld_q;
  initial begin ven_pmldlog_en = $test$plusargs("ven_pmldlog") != 0; ven_pmld_n = 0; end
  always_ff @(posedge clk) if (rst_n) begin
    for (int i = 0; i < NUM_SEG; i++) begin
      if (seg_pm_loaded[i] && !ven_pmld_q[i]) ven_pmld_n <= ven_pmld_n + 1;
      ven_pmld_q[i] <= seg_pm_loaded[i];
    end
  end
  final if (ven_pmldlog_en)
    $display("[PMLOAD] segments reaching protected-mode-loaded: %0d", ven_pmld_n);
`endif
  // REVIEW1_Aug3 R2-H07: seg_pm_loaded is now EXPLICIT — written at every
  // segment hidden-state load site (1 = the hidden state was loaded in
  // protected mode, whether from a validated descriptor or as a null/nulled
  // segment; 0 = real-mode/V86/SMM-style state). The attr-CHANGE inference this
  // replaces could not see a reload whose descriptor happened to carry the
  // same attribute byte, and had no representation of a null load whose attr
  // was already zero. Reset and the PE-drop backstop clear live in the FSM
  // always_ff with the load-site writes (single driver; see the reset arm and
  // the top of the case) -- seg_b[]'s reset sits in the same two segment
  // reset loops for the same single-owner reason.
  logic [31:0] seg_ed_upper;      // expand-down upper bound (by the segment's B bit)
  logic        seg_type_fault;    // write to non-writable / read of execute-only
  // ---- REVIEW2_Aug1 C-06: the bus driver publishes its OWN segment basis --------
  // seg_chk_base used to RECONSTRUCT the base as `(state==S_STORE) ? stbase : opbase`.
  // That is a second copy of a decision the bus driver already makes, and it was wrong
  // three ways: it claimed a base for descriptor-table states that use none, it used
  // opbase for the string arms that actually use dbase_edi (the ES base), and it
  // guessed for every state it had never heard of. Measured consequence: 6/78/18
  // spurious rejections in pseg/pv86/ptaskv86, all with off=0xfffe0528-style
  // underflows because a linear GDT/IDT address had a segment base subtracted from it.
  //
  // core_bus_driver.svh now sets cur_seg_rel at each arm that builds an address from a
  // segment base, so the check no longer runs on fetches or on linear descriptor-table
  // reads. That fixed the false positives.
  //
  // HONEST LIMIT (REVIEW1_Aug2 C-01 called this out, correctly): the driver publishes
  // the FLAG but NOT the base. seg_chk_base below is still the reconstruction
  // `(state==S_STORE) ? stbase : opbase`, and an earlier revision of this comment
  // claimed a cur_seg_base signal that was never committed. Consequences that remain:
  //   * string stores use dbase_edi (ES) while dseg names the string SOURCE (DS), so
  //     the linear address can be right while the LIMIT comes from the wrong hidden
  //     descriptor. Same for the ES side of CMPS in S_LOAD2.
  //   * S_INT_PUSH / S_IRET stack accesses carry no segment identity, so their SS
  //     limits are not checked at all.
  // Both need the access to carry its segment INDEX, not just a base -- see #65.
  logic        tsw_seg_ts;               // incoming segment fails a type/privilege rule -> #TS(sel)
  logic        tsw_seg_np;               // ...or only its Present bit            -> #NP(sel)
  // REVIEW_Aug3 C-06: the S_TSW_SEG descriptor read must not ISSUE for a selector
  // that is already known-bad. The beat-1 validation checked sel_in_table() AFTER
  // the read, so an out-of-table selector became an address first -- and under
  // paging that read can #PF ahead of the architecturally prior #TS. The selector
  // and the staged incoming LDT limit are both stable for the beat, so the bounds
  // test runs combinationally: the bus arm suppresses the request and the FSM
  // faults at beat 0 with no memory touched. Null selectors (legal for
  // DS/ES/FS/GS) still read GDT[0], matching the existing structure.
  logic        tsw_seg_oob;
  assign tsw_seg_oob = (state == S_TSW_SEG) && !tsw_eflags[17]
                    && !is_null_selector(tsw_sel[3'(tsw_step[4:1])])   // R2-C02
                    && !sel_in_table_st(tsw_sel[3'(tsw_step[4:1])], tsw_st_ldt_limit);
  // REVIEW1_Aug3 R2-C02: an incoming NULL selector (TI=0/index-0) also performs
  // no descriptor read -- CS/SS null faults, a null data selector stages an
  // explicit null hidden cache. One suppression predicate for the bus arm, the
  // translation predicate, and the FSM.
  logic        tsw_seg_null;
  assign tsw_seg_null = (state == S_TSW_SEG) && !tsw_eflags[17]
                     && is_null_selector(tsw_sel[3'(tsw_step[4:1])]);
  // ---- REVIEW1_Aug2 C-09 (atomicity): stage the incoming segment state -----------
  // S_TSW_SEG wrote seg_base/seg_limit/seg_attr, cpl_r and ss_b one descriptor at a
  // time, before the EIP/EFLAGS/GPR/CR3/TR commit in S_TSW_BUSY. A descriptor rejected
  // at beat 9 -- or a page fault on its read -- therefore left beats 0..8 already
  // INSTALLED and the task half switched: segments from the new task, everything else
  // from the old one. Same failure C-06/C-07 removed from the IRET paths, over a
  // larger state set. The six descriptors now land here and commit together.
  // REVIEW2_aug2 C-05: the SELECTOR belongs in the staging too. It was committed
  // immediately in S_TSW_SEG while base/limit/attr were staged, so a later #TS or #PF
  // left the new selector paired with the OLD hidden descriptor.
  logic [15:0] tsw_st_sel   [NUM_SEG];
  logic [31:0] tsw_st_base  [NUM_SEG];
  logic [31:0] tsw_st_limit [NUM_SEG];
  logic [7:0]  tsw_st_attr  [NUM_SEG];
  // REVIEW_Aug3 C-06: the D/B bit must be staged for EVERY segment, not just CS/SS.
  // Only CS.D and SS.B were carried, so a 16-bit non-SS expand-down data segment
  // kept the PREVIOUS task's upper bound (seg_b[]) across the switch.
  logic        tsw_st_b     [NUM_SEG];
  // R2-H07: the per-segment "loaded in protected mode" bit, staged with the rest
  // of the incoming hidden state (1 for validated/null staging, 0 for V86).
  logic        tsw_st_pml   [NUM_SEG];
  logic        tsw_st_cs_d, tsw_st_ss_b;
  logic [1:0]  tsw_st_cpl;
  // REVIEW2_aug2 C-05 (second bullet): the incoming LDTR, STAGED. S_TSW_LDT wrote
  // ldt_sel/ldt_base/ldt_limit the moment the LDT descriptor validated -- before ANY
  // of the six task segments had been read, let alone validated -- so a #TS or #PF
  // during S_TSW_SEG left the OLD task running with the NEW task's LDT installed, and
  // every subsequent TI=1 selector resolved through a table the running task does not
  // own. Committed with the rest of the context in S_TSW_BUSY.
  //
  // S_TSW_SEG must still ADDRESS through the incoming LDT (IA-32 loads LDTR before the
  // segment registers precisely so the new task's selectors resolve against it), so the
  // bus driver reads tsw_st_ldt_base rather than the live ldt_base. Staging the commit
  // and preserving that ordering are separate things, and both are required.
  logic [15:0] tsw_st_ldt_sel;
  logic [31:0] tsw_st_ldt_base;
  logic [15:0] tsw_st_ldt_limit;
  logic        walk_usr_lat;             // C-04: the class of the access that missed
  logic        mem_req_pre_sq;           // mem_req before the C-01 segment squash
  logic        xs_probing;               // C-02: the crossing-store probe phase
  // Shared-x87 stores validate their entire destination before the irrevocable
  // command edge.  This is a write-permission probe, not a speculative read:
  // it has no external bus transaction and must not set a leaf PTE's D bit.
  // `second` walks the page reached by a single beat that straddles 4 KiB.
  logic        fp_store_probing;
  logic        fp_store_probe_second;
  logic        fp_store_probe_cross;
  logic        fp_store_probe_advance;
  logic        walk_set_dirty;           // H-02: may set D (probe excluded), vs
                                         //       walk_is_write = architectural W/R
  logic        cur_seg_rel;              // this access is SEGMENT-RELATIVE
  logic [2:0]  cur_seg_idx;              // ...governed by THIS segment
  logic [31:0] seg_chk_base, seg_chk_off;
  logic        seg_access_fault;
  // REVIEW2_aug2 H-05: the INSTRUCTION-FETCH CS-limit check, which did not exist. The
  // data-side check is deliberately qualified on cur_is_d (a fetch address measured
  // against the DS limit is the spurious #GP an earlier round reverted the whole
  // delivery for), so fetches were left entirely unchecked: EIP could leave the code
  // segment and the core kept fetching.
  //
  // Checked at the FIRST word of the instruction only (fetch_word==0). IA-32 checks
  // every byte fetched, but this core's S_FETCH pulls whole words ahead of knowing the
  // instruction length, so checking later beats would fault on PREFETCH past the last
  // instruction in a segment -- inventing violations, which is exactly the failure this
  // finding's delivery was reverted for twice. An instruction whose FIRST byte is
  // outside CS is the case that matters and the one that cannot false-positive; an
  // instruction straddling the limit is still missed and is recorded as such.
  logic        cs_fetch_fault;
  logic        cs_extent_fault;   // R2-H07: decoded-extent half (VEN_SEG_ENFORCE)
  always_comb begin
    logic [32:0] last_byte;
    logic [7:0]  a;
    logic [15:0] chk_sel;   // R2-H07: the probed segment's selector (staged at S_INT_PROBE)
    // REVIEW1_Aug2 C-01: the descriptor comes from the access's OWN segment index,
    // published by the bus driver next to the address, not from dseg. They differ for
    // string stores (ES vs the DS the source names) and for every stack access.
    // REVIEW1_Aug3 R2-H07: S_INT_PROBE probes the STAGED new stack (int_ss_*) --
    // by R2-C04 design the live SS is still the OLD one in this state, so reading
    // seg_*[SG_SS] would judge the new frame by the old segment's base/limit.
    // Measured under VEN_SEG_ENFORCE: a V86->PM delivery's probe evaluated the
    // monitor's frame against the V86 task's 64K paragraph SS -> false #SS
    // cascade (ptaskv86/pv86). Source the check from the staged descriptor.
    dlimit = (state == S_INT_PROBE) ? int_ss_limit : seg_limit[cur_seg_idx];
    a      = (state == S_INT_PROBE) ? int_ss_attr  : seg_attr[cur_seg_idx];
    chk_sel = (state == S_INT_PROBE) ? int_new_ss  : seg_sel[cur_seg_idx];
    // Data-segment type bits (S=1, bit4): bit3=0 data, bit2=E expand-down, bit1=W.
    seg_expand_down = a[4] && !a[3] && a[2];
    // The expand-down upper bound follows the B bit of the segment governing THIS
    // access. The core caches B only for SS (ss_b) and D for CS (cs_d); there is no
    // per-segment array. Expand-down segments are essentially always stacks, so SS is
    // the case that exists and it is exact. For a non-SS expand-down data segment the
    // bound falls back to 4 GiB, which is FAIL-OPEN (it can miss a violation, never
    // invent one) -- stated rather than silently assumed, and it needs the same
    // per-access descriptor work as the rest of C-01 to do properly.
    // REVIEW2_aug2 H-05: use the segment's OWN B bit. SS keeps reading ss_b (that
    // register is also the stack-width source and is maintained on every path that
    // sets SS); every other segment now consults seg_b[], which S_SEGLD captures from
    // desc[54]. A segment whose load path does not yet write seg_b[] still reads 1 and
    // therefore still gets the 4 GiB bound -- unchanged, not newly faulting.
    seg_ed_upper = (cur_seg_idx == 3'(SG_SS))
                 ? (((state == S_INT_PROBE) ? int_ss_b : ss_b) ? 32'hFFFF_FFFF : 32'h0000_FFFF)
                 : (seg_b[cur_seg_idx] ? 32'hFFFF_FFFF : 32'h0000_FFFF);
    // MEASURED (UPDATE 355): this fired spuriously inside the Err79 #GP handler with
    // dseg=2 dlimit=00000000 attr=00 -- the hidden descriptor cache was EMPTY, not "a
    // descriptor that says not-present". This core has no "descriptor has been loaded"
    // bit, so it cannot tell those apart -- the same reason seg_null_sel is tied off
    // below. Tied off rather than fault legitimate code in a window where the cache is
    // simply unpopulated.
    // REVIEW2_aug2 H-05: live once the descriptor was actually loaded in protected
    // mode. Before that, attr=00 means "cache unpopulated", not "not present".
    seg_not_present = seg_pm_loaded[cur_seg_idx] && !a[7];   // a: staged for S_INT_PROBE
    // A null selector may be LOADED but never used to address memory -- #GP(0).
    //
    // BUT NOT FROM THE SELECTOR VALUE ALONE, which is what this used to test and which
    // is WRONG. Measured against the pseg system test: at the instant CR0.PE goes 0->1
    // the segment registers still hold their REAL-MODE values (DS=SS=0x0000) with
    // their real-mode hidden descriptors still cached and valid, and they are not
    // reloaded until several instructions later. IA-32 says the HIDDEN DESCRIPTOR
    // governs until a reload, so selector 0 is perfectly legitimate in that window --
    // and every one of pseg/pmode/ppage/pcpl/pfcpl3 died there when this fired.
    //
    // Detecting a genuinely-null data segment needs a "descriptor has been loaded in
    // protected mode and was null" bit that this core does not track. Until it does,
    // the honest thing is to NOT guess: drop the check rather than fault legitimate
    // transition-window accesses. Tracked in #65 with the access descriptor, which is
    // where that state belongs.
    // REVIEW2_aug2 H-05: likewise. Selector 0 is legitimate in the transition window
    // (the real-mode hidden descriptor still governs); it is a #GP(0) only once the
    // segment has been reloaded in protected mode and is then used to address memory.
    seg_null_sel    = seg_pm_loaded[cur_seg_idx]
                   && (chk_sel[15:2] == 14'd0);   // chk_sel: staged for S_INT_PROBE
    // REVIEW2 C-06: the offset comes from cur_lin, NOT q_ea.
    //
    // MEASURED (UPDATE 355): trusting q_ea produced a repeating spurious #GP with
    //     q_ea=600d600d dseg=2 dlimit=0000ffff
    // where 0x600d600d is a SENTINEL DATA VALUE, not an address -- q_ea is simply not
    // the addressing basis in every S_LOAD/S_STORE clock. cur_lin IS: it is the
    // per-state linear address that mirrors core_bus_driver.svh, and CHECK 5 asserts
    // the two agree on every translatable request. Deriving the offset from it makes
    // the limit check and the actual access share ONE source -- the same "one address,
    // one source" discipline that let the C-02 split land with zero CHECK-5 firings.
    //
    // offset = cur_lin - segment base, using the base the bus driver uses for THIS
    // state (stbase for S_STORE, opbase otherwise -- see the S_LOAD/S_STORE arms).
    // ...and so does the base, so the offset is the real segment offset rather than a
    // reconstruction that guessed stbase-or-opbase by state.
    seg_chk_base = (state == S_INT_PROBE) ? int_ss_base : seg_base[cur_seg_idx];
    seg_chk_off  = cur_lin - seg_chk_base;
    // Real access extent: last touched byte = offset + (width-1), not a fixed +3.
    // REVIEW2_aug2 H-05: extent from the CANONICAL access size, not q_w. cur_size is
    // the same (start,length) descriptor the C-03/C-04 page-crossing layer uses and the
    // one the bus driver's strobes follow; q_w is the decoded operand width, which is
    // not the same thing for the states that access a fixed-size object (descriptor
    // reads, frame pushes, TSS fields). Sharing one source is the point -- a limit
    // check computed off a different width than the access it guards is not a check.
    last_byte = {1'b0, seg_chk_off} + {25'd0, seg_ext_size} - 33'd1;
    if (seg_expand_down)
      // Expand-down: the VALID range is (limit, upper], so an access is out of range
      // when its FIRST byte is at or below the limit -- OR when its LAST byte passes
      // the upper bound. REVIEW1_Aug2 C-01: only the lower half was checked, and the
      // comment claimed "the upper end is covered by the wrap", which is not a check.
      // The upper bound is 0xFFFF when the segment's B bit is clear and 0xFFFFFFFF
      // when it is set (SDM 3.4.5.1), so a 16-bit expand-down stack could address
      // above 64 KiB unchallenged. last_byte is 33-bit, so an extent that wraps past
      // the top exceeds it too rather than aliasing back into range.
      seg_off_over_limit = sys_mode && !real_mode && a[7]
                        && (({1'b0,seg_chk_off} <= {1'b0,dlimit})
                         || (last_byte > {1'b0, seg_ed_upper}));
    else
      // a[7] (P) REQUIRED: with an unpopulated descriptor cache (attr=00, limit=0)
      // EVERY offset trivially exceeds a zero limit. Measured at 0xf02f1 in the Err79
      // handler, where this produced a spurious #GP that broke m6.
      seg_off_over_limit = sys_mode && !real_mode && a[7]
                        && (last_byte > {1'b0,dlimit});
    // ---- REVIEW1_Aug2 C-01: TYPE permission, not just the limit --------------
    // Nothing checked what the segment PERMITS, only how big it is, so a write
    // through a read-only data segment and a read through an execute-only code
    // segment both reached memory. Data-segment type bits (S=1, bit3=0): bit1 = W.
    // Code (S=1, bit3=1): bit1 = R, and a code segment is never writable.
    //   a[7] (P) is required for the same reason the limit check requires it -- an
    //   unpopulated descriptor cache reads as attr=00 and would trivially "fail"
    //   every rule. Real mode and non-segment-relative accesses are excluded by the
    //   composite below, exactly as for the limit.
    seg_type_fault = sys_mode && !real_mode && a[7] && a[4]
                  && ( cur_is_w ?  (a[3] || !a[1])   // write: code seg, or data !W
                                : ( a[3] && !a[1])); // read : execute-only code seg
    // The composite the delivery arm consumes.
    // ---- REVIEW2_Aug1 C-06, THIRD false positive (measured, +ven_seglog) --------
    // This whole block describes a DATA access -- it reads seg_attr[dseg]/
    // seg_limit[dseg] and derives the offset from the data segment's base. It was
    // never qualified on the access actually BEING a data access, so every
    // INSTRUCTION FETCH was limit-checked against DS. Measured on pmode, and on all
    // 19 system tests (12 firings is the floor, i.e. it is systematic):
    //   [SEGCHK] st=1 dseg=2 sel=0000 base=00000000 lim=0000ffff attr=93
    //            cur_lin=000f0066 off=000f0066 w=4 cpl=0 pc=00000066
    // st=1 is S_FETCH and cur_lin is a CODE address, so of course 0x000f0066 exceeds
    // the DS limit 0xFFFF. THIS is the "spurious #GP looping at 0xf020d" the previous
    // round reverted the delivery for: not a subtle descriptor-cache window, just the
    // check running on the wrong access class.
    //
    // cur_is_d is the same signal the paging permission logic already uses to split
    // its D-side and I-side rules, so this reuses the existing classification rather
    // than inventing a second one. A CS-limit check for fetches is a DIFFERENT check
    // against a DIFFERENT descriptor and is NOT added here.
    //
    // WHAT IS STILL WRONG, measured with the same +ven_seglog after this qualifier.
    // 16 of the 19 system tests go to zero; three do not, and they are all ONE class:
    //   pseg     6   [SEGCHK] st=23 dseg=2 sel=0018 base=00020000 lim=0000ffff
    //                         cur_lin=00000528 off=fffe0528
    //   pv86    78   [SEGCHK] st=33 dseg=1 sel=2000 base=00020000 lim=0000ffff
    //                         cur_lin=00001068 off=fffe1068
    //   ptaskv86 18  (same shape)
    // cur_lin 0x528 is the GDT (base 0x500) and 0x1068 is the IDT (base 0x1000):
    // these are DESCRIPTOR-TABLE and system-structure reads. They address memory
    // LINEARLY -- they do not go through dseg at all -- so subtracting the data
    // segment's base underflows (off=0xfffe0528) and every one trivially "exceeds"
    // the limit. They are data-side accesses, so cur_is_d cannot separate them.
    //
    // The missing input is one bit: IS THIS ACCESS SEGMENT-RELATIVE. Writing it here
    // as a list of states would recreate the exact mirror that produced this whole
    // family of false positives -- a second hand-maintained copy of the bus driver's
    // base selection, which is what seg_chk_base already is and why it is wrong for
    // these states. That bit belongs in the per-access descriptor (#65), alongside
    // the linear address, width, class and split phase.
    //
    // So the delivery stays OFF and this stays a diagnostic. What changed is that the
    // remaining blocker is now a NAMED, MEASURED single missing field rather than
    // "a spurious #GP loops at 0xf020d".
    // REVIEW2_aug2 C-01: DETECTION MUST FOLLOW THE SAME POLICY AS DELIVERY.
    //
    // This was computed unconditionally while delivery lives under
    // `ifdef VEN_SEG_ENFORCE (core.sv ~4175) and the bus-driver SQUASH was likewise
    // unconditional. In the DEFAULT build that gave: fault asserts -> request
    // suppressed -> no #GP started -> the FSM waits forever for an ack that can never
    // arrive. A latent DEADLOCK on any segment violation.
    //
    // MEASURED on pseglim, which violates deliberately:
    //     default build      95 instructions, then "quiescent (core idle)"
    //     +VEN_SEG_ENFORCE  154 instructions -- the #GP is delivered and it continues
    //
    // The bus-driver comment asserted this signal was "tied to the enforcement build
    // by its own definition". It was not; I wrote that justification without checking
    // it. Now it IS true, which makes the squash genuinely inert in the default build
    // and keeps the two halves from drifting apart again.
    //
    // Why not simply enable enforcement everywhere (the review's stated preference):
    // H-05 in the same review documents that enforcement is still architecturally
    // INCOMPLETE when enabled, and m7 (Win95/Quake) is excluded from verify-all, so a
    // spurious #GP in a real guest cannot be ruled out from here. Flipping the default
    // belongs with H-05's remaining descriptor-state gaps, not ahead of them.
`ifdef VEN_SEG_ENFORCE
    cs_fetch_fault = sys_mode && !real_mode && !cur_is_d
                  && (state == S_FETCH) && (fetch_word == 3'd0)
                  && seg_attr[SG_CS][7]                    // P: unpopulated cache reads 0
                  && ((cur_lin - seg_base[SG_CS]) > seg_limit[SG_CS]);
    // REVIEW1_Aug3 R2-H07: the DECODED-EXTENT half. The first-byte check above
    // misses an instruction whose LATER bytes cross CS.limit (an instruction
    // ending exactly AT the limit is legal; one byte past it is #GP(0)).
    // Evaluated at the pre-commit point of both issue paths, using eip -- the
    // ABOUT-TO-EXECUTE instruction -- paired with the length source THAT PATH
    // is using right now: u_d.len in S_PIPE (the fastpath advances eip by
    // exactly it at issue), d_len in S_DECODE. (First attempt used q_pc/q_len:
    // q_pc lags eip by an instruction at the issue point; second used d_len in
    // S_PIPE, which lags eip across a far-transfer redirect -- measured by
    // pfetchlim: the first in-segment instruction was judged with the ENTRY
    // ljmp's 7-byte length.) A limit is an offset bound, so no base
    // subtraction (that also dodges the PE-transition window's real-mode base).
    cs_extent_fault = sys_mode && !real_mode && !v86
                  && seg_attr[SG_CS][7]
                  && ((state == S_PIPE && (stall_cnt == 7'd0) && pipe_bytes_ok
                       && (({1'b0, eip} + {28'd0, u_d.len} - 33'd1) > {1'b0, seg_limit[SG_CS]}))
                   || (state == S_DECODE
                       && (({1'b0, eip} + {28'd0, d_len} - 33'd1) > {1'b0, seg_limit[SG_CS]})));
    seg_access_fault = cur_is_d && cur_seg_rel && !seg_ext_skip
                    && (seg_off_over_limit || seg_null_sel || seg_not_present
                     || seg_type_fault);
`else
    // Diagnostic-only in the default build: +ven_seglog still reports what WOULD be
    // rejected (that probe reads the sub-terms directly), but nothing suppresses an
    // access that nothing will fault.
    seg_access_fault = 1'b0;
    cs_fetch_fault   = 1'b0;
    cs_extent_fault  = 1'b0;
`endif
  end



  // ===========================================================================
  // M2S.2 — linear-address translation (paging). The bus driver below first
  // computes the LINEAR address for the current state's access into `mem_addr`
  // exactly as M2S.1 did; this stage then post-translates it to PHYSICAL when
  // paging_on. The split I/D TLBs are looked up combinationally; on a HIT the
  // physical frame replaces the linear page; on a MISS the FSM diverts to S_WALK
  // (see xlate_miss / mem_xlate below). When paging is off (real mode, flat
  // PM-before-PG, ALL of user mode) translation is a pass-through (linear ==
  // physical) so M2S.1 + user mode stay byte-identical.
  // ===========================================================================
  // The TLB ARRAYS + lookup + fill-commit + flush were extracted into the `tlb`
  // module (rtl/mem/tlb.sv), instantiated as u_itlb (IS_D=0) and u_dtlb (IS_D=1)
  // below. The lk_* ports do the per-access lookup at `cur_lin` (consumed by
  // xlate_miss / perm_fault); the xl_* ports do the bus post-translate lookup at
  // `mem_addr` (consumed by mem_xlate). The whole S_WALK page-walk micro-sequence
  // STAYS here in the spine and drives the fill ports (see tlb_fill_* drivers and
  // the instantiation near the bus-translate block).

  // Translate a linear address for the CURRENT bus access (the bus post-stage).
  // `is_d`=1 selects the D-TLB (data), else the I-TLB (fetch). Returns the
  // physical address on a hit; on a miss (or paging off) returns the linear
  // address `lin` (the FSM never USES a miss result — it diverts to S_WALK
  // first). The hit/phys come from each instance's lk_* port. The post-translate
  // is only applied to the translatable states where cur_lin == this `lin`
  // (== mem_addr), so the lk lookup (driven by cur_lin) returns the right entry;
  // on miss/paging-off the actual `lin` (mem_addr) is passed through unchanged.
  function automatic logic [31:0] mem_xlate(input logic [31:0] lin, input logic is_d);
    begin
`ifdef VEN_FE_PIPE
      // FE_PIPE: physical = {registered page-frame, this access's page offset}. The
      // bus driver squashes during fe_xlate_pend, so this is only reached when the
      // registered page is valid + matches lin's page. Guard the registered-frame
      // use EXPLICITLY on (fe_*_v && fe_*_page==lin[31:12]) so a stale/mismatched
      // micro-TLB entry can NEVER drive a wrong physical (defense-in-depth pairing
      // with the fe_translatable re-registration gate): the lk_lin lookup is at
      // cur_lin==lin, so a guarded miss here passes the LINEAR through unchanged and
      // the FSM (xlate_miss) diverts to S_WALK to fill the right entry.
      if (!paging_on)                  mem_xlate = lin;
      else if (is_d && frm_pg_hit)     mem_xlate = {frm_pg_hitphys, lin[11:0]};
      else if (is_d  && fe_dtlb_hit && fe_dtlb_v &&
               (fe_dtlb_page == lin[31:12]))  mem_xlate = {fe_dtlb_phys, lin[11:0]};
      else if (!is_d && fe_itlb_hit && fe_itlb_v &&
               (fe_itlb_page == lin[31:12]))  mem_xlate = {fe_itlb_phys, lin[11:0]};
      else                              mem_xlate = lin;   // miss: value unused
`else
      if (!paging_on)                  mem_xlate = lin;
      else if (is_d && frm_pg_hit)     mem_xlate = {frm_pg_hitphys, lin[11:0]};
      else if (is_d  &&  dtlb_lk_hit)   mem_xlate = dtlb_lk_phys;
      else if (!is_d &&  itlb_lk_hit)   mem_xlate = itlb_lk_phys;
      else                              mem_xlate = lin;   // miss: value unused
`endif
    end
  endfunction

  // ===========================================================================
  // TLB fill-commit driver (combinational): mirrors the four S_WALK fill sites
  // EXACTLY and produces the single fill transaction for THIS clock. The commit
  // lands on the SAME posedge the original inline tlb_fill_*() NBA write did (the
  // clock where S_WALK reaches the fill branch under `mem_ack`), so the read-
  // before-write timing (lookup off the PRE-fill arrays this clock) is preserved.
  //   step0 big, A/D already set     -> fill_big(pde=mem_rdata)
  //   step1 big (PDE writeback)      -> fill_big(walk_pde | A | (write?D))
  //   step2 4 KiB, A/D already set   -> fill_4k(walk_pde, pte=mem_rdata, is_w)
  //   step3 4 KiB (PTE writeback)    -> fill_4k(walk_pde, pte_new=walk_pte|A|D, is_w)
  // Operand computation (perm = AND of PDE&PTE, 4 MiB pfn = {pde[31:22],10'd0})
  // is done here, replacing the old tlb_fill_4k/tlb_fill_big task bodies. The
  // fill is routed to ONE instance by walk_for_d (u_itlb when 0, u_dtlb when 1).
  logic        tlb_fill_en;
  logic        tlb_fill_is_d;
  logic [31:0] tlb_fill_lin;
  logic [19:0] tlb_fill_pfn;
  logic [2:0]  tlb_fill_perm;
  logic        tlb_fill_big;
  logic        tlb_fill_dirty;
  always_comb begin
    logic [31:0] pde, pte, pte_new;
    logic        is_big;
    tlb_fill_en    = 1'b0;
    tlb_fill_is_d  = walk_for_d;
    tlb_fill_lin   = walk_lin;
    tlb_fill_pfn   = 20'd0;
    tlb_fill_perm  = 3'd0;
    tlb_fill_big   = 1'b0;
    tlb_fill_dirty = 1'b0;
    if (state==S_WALK && mem_ack) begin
      unique case (walk_step)
        3'd0: begin
          pde    = mem_rdata;
          is_big = cr4_pse && pde[7];
          // a present 4 MiB page with A(+D for a REAL write) already set fills
          // directly. A4-C01: the D requirement keys on walk_set_dirty, NOT
          // walk_is_write -- a probe walk (write class, no D intent) fills the
          // CLEAN entry directly instead of walking forever.
          if (pde[0] && is_big && !(!pde[5] || (walk_set_dirty && !pde[6]))) begin
            tlb_fill_en   = 1'b1;
            tlb_fill_big  = 1'b1;
            tlb_fill_pfn  = {pde[31:22], 10'd0};
            tlb_fill_perm = {pde[2], pde[1], pde[0]};
            tlb_fill_dirty= pde[6];
          end
        end
        3'd1: begin
          is_big = cr4_pse && walk_pde[7];
          if (is_big) begin
            pde = walk_pde | 32'h0000_0020
                | ((walk_set_dirty && walk_wr_ok_big) ? 32'h0000_0040 : 32'd0);  // C-04; A4-C01: probe never sets D
            tlb_fill_en   = 1'b1;
            tlb_fill_big  = 1'b1;
            tlb_fill_pfn  = {pde[31:22], 10'd0};
            tlb_fill_perm = {pde[2], pde[1], pde[0]};
            tlb_fill_dirty= pde[6];
          end
        end
        3'd2: begin
          pte = mem_rdata;
          // present 4 KiB page with A(+D for a REAL write) already set fills
          // directly (A4-C01: walk_set_dirty, like the 4 MiB arm above).
          if (pte[0] && !(!pte[5] || (walk_set_dirty && !pte[6]))) begin
            tlb_fill_en   = 1'b1;
            tlb_fill_big  = 1'b0;
            tlb_fill_pfn  = pte[31:12];
            tlb_fill_perm = {walk_pde[2]&pte[2], walk_pde[1]&pte[1], walk_pde[0]&pte[0]};
            // REVIEW1_Aug2 C-05: the TLB's dirty bit must be the LEAF ENTRY'S dirty
            // bit, not "this was a write". The 4 MiB paths above already do exactly
            // this (pde[6] of the raw entry, pde[6] of the updated one); the 4 KiB
            // paths did not, and that is the asymmetry the finding names.
            tlb_fill_dirty= pte[6];
          end
        end
        default: begin   // step 3: PTE writeback then fill
          pte_new = walk_pte | 32'h0000_0020
                  | ((walk_set_dirty && walk_wr_ok_4k) ? 32'h0000_0040 : 32'd0);  // C-04; A4-C01: probe never sets D
          tlb_fill_en   = 1'b1;
          tlb_fill_big  = 1'b0;
          tlb_fill_pfn  = pte_new[31:12];
          tlb_fill_perm = {walk_pde[2]&pte_new[2], walk_pde[1]&pte_new[1],
                           walk_pde[0]&pte_new[0]};
          // REVIEW1_Aug2 C-05: pte_new sets D only when the write is PERMITTED
          // (walk_wr_ok_4k), but this recorded dirty=walk_is_write unconditionally --
          // so after a DENIED write the PTE still had D=0 while the TLB claimed the
          // page was dirty. A later legal supervisor write to the same translation
          // would then skip the required D-bit update, leaving PTE.D clear on a page
          // that had genuinely been written. Record what was actually stored.
          tlb_fill_dirty= pte_new[6];
        end
      endcase
    end
  end

  // TLB CR3 flush (combinational pulse): clears ONLY the val bits in BOTH TLBs.
  // Asserted on the exact clock the S_EXEC MOV CR3 commits (q_sysop SYS_MOVCR_TO,
  // q_sys_creg==3, in S_EXEC). q_sysop is mutually exclusive with the flag ops
  // (CLD/STD/CLC/.../STI), so the original if/else-if guard reduces to this.
  // REVIEW_Jul29 H-05: flushing ONLY on MOV CR3 was incomplete. A MOV CR0 that
  // toggles PG (or PE) and a MOV CR4 that changes PSE both change how existing
  // entries must be interpreted, so stale translations could survive a
  // disable/re-enable of paging, or a cached 4 MiB mapping could be re-read under
  // a different PSE setting. INVLPG (0F 01 /7, newly decoded above) joins here as
  // a conservative full flush. Over-flushing is architecturally SAFE — it can only
  // cost extra walks, never produce a wrong translation — which is why this is
  // gated broadly on any CR0/CR4 write rather than on a decoded bit-change.
  // H-01 helper pulses: the exact clocks the task-switch and RSM arms COMMIT a new
  // CR3. Both are the final beat of their micro-sequence, gated on mem_ack the same
  // way the commit itself is, so the flush lands on the same edge as the CR3 write.
  // ===========================================================================
  // REVIEW_aug2 C-04: Dirty must correspond to an ALLOWED write.
  // ===========================================================================
  // Permission is checked only on a TLB HIT (perm_fault). On a MISS the walker set D
  // from walk_is_write alone, filled the TLB, and only on the FOLLOWING clock did
  // perm_fault see RW/US and raise #PF. So a CPL3 write to a supervisor page, or a
  // write to a read-only page under WP, DIRTIED the leaf entry even though no
  // architectural write ever happened -- and the comment claiming "a permission fault
  // causes no A/D writeback" was true only for an already-resident translation.
  //
  // walk_wr_ok evaluates the SAME rule perm_fault uses, but from the WALKED entries:
  //   US: access allowed if the entry is user or we are supervisor
  //   RW: write allowed if the entry is writable, or supervisor with CR0.WP clear
  // 4 KiB combines PDE and PTE; a 4 MiB page has only the PDE. A is left alone --
  // Accessed semantics are a separate question, per the review.
  // ---- REVIEW1_Aug2 C-04: the PAGING ACCESS CLASS, not just the CPL --------------
  // walk_usr and perm_fault derived user/supervisor from eff_cpl alone, with no
  // override for IMPLICIT system-structure references. But cur_lin/translatable
  // include S_INT_GATE, S_INT_CS, S_INT_CS_RET, S_SEGLD, S_LJMP, S_LTR, S_INT_TSS,
  // S_INT_SS, S_IRET_SS and (new) S_IOPERM -- so when CPL3 executed a permitted
  // software interrupt, loaded a segment, or ran an IRET path, the PROCESSOR'S OWN
  // GDT/LDT/IDT/TSS fetch was checked as a USER data access. Real operating systems
  // put descriptor tables and TSS pages in supervisor-only mappings, and the guest's
  // CPL3 code is not the one reading those bytes -- the implicit access must succeed.
  // The current tests hide it by mapping the tables user-accessible.
  //
  // The class is exactly "is this access segment-relative": a guest operand or stack
  // access goes through a segment and carries the architectural CPL; an implicit
  // descriptor/gate/TSS/page-table reference addresses memory LINEARLY and is a
  // supervisor access. cur_seg_rel already answers that -- it was added for C-01 and
  // is measured against all 19 system tests -- so no new classification is invented.
  // Instruction fetch (cur_is_d=0) keeps the plain CPL rule.
  //
  // REVIEW1_Aug3 R2-C04 follow-up (measured by the pxprobe witness): the frame
  // probe and the call-gate param copy are IMPLICIT processor accesses, pushed/
  // read as SUPERVISOR regardless of the not-yet-committed CPL -- QEMU uses
  // cpu_stl/ldl_kernel for every frame push and param read, and silicon agrees
  // (#PF err US=0 on a denied frame page; a supervisor-only new stack is legal).
  // Without this exclusion a CPL3->CPL0 delivery onto supervisor-only pages
  // false-#PF'd, and the error code carried US=1.
  logic acc_usr;
  assign acc_usr = (eff_cpl == 2'd3) && (cur_is_d ? cur_seg_rel : 1'b1)
                && (state != S_INT_PROBE) && (state != S_CG_PRD);

  logic walk_usr, walk_wr_ok_big, walk_wr_ok_4k;
  // The walk runs AFTER the access that missed, and its own PTE reads are not
  // segment-relative, so the class has to be the one latched at the divert -- not
  // recomputed here, which would call every walk a supervisor access.
  assign walk_usr       = walk_usr_lat;
  assign walk_wr_ok_big = (walk_pde[2] || !walk_usr)
                       && (walk_pde[1] || (!walk_usr && !creg0[16]));
  assign walk_wr_ok_4k  = ((walk_pde[2] & walk_pte[2]) || !walk_usr)
                       && ((walk_pde[1] & walk_pte[1]) || (!walk_usr && !creg0[16]));

  logic tsw_cr3_commit, rsm_ctx_restore;
  assign tsw_cr3_commit  = (state == S_TSW_BUSY) && mem_ack && (tsw_step != 5'd0);
  assign rsm_ctx_restore = (state == S_RSM)      && (smm_step == SMM_LAST);

  // REVIEW2 H-01: a CR3 change is a CR3 change no matter which state commits it. This
  // fired only for S_EXEC INVLPG / MOV CR0,CR3,CR4 -- but a TASK SWITCH installs the
  // incoming task's CR3 (core_tsw.svh:156) and RSM restores CR0/CR3/CR4 from the SMM
  // save map (core_smm.svh:101), and neither flushed. The incoming task or the
  // resumed SMM context then reused the PREVIOUS address space's translations,
  // including their U/S and R/W bits -- stale-mapping execution across an address
  // space switch, which is about as bad as a paging bug gets.
  logic tlb_flush;
  assign tlb_flush = ( (state==S_EXEC) &&
                       ( (q_sysop==SYS_INVLPG) ||
                         ((q_sysop==SYS_MOVCR_TO) &&
                          ((q_sys_creg==3'd3) || (q_sys_creg==3'd0) || (q_sys_creg==3'd4))) ) )
                   || tsw_cr3_commit      // H-01: task switch loads the new task's CR3
                   || rsm_ctx_restore;    // H-01: RSM restores CR0/CR3/CR4

  // ---- Split I/D TLB instances. lk_* = combinational lookup at cur_lin (consumed
  // by xlate_miss / perm_fault AND, via mem_xlate, the bus post-translate, since
  // cur_lin == mem_addr in every translatable state). The fill is routed to the
  // matching side by walk_for_d (tlb_fill_is_d); flush hits both on a CR3 write.
  tlb #(.IS_D(1'b0), .TLB_ENTRIES(TLB_ENTRIES)) u_itlb (
      .clk(clk), .rst_n(rst_n),
      .lk_lin(cur_lin),  .lk_hit(itlb_lk_hit), .lk_phys(itlb_lk_phys),
      .lk_perm(itlb_lk_perm), .lk_dirty(itlb_lk_dirty),
      .fill_en(tlb_fill_en && (tlb_fill_is_d==1'b0)),
      .fill_lin(tlb_fill_lin), .fill_pfn(tlb_fill_pfn), .fill_perm(tlb_fill_perm),
      .fill_big(tlb_fill_big), .fill_dirty(tlb_fill_dirty),
      .flush_en(tlb_flush)
  );
  tlb #(.IS_D(1'b1), .TLB_ENTRIES(TLB_ENTRIES)) u_dtlb (
      .clk(clk), .rst_n(rst_n),
      .lk_lin(cur_lin),  .lk_hit(dtlb_lk_hit), .lk_phys(dtlb_lk_phys),
      .lk_perm(dtlb_lk_perm), .lk_dirty(dtlb_lk_dirty),
      .fill_en(tlb_fill_en && (tlb_fill_is_d==1'b1)),
      .fill_lin(tlb_fill_lin), .fill_pfn(tlb_fill_pfn), .fill_perm(tlb_fill_perm),
      .fill_big(tlb_fill_big), .fill_dirty(tlb_fill_dirty),
      .flush_en(tlb_flush)
  );

`ifdef VEN_FE_PIPE
  // +VEN_FE_PIPE: the page-keyed micro-TLB register. On the page-crossing stall clock
  // (fe_xlate_pend) it samples the combinational {i,d}tlb lookup for cur_lin's page;
  // thereafter xlate_miss / mem_xlate read it (off the hit_of critical path). Coherence:
  //  * a CR3 write (tlb_flush) clears both arrays -> invalidate both fe_*_q.
  //  * a page-walk fill (tlb_fill_en) replaces ONE side's translation (incl. set-D on
  //    a write) -> invalidate that side so it re-registers the fresh entry next access.
  // Invalidate wins over (re-)register this edge, so a freshly-flushed/filled page is
  // never cached stale. Mirrors the access split: fetch (cur_is_d=0) -> itlb, data -> dtlb.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fe_itlb_v <= 1'b0; fe_dtlb_v <= 1'b0;
    end else begin
      if (tlb_flush) begin fe_itlb_v <= 1'b0; fe_dtlb_v <= 1'b0; end
      else begin
        // Re-register ONLY from a genuine translatable access this clock
        // (fe_translatable): in a non-translatable state (a task-switch TSS save
        // S_TSW_SAVE, S_LTR/S_INT_TSS, or an idle default) cur_lin is 0 / not the
        // access linear while cur_is_d still defaults to 1, so the OLD code
        // registered fe_*_page=0 with fe_*_phys = the lookup at cur_lin=0 — i.e.
        // the D-TLB INDEX-0 entry's frame (page 0x30 maps to index 0 too). That
        // produced an INCONSISTENT cached entry (page=0, phys=0x30) that then
        // mis-translated a later page-0 (or the colliding-page) access, dropping
        // the CWSDPMI dispatcher's vector store -> the bogus #DE. Gating on
        // fe_translatable keeps the registered translate keyed to a real access.
        // I-side
        if (tlb_fill_en && !tlb_fill_is_d) fe_itlb_v <= 1'b0;
        else if (paging_on && fe_translatable && !cur_is_d &&
                 (!fe_itlb_v || (fe_itlb_page != cur_lin[31:12]))) begin
          fe_itlb_page <= cur_lin[31:12]; fe_itlb_phys <= itlb_lk_phys[31:12];
          fe_itlb_hit  <= itlb_lk_hit;    fe_itlb_v    <= 1'b1;
        end
        // D-side
        if (tlb_fill_en && tlb_fill_is_d) fe_dtlb_v <= 1'b0;
        else if (paging_on && fe_translatable && cur_is_d &&
                 (!fe_dtlb_v || (fe_dtlb_page != cur_lin[31:12]))) begin
          fe_dtlb_page  <= cur_lin[31:12]; fe_dtlb_phys  <= dtlb_lk_phys[31:12];
          fe_dtlb_hit   <= dtlb_lk_hit;    fe_dtlb_dirty <= dtlb_lk_dirty;
          fe_dtlb_v     <= 1'b1;
        end
      end
    end
  end
`endif

  // M2S.3 — begin IDT delivery of a HARDWARE fault (#GP/#NP/#SS/#PF/#UD raised
  // from a fault DECISION that prior stages only computed). A fault always
  // pushes the FAULTING instruction's EIP (restartable); `vec`, `has_err`, and
  // `err` carry the IA-32 error-code rules. `src_pc` is the q_pc to stamp on the
  // single delivery retire record. The micro-sequence then reads IDT[vec], the
  // gate's CS descriptor, pushes the frame, and loads CS:EIP. Only invoked when
  // sys_mode (faults can only arise from the system-mode states).
  // ---- M2S.6 hardware-breakpoint match (gated sys_mode at the call sites) ----
  // Return the DR6 status bits (B0..B3) for every ENABLED DRn (DR7 Ln or Gn set)
  // whose linear address matches `lin` with the requested access type. `want_x`
  // selects an instruction (execute, R/W=00) breakpoint; otherwise a data WRITE
  // (R/W=01) or read-or-write (R/W=11) breakpoint. LEN matching: a DRn covers a
  // 1/2/4/8-aligned region (LENn 00/01/11/10); the corpus uses LEN0=00 (execute,
  // 1 byte) and LEN1=11 (4 bytes), so we honour the documented LEN masks. The
  // length mask aligns `lin` and the breakpoint address before the equality test.
  function automatic logic [3:0] dr_match(input logic [31:0] lin, input logic want_x);
    logic [3:0] hit;
    logic [31:0] addr [4];
    logic [1:0]  rw   [4];
    logic [1:0]  len  [4];
    logic        en   [4];
    logic [31:0] lenmask;
    begin
      addr[0]=dr0; addr[1]=dr1; addr[2]=dr2; addr[3]=dr3;
      // DR7: Ln=bit(2n), Gn=bit(2n+1); R/Wn=bits(16+4n..17+4n); LENn=bits(18+4n..19+4n).
      for (int i=0;i<4;i++) begin
        en[i]  = dr7[2*i] | dr7[2*i+1];
        rw[i]  = dr7[16+4*i +: 2];
        len[i] = dr7[18+4*i +: 2];
      end
      hit = 4'd0;
      for (int i=0;i<4;i++) begin
        // LEN encoding -> alignment mask: 00=1B(0x0) 01=2B(0x1) 11=4B(0x3) 10=8B(0x7)
        unique case (len[i])
          2'b00:   lenmask = 32'h0000_0000;
          2'b01:   lenmask = 32'h0000_0001;
          2'b10:   lenmask = 32'h0000_0007;
          default: lenmask = 32'h0000_0003;
        endcase
        if (en[i] && ((lin & ~lenmask) == (addr[i] & ~lenmask))) begin
          // type match: execute wants R/W=00; data-write wants R/W=01 or 11.
          if (want_x) begin
            if (rw[i] == 2'b00) hit[i] = 1'b1;
          end else begin
            if (rw[i] == 2'b01 || rw[i] == 2'b11) hit[i] = 1'b1;
          end
        end
      end
      return hit;
    end
  endfunction

  // REVIEW2 C-08: SMI acceptance is a TRANSACTION START, not just a state change.
  // The slow boundary (core_fetch_decode.svh:154-158) clears the request, captures
  // smm_resume_eip, resets smm_step and enters S_SMI_SAVE. The fast boundary added
  // with task #57 did only the first and last of those, so the save map got the
  // RESET value of smm_resume_eip (zero) on the first fast-path SMI, and a stale
  // resume EIP / sequencer position on later ones -- RSM then resumed the wrong
  // instruction. Factored into one task so the two boundaries cannot diverge again;
  // this is the same discipline as fp_sys_bail / fp_irq_divert.
  // REVIEW2 C-10 (EFLAGS half): IRET must apply CPL/IOPL-aware masking to the popped
  // image. The 32-bit path did `eflags <= mem_rdata` -- RAW -- so a same-privilege CPL3
  // IRET could set its own IOPL and IF. Combined with the (now fixed) absence of CPL
  // checks on privileged instructions, that was a complete privilege escape: raise
  // IOPL via IRET, then do port I/O and CLI/STI freely.
  //
  // IA-32 rules, applied here:
  //   IOPL (13:12) changes ONLY at CPL 0.
  //   IF   (9)     changes ONLY when CPL <= IOPL.
  //   VM   (17)    changes ONLY at CPL 0 -- and it MUST remain changeable there,
  //                because that is how a 32-bit IRET enters V86 mode (the pv86 path
  //                keys on the popped bit 17).
  //   Reserved bits are forced: bit 1 reads 1; bits 3/5/15 and 22+ read 0. The mask
  //   0x003F_7FD5 is the same one the trace comparator uses as its EFLAGS base.
  function automatic logic [31:0] iret_flags(input logic [31:0] popped,
                                             input logic [31:0] cur);
    logic [31:0] r;
    begin
      r = popped;
      if (cpl_r != 2'd0) begin
        r[13:12] = cur[13:12];   // IOPL preserved below CPL0
        r[17]    = cur[17];      // VM preserved below CPL0
      end
      if (cpl_r > iopl) r[9] = cur[9];   // IF preserved when CPL > IOPL
      iret_flags = (r & 32'h003F_7FD5) | 32'h0000_0002;
    end
  endfunction

  task automatic smi_enter(input logic [31:0] resume_pc);
    begin
      smi_pending    <= 1'b0;
      smm_resume_eip <= resume_pc;   // this instruction restarts after RSM
      smm_step       <= 6'd0;        // start the save sequencer from the top
      state          <= S_SMI_SAVE;
    end
  endtask

  // ---- REVIEW_aug2 H-05: NMI re-arms at IRET COMMIT, not at IRET decode --------
  // The re-arm used to happen in S_DECODE the moment an IRET was recognised, before
  // any of its stack reads, before descriptor validation, before commit. An IRET that
  // FAULTED had therefore already re-armed NMI, so a second NMI could be accepted
  // while the first NMI's frame was still live -- the exact corruption nmi_nest was
  // added to prevent, reachable through a different door.
  //
  // The blocker recorded at the old site was "this needs validate-the-whole-frame-
  // then-commit"; that landed with C-07, so the re-arm now moves to the commit sites.
  // ONE definition of the rule, called from each of the four places an IRET can
  // actually retire (real-mode, same-privilege, inter-privilege, V86-return). A
  // faulting IRET reaches none of them and so re-arms nothing; when the handler
  // returns and the IRET restarts, decode runs again and it gets another chance.
  task automatic iret_retire_nmi();
    if (nmi_nest != 4'd0) nmi_nest <= nmi_nest - 4'd1;
    else                  nmi_in_progress <= 1'b0;
  endtask

  // REVIEW_aug2 H-04: escalate a fault taken DURING a delivery. Split out of
  // start_fault so the decision is written once and start_fault stays a single
  // straight-line commit. Returns the vector to actually deliver.
  //   esc_df  : this pair must become #DF (vector 8, error code 0)
  //   esc_shut: a fault arrived while #DF itself was being delivered -> shutdown
  logic esc_shut;
  assign esc_shut = (dlv_depth == 2'd2);
  function automatic logic esc_to_df(input logic [7:0] v);
    esc_to_df = (dlv_depth == 2'd1)
             && ( (dlv_ctrb && vec_contributory(v))
               || (dlv_pf   && (vec_contributory(v) || v == 8'd14)) );
  endfunction

  task automatic start_fault(input logic [7:0] vec, input logic has_err,
                             input logic [31:0] err, input logic [31:0] fault_pc);
    begin
`ifndef SYNTHESIS
      if (ven_faultlog_en)
        $display("[FAULT] vec=%0d err=%08h pc=%08h state=%0d v86=%0b depth=%0d",
                 vec, err, fault_pc, int'(state), v86, dlv_depth);
`endif
      // ===================================================================
      // REVIEW2_aug2 H-08: ABORT an in-flight NT task RETURN. ntret_pend is set at the
      // IRET and consumed in S_LJMP's second descriptor beat; a fault BEFORE that beat
      // (a #PF on the back-link read or on the descriptor read itself) would otherwise
      // leave it set, and the next far JMP to a busy TSS would be accepted as if it
      // were a task return -- exactly the re-entry H-04 exists to prevent. Same shape,
      // and the same reason, as the split-transfer aborts below.
      ntret_pend <= 1'b0;
      // REVIEW_Aug3 C-04: and an in-flight CALL task switch, for the same reason --
      // a fault before S_TSW_BUSY must not leave the next switch writing a
      // back-link and setting NT as if it nested.
      tsw_call   <= 1'b0;
      // Same class: a far-CALL probe (lcall_pend) or a call-gate re-vector
      // (gate_via) is per-instruction arming. A fault aborts the instruction, so
      // neither may survive into the handler to reshape its first far transfer.
      lcall_pend <= 1'b0;
      lc_gate    <= 1'b0;   // R2-H05: the staged gate width dies with the call
      gate_via   <= 1'b0;
      // REVIEW_Aug3 H-02: and a staged same-privilege RETF -- a rejected target
      // (selector fault, or the #PF on the descriptor read) must not leave the
      // deferred ESP advance armed to fire inside the handler.
      retf_same  <= 1'b0;
      // REVIEW2_aug2 C-06: and an in-flight outer RETF, for the same reason -- a #PF
      // on the ESP/SS pop or on either descriptor read must not leave the sequence
      // armed across the handler, where the next RETF would consume its staged frame.
      retf_out   <= 1'b0;
      retf_ob    <= 1'b0;
      // C-06 (call-gate half): likewise. A #TS/#SS/#PF anywhere in the TSS read, the
      // SS load or the frame push must not leave the call-gate shape latched onto the
      // NEXT interrupt delivery, which would push it a frame with no EFLAGS word.
      cg_xpl     <= 1'b0;
      cg_beat    <= 6'd0;   // R2-H05: and the param-frame beat counter with it
      // REVIEW_aug2 C-02: ABORT any in-flight split memory microsequence.
      // ===================================================================
      // xp_pend (split LOAD) and xs_act/xs_ph (split STORE) were cleared only at reset
      // and on successful completion. A second-page fault therefore left the transfer
      // ARMED while exception delivery and the whole handler ran:
      //   * the handler's next S_LOAD was redirected to the stale second page and
      //     merged with a stale xp_lo;
      //   * the handler's next S_STORE inherited a stale phase and xs_first;
      //   * and on IRET-restart, page 1 was never re-read, so the restarted access
      //     could consume pre-fault data even after the handler repaired the mapping.
      // That is precisely the fault case the split exists to support.
      //
      // Placed HERE, in start_fault, for the same reason the H-09 NMI count is: every
      // exception and interrupt delivery funnels through this task, so a divert path
      // cannot be missed the way hand-copied guards were (that mistake produced #58).
      xp_pend <= 1'b0;
      xs_act  <= 1'b0;
      xs_ph   <= 2'd0;
      // REVIEW1_Aug3 R2-C03: and the generic fragment engine -- a fault mid-sequence
      // aborts it (the FSM delivery arms take over the bus). The request register
      // keeps the engine's registers single-owned (the engine block clears them
      // next edge; the output-stage kill covers this cycle).
      fx_abort_q <= 1'b1;
      // A fault anywhere in a cross-privilege delivery (probe pages, call-gate
      // param reads, the pushes themselves) abandons that delivery: the frame
      // page plan is stale from here on, so a later same-priv push must never
      // match a captured page. The restart re-stages and re-probes.
      frm_pg_val   <= 4'd0;
      frm_pg_markd <= 1'b0;
      // H-09: a delivery that happens while an NMI handler is running stacks a frame
      // inside it. Doing this in start_fault (rather than at each divert site) is
      // deliberate -- every exception and interrupt delivery funnels through here, so
      // the count cannot miss a path the way the hand-copied guards did. vec==2 while
      // nmi_in_progress cannot occur (NMI is blocked), so no self-count.
      if (nmi_in_progress && (nmi_nest != 4'hF)) nmi_nest <= nmi_nest + 4'd1;
`ifndef SYNTHESIS
      // REVIEW_aug2 H-05: see the ven_nmi_arm block above. Counted here, in the one
      // task every delivery funnels through, for the same reason the H-09 count is.
      if (nmi_in_progress &&
          (state == S_IRET || state == S_INT_CS_RET || state == S_IRET_SS ||
           state == S_RMIRET))
        ven_h05_armed_faults <= ven_h05_armed_faults + 1;
`endif
      int_vec     <= vec;
`ifdef VEN_DBG_CORE
      // F4A: capture EVERY hardware fault (vec/eip/cs/err) — the abort's true vector
      // (CWSDPMI may mislabel it "Division by Zero"). The LAST one before the abort.
      $display("tb: FLT vec=%0d fault_pc=%08x cs=%04x err=%08x cr2=%08x cr3=%08x ds_base=%08x ibuf=%016x",
               vec, fault_pc, seg_sel[SG_CS], err, creg2, creg3, seg_base[SG_DS], dbg_ibuf);
      // fault-freeze: count every exception delivery so the PS can freeze the clock on
      // the Nth fault (= the drift's, skipping boot faults) BEFORE the triple-fault rst_n
      // wipes the trail. Fault eip/vec come from the existing dbg_fault_pc / dbg_int_vec
      // + the PC ring at the freeze — no extra capture latches (they bloated routing).
      dbg_fault_cnt_q  <= dbg_fault_cnt_q + 8'd1;
`endif
      int_ret_eip <= fault_pc;     // FAULT: push the faulting EIP (restart)
      int_src_pc  <= fault_pc;
      int_has_err <= has_err;
      int_err     <= err;
      // ---- REVIEW_aug2 H-04: escalation. Placed HERE, after the ordinary vector and
      // error code are assigned, so this is the LAST word on them (a later nonblocking
      // assignment in the same block wins). dlv_* is updated to describe what is being
      // delivered FROM NOW, so a further fault during THIS delivery sees the new depth.
      if (esc_to_df(vec)) begin
        int_vec     <= 8'd8;      // #DF
        int_has_err <= 1'b1;      // #DF always pushes an error code, and it is ZERO
        int_err     <= 32'd0;
        dlv_depth   <= 2'd2;
        dlv_ctrb    <= 1'b0;      // #DF is neither contributory nor a page fault;
        dlv_pf      <= 1'b0;      // at depth 2 the next fault shuts down regardless.
      end else begin
        dlv_depth   <= 2'd1;
        // REVIEW1_Aug2 C-08 (found while checking the review's first claim against
        // QEMU's check_exception): the recorded CLASS must only be replaced when the
        // new exception is itself contributory or a page fault. QEMU:
        //     if (second_contributory || intno == EXCP0E_PAGE || intno == EXCP08_DBLE)
        //         env->old_exception = intno;
        // A BENIGN fault taken during the delivery of a contributory one does not
        // become the new context -- the contributory one is still what a subsequent
        // fault must be paired against. Overwriting it here LOST that, so
        //     #GP -> (benign) -> #GP
        // failed to escalate when the second #GP arrived. Keep the class unless the
        // new vector supplies one.
        if (vec_contributory(vec) || (vec == 8'd14)) begin
          dlv_ctrb  <= vec_contributory(vec);
          dlv_pf    <= (vec == 8'd14);
        end
      end
      int_step    <= 4'd0;
      rm_read_armed <= 1'b0;
      int_sw      <= 1'b0;        // HW fault: bypass the gate DPL>=CPL check
      dlv_ext     <= 1'b0;        // synchronous class: EXT=0 (no inheritance)
      // F3: in PURE real mode (PE=0) a hardware interrupt / exception delivers through
      // the 4-byte IVT (S_RMINT_RD), exactly like a software INT n — NOT the 8-byte
      // protected-mode gate. Without this, the first IRQ after SeaBIOS sets IF=1 (or any
      // real-mode fault) walked a garbage "IDT", #NP'd, and hung. The IVT push carries no
      // error code (real-mode semantics; S_RMINT_PUSH drops int_err). V86 + PM keep the
      // S_INT_GATE path (real_mode==0 there).
      // REVIEW2 H-03: IDT LIMIT check. The gate read never consulted idt_limit, so a
      // vector past the table end fetched 8 bytes of whatever follows the IDT and
      // interpreted them as a gate. IA-32: vector*8+7 must be <= IDT limit, else
      // #GP(vec*8+2). Protected mode only -- real mode uses the fixed 1 KiB IVT.
      // This closes the 'out-of-limit gate is fetched and interpreted' half; the
      // escalation-to-#DF chain is still a single re-vector (see S_INT_GATE) and is
      // tracked in #66.
      // REVIEW1_Aug2 C-08: the IDT-limit re-vector generates a #GP, and that #GP is a
      // second exception in its own right -- it has to be paired with what was already
      // being delivered exactly like any other. Previously it overwrote int_vec with 13
      // AFTER the escalation decision above, so it could not become a #DF, it left
      // dlv_ctrb describing the ORIGINAL vector rather than the generated #GP, and it
      // never asked whether IDT[13] is itself inside the limit -- which would fetch the
      // replacement gate from outside the table.
      if (!real_mode && ({19'd0, vec, 3'd7} > {17'd0, idt_limit})) begin
        if (esc_shut || esc_to_df(8'd13)) begin
          // the generated #GP pairs into a #DF (or a triple fault) -- the shutdown
          // override at the end of this task still has the final say on `state`.
          int_vec     <= 8'd8;
          int_err     <= 32'd0;
          int_has_err <= 1'b1;
          dlv_depth   <= 2'd2;
          dlv_ctrb    <= 1'b0;
          dlv_pf      <= 1'b0;
          // ...and if the #DF gate is ALSO out of limit there is nothing left to
          // deliver: that is a triple fault.
          state       <= ({19'd0, 8'd8, 3'd7} > {17'd0, idt_limit})
                       ? S_SHUTDOWN : S_INT_GATE;
        end else begin
          int_vec     <= 8'd13;
          int_err     <= {21'd0, vec, 3'b010};
          int_has_err <= 1'b1;
          dlv_depth   <= 2'd1;
          dlv_ctrb    <= 1'b1;      // #GP is contributory -- describe what we DELIVER
          dlv_pf      <= 1'b0;
          // A #GP whose own gate is out of limit cannot be delivered either.
          state       <= ({19'd0, 8'd13, 3'd7} > {17'd0, idt_limit})
                       ? S_SHUTDOWN : S_INT_GATE;
        end
      end else
      state       <= real_mode ? S_RMINT_RD : S_INT_GATE;
      // ---- REVIEW_aug2 H-04: SHUTDOWN. A fault arriving while #DF is being
      // delivered is a triple fault; the CPU stops. Last assignment to `state` in
      // this block, so it overrides every delivery target chosen above -- including
      // the IDT-limit re-vector. Parks with no retire, which is what the loud HALT
      // already means to the TB, so the machine STOPS instead of looping the way the
      // measured #UD -> #NP -> #NP -> ... cascade did.
      if (esc_shut) state <= S_SHUTDOWN;
    end
  endtask

  // ---- M2S.6 #DB delivery launched FROM a retire boundary (gated sys_mode at
  // the call sites). Unlike start_fault, the triggering instruction does NOT emit
  // its own retire record: the qemu gdbstub single-step fuses the instruction +
  // the synchronous #DB into ONE record stamped with the instruction's PC and the
  // post-delivery state. So the caller does NOT set retire_valid for the insn; it
  // calls this INSTEAD, which sets DR6.Bn/BS (sticky) and diverts to S_INT_GATE.
  // The delivery's single retire is then stamped with `src_pc` (the instruction
  // that triggered the trap/fault) and pushes `ret_eip` (NEXT eip for a TRAP =
  // resume; the FAULTING/breakpoint eip for a FAULT = restart). #DB: vector 1, no
  // error code, delivered through IDT[1].
  task automatic arm_db(input logic [31:0] dr6_bits,
                        input logic [31:0] src_pc, input logic [31:0] ret_eip);
    begin
      dr6         <= dr6 | dr6_bits;     // sticky status bits
      int_vec     <= 8'd1;
      int_ret_eip <= ret_eip;
      int_src_pc  <= src_pc;
      int_has_err <= 1'b0;
      int_err     <= 32'd0;
      int_step    <= 4'd0;
      rm_read_armed <= 1'b0;
      int_sw      <= 1'b0;               // hardware #DB: bypass the gate DPL check
      dlv_ext     <= 1'b0;               // a trap/fault class event: EXT=0
      // F3: real-mode #DB also delivers through the IVT (see start_fault).
      state       <= real_mode ? S_RMINT_RD : S_INT_GATE;
    end
  endtask

  // Is the current bus access a DATA access (D-TLB) vs an instruction fetch
  // (I-TLB)? Fetch states are S_FETCH / S_PF / the S_PIPE icache fill; the
  // descriptor table reads (S_LGDT/S_SEGLD/S_LJMP) always run with paging OFF
  // (the GDT is loaded before CR0.PG), so they pass through untranslated.
  logic cur_is_d;
  always_comb begin
    unique case (state)
      S_FETCH, S_PF: cur_is_d = 1'b0;
      // S_PIPE issues BOTH an icache fill (pf_miss -> I-TLB, a fetch) AND a
      // checked DS effective-address DATA load (pipe_load_req -> D-TLB). They are mutually
      // exclusive (pf_miss => !pipe_bytes_ok => !pipe_load_req), so classify by
      // which is active: a data load is D-side (Phase-3 [med] fix — previously
      // hardcoded I-TLB, which polluted the I-TLB with data and applied the wrong
      // permission set, defeating the split I/D model and mis-targeting the M2S.3
      // permission check). The fill (or neither) is I-side.
      S_PIPE:        cur_is_d = pipe_load_req || pipe_store_req;
      default:       cur_is_d = 1'b1;
    endcase
  end

  // M2S.4 — byte offset into the 32-bit TSS of the privilege-N stack pointer pair
  // (ESPn then SSn). 32-bit TSS layout: ESP0@0x04, SS0@0x08, ESP1@0x0C, SS1@0x10,
  // ESP2@0x14, SS2@0x18 -> ESPn @ 0x04 + 8*N (SSn is the next word). N=int_new_cpl.
  logic [31:0] tss_stk_off;
  assign tss_stk_off = 32'h0000_0004 + ({30'd0, int_new_cpl} << 3);

  // M2S.5 — the SMRAM save-map offset for save/restore beat `s` (P5 Table 20-1;
  // segment HIDDEN state + table limits go to the RTL-internal HID reserved
  // block). Used by BOTH S_SMI_SAVE (write) and S_RSM (read) so the two walk the
  // same addresses in lockstep. (NUM_SEG==6.)
  function automatic logic [15:0] smm_off(input logic [5:0] s);
    unique case (s)
      6'd0:  smm_off = SMO_CR0;
      6'd1:  smm_off = SMO_CR3;
      6'd2:  smm_off = 16'h7E04;          // CR4 (hidden/reserved per Table 20-1)
      6'd3:  smm_off = 16'h7E08;          // CR2 (hidden/reserved per Table 20-1)
      6'd4:  smm_off = SMO_EFLAGS;
      6'd5:  smm_off = SMO_EIP;
      6'd6:  smm_off = SMO_EAX;
      6'd7:  smm_off = SMO_ECX;
      6'd8:  smm_off = SMO_EDX;
      6'd9:  smm_off = SMO_EBX;
      6'd10: smm_off = SMO_ESP;
      6'd11: smm_off = SMO_EBP;
      6'd12: smm_off = SMO_ESI;
      6'd13: smm_off = SMO_EDI;
      6'd14: smm_off = SMO_CS;
      6'd15: smm_off = SMO_SS;
      6'd16: smm_off = SMO_DS;
      6'd17: smm_off = SMO_ES;
      6'd18: smm_off = SMO_FS;
      6'd19: smm_off = SMO_GS;
      // seg base/limit/attr into the HID reserved block (6 each):
      6'd20,6'd21,6'd22,6'd23,6'd24,6'd25:
             smm_off = SMO_HID + ({10'd0,(s - 6'd20)} << 2);              // base
      6'd26,6'd27,6'd28,6'd29,6'd30,6'd31:
             smm_off = SMO_HID + 16'h0018 + ({10'd0,(s - 6'd26)} << 2);   // limit
      6'd32,6'd33,6'd34,6'd35,6'd36,6'd37:
             smm_off = SMO_HID + 16'h0030 + ({10'd0,(s - 6'd32)} << 2);   // attr
      6'd38: smm_off = SMO_GDTB;
      6'd39: smm_off = SMO_IDTB;
      6'd40: smm_off = SMO_HID + 16'h0048;   // {gdt_limit, idt_limit}
      6'd41: smm_off = SMO_SMBASE;
      6'd42: smm_off = SMO_REVID;
      6'd43: smm_off = SMO_AHALT;
      // REVIEW2 M-02: DR6/DR7/TR/LDTR in their ARCHITECTURAL P5 slots ...
      6'd44: smm_off = SMO_DR6;
      6'd45: smm_off = SMO_DR7;
      6'd46: smm_off = SMO_TR;
      6'd47: smm_off = SMO_LDTR;
      // ... and the HIDDEN TR/LDTR descriptor cache in the implementation-private
      // reserved block, exactly as the 6 segments' hidden state already is. The
      // architectural map has no slots for these (real P5 reloads them from the GDT),
      // but this core keeps hidden state explicitly, so RSM must restore it bit-exactly
      // or the resumed context runs with the SMM handler's task/LDT descriptors.
      6'd48: smm_off = SMO_HID + 16'h0050;   // TR base
      6'd49: smm_off = SMO_HID + 16'h0054;   // TR limit
      6'd50: smm_off = SMO_HID + 16'h0058;   // LDT base
      6'd51: smm_off = SMO_HID + 16'h005C;   // {ldt_limit, tr_valid, tr_attr}
      default: smm_off = SMO_HID + 16'h004C; // {cs_d, cpl}  (beat 52 = SMM_LAST)
    endcase
  endfunction

  // The value to WRITE on save beat `s` (the interrupted-context state).
  function automatic logic [31:0] smm_save_data(input logic [5:0] s);
    unique case (s)
      6'd0:  smm_save_data = creg0;
      6'd1:  smm_save_data = creg3;
      6'd2:  smm_save_data = creg4;
      6'd3:  smm_save_data = creg2;
      6'd4:  smm_save_data = eflags;
      6'd5:  smm_save_data = smm_resume_eip;        // resume EIP (writeable slot)
      6'd6,6'd7,6'd8,6'd9,6'd10,6'd11,6'd12,6'd13:
             smm_save_data = gpr_o[3'(s - 6'd6)];
      6'd14,6'd15,6'd16,6'd17,6'd18,6'd19:
             smm_save_data = {16'd0, seg_sel[3'(s - 6'd14)]};
      6'd20,6'd21,6'd22,6'd23,6'd24,6'd25:
             smm_save_data = seg_base [3'(s - 6'd20)];
      6'd26,6'd27,6'd28,6'd29,6'd30,6'd31:
             smm_save_data = seg_limit[3'(s - 6'd26)];
      6'd32,6'd33,6'd34,6'd35,6'd36,6'd37:
             smm_save_data = {24'd0, seg_attr[3'(s - 6'd32)]};
      6'd38: smm_save_data = gdt_base;
      6'd39: smm_save_data = idt_base;
      6'd40: smm_save_data = {idt_limit, gdt_limit};
      6'd41: smm_save_data = smbase;                // SMBASE relocation slot
      6'd42: smm_save_data = SMM_REV_ID;            // SMM revision id (RO)
      6'd43: smm_save_data = 32'd0;                 // auto-HALT slot (no HALT here)
      // ---- REVIEW2 M-02: debug + task state ----
      6'd44: smm_save_data = dr6;
      6'd45: smm_save_data = dr7;
      6'd46: smm_save_data = {16'd0, tr_sel};
      6'd47: smm_save_data = {16'd0, ldt_sel};
      6'd48: smm_save_data = tr_base;
      6'd49: smm_save_data = tr_limit;
      6'd50: smm_save_data = ldt_base;
      6'd51: smm_save_data = {ldt_limit, 7'd0, tr_valid, tr_attr};
      default: smm_save_data = {29'd0, cpl_r, cs_d};// {cpl, cs_d}  (beat 52)
    endcase
  endfunction

  // ---- the LINEAR address of the current state's access (pre-translation) and
  // whether the access is a write. Mirrors the per-state mem_addr computation in
  // the bus driver, but in LINEAR space so the page walk + #PF decision use the
  // architectural linear address. Only meaningful for the translatable states.
  logic [31:0] cur_lin;
  // REVIEW1_Aug3 R2-C03: the NATURAL per-state linear address, before the
  // fragment engine's page-2 redirect. The engine's crossing detection and
  // CHECK 5 read this (testing the redirected cur_lin would be a comb loop).
  logic [31:0] cur_lin_nat;
  logic        cur_is_w;
  logic        cur_is_w_nat;   // R2-C03: per-state write flag, before the engine forces it
  always_comb begin
    // Case-arm scratch (hoisted to block scope with defaults: a local declared
    // inside a case arm is unassigned on every path that does not enter the
    // arm, which Verilator's latch analysis reports even though the value is
    // only read inside the arm).
    logic [31:0] enter_koff, enter_joff;
    logic [15:0] segld_ssel;
    cur_lin_nat  = 32'd0;
    cur_is_w_nat = 1'b0;
    enter_koff = 32'd0; enter_joff = 32'd0; segld_ssel = 16'd0;
    // C-03: most beats are a full dword. The arms below narrow it where the state
    // genuinely moves fewer bytes; anything left at 4 is the conservative reading.
    cur_size = 4'd4;
    seg_ext_ovr   = 8'd0;   // H-05: no override -> the check follows cur_size
    seg_ext_ovr_v = 1'b0;
    seg_ext_skip  = 1'b0;
`ifndef SYNTHESIS
    ven_h06_hit = 1'b0;
`endif
    unique case (state)
      S_FETCH: cur_lin_nat = flin + {27'd0,fetch_word,2'b00};
      S_PF:    cur_lin_nat = {pf_fill_addr[31:5],5'd0} + {27'd0,pf_word,2'b00};
      S_PIPE: begin
        cur_lin_nat = pf_miss ? {pf_miss_fa[31:5],5'd0}
                               : (seg_base[pipe_mem_seg]+pipe_load_addr);
        cur_is_w_nat = pipe_store_req;
      end
      // REVIEW_aug2 C-05: this must mirror core_bus_driver.svh's S_LOAD arm EXACTLY.
      // Two rows of the review's mismatch table were here:
      //   * stack loads used RAW ESP/EBP while the bus applies stk16() -- so with a
      //     16-bit stack (SS.B=0) the TLB looked up a different page than the bus drove;
      //   * XLAT had no case at all and fell through to opbase+q_ea, so a paged XLATB
      //     translated an unrelated page while the bus addressed DS+(E)BX+AL.
      S_LOAD: begin cur_size = {1'b0, load_beat_w};
        if (q_is_pop || q_ct==CT_RETN || q_ct==CT_RETN_IMM ||
            (q_kind==K_STKMISC && q_sm==SM_POPF))      cur_lin_nat = dbase+stk16(gpr_o[R_ESP]);
        else if (q_kind==K_STKMISC && q_sm==SM_LEAVE)  cur_lin_nat = dbase+stk16(gpr_o[R_EBP]);
        else if (q_kind==K_STR)
          cur_lin_nat = (q_st==ST_SCAS) ? dbase+str_edi : dbase+str_esi;
        else if (q_xlat)
          cur_lin_nat = dbase
                  + (q_cnt16 ? {16'd0, gpr_o[R_EBX][15:0]} : gpr_o[R_EBX])
                  + {24'd0, gpr_o[R_EAX][7:0]};
        else                                           cur_lin_nat = opbase+q_ea;  // M7.1 opbase
        // REVIEW2 C-02: on the SECOND beat of a split access the TLB must look up the
        // SECOND page, not the first. Mirrors the bus driver's S_LOAD arm exactly --
        // if these two ever disagree the C-03 assertion (CHECK 5) fires, which is
        // precisely the drift this pair has suffered before.
        if (xp_pend) cur_lin_nat = {cur_lin_nat[31:12] + 20'd1, 12'd0};
      end
      // The paging lookup MUST translate the SAME linear the bus driver accesses in
      // S_LOAD2 (core_bus_driver.svh:50-56). Previously this only handled the CMPS
      // [EDI] 2nd operand, so under paging the far-ptr seg-load (LSS/LFS/LGS), BOUND/
      // CMPXCHG8B, and far JMP/CALL indirect (m16:32) 2nd read had cur_lin_nat = a STALE
      // dbase_edi+str_edi -> dtlb lookup translated the wrong page -> wrong physical
      // (DOS-Quake go32 `lss esp,cs:[..]`: 2nd read read 0 -> null SS -> #GP). Mirror
      // the four bus-driver arms EXACTLY. Inert without paging (mem_xlate==lin).
      S_LOAD2: begin
        cur_size = {1'b0, load_beat_w};
        if (q_kind==K_BOUND || q_kind==K_CX8B) cur_lin_nat = dbase+q_ea+{28'd0,q_w};
        else if (q_seg_load)                   cur_lin_nat = dbase+q_ea+{28'd0,q_w};
        else if (q_jmpf_mem || q_callf_mem)    cur_lin_nat = opbase+q_ea+{28'd0,q_w};
        else                                   cur_lin_nat = dbase_edi+str_edi;
        // REVIEW1_Aug2 C-03: beat 2 of a page-crossing S_LOAD2 re-issues at the SECOND
        // page's base, exactly as S_LOAD does. Mirrors core_bus_driver.svh.
        if (xp_pend) cur_lin_nat = {cur_lin_nat[31:12] + 20'd1, 12'd0};
      end
      // nested ENTER: mirror the bus driver S_ENTER address so paging translates the same
      // linear (inert in real mode where the case is exercised; correct under paging).
      S_ENTER: begin
        enter_koff = {26'd0, ent_k} * {29'd0, q_w};
        enter_joff = ({26'd0, ent_k} - 32'd1) * {29'd0, q_w};
        if (ent_rd) cur_lin_nat = seg_base[SG_SS] + stk16(gpr_o[R_EBP] - enter_joff);
        else begin  cur_lin_nat = seg_base[SG_SS] + stk16(gpr_o[R_ESP] - enter_koff); cur_is_w_nat = 1'b1; end
      end
      // ---- REVIEW2 C-04: descriptor / TSS structures are LINEAR, so translate them.
      // These states read GDT/LDT descriptors, the TSS, and (for a task switch) write
      // the outgoing TSS -- all architecturally LINEAR addresses. They were excluded
      // from translation under an identity-map assumption, so with a non-identity
      // mapping a descriptor load, privilege-stack lookup, TSS save/load or busy-bit
      // write hit the WRONG PHYSICAL MEMORY and could not page fault. A task switch
      // could corrupt arbitrary physical memory while loading a different task image
      // than the descriptor named.
      //
      // Each cur_lin below mirrors its bus-driver arm EXACTLY. That is more mirroring,
      // which is the very thing C-03 is about -- but the C-03 assertion now compares
      // cur_lin against the pre-translate bus address for every translatable request,
      // so a mismatch fails loudly on the first access instead of silently reading the
      // wrong memory. Deleting the mirror outright is #65.
      S_SEGLD: begin
        segld_ssel = q_seg_from_mem ? seg_mem_sel : gpr_o[q_src_reg][15:0];
        cur_lin_nat = (segld_ssel[2] ? ldt_base : gdt_base) + {16'd0, segld_ssel[15:3], 3'd0}
                + {29'd0, seg_step, 2'b00};
      end
      S_LJMP: cur_lin_nat = (q_ljmp_sel[2] ? ldt_base : gdt_base)
                      + {16'd0, q_ljmp_sel[15:3], 3'd0} + {29'd0, seg_step, 2'b00};

      // REVIEW2 C-03: S_LCALL and S_RETF have LIVE bus accesses (core_bus_driver.svh
      // :101-117) but had NO cur_lin case, so under paging the TLB looked up whatever
      // the default produced while the bus used SS:ESP -- a miss walked the wrong
      // page, and a coincidental hit post-translated the WRONG linear. Mirrored here
      // EXACTLY, stk16() included; the assertion at the end of this file now proves
      // the two agree for every translatable state instead of trusting this comment.
      S_LCALL: begin
        cur_is_w_nat = 1'b1;
        // R2-H05: lc_callw (gate width for a gated call) mirrors the bus arm.
        cur_lin_nat = !seg_step ? seg_base[SG_SS] + stk16(gpr_o[R_ESP] - {28'd0,lc_callw})
                             : seg_base[SG_SS] + stk16(gpr_o[R_ESP] - {27'd0,lc_callw,1'b0});
      end
      // REVIEW_Aug3 C-02: the OUTER-level return beats were missing here. The bus arm
      // keeps popping ESP at +2w and SS at +3w off the ORIGINAL inner ESP when
      // retf_out is set (retf_ob 0=ESP, 1=SS); this mirror had only the two-beat
      // inner form, so under paging beats 2 and 3 translated the wrong linear.
      S_RETF: begin
        // R2-H05 follow-up (B1): the outer slots sit above the imm16 discard --
        // mirrors the bus arm EXACTLY (CHECK 5).
        if (retf_out) cur_lin_nat = seg_base[SG_SS] + stk16(gpr_o[R_ESP] + {16'd0,q_ret_imm} +
                                (retf_ob ? ({27'd0,q_w,1'b0} + {28'd0,q_w})   // 3w: SS
                                         :  {27'd0,q_w,1'b0}));               // 2w: ESP
        else          cur_lin_nat = !seg_step ? seg_base[SG_SS] + stk16(gpr_o[R_ESP])
                                          : seg_base[SG_SS] + stk16(gpr_o[R_ESP]+{28'd0,q_w});
      end
      // REVIEW_aug2 C-05 (state selection): LGDT/LIDT and SGDT/SIDT take an ORDINARY
      // linear memory operand, but neither had a cur_lin case.
      //   * S_LGDT was additionally EXCLUDED from the post-translate stage, so under
      //     paging it read the pseudo-descriptor from a PHYSICAL address.
      //   * S_SGDT was excluded from nothing, so it reached mem_xlate() with the
      //     DEFAULT cur_lin of 0 -- the D-TLB lookup for linear page ZERO. If page 0
      //     happened to be resident the pseudo-descriptor was WRITTEN through page
      //     zero's translation; if not, the operand silently bypassed paging.
      // Both now mirror their bus-driver arms and are translatable.
      S_LGDT:  cur_lin_nat = dbase + q_ea + {29'd0, seg_step, 2'b00};
      S_SGDT: begin
        cur_is_w_nat = 1'b1;
        cur_lin_nat = dbase + q_ea + {29'd0, seg_step, 2'b00};
      end
      // C-03: the m80 third beat and the m16 forms move 2 bytes, not 4.
      S_FLOAD: begin cur_lin_nat = dbase+q_ea + {26'd0, f_step, 2'b00};
                     cur_size = ((q_f_mbytes==4'd10 && f_step==4'd2) ||
                                 (q_f_mbytes==4'd2)) ? 4'd2 : 4'd4;
                     // H-05: check the WHOLE m16/m32/m64/m80 at the first beat.
                     seg_ext_ovr   = {4'd0, q_f_mbytes};
                     seg_ext_ovr_v = 1'b1;
                     seg_ext_skip  = (f_step != 4'd0);
                     if (fp_store_probing) begin
                       cur_is_w_nat = 1'b1;
                       // The first phase validates the natural beat.  When it
                       // straddles 4 KiB, phase two validates the next page's
                       // base.  The whole destination extent was checked on
                       // phase one, so a one-byte page probe needs no second
                       // segment-limit check.
                       if (fp_store_probe_second) begin
                         cur_lin_nat = {cur_lin_nat[31:12] + 20'd1, 12'd0};
                         cur_size = 4'd1;
                         seg_ext_skip = 1'b1;
                       end
                     end
                   end
      S_FSTORE: begin cur_lin_nat = dbase+q_ea + {26'd0, f_step, 2'b00}; cur_is_w_nat = 1'b1;
                     cur_size = ((q_f_mbytes==4'd10 && f_step==4'd2) ||
                                 (q_f_mbytes==4'd2)) ? 4'd2 : 4'd4;
                     seg_ext_ovr   = {4'd0, q_f_mbytes};
                     seg_ext_ovr_v = 1'b1;
                     seg_ext_skip  = (f_step != 4'd0); end
      // REVIEW1_Aug2 M-04: fenv_off carries the stride (4-byte or 2-byte beats); it is
      // the SAME signal the bus arm uses, so the two cannot drift apart (CHECK 5).
      // REVIEW2_aug2 H-05: the ENVIRONMENT IMAGES get the whole-object extent too. I
      // recorded these as needing "a second mechanism rather than a reuse of
      // q_f_mbytes"; that was wrong. The total is (fenv_last+1) * stride and lands on
      // exactly the four architectural sizes -- 16-bit FNSTENV (6+1)*2 = 14, 32-bit
      // (6+1)*4 = 28, 16-bit FNSAVE (46+1)*2 = 94, 32-bit (26+1)*4 = 108 -- so it is
      // the SAME override, with the size computed instead of taken from a field. The
      // extent is 8 bits because 108 does not fit in 5.
      S_FENV_ST: begin cur_lin_nat = dbase+q_ea + fenv_off; cur_is_w_nat = 1'b1;
                       cur_size = (q_f_mbytes == 4'd2) ? 4'd2 : 4'd4;
                       seg_ext_ovr   = (q_f_mbytes == 4'd2)
                                     ? 8'((fenv_last + 6'd1) * 2)
                                     : 8'((fenv_last + 6'd1) * 4);
                       seg_ext_ovr_v = 1'b1;
                       seg_ext_skip  = (fenv_off != 32'd0); end
      S_FENV_LD: begin cur_lin_nat = dbase+q_ea + fenv_off;
                       cur_size = (q_f_mbytes == 4'd2) ? 4'd2 : 4'd4;
                       seg_ext_ovr   = (q_f_mbytes == 4'd2)
                                     ? 8'((fenv_last + 6'd1) * 2)
                                     : 8'((fenv_last + 6'd1) * 4);
                       seg_ext_ovr_v = 1'b1;
                       seg_ext_skip  = (fenv_off != 32'd0);
                       if (fp_store_probing) begin
                         cur_is_w_nat = 1'b1;
                         if (fp_store_probe_second) begin
                           cur_lin_nat = {cur_lin_nat[31:12] + 20'd1, 12'd0};
                           cur_size = 4'd1;
                           seg_ext_skip = 1'b1;
                         end
                       end
                     end
      S_STORE: begin cur_size = {1'b0, q_w};
        cur_is_w_nat = 1'b1;
        // F3/paging fix: POP r/m16 (8F) writes its operand in the operand's OWN
        // segment (DS default/override), NOT the SS that `dbase` forces for the
        // pop's stack READ. core_bus_driver.svh already uses `stbase` for the store
        // mem_addr; the page-walk linear here MUST match or (under paging) the store
        // walks SS:disp and writes the wrong page. This was the DOS-Quake #GP root:
        // go32's `pop ds; pop word [ds:0x4f6c]` (ds!=ss, paging on) stored the popped
        // value to SS_base+0x4f6c instead of DS_base+0x4f6c, corrupting the coroutine
        // fault-dispatch word. stbase==dbase for every non-pop store (byte-identical).
        cur_lin_nat = st_lin_nat;
        // REVIEW2 C-02 (store half): phases 0 (PROBE) and 2 (WRITE) address the SECOND
        // page. Mirrors core_bus_driver.svh's S_STORE arm exactly -- CHECK 5 enforces it.
        // Uses the EFFECTIVE phase so the FIRST clock is the probe (REVIEW_aug2 C-01).
        if (xs_eff_act && (xs_eff_ph != 2'd1)) cur_lin_nat = {cur_lin_nat[31:12] + 20'd1, 12'd0};
      end
      // REVIEW_aug2 C-05: three mismatches lived here. The bus driver is width-aware
      // (q_w: PUSHAW/POPAW are 2-byte spaced) and applies stk16(); this used a HARD 4
      // and no stk16(), so 16-bit PUSHA/POPA looked up the wrong page at most beats and
      // at SP wrap. CMPXCHG8B had no case at all and fell through to the STACK address
      // while the bus drives dbase+q_ea -- a successful paged CMPXCHG8B wrote through
      // the wrong translation. Mirrors core_bus_driver.svh's S_USEQ arm exactly.
      S_USEQ: begin cur_size = {1'b0, q_w};
        if (q_kind==K_CX8B) begin
          cur_is_w_nat = 1'b1;
          cur_lin_nat = dbase + q_ea + (step==4'd0 ? 32'd0 : {28'd0,q_w});
        end else if (q_sm==SM_PUSHA) begin
          cur_is_w_nat = 1'b1;
          cur_lin_nat = dbase + stk16(pusha_esp - (({28'd0,step}+32'd1)*{29'd0,q_w}));
        end else
          cur_lin_nat = dbase + stk16(gpr_o[R_ESP] + ({28'd0,step}*{29'd0,q_w}));
      end
      // M2S.3 IDT delivery linear addresses (mirror the bus driver arms).
      S_INT_GATE:   cur_lin_nat = idt_base + {21'd0, int_vec, 3'd0}
                              + {29'd0, int_step[0], 2'b00};
      // REVIEW_aug2 C-05: the bus honours the selector's TI bit (GDT vs LDT) for both
      // of these; cur_lin hard-coded the GDT, so an LDT-backed interrupt/IRET CS made
      // the TLB translate a different linear page than the bus addressed.
      S_INT_CS, S_INT_CS_RET:
                    cur_lin_nat = (int_gate_sel[2] ? ldt_base : gdt_base)
                            + {16'd0, int_gate_sel[15:3], 3'd0}
                              + {29'd0, int_step[0], 2'b00};
      S_INT_PUSH: begin
        cur_is_w_nat = 1'b1;
        // CROSS-PRIV: push descending from the NEW stack (TSS.espN). SAME-PRIV:
        // descending from the current SS:ESP. (mirror the bus driver arm.)
        //
        // REVIEW2_aug2 H-06: the SAME-PRIVILEGE 16-BIT GATE was missing here. The bus
        // arm pushes a 6-byte frame in 2-BYTE slots -- ESP-2, ESP-4, ESP-6, with a
        // low-half strobe (core_bus_driver.svh, the `int_gate_op16` branch) -- while
        // this mirror always subtracted 4 per entry and the extent defaulted to 4. So
        // for a 16-bit gate the TLB checked and translated one address while the bus
        // wrote another; near a page boundary those are DIFFERENT PAGES, and the frame
        // lands in the wrong one with page two's fault never raised.
        //
        // The three arms must agree exactly, which is what CHECK 5 (PAGING/C-03)
        // asserts -- it did not catch this because no corpus test takes a 16-bit gate
        // with paging on. Same shape as C-03's own finding: one address, one source.
        // REVIEW1_Aug3 R2-H05: the cross-privilege CALL-GATE frame is cg_beat-
        // counted, gate-width units (dword/word), wrapped per the NEW stack's
        // B bit (installed by the time S_INT_PUSH runs, so stk16 reads it).
        // Mirrors the cg_xpl sub-arm in core_bus_driver.svh EXACTLY (CHECK 5).
        if (xpl_active && cg_xpl) begin
          // the call-gate frame by the slot plan (gate-width units, wrapped per
          // the installed new stack's B -- S_INT_PROBE walked the same slots)
          cur_lin_nat = seg_base[SG_SS]
                      + frm_slot_off(int_new_esp, cg_beat, cg_wide, ss_b);
          cur_size = cg_wide ? 4'd4 : 4'd2;
        end else if (xpl_active && !cg_xpl && int_frm16) begin
          // REVIEW_Aug4 A4-H03: the CROSS-PRIV 16-BIT gate frame. Five/six WORD
          // slots (old SS, old SP, FLAGS, CS, IP [, err]) descending from the
          // TSS stack pointer, wrapped per the NEW stack's B bit (installed by
          // S_INT_SS by the time S_INT_PUSH runs) -- this used to share the
          // dword arm below, so a 16-bit interrupt/trap gate that changed
          // privilege built a 32-bit frame.
          cur_lin_nat = seg_base[SG_SS]
                      + frm_slot_off(int_new_esp, {2'd0, int_step}, 1'b0, ss_b);
          cur_size = 4'd2;
        end else if (!xpl_active && !from_v86 && int_gate_op16) begin
          // A4-H03: the SAME-PRIV 16-bit frame wraps the LOW SP on a 16-bit
          // stack (SS.B=0) -- stk16 was missing here, so the slots marched off
          // the 64K window instead of wrapping.
          cur_lin_nat = seg_base[SG_SS]
                     + stk16(gpr_o[R_ESP] - {27'd0, (int_step + 4'd1), 1'b0});
          cur_size = 4'd2;                       // low-half strobe: 2 bytes, not 4
`ifndef SYNTHESIS
          ven_h06_hit = 1'b1;                    // reachability probe (see below)
`endif
        end else begin
          // The cross-priv DWORD frame (incl. V86 entry) also wraps per the
          // installed stack's B bit -- the slot plan, shared with the probe.
          // (A 16-bit TSS stack for a 32-bit gate used to push unwrapped while
          // the ESP writeback wrapped, splitting the frame across the window.)
          cur_lin_nat = xpl_active
                    ? (seg_base[SG_SS] + frm_slot_off(int_new_esp, {2'd0, int_step}, 1'b1, ss_b))
                    : (seg_base[SG_SS] + gpr_o[R_ESP] - ({28'd0, int_step} * 32'd4) - 32'd4);
        end
      end
      // REVIEW_aug2 C-06: S_IRET_SS reads the popped SS DESCRIPTOR from the GDT/LDT,
      // not the stack. Mirrors core_bus_driver.svh exactly (CHECK 5 enforces it).
      S_IRET_SS:    cur_lin_nat = (iret_ss[2] ? ldt_base : gdt_base)
                            + {16'd0, iret_ss[15:3], 3'd0} + ({29'd0, int_step[0], 2'b00});
      S_IRET: begin
                cur_lin_nat = int_gate_op16
                            ? (seg_base[SG_SS] + stk16(gpr_o[R_ESP] + ({27'd0, int_step, 1'b0})))
                            : (seg_base[SG_SS] + gpr_o[R_ESP] + ({28'd0, int_step} * 32'd4));
                // The bus arm pops a dword and masks; the architectural slot of
                // a 16-bit IRETW is a WORD, so the segment extent check charges
                // 2 bytes (a topmost word ending at the bound is legal). The
                // override leaves cur_size -- and therefore the bus beat -- at
                // the dword the driver reads.
                seg_ext_ovr   = 8'd2;
                seg_ext_ovr_v = int_gate_op16;
              end
      // REVIEW2 C-04: S_LTR reads the GDT TSS descriptor; S_INT_TSS reads TSS.ssN:espN;
      // S_INT_SS reads the new SS descriptor. All three are architecturally LINEAR and
      // are now TRANSLATED -- the old comment here said they "address their (linear)
      // structure PHYSICALLY under the identity-map convention ... cur_lin here is
      // informational only", which is exactly the assumption C-04 is about.
      //
      // S_INT_SS also had a REAL BUG that the old "informational only" status hid: it
      // used gdt_base UNCONDITIONALLY while the bus driver honours the selector's TI
      // bit (core_bus_driver.svh:351). That is one of the mismatches REVIEW2 C-03
      // lists BY NAME. Harmless while the value was unused; a wrong-table page walk the
      // moment translation was switched on. Fixed here to match the bus driver.
      S_LTR:     cur_lin_nat = ltr_busy_q
                         ? (gdt_base + {16'd0, ltr_sel_q[15:3], 3'd0} + 32'd4)  // H-11b busy byte
                         : (gdt_base + {16'd0, gpr_o[q_src_reg][15:3], 3'd0}
                            + {29'd0, seg_step, 2'b00});
      // REVIEW1_Aug2 M-03: mirrors the S_IOPERM arm in core_bus_driver.svh verbatim.
      // ---- REVIEW1_Aug2 C-09 (paging half): the task-switch microsequence ---------
      // All five S_TSW_* states were excluded from the paging post-stage because they
      // had no cur_lin cases, so a paged non-identity task switch read and wrote the
      // WRONG PHYSICAL MEMORY and could not raise the page faults it must. GDT and TSS
      // bases are LINEAR architectural addresses, so these are ordinary translated
      // supervisor accesses -- and after C-04 they are correctly classified as
      // supervisor, because none of these arms sets cur_seg_rel.
      //
      // Each case mirrors its core_bus_driver.svh arm EXACTLY; CHECK 5 asserts the two
      // agree on every translatable request, which is the guard that makes adding a
      // mirror safe rather than the drift that produced the C-05 family.
      S_TSW_SAVE: begin cur_lin_nat = tr_base + {24'd0, tsw_save_off(tsw_step)};
                        cur_is_w_nat = 1'b1; end   // the outgoing image is a WRITE
      S_TSW_READ: cur_lin_nat = tsw_new_base + {24'd0, tsw_read_off(tsw_step)};
      S_TSW_LDT:  cur_lin_nat = gdt_base + {16'd0, tsw_new_ldt[15:3], 3'd0}
                          + {29'd0, tsw_step[0], 2'b00};
      // REVIEW_Aug3 C-02: this mirror used the LIVE outgoing ldt_base while the bus
      // arm resolves TI=1 selectors through the STAGED incoming tsw_st_ldt_base (the
      // incoming LDT is committed only in S_TSW_BUSY). A paged task switch whose
      // incoming and outgoing LDTs differ therefore translated the new task's
      // descriptor reads through the wrong table.
      S_TSW_SEG:  cur_lin_nat = (tsw_sel[3'(tsw_step[4:1])][2] ? tsw_st_ldt_base : gdt_base)
                          + {16'd0, tsw_sel[3'(tsw_step[4:1])][15:3], 3'd0}
                          + {29'd0, tsw_step[0], 2'b00};
      // REVIEW_Aug3 C-02: the busy-write ORDER was mirrored backwards. The bus arm
      // writes incoming-busy (tsw_new_sel) on beat 0 and outgoing-available (tr_sel)
      // on beat 1; this mirror had them swapped, so under paging the busy byte was
      // written to the OPPOSITE descriptor -- the outgoing task rewritten busy and
      // the incoming one left available.
      // REVIEW_Aug3 C-04: beat 1 of a CALL task switch is the BACK-LINK write into
      // the incoming TSS (offset 0), not the outgoing-descriptor clear.
      // The busy/backlink beats are WRITES too (found by ptswflt's phase-5
      // injection: without cur_is_w the RO page check never ran and the bytes
      // landed on a read-only GDT page).
      S_TSW_BUSY: begin
        cur_is_w_nat = 1'b1;
        cur_lin_nat = (tsw_step == 5'd0)
                          ? (gdt_base + {16'd0, tsw_new_sel[15:3], 3'd0} + 32'd4)
                          : tsw_call ? tsw_new_base
                                     : (gdt_base + {16'd0, tr_sel[15:3], 3'd0} + 32'd4);
      end
      S_NTRET_RD: cur_lin_nat = tr_base;
      S_IOPERM: cur_lin_nat = (int_step == 4'd0)
                        ? (tr_base + 32'h64)
                        : (tr_base + {16'd0, ioperm_base} + {19'd0, ioperm_port[15:3]});
      S_INT_TSS: cur_lin_nat = tr_base + tss_stk_off + {29'd0, int_step[0], 2'b00};
      S_INT_SS:  cur_lin_nat = (int_new_ss[2] ? ldt_base : gdt_base)
                           + {16'd0, int_new_ss[15:3], 3'd0}
                           + {29'd0, int_step[0], 2'b00};
      // The frame page-plan probe (see the plan contract near frm_pg_*). A
      // WRITE permission probe; the bus arm issues NO transaction, so the TLB
      // lookup / walk / perm check run and nothing is read or written.
      S_INT_PROBE: begin
        cur_is_w_nat = 1'b1;
        // One beat per plan entry: slot-start pages probed AT the slot's
        // first byte (silicon reports CR2 = the faulting push), lo pages at
        // their base (frm_pg_addr carries the staged SS base + masked
        // offset, so a wrapped 16-bit frame's pages are enumerated exactly).
        cur_lin_nat  = frm_pg_addr[frm_pg_i[1:0]];
        // the segment extent follows the SLOT's width, not the dword default:
        // a word slot ending exactly at the stack segment's bound is legal
        // and must not be rejected as a dword. A page-base (mid) entry's
        // extent was covered by the preceding slot-start entry.
        cur_size     = int_frm_wide ? 4'd4 : 4'd2;
        seg_ext_skip = frm_pg_mid[frm_pg_i[1:0]];
      end
      // REVIEW1_Aug3 R2-H05: call-gate parameter read from the OLD (still
      // installed) stack. Unit = dword for a 32-bit gate, word for a 16-bit
      // gate; the source offset wraps per the OLD stack's B bit (stk16) --
      // QEMU helper_lcall_protected: old_ssp + ((ESP + i*u) & old_sp_mask).
      // cg_beat = param index i in this state.
      S_CG_PRD: begin
        cur_lin_nat = seg_base[SG_SS]
                  + stk16(int_old_esp + (cg_wide ? {24'd0, cg_beat, 2'b00}
                                                 : {25'd0, cg_beat, 1'b0}));
        cur_size = cg_wide ? 4'd4 : 4'd2;
      end
      default: cur_lin_nat = 32'd0;
    endcase
  end
  // REVIEW1_Aug3 R2-C03: the redirect/forcing boundary. cur_lin_nat (the natural
  // per-state linear address, read by the engine's crossing detection and by
  // CHECK 5) has NO fragment-engine dependency, so there is no combinational
  // loop; cur_lin is what translation and the bus driver consume. An engine
  // write beat forces cur_is_w so the probe's permission check and the
  // Dirty-bit walk see a WRITE even in a state whose arm never set it.
  assign cur_lin  = fx_redirect_e ? {cur_lin_nat[31:12] + 20'd1, 12'd0}
                                  : cur_lin_nat;
  assign cur_is_w = (fx_eng && fx_wr_e) ? 1'b1 : cur_is_w_nat;

`ifdef VEN_FP_SHARED
  // A shared-top command owns x87 state immediately.  For a destination store,
  // S_FLOAD/S_FENV_LD is therefore a translation+write-permission sweep before
  // command acceptance, not a data read.  q_f_mem_write distinguishes it from
  // FLD/FRSTOR, which use these states as ordinary reads.
  assign fp_store_probing = q_f_mem_write &&
                            ((state == S_FLOAD) || (state == S_FENV_LD));
`else
  assign fp_store_probing = 1'b0;
`endif
  assign fp_store_probe_cross = fp_store_probing && !fp_store_probe_second &&
                                ({1'b0, cur_lin_nat[11:0]} + {9'd0, cur_size} > 13'h1000);
  // The FSM's paging/segment priority holds the state on a walk or FE-pipeline
  // settle cycle and diverts it on a fault.  A phase advances only after this
  // page has passed all of those checks.
  assign fp_store_probe_advance = fp_store_probing && !seg_access_fault &&
                                  !perm_fault && !xlate_miss && !fe_xlate_pend;
`ifdef VEN_FP_SHARED
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      fp_store_probe_second <= 1'b0;
    // A translation walk is a detour of the current probe, so retain the page-2
    // phase across it.  Any other state has left the probe transaction.
    else if (!fp_store_probing && (state != S_WALK))
      fp_store_probe_second <= 1'b0;
    else if (fp_store_probe_advance)
      fp_store_probe_second <= !fp_store_probe_second && fp_store_probe_cross;
  end
`else
  assign fp_store_probe_second = 1'b0;
`endif
  // xlate_miss: paging is on, the current state issues a translatable memory
  // access, and the relevant TLB MISSES -> the FSM must run a page walk (S_WALK)
  // before this access can complete. The descriptor-table reads always run with
  // paging off, so they are excluded. Computed once and consumed by the FSM.
  logic xlate_miss;
  always_comb begin
    logic translatable;
    unique case (state)
      S_FETCH, S_PF, S_PIPE,
      S_LOAD, S_LOAD2, S_FLOAD, S_FSTORE, S_STORE, S_USEQ, S_ENTER,
      // M2S.3 IDT delivery reads/writes are translated when paging is on.
      // M2S.4 adds the inter-priv IRET SS pop (S_IRET_SS) — a genuine stack pop,
      // translated like the other stack accesses.
      // (The descriptor/TSS structure reads are translatable too — added by
      // REVIEW2 C-04 below; the older M2S.1/.2 physical-read convention this
      // comment used to record here is gone.)
      S_INT_GATE, S_INT_CS, S_INT_CS_RET, S_INT_PUSH, S_IRET,
      // REVIEW2 C-03: these four were MISSING. S_FENV_ST/S_FENV_LD already had
      // cur_lin cases but were excluded here, so a TLB miss on an x87 environment
      // save/restore never walked. S_LCALL/S_RETF had neither (cur_lin cases added
      // above); they are ordinary SS:ESP stack accesses and must translate like every
      // other stack access.
      S_FENV_ST, S_FENV_LD, S_LCALL, S_RETF,
      // REVIEW_aug2 C-05: LGDT/LIDT and SGDT/SIDT are ordinary linear operands.
      S_LGDT, S_SGDT,
      // REVIEW2 C-04: descriptor/TSS structures are architecturally LINEAR.
      // NOT included: S_WALK (the page-table walk is physical by definition) and
      // S_SMI_SAVE/S_RSM (the SMM save map is architecturally physical). Those two
      // exclusions are correct and stay.
      S_LJMP, S_INT_TSS, S_INT_SS,
      S_IRET_SS: translatable = 1'b1;
      // REVIEW1_Aug3 R2-C02: a null segment load performs no access (seg_null_load
      // suppresses the request), so it must not translate either -- same
      // suppression/translation coherence as the null-LLDT fix.
      S_SEGLD:   translatable = !seg_null_load;
      // REVIEW_Aug3 (the pltr blocker): a NULL LLDT performs NO access at all --
      // lldt_null_q suppresses the bus request -- so it must not TRANSLATE either.
      // With paging on, the unsuppressed divert walked the GDT[0] page and raised
      // a #PF for an access the architecture never makes (and even on a present
      // page a spurious walk dirties A bits). The suppressed request and the
      // suppressed translation must come from the same predicate.
      S_LTR:     translatable = !lldt_null_q;
      // REVIEW1_Aug3 R2-C04: the frame probe translates (and walks on a miss)
      // like any access, but issues no bus transaction (the bus arm stays idle).
      S_INT_PROBE: translatable = 1'b1;
      // R2-H05: the param reads are ordinary (old-)stack reads -- they page and
      // walk like any other, delivered in the old context on a fault.
      S_CG_PRD:    translatable = 1'b1;
      S_NTRET_RD: translatable = 1'b1;
      S_IOPERM:  translatable = 1'b1;   // REVIEW1_Aug2 M-03: a TSS read, so it pages
      // REVIEW1_Aug2 C-09: the task switch now pages like every other linear access.
      S_TSW_SAVE, S_TSW_READ, S_TSW_LDT, S_TSW_BUSY: translatable = 1'b1;
      // Same suppression/translation coherence as S_LTR: a beat whose request is
      // suppressed -- out-of-bounds (tsw_seg_oob), null (tsw_seg_null, R2-C02), or
      // a V86 incoming task (no descriptor reads at all) -- must not translate
      // either. The V86 half of this was reachable before this change: a
      // paragraph-indexed "GDT read" had its request suppressed but still walked.
      S_TSW_SEG: translatable = !tsw_eflags[17] && !tsw_seg_oob && !tsw_seg_null;
      default: translatable = 1'b0;
    endcase
    // S_PIPE accesses memory only for a checked data read/store or an I-cache fill.
    if (state==S_PIPE && !(pipe_load_req || pipe_store_req || pf_miss)) translatable = 1'b0;
    // Export the final predicate to module scope for the FE_PIPE micro-TLB
    // re-registration gate (below). Identical value to the local `translatable`.
    fe_translatable = translatable;
    // A data access misses if the D-TLB lacks the page OR (for a WRITE) the page
    // is TLB-resident but its Dirty bit has not yet been set in memory — that
    // first write must re-walk to set D (matching qemu's set-D-on-first-write).
    fe_xlate_pend = 1'b0;
    // REVIEW2_aug2 C-02: HOISTED ABOVE THE FEATURE CONDITIONAL. This lived inside the
    // `ifdef VEN_FE_PIPE branch while the `else` branch READ it -- so in the DEFAULT
    // build it was never assigned. Verilator randomises an unassigned signal at
    // construction, and it is read in two places that decide whether a store re-walks
    // to set the TLB Dirty bit (here, and `walk_is_write <= cur_is_w && !xs_probing`).
    // An ordinary store miss could therefore skip or require the Dirty walk depending
    // on simulator seed, synthesis treatment, or power-up state -- nondeterminism in
    // the paging datapath, not a lint nit.
    //
    // It derives from FSM state only (S_STORE + the crossing-store phase), so there was
    // never a reason for it to sit inside a feature branch.
    xs_probing = (state == S_STORE) && xs_eff_act && (xs_eff_ph == 2'd0);
`ifdef VEN_FE_PIPE
    // page crossing -> the registered micro-TLB doesn't yet hold cur_lin's page;
    // stall 1 clock while the fe_*_q always_ff samples it (separate, runs this edge).
    if (paging_on && translatable)
      fe_xlate_pend = cur_is_d ? !(fe_dtlb_v && (fe_dtlb_page == cur_lin[31:12]))
                               : !(fe_itlb_v && (fe_itlb_page == cur_lin[31:12]));
    // ---- REVIEW1_Aug2 C-02: the crossing-store PROBE is not a write -------------
    // Phase 0 validates page 2 (mapping present + WRITE PERMISSION) but performs no
    // transaction and must not mark the page dirty -- if page 1 then faults, the store
    // never happened. But a write to a hit-but-CLEAN entry is treated as a miss below
    // (the `cur_is_w && !dirty` term) so the walker can set D, which means simply
    // suppressing D during the probe would LIVELOCK it: the walk would not set D, the
    // entry would stay clean, and the miss would re-assert forever.
    //
    // So the probe drops the DIRTY requirement while keeping the permission check.
    // perm_fault reads the RW bit straight out of the TLB entry and is independent of
    // dirty, so write permission is still enforced. D is then set by phase 2, when the
    // write actually happens and the same clean entry is walked for real -- which is
    // where it architecturally belongs.

    // xlate_miss from the REGISTERED hit (off the critical path); 0 during the pend
    // stall (the FSM holds, no premature walk).
    // A4-C01: the fragment engine's write probe (fx_probing) is the same
    // not-a-write class as xs_probing here -- a probe on a clean entry is NO miss.
    // S_INT_PROBE's validation phase (frm_pg_markd=0) is the same class; its D-mark
    // phase deliberately KEEPS the clean-entry rewalk (that is how D gets set
    // pre-commit), and an S_INT_PUSH beat on a plan-covered page never misses.
    xlate_miss = paging_on && translatable && !fe_xlate_pend && !frm_pg_hit &&
                 (cur_is_d ? (!fe_dtlb_hit || (cur_is_w && !xs_probing && !fx_probing && !fp_store_probing
                                                 && !((state==S_INT_PROBE) && !frm_pg_markd)
                                                 && !fe_dtlb_dirty))
                           : !fe_itlb_hit);
`else
    xlate_miss = paging_on && translatable && !frm_pg_hit &&
                 (cur_is_d
                    ? (!dtlb_lk_hit ||
                       (cur_is_w && !xs_probing && !fx_probing && !fp_store_probing
                        && !((state==S_INT_PROBE) && !frm_pg_markd) && !dtlb_lk_dirty))
                    : !itlb_lk_hit);
`endif
  end

  // ===========================================================================
  // L1 D-cache TIMING model ports (the state/SM live in dcache_timing, below).
  // dc_acc_valid/dc_acc_addr funnel the SINGLE per-clock LRU access (at most one
  // by construction: the FSM is a unique-case on `state`, and only the S_PIPE
  // U-data issue arm, S_LOAD, S_LOAD2, and S_STORE access the cache — never two in
  // one clock). dc_lu_addr drives the combinational pre-access lookup (dc_lu_hit),
  // always at the same address as this clock's access so the spine's miss penalty
  // sees PRE-access state (the dc_hit-then-dc_access read-before-write). All these
  // mirror the original inline `dc_access(X)` call sites EXACTLY (same guards, same
  // address, same cycle_mode gating; the U-pipe data read is UNGATED). A page-walk
  // diversion (xlate_miss) skips the FSM body this clock, so it gates every site.
  // ===========================================================================
  always_comb begin
    // U-pipe fast-path data access (S_PIPE issue arm). Reads run in both modes;
    // stores mirror the legacy S_STORE timing update and only touch this model in
    // cycle mode. pipe_load_req/pipe_store_req already fold in
    // (state==S_PIPE && pipe_bytes_ok && u_d.simple && !pipe_agi &&
    // mispred_bubbles==0); reaching the issue+commit branch additionally requires
    // stall_cnt==0, pending_mem_pen==0, not-FP, and !sys_mode.
    // REVIEW Aug-1 M-01: the trailing `!sys_mode` was the fifth hand-copy of the bail
    // condition. pipe_load_req already carries fp_sys_bail, so drop the duplicate.
    logic u_mem_acc;
    u_mem_acc = !xlate_miss && !pipe_mem_wait && (pipe_load_req || pipe_store_req) &&
                (stall_cnt==7'd0) && (pending_mem_pen==7'd0) && !u_d.is_fp;

    dc_acc_valid = 1'b0;
    dc_acc_addr  = 32'd0;
    unique case (state)
      S_PIPE: begin
        dc_acc_valid = u_mem_acc && (!pipe_store_req || cycle_mode);
        dc_acc_addr  = pipe_load_addr;
      end
      // Slow-path data accesses: all gated on mem_ack && cycle_mode, mirroring the
      // original inline `if (cycle_mode) ... dc_access(...)` under `if (mem_ack)`.
      S_LOAD: begin
        dc_acc_valid = !xlate_miss && mem_ack && cycle_mode;
        dc_acc_addr  = slow_dmem_addr;
      end
      S_LOAD2: begin
        dc_acc_valid = !xlate_miss && mem_ack && cycle_mode;
        dc_acc_addr  = str_edi;
      end
      S_STORE: begin
        dc_acc_valid = !xlate_miss && mem_ack && cycle_mode;
        dc_acc_addr  = (q_kind==K_STR) ? str_store_addr : st_addr;
      end
      default: ;
    endcase
    // The pre-access lookup is always at this clock's access address (each call
    // site's dc_hit() used the SAME address as its dc_access()).
    dc_lu_addr = dc_acc_addr;
  end

`ifndef VEN_L1_AXI
  dcache_timing #(.DC_SETS(DC_SETS), .DC_WAYS(DC_WAYS)) u_dcache_tm (
    .clk       (clk),
    .rst_n     (rst_n),
    .lu_addr   (dc_lu_addr),
    .lu_hit    (dc_lu_hit),
    .acc_valid (dc_acc_valid),
    .acc_addr  (dc_acc_addr)
  );
`else
  // VEN_L1_AXI (bus_mode=2): the D-cache TIMING model is redundant. Its only output,
  // dc_lu_hit, feeds the modeled D-miss PENALTY (`if(!dc_lu_hit) pen += P5_DMISS`) and
  // NEVER the load data/result. Under the real AXI/DDR bus that penalty is already
  // suppressed (core_fastpath.svh `pending_mem_pen <= real_bus ? 0 : pen`) and the
  // slow-path penalty is cycle_mode-gated (dead at the board's cycle_mode=0) — "mode-2
  // timing is functional-only". So dropping the ~4.4k-cell dcache_timing instance is
  // functionally INERT here and relieves the in-context congestion (the model survived
  // synth only because cfg_cycle_mode is a runtime input). Tie dc_lu_hit=1 (always-hit
  // => no modeled D-miss penalty); the dc_acc_*/dc_lu_addr drivers prune as dead. The
  // DEFAULT (non-L1_AXI) build keeps the model, so make verify's D-cache bands are
  // unchanged. The dc_acc_valid below is consumed nowhere now -> harmless dead net.
  assign dc_lu_hit = 1'b1;
`endif

  // ===========================================================================
  // L1 I-cache module ports (the ARRAYS + fill + LRU touch + reset live in the
  // icache module, below; this is the spine-side combinational driver). The arrays
  // are read PRE-edge through u_icache's READ-ONLY outputs (ic_data_o/ic_tag_o/
  // ic_val_o/ic_lru_o), which the ic_present/ic_hit_way/ic_byte probes consume
  // UNCHANGED. The spine OWNS the fill SEQUENCING (pf_fill_addr/pf_fill_way/pf_word
  // + the ic_victim_o LRU victim) and drives the single fill word + up-to-3 LRU touches
  // here, exactly mirroring the original inline NBA sites (same arm guards, same
  // addresses, same textual U->straddle->V last-write-wins order).
  // ===========================================================================
  logic        ic_fill_en, ic_fill_done;
  logic [IC_WAYW-1:0] ic_fill_way;
  logic [IC_IDXW-1:0]  ic_fill_set;
  logic [4:0]  ic_fill_off;
  logic [31:0] ic_fill_data;
  logic [IC_TAGW-1:0] ic_fill_tag;
  // R2-H09: the filling line's PHYSICAL page tag. mem_addr is the post-translate
  // bus address (core_bus_driver.svh's tail runs mem_xlate in place), so during
  // any fill beat its tag slice is exactly the line's physical identity (the
  // slice remains below the page-offset top. A 32-byte line never straddles a
  // page, so all eight fill
  // words agree on it.
  logic [IC_TAGW-1:0] ic_fill_ptag;
  assign ic_fill_ptag = mem_addr[5+IC_IDXW +: IC_TAGW];
  // R2-H09: the icache's CPU-snoop PHYSICAL match (ports 1/2), forwarded to the
  // uopcache so decoded state dies under the same physical identity.
  logic               ic_snp1_hit, ic_snp2_hit;
  logic [IC_IDXW-1:0] ic_snp1_hset, ic_snp2_hset;
  logic [IC_WAYW-1:0] ic_snp1_hway, ic_snp2_hway;
  // REVIEW2 H-17: instruction cacheability. The I-cache validated EVERY fill and had
  // no cacheable input, so CR0.CD did not control I-side allocation at all -- the
  // D-side already honours it (H-18, ven_l1d .cacheable) but the I-side kept
  // allocating and hitting with the cache architecturally DISABLED.
  //
  // CR0.CD (bit 30) is the half that is decidable inside the core and is enforced
  // here. The other half named in H-17 -- northbridge PAM / SMRAM / MMIO memory-type
  // attributes -- is decided by ven_cachemap, which lives behind EN_L2 and whose
  // MODULE SOURCE IS ABSENT FROM THIS CHECKOUT (REVIEW2 M-05). It therefore cannot
  // be built or tested here. The mechanism below is the whole enforcement path, so
  // when the northbridge sources land, the region term ORs straight in beside CD
  // with no further restructuring.
  logic        ic_fill_nocache;
  // CURRENTLY TIED OFF. Driving this from CR0.CD was tried and REVERTED, because it
  // LIVELOCKS THE CORE -- measured, not suspected:
  //
  //     tb: retired 0 instructions in 8000 clocks (bus: 31997 reads, 0 writes)
  //
  // CR0 resets to 0x6000_0010, so CD (bit 30) and NW (bit 29) are SET out of reset --
  // architecturally correct for a P5. With CD driving fill_nocache, no fetched line is
  // ever validated. The I-cache is not a side cache here: it IS the fetch datapath.
  // The spine misses -> S_PF fills the line -> re-checks ic_val -> still invalid ->
  // fills again, forever. verify-sys, m6 and the L1 gates all went red with all-zero
  // sentinels, which is what "no instruction ever retires" looks like from outside.
  //
  // This is precisely why the snoop poison (H-08/H-12) is safe and this is not: a
  // snoop poison is TRANSIENT, so the retry succeeds. A memory-type/CD condition is
  // PERSISTENT, so the retry can never succeed.
  //
  // Doing H-17 properly therefore needs a FETCH BYPASS: on a non-cacheable fetch,
  // deliver the fetched bytes to the decoder WITHOUT requiring a validated I-cache
  // line. That is a datapath addition, not a poison-bit tweak, and it is tracked in
  // task #69 rather than approximated here. The mechanism below is correct, is
  // unit-tested (run-icache-snoop-gate checks [6][7][8] including a cacheable
  // control), and is the right hook for that work -- it just has nothing safe to
  // drive it until the bypass exists.
`ifndef VEN_IC_NO_FETCH_BYPASS
  // REVIEW1_Aug2 H-06: the FETCH BYPASS the comment above says this needs.
  //
  // Why poisoning alone livelocks: the I-cache IS the fetch datapath, so a line that
  // never validates is refetched forever (measured: 0 instructions in 8000 clocks,
  // 31997 bus reads). A snoop poison is TRANSIENT so the retry succeeds; a CD/memory-
  // type condition is PERSISTENT so it never can.
  //
  // The way out is the same shape H-07 used on the D-side: SERVE WITHOUT ALLOCATING.
  // The fill already writes the DATA array -- only the valid bit is withheld -- so the
  // bytes are present at {fill_set, fill_way} and the fetch just needs to be allowed
  // to read them once. This registers that one line as a BYPASS WINDOW which
  // ic_present()/ic_hit_way() honour, and which is retired as soon as the fetch line
  // moves on. The line's valid bit is never set, so nothing can hit it later: the next
  // fetch of the same address refetches, which IS non-cacheable semantics.
  // TWO entries, not one. MEASURED with a single entry: 10 instructions in 2089 clocks
  // and 8229 bus reads -- ~820 reads per instruction against 8 for one line fill. The
  // fetch reads TWO lines (ic_rd_wayA from flin and ic_rd_wayB from flin_nl, for
  // instructions straddling a line boundary), so with CD set and every line
  // non-cacheable, the two lines evicted each other's window on every straddle and
  // both refilled continuously. That is the same single-entry mistake H-09's
  // invalidation skid had, rebuilt here by me two commits after fixing it there.
  logic [1:0]          icbp_v;
  logic [IC_IDXW-1:0]  icbp_set [2];
  logic [IC_WAYW-1:0]  icbp_way [2];
  logic [IC_TAGW-1:0]  icbp_tag [2];
  logic [IC_TAGW-1:0]  icbp_ptag [2];   // R2-H09: physical identity for the snoop clear
  logic                icbp_rr;      // round-robin insert pointer
  // does entry i cover either line the fetch currently needs?
  function automatic logic icbp_needed(input int i);
    icbp_needed = ((flin[5 +: IC_IDXW]         == icbp_set[i]) &&
                   (flin[5+IC_IDXW +: IC_TAGW] == icbp_tag[i]))
               || ((flin_nl[5 +: IC_IDXW]         == icbp_set[i]) &&
                   (flin_nl[5+IC_IDXW +: IC_TAGW] == icbp_tag[i]));
  endfunction
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin icbp_v <= 2'b00; icbp_rr <= 1'b0; end
    else begin
      if (ic_fill_en && ic_fill_done && ic_fill_nocache) begin
        icbp_v  [icbp_rr] <= 1'b1;
        icbp_set[icbp_rr] <= ic_fill_set;
        icbp_way[icbp_rr] <= ic_fill_way;
        icbp_tag[icbp_rr] <= ic_fill_tag;
        icbp_ptag[icbp_rr] <= ic_fill_ptag;   // R2-H09
        icbp_rr           <= ~icbp_rr;
      end
      // retire an entry only when NEITHER fetch line needs it
      for (int i = 0; i < 2; i++)
        if (icbp_v[i] && !icbp_needed(i)) icbp_v[i] <= 1'b0;
      // R2-H09: a CPU store through ANY alias drops the bypassed copy too --
      // the same physical match the line snoop does (LAST, so it wins over a
      // same-edge capture: a store to the line being bypass-filled must not
      // leave the stale bytes consumable).
      for (int i = 0; i < 2; i++) begin
        if (icbp_v[i] && icsnp_v1 && (icbp_set[i] == icsnp_a1[5 +: IC_IDXW])
            && (icbp_ptag[i] == icsnp_a1[5+IC_IDXW +: IC_TAGW])) icbp_v[i] <= 1'b0;
        if (icbp_v[i] && icsnp_v2 && (icbp_set[i] == icsnp_a2[5 +: IC_IDXW])
            && (icbp_ptag[i] == icsnp_a2[5+IC_IDXW +: IC_TAGW])) icbp_v[i] <= 1'b0;
      end
`ifdef VEN_L1_AXI
      // A4-H02: the EXTERNAL physical snoop (a DMA/northbridge write), exact
      // when lin == phys. With paging ON the exec_flush_all clear below already
      // covers it conservatively, so this precise path is what paging-OFF DMA
      // (real-mode BIOS/DOS code loading) invalidates through.
      for (int i = 0; i < 2; i++)
        if (icbp_v[i] && ic_snoop_valid
            && (icbp_set[i]  == ic_snoop_addr[5 +: IC_IDXW])
            && (icbp_ptag[i] == ic_snoop_addr[5+IC_IDXW +: IC_TAGW]))
          icbp_v[i] <= 1'b0;
`endif
      // A4-H02: the bypass is EXECUTABLE VALIDITY like the I-cache/uopcache --
      // it dies with the same flush domain (global/cache invalidation, A20
      // edge, TLB/remap flush). LAST, so invalidation also wins over a
      // same-edge insertion (a fill completing into a flushed domain must not
      // leave the new entry live behind the flush's back).
      if (exec_flush_all) icbp_v <= 2'b00;
    end
  end
`endif

`ifndef VEN_IC_NO_FETCH_BYPASS
  // REVIEW2_aug2 H-13: MEASURED COST of honouring CR0.CD on instruction fetch, with the
  // two builds confirmed different by checksum first (an earlier "0% cost" reading here
  // turned out to be a build compared against itself):
  //
  //     psmm   21268 -> 38780 clocks   +82%
  //     pv86    8971 -> 10243          +14%
  //     ppage   2567 ->  2783           +8%
  //     pmode / pcpl / pfault           ~0%
  //
  // Left DEFAULT-OFF, and the reason is architectural rather than squeamish: CR0 resets
  // with CD=1, and a real 486/P5 BIOS CLEARS CD/NW after POST. A guest that never clears
  // it runs uncached forever -- that is the guest's defect, and paying up to 82% in the
  // CPU to paper over it is the wrong trade for a design whose target is Win95 + Quake.
  // The datapath is REAL and validated (H-06: 22/60 corpus images refetch, final state
  // byte-identical); only the default is off. Driving it from the physical memory type
  // as well needs ven_cachemap, which is on an unmerged branch.
  //
  // CR0.CD (bit 30) is the driver the comment above says had nothing safe to drive it.
  //
  // REVIEW2_aug2 H-13 IS NOW CLOSED. ven_cachemap was landed on this branch, so the
  // physical MEMORY TYPE is the second driver: ic_mtype_nc is the chipset's KEN#
  // analogue for the line being fetched, queried with is_code=1 (a PAM window opened
  // read-only is L1-cacheable for CODE reads and not for data -- the shadowed-BIOS
  // case). ORed in, not substituted: CR0.CD and the memory type are independent
  // reasons not to retain a line and either alone is sufficient.
  //
  // The perf figures above are unaffected BY CONSTRUCTION: on cacheable DRAM the map
  // returns l1_cacheable=1, so the new term is 0 and the OR is inert. What it changes
  // is only the regions where retaining the line was WRONG.
`ifndef VEN_IC_NO_MTYPE
  assign ic_fill_nocache = creg0[30] | ic_mtype_nc;
`else
  // Opt-out, for the H-13 gate's CONTROL build only: drops the memory-type term so the
  // gate can measure the difference the term makes rather than assert it. Same shape as
  // VEN_IC_NO_FETCH_BYPASS, and for the same reason -- a gate that cannot build the
  // other side of the comparison is not measuring anything.
  assign ic_fill_nocache = creg0[30];
`endif
`else
  // H-13: with the CR0.CD bypass compiled out, an UNCACHEABLE-BY-MEMORY-TYPE line must
  // still not be retained -- that is a chipset-decode property, not a CR0 policy.
  assign ic_fill_nocache = ic_mtype_nc;
`endif

  logic        ic_tch0_en, ic_tch1_en, ic_tch2_en;
  logic [IC_IDXW-1:0]  ic_tch0_set, ic_tch1_set, ic_tch2_set;
  logic [IC_TAGW-1:0] ic_tch0_tag, ic_tch1_tag, ic_tch2_tag;
  always_comb begin
    // ---- fill port: the two MUTUALLY-EXCLUSIVE fill arms (S_PF words 0..7 vs the
    // S_PIPE-miss word-0 path; different FSM states/arms => never concurrent).
    logic ic_pf_miss_fill;
    // S_PIPE word-0 fill arm: the 2nd S_PIPE else-if (stall_cnt==0, !pipe_bytes_ok),
    // gated by the !xlate_miss page-walk diversion. The bus asserts the fill's
    // word-0 read THIS clock (mem_addr = fill line base when pf_miss), so the word
    // is captured here. With a same-cycle BFM (modes 0/1) mem_ack is high this clock
    // so no guard is needed; under the REAL stalling L1 (real_bus) the ven_l1d miss
    // returns mem_ack=0 + combinational garbage for several clocks, so the capture
    // (and the S_PIPE->S_PF advance, core_fastpath.svh) MUST wait for mem_ack — else
    // every cold I-line latches garbage at boot. The `(!real_bus||mem_ack)` term is
    // inert in modes 0/1 and absent in the default build.
    // !fp_issue_block: same reason as pf_miss -- no word-0 capture for a fill
    // that an interrupt or debugger park guarantees will never complete.
    // !exec_issue_ok (a flush cycle): the divert calls this clock a pure bubble,
    // so no fill word may land in it either -- the capture would race the
    // invalidating edge inside the icache. Word 0 refetches from S_PF (the
    // divert sets pf_word=0 on a flush cycle).
    ic_pf_miss_fill = (state==S_PIPE) && !fp_issue_block && !xlate_miss && (stall_cnt==7'd0) &&
                      !pipe_bytes_ok && exec_issue_ok
`ifdef VEN_L1_AXI
                      && (!real_bus || mem_ack)
`endif
                      ;

    ic_fill_en   = 1'b0;
    ic_fill_done = 1'b0;
    ic_fill_set  = '0;
    ic_fill_way  = '0;
    ic_fill_off  = 5'd0;
    ic_fill_data = 32'd0;
    ic_fill_tag  = '0;
    if (state==S_PF && mem_ack) begin
      // S_PF: fill the word covering pf_word; complete (allocate + MRU) on word 7.
      ic_fill_en   = 1'b1;
      ic_fill_set  = pf_fill_addr[5 +: IC_IDXW];
      ic_fill_way  = pf_fill_way;
      ic_fill_off  = {pf_word, 2'b00};
      ic_fill_data = mem_rdata;
      ic_fill_done = (pf_word==3'd7);
      ic_fill_tag  = pf_fill_addr[5+IC_IDXW +: IC_TAGW];
    end else if (ic_pf_miss_fill) begin
      // S_PIPE-miss word 0 into the LRU victim (ic_victim_o, PRE-edge). NOT a
      // completing fill — tag/val/MRU land when S_PF reaches word 7 (pf_fill_*).
      ic_fill_en   = 1'b1;
      ic_fill_set  = pf_miss_fa[5 +: IC_IDXW];
      ic_fill_way  = ic_victim_o[pf_miss_fa[5 +: IC_IDXW]];
      ic_fill_off  = 5'd0;
      ic_fill_data = mem_rdata;
    end

    // ---- LRU touch ports (U / U-straddle / V), textual last-write-wins. Fire only
    // when an instruction COMMITS this clock — the FP issue+commit arm (touches
    // flin only) OR the integer ISSUE arm (flin, straddle when it crosses the line
    // boundary, V when paired). These two arms are mutually exclusive; replicating
    // their guards is the established pattern (cf. dc u_load_acc above).
    begin
      logic ic_in_pipe, ic_halt4, ic_fp_arm, ic_fp_commit, ic_int_issue;
      logic [31:0] ic_dep_ready, ic_straddle_a, ic_v_a;
      // common: reached the inner FP/issue else-chain (past stall/fill/defer).
      // !fp_issue_block: nothing issues on an abandoned clock, so no LRU touch and no
      // FP commit. Gating ic_in_pipe covers ic_int_issue AND ic_fp_commit at once.
      ic_in_pipe = (state==S_PIPE) && !fp_issue_block && !xlate_miss && !pipe_mem_wait && (stall_cnt==7'd0) &&
                   pipe_bytes_ok && (pending_mem_pen==7'd0);
      // FK_ARITH-under-bad-PC HALT arm (no touch). BUG#3: gate by VEN_FP_PC_RELAX to
      // MATCH the fast-path spine (core_fastpath.svh) — else the FMUL retires but its
      // LRU touch / result-commit is suppressed (ic_fp_arm=0) -> divergence.
`ifdef VEN_FP_PC_RELAX
      ic_halt4   = 1'b0;
`else
      ic_halt4   = u_d.is_fp && (u_d.fp_kind==FK_ARITH) && (fctrl[9:8]!=2'b11);
`endif
      ic_fp_arm  = ic_in_pipe && !ic_halt4 && u_d.is_fp;
      ic_dep_ready = (u_d.fp_role>=3'd2) ? fp_ready_cyc : 32'd0;
`ifdef VEN_FP_OVERLAP
      // GAP1 mirror (matches core_fastpath.svh): a following FP op (not FXCH) waits on
      // the x87 exec unit (fp_busy_cyc), so spine + driver agree on the commit clock.
      if (u_d.fp_kind != FK_FXCH
          && $signed(fp_busy_cyc - core_cyc) > 0
          && $signed(fp_busy_cyc - ic_dep_ready) > 0)
        ic_dep_ready = fp_busy_cyc;
`endif
      // FP issue+commit = the final else (not the dep-stall, not the occ-burn).
      ic_fp_commit = ic_fp_arm &&
                     !(!fp_occ_pending && ($signed(ic_dep_ready - core_cyc) > 0)
                                       && ($signed(ic_dep_ready - core_cyc) < 32'sd128)) &&
                     !(!fp_occ_pending && (u_d.fp_occ > 7'd1));
      // integer ISSUE arm = final else of the chain (not-FP, no bail, no mispred
      // bubble, no AGI). !u_d.is_fp already excludes ic_halt4/ic_fp_arm.
      // REVIEW Aug-1 M-01: canonical predicate (was a hand-copied `!u_d.simple ||
      // sys_mode`, so committed system-fast instructions never touched I-cache LRU).
      ic_int_issue = ic_in_pipe && !u_d.is_fp && !fp_sys_bail &&
                     (mispred_bubbles==3'd0) && !pipe_agi;

      // tch0: U's line — touched on EITHER commit arm (set/tag from flin).
      ic_tch0_en  = ic_fp_commit || ic_int_issue;
      ic_tch0_set = flin[5 +: IC_IDXW];
      ic_tch0_tag = flin[5+IC_IDXW +: IC_TAGW];
      // tch1: U's straddle line — integer ISSUE arm only, when flin crosses the
      // 32-byte line boundary (addr = flin + u_d.len - 1). FP ops never straddle.
      ic_straddle_a = flin + {28'd0,u_d.len} - 32'd1;
      ic_tch1_en  = ic_int_issue &&
                    (({1'b0,flin[4:0]} + {2'b0,u_d.len}) > 6'd32);
      ic_tch1_set = ic_straddle_a[5 +: IC_IDXW];
      ic_tch1_tag = ic_straddle_a[5+IC_IDXW +: IC_TAGW];
      // tch2: paired V's line — integer ISSUE arm only, when pipe_pair (= do_v).
      ic_v_a      = flin + {28'd0,u_d.len};
      ic_tch2_en  = ic_int_issue && pipe_pair;
      ic_tch2_set = ic_v_a[5 +: IC_IDXW];
      ic_tch2_tag = ic_v_a[5+IC_IDXW +: IC_TAGW];
    end
  end

  icache #(.IC_SETS(IC_SETS), .IC_LINE(IC_LINE), .IC_WAYS(IC_WAYS)) u_icache (
    .clk       (clk),
    .rst_n     (rst_n),
    .rd_setA   (ic_rd_setA),
    .rd_wayA   (ic_rd_wayA),
    .rd_lineA  (ic_rd_lineA),
    .rd_setB   (ic_rd_setB),
    .rd_wayB   (ic_rd_wayB),
    .rd_lineB  (ic_rd_lineB),
    .rd_collA  (ic_rd_collA),
    .rd_collB  (ic_rd_collB),
    .ic_tag_o  (ic_tag_o),
    .ic_val_o  (ic_val_o),
    .ic_victim_o (ic_victim_o),
    .fill_en   (ic_fill_en),
    .fill_set  (ic_fill_set),
    .fill_way  (ic_fill_way),
    .fill_off  (ic_fill_off),
    .fill_data (ic_fill_data),
    .fill_nocache (ic_fill_nocache),
    .fill_done (ic_fill_done),
    .fill_tag  (ic_fill_tag),
    .fill_ptag (ic_fill_ptag),   // R2-H09: the filling line's PHYSICAL page tag
    .snoop1_hit(ic_snp1_hit), .snoop1_hset(ic_snp1_hset), .snoop1_hway(ic_snp1_hway),
    .snoop2_hit(ic_snp2_hit), .snoop2_hset(ic_snp2_hset), .snoop2_hway(ic_snp2_hway),
    .tch0_en   (ic_tch0_en),
    .tch0_set  (ic_tch0_set),
    .tch0_tag  (ic_tch0_tag),
    .tch1_en   (ic_tch1_en),
    .tch1_set  (ic_tch1_set),
    .tch1_tag  (ic_tch1_tag),
    .tch2_en   (ic_tch2_en),
    .tch2_set  (ic_tch2_set),
    .tch2_tag  (ic_tch2_tag),
    // Phase D.6: snoop-invalidate from the northbridge (VEN_L1_AXI); 0 otherwise.
`ifdef VEN_L1_AXI
    .snoop_inv_valid (ic_snoop_valid),
    .snoop_inv_addr  (ic_snoop_addr),
    .snoop_inv_valid1(icsnp_v1),   // H-12: core-generated SMC snoop
    .snoop_inv_addr1 (icsnp_a1),   // R2-H09: PHYSICAL (both sources)
    .snoop_inv_valid2(icsnp_v2),
    .snoop_inv_addr2 (icsnp_a2),   // H-12
    // REVIEW2 H-16: the I-cache is LINEAR-tagged (flin = seg_base[SG_CS] + eip), but
    // snoop port 0 is the DMA / northbridge snoop and carries a PHYSICAL address. With
    // paging ON those live in different spaces, so a DMA write to physical page P
    // simply CANNOT match a resident line tagged by virtual page V -- the per-line
    // invalidate silently misses and stale bytes stay executable. (Ports 1/2 are the
    // CPU's own SMC stores and were converted to LINEAR addresses by task #51, so they
    // are exact and are left alone.)
    //
    // Of the three directions the review offers -- physical I-tags, a reverse alias
    // map, or "conservatively flush all I/uop state on external writes" -- this takes
    // the third. Physical tags are the right long-term answer but move the whole fetch
    // path behind translation; the conservative flush is correct TODAY, because
    // over-invalidation can only cost refills, never correctness.
    //
    // GATED ON paging_on, which matters for more than tidiness: with paging OFF
    // lin == phys, so the existing per-line physical snoop is EXACT and stays exact.
    // Real-mode BIOS/DOS boot -- where essentially all the DMA is -- keeps the cheap
    // precise path and pays nothing. The blunt flush applies only where the addresses
    // genuinely cannot be compared.
    //
    // This does NOT close the virtual-alias half of H-16 (executing one alias while
    // storing through another): those are CPU stores on ports 1/2, exact in linear
    // space but only for the aliases that share a linear address. That needs physical
    // tags or an alias map -- see task #69.
    // R2-H09: the tlb_flush term covers remaps (MOV CR3 / INVLPG / CR0.PG) -- a
    // remapped linear page's resident lines must die with the old mapping.
    // A4-H02: the expression is exec_flush_all now, shared with every other
    // executable-validity store (uopcache, predecode, the fetch bypass).
    .flush_all       (exec_flush_all)
`else
    // The non-L1-AXI build has no northbridge/DMA snoop source, so the three
    // snoop ports tie off -- but the GLOBAL flush has the same sources as the
    // L1 build (tlb_flush_q / a20_flush / cache_inv_go / smm_flush), and the
    // I-cache must invalidate with them: without this, a flush cycle could
    // refill the OTHER way while the stale line stayed valid, leaving two
    // valid ways sharing one tag (hit priority then decides which byte
    // stream executes -- placement luck, not a contract).
    .snoop_inv_valid (1'b0),
    .snoop_inv_addr  (32'd0),
    .snoop_inv_valid1(icsnp_v1),   // H-12: the core's OWN store snoop
    .snoop_inv_addr1 (icsnp_a1),   // R2-H09: PHYSICAL
    .snoop_inv_valid2(icsnp_v2),
    .snoop_inv_addr2 (icsnp_a2),   // H-12
    .flush_all       (exec_flush_all)
`endif
  );

`ifdef VEN_UOPCACHE
  // ===========================================================================
  // P0-11 PREDECODE-ON-FILL plumbing + the µop-cache instance.
  //
  // Accumulate the S_PF refill burst (word 0 from the S_PIPE-miss arm, words 1..7
  // from S_PF) into a 256-bit line buffer; when the fill COMPLETES (ic_fill_done,
  // word 7), pulse the predecode walker NEXT clock with the assembled line — by
  // then word 7 has landed in pf_line_buf. The walker re-runs decode.sv over the
  // line boundary-by-boundary (off the fast path), so this latency is part of the
  // cold-line imiss tail. inv_en at fill_done clears the (set,way) predecode-valid
  // so the resident-but-not-yet-predecoded window correctly reads uop_hit=0.
  // ===========================================================================
  logic [IC_LINE*8-1:0] pf_line_buf;
  logic                 pd_start_r;
  logic [IC_IDXW-1:0]   pd_set_r;
  logic                 pd_way_r;
  logic [31:0]          pd_flags_r;
  logic                 pd_def16_r;   // H-04: default size captured with the line
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pd_start_r <= 1'b0;
    end else begin
      pd_start_r <= 1'b0;
      if (ic_fill_en) begin
        pf_line_buf[{ic_fill_off,3'b000} +: 32] <= ic_fill_data;
        if (ic_fill_done) begin
          pd_start_r <= 1'b1;
          pd_set_r   <= ic_fill_set;
          pd_way_r   <= ic_fill_way;
          pd_flags_r  <= eflags;
          pd_def16_r  <= def16;   // H-04
        end
      end
    end
  end

  uopcache #(.IC_SETS(IC_SETS), .IC_LINE(IC_LINE), .NSLOT(NSLOT)) u_uopcache (
    .clk(clk), .rst_n(rst_n),
    .rd_setA(ic_rd_setA), .rd_wayA(ic_rd_wayA),
    .rd_slotsA(uc_slotsA), .rd_bvalidA(uc_bvA), .rd_bslotA(uc_bsA), .rd_pdvalidA(uc_pdvA),
    .rd_setB(ic_rd_setB), .rd_wayB(ic_rd_wayB),
    .rd_slotsB(uc_slotsB), .rd_bvalidB(uc_bvB), .rd_bslotB(uc_bsB), .rd_pdvalidB(uc_pdvB),
    .pd_start(pd_start_r), .pd_set(pd_set_r), .pd_way(pd_way_r),
    .pd_line(pf_line_buf), .pd_flags(pd_flags_r), .pd_cycle_mode(cycle_mode),
    // REVIEW Aug-1 H-04: the predecode walker runs the SAME decode leaf as the live
    // u_decode/v_decode, so it needs the SAME default-size input or it walks 16-bit
    // code with 32-bit lengths. pd_def16 is latched with the line; cur_def16 flushes
    // every resident predecode when CS.D flips.
    .pd_def16(pd_def16_r), .cur_def16(def16),
    // REVIEW2 H-16: flush the predecode array with the I-cache, for the same reason
    // and on the same condition -- otherwise the I-cache refills correct bytes while
    // this keeps serving uops predecoded from the stale ones.
    .flush_all(exec_flush_all),   // A4-H02: ONE domain (was a duplicated expression)
    // R2-H09: the icache's PHYSICAL snoop match drops the decoded state of the
    // same {set,way} on the same edge -- a store through any alias now kills
    // stale predecoded uops too (previously only a refill did).
    .inv_en(ic_fill_done || ic_snp1_hit),
    .inv_set(ic_snp1_hit ? ic_snp1_hset : ic_fill_set),
    .inv_way(ic_snp1_hit ? ic_snp1_hway : ic_fill_way),
    .inv2_en(ic_snp2_hit), .inv2_set(ic_snp2_hset), .inv2_way(ic_snp2_hway),
    .pd_busy()
  );
`endif

  // ===========================================================================
  // x87 architectural STATE FILE (fpu_top, R2) — module ports + write driver.
  //
  // The STATE (fpr[8]/ftop/fctrl/fstat/fptag + the FNINIT reset + the st(i)
  // read addressing) lives in u_fpu_state (rtl/fpu/fpu_top.sv). The spine reads
  // it back combinationally (fp_st[i]/fp_st0_phys/ftop/fctrl/fstat/fptag aliases)
  // and drives every state mutation onto the module's write ports through the
  // fp_we_* combinational driver below — which re-derives BOTH writer arms and
  // computes the same values via the same fpu_x87_pkg calls the inline code did:
  //   * FAST arm = the M5 cycle-mode FP issue+commit clock (fp_fast_commit, the
  //     SAME guard the icache ic_fp_commit touch uses — gate-proven).
  //   * SLOW arm = S_FEXEC (when !f_pc_bad) + the S_FSTORE last-beat pop.
  // The two arms are runtime-exclusive (S_PIPE fast vs S_FEXEC/S_FSTORE slow),
  // so the per-category strobes are ORed; at most one fires any clock. The
  // module owns the OLD-ftop NBA addressing (push uses ftop-1, etc.) so ordering
  // is byte-identical. fstat is presented FULLY COMPUTED (the spine does all the
  // masking/merge/sticky-OR), and exposed RAW (TOP not overlaid) so retire_fstat
  // + FNSTSW stay byte-identical.
  // ===========================================================================
  logic        fp_we_push;   logic [79:0] fp_push_data;
  logic        fp_we_top;    logic [79:0] fp_top_data;
  logic        fp_we_fstat;  logic [15:0] fp_fstat_wval;
  logic        fp_we_sti;    logic [2:0]  fp_wsti_idx;  logic [79:0] fp_wsti_data;
  logic        fp_wsti_clr_tag;
  logic        fp_we_fxch;   logic [2:0]  fp_fxch_idx;
  logic [79:0] fp_fxch_a;    logic [79:0] fp_fxch_b;
  logic        fp_we_pop;
  logic        fp_we_pop2;
  logic        fp_we_ffree;  logic [2:0]  fp_ffree_idx;
  logic        fp_we_incstp; logic        fp_we_decstp;
  logic        fp_we_fctrl;  logic [15:0] fp_fctrl_wval;
  logic        fp_we_fninit;
  // --- iterative SRT FDIV/FSQRT engine integration (VEN_SRT_ITER) -----------
  // Eligibility / handshake (module-level so the always_comb driver, the always_ff
  // FSM, and the engine instances all share them). All 0 in the default build, so
  // the `if(!fp_*_elig)` guards stay always-true and S_FP_BUSY is never entered.
  logic        fp_div_elig, fp_sqrt_elig, fp_iter_go, fp_iter_done;
  logic [79:0] eng_div_a, eng_div_b, eng_sqrt_in;
  logic [1:0]  eng_rc;
  logic        eng_div_start, eng_sqrt_start;
  logic        eng_div_busy, eng_div_done;   logic [82:0] eng_div_result;
  logic        eng_sqrt_busy, eng_sqrt_done;  logic [82:0] eng_sqrt_result;
  // M11 env-pointer latch driver (write-only -> u_fpu_state; read back via the
  // fip/fcs/fdp/fds aliases below for FNSTENV/FNSAVE).
  logic        fp_we_eptr;   logic [31:0] fp_eptr_fip;  logic [15:0] fp_eptr_fcs;
  logic        fp_we_dptr;   logic [31:0] fp_eptr_fdp;  logic [15:0] fp_eptr_fds;
  // M11b FLDENV/FRSTOR commit driver (computed from env_tmp on the last load beat).
  logic        fp_we_envld;  logic [15:0] fp_env_fctrl; logic [2:0] fp_env_ftop;
  logic [15:0] fp_env_fstat; logic [7:0]  fp_env_fptag;
  logic        fp_we_envregs; logic [639:0] fp_env_fpr_flat;
  // +VEN_FP_PIPE: the deferred-arith commit port drivers (tied 0 unless piped) +
  // the 1-deep FP-execute pipeline register. A fast-arm FK_ARITH op captures its
  // operands at issue (cycle N), retires normally, and its fpr/fstat write is
  // committed one cycle later (N+1) via the absolute-indexed we_wabs port — so
  // the eip->icache->decode->f_eval->fpr critical cone is split across two clocks.
  // The scoreboard already publishes the result at issue+lat (fadd lat 3), so the
  // result (committed at N+1) is in fpr well before any dependent consumer reads
  // it at issue+3 — both FP cycle bands are preserved by construction.
  logic        fp_we_wabs, fp_we_wabs_fstat;
  logic [2:0]  fp_wabs_idx;
  logic [79:0] fp_wabs_data;
  logic [15:0] fp_wabs_fstat;
`ifdef VEN_FP_PIPE
  logic        fpp_valid;            // a pipelined arith result is in flight (N+1)
  logic [2:0]  fpp_aluop;            // captured f_eval inputs / target
  logic [79:0] fpp_a, fpp_b;
  logic [1:0]  fpp_rc;
  logic [1:0]  fpp_pc;
  logic        fpp_err;
  logic [2:0]  fpp_dst;              // ABSOLUTE fpr index (ftop at issue)
  // combinational capture lines (driven by the fast-arm FK_ARITH issue, latched
  // into fpp_* by the always_ff):
  logic        fp_pipe_cap;
  logic [2:0]  fp_cap_aluop, fp_cap_dst;
  logic [79:0] fp_cap_a, fp_cap_b;
  logic [1:0]  fp_cap_rc;
  logic [1:0]  fp_cap_pc;
  logic        fp_cap_err;
  logic        fp_pipe_rd_haz;       // next op reads the in-flight target -> stall
  logic        fp_cap_stkflt;        // R2-H06: masked stack fault at capture
  logic        fpp_stkflt;           // R2-H06: registered with the capture
`ifdef VEN_FP_PIPE2
  // 2-STAGE FP-commit split (Fmax relief for the K26 production configuration).
  // The 1-stage +VEN_FP_PIPE
  // defer still runs the WHOLE f_eval (f_eval_s1 front -> f_eval_s2 round) in the
  // single commit clock N+1 -> an ~80-level / ~43-CARRY8 cone (fpp_*->fx_round_pack
  // ->fpr) that caps the routed Fmax ~52 MHz. This inserts ONE register at the
  // f_eval_s1/f_eval_s2 boundary, so the cone is split across TWO clocks:
  //   N+1: fp_s1_next = f_eval_s1(fpp_*)  -> registered into fpp2_s1   (front half)
  //   N+2: f_eval_s2(fpp2_s1)             -> committed via we_wabs      (back half)
  // The result lands in fpr at issue+2; the FP scoreboard already publishes it at
  // issue+lat (fadd lat 3 = issue+3), so EVERY role>=2 dependent reads it no earlier
  // than issue+3 -> the commit is still in fpr in time and the per-retire arch state
  // + the FP cycle bands are IDENTICAL to +VEN_FP_PIPE (no oracle change). Requires
  // VEN_FP_PIPE + the SPLIT eval (VEN_SRT_ITER, the same guard as the 1-stage split).
  logic        fpp2_valid;           // a stage-1 result is in flight (commits N+2)
  fx_pipe_t    fpp2_s1;              // registered f_eval_s1 output (the split point)
  logic [1:0]  fpp2_rc;
  logic [1:0]  fpp2_pc;
  logic [2:0]  fpp2_dst;             // ABSOLUTE fpr index carried from stage 0
  logic        fpp2_stkflt;          // R2-H06: the masked-fault marker, stage 1
  fx_pipe_t    fp_s1_next;           // comb f_eval_s1 result feeding the stage reg
`endif
`endif

`ifdef VEN_FP_SHARED
  // ===========================================================================
  // Area-shared x87 integration.  ven_fp_top owns the architectural state and
  // receives exactly one command from the commit-safe S_FEXEC point.  Every
  // memory operand has already completed its read/probe path before this point;
  // in particular a store cannot mutate FP state and then fault on a destination.
  // ===========================================================================
  logic        fp_shared_cmd_valid, fp_shared_cmd_ready, fp_shared_accept_retire, fp_shared_busy;
  logic        fp_shared_rsp_valid, fp_shared_rsp_unsupported, fp_shared_rsp_stack_fault;
  logic [84:0] fp_shared_rsp_arith;
  logic        fp_shared_rsp_store_valid, fp_shared_rsp_ax_valid;
  logic [863:0] fp_shared_rsp_store_data;
  logic [7:0]   fp_shared_rsp_store_bytes;
  logic [15:0]  fp_shared_rsp_ax;
  logic [863:0] fp_shared_env_image;
  logic [863:0] fp_shared_store_data_q;
  logic [7:0]   fp_shared_store_bytes_q;
  logic [639:0] fp_shared_st_flat;
  logic         fp_shared_admin;

  // env_tmp holds dwords for the 32-bit form and right-justified words for the
  // 16-bit form.  Repack to the command contract's byte-contiguous image.
  always_comb begin
    fp_shared_env_image = '0;
    if (q_f_mbytes == 4'd2) begin
      for (int wi = 0; wi < 47; wi++)
        fp_shared_env_image[wi*16 +: 16] = env_tmp[wi][15:0];
    end else begin
      for (int di = 0; di < 27; di++)
        fp_shared_env_image[di*32 +: 32] = env_tmp[di];
    end
  end

  always_comb begin
    fp_shared_admin = (q_fxop==FX_FNINIT) || (q_fxop==FX_FNCLEX) ||
                      (q_fxop==FX_FNSTCW) || (q_fxop==FX_FNSTSW_M) ||
                      (q_fxop==FX_FLDCW) || (q_fxop==FX_FWAIT) ||
                      (q_fxop==FX_FNSTENV) || (q_fxop==FX_FLDENV) ||
                      (q_fxop==FX_FNSAVE) || (q_fxop==FX_FRSTOR);
  end

  assign fp_shared_cmd_valid = (state == S_FEXEC);

  ven_fp_top u_fp_shared (
    .clk(clk), .rst_n(rst_n),
`ifdef VEN_SNAPSHOT_RESTORE
    .init_restore(snapshot_restore && !boot_mode),
    .init_top(snapshot_ftop), .init_status(snapshot_fstat),
    .init_control(snapshot_fctrl), .init_tag(snapshot_fptag),
    .init_fip(snapshot_fip), .init_fcs(snapshot_fcs),
    .init_fdp(snapshot_fdp), .init_fds(snapshot_fds),
    .init_regs_phys(snapshot_fpr_flat),
`endif
    .cmd_valid(fp_shared_cmd_valid), .cmd_ready(fp_shared_cmd_ready),
    .cmd_accept_retire(fp_shared_accept_retire),
    .cmd_op(q_fxop), .cmd_aluop(q_f_aluop), .cmd_sti(q_f_sti),
    .cmd_pop(q_f_pop), .cmd_constant(q_f_const), .cmd_mem(f_mem80),
    .cmd_mem_bytes(q_f_mbytes), .cmd_fdiv_bug(errata_en[0]),
    .cmd_fist_bug(errata_en[1]), .cmd_env16(q_f_mbytes == 4'd2),
    .cmd_real_mode(real_mode), .cmd_env_image(fp_shared_env_image),
    .cmd_update_fip(!fp_shared_admin), .cmd_fip(q_pc), .cmd_fcs(SEG_CS),
    .cmd_update_fdp(!fp_shared_admin && (q_f_mem_read || q_f_mem_write)),
    .cmd_fdp(dbase + q_ea), .cmd_fds(SEG_DS),
    .busy(fp_shared_busy), .rsp_valid(fp_shared_rsp_valid),
    .rsp_unsupported(fp_shared_rsp_unsupported),
    .rsp_stack_fault(fp_shared_rsp_stack_fault), .rsp_arith(fp_shared_rsp_arith),
    .rsp_store_valid(fp_shared_rsp_store_valid),
    .rsp_store_data(fp_shared_rsp_store_data),
    .rsp_store_bytes(fp_shared_rsp_store_bytes),
    .rsp_ax_valid(fp_shared_rsp_ax_valid), .rsp_ax(fp_shared_rsp_ax),
    .ftop_o(ftop), .fstat_o(fstat), .fctrl_o(fctrl), .fptag_o(fptag),
    .fip_o(fip), .fcs_o(fcs), .fdp_o(fdp), .fds_o(fds),
    .fpr_phys_flat_o(fpr_flat), .st_flat_o(fp_shared_st_flat)
  );

  for (genvar fp_si = 0; fp_si < 8; fp_si++) begin : g_fp_shared_st
    assign fp_st[fp_si] = fp_shared_st_flat[fp_si*80 +: 80];
  end
  assign fp_st0_phys = fp_st[0];

  // The legacy writeback and its fast/iterative handshakes have no producer in
  // this profile.  Tie their remaining control consumers inert; the old engines
  // consequently have no externally observable fanout and are pruned by synth.
  always_comb begin
    fp_stk_ovf = 1'b0; fp_stk_unf = 1'b0;
    fp_div_elig = 1'b0; fp_sqrt_elig = 1'b0;
    fp_iter_go = 1'b0; fp_iter_done = 1'b0;
    eng_div_a = '0; eng_div_b = '0; eng_sqrt_in = '0; eng_rc = '0;
    eng_div_start = 1'b0; eng_sqrt_start = 1'b0;
`ifdef VEN_FP_PIPE
    fp_pipe_cap = 1'b0; fp_cap_aluop = '0; fp_cap_dst = '0;
    fp_cap_a = '0; fp_cap_b = '0; fp_cap_rc = '0; fp_cap_pc = '0;
    fp_cap_err = 1'b0; fp_cap_stkflt = 1'b0; fp_pipe_rd_haz = 1'b0;
`ifdef VEN_FP_PIPE2
    fp_s1_next = '0;
`endif
`endif
  end
`else
  // x87 FP WRITE-DRIVER — the big combinational state-mutation driver, extracted
  // VERBATIM to core/fpu_writeback.sv (R3). It reads the decode latch / fpu_top
  // readback / engine results and drives every fp_we_* / fp_*_data write port +
  // the iterative-engine handshake. Behaviour-identical to the inline always_comb
  // it replaced (refactor gate: fingerprint byte-identical). Ports connect to the
  // same-named core.sv wires (declared just above) that feed u_fpu_state below.
  fpu_writeback #(
    .SEG_CS (SEG_CS),
    .SEG_DS (SEG_DS)
  ) u_fpu_wb (
    // ---- inputs ----
    .state            (state),
    .errata_en        (errata_en),
    .u_d              (u_d),
    .v_d              (v_d),
    .q_fxop           (q_fxop),
    .q_f_mem_read     (q_f_mem_read),
    .q_f_mem_write    (q_f_mem_write),
    .q_f_mbytes       (q_f_mbytes),
    .q_f_pop          (q_f_pop),
    .q_f_sti          (q_f_sti),
    .q_f_aluop        (q_f_aluop),
    .q_f_const        (q_f_const),
    .q_pc             (q_pc),
    .q_ea             (q_ea),
    .dbase            (dbase),
    .mem_ack          (mem_ack),
    .mem_rdata        (mem_rdata),
    .f_mem80          (f_mem80),
    .f_step           (f_step),
    .f_seq_step       (f_seq_step),
    .fp_stk_ovf       (fp_stk_ovf),
    .fp_stk_unf       (fp_stk_unf),
    .fp_flt_i         (fp_flt_q),
    .fp_flt_ovf_i     (fp_flt_ovf_q),
    .fenv_last        (fenv_last),
    .env_tmp          (env_tmp),
    .fp_st            (fp_st),
    .ftop             (ftop),
    .fctrl            (fctrl),
    .fstat            (fstat),
    .fptag            (fptag),
    .xlate_miss       (xlate_miss),
    .issue_block      (fp_issue_block),
    .stall_cnt        (stall_cnt),
    .pipe_bytes_ok    (pipe_bytes_ok),
    .pending_mem_pen  (pending_mem_pen),
    .v_bytes_ok       (v_bytes_ok),
    .pair_block       (dbg_pair_block),
    .core_cyc         (core_cyc),
    .fp_ready_cyc     (fp_ready_cyc),
    .fp_occ_pending   (fp_occ_pending),
    .fstore_ie        (fstore_ie),
    .fstore_pe        (fstore_pe),
    .fstore_oe        (fstore_oe),
    .fstore_ue        (fstore_ue),
`ifdef VEN_FP_OVERLAP
    .fp_busy_cyc      (fp_busy_cyc),
`endif
    .eng_div_done     (eng_div_done),
    .eng_div_result   (eng_div_result),
    .eng_sqrt_done    (eng_sqrt_done),
    .eng_sqrt_result  (eng_sqrt_result),
    .eng_bcd_done     (eng_bcd_done),
    .eng_bcd_result   (eng_bcd_result),
    .eng_fbld_done    (eng_fbld_done),
    .eng_fbld_result  (eng_fbld_result),
    .eng_trsc_done    (eng_trsc_done),
    .eng_trsc_result  (eng_trsc_result),
    .eng_trsc_pe      (eng_trsc_pe),
    .eng_trsc_ie      (eng_trsc_ie),
    .eng_trsc_c2      (eng_trsc_c2),
`ifdef VEN_TRANSCENDENTAL
    .eng_fs_sin       (eng_fs_sin),
    .eng_fs_cos       (eng_fs_cos),
`endif
    .eng_fprem_done   (eng_fprem_done),
    .eng_fprem_c2     (eng_fprem_c2),
    .eng_fprem_ie     (eng_fprem_ie),
    .eng_fprem_result (eng_fprem_result),
    .eng_fprem_q012   (eng_fprem_q012),
`ifdef VEN_FP_PIPE
    .fpp_valid        (fpp_valid),
    .fpp_aluop        (fpp_aluop),
    .fpp_a            (fpp_a),
    .fpp_b            (fpp_b),
    .fpp_rc           (fpp_rc),
    .fpp_pc           (fpp_pc),
    .fpp_err          (fpp_err),
    .fpp_dst          (fpp_dst),
    .fpp_stkflt       (fpp_stkflt),   // R2-H06
`ifdef VEN_FP_PIPE2
    .fpp2_valid       (fpp2_valid),
    .fpp2_s1          (fpp2_s1),
    .fpp2_rc          (fpp2_rc),
    .fpp2_pc          (fpp2_pc),
    .fpp2_dst         (fpp2_dst),
    .fpp2_stkflt      (fpp2_stkflt),   // R2-H06
`endif
`endif
`ifdef VEN_FPTRAP
    .fptrap_resp_valid(fptrap_resp_valid),
    .fptrap_result    (fptrap_result),
`ifdef VEN_FP_PS_ALL
    .fptrap_res1      (fptrap_res1),
    .fptrap_res_fstat (fptrap_res_fstat),
    .fptrap_action    (fptrap_action),
    .fptrap_sti       (q_f_sti),
`endif
`endif
    // ---- outputs ----
    .fp_we_push       (fp_we_push),
    .fp_push_data     (fp_push_data),
    .fp_we_top        (fp_we_top),
    .fp_top_data      (fp_top_data),
    .fp_we_fstat      (fp_we_fstat),
    .fp_fstat_wval    (fp_fstat_wval),
    .fp_we_sti        (fp_we_sti),
    .fp_wsti_idx      (fp_wsti_idx),
    .fp_wsti_data     (fp_wsti_data),
    .fp_wsti_clr_tag  (fp_wsti_clr_tag),
    .fp_we_fxch       (fp_we_fxch),
    .fp_fxch_idx      (fp_fxch_idx),
    .fp_fxch_a        (fp_fxch_a),
    .fp_fxch_b        (fp_fxch_b),
    .fp_we_pop        (fp_we_pop),
    .fp_we_pop2       (fp_we_pop2),
    .fp_we_ffree      (fp_we_ffree),
    .fp_ffree_idx     (fp_ffree_idx),
    .fp_we_incstp     (fp_we_incstp),
    .fp_we_decstp     (fp_we_decstp),
    .fp_we_fctrl      (fp_we_fctrl),
    .fp_fctrl_wval    (fp_fctrl_wval),
    .fp_we_fninit     (fp_we_fninit),
    .fp_div_elig      (fp_div_elig),
    .fp_sqrt_elig     (fp_sqrt_elig),
    .fp_iter_go       (fp_iter_go),
    .fp_iter_done     (fp_iter_done),
    .eng_div_a        (eng_div_a),
    .eng_div_b        (eng_div_b),
    .eng_sqrt_in      (eng_sqrt_in),
    .eng_rc           (eng_rc),
    .eng_div_start    (eng_div_start),
    .eng_sqrt_start   (eng_sqrt_start),
    .fp_we_eptr       (fp_we_eptr),
    .fp_eptr_fip      (fp_eptr_fip),
    .fp_eptr_fcs      (fp_eptr_fcs),
    .fp_we_dptr       (fp_we_dptr),
    .fp_eptr_fdp      (fp_eptr_fdp),
    .fp_eptr_fds      (fp_eptr_fds),
    .fp_we_envld      (fp_we_envld),
    .fp_env_fctrl     (fp_env_fctrl),
    .fp_env_ftop      (fp_env_ftop),
    .fp_env_fstat     (fp_env_fstat),
    .fp_env_fptag     (fp_env_fptag),
    .fp_we_envregs    (fp_we_envregs),
    .fp_env_fpr_flat  (fp_env_fpr_flat),
    .fp_we_wabs       (fp_we_wabs),
    .fp_we_wabs_fstat (fp_we_wabs_fstat),
    .fp_wabs_idx      (fp_wabs_idx),
    .fp_wabs_data     (fp_wabs_data),
    .fp_wabs_fstat    (fp_wabs_fstat)
`ifdef VEN_FP_PIPE
    ,
    .fp_pipe_cap      (fp_pipe_cap),
    .fp_cap_aluop     (fp_cap_aluop),
    .fp_cap_dst       (fp_cap_dst),
    .fp_cap_a         (fp_cap_a),
    .fp_cap_b         (fp_cap_b),
    .fp_cap_rc        (fp_cap_rc),
    .fp_cap_pc        (fp_cap_pc),
    .fp_cap_err       (fp_cap_err),
    .fp_cap_stkflt    (fp_cap_stkflt),   // R2-H06
    .fp_pipe_rd_haz   (fp_pipe_rd_haz)
`ifdef VEN_FP_PIPE2
    ,
    .fp_s1_next       (fp_s1_next)
`endif
`endif
  );

  fpu_top u_fpu_state (
    .clk          (clk),
    .rst_n        (rst_n),
`ifdef VEN_SNAPSHOT_RESTORE
    .init_restore (snapshot_restore && !boot_mode),
    .init_ftop    (snapshot_ftop),
    .init_fstat   (snapshot_fstat),
    .init_fctrl   (snapshot_fctrl),
    .init_fptag   (snapshot_fptag),
    .init_fip     (snapshot_fip),
    .init_fcs     (snapshot_fcs),
    .init_fdp     (snapshot_fdp),
    .init_fds     (snapshot_fds),
    .init_fpr_flat(snapshot_fpr_flat),
`endif
    .st0          (fp_st[0]),
    .st1          (fp_st[1]),
    .st2          (fp_st[2]),
    .st3          (fp_st[3]),
    .st4          (fp_st[4]),
    .st5          (fp_st[5]),
    .st6          (fp_st[6]),
    .st7          (fp_st[7]),
    .ftop_o       (ftop),
    .fstat_o      (fstat),
    .fctrl_o      (fctrl),
    .fptag_o      (fptag),
    .rd_phys_top  (fp_st0_phys),
    .we_push      (fp_we_push),
    .push_data    (fp_push_data),
    .we_top       (fp_we_top),
    .top_data     (fp_top_data),
    .we_fstat     (fp_we_fstat),
    .fstat_wval   (fp_fstat_wval),
    .we_sti       (fp_we_sti),
    .wsti_idx     (fp_wsti_idx),
    .wsti_data    (fp_wsti_data),
    .wsti_clr_tag (fp_wsti_clr_tag),
    .we_fxch      (fp_we_fxch),
    .fxch_idx     (fp_fxch_idx),
    .fxch_a       (fp_fxch_a),
    .fxch_b       (fp_fxch_b),
    .we_pop       (fp_we_pop),
    .we_pop2      (fp_we_pop2),
    .we_ffree     (fp_we_ffree),
    .ffree_idx    (fp_ffree_idx),
    .we_incstp    (fp_we_incstp),
    .we_decstp    (fp_we_decstp),
    .we_fctrl     (fp_we_fctrl),
    .fctrl_wval   (fp_fctrl_wval),
    .we_fninit    (fp_we_fninit),
    .we_eptr      (fp_we_eptr),
    .eptr_fip     (fp_eptr_fip),
    .eptr_fcs     (fp_eptr_fcs),
    .we_dptr      (fp_we_dptr),
    .dptr_fdp     (fp_eptr_fdp),
    .dptr_fds     (fp_eptr_fds),
    .fip_o        (fip),
    .fcs_o        (fcs),
    .fdp_o        (fdp),
    .fds_o        (fds),
    .fpr_flat_o   (fpr_flat),
    .we_envld     (fp_we_envld),
    .env_fctrl    (fp_env_fctrl),
    .env_ftop     (fp_env_ftop),
    .env_fstat    (fp_env_fstat),
    .env_fptag    (fp_env_fptag),
    .we_envregs   (fp_we_envregs),
    .env_fpr_flat (fp_env_fpr_flat),
    // +VEN_FP_PIPE deferred-arith commit port (inert / tied 0 when not piped).
    .we_wabs      (fp_we_wabs),
    .wabs_idx     (fp_wabs_idx),
    .wabs_data    (fp_wabs_data),
    .we_wabs_fstat(fp_we_wabs_fstat),
    .wabs_fstat   (fp_wabs_fstat)
  );
`endif

  // FPREM/FPREM1 (D9 F8 / F5) engine handshake. Under VEN_SRT_ITER the UNIFIED
  // fpu_srt_div handles remainder (folded in); otherwise the dedicated fpu_fprem
  // serves the combinational config. Declared once here; one driver per config.
  logic        eng_fprem_start, eng_fprem_busy, eng_fprem_done, eng_fprem_c2, eng_fprem_ie;
  logic [79:0] eng_fprem_result;
  logic [2:0]  eng_fprem_q012;
`ifdef VEN_FP_SHARED
  // ven_fp_top owns the only remainder service in the shared profile.  Keeping
  // the legacy request live would elaborate a second SRT engine, defeating the
  // area objective even though its result has no architectural consumer.
  assign eng_fprem_start = 1'b0; assign eng_fprem_busy = 1'b0;
  assign eng_fprem_done  = 1'b0; assign eng_fprem_result = 80'd0;
  assign eng_fprem_q012  = 3'd0; assign eng_fprem_c2 = 1'b0; assign eng_fprem_ie = 1'b0;
`elsif VEN_FPREM
  assign eng_fprem_start = (state==S_FEXEC) && (q_fxop==FX_FPREM || q_fxop==FX_FPREM1);
`else
  assign eng_fprem_start = 1'b0; assign eng_fprem_busy = 1'b0;
  assign eng_fprem_done  = 1'b0; assign eng_fprem_result = 80'd0;
  assign eng_fprem_q012  = 3'd0; assign eng_fprem_c2 = 1'b0; assign eng_fprem_ie = 1'b0;
`endif

`ifdef VEN_SRT_ITER
`ifdef VEN_FP_SHARED
  // Do not instantiate the pre-shared core SRT service beside ven_fp_top.u_srt.
  // The adapter holds S_FEXEC until the shared completion, so these legacy
  // completion wires are intentionally inert rather than a second producer.
  assign eng_div_busy=1'b0;  assign eng_div_done=1'b0;  assign eng_div_result='0;
  assign eng_sqrt_busy=1'b0; assign eng_sqrt_done=1'b0; assign eng_sqrt_result='0;
`else
  // iterative SRT FDIV / FSQRT engines — the FPGA-synthesizable multi-cycle form
  // of fx_srt_div / fx_sqrt. Started from S_FEXEC for normal-operand divides /
  // +normal sqrts; their {inexact,result} commits in S_FP_BUSY (fp_we_* driver).
  // buggy-PLA select mirrors the compile-time VEN_SRT_FDIV_BUG (== fx_div default).
  `ifdef VEN_SRT_FDIV_BUG
  localparam logic ENG_DIV_BUGGY = 1'b1;
  `else
  localparam logic ENG_DIV_BUGGY = 1'b0;
  `endif
  // UNIFIED FDIV: one engine does divide AND square-root (Pentium FDIV section).
  // div and sqrt are mutually exclusive (blocking FP), so the single busy/done/
  // result fan out to both handshakes; fp_iter_done picks by q_fxop. mode/a are
  // muxed at the (one-cycle) start pulse, which the engine latches.
  // div/sqrt/rem are mutually exclusive blocking FP ops -> the single engine's
  // busy/done/result fan out to every handshake; the consuming FSM state picks the
  // matching one. mode/a/b/prem1 are muxed at the one-cycle start pulse.
  logic [1:0]  eng_u_mode;
  logic        eng_u_start, eng_u_busy, eng_u_done, eng_u_prem1, eng_u_rem_go;
  logic [79:0] eng_u_a, eng_u_b;
  logic [82:0] eng_u_result;
`ifdef VEN_FPREM
  assign eng_u_rem_go = eng_fprem_start;
  assign eng_u_prem1  = (q_fxop==FX_FPREM1);
`else
  assign eng_u_rem_go = 1'b0;
  assign eng_u_prem1  = 1'b0;
`endif
  assign eng_u_start = eng_div_start || eng_sqrt_start || eng_u_rem_go;
  assign eng_u_mode  = eng_u_rem_go ? 2'd2 : (eng_sqrt_start ? 2'd1 : 2'd0);
  assign eng_u_a     = eng_u_rem_go ? fst(3'd0) : (eng_sqrt_start ? eng_sqrt_in : eng_div_a);
  assign eng_u_b     = eng_u_rem_go ? fst(3'd1) : eng_div_b;
  // The remainder sideband lands on private wires; eng_fprem_q012/c2/ie are
  // driven exactly once per configuration (below under VEN_FPREM, or the
  // tie-off where the handshake is declared) -- connecting the engine pins
  // straight to the handshake nets made them multiply driven in the
  // VEN_SRT_ITER-without-VEN_FPREM configuration.
  logic [2:0] srt_rem_q012;
  logic       srt_rem_c2, srt_rem_ie;
  fpu_srt_div u_srt_div (
    .clk(clk), .rst_n(rst_n), .start(eng_u_start), .mode(eng_u_mode),
    .prem1(eng_u_prem1), .a(eng_u_a), .b(eng_u_b), .rc(eng_rc), .pc(fctrl[9:8]), .buggy(ENG_DIV_BUGGY),
    .busy(eng_u_busy), .done(eng_u_done), .result(eng_u_result),
    .rem_q012(srt_rem_q012), .rem_c2(srt_rem_c2), .rem_ie(srt_rem_ie)
  );
  assign eng_div_busy   = eng_u_busy;   assign eng_sqrt_busy   = eng_u_busy;
  assign eng_div_done   = eng_u_done;   assign eng_sqrt_done   = eng_u_done;
  assign eng_div_result = eng_u_result; assign eng_sqrt_result = eng_u_result;
`ifdef VEN_FPREM
  assign eng_fprem_busy   = eng_u_busy;
  assign eng_fprem_done   = eng_u_done;
  assign eng_fprem_result = eng_u_result[79:0];
  assign eng_fprem_q012   = srt_rem_q012;
  assign eng_fprem_c2     = srt_rem_c2;
  assign eng_fprem_ie     = srt_rem_ie;
`endif
`endif
`else
  assign eng_div_busy=1'b0;  assign eng_div_done=1'b0;  assign eng_div_result='0;
  assign eng_sqrt_busy=1'b0; assign eng_sqrt_done=1'b0; assign eng_sqrt_result='0;
`endif

`ifdef VEN_DBG_WD
  // [VEN-STALL] hang detector: if the core retires NOTHING for 20000 cycles it is
  // wedged. Log state + FPU handshake so an FDIVP/FSQRT wedge (the HW Quake hang at
  // cs=00a7:0x4532d) is diagnosable: state=S_FP_BUSY + eng_div_busy tells the mode.
  logic [19:0] dbg_stall_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) dbg_stall_cnt <= 20'd0;
    else if (retire_valid) dbg_stall_cnt <= 20'd0;
    else begin
      dbg_stall_cnt <= dbg_stall_cnt + 20'd1;
      if (dbg_stall_cnt == 20'd20000)
        $display("[VEN-STALL] no-retire 20000cyc: state=%s cs=%04x eip=%08h q_fxop=%0d fp_div_elig=%b fp_iter_go=%b fp_iter_done=%b eng_div_busy=%b eng_div_done=%b",
                 state.name(), seg_sel[SG_CS], eip, q_fxop, fp_div_elig, fp_iter_go, fp_iter_done, eng_div_busy, eng_div_done);
    end
  end
`endif

  // --- iterative integer DIV/IDIV engine (VEN_IDIV_ITER) -------------------
  // The FPGA-synthesizable multi-cycle form of the native '/'/'%' in
  // core_exec.svh's K_MULDIV DIV/IDIV arms. Started from S_EXEC for DIV/IDIV
  // (q_md 6/7); the FSM waits in S_DIV_BUSY and commits EAX/EDX + #DE on `done`.
  logic        eng_int_start, eng_int_signed;
  logic [2:0]  eng_int_w;
  logic [63:0] eng_int_num;
  logic [31:0] eng_int_den;
  logic        eng_int_busy, eng_int_done, eng_int_derr;
  logic [31:0] eng_int_quot, eng_int_rem;
  // Divide-#DE tap: latch the engine's operands at issue (they are combinational +
  // stale by S_DIV_BUSY), snapshot them to the dbg_de_* outputs when the #DE fires.
  logic [63:0] dbg_de_num_r;   // dividend latched at the divide START
  logic [31:0] dbg_de_den_r;   // divisor
  logic [2:0]  dbg_de_w_r;     // width (1/2/4)
  logic [31:0] dbg_de_eip_r;   // the divide's EIP
  logic [12:0] dbg_de_cnt_r;   // running count of divide #DEs
`ifdef VEN_IDIV_ITER
  always_comb begin
    logic [31:0] srcv_drv;
    eng_int_start=1'b0; eng_int_signed=1'b0; eng_int_w=q_w;
    eng_int_num=64'd0; eng_int_den=32'd0;
    srcv_drv = q_mem_read ? wmask(mem_load_data, q_w) : reg_read(q_src_reg, q_w, q_src_high8);
    if (state==S_EXEC && q_kind==K_MULDIV && (q_md==3'd6 || q_md==3'd7)) begin
      eng_int_start  = 1'b1;
      eng_int_signed = (q_md==3'd7);
      eng_int_w      = q_w;
      eng_int_num    = (q_w==3'd1) ? {48'd0, gpr_o[R_EAX][15:0]} :
                       (q_w==3'd2) ? {32'd0, gpr_o[R_EDX][15:0], gpr_o[R_EAX][15:0]} :
                                     {gpr_o[R_EDX], gpr_o[R_EAX]};
      eng_int_den    = srcv_drv;
    end
  end
  ven_idiv u_idiv (
    .clk(clk), .rst_n(rst_n), .start(eng_int_start), .is_signed(eng_int_signed),
    .w(eng_int_w), .dividend(eng_int_num), .divisor(eng_int_den),
    .busy(eng_int_busy), .done(eng_int_done),
    .quotient(eng_int_quot), .remainder(eng_int_rem), .derr(eng_int_derr)
  );
`else
  always_comb begin
    eng_int_start=1'b0; eng_int_signed=1'b0; eng_int_w=3'd0;
    eng_int_num=64'd0;  eng_int_den=32'd0;
  end
  assign eng_int_busy=1'b0; assign eng_int_done=1'b0; assign eng_int_derr=1'b0;
  assign eng_int_quot=32'd0; assign eng_int_rem=32'd0;
`endif

  // --- iterative FP->packed-BCD (FBSTP) engine (VEN_BCD_ITER) --------------
  // The 18-chained-/10 fx_fx_to_bcd was the core's worst timing path. On FBSTP,
  // run the engine (started in S_FEXEC), wait in S_BCD_BUSY, latch the BCD store
  // value (fbcd_result_q) + defer the fstat sticky to the engine-done clock.
  logic        eng_bcd_start, eng_bcd_busy, eng_bcd_done;
  logic [81:0] eng_bcd_result;
  logic [81:0] fbcd_result_q;       // latched {ie,pe,bcd} store value
  // ONE suppression decision for a store with an UNMASKED stack fault, shared by
  // the S_FEXEC state transition (core_fp_exec.svh), the PS store-trap request,
  // and the BCD engine start: the operation retires suppressed and NOTHING may
  // launch -- a background engine run would complete AFTER the suppressed
  // retire, and a second FBSTP within its ~60-cycle window would consume the
  // stale result.
  wire fp_store_suppressed = (fp_stk_ovf || fp_stk_unf) && !fctrl[0];
`ifdef VEN_FP_PS_ALL
  // FP_PS_ALL store-after-trap: the floatx80->m32/m64/int/BCD narrowing CONVERSION
  // (fx_to_f32_ex / fx_to_f64_ex / fx_to_int_ex / fx_fx_to_bcd) is a deep combinational
  // cone that, with the rest of the x87 compute logic gated out, became the lone long
  // pole (fpr_reg -> dc_line_reg, ~356 logic levels of un-shared mantissa normalize/
  // round). Under FP_PS_ALL we PS-TRAP these narrowing stores too: the A53 computes the
  // converted bytes (SoftFloat extF80) and writes them back in fptrap_result (low bits)
  // + the status word in fptrap_res_fstat. The core latches them here and drives the
  // S_FSTORE bus from the REGISTER, so the conversion never sits on the PL store path.
  logic [79:0] f_trap_store_q;      // latched PS-converted store bytes (m32/m64/int/BCD)
  // is the in-flight x87 op a PS-trapped NARROWING STORE (vs a compute op that retires)?
  // keyed off q_fxop (registered from decode, stable across S_FPTRAP_WAIT). FST m80 /
  // FNSTCW / FNSTSW m16 are EXACT (no conversion) -> stay in PL, NOT trapped.
  wire f_ps_store_trap = (q_fxop==FX_FST_M32)  || (q_fxop==FX_FST_M64)  ||
                         (q_fxop==FX_FIST_M16) || (q_fxop==FX_FIST_M32) ||
                         (q_fxop==FX_FIST_M64) || (q_fxop==FX_FBSTP);
  // FP_PS_ALL load-after-trap: the m32/m64/int -> floatx80 WIDENING conversion
  // (f_mem_as_float / f_mem_as_int -> fx_from_f32/f64/int) was the next worst SETUP
  // cone once the stores were trapped (f_mem80_reg -> u_fpu_state/fpr_reg, ~74 logic
  // levels). PS-TRAP these loads too: the A53 converts f_mem80 (exported as fptrap_mem)
  // to extF80 and returns it in fptrap_result; the generalized trap-commit pushes it
  // (action A_PUSH). FLD m80 is EXACT (no conversion) -> stays in PL, NOT trapped.
  // FLDCONST (ROM const) and FLD ST(i) (reg copy) are likewise not memory-widening.
  // FBLD (packed-BCD m80 -> floatx80) is ALSO a widening load. Under FP_PS_ALL the build
  // STRIPS VEN_BCD_ITER (impl_kv260_soc.tcl), so FBLD would fall back to the COMBINATIONAL
  // fx_bcd_to_fx (the 18-chained-*10 BCD->float cone — ~69 logic levels / 39 CARRY8,
  // f_mem80_reg -> u_fpu_state/fpr_reg) which post-route is the WORST setup pole, starving
  // hold-fix. Trap it too: the PS converts the packed BCD to extF80 (action A_PUSH).
  wire f_ps_load_trap  = (q_fxop==FX_FLD_M32)  || (q_fxop==FX_FLD_M64)  ||
                         (q_fxop==FX_FILD_M16) || (q_fxop==FX_FILD_M32) ||
                         (q_fxop==FX_FILD_M64) || (q_fxop==FX_FBLD);
`endif
  // FBLD (packed-BCD m80 -> floatx80): the 18-chained-*10 fx_bcd_to_fx was the
  // core's worst LOGIC path once the FP arith was pipelined. Run the iterative
  // engine (started in S_FEXEC), wait in S_FBLD_BUSY, then push the result + retire.
  logic        eng_fbld_start, eng_fbld_busy, eng_fbld_done;
  logic [79:0] eng_fbld_result;
`ifdef VEN_BCD_ITER
`ifdef VEN_FP_SHARED
  // The shared shell contains its own BCD load/store sequencers.  Explicitly
  // tie off the historical pair so no duplicate decimal datapath survives a
  // conservative synthesis pass.
  assign eng_bcd_start=1'b0; assign eng_bcd_busy=1'b0; assign eng_bcd_done=1'b0;
  assign eng_bcd_result=82'd0;
  assign eng_fbld_start=1'b0; assign eng_fbld_busy=1'b0; assign eng_fbld_done=1'b0;
  assign eng_fbld_result=80'd0;
`else
  assign eng_bcd_start = (state==S_FEXEC) && (q_fxop==FX_FBSTP) && !fp_store_suppressed;
`ifndef SYNTHESIS
  // a suppressed store must never launch the engine; the start count is
  // observable so the back-to-back FBSTP case can prove exactly one accepted
  // start per valid op (zero for the suppressed one).
  int ven_bcd_starts; logic ven_bcdlog_en;
  initial begin ven_bcdlog_en = $test$plusargs("ven_bcdlog") != 0; ven_bcd_starts = 0; end
  always_ff @(posedge clk) begin
    if (rst_n && eng_bcd_start) ven_bcd_starts <= ven_bcd_starts + 1;
    if (rst_n && fp_store_suppressed && (state==S_FEXEC)
        && (eng_bcd_start || eng_fbld_start))
      $error("FPU/SUPPRESS: an iterative engine launched for a suppressed x87 store");
  end
  final if (ven_bcdlog_en) $display("[BCDLOG] ven_bcd engine starts: %0d", ven_bcd_starts);
`endif
  ven_bcd u_bcd (
    .clk(clk), .rst_n(rst_n), .start(eng_bcd_start),
    .v(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_bcd_busy), .done(eng_bcd_done), .result(eng_bcd_result)
  );
  assign eng_fbld_start = (state==S_FEXEC) && (q_fxop==FX_FBLD);
  ven_bcd_to_fp u_bcd2fp (
    .clk(clk), .rst_n(rst_n), .start(eng_fbld_start),
    .bcd(f_mem80),
    .busy(eng_fbld_busy), .done(eng_fbld_done), .result(eng_fbld_result)
  );
`endif
`else
  assign eng_bcd_start=1'b0; assign eng_bcd_busy=1'b0; assign eng_bcd_done=1'b0;
  assign eng_bcd_result=82'd0;
  assign eng_fbld_start=1'b0; assign eng_fbld_busy=1'b0; assign eng_fbld_done=1'b0;
  assign eng_fbld_result=80'd0;
`endif

  // --- iterative x87 transcendental engine (F2XM1, #11; VEN_TRANSCENDENTAL) ---
  // Started in S_FEXEC on FX_F2XM1, busy-wait in S_TRSC_BUSY, commit ST0 +
  // fstat PE/IE on `done`. Bit-exact vs qemu helper_f2xm1 (verif/trsc gate). The
  // engine is dual-mode-ready (SILICON param) but F2XM1's qemu algorithm is the
  // accuracy-faithful one, so both modes share the datapath.
  logic        eng_trsc_done;
  logic [79:0] eng_trsc_result;
  logic        eng_trsc_pe, eng_trsc_ie, eng_trsc_c2;
`ifdef VEN_TRANSCENDENTAL
  // F2XM1 (unary, in-place ST0) + FPATAN (ST1=y/ST0=x, result->ST1 then pop) each
  // get their own engine; S_TRSC_BUSY waits on whichever q_fxop selected.
  logic        eng_f2_start, eng_f2_busy, eng_f2_done, eng_f2_pe, eng_f2_ie;
  logic [79:0] eng_f2_result;
  logic        eng_fa_start, eng_fa_busy, eng_fa_done, eng_fa_pe, eng_fa_ie;
  logic [79:0] eng_fa_result;
  logic        eng_fy_start, eng_fy_busy, eng_fy_done, eng_fy_pe, eng_fy_ie;
  logic [79:0] eng_fy_result;
  // FPATAN is ALWAYS synthesized — Quake's only transcendental (PROGRESS.md M11).
`ifndef VEN_FP_SHARED
  assign eng_fa_start = (state==S_FEXEC) && (q_fxop==FX_FPATAN);
  fpu_fpatan u_fpatan (
    .clk(clk), .rst_n(rst_n), .start(eng_fa_start),
    .y(fst(3'd1)), .x(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_fa_busy), .done(eng_fa_done), .result(eng_fa_result),
    .inexact(eng_fa_pe), .invalid(eng_fa_ie)
  );
`endif
  // FSIN/FCOS engine decls (referenced by the result mux regardless of gating).
  logic        eng_fs_start, eng_fs_busy, eng_fs_done, eng_fs_c2;
  logic [79:0] eng_fs_sin, eng_fs_cos;
  wire is_trig = (q_fxop==FX_FSIN) || (q_fxop==FX_FCOS) ||
                 (q_fxop==FX_FSINCOS) || (q_fxop==FX_FPTAN);
`ifdef VEN_FP_SHARED
  // ven_fp_top owns the one shared transcendental sequencer (and routes every
  // arithmetic step through its common ALU/widemul/SRT services).  The legacy
  // four-engine bank below is otherwise reachable solely through the old
  // S_TRSC_BUSY producer, which the shared command/response path never enters.
  // Tie every historical handshake off explicitly instead of relying on a
  // whole-hierarchy prune: the latter retained the engines in the FPGA netlist
  // through conservative cross-module optimization and erased the area win.
  assign eng_f2_start=1'b0; assign eng_f2_busy=1'b0; assign eng_f2_done=1'b0;
  assign eng_f2_pe=1'b0;    assign eng_f2_ie=1'b0;   assign eng_f2_result=80'd0;
  assign eng_fa_start=1'b0; assign eng_fa_busy=1'b0; assign eng_fa_done=1'b0;
  assign eng_fa_pe=1'b0;    assign eng_fa_ie=1'b0;   assign eng_fa_result=80'd0;
  assign eng_fy_start=1'b0; assign eng_fy_busy=1'b0; assign eng_fy_done=1'b0;
  assign eng_fy_pe=1'b0;    assign eng_fy_ie=1'b0;   assign eng_fy_result=80'd0;
  assign eng_fs_start=1'b0; assign eng_fs_busy=1'b0; assign eng_fs_done=1'b0;
  assign eng_fs_c2=1'b0;    assign eng_fs_sin=80'd0; assign eng_fs_cos=80'd0;
  assign eng_trsc_done=1'b0; assign eng_trsc_result=80'd0;
  assign eng_trsc_pe=1'b0;   assign eng_trsc_ie=1'b0; assign eng_trsc_c2=1'b0;
`else
  // ---- PER-ENGINE synthesis control (FPGA fit) --------------------------------
  // DEFAULT: all four engines are built (that is what the cosim and `make verify`
  // compile, so they stay byte-identical). On the XCZU15EG all four land ~95% LUT,
  // so each OPTIONAL engine can be tied off INDIVIDUALLY when area demands it.
  // Executing a tied-off opcode stalls S_TRSC_BUSY forever (no `done`) — the wedge
  // signature is st=17 in the PC ring — so only tie off an engine the guest
  // provably never executes:
  //   VEN_TRANS_NO_TRIG   -> fsincos (FSIN/FCOS/FSINCOS/FPTAN)
  //       HW-PROVEN NEEDED: Quake's libm sin() wedged at cs:eip=00a7:0004ed3c
  //       (UPDATE 202). Do NOT set for a Quake/Win95 build.
  //   VEN_TRANS_NO_FYL2X  -> fyl2x/fyl2xp1 (log/log2)
  //       HW-PROVEN NEEDED: Quake's libm log() wedged at 0x52512, the FYL2X after
  //       an ftst/fnstsw/sahf/jbe domain guard (UPDATE 203). Do NOT set either.
  //   VEN_TRANS_NO_F2XM1  -> f2xm1 (exp/pow)
  //       Cheapest to drop: a guest-RAM scan found only ONE exp2 signature
  //       (f2xm1 near fscale) and it was never observed executing.
  // FPATAN is always built (Quake's original transcendental).
  // Legacy VEN_TRANS_FPATAN_ONLY == all three tie-offs at once.

  // ---- F2XM1 (exp / pow) ------------------------------------------------------
`ifdef VEN_TRANS_FPATAN_ONLY
  assign eng_f2_start=1'b0; assign eng_f2_busy=1'b0; assign eng_f2_done=1'b0;
  assign eng_f2_pe=1'b0;    assign eng_f2_ie=1'b0;   assign eng_f2_result=80'd0;
`elsif VEN_TRANS_NO_F2XM1
  assign eng_f2_start=1'b0; assign eng_f2_busy=1'b0; assign eng_f2_done=1'b0;
  assign eng_f2_pe=1'b0;    assign eng_f2_ie=1'b0;   assign eng_f2_result=80'd0;
`else
  assign eng_f2_start = (state==S_FEXEC) && (q_fxop==FX_F2XM1);
  fpu_f2xm1 u_f2xm1 (
    .clk(clk), .rst_n(rst_n), .start(eng_f2_start),
    .x(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_f2_busy), .done(eng_f2_done), .result(eng_f2_result),
    .inexact(eng_f2_pe), .invalid(eng_f2_ie)
  );
`endif

  // ---- FYL2X / FYL2XP1 (log) --------------------------------------------------
`ifdef VEN_TRANS_FPATAN_ONLY
  assign eng_fy_start=1'b0; assign eng_fy_busy=1'b0; assign eng_fy_done=1'b0;
  assign eng_fy_pe=1'b0;    assign eng_fy_ie=1'b0;   assign eng_fy_result=80'd0;
`elsif VEN_TRANS_NO_FYL2X
  assign eng_fy_start=1'b0; assign eng_fy_busy=1'b0; assign eng_fy_done=1'b0;
  assign eng_fy_pe=1'b0;    assign eng_fy_ie=1'b0;   assign eng_fy_result=80'd0;
`else
  assign eng_fy_start = (state==S_FEXEC) && (q_fxop==FX_FYL2X || q_fxop==FX_FYL2XP1);
  fpu_fyl2x u_fyl2x (
    .clk(clk), .rst_n(rst_n), .start(eng_fy_start),
    .mode(q_fxop==FX_FYL2XP1), .y(fst(3'd1)), .x(fst(3'd0)), .rc(fctrl[11:10]),
    .busy(eng_fy_busy), .done(eng_fy_done), .result(eng_fy_result),
    .inexact(eng_fy_pe), .invalid(eng_fy_ie)
  );
`endif

  // ---- FSIN / FCOS / FSINCOS / FPTAN ------------------------------------------
  // One engine computes sin AND cos; FSIN commits sin_o, FCOS cos_o.
`ifdef VEN_TRANS_FPATAN_ONLY
  assign eng_fs_start=1'b0; assign eng_fs_busy=1'b0; assign eng_fs_done=1'b0;
  assign eng_fs_c2=1'b0;    assign eng_fs_sin=80'd0; assign eng_fs_cos=80'd0;
`elsif VEN_TRANS_NO_TRIG
  assign eng_fs_start=1'b0; assign eng_fs_busy=1'b0; assign eng_fs_done=1'b0;
  assign eng_fs_c2=1'b0;    assign eng_fs_sin=80'd0; assign eng_fs_cos=80'd0;
`else
  assign eng_fs_start = (state==S_FEXEC) && is_trig;
  fpu_fsincos u_fsincos (
    .clk(clk), .rst_n(rst_n), .start(eng_fs_start), .x(fst(3'd0)),
    .busy(eng_fs_busy), .done(eng_fs_done),
    .sin_o(eng_fs_sin), .cos_o(eng_fs_cos), .c2_o(eng_fs_c2)
  );
`endif
  assign eng_trsc_done   = (q_fxop==FX_F2XM1) ? eng_f2_done :
                           (q_fxop==FX_FPATAN) ? eng_fa_done :
                           is_trig ? eng_fs_done : eng_fy_done;
  assign eng_trsc_result = (q_fxop==FX_F2XM1) ? eng_f2_result :
                           (q_fxop==FX_FPATAN) ? eng_fa_result :
                           (q_fxop==FX_FSIN)  ? eng_fs_sin :
                           (q_fxop==FX_FCOS)  ? eng_fs_cos : eng_fy_result;
  assign eng_trsc_pe     = (q_fxop==FX_F2XM1) ? eng_f2_pe :
                           (q_fxop==FX_FPATAN) ? eng_fa_pe :
                           is_trig ? 1'b1 : eng_fy_pe;       // sin/cos always inexact
  assign eng_trsc_ie     = (q_fxop==FX_F2XM1) ? eng_f2_ie :
                           (q_fxop==FX_FPATAN) ? eng_fa_ie :
                           is_trig ? 1'b0 : eng_fy_ie;
  assign eng_trsc_c2     = is_trig ? eng_fs_c2 : 1'b0;
`endif
`else
  assign eng_trsc_done=1'b0; assign eng_trsc_result=80'd0;
  assign eng_trsc_pe=1'b0; assign eng_trsc_ie=1'b0; assign eng_trsc_c2=1'b0;
`endif

  // --- FPREM dedicated engine — COMBINATIONAL config only (no VEN_SRT_ITER) ----
  // Under VEN_SRT_ITER the unified fpu_srt_div handles remainder (folded above);
  // the eng_fprem_* handshake + start are declared/driven there. Here the dedicated
  // fpu_fprem serves builds without the iterative engine (e.g. the make-verify tb).
`ifdef VEN_FPREM
 `ifndef VEN_SRT_ITER
  fpu_fprem u_fprem (
    .clk(clk), .rst_n(rst_n), .start(eng_fprem_start),
    .prem1(q_fxop==FX_FPREM1),
    .a(fst(3'd0)), .b(fst(3'd1)),
    .busy(eng_fprem_busy), .done(eng_fprem_done), .result(eng_fprem_result),
    .q012(eng_fprem_q012), .c2(eng_fprem_c2), .ie(eng_fprem_ie)
  );
 `endif
`endif

  // ---- M2S.2 permission-fault DECISION (P/RW/US), computed not delivered. On a
  // TLB-resident data access the effective {US,RW,P} (perm) is checked against
  // the current privilege (CPL) and CR0.WP (bit 16): a USER-mode (CPL==3) access
  // to a supervisor (US=0) page, or a WRITE to a read-only page when the writer is
  // user OR CR0.WP is set, is a permission-violation #PF (error code P=1).
  //
  // M2S.3 STATUS: the NOT-PRESENT #PF (PDE/PTE P=0) now DELIVERS through the IDT
  // (S_WALK -> start_fault(14), CR2 + error code with P=0; see S_WALK steps 0/2).
  // This PERMISSION #PF (page present but US/RW protection fails) is still only
  // COMPUTED, not delivered — wiring it would require raising a fault from the
  // combinational S_PIPE/S_EXEC data path (the heavily-exercised user + sys fast
  // path) AND a corpus test that actually triggers it (CPL3 or WP=1 against a
  // present supervisor/RO page) to differentially validate the delivery. The
  // pintr/pfault corpus runs at CPL=0 / WP=0 against present RW pages, so
  // perm_fault is ALWAYS 0 here and there is no oracle for the delivery path; it
  // is a documented M2S.4 follow-on (cross-privilege brings CPL3 + WP tests).
  // REVIEW2 C-01: this used to end "Sunk in the lint sink; the access is NOT blocked
  // when perm_fault would fire." It now BLOCKS AND DELIVERS.
  //
  // What was missing was the whole page-level privilege boundary: a CPL3 access could
  // read or write a present SUPERVISOR page, a write could modify a READ-ONLY page,
  // and a CPL3 instruction fetch could execute a supervisor page -- with no #PF, no
  // CR2, and no error code. CR0.WP was therefore not architectural either.
  //
  // The old note said wiring it up needed a corpus test that actually triggers it.
  // That cuts the other way: the pintr/pfault corpus runs at CPL0 with WP=0 against
  // present RW pages, so perm_fault is identically 0 there -- which means DELIVERING
  // it is provably inert for the existing gate, and leaving it unwired bought nothing.
  // The permission check is now made on BOTH sides:
  //   * D side: the existing US/RW rules against dtlb_lk_perm.
  //   * I side: instruction fetch was not checked AT ALL. itlb_lk_perm was computed
  //     and never read. A fetch is always a read, so only the U/S rule applies.
  // ===========================================================================
  // REVIEW2 C-05: CENTRALIZED PRIVILEGE VALIDATION.
  //
  // Dispatch decided what a privileged instruction may do from BUILD/MODE switches
  // (sys_mode, soc_en, cosim_en) rather than from architectural CPL, and port I/O
  // consulted neither IOPL nor the TSS I/O bitmap. At CPL3 software could therefore
  // execute MOV CR, MOV DR, LGDT/LIDT, LTR/LLDT, INVLPG, CLI/STI, HLT and IN/OUT --
  // i.e. replace CR3, disable paging, install its own descriptor tables, do device
  // I/O, or halt the machine. That is privilege escalation, not a compatibility
  // corner.
  //
  // ONE predicate, consulted once before dispatch. Deliberately NOT spread across the
  // individual dispatch arms: this whole session's evidence is that a condition
  // written in N places becomes N-1 places that go stale.
  //
  // Gated on sys_mode so the bare-metal user corpus is byte-identical (it has no IDT
  // and runs its own privilege model). eff_cpl is already V86-correct (forced to 3).
  logic priv_fault;
  always_comb begin
    logic cpl0_only, iopl_sensitive, rdtsc_priv;
    // CPL0-only. SGDT/SIDT/STR/SMSW are deliberately ABSENT -- they are readable at
    // any CPL on a P5 (that is the well-known store-descriptor-table leak, not a bug
    // to fix here). MOV CR/DR covers both directions: reading CR/DR is CPL0-only too.
    cpl0_only = (d_sysop==SYS_MOVCR_TO)  || (d_sysop==SYS_MOVCR_FROM)
             || (d_sysop==SYS_MOVDR_TO)  || (d_sysop==SYS_MOVDR_FROM)
             || (d_sysop==SYS_LGDT)      || (d_sysop==SYS_LIDT)
             || (d_sysop==SYS_LLDT)      || (d_sysop==SYS_LTR)
             || (d_sysop==SYS_INVLPG)    || d_halt
    // REVIEW_aug2 H-06: INVD (0F 08) and WBINVD (0F 09). They decode to anonymous
    // NOPs -- correct for their architectural effect, but it left no predicate here,
    // so CPL3 code could execute them. d_cacheinv exists solely to be rejected here.
             || d_cacheinv;
    // REVIEW_aug2 H-06: RDTSC is NOT unconditionally CPL0-only -- it is readable at
    // any CPL unless CR4.TSD (bit 2) is set, which is the whole point of that bit.
    // So it gets its own term rather than joining the list above.
    rdtsc_priv = (d_kind==K_RDTSC) && creg4[2] && (eff_cpl != 2'd0);
    // IOPL-sensitive: CLI/STI and all port I/O. The TSS I/O permission bitmap is NOT
    // consulted yet -- with a bitmap a CPL>IOPL task may still be granted a port, so
    // this is STRICTER than architectural for that case. Recorded honestly rather
    // than silently: see #66 for the bitmap.
    // REVIEW1_Aug2 M-03: CLI/STI are IOPL-only -- there is no bitmap for them. Port
    // I/O at CPL > IOPL is NOT automatically illegal: the TSS I/O-permission bitmap can
    // grant individual ports, and rejecting everything (which is what this did) blocks
    // legitimate protected-mode I/O virtualisation. d_io is therefore removed from the
    // unconditional predicate and routed through S_IOPERM instead.
    iopl_sensitive = d_cli || d_sti;
    priv_fault = sys_mode &&
                 ( (cpl0_only      && (eff_cpl != 2'd0))
                || (iopl_sensitive && (eff_cpl >  iopl))
                || rdtsc_priv );
  end

  logic perm_fault, perm_fault_i;
  logic [31:0] perm_err;
  always_comb begin
    logic [2:0] pd, pi; logic usr, wp;
    pd  = dtlb_lk_perm;   // {US, RW, P} (D-TLB lookup at cur_lin)
    pi  = itlb_lk_perm;   // {US, RW, P} (I-TLB lookup at cur_lin)
    usr = acc_usr;   // REVIEW1_Aug2 C-04: the access CLASS (V86 forces eff_cpl 3)
    wp  = creg0[16];
    perm_fault   = 1'b0;
    perm_fault_i = 1'b0;
    // REVIEW_Aug3: the data half must be qualified on fe_translatable, matching the
    // fetch half -- a state whose access is SUPPRESSED (null-LLDT S_LTR, an
    // out-of-bounds S_TSW_SEG beat, and the physical S_WALK/SMM states, none of
    // which are translatable) must not take a permission fault for a transaction
    // it never issues.
    if (paging_on && cur_is_d && fe_translatable && dtlb_lk_hit) begin
      // user access to a supervisor page
      if (usr && !pd[2]) perm_fault = 1'b1;
      // write to a read-only page (user writer always; supervisor only if WP)
      if (cur_is_w && !pd[1] && (usr || wp)) perm_fault = 1'b1;
    end
    if (paging_on && !cur_is_d && fe_translatable && itlb_lk_hit) begin
      // C-01: CPL3 fetch from a supervisor page.
      if (usr && !pi[2]) begin perm_fault = 1'b1; perm_fault_i = 1'b1; end
    end
    // #PF error code (IA-32 Vol.3): [0]=P (1 here -- the page IS present, which is
    // exactly what distinguishes this from the S_WALK not-present fault), [1]=W/R,
    // [2]=U/S, [3]=RSVD, [4]=I/D (instruction fetch).
    perm_err = {27'd0, perm_fault_i, 1'b0, usr, cur_is_w && !perm_fault_i, 1'b1};
  end


  // ===========================================================================
  // Bus request generation (single combinational driver) — relocated VERBATIM
  // into core_bus_driver.svh (module-scope `always_comb, pasted here).
  // ===========================================================================
  // REVIEW1_Aug3 R2-C03: the driver produces bd_*; the FRAGMENT ENGINE's output
  // stage below drives the actual mem_* ports.
  `include "core_bus_driver.svh"

  // ===========================================================================
  // REVIEW1_Aug3 R2-C03: the fragment-engine OUTPUT STAGE + FSM-side muxes.
  //
  // Engagement is REGISTERED (fx_act) so no combinational path runs from
  // xlate_miss/perm_fault through fx_start into cur_lin and back. The only two
  // combinational intercepts, both loop-free (they never touch cur_lin or the
  // TLB lookup): the write start clock suppresses the port request (nothing may
  // escape unmasked on the entry clock -- the xs_eff lesson), and a same-clock
  // combinational frag1 ack is hidden from the FSM.
  logic        fx_eng, fx_wr_e;
  logic [1:0]  fx_ph_e;
  logic        fx_probe_e, fx_redirect_e, fx_shift_e, fx_maskA_e, fx_hold_e, fx_merge_e;
  logic        fx_wrsup_e;
  // The walk-detour blank: while the FSM is in S_WALK the engine is invisible
  // (its registers are frozen in the sequencer above). Without this the armed
  // read-merge leaks into the walk's PDE/PTE latches (pxc04).
  logic        fx_walk_hold;
  assign fx_walk_hold = (state == S_WALK);
  // the abort-cycle kill: while fx_abort_q is set (one cycle after any
  // start_fault), the ARMED sequence's shaping is blanked so the delivery's
  // first beat is never hijacked; the fx_start-based terms below stay live so
  // a delivery beat that itself crosses still fragments correctly.
  assign fx_eng   = fx_act && !fx_walk_hold && !fx_abort_q;
  assign fx_wr_e  = fx_wr;
  assign fx_ph_e  = fx_ph;
  assign fx_probe_e    = fx_act && !fx_walk_hold && !fx_abort_q &&  fx_wr && (fx_ph == 2'd0);
  assign fx_redirect_e = fx_act && !fx_walk_hold && !fx_abort_q && ((fx_wr && (fx_ph != 2'd1))
                                 || (!fx_wr && (fx_ph == 2'd1)));
  assign fx_shift_e    = fx_act && !fx_walk_hold && !fx_abort_q &&  fx_wr && (fx_ph == 2'd2);
  assign fx_maskA_e    = fx_act && !fx_walk_hold && !fx_abort_q &&  fx_wr && (fx_ph == 2'd1);
  assign fx_hold_e     = (fx_act && !fx_walk_hold && !fx_abort_q && ((fx_wr && (fx_ph == 2'd1))
                                  || (!fx_wr && (fx_ph == 2'd0))))
                      || (fx_start && !bd_we);   // a same-clock frag1 ack
  assign fx_merge_e    = fx_act && !fx_walk_hold && !fx_abort_q && !fx_wr && (fx_ph == 2'd1);
  assign fx_wrsup_e    = fx_probe_e || (fx_start && bd_we);

  // read-fragment strobe shaping (R2-H01): the L1 sizes a non-cacheable read
  // from the strobes, so each fragment carries its own window -- frag1 the
  // page-1 bytes, frag2 the page-2 bytes (shifted to lane 0). fx_first_nat is
  // the start-clock (pre-register) page-1 byte count.
  logic [2:0]  fx_first_nat;
  logic        fx_rdfrag1_e, fx_rdfrag2_e;
  assign fx_first_nat = 3'(13'h1000 - {1'b0, cur_lin_nat[11:0]});
  assign fx_rdfrag1_e = (fx_act && !fx_walk_hold && !fx_abort_q && !fx_wr && (fx_ph == 2'd0)) || (fx_start && !bd_we);
  assign fx_rdfrag2_e = fx_act && !fx_walk_hold && !fx_abort_q && !fx_wr && (fx_ph == 2'd1);

  assign mem_req   = fx_wrsup_e ? 1'b0 : bd_req;   // the probe issues NO transaction
  assign mem_we    = bd_we;
  assign mem_addr  = bd_addr;                      // follows cur_lin (redirected)
  assign mem_wdata = fx_shift_e ? (fx_wdata_q >> ({2'd0, fx_first} << 3)) : bd_wdata;
  assign mem_wstrb = fx_shift_e ? (fx_wstrb_q >> fx_first)              // write frag B
                   : fx_maskA_e ? (bd_wstrb & ((4'b1 << fx_first) - 4'b1))  // write frag A
                   : fx_rdfrag2_e ? (fx_wstrb_q >> fx_first)            // read frag2
                   : fx_rdfrag1_e ? (bd_wstrb & ((4'b1 << (fx_act ? fx_first : fx_first_nat)) - 4'b1))
                   : bd_wstrb;
  // the FSM's view of the bus: the ack is hidden until the LAST fragment, and
  // read data is the two fragments merged at the beat's byte offset.
  logic [31:0] mem_rdata;
  logic        mem_ack;
  assign mem_rdata = fx_merge_e ? fx_merged : bus_rdata;
  assign mem_ack   = bus_ack && !fx_hold_e;
  assign fx_probing = fx_probe_e;

  // ===========================================================================
  // M7.3b port-I/O bus driver (separate combinational driver) — relocated
  // VERBATIM into core_io_driver.svh (module-scope `always_comb, pasted here).
  `include "core_io_driver.svh"

  // capture original ESP at the cycle we enter PUSHA's S_USEQ.
  always_ff @(posedge clk) begin
    if (state==S_EXEC && q_kind==K_STKMISC && q_sm==SM_PUSHA) pusha_esp<=gpr_o[R_ESP];
  end

  // ===========================================================================
  // Lint sinks
  // ===========================================================================
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, mem_rdata[0], pfx_lock, pfx_seg, pfx_addr, q_imul_3op,
                   q_str_storedi,
                   // M2S.1 — the SEGMENT-LOAD protection DECISIONS (present/type/
                   // DPL via seg_load_fault) now DELIVER through the IDT in M2S.3
                   // (S_SEGLD/S_LJMP -> start_fault #GP/#NP/#SS). What remains here
                   // is the PER-ACCESS LIMIT check:
                   //   seg_off_over_limit : an operand whose last byte exceeds the
                   //                 segment limit is #GP(0); COMPUTED (0 for the
                   //                 in-bounds pseg corpus). Wiring it would raise a
                   //                 fault from the combinational data path AND
                   //                 needs an over-limit corpus test to validate —
                   //                 deferred to M2S.4 (documented follow-on).
                   seg_off_over_limit,
                   // M2S.2 — paging DECISIONS. The NOT-PRESENT #PF (PDE/PTE P=0)
                   // NOW DELIVERS (S_WALK -> start_fault(14), CR2 + error code; so
                   // walk_pf's delivery path IS live — it is sunk only because the
                   // gate's pages are all present so the flag is never set). What
                   // remains COMPUTED-not-delivered:
                   //   perm_fault  : the per-access P/RW/US permission-violation #PF
                   //                 (0 for the CPL=0/WP=0/present gate corpus) —
                   //                 M2S.4 follow-on (needs CPL3/WP test + raising
                   //                 from the data path); see perm_fault above.
                   //   pf_errcode  : the {US,RW,P} error code latch (the delivered
                   //                 #PF builds its error code inline in start_fault).
                   //   itlb_lk_perm: the fetch-side effective {US,RW,P} (home for a
                   //                 future fetch-permission / NX check; the I-TLB
                   //                 lookup port's perm output, now in u_itlb).
                   // Sunk so the clean -Wall lint stays quiet.
                   perm_fault, walk_pf, &pf_errcode,
                   itlb_lk_perm[0], itlb_lk_dirty,
                   // RESERVED system state, loaded this stage, gated-diffed later:
                   // GDT limit (descriptor-table bounds) + the IDTR (interrupts =
                   // M2S.3). Retained as the home for those checks.
                   gdt_limit[0], idt_base[0], idt_limit[0],
                   // REVIEW2_aug2 C-03 (fifth bullet): tr_valid and tr_limit USED to be
                   // sunk here as "COMPUTED-not-delivered", with a comment saying the
                   // negative cases "would consult" them. They are now consulted for
                   // real, in core_int_deliver.svh at the S_INT_CS -> S_INT_TSS
                   // transition: a cross-privilege delivery requires a loaded TSS and
                   // bounds the ssN:espN read against tr_limit, raising #TS(0) and
                   // #TS(tr_sel) respectively. Removed from the sink accordingly --
                   // leaving them here would keep -Wall quiet about a signal that no
                   // longer needs the exemption, and the stale comment claimed the
                   // opposite of what the RTL now does.
                   // M8.1 — inta_valid: the PIC asserts it with a meaningful
                   // inta_vector. The master 8259 always supplies a vector on the
                   // 2nd INTA cycle, so the divert latches inta_vector
                   // unconditionally; inta_valid is the home for a future spurious-
                   // IRQ7/IRQ15 refinement (deliver vector 7/15 with inta_valid=0).
                   // Sunk so -Wall stays quiet while the pin exists for ventium_soc.
                   inta_valid};
  // verilator lint_on UNUSED

`ifdef VEN_DBG_POP
  // DOS-Quake #GP triage: trace the go32 fault-dispatcher `pop word [ds:0x4f6c]`
  // (cs=2b:0x3e83) memory load (stack read) + store (operand write), to see why
  // the popped value never lands at [ds:0x4f6c]. Inert unless +define+VEN_DBG_POP.
  always_ff @(posedge clk) begin
    if (seg_sel[SG_CS][15:0]==16'h002b && q_pc[15:0]==16'h3e83 && mem_req && mem_ack) begin
      if (state==S_LOAD)
        $display("[POP-LD] q_pc=%05x addr=%08x rdata=%08x", q_pc, mem_addr, mem_rdata);
      else if (state==S_STORE)
        $display("[POP-ST] q_pc=%05x addr=%08x wdata=%08x wstrb=%x", q_pc, mem_addr, mem_wdata, mem_wstrb);
      else
        $display("[POP-?]  q_pc=%05x state=%0d addr=%08x rdata=%08x we=%b wdata=%08x", q_pc, state, mem_addr, mem_rdata, mem_we, mem_wdata);
    end
  end
`endif


`ifdef VEN_PERF_PROFILE
  // ===========================================================================
  // task #54 INSTRUMENT — WHERE DO THE CYCLES ACTUALLY GO?
  //
  // After the C-01 fix the booting cosim runs at CPI 8.26 (was 13.00). A real P5
  // is ~1.1-1.5, so ~7 cycles/instruction are still unaccounted for. Every prior
  // attempt to attribute them was an INFERENCE from an aggregate ("93.7% stall at
  // 3% AXI occupancy" -> "it must be core-internal"), and retraction #12 shows how
  // that goes wrong. So: count the clocks directly.
  //
  //   pp_state[s] : clocks spent with state==s. Separates "the slow FSM is running
  //                 a multi-cycle instruction" from "S_PIPE is stalled".
  //   pp_bail[i]  : clocks in S_PIPE broken down by the FIRST arm of the spine's
  //                 else-if chain that fired. The buckets are in the SAME PRIORITY
  //                 ORDER as core_fastpath.svh / core_gpr_wb.svh, so bucket i means
  //                 "arm i rejected this clock and arms 0..i-1 did not".
  //
  // Counters only; no datapath signal is read by anything else, so this is inert
  // unless +define+VEN_PERF_PROFILE.
  // ===========================================================================
  localparam int PP_NSTATE = 64;
  localparam int PP_NBAIL  = 14;
  localparam int PP_NSBAIL = 4;
  // The uop-cache fallback starts one S_FETCH transaction, whose subsequent
  // clocks live in the FSM-state counters rather than the one-clock bail bucket.
  // Split the entry cause so profile data can distinguish a walker/validity
  // problem from a deliberately uncovered instruction boundary before anyone
  // considers changing the cache or execution policy.
  localparam int PP_NUOPMISS = 4;
  longint pp_state [PP_NSTATE];
  // Per-state memory accounting.  `pp_mem_wait` counts clocks in which a
  // request is visibly held without an acknowledgement; `pp_mem_ack` counts
  // completed request/response handshakes.  Keeping both is important: a large
  // S_FETCH/S_PF residency could otherwise be either real L1/AXI latency or
  // purely core-local sequencing.
  longint pp_mem_wait [PP_NSTATE];
  longint pp_mem_ack  [PP_NSTATE];
  longint pp_bail  [PP_NBAIL];
  longint pp_uopmiss [PP_NUOPMISS];
  // A boundary-unavailable miss can be a dense-line overflow, or an unusual
  // branch target.  Its byte-offset distribution determines whether a small
  // tail sidecar is sufficient; aggregate miss counts alone cannot answer that.
  longint pp_uopmiss_off [IC_LINE];
  longint pp_uop_sfetch;  // successful registered-window hand-offs
  longint pp_resident_sfetch; // S_PIPE slow-path hand-offs accepted from BRAM
`ifdef VEN_FP_SHARED
`ifndef SYNTHESIS
  // The shared top separately reports its service latency.  Measure the same
  // accepted-command-to-core-observed-response interval here so a core-side
  // wait-state change cannot be justified from a leaf-only counter.
  longint pp_fp_shared_cmds, pp_fp_shared_roundtrip;
  logic pp_fp_shared_pending;
  longint pp_fp_shared_age;
`endif
`endif
  // Bucket 9 (`fp_sys_bail`) is deliberately broad.  Split its actual hand-off
  // cause so an implementation change targets a demonstrated eligibility
  // limit, rather than blindly widening the system fast path.
  longint pp_sys_bail [PP_NSBAIL];
`ifndef SYNTHESIS
`ifdef VEN_SLOWOP_PERF
  // The slow decoder is deliberately the safe fallback.  Attribute its
  // *non-simple* entries by their actual byte stream before widening that
  // whitelist: a generic decoding extension is useful only when it covers a
  // measured instruction family, and this remains entirely outside synthesis.
  longint unsigned pp_slowop [256];
  longint unsigned pp_slowop_rr [256];
  longint unsigned pp_slowop_rr_hi8 [256];
  longint unsigned pp_slowop_0f [256];
  longint unsigned pp_slowop_0f_setcc_rr [256];
  longint unsigned pp_slowop_0f_setcc_rr_hi8 [256];
  logic [31:0] pp_slowop_first_pc [256];
  logic [47:0] pp_slowop_first_bytes [256];
`endif
`endif
  longint pp_cycles, pp_ret1, pp_ret2;
  longint pp_divert;   // clocks where an interrupt diverted the S_PIPE spine
  longint pp_shadow, pp_shret;   // clocks with irq_shadow set / retires under it

  // Bucket names, index-matched to the chain below (for the dump).
  function automatic string pp_bail_name(input int i);
    case (i)
      0:  pp_bail_name = "stall_cnt!=0      (multi-cycle op / injected penalty)";
      1:  pp_bail_name = "!pipe_bytes_ok    (I-cache miss: fetch bytes absent)";
      2:  pp_bail_name = "ic_fetch !ready   (registered I-cache read latency)";
      3:  pp_bail_name = "uop miss/!cycle   (uop cache)";
      4:  pp_bail_name = "pending_mem_pen   (modeled P5 memory penalty)";
      5:  pp_bail_name = "pipe_mem_wait     (D-side or fragment result pending)";
      6:  pp_bail_name = "fp_pipe_rd_haz    (x87 result not ready)";
      7:  pp_bail_name = "fp arith !PC=ext  (x87 precision-control bail)";
      8:  pp_bail_name = "is_fp             (x87 issue/occupancy)";
      9:  pp_bail_name = "fp_sys_bail       (-> SLOW FSM: not simple, or sys)";
      10: pp_bail_name = "mispred_bubbles   (branch mispredict penalty)";
      11: pp_bail_name = "pipe_agi          (address-generation interlock)";
      12: pp_bail_name = "ISSUE             (retired 1 or 2 this clock)";
      default: pp_bail_name = "?";
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i=0;i<PP_NSTATE;i++) pp_state[i] <= 64'd0;
      for (int i=0;i<PP_NSTATE;i++) begin
        pp_mem_wait[i] <= 64'd0;
        pp_mem_ack[i]  <= 64'd0;
      end
      for (int i=0;i<PP_NBAIL;i++)  pp_bail[i]  <= 64'd0;
      for (int i=0;i<PP_NUOPMISS;i++) pp_uopmiss[i] <= 64'd0;
      for (int i=0;i<IC_LINE;i++) pp_uopmiss_off[i] <= 64'd0;
      pp_uop_sfetch <= 64'd0;
      pp_resident_sfetch <= 64'd0;
`ifdef VEN_FP_SHARED
`ifndef SYNTHESIS
      pp_fp_shared_cmds <= 64'd0;
      pp_fp_shared_roundtrip <= 64'd0;
      pp_fp_shared_pending <= 1'b0;
      pp_fp_shared_age <= 64'd0;
`endif
`endif
      for (int i=0;i<PP_NSBAIL;i++) pp_sys_bail[i] <= 64'd0;
`ifndef SYNTHESIS
`ifdef VEN_SLOWOP_PERF
      for (int i=0;i<256;i++) begin
        pp_slowop[i] <= 64'd0;
        pp_slowop_rr[i] <= 64'd0;
        pp_slowop_rr_hi8[i] <= 64'd0;
        pp_slowop_0f[i] <= 64'd0;
        pp_slowop_0f_setcc_rr[i] <= 64'd0;
        pp_slowop_0f_setcc_rr_hi8[i] <= 64'd0;
        pp_slowop_first_pc[i] <= 32'd0;
        pp_slowop_first_bytes[i] <= 48'd0;
      end
`endif
`endif
      pp_cycles <= 64'd0; pp_ret1 <= 64'd0; pp_ret2 <= 64'd0; pp_divert <= 64'd0; pp_shadow <= 64'd0; pp_shret <= 64'd0;
    end else begin
      pp_cycles <= pp_cycles + 64'd1;
      if (fp_irq_divert) pp_divert <= pp_divert + 64'd1;
      if (irq_shadow) pp_shadow <= pp_shadow + 64'd1;
      if (irq_shadow && retire_valid) pp_shret <= pp_shret + 64'd1;
      pp_state[int'(state) & (PP_NSTATE-1)] <= pp_state[int'(state) & (PP_NSTATE-1)] + 64'd1;
      if (mem_req && !mem_ack)
        pp_mem_wait[int'(state) & (PP_NSTATE-1)] <= pp_mem_wait[int'(state) & (PP_NSTATE-1)] + 64'd1;
      if (mem_req && mem_ack)
        pp_mem_ack[int'(state) & (PP_NSTATE-1)] <= pp_mem_ack[int'(state) & (PP_NSTATE-1)] + 64'd1;
      if (retire_valid)  pp_ret1 <= pp_ret1 + 64'd1;
      if (retire2_valid) pp_ret2 <= pp_ret2 + 64'd1;
      if (sfetch_uop_fast) pp_uop_sfetch <= pp_uop_sfetch + 64'd1;
      if (sfetch_resident_fast) pp_resident_sfetch <= pp_resident_sfetch + 64'd1;
`ifdef VEN_FP_SHARED
`ifndef SYNTHESIS
      if ((state == S_FEXEC) && fp_shared_cmd_ready && !fp_shared_accept_retire) begin
        pp_fp_shared_pending <= 1'b1;
        pp_fp_shared_age <= 64'd0;
      end else if (pp_fp_shared_pending) begin
        if ((state == S_FP_SHARED_WAIT) && fp_shared_rsp_valid) begin
          pp_fp_shared_cmds <= pp_fp_shared_cmds + 64'd1;
          pp_fp_shared_roundtrip <= pp_fp_shared_roundtrip + pp_fp_shared_age + 64'd1;
          pp_fp_shared_pending <= 1'b0;
        end else begin
          pp_fp_shared_age <= pp_fp_shared_age + 64'd1;
        end
      end
`endif
`endif

      // The S_PIPE chain, in the spine's exact priority order. Mirrors
      // core_gpr_wb.svh's guard chain one-for-one -- if that chain is edited and
      // this is not, the buckets go stale (which is the C-01 failure mode, so it
      // is called out here on purpose; this block is diagnostic-only and cannot
      // change behaviour, but it CAN lie).
      if (state == S_PIPE) begin
        int b;
        b = 12;                                                        // ISSUE
        if      (stall_cnt != 7'd0)                            b = 0;
        else if (!pipe_bytes_ok
`ifdef VEN_L1_AXI
                 && !(real_bus && !mem_ack)
`endif
                )                                              b = 1;
`ifdef VEN_L1_AXI
        else if (!pipe_bytes_ok)                               b = 1;
`endif
`ifdef VEN_IC_BRAM
        else if (!ic_fetch_ready)                              b = 2;
`endif
`ifdef VEN_UOPCACHE
        else if (!uop_hit || !cycle_mode)                      b = 3;
`endif
        else if (pending_mem_pen != 7'd0)                      b = 4;
        else if (pipe_mem_wait)                                  b = 5;
`ifdef VEN_FP_PIPE
        else if (fp_pipe_rd_haz)                               b = 6;
`endif
        else if (u_d.is_fp && u_d.fp_kind==FK_ARITH
                 && fctrl[9:8]!=2'b11)                         b = 7;
        else if (u_d.is_fp)                                    b = 8;
        else if (fp_sys_bail)                                  b = 9;
        else if (mispred_bubbles != 3'd0)                      b = 10;
        else if (pipe_agi)                                     b = 11;
        pp_bail[b] <= pp_bail[b] + 64'd1;
        if (b == 3) begin
          // Keep this order aligned with `!uop_hit || !cycle_mode` above.
          // `uop_hit` itself gates exec_issue_ok first, then line predecode
          // validity, then the byte-to-slot boundary map.  The categories add
          // exactly to bail bucket 3 and are diagnostic-only.
`ifdef VEN_UOPCACHE
          if (!cycle_mode) pp_uopmiss[0] <= pp_uopmiss[0] + 64'd1;
          else if (!exec_issue_ok) pp_uopmiss[1] <= pp_uopmiss[1] + 64'd1;
          else if (!(uc_u_in_b ? uc_pdvB : uc_pdvA))
            pp_uopmiss[2] <= pp_uopmiss[2] + 64'd1;
          else begin
            pp_uopmiss[3] <= pp_uopmiss[3] + 64'd1;
            pp_uopmiss_off[flin[4:0]] <= pp_uopmiss_off[flin[4:0]] + 64'd1;
          end
`endif
        end
        if (b == 9) begin
          // Keep this priority in lockstep with fp_sys_bail.  An instruction
          // may satisfy more than one conservative exclusion; classifying the
          // first term makes the totals add up exactly to bucket 9.
          if (!u_d.simple) begin
            pp_sys_bail[0] <= pp_sys_bail[0] + 64'd1;
`ifndef SYNTHESIS
`ifdef VEN_SLOWOP_PERF
            // is_fp deliberately uses simple=0 to stay separate from integer
            // pairing; those instructions have already been accepted by the
            // compact x87 path and are not slow decoder work.
            if (!u_d.is_fp) begin
              pp_slowop[ic_byte(flin)] <= pp_slowop[ic_byte(flin)] + 64'd1;
              // A register-only candidate avoids the data-side protocol entirely.
              // Count the high-byte spelling separately: AH..BH needs the partial
              // register read/write muxes that a low-byte-only extension would avoid.
              if (ic_byte(flin + 32'd1)[7:6] == 2'b11) begin
                pp_slowop_rr[ic_byte(flin)] <= pp_slowop_rr[ic_byte(flin)] + 64'd1;
                if (ic_byte(flin + 32'd1)[5] || ic_byte(flin + 32'd1)[2])
                  pp_slowop_rr_hi8[ic_byte(flin)] <= pp_slowop_rr_hi8[ic_byte(flin)] + 64'd1;
              end
              // 0F 9x is the common SETcc shape: its ModR/M byte is b2, unlike
              // one-byte opcodes. Attribute the extension byte independently so
              // a partial-register SETcc path is considered on measured coverage.
              if (ic_byte(flin) == 8'h0F) begin
                pp_slowop_0f[ic_byte(flin + 32'd1)] <= pp_slowop_0f[ic_byte(flin + 32'd1)] + 64'd1;
                if ((ic_byte(flin + 32'd1)[7:4] == 4'h9)
                    && (ic_byte(flin + 32'd2)[7:6] == 2'b11)) begin
                  pp_slowop_0f_setcc_rr[ic_byte(flin + 32'd1)]
                    <= pp_slowop_0f_setcc_rr[ic_byte(flin + 32'd1)] + 64'd1;
                  if (ic_byte(flin + 32'd2)[2])
                    pp_slowop_0f_setcc_rr_hi8[ic_byte(flin + 32'd1)]
                      <= pp_slowop_0f_setcc_rr_hi8[ic_byte(flin + 32'd1)] + 64'd1;
                end
              end
            end
            // Keep a concrete byte window for each first-byte bucket.  Prefix
            // buckets are expected, and their exemplar distinguishes an
            // operand/address-size exclusion from the following opcode.
            if (pp_slowop[ic_byte(flin)] == 0) begin
              pp_slowop_first_pc[ic_byte(flin)] <= flin;
              pp_slowop_first_bytes[ic_byte(flin)] <= {
                ic_byte(flin + 32'd5), ic_byte(flin + 32'd4),
                ic_byte(flin + 32'd3), ic_byte(flin + 32'd2),
                ic_byte(flin + 32'd1), ic_byte(flin)
              };
            end
`endif
`endif
          end
`ifdef VEN_SYS_FASTPATH
          else if (sys_mode && !sys_fp_ok) pp_sys_bail[1] <= pp_sys_bail[1] + 64'd1;
          else if (sys_mode && u_d.is_store && !sys_fp_store_ok) pp_sys_bail[2] <= pp_sys_bail[2] + 64'd1;
          else if (sys_mode && u_d.is_mem && !u_d.is_store && !sys_fp_load_ok) pp_sys_bail[2] <= pp_sys_bail[2] + 64'd1;
          else if (sys_mode && fp_dbg_active) pp_sys_bail[3] <= pp_sys_bail[3] + 64'd1;
`else
          else if (sys_mode) pp_sys_bail[1] <= pp_sys_bail[1] + 64'd1;
`endif
        end
      end
    end
  end

  // Dump at end of simulation. `final` runs once in Verilator on $finish/exit.
  final begin
    longint tot_ret, slow_cyc;
    tot_ret  = pp_ret1 + pp_ret2;
    slow_cyc = pp_cycles - pp_state[int'(S_PIPE) & (PP_NSTATE-1)];
    $display("");
    $display("==== VEN_PERF_PROFILE (task #54: where the cycles go) ====");
    $display("  clocks              %0d", pp_cycles);
    $display("  retires             %0d   (U=%0d  pairedV=%0d)", tot_ret, pp_ret1, pp_ret2);
    $display("  S_PIPE irq diverts  %0d", pp_divert);
    $display("  irq_shadow clocks   %0d   (retires under shadow: %0d)", pp_shadow, pp_shret);
    if (tot_ret != 0)
      $display("  CPI                 %0d.%02d",
               pp_cycles/tot_ret, ((pp_cycles*100)/tot_ret)%100);
    $display("");
    $display("  -- clocks by FSM state (only non-zero) --");
    for (int i=0;i<PP_NSTATE;i++)
      if (pp_state[i] != 0)
        $display("    state %2d %10d  %3d.%01d%%", i, pp_state[i],
                 (pp_state[i]*1000)/pp_cycles/10, ((pp_state[i]*1000)/pp_cycles)%10);
    $display("");
    $display("  -- memory pressure by FSM state (only non-zero) --");
    for (int i=0;i<PP_NSTATE;i++)
      if ((pp_mem_wait[i] != 0) || (pp_mem_ack[i] != 0))
        $display("    state %2d  req-wait clocks %10d  req/ack handshakes %10d",
                 i, pp_mem_wait[i], pp_mem_ack[i]);
    $display("");
    $display("  S_PIPE clocks %0d   NON-S_PIPE (slow FSM) clocks %0d  (%0d.%01d%%)",
             pp_state[int'(S_PIPE) & (PP_NSTATE-1)], slow_cyc,
             (slow_cyc*1000)/pp_cycles/10, ((slow_cyc*1000)/pp_cycles)%10);
    $display("");
    $display("  -- S_PIPE clocks by FIRST bail arm (priority order) --");
    for (int i=0;i<PP_NBAIL;i++)
      if (pp_bail[i] != 0)
        $display("    [%2d] %10d  %3d.%01d%%  %s", i, pp_bail[i],
                 (pp_bail[i]*1000)/pp_cycles/10, ((pp_bail[i]*1000)/pp_cycles)%10,
                 pp_bail_name(i));
    if (pp_bail[3] != 0) begin
      $display("");
      $display("  -- uop-cache fallback cause (sums to bucket 3) --");
      $display("    functional/non-cycle mode          %10d", pp_uopmiss[0]);
      $display("    executable-state flush             %10d", pp_uopmiss[1]);
      $display("    line not predecoded-valid          %10d", pp_uopmiss[2]);
      $display("    boundary unavailable                %10d", pp_uopmiss[3]);
      $display("    resident uop fetch hand-offs        %10d", pp_uop_sfetch);
      $display("  -- unavailable-boundary byte offsets (only non-zero) --");
      for (int i=0;i<IC_LINE;i++)
        if (pp_uopmiss_off[i] != 0)
          $display("    offset %2d                         %10d", i, pp_uopmiss_off[i]);
    end
    if (pp_resident_sfetch != 0)
      $display("  resident S_PIPE slow-fetch hand-offs  %10d", pp_resident_sfetch);
`ifdef VEN_FP_SHARED
`ifndef SYNTHESIS
    if (pp_fp_shared_cmds != 0)
      $display("  shared-FP core round trip: commands=%0d cycles=%0d avg=%0d.%02d",
               pp_fp_shared_cmds, pp_fp_shared_roundtrip,
               pp_fp_shared_roundtrip / pp_fp_shared_cmds,
               ((pp_fp_shared_roundtrip * 100) / pp_fp_shared_cmds) % 100);
`endif
`endif
    if (pp_bail[9] != 0) begin
      $display("");
      $display("  -- fp_sys_bail hand-off cause (sums to bucket 9) --");
      $display("    !u_d.simple                     %10d", pp_sys_bail[0]);
      $display("    system context not eligible      %10d", pp_sys_bail[1]);
      $display("    system memory not eligible       %10d", pp_sys_bail[2]);
      $display("    system debug active              %10d", pp_sys_bail[3]);
    end
`ifndef SYNTHESIS
`ifdef VEN_SLOWOP_PERF
    if (pp_sys_bail[0] != 0) begin
      $display("");
      $display("  -- non-simple slow-decode entry bytes (only non-zero) --");
      for (int i=0;i<256;i++)
        if (pp_slowop[i] != 0)
          $display("    byte %02x count %10d rr=%10d rr-hi8=%10d first-flin=%08x bytes=%012x",
                   i, pp_slowop[i], pp_slowop_rr[i], pp_slowop_rr_hi8[i],
                   pp_slowop_first_pc[i], pp_slowop_first_bytes[i]);
      $display("");
      $display("  -- 0F slow-decode extensions (only non-zero) --");
      for (int i=0;i<256;i++)
        if (pp_slowop_0f[i] != 0)
          $display("    0f %02x count %10d setcc-rr=%10d setcc-rr-hi8=%10d",
                   i, pp_slowop_0f[i], pp_slowop_0f_setcc_rr[i],
                   pp_slowop_0f_setcc_rr_hi8[i]);
    end
`endif
`endif
    $display("==========================================================");
  end
`endif


  // ===========================================================================
  // FAST-PATH COMMIT ASSERTIONS (simulation only).
  //
  // The fast path has now produced the SAME defect twice: a guard chain that is
  // reproduced by hand in the spine (core_fastpath.svh) and in the extracted
  // side-effect drivers, then extended in only one of them.
  //   C-01 : task #55 relaxed the spine's sys_mode bail-out; core_gpr_wb.svh kept
  //          the old text, so register writes were silently DISCARDED.
  //   #57  : the interrupt-acceptance arm was added to the spine only, so the
  //          mirrors committed state for an instruction that never retired.
  // Both were invisible to every existing test: decode16 (24/24) and upipe16
  // (530/530) do not drive the integrated mirrors, and the cycle gate compares
  // only {pc,cyc,pipe,paired} -- no registers -- so a wrong commit at the right PC
  // reads as green.
  //
  // These two checks close that specific hole. They compare what the SPINE
  // actually did against what the MIRROR actually did, WITHOUT re-typing the
  // chain -- re-typing it is the bug, so an assertion built that way would rot in
  // exactly the same manner.
  // synopsys translate_off
`ifndef SYNTHESIS
  logic        fpchk_arm_q, fpchk_we_q, fpchk_wreg_q;
  logic [3:0]  fpchk_dst_q;
  logic [7:0]  fpchk_shadow_n;   // retires observed with irq_shadow still set
  logic        fpchk_dbg_q;      // CHECK 4: debug armed on the issue clock
  logic        fpchk_fxabort_q, fpchk_fxstart_q;  // CHECK 8: abort request/start history
  logic [1:0]  fpchk_fxph_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fpchk_arm_q <= 1'b0; fpchk_we_q <= 1'b0; fpchk_wreg_q <= 1'b0;
      fpchk_dst_q <= 4'd0; fpchk_shadow_n <= 8'd0; fpchk_dbg_q <= 1'b0;
      fpchk_fxabort_q <= 1'b0; fpchk_fxstart_q <= 1'b0; fpchk_fxph_q <= 2'd0;
    end else begin
      // ---- CHECK 1: a diverted clock must commit NOTHING ---------------------
      // Direct, same-clock, no history needed: if the spine is abandoning this
      // instruction for an interrupt or external debugger park, no mirror may
      // write a register.
      if (fp_issue_block && (gpr_we != '0))
        $error("FASTPATH/issue-block: gpr_we=%b on a clock the spine did not issue (eip=%08h) -- a register was committed for an instruction that did not retire",
               gpr_we, eip);

      // ---- CHECK 2: the C-01 shape -------------------------------------------
      // Sample the mirror's decision and the instruction's shape THIS clock; the
      // spine's own decision shows up as retire_valid on the NEXT clock (it is a
      // registered output of the ISSUE arm). So next clock we can ask: did the
      // spine retire a register-writing integer instruction while the mirror
      // wrote no register? That is exactly C-01, and nothing here restates the
      // guard chain.
      fpchk_arm_q  <= (state == S_PIPE) && !fp_issue_block;
      fpchk_we_q   <= (gpr_we != '0);
      fpchk_wreg_q <= u_d.wreg && !u_d.is_branch && !u_d.is_nop && !u_d.is_fp;
      fpchk_dst_q  <= {1'b0, u_d.dst};
      if (fpchk_arm_q && retire_valid && retire_pipe_valid
          && fpchk_wreg_q && !fpchk_we_q)
        $error("FASTPATH/C-01: spine retired a register-writing fast-path insn (dst=r%0d) but the GPR writeback mirror asserted no gpr_we -- the two guard chains have drifted apart",
               fpchk_dst_q);

      // ---- CHECK 7: invalidation beats consumption on a flush cycle ----------
      // exec_issue_ok gates every executable hit (ic_present, uop_hit) while
      // exec_flush_all is asserted, so a flush cycle can neither serve a cached
      // line nor a predecoded slot. These trip if a future change reintroduces
      // a consumption path around the gate (the RSM leak: a cached SMRAM line
      // retiring in the cycle after SMM closes).
      if (exec_flush_all && (sfetch_fast || sfetch_uop_fast || sfetch_resident_fast))
        $error("FETCH/FLUSH: the fast fetch window is serving while exec_flush_all is asserted -- invalidation must beat consumption");
`ifdef VEN_UOPCACHE
      if (exec_flush_all && uop_hit)
        $error("FETCH/FLUSH: a predecode hit is serving while exec_flush_all is asserted -- invalidation must beat consumption");
`endif

      // ---- CHECK 8: fragment abort is complete and blank -------------------
      // start_fault only PULSES fx_abort_q (the engine's registers are
      // single-owned by the sequencer block): the abort cycle itself must show
      // no armed fragment shaping (the kill keeps the delivery's first beat
      // clean), and one cycle later the engine must be disengaged unless a new
      // crossing start already replaced the aborted sequence.
      if (fx_abort_q && (fx_probe_e || fx_merge_e || fx_redirect_e || fx_shift_e
                         || fx_maskA_e || fx_rdfrag2_e))
        $error("FX/ABORT: armed fragment shaping is live during the abort cycle -- the delivery's first beat would be hijacked");
      if (fpchk_fxabort_q && !fpchk_fxstart_q && fx_act)
        $error("FX/ABORT: the engine is still engaged one cycle after the abort request (ph=%0d)", fpchk_fxph_q);
      fpchk_fxabort_q <= fx_abort_q;
      fpchk_fxstart_q <= fx_start;
      fpchk_fxph_q    <= fx_ph;

      // ---- CHECK 9: the I-cache invalidation contract -----------------------
      // On an exec_flush_all cycle the executable arrays clear at the edge, so
      // no fill word may land on that same clock (the capture would race the
      // clear inside the icache, and tool-dependent NBA order would decide
      // which one wins). The S_PIPE word-0 capture and the word-0 bus request
      // are both gated by exec_issue_ok; this trips if a path around them
      // appears.
      if (exec_flush_all && ic_fill_en)
        $error("ICACHE/FLUSH: a fill word landed on a flush cycle -- it races the invalidating edge");

      // ---- CHECK 6: probe walks never set D; real writes never fill clean ----
      // REVIEW_Aug4 A4-C01. The two write-intent notions must stay separate all
      // the way to memory: walk_is_write (architectural class: W/R permission
      // and the #PF error code) vs walk_set_dirty (may change architectural D
      // state). A crossing-write probe walks with the first but not the second.
      if (state == S_WALK && paging_on && mem_req && mem_we
          && walk_is_write && !walk_set_dirty) begin
        if (walk_step == 3'd1 && mem_wdata[6] && !walk_pde[6])
          $error("WALK/A4-C01: a PROBE walk is setting PDE.D (wdata=%08h pde=%08h) -- the probe must not change architectural D state: if page 1 faults, the store never happened",
                 mem_wdata, walk_pde);
        if (walk_step == 3'd3 && mem_wdata[6] && !walk_pte[6])
          $error("WALK/A4-C01: a PROBE walk is setting PTE.D (wdata=%08h pte=%08h) -- the probe must not change architectural D state",
                 mem_wdata, walk_pte);
      end
      // A permitted non-probe write must not fill a CLEAN writable leaf: the
      // entry it installs must carry the D it just wrote (or that was already
      // set) -- otherwise the next write re-walks forever.
      if (state == S_WALK && mem_ack && tlb_fill_en && walk_for_d
          && walk_is_write && walk_set_dirty && !tlb_fill_dirty
          && ((walk_step == 3'd1 && walk_wr_ok_big)
              || (walk_step == 3'd3 && walk_wr_ok_4k)))
        $error("WALK/A4-C01: a REAL write filled a CLEAN writable leaf (step=%0d) -- the next write to this page will miss and re-walk indefinitely",
               walk_step);

      // ---- CHECK 5: RETIRED (REVIEW1_Aug3 R2-M02 complete) ----------------------
      // This assertion compared cur_lin (what the TLB looks up and the page walk
      // fills) against mem_addr_arm (what the legacy per-state bus-driver arms
      // computed) on every translatable request. It stayed green for the whole
      // REVIEW2 C-03..C-05 era, which is what made deleting the arms safe. The
      // migration is now COMPLETE: every translatable state's address is cur_lin,
      // and the only remaining bus-driver address arms belong to the states that
      // are physical by definition (S_WALK, S_SMI_SAVE/S_RSM) or run unpaged
      // (S_RMINT_*). There is no second generator left to compare, so the check,
      // the addr_migrated predicate, and the mem_addr_arm snapshot retire
      // together, exactly as planned when the predicate was introduced.

      // ---- REVIEW2_Aug1 C-06 DIAGNOSTIC (+ven_seglog) ------------------------
      // The delivery is REMOVED (see core_fetch_decode.svh), because two earlier
      // attempts shipped false positives. This logs, WITHOUT faulting, every access
      // the limit check WOULD have rejected -- qualified on a real bus request in a
      // translatable state, the same qualifier CHECK 5 uses, so it reports accesses
      // and not combinational glitches. The point is to find the remaining false
      // positive by measurement instead of re-enabling delivery and bisecting a
      // corpus-wide failure, which is how the first two were found the hard way.
      // NOTE the qualifier: mem_req_pre_sq, not mem_req. Once C-01 made
      // seg_access_fault SQUASH the request, qualifying on mem_req made this probe
      // self-defeating -- it printed nothing precisely when it had something to say.
      // REVIEW2_aug2 C-01: read the SUB-TERMS, not seg_access_fault. That signal is now
      // gated on VEN_SEG_ENFORCE (it had to be -- see its definition), so keying the
      // probe off it would make this diagnostic silent in exactly the build where you
      // most want to know what enforcement WOULD reject before flipping the default.
      // REVIEW1_Aug3 R2-H07: S_INT_PROBE issues NO bus request by design (bd_req=0),
      // so mem_req_pre_sq never covers it -- the frame-extent probe's would-be
      // segment rejections were invisible to this log. Include it explicitly.
      // (Diagnostic only: no DELIVERY is added there -- QEMU does not segment-check
      // implicit kernel pushes, so faulting would diverge from the oracle.)
      if (ven_seglog_en && (mem_req_pre_sq || (state == S_INT_PROBE)) && fe_translatable
          && cur_is_d && cur_seg_rel
          && (seg_off_over_limit || seg_null_sel || seg_not_present || seg_type_fault))
        $display("[SEGCHK] st=%0d dseg=%0d sel=%04h base=%08h lim=%08h attr=%02h ed=%b | cur_lin=%08h off=%08h w=%0d cpl=%0d pc=%08h",
                 int'(state), int'(cur_seg_idx), seg_sel[cur_seg_idx], seg_chk_base, dlimit,
                 seg_attr[cur_seg_idx], seg_expand_down, cur_lin, seg_chk_off, q_w,
                 int'(eff_cpl), eip);
      // R2-H07: the fetch-extent check's firings, same plusarg.
      if (ven_seglog_en && cs_extent_fault)
        $display("[SEGCHK-X] st=%0d eip=%08h len=%0d cs_lim=%08h cs_attr=%02h",
                 int'(state), eip, (state == S_PIPE) ? u_d.len : d_len,
                 seg_limit[SG_CS], seg_attr[SG_CS]);

      // ---- CHECK 4: the fast path must never issue while debugging is armed ---
      // The fast path implements neither single-step nor DR breakpoints, so if it
      // ever retires with TF set or a breakpoint enabled in sys_mode, a debug event
      // was silently dropped.
      //
      // CORRECTED. The first version tested `(state==S_PIPE) && retire_valid`, which
      // is WRONG and fired constantly: retire_valid is REGISTERED and is set by the
      // SLOW-path arms too, and when a slow instruction retires the FSM has already
      // returned to S_PIPE -- so the condition matched the completely normal case.
      // It $stop'd the pdebug system test 113 records early, and I only found that by
      // finally running `make verify-sys`. An assertion that fires on correct
      // behaviour is worse than no assertion: it hides real failures behind noise and
      // burns the credibility of every other check next to it.
      //
      // retire_pipe_valid is set ONLY by the fast path's issue/commit arms (the slow
      // arms leave it at its default 0), so it is the right predicate. Sampled like
      // CHECK 2: latch the condition on the ISSUE clock and test it the next clock,
      // when the registered retire actually appears.
      fpchk_dbg_q <= sys_mode && fp_dbg_active && (state == S_PIPE);
      if (fpchk_dbg_q && retire_pipe_valid)
        $error("FASTPATH/debug: fast path retired with TF=%b RF=%b dr7[7:0]=%02h in sys_mode (eip=%08h) -- a #DB was silently skipped; fp_sys_bail should have sent this to the slow FSM",
               eflags[8], eflags[16], dr7[7:0], eip);

      // ---- CHECK 3: slow-path-only state that the fast path can starve --------
      // Third instance of the same shape: irq_shadow (the STI / MOV-SS
      // one-instruction interrupt inhibit) is SET in S_EXEC and was CLEARED only in
      // S_DECODE -- both slow-FSM states. A fast path that never enters S_DECODE
      // latched it forever and silently masked every maskable interrupt.
      // Architecturally the shadow spans exactly ONE instruction, so counting more
      // than a couple of retires with it still set means something stopped clearing
      // Threshold is 1 retire_valid CLOCK. Reaching 1 is NORMAL and expected: the
      // shadowed instruction itself retires with the shadow still set (measured:
      // 430 such retires in a boot, all slow-path, each isolated). What must never
      // happen is a SECOND retire under the same shadow -- that means nothing
      // cleared it. Verified live: removing the fast-path clear makes this fire at
      // cycle 5,017,000 (eip=0x7087); with the clear in place it is silent across
      // the full boot and all 98 verify programs. (A paired U+V clock retires two
      // instructions but is still a single retire_valid clock.)
      if (irq_shadow && retire_valid) fpchk_shadow_n <= fpchk_shadow_n + 8'd1;
      else if (!irq_shadow)           fpchk_shadow_n <= 8'd0;
      if (fpchk_shadow_n > 8'd1)
        $error("FASTPATH/irq-shadow: irq_shadow has stayed set across %0d retires (eip=%08h) -- the STI/MOV-SS shadow must last ONE instruction; some path is setting it without a matching clear",
               fpchk_shadow_n, eip);
    end
  end
`endif
  // synopsys translate_on

endmodule : core
