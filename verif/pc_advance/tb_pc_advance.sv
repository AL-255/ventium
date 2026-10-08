`timescale 1ns/1ps
module tb_pc_advance;
  logic [31:0] pc;
  logic [3:0] ulen, vlen;
  logic paired, code16;
  wire [31:0] eip_nx, post_eip;
  logic [31:0] reference_u, reference_post;
  logic [31:0] random_state = 32'h574ed136;
  integer checks = 0;
  pc_advance_dut dut(.*);

  function automatic logic [31:0] rng(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    rng = y ^ (y << 5);
  endfunction

  task automatic check;
    // Reference is the previous core expression, including exact 16-bit wrap.
    reference_u = code16 ? {16'd0, (pc[15:0] + {12'd0,ulen})}
                         : (pc + {28'd0,ulen});
    reference_post = code16
      ? {16'd0, (pc[15:0] + {12'd0,ulen} + (paired ? {12'd0,vlen} : 16'd0))}
      : (pc + {28'd0,ulen} + (paired ? {28'd0,vlen} : 32'd0));
    #1;
    if (eip_nx !== reference_u || post_eip !== reference_post)
      $fatal(1, "PC advance pc=%h U=%d V=%d paired=%b code16=%b got=%h/%h expected=%h/%h",
             pc, ulen, vlen, paired, code16, eip_nx, post_eip, reference_u, reference_post);
    checks++;
  endtask

  initial begin
    // All length codes, both pairing states and both widths at carry boundaries.
    // Zero-length descriptors are included as a stronger arithmetic check; the
    // issue machinery, not this leaf, decides descriptor validity and pairing.
    for (integer b=0; b<8; b++) begin
      case (b)
        0: pc=32'h0;          1: pc=32'h14562;
        2: pc=32'h59680;      3: pc=32'hffff;
        4: pc=32'hffef;       5: pc=32'hfffffff0;
        6: pc=32'hffffffff;   7: pc=32'h1234fffc;
      endcase
      for (integer u=0; u<16; u++) for (integer v=0; v<16; v++)
        for (integer p=0; p<2; p++) for (integer c=0; c<2; c++) begin
          ulen=4'(u); vlen=4'(v); paired=1'(p); code16=1'(c); check();
        end
    end
    for (integer i=0; i<65536; i++) begin
      random_state=rng(random_state); pc=random_state;
      random_state=rng(random_state);
      {ulen,vlen,paired,code16}=random_state[9:0]; check();
    end
    $display("PC-ADVANCE-RTL-OK checks=%0d", checks);
    $finish;
  end
endmodule
