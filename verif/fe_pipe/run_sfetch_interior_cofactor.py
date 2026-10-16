"""Source-extracted two-profile miter and unrestricted binary width proof."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import prepare_sfetch_interior_cofactor as recipe

HERE = Path(__file__).resolve().parent
MODES = ('positive','no-page-clip','wrong-interior','raw-boundary')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def fixture(source, mode):
    want = recipe.want_block(source)
    helper, select = recipe.HELPER, recipe.NEW_SELECT
    if mode == 'no-page-clip':
        helper = helper.replace("sfetch_demand_addr[11:0] > 12'hffc", "1'b0")
    elif mode == 'wrong-interior':
        helper = helper.replace("sfetch_interior_size = 3'd4;", "sfetch_interior_size = 3'd3;")
    elif mode == 'raw-boundary':
        select = select.replace('sfetch_beat_size_q;', 'sfetch_want_size;')
    else:
        assert mode == 'positive'
    equations = '  logic [2:0] sfetch_want_size, old_size, new_size;\n'+want
    equations += recipe.OLD_SELECT.replace('assign sfetch_demand_size =','assign old_size =')
    equations += helper+select.replace('assign sfetch_demand_size =','assign new_size =')
    return (HERE/'tb_sfetch_interior_cofactor.sv').read_text().replace('  // EXTRACTED_EQUATIONS',equations)


def symbolic():
    # This proof includes arbitrary counts/stage sizes, not just reachable
    # multiples of four. The native miter separately binds it to actual RTL.
    text = '''(set-logic QF_BV)
(declare-const addr (_ BitVec 12))
(declare-const need (_ BitVec 5))
(declare-const valid (_ BitVec 5))
(declare-const stage (_ BitVec 3))
(declare-const interior Bool)
(define-fun delta () (_ BitVec 5) (bvsub need valid))
(define-fun raw () (_ BitVec 3) (ite (bvuge delta #b00100) #b100 ((_ extract 2 0) delta)))
(define-fun rem () (_ BitVec 3) ((_ extract 2 0) (bvsub #b1000000000000 ((_ zero_extend 1) addr))))
(define-fun clip ((n (_ BitVec 3))) (_ BitVec 3)
  (ite (and (bvugt addr #xffc) (bvugt n rem)) rem n))
(define-fun want () (_ BitVec 3) (clip (ite interior #b100 raw)))
(define-fun old () (_ BitVec 3) (ite interior want stage))
(define-fun new () (_ BitVec 3) (ite interior (clip #b100) stage))
'''
    for expr in ('(not (= old new))', '(= old #b100)',
                 '(not (= old (ite interior #b100 stage)))',
                 '(not (= old (ite interior (clip #b011) stage)))',
                 '(not (= old (ite interior (clip #b100) want)))'):
        text += '(push 1)\n(assert '+expr+')\n(check-sat)\n(pop 1)\n'
    return text, ['unsat','sat','sat','sat','sat']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    a = ap.parse_args(); source=a.source.resolve(strict=True); out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert out.is_relative_to(scratch) and not out.exists() and out!=scratch
    assert scratch.stat().st_dev!=HERE.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0)=={18,19}
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    assert 0<int((group/'memory.max').read_text())<=512*1024**2
    assert (group/'memory.swap.max').read_text().strip()=='0'
    original=source.read_text(); changed=recipe.transform(original)
    inputs=(source,Path(__file__),Path(recipe.__file__),HERE/'tb_sfetch_interior_cofactor.sv',
            Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'),Path('/usr/bin/z3'))
    pins={str(p.resolve()):sha(p) for p in inputs}
    out.mkdir(mode=0o700)
    def save(name,value):
        with (out/name).open('x') as stream:json.dump(value,stream,indent=2)
    with (out/'core.sv').open('x') as stream:stream.write(changed)
    jobs=[(False,'positive')]+[(True,mode) for mode in MODES]
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],jobs=jobs))
    begin=time.monotonic(); rows=[]; errors=[]; proof_ok=False
    def execute(job):
        full,mode=job; work=out/(('interior16-' if full else 'default-')+mode);work.mkdir()
        sv=work/'tb.sv';exe=work/'test.vvp'
        with sv.open('x') as stream:stream.write(fixture(original,mode))
        command=['/usr/bin/iverilog','-g2012','-Wall','-s','tb','-o',str(exe),
                 *(['-DVEN_SFETCH16_DEMAND'] if full else []),str(sv)]
        with (work/'build.log').open('x') as stream:
            built=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=30)
        assert built.returncode==0,(mode,'compile')
        with (work/'native.log').open('x') as stream:
            child=subprocess.Popen(['/usr/bin/vvp',str(exe)],stdout=stream,stderr=subprocess.STDOUT)
            try:
                affinity=sorted(os.sched_getaffinity(child.pid));assert affinity==[18,19]
                code=child.wait(timeout=60)
            except BaseException:child.kill();child.wait();raise
        log=(work/'native.log').read_text()
        passed=(code==0 and 'SFETCH-INTERIOR-COFACTOR-OK checks=196608' in log and 'FATAL' not in log) if mode=='positive' else (
                code==1 and 'SFETCH-INTERIOR-MISMATCH' in log)
        return dict(profile='interior16' if full else 'default',mode=mode,passed=passed,
                    command=command,native_exit=code,compile_exit=built.returncode,pid=child.pid,
                    affinity=affinity,waited=True,proc_gone=not Path('/proc',str(child.pid)).exists())
    try:
        problem,expected=symbolic()
        with (out/'proof.smt2').open('x') as stream:stream.write(problem)
        proof=subprocess.run(['/usr/bin/z3','-smt2',str(out/'proof.smt2')],capture_output=True,text=True,timeout=30)
        for name,text in (('proof.stdout',proof.stdout),('proof.stderr',proof.stderr)):
            with (out/name).open('x') as stream:stream.write(text)
        proof_ok=proof.returncode==0 and proof.stdout.splitlines()==expected and not proof.stderr
        assert proof_ok
        with ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(execute,jobs))
    except Exception as exc:errors.append(repr(exc))
    events={k:int(v) for k,v in (line.split() for line in (group/'memory.events').read_text().splitlines())}
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=proof_ok and stable and not errors and len(rows)==len(jobs)
                and all(r['passed'] and r['proc_gone'] for r in rows)
                and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
                proof_passed=proof_ok,pins_unchanged=stable,rows=rows,errors=errors,
                memory_events=events,memory_peak=int((group/'memory.peak').read_text()),
                seconds=time.monotonic()-begin,derivative_sha256=sha(out/'core.sv'),
                artifacts={str(p):sha(p) for p in out.rglob('*') if p.is_file()},
                whole_core=False,standard_suite=False,physical_fpga=False,gameplay_ipc=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
