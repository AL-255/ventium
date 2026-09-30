#!/usr/bin/env python3
"""Check the production opcode69 decoder across prefix/address/operand sizes.

The generated interface follows the existing short-dispatch leaf flow: actual
decoder port declarations and core sysop enum are extracted, not duplicated.
All generated sources/builds live in one named /tmp directory.
"""
import os
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
guard = ROOT / 'tools/build_scope.sh'
# Only preserve the reviewed shared lock, never arbitrary caller descriptors.
# An outside-scope invocation legitimately has no FD9 yet. Inside the scope,
# closing that descriptor in the probe falsely reports inactive and recurses.
try:
    lock_fds = (9,) if os.readlink('/proc/self/fd/9') == '/tmp/ventium-heavy-build.lock' else ()
except OSError:
    lock_fds = ()
if subprocess.run([str(guard), '--is-active'], check=False, pass_fds=lock_fds).returncode:
    os.execv(str(guard), [str(guard), '--', 'python3', __file__])
OUT = pathlib.Path(tempfile.mkdtemp(prefix='ventium-imul69-decode-', dir='/tmp'))
decoder = (ROOT / 'rtl/core/decode_stages.sv').read_text()
core = (ROOT / 'rtl/core/core.sv').read_text()
ports = re.findall(r'output\s+(logic|\w+_e)\s*(\[[^\]]+\])?\s+(\w+)', decoder.split(');', 1)[0])
assert len(ports) > 100
sys_enum = re.search(r'typedef enum logic \[4:0\] \{.*?\} sysop_e;', core, re.S).group(0)
source = r'''`timescale 1ns/1ps
@SYS_ENUM@
module tb_imul69_decode;
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;
  logic [7:0] ibuf[16];
  logic [31:0] gpr[NUM_GPR];
  logic def16=0;
  @PORTS@
  decode_stages dut(.ibuf,.gpr,.eflags(32'h202),.sys_mode(1'b0),.def16,
      .seg_real(1'b0),.smm_active(1'b0),.paging_on(1'b0),.cosim_en(1'b0),.soc_en(1'b0),
      @CONNECTIONS@);
  int checks=0;
  initial begin
    for(int r=0;r<NUM_GPR;r++) gpr[r]=32'h76540000+32'(r*3);
    for(int default16=0;default16<2;default16++) begin
      def16=1'(default16);
      for(int operand16=0;operand16<2;operand16++) begin
        for(int address16=0;address16<2;address16++) begin
          for(int shape=0;shape<6;shape++) begin
            for(int sign=0;sign<2;sign++) begin
              int off,modrm_index,imm_index,extent;
              logic [31:0] expected_imm;
              logic [7:0] modrm;
              for(int i=0;i<16;i++) ibuf[i]=8'hd7;
              off=0;
              if(operand16!=default16) begin ibuf[off]=8'h66;off++;end
              if(address16!=default16) begin ibuf[off]=8'h67;off++;end
              ibuf[off]=8'h69;off++;modrm_index=off;
              // Independent ModR/M/SIB extent: reg, base, literal,disp8,disp16/32,SIB.
              case(shape)
                0:begin modrm=8'hd3;extent=1;end // DX <- BX
                1:begin modrm=8'h16;extent=address16?3:1;end // rm6 literal16 or ESI
                2:begin modrm=8'h15;extent=address16?1:5;end // rm5 DI or literal32
                3:begin modrm=8'h56;extent=2;end
                4:begin modrm=8'h96;extent=address16?3:5;end
                default:begin modrm=8'h54;extent=address16?2:3;end
              endcase
              ibuf[off]=modrm;
              for(int i=1;i<extent;i++) ibuf[off+i]=8'(i*7);
              if(shape==5 && !address16) ibuf[off+1]=8'h5e;
              imm_index=modrm_index+extent;
              ibuf[imm_index]=8'h34;ibuf[imm_index+1]=sign?8'h92:8'h12;
              if(operand16) begin
                ibuf[imm_index+2]=8'h90;ibuf[imm_index+3]=8'h47;
                expected_imm=sign?32'hffff9234:32'h00001234;
              end else begin
                ibuf[imm_index+2]=8'had;ibuf[imm_index+3]=8'hbc;
                expected_imm=sign?32'hbcad9234:32'hbcad1234;
              end
              #1;
              if(d_kind!=K_IMUL2 || !d_imul_3op || d_unknown ||
                  !d_writes_reg || !d_writes_flags || d_dst_reg!=2 ||
                  d_w!=(operand16?3'd2:3'd4) ||
                  d_len!=4'(imm_index+(operand16?2:4)) ||
                  d_imul_imm!=expected_imm ||
                  d_mem_read!=(shape!=0) || d_mem_write)
                $fatal(1,"IMUL69 default%0d op16%0d addr16%0d shape%0d sign%0d len%0d imm%08x",
                    default16,operand16,address16,shape,sign,d_len,d_imul_imm);
              checks++;
              // A next-instruction suffix cannot affect a word immediate/length.
              if(operand16) begin
                ibuf[imm_index+2]^=8'hff;ibuf[imm_index+3]^=8'hff;#1;
                if(d_len!=4'(imm_index+2) || d_imul_imm!=expected_imm)
                  $fatal(1,"IMUL69 consumed next instruction bytes");
                checks++;
              end
            end
          end
        end
      end
    end
    $display("IMUL69-DECODE-OK checks=%0d",checks);$finish;
  end
endmodule
'''
source = source.replace('@SYS_ENUM@', sys_enum).replace('@PORTS@', '\n'.join(
    f'{typ} {width or ""} {name};' for typ, width, name in ports)).replace(
    '@CONNECTIONS@', ',\n'.join(f'.{name}({name})' for _, _, name in ports))
tb = OUT / 'tb_imul69_decode.sv'
tb.write_text(source)
rtl = ROOT / 'rtl'
command = [str(ROOT / 'tools/verilator_serial.sh'), '--binary', '--timing', '--assert',
           '-j', '1', '-sv', '-Wall', '-Wno-UNUSED', '-Wno-fatal', '-Wno-TIMESCALEMOD',
           '-Werror-IMPLICIT', '-Werror-PINMISSING', '-Werror-UNDRIVEN',
           '-Werror-MULTIDRIVEN', '-Werror-LATCH', '-Werror-UNOPTFLAT', '+define+VTM_NO_DPI',
           '--top-module', 'tb_imul69_decode', '-Mdir', str(OUT / 'obj'),
           str(rtl / 'ventium_pkg.sv'), str(rtl / 'core/ventium_alu_pkg.sv'),
           str(rtl / 'core/ventium_decode_pkg.sv'), str(rtl / 'fpu/fpu_x87_pkg.sv'),
           str(rtl / 'core/ventium_x87_pkg.sv'), str(rtl / 'core/ventium_sys_pkg.sv'),
           str(tb), str(rtl / 'core/decode_stages.sv')]
print(f'Artifacts: {OUT}', flush=True)
with (OUT / 'build.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, pass_fds=lock_fds)
if result.returncode:
    print((OUT / 'build.log').read_text()[-6000:])
    raise SystemExit(result.returncode)
with (OUT / 'run.log').open('w') as log:
    result = subprocess.run([str(OUT / 'obj/Vtb_imul69_decode')], stdout=log, stderr=subprocess.STDOUT)
print((OUT / 'run.log').read_text(), end='')
raise SystemExit(result.returncode)
