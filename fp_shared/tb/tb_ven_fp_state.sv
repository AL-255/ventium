`timescale 1ns/1ps
`default_nettype none

module tb_ven_fp_state;
  localparam logic [79:0] QNAN_INDEF = 80'hffffc000000000000000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [2:0] rd0_idx, rd1_idx;
  logic [79:0] rd0_data, rd1_data;
  logic rd0_empty, rd1_empty;
  logic [2:0] top_new, top_old;
  logic [15:0] status_new, status_old, control_new, control_old;
  logic [7:0] tag_new, tag_old;
  logic [639:0] phys_new, phys_old, st_new, st_old;
  logic [31:0] fip_new, fip_old, fdp_new, fdp_old;
  logic [15:0] fcs_new, fcs_old, fds_new, fds_old;

  logic c_init, c_push, c_write, c_write_valid, c_swap, c_free;
  logic c_swap_materialize_empty;
  logic c_inc, c_dec, c_status, c_control;
  logic c_eptr, c_dptr, c_env, c_envregs;
  logic [79:0] push_data, write_data;
  logic [2:0] write_idx, swap_idx, free_idx;
  logic [1:0] c_pop;
  logic [15:0] status_data, control_data;
  logic [31:0] eptr_fip, dptr_fdp;
  logic [15:0] eptr_fcs, dptr_fds;
  logic [15:0] env_control, env_status;
  logic [2:0] env_top;
  logic [7:0] env_tag;
  logic [639:0] env_regs;

  logic [79:0] os0, os1, os2, os3, os4, os5, os6, os7;
  logic [79:0] old_top;

  function automatic logic [79:0] old_st(input logic [2:0] idx);
    unique case (idx)
      3'd0: return os0;
      3'd1: return os1;
      3'd2: return os2;
      3'd3: return os3;
      3'd4: return os4;
      3'd5: return os5;
      3'd6: return os6;
      default: return os7;
    endcase
  endfunction

  ven_fp_state dut (
      .clk(clk), .rst_n(rst_n),
      .rd0_idx(rd0_idx), .rd1_idx(rd1_idx),
      .rd0_data(rd0_data), .rd1_data(rd1_data),
      .rd0_empty(rd0_empty), .rd1_empty(rd1_empty),
      .top_o(top_new), .status_o(status_new), .control_o(control_new),
      .tag_o(tag_new), .phys_flat_o(phys_new), .st_flat_o(st_new),
      .fip_o(fip_new), .fcs_o(fcs_new), .fdp_o(fdp_new), .fds_o(fds_new),
      .commit_init(c_init), .commit_push(c_push), .push_data(push_data),
      .commit_write(c_write), .write_idx(write_idx), .write_data(write_data),
      .write_mark_valid(c_write_valid), .commit_swap(c_swap),
      .swap_idx(swap_idx),
      .commit_swap_materialize_empty(c_swap_materialize_empty),
      .commit_pop(c_pop), .commit_free(c_free),
      .free_idx(free_idx), .commit_inc_top(c_inc), .commit_dec_top(c_dec),
      .commit_status(c_status), .status_data(status_data),
      .commit_control(c_control), .control_data(control_data),
      .commit_eptr(c_eptr), .eptr_fip(eptr_fip), .eptr_fcs(eptr_fcs),
      .commit_dptr(c_dptr), .dptr_fdp(dptr_fdp), .dptr_fds(dptr_fds),
      .commit_env(c_env), .env_control(env_control), .env_top(env_top),
      .env_status(env_status), .env_tag(env_tag),
      .commit_env_regs(c_envregs), .env_regs_phys(env_regs)
  );

  fpu_top oracle (
      .clk(clk), .rst_n(rst_n),
      .st0(os0), .st1(os1), .st2(os2), .st3(os3),
      .st4(os4), .st5(os5), .st6(os6), .st7(os7),
      .ftop_o(top_old), .fstat_o(status_old), .fctrl_o(control_old),
      .fptag_o(tag_old), .rd_phys_top(old_top),
      .we_push(c_push), .push_data(push_data),
      .we_top(1'b0), .top_data(80'd0),
      .we_fstat(c_status), .fstat_wval(status_data),
      .we_sti(c_write), .wsti_idx(write_idx), .wsti_data(write_data),
      .wsti_clr_tag(c_write_valid),
      .we_fxch(c_swap), .fxch_idx(swap_idx), .fxch_a(old_st(swap_idx)),
      .fxch_b(os0),
      .fxch_materialize_empty(c_swap_materialize_empty),
      .we_pop(c_pop==2'd1), .we_pop2(c_pop==2'd2),
      .we_ffree(c_free), .ffree_idx(free_idx),
      .we_incstp(c_inc), .we_decstp(c_dec),
      .we_fctrl(c_control), .fctrl_wval(control_data), .we_fninit(c_init),
      .we_eptr(c_eptr), .eptr_fip(eptr_fip), .eptr_fcs(eptr_fcs),
      .we_dptr(c_dptr), .dptr_fdp(dptr_fdp), .dptr_fds(dptr_fds),
      .fip_o(fip_old), .fcs_o(fcs_old), .fdp_o(fdp_old), .fds_o(fds_old),
      .fpr_flat_o(phys_old),
      .we_envld(c_env), .env_fctrl(env_control), .env_ftop(env_top),
      .env_fstat(env_status), .env_fptag(env_tag),
      .we_envregs(c_envregs), .env_fpr_flat(env_regs),
      .we_wabs(1'b0), .wabs_idx(3'd0), .wabs_data(80'd0),
      .we_wabs_fstat(1'b0), .wabs_fstat(16'd0)
  );

  assign st_old = {os7, os6, os5, os4, os3, os2, os1, os0};

  task automatic clear_commit();
    begin
      c_init=0; c_push=0; c_write=0; c_write_valid=0; c_swap=0;
      c_swap_materialize_empty=0;
      c_free=0; c_inc=0; c_dec=0; c_status=0; c_control=0;
      c_eptr=0; c_dptr=0; c_env=0; c_envregs=0;
      c_pop=0; push_data='0; write_data='0; write_idx='0;
      swap_idx='0; free_idx='0; status_data='0; control_data='0;
      eptr_fip='0; eptr_fcs='0; dptr_fdp='0; dptr_fds='0;
      env_control='0; env_top='0; env_status='0; env_tag='0; env_regs='0;
    end
  endtask

  task automatic compare(input int step);
    begin
      #1;
      if ({top_new,status_new,control_new,tag_new,
           fip_new,fcs_new,fdp_new,fds_new,phys_new,st_new} !==
          {top_old,status_old,control_old,tag_old,
           fip_old,fcs_old,fdp_old,fds_old,phys_old,st_old}) begin
        $display("STATE MISMATCH step=%0d", step);
        $display(" top new=%0d old=%0d status=%h/%h control=%h/%h tag=%h/%h",
                 top_new, top_old, status_new, status_old,
                 control_new, control_old, tag_new, tag_old);
        $fatal(1);
      end
      rd0_idx = $urandom_range(0,7);
      rd1_idx = $urandom_range(0,7);
      #1;
      if (rd0_data !== st_old[rd0_idx*80 +: 80] ||
          rd1_data !== st_old[rd1_idx*80 +: 80] ||
          rd0_empty !== tag_old[top_old+rd0_idx] ||
          rd1_empty !== tag_old[top_old+rd1_idx])
        $fatal(1, "read-port mismatch step=%0d", step);
    end
  endtask

  initial begin
    clear_commit(); rd0_idx=0; rd1_idx=0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    compare(-1);

    // The compact candidate normally implements FXCH by swapping two map
    // pointers.  The masked-#IS exception is deliberately different: EMPTY
    // operands must first become real-indefinite and valid, then those banks
    // are exchanged.  Exercise that sideband here rather than relying only on
    // the command-shell regression, so a disconnected qualifier cannot hide
    // behind ordinary pointer-swap A/B traffic.
    @(negedge clk);
    clear_commit();
    c_push = 1'b1;
    push_data = 80'h4001_8000_0000_0000_0000;  // 4.0, becomes ST(0)
    @(posedge clk);
    compare(-2);

    @(negedge clk);
    clear_commit();
    c_swap = 1'b1;
    c_swap_materialize_empty = 1'b1;
    swap_idx = 3'd1;                         // ST(1) is EMPTY
    @(posedge clk);
    compare(-3);
    if (st_new[79:0] !== QNAN_INDEF ||
        st_new[159:80] !== 80'h4001_8000_0000_0000_0000 ||
        tag_new[3'd7] !== 1'b0 || tag_new[3'd0] !== 1'b0)
      $fatal(1, "masked-FXCH materialization did not produce two valid exchanged operands");

    // Exercise the inverse physical direction too: ST(0) begins EMPTY while
    // ST(1) is live.  This reaches both the compact-map state file and the
    // direct legacy oracle with the complementary pre-edge tags, catching a
    // repair that materializes the correct bank but attaches validity to the
    // old logical slot after the exchange.
    @(negedge clk);
    clear_commit();
    c_init = 1'b1;
    @(posedge clk);
    compare(-4);

    @(negedge clk);
    clear_commit();
    c_push = 1'b1;
    push_data = 80'h3fff_8000_0000_0000_0000;  // 1.0, ST(0)
    @(posedge clk);
    compare(-5);

    @(negedge clk);
    clear_commit();
    c_push = 1'b1;
    push_data = 80'h4001_8000_0000_0000_0000;  // 4.0, ST(0); 1.0 -> ST(1)
    @(posedge clk);
    compare(-6);

    @(negedge clk);
    clear_commit();
    c_free = 1'b1;
    free_idx = 3'd0;                            // ST(0) EMPTY, ST(1) live
    @(posedge clk);
    compare(-7);

    @(negedge clk);
    clear_commit();
    c_swap = 1'b1;
    c_swap_materialize_empty = 1'b1;
    swap_idx = 3'd1;
    @(posedge clk);
    compare(-8);
    if (st_new[79:0] !== 80'h3fff_8000_0000_0000_0000 ||
        st_new[159:80] !== QNAN_INDEF ||
        tag_new[top_new] !== 1'b0 || tag_new[top_new + 3'd1] !== 1'b0)
      $fatal(1, "reverse masked-FXCH materialization lost data or validity");

    for (int step=0; step<5000; step++) begin
      int sel;
      @(negedge clk);
      clear_commit();
      sel = $urandom_range(0,16);
      unique case (sel)
        0: begin c_push=1; push_data={$urandom(),$urandom(),$urandom()}; end
        1: begin c_write=1; write_idx=$urandom_range(0,7);
                 write_data={$urandom(),$urandom(),$urandom()};
                 c_write_valid=$urandom_range(0,1); end
        2: begin c_swap=1; swap_idx=$urandom_range(0,7); end
        3: c_pop=2'd1;
        4: c_pop=2'd2;
        5: begin c_free=1; free_idx=$urandom_range(0,7); end
        6: c_inc=1;
        7: c_dec=1;
        8: begin c_status=1; status_data=$urandom(); end
        9: begin c_control=1; control_data=$urandom(); end
        10: c_init=1;
        11: begin c_eptr=1; eptr_fip=$urandom(); eptr_fcs=$urandom(); end
        12: begin c_dptr=1; dptr_fdp=$urandom(); dptr_fds=$urandom(); end
        13: begin
          c_env=1; env_control=$urandom(); env_top=$urandom_range(0,7);
          env_status=$urandom(); env_tag=$urandom();
        end
        14: begin
          c_envregs=1;
          for (int i=0; i<20; i++) env_regs[i*32 +: 32]=$urandom();
        end
        15: begin
          c_env=1; c_envregs=1; env_control=$urandom();
          env_top=$urandom_range(0,7); env_status=$urandom(); env_tag=$urandom();
          for (int i=0; i<20; i++) env_regs[i*32 +: 32]=$urandom();
        end
        default: begin
          // Exercise the proven priority: environment metadata wins ordinary
          // scalar writes that happen on the same edge.
          c_status=1; status_data=$urandom();
          c_control=1; control_data=$urandom();
          c_env=1; env_control=$urandom(); env_top=$urandom_range(0,7);
          env_status=$urandom(); env_tag=$urandom();
        end
      endcase
      @(posedge clk);
      compare(step);
    end
    $display("VEN-FP-STATE-A-B-OK steps=5000");
    $finish;
  end
endmodule

`default_nettype wire
