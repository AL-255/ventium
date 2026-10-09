#!/usr/bin/env python3
"""Build paired private leaf models; never overwrite a canonical model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'out'):
        parser.add_argument('--'+name, required=True, type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch and __debug__
    output = args.out.resolve()
    assert output.is_relative_to(scratch)
    output.mkdir()
    original = REPO/'fp_shared/tb/tb_ven_fp_arith_forward.sv'
    extension = REPO/'fp_shared/tb/fp_mem_forward_cases.svh'
    text = original.read_text()
    assert text.count('  initial begin\n    logic [15:0] cw;') == 1
    text = text.replace('  initial begin\n    logic [15:0] cw;',
                        extension.read_text()+'\n  initial begin\n    logic [15:0] cw;')
    # The old register-only negative test excluded precisely the newly enabled
    # form. Preserve it in control and replace it with positive memory coverage.
    text = text.replace('for (int kind=0; kind<8; kind++) rejection_case(kind);',
                        'for (int kind=0; kind<8; kind++)\n'
                        '      if (!MEM_FORWARD || kind!=4) rejection_case(kind);')
    text = text.replace('    $finish;', '    memory_cases();\n    $finish;')
    # Do not inline the large serial numeric helper at every timed task call.
    # A single combinational reference cone receives each query, then the
    # testbench samples it after settling. No DUT clock or acceptance changes.
    text, replacements = re.subn(r'(\w+)\s*=reference_result\((.*?)\);',
                                 lambda m: 'calc_reference('+m[2]+','+m[1]+');',
                                 text, flags=re.S)
    assert replacements == 11, replacements
    text = text.replace('  int memory_checks=0;', '''  logic [2:0] ref_op;
  logic [79:0] ref_a,ref_b;
  logic [15:0] ref_cw;
  logic [84:0] ref_result;
  always_comb ref_result=f_eval_s2(f_eval_s1(ref_op,ref_a,ref_b,
      ref_cw[11:10],ref_cw[9:8],1'b0),ref_cw[11:10],ref_cw[9:8]);
  task automatic calc_reference(input logic [2:0] op,
      input logic [79:0] a,b, input logic [15:0] cw, output logic [84:0] result);
    ref_op=op; ref_a=a; ref_b=b; ref_cw=cw;
    #1; result=ref_result;
  endtask
  int memory_checks=0;''')
    fixture = output/'tb_ven_fp_arith_forward.sv'
    fixture.write_text(text)
    files = ['rtl/core/ventium_decode_pkg.sv', 'rtl/fpu/fpu_x87_pkg.sv',
             'rtl/core/ventium_x87_pkg.sv', 'rtl/fpu/fpu_srt_div.sv',
             'rtl/fpu/ven_bcd.sv', 'rtl/fpu/ven_bcd_to_fp.sv', 'rtl/fpu/fpu_estdiv.sv',
             'fp_shared/ven_fp_state.sv', 'fp_shared/ven_fp_alu.sv',
             'fp_shared/ven_fp_misc.sv', 'fp_shared/ven_fp_widemul.sv',
             'fp_shared/ven_fp_estdiv.sv', 'fp_shared/ven_fp_trans.sv', 'fp_shared/ven_fp_top.sv']
    pins = {str(source/p): sha(source/p) for p in files}
    # Included package arithmetic is part of the actual source closure too.
    pins.update({str(p): sha(p) for p in (source/'rtl/fpu').glob('*.svh')})
    pins.update({str(p): sha(p) for p in (source/'fp_shared').glob('*.svh')})
    pins.update({str(p): sha(p) for p in (original, extension, fixture, Path(__file__))})
    (output/'inputs.json').write_text(json.dumps(pins, indent=2)+'\n')
    result = dict(passed=False, started=time.time(), variants=[], gameplay_ipc=None, standard_suite=False)
    env = dict(os.environ, TMPDIR=str(output), PYTHONDONTWRITEBYTECODE='1', CCACHE_DISABLE='1',
               VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32', VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32')
    try:
        for name in ('control', 'candidate'):
            leaf = output/name
            leaf.mkdir()
            command = [str(REPO/'tools/build_scope.sh'), '--', 'timeout', '--signal=TERM',
                       '--kill-after=15s', '600s', '/tools/verilator/v5.046/bin/verilator',
                       '--binary', '--timing', '--assert', '-j', '32', '--output-groups', '0',
                       '--output-split', '8000', '--output-split-cfuncs', '8000', '-sv', '-Wall',
                       '-Wno-fatal', '-Wno-UNUSED', '--top-module', 'tb_ven_fp_arith_forward',
                       '--Mdir', str(leaf/'obj'), '-I'+str(source/'rtl/fpu'),
                       '-I'+str(source/'fp_shared'), '+define+VEN_FPREM',
                       '+define+VEN_FP_ARITH_STREAM', '+define+VEN_FP_ARITH_FWD']
            command += ['-Werror-'+n for n in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN',
                                               'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')]
            if name == 'candidate':
                command += ['+define+VEN_FP_ARITH_MEM_FWD']
            command += [str(source/p) for p in files]+[str(fixture)]
            (leaf/'command.json').write_text(json.dumps(command, indent=2)+'\n')
            with (leaf/'build.log').open('x') as log:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env).returncode
            row = dict(name=name, build_exit=rc)
            result['variants'].append(row)
            assert rc == 0, (name, 'build', rc)
            binary = leaf/'obj/Vtb_ven_fp_arith_forward'
            row['binary_sha256'] = sha(binary)
            with (leaf/'run.log').open('x') as log:
                rc = subprocess.run(['timeout', '--kill-after=3s', '60s', binary],
                                    stdout=log, stderr=subprocess.STDOUT, env=env).returncode
            row['native_exit'] = rc
            assert rc == 0, (name, 'run', rc)
            log = (leaf/'run.log').read_text()
            old_checks = 48 if name == 'control' else 47
            assert f'FP-ARITH-FORWARD-LEAF-OK forwarding=1 checks={old_checks}' in log
            assert f'FP-MEM-FORWARD-LEAF-OK enabled={int(name=="candidate")} memory_checks=236' in log
        result['passed'] = True
    finally:
        result['finished'] = time.time()
        result['inputs_unchanged'] = all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (output/'closed.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
