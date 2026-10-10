#!/usr/bin/env python3
"""Five-way saved instruction payload experiment with public L1 traffic."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import time

import prepare_code_payload as recipe

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--fixture-root', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    root, parent, fixture = [p.resolve(strict=True) for p in (a.out,a.parent,a.fixture_root)]
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    assert Path(os.environ['TMPDIR']).resolve() == root
    assert subprocess.run([REPO/'tools/build_scope.sh','--is-active'],
        pass_fds=(9,),stdout=subprocess.DEVNULL).returncode == 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def load(p): return json.loads(p.read_text())
    def save(name, obj):
        with (root/name).open('x') as f: json.dump(obj,f,indent=2)
    started, built = [load(parent/n) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert built['binary_sha256'] == sha(parent/'obj/tb_ventium') == 'e8253e84b5859a97aa74f007b715c71485296c0eb7f30b3df3fb520158927b24'
    assert all(sha(p)==h for p,h in started['pins'].items())
    old = parent/'candidate'/recipe.TARGET
    assert sha(old) == 'd78345f1fc81235d5c4881d2ad645eda89ee5da808f2a4131d5bbdda3e178436'
    closed = load(fixture/'closed.json')
    assert closed['passed'] and closed['all_clock_interface_observations_identical']
    original_tb = fixture/'tb_l1d_mem_chain.sv'
    old_inputs = load(fixture/'started.json')['pins']
    assert old_inputs[str(original_tb)] == sha(original_tb)
    text = original_tb.read_text()
    for before, after in (
        ('  `include "high_window_payload_leaf.svh"',
         '  `include "high_window_payload_leaf.svh"\n  `include "code_payload_leaf.svh"'),
        ('    run_high_window_payload();\n    $finish;',
         '    run_high_window_payload();\n    run_code_payload();\n    $finish;')):
        assert text.count(before)==1, before
        text=text.replace(before,after)
    tb=root/'tb_l1d_mem_chain.sv'; tb.write_text(text)
    changed=recipe.transform(old.read_text())
    candidate=root/'ven_l1d.sv'; candidate.write_text(changed)
    wrongword=root/'wrong_word.sv'
    wrongword.write_text(changed.replace(recipe.NEW,recipe.NEW.replace('+: 32]', "+: 32] ^ 32'd1")))
    wrongowner=root/'wrong_owner.sv'
    wrongowner.write_text(changed.replace(recipe.SELECT,recipe.SELECT.replace('code_access && !rd_match',"1'b1")))
    flags=next(s.split('=',1)[1].split() for s in started['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defines=[s for s in flags if s.startswith('+define+')]
    assert '+define+VEN_L1D_HIGH_PAYLOAD_SELECT' in defines
    assert '+define+VEN_L1D_CODE_WORD_REUSE' in defines
    assert '+define+'+recipe.FLAG not in defines and '+define+SYNTHESIS' not in defines
    modules=[parent/'candidate/rtl/mem'/n for n in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    files=[Path(__file__),Path(recipe.__file__),old,candidate,wrongword,wrongowner,tb,original_tb,
           fixture/'closed.json',parent/'build-closed.json',*modules]
    files += [HERE/n for n in ('code_payload_leaf.svh','high_window_payload_leaf.svh',
        'response_payload_leaf.svh','window_write_update_leaf.svh','store_window_warm_leaf.svh')]
    pins={str(p):sha(p) for p in files}
    save('started.json',dict(pins=pins,defines=defines,parent_model=built['binary_sha256'],
        parent_source_pins_checked=len(started['pins']),invocation=os.environ.get('INVOCATION_ID')))
    begin=time.monotonic()
    result=dict(passed=False,variants=[],errors=[],gameplay_ipc=None,standard_suite=False,
                synthesis_started=False,production_changed=False)
    env=dict(os.environ,CCACHE_DISABLE='1',PYTHONDONTWRITEBYTECODE='1')
    try:
        for name,source,on,negative in (('control',old,False,False),('off',candidate,False,False),
                ('on',candidate,True,False),('wrong-word',wrongword,True,True),('wrong-owner',wrongowner,True,True)):
            leaf=root/name; leaf.mkdir()
            cmd=['timeout','--kill-after=5s','180s','/tools/verilator/v5.046/bin/verilator',
                '--binary','--timing','-sv','--assert','-j','32','-Wno-fatal','-Wno-UNUSED',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(HERE),'--top-module','tb_l1d_mem_chain','--Mdir',str(leaf/'obj'),'-o','test',
                *defines,*(['+define+'+recipe.FLAG] if on else []),*map(str,modules),str(source),str(tb)]
            save(name+'/command.json',cmd)
            with (leaf/'build.log').open('x') as f:
                build=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=190)
            row=dict(name=name,build_exit=build.returncode); result['variants'].append(row)
            assert build.returncode==0,row
            obs=leaf/'cycles.txt'
            with (leaf/'run.log').open('x') as f:
                native=subprocess.run(['timeout','30s',leaf/'obj/test','+OBS='+str(obs)],
                    env=env,stdout=f,stderr=subprocess.STDOUT,timeout=40)
            log=(leaf/'run.log').read_text()
            row.update(native_exit=native.returncode,binary_sha256=sha(leaf/'obj/test'))
            if negative:
                assert native.returncode in (1,-6,134) and re.search(
                    r'CODE-PAYLOAD|L1 primary payload cut changed an acknowledged read|old-response owner/data changed',log),(row,log)
                row['required_negative_observed']=True
            else:
                assert native.returncode==0 and not re.search(r'%Error|%Fatal|Assertion failed',log),(row,log)
                for marker in ('L1D-MEM-CHAIN-OK accepted=150','WINDOW-WRITE-UPDATE-OK',
                    'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK','CODE-PAYLOAD-OK'):
                    assert marker in log,(name,marker)
                row['coverage']=re.findall(r'CODE-PAYLOAD-OK.*',log)
            row['cycles_sha256']=sha(obs)
            with obs.open('rb') as src,gzip.open(str(obs)+'.gz','xb',compresslevel=3) as dst:
                while block:=src.read(1024*1024): dst.write(block)
            with gzip.open(str(obs)+'.gz','rb') as f:
                assert hashlib.file_digest(f,'sha256').hexdigest()==row['cycles_sha256']
            obs.unlink()
            print(json.dumps(row),flush=True)
        assert len({r['cycles_sha256'] for r in result['variants'][:3]})==1
        result.update(passed=True,all_clock_interface_observations_identical=True)
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-begin)
        result['passed'] &= result['pins_unchanged']
        save('closed.json',result)
        print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
