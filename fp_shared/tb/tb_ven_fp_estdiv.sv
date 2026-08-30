`timescale 1ns/1ps
`default_nettype none

module tb_ven_fp_estdiv;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic req = 1'b0;
  logic [63:0] a0, a1, b;
  logic old_vld, new_vld;
  logic [63:0] old_z, new_z;
  int checks;

  always #5 clk = ~clk;

  fpu_estdiv u_old (
      .clk(clk), .rst_n(rst_n), .req(req), .a0(a0), .a1(a1), .b(b),
      .vld(old_vld), .z(old_z)
  );
  ven_fp_estdiv u_new (
      .clk(clk), .rst_n(rst_n), .req(req), .a0(a0), .a1(a1), .b(b),
      .vld(new_vld), .z(new_z)
  );

  function automatic logic [63:0] rnd64();
    return {$urandom, $urandom};
  endfunction

  task automatic check_one(
      input logic [63:0] ia0,
      input logic [63:0] ia1,
      input logic [63:0] ib
  );
    logic seen_old, seen_new;
    logic [63:0] got_old, got_new;
    int timeout;
    begin
      @(negedge clk);
      a0 = ia0;
      a1 = ia1;
      b = ib;
      req = 1'b1;
      @(negedge clk);
      req = 1'b0;
      seen_old = 1'b0;
      seen_new = 1'b0;
      timeout = 0;
      while (!(seen_old && seen_new)) begin
        if (old_vld) begin
          got_old = old_z;
          seen_old = 1'b1;
        end
        if (new_vld) begin
          got_new = new_z;
          seen_new = 1'b1;
        end
        @(negedge clk);
        timeout++;
        if (timeout > 100)
          $fatal(1, "estdiv timeout a0=%016h a1=%016h b=%016h", ia0, ia1, ib);
      end
      if (got_new !== got_old)
        $fatal(1, "estdiv mismatch a0=%016h a1=%016h b=%016h old=%016h new=%016h",
               ia0, ia1, ib, got_old, got_new);
      checks++;
    end
  endtask

  initial begin
    a0 = 64'd0;
    a1 = 64'd0;
    b = 64'd0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    check_one(64'd0, 64'd0, 64'h8000000000000000);
    check_one(64'h8000000000000000, 64'hffffffffffffffff,
              64'h80000000ffffffff);
    check_one(64'hffffffffffffffff, 64'h0123456789abcdef,
              64'h8000000000000000);
    check_one(64'h7fffffffffffffff, 64'hffffffffffffffff,
              64'hffffffffffffffff);

    for (int i = 0; i < 5000; i++) begin
      automatic logic [63:0] rb;
      automatic logic [63:0] ra0;
      rb = rnd64();
      if ((i % 7) == 0) begin
        rb[63] = 1'b0;
        ra0 = rnd64() | 64'h8000000000000000;
      end else begin
        rb[63] = 1'b1;
        ra0 = rnd64() & 64'h7fffffffffffffff;
      end
      check_one(ra0, rnd64(), rb);
    end

    $display("VEN-FP-ESTDIV-A-B-OK checks=%0d", checks);
    $finish;
  end
endmodule

`default_nettype wire
