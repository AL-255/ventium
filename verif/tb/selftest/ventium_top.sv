// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// verif/tb/selftest/ventium_top.sv
//
// THROWAWAY self-test stub for Producer C (the Verilator C++ testbench).
//
// This is NOT the real core. rtl/ventium_top.sv is authored by a sibling agent
// in parallel, so this testbench must prove its clock/reset/DPI/trace flow
// against a stub that obeys the SAME interface contract:
//   - docs/rtl-interface.md §1  (top module ports)
//   - docs/rtl-interface.md §2  (vtm_retire DPI callback)
//   - docs/rtl-interface.md §3  (mem_* bus-functional port group)
//   - docs/rtl-interface.md §5  (M0 NOP-stub behaviour: retire a fixed finite
//                                canned sequence, then idle)
//
// It retires 8 NOP-like "instructions" with monotonic n, fetches one word per
// retire over the mem_* port (so the bus-functional model is exercised), and
// then goes idle so the TB's quiescence detector stops the run.
//
// The integration phase builds the TB against the REAL rtl/ sources, NOT this.

module ventium_top #(
    // entry/reset-EIP is supplied by the testbench at +RESET via a parameter so
    // the stub's pc values are deterministic relative to --entry. The real core
    // takes its reset vector from architectural reset state instead; this is a
    // stub-only convenience and is harmless if left at its default.
    parameter int unsigned ENTRY = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Bus-functional-model port group (docs/rtl-interface.md §3, M0 contract).
    output logic        mem_req,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_wstrb,
    input  logic [31:0] mem_rdata,
    input  logic        mem_ack
);

    // ---- DPI retire callback import (exact signature from rtl-interface.md §2)
`ifndef VTM_NO_DPI
    import "DPI-C" context function void vtm_retire(
        input longint unsigned n,        // retire seq, 0-based, monotonic
        input int      unsigned pc,      // fetch vaddr of retired insn
        input int      unsigned eflags,
        input int      unsigned eax, input int unsigned ecx,
        input int      unsigned edx, input int unsigned ebx,
        input int      unsigned esp, input int unsigned ebp,
        input int      unsigned esi, input int unsigned edi,
        input shortint unsigned cs,  input shortint unsigned ss,
        input shortint unsigned ds,  input shortint unsigned es,
        input shortint unsigned fs,  input shortint unsigned gs);
`endif

    localparam int unsigned N_INSN = 8;   // canned sequence length

    // retire counter; also doubles as our trivial "fetch index"
    logic [63:0] seq;
    logic        done;

    // Drive the bus: request one read per not-yet-retired step so the TB's
    // mem_* handshake gets exercised. Address walks entry, entry+1, ... (the
    // stub does not actually use the fetched bytes — M0 ignores them).
    assign mem_req   = (rst_n && !done);
    assign mem_we    = 1'b0;
    assign mem_addr  = ENTRY + seq[31:0];   // byte address of "next insn"
    assign mem_wdata = 32'h0;
    assign mem_wstrb = 4'b0000;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            seq  <= 64'd0;
            done <= 1'b0;
        end else if (!done) begin
            // Single-beat handshake: when the TB acks our read, "retire" one.
            if (mem_req && mem_ack) begin
`ifndef VTM_NO_DPI
                // Stub post-commit state: pc = entry + seq (one byte/insn here,
                // deterministic), zeroed GPRs/eflags, flat segment selectors.
                // Not meant to match QEMU (see trace-format.md §4) — only to
                // prove the trace path is well-formed end to end.
                vtm_retire(
                    /* n      */ seq,
                    /* pc     */ ENTRY + seq[31:0],
                    /* eflags */ 32'h0000_0002,   // bit 1 reads as 1 on x86
                    /* eax    */ 32'd0, /* ecx */ 32'd0,
                    /* edx    */ 32'd0, /* ebx */ 32'd0,
                    /* esp    */ 32'd0, /* ebp */ 32'd0,
                    /* esi    */ 32'd0, /* edi */ 32'd0,
                    /* cs */ 16'h0000, /* ss */ 16'h0000,
                    /* ds */ 16'h0000, /* es */ 16'h0000,
                    /* fs */ 16'h0000, /* gs */ 16'h0000);
`endif
                seq <= seq + 64'd1;
                if (seq == 64'(N_INSN) - 64'd1)
                    done <= 1'b1;   // finite sequence: go idle (rtl-interface §5.3)
            end
        end
    end

endmodule
