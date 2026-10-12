#!/usr/bin/env python3
"""Whole-FPU memory-divide capture A/B, exact latency and busy-input tests.

Run inside the existing ipc_parallel32 heavy-build scope. Keeps source trees
immutable; emits only a private top and testbench in external/tmp. No timing,
whole-core or full-system acceptance follows from this leaf comparison.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import time
import traceback

import prepare_memdiv_capture as recipe
from run_srt_payload_top_ab import UNITS, INCLUDES, sha, save, inherited_lock_fds


def bench_text(original, tail):
    text = original
    for side in ('old', 'new'):
        marker = f'           {side}_dut.srt_mode, {side}_dut.srt_a, {side}_dut.srt_b,\n'
        assert text.count(marker) == 1
        text = text.replace(marker, '')
    marker = '        $fatal(1, "%s: SRT ownership/control mismatch", label);'
    assert text.count(marker) == 1
    text = text.replace(marker, marker+'''
      if (new_dut.srt_start &&
          ({new_dut.srt_mode, new_dut.srt_a, new_dut.srt_b} !==
           {old_dut.srt_mode, old_dut.srt_a, old_dut.srt_b}))
        $fatal(1, "%s: active SRT operand mismatch", label);''')
    assert text.count('    if (rst_n)\n') == 1
    text = text.replace('    if (rst_n)\n', '    if (rst_n && register_phase)\n')
    marker = '.cmd_valid(cmd_valid), .cmd_ready(new_cmd_ready)'
    assert text.count(marker) == 1
    text = text.replace(marker, '.cmd_valid(cmd_valid | busy_noise), .cmd_ready(new_cmd_ready)')
    assert text.count('  initial begin\n') == 1
    text = text.replace('  initial begin\n', '  task automatic run_register_matrix();\n')
    ending = '    $finish;\n  end\nendmodule\n\n`default_nettype wire\n'
    assert text.endswith(ending)
    return text[:-len(ending)]+'  endtask\n\n'+tail


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent-core', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--variant', choices=('base', 'deployed', 'live-bits', 'reverse', 'width'), required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    here = Path(__file__).resolve().parent
    parent = args.parent_core.resolve(strict=True)
    source = parent/'candidate'
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != repo.stat().st_dev
    assert shutil.disk_usage(scratch).free > 4.5*1024**3
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    lock_fds = inherited_lock_fds()
    subprocess.run([repo/'tools/build_scope.sh','--is-active'], pass_fds=lock_fds, check=True, timeout=10)
    before = json.loads((parent/'build-started.json').read_text())
    closed = json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == closed['binary_sha256']
    top = source/recipe.PAYLOAD
    pins = {**before['pins']}
    files = [*(source/p for p in UNITS), *(source/'rtl/fpu'/p for p in INCLUDES),
        top, here/'tb_ven_fp_srt_top_ab.sv', here/'tb_memdiv_capture_tail.svh',
        Path(__file__), Path(recipe.__file__), here/'run_srt_payload_top_ab.py',
        repo/'tools/build_scope.sh', repo/'tools/verilator_serial.sh',
        parent/'build-started.json', parent/'build-closed.json',
        Path('/tools/verilator/v5.046/bin/verilator'), Path('/tools/verilator/v5.046/bin/verilator_bin')]
    pins.update({str(p):sha(p) for p in files})
    assert all(sha(Path(p)) == h for p,h in pins.items())
    old = top.read_text(); new = recipe.transform(old)
    mutants = {
        'live-bits': ('f_mem_as_float(div_mem_q, div_bytes_q)', 'f_mem_as_float(cmd_mem, div_bytes_q)'),
        'reverse': ('div_aluop = div_aluop_q;', "div_aluop = 3'd6;"),
        'width': ('div_bytes_q <= cmd_mem_bytes;', "div_bytes_q <= 4'd8;"),
    }
    if args.variant in mutants:
        a,b = mutants[args.variant]; assert new.count(a) == 1
        new = new.replace(a,b)
    definitions = ['VEN_FPREM'] if args.variant == 'base' else json.loads((parent/'prepared.json').read_text())['definitions']
    assert not {'SYNTHESIS','VTM_NO_DPI','VEN_SNAPSHOT_RESTORE'} & set(definitions)
    definitions = [*definitions, 'VEN_FP_PERF']
    out.mkdir()
    for name, text in (
        ('old.sv', old.replace('module ven_fp_top\n', 'module ven_fp_top_old\n')),
        ('new.sv', new),
        ('tb.sv', bench_text((here/'tb_ven_fp_srt_top_ab.sv').read_text(),
                             (here/'tb_memdiv_capture_tail.svh').read_text())),
    ):
        with (out/name).open('x') as stream: stream.write(text)
        pins[str(out/name)] = sha(out/name)
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        variant=args.variant, definitions=definitions, controller_affinity=sorted(os.sched_getaffinity(0))))
    rows = []

    def native(label, command, limit, heavy=False):
        command = list(map(str,command)); save(out/(label+'.command.json'),command)
        began = time.monotonic()
        with (out/(label+'.log')).open('x') as stream:
            with subprocess.Popen(command,stdout=stream,stderr=subprocess.STDOUT,
                    pass_fds=lock_fds if heavy else (),start_new_session=True) as child:
                affinity = sorted(os.sched_getaffinity(child.pid))
                try: status = child.wait(timeout=limit)
                except BaseException:
                    if child.poll() is None:
                        os.killpg(child.pid,signal.SIGTERM)
                        try: child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid,signal.SIGKILL); child.wait(timeout=10)
                    raise
        row = dict(label=label,native_exit=status,seconds=time.monotonic()-began,
                   child_affinity=affinity,log_sha256=sha(out/(label+'.log')))
        rows.append(row)
        return status, (out/(label+'.log')).read_text()

    result = dict(passed=False,errors=[],whole_core=False,standard_suite=False,
                  physical_board=False,gameplay_ipc=None,fmax_mhz=None)
    began = time.monotonic()
    try:
        command = [repo/'tools/verilator_serial.sh','--binary','--timing','--assert',
            '--threads','1','-j','32','--output-groups','0','--output-split','20000',
            '--output-split-cfuncs','20000','-sv','-Wall','-Wno-fatal','-Wno-UNUSED',
            *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
            '--top-module','tb_ven_fp_srt_top_ab',*['+define+'+d for d in definitions],
            '-I'+str(source/'rtl/fpu'),'--Mdir',out/'obj',
            *[source/p for p in UNITS],out/'old.sv',out/'new.sv',out/'tb.sv']
        status,_ = native('build',command,240,True)
        assert status == 0, ('compile',status)
        binary = out/'obj/Vtb_ven_fp_srt_top_ab'; pins[str(binary)] = sha(binary)
        status,log = native('run',[binary],120)
        if args.variant in mutants:
            assert status != 0 and 'MEMDIV_' in log, ('negative control',status)
        else:
            assert status == 0 and 'FP-SRT-TOP-AB-OK matrix=12 checks=396' in log
            assert 'MEMDIV-CAPTURE-OK mem=8208 delayed=8192 fault=16 ' in log
        result['passed'] = True
    except BaseException as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(rows=rows,pins=pins,seconds=time.monotonic()-began,
                  pins_unchanged=all(sha(Path(p)) == h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
