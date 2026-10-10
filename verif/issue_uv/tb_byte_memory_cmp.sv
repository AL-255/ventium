`timescale 1ns/1ps
module tb_byte_memory_cmp;
  import ventium_decode_pkg::*;
  logic [55:0] bytes_q;
  logic def16=0,cycle_mode=1;
  logic [31:0] iflags=32'h202,operand=0;
  fpd_t actual,old,wide;
  logic [31:0] alu,flags,sh,shm1;
  logic shcf;
  logic [4:0] shcnt;
  int checks=0,memory_checks=0,alu_checks=0;
  decode dut(.ib0(bytes_q[7:0]),.ib1(bytes_q[15:8]),.ib2(bytes_q[23:16]),
      .ib3(bytes_q[31:24]),.ib4(bytes_q[39:32]),.ib5(bytes_q[47:40]),
      .ib6(bytes_q[55:48]),.iflags,.def16,.cycle_mode,.uop(actual));
  decode_control orig(.ib0(bytes_q[7:0]),.ib1(bytes_q[15:8]),.ib2(bytes_q[23:16]),
      .ib3(bytes_q[31:24]),.ib4(bytes_q[39:32]),.ib5(bytes_q[47:40]),
      .ib6(bytes_q[55:48]),.iflags,.def16,.cycle_mode,.uop(old));
  decode_control grammar(.ib0(8'h83),.ib1(bytes_q[15:8]),.ib2(bytes_q[23:16]),
      .ib3(bytes_q[31:24]),.ib4(bytes_q[39:32]),.ib5(bytes_q[47:40]),
      .ib6(bytes_q[55:48]),.iflags,.def16,.cycle_mode,.uop(wide));
  u_pipe arithmetic(.u_d(actual),.u_dst_val(operand),.u_src_val(32'habadcafe),
      .eflags(iflags),.u_alu(alu),.u_flags(flags),.u_sh(sh),.u_shm1(shm1),
      .u_shcf(shcf),.u_shcnt(shcnt));
`ifdef VEN_FAST_BYTE_MEM_CMP
  localparam bit EXPECT_NEW=1;
`elsif BC_REQUIRE_NEW_BEHAVIOR
  localparam bit EXPECT_NEW=1;
`else
  localparam bit EXPECT_NEW=0;
`endif
  initial begin
    fpd_t expected;
    logic [7:0] difference;
    logic [31:0] expected_flags;
    // Actual old 83 decoder supplies the unchanged address/segment/pair
    // grammar; old 80 supplies exact register/high-byte/default behavior.
    for(int mode=0;mode<4;mode++)
      for(int modrm=0;modrm<256;modrm++)
        for(int sib=0;sib<256;sib++)
          for(int tail=0;tail<4;tail++) begin
            def16=1'(mode>>1);cycle_mode=1'(mode);
            bytes_q={32'(32'h87654321^(32'hffffffff>>tail)),8'(sib),8'(modrm),8'h80};
            #1;expected=old;
            if(EXPECT_NEW && modrm<192 && wide.simple) begin
              expected=wide;expected.w8=1;expected.imm={24'd0,wide.imm[7:0]};
            end
            if(actual!==expected)
              $fatal(1,"BYTE-MEM-CMP-DECODE mode=%0d modrm=%x sib=%x",mode,modrm,sib);
            checks++;
            if(actual.simple && actual.is_mem) begin
              memory_checks++;
              if(def16 || modrm[5:3]!=3'd7 || actual.is_store || actual.is_load ||
                 actual.wreg || actual.writes!=0 || !actual.mem_lhs || !actual.wflags ||
                 !actual.w8 || !actual.use_imm || actual.pairs_second)
                $fatal(1,"unsafe byte memory CMP descriptor");
            end
          end
    // Unrelated opcode packets remain identical, including all prefixes,
    // all ModR/M bytes, both modes and representative SIB/tail patterns.
    for(int mode=0;mode<4;mode++)
      for(int opcode=0;opcode<256;opcode++)
        for(int modrm=0;modrm<256;modrm++) begin
          def16=1'(mode>>1);cycle_mode=1'(mode);
          bytes_q={32'h88776655,8'(modrm^8'h55),8'(modrm),8'(opcode)};
          #1;
          if(opcode!=128 && actual!==old)$fatal(1,"unrelated decode changed");
          checks++;
        end
    if(EXPECT_NEW) begin
      if(memory_checks==0)$fatal(1,"missing new memory decode coverage");
      def16=0;cycle_mode=1;
      // Every byte subtraction and all defined arithmetic flags, preserving
      // unrelated flags. This oracle does not use the production ALU helpers.
      for(int a=0;a<256;a++) for(int b=0;b<256;b++) begin
        bytes_q={32'hbaddcafe,8'(b),8'h38,8'h80};
        operand=32'hfedcba00|32'(a);iflags=32'h00240ed7;
        difference=8'(a-b);expected_flags=iflags;
        expected_flags[0]=(a<b);
        expected_flags[2]=~^difference;
        expected_flags[4]=1'((a^b^32'(difference))>>4);
        expected_flags[6]=(difference==0);
        expected_flags[7]=difference[7];
        expected_flags[11]=1'(((a^b)&(a^32'(difference)))>>7);
        #1;
        if(flags!==expected_flags || alu[7:0]!==difference)
          $fatal(1,"byte CMP arithmetic a=%x b=%x got=%x expected=%x",a,b,flags,expected_flags);
        alu_checks++;
      end
    end else if(memory_checks!=0)$fatal(1,"disabled proposal admitted byte memory");
    $display("BYTE-MEM-CMP-OK checks=%0d memory=%0d arithmetic=%0d",checks,memory_checks,alu_checks);
    $finish;
  end
endmodule
