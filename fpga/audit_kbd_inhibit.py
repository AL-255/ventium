"""Audit original red witnesses and the separate positive endpoint matrix."""
import json
from pathlib import Path
import re
import subprocess

import prepare_kbd_inhibit as recipe
import run_kbd_inhibit_witness as witness


def main():
    assert __debug__
    root=witness.ROOT
    artifacts={};summaries=[]
    for name,unit,positive in (
        ('kbd-inhibit-witness-r2','ventium-kbd-inhibit-witness-oct16-r2.service',False),
        ('kbd-inhibit-fixed-r1','ventium-kbd-inhibit-fixed-oct16-r1.service',True)):
        run=root/name
        start=json.loads((run/'started.json').read_text());done=json.loads((run/'closed.json').read_text())
        assert done['candidate_matrix_passed' if positive else 'witness_matrix_passed']
        assert done['pins_unchanged'] and not done['errors'] and len(done['rows'])==46
        assert not done['physical_fpga'] and not done['standard_suite'] and done['gameplay_ipc'] is None
        assert all(witness.sha(p)==h for p,h in start['pins'].items())
        assert not any(done['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
        owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-p','ActiveState','-p','SubState','-p','MainPID','-p','ExecMainStatus','-p','InvocationID','-p','Result'],text=True).splitlines())
        assert owner==dict(ActiveState='active',SubState='exited',MainPID='0',ExecMainStatus='0',
            InvocationID=start['invocation'],Result='success')
        expected=[(hz,phase) for hz in (3125000,40000000) for phase in range(23)]
        assert [tuple(v) for v in start['cases']]==expected
        assert [(r['hz'],r['phase']) for r in done['rows']]==expected
        assert len(done['builds'])==2
        for hz,build in zip((3125000,40000000),done['builds']):
            expected_cmd=['-g2012','-Wall','-s','tb_kbd_inhibit',f'-Ptb_kbd_inhibit.HZ={hz}',
                '-o',str(run/f'{hz}.vvp'),str(run/'source/ven_ps2_kbd_inject.v'),str(run/'source/tb_kbd_inhibit.sv')]
            assert build['native_exit']==0 and Path(build['command'][0]).name=='iverilog'
            assert [str(Path(v).resolve()) if v.startswith('/') else v for v in build['command'][1:]]==expected_cmd
        for row in done['rows']:
            hz,phase=row['hz'],row['phase'];red=not positive and phase<21
            assert row['passed'] and row['waited'] and row['expected_red']==red
            assert row['native_exit']==int(red) and row['affinity']==[12,13]
            assert not Path('/proc',str(row['native_pid'])).exists()
            log=run/f'{hz}-p{phase}.log';image=run/f'{hz}.vvp'
            assert witness.sha(log)==row['log_sha256'] and witness.sha(image)==row['image_sha256']
            assert Path(row['command'][1]).resolve()==image and row['command'][2:]==[f'+phase={phase}']
            text=log.read_text();lines=text.splitlines();assert len(lines)==2
            if red:
                assert re.fullmatch(r'FATAL: .+:\d+: KBD-EARLY-READY-WHILE-INHIBITED '
                    +f'hz={hz} phase={phase} edges=\\d+',lines[0])
                assert 'bounded keyboard inhibit timeout' not in text
            else:
                assert lines[0]==f'KBD-INHIBIT-OK hz={hz} phase={phase} retry={int(phase<21)} reset_cancel=1'
                finish=re.fullmatch(r'(.+\.sv):(\d+): \$finish called at (\d+) \(1ps\)',lines[1])
                assert finish and int(finish[3])>0
                assert Path(finish[1]).resolve()==run/'source/tb_kbd_inhibit.sv'
                assert Path(finish[1]).read_text().splitlines()[int(finish[2])-1].strip()=='$finish;'
            artifacts[str(log)]=witness.sha(log);artifacts[str(image)]=witness.sha(image)
        for p in (run/'started.json',run/'closed.json'):artifacts[str(p)]=witness.sha(p)
        summaries.append(dict(run=name,owner=owner,pins_checked=len(start['pins']),
            red_witnesses=0 if positive else 42,positive_cases=46 if positive else 4))
    old=(root/'kbd-inhibit-witness-r2/source/ven_ps2_kbd_inject.v').read_text()
    new=(root/'kbd-inhibit-fixed-r1/source/ven_ps2_kbd_inject.v').read_text()
    assert new==recipe.transform(old)
    assert witness.sha(root/'kbd-inhibit-witness-r2/source/tb_kbd_inhibit.sv')==witness.sha(root/'kbd-inhibit-fixed-r1/source/tb_kbd_inhibit.sv')
    result=dict(passed=True,matrices=summaries,artifacts=artifacts,
        endpoint_contract_only=True,controller_integration=False,physical_fpga=False,
        standard_suite=False,gameplay_ipc=None)
    for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(witness.__file__).resolve()):
        artifacts[str(p)]=witness.sha(p)
    with (root/'kbd-inhibit-fixed-r1/audit.json').open('x') as stream:json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'}))


if __name__=='__main__':main()
