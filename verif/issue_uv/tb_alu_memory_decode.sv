`timescale 1ns/1ps
// Metamorphic descriptor check: all admitted register-destination ALU forms
// reuse ADD's exact addressing/dependency packet, changing only ALU selection
// and ADC/SBB's U-only pairing class. This is not an arithmetic oracle.
module tb_alu_memory_decode;
  import ventium_decode_pkg::*;
  logic [55:0] bytes_q;
  logic def16, cycle_mode;
  fpd_t packet;
  int checks=0, memory_checks=0, seven_checks=0;
  decode dut(.ib0(bytes_q[7:0]), .ib1(bytes_q[15:8]), .ib2(bytes_q[23:16]),
      .ib3(bytes_q[31:24]), .ib4(bytes_q[39:32]), .ib5(bytes_q[47:40]),
      .ib6(bytes_q[55:48]), .iflags(32'h203), .def16, .cycle_mode, .uop(packet));
  initial begin
    fpd_t base, expected;
    for(int mode=0;mode<4;mode++) begin
      def16=1'(mode>>1); cycle_mode=1'(mode);
      for(int modrm=0;modrm<256;modrm++) begin
        for(int sib=0;sib<256;sib++) begin
          bytes_q={32'h87654321,8'(sib),8'(modrm),8'h03};
          #1; base=packet;
          for(int op=0;op<7;op++) begin
            bytes_q[7:0]=8'(3+8*op);
            expected=base;
            if(base.simple) begin
              expected.alu_op=5'(op);
              expected.pairs_second=!(op==2 || op==3);
            end
            #1; checks++;
            if(packet!==expected)
              $fatal(1,"ALU packet mismatch op=%02x modrm=%02x sib=%02x mode=%0d",bytes_q[7:0],modrm,sib,mode);
            if(packet.simple && packet.is_mem) begin
              memory_checks++;
              if(packet.len==7) seven_checks++;
              if(packet.is_store || packet.is_load || packet.mem_lhs ||
                 !packet.wreg || !packet.wflags || packet.dst==3'd4 || def16)
                $fatal(1,"unsafe checked ALU descriptor");
            end
          end
        end
      end
    end
    if(memory_checks==0 || seven_checks==0) $fatal(1,"missing memory coverage");
    $display("ALU-MEMORY-DECODE-OK checks=%0d memory=%0d seven=%0d",checks,memory_checks,seven_checks);
    $finish;
  end
endmodule
