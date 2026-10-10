// Exercise the ACTUAL core_mem_chain.svh. Cache-return identity and DTLB
// replies are explicit mocked inputs; this is not an interrupt-delivery or
// physical-cache test. The full-core QEMU corpus supplies architectural checks.
module tb_raw_branch_guards;
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  localparam int SG_CS=1, SG_SS=2, SG_DS=3, S_PIPE=28;
  logic clk=0, rst_n;
  logic pipe_mem_active_q, pipe_pair_lookahead, v_bytes_ok, pipe_new_mem_req;
  logic pipe_new_load_req, pipe_mem_we_q, pipe_int_commit, fp_shared_mem_admit;
  logic u_pred_taken, v_pred_taken, v_br_taken_eff;
  logic cycle_mode, real_bus, def16, a20_on, irq_shadow, fp_dbg_active;
  logic dbg_step_active, fp_issue_block, smi_take, nmi_take, intr_take;
  logic exec_flush_all, ic_snoop_valid, ic_snoop_valid1, fx_act, fx_abort_q, bus_err;
  logic dbg_block_issue, dbg_bp_en, paging_on, sys_mode, sys_fp_ok, real_mode, cs_d;
  logic tlb_flush, tlb_fill_en, pipe_mem_abort_now, ven_fetchdbg_en;
  logic mem_next_req, mem_next_commit, mem_next_ready;
  logic [31:0] mem_next_addr;
  logic [3:0] mem_next_wstrb;
  int state, pending_mem_pen, stall_cnt, mispred_bubbles, checks=0;
  logic [1:0] eff_cpl;
  logic [31:0] eip,flin,pipe_commit_eip,pipe_mem_eip_q,u_target,v_target;
  logic [31:0] pipe_load_addr,d_ea;
  logic [2:0] pipe_mem_seg,d_seg;
  logic [31:0] seg_base[6],seg_limit[6],gpr_o[8];
  logic [15:0] seg_sel[6];
  logic [7:0] seg_attr[6],ic_front_bytes[22];
  logic seg_pm_loaded[6];
  fpd_t pipe_u_eff,pipe_v_eff,u_d,v_d,pipe_mem_u_q,pipe_mem_v_q;
  logic returned_first,returned_last;
  assign flin=seg_base[SG_CS]+eip;
  assign pipe_commit_eip=eip;
  assign u_d=pipe_u_eff;
  function automatic logic ic_buffered(input logic [31:0] addr);
    return addr==flin+32'd4 ? returned_first : returned_last;
  endfunction
  `include "core_mem_chain.svh"
  assign mc_lookup_phys=mc_query_lin^32'h40000000;

  task automatic tick;
    clk=0; #1; clk=1; #1; clk=0; #1;
  endtask
  task automatic defaults;
    rst_n=1; pipe_mem_active_q=0; pipe_pair_lookahead=1; v_bytes_ok=1;
    pipe_new_mem_req=0; pipe_new_load_req=0; pipe_mem_we_q=0;
    pipe_int_commit=1; fp_shared_mem_admit=0;
    u_pred_taken=0; v_pred_taken=0; v_br_taken_eff=0;
    cycle_mode=1; real_bus=1; def16=0; a20_on=1; irq_shadow=0; fp_dbg_active=0;
    dbg_step_active=0; fp_issue_block=0; smi_take=0; nmi_take=0; intr_take=0;
    exec_flush_all=0; ic_snoop_valid=0; ic_snoop_valid1=0; fx_act=0; fx_abort_q=0; bus_err=0;
    dbg_block_issue=0; dbg_bp_en=0; paging_on=1; sys_mode=1; sys_fp_ok=1; real_mode=0; cs_d=1;
    tlb_flush=0; tlb_fill_en=0; pipe_mem_abort_now=0; ven_fetchdbg_en=0;
    mem_next_ready=1; state=S_PIPE; pending_mem_pen=0; stall_cnt=0; mispred_bubbles=0;
    eff_cpl=0; eip=32'h200; pipe_mem_eip_q=0; u_target=32'h800; v_target=32'h900;
    pipe_load_addr=0;d_ea=0;pipe_mem_seg=3;d_seg=3;
    foreach(seg_base[i]) begin
      seg_base[i]=32'h10000000;seg_limit[i]=32'hffffffff;seg_sel[i]=16'h10;
      seg_attr[i]=8'h92;seg_pm_loaded[i]=1;
    end
    foreach(gpr_o[i]) gpr_o[i]=32'h3000;
    foreach(ic_front_bytes[i]) ic_front_bytes[i]=8'h90;
    ic_front_bytes[4]=8'h8b;ic_front_bytes[5]=8'h50;ic_front_bytes[6]=8'h04;
    pipe_u_eff='0;pipe_u_eff.len=2;pipe_u_eff.simple=1;
    pipe_v_eff='0;pipe_v_eff.len=2;pipe_v_eff.simple=1;
    pipe_v_eff.is_branch=1;pipe_v_eff.br_cond=1;
    v_d=pipe_v_eff;pipe_mem_u_q='0;pipe_mem_v_q='0;
    returned_first=1;returned_last=1;
    mc_lookup_hit=1;mc_lookup_perm=3'b111;mc_lookup_dirty=0;
  endtask
  task automatic check(input bit offer,commit);
    #1;
    assert(mem_next_req===offer && mem_next_commit===commit)
      else $fatal(1,"guard check%0d got%b/%b expected%b/%b",checks,
                  mem_next_req,mem_next_commit,offer,commit);
    assert(!mc_chain_accept && !mc_valid_q && mc_query_v.len==0)
      else $fatal(1,"hint acquired an execution descriptor");
    if(offer) assert(mem_next_addr==((seg_base[SG_DS]+gpr_o[0]+32'd4)^32'h40000000))
      else $fatal(1,"query address/translation changed");
    checks++;
  endtask
  initial begin
    defaults();rst_n=0;tick();rst_n=1;check(1,1);tick();check(1,1);
    // Actual outcome, retirement and leaf availability must not enter query
    // selection. Only the checked commit edge may capture the resident read.
    v_br_taken_eff=1;check(1,0);tick();
    defaults();pipe_int_commit=0;check(1,0);tick();
    defaults();mem_next_ready=0;check(1,1);
    assert(!mc_prime_accept) else $fatal(1,"rejected leaf accepted");tick();
    for(int deny=0;deny<35;deny++) begin
      defaults();
      case(deny)
        0:cycle_mode=0;1:real_bus=0;2:state=1;3:def16=1;4:a20_on=0;
        5:irq_shadow=1;6:fp_dbg_active=1;7:pending_mem_pen=1;8:stall_cnt=1;
        9:mispred_bubbles=1;10:dbg_step_active=1;11:fp_issue_block=1;
        12:smi_take=1;13:nmi_take=1;14:intr_take=1;15:exec_flush_all=1;
        16:ic_snoop_valid=1;17:ic_snoop_valid1=1;18:fx_act=1;19:fx_abort_q=1;
        20:bus_err=1;21:dbg_block_issue=1;22:dbg_bp_en=1;23:mc_lookup_hit=0;
        24:mc_lookup_perm=3'b110;25:begin eff_cpl=3;mc_lookup_perm=3'b011;end
        26:sys_fp_ok=0;27:real_mode=1;28:cs_d=0;29:seg_pm_loaded[SG_DS]=0;
        30:seg_sel[SG_DS]=0;31:seg_attr[SG_DS]=8'h12;
        32:seg_attr[SG_DS]=8'h9a;33:seg_attr[SG_DS]=8'h96;
        34:pipe_mem_active_q=1;
      endcase
      check(0,0);tick();
    end
    defaults();v_pred_taken=1;check(0,0);
    defaults();pipe_v_eff.br_cond=0;check(0,0);
    defaults();pipe_v_eff.w16=1;check(0,0);
    defaults();returned_first=0;check(0,0);
    defaults();returned_last=0;check(0,0);
    defaults();pipe_u_eff.writes=8'h01;check(0,0);
    defaults();pipe_v_eff.writes=8'h01;check(0,0);
    defaults();pipe_u_eff.writes=8'h04;check(1,1); // WAW to future MOV dest is safe
    defaults();ic_front_bytes[4]=8'h66;check(0,0);
    defaults();ic_front_bytes[5]=8'h54;check(0,0); // SIB
    defaults();ic_front_bytes[5]=8'h90;check(0,0); // disp32
    defaults();ic_front_bytes[5]=8'h20;check(0,0); // ESP destination
    // Exact returned-code line, page and CS extents. Keep data safely resident.
    for(int offset=0;offset<4096;offset++) begin
      defaults();eip=32'(offset);
      check(offset%32<=25 || offset%32>=28 && offset<=4089,
            offset%32<=25 || offset%32>=28 && offset<=4089);
    end
    for(int limit=0;limit<16;limit++) begin
      defaults();seg_limit[SG_CS]=eip+32'(limit);
      check(limit>=6,limit>=6);
    end
    for(int offset=0;offset<32;offset++) begin
      defaults();gpr_o[0]=32'h3000+32'(offset);
      check((offset+4)%32<=28,(offset+4)%32<=28);
    end
    // U branch uses the existing checked V decoder, not the tiny third-slot
    // recognizer. Actual U outcome and V byte-valid remain mandatory.
    defaults();pipe_pair_lookahead=0;pipe_u_eff=pipe_v_eff;
    v_d=mc_raw_branch_mov(8'h8b,8'h50,8'h04);check(1,1);
    pipe_u_eff.br_taken=1;check(1,0);
    pipe_u_eff.br_taken=0;v_bytes_ok=0;check(0,0);
    $display("RAW-BRANCH-GUARDS-OK checks=%0d",checks);$finish;
  end
endmodule
