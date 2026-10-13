"""Light source-extracted window-reuse miter, not full cache/core acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_window_current_reuse as recipe

HERE=Path(__file__).resolve().parent


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def assign(source,name):
    rows=re.findall(r'^  (?:assign|wire) '+name+r'\s*=.*?;',source,re.M|re.S)
    if len(rows)!=1:raise ValueError((name,len(rows)))
    return re.sub(r'^  wire ','  assign ',rows[0])+'\n'


def fixture(old,new,flags):
    body=''.join(assign(old,n) for n in ('mc_lookup_old','mc_lookup_prime','mc_lookup_next'))
    if 'VEN_PIPE_MEM_CHAIN' in flags:
        body+=''.join(assign(old,n) for n in ('hit0','hit1','hit'))
    else:
        body+='  assign hit0=tag_current_hit[0];\n  assign hit1=tag_current_hit[1];\n'+assign(old,'hit')
    body+=assign(new,'window_current_hit') if 'VEN_L1D_WINDOW_REUSE' in flags else "  assign window_current_hit=1'b0;\n"
    for name,label in (('window_reuse','window'),('shadow_reuse','shadow')):
        for version,source in (('old',old),('new',new)):
            body+=assign(source,name).replace('assign '+name+' =','assign '+version+'_'+label+' =')
    template=(HERE/'tb_window_current_reuse.sv').read_text()
    assert template.count('  // EXTRACTED_EQUATIONS')==1
    return template.replace('  // EXTRACTED_EQUATIONS',body)


def scope(source,changed):
    restored=changed.replace(recipe.HELPER,'')
    for name in ('window_reuse','shadow_reuse'):
        old=recipe.equation(source,name)
        block=recipe.replacement(old)+recipe.witness(old,name)
        assert restored.count(block)==1
        restored=restored.replace(block,old)
    assert restored==source
    for bad in (source+'\n',changed):
        try:recipe.transform(bad)
        except ValueError:pass
        else:raise AssertionError('drift/reapplication accepted')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    args=ap.parse_args(); source_path=args.source.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert root.parent.stat().st_dev==scratch.stat().st_dev!=HERE.stat().st_dev
    assert os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)=={12}
    source=source_path.read_text();changed=recipe.transform(source);scope(source,changed)
    pins={str(p):sha(p) for p in (source_path,Path(__file__).resolve(),Path(recipe.__file__).resolve(),
          HERE/'tb_window_current_reuse.sv',Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[12]))
    (root/'candidate.sv').write_text(changed)
    windows=['VEN_L1D_WINDOW_REUSE','VEN_L1D_TWO_WINDOW_REUSE']
    chain=['VEN_PIPE_MEM_CHAIN','VEN_PIPE_REG_LOAD_PRIME','VEN_L1D_PRIME_UNDER_FILL']
    full=windows+chain+['VEN_P54_DUAL_STORE_PAIR','VEN_L1D_CODE_BUFFER']
    modes=[('full',full),('no-store-pair',[f for f in full if f!='VEN_P54_DUAL_STORE_PAIR']),
           ('no-code',[f for f in full if f!='VEN_L1D_CODE_BUFFER']),
           ('primary-only',[f for f in full if f!='VEN_L1D_TWO_WINDOW_REUSE']),
           ('no-chain',windows+['VEN_L1D_CODE_BUFFER']),
           ('no-chain-no-code',windows),('no-windows',chain)]
    mutations={
        'lost-next-owner':('!(c_next_req && rd_match)',"1'b1"),
        'wrong-tags':('assign window_current_hit = |tag_current_hit;',
                      'assign window_current_hit = |tag_prime_hit;'),
        'lost-flush':('!flush_all &&',''),
        'lost-snoop':('!snoop_inv_valid &&',''),
        'wrong-extent':("c_addr[4:0] <= 5'd28","c_addr[4:0] <= 5'd31"),
        'lost-code-guard':('!code_access &&',''),
    }
    cases=[(label,flags,None) for label,flags in modes]+[(label,full,edit) for label,edit in mutations.items()]
    begin=time.monotonic();rows=[];errors=[]
    try:
        for label,flags,edit in cases:
            folder=root/label;folder.mkdir();candidate=changed
            if edit:
                # Change only the new helper/equations, retaining old witnesses.
                if label=='wrong-tags':
                    assert candidate.count(edit[0])==1;candidate=candidate.replace(*edit)
                else:
                    before=recipe.replacement(recipe.equation(source,'window_reuse'))
                    assert before.count(edit[0])==1 and candidate.count(before)==1
                    candidate=candidate.replace(before,before.replace(*edit))
            sv=folder/'candidate.sv';sv.write_text(candidate);pp=[]
            for name,path in (('old',source_path),('new',sv)):
                out=folder/(name+'.pp.sv')
                command=['/usr/bin/iverilog','-g2012','-E','-DSYNTHESIS',*['-D'+f for f in flags],'-o',str(out),str(path)]
                done=subprocess.run(command,capture_output=True,text=True,timeout=10)
                (folder/(name+'.preprocess.log')).write_text(done.stdout+done.stderr)
                assert done.returncode==0,(label,done.stderr);pp.append(out.read_text())
            tb=folder/'tb.sv';tb.write_text(fixture(*pp,flags));binary=folder/'test.vvp'
            command=['/usr/bin/iverilog','-g2012','-s','tb',*['-D'+f for f in flags],'-o',str(binary),str(tb)]
            done=subprocess.run(command,capture_output=True,text=True,timeout=10)
            (folder/'build.log').write_text(done.stdout+done.stderr)
            assert done.returncode==0,(label,done.stderr)
            done=subprocess.run(['/usr/bin/vvp',str(binary)],capture_output=True,text=True,timeout=40)
            log=done.stdout+done.stderr;(folder/'run.log').write_text(log)
            assert done.returncode==(1 if edit else 0),(label,log)
            assert ('WINDOW-REUSE-MISMATCH' if edit else 'WINDOW-REUSE-OK checks=344071 ') in log,(label,log)
            row=dict(label=label,flags=flags,expected_failure=edit is not None,native_exit=done.returncode,
                     coverage=log.strip(),artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()})
            rows.append(row);print(label,log.strip(),flush=True)
    except Exception as exc:
        import traceback
        errors.append(dict(error=repr(exc),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and not errors and len(rows)==len(cases),pins_unchanged=stable,
        rows=rows,errors=errors,seconds=time.monotonic()-begin,source_scope_exact=True,
        sequential_cache=False,whole_core=False,binary_values_only=True,hardware_acceptance=False,
        gameplay_ipc=None,fmax_mhz=None,derivative_sha256=sha(root/'candidate.sv'))
    save('closed.json',result);print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
