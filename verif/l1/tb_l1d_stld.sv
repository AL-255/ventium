// tb_l1d_stld.sv — validate the store-to-load forwarding fix (write->read same-line
// coherence). Models the exact hardware failure: the backing (PS-DDR) DROPS writes
// (BVALID before the write lands), so a re-read of a just-written line returns STALE
// data — UNLESS ven_l1d's forwarding buffer supplies the committed store. Tests both
// the fill path (miss) and the serve path (stale HIT), cacheable and non-cacheable.
module tb_l1d;
  logic clk=0, rst_n=0;
  always #5 clk = ~clk;

  logic        c_req, c_we; logic [31:0] c_addr, c_wdata; logic [3:0] c_wstrb;
  logic [31:0] c_rdata; logic c_ack; logic [3:0] dbg_serve;
  logic        m_req, m_we; logic [31:0] m_addr, m_wdata; logic [3:0] m_wstrb;
  logic [31:0] m_rdata; logic m_ack;
  logic        cacheable;

  ven_l1d dut (
`ifdef VEN_PIPE_MEM_CHAIN
      .c_next_req(1'b0), .c_next_commit(1'b0), .c_next_cacheable(1'b0),
      .c_next_addr(32'd0), .c_next_wstrb(4'd0), .c_next_ready(),
`endif
.clk, .rst_n, .flush_all(1'b0), .golden(1'b0),
    .cacheable(cacheable), .snoop_inv_valid(1'b0), .snoop_inv_addr(32'd0),
    .c_req, .c_we, .c_addr, .c_wdata, .c_wstrb, .c_rdata, .c_ack, .dbg_serve,
    .m_req, .m_we, .m_addr, .m_wdata, .m_wstrb, .m_rdata, .m_ack);

  // Backing: byte-addressed. WRITES ARE DROPPED (stale-DDR model) so only ven_l1d's
  // forwarding can provide written data. Reads return the (stale) backing verbatim.
  logic [7:0] mem [0:(1<<20)-1];
  function automatic logic [31:0] rd32(input logic [31:0] a);
    logic [19:0] b; b = a[19:0];
    rd32 = {mem[b+3], mem[b+2], mem[b+1], mem[b+0]};
  endfunction
  always_comb begin
    m_rdata = 32'd0; m_ack = 1'b0;
    if (m_req) begin m_ack = 1'b1; if (!m_we) m_rdata = rd32({m_addr[19:2],2'b00}); end
  end

  int errors = 0;
  task automatic do_write(input logic [31:0] a, input logic [31:0] d, input logic [3:0] be);
    @(negedge clk); c_req<=1; c_we<=1; c_addr<=a; c_wdata<=d; c_wstrb<=be;
    do @(posedge clk); while (!c_ack);
    @(negedge clk); c_req<=0; c_we<=0;
  endtask
  task automatic do_read(input logic [31:0] a, output logic [31:0] d);
    @(negedge clk); c_req<=1; c_we<=0; c_wstrb<=0; c_addr<=a;
    do @(posedge clk); while (!c_ack);
    #1; d = c_rdata;
    @(negedge clk); c_req<=0;
  endtask
  task automatic chk(input string nm, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin errors++; $display("FAIL %s: got %08x exp %08x", nm, got, exp); end
    else $display("PASS %s: %08x", nm, got);
  endtask

  logic [31:0] rv;
  initial begin
    for (int i=0;i<(1<<20);i++) mem[i]=8'h00;
    c_req=0;c_we=0;c_addr=0;c_wdata=0;c_wstrb=0; cacheable=1'b1;
    repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);

    // ---- CACHEABLE: pre-cache line 0x88f80 as 0, write the CS desc word, re-read.
    do_read(32'h00088f8b, rv);                    // pre-cache line (backing 0)
    do_write(32'h00088f88, 32'h9b0f0000, 4'hf);   // CS desc word @0x88f88 = 00 00 0f 9b
    do_read (32'h00088f88, rv); chk("cacheable-fwd-word", rv, 32'h9b0f0000);
    do_read (32'h00088f88, rv); chk("cacheable-fwd-hit",  rv, 32'h9b0f0000);  // 2nd read = HIT path

    // ---- NON-CACHEABLE (CR0.CD=1 at BIOS PM-entry — the real GDT case).
    cacheable = 1'b0;
    do_read (32'h00099000, rv);                   // pre-cache/serve backing 0
    do_write(32'h00099000, 32'hdeadbeef, 4'hf);
    do_read (32'h00099000, rv); chk("noncache-fwd",     rv, 32'hdeadbeef);
    do_read (32'h00099000, rv); chk("noncache-fwd-hit", rv, 32'hdeadbeef);

    // ---- unaligned byte write forwarded to an unaligned read (GDT is at 0x88f6b+off).
    cacheable = 1'b1;
    do_write(32'h00088f8b, 32'h000000ff, 4'h1);   // single byte 0xff at 0x88f8b
    do_read (32'h00088f8b, rv); chk("unaligned-fwd-byte", rv[7:0], 8'hff);

    if (errors==0) $display("L1D-STLD-OK"); else $display("L1D-STLD-FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
