// Real U-pipe modules, identical descriptor and operand inputs, all outputs.
// Run the original and candidate in separate native processes. Icarus can
// delta-cycle livelock when both instances call the same package functions.
// Preserve every X/Z bit in the original's output file; do not normalize flags.
`timescale 1ns/1ps
module tb_u_alu_shared;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  fpd_t u;
  logic [31:0] a,b,flags;
  logic [31:0] result,out_flags,shifted,previous;
  logic carry;
  logic [4:0] count;
  logic [133:0] expected;
  integer golden;
  string golden_path;
  integer checks=0;
`ifdef U_ALU_REFERENCE
  u_pipe dut(
`else
  u_pipe_shared dut(
`endif
    .u_d(u),.u_dst_val(a),.u_src_val(b),.eflags(flags),
    .u_alu(result),.u_flags(out_flags),.u_sh(shifted),.u_shm1(previous),
    .u_shcf(carry),.u_shcnt(count));
  task automatic check;
    #1;checks++;
`ifdef U_ALU_REFERENCE
    $fdisplay(golden,"%b",{result,out_flags,shifted,previous,carry,count});
`else
    if($fscanf(golden,"%b",expected)!=1)
      $fatal(1,"U-ALU-REFERENCE-MISSING n=%0d",checks);
    if(expected !== {result,out_flags,shifted,previous,carry,count})
      $fatal(1,"U-ALU-SHARED-MISMATCH n=%0d op=%0d w8=%b w16=%b imm=%b a=%h b=%h flags=%h expected=%b actual=%b",
          checks,u.alu_op,u.w8,u.w16,u.use_imm,a,b,flags,expected,
          {result,out_flags,shifted,previous,carry,count});
`endif
  endtask
  initial begin
    logic [31:0] edges[0:7];
    if(!$value$plusargs("golden=%s",golden_path)) $fatal(1,"golden path required");
`ifdef U_ALU_REFERENCE
    golden=$fopen(golden_path,"w");
`else
    golden=$fopen(golden_path,"r");
`endif
    if(!golden) $fatal(1,"cannot open golden");
    edges[0]=0;edges[1]=1;edges[2]=32'h80ff7f01;edges[3]=32'h7fffffff;
    edges[4]=32'h80000000;edges[5]=32'hffffffff;edges[6]=32'h00008000;edges[7]=32'hffff7fff;
    u='0;
    for(int op=0;op<32;op++) for(int width=0;width<4;width++)
      for(int imm=0;imm<2;imm++) for(int cl=0;cl<2;cl++)
        for(int shift=0;shift<8;shift++) for(int cf=0;cf<2;cf++) for(int val=0;val<8;val++) begin
          u.alu_op=5'(op);u.w8=1'(width);u.w16=1'(width>>1);
          u.use_imm=1'(imm);u.imm=edges[(val+5)%8];u.shift_cl=1'(cl);
          u.shrot=3'(shift);u.shimm=5'(op);u.is_shift=1;u.is_mem=1'(val);
          a=edges[val];b=edges[(val+3)%8];flags=32'ha55a8cd4|32'(cf);
          check();
        end
    if(checks!=65536) $fatal(1,"coverage %0d",checks);
    // Four-state descriptor widths exercise the actual fp_operand_width
    // selector, not just a fabricated numeric-width helper argument.
    for(int op=0;op<32;op++) for(int which=0;which<4;which++) begin
      u.alu_op=5'(op);u.w8=0;u.w16=0;
      case(which)
        0:u.w8=1'bx;
        1:u.w16=1'bx;
        2:u.w8=1'bz;
        3:begin u.w8=1'bx;u.w16=1'bz;end
      endcase
      check();
    end
    if(checks!=65664) $fatal(1,"coverage %0d",checks);
`ifndef U_ALU_REFERENCE
    if($fscanf(golden,"%b",expected)==1) $fatal(1,"extra golden records");
`endif
    $fclose(golden);
    $display("U-ALU-SHARED-OK checks=%0d",checks);
    $finish;
  end
endmodule
