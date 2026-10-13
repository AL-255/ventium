"""Audit a closed initial SMSW witness and pin its complete evidence.

Require native closure and exactly one #UD at the tested PC in every missing
memory-form control. No such fault is permitted in the MOV controls. This
does not qualify a repaired model or turn an expected failure into acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--unit', required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    start = json.loads((root/'started.json').read_text())
    closed = json.loads((root/'closed.json').read_text())
    assert start['expect_missing'] and closed['passed'] and not closed['repaired_rtl']
    assert closed['pins_unchanged'] and not closed['errors']
    assert len(closed['rows']) == 88 and not closed['differential_gate']
    props = subprocess.check_output(['systemctl', '--user', 'show', args.unit,
        '-p', 'MainPID', '-p', 'SubState', '-p', 'ExecMainStatus', '-p', 'Result',
        '-p', 'InvocationID'], text=True)
    owner = dict(line.split('=', 1) for line in props.splitlines())
    assert owner == dict(MainPID='0', SubState='exited', ExecMainStatus='0',
                         Result='success', InvocationID=start['invocation'])
    assert all(sha(path) == value for path,value in start['pins'].items())
    failed_memory = healthy_control = 0
    for row in closed['rows']:
        case = row['case']
        mode, addr, op, offset, base, control = [case[key] for key in
            ('MODE', 'ADDR32', 'OP32', 'OFFSET', 'BASE', 'CONTROL')]
        name = f'm{mode}-a{addr}-o{op}-d{offset}-b{base}-c{control}'
        assert sha(root/(name+'.bin')) == row['image_sha256']
        symbols = {name: int(addr, 16) for addr,_,name in
                   (line.split() for line in subprocess.check_output([
                       'nm', '-n', str(root/(name+'.elf'))], text=True).splitlines())}
        probe, after = symbols['smsw_probe'], symbols['smsw_after']
        image = (root/(name+'.bin')).read_bytes()
        insn = image[probe-0xf0000:after-0xf0000]
        if not control:
            expected = (b'\x66' if op != mode else b'')
            expected += b'\x67' if addr != mode else b''
            expected += b'\x0f\x01\x64\x33\x08' if addr else b'\x0f\x01\x60\x08'
            assert insn == expected, (name, insn.hex(), expected.hex())
        text = (root/(name+'-rtl.log')).read_text()
        faults = re.findall(r'^\[FAULT\] vec=(\d+) err=([0-9a-f]+) pc=([0-9a-f]+) '
                            r'state=(\d+) v86=(\d+) depth=(\d+)$', text, re.M)
        assert row['qemu_exit'] == 133
        if control:
            assert row['rtl_exit'] == 133 and faults == [], (name, faults)
            healthy_control += 1
        else:
            assert row['rtl_exit'] == 135 and len(faults) == 1
            vector, error, pc, state, v86, depth = faults[0]
            assert (int(vector), int(error,16), int(pc,16), int(state), int(v86), int(depth)) == (
                6, 0, probe if mode else probe-0xf0000, 2, 0, 0), (name, faults)
            failed_memory += 1
    assert (failed_memory, healthy_control) == (80, 8)
    artifacts = {str(path): sha(path) for path in root.iterdir() if path.is_file()}
    result = dict(passed=True, owner=owner, qemu_success=88, missing_opcode_cases=80,
                  mov_controls=8, exact_instruction_and_fault_pc=True,
                  repaired_rtl=False, differential_gate=False, gameplay_ipc=None,
                  standard_suite=False, physical_board=False, artifacts=artifacts)
    with (root/'audit.json').open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({key:value for key,value in result.items() if key != 'artifacts'}))


if __name__ == '__main__':
    main()
