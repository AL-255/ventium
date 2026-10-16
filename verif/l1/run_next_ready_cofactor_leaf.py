"""Source-extracted readiness simulation and a binary symbolic identity proof."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import prepare_next_ready_cofactor as recipe
from run_backing_direction_leaf import ROOT,sha

HERE=Path(__file__).resolve().parent
PROFILES=dict(chain=[],prime=['VEN_PIPE_REG_LOAD_PRIME'],
    fill=['VEN_PIPE_REG_LOAD_PRIME','VEN_L1D_PRIME_UNDER_FILL','VEN_L1D_HIT_UNDER_FILL'],
    dual=['VEN_PIPE_REG_LOAD_PRIME','VEN_P54_DUAL_STORE_PAIR'],
    full=['VEN_PIPE_REG_LOAD_PRIME','VEN_P54_DUAL_STORE_PAIR',
          'VEN_L1D_PRIME_UNDER_FILL','VEN_L1D_HIT_UNDER_FILL','VEN_L1D_CODE_BUFFER'])
MUTANTS=('drop-request','current-tag','drop-old-cacheability')


def symbolic():
    # O/P overapproximate all possible slot expressions/configurations. G
    # includes unchanged next cacheability, invalidation and width predicates.
    text='(set-logic QF_UF)\n'
    for name in ('R','O','P','C','G','H','J'):
        text+=f'(declare-const {name} Bool)\n'
    text+='''(define-fun lookup () Bool (and R (or O P)))
(define-fun old () Bool (and lookup (or (and R P) C) G (ite lookup H J)))
(define-fun new () Bool (and R (or P (and O C)) G H))
'''
    checks=[('(not (= old new))','unsat'),('new','sat'),
        ('(not (= old (and (or P (and O C)) G H)))','sat'),
        ('(not (= old (and R (or P (and O C)) G J)))','sat'),
        ('(not (= old (and R (or P O) G H)))','sat')]
    for expression,_ in checks:
        text+=f'(push 1)\n(assert {expression})\n(check-sat)\n(pop 1)\n'
    return text,[expected for _,expected in checks]


def fixture(source,mode):
    old=recipe.block(source);new=recipe.changed_block(source)
    edits={'drop-request':('c_next_ready = c_next_req &&',"c_next_ready = 1'b1 &&"),
           'current-tag':('&& (|tag_prime_hit) &&','&& (|tag_current_hit) &&'),
           'drop-old-cacheability':('(mc_old_slot && cacheable)','mc_old_slot')}
    if mode!='positive':
        before,after=edits[mode];assert new.count(before)==1;new=new.replace(before,after)
    outputs={'mc_lookup_old':1,'mc_lookup_prime':1,'mc_lookup_next':1,
             'lookup_addr':32,'lookup_wstrb':4,'c_next_ready':1,'mc_capture_next':1,'hit':1}
    text=''
    for prefix,block in (('old_',old),('new_',new)):
        text+=''.join(f'  logic [{w-1}:0] {prefix}{n};\n' for n,w in outputs.items())
        # Bind the original selected hit exactly. The arrays are abstracted
        # by independent per-way Boolean tag results, not assumed identical.
        block+='  assign hit = mc_lookup_next ? (|tag_prime_hit) : (|tag_current_hit);\n'
        names=outputs.keys()|{'mc_old_slot','mc_prime_slot'}
        for name in sorted(names,key=len,reverse=True):
            block=re.sub(r'\b'+name+r'\b',prefix+name,block)
        text+=block
    template=(HERE/'tb_next_ready_cofactor.sv').read_text()
    assert template.count('  // EXTRACTED_EQUATIONS')==1
    return template.replace('  // EXTRACTED_EQUATIONS',text)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('source','out'):ap.add_argument('--'+name,type=Path,required=True)
    a=ap.parse_args();source=a.source.resolve(strict=True);out=a.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert ROOT.stat().st_dev!=HERE.stat().st_dev and shutil.disk_usage(ROOT).free>4*1024**3
    assert sorted(os.sched_getaffinity(0))==[12,13] and os.environ.get('INVOCATION_ID')
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((cg/'memory.max').read_text())<=512*1024**2
    assert (cg/'memory.swap.max').read_text().strip()=='0' and 0<int((cg/'pids.max').read_text())<=32
    assert sha(source)==recipe.PARENT
    original=source.read_text();changed=recipe.transform(original)
    # Bind the Boolean hit abstraction to the unchanged actual RTL equations.
    for line in ('  assign hit0 = mc_lookup_next ? tag_prime_hit[0] : tag_current_hit[0];',
                 '  assign hit1 = mc_lookup_next ? tag_prime_hit[1] : tag_current_hit[1];',
                 '  assign hit     = hit0 || hit1;'):
        assert original.count(line)==1
    paths=[source,Path(__file__),Path(recipe.__file__),HERE/'tb_next_ready_cofactor.sv',
           HERE/'run_backing_direction_leaf.py',Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'),Path('/usr/bin/z3')]
    pins={str(p.resolve()):sha(p) for p in paths}
    out.mkdir();(out/'ven_l1d.sv').write_text(changed)
    def save(name,value):
        with (out/name).open('x') as stream:json.dump(value,stream,indent=2)
    jobs=[(profile,'positive') for profile in PROFILES]+[('full',mode) for mode in MUTANTS]
    save('started.json',dict(pins=pins,jobs=jobs,invocation=os.environ['INVOCATION_ID']))
    begin=time.monotonic();rows=[];errors=[];proof_ok=False
    def execute(job):
        profile,mode=job;folder=out/(profile+'-'+mode);folder.mkdir()
        tb=folder/'tb.sv';tb.write_text(fixture(original,mode));exe=folder/'test.vvp'
        cmd=['/usr/bin/iverilog','-g2012','-Wall','-s','tb','-o',str(exe),
             *['-D'+d for d in PROFILES[profile]],str(tb)]
        with (folder/'build.log').open('x') as stream:
            built=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
        assert built.returncode==0
        with (folder/'native.log').open('x') as stream:
            child=subprocess.Popen(['/usr/bin/vvp',str(exe)],stdout=stream,stderr=subprocess.STDOUT)
            try:
                affinity=sorted(os.sched_getaffinity(child.pid));assert affinity==[12,13]
                code=child.wait(timeout=60)
            except BaseException:child.kill();child.wait();raise
        log=(folder/'native.log').read_text()
        good=(code==0 and 'NEXT-READY-LEAF-OK samples=196608 ' in log and 'FATAL' not in log) if mode=='positive' else (
            code==1 and 'NEXT-READY-MISMATCH' in log)
        row=dict(profile=profile,mode=mode,passed=good,native_exit=code,compile_exit=built.returncode,
            command=cmd,affinity=affinity,native_pid=child.pid,waited=True,
            artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()})
        print(json.dumps({k:row[k] for k in ('profile','mode','passed','native_exit')}),flush=True)
        return row
    try:
        problem,expected=symbolic();(out/'proof.smt2').write_text(problem)
        proof=subprocess.run(['/usr/bin/z3','-smt2',str(out/'proof.smt2')],capture_output=True,text=True,timeout=30)
        (out/'proof.stdout').write_text(proof.stdout);(out/'proof.stderr').write_text(proof.stderr)
        proof_ok=proof.returncode==0 and proof.stdout.splitlines()==expected and not proof.stderr
        assert proof_ok
        with ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(execute,jobs))
    except Exception as exc:errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines())}
    result=dict(passed=not errors and proof_ok and stable and len(rows)==len(jobs) and all(r['passed'] for r in rows)
        and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
        pins_unchanged=stable,proof_passed=proof_ok,rows=rows,errors=errors,memory_events=events,
        seconds=time.monotonic()-begin,memory_peak=int((cg/'memory.peak').read_text()),
        derivative_sha256=sha(out/'ven_l1d.sv'),whole_cache=False,whole_core=False,
        gameplay_ipc=None,hardware_acceptance=False,standard_suite=False)
    save('closed.json',result);print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
