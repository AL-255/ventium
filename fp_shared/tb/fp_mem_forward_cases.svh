// Included into a private derivative of tb_ven_fp_arith_forward by its runner.
// Ordinary commands only. Numeric helper is NOT an independent oracle;
// complete core/QEMU comparisons are required separately.
`ifdef VEN_FP_ARITH_MEM_FWD
  localparam bit MEM_FORWARD=1;
`else
  localparam bit MEM_FORWARD=0;
`endif
  int memory_checks=0;
  task automatic mem_cmd(input int kind, input logic [2:0] op,
                         input logic [79:0] payload, input logic [31:0] ip);
    arith(0,0,op,ip);
    case (kind)
      0: begin cmd_op=FX_AR_M32; cmd_mem_bytes=4; end
      1: begin cmd_op=FX_AR_M64; cmd_mem_bytes=8; end
      2: begin cmd_op=FX_AR_I16; cmd_mem_bytes=2; end
      3: begin cmd_op=FX_AR_I32; cmd_mem_bytes=4; end
      default: $fatal(1,"MEM-FWD invalid kind");
    endcase
    cmd_mem=payload; cmd_update_fdp=1;
    cmd_fdp=ip+32'h01200000; cmd_fds=16'h0040;
  endtask
  function automatic logic [79:0] mem_one(input int kind);
    case (kind)
      0: return 80'h3f800000;
      1: return 80'h3ff0000000000000;
      default: return 80'd1;
    endcase
  endfunction
  task automatic mem_state(input logic [639:0] regs, input logic [15:0] sw,
      input logic [15:0] cw, input logic [31:0] ip, input logic [31:0] dp,
      input logic [15:0] ds);
    if (fpr_phys_flat_o!=regs || st_flat_o!=regs || ftop_o!=0 || fptag_o!=0 ||
        fstat_o!=sw || fctrl_o!=cw || fip_o!=ip || fdp_o!=dp || fds_o!=ds ||
        fcs_o!=(ip==32'h1000 ? 16'h18 : 16'h28) || rsp_unsupported ||
        rsp_stack_fault || rsp_store_valid || rsp_ax_valid)
      $fatal(1,"MEM-FWD state sw=%04x/%04x ip=%08x/%08x dp=%08x/%08x",
             fstat_o,sw,ip,fip_o,dp,fdp_o);
  endtask
  task automatic mem_pair(input int kind, input logic [2:0] op,
      input logic [79:0] payload, input logic [79:0] value,
      input logic [15:0] cw, input bit mapped=0, input bit prior_mem=0);
    logic [639:0] before_regs, after_a, after_b, raw_before, raw_a, raw_b;
    logic [23:0] mapping;
    logic [79:0] operand;
    logic [84:0] ra,rb;
    logic [15:0] sa,sb;
    logic [31:0] dp_a;
    logic [15:0] ds_a;
    int ae,be;
    setup(value,THREE,TWO,cw,mapped);
    before_regs=fpr_phys_flat_o;
    for (int p=0;p<8;p++) begin
      raw_before[p*80+:80]=dut.u_state.bank[p]; mapping[p*3+:3]=dut.u_state.map[p];
    end
    operand=(kind<2) ? f_mem_as_float(payload,kind==0 ? 4'd4 : 4'd8)
                     : f_mem_as_int(payload,kind==2 ? 4'd2 : 4'd4);
    ra=reference_result(0,before_regs[79:0],prior_mem ? ONE : before_regs[159:80],cw);
    rb=reference_result(op,ra[79:0],operand,cw);
    after_a=before_regs; after_a[79:0]=ra[79:0];
    after_b=after_a; after_b[79:0]=rb[79:0];
    raw_a=raw_before; raw_a[int'(mapping[2:0])*80+:80]=ra[79:0];
    raw_b=raw_a; raw_b[int'(mapping[2:0])*80+:80]=rb[79:0];
    sa=f_arith_fstat(fstat_o,ra); sb=f_arith_fstat(sa,rb);
    if (value==SIX && payload==mem_one(kind) && op==0 && !mapped && !prior_mem &&
        rb!=85'h04002a000000000000000) $fatal(1,"MEM-FWD exact 6+3+1=10 anchor");
    if (prior_mem) mem_cmd(kind,0,mem_one(kind),32'h1000);
    else arith(0,1,0,32'h1000);
    dp_a=prior_mem ? 32'h01201000 : 32'h11223344;
    ds_a=prior_mem ? 16'h40 : 16'h20;
    ready_is(1,"memory A issue"); tick(); ae=edges;
    mem_cmd(kind,op,payload,32'h2000);
    ready_is(0,"memory stage0 hazard"); tick();
    ready_is(0,"memory stage1 hazard"); tick();
    ready_is(MEM_FORWARD,"memory final registered hazard");
    mem_state(before_regs,0,cw,32'h1000,dp_a,ds_a);
    bank_is(raw_before,mapping);
    if (MEM_FORWARD && (dut.alu_a!=ra[79:0] || dut.alu_b!=operand || dut.arith_forward_sti))
      $fatal(1,"MEM-FWD wrong ST0/memory select");
    tick();
    if (!rsp_valid || rsp_arith!=ra || responses!=1)
      $fatal(1,"MEM-FWD older ordered response");
    mem_state(after_a,sa,cw,MEM_FORWARD ? 32'h2000 : 32'h1000,
              MEM_FORWARD ? 32'h01202000 : dp_a,MEM_FORWARD ? 16'h40 : ds_a);
    bank_is(raw_a,mapping);
    if (!MEM_FORWARD) begin ready_is(1,"memory bank after commit"); tick(); end
    be=edges; idle();
    if (be-ae!=(MEM_FORWARD ? 3 : 4) || accepts!=2)
      $fatal(1,"MEM-FWD acceptance gap %0d",be-ae);
    // Poison unaccepted producer pins: operand/metadata were captured once.
    cmd_mem='1; cmd_update_fip=1; cmd_update_fdp=1;
    cmd_fip='1; cmd_fdp='1; cmd_fcs='1; cmd_fds='1;
    for (int i=1;i<=3;i++) begin
      tick();
      if (rsp_valid!=(i==3)) $fatal(1,"MEM-FWD younger response order");
      mem_state(i==3 ? after_b : after_a,i==3 ? sb : sa,cw,32'h2000,32'h01202000,16'h40);
      bank_is(i==3 ? raw_b : raw_a,mapping);
    end
    if (rsp_arith!=rb || responses!=2 || accepts!=2) $fatal(1,"MEM-FWD counts/result");
    repeat(3) begin tick(); if (busy || rsp_valid) $fatal(1,"MEM-FWD owner leak"); end
    memory_checks++;
  endtask
  task automatic mem_reject(input int kind, input int why);
    logic [639:0] before_regs;
    setup(SIX,THREE,TWO,why==2 ? 16'h037e : 16'h037f);
    if (why==3) begin
      idle(); cmd_op=FX_FLDENV; cmd_env_image[15:0]=16'h037f;
      cmd_env_image[47:32]=16'h0080; cmd_valid=1;
      ready_is(1,"memory ES setup"); tick(); idle(); tick();
    end
    before_regs=fpr_phys_flat_o; accepts=0; responses=0;
    // Prior pop, younger pop, unmasked exception, existing ES, non-fast DIV.
    arith(0,1,0,32'h1000,why==0); ready_is(1,"memory reject older"); tick();
    mem_cmd(kind,why==4 ? 3'd6 : 3'd0,mem_one(kind),32'h2000);
    cmd_pop=(why==1);
    for (int i=0;i<3;i++) begin ready_is(0,"memory guarded serialization"); tick(); end
    if (accepts!=1 || responses!=1 || fip_o!=32'h1000 || fdp_o!=32'h11223344)
      $fatal(1,"MEM-FWD excluded request accepted");
    idle(); repeat(4) begin tick(); if (busy || rsp_valid) $fatal(1,"MEM-FWD rejection leak"); end
    memory_checks++;
  endtask
  task automatic mem_mixed(input int kind);
    logic [84:0] ra,rb,rc;
    setup(SIX,THREE,TWO,16'h037f);
    ra=reference_result(0,THREE,SIX,16'h037f);
    rb=reference_result(0,SIX,TWO,16'h037f);
    rc=reference_result(0,rb[79:0],ONE,16'h037f);
    arith(1,1,0,32'h1000); tick();
    arith(0,2,0,32'h2000); ready_is(1,"memory mixed independent B"); tick();
    mem_cmd(kind,0,mem_one(kind),32'h2000);
    ready_is(0,"memory mixed B stage0"); tick();
    ready_is(0,"memory A final cannot erase B stage1"); tick();
    if (!rsp_valid || rsp_arith!=ra || accepts!=2) $fatal(1,"MEM-FWD mixed A");
    ready_is(MEM_FORWARD,"memory B final"); tick();
    if (!rsp_valid || rsp_arith!=rb || responses!=2) $fatal(1,"MEM-FWD mixed B");
    if (!MEM_FORWARD) begin ready_is(1,"memory mixed postcommit"); tick(); end
    idle(); repeat(3) tick();
    if (!rsp_valid || rsp_arith!=rc || responses!=3 || accepts!=3 ||
        st_flat_o[79:0]!=rc[79:0] || st_flat_o[159:80]!=ra[79:0])
      $fatal(1,"MEM-FWD mixed C");
    memory_checks++;
  endtask
  task automatic mem_reset(input int kind, input int age);
    setup(SIX,THREE,TWO,16'h037f);
    arith(0,1,0,32'h1000); tick();
    mem_cmd(kind,0,mem_one(kind),32'h2000);
    repeat(age) tick();
    rst_n=0; tick(); idle(); rst_n=1;
    repeat(6) begin
      tick();
      if (busy || rsp_valid || fpr_phys_flat_o!=0 || ftop_o!=0 || fptag_o!=8'hff ||
          fstat_o!=0 || fctrl_o!=16'h037f || fip_o!=0 || fdp_o!=0)
        $fatal(1,"MEM-FWD reset stale owner age=%0d",age);
    end
    memory_checks++;
  endtask
  task automatic memory_cases;
    logic [15:0] cw;
    for (int kind=0;kind<4;kind++) begin
      for (int op=0;op<6;op++) if (op==0 || op==1 || op==4 || op==5)
        for (int mapped=0;mapped<2;mapped++)
          for (int prior=0;prior<2;prior++)
            mem_pair(kind,3'(op),mem_one(kind),SIX,16'h037f,1'(mapped),1'(prior));
      for (int pc=0;pc<4;pc++) if (pc!=1)
        for (int rc=0;rc<4;rc++) begin
          cw=16'h007f | (16'(pc)<<8) | (16'(rc)<<10);
          mem_pair(kind,0,mem_one(kind),80'h403e8000000000000001,cw);
          mem_pair(kind,5,mem_one(kind),80'hc03e8000000000000001,cw);
        end
      mem_pair(kind,0,mem_one(kind),SNAN,16'h037f);
      mem_pair(kind,4,mem_one(kind),QNAN,16'h037f);
      mem_pair(kind,1,mem_one(kind),MAXFINITE,16'h037f);
      mem_pair(kind,0,mem_one(kind),80'd1,16'h037f);
      for (int why=0;why<5;why++) mem_reject(kind,why);
      mem_mixed(kind);
      for (int age=0;age<7;age++) mem_reset(kind,age);
    end
    mem_pair(0,0,80'h7f800123,SIX,16'h037f);
    mem_pair(1,0,80'h7ff0000000000123,SIX,16'h037f);
    mem_pair(0,5,80'hff800000,INF,16'h037f);
    mem_pair(1,5,80'hfff0000000000000,INF,16'h037f);
    mem_pair(2,0,80'hffff8000,SIX,16'h037f);
    mem_pair(3,5,80'h80000000,SIX,16'h037f);
    mem_pair(0,1,80'h80000000,80'h80000000000000000000,16'h037f);
    mem_pair(1,0,80'd1,SIX,16'h037f);
    $display("FP-MEM-FORWARD-LEAF-OK enabled=%0d memory_checks=%0d",MEM_FORWARD,memory_checks);
  endtask
