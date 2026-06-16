// Investigator B: stress the ven_l1d registered-read-window handshake across a
// CONTINUOUS multi-instruction fetch stream (c_req held high the ENTIRE time, the
// way the real core's S_FETCH burst does), with a MULTI-CYCLE backing (line fill
// latency), exercising the rd_armed/rd_match/rd_addr_q "stale window for a
// mismatched address" path that is the sequence-dependent suspect.
module tb_l1d_b2bfetch;
  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        m_req, m_we; logic [31:0] m_addr, m_wdata; logic [3:0] m_wstrb;
  logic [31:0] m_rdata; logic m_ack;

  ven_l1d dut (.clk, .rst_n, .flush_all(1'b0), .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb,
               .c_rdata, .c_ack, .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack);

  logic [7:0] mem [0:(1<<24)-1];
  // ---- MULTI-CYCLE backing: a read takes RLAT cycles to ack (models AXI fill).
  int RLAT = 3;
  int lat = 0;
  logic [31:0] m_addr_l;
  always_ff @(posedge clk) begin
    if (!rst_n) begin lat<=0; m_ack<=0; m_rdata<=0; end
    else begin
      m_ack<=0;
      if (m_req && !m_we) begin
        if (lat==0) begin m_addr_l<=m_addr; lat<=RLAT; end
        else if (lat==1) begin
          m_ack<=1; m_rdata<={mem[m_addr+3],mem[m_addr+2],mem[m_addr+1],mem[m_addr+0]}; lat<=0;
        end else lat<=lat-1;
      end else if (m_req && m_we) begin
        m_ack<=1;
      end else lat<=0;
    end
  end
  always_ff @(posedge clk) if (m_req && m_we)
    for (int b=0;b<4;b++) if (m_wstrb[b]) mem[m_addr+b] <= m_wdata[b*8 +: 8];

  int errors=0; int checks=0;

  // Continuous fetch stream: a list of fetch addresses; for EACH, read 4 words with
  // c_req held HIGH across the whole stream (never deasserted between instructions),
  // mirroring the core that holds c_req from one S_FETCH straight into the next.
  logic [31:0] prog [40]; int proglen;
  task automatic stream_fetch();
    int guard; int pi; int wi; logic [31:0] base;
    pi=0; wi=0; guard=0;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_wstrb<=4'd0;
    base = prog[0]; c_addr<=base;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin
        automatic logic [31:0] a   = prog[pi] + 32'(wi)*4;
        automatic logic [31:0] exp = {mem[a+3],mem[a+2],mem[a+1],mem[a+0]};
        checks++;
        if (c_rdata !== exp) begin
          $display("  FAIL insn[%0d] flin=%08x word%0d @%08x: got %08x exp %08x boff=%0d",
                   pi, prog[pi], wi, a, c_rdata, exp, a[4:0]);
          errors++;
        end
        wi++;
        if (wi==4) begin
          wi=0; pi++;
          if (pi==proglen) break;
        end
        c_addr <= prog[pi] + 32'(wi)*4;   // c_req STAYS high into the next insn
      end
      if (++guard>4000) begin $display("  FAIL stream: stuck at insn[%0d] w%0d",pi,wi); errors++; break; end
    end
    @(negedge clk); c_req<=1'b0;
  endtask

  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    for (int i=0;i<(1<<24);i++) mem[i]=8'h00;
    // board repro program @ 0x08047000
    mem[32'h08047000]=8'h50; mem[32'h08047001]=8'h53;
    mem[32'h08047002]=8'hb8; mem[32'h08047003]=8'hf3; mem[32'h08047004]=8'h00;
    mem[32'h08047005]=8'h00; mem[32'h08047006]=8'h00;
    mem[32'h08047007]=8'hbb; mem[32'h08047008]=8'h11; mem[32'h08047009]=8'h22;
    mem[32'h0804700a]=8'h33; mem[32'h0804700b]=8'h44; mem[32'h0804700c]=8'hf4;
    for (int k=13;k<128;k++) mem[32'h08047000+k]=8'hCC;

    repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    // exact retired-EIP fetch stream for the board repro
    prog[0]=32'h08047000; prog[1]=32'h08047001; prog[2]=32'h08047002;
    prog[3]=32'h08047007; prog[4]=32'h0804700c;
    proglen=5;

    $display("=== continuous stream, RLAT=%0d ===", RLAT);
    stream_fetch();

    // Re-run with several backing latencies to shake any cycle-alignment-sensitive
    // window-capture stale-serve.
    for (int rl=1; rl<=6; rl++) begin
      RLAT=rl;
      // also re-run the same stream after a FLUSH so every line cold-misses (forces
      // the multi-cycle fill between consecutive fetches -> the rd_armed-across-addr case)
      $display("=== continuous stream, RLAT=%0d (re-run) ===", rl);
      stream_fetch();
    end

    if (errors==0) $display("L1D-B2BFETCH-OK (%0d checks, all byte-exact)", checks);
    else           $display("L1D-B2BFETCH-FAIL (%0d/%0d mismatches)", errors, checks);
    $finish;
  end
endmodule
