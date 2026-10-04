// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`default_nettype none
`timescale 1ns/1ps
module tb_ic_residency_span;
  localparam int IC_SETS=128, IC_WAYS=2, IC_LINE=32;
  localparam int IC_IDXW=7, IC_WAYW=1, IC_TAGW=20;
  localparam int IWORDS=4;
  typedef struct packed { logic [3:0] len; } tiny_decode_t;
  tiny_decode_t u_d, v_d;
  logic [31:0] flin;
  wire [31:0] flin_nl={flin[31:5],5'd0}+32'd32;
  logic [IC_TAGW-1:0] ic_tag_o [IC_SETS][IC_WAYS];
  logic ic_val_o [IC_SETS][IC_WAYS];
  logic [1:0] icbp_v;
  logic [IC_IDXW-1:0] icbp_set [2];
  logic [IC_TAGW-1:0] icbp_tag [2];
  logic [IC_WAYW-1:0] icbp_way [2];
  logic [IC_LINE*8-1:0] ic_rd_lineA, ic_rd_lineB;
  logic [IC_IDXW-1:0] rdA_set_q, rdB_set_q, ic_rd_setA, ic_rd_setB;
  logic [IC_WAYW-1:0] rdA_way_q, rdB_way_q;
  logic ic_rd_collA, ic_rd_collB;
  logic exec_issue_ok, pipe_fetch_checked_handoff;
  logic [5:0] fp_pipe_decode_win_last;
  logic old_pipe_bytes_ok, old_v_bytes_ok;
  logic [31:0] old_pf_miss_fa;
  logic new_pipe_bytes_ok, new_v_bytes_ok;
  logic [31:0] new_pf_miss_fa;
  integer checks=0;

  // Raw functions, current marked span, and old caller expressions are taken
  // verbatim from the actual core by the runner; no copied oracle logic here.
  `include "ic_residency_reference.svh"
  `include "ic_front_residency.svh"

  // Intended production substitutions only replace lookup calls. In
  // particular retain the original four-state OR comparison guards.
  always_comb begin
    new_pipe_bytes_ok = exec_issue_ok && ic_front_a[IC_WAYW] &&
        (({1'b0,flin[4:0]} + fp_pipe_decode_win_last < 6'd32) ||
         ic_res_present_offset(fp_pipe_decode_win_last)) &&
        (({1'b0,flin[4:0]} + {2'b0,u_d.len} <= 6'd32) ||
         ic_res_present_end({2'b0,u_d.len}));
    new_pf_miss_fa = !ic_front_a[IC_WAYW] ? flin :
        !ic_res_present_offset(fp_pipe_decode_win_last)
            ? (flin + {26'd0,fp_pipe_decode_win_last}) :
              (flin + {28'd0,u_d.len} - 32'd1);
    new_v_bytes_ok = exec_issue_ok && !pipe_fetch_checked_handoff &&
        ic_res_present_offset({2'b0,u_d.len}) &&
        ic_res_present_end({2'b0,u_d.len}+{2'b0,v_d.len});
  end

  task automatic check_bit(input logic got, input logic want,
                           input string label);
    begin
      checks=checks+1;
      if (!(got === want))
        $fatal(1,"IC-RESIDENCY %s got=%b want=%b flin=%h U=%b V=%b window=%b",
               label,got,want,flin,u_d.len,v_d.len,fp_pipe_decode_win_last);
    end
  endtask

  task automatic check_callers;
    begin
      #1;
      check_bit(new_pipe_bytes_ok,old_pipe_bytes_ok,"pipe_bytes_ok");
      check_bit(new_v_bytes_ok,old_v_bytes_ok,"v_bytes_ok");
      checks=checks+1;
      if (!(new_pf_miss_fa === old_pf_miss_fa))
        $fatal(1,"IC-RESIDENCY pf_miss_fa got=%h want=%h flin=%h U=%b window=%b",
               new_pf_miss_fa,old_pf_miss_fa,flin,u_d.len,fp_pipe_decode_win_last);
      check_bit(ic_res_present_end({2'b0,u_d.len}+{2'b0,v_d.len}),
                ic_present(flin+{28'd0,u_d.len}+{28'd0,v_d.len}-32'd1),"V-last");
      check_bit(ic_res_buffered_end({2'b0,u_d.len}),
                ic_buffered(flin+{28'd0,u_d.len}-32'd1),"buffered-U-last");
      check_bit(ic_res_present_offset(fp_pipe_decode_win_last),
                ic_present(flin+{26'd0,fp_pipe_decode_win_last}),"window-last");
    end
  endtask

  task automatic clear_state;
    begin
      for (integer s=0;s<IC_SETS;s=s+1)
        for (integer w=0;w<IC_WAYS;w=w+1) begin
          ic_val_o[s][w]=0; ic_tag_o[s][w]='0;
        end
      icbp_v=0;
      for (integer i=0;i<2;i=i+1) begin
        icbp_set[i]='0; icbp_tag[i]='0; icbp_way[i]='0;
      end
      rdA_set_q=7'd23; rdB_set_q=7'd29;
      rdA_way_q=0; rdB_way_q=0;
      ic_rd_collA=0; ic_rd_collB=0;
      ic_rd_setA=0; ic_rd_setB=0;
      ic_rd_lineA={32{8'ha5}}; ic_rd_lineB={32{8'h3c}};
      exec_issue_ok=1; pipe_fetch_checked_handoff=0;
      fp_pipe_decode_win_last=6'd5; u_d.len=0; v_d.len=0;
    end
  endtask

  task automatic resident(input logic [31:0] addr,input integer way);
    begin
      ic_val_o[addr[5 +: IC_IDXW]][way]=1;
      ic_tag_o[addr[5 +: IC_IDXW]][way]=addr[5+IC_IDXW +: IC_TAGW];
    end
  endtask

  task automatic bypass(input integer slot,input logic [31:0] addr,
                        input logic [IC_WAYW-1:0] way);
    begin
      icbp_v[slot]=1; icbp_set[slot]=addr[5 +: IC_IDXW];
      icbp_tag[slot]=addr[5+IC_IDXW +: IC_TAGW]; icbp_way[slot]=way;
    end
  endtask

  task automatic fixture(input logic [31:0] base,input integer mode);
    logic [31:0] b;
    begin
      clear_state(); flin=base; b=base+32'd32;
      if (mode!=0 && mode!=2) resident(base,0);
      if (mode!=0 && mode!=1) resident(b,1);
      if ((mode%2)==0) resident(base-32'd32,1);
      if (mode==4) begin
        resident(base,1); resident(b,0); // duplicate valid tags: last way wins
      end
      if (mode==5) bypass(0,base,1);
      if (mode==6) begin bypass(0,base,1); bypass(1,base,0); end
      if (mode==7) begin
        ic_val_o[base[5 +: IC_IDXW]][0]=0;
        ic_val_o[b[5 +: IC_IDXW]][1]=0;
        bypass(0,base,0); bypass(1,b,1); // bypass-only residency
      end
      rdA_set_q=base[5 +: IC_IDXW]; rdA_way_q=ic_hit_way(base);
      rdB_set_q=b[5 +: IC_IDXW]; rdB_way_q=ic_hit_way(b);
      case(mode)
        8: begin
          rdA_set_q=b[5 +: IC_IDXW]; rdA_way_q=ic_hit_way(b);
          rdB_set_q=base[5 +: IC_IDXW]; rdB_way_q=ic_hit_way(base);
        end
        9,10,11: begin
          rdB_set_q=rdA_set_q; rdB_way_q=rdA_way_q;
          if (mode>=10) ic_rd_collA=1;
          if (mode==11) ic_rd_collB=1;
        end
        12: begin rdA_way_q=~rdA_way_q; rdB_way_q=~rdB_way_q; end
        13: begin rdA_set_q=7'd23; rdB_set_q=7'd29; end
        14: begin ic_rd_collA=1'bx; ic_rd_collB=1'bz; end
        15: begin bypass(0,base,0); bypass(1,base,1'bx); end
        16: begin
          ic_val_o[base[5 +: IC_IDXW]][1]=1'bx;
          ic_tag_o[b[5 +: IC_IDXW]][1]='x;
        end
        17: begin rdA_set_q='x; rdB_way_q='z; end
        default: begin end
      endcase
      // Test-only refresh after metadata changes. Icarus issue #983 misses
      // function-global array changes in continuous calls at a fixed address.
      // Pulse only the input address, then settle; never drive probe outputs
      // or expected results. This tests the truth table, not event sensitivity.
      flin='x; #1; flin=base; #1;
    end
  endtask

  task automatic check_span;
    logic [IC_WAYW:0] raw_a,raw_b;
    begin
      #1;
      raw_a={ic_present(flin),ic_hit_way(flin)};
      raw_b={ic_present(flin_nl),ic_hit_way(flin_nl)};
      if (!(ic_front_a === raw_a) || !(ic_front_b === raw_b))
        $fatal(1,"IC-RESIDENCY extracted A/B probe mismatch flin=%h A=%b rawA=%b B=%b rawB=%b",
               flin,ic_front_a,raw_a,ic_front_b,raw_b);
      check_bit(ic_res_a_buffered,ic_buffered(flin),"buffered-direct-A");
      check_bit(ic_res_b_buffered,ic_buffered(flin_nl),"buffered-direct-B");
      for (integer d=0;d<32;d=d+1) begin
        check_bit(ic_res_present_offset(6'(d)),ic_present(flin+32'(d)),"offset-present");
        check_bit(ic_res_buffered_offset(6'(d)),ic_buffered(flin+32'(d)),"offset-buffered");
      end
      for (integer c=0;c<=30;c=c+1) begin
        check_bit(ic_res_present_end(6'(c)),ic_present(flin+32'(c)-32'd1),"end-present");
        check_bit(ic_res_buffered_end(6'(c)),ic_buffered(flin+32'(c)-32'd1),"end-buffered");
      end
      // Existing stale-byte behavior is not changed by the proposal. Exercise
      // the actual extracted span under duplicate/redirected/collided ports.
      for (integer d=0;d<IC_FRONT_BYTES;d=d+1)
        if (!(ic_front_bytes[d] === ic_byte(flin+32'(d))))
          $fatal(1,"IC-RESIDENCY existing byte span changed at offset=%0d",d);
    end
  endtask

  task automatic exhaustive_known_lengths;
    logic [31:0] base;
    begin
      for (integer which=0;which<3;which=which+1) begin
        case(which)
          0: base=32'h00100fe0; // set127->0 carries into a DIFFERENT tag
          1: base=32'hffffffe0; // full32-bit forward wrap
          default: base=32'h00000000; // zero-length backwards wrap
        endcase
        for (integer mode=0;mode<18;mode=mode+1) begin
          fixture(base,mode);
          for (integer off=0;off<32;off=off+1) begin
            flin=base+32'(off); check_span();
            for (integer u=0;u<16;u=u+1)
              for (integer v=0;v<16;v=v+1) begin
                u_d.len=4'(u); v_d.len=4'(v);
                fp_pipe_decode_win_last=6'd5; check_callers();
                fp_pipe_decode_win_last=6'd6; check_callers();
              end
          end
        end
      end
    end
  endtask

  task automatic four_state_cases;
    logic [3:0] unknown_len;
    begin
      for (integer off=0;off<32;off=off+1) begin
        fixture(32'hffffffe0,3); flin=32'hffffffe0+32'(off);
        for (integer bitno=0;bitno<4;bitno=bitno+1) begin
          // Icarus cannot elaborate a variable bit-select lvalue directly
          // on a packed struct member. Mutate a plain vector, then assign
          // the entire member; the driven four-state value is unchanged.
          unknown_len=0; unknown_len[bitno]=1'bx;
          u_d.len=unknown_len; v_d.len=0; check_callers();
          unknown_len=4'hf; unknown_len[bitno]=1'bz;
          u_d.len=unknown_len; v_d.len=4'hf; check_callers();
          unknown_len=0; unknown_len[bitno]=1'bx;
          u_d.len=0; v_d.len=unknown_len; check_callers();
          unknown_len=4'hf; unknown_len[bitno]=1'bz;
          u_d.len=4'hf; v_d.len=unknown_len; check_callers();
        end
        u_d.len='x; v_d.len='z; check_callers();
        u_d.len=0; v_d.len=0;
        fp_pipe_decode_win_last=6'b0001xx; check_callers();
        fp_pipe_decode_win_last=6'b0001zz; check_callers();
        fp_pipe_decode_win_last=6'd5;
        exec_issue_ok=1'bx; check_callers();
        exec_issue_ok=1'bz; pipe_fetch_checked_handoff=1'bx; check_callers();
        exec_issue_ok=0; pipe_fetch_checked_handoff=1'bz; check_callers();
        exec_issue_ok=1; pipe_fetch_checked_handoff=1; check_callers();
        check_bit(ic_res_present_offset(6'b00x001),
                  ic_present(flin+{26'd0,6'b00x001}),"unknown-offset");
        check_bit(ic_res_buffered_offset(6'b00z001),
                  ic_buffered(flin+{26'd0,6'b00z001}),"unknown-buffered-offset");
      end
      // Direct flin can retain a known line identity with unknown byte offset,
      // while flin+offset arithmetic becomes X. Check both contracts separately.
      for (integer bitno=0;bitno<32;bitno=bitno+1) begin
        fixture(32'h00100fe0,3); flin[bitno]=1'bx; check_callers();
        check_bit(ic_res_a_buffered,ic_buffered(flin),"X-flin-direct-buffer");
        check_bit(ic_res_present_offset(6'd0),ic_present(flin+32'd0),"X-flin-added-zero");
        check_bit(ic_res_buffered_offset(6'd15),ic_buffered(flin+32'd15),"X-flin-slow-end");
        fixture(32'h00100fe0,3); flin[bitno]=1'bz; check_callers();
      end
    end
  endtask

  initial begin
    exhaustive_known_lengths();
    four_state_cases();
`ifdef VEN_IC_NO_FETCH_BYPASS
    $display("IC-RESIDENCY-PROPOSAL-OK no_bypass=1 checks=%0d",checks);
`else
    $display("IC-RESIDENCY-PROPOSAL-OK no_bypass=0 checks=%0d",checks);
`endif
    $finish;
  end
endmodule
`default_nettype wire
