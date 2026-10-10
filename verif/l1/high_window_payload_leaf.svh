// Passive independent backing-memory witness; no deposits into DUT state.
int hw_valid=0, hw_shadow=0, hw_primary=0, hw_duplicate=0, hw_blocked=0;
always @(posedge clk) if (rst_n) begin
  if (c_rdata_hi_valid) begin
    hw_valid++;
    if (c_rdata_hi !== word_at(c_addr+4))
      $fatal(1,"HIGH-WINDOW-BACKING: addr=%08x got=%08x expected=%08x",
             c_addr,c_rdata_hi,word_at(c_addr+4));
    if (dut.shadow_reuse) hw_shadow++; else hw_primary++;
    if (dut.shadow_reuse && dut.rd_match) hw_duplicate++;
  end
  if (dut.rd_match && !dut.rd_full_line_q && !dut.shadow_reuse) begin
    if (c_rdata_hi_valid) $fatal(1,"HIGH-WINDOW-PARTIAL: borrowed bank exposed");
    hw_blocked++;
  end
end

task automatic run_high_window_payload;
  // Every legal unaligned 64-bit span, for both saved physical owners.
  for (int offset=0; offset<=24; offset++) begin
    iw_setup('h1000,'h1040);
    read_at(32'h1000+32'(offset));
    read_at(32'h1040+32'(offset));
  end
  // Low dword fits, but a high dword at +4 would cross the line.
  for (int offset=25; offset<=28; offset++) begin
    iw_setup('h1000,'h1040);
    @(negedge clk); c_req=1; c_addr=32'h1000+32'(offset);
    #1;
    if (!c_ack || c_rdata_hi_valid) $fatal(1,"HIGH-WINDOW-EXTENT");
    @(posedge clk); @(negedge clk); c_req=0;
  end
  // Rejected next lookahead must not turn raw high payload into a valid beat.
  iw_setup('h1000,'h1040);
  arm_old('h1000);
  c_next_req=1; c_next_commit=0; c_next_addr='h8000;
  repeat (3) begin
    #1;
    if (!c_ack || !dut.mc_lookup_next || c_rdata_hi_valid)
      $fatal(1,"HIGH-WINDOW-LOOKAHEAD: changed high-word qualification");
    @(posedge clk); @(negedge clk);
  end
  c_req=0; c_next_req=0;
  if (hw_valid==0 || hw_shadow==0 || hw_primary==0 || hw_duplicate==0 || hw_blocked==0)
    $fatal(1,"HIGH-WINDOW-COVERAGE valid=%0d shadow=%0d primary=%0d duplicate=%0d blocked=%0d",
           hw_valid,hw_shadow,hw_primary,hw_duplicate,hw_blocked);
  iw_reset();
  $display("HIGH-WINDOW-PAYLOAD-OK valid=%0d shadow=%0d primary=%0d duplicate=%0d blocked=%0d",
           hw_valid,hw_shadow,hw_primary,hw_duplicate,hw_blocked);
endtask
