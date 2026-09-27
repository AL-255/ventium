`timescale 1ns/1ps
`default_nettype none
// Stage-B leaf gate. Ordinary commands initialize state; no restore
// ports, forced pipeline state or guest-specific RTL. Not a QEMU arithmetic oracle.
module tb_ven_fp_arith_forward;
  import ventium_decode_pkg::*;
  import ventium_x87_pkg::*;
  localparam logic [79:0] ONE=80'h3fff8000000000000000;
  localparam logic [79:0] TWO=80'h40008000000000000000;
  localparam logic [79:0] THREE=80'h4000c000000000000000;
  localparam logic [79:0] SIX=80'h4001c000000000000000;
  localparam logic [79:0] INF=80'h7fff8000000000000000;
  localparam logic [79:0] SNAN=80'h7fff8000000000000042;
  localparam logic [79:0] QNAN=80'h7fffc000000000000042;
  localparam logic [79:0] MAXFINITE=80'h7ffeffffffffffffffff;
`ifdef VEN_FP_ARITH_FWD
  localparam bit FORWARD=1;
`else
  localparam bit FORWARD=0;
`endif
  logic clk=0, rst_n=0, cmd_valid, cmd_ready, cmd_accept_retire, alu_commit_retire;
  fxop_e cmd_op;
  logic [2:0] cmd_aluop, cmd_sti, cmd_constant;
  logic cmd_pop, cmd_fdiv_bug, cmd_fist_bug, cmd_env16, cmd_real_mode;
  logic [79:0] cmd_mem;
  logic [3:0] cmd_mem_bytes;
  logic [863:0] cmd_env_image;
  logic cmd_update_fip, cmd_update_fdp;
  logic [31:0] cmd_fip, cmd_fdp;
  logic [15:0] cmd_fcs, cmd_fds;
  logic busy, rsp_valid, rsp_unsupported, rsp_stack_fault, rsp_store_valid, rsp_ax_valid;
  logic [84:0] rsp_arith;
  logic [863:0] rsp_store_data;
  logic [7:0] rsp_store_bytes;
  logic [15:0] rsp_ax;
  logic [2:0] ftop_o;
  logic [15:0] fstat_o, fctrl_o;
  logic [7:0] fptag_o;
  logic [31:0] fip_o, fdp_o;
  logic [15:0] fcs_o, fds_o;
  logic [639:0] fpr_phys_flat_o, st_flat_o;
  int checks=0, edges=0, accepts=0, responses=0;
  ven_fp_top dut (.*);

  task automatic idle;
    cmd_valid=0; cmd_op=FX_NONE; cmd_aluop=0; cmd_sti=0; cmd_constant=0;
    cmd_pop=0; cmd_fdiv_bug=0; cmd_fist_bug=0; cmd_env16=0; cmd_real_mode=0;
    cmd_mem=0; cmd_mem_bytes=0; cmd_env_image=0;
    cmd_update_fip=0; cmd_update_fdp=0;
    cmd_fip=0; cmd_fdp=0; cmd_fcs=0; cmd_fds=0;
  endtask
  task automatic tick;
    #2;
    if (rst_n && cmd_valid && cmd_ready) accepts++;
    clk=1; #1;
    if (rst_n && rsp_valid) responses++;
    clk=0; #1; edges++;
  endtask
  task automatic ready_is(input bit expected, input string why);
    #1;
    if (cmd_ready != expected) $fatal(1,"FWD-LEAF %s ready=%0b expected=%0b",why,cmd_ready,expected);
  endtask
  task automatic serial(input fxop_e op, input logic [79:0] value, input logic [2:0] sti=0);
    idle(); cmd_valid=1; cmd_op=op; cmd_mem=value; cmd_sti=sti;
    cmd_mem_bytes=(op==FX_FLDCW) ? 2 : 10;
    cmd_update_fdp=(op==FX_FLD_M80); cmd_fdp=32'h11223344; cmd_fds=16'h0020;
    ready_is(1,"serial setup"); tick(); cmd_valid=0;
    for (int i=0; !rsp_valid && i<100; i++) tick();
    if (!rsp_valid || rsp_unsupported || rsp_stack_fault)
      $fatal(1,"FWD-LEAF setup response op=%0d",op);
    tick(); idle();
  endtask
  task automatic setup(input logic [79:0] v0, input logic [79:0] v1,
                       input logic [79:0] v2, input logic [15:0] cw,
                       input bit swap_map=0);
    rst_n=0; idle(); tick(); tick(); rst_n=1; tick();
    serial(FX_FNINIT,0);
    for (int i=7; i>=0; i--)
      serial(FX_FLD_M80, i==0 ? v0 : i==1 ? v1 : i==2 ? v2 : ONE);
    serial(FX_FLDCW,{64'd0,cw});
    if (swap_map) begin
      serial(FX_FXCH,0,2);
      if (dut.u_state.map[0]!=3'd2 || dut.u_state.map[2]!=3'd0)
        $fatal(1,"FWD-LEAF mapped setup did not change the private map");
    end
    if (ftop_o!=0 || fptag_o!=0 || fctrl_o!=cw)
      $fatal(1,"FWD-LEAF setup state");
    accepts=0; responses=0;
  endtask
  task automatic arith(input bit to_i, input logic [2:0] sti, input logic [2:0] op,
                       input logic [31:0] ip, input bit pop=0);
    idle(); cmd_valid=1; cmd_op=to_i ? FX_AR_STI_ST0 : FX_AR_ST0_STI;
    cmd_sti=sti; cmd_aluop=op; cmd_pop=pop;
    cmd_update_fip=1; cmd_fip=ip;
    cmd_fcs=(ip==32'h1000) ? 16'h0018 : (ip==32'h2000) ? 16'h0028 : 16'h0038;
    // Register arithmetic must preserve these pointers despite live poison.
    cmd_update_fdp=0; cmd_fdp=32'hdeadbeef; cmd_fds=16'hffff;
  endtask
  function automatic logic [84:0] reference_result(input logic [2:0] op,
      input logic [79:0] a, input logic [79:0] b, input logic [15:0] cw);
    // Existing serial architectural helper, not an independent numeric oracle.
    return f_eval_s2(f_eval_s1(op,a,b,cw[11:10],cw[9:8],1'b0),cw[11:10],cw[9:8]);
  endfunction
  task automatic state_is(input logic [639:0] regs, input logic [15:0] status,
                          input logic [31:0] ip, input logic [15:0] cw,
                          input string why);
    if (fpr_phys_flat_o!=regs || st_flat_o!=regs || ftop_o!=0 || fptag_o!=0 ||
        fstat_o!=status || fctrl_o!=cw || fip_o!=ip ||
        fcs_o!=((ip==32'h1000) ? 16'h0018 : (ip==32'h2000) ? 16'h0028 : 16'h0038) ||
        fdp_o!=32'h11223344 || fds_o!=16'h0020 ||
        rsp_unsupported || rsp_stack_fault || rsp_store_valid || rsp_ax_valid)
      $fatal(1,"FWD-LEAF %s state/status/metadata mismatch sw=%04x expected=%04x ip=%08x",
             why,fstat_o,status,fip_o);
  endtask
  task automatic bank_is(input logic [639:0] raw_bank, input logic [23:0] mapping);
    // phys_flat_o already materializes bank[map[p]]. Keep a separate raw-bank
    // expectation so the nonidentity-map case proves the real write destination.
    for (int p=0; p<8; p++)
      if (dut.u_state.bank[p]!=raw_bank[p*80+:80] || dut.u_state.map[p]!=mapping[p*3+:3])
        $fatal(1,"FWD-LEAF raw bank/map mismatch slot=%0d",p);
  endtask
  task automatic pair_case(input string label_s,
      input bit a_to_i, input logic [2:0] ai, input logic [2:0] aop,
      input bit b_to_i, input logic [2:0] bi, input logic [2:0] bop,
      input logic [79:0] v0, input logic [79:0] v1, input logic [79:0] v2,
      input logic [15:0] cw, input bit swap_map=0);
    logic [639:0] initial_regs, after_a, after_b;
    logic [639:0] initial_bank, bank_after_a, bank_after_b;
    logic [23:0] initial_map;
    logic [84:0] ra, rb;
    logic [79:0] b_a, b_b;
    logic [15:0] sa, sb;
    int ae, be, ad, bd;
    setup(v0,v1,v2,cw,swap_map);
    initial_regs=fpr_phys_flat_o;
    for (int p=0; p<8; p++) begin
      initial_bank[p*80+:80]=dut.u_state.bank[p];
      initial_map[p*3+:3]=dut.u_state.map[p];
    end
    ad=a_to_i ? int'(ai) : 0; bd=b_to_i ? int'(bi) : 0;
    ra=reference_result(aop, a_to_i ? initial_regs[ai*80+:80] : initial_regs[79:0],
                        a_to_i ? initial_regs[79:0] : initial_regs[ai*80+:80],cw);
    after_a=initial_regs; after_a[ad*80+:80]=ra[79:0];
    b_a=b_to_i ? after_a[bi*80+:80] : after_a[79:0];
    b_b=b_to_i ? after_a[79:0] : after_a[bi*80+:80];
    rb=reference_result(bop,b_a,b_b,cw);
    // A few independently written exact anchors also check the helper setup.
    if (label_s=="ST0 RAW+WAW" &&
        (ra!=85'h040029000000000000000 || rb!=85'h04002c000000000000000))
      $fatal(1,"FWD-LEAF exact 6+3=9; 9+3=12 anchor");
    if (label_s=="both aliases multiply" && rb!=85'h04005a200000000000000)
      $fatal(1,"FWD-LEAF exact 9*9=81 anchor");
    if (label_s=="STi source RAW" && rb!=85'h0c000c000000000000000)
      $fatal(1,"FWD-LEAF exact 6-9=-3 anchor");
    after_b=after_a; after_b[bd*80+:80]=rb[79:0];
    bank_after_a=initial_bank;
    bank_after_a[int'(initial_map[ad*3+:3])*80+:80]=ra[79:0];
    bank_after_b=bank_after_a;
    bank_after_b[int'(initial_map[bd*3+:3])*80+:80]=rb[79:0];
    sa=f_arith_fstat(fstat_o,ra); sb=f_arith_fstat(sa,rb);
    arith(a_to_i,ai,aop,32'h1000); ready_is(1,"A issue"); tick(); ae=edges;
    arith(b_to_i,bi,bop,32'h2000);
    ready_is(0,"stage 0 dependency"); tick();
    ready_is(0,"stage 1 dependency"); tick();
    ready_is(FORWARD,"stage 2 registered dependency");
    if (fpr_phys_flat_o!=initial_regs || responses!=0 || accepts!=1 || fip_o!=32'h1000)
      $fatal(1,"FWD-LEAF early architectural mutation");
    bank_is(initial_bank,initial_map);
    if (FORWARD && (dut.alu_a!=b_a || dut.alu_b!=b_b))
      $fatal(1,"FWD-LEAF wrong forwarded operand or swap %s",label_s);
    tick();
    if (!rsp_valid || rsp_arith!=ra || responses!=1)
      $fatal(1,"FWD-LEAF older ordered response");
    state_is(after_a,sa,FORWARD ? 32'h2000 : 32'h1000,cw,"A commit / B accept");
    bank_is(bank_after_a,initial_map);
    if (!FORWARD) begin ready_is(1,"post-commit bank read"); tick(); end
    be=edges;
    if (accepts!=2 || be-ae!=(FORWARD ? 3 : 4))
      $fatal(1,"FWD-LEAF acceptance interval %0d",be-ae);
    idle(); cmd_update_fip=1; cmd_update_fdp=1;
    cmd_fip='1; cmd_fdp='1; cmd_fcs='1; cmd_fds='1; cmd_mem='1;
    for (int i=1; i<=3; i++) begin
      tick();
      if (rsp_valid!=(i==3)) $fatal(1,"FWD-LEAF missing/early B response");
      state_is(i==3 ? after_b : after_a,i==3 ? sb : sa,32'h2000,cw,"B drain");
      bank_is(i==3 ? bank_after_b : bank_after_a,initial_map);
    end
    if (rsp_arith!=rb || responses!=2 || accepts!=2)
      $fatal(1,"FWD-LEAF younger response/count");
    repeat(3) begin tick(); if (busy || rsp_valid) $fatal(1,"FWD-LEAF duplicate/leaked owner"); end
    checks++;
    $display("FWD-LEAF pair=%s accepted_gap=%0d",label_s,be-ae);
  endtask

  task automatic rejection_case(input int kind);
    logic [639:0] after_a;
    logic [84:0] ra;
    logic [7:0] old_tags;
    logic [15:0] old_status;
    setup(SIX,THREE,TWO,kind==3 ? 16'h037e : 16'h037f);
    if (kind==2) serial(FX_FFREE,0,2);
    if (kind==7) begin
      // Architectural environment load establishes an adversarial existing ES.
      idle(); cmd_op=FX_FLDENV; cmd_env_image[15:0]=16'h037f;
      cmd_env_image[47:32]=16'h0080; cmd_valid=1;
      ready_is(1,"ES environment setup"); tick(); idle(); tick();
    end
    old_tags=fptag_o; old_status=fstat_o;
    after_a=fpr_phys_flat_o;
    ra=reference_result(0,SIX,THREE,fctrl_o); after_a[79:0]=ra[79:0];
    accepts=0; responses=0;
    arith(0,1,0,32'h1000,kind==0); ready_is(1,"rejection A issue"); tick();
    arith(0,kind==2 ? 3'd2 : 3'd1,0,32'h2000,kind==1);
    if (kind==4) begin cmd_op=FX_AR_M32; cmd_mem_bytes=4; cmd_mem=80'h3f800000; end
    if (kind==5) cmd_op=FX_FXCH;
    if (kind==6) begin cmd_op=FX_FLDCW; cmd_mem=80'h027f; end
    for (int i=0; i<3; i++) begin ready_is(0,"excluded at every older stage"); tick(); end
    // Cancel only the never-accepted younger test stimulus, not an RTL owner.
    cmd_valid=0;
    if (accepts!=1 || responses!=1 || fpr_phys_flat_o!=after_a ||
        ftop_o!=(kind==0 ? 3'd1 : 3'd0) ||
        fptag_o!=(kind==0 ? old_tags|8'd1 : old_tags) ||
        fstat_o!=f_arith_fstat(old_status,ra) || fip_o!=32'h1000)
      $fatal(1,"FWD-LEAF excluded form mutated state kind=%0d",kind);
    repeat(3) begin tick(); if (rsp_valid || busy) $fatal(1,"FWD-LEAF excluded extra response"); end
    checks++;
  endtask

  task automatic mixed_owners(input bit gap);
    logic [639:0] expected;
    logic [84:0] ra,rb,rc;
    int be,ce;
    setup(SIX,THREE,TWO,16'h037f);
    expected=fpr_phys_flat_o;
    ra=reference_result(0,THREE,SIX,16'h037f);
    rb=reference_result(0,SIX,TWO,16'h037f);
    rc=reference_result(4,rb[79:0],ra[79:0],16'h037f);
    arith(1,1,0,32'h1000); ready_is(1,"mixed A"); tick();
    if (gap) begin idle(); tick(); end
    arith(0,2,0,32'h2000); ready_is(1,"independent mixed B"); tick(); be=edges;
    arith(0,1,4,32'h3000); ready_is(0,"mixed younger stage0 dependency");
    if (!gap) begin tick(); ready_is(0,"stage2 match with younger stage1 hazard"); end
    // Gap 0: A stage2 / B stage1; gap 1: A stage2 / B stage0.
    // A's STi forwarding match cannot erase B's ST0 RAW+WAW hazard.
    tick();
    if (!rsp_valid || rsp_arith!=ra || accepts!=2 || responses!=1)
      $fatal(1,"FWD-LEAF mixed A response");
    expected[159:80]=ra[79:0];
    state_is(expected,0,32'h2000,16'h037f,"mixed A state");
    if (gap) begin
      ready_is(0,"younger B still at stage1 after A committed"); tick();
      if (rsp_valid) $fatal(1,"FWD-LEAF mixed unexpected response");
    end
    ready_is(FORWARD,"mixed B stage2"); tick();
    if (!rsp_valid || rsp_arith!=rb || responses!=2)
      $fatal(1,"FWD-LEAF mixed B response");
    expected[79:0]=rb[79:0];
    state_is(expected,0,FORWARD ? 32'h3000 : 32'h2000,16'h037f,"mixed B state");
    if (!FORWARD) begin ready_is(1,"mixed C after B commit"); tick(); end
    ce=edges; idle();
    if (accepts!=3 || ce-be!=(FORWARD ? 3 : 4)) $fatal(1,"FWD-LEAF mixed cadence");
    repeat(3) tick();
    expected[79:0]=rc[79:0];
    state_is(expected,0,32'h3000,16'h037f,"mixed C state");
    if (!rsp_valid || rsp_arith!=rc || responses!=3) $fatal(1,"FWD-LEAF mixed C response");
    repeat(3) begin tick(); if (rsp_valid || busy) $fatal(1,"FWD-LEAF mixed leak"); end
    checks++;
  endtask
  task automatic reset_at_forward_edge;
    setup(SIX,THREE,TWO,16'h037f);
    arith(0,1,0,32'h1000); tick();
    arith(0,1,0,32'h2000); tick(); tick();
    ready_is(FORWARD,"reset at final stage");
    rst_n=0; tick(); idle(); rst_n=1;
    repeat(6) begin
      tick();
      if (busy || rsp_valid || fpr_phys_flat_o!=0 || ftop_o!=0 || fptag_o!=8'hff ||
          fstat_o!=0 || fctrl_o!=16'h037f || fip_o!=0 || fdp_o!=0)
        $fatal(1,"FWD-LEAF reset leaked cancelled state/response");
    end
    checks++;
  endtask
  initial begin
    logic [15:0] cw;
    logic [79:0] half_ulp;
    pair_case("ST0 RAW+WAW",0,1,0,0,1,0,SIX,THREE,TWO,16'h037f);
    pair_case("STi source RAW",1,1,0,0,1,4,SIX,THREE,TWO,16'h037f);
    pair_case("ST0 source before swap",0,1,0,1,1,4,SIX,THREE,TWO,16'h037f);
    pair_case("STi RAW+WAW reverse",1,1,0,1,1,5,SIX,THREE,TWO,16'h037f);
    pair_case("both aliases multiply",0,1,0,0,0,1,SIX,THREE,TWO,16'h037f);
    pair_case("both aliases swap",0,1,0,1,0,4,SIX,THREE,TWO,16'h037f);
    pair_case("nonidentity bank map",1,1,0,0,1,5,SIX,THREE,TWO,16'h037f,1);
    pair_case("signaling NaN sticky IE",0,1,0,0,1,0,SNAN,ONE,TWO,16'h037f);
    pair_case("quiet NaN payload",0,1,0,0,1,4,QNAN,ONE,TWO,16'h037f);
    pair_case("infinity invalid",0,1,4,0,1,0,INF,INF,TWO,16'h037f);
    pair_case("overflow then invalid sticky",0,1,0,0,2,1,MAXFINITE,MAXFINITE,80'd0,16'h037f);
    pair_case("denormal",0,1,0,0,1,4,80'd1,80'd1,TWO,16'h037f);
    pair_case("negative zero",0,1,0,0,0,1,80'h80000000000000000000,80'd0,TWO,16'h037f);
    for (int pc=0; pc<4; pc++) if (pc!=1)
      for (int rc=0; rc<4; rc++) begin
        cw=16'h007f | (16'(pc)<<8) | (16'(rc)<<10);
        half_ulp={(pc==0 ? 16'h3fe7 : pc==2 ? 16'h3fca : 16'h3fbf),64'h8000000000000000};
        pair_case("positive rounding boundary",0,1,0,0,1,4,ONE,half_ulp,TWO,cw);
        pair_case("negative rounding boundary",0,1,0,0,1,5,
                  ONE^80'h80000000000000000000,half_ulp^80'h80000000000000000000,TWO,cw);
      end
    for (int kind=0; kind<8; kind++) rejection_case(kind);
    mixed_owners(0); mixed_owners(1); reset_at_forward_edge();
    $display("FP-ARITH-FORWARD-LEAF-OK forwarding=%0b checks=%0d",FORWARD,checks);
    $finish;
  end
endmodule
`default_nettype wire
