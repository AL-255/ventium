// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps

// Cache-level response-owner regression, not full-core cancellation proof.
// Warm resident A, start cold B, then replace the unacknowledged legacy
// request with A immediately BEFORE B's first backing beat. HIT_UNDER_FILL
// admits A's registered window on the same edge that arms B's critical word.
// ACK for A must carry A's bytes, including at the actual sampling edge.
// +HOLD_B is the ordinary hold-until-ACK control; +CODE_A exercises a resident
// instruction-buffer request A during a DATA fill B. Pair ports stay inert.
module tb_l1d_early_retarget;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic c_req = 0, c_we = 0;
  logic [31:0] c_addr = 0, c_wdata = 0;
  logic [3:0] c_wstrb = 4'hf;
  logic [31:0] c_rdata;
  logic c_ack;
`ifdef VEN_L1D_CODE_BUFFER
  logic c_code = 0;
`endif
  logic m_req, m_we;
  logic [31:0] m_addr, m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic m_ack, m_rd_narrow;
  logic [1:0] m_rd_size;
  logic allow_backing = 1;
  localparam logic [31:0] A = 32'h0000_2020; // neighbor line, word zero
  localparam logic [31:0] B = 32'h0000_201c; // cold line, word seven
  bit hold_b, code_a;
  int checks = 0;

  function automatic logic [31:0] backing_word(input logic [31:0] address);
    return address ^ 32'hbadd_0000;
  endfunction
  assign m_rdata = backing_word(m_addr);
  assign m_ack = m_req && !m_we && allow_backing;

  ven_l1d dut (
      .clk, .rst_n, .flush_all(1'b0), .golden(1'b0), .cacheable(1'b1),
      .snoop_inv_valid(1'b0), .snoop_inv_addr(32'd0),
      .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack,
`ifdef VEN_L1D_CODE_BUFFER
      .c_code,
`endif
`ifdef VEN_L1D_STORE_POLICY
      .c_store_update_mask(4'hf),
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
      .c_pair_req(1'b0), .c_pair_addr(32'd0), .c_pair_wdata(32'd0),
      .c_pair_wstrb(4'd0), .c_pair_ready(), .c_pair_ack(),
`ifdef VEN_L1D_STORE_POLICY
      .c_pair_store_update_mask(4'hf),
`endif
      .m_pair_req(), .m_pair_addr(), .m_pair_wdata(), .m_pair_wstrb(),
      .m_pair_ready(1'b0), .m_pair_ack(1'b0),
`endif
`ifdef VEN_PIPE_MEM_CHAIN
      .c_next_req(1'b0), .c_next_commit(1'b0), .c_next_cacheable(1'b0),
      .c_next_addr(32'd0), .c_next_wstrb(4'd0), .c_next_ready(),
`endif
`ifdef VEN_FP_LOAD64
      .c_rdata_hi(), .c_rdata_hi_valid(),
`endif
`ifdef VEN_L1D_HIT_STREAM
      .c_hit_stream(1'b0), .c_req_ready(), .c_rsp_valid(),
      .c_rsp_ready(1'b0), .c_rsp_addr(), .c_rsp_cancel(),
`endif
`ifdef VEN_P54_DUAL_HIT
      .pair_req_valid(2'd0), .pair_cacheable(2'd0), .pair_paddr(64'd0),
      .pair_size_log2(4'd0), .pair_owner(32'd0), .pair_req_ready(),
      .pair_req_split(), .pair_bank_conflict(), .pair_rsp_valid(),
      .pair_rsp_cancel(), .pair_rsp_ready(2'd0), .pair_rsp_owner(),
      .pair_rsp_paddr(), .pair_rsp_data(),
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
      .pair_now_req(1'b0), .pair_now_cacheable(1'b0), .pair_now_paddr(32'd0),
      .pair_now_size_log2(2'd0), .pair_now_valid(), .pair_now_data(),
`endif
`endif
      .dbg_serve(), .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb,
      .m_rdata, .m_ack, .m_rd_narrow, .m_rd_size);

  task automatic require_true(input bit condition, input string message);
    if (!condition) $fatal(1, "L1D-EARLY-RETARGET-FAIL %s", message);
    checks++;
  endtask

  initial begin
    hold_b = $test$plusargs("HOLD_B");
    code_a = $test$plusargs("CODE_A");
`ifndef VEN_L1D_CODE_BUFFER
    require_true(!code_a, "CODE_A requires VEN_L1D_CODE_BUFFER");
`endif
    $display("CASE hold_until_ack=%0d code_a=%0d A=%08x B=%08x", hold_b, code_a, A, B);
    repeat (4) @(posedge clk);
    @(negedge clk); rst_n = 1;
    @(negedge clk); c_req = 1; c_addr = A;
`ifdef VEN_L1D_CODE_BUFFER
    c_code = code_a;
`endif
    begin : warm_a
      bit got_a;
      got_a = 0;
      for (int cycle = 0; cycle < 100; cycle++) begin
        @(posedge clk); #1;
        if (c_ack) begin
          require_true(c_rdata == backing_word(A), "warming resident A returned wrong data");
          got_a = 1;
          break;
        end
      end
      require_true(got_a, "warming resident A timed out");
    end
    @(negedge clk); c_req = 0;
    begin : drain_a
      bit idle;
      idle = 0;
      for (int cycle = 0; cycle < 100; cycle++) begin
        @(posedge clk); #1;
        if (dut.st == 2'd0) begin idle = 1; break; end
      end
      require_true(idle, "warm A fill did not drain");
    end
    // No ACK for B has occurred when the diagnostic replaces it by A.
    @(negedge clk); allow_backing = 0; c_req = 1; c_addr = B;
`ifdef VEN_L1D_CODE_BUFFER
    c_code = 0;
`endif
    @(posedge clk); #1;
    require_true(dut.st == 2'd1 && dut.fw == 0 && m_req, "B did not enter blocked first fill beat");
    require_true(!c_ack && !dut.early_armed, "B acknowledged before retarget setup");
    @(negedge clk);
    if (!hold_b) begin
      c_addr = A;
`ifdef VEN_L1D_CODE_BUFFER
      c_code = code_a;
`endif
    end
    allow_backing = 1;
    #1;
    require_true(m_addr == B && m_ack, "backing first-beat owner changed from B");
    if (!hold_b) require_true(dut.do_rd_cap, "resident A was not captured on B critical-beat edge");
    @(posedge clk); #1;
    $display("EDGE early_armed=%0d early_match=%0d rd_match=%0d rd_addr=%08x early_addr=%08x ack=%0d data=%08x expected=%08x",
        dut.early_armed, dut.early_match, dut.rd_match, dut.rd_addr_q,
        dut.early_addr_q, c_ack, c_rdata, backing_word(hold_b ? B : A));
    require_true(dut.early_armed, "B critical data was not armed");
    require_true(c_ack, "selected live request was not acknowledged");
    if (!hold_b)
      require_true(dut.rd_match && !dut.early_match && dut.rd_addr_q == A,
                   "simultaneous A window/B critical ownership overlap was not reached");
    // Assert at the following consumer sampling edge, before DUT NBA updates.
    @(posedge clk);
    $display("SAMPLE ack=%0d data=%08x expected=%08x early_armed=%0d early_match=%0d rd_match=%0d",
        c_ack, c_rdata, backing_word(hold_b ? B : A), dut.early_armed, dut.early_match, dut.rd_match);
    require_true(c_ack, "ACK disappeared before the core sampling edge");
    require_true(c_rdata == backing_word(hold_b ? B : A),
                 "ACK carries data belonging to a different request");
    $display("L1D-EARLY-RETARGET-OK checks=%0d hold_until_ack=%0d code_a=%0d", checks, hold_b, code_a);
    $finish;
  end
  initial begin #10000; $fatal(1, "L1D-EARLY-RETARGET-FAIL watchdog"); end
endmodule
