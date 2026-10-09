// Predicate unit only. The runner extracts both equations from the candidate.
module tb_fp_pop_drain;
  typedef enum logic [1:0] { S_PIPE, S_FLOAD, S_FEXEC } state_e;
  typedef enum logic [2:0] { FK_ARITH, FK_ARITH_STI, FK_ARITH_STI_POP,
                           FK_FXCH, FK_MEM } kind_e;
  typedef struct packed {
    logic is_fp, is_mem, simple, is_stack, is_branch;
    kind_e fp_kind;
    logic [2:0] fp_aluop, fp_role;
  } descriptor_t;
  descriptor_t u_d;
  state_e state;
  logic [2:0] fp_async_count;
  logic fp_async_pending, fp_async_stream_shape, fp_async_hold;
  logic fp_shared_rsp_valid, fp_async_reg_cmd, fp_async_mem_cmd;
  logic fp_async_operand_read, pipe_mem_active_q;
  logic [15:0] fctrl, fstat;
  logic fp_fast_trap_bail, sys_mode, real_mode, cs_d;
  logic pipe_frontend_ready, exec_issue_ok, fp_dbg_active, dbg_block_issue;
  logic smi_take, nmi_take, intr_take;
  integer checks = 0;
  assign fp_async_pending = (fp_async_count != 0);
  `include "pop_drain_equations.svh"

  task automatic defaults;
    u_d='0; u_d.is_fp=1; u_d.fp_kind=FK_ARITH_STI_POP;
    state=S_PIPE; fp_async_count=1; fp_shared_rsp_valid=1;
    fp_async_reg_cmd=0; fp_async_mem_cmd=0; fp_async_operand_read=0;
    pipe_mem_active_q=0; fctrl=16'h037f; fstat=0;
    fp_fast_trap_bail=0; sys_mode=1; real_mode=0; cs_d=1;
    pipe_frontend_ready=1; exec_issue_ok=1; fp_dbg_active=0;
    dbg_block_issue=0; smi_take=0; nmi_take=0; intr_take=0;
  endtask

  task automatic check(input logic shape, input logic hold_expected);
    #1;
    if (fp_async_stream_shape !== shape || fp_async_hold !== hold_expected)
      $fatal(1,"POP-DRAIN shape=%b/%b hold=%b/%b count=%d rsp=%b op=%d",
             fp_async_stream_shape,shape,fp_async_hold,hold_expected,
             fp_async_count,fp_shared_rsp_valid,u_d.fp_aluop);
    checks++;
  endtask

  initial begin
    for (int count=0; count<5; count++)
      for (int response=0; response<2; response++)
        for (int op=0; op<8; op++) begin
          logic permit;
          defaults(); fp_async_count=3'(count); fp_shared_rsp_valid=1'(response);
          u_d.fp_aluop=3'(op); permit=0;
`ifdef VEN_FP_POP_DRAIN
          permit=(count==1 && response==1 && (op==0 || op==1 || op==4 || op==5));
`endif
          check(permit, count!=0 && !permit);
        end
    // Exception masks/ES, EM/TS/MF front-end trap predicate and context guards.
    for (int blocker=0; blocker<14; blocker++) begin
      defaults();
      case (blocker)
        0,1,2,3,4,5: fctrl[blocker]=0;
        6: fstat[7]=1;
        7: fp_fast_trap_bail=1;
        8: real_mode=1;
        9: cs_d=0;
        10: state=S_FLOAD;
        11: state=S_FEXEC;
        12: u_d.is_fp=0;
        13: u_d.is_mem=1;
        default: ;
      endcase
      check(0,1);
    end
    // The optimization cannot admit across debug, events or stale fetch.
    for (int blocker=0; blocker<7; blocker++) begin
      defaults();
      case (blocker)
        0: fp_dbg_active=1;
        1: dbg_block_issue=1;
        2: smi_take=1;
        3: nmi_take=1;
        4: intr_take=1;
        5: pipe_frontend_ready=0;
        6: exec_issue_ok=0;
        default: ;
      endcase
`ifdef VEN_FP_POP_DRAIN
      check(1,1);
`else
      check(0,1);
`endif
    end
    defaults(); sys_mode=0; real_mode=1; cs_d=0;
`ifdef VEN_FP_POP_DRAIN
    check(1,0);
`else
    check(0,1);
`endif
    $display("FP-POP-DRAIN-PREDICATES-OK checks=%0d",checks);
    $finish;
  end
endmodule
