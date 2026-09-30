// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Actual banked ven_l1d: an already-owned U load consumes its old value while
// V posts one store. The independent backend ignores ROM writes and accepts
// RAM writes; the policy must never filter its payload or fabricate a U ACK.
module tb_l1d_load_store_policy;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic flush_all = 0;
  logic c_req = 0, c_we = 0, c_pair_req = 0, c_code = 0;
  logic [31:0] c_addr = 0, c_wdata = 0, c_pair_addr = 0, c_pair_wdata = 0;
  logic [3:0] c_wstrb = 0, c_pair_wstrb = 0;
  logic [3:0] update_u = 4'hf, update_v = 4'hf;
  wire [31:0] c_rdata;
  wire c_ack, c_pair_ready, c_pair_ack;
  wire m_req, m_we, m_pair_req, m_rd_narrow;
  wire [31:0] m_addr, m_wdata, m_pair_addr, m_pair_wdata;
  wire [3:0] m_wstrb, m_pair_wstrb;
  wire [1:0] m_rd_size;
  logic stall_write = 0;
  wire m_ack = m_req && (!m_we || !stall_write);
  wire m_pair_ready = 1;
  wire m_pair_ack = 0;
  localparam int WORDS = 262144;
  logic [31:0] ram [WORDS], expected [WORDS];
  wire [31:0] m_rdata = ram[m_addr[19:2]];
  int writes = 0, backing_reads = 0, checks = 0;
  int control_errors = 0, rom_errors = 0, ram_errors = 0;
  int accepted = 0, ignored_rom = 0, masked_ram = 0, allones_ram = 0;
  int same_tag = 0, different_tag = 0, stalled = 0, rejected = 0;
  int u_window = 0, v_shadow = 0, code_witnesses = 0;

  ven_l1d dut (
    .clk, .rst_n, .flush_all, .golden(1'b0), .cacheable(1'b1),
    .snoop_inv_valid(1'b0), .snoop_inv_addr(32'd0),
    .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack,
`ifdef VEN_L1D_CODE_BUFFER
    .c_code,
`endif
`ifdef VEN_L1D_STORE_POLICY
    .c_store_update_mask(update_u), .c_pair_store_update_mask(update_v),
`endif
    .c_pair_req, .c_pair_addr, .c_pair_wdata, .c_pair_wstrb,
    .c_pair_ready, .c_pair_ack, .dbg_serve(),
    .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack,
    .m_pair_req, .m_pair_addr, .m_pair_wdata, .m_pair_wstrb,
    .m_pair_ready, .m_pair_ack, .m_rd_narrow, .m_rd_size
  );

  function automatic bit is_rom(input logic [31:0] address);
    return address >= 32'hc0000 && address < 32'h100000;
  endfunction
  function automatic bit resident(input logic [31:0] address);
    return (dut.dc_val[address[11:5]][0] &&
            dut.dc_tag[address[11:5]][0] == address[31:12]) ||
           (dut.dc_val[address[11:5]][1] &&
            dut.dc_tag[address[11:5]][1] == address[31:12]);
  endfunction
  always @(posedge clk) begin
    if (rst_n && m_req && m_ack) begin
      if (m_addr >= 32'h100000) $fatal(1, "backend address outside fixture");
      if (m_we) begin
        writes <= writes + 1;
        if (!is_rom(m_addr))
          for (int b = 0; b < 4; b++)
            if (m_wstrb[b]) ram[m_addr[19:2]][8*b+:8] <= m_wdata[8*b+:8];
      end else backing_reads <= backing_reads + 1;
    end
    if (rst_n && m_pair_req) $fatal(1, "load/store must post V on single backing slot");
  end
  task automatic require(input bit good, input string label);
    checks++;
    if (!good) begin
      control_errors++;
      if (control_errors <= 12) $display("LOADSTORE-CONTROL-MISMATCH %s", label);
    end
  endtask
  task automatic data_check(input logic [31:0] address, value,
                            input string label);
    checks++;
    if (value !== expected[address[19:2]]) begin
      if (is_rom(address)) rom_errors++; else ram_errors++;
      if (rom_errors + ram_errors <= 12)
        $display("LOADSTORE-DATA-MISMATCH %s a=%08x got=%08x want=%08x",
                 label, address, value, expected[address[19:2]]);
    end
  endtask
  task automatic wait_idle;
    int guard = 0;
    while (dut.st != 0) begin
      @(negedge clk);
      if (++guard > 100) $fatal(1, "fill did not drain");
    end
  endtask
  task automatic flush_cache;
    wait_idle();
    @(negedge clk); flush_all = 1;
    @(negedge clk); flush_all = 0;
    @(negedge clk);
  endtask
  task automatic read_at(input logic [31:0] address, input bit code,
                         input string label);
    logic [31:0] value;
    bit done = 0;
    int guard = 0;
    @(negedge clk);
    c_req = 1; c_we = 0; c_addr = address; c_wstrb = 4'hf; c_code = code;
    while (!done) begin
      @(posedge clk);
      if (c_ack) begin value = c_rdata; done = 1; end
      if (++guard > 100) $fatal(1, "read timeout a=%08x", address);
    end
    data_check(address, value, label);
    @(negedge clk); c_req = 0; c_code = 0; c_wstrb = 0;
    wait_idle();
  endtask
  task automatic exercise(input logic [31:0] ua, va,
                          input logic [3:0] policy,
                          input int disposition, input string label);
    int base_writes, base_reads;
    logic [31:0] u_value;
    logic [31:0] v_value;
    bit same_line;
    same_line = ua[31:5] == va[31:5];
    flush_cache();
`ifdef VEN_L1D_CODE_BUFFER
    read_at(va, 1, "prime V code");
    require(dut.code_valid_q, "primed V code buffer absent");
    code_witnesses++;
`endif
    read_at(va, 0, "prime V data");
    read_at(va, 0, "prime V complete registered window");
    read_at(ua, 0, "prime U data");
    read_at(ua, 0, "prime U complete registered window");
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    // Both U/V lines are now resident. A third, unrelated window removes U
    // from the saved-window pair without evicting either physical tag. The
    // following V->U captures establish primary U and shadow V via real reads,
    // instead of letting a shadow reuse leave the opposite ownership in place.
    read_at(32'h80, 0, "prime unrelated third line");
    read_at(32'h80, 0, "prime unrelated complete window");
    read_at(va, 0, "capture V window before U");
    read_at(ua, 0, "capture U with V shadow");
`endif
    require(resident(ua) && resident(va), "U and V physical tags not resident");
    @(negedge clk);
    c_req = 1; c_we = 0; c_code = 0; c_addr = ua; c_wstrb = 4'hf;
    c_pair_req = 0;
    @(posedge clk); #1;
    require(c_ack && (dut.rd_match || dut.window_reuse || dut.shadow_reuse),
            "U response not owned before younger V request");
    u_value = c_rdata;
    data_check(ua, u_value, "registered older U");
`ifdef VEN_L1D_WINDOW_REUSE
    if (dut.window_valid_q && dut.rd_addr_q[31:5] == ua[31:5]) u_window++;
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    if (dut.shadow_valid_q && dut.shadow_line_addr_q == va[31:5]) v_shadow++;
`endif
`endif
    base_writes = writes;
    v_value = 32'h0720_0720 ^ (32'(accepted) << 8);
    @(negedge clk);
    update_u = 0; // U is a load; its store advisory must be irrelevant.
    update_v = policy;
    c_pair_req = 1; c_pair_addr = va; c_pair_wdata = v_value; c_pair_wstrb = 4'hf;
    stall_write = disposition == 1;
    #1;
    require(c_ack && c_rdata === u_value, "V request changed owned U result");
    if (disposition == 2) begin
      require(!c_pair_ready && !c_pair_ack && !m_req,
              "equal-bank rejected V escaped to backend");
      @(posedge clk);
      require(c_ack && c_rdata === u_value, "rejected V spoiled consumed U value");
      rejected++;
    end else if (disposition == 1) begin
      repeat (3) begin
        @(posedge clk);
        // U's first owned response has already been consumed. Without window
        // reuse, a held U must recapture on alternate clocks; lack of an ACK
        // then is not a stall/corruption. V still cannot post on any edge.
        require(!c_pair_ack && !m_ack && writes == base_writes,
                "stalled V accepted early");
        if (c_ack) require(c_rdata === u_value, "stalled V changed consumed U value");
      end
      stalled++;
    end else begin
      require(c_pair_ready && c_pair_ack && m_req && m_we && m_ack &&
              m_addr == va && m_wdata == v_value && m_wstrb == 4'hf &&
              !m_pair_req, "accepted V backing payload/owner changed");
      @(posedge clk);
      require(c_ack && c_rdata === u_value && c_pair_ack,
              "acceptance edge did not preserve consumed U value");
      if (!is_rom(va)) expected[va[19:2]] = v_value;
      accepted++;
      if (is_rom(va)) ignored_rom++;
      else if (policy == 0) masked_ram++;
      else allones_ram++;
      if (same_line) same_tag++; else different_tag++;
    end
    @(negedge clk);
    c_req = 0; c_pair_req = 0; c_wstrb = 0; c_pair_wstrb = 0; stall_write = 0;
    require(writes == base_writes + (disposition == 0 ? 1 : 0),
            "V not posted exactly once or withdrawn V posted");
    require(ram[va[19:2]] === expected[va[19:2]], "backend ignored/write policy mismatch");
    if (disposition != 0) begin
      require(resident(ua) && resident(va), "unaccepted V invalidated resident tag");
    end else begin
`ifdef VEN_L1D_STORE_POLICY
      if (policy == 0) begin
        require(!resident(va), "accepted masked V retained target resident tag");
        if (!same_line) require(resident(ua), "masked V invalidated unrelated U tag");
      end else require(resident(va), "all-ones V invalidated allowed RAM target");
`endif
    end
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    if (!same_line) begin
      if (disposition == 0)
        require(!dut.shadow_valid_q || dut.shadow_line_addr_q != va[31:5],
                "accepted V retained stale target shadow owner");
      else require(dut.shadow_valid_q && dut.shadow_line_addr_q == va[31:5],
                   "unaccepted V discarded untouched target shadow owner");
    end
`endif
    base_reads = backing_reads;
    read_at(va, 0, {label, " final data"});
`ifdef VEN_L1D_STORE_POLICY
    if (disposition == 0 && policy == 0)
      require(backing_reads > base_reads, "masked V target did not refill from backend");
    else require(backing_reads == base_reads, "unaccepted/all-ones V caused data refill");
`endif
    read_at(va, 0, {label, " repeat data/window"});
    read_at(ua, 0, {label, " U after V"});
`ifdef VEN_L1D_CODE_BUFFER
    read_at(va, 1, {label, " final code"});
    read_at(va, 1, {label, " repeat code"});
`endif
  endtask

  initial begin
    for (int i = 0; i < WORDS; i++) begin
      ram[i] = 32'hc35a_0000 ^ 32'(i);
      expected[i] = ram[i];
    end
    repeat (5) @(negedge clk); rst_n = 1;
    exercise(32'hc0620, 32'hc0624, 0, 0, "same-tag ignored ROM");
    exercise(32'hc0620, 32'hd0624, 0, 0, "same-set different-tag ignored ROM");
    exercise(32'h006020, 32'hc0624, 0, 0, "RAM U different-tag ignored ROM");
    exercise(32'hc0620, 32'h006024, 0, 0, "ROM U masked writable RAM");
    exercise(32'h006020, 32'h006024, 0, 0, "same-tag masked writable RAM");
    exercise(32'h006020, 32'h016024, 0, 0, "same-set different-tag masked RAM");
    exercise(32'h006020, 32'h006024, 4'hf, 0, "same-tag all-ones RAM control");
    exercise(32'h006020, 32'h016024, 4'hf, 0, "different-tag all-ones RAM control");
    exercise(32'hc0620, 32'hc0624, 0, 1, "stalled then withdrawn ROM V");
    exercise(32'h006020, 32'h016024, 0, 1, "stalled then withdrawn RAM V");
    exercise(32'hc0620, 32'hd0620, 0, 2, "equal-bank rejected ROM V");
    exercise(32'h006020, 32'h016020, 0, 2, "equal-bank rejected RAM V");
    require(accepted == 8 && ignored_rom == 3 && masked_ram == 3 &&
            allones_ram == 2 && same_tag == 3 && different_tag == 5 &&
            stalled == 2 && rejected == 2, "coverage populations incomplete");
`ifdef VEN_L1D_WINDOW_REUSE
    require(u_window == 12, "registered primary-window witnesses incomplete");
`ifdef VEN_L1D_TWO_WINDOW_REUSE
    require(v_shadow > 0, "no target V shadow-window owner exercised");
`endif
`endif
`ifdef VEN_L1D_CODE_BUFFER
    require(code_witnesses == 12, "code-buffer witnesses incomplete");
`endif
    $display("LOADSTORE-RESULT checks=%0d control_errors=%0d rom_errors=%0d ram_errors=%0d accepted=%0d ignored_rom=%0d masked_ram=%0d allones_ram=%0d same_tag=%0d different_tag=%0d stalled=%0d rejected=%0d u_window=%0d v_shadow=%0d code=%0d",
             checks, control_errors, rom_errors, ram_errors, accepted, ignored_rom,
             masked_ram, allones_ram, same_tag, different_tag, stalled, rejected,
             u_window, v_shadow, code_witnesses);
    if (control_errors || rom_errors || ram_errors) $fatal(1, "LOADSTORE-POLICY-FAIL");
    $display("LOADSTORE-POLICY-OK");
    $finish;
  end
  initial begin #1000000; $fatal(1, "LOADSTORE fixture watchdog"); end
endmodule
