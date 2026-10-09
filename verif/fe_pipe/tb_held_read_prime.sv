// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tb_held_read_prime;
  typedef struct packed {
    logic [3:0] len;
    logic is_stack, is_fp, is_branch;
  } descriptor_t;
  descriptor_t u_d, v_d, pipe_mem_u_q;
  localparam int SG_CS=1, S_PIPE=1, S_WALK=2, S_HALT=3, S_SHUTDOWN=4;
  logic clk=0, rst_n, exec_flush_all, icsnp_v1, icsnp_v2;
  logic ic_snoop_valid, ic_snoop_valid1, ic_snoop_valid2;
  logic tlb_flush, tlb_fill_en, pipe_mem_abort_now;
  logic pipe_mem_active_q, pipe_new_load_req, def16, v_bytes_ok;
  logic xlate_miss, fe_xlate_pend, mem_ack, pipe_pair_lookahead;
  logic pipe_pair_mem_ok;
  logic pipe_int_commit, pipe_mem_we_q, pipe_mem_pair_q, mc_valid_q;
  logic [31:0] flin, eip, seg_limit[6];
  integer state, checks=0;
  `include "core_raw_held_prime.svh"

  task automatic tick;
    clk=0; #1; clk=1; #1; clk=0; #1;
  endtask
  task automatic defaults;
    rst_n=1; exec_flush_all=0; icsnp_v1=0; icsnp_v2=0;
    ic_snoop_valid=0; ic_snoop_valid1=0; ic_snoop_valid2=0;
    tlb_flush=0; tlb_fill_en=0; pipe_mem_abort_now=0;
    pipe_mem_active_q=0; pipe_new_load_req=1; def16=0; v_bytes_ok=1;
    xlate_miss=0; fe_xlate_pend=0; mem_ack=0; pipe_pair_lookahead=0; pipe_pair_mem_ok=0;
    pipe_int_commit=0; pipe_mem_we_q=0; pipe_mem_pair_q=0; mc_valid_q=0;
    state=S_PIPE; flin=32'h10000200; eip=32'h200;
    foreach(seg_limit[i]) seg_limit[i]=32'hffff_ffff;
    u_d='0; u_d.len=2; v_d='0; v_d.len=3; pipe_mem_u_q=u_d;
  endtask
  task automatic check(input bit held, input bit fresh);
    #1;
`ifndef VEN_RAW_HELD_READ_PRIME
    held=0; fresh=0;
`endif
    assert(mc_held_read_prime===held && mc_fresh_read_prime===fresh)
      else $fatal(1,"held-prime check%0d actual=%b/%b expected=%b/%b",
                  checks,mc_held_read_prime,mc_fresh_read_prime,held,fresh);
    checks++;
  endtask
  task automatic capture;
    tick(); pipe_mem_active_q=1; pipe_new_load_req=0;
  endtask

  initial begin
    bit expected;
    logic [32:0] vend;
    logic [31:0] nextlin;
    defaults(); rst_n=0; tick(); rst_n=1;
    // Every admission predicate combination, including translation detours.
    for(int mask=0;mask<1024;mask++) begin
      defaults();
      pipe_new_load_req=mask[0]; v_bytes_ok=mask[1]; def16=mask[2];
      mem_ack=mask[3]; xlate_miss=mask[4]; fe_xlate_pend=mask[5];
      u_d.is_stack=mask[6]; u_d.is_fp=mask[7]; u_d.is_branch=mask[8];
      pipe_pair_lookahead=mask[9];
      expected=mask[0] && mask[1] && !mask[2] &&
               (!mask[3] || mask[4] || mask[5]) &&
               !(mask[6] || mask[7] || mask[8] || mask[9]);
      capture(); check(expected,0);
    end
    // Full code-page offsets and every short U/V length. No stale bytes or
    // successor page may be legitimated by retaining a raw descriptor.
    for(int offset=0;offset<4096;offset++)
      for(int ulen=1;ulen<=7;ulen++)
        for(int vlen=0;vlen<=7;vlen++) begin
          defaults(); flin=32'h10000000+32'(offset); eip=32'(offset);
          u_d.len=4'(ulen); v_d.len=4'(vlen);
          nextlin=flin+32'(ulen);
          expected=vlen!=0 && nextlin[31:12]==flin[31:12] &&
                   (int'(nextlin[4:0])+vlen<=32);
          capture(); check(expected,0);
        end
    // Exact segment endpoint and widened addition (including 32-bit wrap).
    for(int mode=0;mode<2;mode++)
      for(int limit=0;limit<64;limit++)
        for(int offset=0;offset<64;offset++) begin
          defaults();
          eip=(mode!=0 ? 32'hffff_ffc0 : 32'd0)+32'(offset);
          seg_limit[SG_CS]=(mode!=0 ? 32'hffff_ffc0 : 32'd0)+32'(limit);
          vend={1'b0,eip}+33'd4;
          expected=vend<={1'b0,seg_limit[SG_CS]};
          capture(); check(expected,0);
        end
    // Each invalidator must permanently poison this saved descriptor, even
    // if the event disappears before the outstanding U read finishes.
    for(int event_id=0;event_id<12;event_id++) begin
      defaults(); capture(); check(1,0);
      case(event_id)
        0: rst_n=0;
        1: exec_flush_all=1;
        2: icsnp_v1=1;
        3: icsnp_v2=1;
        4: ic_snoop_valid=1;
        5: ic_snoop_valid1=1;
        6: ic_snoop_valid2=1;
        7: tlb_flush=1;
        8: tlb_fill_en=1;
        9: pipe_mem_abort_now=1;
        10: state=S_HALT;
        11: state=S_SHUTDOWN;
      endcase
      tick(); check(0,0);
      defaults(); pipe_mem_active_q=1; pipe_new_load_req=0; check(0,0);
      tick(); check(0,0);
    end
    // Saved owner's class/pair state, never a live reinterpretation of U.
    for(int mask=0;mask<128;mask++) begin
      defaults(); capture();
      pipe_mem_active_q=mask[0]; pipe_mem_we_q=mask[1];
      pipe_mem_pair_q=mask[2]; pipe_mem_u_q.is_stack=mask[3];
      pipe_mem_u_q.is_fp=mask[4]; pipe_mem_u_q.is_branch=mask[5];
      mc_valid_q=mask[6];
      check(mask[0] && !(|mask[6:1]),0);
    end
    // Fresh owner is an ACK-independent offer, not an acceptance signal.
    for(int mask=0;mask<256;mask++) begin
      defaults(); tick(); pipe_mem_active_q=mask[0]; mc_valid_q=mask[1];
      pipe_new_load_req=mask[2]; pipe_pair_lookahead=mask[3];
      u_d.is_stack=mask[4]; u_d.is_fp=mask[5]; u_d.is_branch=mask[6];
      pipe_pair_mem_ok=mask[7];
      expected=!mask[0] && !mask[1] && mask[2] && !(|mask[7:3]);
      check(mask[0] && !mask[1],expected);
      mem_ack=1; check(mask[0] && !mask[1],expected);
    end
    defaults(); capture(); check(1,0);
    state=S_WALK; check(0,0); state=S_PIPE; check(1,0);
    pipe_int_commit=1; tick(); check(0,0); pipe_int_commit=0;
    tick(); check(0,0);
    $display("HELD-READ-PRIME-LEAF-OK checks=%0d",checks);
    $finish;
  end
endmodule
