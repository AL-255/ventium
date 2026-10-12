// Extracted request/fill equations, not a whole-core translation proof.
module fill_permit(input logic [25:0] bits, input logic [1:0] state,
    input logic [2:0] pf_word, input logic [31:0] payload,
    input integer mutant, output logic [66:0] observation,
    output logic write_owner, output logic fill, output logic done);
  localparam S_PIPE=1, S_PF=2, IC_IDXW=7, IC_TAGW=20;
  wire exec_issue_ok=bits[0], pipe_bytes_ok=bits[1], pipe_fetch_checked_handoff=bits[2];
  wire ic_fetch_ready=bits[3], uop_hit=bits[4], cycle_mode=bits[5];
  wire pipe_mem_active_q=bits[6],pipe_mem_we_q=bits[7],fp_issue_block=bits[8];
  wire [6:0] stall_cnt={6'd0,bits[9]},pending_mem_pen={6'd0,bits[10]};
  wire fp_sys_bail=bits[11],cs_extent_fault=bits[12],pipe_agi=bits[15];
  wire [2:0] mispred_bubbles={2'd0,bits[16]};
  wire fp_pipe_rd_haz=bits[17];
  wire fsm_case_enabled=bits[18],exec_flush_all=bits[19],real_bus=bits[20];
  wire bus_read_ack=bits[21],bus_write_ack=bits[22],fx_hold_e=bits[23];
  // Cancellation represents the existing translation/permission/async tail.
  // It never changes direction; the whole-core gate checks real fault delivery.
  wire cancelled=bits[24] || bits[25];
  typedef struct packed {logic is_mem;logic is_store;} decoded_t;
  wire decoded_t u_d={bits[13],bits[14]};
  typedef struct packed {logic w8;} effective_t;
  wire effective_t pipe_u_eff='0;
  wire [31:0] pipe_store_data=32'h12345678;
  function automatic [3:0] fp_mem_read_strobe(input effective_t value);
    fp_mem_read_strobe=value.w8 ? 4'h1 : 4'hf;
  endfunction
  logic pipe_frontend_ready,pf_miss,pipe_new_load_req,pipe_new_store_req,pipe_load_req,pipe_store_req;
  logic bd_req,bd_we;
  logic [3:0] bd_wstrb;
  logic [31:0] bd_wdata;
  always_comb begin
FRONTEND
REQUESTS
    bd_req=0;bd_we=0;bd_wstrb=0;bd_wdata=0;
    case (state)
      S_PF: begin bd_req=1; end
BRANCH
      default: ;
    endcase
    if (cancelled) bd_req=0;
  end
  wire mem_ack=(bd_we ? bus_write_ack : bus_read_ack) && !fx_hold_e;
`ifdef VEN_FP_LOAD_EARLY_CMD
  wire mem_read_ack=(mutant==1) ? bus_read_ack :
                    (mutant==2) ? 1'b1 : bus_read_ack && !fx_hold_e;
`else
  wire mem_read_ack=mem_ack;
`endif
  wire [31:0] pf_fill_addr=32'h34567fe0 ^ {payload[10:0],5'd0};
  wire [31:0] pf_miss_fa=32'h76543000 ^ {payload[14:0],5'd0};
  wire pf_fill_way=payload[31];
  wire [31:0] mem_rdata=payload;
  wire ic_victim_o[128];
  for(genvar s=0;s<128;s++) assign ic_victim_o[s]=1'(s)^payload[16];
  logic ic_fill_en,ic_fill_done,ic_fill_way;
  logic [6:0] ic_fill_set;
  logic [4:0] ic_fill_off;
  logic [31:0] ic_fill_data;
  logic [19:0] ic_fill_tag;
  always_comb begin
FILL_BODY
  end
  assign observation={ic_fill_en,ic_fill_done,ic_fill_set,ic_fill_way,
                      ic_fill_off,ic_fill_data,ic_fill_tag};
  assign write_owner=bd_we;
  assign fill=ic_fill_en;
  assign done=ic_fill_done;
endmodule

module tb_ic_fill_read_ack;
  logic [25:0] bits;
  logic [1:0] state;
  logic [2:0] pf_word;
  logic [31:0] payload;
  integer mutant;
  wire [66:0] reference_obs,candidate_obs;
  wire rw,cw,rf,cf,rd,cd;
  fill_reference reference_dut(bits,state,pf_word,payload,0,reference_obs,rw,rf,rd);
  fill_candidate candidate_dut(bits,state,pf_word,payload,mutant,candidate_obs,cw,cf,cd);
  integer samples=0,pf_fills=0,word0=0,completed=0,fragment_hold=0;
  integer no_ack=0,flush=0,held=0,diverted=0,bypass=0;
  task automatic check;
    #1;
    samples++;
    if(reference_obs!==candidate_obs || rw!==cw)
      $fatal(1,"IC-FILL-EQUIV state=%0d bits=%07x word=%0d mutant=%0d old=%h new=%h",
             state,bits,pf_word,mutant,reference_obs,candidate_obs);
    if(cf && cw) $fatal(1,"IC-FILL-WRITE-OWNER bits=%07x",bits);
    if(cf && state==2) pf_fills++;
    if(cf && state==1) word0++;
    if(cd) completed++;
    if(!cf && bits[23] && bits[21]) fragment_hold++;
    if(!cf && !bits[21] && bits[22]) no_ack++;
    if(!cf && bits[19]) flush++;
    if(!cf && state==1 && bits[6] && !bits[1]) held++;
    if(!cf && !bits[18]) diverted++;
    if(cf && state==1 && !bits[20] && !bits[21]) bypass++;
  endtask
  initial begin
    if(!$value$plusargs("mutant=%d",mutant)) mutant=0;
    // All original 18 frontend/data-owner guard classes, all 64 combinations
    // of FSM/flush/bypass/read ACK/write ACK/fragment hold, all three states.
    // At each vector, pf_word/payload sweep deterministically. Cancellation
    // is independent of direction and does not authorize a fill.
    for(integer st=0;st<3;st++) begin
      state=2'(st);
      for(integer i=0;i<16777216;i++) begin
        bits={2'(i ^ (i>>7)),24'(i)};
        pf_word=3'(i ^ (i>>18));
        payload=32'hf1235678 ^ (32'(i)*32'h10204081);
        check();
      end
    end
    if(!(samples==50331648 && pf_fills && word0 && completed && fragment_hold &&
         no_ack && flush && held && diverted && bypass))
      $fatal(1,"IC-FILL-VACUOUS samples=%0d",samples);
    $display("IC-FILL-READ-ACK-OK samples=%0d pf=%0d word0=%0d completed=%0d fragment=%0d noack=%0d flush=%0d held=%0d diverted=%0d bypass=%0d",
             samples,pf_fills,word0,completed,fragment_hold,no_ack,flush,held,diverted,bypass);
    $finish;
  end
endmodule
