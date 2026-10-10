`timescale 1ns/1ps
module tb;
  // Control expressions and both payload expressions are inserted from the
  // actual source/recipe. Opcode eligibility is an unconstrained qualifier:
  // it can only narrow the original complete-beat condition, not broaden it.
  localparam [5:0] S_FLOAD = 6'd14;
  reg [5:0] state;
  reg cycle_mode, q_f_mem_read, q_f_mem_write, mem_ack, fsm_case_enabled;
  reg fp_shared_early_retire_ok, fp_dbg_active, bus_rdata_hi_valid;
  reg fx_eng, fx_start, tf_at_issue, rf_at_issue, op_eligible;
  reg [3:0] q_f_mbytes, f_step;
  reg [31:0] cur_lin_nat;
  reg [79:0] f_mem80;
  reg [31:0] mem_rdata, bus_rdata_hi;
  wire fp_load64_take, fp_shared_load_cmd;
  wire [79:0] old_mem, new_mem;
  integer checks = 0, valid_reads = 0, wide_reads = 0;
  // SOURCE_EXPRESSIONS
  task check;
    begin
      #1;
      if (state != S_FLOAD || fp_shared_load_cmd || (!q_f_mem_read && q_f_mem_write)) begin
        if (old_mem !== new_mem)
          $fatal(1, "PAYLOAD mismatch state=%0d bytes=%0d step=%0d ack=%b hi=%b old=%h new=%h",
            state, q_f_mbytes, f_step, mem_ack, bus_rdata_hi_valid, old_mem, new_mem);
        checks = checks + 1;
        if (fp_shared_load_cmd) valid_reads = valid_reads + 1;
        if (fp_shared_load_cmd && fp_load64_take) wide_reads = wide_reads + 1;
      end
    end
  endtask
  initial begin
    f_mem80 = 80'habcd1122334455667788;
    mem_rdata = 32'hdeadbeef;
    bus_rdata_hi = 32'h01234567;
    for (integer flags = 0; flags < 8192; flags = flags + 1) begin
      {cycle_mode,q_f_mem_read,q_f_mem_write,mem_ack,fsm_case_enabled,
       fp_shared_early_retire_ok,fp_dbg_active,bus_rdata_hi_valid,fx_eng,
       fx_start,tf_at_issue,rf_at_issue,op_eligible} = flags[12:0];
      for (integer st = 0; st < 2; st = st + 1) begin
        state = st == 0 ? S_FLOAD : 6'd0;
        for (integer size = 0; size < 3; size = size + 1) begin
          q_f_mbytes = size == 0 ? 4'd4 : size == 1 ? 4'd8 : 4'd10;
          for (integer stepno = 0; stepno < 3; stepno = stepno + 1) begin
            f_step = stepno[3:0];
            for (integer addr = 0; addr < 4; addr = addr + 1) begin
              case (addr)
                0: cur_lin_nat = 32'h00abc000;
                1: cur_lin_nat = 32'h00abcff8;
                2: cur_lin_nat = 32'h00abcff9;
                3: cur_lin_nat = 32'h00abcfff;
              endcase
              check();
            end
          end
        end
      end
    end
    // Every payload bit sees random data with actual eligible m32/m64 beats.
    {cycle_mode,q_f_mem_read,q_f_mem_write,mem_ack,fsm_case_enabled,
     fp_shared_early_retire_ok,fp_dbg_active,bus_rdata_hi_valid,fx_eng,
     fx_start,tf_at_issue,rf_at_issue,op_eligible} = 13'b1101110100001;
    state = S_FLOAD; cur_lin_nat = 0;
    for (integer n = 0; n < 4096; n = n + 1) begin
      f_mem80 = {$random,$random,$random};
      mem_rdata = $random; bus_rdata_hi = $random;
      q_f_mbytes = n[1] ? 4'd4 : 4'd8;
      f_step = {3'd0,n[0]};
      check();
    end
    if (checks < 300000 || valid_reads < 2000)
      $fatal(1, "missing valid sampling coverage checks=%0d reads=%0d", checks, valid_reads);
`ifdef VEN_FP_LOAD64
    if (wide_reads < 1000) $fatal(1, "wide path not exercised: %0d", wide_reads);
`else
    if (wide_reads != 0) $fatal(1, "disabled wide path activated");
`endif
    $display("FP-LOAD-PAYLOAD-OK checks=%0d reads=%0d wide=%0d", checks, valid_reads, wide_reads);
    $finish;
  end
endmodule
