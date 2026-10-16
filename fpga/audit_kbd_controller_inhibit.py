"""Regrade the closed physical-pin 8042/injector matrix independently."""
import argparse
import itertools
import json
from pathlib import Path
import re
import subprocess

import run_kbd_controller_inhibit as run


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True)
    ap.add_argument('--unit',required=True)
    args=ap.parse_args();root=args.run.resolve(strict=True)
    assert __debug__ and root.parent==run.ROOT
    start=json.loads((root/'started.json').read_text())
    done=json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert not done['physical_fpga'] and not done['standard_suite'] and not done['debug_mmio_tested']
    assert done['gameplay_ipc'] is None
    assert all(run.sha(p)==h for p,h in start['pins'].items())
    assert start['definitions']==['VEN_KBC_FAST','VEN_KBD_AUTOACK']
    assert not any(done['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    owner=dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show',args.unit,'-p','ActiveState','-p','SubState',
        '-p','MainPID','-p','ExecMainStatus','-p','InvocationID','-p','Result'],text=True).splitlines())
    assert owner==dict(ActiveState='active',SubState='exited',MainPID='0',ExecMainStatus='0',
                      InvocationID=start['invocation'],Result='success')
    expected=[['candidate',hz,phase,reset] for hz,phase,reset in
              itertools.product((3125000,40000000),range(26),(0,1))]+[
                  ['parent',hz,20,0] for hz in (3125000,40000000)]
    assert start['cases']==expected and [r['case'] for r in done['rows']]==expected
    assert len(done['builds'])==4
    artifacts={}
    for (label,hz),build in zip(itertools.product(('parent','candidate'),(3125000,40000000)),done['builds']):
        cmd=build['command'];src=root/'source'
        assert Path(cmd[0]).name=='iverilog' and build['native_exit']==0
        expected_cmd=['-g2012','-Wall','-s','tb_kbd_controller_inhibit',
            f'-Ptb_kbd_controller_inhibit.HZ={hz}','-DVEN_KBC_FAST','-DVEN_KBD_AUTOACK',
            '-o',str(root/f'{label}-{hz}.vvp'),*[str(src/n) for n in
                ('controller.v','simple_fifo.v',label+'.v','tb_kbd_controller_inhibit.sv')]]
        assert [str(Path(v).resolve()) if v.startswith('/') else v for v in cmd[1:]]==expected_cmd
        log=root/f'{label}-{hz}-compile.log'
        assert Path(build['log']).resolve()==log and run.sha(log)==build['log_sha256']
        artifacts[str(log)]=run.sha(log)
    for row in done['rows']:
        label,hz,phase,reset=row['case'];red=label=='parent'
        assert row['passed'] and row['waited'] and row['native_exit']==int(red)
        assert row['affinity']==[12,13] and not Path('/proc',str(row['native_pid'])).exists()
        log=root/f'{label}-{hz}-p{phase}-r{reset}.log';image=root/f'{label}-{hz}.vvp'
        assert Path(row['log']).resolve()==log and run.sha(log)==row['log_sha256']
        assert run.sha(image)==row['image_sha256']
        assert Path(row['command'][0]).name=='vvp' and Path(row['command'][1]).resolve()==image
        assert row['command'][2:]==[f'+phase={phase}',f'+reset={reset}']
        lines=log.read_text().splitlines();assert len(lines)==2
        if red:
            assert re.fullmatch(r'FATAL: .+:\d+: KBD-CONTROLLER-EARLY-READY '
                +f'hz={hz} phase={phase}',lines[0])
        else:
            retry=int(reset==0 and (phase<21 or phase in (23,24)))
            assert lines[0]==f'KBD-CONTROLLER-OK hz={hz} phase={phase} reset={reset} retry={retry} irq1=1'
            match=re.fullmatch(r'(.+\.sv):(\d+): \$finish called at (\d+) \(1ps\)',lines[1])
            assert match and int(match[3])>0
            assert Path(match[1]).resolve()==root/'source/tb_kbd_controller_inhibit.sv'
            assert Path(match[1]).read_text().splitlines()[int(match[2])-1].strip()=='$finish;'
        artifacts[str(log)]=run.sha(log);artifacts[str(image)]=run.sha(image)
    for p in (root/'started.json',root/'closed.json',Path(__file__).resolve()):
        artifacts[str(p)]=run.sha(p)
    result=dict(passed=True,owner=owner,input_pins=len(start['pins']),artifacts=artifacts,
        candidate_positive_cases=104,original_endpoint_red_witnesses=2,
        controller_sha256=run.CONTROLLER_SHA,endpoint_sha256=run.FIXED_SHA,
        automatic_retry_without_producer_resubmit=True,shared_reset=True,
        physical_fpga=False,debug_mmio_tested=False,standard_suite=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as stream:json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'}))


if __name__=='__main__':main()
