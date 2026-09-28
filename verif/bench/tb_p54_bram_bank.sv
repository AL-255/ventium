`timescale 1ns/1ps
`default_nettype none
module tb_p54_bram_bank;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic a_en, b_en;
  logic [7:0] a_row, b_row;
  logic [3:0] a_wstrb;
  logic [31:0] a_wdata, a_rdata, b_rdata;
  ven_p54_bram_bank dut (.*);

  initial begin
    a_en = 1'b0; b_en = 1'b0;
    a_row = '0; b_row = '0; a_wstrb = '0; a_wdata = '0;
    // Initialize every row through the ordinary byte-write port. No RAM
    // initialization/reset is assumed by the hardware contract.
    for (int row = 0; row < 256; row++) begin
      @(negedge clk);
      a_en = 1'b1; a_row = 8'(row); a_wstrb = 4'hf;
      a_wdata = 32'h5100_0000 | 32'(row);
    end
    @(negedge clk);
    a_en = 1'b0; a_wstrb = '0;
    // Two independent registered read ports, one response each clock. Both
    // same-row and different-row reads are legal when no write occurs.
    for (int row = 0; row < 256; row++) begin
      @(negedge clk);
      a_en = 1'b1; a_row = 8'(row);
      b_en = 1'b1; b_row = 8'((row + 17) % 256);
      @(posedge clk); #1;
      assert (a_rdata == (32'h5100_0000 | 32'(row)))
        else $fatal(1, "A row=%0d got=%08x", row, a_rdata);
      assert (b_rdata == (32'h5100_0000 | 32'((row + 17) % 256)))
        else $fatal(1, "B row=%0d got=%08x", row, b_rdata);
    end
    @(negedge clk);
    a_en = 1'b1; a_row = 8'd9; a_wstrb = 4'b0101;
    a_wdata = 32'haabb_ccdd;
    b_en = 1'b1; b_row = 8'd10; // no write/read collision
    @(posedge clk); #1;
    assert (b_rdata == 32'h5100_000a) else $fatal(1, "B read during A write");
    @(negedge clk);
    a_wstrb = '0; b_row = 8'd9;
    @(posedge clk); #1;
    assert (a_rdata == 32'h51bb_00dd && b_rdata == 32'h51bb_00dd)
      else $fatal(1, "byte write/readback: A=%08x B=%08x", a_rdata, b_rdata);
    $display("P54-BRAM-BANK-OK");
    $finish;
  end
endmodule
`default_nettype wire
