#!/usr/bin/env python3
"""Bounded actual-source Icarus/Z3 exponent check; not a whole-engine test."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback
import prepare_div_exp_width as recipe


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source','out'): parser.add_argument('--'+name,type=Path,required=True)
    args = parser.parse_args()
    source, out = args.source.resolve(strict=True), args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert Path(os.environ['TMPDIR']).resolve() == scratch and out.is_relative_to(scratch) and out != scratch
    assert not out.exists() and shutil.disk_usage(scratch).free > 4*1024**3
    old = source.read_text(); new = recipe.transform(old)
    package = source.with_name('fpu_x87_pkg.sv')
    assert sha(package) == recipe.PACKAGE
    pkg = package.read_text(); here = Path(__file__).parent
    def function(text, declaration):
        assert text.count(declaration) == 1
        start = text.index(declaration); end = text.index('endfunction',start)+len('endfunction')
        return text[start:end]+'\n'
    shared = function(pkg,'  function automatic logic [14:0] fx_exp ')
    shared += function(pkg,'  function automatic logic [63:0] fx_man ')
    shared += function(pkg,'  function automatic logic signed [31:0] fx_uexp_eff(')
    shared += function(old,'  function automatic logic [5:0] srt_input_clz64(')
    def operand(name, body):
        # Model the exact sequential RHS as a combinational setup bundle. Only
        # assignment scheduling is removed; the real engine miter is separate.
        assert body.count('<=') == 2
        return ('function automatic logic [191:0] '+name+'(input logic [79:0] a,b);\n'
            'logic signed [31:0] ua,ub;\n'+body.replace('<=','=')+
            'return {ua,ub,ma_,mb_};\nendfunction\n')
    shared += operand('reference_operand',recipe.OLD)
    shared += '''function automatic logic signed [31:0] reference_exp(
        input logic [14:0] e, input logic [5:0] shift);
      int ka;
      ka=63-int'(shift);
      return fx_uexp_eff({1'b0,e,64'd0})-(63-ka);
    endfunction
'''
    out.mkdir()
    pins = {str(p):sha(p) for p in (source,package,Path(__file__),Path(recipe.__file__),
        here/'test_div_exp_width.py',here/'tb_div_exp_width.svh',Path('/usr/bin/iverilog').resolve(),
        Path('/usr/bin/vvp').resolve(),Path('/usr/bin/z3').resolve())}
    def save(name,value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2)
    def write(name,body):
        with (out/name).open('x') as f: f.write(body)
        pins[str(out/name)] = sha(out/name)
    rows = []
    def run(label,command,expected=0,marker=None,seconds=90):
        command = list(map(str,command)); start = time.monotonic()
        with (out/(label+'.log')).open('x') as f:
            native = subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=seconds)
        row = dict(label=label,command=command,native_exit=native.returncode,
                   seconds=time.monotonic()-start,log_sha256=sha(out/(label+'.log')))
        rows.append(row)
        assert native.returncode == expected, row
        if marker is not None: assert marker in (out/(label+'.log')).read_text(), row
    result = dict(passed=False,errors=[],whole_engine=False,whole_core=False,gameplay_ipc=None,fmax_mhz=None)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    start = time.monotonic()
    try:
        write('candidate.sv',new)
        variants = (
            ('positive',recipe.HELPER,None),
            ('zero-bias',recipe.HELPER.replace("? 15'd1 : encoded", "? 15'd0 : encoded"),'zero-bias'),
            ('unsigned',recipe.HELPER.replace('{{16{adjusted[15]}}, adjusted}',"{16'd0, adjusted}"),'unsigned'),
            ('too-narrow',recipe.HELPER.replace('[15:0] adjusted','[14:0] adjusted').replace(
                '{{16{adjusted[15]}}, adjusted}','{{17{adjusted[14]}}, adjusted}'),'too-narrow'))
        for label,helper,mutation in variants:
            assert mutation is None or helper != recipe.HELPER
            write(label+'.smt2',recipe.proof(mutation))
            run(label+'-proof',['/usr/bin/z3','-smt2',out/(label+'.smt2')],seconds=15)
            assert (out/(label+'-proof.log')).read_text().strip() == ('sat' if mutation else 'unsat')
            write(label+'.sv','module tb;\n'+shared+helper+operand('candidate_operand',recipe.NEW)+
                  (here/'tb_div_exp_width.svh').read_text()+'\nendmodule\n')
            run(label+'-build',['/usr/bin/iverilog','-g2012','-s','tb','-o',out/(label+'.vvp'),out/(label+'.sv')],seconds=30)
            pins[str(out/(label+'.vvp'))] = sha(out/(label+'.vvp'))
            run(label,['/usr/bin/vvp',out/(label+'.vvp')],expected=1 if mutation else 0,
                marker='DIV_EXP_WIDTH_MISMATCH' if mutation else
                    'DIV-EXP-WIDTH-OK count=2101120 fourstate=3968 normalization=137796 min=-16445 max=16384')
        result['passed'] = True
    except BaseException as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(rows=rows,pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
