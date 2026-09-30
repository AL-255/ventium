// 16-bit decode unit test (task #56). The 98-program gate is 32-bit flat by construction, so
// every operand-size layer of the fast-path retrofit went in unguarded. This drives decode.sv
// directly with def16=1 and checks what it produces against the x86 encoding, which localises a
// wrong arm in seconds instead of a boot-and-guess cycle.
`timescale 1ns/1ps
module tb_decode16;
  import ventium_decode_pkg::*;
  logic [7:0] b [0:6];
  logic [31:0] fl = 32'h2;
  logic d16 = 1'b1;
  fpd_t uop;
  decode dut(.ib0(b[0]),.ib1(b[1]),.ib2(b[2]),.ib3(b[3]),.ib4(b[4]),.ib5(b[5]),.ib6(b[6]),
             .iflags(fl), .def16(d16), .cycle_mode(1'b0), .uop(uop));
  int fails = 0;
  task automatic chk(string name, int exp_len, logic exp_simple, int exp_imm);
    #1;
    if (uop.simple !== exp_simple) begin
      $display("FAIL %-22s simple=%0d expected %0d", name, uop.simple, exp_simple); fails++;
    end else if (exp_simple && uop.len !== exp_len[3:0]) begin
      $display("FAIL %-22s len=%0d expected %0d", name, uop.len, exp_len); fails++;
    end else if (exp_simple && exp_imm >= 0 && uop.imm !== exp_imm) begin
      $display("FAIL %-22s imm=%08x expected %08x", name, uop.imm, exp_imm); fails++;
    end else if (exp_simple && uop.w16 !== 1'b1) begin
      $display("FAIL %-22s w16=%0d expected 1", name, uop.w16); fails++;
    end else $display("ok   %-22s len=%0d imm=%08x w16=%0d", name, uop.len, uop.imm, uop.w16);
  endtask
  // task #56: assert the DESTINATION INDEX and write-enable too. The VEN_D16_NOWREG bisect showed
  // the defect is in the register-write path, and dst/wreg were never checked -- only len/imm/w16.
  task automatic chk_dst(string name, int exp_dst, logic exp_wreg);
    #1; checks_d++;
    if (uop.wreg !== exp_wreg) begin
      $display("FAIL %-22s wreg=%0d expected %0d", name, uop.wreg, exp_wreg); fails++;
    end else if (exp_wreg && uop.dst !== exp_dst[2:0]) begin
      $display("FAIL %-22s dst=%0d expected %0d", name, uop.dst, exp_dst); fails++;
    end else $display("ok   %-22s dst=%0d wreg=%0d", name, uop.dst, uop.wreg);
  endtask
  int checks_d = 0;
  initial begin
    // The decoder's seventh input is inactive for every 16-bit-default form,
    // but drive it deterministically so this operand-size fence cannot mask an
    // accidental future dependence on an uninitialised byte.
    b[6] = 8'd0;
    // MOV AX,imm16      B8 34 12          -> len 3, imm 0x1234
    b[0]=8'hB8; b[1]=8'h34; b[2]=8'h12; b[3]=0; b[4]=0; b[5]=0;
    chk("MOV AX,imm16", 3, 1'b1, 32'h1234);
    // ADD AX,imm16      05 78 56          -> len 3, imm 0x5678
    b[0]=8'h05; b[1]=8'h78; b[2]=8'h56;
    chk("ADD AX,imm16", 3, 1'b1, 32'h5678);
    // TEST AX,imm16     A9 CD AB          -> len 3, imm 0xABCD
    b[0]=8'hA9; b[1]=8'hCD; b[2]=8'hAB;
    chk("TEST AX,imm16", 3, 1'b1, 32'hABCD);
    // ADD BX,imm16      81 C3 21 43       -> len 4, imm 0x4321   (modrm C3 = reg form, /0=ADD)
    b[0]=8'h81; b[1]=8'hC3; b[2]=8'h21; b[3]=8'h43;
    chk("ADD BX,imm16 (81)", 4, 1'b1, 32'h4321);
    // MOV BX,imm16      C7 C3 EF BE       -> len 4, imm 0xBEEF
    b[0]=8'hC7; b[1]=8'hC3; b[2]=8'hEF; b[3]=8'hBE;
    chk("MOV BX,imm16 (C7)", 4, 1'b1, 32'hBEEF);
    // JMP rel16         E9 05 00          -> len 3
    b[0]=8'hE9; b[1]=8'h05; b[2]=8'h00; b[3]=0;
    chk("JMP rel16", 3, 1'b1, -1);
    // MOV AX,BX         8B C3             -> len 2 (reg form)
    b[0]=8'h8B; b[1]=8'hC3; b[2]=0;
    chk("MOV AX,BX (8B reg)", 2, 1'b1, -1);
    // MOV AX,[BX]       8B 07  -> 16-bit modrm DIFFERS; must be REJECTED (step E deferred)
    b[0]=8'h8B; b[1]=8'h07;
    chk("MOV AX,[BX] rejected", 0, 1'b0, -1);
    // ---- extended coverage (task #60): forms the first pass did not test ----------
    // INC AX / DEC AX (40+r / 48+r): ONE byte in both 16- and 32-bit; width is the only difference
    b[0]=8'h40; b[1]=0; b[2]=0; b[3]=0;
    chk("INC AX (40+r)", 1, 1'b1, -1);
    b[0]=8'h48;
    chk("DEC AX (48+r)", 1, 1'b1, -1);
    // ADD BX,imm8 sign-extended (83 /0 ib): len 3 in BOTH sizes -- size-INDEPENDENT, must not move
    b[0]=8'h83; b[1]=8'hC3; b[2]=8'h05; b[3]=0;
    chk("ADD BX,imm8 (83)", 3, 1'b1, 32'h5);
    // Jcc rel16 (0F 8x cw): len 4 in 16-bit (vs 6 in 32-bit)
    b[0]=8'h0F; b[1]=8'h84; b[2]=8'h10; b[3]=8'h00; b[4]=0; b[5]=0;
    chk("JZ rel16 (0F 84)", 4, 1'b1, -1);
    // SHL BX,imm8 (C1 /4 ib): len 3 in both sizes; the WIDTH is what matters (step I)
    b[0]=8'hC1; b[1]=8'hE3; b[2]=8'h04; b[3]=0;
    chk("SHL BX,imm8 (C1)", 3, 1'b1, -1);
    // SHL BX,1 (D1 /4): len 2 both sizes
    b[0]=8'hD1; b[1]=8'hE3; b[2]=0;
    chk("SHL BX,1 (D1)", 2, 1'b1, -1);
    // MOV r/m16,r16 reg form (89 /r): len 2
    b[0]=8'h89; b[1]=8'hD8; b[2]=0;
    chk("MOV AX,BX (89 reg)", 2, 1'b1, -1);
    // XOR AX,AX (31 /r reg form): len 2 -- the single most common BIOS idiom
    b[0]=8'h31; b[1]=8'hC0; b[2]=0;
    chk("XOR AX,AX (31 reg)", 2, 1'b1, -1);
    // ---- destination-index checks (x86 reg order: AX CX DX BX SP BP SI DI) ----
    b[0]=8'hB8; b[1]=8'h34; b[2]=8'h12; b[3]=0;  chk_dst("MOV AX,imm16 dst", 0, 1'b1);
    b[0]=8'hBB; b[1]=8'h34; b[2]=8'h12;          chk_dst("MOV BX,imm16 dst", 3, 1'b1);
    b[0]=8'h40;                                   chk_dst("INC AX dst",       0, 1'b1);
    b[0]=8'h43;                                   chk_dst("INC BX dst",       3, 1'b1);
    b[0]=8'h8B; b[1]=8'hC3;                       chk_dst("MOV AX,BX dst",    0, 1'b1);
    b[0]=8'h89; b[1]=8'hD8;                       chk_dst("MOV AX,BX(89) dst",0, 1'b1);
    b[0]=8'h31; b[1]=8'hC0;                       chk_dst("XOR AX,AX dst",    0, 1'b1);
    b[0]=8'h39; b[1]=8'hD8;                       chk_dst("CMP AX,BX no-wreg",0, 1'b0);
    $display("\n%s  (%0d failure(s))", fails==0 ? "DECODE16: PASS" : "DECODE16: FAIL", fails);
    $finish;
  end
endmodule
