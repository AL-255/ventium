// Actual include, no FPU model. Full architectural gates are separate.
module tb_fp_scalar_dispatch;
  import ventium_decode_pkg::*;
  localparam logic S_PIPE=0, S_OTHER=1;
  logic state,cycle_mode,pipe_fp_short_window_ok,def16,d_unknown,d_is_x87;
  logic d_lock,d_is_fwait,d_f_mem_read,d_f_mem_write;
  logic sys_mode,sys_fp_ok,real_mode,v86,cs_d;
  logic fp_async_pending,fp_shared_busy,fp_dbg_active,dbg_block_issue;
  logic dbg_step_active,irq_shadow,smi_take,nmi_take,intr_take,pipe_agi;
  logic [31:0] creg0;
  logic [15:0] fstat;
  logic [2:0] mispred_bubbles;
  logic [6:0] stall_cnt,pending_mem_pen;
  fxop_e d_fxop;
  integer checks=0;
  `include "core_fp_scalar_dispatch.svh"
  task automatic defaults;
    state=S_PIPE;cycle_mode=1;pipe_fp_short_window_ok=1;def16=0;
    d_unknown=0;d_is_x87=1;d_lock=0;d_is_fwait=0;
    d_f_mem_read=0;d_f_mem_write=1;d_fxop=FX_FIST_M32;
    sys_mode=1;sys_fp_ok=1;real_mode=0;v86=0;cs_d=1;
    creg0=32'h80000011;fstat=0;
    fp_async_pending=0;fp_shared_busy=0;fp_dbg_active=0;dbg_block_issue=0;
    dbg_step_active=0;irq_shadow=0;smi_take=0;nmi_take=0;intr_take=0;pipe_agi=0;
    mispred_bubbles=0;stall_cnt=0;pending_mem_pen=0;
  endtask
  function automatic logic scalar(input fxop_e op);
    case(op)
      FX_FLD_M32,FX_FLD_M64,FX_FLD_M80,FX_FILD_M16,FX_FILD_M32,FX_FILD_M64,
      FX_FST_M32,FX_FST_M64,FX_FST_M80,FX_FIST_M16,FX_FIST_M32,FX_FIST_M64,
      FX_FCOM_M32,FX_FCOM_M64,FX_AR_I16,FX_AR_I32:return 1;
      default:return 0;
    endcase
  endfunction
  task automatic check(input logic expected);
    #1;
`ifndef VEN_FP_SCALAR_DISPATCH
    expected=0;
`endif
    if(pipe_fp_scalar_dispatch_ok!==expected)
      $fatal(1,"scalar dispatch mismatch check=%0d op=%0d actual=%b expected=%b",
             checks,d_fxop,pipe_fp_scalar_dispatch_ok,expected);
    checks++;
  endtask
  task automatic block_one(input int n);
    case(n)
       0:state=S_OTHER; 1:cycle_mode=0; 2:pipe_fp_short_window_ok=0;
       3:def16=1; 4:d_unknown=1; 5:d_is_x87=0; 6:d_lock=1;
       7:d_is_fwait=1; 8:creg0[2]=1; 9:creg0[3]=1; 10:fstat[7]=1;
      11:fp_async_pending=1; 12:fp_shared_busy=1; 13:fp_dbg_active=1;
      14:dbg_block_issue=1; 15:dbg_step_active=1; 16:irq_shadow=1;
      17:smi_take=1; 18:nmi_take=1; 19:intr_take=1; 20:pipe_agi=1;
      21:mispred_bubbles=3; 22:stall_cnt=1; 23:pending_mem_pen=1;
      default:$fatal(1,"unknown blocker");
    endcase
  endtask
  initial begin
    for(int op=0;op<128;op++)for(int direction=0;direction<4;direction++)begin
      defaults();d_fxop=fxop_e'(op);
      {d_f_mem_read,d_f_mem_write}=2'(direction);
      check(scalar(d_fxop) && (direction==1 || direction==2));
    end
    for(int a=0;a<24;a++)for(int b=0;b<24;b++)begin
      defaults();block_one(a);block_one(b);check(0);
    end
    for(int context_bits=0;context_bits<32;context_bits++)begin
      defaults();{sys_mode,sys_fp_ok,real_mode,v86,cs_d}=5'(context_bits);
      check(!sys_mode || (sys_fp_ok && !real_mode && !v86 && cs_d));
    end
    for(int status_word=0;status_word<65536;status_word++)begin
      defaults();fstat=16'(status_word);check((status_word & 128)==0);
    end
    for(int cr_bits=0;cr_bits<32;cr_bits++)begin
      defaults();creg0=32'(cr_bits);check((cr_bits & 12)==0);
    end
    $display("FP-SCALAR-DISPATCH-LEAF-OK checks=%0d",checks);$finish;
  end
endmodule
