#!/usr/bin/env python3
"""Bounded four-state test of the actual transformed SRT CLZ; no core build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from prepare_rem_clz_tree import OLD, NEW, transform

HERE=Path(__file__).resolve().parent


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    args=ap.parse_args()
    assert __debug__ and os.environ['TMPDIR']=='/home/yukidama/external/tmp'
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0)=={0}
    out=args.out.resolve(); source=args.source.resolve(strict=True)
    assert not out.exists() and out.is_relative_to(Path(os.environ['TMPDIR']).resolve())
    original=source.read_text(); proposed=transform(original)
    assert proposed.count(NEW)==1 and proposed.count(OLD)==1
    out.mkdir()
    (out/'source.sv').write_text(original)
    (out/'candidate.sv').write_text(proposed)
    oracle=OLD.replace('rem_clz64(','rem_clz64_original(')
    candidate=proposed[proposed.index(NEW):proposed.index(NEW)+len(NEW)]
    cases={
        'candidate':candidate,
        'bad_zero':candidate.replace("else return 7'd64;","else return 7'd0;"),
        'bad_half':candidate.replace('part << 32','part << 31'),
        # Ternary merges an unknown decision, unlike the original procedural if.
        'bad_unknown':candidate.replace("if (|x) return n;\n    else return 7'd64;",
                                        "return (|x) ? n : 7'd64;"),
    }
    assert len(set(cases.values()))==4
    for name,body in cases.items():
        d=out/name;d.mkdir()
        (d/'functions.svh').write_text(oracle+'\n'+body.replace('rem_clz64(','rem_clz64_tree(')+'\n')
    pins={str(p):sha(p) for p in [source,Path(__file__),HERE/'prepare_rem_clz_tree.py',
        HERE/'tb_rem_clz_tree.sv',Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'),
        out/'source.sv',out/'candidate.sv',*[out/name/'functions.svh' for name in cases]]}
    (out/'started.json').write_text(json.dumps(dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        source=str(source),affinity=sorted(os.sched_getaffinity(0)),gameplay_ipc=None),indent=2))
    start=time.monotonic();result=dict(passed=False,rows=[],errors=[])
    try:
        for name in cases:
            d=out/name
            command=['/usr/bin/iverilog','-g2012','-s','tb_rem_clz_tree','-I'+str(d),
                '-o',str(d/'test.vvp'),str(HERE/'tb_rem_clz_tree.sv')]
            with (d/'compile.log').open('x') as f:
                built=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=15)
            assert built.returncode==0, str(d/'compile.log')
            with (d/'run.log').open('x') as f:
                native=subprocess.run(['/usr/bin/vvp',str(d/'test.vvp')],stdout=f,stderr=subprocess.STDOUT,timeout=120)
            log=(d/'run.log').read_text()
            if name=='candidate':
                assert native.returncode==0 and 'REM-CLZ-TREE-OK checks=311428' in log
            else:
                assert native.returncode==1 and 'REM-CLZ-MISMATCH' in log
                assert 'REM-CLZ-TREE-OK' not in log
            result['rows'].append(dict(name=name,native_exit=native.returncode,expected_negative=name!='candidate',
                compiler_command=command,log_sha256=sha(d/'run.log')))
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(inputs_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-start,
            standard_suite=False,whole_core=False,area_measured=False,frequency_measured=False,gameplay_ipc=None)
        result['passed'] &= result['inputs_unchanged']
        (out/'closed.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result),flush=True)
    raise SystemExit(0 if result['passed'] else 1)


if __name__=='__main__':main()
