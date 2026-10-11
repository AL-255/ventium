// This exercises the real cache map and source-extracted seam/lookup equations.
// It does not instantiate the cache arrays, backing bus or sequential owners.
module next_query_seam (
    input logic [31:0] core_next_addr, c_addr, smbase,
    input logic [31:0] ctl,
    input logic [55:0] pam,
    input logic [7:0] dramc, cc, tom_mb4, smram,
    output wire [31:0] lookup_addr,
    output wire core_next_ready, mc_capture_next,
    output wire mc_lookup_next,
    output wire [3:0] mc_next_region);
  localparam integer OFFW=5, IDXW=7, L1_IDLE=0, L1_FILL=1;
  wire core_next_req=ctl[0], core_next_commit=ctl[1];
  wire seam_core_rst_n=!ctl[2], EN_L2=ctl[3], shutdown=ctl[4];
  wire dma_drain_stall=ctl[5], core_lock_hold=ctl[6];
  wire core_smram_deny=ctl[7], core_route_deny=ctl[8], cr0_cd=ctl[9];
  wire smm_active=ctl[10], c_req=ctl[11], c_we=ctl[12];
  wire rd_match=ctl[13], rd_armed=ctl[14], early_armed=ctl[15];
  wire stream_path=ctl[16], bypass_q=ctl[17], fill_poison=ctl[18];
  wire code_fill_q=ctl[19], cacheable=!ctl[20], golden=ctl[21];
  wire flush_all=ctl[22], snoop_inv_valid=ctl[23], hit=!ctl[24];
  wire [1:0] st=ctl[26:25];
  wire [3:0] c_next_wstrb=ctl[27] ? 4'h1 : 4'hf;
  wire [IDXW-1:0] fset=c_addr[OFFW +: IDXW];
  wire mc_next_l1c, mc_next_dram, mc_next_l2c, mc_next_enable;
  wire mc_next_ready, c_next_req, c_next_commit, c_next_cacheable;
  wire c_next_ready, mc_lookup_old, mc_lookup_prime;
  wire [31:0] c_next_addr=core_next_addr;
  ven_cachemap map (.addr(core_next_addr), .is_write(1'b0), .is_code(1'b0),
      .smm_active, .pam, .dramc, .cc, .tom_mb4, .smram,
      .to_dram(mc_next_dram), .l1_cacheable(mc_next_l1c),
      .l2_cacheable(mc_next_l2c), .region(mc_next_region));
  assign mc_next_ready=c_next_ready;
  // SOURCE_EXTRACTED_SEAM
endmodule

module tb_next_query_seam;
  logic agi_prime_select, ref_prime_select, mc_prime_offer, mc_valid_q;
  logic agi_prime_offer, ref_prime_offer, mc_offer, mem_next_req;
  logic [31:0] mc_query_phys, mc_phys_q, reference_addr, candidate_addr;
  logic [31:0] ctl, c_addr, smbase, rng;
  logic [55:0] pam;
  logic [7:0] dramc, cc, tom_mb4, smram;
  wire [31:0] lookup_reference, lookup_candidate;
  wire ready_reference, ready_candidate, capture_reference, capture_candidate;
  wire selected_reference, selected_candidate;
  wire [3:0] region_reference, region_candidate;
  integer samples=0, offered=0, accepted=0, captured=0, unused_regions=0;
  bit mutant_unguarded;
  // SOURCE_EXTRACTED_PAYLOAD
  next_query_seam reference_seam (.core_next_addr(reference_addr), .c_addr,
      .smbase, .ctl, .pam, .dramc, .cc, .tom_mb4, .smram,
      .lookup_addr(lookup_reference), .core_next_ready(ready_reference),
      .mc_capture_next(capture_reference), .mc_lookup_next(selected_reference),
      .mc_next_region(region_reference));
  next_query_seam candidate_seam (.core_next_addr(candidate_addr), .c_addr,
      .smbase, .ctl, .pam, .dramc, .cc, .tom_mb4, .smram,
      .lookup_addr(lookup_candidate), .core_next_ready(ready_candidate),
      .mc_capture_next(capture_candidate), .mc_lookup_next(selected_candidate),
      .mc_next_region(region_candidate));

  function automatic [31:0] address(input integer n);
    case (n)
      0: return 32'h00000000;
      1: return 32'h0000001f;
      2: return 32'h0007ffff;
      3: return 32'h00080000;
      4: return 32'h0009ffff;
      5: return 32'h000a0000;
      6: return 32'h000bffff;
      7: return 32'h000c0000;
      8: return 32'h000effff;
      9: return 32'h000f0000;
      10: return 32'h000fffff;
      11: return 32'h00100000;
      12: return 32'h00efffff;
      13: return 32'h00f00000;
      14: return 32'h00ffffff;
      15: return 32'h01000000;
      16: return 32'h03ffffff;
      17: return 32'h04000000;
      18: return 32'h3fbfffff;
      19: return 32'h3fc00000;
      20: return 32'h40000000;
      21: return 32'hffffffff;
      22: return 32'h00030000;
      default: return 32'h00040000;
    endcase
  endfunction

  initial begin
    mutant_unguarded=$test$plusargs("mutant_unguarded");
    rng=32'h12345678;
    for (int a=0; a<24; a++) for (int p=0; p<16; p++)
      for (int b=0; b<128; b++) for (int state_case=0; state_case<4; state_case++) begin
        {mc_valid_q,agi_prime_select,ref_prime_select,mc_prime_offer}=b[3:0];
        agi_prime_offer=agi_prime_select && b[4];
        ref_prime_offer=ref_prime_select && b[5];
        mc_offer=mc_valid_q && b[6];
        mc_query_phys=address(a); mc_phys_q=address((a+7)%24);
        c_addr=32'h12340010; smbase=p[0] ? 32'h00030000 : 32'hfff00000;
        pam={14{p[3:0]}}; dramc={p[1:0],6'b0}; cc={6'b010000,p[1:0]};
        tom_mb4=p[3] ? 8'hff : 8'h10; smram={1'b0,p[2],2'b0,p[3],3'b0};
        rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
        ctl=0;
        // Most samples exercise a legal idle/return/fill lookup. The fourth
        // group independently blocks each seam/lookup permission bit.
        if (state_case==1) begin ctl[11]=1; ctl[13]=1; ctl[14]=1; end
        if (state_case==2) ctl[26:25]=L1_FILL_VALUE;
        if (state_case==3) ctl=32'b1 << (2+(rng%26));
        ctl[10]=p[1]; ctl[27]=p[0];
        #1;
        ctl[0]=mem_next_req; ctl[1]=mem_next_req && b[6];
        #1;
        if ({ready_reference,capture_reference,selected_reference,lookup_reference}
            !== {ready_candidate,capture_candidate,selected_candidate,lookup_candidate})
          $fatal(1,"NEXT_QUERY_SEAM_EQ sample=%0d req=%b ctl=%h",samples,mem_next_req,ctl);
        samples++; offered+=mem_next_req; accepted+=ready_candidate; captured+=capture_candidate;
        if (!mem_next_req && region_reference != region_candidate) unused_regions++;
      end
    if (samples!=196608 || offered==0 || accepted==0 || captured==0 || unused_regions==0)
      $fatal(1,"NEXT_QUERY_SEAM_COVERAGE samples=%0d offered=%0d accepted=%0d captured=%0d regions=%0d",
          samples,offered,accepted,captured,unused_regions);
    $display("NEXT-QUERY-SEAM-OK samples=%0d offered=%0d accepted=%0d captured=%0d unused-regions=%0d",
        samples,offered,accepted,captured,unused_regions);
    $finish;
  end
  localparam [1:0] L1_FILL_VALUE=1;
endmodule
