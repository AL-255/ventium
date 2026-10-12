// Source-extracted readiness contract only; not a cache/state-machine proof.
module tb_pair_intent_ready;
  localparam [2:0] L1_IDLE = 3'd0;
  reg rst_n, c_req, c_we, cacheable, golden, flush_all, snoop_inv_valid;
  reg early_armed, stream_path, m_pair_ready, pair_read_owned, pair_current_hit;
  reg code_access, c_pair_intent, c_next_req, rd_match;
  reg [2:0] st;
  reg [31:0] c_addr, c_pair_addr;
  reg [3:0] c_wstrb, c_pair_wstrb;
  wire c_pair_ready, pair_intent_ready;
  integer i;
  integer checks = 0, qualified = 0, ready = 0, outside_difference = 0;

  // @@ORIGINAL@@
  // @@COFACTOR@@

  task check;
    begin
      #1;
      checks = checks + 1;
      if (c_pair_intent) begin
        qualified = qualified + 1;
        if (c_pair_ready !== pair_intent_ready)
          $fatal(1,"INTENT-READY: qualified readiness changed at vector %0d",checks);
        if (c_pair_ready) ready = ready + 1;
      end else if (c_pair_ready !== pair_intent_ready)
        outside_difference = outside_difference + 1;
    end
  endtask

  initial begin
    // Exhaust every binary control combination, with legal dword geometry.
    c_addr=32'h1000; c_pair_addr=32'h1004;
    c_wstrb=4'hf; c_pair_wstrb=4'hf;
    for (i=0; i<131072; i=i+1) begin
      {rst_n,c_req,c_we,cacheable,golden,flush_all,snoop_inv_valid,
       early_armed,stream_path,m_pair_ready,pair_read_owned,pair_current_hit,
       code_access,c_pair_intent,c_next_req,rd_match}=i[15:0];
      st=i[16] ? 3'd1 : L1_IDLE;
      check();
    end
    // Exhaust both offsets and both strobe masks under a real intent.
    rst_n=1; c_req=1; c_we=0; cacheable=1; golden=0; flush_all=0;
    snoop_inv_valid=0; early_armed=0; stream_path=0; m_pair_ready=1;
    pair_read_owned=1; pair_current_hit=1; code_access=0;
    c_pair_intent=1; c_next_req=1; rd_match=1; st=L1_IDLE;
    for (i=0; i<262144; i=i+1) begin
      c_addr={27'h80,i[4:0]}; c_pair_addr={27'h81,i[9:5]};
      c_wstrb=i[13:10]; c_pair_wstrb=i[17:14];
      check();
    end
    if (checks != 393216 || qualified != 327680 || ready == 0)
      $fatal(1,"INTENT-READY: incomplete vector coverage");
`ifdef VEN_P54_LOAD_STORE_PAIR
`ifdef VEN_PIPE_MEM_CHAIN
    // Without intent the original conflict exclusion is meaningful. A global
    // replacement would be wrong; retain that negative witness explicitly.
    if (outside_difference == 0)
      $fatal(1,"INTENT-READY: missed unqualified-port counterexample");
`endif
`endif
    $display("INTENT-READY-OK checks=%0d qualified=%0d ready=%0d outside_difference=%0d",
             checks,qualified,ready,outside_difference);
    $finish;
  end
endmodule
