// sys/sys_state.sv — System state: segments, control/debug regs, SMM, MSRs,
//                    CPUID, RDTSC + perf counters; exception pipeline (M0 stub).
//
// PLAN.md §6.9 (System state) + §6.8 (Interrupt/exception pipeline): the
// segment selectors + hidden descriptor state (cs ss ds es fs gs), CRx/DRx/TRx,
// SMM + SMRAM save/restore + RSM, CPUID, MSRs, test registers, RDTSC + two
// 40-bit performance counters, debug breakpoints / single-step, and the
// fault-priority / restart / INT-INTA logic.
// Key reference: IA-32 SDM Vol.3 (243192) (system programming — segmentation,
// paging, interrupts/exceptions, task switching, debug); Pentium Dev. Manual
// Vol.3 (241430) (SMM, MSRs, CPUID); spec updates for fault-priority quirks.
//
// M0 status: STUB. The M0 retire point synthesises stub segment state directly
// in ventium_top. Real system state lands across M2 (PLAN §7); SMM/debug there
// too. Segment selectors are the cs/ss/ds/es/fs/gs func-mode trace fields
// (trace-format.md §2.2 / tracefmt.py SEG_KEYS).

module sys_state (
    input  logic        clk,
    input  logic        rst_n
    // M2+ skeleton (not yet wired):
    //   output logic [15:0]  cs, ss, ds, es, fs, gs,   // segment selectors
    //   output logic [31:0]  cr0, cr2, cr3, cr4,
    //   output logic [63:0]  tsc,                       // RDTSC
    //   input  logic         exc_req,                   // raise exception
    //   input  logic [7:0]   exc_vector,
    //   output logic [31:0]  exc_handler_eip
);
  // Intentionally empty at M0.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, clk, rst_n};
  // verilator lint_on UNUSED
endmodule : sys_state
