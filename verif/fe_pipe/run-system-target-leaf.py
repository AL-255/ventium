#!/usr/bin/env python3
"""Bounded real-selector leaf: original, disabled candidate, enabled candidate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control-source', 'candidate-source', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    include = 'rtl/core/core_ctrl_target_read.svh'
    sources = {name: getattr(args, name + '_source').resolve(strict=True)
               for name in ('control', 'candidate')}
    pins = {str(p): sha(p) for p in (Path(__file__), HERE / 'tb_system_target_read.sv',
                                    REPO / 'tools/build_scope.sh',
                                    *(p / include for p in sources.values()))}
    def save(name, value):
        with (args.out / name).open('x') as stream:
            json.dump(value, stream, indent=2)
    def run(command, name, timeout):
        save(name + '.command.json', list(map(str, command)))
        with (args.out / (name + '.log')).open('x') as stream:
            rc = subprocess.run(command, env=dict(os.environ, TMPDIR=str(args.out)),
                                stdout=stream, stderr=subprocess.STDOUT, timeout=timeout).returncode
        save(name + '.exit.json', dict(exit=rc))
        assert rc == 0, (name, rc)
    save('inputs.json', pins)
    result = dict(passed=False, variants=[], gameplay_ipc=None, standard_suite=False)
    try:
        for label, source, enabled in (('control', sources['control'], False),
                                       ('disabled', sources['candidate'], False),
                                       ('enabled', sources['candidate'], True)):
            obj = args.out / ('obj-' + label)
            flags = ['+define+VEN_P54_CTRL_TARGET_SYSTEM'] if enabled else []
            run([REPO / 'tools/build_scope.sh', '--', 'taskset', '-c', '2,3,18,19',
                 '/tools/verilator/v5.046/bin/verilator', '--binary', '--timing', '--assert', '-j', '4',
                 '-Wall', '-Wno-UNUSED', '-Wno-fatal', '-Werror-IMPLICIT', '-Werror-PINMISSING',
                 '-Werror-UNDRIVEN', '-Werror-MULTIDRIVEN', '-Werror-LATCH', '-Werror-UNOPTFLAT',
                 '--top-module', 'tb_system_target_read', '-I' + str(source / 'rtl/core'),
                 '--Mdir', obj, '-o', 'tb_target', *flags, HERE / 'tb_system_target_read.sv'], label + '-build', 120)
            run([obj / 'tb_target'], label + '-run', 15)
            assert 'SYSTEM-TARGET-READ-LEAF-OK checks=115712' in (args.out / (label + '-run.log')).read_text()
            result['variants'].append(dict(name=label, checks=115712, binary_sha256=sha(obj / 'tb_target')))
        result['passed'] = True
    finally:
        result['inputs_unchanged'] = all(sha(Path(p)) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save('closed.json', result)
    print(json.dumps(result), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
