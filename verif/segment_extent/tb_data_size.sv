/* ENUM */
module tb_data_size;
  state_e state;
  logic pipe_load_req, pipe_store_req, sfetch_boundary;
  logic [2:0] sfetch_demand_size;
  logic [3:0] base_size, cur_size, cur_data_size, original_size;
  logic seg_ext_ovr_v, expand_down, qualifier, fault_other;
  logic [7:0] seg_ext_ovr, old_count, new_count;
  logic [31:0] off, bound, upper;
  logic old_fault, new_fault;
  int unsigned checks, data_checks, fetch_differences, object_checks;
  /* CLASSIFICATION */
  /* FUNCTION */
  always_comb begin
    // All unchanged non-fetch case arms are abstracted by an arbitrary size.
    // Recipe tests check those arms contain only writes to cur_size and remain
    // byte-identical. This leaf is not a sequential full-core proof.
    cur_size = base_size;
    /* TAP */
  end
  always_comb begin
    original_size = base_size;
    if (state == S_FETCH) begin
      /* ORIGINAL_FETCH_SIZE */
    end
  end
  assign old_count = seg_ext_ovr_v ? seg_ext_ovr : {4'd0, original_size};
  assign new_count = seg_ext_ovr_v ? seg_ext_ovr : {4'd0, cur_data_size};
  assign old_fault = cur_is_d && qualifier && (fault_other ||
      (expand_down ? ((off <= bound) || seg_extent_above(off, upper, old_count))
                   : seg_extent_above(off, bound, old_count)));
  assign new_fault = cur_is_d && qualifier && (fault_other ||
      (expand_down ? ((off <= bound) || seg_extent_above(off, upper, new_count))
                   : seg_extent_above(off, bound, new_count)));
  task automatic check;
    #1;
    if (cur_size !== original_size || old_fault !== new_fault ||
        (cur_is_d && old_count !== new_count)) begin
      $display("DATA-SIZE-MISMATCH state=%0d base=%0d fetch=%0d old=%0d new=%0d",
               state, base_size, sfetch_demand_size, old_count, new_count);
      $fatal(1, "data-size cofactor");
    end
    checks++;
    if (cur_is_d) data_checks++;
    if (!cur_is_d && old_count != new_count) fetch_differences++;
    if (cur_is_d && seg_ext_ovr_v && seg_ext_ovr > 15) object_checks++;
  endtask
  initial begin
    checks=0; data_checks=0; fetch_differences=0; object_checks=0;
    for (int s=0; s<128; s++)
      for (int n=0; n<256; n++)
        for (int w=0; w<8; w++) begin
          state=state_e'(s); base_size=4'(n); sfetch_demand_size=3'(w);
          sfetch_boundary=1'(n>>4); seg_ext_ovr_v=1'(n>>5);
          seg_ext_ovr=8'(n); pipe_load_req=1'(n>>6); pipe_store_req=1'(n>>7);
          expand_down=1'(w); qualifier=1'b1; fault_other=1'b0;
          off=32'hffffff00 + 32'(n); bound=off + 32'(w);
          upper=(n & 1) ? 32'hffffffff : 32'hffff;
          check();
        end
    for (int n=0; n<100000; n++) begin
      state=state_e'($urandom_range(0,127)); base_size=4'($urandom);
      sfetch_demand_size=3'($urandom); sfetch_boundary=1'($urandom);
      seg_ext_ovr_v=1'($urandom); seg_ext_ovr=8'($urandom);
      pipe_load_req=1'($urandom); pipe_store_req=1'($urandom);
      expand_down=1'($urandom); qualifier=1'($urandom); fault_other=1'($urandom);
      off=$urandom; bound=off+($urandom % 512)-256;
      upper=(n & 1) ? 32'hffffffff : 32'hffff;
      check();
    end
    if (data_checks<100000 || fetch_differences<100 || object_checks<10000)
      $fatal(1,"missing data-size coverage");
    $display("DATA-SIZE-OK checks=%0d data=%0d fetch-differences=%0d objects=%0d",
             checks,data_checks,fetch_differences,object_checks);
    $finish;
  end
endmodule
