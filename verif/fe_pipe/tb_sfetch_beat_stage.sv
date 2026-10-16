// Exact extracted stage, exercised without hierarchical state writes.
module tb;
  localparam S_FETCH=0, S_WALK=1, S_OTHER=2;
  reg clk=0, rst_n=0;
  reg [1:0] state=S_OTHER, walk_ret_state=S_OTHER;
  reg sfetch_boundary=0, sfetch_want_req=0, fsm_case_enabled=1;
  reg mem_req=0, mem_ack=0;
  reg [2:0] sfetch_want_size=0;
  wire sfetch_demand_req;
  wire [2:0] sfetch_demand_size;
  // EXTRACTED_STAGE
  integer checks=0, beats=0, walks=0, resets=0, cancels=0, stalls=0;
  task automatic tick;
    #2; clk=1; #2; clk=0; #2;
  endtask
  task automatic expect_beat(input bit pending, input [2:0] size);
    #1;
    checks++;
    if (sfetch_demand_req !== pending || (pending && sfetch_demand_size !== size))
      $fatal(1,"SFETCH-BEAT-MISMATCH checks=%0d req=%b expected=%b size=%d expected=%d",
             checks,sfetch_demand_req,pending,sfetch_demand_size,size);
  endtask
  initial begin
    tick(); rst_n=1;
    for (int n=0; n<4096; n++) begin
      state=S_FETCH; sfetch_boundary=1; sfetch_want_req=1;
      sfetch_want_size=3'(1+(n%4)); fsm_case_enabled=1; mem_req=0; mem_ack=0;
      expect_beat(0,0); // late raw metadata cannot reach request/width this clock
      tick(); expect_beat(1,3'(1+(n%4))); beats++;
      // Request remains live through backpressure and unqualified ACKs.
      mem_ack=1; tick(); expect_beat(1,3'(1+(n%4))); stalls++;
      mem_req=1; fsm_case_enabled=0; tick(); expect_beat(1,3'(1+(n%4))); stalls++;
      mem_ack=0; fsm_case_enabled=1;
      if ((n%2)==0) begin
        state=S_WALK; walk_ret_state=S_FETCH;
        mem_req=1; mem_ack=1; tick(); expect_beat(0,0);
        tick(); state=S_FETCH; mem_ack=0; expect_beat(1,3'(1+(n%4))); walks++;
      end
      case (n%8)
        0: begin // Reset drops even an outstanding owner.
          rst_n=0; tick(); rst_n=1; expect_beat(0,0); resets++;
        end
        1: begin // A fault redirected the FSM, then a new instruction begins.
          state=S_OTHER; tick(); state=S_FETCH; expect_beat(0,0); cancels++;
        end
        2: begin // Walk owned by another producer cannot retain this beat.
          state=S_WALK; walk_ret_state=S_OTHER; tick(); state=S_FETCH;
          expect_beat(0,0); cancels++;
        end
        3: begin // Non-boundary wide fetch remains outside this stage.
          sfetch_boundary=0; tick(); sfetch_boundary=1; expect_beat(0,0); cancels++;
        end
        default: begin
          mem_ack=1; tick(); expect_beat(0,0);
          // No same-edge reload of stale size/valid count after accepting data.
        end
      endcase
      mem_req=0; mem_ack=0; sfetch_want_req=0;
      tick(); expect_beat(0,0);
    end
    if (beats!=4096 || walks!=2048 || resets!=512 || cancels!=1536 || stalls!=8192)
      $fatal(1,"SFETCH-BEAT-COVERAGE");
    $display("SFETCH-BEAT-OK checks=%0d beats=%0d walks=%0d resets=%0d cancels=%0d stalls=%0d",
             checks,beats,walks,resets,cancels,stalls);
    $finish;
  end
endmodule
