"""Independently regrade closed native cold-input runs and their source pins."""
import argparse
import json
from pathlib import Path
import subprocess

import run_retained_pc_input as run
from build_pc_input_probe import sha


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run', type=Path, required=True)
    ap.add_argument('--owner', required=True)
    a = ap.parse_args(); root = a.run.resolve(strict=True)
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    def load(path): return json.loads(path.read_text())
    started, closed = load(root/'started.json'), load(root/'closed.json')
    assert closed['passed'] and closed['pins_unchanged']
    assert not any(closed['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    assert started['cold_boot'] and started['uv_fast'] and started['cycle_mode'] == 1
    assert not started['standard_suite'] and not started['physical_board']
    props = subprocess.check_output(['systemctl','--user','show',a.owner,
        '-p','ActiveState','-p','SubState','-p','InvocationID','-p','MainPID',
        '-p','ExecMainStatus','-p','Result'], text=True)
    owner = dict(line.split('=',1) for line in props.splitlines())
    assert owner == dict(ActiveState='active',SubState='exited',
        InvocationID=started['invocation'],MainPID='0',ExecMainStatus='0',Result='success')
    assert all(sha(p) == h for p,h in started['pins'].items())
    assert [r['raw'] for r in closed['rows']] == [0,1]
    artifacts = {}; grades = []
    for row in closed['rows']:
        work = root/f"raw{row['raw']}"; log = work/'run.log'
        assert row == load(work/'closed.json')
        assert row['passed'] and row['error'] is None and row['native_exit'] == 0
        assert row['actual_wait'] and row['proc_gone'] and row['commands_sent'] and row['graceful_stop']
        native = load(work/'native.json'); assert native == row['observed']
        assert native['affinity'] == [16+row['raw']]
        assert not Path('/proc',str(native['pid'])).exists()
        assert sha(native['exe']) == started['model']
        assert sha(log) == row['log_sha256']
        grade = run.grade(log.read_text(),row['raw'])
        assert grade == row['grade'] and grade['last_cycle'] == 6500000
        assert load(work/'sent.json')['commands'] == run.COMMANDS.decode()
        assert native['argv'] == row['argv'][3:]
        for p in (log,work/'closed.json',work/'native.json',work/'sent.json',
                  work/'input.img',work/'rom/boot0.rom',work/'rom/boot1.rom'):
            artifacts[str(p)] = sha(p)
        grades.append(grade)
    for p in (root/'started.json',root/'closed.json',Path(__file__),Path(run.__file__)):
        artifacts[str(p.resolve())] = sha(p)
    result = dict(passed=True,owner=owner,source_pins_checked=len(started['pins']),
        model=started['model'],grades=grades,artifacts=artifacts,
        cold_input_transport=True,windows_ui=False,physical_fpga=False,
        standard_suite=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as f: json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifacts','grades')}))


if __name__ == '__main__': main()
