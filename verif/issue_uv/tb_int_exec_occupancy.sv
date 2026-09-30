// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
// Includes the production compact hold, not a copied timing implementation.
// Iterative configurations also measure the real ven_idiv done pulse.
module tb_int_exec_occupancy;
  import ventium_decode_pkg::*;
  typedef enum logic [2:0] {S_FETCH,S_LOAD,S_EXEC,S_DIV_BUSY,S_PIPE,S_WALK} state_t;
  logic clk=0, rst_n=0, cycle_mode=1, base_ready=1;
  state_t state=S_FETCH;
  kind_e q_kind=K_ALU;
  logic [2:0] q_md=0,q_w=4;
  logic q_mem_read=0,q_shift_cl=0;
  logic [2:0] q_shrot=4;
`ifdef VEN_P54_PREFIX_EX_CHAIN
  logic p54_prefix_ex_take=0;
`endif
  `include "core_int_exec_occ.svh"
  wire fsm_case_enabled=fsm_case_ready && !p54_int_exec_hold;
  assign fsm_case_ready=base_ready;
  logic div_start,div_done,div_busy,div_derr;
  logic [63:0] numerator=100;
  logic [31:0] denominator=3,quotient,remainder;
`ifdef VEN_IDIV_ITER
  assign div_start=fsm_case_enabled && state==S_EXEC && q_kind==K_MULDIV &&
                   (q_md==3'd6 || q_md==3'd7);
  ven_idiv divider(.clk,.rst_n,.start(div_start),.is_signed(q_md==3'd7),
      .w(q_w),.dividend(numerator),.divisor(denominator),.busy(div_busy),
      .done(div_done),.quotient,.remainder,.derr(div_derr));
`else
  assign div_start=0;
  assign div_done=0;
  assign div_busy=0;
  assign div_derr=0;
  assign quotient=0;
  assign remainder=0;
`endif
  int unsigned checks=0,operations=0;

  task automatic tick;
    #2; clk=1; #2; clk=0; #1;
  endtask

  function automatic int period_target(input kind_e kind,input int md,w);
    if(kind==K_EXT) return 3;
    if(kind==K_IMUL2) return 10;
    if(kind==K_SHIFT && q_shift_cl && q_shrot!=2 && q_shrot!=3) return 4;
    if(kind!=K_MULDIV) return 1;
    case(md)
      4,5: return w==4 ? 10:11;
      6: return w==4 ? 41:w==2 ? 25:17;
      7: return w==4 ? 46:w==2 ? 30:22;
      default:return 1;
    endcase
  endfunction

  task automatic check_operation(input kind_e kind,input int md,w,
      input bit memory_form,input int frontend_clocks,source_wait,paused_clocks,
      input bit cl_form=0,input int subop=4);
    int clocks,starts,expected,commits,paused;
    bit enabled,done,derr,started;
    q_kind=kind; q_md=3'(md); q_w=3'(w); q_mem_read=memory_form;
    q_shift_cl=cl_form;q_shrot=3'(subop);
    numerator=100; denominator=3; base_ready=1;
    state=S_FETCH;
    repeat(frontend_clocks+1) begin
      #1;
      if(p54_int_exec_hold) $fatal(1,"frontend was charged as EX");
      tick();
    end
    state=S_LOAD;
    repeat(source_wait+int'(memory_form)) begin
      #1;
      if(p54_int_exec_hold) $fatal(1,"source ACK/wait charged twice");
      tick();
    end
    state=S_EXEC;
    clocks=0;starts=0;commits=0;paused=0;
    if(paused_clocks!=0) begin
      base_ready=0;
      repeat(paused_clocks) begin
        #1;
        if(fsm_case_enabled || div_start) $fatal(1,"priority pause leaked execution");
        tick();paused++;
      end
      base_ready=1;
    end
    while(commits==0 && clocks<100) begin
      #1;
      enabled=fsm_case_enabled;done=div_done;derr=div_derr;started=div_start;
      if(p54_int_exec_hold && enabled) $fatal(1,"hold leaked architectural write");
      if(started) starts++;
      tick();clocks++;
      if(state==S_EXEC && enabled) begin
`ifdef VEN_IDIV_ITER
        if(kind==K_MULDIV && (md==6 || md==7)) state=S_DIV_BUSY;
        else begin state=S_PIPE;commits++;end
`else
        state=S_PIPE;commits++;
`endif
      end else if(state==S_DIV_BUSY && enabled && done) begin
        if(derr || quotient!=33 || remainder!=1)
          $fatal(1,"divider result/done was lost q=%0d r=%0d err=%0d",quotient,remainder,derr);
        state=S_PIPE;commits++;
      end
    end
    if(commits!=1) $fatal(1,"missing/duplicate retirement");
`ifdef VEN_P54_INT_EXEC_OCC
    expected=cycle_mode ? period_target(kind,md,w)-int'(memory_form) : 1;
`else
    expected=1;
`endif
`ifdef VEN_IDIV_ITER
    if(kind==K_MULDIV && (md==6 || md==7)) begin
      if(!cycle_mode
`ifndef VEN_P54_INT_EXEC_OCC
          || 1'b1
`endif
          ) expected=w==4 ? 35:w==2 ? 19:11;
      if(starts!=1) $fatal(1,"iterative DIV double-start count=%0d",starts);
    end else if(starts!=0) $fatal(1,"non-DIV started divider");
`endif
    if(clocks!=expected || paused!=paused_clocks)
      $fatal(1,"EX clocks kind=%0d md=%0d w=%0d mem=%0d mode=%0d got=%0d expected=%0d",
          kind,md,w,memory_form,cycle_mode,clocks,expected);
    operations++;checks+=3;
    tick(); // clears the previous operation's ownership before a new EX
  endtask

  task automatic check_reset_and_diversion;
`ifdef VEN_P54_INT_EXEC_OCC
    logic [5:0] remaining;
`endif
    q_kind=K_IMUL2;q_md=0;q_w=4;q_mem_read=0;cycle_mode=1;
    state=S_EXEC;repeat(4) tick();
`ifdef VEN_P54_INT_EXEC_OCC
    remaining=p54_int_exec_rem_q;
    base_ready=0;repeat(3) tick();base_ready=1;
    if(p54_int_exec_rem_q!=remaining) $fatal(1,"priority stall advanced countdown");
`endif
    rst_n=0;tick();rst_n=1;
`ifdef VEN_P54_INT_EXEC_OCC
    #1;
    if(!p54_int_exec_hold || p54_int_exec_active_q || p54_int_exec_rem_q!=0)
      $fatal(1,"reset retained countdown owner");
    tick();
    state=S_WALK;repeat(3) tick();state=S_EXEC;#1;
    if(!p54_int_exec_hold || p54_int_exec_active_q)
      $fatal(1,"diversion retained wrong operation owner");
`endif
    state=S_FETCH;tick();checks+=2;
  endtask

`ifdef VEN_P54_PREFIX_EX_CHAIN
  // Counter ownership only: assert an accepted operation-generation event
  // without leaving EX. The separate whole-core fixture checks eligibility.
  task automatic check_chain_rearm(input kind_e old_kind, new_kind);
    int clocks;
    cycle_mode=1;base_ready=1;q_mem_read=0;q_w=4;
    state=S_FETCH;tick();state=S_EXEC;q_kind=old_kind;
    clocks=0;
    do begin
      #1;
      p54_prefix_ex_take=fsm_case_enabled;
      tick();clocks++;
    end while (!p54_prefix_ex_take && clocks<20);
    if(clocks!=period_target(old_kind,0,4)) $fatal(1,"old chained EX shortened");
    p54_prefix_ex_take=0;q_kind=new_kind;#1;
    if(!p54_int_exec_hold || p54_int_exec_active_q || p54_int_exec_rem_q!=0)
      $fatal(1,"same-state q handoff retained completed countdown");
    clocks=0;
    do begin
      bit enabled;
      #1;enabled=fsm_case_enabled;tick();clocks++;
      if(enabled) break;
    end while(clocks<20);
    if(clocks!=period_target(new_kind,0,4)) $fatal(1,"new chained EX shortened");
    state=S_FETCH;tick();checks+=3;operations+=2;
  endtask
`endif

`ifdef VEN_IDIV_ITER
  task automatic check_fault(input bit zero_divisor);
    int edges,starts;
    bit enabled,done,derr,started;
    q_kind=K_MULDIV;q_md=6;q_w=1;q_mem_read=0;cycle_mode=1;base_ready=1;
    numerator=zero_divisor ? 100:512;denominator=zero_divisor ? 0:1;
    state=S_FETCH;tick();state=S_EXEC;edges=0;starts=0;
    while(edges<100) begin
      #1;enabled=fsm_case_enabled;done=div_done;derr=div_derr;started=div_start;
      if(started) starts++;
      tick();edges++;
      if(state==S_EXEC && enabled) state=S_DIV_BUSY;
      else if(state==S_DIV_BUSY && enabled && done) begin
        if(!derr || starts!=1) $fatal(1,"divide fault was committed as a result");
        state=S_PIPE;tick();checks++;return;
      end
    end
    $fatal(1,"divide-error done pulse lost");
  endtask
`endif

  initial begin
    tick();rst_n=1;tick();
    for(int mode=0;mode<2;mode++) begin
      cycle_mode=1'(mode);
      for(int wi=0;wi<3;wi++) begin
        for(int mem=0;mem<2;mem++) begin
          for(int front=0;front<3;front++) begin
            for(int md=4;md<=7;md++)
              check_operation(K_MULDIV,md,1<<wi,1'(mem),front*7,front*3,front);
            check_operation(K_EXT,0,1<<wi,1'(mem),front*7,front*3,front);
            check_operation(K_IMUL2,0,1<<wi,1'(mem),front*7,front*3,front);
            for(int subop=0;subop<8;subop++) begin
              if(subop!=2 && subop!=3)
                check_operation(K_SHIFT,0,1<<wi,1'(mem),front*7,front*3,front,1,subop);
            end
          end
        end
      end
    end
    // The unhandled K_ALU path must not pick up stale timing ownership.
    check_operation(K_ALU,0,4,0,0,0,0);
    check_operation(K_SHIFT,0,4,0,0,0,0,0,4);
    check_operation(K_SHIFT,0,4,0,0,0,0,1,2);
    check_operation(K_SHIFT,0,4,0,0,0,0,1,3);
    check_reset_and_diversion();
`ifdef VEN_P54_PREFIX_EX_CHAIN
    check_chain_rearm(K_EXT,K_IMUL2);
    check_chain_rearm(K_IMUL2,K_EXT);
    check_chain_rearm(K_IMUL2,K_IMUL2);
`endif
`ifdef VEN_IDIV_ITER
    check_fault(1);check_fault(0);
`endif
    $display("INT-EXEC-OCCUPANCY-OK operations=%0d checks=%0d",operations,checks);
    $finish;
  end
endmodule
