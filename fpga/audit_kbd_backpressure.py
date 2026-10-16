"""Independently regrade the actual FPGA keyboard FIFO-pressure experiment."""
import argparse
import itertools
import json
from pathlib import Path
import re
import subprocess

import run_kbd_backpressure as run


def check_log(case, code, text, tb):
    label, hz, during, translated, flip = case
    lines = text.splitlines()
    assert len(lines) == 2
    red = label == 'parent' and during == 1
    assert code == int(red)
    if red:
        first = 0x1c if translated else 0x5a
        second = 0x11 if translated ^ flip else 0x1d
        match = re.fullmatch(r'FATAL: (.+\.sv):(\d+): KBD-BACKPRESSURE-DATA '
                             + f'got={second:02x} expected={first:02x}', lines[0])
        assert match and Path(match[1]).resolve() == tb
        assert 'KBD-BACKPRESSURE-DATA' in tb.read_text().splitlines()[int(match[2])-1]
        assert re.fullmatch(r'\s+Time: \d+\s+Scope: tb_kbd_backpressure\.check_byte', lines[1])
    else:
        assert lines[0] == (f'KBD-BACKPRESSURE-OK hz={hz} during={during} translate={translated} '
                           f'flip={flip} frames=2 reads=66 pending={int(label=="candidate" and during)}')
        match = re.fullmatch(r'(.+\.sv):(\d+): \$finish called at (\d+) \(1ps\)', lines[1])
        assert match and Path(match[1]).resolve() == tb and int(match[3]) > 0
        assert tb.read_text().splitlines()[int(match[2])-1].strip() == '$finish;'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run', type=Path, required=True)
    ap.add_argument('--unit', required=True)
    args = ap.parse_args(); root = args.run.resolve(strict=True)
    assert __debug__ and root.parent == run.ROOT
    start = json.loads((root/'started.json').read_text())
    done = json.loads((root/'closed.json').read_text())
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert not done['physical_fpga'] and not done['debug_mmio'] and not done['standard_suite']
    assert done['gameplay_ipc'] is None
    assert all(run.sha(p) == h for p, h in start['pins'].items())
    assert start['definitions'] == ['VEN_KBC_FAST','VEN_KBD_AUTOACK']
    assert start['read_only_candidate_probe'] == 'CHECK_RETAINED'
    assert not any(done['memory_events'][k] for k in ('oom','oom_kill','oom_group_kill'))
    owner = dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show',args.unit,'-p','ActiveState','-p','SubState',
        '-p','MainPID','-p','ExecMainStatus','-p','InvocationID','-p','Result'], text=True).splitlines())
    assert owner == dict(ActiveState='active',SubState='exited',MainPID='0',ExecMainStatus='0',
                         InvocationID=start['invocation'],Result='success')
    expected = [list(c) for c in itertools.product(('candidate','parent'), (3125000,40000000),
                                                  (0,1),(0,1),(0,1))]
    assert start['cases'] == expected and [r['case'] for r in done['rows']] == expected
    src = root/'source'; artifacts = {}
    for name, digest in (('candidate.v',run.inputs.CONTROLLER_SHA),('parent.v',run.PARENT_SHA),
                         ('simple_fifo.v',run.inputs.FIFO_SHA),('ven_ps2_kbd_inject.v',run.inputs.FIXED_SHA)):
        assert run.sha(src/name) == digest
    assert len(done['builds']) == 4
    for (label,hz), build in zip(itertools.product(('candidate','parent'),(3125000,40000000)),done['builds']):
        expected_cmd = ['-g2012','-Wall','-s','tb_kbd_backpressure',f'-Ptb_kbd_backpressure.HZ={hz}',
            '-DVEN_KBC_FAST','-DVEN_KBD_AUTOACK',*(['-DCHECK_RETAINED'] if label=='candidate' else []),
            '-o',str(root/f'{label}-{hz}.vvp'),*[str(src/n) for n in
                (label+'.v','simple_fifo.v','ven_ps2_kbd_inject.v','tb_kbd_backpressure.sv')]]
        assert Path(build['command'][0]).name == 'iverilog' and build['command'][1:] == expected_cmd
        log = root/f'{label}-{hz}-compile.log'
        assert build['native_exit'] == 0 and Path(build['log']).resolve() == log
        assert run.sha(log) == build['log_sha256']; artifacts[str(log)] = run.sha(log)
    for row in done['rows']:
        label,hz,during,translated,flip = row['case']
        log = root/f'{label}-{hz}-d{during}-t{translated}-f{flip}.log'
        image = root/f'{label}-{hz}.vvp'
        assert row['passed'] and row['waited'] and row['affinity'] == [12,13]
        assert not Path('/proc',str(row['native_pid'])).exists()
        assert Path(row['log']).resolve() == log and run.sha(log) == row['log_sha256']
        assert run.sha(image) == row['image_sha256']
        assert Path(row['command'][0]).name == 'vvp' and row['command'][1:] == [str(image),
            f'+during={during}',f'+translate={translated}',f'+flip={flip}']
        check_log(row['case'],row['native_exit'],log.read_text(),src/'tb_kbd_backpressure.sv')
        artifacts[str(log)] = run.sha(log); artifacts[str(image)] = run.sha(image)
    for path in (root/'started.json',root/'closed.json',Path(__file__).resolve()):
        artifacts[str(path)] = run.sha(path)
    result = dict(passed=True,owner=owner,input_pins=len(start['pins']),artifacts=artifacts,
        candidate_cases=16,parent_full_before_controls=8,parent_missing_scan_witnesses=8,
        physical_fpga=False,debug_mmio=False,standard_suite=False,gameplay_ipc=None)
    with (root/'audit.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='artifacts'}))


if __name__ == '__main__': main()
