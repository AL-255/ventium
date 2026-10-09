// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
module tb_ifetch_auth_multi;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic paging_on, fe_translatable, cur_is_d, fsm_case_enabled, itlb_lk_hit;
  logic xlate_miss, perm_fault, fe_xlate_pend, tlb_flush, tlb_fill_en, tlb_fill_is_d;
  logic [31:0] flin, cur_lin;
  logic [1:0] eff_cpl;
  logic [2:0] itlb_lk_perm;
  logic if_auth_ok;
  int checks=0;
  `include "core_ifetch_auth_multi.svh"
  task automatic tick;
    @(posedge clk); #1; @(negedge clk);
  endtask
  task automatic check(input bit expect_ok);
    #1;
    if (if_auth_ok !== expect_ok)
      $fatal(1,"permission mismatch page=%08x cpl=%0d got=%b expected=%b",
             flin,eff_cpl,if_auth_ok,expect_ok);
    checks++;
  endtask
  task automatic capture(input logic [31:0] address, input bit user_page);
    cur_lin=address; itlb_lk_perm={user_page,2'b11};
    fsm_case_enabled=1; tick(); fsm_case_enabled=0;
  endtask
  initial begin
    paging_on=1; fe_translatable=1; cur_is_d=0; fsm_case_enabled=0; itlb_lk_hit=1;
    xlate_miss=0; perm_fault=0; fe_xlate_pend=0; tlb_flush=0; tlb_fill_en=0; tlb_fill_is_d=0;
    flin=0; cur_lin=0; eff_cpl=0; itlb_lk_perm=3'b111;
    tick(); rst_n=1;
    // Every offset/CPL of sixteen resident pages; raw supervisor bits must not
    // become a permanent allow result when the client later enters CPL3.
    for (int p=0;p<16;p++) capture(32'h10000000+32'(p*4096),1'(p&1));
    for (int p=0;p<16;p++)
      for (int c=0;c<4;c++)
        for (int off=0;off<4096;off+=31) begin
          flin=32'h10000000+32'(p*4096+off); eff_cpl=2'(c);
          check((c!=3) || ((p&1)!=0));
        end
    // Index collision must reject the old full tag, not merge permissions.
    capture(32'h20005000,0); eff_cpl=0; flin=32'h10005000; check(0);
    flin=32'h20005000; check(1); eff_cpl=3; check(0);
    // Live refresh changes US in either direction without duplicate entries.
    capture(32'h20005000,1); check(1); capture(32'h20005000,0); check(0);
    // Each capture guard independently prevents a bogus authorization.
    for (int guard=0;guard<8;guard++) begin
      tlb_flush=1; tick(); tlb_flush=0;
      paging_on=(guard!=0); fe_translatable=(guard!=1); cur_is_d=(guard==2);
      fsm_case_enabled=(guard!=3); itlb_lk_hit=(guard!=4);
      xlate_miss=(guard==5); perm_fault=(guard==6); fe_xlate_pend=(guard==7);
      cur_lin=32'h30009000; itlb_lk_perm=3'b111; tick();
      paging_on=1; fe_translatable=1; cur_is_d=0; fsm_case_enabled=0; itlb_lk_hit=1;
      xlate_miss=0; perm_fault=0; fe_xlate_pend=0; flin=cur_lin; check(0);
    end
    // Flush, reset and I-parent fill beat a simultaneous legal capture.
    for (int event_id=0;event_id<3;event_id++) begin
      capture(32'h40003000,1); flin=cur_lin; check(1);
      fsm_case_enabled=1; rst_n=(event_id!=0); tlb_flush=(event_id==1);
      tlb_fill_en=(event_id==2); tlb_fill_is_d=0; tick();
      fsm_case_enabled=0; rst_n=1; tlb_flush=0; tlb_fill_en=0; check(0);
    end
    // D-parent fills do not replace I-parent state. Data requests never insert.
    capture(32'h50007000,1); flin=cur_lin; check(1);
    tlb_fill_en=1; tlb_fill_is_d=1; cur_is_d=1; cur_lin=32'h60007000;
    fsm_case_enabled=1; tick(); fsm_case_enabled=0; check(1);
    flin=cur_lin; check(0); paging_on=0; check(1);
    $display("IFETCH-AUTH-MULTI-OK checks=%0d",checks); $finish;
  end
endmodule
