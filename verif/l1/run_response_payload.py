#!/usr/bin/env python3
"""Current-read payload A/B: exact full profile, coherent stores, negative control."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess

from prepare_response_payload import FLAG, transform

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]

def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--parent', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    a.parent = a.parent.resolve(strict=True); a.out = a.out.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert a.out.is_relative_to(scratch) and Path(os.environ['TMPDIR']).resolve() == a.out
    assert subprocess.run([REPO/'tools/build_scope.sh', '--is-active'],
                          pass_fds=(9,), stdout=subprocess.DEVNULL).returncode == 0
    resource.setrlimit(resource.RLIMIT_CORE, (0,0))
    prior = json.loads((a.parent/'build-started.json').read_text())
    assert all(sha(f) == h for f,h in prior['pins'].items())
    defs = [x for x in prior['command'] if x.startswith('VL_EXTRA_DEFINES=')]
    assert len(defs) == 1
    options = defs[0].split('=',1)[1].split()
    host_only = {'--savable', '--assert', *['-Werror-'+w for w in
        ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')]}
    assert all(d.startswith('+define+') or d in host_only for d in options)
    defs = [d for d in options if d.startswith('+define+')]
    assert len(defs)==len(set(defs)) and all(d.startswith('+define+') for d in defs)
    assert '+define+'+FLAG not in defs and '+define+SYNTHESIS' not in defs
    assert {'+define+VEN_L1D_STORE_WINDOW_WARM', '+define+VEN_RAW_V_READ_PRIME',
            '+define+VEN_L1D_TWO_WINDOW_REUSE', '+define+VEN_P54_DUAL_HIT_LEGACY_CAPTURE'} <= set(defs)
    base = HERE/'tb_l1d_mem_chain.sv'
    helpers = HERE/'independent_windows_leaf.svh'
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
            '  `include "store_window_warm_leaf.svh"\n'
            '  `include "response_payload_leaf.svh"\n'
            '  initial begin\n    for(int i=0;i<65536;i++)',
        '    $finish;': '    run_window_write_update();\n    run_store_window_warm();\n'
                      '    run_response_payload();\n    $finish;',
        '#1000000;': '#10000000;',
    }
    for old,new in edits.items():
        assert text.count(old)==1, old
        text = text.replace(old,new)
    # Native interface samples, not architectural .vtrace records. Keep every
    # clock and all handshake outputs; payload only when its valid owner fires.
    observe = '''
  integer observations;
  string observation_path;
  initial begin
    if (!$value$plusargs("OBS=%s",observation_path)) $fatal(1,"missing observation file");
    observations=$fopen(observation_path,"w");
    if (!observations) $fatal(1,"cannot open observation file");
  end
  always @(posedge clk) begin
    $fdisplay(observations,"%0d %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
      ticks, rst_n, c_req, c_ack, c_next_ready,
      (c_req && !c_we && c_ack) ? c_rdata : 32'd0,
      c_rdata_hi_valid, c_rdata_hi_valid ? c_rdata_hi : 32'd0,
      c_pair_ready, c_pair_ack, pair_req_ready, pair_rsp_valid, pair_rsp_cancel,
      pair_rsp_valid[0] ? pair_rsp_data[0] : 32'd0,
      pair_rsp_valid[1] ? pair_rsp_data[1] : 32'd0,
      m_req, m_we, m_req ? m_addr : 32'd0,
      (m_req && m_we) ? m_wdata : 32'd0, m_req ? m_wstrb : 4'd0,
      m_pair_req, m_pair_req ? m_pair_wdata : 32'd0);
  end
'''
    assert text.count('endmodule')==1
    generated = a.out/'tb_l1d_mem_chain.sv'
    generated.write_text(text.replace('endmodule',observe+'endmodule'))
    original = a.parent/'candidate/rtl/mem/ven_l1d.sv'
    assert sha(original)=='acb5dca4d2ef4489d3c95b8c051624da581c2e77e2f7bc9a662b2a11d00deb8c'
    changed = transform(original.read_text())
    candidate = a.out/'ven_l1d.sv'; candidate.write_text(changed)
    # This mutation must be rejected by the independent backing-memory oracle
    # or by the retained original-mux assertion, not by a timeout/build error.
    bad = a.out/'never_shadow.sv'
    bad.write_text(changed.replace('wire shadow_payload_select = !rd_match && shadow_valid_q &&',
                                  "wire shadow_payload_select = 1'b0 && shadow_valid_q &&"))
    sources = [a.parent/'candidate/rtl/mem'/f for f in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    pins = {str(f):sha(f) for f in [Path(__file__), HERE/'prepare_response_payload.py',
        base, helpers, HERE/'window_write_update_leaf.svh', HERE/'store_window_warm_leaf.svh',
        HERE/'response_payload_leaf.svh', generated, original, candidate, bad, *sources]}
    (a.out/'started.json').write_text(json.dumps(dict(pins=pins,defines=defs,
        source_parent=str(a.parent),invocation=os.environ.get('INVOCATION_ID')),indent=2))
    result = dict(passed=False, variants=[],gameplay_ipc=None,standard_suite=False)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1')
    try:
        for name,source,enabled,negative in [('control',original,False,False),
                ('off',candidate,False,False),('on',candidate,True,False),
                ('negative',bad,True,True)]:
            out = a.out/name; out.mkdir()
            command = ['timeout','--kill-after=5s','180s','/tools/verilator/v5.046/bin/verilator',
                '--binary','--timing','-sv','--assert','-j','32','-Wno-fatal','-Wno-UNUSED',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(HERE),'--top-module','tb_l1d_mem_chain','--Mdir',str(out/'obj'),'-o','test',
                *defs,*(['+define+'+FLAG] if enabled else []),*map(str,sources),str(source),str(generated)]
            (out/'command.json').write_text(json.dumps(command,indent=2))
            with (out/'build.log').open('x') as f:
                code = subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,)).returncode
            row = dict(name=name,build_exit=code); result['variants'].append(row)
            assert code==0,(name,'build')
            obs = out/'cycles.txt'
            with (out/'run.log').open('x') as f:
                code = subprocess.run(['timeout','30s',out/'obj/test','+OBS='+str(obs)],env=env,
                    stdout=f,stderr=subprocess.STDOUT).returncode
            row.update(native_exit=code,binary_sha256=sha(out/'obj/test'),cycles_sha256=sha(obs))
            log = (out/'run.log').read_text()
            if negative:
                assert code in (1,-6,134) and ('old-response owner/data changed' in log or
                    'L1 primary payload cut changed an acknowledged read' in log),log
                row['expected_assertion']=True
            else:
                assert code==0,(name,log)
                for marker in ('L1D-MEM-CHAIN-OK accepted=150', 'WINDOW-WRITE-UPDATE-OK',
                               'STORE-WARM-OK','RESPONSE-PAYLOAD-OK'):
                    assert marker in log,(name,marker)
            # Preserve lossless full per-clock evidence, without retaining both
            # the raw and compressed generated observations.
            with obs.open('rb') as src, gzip.open(str(obs)+'.gz','xb',compresslevel=3) as dst:
                while block:=src.read(1024*1024): dst.write(block)
            with gzip.open(str(obs)+'.gz','rb') as f:
                assert hashlib.file_digest(f,'sha256').hexdigest()==row['cycles_sha256']
            obs.unlink()
            print(json.dumps(row),flush=True)
        assert len({r['cycles_sha256'] for r in result['variants'][:3]})==1
        result.update(passed=True,all_clock_interface_observations_identical=True)
    finally:
        result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['pins_unchanged']
        (a.out/'closed.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result),flush=True)
    assert result['passed']

if __name__=='__main__':
    main()
