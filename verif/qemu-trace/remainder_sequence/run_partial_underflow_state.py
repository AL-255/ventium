"""Native/QEMU/shared-FPU partial-underflow diagnostic with existing binaries."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys
import traceback

import partial_underflow_vectors as vectors
from run_small_quotient import sha, save
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'verif/srt'))
from remainder_execution import execute


def main():
    ap=argparse.ArgumentParser(description=__doc__); ap.add_argument('--out',type=Path,required=True)
    root=ap.parse_args().out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={12}
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free>4*1024**3+32*1024**2
    evidence=scratch/'ventium-fprem-sequence.iSZ9BAj4'; leaf=evidence/'srt-underflow-r2'
    probe=evidence/'exception-state-r2/probe'; qemu=evidence/'build-underflow-r1/build/qemu-i386'
    control=evidence/'srt-exceptions-r3/candidate/obj/test'; model=leaf/'obj/test'
    assert sha(probe)=='d380fe69cd85c632abe444e0adcc098ce9adaef47a79a554dffde9de438a3bd3'
    assert sha(qemu)=='998b4f5d3eda4493f391ea6775adcc88f3dd810ba2829f7d635cac27877f9b85'
    assert sha(control)=='b8b49226de20f1ec0bdf263865909b80d3dd761137d2977fe55e5f868621e8d0'
    assert sha(model)=='899139eaff1daa55ba00ed3cfc9003614775b36bebbea8c89f303f8544ab623b'
    before=json.loads((leaf/'started.json').read_text()); closed=json.loads((leaf/'closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged']
    pins=dict(before['pins'])
    for p in (Path(__file__),Path(vectors.__file__),Path(vectors.exact.__file__),
              Path(vectors.state.__file__),Path(vectors.oracle.__file__),
              REPO/'verif/srt/remainder_execution.py',probe,qemu,control,model,leaf/'started.json',leaf/'closed.json'):
        pins[str(p.resolve())]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    rows=vectors.rows();root.mkdir();save(root/'cases.json',rows)
    inp=root/'stdin.bin';inp.write_bytes(b''.join(map(vectors.state.pack,rows)))
    vectorfile=root/'vectors.txt'
    with vectorfile.open('x') as f:
        for r in rows: f.write(f"{r['cw']:04x} {r['sw']:04x} {r['tag']:04x} {r['a'][0]:04x}{r['a'][1]:016x} {r['b'][0]:04x}{r['b'][1]:016x} {r['op']}\n")
    save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cases=len(rows),
        legal_partial_bits=list(range(32,64)),whole_core=False,compiler_launched=False))
    result=dict(passed=False,errors=[],executions=[],implementations={},canonical_gate_passed=False,
                standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    try:
        for label,command,stdin in (('native',[probe],inp),('reference',[qemu,'-cpu','pentium',probe],inp),
            ('control',[control,'+vectors='+str(vectorfile)],None),('candidate',[model,'+vectors='+str(vectorfile)],None)):
            result['executions'].append(execute(label,command,root,stdin))
            raw=(root/(label+'.out')).read_bytes()
            if label in ('native','reference'):
                assert len(raw)==108*len(rows); outputs=[raw[i:i+108] for i in range(0,len(raw),108)]
            else:
                text=raw.decode();found=re.findall(r'^ROW (\d+) ([0-9a-f]{216}) (\d+) (\d+)$',text,re.M)
                assert len(found)==len(rows) and f'REM-EXCEPTION-TRANSPORT-OK rows={len(rows)} resets=3' in text
                assert [int(r[0]) for r in found]==list(range(len(rows)))
                outputs=[int(r[1],16).to_bytes(108,'little') for r in found]
            failures=[]
            for i,(r,v) in enumerate(zip(rows,outputs)):
                errors=vectors.check(r,v)
                if errors: failures.append(dict(index=i,errors=errors,raw=v.hex()))
            save(root/(label+'-graded.json'),dict(failures=failures))
            result['implementations'][label]=dict(cases=len(rows),failures=len(failures),passed=not failures)
        result['passed']=all(result['implementations'][n]['passed'] for n in ('native','reference','candidate')) \
            and result['implementations']['control']['failures']==720
    except Exception as e: result['errors'].append(dict(error=repr(e),traceback=traceback.format_exc()))
    result['pins_unchanged']=all(sha(p)==h for p,h in pins.items());result['passed'] &= result['pins_unchanged']
    save(root/'closed.json',result);print(json.dumps(result,indent=2),flush=True);return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
