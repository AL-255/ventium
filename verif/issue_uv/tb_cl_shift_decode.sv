// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`timescale 1ns/1ps
module tb_cl_shift_decode;
  import ventium_decode_pkg::*;
  logic [7:0] opcode,modrm;
  logic def16,cycle_mode;
  fpd_t d;
  decode dut(.ib0(opcode),.ib1(modrm),.ib2(8'd3),.ib3(8'd0),.ib4(8'd0),
      .ib5(8'd0),.ib6(8'd0),.iflags(32'h202),.def16,.cycle_mode,.uop(d));
  int checks=0;
  initial begin
    for(int mode=0;mode<2;mode++) for(int width=0;width<2;width++) begin
      cycle_mode=1'(mode);def16=1'(width);
      for(int encoded=0;encoded<256;encoded++) begin
        opcode=8'hd3;modrm=8'(encoded);#1;
        if(!def16 && modrm[7:6]==2'b11 && modrm[5]) begin
`ifdef VEN_P54_INT_EXEC_OCC
          if(cycle_mode) begin
            if(d.simple) $fatal(1,"CL shift bypassed four-clock execute hold");
          end else
`endif
          if(!d.simple || !d.is_shift || !d.shift_cl || d.len!=2 ||
              d.dst!=modrm[2:0] || d.src!=1 || d.shrot!=modrm[5:3] ||
              !d.wreg || !d.wflags || d.pairs_first || d.pairs_second ||
              d.reads!=((8'h1<<modrm[2:0])|8'h2) || d.writes!=(8'h1<<modrm[2:0]))
            $fatal(1,"reference D3 descriptor changed");
        end else if(d.simple) $fatal(1,"new CL/memory/carry shape enabled");
        checks++;
        // Immediate and by-one siblings still have single-clock PU admission.
        if(modrm[7:6]==2'b11 && modrm[5]) begin
          opcode=8'hd1;#1;
          if(!d.simple || d.shift_cl || !d.pairs_first || d.pairs_second)
            $fatal(1,"by-one shift unexpectedly serialized");
          opcode=8'hc1;#1;
          if(!d.simple || d.shift_cl || !d.pairs_first || d.pairs_second)
            $fatal(1,"immediate shift unexpectedly serialized");
          checks+=2;
        end
      end
    end
    $display("CL-SHIFT-DECODE-OK checks=%0d",checks);$finish;
  end
endmodule
