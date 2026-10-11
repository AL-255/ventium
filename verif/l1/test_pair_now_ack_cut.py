#!/usr/bin/env python3
"""Prove and simulate the source-extracted same-line response ACK cofactor.

No full-cache, core or timing acceptance is implied. Builds only a small
Icarus combinational microtest, not a competing Verilator/Vivado job.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

import prepare_pair_now_ack_cut as patch


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def assignment(source, name):
    rows = re.findall(r'  assign '+name+r' = .*?;\n', source, re.S)
    identity = 'window_valid_q' if name == 'window_reuse' else 'shadow_valid_q'
    rows = [row for row in rows if identity in row]
    if len(rows) != 1:
        raise ValueError('ambiguous reuse assignment '+name)
    return rows[0]


def formal(mutant=False):
    flags = ('req we cache hit stream flush snoop early golden idle next code '
             'window_id shadow_id window_feature shadow_feature code_feature '
             'extent shape other_read write_ack stream_ack stream_feature comb '
             'comb_ack').split()
    text='(set-logic QF_BV)\n'
    for name in flags:
        text+=f'(declare-const {name} Bool)\n'
    terms={
        'reuse_guard':'(and req (not we) cache hit (not stream) (not flush) '
                      '(not snoop) (not early) (not golden) idle (not next) '
                      '(not (and code_feature code)) extent)',
        'window':'(and window_feature window_id reuse_guard)',
        'shadow':'(and window_feature shadow_feature shadow_id reuse_guard)',
        'ack':'(ite comb comb_ack (ite (and stream_feature stream) stream_ack '
              '(and req (ite we write_ack (or window shadow other_read)))))',
        'old':'(and shape req (not we) cache ack (or window shadow))',
        'new':'(and shape req (not we) cache (or (not comb) ack) (or window shadow))',
    }
    if mutant:
        terms['new']=terms['new'].replace('(or window shadow)', 'true')
    for name,body in terms.items():
        text+=f'(define-fun {name} () Bool {body})\n'
    return text+'(assert (not (= old new)))\n(check-sat)\n'


def fixture(source, mutant=None):
    start=source.rindex("    c_ack   = 1'b0;\n")
    end=source.index('  end\n\n`ifndef SYNTHESIS\n`ifndef VEN_L1D_COMB_ACK',start)
    ack=source[start:end]
    boundary='`endif\n`ifdef VEN_L1D_HIT_STREAM'
    data="      c_rdata = rd_window_q[{1'b0,rd_addr_q[4:0],3'b000} +: 32];\n"
    assert ack.count(boundary)==1 and ack.count(data)==1
    ack=ack.replace(boundary,'`ifdef VEN_L1D_HIT_STREAM').replace(data,'')
    window=assignment(source,'window_reuse')
    shadow=assignment(source,'shadow_reuse')
    original=patch.extract(source)
    changed=patch.extract(patch.transform(source))
    if mutant=='unowned':
        changed=changed.replace('(window_reuse || shadow_reuse)',"1'b1")
    elif mutant=='same-bank':
        changed=changed.replace('(c_addr[4:2] != pair_now_paddr[4:2])',"1'b1")
    elif mutant=='wrong-address':
        changed=changed.replace('(pair_now_paddr == pair_paddr[1])',"1'b1")
    prefix='''`timescale 1ns/1ps
module tb;
  localparam L1_IDLE=0, L1_FILL=1, L1_BYP=2, BYPASS_RD_EN=1;
  logic c_req,c_we,cacheable,hit,mc_lookup_next,stream_path,early_armed;
  logic golden,flush_all,snoop_inv_valid,code_access,window_valid_q,shadow_valid_q;
  logic window_reuse,shadow_reuse,rd_match,early_match,byp_match,code_word_reuse;
  logic m_ack,m_pair_ack,c_pair_req,c_pair_ready,c_ack;
  logic c_hit_stream,c_rsp_valid,c_rsp_ready;
  logic [1:0] st,pair_req_valid,pair_rsp_valid,pair_now_size_log2;
  logic [31:0] c_addr,rd_addr_q,pair_now_paddr;
  logic [31:5] shadow_line_addr_q;
  logic [1:0][31:0] pair_paddr;
  logic [1:0][1:0] pair_size_log2;
  logic pair_now_req,pair_now_cacheable,old_now,new_now;
  logic [63:0] rng=64'h5983cbe7fd3406a1;
  integer checks=0,returns=0;
'''
    body=('`ifdef TEST_WINDOW\n'+window+'`else\n  assign window_reuse=0;\n`endif\n'+
          '`ifdef TEST_SHADOW\n'+shadow+'`else\n  assign shadow_reuse=0;\n`endif\n'+
          '  always_comb begin\n'+ack+'  end\n'+
          original.replace('pair_now_valid =','old_now =')+
          changed.replace('pair_now_valid =','new_now ='))
    suffix='''
  task automatic check;
    #1;
    if (old_now !== new_now)
      $fatal(1,"PAIR-NOW-MISMATCH case=%0d old=%b new=%b ack=%b window=%b shadow=%b",
             checks,old_now,new_now,c_ack,window_reuse,shadow_reuse);
    checks++;
    if (old_now) returns++;
  endtask
  task automatic defaults;
    c_req=1; c_we=0; cacheable=1; hit=1; mc_lookup_next=0; stream_path=0;
    early_armed=0; golden=0; flush_all=0; snoop_inv_valid=0; code_access=0;
    window_valid_q=1; shadow_valid_q=1; rd_match=0; early_match=0; byp_match=0;
    code_word_reuse=0; m_ack=0; m_pair_ack=0; c_pair_req=0; c_pair_ready=0;
    c_hit_stream=0; c_rsp_valid=0; c_rsp_ready=0;
    st=L1_IDLE; pair_req_valid=2'b10; pair_rsp_valid=0;
    pair_now_size_log2=2; pair_size_log2={2'd2,2'd0};
    c_addr=32'h1040; rd_addr_q=c_addr; shadow_line_addr_q=c_addr[31:5];
    pair_now_paddr=c_addr+4; pair_paddr={pair_now_paddr,32'd0};
    pair_now_req=1; pair_now_cacheable=1;
  endtask
  initial begin
    defaults(); window_valid_q=0; shadow_valid_q=0; check();
    defaults(); pair_now_paddr=c_addr; pair_paddr[1]=c_addr; check();
    defaults(); pair_paddr[1]=pair_now_paddr+4; check();
    // Sweep cancellation, ownership and direction while forcing useful
    // matching address/size cases; then cover arbitrary identities/shape.
    for (integer i=0;i<4096;i++) begin
      defaults();
      {c_req,c_we,cacheable,hit,mc_lookup_next,stream_path,early_armed,
       golden,flush_all,snoop_inv_valid,window_valid_q,shadow_valid_q}=12'(i);
      m_ack=i[0]; m_pair_ack=i[1]; c_pair_req=i[2]; c_pair_ready=i[3];
      check();
    end
    for (integer i=0;i<65536;i++) begin
      defaults();
      rng=rng^(rng<<13); rng=rng^(rng>>7); rng=rng^(rng<<17);
      {st,c_req,c_we,cacheable,hit,mc_lookup_next,stream_path,early_armed,
       golden,flush_all,snoop_inv_valid,code_access,window_valid_q,shadow_valid_q,
       rd_match,early_match,byp_match,code_word_reuse,m_ack,m_pair_ack,c_pair_req,
       c_pair_ready,c_hit_stream,c_rsp_valid,c_rsp_ready}=rng[25:0];
      c_addr=rng[63:32]; rd_addr_q={c_addr[31:5],5'd0};
      shadow_line_addr_q=rng[31]?c_addr[31:5]:~c_addr[31:5];
      pair_now_paddr={c_addr[31:5],rng[4:0]};
      pair_paddr[1]=rng[30]?pair_now_paddr:~pair_now_paddr;
      pair_req_valid=rng[29:28]; pair_rsp_valid=rng[27:26];
      pair_now_size_log2=rng[25:24]; pair_size_log2[1]=rng[23]?pair_now_size_log2:2'd3;
      check();
    end
`ifdef TEST_WINDOW
    if (!returns) $fatal(1,"missing same-line return witness");
`endif
    $display("PAIR-NOW-LEAF-OK samples=%0d returns=%0d",checks,returns);
    $finish;
  end
endmodule
'''
    return prefix+body+suffix


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',required=True,type=Path)
    ap.add_argument('--out',required=True,type=Path)
    args=ap.parse_args()
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    repo=Path(__file__).resolve().parents[2]
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=repo.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    source=args.parent.read_text(); candidate=patch.transform(source)
    original=patch.extract(source)
    replacement=patch.COMMENT+original.replace(patch.OLD,patch.NEW)+patch.witness(original)
    assert candidate.replace(replacement,original)==source
    for bad in (source+'\n',candidate):
        try: patch.transform(bad)
        except ValueError: pass
        else: raise AssertionError('source drift accepted')
    root.mkdir()
    pins={str(p.resolve()):sha(p) for p in (args.parent,Path(__file__),Path(patch.__file__),
          Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'),Path('/usr/bin/z3'))}
    result=dict(passed=False,pins=pins,rows=[],symbolic=[],whole_cache=False,whole_core=False,
                gameplay_ipc=None,fmax_mhz=None,standard_suite=False)
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,affinity=sorted(os.sched_getaffinity(0)),
                            invocation=os.environ.get('INVOCATION_ID')))
    (root/'ven_l1d.sv').write_text(candidate)
    result['candidate_sha256']=sha(root/'ven_l1d.sv')
    started=time.monotonic()
    try:
        for mutant in (False,True):
            label='unowned' if mutant else 'equivalent'; problem=formal(mutant)
            (root/(label+'.smt2')).write_text(problem)
            r=subprocess.run(['/usr/bin/z3','-in','-smt2'],input=problem,text=True,
                             capture_output=True,timeout=15)
            (root/(label+'.proof.log')).write_text(r.stdout+r.stderr)
            assert r.returncode==0 and r.stdout.strip()==('sat' if mutant else 'unsat')
            result['symbolic'].append(dict(label=label,result=r.stdout.strip()))
        profiles=[]
        for stream,code,shadow in itertools.product((0,1),repeat=3):
            defs=['TEST_WINDOW','VEN_P54_DUAL_STORE_PAIR']
            defs += [d for v,d in ((stream,'VEN_L1D_HIT_STREAM'),(code,'VEN_L1D_CODE_BUFFER'),
                                  (code,'VEN_L1D_CODE_WORD_REUSE'),(shadow,'TEST_SHADOW')) if v]
            profiles.append((f'reg-{stream}{code}{shadow}',defs,None))
        profiles += [('windows-off',['VEN_P54_DUAL_STORE_PAIR'],None),
                     ('comb-preserved',['TEST_WINDOW','VEN_L1D_COMB_ACK'],None)]
        profiles += [(m,['TEST_WINDOW','TEST_SHADOW','VEN_L1D_HIT_STREAM',
                         'VEN_L1D_CODE_BUFFER','VEN_L1D_CODE_WORD_REUSE',
                         'VEN_P54_DUAL_STORE_PAIR'],m)
                     for m in ('unowned','same-bank','wrong-address')]
        for label,defs,mutant in profiles:
            folder=root/label; folder.mkdir(); tb=folder/'tb.sv'
            tb.write_text(fixture(source,mutant))
            command=['/usr/bin/iverilog','-g2012','-s','tb',*['-D'+d for d in defs],
                     '-o',str(folder/'a.out'),str(tb)]
            with (folder/'build.log').open('x') as f:
                r=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,timeout=15)
            assert r.returncode==0,label
            with (folder/'run.log').open('x') as f:
                r=subprocess.run(['/usr/bin/vvp',str(folder/'a.out')],stdout=f,
                                 stderr=subprocess.STDOUT,timeout=30)
            log=(folder/'run.log').read_text()
            if mutant: assert r.returncode==1 and 'PAIR-NOW-MISMATCH' in log,label
            else: assert r.returncode==0 and 'PAIR-NOW-LEAF-OK samples=69635' in log,label
            row=dict(label=label,defs=defs,mutant=mutant,native_exit=r.returncode,log=log.strip(),
                     source_sha256=sha(tb),binary_sha256=sha(folder/'a.out'))
            result['rows'].append(row); print(json.dumps(row),flush=True)
        result['passed']=True
    finally:
        result.update(seconds=time.monotonic()-started,pins_unchanged=all(sha(p)==v for p,v in pins.items()))
        result['passed'] &= result['pins_unchanged']; save('closed.json',result)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
