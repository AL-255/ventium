`timescale 1ns/1ps
module tb_p54_hit_return;
  logic clk=0, rst_n=0, flush=0;
  always #5 clk=~clk;
  logic [1:0] req_valid=0, req_hit=2'b11, req_ready, req_split;
  logic [1:0][7:0] req_bank_mask;
  logic [1:0][15:0] req_owner=0, rsp_owner;
  logic [1:0][31:0] req_paddr=0, req_data=0, rsp_paddr, rsp_data;
  logic [1:0][1:0] req_size_log2=0;
  logic [7:0] bank_ready=8'hff;
  logic bank_conflict;
  logic [1:0] rsp_valid, rsp_ready=0, rsp_cancel;
  logic [1:0] accepted, canceled;
  logic [15:0] exp_owner[2];
  logic [31:0] exp_addr[2], exp_data[2];
  logic [1:0] exp_valid=0;
  logic [1:0] stalled_q=0;
  logic [1:0][15:0] stalled_owner_q;
  logic [1:0][31:0] stalled_addr_q, stalled_data_q;
  logic [1:0][1:0] stalled_size_q;
  logic [1:0] stalled_hit_q;
  int checks=0, accepts=0, responses=0, holds=0, flushes=0, cancels=0;
  int unsigned rng=32'h51671a39;
  ven_p54_hit_return dut(.*);

  always @(posedge clk) begin
    accepted = req_valid & req_ready;
    canceled = exp_valid & {2{flush}};
    if (!rst_n) begin
      exp_valid = '0;
      stalled_q = '0;
    end else begin
      for (int lane=0; lane<2; lane++) begin
        if (stalled_q[lane] && !flush &&
            (!req_valid[lane] || req_owner[lane] !== stalled_owner_q[lane] ||
             req_paddr[lane] !== stalled_addr_q[lane] ||
             req_data[lane] !== stalled_data_q[lane] ||
             req_size_log2[lane] !== stalled_size_q[lane] ||
             req_hit[lane] !== stalled_hit_q[lane]))
          $fatal(1,"producer changed a stalled request lane=%0d", lane);
        stalled_q[lane] = req_valid[lane] && !req_ready[lane] && !flush;
        stalled_owner_q[lane] = req_owner[lane];
        stalled_addr_q[lane] = req_paddr[lane];
        stalled_data_q[lane] = req_data[lane];
        stalled_size_q[lane] = req_size_log2[lane];
        stalled_hit_q[lane] = req_hit[lane];
      end
      for (int lane=0; lane<2; lane++) begin
        if (rsp_valid[lane] !== (exp_valid[lane] && !flush))
          $fatal(1,"response valid mismatch lane=%0d clock=%0d",lane,checks);
        if (rsp_valid[lane]) begin
          if (rsp_owner[lane] !== exp_owner[lane] ||
              rsp_paddr[lane] !== exp_addr[lane] ||
              rsp_data[lane] !== exp_data[lane])
            $fatal(1,"response owner/data changed lane=%0d clock=%0d",lane,checks);
          if (rsp_ready[lane]) responses++;
          else holds++;
        end
      end
      if (flush) begin
        if (req_ready != 0) $fatal(1,"accepted request during flush");
        if (rsp_cancel !== canceled) $fatal(1,"cancellation owner mismatch");
        cancels += $countones(canceled);
        exp_valid = '0;
        flushes++;
      end else begin
        for (int lane=0; lane<2; lane++) begin
          if (rsp_valid[lane] && rsp_ready[lane]) exp_valid[lane]=0;
          if (accepted[lane]) begin
            if (exp_valid[lane]) $fatal(1,"overwrote held response");
            exp_valid[lane]=1;
            exp_owner[lane]=req_owner[lane];
            exp_addr[lane]=req_paddr[lane];
            exp_data[lane]=req_data[lane];
            accepts++;
          end
        end
      end
      checks++;
    end
  end

  task automatic step();
    @(posedge clk);
    #1;
  endtask

  initial begin
    repeat(3) step();
    @(negedge clk); rst_n=1;
    // Both lanes accept on every edge after filling their one-response slots.
    for (int i=0; i<65; i++) begin
      req_valid=2'b11; rsp_ready=2'b11;
      req_owner[0]=16'(2*i); req_owner[1]=16'(2*i+1);
      req_paddr[0]=32'h1000; req_paddr[1]=32'h1024;
      req_size_log2[0]=2; req_size_log2[1]=2;
      req_data[0]=32'(i); req_data[1]=~32'(i);
      #1;
      if (req_ready!==2'b11) $fatal(1,"two-hit cadence bubble %0d",i);
      step();
      @(negedge clk);
    end
    req_valid=0; step(); @(negedge clk);
    if (accepts!=130 || responses!=130) $fatal(1,"pair cadence count");

    // Hold an old owner while a newer request is presented. No overwrite.
    req_valid=2'b01; rsp_ready=0; req_owner[0]=16'h1234;
    req_paddr[0]=32'h1008; req_data[0]=32'hfeed1234;
    #1; if (!req_ready[0]) $fatal(1,"hold fixture did not accept");
    step(); @(negedge clk);
    req_owner[0]=16'h5678; req_paddr[0]=32'h1010;
    req_data[0]=32'hfeed5678;
    repeat(5) begin
      #1; if (req_ready[0] || !rsp_valid[0] || rsp_owner[0]!=16'h1234)
        $fatal(1,"backpressure changed owner");
      step(); @(negedge clk);
    end
    rsp_ready[0]=1;
    #1; if (!req_ready[0]) $fatal(1,"consume/replace bubble");
    step(); @(negedge clk);
    req_valid=0;
    #1; if (!rsp_valid[0] || rsp_owner[0]!=16'h5678)
      $fatal(1,"replacement owner missing");
    step(); @(negedge clk);

    // A miss or split U cannot let a younger V pass.
    req_valid=2'b11; req_hit=2'b10; rsp_ready=2'b11;
    req_paddr[0]=32'h1000; req_paddr[1]=32'h1024;
    #1; if (req_ready!=0) $fatal(1,"V passed U miss");
    req_hit=2'b11; req_paddr[0]=32'h101f;
    #1; if (req_ready!=0 || !req_split[0]) $fatal(1,"V passed U split");
    req_paddr[0]=32'h1000; req_paddr[1]=32'h1020;
    #1; if (req_ready!=2'b01 || !bank_conflict)
      $fatal(1,"same-bank pair not serialized");
    step(); @(negedge clk);
    req_valid=2'b10; req_paddr[1]=32'h1020;
    #1; if (!req_ready[1]) $fatal(1,"held V did not resume");
    step(); @(negedge clk);

    // Cancellation wins over simultaneous response consume/request replacement.
    flush=1; req_valid=2'b11; rsp_ready=2'b11;
    #1; if (rsp_valid!=0 || req_ready!=0) $fatal(1,"flush leaked owner");
    step(); @(negedge clk);
    flush=0; req_valid=0;
    #1; if (rsp_valid!=0) $fatal(1,"canceled response resurrected");

    // Exercise independently paced lanes with random bank and response stalls.
    for (int i=0; i<10000; i++) begin
      rng = rng * 32'd1664525 + 32'd1013904223;
      rsp_ready[0]=rng[3]; rsp_ready[1]=rng[4];
      if (!req_valid[0] || accepted[0]) begin
        req_valid[0]=rng[0];
        req_size_log2[0]=rng[16:15];
        req_paddr[0]=32'h1000 + 32'(int'(rng[9:5]) %
                                    (33 - (1 << req_size_log2[0])));
        req_owner[0]=16'(2*i); req_data[0]=rng;
      end
      if (!req_valid[1] || accepted[1]) begin
        req_valid[1]=rng[1];
        req_size_log2[1]=rng[18:17];
        req_paddr[1]=32'h1020 + 32'(int'(rng[14:10]) %
                                    (33 - (1 << req_size_log2[1])));
        req_owner[1]=16'(2*i+1); req_data[1]=~rng;
      end
      bank_ready=rng[26:19];
      #1;
      if (req_valid[0] && !req_ready[0] && req_ready[1])
        $fatal(1,"V overtook unaccepted U");
      step(); @(negedge clk);
    end
    // Drain any held producer requests before ending the stream.
    bank_ready='1; rsp_ready=2'b11;
    for (int n=0; n<8 && req_valid!=0; n++) begin
      step(); @(negedge clk);
      req_valid &= ~accepted;
    end
    if (req_valid!=0) $fatal(1,"pending requests failed to drain");
    repeat(2) begin step(); @(negedge clk); end
    if (exp_valid!=0 || rsp_valid!=0 || accepts<500 || responses<500 || holds<500 ||
        cancels!=1 || accepts-responses!=cancels)
      $fatal(1,"insufficient response coverage");
    $display("P54-HIT-RETURN-OK checks=%0d accepts=%0d responses=%0d holds=%0d cancels=%0d flushes=%0d",
             checks,accepts,responses,holds,cancels,flushes);
    $finish;
  end
endmodule
