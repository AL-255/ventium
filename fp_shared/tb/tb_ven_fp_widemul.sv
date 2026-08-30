`timescale 1ns/1ps
`default_nettype none

module tb_ven_fp_widemul;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic start, busy, done;
  logic [127:0] a, b;
  logic [255:0] product;
  int checks;

  ven_fp_widemul dut (.*);

  task automatic check_one(input logic [127:0] av,
                           input logic [127:0] bv);
    logic [255:0] expected;
    int timeout;
    begin
      while (busy) @(negedge clk);
      a = av;
      b = bv;
      expected = av * bv;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      timeout = 0;
      while (!done) begin
        @(negedge clk);
        timeout++;
        if (timeout > 20)
          $fatal(1, "wide multiplier timeout a=%032h b=%032h", av, bv);
      end
      if (product !== expected)
        $fatal(1, "wide multiplier mismatch a=%032h b=%032h got=%064h exp=%064h",
               av, bv, product, expected);
      checks++;
    end
  endtask

  initial begin
    start = 1'b0;
    a = 128'd0;
    b = 128'd0;
    checks = 0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    check_one(128'd0, 128'd0);
    check_one(128'd1, 128'd1);
    check_one({128{1'b1}}, {128{1'b1}});
    check_one(128'h80000000000000000000000000000000,
              128'h80000000000000000000000000000000);
    check_one(128'h0123456789abcdef_fedcba9876543210,
              128'hf0e1d2c3b4a59687_78695a4b3c2d1e0f);
    for (int i = 0; i < 1000; i++) begin
      logic [127:0] ra, rb;
      ra = {$urandom, $urandom, $urandom, $urandom};
      rb = {$urandom, $urandom, $urandom, $urandom};
      check_one(ra, rb);
    end

    $display("VEN-FP-WIDEMUL-OK checks=%0d", checks);
    $finish;
  end
endmodule

`default_nettype wire
