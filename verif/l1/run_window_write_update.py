#!/usr/bin/env python3
"""Full-profile coherent-window A/B and exact required-failure regression."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from prepare_window_write_update import FLAG, transform

HERE = Path(__file__).resolve().parent


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'profile', 'out'):
        p.add_argument('--'+name, type=Path, required=True)
    a = p.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    a.out = a.out.resolve(); assert a.out.is_relative_to(scratch)
    a.out.mkdir()
    base = HERE/'tb_l1d_mem_chain.sv'
    helpers = HERE/'independent_windows_leaf.svh'
    extension = HERE/'window_write_update_leaf.svh'
    recipe = HERE/'prepare_window_write_update.py'
    text = base.read_text()
    edits = {
        '  int ticks=0, accepted=0, backing=0;':
            '  logic hold_ack=0;\n  int ticks=0, accepted=0, backing=0;',
        '  assign m_ack=m_req && ((ticks%3)==0);':
            '  assign m_ack=m_req && !hold_ack && ((ticks%3)==0);\n'
            '  assign m_pair_ack=m_pair_req && m_ack;',
        '  logic m_pair_req, m_pair_ready=0, m_pair_ack=0;':
            '  logic m_pair_req, m_pair_ready=1, m_pair_ack;',
        '    if(rst_n && c_req && !c_we && c_ack) begin':
            '    if(m_pair_req && m_pair_ack)\n'
            '      for(int b=0;b<4;b++) if(m_pair_wstrb[b])\n'
            '        mem[m_pair_addr+b]=m_pair_wdata[b*8 +: 8];\n'
            '    if(rst_n && c_req && !c_we && c_ack) begin',
        '  initial begin\n    for(int i=0;i<65536;i++)':
            helpers.read_text().split('task automatic run_independent_windows;')[0] +
            '\n  `include "window_write_update_leaf.svh"\n'
            '  initial begin\n    for(int i=0;i<65536;i++)',
        '    $finish;': '    run_window_write_update();\n    $finish;',
        '#1000000;': '#10000000;',
    }
    for old,new in edits.items():
        assert text.count(old)==1,old
        text=text.replace(old,new)
    generated=a.out/'tb_l1d_mem_chain.sv';generated.write_text(text)
    lines=a.profile.read_text().splitlines();defs=set(lines)
    assert lines and len(lines)==len(defs) and FLAG not in defs
    assert all(re.fullmatch(r'VEN_[A-Z0-9_]+',d) for d in defs)
    assert {'VEN_L1D_INDEPENDENT_WINDOW_INVALIDATE','VEN_L1D_BANKED_DATA',
            'VEN_L1D_TWO_WINDOW_REUSE','VEN_P54_LOAD_STORE_PAIR',
            'VEN_RAW_V_READ_PRIME'}<=defs
    original=a.source/'rtl/mem/ven_l1d.sv'
    candidate=a.out/'ven_l1d.sv';candidate.write_text(transform(original.read_text()))
    pins={str(p.resolve()):sha(p) for p in
          (Path(__file__),base,helpers,extension,recipe,generated,a.profile,original,candidate)}
    result=dict(passed=False,variants=[],gameplay_ipc=None,standard_suite=False)
    env=dict(os.environ,CCACHE_DISABLE='1',PYTHONDONTWRITEBYTECODE='1')
    try:
        for name,source,extra,negative in (
            ('control',original,set(),False),
            ('candidate-off',candidate,set(),False),
            ('candidate',candidate,{FLAG},False),
            ('required-failure',original,{'WU_REQUIRE_NEW_BEHAVIOR'},True),
        ):
            out=a.out/name;out.mkdir()
            files=[a.source/'rtl/mem'/x for x in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]+[source]
            pins.update({str(p.resolve()):sha(p) for p in files})
            cmd=['timeout','--kill-after=5s','180s','/tools/verilator/v5.046/bin/verilator',
                 '--binary','--timing','-sv','--assert','-j','32','-Wno-fatal','-Wno-UNUSED',
                 *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                 '-I'+str(HERE),'--top-module','tb_l1d_mem_chain','--Mdir',str(out/'obj'),'-o','test',
                 *['+define+'+d for d in sorted(defs|extra)],*map(str,files),str(generated)]
            (out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n')
            with (out/'build.log').open('x') as f:
                code=subprocess.run(cmd,env=env,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,)).returncode
            row=dict(name=name,build_exit=code);result['variants'].append(row)
            assert code==0,(name,'build',code)
            with (out/'run.log').open('x') as f:
                code=subprocess.run(['timeout','30s',out/'obj/test'],env=env,stdout=f,stderr=subprocess.STDOUT).returncode
            row.update(native_exit=code,binary_sha256=sha(out/'obj/test'))
            log=(out/'run.log').read_text();assert 'L1D-MEM-CHAIN-OK accepted=150' in log
            if negative:
                assert code in (1,-6,134) and 'WRITE-UPDATE-REUSE-MISSING' in log
                assert '%Fatal:' in log and 'Verilog $stop' in log
                row['expected_assertion']=True
            else:
                assert code==0,(name,code)
                match=re.search(r'WINDOW-WRITE-UPDATE-OK checks=(\d+) stores=(\d+) immediate=(\d+)',log)
                assert match
                row.update(checks=int(match[1]),stores=int(match[2]),immediate=int(match[3]))
        orig,off,on,_=result['variants']
        assert all(orig[k]==off[k] for k in ('checks','stores','immediate'))
        assert on['checks']==orig['checks'] and on['stores']==orig['stores']
        assert on['immediate']>orig['immediate']
        result['passed']=True
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (a.out/'pins.json').write_text(json.dumps(pins,indent=2)+'\n')
        (a.out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2),flush=True)
    assert result['passed']


if __name__=='__main__':
    main()
