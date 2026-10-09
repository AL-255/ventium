// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// The runner extracts the actual candidate assignments, not a rewritten DUT.
module tb_fp_scalar_load_cmd;
  import ventium_decode_pkg::*;
  localparam logic S_FLOAD=1'b0, S_FEXEC=1'b1;
  logic state, cycle_mode, q_f_mem_read, q_f_mem_write, mem_ack;
  logic fsm_case_enabled, fp_shared_early_retire_ok, fp_dbg_active;
  logic fp_shared_load_cmd, fp_load64_take;
  logic [3:0] q_f_mbytes, f_step;
  fxop_e q_fxop;
  logic [15:0] fctrl, fstat;
  logic [79:0] f_mem80, fp_shared_cmd_mem;
  logic [31:0] mem_rdata, bus_rdata_hi;
  // Keep the coverage witness observable across timed-task coroutine lowering.
  int checks /* verilator public_flat_rw */;
`include "scalar_load_assignments.svh"

  task automatic defaults;
    state=S_FLOAD; cycle_mode=1; q_f_mem_read=1; q_f_mem_write=0;
    mem_ack=1; fsm_case_enabled=1; fp_shared_early_retire_ok=1; fp_dbg_active=0;
    q_f_mbytes=4; f_step=0; fp_load64_take=0;
    fctrl=16'h037f; fstat=0;
    f_mem80=80'h76543210abcdef012345;
    mem_rdata=32'hdeadbeef; bus_rdata_hi=32'h87654321;
  endtask

  task automatic check;
    logic known, expected;
    logic [79:0] payload;
    known=(q_fxop inside {FX_FLD_M32,FX_FLD_M64,FX_FILD_M32,FX_FILD_M64,FX_AR_M32,FX_AR_M64});
`ifdef VEN_FP_SCALAR_LOAD_CMD
    known |= (q_fxop inside {FX_AR_I32,FX_FCOM_M32,FX_FCOM_M64}) &&
             fctrl[5:0]==6'h3f && !fstat[7];
`endif
    expected=known && cycle_mode && state==S_FLOAD && q_f_mem_read && !q_f_mem_write &&
        mem_ack && fsm_case_enabled && fp_shared_early_retire_ok && !fp_dbg_active &&
        ((q_f_mbytes==4 && f_step==0) || (q_f_mbytes==8 && (f_step==1 || fp_load64_take)));
    payload=!expected ? f_mem80 : fp_load64_take ? {f_mem80[79:64],bus_rdata_hi,mem_rdata} :
        f_step==0 ? {f_mem80[79:32],mem_rdata} : {f_mem80[79:64],mem_rdata,f_mem80[31:0]};
    #1;
    assert(fp_shared_load_cmd===expected && fp_shared_cmd_mem===payload)
      else $fatal(1,"scalar final operand op=%0d bytes=%0d step=%0d ack=%b cw=%h sw=%h",
                  q_fxop,q_f_mbytes,f_step,mem_ack,fctrl,fstat);
  endtask

  initial begin
    checks=0;
    for(int op=0;op<128;op++) begin
      for(int width=0;width<16;width++)
        for(int step=0;step<16;step++)
          for(int high=0;high<2;high++) begin
            defaults();q_fxop=fxop_e'(op);q_f_mbytes=4'(width);f_step=4'(step);
            fp_load64_take=1'(high);check();checks++;
          end
      for(int guards=0;guards<256;guards++) begin
        defaults();q_fxop=fxop_e'(op);
        {cycle_mode,state,q_f_mem_read,q_f_mem_write,mem_ack,fsm_case_enabled,
         fp_shared_early_retire_ok,fp_dbg_active}=8'(guards);
        check();checks++;
      end
      for(int masks=0;masks<64;masks++)
        for(int pending=0;pending<2;pending++) begin
          defaults();q_fxop=fxop_e'(op);fctrl[5:0]=6'(masks);fstat[7]=1'(pending);check();checks++;
        end
    end
    $display("SCALAR-LOAD-CMD-LEAF-OK checks=%0d",checks);
    $finish;
  end
endmodule
