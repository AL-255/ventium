"""Source-extracted binary miter; not sequential cache or hardware acceptance."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_pair_now_capture as recipe
from test_window_current_reuse import sha

HERE=Path(__file__).resolve().parent


def assignment(source,name):
    rows=re.findall(r'^ +(?:assign|wire) '+re.escape(name)+r'\s*=.*?;',source,re.M|re.S)
    assert len(rows)==1,(name,len(rows))
    return re.sub(r'^ +wire ','  assign ',rows[0])+'\n'


def fixture(old,new,flags):
    body=''
    for name in ('mc_lookup_old','mc_lookup_prime','mc_lookup_next','hit0','hit1','hit',
                 'window_reuse','shadow_reuse','pair_legacy_capture','pair_prime_capture',
                 'pair_store_read_capture','pair_legacy_bank_owned','pair_lookup_active',
                 'pair_now_valid'):
        if name in ('hit0','hit1') and 'VEN_PIPE_MEM_CHAIN' not in flags:
            body+=f'  assign {name}=tag_current_hit[{name[-1]}];\n'
        else:body+=assignment(old,name)
    for name in ('pair_fresh_current_hit','pair_fresh_saved_window'):
        if 'VEN_P54_DUAL_HIT_LEGACY_CAPTURE' in flags:body+=assignment(old,name)
        else:body+=f"  assign {name}=1'b0;\n"
    body+='  for(genvar lane=0;lane<2;lane++) begin\n'
    body+=assignment(old,'pair_hit[lane]').replace('pair_hit[lane]','old_hit[lane]')
    body+=assignment(new,'pair_hit[lane]').replace('pair_hit[lane]','new_hit[lane]')
    body+='  end\n'
    template=(HERE/'tb_pair_now_capture.sv').read_text()
    assert template.count('  // EXTRACTED_EQUATIONS')==1
    return template.replace('  // EXTRACTED_EQUATIONS',body)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True);ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args();source_path=args.source.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=HERE.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)=={12}
    original=source_path.read_text();changed=recipe.transform(original);old=recipe.equation(original)
    assert changed.replace(old.replace(recipe.OLD,recipe.NEW)+recipe.witness(old),old)==original
    for bad in (original+'\n',changed):
        try:recipe.transform(bad)
        except ValueError:pass
        else:raise AssertionError('accepted drift/reapplication')
    pins={str(p):sha(p) for p in (source_path,Path(__file__).resolve(),Path(recipe.__file__).resolve(),
        HERE/'test_window_current_reuse.py',HERE/'tb_pair_now_capture.sv',Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[12]))
    (root/'candidate.sv').write_text(changed)
    full=['VEN_P54_DUAL_HIT','VEN_P54_DUAL_HIT_LEGACY_CAPTURE','VEN_P54_DUAL_LOAD_PAIR',
          'VEN_P54_DUAL_BYTE_LOAD_PAIR','VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME',
          'VEN_L1D_PRIME_UNDER_FILL','VEN_P54_DUAL_STORE_PAIR','VEN_L1D_CODE_BUFFER',
          'VEN_L1D_WINDOW_REUSE','VEN_L1D_TWO_WINDOW_REUSE']
    modes=[('full',full),('standalone',[f for f in full if f!='VEN_P54_DUAL_LOAD_PAIR']),
           ('no-capture',[f for f in full if f not in ('VEN_P54_DUAL_LOAD_PAIR','VEN_P54_DUAL_HIT_LEGACY_CAPTURE')]),
           ('no-chain',[f for f in full if f not in ('VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME','VEN_L1D_PRIME_UNDER_FILL')]),
           ('primary-only',[f for f in full if f!='VEN_L1D_TWO_WINDOW_REUSE']),
           ('no-windows',[f for f in full if 'WINDOW_REUSE' not in f]),
           ('prime',full+['VEN_P54_DUAL_LOAD_PRIME']),
           ('store-load',full+['VEN_P54_STORE_LOAD_PAIR'])]
    cases=[(name,flags,False) for name,flags in modes]+[('lost-two-lane-priority',full,True)]
    rows=[];errors=[];begin=time.monotonic()
    try:
        for name,flags,mutant in cases:
            folder=root/name;folder.mkdir();candidate=changed
            if mutant:
                assert recipe.NEW.count('pair_req_valid[0] &&')==1
                candidate=candidate.replace(recipe.NEW,recipe.NEW.replace('pair_req_valid[0] &&',"1'b0 &&"))
            sv=folder/'candidate.sv';sv.write_text(candidate);pp=[]
            for label,path in (('old',source_path),('new',sv)):
                dest=folder/(label+'.pp.sv')
                cmd=['/usr/bin/iverilog','-g2012','-E','-DSYNTHESIS',*['-D'+f for f in flags],'-o',str(dest),str(path)]
                native=subprocess.run(cmd,capture_output=True,text=True,timeout=10)
                (folder/(label+'.preprocess.log')).write_text(native.stdout+native.stderr)
                assert native.returncode==0,native.stderr;pp.append(dest.read_text())
            tb=folder/'tb.sv';tb.write_text(fixture(*pp,flags));binary=folder/'test.vvp'
            cmd=['/usr/bin/iverilog','-g2012','-s','tb',*['-D'+f for f in flags],'-o',str(binary),str(tb)]
            native=subprocess.run(cmd,capture_output=True,text=True,timeout=10)
            (folder/'build.log').write_text(native.stdout+native.stderr)
            assert native.returncode==0,native.stderr
            native=subprocess.run(['/usr/bin/vvp',str(binary)],capture_output=True,text=True,timeout=40)
            log=native.stdout+native.stderr;(folder/'run.log').write_text(log)
            assert native.returncode==(1 if mutant else 0),log
            assert ('PAIR-NOW-CAPTURE-MISMATCH' if mutant else 'PAIR-NOW-CAPTURE-OK checks=149509 ') in log,log
            rows.append(dict(name=name,flags=flags,mutant=mutant,native_exit=native.returncode,
                coverage=log.strip(),artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()}))
            print(name,log.strip(),flush=True)
    except Exception as exc:
        import traceback
        errors.append(dict(error=repr(exc),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and not errors and len(rows)==len(cases),pins_unchanged=stable,
        errors=errors,rows=rows,seconds=time.monotonic()-begin,derivative_sha256=sha(root/'candidate.sv'),
        source_scope_exact=True,sequential_cache=False,whole_core=False,binary_values_only=True,
        hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    save('closed.json',result);print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
