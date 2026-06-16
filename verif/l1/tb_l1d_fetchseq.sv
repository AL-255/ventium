// Investigator B: replay the EXACT slow-S_FETCH unaligned read sequence for the
// 12-byte board repro program, checking every returned byte. Reproduces:
//   guest 0x08047000 = "50 53 b8 f3 00 00 00 bb 11 22 33 44 f4"
//   push eax(1B@..00); push ebx(1B@..01); mov eax,imm32(5B@..02); mov ebx,imm32(5B@..07); hlt(@..0c)
// The slow path reads a 16-byte window (4 words) at flin = EIP for EACH instruction.
// We model the actual fetch ADDRESSES the core issues, with c_req HELD across the 4
// words (the real S_FETCH protocol), and verify c_rdata is byte-exact vs the backing.
module tb_l1d_fetchseq;
  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack;
  logic        m_req, m_we; logic [31:0] m_addr, m_wdata; logic [3:0] m_wstrb;
  logic [31:0] m_rdata; logic m_ack;

  ven_l1d dut (.clk, .rst_n, .flush_all(1'b0), .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb,
               .c_rdata, .c_ack, .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack);

  logic [7:0] mem [0:(1<<24)-1];
  function automatic logic [31:0] rd32(input logic [31:0] a);
    rd32 = {mem[a+3], mem[a+2], mem[a+1], mem[a+0]};
  endfunction
  always_comb begin
    m_rdata = 32'd0; m_ack = 1'b0;
    if (m_req) begin m_ack = 1'b1; if (!m_we) m_rdata = rd32(m_addr); end
  end

  int errors = 0;

  // mimic the slow S_FETCH: hold c_req, read 4 words at flin+0/4/8/12, check each.
  task automatic fetch16(input logic [31:0] flin);
    int guard; int i;
    @(negedge clk); c_req<=1'b1; c_we<=1'b0; c_wstrb<=4'd0; c_addr<=flin;
    i=0; guard=0;
    forever begin
      @(posedge clk); #1;
      if (c_ack) begin
        automatic logic [31:0] a   = flin + 32'(i)*4;
        automatic logic [31:0] exp = {mem[a+3], mem[a+2], mem[a+1], mem[a+0]};
        if (c_rdata !== exp) begin
          $display("  FAIL fetch flin=%08x word%0d @%08x: got %08x exp %08x (boff=%0d)",
                   flin, i, a, c_rdata, exp, a[4:0]);
          errors++;
        end else
          $display("  ok   fetch flin=%08x word%0d @%08x = %08x (boff=%0d)",
                   flin, i, a, c_rdata, a[4:0]);
        i++; if (i==4) break;
        c_addr <= flin + 32'(i)*4;
      end
      if (++guard > 400) begin $display("  FAIL fetch flin=%08x: no ack at w%0d", flin, i); errors++; break; end
    end
    @(negedge clk); c_req<=1'b0;
  endtask

  initial begin
    c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
    for (int i=0;i<(1<<24);i++) mem[i] = 8'h00;
    // load the 12-byte board repro at 0x08047000
    mem[32'h08047000]=8'h50; mem[32'h08047001]=8'h53;
    mem[32'h08047002]=8'hb8; mem[32'h08047003]=8'hf3; mem[32'h08047004]=8'h00;
    mem[32'h08047005]=8'h00; mem[32'h08047006]=8'h00;
    mem[32'h08047007]=8'hbb; mem[32'h08047008]=8'h11; mem[32'h08047009]=8'h22;
    mem[32'h0804700a]=8'h33; mem[32'h0804700b]=8'h44; mem[32'h0804700c]=8'hf4;
    // fill the rest of the line + next line with a marker so OOB reads are visible
    for (int k=13;k<64;k++) mem[32'h08047000+k] = 8'hCC;

    repeat(4) @(posedge clk); rst_n<=1'b1; @(posedge clk);

    // Sequence A: the FAILING board sequence — fetch at each retired EIP.
    // push eax @..00, push ebx @..01, mov eax @..02 (5B word-spanning), mov ebx @..07 (5B).
    $display("=== Sequence A: board repro fetch addresses ===");
    fetch16(32'h08047000);   // push eax
    fetch16(32'h08047001);   // push ebx
    fetch16(32'h08047002);   // mov eax,imm32  (boff 2, spans word0/word1)
    fetch16(32'h08047007);   // mov ebx,imm32  (boff 7, spans word0/word1) <-- the suspect
    fetch16(32'h0804700c);   // hlt

    // Sequence B: the WORKING variant — same 0x08047007 fetch, but preceded by
    // single-byte steps (mimics the NOP*7 control: prior insn is 1-byte).
    $display("=== Sequence B: 0x08047007 fetch after 1-byte prior fetches ===");
    fetch16(32'h08047005);
    fetch16(32'h08047006);
    fetch16(32'h08047007);   // same address, different fetch history

    if (errors==0) $display("L1D-FETCHSEQ-OK (all fetch words byte-exact)");
    else           $display("L1D-FETCHSEQ-FAIL (%0d byte mismatches)", errors);
    $finish;
  end
endmodule
