#!/usr/bin/env python3
"""Compare actual parent/candidate L1 interfaces on every sampled edge.

Requires tools/build_scope.sh; retains native logs, source pins and two negative
controls. No source under an existing run is edited and no FPGA run is launched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from prepare_l1_legacy_capture_cut import PARENT_SHA, transform

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
VL = '/tools/verilator/v5.046/bin/verilator'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def ports(preprocessed):
    text = re.sub(r'//[^\n]*|/\*.*?\*/|`line[^\n]*', '', preprocessed, flags=re.S)
    match = re.search(r'module\s+ven_l1d\b.*?\)\s*\((.*?)\);', text, re.S)
    if not match:
        raise ValueError('L1 preprocessed header missing')
    result=[]
    direction=width=None
    for piece in match[1].split(','):
        piece=piece.strip()
        m=re.fullmatch(r'(input|output)\s+logic\s*((?:\[[^\]]+\]\s*)*)(\w+)', piece)
        if m:
            direction,width,name=m.groups()
        elif re.fullmatch(r'\w+', piece) and direction:
            name=piece
        else:
            raise ValueError('unsupported header '+piece)
        result.append((direction,width,name))
    if len({x[2] for x in result}) != len(result):
        raise ValueError('duplicate L1 port')
    return result


def observer(portlist):
    outputs={name:width for direction,width,name in portlist if direction=='output'}
    code='\n'.join('  logic '+width+'ref_'+name+';' for name,width in outputs.items())+'\n'
    code+='  parent_l1d reference (\n'+',\n'.join(
        '    .'+name+'(' + ('ref_' if direction=='output' else '')+name+')'
        for direction,width,name in portlist)+'\n  );\n'
    # Compare controls even when idle; compare payload only for its valid owner.
    controlled={
        'c_rdata':'c_ack', 'c_rdata_hi':'c_ack && c_rdata_hi_valid',
        'm_addr':'m_req', 'm_wdata':'m_req && m_we', 'm_wstrb':'m_req',
        'm_pair_addr':'m_pair_req', 'm_pair_wdata':'m_pair_req', 'm_pair_wstrb':'m_pair_req',
        'pair_rsp_owner':'|pair_rsp_valid', 'pair_rsp_paddr':'|pair_rsp_valid',
        'pair_rsp_data':None, 'pair_now_data':'pair_now_valid',
    }
    code+='  int cut_miter_edges=0;\n  always @(clk) begin\n    if(!clk) #0.5;\n    if(rst_n) begin\n'
    for name in outputs:
        if name in ('pair_rsp_data','pair_rsp_owner','pair_rsp_paddr'):
            for lane in range(2):
                code+=f'    if(pair_rsp_valid[{lane}] && {name}[{lane}]!==ref_{name}[{lane}]) $fatal(1,"CUT_EQUIV {name}[{lane}]");\n'
        else:
            guard=controlled.get(name,'1\'b1')
            code+=f'    if(({guard}) && {name}!==ref_{name}) $fatal(1,"CUT_EQUIV {name}");\n'
    for name in ('do_rd_cap','pair_legacy_capture','pair_prime_capture','pair_store_read_capture',
                 'pair_lookup_active','pair_bank_ready','mc_capture_next'):
        code+=f'    if(dut.{name}!==reference.{name}) $fatal(1,"CUT_EQUIV {name}");\n'
    code+='    cut_miter_edges++;\n    end\n  end\n'
    return code


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent-export',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent=args.parent_export.resolve(strict=True); out=args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.is_relative_to(parent)
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    out.mkdir()
    source=parent/'ventium/rtl/mem/ven_l1d.sv'
    assert sha(source)==PARENT_SHA
    original=source.read_text(); changed=transform(original)
    manifest=parent/'input-manifest.json'
    defs=set(json.loads(manifest.read_text())['hardware_defines'])
    # Keep the hardware feature profile, but enable the RTL's own simulation
    # assertions/counters (the existing fixture checks those counters too).
    defs.remove('SYNTHESIS')
    assert {'VEN_P54_DUAL_HIT','VEN_P54_DUAL_HIT_LEGACY_CAPTURE',
            'VEN_PIPE_REG_LOAD_PRIME','VEN_RAW_V_READ_PRIME','VEN_P54_DUAL_BYTE_LOAD_PAIR'} <= defs
    assert not {'VEN_L1D_COMB_ACK','VEN_P54_DUAL_LOAD_PRIME','VEN_L1D_HIT_STREAM'} & defs
    base=HERE/'tb_l1d_mem_chain.sv'
    inputs=[source,manifest,base,HERE/'l1_legacy_capture_cut_leaf.svh',
            HERE/'prepare_l1_legacy_capture_cut.py',HERE/'test_l1_legacy_capture_cut.py',Path(__file__)]
    modules=[parent/'ventium/rtl/mem'/x for x in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    pins={str(p):sha(p) for p in [*inputs,*modules]}

    def write(path,text):
        with path.open('x') as f: f.write(text)
        pins[str(path)]=sha(path)

    def save(name,value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2); f.write('\n')

    def run(label,command,seconds):
        save(label+'.command.json',list(map(str,command)))
        with (out/(label+'.log')).open('x') as log:
            rc=subprocess.run(['timeout','--kill-after=5s',str(seconds)+'s',*map(str,command)],
                stdout=log,stderr=subprocess.STDOUT,pass_fds=(9,)).returncode
        return rc,(out/(label+'.log')).read_text()

    start=time.monotonic()
    result=dict(passed=False,rows=[],errors=[],gameplay_ipc=None,standard_suite=False)
    save('started.json',dict(invocation=os.environ.get('INVOCATION_ID'),parent=str(parent),pins=pins))
    try:
        env=dict(os.environ,L1_CAPTURE_PARENT=str(source))
        with (out/'recipe-tests.log').open('x') as log:
            unit=subprocess.run(['python3','-B',HERE/'test_l1_legacy_capture_cut.py','-v'],
                                env=env,stdout=log,stderr=subprocess.STDOUT)
        assert unit.returncode==0
        for label,extra,mutation in (
            ('hardware',set(),None),
            ('prime-store',{'VEN_P54_DUAL_LOAD_PRIME','VEN_P54_STORE_LOAD_PAIR'},None),
            ('mutant-uncommitted',set(),'commit'),
            ('mutant-reuse',set(),'reuse')):
            leaf=out/label; leaf.mkdir()
            new=changed
            if mutation=='commit':
                new=new.replace('&& do_rd_cap_legacy','&& do_rd_cap_legacy && c_next_commit')
            if mutation=='reuse':
                new=new.replace('!rd_match && !window_reuse && !shadow_reuse',"!rd_match && 1'b1 && 1'b1")
            write(leaf/'ven_l1d.sv',new)
            write(leaf/'parent_l1d.sv',original.replace('module ven_l1d #(', 'module parent_l1d #(')
                  .replace('endmodule : ven_l1d','endmodule : parent_l1d'))
            macros=sorted(defs|extra)
            preprocess=[VL,'-E',*['+define+'+d for d in macros],source]
            rc,pp=run(label+'-preprocess',preprocess,20); assert rc==0
            portlist=ports(pp)
            fixture=base.read_text().replace('  ven_l1d dut(.*);',
                       '  ven_l1d dut(.*);\n'+observer(portlist))
            fixture=fixture.replace('  int ticks=0, accepted=0, backing=0;',
                '  logic hold_ack=0;\n  int ticks=0, accepted=0, backing=0;')
            fixture=fixture.replace('assign m_ack=m_req && ((ticks%3)==0);',
                'assign m_ack=m_req && !hold_ack && ((ticks%3)==0);')
            fixture=fixture.replace('  initial begin\n    for(int i=0;i<65536;i++)',
                '  `include "l1_legacy_capture_cut_leaf.svh"\n  initial begin\n    for(int i=0;i<65536;i++)')
            assert fixture.count('    $finish;')==1
            fixture=fixture.replace('    $finish;',
                '    run_legacy_capture_cut();\n    $display("CUT-MITER-EDGES %0d",cut_miter_edges);\n    $finish;')
            write(leaf/'tb_l1d_mem_chain.sv',fixture)
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
                '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                    ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(HERE),*['+define+'+d for d in macros],
                '--top-module','tb_l1d_mem_chain','--Mdir',leaf/'obj','-j','32',
                *modules,leaf/'parent_l1d.sv',leaf/'ven_l1d.sv',leaf/'tb_l1d_mem_chain.sv']
            rc,_=run(label+'-build',command,180); assert rc==0,(label,'build',rc)
            model=leaf/'obj/Vtb_l1d_mem_chain'
            rc,log=run(label+'-run',[model],30)
            row=dict(label=label,native_exit=rc,binary_sha256=sha(model))
            result['rows'].append(row)
            if mutation:
                assert rc!=0 and 'CUT_EQUIV' in log and 'L1-LEGACY-CAPTURE-CUT-OK' not in log,(label,rc,log)
                row['rejected_by_equivalence']=True
            else:
                match=re.search(r'L1-LEGACY-CAPTURE-CUT-OK checks=(\d+) fresh=(\d+) same_bank=(\d+) held=(\d+)',log)
                assert rc==0 and match,(label,rc,log[-3000:])
                assert tuple(map(int,match.groups()))==(538,448,64,1536)
                assert 'L1D-MEM-CHAIN-OK accepted=150' in log
                row['checks']=list(map(int,match.groups()))
                row['edges']=int(re.search(r'CUT-MITER-EDGES (\d+)',log)[1])
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result['pins_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['pins_unchanged']
        result['seconds']=time.monotonic()-start
        save('pins.json',pins); save('closed.json',result)
        print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
