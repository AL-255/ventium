module tb_raw_branch_mov;
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  `include "raw-branch-mov.svh"
  logic [7:0] b0, b1, b2;
  fpd_t decoded, hint;
  int checked, accepted;
  decode dut(.ib0(b0), .ib1(b1), .ib2(b2), .ib3(8'h80), .ib4(8'hff),
      .ib5(8'h5a), .ib6(8'ha5), .iflags(32'h246), .def16(1'b0),
      .cycle_mode(1'b1), .uop(decoded));
  task automatic check_one;
    logic admit;
    #1;
    hint = mc_raw_branch_mov(b0,b1,b2);
    admit = b0 == 8'h8b && b1[7:6] < 2 && b1[2:0] != 4 && b1[5:3] != 4 &&
            !(b1[7:6] == 0 && b1[2:0] == 5);
    assert ((hint.len != 0) == admit) else $fatal(1,"incorrect admission");
    if (admit) begin
      assert (hint === decoded) else $fatal(1,"descriptor differs %02x %02x %02x", b0,b1,b2);
      accepted++;
    end else assert (hint === '0) else $fatal(1,"rejected descriptor not blank");
    checked++;
  endtask
  initial begin
    checked=0; accepted=0;
    for (int opcode=0;opcode<256;opcode++)
      for (int modrm=0;modrm<256;modrm++) begin
        b0=8'(opcode); b1=8'(modrm); b2=8'h80; check_one();
      end
    b0=8'h8b;
    for (int modrm=0;modrm<256;modrm++)
      for (int disp=0;disp<256;disp++) begin
        b1=8'(modrm); b2=8'(disp); check_one();
      end
    assert (checked==131072 && accepted==23387) else $fatal(1,"coverage count %0d/%0d", checked,accepted);
    $display("RAW-BRANCH-MOV-OK checks=%0d accepted=%0d",checked,accepted);
    $finish;
  end
endmodule
