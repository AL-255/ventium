/* MODULES */
module tb_fast_segment;
  logic sys_fp_ok, real_mode, cs_d, sys_mode, fp_dbg_active, stk_is16;
  logic [3:0] decoded, memory_form;
  logic [2:0] pipe_mem_seg;
  logic [31:0] pipe_load_addr;
  logic [7:0] seg_attr [6];
  logic [31:0] seg_limit [6], seg_base [6];
  logic seg_pm_loaded [6];
  logic [15:0] seg_sel [6];
  logic old_load, old_store, old_bail, new_load, new_store, new_bail;
  logic [31:0] old_lin, new_lin;
  int checks, admitted, stores, denied;
  admission_old old_dut(.*, .out_load(old_load), .out_store(old_store),
                         .out_bail(old_bail), .out_lin(old_lin));
  admission_new new_dut(.*, .out_load(new_load), .out_store(new_store),
                         .out_bail(new_bail), .out_lin(new_lin));
  task automatic check;
    #1;
    if ({old_load,old_store,old_bail,old_lin} !== {new_load,new_store,new_bail,new_lin}) begin
      $display("FAST-SEGMENT-MISMATCH seg=%0d addr=%x width=%0d attr=%x limit=%x old=%b%b%b new=%b%b%b",
        pipe_mem_seg, pipe_load_addr, memory_form[3:1], seg_attr[pipe_mem_seg],
        seg_limit[pipe_mem_seg], old_load,old_store,old_bail,new_load,new_store,new_bail);
      $fatal(1,"fast segment admission changed");
    end
    checks++;
    if (new_load) admitted++;
    if (new_store) stores++;
    if (!new_load) denied++;
  endtask
  initial begin
    checks=0; admitted=0; stores=0; denied=0;
    sys_fp_ok=1; real_mode=0; cs_d=1; sys_mode=1; fp_dbg_active=0; stk_is16=0;
    decoded=4'b1011;
    // Exhaustive attributes, independent selected segments, all width codes,
    // both full/finite limits, page equality, and FFC..FFF byte boundaries.
    for (int s=0;s<6;s++)
      for (int a=0;a<256;a++)
        for (int w=0;w<8;w++)
          for (int k=0;k<16;k++) begin
            for (int j=0;j<6;j++) begin
              seg_attr[j]=8'h92; seg_limit[j]=32'h12400;
              seg_base[j]=32'(j)*32'hfff; seg_pm_loaded[j]=1;
              seg_sel[j]=16'(j*8+8);
            end
            pipe_mem_seg=3'(s); seg_attr[s]=8'(a);
            seg_limit[s]=(k & 8) ? 32'hffffffff : 32'h12400;
            memory_form={3'(w),1'(w)};
            pipe_load_addr=(k & 4) ? 32'h12ffc+32'(k & 3) : 32'h11ffc+32'(k & 3);
            check();
          end
    // Qualifier transitions, null selectors and unloaded hidden caches.
    for (int q=0;q<4096;q++) begin
      {sys_fp_ok,real_mode,cs_d,sys_mode,fp_dbg_active,stk_is16}=6'(q);
      decoded=4'(q>>6); memory_form={3'd2,1'b0}; pipe_mem_seg=2;
      pipe_load_addr=32'h11ffe; seg_attr[2]=8'h92; seg_limit[2]=32'h12400;
      seg_pm_loaded[2]=1'(q>>10); seg_sel[2]=(q & 2048) ? 16'h000b : 16'h0003;
      check();
    end
    for (int n=0;n<100000;n++) begin
      {sys_fp_ok,real_mode,cs_d,sys_mode,fp_dbg_active,stk_is16}=6'($urandom);
      decoded=4'($urandom); memory_form=4'($urandom);
      pipe_mem_seg=3'($urandom_range(0,5)); pipe_load_addr=$urandom;
      for (int j=0;j<6;j++) begin
        seg_attr[j]=8'($urandom); seg_limit[j]=(n & 1) ? 32'hffffffff : $urandom;
        seg_base[j]=$urandom; seg_pm_loaded[j]=1'($urandom); seg_sel[j]=16'($urandom);
      end
      check();
    end
`ifdef VEN_SYS_FASTLOAD_FLAT
    if (admitted<100 || denied<100) $fatal(1,"missing load coverage");
`ifdef VEN_SYS_FASTSTORE_FLAT
    if (stores<100) $fatal(1,"missing store coverage");
`endif
`else
    if (admitted!=0 || stores!=0) $fatal(1,"disabled path admitted");
`endif
    if (checks!=300704) $fatal(1,"missing vectors");
    $display("FAST-SEGMENT-OK checks=%0d loads=%0d stores=%0d denied=%0d",checks,admitted,stores,denied);
    $finish;
  end
endmodule
