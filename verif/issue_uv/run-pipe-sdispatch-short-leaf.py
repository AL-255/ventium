#!/usr/bin/env python3
"""Prove admitted reference fields ignore omitted suffix; test actual RTL guards.

Generates a bounded decoder-only miter under /tmp. The admission predicates are
extracted from core.sv itself, not independently reimplemented in the test.
No full-core rebuild, persistent uop-cache, guest patch or saved state is used.
"""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(tempfile.mkdtemp(prefix="ventium-sdispatch-short-leaf-", dir="/tmp"))
core = (ROOT / "rtl/core/core.sv").read_text()
decoder = (ROOT / "rtl/core/decode_stages.sv").read_text()
ports = re.findall(r"output\s+(logic|\w+_e)\s*(\[[^\]]+\])?\s+(\w+)",
                   decoder.split(");", 1)[0])
assert len(ports) > 100, "decoder output contract changed"
start = core.index("  logic pipe_sdispatch_shape_ok;")
end = core.index("`else\n`ifdef VEN_PIPE_SDISPATCH_SHORT\n  initial", start)
guards = core[start:end]
sys_enum = re.search(r"typedef enum logic \[4:0\] \{.*?\} sysop_e;", core, re.S).group(0)
decl = "\n".join(f"  {typ} {width or ''} {name};" for typ, width, name in ports)
conn = ",\n".join(f"    .{name}({name})" for _, _, name in ports)
empty_conn = ",\n".join(f"    .{name}()" for _, _, name in ports)
# ModR/M.reg and the decoder's always-computed EA/segment scratch can inspect
# unused suffix on NOP/register forms. They are not architectural operands in
# those forms. All other exposed fields, including unused defaults, are checked.
checks = []
for _, _, name in ports:
    if name == "modrm_reg":
        continue
    when = "1'b1"
    if name in ("d_ea", "d_seg"):
        when = "(d_mem_read || d_mem_write || d_is_lea)"
    checks.append(f"    if ({when} && {name} !== padded.{name}) "
                  f'$fatal(1,"suffix changed {name} op=%02x modrm=%02x len=%0d",'
                  "refdecode_ibuf[0],refdecode_ibuf[1],d_len);")
source = r'''`timescale 1ns/1ps
@SYS_ENUM@
module tb_pipe_sdispatch_short;
  import ventium_pkg::*;
  import ventium_alu_pkg::*;
  import ventium_decode_pkg::*;
  import fpu_x87_pkg::*;
  import ventium_x87_pkg::*;
  import ventium_sys_pkg::*;
  logic [7:0] refdecode_ibuf[16], padded_ibuf[16];
  logic [31:0] gpr_o[NUM_GPR];
  logic [31:0] eflags=32'h202, flin=32'h08048011, eip=32'h08048011;
  logic [31:0] seg_limit[6];
  logic sys_mode=0, soc_en=0, cosim_en=0, def16=0, real_mode=0, v86=0;
  logic cycle_mode=1, exec_issue_ok=1, icsnp_v1=0, icsnp_v2=0, ic_snoop_valid=0;
  logic [8:0] agi_wr0=9'h100, agi_wr1=9'h100;
  localparam int S_PIPE=1;
  localparam int SG_CS=0;
  int state=S_PIPE;
  bit first_fresh=1, second_fresh=0;
  int admitted=0, memory_cases=0, prefixed=0, checked=0, boundary_checks=0;
  logic [31:0] random_q=32'h42ad7201;
  function automatic logic ic_buffered(input logic [31:0] addr);
    if (addr[31:5]==flin[31:5]) return first_fresh;
    if (addr[31:5]==(flin[31:5]+27'd1)) return second_fresh;
    return 1'b0;
  endfunction
@DECL@
  decode_stages original(.ibuf(refdecode_ibuf),.gpr(gpr_o),.eflags,
    .sys_mode,.def16,.seg_real(real_mode),.smm_active(1'b0),.paging_on(1'b0),
    .cosim_en,.soc_en,
@CONN@);
  decode_stages padded(.ibuf(padded_ibuf),.gpr(gpr_o),.eflags,
    .sys_mode,.def16,.seg_real(real_mode),.smm_active(1'b0),.paging_on(1'b0),
    .cosim_en,.soc_en,
@EMPTY_CONN@);
@GUARDS@
  task automatic next_random;
    random_q ^= random_q << 13;
    random_q ^= random_q >> 17;
    random_q ^= random_q << 5;
  endtask
  task automatic compare_suffix;
@CHECKS@
    checked++;
  endtask
  task automatic probe(input bit expected, input string name);
    #1;
    if (pipe_sdispatch_short_window_ok !== expected)
      $fatal(1,"short admission %s expected%0b got%0b len%0d",name,expected,
             pipe_sdispatch_short_window_ok,d_len);
    boundary_checks++;
  endtask
  initial begin
    for (int r=0;r<NUM_GPR;r++) gpr_o[r]=32'h76543210+32'(r*127);
    for (int s=0;s<6;s++) seg_limit[s]=32'hffffffff;
    for (int prefix=0;prefix<3;prefix++) begin
      for (int escape=0;escape<2;escape++) begin
        for (int opcode=0;opcode<256;opcode++) begin
          for (int modrm=0;modrm<256;modrm++) begin
            int off, span;
            for (int i=0;i<16;i++) begin
              next_random(); refdecode_ibuf[i]=random_q[7:0];
            end
            off=0;
            if (prefix!=0) begin
              refdecode_ibuf[off]=(prefix==1)?8'h66:8'h2e; off++;
            end
            if (escape!=0) begin refdecode_ibuf[off]=8'h0f; off++; end
            refdecode_ibuf[off]=8'(opcode);
            refdecode_ibuf[off+1]=8'(modrm);
            #1;
            if (pipe_sdispatch_short_window_ok) begin
              span=int'(d_len); admitted++;
              if (d_mem_read || d_mem_write) memory_cases++;
              if (prefix!=0) prefixed++;
              for (int i=0;i<16;i++)
                padded_ibuf[i]=(i<span)?refdecode_ibuf[i]:8'd0;
              #1; compare_suffix();
              // A second independently random suffix must preserve the SAME
              // meaning and positive extent. This checks stale-BRAM garbage,
              // not just a fortuitously zero suffix.
              for (int i=span;i<16;i++) begin
                next_random();refdecode_ibuf[i]=random_q[7:0];
              end
              #1; compare_suffix();
              if (!pipe_sdispatch_short_window_ok || int'(d_len)!=span)
                $fatal(1,"suffix manufactured or destroyed admission");
            end
          end
        end
      end
    end
    if (admitted<10000 || memory_cases<1000 || prefixed<1000)
      $fatal(1,"insufficient admitted coverage %0d/%0d/%0d",admitted,memory_cases,prefixed);
    // Fixed two-byte DIV, at the exact tiny-kernel offset17 overfetch case.
    for (int i=0;i<16;i++) refdecode_ibuf[i]=8'hff;
    refdecode_ibuf[0]=8'hf7;refdecode_ibuf[1]=8'hf3;
    probe(1,"DIV offset17, absent unrelated next line");
    first_fresh=0;probe(0,"stale tag/way or read collision");first_fresh=1;
    icsnp_v1=1;probe(0,"CPU SMC snoop1");icsnp_v1=0;
    icsnp_v2=1;probe(0,"CPU SMC snoop2");icsnp_v2=0;
    ic_snoop_valid=1;probe(0,"DMA SMC snoop");ic_snoop_valid=0;
    exec_issue_ok=0;probe(0,"executable flush");exec_issue_ok=1;
    state=0;probe(0,"nonissue state");state=S_PIPE;
    cycle_mode=0;probe(0,"functional mode");cycle_mode=1;
    def16=1;probe(0,"unsupported default width");def16=0;
    sys_mode=1;seg_limit[0]=eip;probe(0,"system/CS-limit path remains reference");sys_mode=0;
    soc_en=1;probe(0,"external event ownership");soc_en=0;
    flin=32'h0804801f;eip=flin;
    probe(0,"missing encoded cross-line suffix");
    second_fresh=1;probe(1,"fresh encoded cross-line suffix");
    flin=32'h08048fff;eip=flin;
    probe(0,"cross-page bytes retain universal fetch");
    flin=32'h08048011;eip=flin;second_fresh=0;
    refdecode_ibuf[0]=8'h66;refdecode_ibuf[1]=8'h2e;
    refdecode_ibuf[2]=8'hf7;refdecode_ibuf[3]=8'hf3;
    probe(0,"two ordinary prefixes retain extra decode clock");
    $display("PIPE-SDISPATCH-SHORT-LEAF-OK admitted=%0d memory=%0d prefixed=%0d suffix_checks=%0d boundary=%0d",
             admitted,memory_cases,prefixed,checked,boundary_checks);
    $finish;
  end
endmodule
'''
for key, value in {"DECL": decl, "CONN": conn, "EMPTY_CONN": empty_conn,
                   "GUARDS": guards, "CHECKS": "\n".join(checks),
                   "SYS_ENUM": sys_enum}.items():
    source = source.replace(f"@{key}@", value)
(OUT / "tb_pipe_sdispatch_short.sv").write_text(source)
rtl = ROOT / "rtl"
command = ["timeout", "--signal=TERM", "--kill-after=10s", "240s",
           str(ROOT / "tools/verilator_serial.sh"), "--binary", "--timing", "--assert",
           "-sv", "-Wall", "-Wno-UNUSED", "-Wno-fatal", "-Werror-IMPLICIT",
           "-Werror-PINMISSING", "-Werror-UNDRIVEN", "-Werror-MULTIDRIVEN",
           "-Werror-LATCH", "-Werror-UNOPTFLAT", "+define+VTM_NO_DPI",
           "+define+VEN_IC_BRAM", "+define+VEN_L1_AXI", "+define+VEN_PIPE_SDECODE",
           "+define+VEN_PIPE_SDISPATCH", "+define+VEN_PIPE_SDISPATCH_SHORT",
           "+define+VEN_P54_INT_EXEC_OCC", "--top-module", "tb_pipe_sdispatch_short",
           "--Mdir", str(OUT / "obj"), str(rtl / "ventium_pkg.sv"),
           str(rtl / "core/ventium_alu_pkg.sv"), str(rtl / "core/ventium_decode_pkg.sv"),
           str(rtl / "fpu/fpu_x87_pkg.sv"), str(rtl / "core/ventium_sys_pkg.sv"),
           str(rtl / "core/ventium_x87_pkg.sv"),
           str(OUT / "tb_pipe_sdispatch_short.sv"), str(rtl / "core/decode_stages.sv")]
print(f"Artifacts: {OUT}", flush=True)
with (OUT / "build.log").open("w") as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print("\n".join((OUT / "build.log").read_text().splitlines()[-60:]))
    raise SystemExit(result.returncode)
subprocess.run(["timeout", "--signal=TERM", "--kill-after=10s", "60s",
                str(OUT / "obj/Vtb_pipe_sdispatch_short")], check=True)
