#!/usr/bin/env python3
"""Actual shadow include: bounded permission/ownership/invalidation unit gate."""
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
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    pins = {str(p): sha(p) for p in (Path(__file__), HERE / 'core_ifetch_auth_multi.svh',
                                    HERE / 'tb_ifetch_auth_multi.sv', REPO / 'tools/build_scope.sh')}
    def save(name, value):
        with (args.out / name).open('x') as stream:
            json.dump(value, stream, indent=2)
    def run(command, name):
        save(name + '.command.json', list(map(str, command)))
        with (args.out / (name + '.log')).open('x') as stream:
            rc = subprocess.run(command, env=dict(os.environ, TMPDIR=str(args.out)),
                                stdout=stream, stderr=subprocess.STDOUT, timeout=180).returncode
        save(name + '.exit.json', dict(exit=rc))
        assert rc == 0, (name, rc)
    save('inputs.json', pins)
    result = dict(passed=False, gameplay_ipc=None, standard_suite=False)
    try:
        run([REPO / 'tools/build_scope.sh', '--', 'taskset', '-c', '2,3,18,19',
             '/tools/verilator/v5.046/bin/verilator', '--binary', '--timing', '--assert', '-j', '4',
             '-Wno-fatal', '-Werror-IMPLICIT', '-Werror-PINMISSING', '-Werror-UNDRIVEN',
             '-Werror-MULTIDRIVEN', '-Werror-LATCH', '-Werror-UNOPTFLAT',
             '--top-module', 'tb_ifetch_auth_multi', '-I' + str(HERE), '--Mdir', args.out / 'obj',
             '-o', 'tb_auth', HERE / 'tb_ifetch_auth_multi.sv'], 'build')
        run([args.out / 'obj/tb_auth'], 'run')
        assert 'IFETCH-AUTH-MULTI-OK checks=' in (args.out / 'run.log').read_text()
        result.update(passed=True, binary_sha256=sha(args.out / 'obj/tb_auth'))
    finally:
        result['inputs_unchanged'] = all(sha(Path(p)) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save('closed.json', result)
    print(json.dumps(result), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
