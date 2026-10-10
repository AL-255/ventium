`timescale 1ns/1ps
`default_nettype none
// Admission equation only; full-core RET/SS/page/event semantics need separate
// differential tests. The runner extracts the actual proposed RTL expression.
module tb_ret_short_window;
  import ventium_decode_pkg::*;
  typedef enum logic { S_PIPE, S_OTHER } state_t;
  state_t state;
  kind_e d_kind;
  ctk_e d_ct;
  localparam int SG_CS = 0;
  logic cycle_mode, def16, pipe_fetch_checked_handoff, d_unknown;
  logic exec_issue_ok, icsnp_v1, icsnp_v2, ic_snoop_valid;
  logic sys_mode, real_mode, v86, first_owner, last_owner;
  logic [7:0] refdecode_ibuf[16];
  logic [3:0] d_len;
  logic [31:0] flin, eip, seg_limit[1];
  logic pipe_ret_short_window_ok;
  int checks = 0;
  function automatic logic ic_buffered(input logic [31:0] addr);
    return addr[31:5] == flin[31:5] ? first_owner : last_owner;
  endfunction
  `include "ret_short_equation.svh"

  task automatic defaults(input bit immediate_ret = 1);
    state = S_PIPE; cycle_mode = 1; def16 = 0;
    pipe_fetch_checked_handoff = 0; d_unknown = 0;
    d_kind = K_CTRL; d_ct = immediate_ret ? CT_RETN_IMM : CT_RETN;
    d_len = immediate_ret ? 3 : 1;
    exec_issue_ok = 1; icsnp_v1 = 0; icsnp_v2 = 0; ic_snoop_valid = 0;
    sys_mode = 1; real_mode = 0; v86 = 0;
    flin = 32'h100f001f; eip = 32'hf001f; seg_limit[0] = 32'hffffffff;
    first_owner = 1; last_owner = 1;
    foreach (refdecode_ibuf[i]) refdecode_ibuf[i] = 8'hff;
    refdecode_ibuf[0] = immediate_ret ? 8'hc2 : 8'hc3;
  endtask

  task automatic check(input logic expected);
    #1;
    if (pipe_ret_short_window_ok !== expected)
      $fatal(1, "RET-SHORT check=%0d got=%b expected=%b opcode=%h kind=%0d ct=%0d len=%0d flin=%h eip=%h limit=%h",
             checks, pipe_ret_short_window_ok, expected, refdecode_ibuf[0],
             d_kind, d_ct, d_len, flin, eip, seg_limit[0]);
    checks++;
  endtask

  initial begin
    for (int mode=0; mode<2; mode++) begin
      for (int op=0; op<256; op++) begin
        defaults(1'(mode)); refdecode_ibuf[0] = 8'(op);
        check(op == (mode ? 194 : 195));
      end
      for (int len=0; len<16; len++) begin
        defaults(1'(mode)); d_len = 4'(len);
        check(len == (mode ? 3 : 1));
      end
      for (int ctrl=0; ctrl<16; ctrl++) begin
        defaults(1'(mode)); d_ct = ctk_e'(ctrl);
        check(ctrl == int'(mode ? CT_RETN_IMM : CT_RETN));
      end
      for (int offset=0; offset<32; offset++) begin
        defaults(1'(mode)); flin = 32'h100f0000 + 32'(offset);
        eip = 32'hf0000 + 32'(offset); check(1);
        last_owner = 0;
        check(offset + (mode ? 3 : 1) <= 32);
      end
      for (int tail=0; tail<17; tail++) begin
        defaults(1'(mode)); flin = 32'h100f0fff - 32'(tail);
        check((mode ? 3 : 1) <= tail+1);
        defaults(1'(mode)); seg_limit[0] = eip + 32'(tail);
        check((mode ? 3 : 1) <= tail+1);
      end
    end
    for (int blocker=0; blocker<15; blocker++) begin
      defaults();
      case (blocker)
        0: state = S_OTHER;
        1: cycle_mode = 0;
        2: def16 = 1;
        3: pipe_fetch_checked_handoff = 1;
        4: d_unknown = 1;
        5: d_kind = K_ALU;
        6: exec_issue_ok = 0;
        7: icsnp_v1 = 1;
        8: icsnp_v2 = 1;
        9: ic_snoop_valid = 1;
        10: real_mode = 1;
        11: v86 = 1;
        12: first_owner = 0;
        13: last_owner = 0;
        14: seg_limit[0] = eip - 1;
        default: ;
      endcase
      check(0);
    end
    defaults(); eip = 32'hffffffff; flin = 32'h0fff; check(0);
    defaults(0); eip = 32'hffffffff; flin = 32'h0fff; check(1);
    defaults(); sys_mode = 0; real_mode = 1; v86 = 1; seg_limit[0] = 0; check(1);
    if (checks != 790) $fatal(1, "incomplete predicate corpus %0d", checks);
    $display("RET-SHORT-PREDICATE-OK checks=%0d", checks);
    $finish;
  end
endmodule
`default_nettype wire
