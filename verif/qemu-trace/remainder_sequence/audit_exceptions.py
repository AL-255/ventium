"""Independent closed-run regrade for the private FPREM exception repair."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import state_vectors as vectors
import prepare_exception
import oracle
import precision_oracle
from run_small_quotient import sha, save
from audit import owner
REPO=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(REPO/'verif/srt'))
import prepare_remainder_exceptions as recipe
sys.path.insert(0,str(REPO/'verif/diff'))
import compare
import tracefmt


def load(p):return json.loads(p.read_text())


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and os.sched_getaffinity(0)=={13}
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.environ['INVOCATION_ID']
    assert not(root/'exception-audit.json').exists()
    archives={str(REPO/'verif/srt/prepare_remainder_exceptions.py'):[
        root/'srt-exceptions-r1/original_prepare_remainder_exceptions.py',
        root/'srt-exceptions-r2/original_prepare_remainder_exceptions.py'],
        str(REPO/'verif/srt/build_remainder_exceptions_core.py'):[
        root/'core-exceptions-r1/original_build_remainder_exceptions_core.py']}
    hashes={};pins=set();archive_uses={};owners={}
    def digest(p):
        p=str(p)
        if p not in hashes:hashes[p]=sha(p)
        return hashes[p]
    def pincheck(items):
        for p,h in items.items():
            pins.add((p,h))
            if digest(p)==h:continue
            choices=[v for v in archives.get(p,[]) if digest(v)==h]
            assert len(choices)==1,(p,h)
            archive_uses[p+':'+h]=str(choices[0])
    runs=[('build-exceptions-r1','ventium-qemu-fprem-exceptions-build-oct15-r1',0,'started.json',True),
        ('exception-state-r1','ventium-fprem-exception-state-oct15-r1',1,'started.json',False),
        ('exception-state-r2','ventium-fprem-exception-state-oct15-r2',0,'started.json',False),
        ('exception-sequence-r1','ventium-fprem-exception-sequence-oct15-r1',0,'started.json',False),
        ('srt-exceptions-r1','ventium-srt-remainder-exceptions-oct15-r1',1,'started.json',True),
        ('srt-exceptions-r2','ventium-srt-remainder-exceptions-oct15-r2',0,'started.json',True),
        ('srt-exceptions-r3','ventium-srt-remainder-exceptions-oct15-r3',0,'started.json',True),
        ('core-exceptions-r1','ventium-srt-remainder-exceptions-core-oct15-r1',0,'build-started.json',True),
        ('core-exceptions-r2','ventium-srt-remainder-exceptions-core-oct15-r2',0,'build-started.json',True),
        ('cold-exception-abort-r1','ventium-fprem-exception-cold-abort-oct15-r1',1,'started.json',False),
        ('cold-exception-de-r2','ventium-fprem-exception-cold-de-oct15-r2',0,'started.json',False),
        ('cold-exception-abort-r2','ventium-fprem-exception-cold-abort-oct15-r2',0,'started.json',False),
        ('cold-exception-small-r1','ventium-fprem-exception-cold-small-oct15-r1',0,'started.json',False),
        ('func-exceptions-r2','ventium-fprem-exceptions-func-oct15-r2',0,'started.json',False),
        ('core-exceptions-r2','ventium-fprem-exceptions-verify-oct15-r2',1,'verify-started.json',False)]
    for directory,unit,exit_code,start_name,scope in runs:
        started=load(root/directory/start_name);pincheck(started['pins'])
        record=owner(unit+'.service',exit_code);owners[unit]=record
        if scope:
            events=[json.loads(line) for line in subprocess.check_output(['journalctl','--user',
                '--no-pager','-o','json','USER_INVOCATION_ID='+started['invocation']],text=True).splitlines()]
            stopped=[e for e in events if e.get('USER_UNIT')=='ventium-ipc-parallel32.scope' and 'MEMORY_PEAK' in e]
            assert len(stopped)==1
            record.update(scope_invocation=started['invocation'],scope_memory_peak=stopped[0]['MEMORY_PEAK'],
                          scope_swap_peak=stopped[0].get('MEMORY_SWAP_PEAK'))
        else:assert record['InvocationID']==started['invocation']
    build=root/'build-exceptions-r1';inventory=load(build/'source.json');built=load(build/'closed.json')
    parent=Path(load(build/'started.json')['parent'])
    assert built['passed'] and built['pins_unchanged'] and len(inventory['after'])==11132
    assert inventory['changed']==[prepare_exception.HELPER]
    assert (build/'source'/prepare_exception.HELPER).read_text()==prepare_exception.transform((parent/'source'/prepare_exception.HELPER).read_text())
    pincheck({str(build/'source'/n):h for n,h in inventory['after'].items()})
    assert digest(built['binary'])==built['sha256']
    sequence={};ref=root/'exception-sequence-r1'
    assert load(ref/'closed.json')['passed'] and load(ref/'closed.json')['pins_unchanged']
    for mode,grader in (('sequence',oracle),('precision',precision_oracle)):
        cases=grader.cases();assert load(ref/mode/'cases.json')==json.loads(json.dumps(cases))
        for label in ('native','control','candidate'):
            receipt=load(ref/mode/(label+'.native.json'))
            assert receipt['native_exit']==0 and receipt['actual_wait'] and receipt['reaped']
            assert receipt['observed_affinity']==[[12]] and digest(ref/mode/(label+'.bin'))==receipt['sha256']
            checked=grader.grade(cases,(ref/mode/(label+'.bin')).read_bytes())
            assert json.loads(json.dumps(checked))==load(ref/mode/(label+'.graded.json'))
            assert checked['passed']==(mode=='precision' or label!='control')
            sequence[mode+'-'+label]={k:v for k,v in checked.items() if k!='errors'}
            sequence[mode+'-'+label]['mismatches']=len(checked['errors'])
    rows=vectors.rows();expected=None;reference={}
    for directory,want in (('exception-state-r1',4068),('exception-state-r2',0)):
        folder=root/directory;closed=load(folder/'closed.json')
        assert load(folder/'cases.json')==json.loads(json.dumps(rows))
        native=(folder/'native.bin').read_bytes();qemu=(folder/'qemu.bin').read_bytes()
        assert len(native)==len(qemu)==len(rows)*108
        got=[]
        for i,r in enumerate(rows):
            n=native[i*108:(i+1)*108];q=qemu[i*108:(i+1)*108]
            assert not vectors.check_native(r,n)
            errors=vectors.compare(r,n,q)
            if errors:got.append(dict(index=i,errors=errors))
        assert got==closed['mismatches'] and len(got)==want and not closed['native_oracle_errors']
        assert closed['passed']==(want==0) and closed['pins_unchanged']
        for execution in closed['executions']:
            assert execution['native_exit']==0 and execution['affinity']==[[12]]
            assert digest(folder/(execution['name']+'.bin'))==execution['sha256']
        reference[directory]=dict(cases=len(rows),mismatches=len(got))
        if not want:expected=[native[i:i+108] for i in range(0,len(native),108)]
    leaf=root/'srt-exceptions-r3';latencies={};engine={}
    for label,want in (('parent',6860),('candidate',0)):
        folder=leaf/label;found=re.findall(r'^ROW (\d+) ([0-9a-f]{216}) (\d+) (\d+)$',(folder/'run.log').read_text(),re.M)
        assert len(found)==len(rows);diffs=[];latencies[label]=[]
        for i,((number,data,latency,fault),r,n) in enumerate(zip(found,rows,expected)):
            assert int(number)==i and bool(int(fault))==bool(vectors.flags(r)&0x40)
            errors=vectors.compare(r,n,int(data,16).to_bytes(108,'little'))
            if errors:diffs.append(dict(index=i,errors=errors))
            latencies[label].append(int(latency))
        assert diffs==load(folder/'graded.json')['mismatches'] and len(diffs)==want
        engine[label]=dict(cases=len(rows),mismatches=len(diffs))
    assert all(b<=a for a,b in zip(latencies['parent'],latencies['candidate']))
    # Same instruction latency for every architecturally valid input; only
    # unsupported encodings (which formerly entered recurrence) get shorter.
    for r,a,b in zip(rows,latencies['parent'],latencies['candidate']):
        if all(vectors.classify(x)!='unsupported' for x in (r['a'],r['b'])):assert a==b
    core=root/'core-exceptions-r2';prepared=load(core/'prepared.json');cc=load(core/'build-closed.json')
    cp=Path(prepared['parent'])/'candidate';source=core/'candidate'
    files=sorted(p for p in source.rglob('*') if p.is_file());assert len(files)==195
    delta=sorted(str(p.relative_to(source)) for p in files if digest(p)!=digest(cp/p.relative_to(source)))
    assert delta==sorted(recipe.PARENTS)==prepared['changes'] and len(prepared['definitions'])==152
    for n in delta:
        assert (source/n).read_text()==recipe.transform((cp/n).read_text(),n)==(leaf/'candidate/source'/n).read_text()
    assert cc['passed'] and cc['pins_unchanged'] and digest(core/'obj/tb_ventium')==cc['binary_sha256']
    cold={}
    for directory in ('cold-exception-de-r2','cold-exception-abort-r2','cold-exception-small-r1'):
        folder=root/directory;c=load(folder/'closed.json');wrapper=load(folder.with_suffix('.driver.json'));pincheck(wrapper['pins'])
        assert c['passed'] and c['pins_unchanged'] and c['axi_backend'] and c['actual_v_retirements']>0
        with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
            assert compare.main(['--mode','func',str(folder/'qemu.vtrace'),str(folder/'rtl.vtrace')])==0
        for label in ('qemu','rtl'):
            t=tracefmt.read_trace(str(folder/(label+'.vtrace'))).records
            assert int(t[-1]['ebx'],16)==0 and int(t[-1]['ebp'],16)==1
        cold[directory]=dict(records=len(t),v_retirements=c['actual_v_retirements'])
    # Do not convert the earlier abort trace divergence into a pass.
    assert not load(root/'cold-exception-abort-r1/closed.json')['passed']
    canonical=load(core/'verify-closed.json')
    assert canonical['canonical_gate_native_exit']==2 and not canonical['canonical_gate_passed'] and canonical['pins_unchanged']
    traces=sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'));assert len(traces)==20
    for p in traces:assert tracefmt.read_trace(str(p)).records==tracefmt.read_trace(str(cp.parent/'generic-work'/p.name)).records
    func=root/'func-exceptions-r2';fc=load(func/'closed.json');fs=load(func/'started.json')
    pincheck(load(func.with_suffix('.driver.json'))['pins'])
    assert fc['passed'] and fc['pins_unchanged'] and len(fc['rows'])==108
    goldens={}
    for p in (func/'private-enabled-cache').glob('*.vtrace'):
        t=tracefmt.read_trace(str(p));name=re.search(r'elf=(\w+)\.func\.elf ',t.hdr['note']).group(1)
        assert name not in goldens;goldens[name]=p
    assert len(goldens)==108
    unmasked=total=paired=0
    for job,row in zip(fs['jobs'],fc['rows']):
        name=job[1];assert row['name']==name and row['passed'] and row['native_worker_exit']==0 and row['actual_wait']
        assert row['affinity_verified'] and not row['error']
        rtl=func/'work'/(name+'.func_rtl.vtrace');gold=goldens[name]
        r,g=tracefmt.read_trace(str(rtl)),tracefmt.read_trace(str(gold));assert len(r.records)==len(g.records)
        total+=len(r.records)
        with contextlib.redirect_stdout(io.StringIO()),contextlib.redirect_stderr(io.StringIO()):
            unmasked+=compare.main(['--mode','func',str(gold),str(rtl)])==0
        log=(func/'work'/(name+'.func_rtl.log')).read_text();assert '--l1-axi selected' in log
        paired+=int(re.search(r'pairedV=(\d+)',log).group(1))
    assert (total,unmasked)==(80800,105) and paired>0
    save(root/'exception-audit.json',dict(passed=True,input_pins=len(pins),archive_uses=archive_uses,
        owners=owners,qemu_sha256=built['sha256'],model_sha256=cc['binary_sha256'],reference=reference,
        sequences=sequence,engine=engine,
        cold=cold,functional_passes=108,raw_unmasked_functional_passes=105,functional_records=total,
        functional_v_retirements=paired,no_instruction_latency_increase=True,cycle_streams_parent_identical=20,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        unmasked_underflow_qualified=False))
    print('FPREM-EXCEPTION-AUDIT-OK',len(pins),cc['binary_sha256'],flush=True)


if __name__=='__main__':main()
