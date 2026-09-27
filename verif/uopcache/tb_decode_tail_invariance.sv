`timescale 1ns/1ps
// A cached descriptor must depend only on its own instruction bytes. Increasing
// descriptor lifetime/capacity must not expose hidden trailing-byte dependencies.
module tb_decode_tail_invariance;
  import ventium_decode_pkg::*;
  logic [55:0] bytes_q;
  logic def16, cycle_mode;
  fpd_t packet;
  int checks=0, admitted=0;
  decode dut(.ib0(bytes_q[7:0]), .ib1(bytes_q[15:8]), .ib2(bytes_q[23:16]),
      .ib3(bytes_q[31:24]), .ib4(bytes_q[39:32]), .ib5(bytes_q[47:40]),
      .ib6(bytes_q[55:48]), .iflags(32'h203), .def16, .cycle_mode, .uop(packet));
  initial begin
    fpd_t saved;
    logic [55:0] original;
    for(int mode=0; mode<4; mode++) begin
      def16=1'(mode>>1); cycle_mode=1'(mode);
      for(int op=0; op<256; op++) begin
        for(int modrm=0; modrm<256; modrm++) begin
          for(int sample=0; sample<4; sample++) begin
            bytes_q={32'h87654321,8'(sample*85),8'(modrm),8'(op)};
            #1;
            if(packet.simple || packet.is_fp) begin
              admitted++;
              if(packet.len<1 || packet.len>7) $fatal(1,"invalid admitted length");
              saved=packet; original=bytes_q;
              for(int tail=int'(saved.len); tail<7; tail++) begin
                bytes_q=original;
                bytes_q[tail*8 +: 8]=~original[tail*8 +: 8];
                #1; checks++;
                if(packet!==saved)
                  $fatal(1,"trailing-byte dependency op=%02x modrm=%02x mode=%0d len=%0d byte=%0d original=%014x changed=%014x",
                         op,modrm,mode,saved.len,tail,original,bytes_q);
              end
            end
          end
        end
      end
    end
    if(admitted==0 || checks==0) $fatal(1,"empty invariance test");
    $display("DECODE-TAIL-INVARIANCE-OK admitted=%0d checks=%0d",admitted,checks);
    $finish;
  end
endmodule
