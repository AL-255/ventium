#!/usr/bin/env python3
"""Bounded shared-production-include/reference decoder, datapath and D1 leaf."""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(tempfile.mkdtemp(prefix="ventium-prefix66-leaf-", dir="/tmp"))
core = (ROOT / "rtl/core/core.sv").read_text()
decoder = (ROOT / "rtl/core/decode_stages.sv").read_text()
ports = re.findall(r"output\s+(logic|\w+_e)\s*(\[[^\]]+\])?\s+(\w+)",
                   decoder.split(");", 1)[0])
assert len(ports) > 100
sys_enum = re.search(r"typedef enum logic \[4:0\] \{.*?\} sysop_e;", core, re.S).group(0)
merge = re.search(r"function automatic logic \[31:0\] reg_merge\(.*?endfunction",
                  core, re.S).group(0)
decl = "\n".join(f"  {typ} {width or ''} {name};" for typ, width, name in ports)
conn = ",\n".join(f"    .{name}({name})" for _, _, name in ports)
reference = merge + '\n' + decl + "\n  decode_stages reference(.ibuf(refbytes),.gpr(gpr_o),.eflags,\n" + \
    "    .sys_mode,.def16,.seg_real(1'b0),.smm_active,.paging_on,.cosim_en,.soc_en,\n" + conn + ");\n"
# Test the actual core's prefix-specific qualification as well as issue_uv.
# In particular issue_uv's legacy implicit-stack ESP exception is not valid
# for two explicit PREFIX66 register writes. Do not copy a proposed helper.
pair_expr = core.split('    pipe_pair = cycle_mode', 1)[1].split(';', 1)[0]
prefix_pair_expr = pair_expr.split('`ifdef VEN_P54_PREFIX66_REG', 1)[1].split('`endif', 1)[0].strip()
assert prefix_pair_expr.startswith('&& ')
reference += "\n  logic prefix_pair_qualified;\n  assign prefix_pair_qualified=pair_ok && " + prefix_pair_expr[3:] + ";\n"
(OUT / "p54_prefix66_reference_ports.svh").write_text(reference)
(OUT / "tb_p54_prefix66.sv").write_text(sys_enum + '\n`include "tb_p54_prefix66_body.svh"\n')
rtl = ROOT / "rtl"
command = ["timeout", "--signal=TERM", "--kill-after=10s", "240s",
           str(ROOT / "tools/verilator_serial.sh"), "--binary", "--timing", "--assert",
           "-sv", "-Wall", "-Wno-UNUSED", "-Wno-fatal", "-Werror-IMPLICIT",
           "-Werror-PINMISSING", "-Werror-UNDRIVEN", "-Werror-MULTIDRIVEN",
           "-Werror-LATCH", "-Werror-UNOPTFLAT", "+define+VTM_NO_DPI",
           "+define+VEN_L1_AXI", "+define+VEN_P54_PREFIX66_REG",
           "+define+VEN_FAST_BYTE_ALU", "+define+VEN_FAST_UNARY_R",
           "+define+VEN_FAST_BYTE_SHIFT", "+define+VEN_P54_AGI_WRITE_MASK",
           "-I" + str(rtl / "core"), "-I" + str(ROOT / "verif/issue_uv"),
           "-I" + str(OUT), "--top-module", "tb_p54_prefix66",
           "--Mdir", str(OUT / "obj"), str(rtl / "ventium_pkg.sv"),
           str(rtl / "core/ventium_alu_pkg.sv"), str(rtl / "core/ventium_decode_pkg.sv"),
           str(rtl / "fpu/fpu_x87_pkg.sv"), str(rtl / "core/ventium_sys_pkg.sv"),
           str(rtl / "core/ventium_x87_pkg.sv"), str(OUT / "tb_p54_prefix66.sv"),
           str(rtl / "core/decode_stages.sv"), str(rtl / "core/decode.sv"),
           str(rtl / "core/u_pipe.sv"), str(rtl / "core/issue_uv.sv")]
print(f"Artifacts: {OUT}", flush=True)
with (OUT / "build.log").open("w") as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode:
    print("\n".join((OUT / "build.log").read_text().splitlines()[-70:]))
    raise SystemExit(result.returncode)
subprocess.run(["timeout", "--signal=TERM", "--kill-after=10s", "45s",
                str(OUT / "obj/Vtb_p54_prefix66")], check=True)
