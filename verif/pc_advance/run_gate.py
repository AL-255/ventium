#!/usr/bin/env python3
"""Check the ACTUAL core fast-PC expressions; not a whole-core or FPGA gate.

Requires Icarus Verilog and Z3. Pass a fresh output directory under the scratch
filesystem, e.g. python3 verif/pc_advance/run_gate.py --out "$TMPDIR/pc-advance".
No production source is generated or modified by this gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BEGIN = '// PC_ADVANCE_ARITH_BEGIN (also exercised by verif/pc_advance)'
END = '// PC_ADVANCE_ARITH_END'
PROVED_BODY_SHA = '4249d7266f7c654121595abcefde2703a1c7261232ec97b4f4445d5ad12620ee'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    out = args.out.resolve()
    assert not out.exists() and out.parent.is_dir(), 'fresh output under an existing scratch parent required'
    assert shutil.disk_usage(out.parent).free > 16 * 1024**2
    source = ROOT / 'rtl/core/core_fastpath.svh'
    before = source.read_bytes()
    text = before.decode()
    assert text.count(BEGIN) == text.count(END) == 1
    body = text.split(BEGIN)[1].split(END)[0]
    body_sha = hashlib.sha256(re.sub(r'\s+', '', body).encode()).hexdigest()
    assert body_sha == PROVED_BODY_SHA, 'production arithmetic changed: re-audit the SMT mapping'
    for declaration in ('logic [4:0] uv_advance_len;', 'logic [31:0] u_advance_raw, uv_advance_raw;'):
        assert re.sub(r'\s+', '', declaration) in re.sub(r'\s+', '', text)
    out.mkdir()
    dut = '''`timescale 1ns/1ps
module pc_advance_dut(input logic [31:0] pc, input logic [3:0] ulen,vlen,
  input logic paired,code16, output logic [31:0] eip_nx,post_eip);
  typedef struct packed {logic [3:0] len;} desc_t;
  desc_t pipe_u_eff,pipe_v_eff;
  logic [31:0] pipe_commit_eip;
  logic do_v;
  logic [4:0] uv_advance_len;
  logic [31:0] u_advance_raw,uv_advance_raw;
  function automatic logic fp_code16(input desc_t d);
    fp_code16=code16;
  endfunction
  always_comb begin
    pipe_u_eff.len=ulen; pipe_v_eff.len=vlen;
    pipe_commit_eip=pc; do_v=paired;
''' + body + '\n  end\nendmodule\n'
    (out / 'pc_advance_dut.sv').write_text(dut)
    env = dict(os.environ, TMPDIR=str(out))

    def run(name, argv):
        p = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=30)
        (out / (name + '.log')).write_text(p.stdout + p.stderr)
        (out / (name + '.exit')).write_text(str(p.returncode) + '\n')
        assert p.returncode == 0, (name, p.stdout, p.stderr)
        return p.stdout

    run('compile', ['iverilog', '-g2012', '-s', 'tb_pc_advance', '-o', str(out/'tb'),
                    str(out/'pc_advance_dut.sv'), str(HERE/'tb_pc_advance.sv')])
    sim = run('simulation', ['vvp', str(out/'tb')])
    assert 'PC-ADVANCE-RTL-OK checks=73728' in sim
    proof = run('proof', ['z3', '-smt2', str(HERE/'equivalence.smt2')])
    assert proof.splitlines() == ['sat', 'unsat', 'sat', 'unsat'], proof
    assert source.read_bytes() == before, 'source changed during gate'
    result = dict(result='PC-ADVANCE-GATE-OK', tests=73728, full_width_equivalence=True,
                  source_sha256=hashlib.sha256(before).hexdigest(), arithmetic_body_sha256=body_sha,
                  whole_core_verified=False, hardware_verified=False, gameplay_ipc=None)
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
