#!/usr/bin/env python3
"""Run the retained code-buffer coherence corpus against private reuse RTL."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control-source', 'candidate-source', 'out'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    test = REPO / 'verif/bench/tb_l1d_code_buffer.sv'
    pins = {str(path.resolve()): sha(path) for path in (Path(__file__), test)}
    result = dict(passed=False, cases=[], gameplay_ipc=None, standard_suite=False)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1')
    common = {'VEN_L1D_CODE_BUFFER', 'VEN_L1D_BANKED_DATA',
              'VEN_L1D_CODE_TAG_INVALIDATE', 'VEN_L1D_CODE_STREAM'}
    profiles = {
        'hit-under-fill': {'VEN_L1D_HIT_UNDER_FILL'},
        'paired-store': {'VEN_P54_DUAL_STORE_PAIR', 'VEN_P54_LOAD_STORE_PAIR'},
        'combined': {'VEN_L1D_HIT_UNDER_FILL', 'VEN_P54_DUAL_STORE_PAIR',
                     'VEN_P54_LOAD_STORE_PAIR'},
    }
    try:
        for variant, source, enabled in (
            ('control', args.control_source, False),
            ('candidate-off', args.candidate_source, False),
            ('candidate', args.candidate_source, True),
        ):
            leaf = source / 'rtl/mem/ven_l1d.sv'
            pins[str(leaf.resolve())] = sha(leaf)
            for profile, extra in profiles.items():
                out = args.out / (variant + '-' + profile)
                out.mkdir()
                defs = common | extra | ({'VEN_L1D_CODE_WORD_REUSE'} if enabled else set())
                cmd = ['timeout', '--kill-after=5s', '120s',
                       '/tools/verilator/v5.046/bin/verilator',
                       '--binary', '--timing', '--assert', '-sv', '-j', '32',
                       '-Wall', '-Wno-UNUSED', '-Wno-fatal',
                       *['-Werror-' + word for word in ('IMPLICIT', 'PINMISSING',
                         'UNDRIVEN', 'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                       *['+define+' + word for word in sorted(defs)],
                       '--top-module', 'tb_l1d_code_buffer', '--Mdir', str(out/'obj'),
                       '-o', 'test', str(leaf), str(test)]
                (out/'command.json').write_text(json.dumps(cmd, indent=2)+'\n')
                row = dict(variant=variant, profile=profile)
                result['cases'].append(row)
                with (out/'build.log').open('x') as log:
                    row['build_exit'] = subprocess.run(cmd, env=env, stdout=log,
                        stderr=subprocess.STDOUT).returncode
                assert row['build_exit'] == 0, row
                with (out/'run.log').open('x') as log:
                    row['native_exit'] = subprocess.run(['timeout', '30s', out/'obj/test'],
                        env=env, stdout=log, stderr=subprocess.STDOUT).returncode
                row['binary_sha256'] = sha(out/'obj/test')
                assert row['native_exit'] == 0, row
                assert 'P54-L1D-CODE-BUFFER-OK' in (out/'run.log').read_text(), row
                print(json.dumps(row), flush=True)
        result['passed'] = True
    finally:
        result['inputs_unchanged'] = all(sha(path) == digest for path, digest in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'pins.json').write_text(json.dumps(pins, indent=2)+'\n')
        (args.out/'closed.json').write_text(json.dumps(result, indent=2)+'\n')
    assert result['passed']


if __name__ == '__main__':
    main()
