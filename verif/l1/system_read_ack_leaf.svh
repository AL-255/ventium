// ACK-boundary proof only. Request authorization and the complete system FSM
// remain whole-core obligations. The source audit establishes each direction.
module system_read_ack_owner(input integer owner, input integer mutant,
    input logic [6:0] frag, input logic [3:0] ctrl,
    output logic old_enable, new_enable, read_owner, hold_ack);
  wire bus_read_ack=ctrl[0], bus_write_ack=ctrl[1], permit=ctrl[2];
  // Exercise an ACK-independent arm (e.g. a null selector or V86 task segment)
  // too. The actual source transformation leaves these conditions untouched.
  wire bypass=ctrl[3];
  wire fx_act=frag[0],fx_walk_hold=frag[1],fx_abort_q=frag[2],fx_wr=frag[3];
  wire [1:0] fx_ph=frag[5:4];
  wire fx_start=frag[6];
  wire fx_hold_e;
  logic selected_ack;
  wire mem_ack,mem_read_ack;
  assign read_owner =
READ_OWNER
  ;
  wire bus_ack=read_owner ? bus_read_ack : bus_write_ack;
FRAGMENT
ACK
`ifdef VEN_FP_LOAD_EARLY_CMD
READ_ACK
`else
FALLBACK_ACK
`endif
  // Source-linked ACK consumers, including all eight encodings of walk_step.
  // Two unchanged write owners catch accidentally replacing general ACKs.
  always_comb begin
    selected_ack=mem_ack;
    case(owner)
CONSUMERS
      default: ;
    endcase
    if (mutant==1 && read_owner) selected_ack=bus_read_ack;
    if (mutant==2 && read_owner) selected_ack=1;
    if (mutant==3 && !read_owner) selected_ack=bus_read_ack && !fx_hold_e;
    if (mutant==4 && read_owner) selected_ack=bus_write_ack && !fx_hold_e;
  end
  assign old_enable=permit && (bypass || mem_ack);
  assign new_enable=permit && (bypass || selected_ack);
  assign hold_ack=fx_hold_e;
endmodule

module tb_system_read_ack;
  integer owner,mutant;
  logic [6:0] frag;
  logic [3:0] ctrl;
  wire old_enable,new_enable,read_owner,hold_ack;
  system_read_ack_owner dut(.*);
  integer samples=0,reads=0,writes=0,held=0,completed=0,denied=0,bypassed=0,distinct_acks=0;
  initial begin
    if (!$value$plusargs("mutant=%d",mutant)) mutant=0;
    for(integer st=0;st<30;st++)
    for(integer f=0;f<128;f++)
    for(integer c=0;c<16;c++) begin
      owner=st; frag=7'(f); ctrl=4'(c); #1;
      samples++;
      if (old_enable!==new_enable)
        $fatal(1,"SYSTEM-READ-EQUIV owner=%0d frag=%h ctrl=%h mutant=%0d",owner,frag,ctrl,mutant);
      if(read_owner) reads++; else writes++;
      if(hold_ack && ctrl[2] && !ctrl[3] && !new_enable) held++;
      if(new_enable && !ctrl[3]) completed++;
      if(!ctrl[2] && !new_enable) denied++;
      if(ctrl[2] && ctrl[3] && new_enable) bypassed++;
      if(ctrl[0]!=ctrl[1]) distinct_acks++;
    end
    if(!(samples==61440 && reads==45056 && writes==16384 && held && completed &&
         denied && bypassed && distinct_acks)) $fatal(1,"SYSTEM-READ-VACUOUS");
    $display("SYSTEM-READ-OK samples=%0d reads=%0d writes=%0d held=%0d completed=%0d denied=%0d bypassed=%0d distinct_acks=%0d",
             samples,reads,writes,held,completed,denied,bypassed,distinct_acks);
    $finish;
  end
endmodule
