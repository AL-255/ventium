#!/usr/bin/env python3
"""Full trans arithmetic and edge A/B, with an independent nonstubbed oracle."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='frozen whole-core source root')
    parser.add_argument('--compile-record', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True, help='prepared source experiment root')
    args = parser.parse_args()
    src, out = args.source.resolve(strict=True), args.out.resolve(strict=True)
    pins = json.loads((out/'candidate/inputs.json').read_text())
    assert all(sha(p)==h for p,h in pins.items())
    original = src/'fp_shared/ven_fp_trans.sv'
    assert str(original) in pins
    defs = sorted(set(re.findall(r'\+define\+(\w+)', args.compile_record.read_text().splitlines()[1])))
    assert {'VEN_FP_SHARED','VEN_SRT_ITER','VEN_FP_ARITH_FWD','VEN_FP_FXCH_QUEUE'} <= set(defs)
    oracle_script = REPO/'verif/fppipe/prepare-trans-oracle.py'
    spec = importlib.util.spec_from_file_location('oracle',oracle_script)
    oracle = importlib.util.module_from_spec(spec); spec.loader.exec_module(oracle)
    fixture = REPO/'fp_shared/tb/tb_ven_fp_trans.sv'
    oracle_sources = oracle.prepare(src,fixture,out/'oracle')
    text = oracle_sources[-1].read_text()
    text = oracle.replace_once(text, '  int checks;',
        '  int checks;\n  `include "shared_trans_miter.svh"')
    # Aborted commands are not arithmetic passes. They separately check that
    # reset/late-response edges remain identical, without forcing DUT state.
    text = oracle.replace_once(text,
        '    $display("VEN-FP-TRANS-A-B-OK checks=%0d", checks);', '''    for (int abort_at=1; abort_at<=144; abort_at++) begin
      @(negedge clk);
      rst_n = 1'b0;
      start = 1'b0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      op = (abort_at % 3 == 0) ? FX_FYL2X :
           (abort_at % 3 == 1) ? FX_FPATAN : FX_F2XM1;
      x = 80'h3ffeaaaaaaaaaaaaaaab;
      y = 80'h4000c000000000000000;
      rc = 2'(abort_at);
      start = 1'b1;
      @(negedge clk); start = 1'b0;
      repeat (abort_at) @(negedge clk);
      rst_n = 1'b0;
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      repeat (4) @(negedge clk);
      if (new_done || new_busy || dut_fx_req || dut_div_start)
        $fatal(1, "post-abort stale command at %0d", abort_at);
    end
    $display("TRANS-PACK-RESET-AB-OK aborts=144");
    $display("VEN-FP-TRANS-A-B-OK checks=%0d", checks);''')
    generated = out/'tb_ven_fp_trans.sv'
    generated.write_text(text)
    packages = [src/'rtl'/p for p in ('core/ventium_decode_pkg.sv','fpu/fpu_x87_pkg.sv',
                                     'core/ventium_x87_pkg.sv')]
    sources = [*packages, src/'rtl/fpu/fpu_srt_div.sv', src/'fp_shared/ven_fp_alu.sv',
        src/'fp_shared/ven_fp_estdiv.sv',src/'fp_shared/ven_fp_widemul.sv',
        out/'candidate/ven_fp_trans_control.sv',out/'candidate/ven_fp_trans.sv',
        *oracle_sources[:-1], *[src/'rtl/fpu'/n for n in
        ('fpu_fsincos.sv','fpu_f2xm1.sv','fpu_fyl2x.sv')],generated]
    inputs = [*sources, fixture, Path(__file__).resolve(),args.compile_record.resolve(),
        oracle_script,REPO/'verif/fppipe/shared_trans_miter.svh',REPO/'tools/build_scope.sh',
        *[src/'rtl/fpu'/n for n in ('fpu_fsincos_rom.svh','fpu_f2xm1_rom.svh',
                                    'fpu_fpatan_rom.svh','fpu_fyl2x_rom.svh')]]
    pins.update({str(p):sha(p) for p in inputs})
    env=dict(os.environ,TMPDIR=str(out),PYTHONDONTWRITEBYTECODE='1',CCACHE_DISABLE='1',
             VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32',VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32')
    argv=[REPO/'tools/build_scope.sh','--','timeout','--signal=TERM','--kill-after=15s','600s',
        '/tools/verilator/v5.046/bin/verilator','--binary','--timing','--assert','-j','32',
        '--output-split','12000','--output-split-cfuncs','5000','-CFLAGS','-O1',
        '-sv','-Wall','-Wno-fatal','-Wno-UNUSED',*['-Werror-'+c for c in
        ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
        '-I'+str(src/'rtl/fpu'),'-I'+str(REPO/'verif/fppipe'),
        *['+define+'+d for d in defs],'+define+VTM_NO_DPI','--Mdir',out/'obj',
        '--top-module','tb_ven_fp_trans',*sources]
    (out/'started.json').write_text(json.dumps(dict(argv=list(map(str,argv)),pins=pins,
        defines=defs,started=time.time()),indent=2)+'\n')
    result=dict(passed=False,runs=[],errors=[],gameplay_ipc=None,fpga_acceptance=False)
    try:
        with (out/'build.log').open('x') as log:
            code=subprocess.run(argv,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
        result['build_exit']=code
        assert code==0,'native build failed'
        binary=out/'obj/Vtb_ven_fp_trans'; result['binary_sha256']=sha(binary)
        for seed in (1,17,20260830):
            path=out/f'seed-{seed}.log'
            with path.open('x') as log:
                code=subprocess.run(['timeout','--signal=TERM','--kill-after=5s','90s',binary,
                    f'+verilator+seed+{seed}'],env=env,stdout=log,stderr=subprocess.STDOUT).returncode
            text=path.read_text()
            passed=code==0 and '%Error' not in text and all(text.count(marker)==1 for marker in
                ('VEN-FP-TRANS-A-B-OK checks=1640','TRANS-PACK-EDGE-AB-OK',
                 'TRANS-PACK-RESET-AB-OK aborts=144'))
            result['runs'].append(dict(seed=seed,native_exit=code,passed=passed,raw_sha256=sha(path)))
            assert passed,f'seed {seed} failed'
        result['passed']=True
    except Exception as error: result['errors'].append(repr(error))
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        result['finished']=time.time()
        (out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
