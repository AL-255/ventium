"""Small source-extracted request miter, not a whole-core or timing pass."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_pipe_mem_cs_extent as recipe
from prove_pipe_mem_cs_extent import problem, QUERIES

FIELDS = [('state',2),('eip',32),('cs_limit',32),('u_len',4),('held_len',4),('d_len',4),
          ('stall_cnt',7),('pending_mem_pen',7),('mispred_bubbles',3),('sfetch_header_fault_q',2)]
FIELDS += [(n,1) for n in ('sys_mode real_mode v86 cs_present pipe_mem_active_q '
    'fp_issue_block exec_issue_ok pipe_frontend_ready fp_pipe_rd_haz is_fp fp_sys_bail '
    'pipe_agi is_mem is_store pipe_mem_we_q sfetch_early_nm sfetch_early_gp').split()]
OUTPUTS = ['pipe_new_load_req','pipe_new_store_req','pipe_load_req','pipe_store_req']


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def statement(source,name,assigned=False):
    pattern = (r'^  assign ' if assigned else r'^    ')+name+r'\s*=.*?;\n'
    rows=re.findall(pattern,source,re.M|re.S)
    assert len(rows)==1,(name,len(rows))
    return rows[0] if assigned else '  assign '+rows[0].lstrip()


def module(source,name,cofactor=False,mutant=None):
    ports=[f'input wire [{width-1}:0] {key}' for key,width in FIELDS]
    ports += ['output wire '+key for key in OUTPUTS]
    text='module '+name+'('+',\n'.join(ports)+');\n'
    text+='''  localparam S_PIPE=2'd1, S_DECODE=2'd2, SG_CS=0;
  typedef struct packed {logic [3:0] len;logic is_fp,is_mem,is_store;} decoded;
  decoded u_d,pipe_u_eff;
  assign u_d={u_len,is_fp,is_mem,is_store};
  assign pipe_u_eff={pipe_mem_active_q ? held_len : u_len,is_fp,is_mem,is_store};
  wire [7:0] seg_attr[0:0];
  wire [31:0] seg_limit[0:0];
  assign seg_attr[0]={cs_present,7'd0};
  assign seg_limit[0]=cs_limit;
  wire pipe_cs_preissue_ok,pipe_cs_issue_eligible,cs_extent_fault;
  wire pipe_new_mem_cs_extent_fault;
'''
    for key in ('pipe_cs_preissue_ok','pipe_cs_issue_eligible'):
        text+=statement(source,key,True)
    fault=re.findall(r'^    cs_extent_fault = sys_mode.*?;\n',source,re.M|re.S)
    assert len(fault)==1
    text+='`ifdef VEN_SEG_ENFORCE\n  assign '+fault[0].lstrip()
    text+="`else\n  assign cs_extent_fault=1'b0;\n`endif\n"
    if cofactor:
        added=recipe.ADDED
        if mutant=='lost-limit':
            before=re.findall(r'  assign pipe_new_mem_cs_extent_fault = sys_mode.*?;\n',added,re.S)
            assert len(before)==1
            added=added.replace(before[0],"  assign pipe_new_mem_cs_extent_fault = 1'b0;\n")
        elif mutant=='wrap32':
            old="({1'b0, eip} + {28'd0, u_d.len} - 33'd1) >\n                      {1'b0, seg_limit[SG_CS]}"
            assert added.count(old)==1
            added=added.replace(old,"(eip + {28'd0, u_d.len} - 32'd1) > seg_limit[SG_CS]")
        else:assert mutant is None
        text+=added
    for key in OUTPUTS:text+=statement(source,key)
    return text+'endmodule\n'


def bench():
    text='module tb_pipe_cs;\n'
    for key,width in FIELDS:text+=f'  reg [{width-1}:0] {key};\n'
    text+='  wire [3:0] old_req,new_req;\n'
    for label,port in (('original','old_req'),('cofactor','new_req')):
        ports=[f'.{n}({n})' for n,_ in FIELDS]+[f'.{n}({port}[{i}])' for i,n in enumerate(OUTPUTS)]
        text+='  '+label+' '+label+'_i('+','.join(ports)+');\n'
    text+='''  integer seed=32'h31724568;
  integer loads=0,stores=0,held=0;
  initial begin
    for(integer i=0;i<16384;i=i+1) begin
'''
    for key,_ in FIELDS:text+='      '+key+'=$random(seed);\n'
    text+='''      // Bias one quarter toward real admission; random gated cases
      // exercise rejection and held owners as well. All slow lengths vary.
      if((i%4)==0) begin
        state=1;pipe_mem_active_q=0;fp_issue_block=0;exec_issue_ok=1;
        pipe_frontend_ready=1;stall_cnt=0;pending_mem_pen=0;fp_sys_bail=0;
        pipe_agi=0;mispred_bubbles=0;fp_pipe_rd_haz=0;
      end
      case(i%16)
        0: begin eip=32'hffffffff;u_len=2;cs_limit=32'hffffffff;end
        1: begin eip=0;u_len=0;cs_limit=32'hffffffff;end
        2: begin cs_limit=eip+{28'd0,u_len}-1;end
        3: begin cs_limit=eip+{28'd0,u_len}-2;end
        default: begin end
      endcase
      if(i==0) begin
        sys_mode=1;real_mode=0;v86=0;cs_present=1;is_mem=1;is_store=0;
      end
      #1;
      if(old_req !== new_req)
        $fatal(1,"PIPE-CS-MITER-MISMATCH i=%0d state=%0d eip=%h len=%0d limit=%h old=%b new=%b",i,state,eip,u_len,cs_limit,old_req,new_req);
      if(old_req[0])loads=loads+1;
      if(old_req[1])stores=stores+1;
      if(pipe_mem_active_q && (|old_req[3:2]))held=held+1;
    end
    if(loads==0 || stores==0 || held==0)$fatal(1,"missing admission coverage");
    $display("PIPE-CS-MITER-OK checks=16384 loads=%0d stores=%0d held=%0d",loads,stores,held);
    $finish;
  end
endmodule
'''
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('source','out'):ap.add_argument('--'+n,type=Path,required=True)
    args=ap.parse_args();source=args.source.resolve(strict=True);root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and os.environ.get('INVOCATION_ID') and os.sched_getaffinity(0)=={12}
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    old=source.read_text();new=recipe.transform(old)
    pins={str(p.resolve()):sha(p) for p in (source,Path(__file__),Path(recipe.__file__),
        Path(__file__).with_name('prove_pipe_mem_cs_extent.py'),
        Path('/usr/bin/iverilog'),Path('/usr/bin/vvp'),Path('/usr/bin/z3'))}
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[12]))
    begin=time.monotonic();rows=[]
    for seg,fp,mutant in [(s,f,None) for s in (0,1) for f in (0,1)]+[(1,1,'lost-limit'),(1,1,'wrap32')]:
        label=f's{seg}-f{fp}-'+(mutant or 'positive');folder=root/label;folder.mkdir()
        code=module(old,'original')+module(new,'cofactor',True,mutant)+bench()
        with (folder/'miter.sv').open('x') as f:f.write(code)
        command=['/usr/bin/iverilog','-g2012','-s','tb_pipe_cs',
            *(['-DVEN_SEG_ENFORCE'] if seg else []),*(['-DVEN_FP_PIPE'] if fp else []),
            '-o',str(folder/'test'),str(folder/'miter.sv')]
        for stage,cmd in (('compile',command),('simulate',['/usr/bin/vvp',str(folder/'test')])):
            with (folder/(stage+'.log')).open('x') as f:
                done=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=20)
            if stage=='compile':assert done.returncode==0,label
        log=(folder/'simulate.log').read_text()
        if mutant:
            assert done.returncode!=0 and 'PIPE-CS-MITER-MISMATCH i=0 ' in log,(label,log)
        else:
            assert done.returncode==0 and 'PIPE-CS-MITER-OK checks=16384 ' in log,(label,log)
        rows.append(dict(label=label,native_exit=done.returncode,expected_failure=bool(mutant),
            artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()}))
    proofs=[]
    for name,formula,expected in QUERIES:
        query=problem()+'(assert '+formula+')\n(check-sat)\n'
        with (root/(name+'.smt2')).open('x') as f:f.write(query)
        result=subprocess.run(['/usr/bin/z3','-in','-smt2'],input=query,text=True,capture_output=True,timeout=10)
        with (root/(name+'.stdout')).open('x') as f:f.write(result.stdout)
        assert result.returncode==0 and not result.stderr and result.stdout.strip()==expected
        proofs.append(dict(name=name,result=expected,native_exit=0))
    assert all(sha(p)==h for p,h in pins.items())
    save('closed.json',dict(passed=True,pins_unchanged=True,profiles=rows,queries=proofs,
        seconds=time.monotonic()-begin,checks=4*16384,candidate_rtl_changed=False,
        whole_core_qualified=False,timing_measured=False,gameplay_ipc=None,standard_suite=False))
    print('PIPE-CS-LEAF-OK four profiles, 65536 comparisons, two native mutants, six SMT queries',flush=True)


if __name__=='__main__':main()
