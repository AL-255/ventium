#!/usr/bin/env python3
"""Exact-profile tag-LUTRAM cold/warm reset checks with randomized initialization."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control-source', 'candidate-source', 'profile', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    base = HERE/'tb_l1d_mem_chain.sv'
    extension = HERE/'code_word_reuse_leaf.svh'
    tags = HERE/'tag_lutram_leaf.svh'
    text = base.read_text()
    edits = {
        '  int ticks=0, accepted=0, backing=0;': '  logic hold_ack=0;\n  int ticks=0, accepted=0, backing=0;',
        '  assign m_ack=m_req && ((ticks%3)==0);': '  assign m_ack=m_req && !hold_ack && ((ticks%3)==0);',
        '  initial begin\n    for(int i=0;i<65536;i++)':
            '  `include "code_word_reuse_leaf.svh"\n  `include "tag_lutram_leaf.svh"\n  initial begin\n    for(int i=0;i<65536;i++)',
        '    $finish;': '    run_code_word_reuse();\n    run_tag_lutram();\n    $finish;',
    }
    for old, new in edits.items():
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    generated = args.out/'tb_l1d_mem_chain.sv'
    generated.write_text(text)
    # Use the frozen complete macro inventory, not just +define tokens: the
    # full-PC command also supplies most RTL macros through Verilator -D.
    lines = args.profile.read_text().splitlines()
    assert lines and all(re.fullmatch(r'VEN_[A-Z0-9_]+', line) for line in lines)
    defs = set(lines)
    assert len(defs) == len(lines)
    assert {'VEN_L1D_CODE_BUFFER', 'VEN_L1D_CODE_STREAM', 'VEN_PIPE_MEM_CHAIN',
            'VEN_L1D_HIT_UNDER_FILL', 'VEN_L1D_PRIME_UNDER_FILL'} <= defs
    assert 'VEN_L1D_CODE_WORD_REUSE' in defs
    assert 'VEN_L1D_TAG_LUTRAM' not in defs
    pins = {str(p.resolve()): sha(p) for p in (Path(__file__), base, extension, tags, generated, args.profile)}
    result = dict(passed=False, variants=[], gameplay_ipc=None, standard_suite=False)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1')
    try:
        for name, source, enabled in (
            ('control', args.control_source, False),
            ('candidate-off', args.candidate_source, False),
            ('candidate', args.candidate_source, True),
        ):
            out = args.out/name; out.mkdir()
            files = [source/'rtl/mem'/x for x in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv','ven_l1d.sv')]
            pins.update({str(p.resolve()): sha(p) for p in files})
            variants = defs | ({'VEN_L1D_TAG_LUTRAM'} if enabled else set())
            cmd = ['timeout','--kill-after=5s','180s','/tools/verilator/v5.046/bin/verilator',
                '--binary','--timing','-sv','--assert','-j','32','-Wno-fatal','-Wno-UNUSED',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(HERE),'--top-module','tb_l1d_mem_chain','--Mdir',str(out/'obj'),'-o','test',
                *['+define+'+d for d in sorted(variants)],*map(str,files),str(generated)]
            (out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
            with (out/'build.log').open('x') as f:
                code = subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
            row = dict(name=name,build_exit=code); result['variants'].append(row)
            assert code == 0, (name,'build',code)
            row['seeds'] = []
            for seed in (1,7,101):
                log_path = out/('run-seed-'+str(seed)+'.log')
                with log_path.open('x') as f:
                    code = subprocess.run(['timeout','30s',out/'obj/test',
                        '+verilator+rand+reset+2','+verilator+seed+'+str(seed)],
                        env=env,stdout=f,stderr=subprocess.STDOUT).returncode
                log = log_path.read_text()
                assert code == 0 and 'L1D-MEM-CHAIN-OK accepted=150' in log, (name,seed,code)
                word = re.search(r'CODE-WORD-REUSE-LEAF-OK checks=(\d+) staged_latency=(\d+)',log)
                tag = re.search(r'TAG-LUTRAM-LEAF-OK checks=(\d+) ticks=(\d+) backing=(\d+)',log)
                assert word and tag
                row['seeds'].append(dict(seed=seed,native_exit=code,word_checks=int(word[1]),
                    word_latency=int(word[2]),tag_checks=int(tag[1]),ticks=int(tag[2]),backing=int(tag[3])))
            row['binary_sha256'] = sha(out/'obj/test')
        expected = result['variants'][0]['seeds']
        assert all(v['seeds'] == expected for v in result['variants'])
        result['passed'] = True
    finally:
        result['inputs_unchanged'] = all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')
        (args.out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2),flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
