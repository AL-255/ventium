`timescale 1ns/1ps
`default_nettype none
module tb_classifier;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_decode_pkg::*;
  logic [79:0] a, sti, mem;
  logic [15:0] status;
  logic [3:0] bytes;
  fxop_e op;
  wire [15:0] old_status, new_status;
  wire [79:0] old_b, new_b;
  old_compare old_dut(a,sti,mem,status,bytes,op,old_status,old_b);
  new_compare new_dut(a,sti,mem,status,bytes,op,new_status,new_b);
  int checks=0;
  int memory_nan_checks=0, quiet_nan_checks=0, finite_int_checks=0;
  function automatic logic [79:0] special(input int n);
    case (n&15)
      0: return 80'h00000000000000000000;
      1: return 80'h80000000000000000000;
      2: return 80'h7fff8000000000000000;
      3: return 80'hffff8000000000000000;
      4: return 80'h7fffc000000000000000;
      5: return 80'h7fff8000000000000001;
      6: return 80'hffffa000000000000000;
      7: return 80'h7fff0000000000000000;
      8: return 80'h00008000000000000000;
      9: return 80'h00000000000000000001;
      10: return 80'h3fff0000000000000000;
      11: return 80'h3fff8000000000000000;
      12: return 80'hbfff8000000000000000;
      default: return {16'($urandom),$urandom,$urandom};
    endcase
  endfunction
  task automatic check;
    #1;
    if (old_status !== new_status || old_b !== new_b)
      $fatal(1,"FP-COMPARE-MISMATCH op=%0d bytes=%0d a=%h sti=%h mem=%h sw=%h old=%h new=%h",
          op,bytes,a,sti,mem,status,old_status,new_status);
    checks++;
    if ((op inside {FX_FICOM_M16,FX_FICOM_M32}) && !fx_is_nan(a))
      finite_int_checks++;
    if ((op inside {FX_FUCOM_STI,FX_FUCOMPP}) && fx_is_nan(sti) && !fx_is_snan(sti))
      quiet_nan_checks++;
    if ((op inside {FX_FCOM_M32,FX_FCOM_M64}) && fx_is_nan(old_b))
      memory_nan_checks++;
  endtask
  initial begin
    fxop_e ops[16]='{FX_FCOM_M32,FX_FCOM_M64,FX_FICOM_M16,FX_FICOM_M32,
      FX_FCOM_STI,FX_FUCOM_STI,FX_FCOMPP,FX_FUCOMPP,FX_FTST,FX_FXAM,
      FX_FLD_M32,FX_FLD_M64,FX_FLD_M80,FX_NONE,FX_FNSTSW_AX,FX_AR_ST0_STI};
    // Exhaustive signed-16 inputs, both signs/zero/most-negative included.
    for (int n=0;n<65536;n++) begin
      op=FX_FICOM_M16; bytes=2; a=special(n); sti=special(n+3);
      mem={16'($urandom),$urandom,16'($urandom),16'(n)};
      status=16'($urandom); check();
    end
    // Every exponent, both signs, zero and each one-hot fraction bit. This
    // forces infinities, quiet/signaling NaNs and all normalization ranges.
    for (int width=0;width<2;width++) begin
      for (int ex=0;ex<(width ? 2048 : 256);ex++) begin
        for (int bitpos=-1;bitpos<(width ? 52 : 23);bitpos++) begin
          for (int signbit=0;signbit<2;signbit++) begin
            op=width ? FX_FCOM_M64 : FX_FCOM_M32; bytes=width ? 8 : 4;
            mem={16'($urandom),$urandom,$urandom};
            if (width) mem[63:0]={1'(signbit),11'(ex),52'(bitpos<0 ? 0 : (64'd1<<bitpos))};
            else mem[31:0]={1'(signbit),8'(ex),23'(bitpos<0 ? 0 : (64'd1<<bitpos))};
            a=special(bitpos+1); sti=special(ex); status=16'($urandom); check();
          end
        end
      end
    end
    // Also test mismatched/unused byte counts. The old helper has a defined
    // m80/default path; an opcode-name shortcut must not silently drop it.
    for (int oi=0;oi<16;oi++) begin
      for (int size=0;size<16;size++) begin
        for (int n=0;n<512;n++) begin
          op=ops[oi]; bytes=4'(size); a=special(n); sti=special(n>>4);
          mem=special(n+7); status=16'($urandom); check();
        end
      end
    end
    if (memory_nan_checks==0 || quiet_nan_checks==0 || finite_int_checks==0)
      $fatal(1,"FP-COMPARE-VACUOUS");
    $display("FP-COMPARE-OK checks=%0d memory_nan=%0d quiet_nan=%0d finite_integer=%0d",
        checks,memory_nan_checks,quiet_nan_checks,finite_int_checks);
    $finish;
  end
  initial begin #2000000; $fatal(1,"FP-COMPARE-TIMEOUT"); end
endmodule
`default_nettype wire
