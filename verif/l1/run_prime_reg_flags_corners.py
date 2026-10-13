"""Cold whole-core branch tests: forwarded shift/preserved flags and rejection.

Reuse the complete native QEMU/state/cycle/hint checker. Only the fixture U
instruction changes; no register/cache injection or altered comparisons.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import run_mc_address_branch as original
from run_intent_ready_pairs import replace
from run_prime_reg_flags_core import PARENT,CANDIDATE
from run_parallel_tag_cache import sha

REPO=Path(__file__).resolve().parents[2]
PATTERN=re.compile(r'^PRIME-REG-FLAGS offers=(\d+) commits=(\d+) rejects=(\d+) alu=(\d+) shift=(\d+) preserve=(\d+)$',re.M)
FIELDS=('offers','commits','rejects','alu','shift','preserve')


def fixture(source,variant):
    if variant=='alternating':
        source=replace(source,'    xorl %ebx,%ebx','    movl $1,%ebx')
        return replace(source,'    testl $1,%ecx\nhot_branch:\n    jne branch_taken',
                       '    xorl %ebx,%edi\nhot_branch:\n    jne branch_taken')
    if variant=='shift':
        old='    testl %edi,%edi\n    jmp hot_u'
        assert source.count(old)==2
        source=source.replace(old,'    xorl %esi,%esi\n    jmp hot_u')
        operation='    shll $1,%edi'
    else:
        assert variant=='preserve'
        operation='    movl $0,%esi'
    return replace(source,'    testl %edi,%edi\nhot_branch:\n    je branch_taken',
                   operation+'\nhot_branch:\n    je branch_taken')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('parent','candidate','out'):ap.add_argument('--'+key,required=True,type=Path)
    args=ap.parse_args()
    root=args.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert os.environ.get('INVOCATION_ID')
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    models={n:getattr(args,n).resolve(strict=True) for n in ('parent','candidate')}
    assert sha(models['parent'])==PARENT and sha(models['candidate'])==CANDIDATE
    source=REPO/'verif/fe_pipe/raw-branch-prime.S'
    runner=Path(original.__file__)
    pins={str(p):sha(p) for p in (Path(__file__).resolve(),source,runner,*models.values(),
          REPO/'verif/l1/run_prime_reg_flags_core.py',REPO/'verif/l1/run_intent_ready_pairs.py')}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as stream:json.dump(value,stream,indent=2)
    commands=[]
    for variant in ('shift','preserve','alternating'):
        asm=root/(variant+'.S');asm.write_text(fixture(source.read_text(),variant))
        text=replace(runner.read_text(),'HERE = Path(__file__).resolve().parent',
                     'HERE = Path('+repr(str(runner.parent))+')')
        text=replace(text,"    source = REPO/'verif/fe_pipe/raw-branch-prime.S'",'    source = Path('+repr(str(asm))+')')
        text=replace(text,"        with socket.socket() as sock:\n            sock.bind(('127.0.0.1', 0))\n            port = sock.getsockname()[1]\n",
                     '        port = 26500 + 64 * kind + 32 * reloc + offset\n')
        driver=root/(variant+'.py');driver.write_text(text)
        compile(text,str(driver),'exec')
        for path in (asm,driver):pins[str(path)]=sha(path)
        commands.append((variant,[sys.executable,'-B',str(driver),'--control',str(models['parent']),
             '--candidate',str(models['candidate']),'--out',str(root/variant),'--kind',
             '3' if variant=='alternating' else '0','--offset','0','--offset','4','--offset','8','--workers','4']))
    save('started.json',dict(pins=pins,commands=commands,invocation=os.environ['INVOCATION_ID']))
    result=dict(passed=False,rows=[],errors=[],standard_suite=False,gameplay_ipc=None)
    begin=time.monotonic()
    try:
        for variant,command in commands:
            with (root/(variant+'.log')).open('x') as stream:
                child=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=120)
            checked=json.loads((root/variant/'closed.json').read_text())
            assert child.returncode==0 and checked['passed'] and checked['pins_unchanged'] and not checked['errors'],variant
            assert len(checked['measurements'])==24
            counts={key:0 for key in FIELDS};runs=0
            for path in (root/variant).rglob('candidate*.stdout'):
                rows=PATTERN.findall(path.read_text());assert len(rows)==1
                counts={key:counts[key]+int(value) for key,value in zip(FIELDS,rows[0])};runs+=1
                pins[str(path)]=sha(path)
            assert runs==24 and counts['offers']==counts['commits']+counts['rejects']
            assert counts['commits']>0
            required={'shift':'shift','preserve':'preserve','alternating':'rejects'}[variant]
            assert counts[required]>0,(variant,counts)
            result['rows'].append(dict(variant=variant,native_exit=child.returncode,runs=runs,counts=counts,
                 checker_sha256=sha(root/variant/'closed.json')))
            print(result['rows'][-1],flush=True)
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()),pins=pins)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
