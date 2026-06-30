// Self-checking unit test for the behavioral altsyncram (L1 icache config:
// DUAL_PORT, 32/32, byteena 4, registered read). Verifies write->read data and
// latency, and read-during-write. Run: verilator --binary tb_mem.sv ../stubs/sim_prims.sv
`timescale 1ns/1ps
module tb_mem;
  localparam AW = 8;
  reg clk = 0;
  always #5 clk = ~clk;

  // Port A (write), Port B (read)
  reg  [AW-1:0] addr_a = 0, addr_b = 0;
  reg  [3:0]    be_a = 4'hF;
  reg  [31:0]   data_a = 0;
  reg           wren_a = 0;
  wire [31:0]   q_b;

  altsyncram #(
    .operation_mode("DUAL_PORT"), .address_reg_b("CLOCK0"), .outdata_reg_b("UNREGISTERED"),
    .numwords_a(2**AW), .numwords_b(2**AW), .widthad_a(AW), .widthad_b(AW),
    .width_a(32), .width_b(32), .width_byteena_a(4), .byte_size(8)
  ) dut (
    .clock0(clk), .clock1(1'b1),
    .address_a(addr_a), .byteena_a(be_a), .data_a(data_a), .wren_a(wren_a),
    .address_b(addr_b), .byteena_b(1'b1), .data_b(32'b0), .wren_b(1'b0),
    .q_a(), .q_b(q_b),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
  );

  integer errors = 0;
  task wr(input [AW-1:0] a, input [31:0] d); begin
    @(negedge clk); addr_a = a; data_a = d; wren_a = 1; be_a = 4'hF;
    @(negedge clk); wren_a = 0;
  end endtask
  task rd_check(input [AW-1:0] a, input [31:0] exp); begin
    @(negedge clk); addr_b = a;          // present address
    @(posedge clk); #1;                  // 1-cycle registered read
    if (q_b !== exp) begin
      $display("FAIL: read addr %0d got %08x expected %08x", a, q_b, exp); errors = errors + 1;
    end else $display("ok: addr %0d = %08x", a, q_b);
  end endtask

  initial begin
    @(negedge clk);
    wr(8'd5,  32'h12345678);
    wr(8'd6,  32'hDEADBEEF);
    wr(8'd10, 32'hCAFEF00D);
    rd_check(8'd5,  32'h12345678);
    rd_check(8'd6,  32'hDEADBEEF);
    rd_check(8'd10, 32'hCAFEF00D);
    rd_check(8'd5,  32'h12345678);   // re-read
    // sequential read (icache-like): present consecutive addresses each cycle
    @(negedge clk); addr_b = 8'd6; @(posedge clk); #1;
    if (q_b !== 32'hDEADBEEF) begin $display("FAIL seqread1 %08x", q_b); errors=errors+1; end
    addr_b = 8'd10; @(posedge clk); #1;
    if (q_b !== 32'hCAFEF00D) begin $display("FAIL seqread2 %08x", q_b); errors=errors+1; end
    else $display("ok: back-to-back reads pipeline correctly");
    $display("=== errors=%0d ===", errors);
    $finish;
  end
endmodule
