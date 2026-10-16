"""Diagnose historical coverage drift using complete same-input A/B evidence.

Never turn the failed aggregate gate into a pass. Require every child corpus,
all architectural/cycle records, native commands and all probe fields to agree
with the actual selected parent. No field masks or shortened traces are used.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import run_prime_width_core as runner
from run_next_pair_probe import FIELDS, PATTERN

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'diff'))
import tracefmt

LABELS = ('load-store','held','branch','integer','fp','agi','ref','agi-store')
LEGACY = dict(clocks=21190336,agi=18172,ref=24352,retained=0,
              prime=282808,intent=5616,request=3072,accept=1872,shape_only=1536)


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def compare_pair(old, new):
    a,b=tracefmt.read_trace(str(old)),tracefmt.read_trace(str(new))
    assert (a.mode,a.sys,a.x87)==(b.mode,b.sys,b.x87)
    assert a.records==b.records,('complete stream differs',new)
    assert b.records and [r['n'] for r in b.records]==list(range(len(b.records)))
    return b


def probe_pair(old, new):
    before,after=PATTERN.findall(old),PATTERN.findall(new)
    assert len(before)==len(after)==1
    assert before==after,'same-input probe counters changed'
    return dict(zip(FIELDS,map(int,after[0])))


def native_code(data, label):
    key='exit' if label in ('agi','ref') else 'native_exit'
    assert set(data)=={key}
    assert type(data[key]) is int
    return data[key]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    args=ap.parse_args(); root=args.root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    start,done=load(root/'started.json'),load(root/'closed.json')
    assert done['pins_unchanged'] and not done['passed']
    assert [r['label'] for r in done['rows']]==list(LABELS)
    assert all(r['native_exit']==0 for r in done['rows'])
    assert len(done['errors'])==1 and done['errors'][0]['error']=='AssertionError()'
    tb=done['errors'][0]['traceback']
    line=int(re.search(r'line (\d+), in main',tb).group(1))
    assert runner.derive().splitlines()[line-1].strip().startswith("assert result['coverage'] ==")
    owner=dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-prime-width-core-checks-oct16-r1.service',
        '-p','InvocationID','-p','MainPID','-p','SubState','-p','ExecMainStatus'],text=True).splitlines())
    assert owner==dict(InvocationID='c53eb9d385a0472faf4de153b2b0980c',MainPID='0',
                       SubState='failed',ExecMainStatus='1')
    assert start['invocation']=='8309e8d067bc4c7ba048fe1816700c82'
    pins=dict(start['pins'])
    for p in (Path(__file__).resolve(),root/'started.json',root/'closed.json'):
        pins[str(p)]=sha(p)
    totals=Counter(); coverage=Counter(); per_corpus={}; models={}
    for row in done['rows']:
        folder=root/row['label']
        receipt=folder/('result.json' if row['label']=='held' else 'closed.json')
        child=load(receipt)
        assert sha(receipt)==row['receipt_sha256'] and child['passed'] and not child['errors']
        assert child['inputs_unchanged' if row['label']=='held' else 'pins_unchanged']
        pins[str(receipt)]=sha(receipt)
        for path in (*folder.rglob('started.json'),*folder.rglob('inputs.json'),folder.with_suffix('.driver.json')):
            if not path.exists(): continue
            data=load(path)
            extra=data if path.name=='inputs.json' else data['pins']
            for p,h in extra.items():
                assert p not in pins or pins[p]==h
                pins[p]=h
            pins[str(path)]=sha(path)
        count=Counter()
        for new in sorted(folder.rglob('candidate*.vtrace')):
            assert re.fullmatch(r'candidate-(?:lat|l)\d+-cycle(?:-func)?\.vtrace',new.name)
            old=new.with_name(new.name.replace('candidate-','control-',1))
            trace=compare_pair(old,new)
            count['stream_pairs']+=1
            count[trace.mode+'_records']+=len(trace.records)
            if trace.mode=='cycle':
                count['actual_v_retirements']+=sum(r.get('pipe')=='V' and bool(r.get('paired')) for r in trace.records)
            texts=[]
            for path,model in ((old,runner.PARENT),(new,runner.CANDIDATE)):
                base=str(path)[:-len('.vtrace')]
                command_path=Path(base+'.command.json'); command=load(command_path)
                native=next(Path(s) for s in command if s.endswith('/tb_ventium'))
                if native not in models: models[native]=sha(native)
                assert models[native]==model
                pins[str(native)]=model
                mode='--cycle-func' if trace.mode=='func' else '--cycle'
                assert {'--system','--cosim','--l1-axi',mode}<=set(command)
                result_path=Path(base+'.exit.json')
                if result_path.exists(): code=native_code(load(result_path),row['label'])
                else:
                    result_path=Path(base+'.exit'); code=int(result_path.read_text())
                assert code==133
                stdout,stderr=Path(base+'.stdout'),Path(base+'.stderr')
                text=stdout.read_text(); texts.append(text)
                assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL',text+'\n'+stderr.read_text())
                for p in (path,command_path,result_path,stdout,stderr): pins[str(p)]=sha(p)
            counts=probe_pair(*texts)
            coverage.update(counts); count['probe_pairs']+=1
        assert count['stream_pairs']>0 and count['actual_v_retirements']>0
        per_corpus[row['label']]=dict(count); totals.update(count)
    assert totals['stream_pairs']==totals['probe_pairs']==done['probe_runs']==4240
    assert dict(coverage)==done['coverage']
    assert dict(coverage)!=LEGACY
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(same_input_equivalence=True,legacy_aggregate_gate_passed=False,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,model=runner.CANDIDATE,parent=runner.PARENT,
        owner=owner,totals=dict(totals),per_corpus=per_corpus,
        actual_parent_and_candidate_coverage=dict(coverage),legacy_expected_coverage=LEGACY,
        changed_legacy_fields={k:dict(legacy=LEGACY[k],parent=coverage[k],candidate=coverage[k])
                               for k in FIELDS if coverage[k]!=LEGACY[k]},
        input_pins=len(pins),pins=pins)
    with (root/'parent-equivalence-audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'},indent=2))


if __name__=='__main__':main()
