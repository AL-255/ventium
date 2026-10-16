"""Recheck retained native logs, exact matrix, input hashes and terminal owner.

This is hosted serial transport verification, not Windows UI or FPGA proof.
"""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import re
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run', type=Path, required=True)
    ap.add_argument('--owner', required=True)
    a=ap.parse_args(); root=a.run.resolve(strict=True)
    assert __debug__ and root.parent == Path(
        '/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
    started=json.loads((root/'started.json').read_text())
    closed=json.loads((root/'closed.json').read_text())
    assert closed['passed'] and not closed['errors'] and closed['pins_unchanged']
    assert not any(closed['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    assert not closed['physical_fpga'] and not closed['standard_suite']
    assert not closed['universal_keyboard_contract'] and closed['gameplay_ipc'] is None
    assert closed['smoke'] == started['smoke']
    props=subprocess.check_output(['systemctl','--user','show',a.owner,
        '-p','ActiveState','-p','SubState','-p','InvocationID','-p','MainPID',
        '-p','ExecMainStatus','-p','Result'],text=True)
    owner=dict(line.split('=',1) for line in props.splitlines())
    assert owner == dict(ActiveState='active',SubState='exited',MainPID='0',
        InvocationID=started['invocation'],ExecMainStatus='0',Result='success')
    assert all(sha(p)==h for p,h in started['pins'].items())
    points=(0,) if started['smoke'] else range(9)
    expected={('candidate',*v) for v in itertools.product(
        (3125000,40000000),(0,1),(0,1),(0,1),points)}
    expected.update(('parent',*v,0) for v in itertools.product(
        (3125000,40000000),(0,1),(0,1),(0,1)))
    assert {tuple(v) for v in started['cases']} == expected
    assert len(closed['rows']) == len(expected)
    assert {tuple(row['case']) for row in closed['rows']} == expected
    assert len(closed['builds']) == 8 and all(b['native_exit']==0 for b in closed['builds'])
    expected_builds=set()
    for label,hz,ack in itertools.product(('parent','candidate'),(3125000,40000000),(0,1)):
        cmd=['-g2012','-Wall','-s','tb_hosted_resync',f'-Ptb_hosted_resync.HZ={hz}',
             '-DVEN_KBC_FAST',*(['-DVEN_KBD_AUTOACK'] if ack else []),'-o',
             str(root/f'{label}-{hz}-a{ack}.vvp'),
             *[str(root/'source'/n) for n in
               (label+'.v','simple_fifo.v','ven_ps2_device.sv','tb_hosted_resync.sv')]]
        expected_builds.add(tuple(cmd))
    actual_builds=set()
    for build in closed['builds']:
        cmd=build['command']
        assert Path(cmd[0]).name=='iverilog' and str(Path(cmd[0]).resolve()) in started['pins']
        actual_builds.add(tuple(str(Path(v).resolve()) if v.startswith('/') else v for v in cmd[1:]))
    assert actual_builds==expected_builds
    artifacts={}; positive=red=0
    for row in closed['rows']:
        label,hz,ack,mouse,reset,point=row['case']
        log=Path(row['log']); assert log.parent.resolve() == root
        assert sha(log)==row['log_sha256']
        assert row['passed'] and row['waited'] and row['affinity']==[12,13]
        assert not Path('/proc',str(row['native_pid'])).exists()
        image=root/f'{label}-{hz}-a{ack}.vvp'
        assert Path(row['command'][1]).resolve() == image
        assert row['command'][2:]==[f'+mouse={mouse}',f'+reset={reset}',f'+point={point}']
        text=log.read_text()
        if label=='candidate':
            expected_line=(f'HOSTED-RESYNC-OK hz={hz} mouse={mouse} reset={reset} '
                f'point={point} aborts={int(point<8)} completed={1+int(point==8)} '
                f'edges={11+(1,1,5,8,9,10,10,11,11)[point]}')
            lines=text.splitlines()
            assert len(lines)==2 and lines[0]==expected_line, text
            finish=re.fullmatch(r'(.+\.sv):(\d+): \$finish called at (\d+) \(1ps\)',lines[1])
            assert finish and int(finish[3])>0, text
            tb=root/'source/tb_hosted_resync.sv'
            assert Path(finish[1]).resolve()==tb
            assert tb.read_text().splitlines()[int(finish[2])-1].strip()=='$finish;'
            assert row['native_exit']==0 and row['correctness'] and not row['expected_red_witness']
            positive+=1
        else:
            assert row['native_exit']==1 and not row['correctness'] and row['expected_red_witness']
            assert len(re.findall(r'FATAL: .*RESYNC-INHIBIT-MISSING',text))==1
            assert 'HOSTED-RESYNC-OK' not in text
            red+=1
        artifacts[str(log)]=sha(log); artifacts[str(image)]=sha(image)
    for p in (root/'started.json',root/'closed.json',Path(__file__).resolve()):
        artifacts[str(p)]=sha(p)
    result=dict(passed=True,owner=owner,source_pins_checked=len(started['pins']),
        candidate_cases=positive,parent_red_witnesses=red,smoke=started['smoke'],
        artifacts=artifacts,physical_fpga=False,standard_suite=False,
        universal_keyboard_contract=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'}))


if __name__=='__main__': main()
