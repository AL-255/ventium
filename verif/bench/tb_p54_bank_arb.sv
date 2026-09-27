`timescale 1ns/1ps
module tb_p54_bank_arb;
  logic [1:0] req_valid;
  logic [1:0][31:0] req_paddr;
  logic [1:0][1:0] req_size_log2;
  logic [7:0] bank_ready;
  logic [1:0] req_grant, req_split;
  logic [1:0][7:0] req_banks;
  logic [7:0] used_banks;
  logic bank_conflict;
  int unsigned rng, seed;
  int checks = 0;
  ven_p54_bank_arb dut(.*);

  function automatic logic [7:0] reference_banks(input logic [31:0] addr,
                                                  input logic [1:0] lg);
    logic [7:0] mask;
    mask = '0;
    for (int byte_index = 0; byte_index < (1 << lg); byte_index++)
      if ((int'(addr[4:0]) + byte_index) < 32)
        mask[(int'(addr[4:0]) + byte_index) / 4] = 1'b1;
    return mask;
  endfunction

  task automatic check_case();
    logic [1:0] split_expected, grant_expected;
    logic [1:0][7:0] banks_expected;
    logic [7:0] used_expected;
    logic conflict_expected;
    for (int lane = 0; lane < 2; lane++) begin
      split_expected[lane] = (int'(req_paddr[lane][4:0]) +
                              (1 << req_size_log2[lane])) > 32;
      banks_expected[lane] = split_expected[lane] ? '0 :
          reference_banks(req_paddr[lane], req_size_log2[lane]);
    end
    grant_expected[0] = req_valid[0] && !split_expected[0] &&
        ((banks_expected[0] & bank_ready) == banks_expected[0]);
    conflict_expected = req_valid[0] && req_valid[1] &&
        !split_expected[0] && !split_expected[1] &&
        ((banks_expected[0] & banks_expected[1]) != 0);
    grant_expected[1] = req_valid[1] && !split_expected[1] &&
        (!req_valid[0] || grant_expected[0]) &&
        ((banks_expected[1] & bank_ready) == banks_expected[1]) &&
        (!grant_expected[0] || !conflict_expected);
    used_expected = (grant_expected[0] ? banks_expected[0] : 8'd0) |
                    (grant_expected[1] ? banks_expected[1] : 8'd0);
    #1;
    if ({req_grant, req_split, req_banks, used_banks, bank_conflict} !==
        {grant_expected, split_expected, banks_expected, used_expected,
         conflict_expected})
      $fatal(1, "bank arbitration mismatch at check %0d", checks);
    checks++;
  endtask

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rng = seed;
    req_valid = 2'b11; bank_ready = '1;
    req_size_log2 = '{2'd2, 2'd2};
    req_paddr = '{32'h1024, 32'h1000}; // distinct lines/banks
    check_case();
    if (req_grant !== 2'b11) $fatal(1, "distinct-bank pair did not grant");
    req_paddr = '{32'h1020, 32'h1000}; // same bank, different lines
    check_case();
    if (req_grant !== 2'b01 || !bank_conflict)
      $fatal(1, "same-bank pair did not hold V");
    req_paddr = '{32'h1020, 32'h101f}; // older U crosses line
    check_case();
    if (req_grant !== 2'b00) $fatal(1, "V passed split U");
    req_paddr = '{32'h1024, 32'h1001};
    req_size_log2 = '{2'd3, 2'd3}; // both unaligned 64-bit extents
    check_case();
    bank_ready = 8'hfe; // U bank zero unavailable
    check_case();
    if (req_grant[1]) $fatal(1, "V passed blocked U");
    for (int n = 0; n < 32768; n++) begin
      rng = rng * 32'd1664525 + 32'd1013904223;
      req_paddr[0] = {20'd0, rng[11:0]};
      req_valid[0] = rng[13]; req_size_log2[0] = rng[15:14];
      rng = rng * 32'd1664525 + 32'd1013904223;
      req_paddr[1] = {20'd0, rng[11:0]};
      req_valid[1] = rng[13]; req_size_log2[1] = rng[15:14];
      bank_ready = rng[23:16];
      check_case();
    end
    $display("P54-BANK-ARB-OK seed=%0d checks=%0d", seed, checks);
    $finish;
  end
endmodule
