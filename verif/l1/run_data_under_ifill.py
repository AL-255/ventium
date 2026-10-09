#!/usr/bin/env python3
"""Matched registered D-hit/I-fill microtests, including old ownership coverage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control-source', 'candidate-source', 'profile', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    base = HERE / 'tb_l1d_mem_chain.sv'
    extensions = [HERE / 'code_word_reuse_leaf.svh', HERE / 'data_under_ifill_leaf.svh']
    text = base.read_text()
    edits = {
        '  int ticks=0, accepted=0, backing=0;':
            '  logic hold_ack=0;\n  int ticks=0, accepted=0, backing=0;',
        '  assign m_ack=m_req && ((ticks%3)==0);':
            '  assign m_ack=m_req && !hold_ack && ((ticks%3)==0);',
        '  initial begin\n    for(int i=0;i<65536;i++)':
            '  `include "code_word_reuse_leaf.svh"\n'
            '  `include "data_under_ifill_leaf.svh"\n'
            '  initial begin\n    for(int i=0;i<65536;i++)',
        '    $finish;': '    run_code_word_reuse();\n    run_data_under_ifill();\n    $finish;',
    }
    for old, new in edits.items():
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    generated = args.out / 'tb_l1d_mem_chain.sv'
    generated.write_text(text)
    lines = args.profile.read_text().splitlines()
    assert lines and all(re.fullmatch(r'VEN_[A-Z0-9_]+', word) for word in lines)
    defs = set(lines)
    assert len(defs) == len(lines)
    assert {'VEN_L1D_CODE_WORD_REUSE', 'VEN_L1D_HIT_UNDER_FILL',
            'VEN_L1D_TAG_LUTRAM', 'VEN_PIPE_MEM_CHAIN'} <= defs
    assert 'VEN_L1D_DATA_UNDER_IFILL' not in defs
    pins = {str(p.resolve()): sha(p) for p in
            (Path(__file__), base, *extensions, generated, args.profile)}
    result = dict(passed=False, variants=[], gameplay_ipc=None, standard_suite=False)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1')
    try:
        for name, source, enabled in (
            ('control', args.control_source, False),
            ('candidate-off', args.candidate_source, False),
            ('candidate', args.candidate_source, True),
        ):
            out = args.out / name; out.mkdir()
            files = [source/'rtl/mem'/x for x in
                     ('ven_p54_bank_arb.sv', 'ven_p54_hit_return.sv', 'ven_l1d.sv')]
            pins.update({str(p.resolve()): sha(p) for p in files})
            macros = defs | ({'VEN_L1D_DATA_UNDER_IFILL'} if enabled else set())
            cmd = ['timeout', '--kill-after=5s', '180s', '/tools/verilator/v5.046/bin/verilator',
                   '--binary', '--timing', '-sv', '--assert', '-j', '32', '-Wno-fatal', '-Wno-UNUSED',
                   *['-Werror-'+w for w in ('IMPLICIT', 'PINMISSING', 'UNDRIVEN',
                                          'MULTIDRIVEN', 'LATCH', 'UNOPTFLAT')],
                   '-I'+str(HERE), '--top-module', 'tb_l1d_mem_chain',
                   '--Mdir', str(out/'obj'), '-o', 'test',
                   *['+define+'+d for d in sorted(macros)], *map(str, files), str(generated)]
            (out/'command.json').write_text(json.dumps(cmd, indent=2)+'\n')
            with (out/'build.log').open('x') as log:
                code = subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
            row = dict(name=name, build_exit=code, seeds=[]); result['variants'].append(row)
            assert code == 0, row
            for seed in (1, 7, 101):
                with (out/f'run-{seed}.log').open('x') as log:
                    code = subprocess.run(['timeout', '30s', out/'obj/test',
                        '+verilator+rand+reset+2', '+verilator+seed+'+str(seed)],
                        env=env, stdout=log, stderr=subprocess.STDOUT).returncode
                log = (out/f'run-{seed}.log').read_text()
                marker = re.search(r'DATA-UNDER-IFILL-OK checks=(\d+) held_completions=(\d+)', log)
                assert code == 0 and marker, (name, seed, code)
                assert 'L1D-MEM-CHAIN-OK accepted=150' in log
                assert 'CODE-WORD-REUSE-LEAF-OK checks=51 staged_latency=18' in log
                assert tuple(map(int, marker.groups())) == (659, 640 if enabled else 0)
                row['seeds'].append(dict(seed=seed, native_exit=code,
                    checks=int(marker[1]), held_completions=int(marker[2])))
            row['binary_sha256'] = sha(out/'obj/test')
        result['passed'] = True
    finally:
        result['inputs_unchanged'] = all(sha(p) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'pins.json').write_text(json.dumps(pins, indent=2)+'\n')
        (args.out/'closed.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result, indent=2), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
