`timescale 1ns/1ps
module tb_p54_bram_data;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst_n = 0, flush = 0;
  logic wr_valid = 0;
  logic [2:0] wr_bank = 0;
  logic [7:0] wr_row = 0;
  logic [3:0] wr_wstrb = 0;
  logic [31:0] wr_data = 0;
  logic wr_ready;
  logic u_req_valid = 0, u_req_ready, u_rsp_valid, u_rsp_cancel, u_rsp_ready = 0;
  logic [2:0] u_req_bank = 0;
  logic [7:0] u_req_row = 0;
  logic [15:0] u_req_owner = 0, u_rsp_owner;
  logic [31:0] u_rsp_data;
  logic v_req_valid = 0, v_req_ready, v_bank_conflict;
  logic v_rsp_valid, v_rsp_cancel, v_rsp_ready = 0;
  logic [2:0] v_req_bank = 0;
  logic [7:0] v_req_row = 0;
  logic [15:0] v_req_owner = 0, v_rsp_owner;
  logic [31:0] v_rsp_data;
  int checks = 0;

  ven_p54_bram_data dut (.*);

  task automatic edge_step;
    @(posedge clk);
    #1;
  endtask

  task automatic write_word(input logic [2:0] bank,
                            input logic [7:0] row,
                            input logic [31:0] data);
    @(negedge clk);
    wr_valid = 1;
    wr_bank = bank;
    wr_row = row;
    wr_wstrb = 4'hf;
    wr_data = data;
    #1;
    if (!wr_ready) $fatal(1, "write not ready bank=%0d row=%0d", bank, row);
    edge_step();
    @(negedge clk);
    wr_valid = 0;
  endtask

  initial begin
    repeat (2) edge_step();
    @(negedge clk);
    rst_n = 1;
    for (int bank = 0; bank < 8; bank++)
      for (int row = 0; row < 4; row++)
        write_word(3'(bank), 8'(row + 9), 32'hc0000000 | 32'(bank << 8) | 32'(row));

    // Two distinct physical banks return simultaneously with separate owners.
    @(negedge clk);
    u_req_valid = 1; u_req_bank = 3'd2; u_req_row = 8'd9; u_req_owner = 16'h102;
    v_req_valid = 1; v_req_bank = 3'd5; v_req_row = 8'd11; v_req_owner = 16'h205;
    #1;
    if (!u_req_ready || !v_req_ready || v_bank_conflict)
      $fatal(1, "distinct banks were not accepted together");
    edge_step();
    if (!u_rsp_valid || !v_rsp_valid || u_rsp_owner != 16'h102 ||
        v_rsp_owner != 16'h205 || u_rsp_data != 32'hc0000200 ||
        v_rsp_data != 32'hc0000502)
      $fatal(1, "dual response/owner mismatch U=%h V=%h", u_rsp_data, v_rsp_data);
    checks++;

    // Holding U/V prevents a second request. A write to U's bank must wait;
    // a write to V's bank may proceed on A while its B response remains held.
    @(negedge clk);
    u_req_valid = 1; v_req_valid = 1;
    wr_valid = 1; wr_bank = 3'd2; wr_row = 8'd9; wr_data = 32'hdeadbeef;
    #1;
    if (u_req_ready || v_req_ready || wr_ready)
      $fatal(1, "held U response overwritten or older U overtaken");
    wr_bank = 3'd5; wr_row = 8'd12; wr_data = 32'h76543210;
    #1;
    if (!wr_ready || u_req_ready || v_req_ready)
      $fatal(1, "independent write should proceed while responses held");
    edge_step();
    if (u_rsp_data != 32'hc0000200 || v_rsp_data != 32'hc0000502)
      $fatal(1, "held response data changed on independent write");
    checks++;

    @(negedge clk);
    wr_valid = 0; u_req_valid = 0; v_req_valid = 0;
    u_rsp_ready = 1; v_rsp_ready = 1;
    edge_step();
    if (u_rsp_valid || v_rsp_valid) $fatal(1, "response not consumed");
    checks++;

    // Same-bank U/V requests serialize; V can be replayed after U consumes.
    @(negedge clk);
    u_rsp_ready = 0; v_rsp_ready = 0;
    u_req_valid = 1; u_req_bank = 3'd1; u_req_row = 8'd10; u_req_owner = 16'h301;
    v_req_valid = 1; v_req_bank = 3'd1; v_req_row = 8'd11; v_req_owner = 16'h302;
    #1;
    if (!u_req_ready || v_req_ready || !v_bank_conflict)
      $fatal(1, "same-bank conflict missing");
    edge_step();
    if (!u_rsp_valid || v_rsp_valid || u_rsp_data != 32'hc0000101)
      $fatal(1, "same-bank U response mismatch");
    checks++;
    @(negedge clk);
    u_req_valid = 0; u_rsp_ready = 1;
    #1;
    if (!v_req_ready) $fatal(1, "same-bank V replay blocked");
    edge_step();
    if (u_rsp_valid || !v_rsp_valid || v_rsp_owner != 16'h302 ||
        v_rsp_data != 32'hc0000102)
      $fatal(1, "same-bank V replay mismatch");
    checks++;

    // Flush exposes cancellation instead of allowing the held response to
    // masquerade as data for a later owner.
    @(negedge clk);
    v_req_valid = 0; flush = 1;
    #1;
    if (v_rsp_valid || !v_rsp_cancel || wr_ready || u_req_ready || v_req_ready)
      $fatal(1, "flush did not cancel and stop admission");
    edge_step();
    if (v_rsp_valid || v_rsp_cancel) $fatal(1, "flush failed to clear owner");
    checks++;

    // Exercise all 56 ordered distinct-bank pairs with consecutive
    // consume-and-replace edges, not just one favorable pair.
    for (int ub = 0; ub < 8; ub++) begin
      for (int vb = 0; vb < 8; vb++) begin
        if (ub != vb) begin
          @(negedge clk);
          flush = 0;
          u_rsp_ready = 1; v_rsp_ready = 1;
          u_req_valid = 1; v_req_valid = 1;
          u_req_bank = 3'(ub); v_req_bank = 3'(vb);
          u_req_row = 8'(9 + (ub % 4));
          v_req_row = 8'(9 + (vb % 4));
          u_req_owner = 16'(16'h400 + ub*8 + vb);
          v_req_owner = 16'(16'h500 + ub*8 + vb);
          #1;
          if (!u_req_ready || !v_req_ready || v_bank_conflict)
            $fatal(1, "distinct-bank admission failed U=%0d V=%0d", ub, vb);
          edge_step();
          if (!u_rsp_valid || !v_rsp_valid ||
              u_rsp_owner != u_req_owner || v_rsp_owner != v_req_owner ||
              u_rsp_data != (32'hc0000000 | 32'(ub << 8) | 32'(ub % 4)) ||
              v_rsp_data != (32'hc0000000 | 32'(vb << 8) | 32'(vb % 4)))
            $fatal(1, "distinct-bank data/owner failed U=%0d V=%0d", ub, vb);
          checks++;
        end
      end
    end
    @(negedge clk);
    u_req_valid = 0; v_req_valid = 0;
    edge_step();
    if (u_rsp_valid || v_rsp_valid) $fatal(1, "final responses not consumed");
    $display("P54-BRAM-DATA-OK checks=%0d", checks);
    $finish;
  end
endmodule
