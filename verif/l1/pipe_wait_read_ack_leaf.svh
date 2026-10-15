// Source-linked combinational ownership/fragment miter, not full-cache proof.
module wait_owner(input logic [21:0] bits, input logic [1:0] state,
    input logic [6:0] frag, input integer mutant,
    output logic [4:0] observation, output logic old_wait, output logic new_wait);
  localparam S_PIPE=1, S_PF=2;
  wire exec_issue_ok=bits[0], pipe_bytes_ok=bits[1], pipe_fetch_checked_handoff=bits[2];
  wire ic_fetch_ready=bits[3], uop_hit=bits[4], cycle_mode=bits[5];
  wire pipe_mem_active_q=bits[6],pipe_mem_we_q=bits[7],fp_issue_block=bits[8];
  wire [6:0] stall_cnt={6'd0,bits[9]},pending_mem_pen={6'd0,bits[10]};
  wire fp_sys_bail=bits[11],pipe_new_mem_cs_extent_fault=bits[12],pipe_agi=bits[15];
  wire [2:0] mispred_bubbles={2'd0,bits[16]};
  wire fp_pipe_rd_haz=bits[17];
  wire bus_read_ack=bits[18],bus_write_ack=bits[19],cancelled=bits[21];
  wire fx_act=frag[0],fx_walk_hold=frag[1],fx_abort_q=frag[2],fx_wr=frag[3];
  wire [1:0] fx_ph=frag[5:4];
  wire fx_start=frag[6];
  wire fx_hold_e;
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
  // Abstract the already established seam contract: read/general ACK agree
  // for !we; write completion remains independent. Cancellation is input-only.
  wire bus_ack=bd_we ? bus_write_ack : bus_read_ack;
  wire mem_ack,mem_read_ack;
FRAGMENT
ACK
`ifdef VEN_FP_LOAD_EARLY_CMD
READ_ACK
`else
FALLBACK_ACK
`endif
  wire selected_read_ack=(mutant==1) ? bus_read_ack :
                         (mutant==2) ? 1'b1 : mem_read_ack;
  wire selected_store_ack=(mutant==3) ? (bus_read_ack && !fx_hold_e) : mem_ack;
  wire selected_store_req=(mutant==4) ? 1'b0 : pipe_store_req;
REFERENCE
CANDIDATE
  assign observation={pipe_load_req,pipe_store_req,bd_we,bd_req,fx_hold_e};
endmodule

module tb_pipe_wait_read_ack;
  logic [21:0] bits;
  logic [1:0] state;
  logic [6:0] frag;
  integer mutant;
  wire [4:0] observation;
  wire old_wait,new_wait;
  wait_owner dut(.*);
  integer samples=0,reads=0,stores=0,held_reads=0,held_stores=0,idle=0;
  integer fragment_wait=0,done=0,cancelled=0,distinct_acks=0;
  task automatic check;
    #1;
    samples++;
    if (old_wait!==new_wait)
      $fatal(1,"PIPE-WAIT-EQUIV state=%0d bits=%h frag=%h mutant=%0d old=%b new=%b",
             state,bits,frag,mutant,old_wait,new_wait);
    if (observation[4] && (observation[3] || observation[2]))
      $fatal(1,"PIPE-WAIT-OWNER");
    if (observation[4]) begin reads++; if(bits[6]) held_reads++; end
    if (observation[3]) begin stores++; if(bits[6]) held_stores++; end
    if (!observation[4] && !observation[3]) idle++;
    if ((observation[4] || observation[3]) && observation[0] && new_wait) fragment_wait++;
    if ((observation[4] || observation[3]) && !new_wait) done++;
    if ((observation[4] || observation[3]) && bits[21]) cancelled++;
    if ((observation[4] || observation[3]) && (bits[18]!=bits[19])) distinct_acks++;
  endtask
  initial begin
    if (!$value$plusargs("mutant=%d",mutant)) mutant=0;
    // All 18 frontend/owner guards, both independent ACKs, fragment hold and
    // request cancellation, in idle, S_PIPE and S_PF. No guard is assumed true.
    for(integer st=0;st<3;st++) begin
      state=2'(st);
      for(integer i=0;i<4194304;i++) begin
        bits=22'(i); frag={bits[20],6'd0}; check();
      end
    end
    // Separately exhaust the actual 7-bit fragment qualifier on held read and
    // write owners, with independent ACKs and cancellation. The two truth
    // tables compose only at fx_hold_e, which the first sweep enumerates fully.
    state=1;
    for(integer wr=0;wr<2;wr++)
    for(integer f=0;f<128;f++)
    for(integer ctrl=0;ctrl<8;ctrl++) begin
      bits='0; bits[6]=1; bits[7]=1'(wr);
      {bits[21],bits[19:18]}=3'(ctrl); frag=7'(f); check();
    end
    if (!(samples==12584960 && reads && stores && held_reads && held_stores &&
          idle && fragment_wait && done && cancelled && distinct_acks))
      $fatal(1,"PIPE-WAIT-VACUOUS samples=%0d",samples);
    $display("PIPE-WAIT-OK samples=%0d reads=%0d stores=%0d held_reads=%0d held_stores=%0d idle=%0d fragment_wait=%0d done=%0d cancelled=%0d distinct_acks=%0d",
             samples,reads,stores,held_reads,held_stores,idle,fragment_wait,done,cancelled,distinct_acks);
    $finish;
  end
endmodule
