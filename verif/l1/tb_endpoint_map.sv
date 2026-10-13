// Exact-source cache-map/endpoint equivalence, including generic address masks.
module tb_endpoint_map;
  logic [31:0] core_addr;
  logic core_we, smm_active;
  logic [3:0] core_wstrb;
  logic [55:0] NB_PAM;
  logic [7:0] NB_DRAMC, NB_CC, NB_TOM_MB4, NB_SMRAM;
  wire core_clk = 1'b0;
  wire seam_core_rst_n = 1'b0;
  wire [51:0] control [16], candidate [16];
  localparam logic [31:0] MASKS [8] = '{
      32'hffffffff, 32'h0fffffff, 32'h03ffffff, 32'h7fffffff,
      32'hfffffffe, 32'hffffffef, 32'h00ffffe1, 32'h00000000};
  for (genvar s=0; s<2; s++) begin : snapshots
    for (genvar m=0; m<8; m++) begin : masks
      endpoint_control #(.ADDR_MASK(MASKS[m]), .CMAP_SNAPSHOT_USER_HIGHMEM(1'(s)))
          before_map (.result(control[s*8+m]), .*);
      endpoint_candidate #(.ADDR_MASK(MASKS[m]), .CMAP_SNAPSHOT_USER_HIGHMEM(1'(s)))
          after_map (.result(candidate[s*8+m]), .*);
    end
  end
  longint unsigned checks=0, vectors=0, wraps=0, crossing=0, zero_reads=0;
  logic [31:0] random_state=32'h63c4521f;
  function automatic logic [31:0] next_random(input logic [31:0] value);
    logic [31:0] x;
    x=value ^ (value << 13); x=x ^ (x >> 17); return x ^ (x << 5);
  endfunction
  task automatic randomize_config;
    random_state=next_random(random_state); NB_PAM[31:0]=random_state;
    random_state=next_random(random_state); NB_PAM[55:32]=random_state[23:0];
    random_state=next_random(random_state);
    NB_DRAMC=random_state[7:0]; NB_CC=random_state[15:8];
    NB_TOM_MB4=random_state[23:16]; NB_SMRAM=random_state[31:24];
    smm_active=random_state[0];
  endtask
  task automatic check;
    logic [31:0] expected_last;
    int unsigned delta;
    // Independently spell the public highest-enabled-byte rule.
    if (!core_we && core_wstrb==0) delta=3;
    else if (core_wstrb[3]) delta=3;
    else if (core_wstrb[2]) delta=2;
    else if (core_wstrb[1]) delta=1;
    else delta=0;
    expected_last=core_addr+delta;
    #1;
    for (int p=0; p<16; p++) begin
      if (control[p] !== candidate[p] || candidate[p][51:20] !== expected_last)
        $fatal(1,"ENDPOINT-MAP-MISMATCH vector=%0d profile=%0d addr=%08h we=%b strb=%h control=%013h candidate=%013h",
               vectors,p,core_addr,core_we,core_wstrb,control[p],candidate[p]);
      checks++;
    end
    vectors++;
    if (expected_last < core_addr) wraps++;
    if (expected_last[31:5] != core_addr[31:5]) crossing++;
    if (!core_we && core_wstrb==0) zero_reads++;
  endtask
  logic [31:0] boundaries [40];
  initial begin
    // Every fixed decoder boundary, every PAM segment, TOM, PCI/ROM aperture,
    // 32-bit wrap and representative low-bit/noncontiguous-mask transitions.
    boundaries = '{32'h0,32'h80000,32'ha0000,32'hc0000,
      32'hc4000,32'hc8000,32'hcc000,32'hd0000,32'hd4000,32'hd8000,
      32'hdc000,32'he0000,32'he4000,32'he8000,32'hec000,32'hf0000,
      32'h100000,32'hf00000,32'h1000000,32'h4000000,32'h10000000,
      32'h3fc00000,32'h40000000,32'h80000000,32'hc0000000,32'hfffe0000,
      32'hffffffe0,32'hffffffff,32'h1000020,32'h4000020,32'h10000020,
      32'h001ffff0,32'h00ffffe0,32'h01000010,32'h20000010,32'h20000001,
      32'h20000002,32'h2000001f,32'h20000020,32'h0};
    for (int cfg=0; cfg<64; cfg++) begin
      randomize_config();
      NB_DRAMC[7:6]=2'(cfg); NB_SMRAM[6]=cfg[2]; NB_SMRAM[3]=cfg[3];
      smm_active=cfg[4]; NB_CC[0]=cfg[5];
      boundaries[39]={2'b0,NB_TOM_MB4,22'b0};
      for (int b=0; b<40; b++)
        for (int offset=-4; offset<4; offset++)
          for (int write_kind=0; write_kind<2; write_kind++)
            for (int strobe=0; strobe<16; strobe++) begin
              core_addr=boundaries[b]+32'(offset);
              core_we=1'(write_kind); core_wstrb=4'(strobe); check();
            end
    end
    for (int r=0; r<65536; r++) begin
      randomize_config(); random_state=next_random(random_state);
      core_addr=random_state; core_we=random_state[7]; core_wstrb=random_state[15:12];
      check();
    end
    assert(vectors==720896 && checks==11534336 && wraps>0 && crossing>0 && zero_reads>0)
      else $fatal(1,"ENDPOINT-MAP-COVERAGE");
    $display("ENDPOINT-MAP-OK vectors=%0d checks=%0d wraps=%0d crossing=%0d zero_reads=%0d",
             vectors,checks,wraps,crossing,zero_reads);
    $finish;
  end
endmodule
