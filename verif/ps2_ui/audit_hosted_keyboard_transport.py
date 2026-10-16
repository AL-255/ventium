"""Recheck the closed physical-pin keyboard matrix and parity negative control."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import run_hosted_keyboard_transport as run


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True);ap.add_argument('--owner',required=True)
    a=ap.parse_args();root=a.run.resolve(strict=True)
    assert __debug__ and root.parent==run.ROOT
    start=json.loads((root/'started.json').read_text())
    done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert not start['autoack'] and start['physical_keyboard_pins']
    assert not done['original_run_passed'] and not done['physical_fpga'] and not done['standard_suite']
    assert done['gameplay_ipc'] is None
    assert all(run.sha(p)==h for p,h in done['pins'].items())
    assert all(done['pins'][p]==h for p,h in start['pins'].items())
    assert not any(done['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',a.owner,
        '-p','ActiveState','-p','SubState','-p','MainPID','-p','ExecMainStatus','-p','InvocationID','-p','Result'],text=True).splitlines())
    assert owner==dict(ActiveState='active',SubState='exited',MainPID='0',ExecMainStatus='0',
        InvocationID=start['invocation'],Result='success')
    assert (root/'source/tb_physical_keyboard.sv').read_text()==run.keyboard_tb(
        (root/'source/tb_ps2_device.sv').read_text())
    assert len(done['builds'])==3
    assert [r['label'] for r in done['rows']]==['parent','candidate','bad-parity']
    artifacts={};latencies={}
    for build,row in zip(done['builds'],done['rows']):
        label=row['label'];cmd=build['command']
        expected=['-g2012','-Wall','-s','tb_ps2_device','-DVEN_KBC_FAST','-o',str(root/(label+'.vvp')),
            str(root/'source'/('parent.v' if label=='parent' else 'candidate.v')),
            str(root/'source/simple_fifo.v'),str(root/'source'/('bad-parity.sv' if label=='bad-parity' else 'ven_ps2_device.sv')),
            str(root/'source/tb_physical_keyboard.sv')]
        assert Path(cmd[0]).name=='iverilog' and build['native_exit']==0
        assert [str(Path(v).resolve()) if v.startswith('/') else v for v in cmd[1:]]==expected
        assert not any('AUTOACK' in v for v in cmd)
        assert row['passed'] and row['waited'] and row['affinity']==[12,13]
        assert not Path('/proc',str(row['native_pid'])).exists()
        image=root/(label+'.vvp');log=root/(label+'.log')
        assert run.sha(image)==row['image_sha256'] and run.sha(log)==row['log_sha256']
        assert Path(row['command'][0]).name=='vvp' and len(row['command'])==2
        assert Path(row['command'][1]).resolve()==image
        text=log.read_text()
        if label=='bad-parity':
            assert row['native_exit']==1 and text.count('TX bit/parity mismatch')==1
            assert 'PS2-DEVICE-ALL-OK' not in text
        else:
            assert row['native_exit']==0 and run.grade(0,text)
            observations=re.findall(r'PS2-RECEIVE-LATENCY hz=(\d+) byte=([0-9a-f]+) clocks=(\d+) limit=(\d+)',text)
            latencies[label]=[]
            for hz in (3125000,40000000):
                rows=[(int(b,16),int(c),int(l)) for h,b,c,l in observations if int(h)==hz]
                assert [b for b,_,_ in rows]==[255,242,244,245,243,232,233,235,0,165,242,244,150,105,129,244,195,255]
                limit=2*8192+24*((hz+24999)//25000)+256
                assert all(0<=c<l==limit for _,c,l in rows)
                latencies[label].append(dict(hz=hz,first=rows[0][1],last=rows[-1][1],limit=limit))
        artifacts[str(image)]=run.sha(image);artifacts[str(log)]=run.sha(log)
    for p in (root/'started.json',root/'closed.json',Path(__file__).resolve(),Path(run.__file__).resolve()):
        artifacts[str(p)]=run.sha(p)
    result=dict(passed=True,owner=owner,source_pins_checked=len(done['pins']),
        candidate_checks=98,parent_checks=98,parity_mutant_rejected=True,latencies=latencies,
        artifacts=artifacts,physical_fpga=False,standard_suite=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as stream:json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'}))


if __name__=='__main__':main()
