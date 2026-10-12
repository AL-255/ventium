#!/usr/bin/env python3
"""Sequential SRT operand-isolation miter; no whole-core or timing acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_rem_operand_split as patch


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fixture(original, enabled):
    text = original.replace('tb_input_norm_miter', 'tb_rem_operand_split')
    # C is deliberately dead in IDLE/SPECIAL; compare it in every consuming
    # state. All other existing internal-state and public-output checks remain.
    text = patch.once(text, 'control.C !== candidate.C ||',
        '((control.st != 4\'d0 && control.st != 4\'d8) &&\n'
        '         control.C !== candidate.C) ||')
    anchor = '  task automatic run(input logic [79:0] aa,bb,input logic [1:0] mm);\n'
    text = patch.once(text, anchor, '''  function automatic logic [79:0] special_operand(input integer index);
    case(index)
      0: return 80'h00000000000000000000;
      1: return 80'h80000000000000000000;
      2: return 80'h7fff8000000000000000;
      3: return 80'hffff8000000000000000;
      4: return 80'h7fffc000000000001234;
      5: return 80'h7fff8000000000000001;
      6: return 80'h00000000000000000001;
      default: return 80'h3fff8000000000000000;
    endcase
  endfunction

'''+anchor)
    anchor = '    // Every leading-one position, exponent-zero and ordinary unnormal input,\n'
    text = patch.once(text, anchor, '''    // Signed zeros, infinities, NaNs and smallest denormals in both operands.
    for(integer ia=0;ia<8;ia++) for(integer ib=0;ib<8;ib++)
      for(integer m=0;m<3;m++) begin
        rc=2'(ia); pc=(ib%3==0)?0:(ib%3==1)?2:3;
        prem1=1'(ib); buggy=1'(ia);
        run(special_operand(ia),special_operand(ib),2'(m));
      end
'''+anchor)
    text = patch.once(text, 'samples!=4544', 'samples!=4736')
    text = text.replace('SRT-INPUT-NORM-MITER-OK', 'SRT-REM-OPERAND-MITER-OK')
    if enabled:
        anchor = '  fpu_srt_div candidate(.clk,.rst_n,.start,.mode,.prem1,.a,.b,.rc,.pc,.buggy,\n'
        text = patch.once(text, anchor, '''  // Deliberately corrupt the shared DIV input in REM mode. Remainder must
  // use its independent ST operands. Conversely, corrupt unused REM inputs
  // during divide/sqrt; changing commands while busy is covered below too.
  fpu_srt_div candidate(.clk,.rst_n,.start,.mode,.prem1,
      .a(mode==2 ? ~a : a),.b(mode==2 ? ~b : b),
      .rem_a(mode==2 ? a : ~a),.rem_b(mode==2 ? b : ~b),.rc,.pc,.buggy,
''')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    parent = args.parent.resolve(strict=True); out = args.out.resolve()
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert shutil.disk_usage(scratch).free > 4*1024**3
    subprocess.run([str(repo/'tools/build_scope.sh'), '--is-active'], check=True, pass_fds=(9,))
    source = {name: (parent/name).read_text() for name in patch.HASHES}
    new = patch.transform(source)
    tb = Path(__file__).with_name('tb_input_norm_miter.sv')
    pins = {str(p.resolve()): sha(p) for p in (
        *(parent/name for name in patch.HASHES), parent/'rtl/fpu/fpu_x87_pkg.sv',
        tb, Path(__file__), Path(patch.__file__), repo/'tools/build_scope.sh',
        repo/'tools/verilator_serial.sh', Path('/tools/verilator/v5.046/bin/verilator'),
        Path('/tools/verilator/v5.046/bin/verilator_bin'))}
    out.mkdir()
    for name, content in new.items():
        target = out/'candidate'/name; target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content); pins[str(target)] = sha(target)
    control = out/'fpu_srt_div_control.sv'
    control.write_text(patch.once(source['rtl/fpu/fpu_srt_div.sv'],
        'module fpu_srt_div\n', 'module fpu_srt_div_control\n'))
    pins[str(control)] = sha(control)
    def save(name, value):
        with (out/name).open('x') as stream: json.dump(value, stream, indent=2)
    save('started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        scope='complete SRT sequential A/B, not shared-top/core/numeric-oracle/timing acceptance'))
    rows=[]; began=time.monotonic(); result=dict(passed=False)
    variants = [('disabled', False, None), ('enabled', True, None),
                ('wrong-rem-port', True, 'port'), ('wrong-idle-carry', True, 'carry')]
    try:
        for label, enabled, mutant in variants:
            assert shutil.disk_usage(scratch).free > 4*1024**3
            folder=out/label; folder.mkdir()
            sv = new['rtl/fpu/fpu_srt_div.sv']
            if mutant == 'port':
                sv=patch.once(sv, 'wire [79:0] rem_input_a = rem_a;', 'wire [79:0] rem_input_a = a;')
            elif mutant == 'carry':
                sv=patch.once(sv, "          C <= 80'd0;", "          C <= (80'd1 << 72);")
            dut=folder/'fpu_srt_div.sv'; dut.write_text(sv)
            test=folder/'tb_rem_operand_split.sv'; test.write_text(fixture(tb.read_text(),enabled))
            command=[str(repo/'tools/verilator_serial.sh'),'-j','32','--binary','--timing',
                '--assert','--threads','1','-Wall','-Wno-UNUSED','-Wno-fatal',
                '-Werror-IMPLICIT','-Werror-PINMISSING','-Werror-UNDRIVEN',
                '-Werror-MULTIDRIVEN','-Werror-LATCH','-Werror-UNOPTFLAT',
                '+define+VEN_FPREM',*(['+define+'+patch.FLAG] if enabled else []),
                '--Mdir',str(folder/'obj'),'--top-module','tb_rem_operand_split',
                str(parent/'rtl/fpu/fpu_x87_pkg.sv'),str(control),str(dut),str(test)]
            row=dict(label=label,command=command); rows.append(row)
            with (folder/'build.log').open('x') as log:
                build=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,
                                     pass_fds=(9,),timeout=150)
            row['build_exit']=build.returncode
            assert build.returncode==0, (label,'build',build.returncode)
            binary=folder/'obj/Vtb_rem_operand_split'
            # A single native process runs the generated timing testbench.
            # Explicit affinity avoids a host-sized Verilator startup pool.
            run_command=['taskset','-c','11',str(binary)]
            row['run_command']=run_command
            with (folder/'run.log').open('x') as log:
                child=subprocess.Popen(run_command,stdout=log,stderr=subprocess.STDOUT)
                row['pid']=child.pid
                try:
                    # Popen can be observed before taskset execs; accept the
                    # affinity only after it is actually installed.
                    deadline=time.monotonic()+5
                    while child.poll() is None:
                        affinity=sorted(os.sched_getaffinity(child.pid))
                        if affinity == [11]: break
                        assert time.monotonic()<deadline
                        time.sleep(.001)
                    assert child.poll() is None and affinity == [11], 'child too short to verify CPU affinity'
                    row['affinity']=affinity
                    row['native_exit']=child.wait(timeout=90)
                finally:
                    if child.poll() is None: child.kill(); child.wait()
            output=(folder/'run.log').read_text()
            row['log']=output
            row['artifacts']={str(p):sha(p) for p in (dut,test,binary,folder/'build.log',folder/'run.log')}
            if mutant:
                assert row['native_exit'] != 0 and 'MISMATCH' in output, (label,output)
            else:
                assert row['native_exit']==0 and 'SRT-REM-OPERAND-MITER-OK samples=4736 ' in output, (label,output)
        result['passed']=True
    except BaseException as error:
        result['error']=repr(error)
        import traceback
        result['traceback']=traceback.format_exc()
    finally:
        result.update(rows=rows,seconds=time.monotonic()-began,pins=pins,
            pins_unchanged=all(sha(p)==h for p,h in pins.items()),
            whole_core=False,shared_top=False,numeric_oracle=False,fmax_mhz=None,gameplay_ipc=None)
        result['passed'] &= result['pins_unchanged']
        save('closed.json',result)
        print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
