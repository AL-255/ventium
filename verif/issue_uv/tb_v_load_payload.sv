`timescale 1ns/1ps
// Source-extracted data selectors and immediate-accept equation are inserted
// below. This leaf checks binary payload equivalence under the named owner
// contract; it does not establish sequential reachability or complete GPR WB.
module tb;
  logic pipe_mem_active_q, pipe_mem_v_hit_q, pipe_mem_we_q;
  logic pipe_v_pair_request, mem_pair_now_valid, mem_read_ack;
  logic [31:0] mem_pair_now_data;
  logic [1:0][31:0] mem_pair_rsp_data;
  wire pipe_v_pair_now_accept;
  wire [31:0] old_data, new_data;
  logic contract, consumed;
  integer checks=0, held=0, immediate=0, both=0, excluded=0;
  logic [63:0] rng=64'hbc54a370ed8126f9;
  // SOURCE_EXTRACTED_EQUATIONS
  initial begin
    for (integer bits=0; bits<64; bits++) begin
      {mem_read_ack,mem_pair_now_valid,pipe_v_pair_request,pipe_mem_we_q,
       pipe_mem_v_hit_q,pipe_mem_active_q}=6'(bits);
      for (integer sample=0; sample<256; sample++) begin
        rng=rng^(rng<<13);rng=rng^(rng>>7);rng=rng^(rng<<17);
        mem_pair_now_data=rng[31:0]; mem_pair_rsp_data[1]=rng[63:32];
        mem_pair_rsp_data[0]=~rng[31:0];
        #1;
        contract=1'b1;
`ifdef VEN_RAW_V_READ_PRIME
`ifndef VEN_P54_DUAL_LOAD_PRIME
        contract=!pipe_mem_v_hit_q || (pipe_mem_active_q && !pipe_mem_we_q);
`endif
`endif
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
        consumed=pipe_mem_v_hit_q || pipe_v_pair_now_accept;
`else
        consumed=pipe_mem_v_hit_q;
`endif
        if (!contract) excluded++;
        else if (consumed) begin
          checks++;
          if (pipe_mem_v_hit_q) held++;
          if (pipe_v_pair_now_accept) immediate++;
          if (pipe_mem_v_hit_q && pipe_v_pair_now_accept) both++;
          if (old_data !== new_data)
            $fatal(1,"V-LOAD-PAYLOAD-MISMATCH bits=%0d sample=%0d old=%h new=%h",bits,sample,old_data,new_data);
        end
      end
    end
    if (!checks || !held) $fatal(1,"V-LOAD-PAYLOAD-COVERAGE held");
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
    if (!immediate) $fatal(1,"V-LOAD-PAYLOAD-COVERAGE immediate");
`endif
`ifdef VEN_RAW_V_READ_PRIME
`ifndef VEN_P54_DUAL_LOAD_PRIME
    if (!excluded || both) $fatal(1,"V-LOAD-PAYLOAD-COVERAGE owner");
`else
    if (excluded || !both) $fatal(1,"V-LOAD-PAYLOAD-COVERAGE original dual-prime");
`endif
`else
    if (excluded || !both) $fatal(1,"V-LOAD-PAYLOAD-COVERAGE original non-raw");
`endif
    $display("V-LOAD-PAYLOAD-OK checks=%0d held=%0d immediate=%0d both=%0d excluded=%0d",checks,held,immediate,both,excluded);
    $finish;
  end
endmodule
