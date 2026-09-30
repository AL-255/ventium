// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The production L1 -> AXI -> Avalon -> actual ao486 cache/ROM policy.
// No CPU opcodes, saved states, guest mappings, or injected cache contents.
// A backend-ignored write must not create a contradictory resident L1 copy.
module tb_l1axi_ao486_romwrite;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  initial begin #100000000; $fatal(1,"ROMWRITE watchdog"); end
  logic req=0, we=0, code=0, flush=0, uma=0, jitter=0, hold_aw=0;
  logic [31:0] addr=0, data=0;
  logic [3:0] mask=0;
  logic policy_override=0;
  logic [3:0] override_u=4'hf, override_v=4'hf;
  function automatic logic [3:0] platform_update_mask(input logic [31:0] physical);
    logic [3:0] bits;
    for (int b=0;b<4;b++) begin
      logic [31:0] effective;
      effective=(physical+32'(b)) & 32'h0fffffff;
      bits[b]=!(effective>=32'hc0000 && effective<=32'hfffff);
    end
    return bits;
  endfunction
  wire [3:0] update_mask=policy_override ? override_u : platform_update_mask(addr);
`ifdef VEN_P54_DUAL_STORE_PAIR
  logic pair_req=0;
  logic [31:0] pair_addr=0, pair_data=0;
  wire pair_ready, pair_ack;
  wire [3:0] pair_update_mask=policy_override ? override_v : platform_update_mask(pair_addr);
`endif
  wire [31:0] result;
  wire ack, bus_err, idle;
  wire [3:0] awid, bid, arid, rid;
  wire [39:0] awaddr, araddr;
  wire [7:0] awlen, arlen;
  wire [2:0] awsize, arsize;
  wire [1:0] awburst, arburst, bresp, rresp;
  wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  wire arvalid, arready, rlast, rvalid, rready;
  wire [31:0] wdata, rdata;
  wire [3:0] wstrb;
  wire bridge_awready, bridge_wready, bridge_bvalid;
  wire allow_aw=!hold_aw && (!jitter || (clocks%5>=2));
  wire allow_w=!jitter || (clocks%7>=3);
  wire allow_b=!jitter || (clocks%11>=4);
  assign awready=bridge_awready && allow_aw;
  assign wready=bridge_wready && allow_w;
  assign bvalid=bridge_bvalid && allow_b;

  // PAM remains the current platform integration's cacheable-R/W default.
  // The independent real ao486 backend suppresses ROM writes. This test
  // deliberately exposes any disagreement rather than pretending PAM alone
  // already implements an acknowledged/ignored ROM-write contract.
  ventium_l1_axi #(.REMAP_BASE(40'd0), .ADDR_MASK(32'hFFFFFFFF),
      .LINE_REPLAY(1'b0), .NB_TOM_MB4(8'd64)) dut (
      .core_clk(clk), .core_rst_n(rst_n), .axi_clk(clk), .axi_rst_n(rst_n),
      .flush_all(flush), .golden_l1(1'b0), .smm_active(1'b0),
      .smbase(32'h30000), .smm_flush_o(), .core_lock(1'b0), .core_lock_hold(1'b0),
      .core_req(req), .core_we(we), .core_code(code), .core_addr(addr), .core_lin(addr),
`ifdef VEN_L1D_STORE_POLICY
      .core_store_update_mask(update_mask),
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
      .core_store_pair_req(pair_req), .core_store_pair_addr(pair_addr),
      .core_store_pair_wdata(pair_data), .core_store_pair_wstrb(4'hf),
      .core_store_pair_ready(pair_ready), .core_store_pair_ack(pair_ack),
`ifdef VEN_L1D_STORE_POLICY
      .core_store_pair_update_mask(pair_update_mask),
`endif
`endif
      .core_wdata(data), .core_wstrb(mask), .core_rdata(result), .core_ack(ack),
      .core_ic_nocache(), .bus_err(bus_err), .cr0_cd(1'b0),
      .shutdown(1'b0), .m_idle(idle),
      .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
      .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(),
      .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(),
      .m_axi_awvalid(awvalid), .m_axi_awready(awready),
      .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
      .m_axi_wvalid(wvalid), .m_axi_wready(wready),
      .m_axi_bid(bid), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
      .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
      .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(),
      .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(),
      .m_axi_arvalid(arvalid), .m_axi_arready(arready),
      .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
      .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
  );
  wire [29:0] av_addr;
  wire [31:0] av_din, av_dout;
  wire [3:0] av_be, av_count;
  wire av_write, av_read, av_busy, av_valid;
  ven_axi2avalon bridge (
      .clk(clk), .rst_n(rst_n),
      .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
      .s_axi_awsize(awsize), .s_axi_awburst(awburst),
      .s_axi_awvalid(awvalid && allow_aw), .s_axi_awready(bridge_awready),
      .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
      .s_axi_wvalid(wvalid && allow_w), .s_axi_wready(bridge_wready),
      .s_axi_bid(bid), .s_axi_bresp(bresp),
      .s_axi_bvalid(bridge_bvalid), .s_axi_bready(bready && allow_b),
      .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
      .s_axi_arsize(arsize), .s_axi_arburst(arburst),
      .s_axi_arvalid(arvalid), .s_axi_arready(arready),
      .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
      .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
      .avm_address(av_addr), .avm_writedata(av_din), .avm_byteenable(av_be),
      .avm_burstcount(av_count), .avm_write(av_write), .avm_read(av_read),
      .avm_waitrequest(av_busy), .avm_readdatavalid(av_valid), .avm_readdata(av_dout)
  );
  wire [24:0] ddr_addr;
  wire [63:0] ddr_din;
  wire [7:0] ddr_be, ddr_count;
  wire ddr_rd, ddr_we, vga_rd, vga_we;
  logic [63:0] ddr_dout=0;
  logic ddr_valid=0, ddr_busy=0;
  l2_cache #(.ADDRBITS(24)) backend (
      .CLK(clk), .RESET(!rst_n), .DISABLE(1'b0),
      .l2_inv_pulse(1'b0), .l2_inv_addr(25'd0),
      .CPU_ADDR(av_addr), .CPU_DIN(av_din), .CPU_DOUT(av_dout),
      .CPU_DOUT_READY(av_valid), .CPU_BE(av_be), .CPU_BURSTCNT(av_count),
      .CPU_BUSY(av_busy), .CPU_RD(av_read), .CPU_WE(av_write),
      .DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be),
      .DDRAM_BURSTCNT(ddr_count), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
      .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_valid), .DDRAM_BUSY(ddr_busy),
      .VGA_ADDR(), .VGA_DIN(8'd0), .VGA_DOUT(), .VGA_MODE(3'd0),
      .VGA_RD(vga_rd), .VGA_WE(vga_we), .VGA_WR_SEG(6'd0), .VGA_RD_SEG(6'd0),
      .VGA_FB_EN(1'b0), .uma_ram(uma)
  );

  localparam int WORDS=262160; //1MiB+64B for the ROM/RAM boundary control
  logic [31:0] ram[WORDS], expected[WORDS];
  int left=0, delay_n=0, next_word=0, clocks=0;
  int ar_total=0, aw_total=0, ddr_reads=0, ddr_writes=0, av_writes=0;
  int checks=0, errors=0, ram_errors=0, rom_errors=0, reads=0, stores=0;
  int code_witnesses=0, array_witnesses=0, window_witnesses=0, shadow_witnesses=0;
  int accepted_store_bank_edges=0;
  int pair_stores=0, no_extra_ar=0, no_global_flush=0, policy_controls=0;
  bit rom_phase=0;
  always @(posedge clk) begin
    clocks <= clocks+1;
    if (rst_n && bus_err) $fatal(1,"unexpected bus_err");
    if (rst_n && (vga_rd || vga_we)) $fatal(1,"ROM/RAM fixture reached VGA aperture");
    if (arvalid && arready) ar_total <= ar_total+1;
    if (awvalid && awready) aw_total <= aw_total+1;
    if (av_write && !av_busy) av_writes <= av_writes+1;
`ifdef VEN_L1D_BANKED_DATA
    if (rst_n && dut.u_l1d.bank_store_we) accepted_store_bank_edges <= accepted_store_bank_edges+1;
`endif
    ddr_valid <= 0;
    if (ddr_rd && !ddr_busy) begin
      if (ddr_count != 8 || int'(ddr_addr)*2+15 >= WORDS)
        $fatal(1,"DDR read ownership/shape addr=%x count=%0d",ddr_addr,ddr_count);
      ddr_reads <= ddr_reads+1;
      ddr_busy <= 1; left <= 8; delay_n <= 4; next_word <= int'(ddr_addr)*2;
    end
    if (ddr_we && !ddr_busy) begin
      if (ddr_count != 1 || int'(ddr_addr)*2+1 >= WORDS)
        $fatal(1,"DDR write ownership/shape");
      ddr_writes <= ddr_writes+1;
      for (int lane=0; lane<8; lane++)
        if (ddr_be[lane]) ram[int'(ddr_addr)*2+lane/4][8*(lane%4)+:8] <= ddr_din[8*lane+:8];
    end
    if (ddr_busy) begin
      if (delay_n != 0) delay_n <= delay_n-1;
      else begin
        ddr_dout <= {ram[next_word+1],ram[next_word]}; ddr_valid <= 1;
        next_word <= next_word+2; left <= left-1;
        delay_n <= jitter ? ((next_word % 3)+1) : 0;
        if (left == 1) ddr_busy <= 0;
      end
    end
  end
  function automatic logic [31:0] expected_word(input logic [31:0] a);
    logic [31:0] value;
    for (int byte_n=0;byte_n<4;byte_n++)
      value[8*byte_n+:8]=expected[(int'(a)+byte_n)>>2][8*((int'(a)+byte_n)&3)+:8];
    return value;
  endfunction
  task automatic require(input bit good, input string label);
    checks++;
    if (!good) begin
      errors++;
      if (rom_phase) rom_errors++; else ram_errors++;
      if (errors <= 16) $display("ROMWRITE-MISMATCH %s cyc=%0d",label,clocks);
    end
  endtask
  task automatic drain;
    int stable, guard;
    stable=0; guard=0;
    while (stable < 4) begin
      @(negedge clk);
      if (idle && !av_busy && !ddr_busy && dut.u_l1d.st == 0) stable++;
      else stable=0;
      if (++guard>5000) $fatal(1,"posted-write/fill drain timeout");
    end
  endtask
  task automatic flush_l1;
    drain();
    @(negedge clk); flush=1;
    @(negedge clk); flush=0;
    repeat(3) @(negedge clk);
  endtask
  task automatic read_at(input logic [31:0] a, input bit is_code, input string label);
    logic [31:0] captured;
    bit complete;
    int guard;
    @(negedge clk); req=1; we=0; code=is_code; addr=a; mask=4'hf;
    complete=0; guard=0;
    while (!complete) begin
      @(posedge clk);
      if (ack) begin
        captured=result; complete=1;
        if (dut.u_l1d.code_access) code_witnesses++;
        else array_witnesses++;
        if (dut.u_l1d.window_reuse) window_witnesses++;
        if (dut.u_l1d.shadow_reuse) shadow_witnesses++;
      end
      if (++guard>5000) $fatal(1,"read timeout %s %08x",label,a);
    end
    reads++;
    require(captured === expected_word(a),
            $sformatf("%s a=%08x code=%0d got=%08x want=%08x",label,a,is_code,captured,expected_word(a)));
    @(negedge clk); req=0; code=0; mask=0;
  endtask
  task automatic store_at(input logic [31:0] a, input logic [3:0] be,
                          input logic [31:0] value, input bit writable);
    bit complete;
    int guard;
    @(negedge clk); req=1; we=1; code=0; addr=a; mask=be; data=value;
    complete=0; guard=0;
    while (!complete) begin
      @(posedge clk); complete=ack;
      if (++guard>5000) $fatal(1,"store timeout a=%08x mask=%x",a,be);
    end
    stores++;
    if (writable)
      for (int byte_n=0;byte_n<4;byte_n++)
        if (be[byte_n]) expected[(int'(a)+byte_n)>>2][8*((int'(a)+byte_n)&3)+:8]=value[8*byte_n+:8];
    @(negedge clk); req=0; we=0; mask=0;
  endtask
  task automatic warm_sources(input logic [31:0] line);
    // Prime the second physical line first. A miss invalidates saved windows,
    // so the later switch must be a resident hit to prove shadow reuse.
    read_at(32'h00008001,0,"prime-other-window"); drain();
    read_at(line+1,0,"warm-D"); drain();
    read_at(line+1,0,"warm-window");
    read_at(line+8,1,"warm-code"); drain();
    read_at(line+1,0,"restore-D-window");
    // Populate another saved window so the original can occupy shadow_line_q.
    read_at(32'h00008001,0,"warm-other-window");
    read_at(line+1,0,"warm-shadow");
  endtask
  task automatic exercise_line(input logic [31:0] line, input bit writable,
                               input string label);
    int off, before_ddr_writes, before_ar;
    logic [31:0] value;
    rom_phase=!writable;
    // All16 masks include byte, word, dword, sparse masks, and zero-strobe.
    // Seven representative offsets cover every byte lane and both line edges.
    for (int position=0;position<7;position++) begin
      off=position<4 ? position : 25+position; //0,1,2,3,29,30,31
      for (int be=0;be<16;be++) begin
        flush_l1(); warm_sources(line); drain();
        before_ddr_writes=ddr_writes;
        value=32'hd359a671 ^ (32'(off)<<24) ^ (32'(be)*32'h01020408);
        store_at(line+32'(off),4'(be),value,writable);
        // Do not wait for external B before the next read: posted ordering is
        // part of the RAM positive control and the ignored-ROM contract.
        before_ar=ar_total;
        read_at(line+32'(off),0,{label," immediate-D"});
        if (writable && line<32'hc0000 && off<4) begin
          require(ar_total==before_ar,{label," resident ordinary RAM read lost"});
          no_extra_ar++;
        end
        read_at(line+(32'(off)&32'hFFFFFFFC),1,{label," immediate-code"});
        drain();
        if (!writable) require(ddr_writes==before_ddr_writes,{label," backend ignored store"});
        for (int byte_n=0;byte_n<4;byte_n++)
          require(ram[(int'(line)+off+byte_n)>>2] === expected[(int'(line)+off+byte_n)>>2],
                  {label," actual DDR bytes"});
        read_at(line+1,1,{label," unaligned-code"});
        read_at(line+8,1,{label," aligned-code"});
        // Evict code staging but retain the physically tagged D array.
        read_at(32'h00008100,1,"other-code"); drain();
        read_at(line+1,1,{label," code-revisit"});
        flush_l1(); read_at(line+1,0,{label," fresh-backing"}); drain();
      end
    end
  endtask
  task automatic unaffected_other_way;
    int before_ar;
    logic [31:0] target, unrelated;
    target=32'hc0200; unrelated=32'h00000200; //same L1 set, different physical tag
    rom_phase=1; flush_l1();
    read_at(unrelated+1,0,"unrelated warm"); drain();
    warm_sources(target); drain();
    before_ar=ar_total;
    store_at(target+1,4'h1,32'h72,0);
    read_at(unrelated+1,0,"unrelated same-set way after ignored store");
    require(ar_total==before_ar,"masked ROM store globally flushed unrelated RAM");
    no_global_flush++;
    read_at(target+1,0,"masked target reload"); drain();
  endtask
`ifdef VEN_L1D_STORE_POLICY
  task automatic explicit_policy_controls;
    int before_ar;
    logic [31:0] target, boundary_value;
    rom_phase=0; target=32'h5000;
    flush_l1(); warm_sources(target); drain();
    // Inactive policy zeros are not permission changes and cannot force a miss.
    policy_override=1; override_u=4'b0001;
    before_ar=ar_total;
    store_at(target,4'b0001,32'hdcba7654,1);
    read_at(target,0,"inactive policy zeros RAM");
    require(ar_total==before_ar,"inactive policy zero invalidated RAM");
    override_u=4'b0000;
    before_ar=ar_total;
    store_at(target,4'b0000,32'h98765432,1);
    read_at(target,0,"zero-strobe policy no-op");
    require(ar_total==before_ar,"zero-strobe policy invalidated RAM");
    // An active zero suppresses only the cached copy, NOT the actual RAM store.
    store_at(target,4'b0011,32'habcdef12,1);
    read_at(target,0,"active policy zero writable RAM refill"); drain();
    require(ram[int'(target)>>2]===expected[int'(target)>>2],"active policy zero lost backend store");
    // Partial-policy cross-line writes must invalidate each touched physical tag.
    flush_l1(); warm_sources(target); read_at(target+33,0,"cross policy next warm"); drain();
    override_u=4'b1110;
    store_at(target+31,4'hf,32'h1648ace0,1);
    read_at(target+31,0,"mixed-mask cross-line writable RAM"); drain();
    policy_override=0; policy_controls+=4;
    // Physical ROM/RAM boundary: the first byte is ignored, following bytes
    // remain genuine RAM writes. No whole-dword/first-byte policy shortcut.
    rom_phase=1; target=32'h000fffff;
    flush_l1(); read_at(target-2,0,"ROM boundary warm"); drain();
    read_at(target+1,0,"RAM boundary warm"); drain();
    boundary_value=32'h80a5f17b;
    store_at(target,4'hf,boundary_value,0);
    for (int b=1;b<4;b++)
      expected[(int'(target)+b)>>2][8*((int'(target)+b)&3)+:8]=boundary_value[8*b+:8];
    read_at(target,0,"ROM/RAM byte-policy boundary"); drain();
    require(ram[WORDS-16]===expected[WORDS-16],"ROM boundary preserved RAM strobes");
    policy_controls++;
  endtask
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
  task automatic store_pair_at(input logic [31:0] u, input logic [31:0] v,
                               input bit u_writable, input bit v_writable,
                               input bit warm_v=1);
    int guard;
    bit complete;
    flush_l1(); warm_sources(u & 32'hffffffe0);
    if (warm_v) begin read_at(v+1,0,"V warm"); drain(); end
    rom_phase=!(u_writable && v_writable);
    @(negedge clk);
    req=1; we=1; code=0; addr=u; data=32'h5938ad72; mask=4'hf;
    pair_req=1; pair_addr=v; pair_data=32'hc72516e8;
    complete=0; guard=0;
    while (!complete) begin
      @(posedge clk);
      if (ack) begin complete=1; require(pair_ack,"U/V acceptance not atomic"); end
      if (++guard>5000) $fatal(1,"paired store timeout");
    end
    if (u_writable) expected[int'(u)>>2]=data;
    if (v_writable) expected[int'(v)>>2]=pair_data;
    pair_stores++; stores+=2;
    @(negedge clk); req=0; we=0; pair_req=0; mask=0;
    read_at(u,0,"paired U immediate load"); read_at(v,0,"paired V immediate load"); drain();
    require(ram[int'(u)>>2]===expected[int'(u)>>2],"paired U actual backing");
    require(ram[int'(v)>>2]===expected[int'(v)>>2],"paired V actual backing");
    read_at(u,1,"paired U aligned code"); read_at(v+1,1,"paired V unaligned code"); drain();
  endtask
  task automatic pair_controls;
    store_pair_at(32'h4010,32'hc0204,1,0);
    store_pair_at(32'hc0210,32'h4004,0,1);
    store_pair_at(32'hc0210,32'hf0444,0,0);
    store_pair_at(32'h4010,32'h5004,1,1);
    store_pair_at(32'h4010,32'hc1204,1,0,0); //V nonallocating ROM miss
    store_pair_at(32'h4010,32'hd0264,1,uma);
    store_pair_at(32'h4010,32'hce004,1,1); //after shared enable, policy stillmask0
`ifdef VEN_L1D_STORE_POLICY
    policy_override=1; override_u=4'b0000; override_v=4'hf;
    store_pair_at(32'h5010,32'h6004,1,1);
    override_u=4'hf; override_v=4'b0000;
    store_pair_at(32'h5010,32'h6004,1,1);
    policy_override=0;
`endif
  endtask
`endif
  task automatic reset_policy(input bit uma_value);
    drain();
    @(negedge clk); rst_n=0; uma=uma_value;
    repeat(4) @(negedge clk); rst_n=1;
    repeat(160) @(negedge clk); drain();
  endtask
  initial begin
    int before_errors, before_ddr_writes;
    for (int i=0;i<WORDS;i++) begin
      ram[i]=32'h91826f34 ^ (32'(i)*32'h0103070b); expected[i]=ram[i];
    end
    repeat(4) @(negedge clk); rst_n=1;
    repeat(160) @(negedge clk); drain();
    for (int policy=0;policy<2;policy++) begin
      reset_policy(1'(policy)); jitter=1'(policy);
      before_errors=ram_errors;
      exercise_line(32'h00004000,1,"ordinary-RAM");
      require(ram_errors==before_errors,"ordinary RAM positive matrix");
      $display("ROMWRITE-RAM-CONTROL uma=%0d errors=%0d",uma,ram_errors-before_errors);
      exercise_line(32'h000c0200,0,"video-ROM");
      exercise_line(32'h000f0440,0,"system-ROM");
      exercise_line(32'h000d0260,uma,"D-window");
      // Queue an older shared-enable command and a younger shared store
      // before external AW admission, then release them in actual bus order.
      // This makes ownership independent of frontend/live-enable guesses.
      // The shared-folder escape is real platform policy: the first magic
      // store enables later CE000-CFFFF writes. Its own backend write remains
      // ignored because shr_rgn_en updates on that command's acceptance edge.
      rom_phase=1; flush_l1(); warm_sources(32'h000ce000); drain();
      before_ddr_writes=ddr_writes;
      @(negedge clk); hold_aw=1;
      store_at(32'h000ce000,4'h3,32'h0000a345,0);
      store_at(32'h000ce004,4'hf,32'h8517a9c2,1);
      @(negedge clk); hold_aw=0;
      drain();
      require(ddr_writes==before_ddr_writes+1,"older shared-enable/younger write order");
      require(ram[32'hce000>>2]===expected[32'hce000>>2],"enable command's own store ignored");
      require(ram[32'hce004>>2]===expected[32'hce004>>2],"younger shared write reached RAM");
      read_at(32'h000ce001,0,"shared enable cached bytes");
      flush_l1();
      exercise_line(32'h000ce000,1,"shared-enabled-RAM");
      unaffected_other_way();
`ifdef VEN_L1D_STORE_POLICY
      explicit_policy_controls();
`endif
`ifdef VEN_P54_DUAL_STORE_PAIR
      pair_controls();
`endif
    end
    rom_phase=0;
    require(code_witnesses>0 && array_witnesses>0,"code and D read sources exercised");
    require(window_witnesses>0 && shadow_witnesses>0,"window and shadow read sources exercised");
    $display("ROMWRITE-RESULT checks=%0d errors=%0d ram_errors=%0d rom_errors=%0d reads=%0d stores=%0d ars=%0d aws=%0d av_writes=%0d ddr_reads=%0d ddr_writes=%0d code=%0d array=%0d window=%0d shadow=%0d bank_store_edges=%0d pairs=%0d no_extra_ar=%0d no_global_flush=%0d policy_controls=%0d clocks=%0d",
        checks,errors,ram_errors,rom_errors,reads,stores,ar_total,aw_total,av_writes,
        ddr_reads,ddr_writes,code_witnesses,array_witnesses,window_witnesses,shadow_witnesses,
        accepted_store_bank_edges,pair_stores,no_extra_ar,no_global_flush,policy_controls,clocks);
    if (ram_errors != 0) $fatal(1,"ROMWRITE-RAM-CONTROL-FAIL");
    if (rom_errors != 0) $fatal(1,"ROMWRITE-CACHE-FAIL");
    $display("ROMWRITE-CACHE-OK"); $finish;
  end
endmodule
