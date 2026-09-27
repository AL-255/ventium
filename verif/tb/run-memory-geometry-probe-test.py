#!/usr/bin/env python3
"""Tiny host/mock test: no Verilator, DUT build, or simulation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def main():
    out = Path(tempfile.mkdtemp(prefix='ventium-memory-geometry-mock.'))
    print(f'Artifacts: {out}', flush=True)
    with (out/'build.log').open('x') as log:
        subprocess.run(['g++', '-std=c++17', '-O0', '-Wall', '-Wextra', '-Werror',
                        HERE/'test_memory_geometry_probe.cpp', '-o', out/'test'],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
    negatives = ['unsupported', 'missing-finish', 'gap', 'outstanding', 'bad-id',
                 'bad-last', 'overlap', 'reset', 'bad-narrow', 'unsolicited-r',
                 'profile-suffix', 'exec-alias', 'chain-accept', 'overflow', 'wrong-count', 'public-zero-negative']
    for mode in ['off', 'ok', 'rresp', *negatives, 'existing']:
        env = {k:v for k,v in os.environ.items() if not k.startswith('VEN_MEM_GEOM_')}
        path = out/f'{mode}.jsonl'
        env.update(VEN_MEM_GEOM_LOG=str(path), VEN_MEM_GEOM_PC='0x8000',
                   VEN_MEM_GEOM_CONSUMER='0x8003', VEN_MEM_GEOM_EXPECT_READS='2')
        if mode=='overflow': env['VEN_MEM_GEOM_MAX_RECORDS']='4'
        if mode=='wrong-count': env['VEN_MEM_GEOM_EXPECT_READS']='3'
        if mode=='existing': path.write_text('preserved old receipt\n')
        with (out/f'{mode}.log').open('x') as log:
            result = subprocess.run([out/'test', mode], env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=10)
        expected = 0 if mode in ('off','ok','rresp') else (7 if mode=='public-zero-negative' else 2)
        assert result.returncode==expected, (mode, result.returncode, (out/f'{mode}.log').read_text())
        if mode=='off': assert not path.exists()
        elif mode=='existing': assert path.read_text()=='preserved old receipt\n'
        else:
            rows=[json.loads(line) for line in path.read_text().splitlines()]
            if expected:
                assert not any(r['type']=='complete' for r in rows), mode
    rows=[json.loads(line) for line in (out/'ok.jsonl').read_text().splitlines()]
    assert rows[0]['type']=='begin' and rows[-1]['type']=='complete'
    assert rows[-1]['records']==len(rows)
    assert rows[-1]['final_reads']==2 and rows[-1]['fast_commits']==1
    assert rows[-1]['axi_reads']==4 and rows[-1]['axi_beats']==4
    core={r['cycle']:r for r in rows if r['type']=='core'}
    assert [c for c,r in core.items() if r['final_read']]==[4,8]
    assert core[1]['req']==1 and core[1]['accepted']==0
    assert core[2]['accepted']==1 and core[2]['final_read']==0
    assert core[3]['walk']==1 and core[3]['owner']=='slow-ext' and not core[3]['final_read']
    assert core[6]['owner']=='pipe-held' and core[6]['owner_pc']==0x8000
    assert core[7]['walk']==1 and core[7]['owner']=='pipe-held' and not core[7]['final_read']
    assert core[9]['owner_pc']==0x8003 and not core[9]['final_read']
    ar=[r for r in rows if r['type']=='axi_ar']
    assert ar[0]['address']==0x100000001 and ar[0]['narrow']==1
    assert all('owner_pc' not in r for r in ar), 'do not invent current-PC ownership of backing traffic'
    error_rows=[json.loads(line) for line in (out/'rresp.jsonl').read_text().splitlines()]
    assert any(r['type']=='axi_r' and r['resp']==2 for r in error_rows)
    print(f'MEMORY-GEOMETRY-MOCK-OK positive=3 negative={len(negatives)+1}')


if __name__=='__main__':
    main()
