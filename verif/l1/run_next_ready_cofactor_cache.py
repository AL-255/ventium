"""Actual full-size cache A/B miter, retaining current pairing/fill regressions."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

import prepare_next_ready_cofactor as recipe
import run_next_ready_cofactor_leaf as leaf
import run_current_u_pair as previous

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
ROOT=leaf.ROOT
sha=leaf.sha


def fixture(ports,flat):
    text=previous.fixture(ports,False)
    # The current source retains the generic client, without the historical
    # default-off specialization parameter. Both instances receive all inputs.
    assert text.count("ven_l1d #(.PAIR_CURRENT_U_ONLY(1'b0))")==1
    text=text.replace("ven_l1d #(.PAIR_CURRENT_U_ONLY(1'b0))",'ven_l1d')
    text=re.sub(r'  wire \[1:0\] contract_pair_valid =\n[^;]+;\n','',text)
    assert 'PAIR_CURRENT_U_ONLY' not in text and 'contract_pair_valid' not in text
    before='      if((c_req && !c_ack) || m_req)'
    after='''      if((c_req && !c_ack) || (m_req &&
         !(dut.mc_lookup_prime && dut.st==dut.L1_FILL && !dut.code_fill_q &&
           c_next_addr[5 +: 7]!=dut.fset)))'''
    assert text.count(before)==1;text=text.replace(before,after)
    anchor='    // No gaps: old response belongs to c_addr'
    assert text.count(anchor)==1
    text=text.replace(anchor,'''    c_next_req=1;c_next_commit=0;c_next_addr='h2020;cacheable=0;
    #1;if(c_next_ready) $fatal(1,"NEXT-READY-OLD-NC accepted");
    cacheable=1;
    #1;if(!c_next_ready) $fatal(1,"NEXT-READY-OLD-NC did not recover");
    c_next_req=0;
'''+anchor)
    includes=''.join('  `include "'+name+'"\n' for name in (
        'code_word_reuse_leaf.svh','data_under_ifill_leaf.svh',
        'prime_under_ifill_leaf.svh','next_ready_underfill_leaf.svh'))
    anchor='  initial begin\n    for(int i=0;i<65536;i++)'
    assert text.count(anchor)==1;text=text.replace(anchor,includes+anchor)
    text=text.replace('    $finish;',
        '    run_code_word_reuse();\n    run_data_under_ifill();\n'
        '    run_prime_under_ifill();\n    run_next_ready_underfill();\n'
        '    $display("NEXT-READY-CACHE-OK samples=%0d",cut_miter_edges);\n    $finish;')
    assert text.count('#1000000; $fatal')==1
    text=text.replace('#1000000; $fatal','#6000000; $fatal')
    # Same inputs and same generic-client configuration for both instances.
    # Compare all persistent cache bytes/tags as well as the public miter.
    arrays='''
  always @(posedge clk or negedge clk) begin
    #2;
    if(rst_n) for(integer s=0;s<128;s++) begin
      if(dut.dc_lru[s]!==reference.dc_lru[s] || dut.dc_val[s]!==reference.dc_val[s])
        $fatal(1,"NEXT-READY-ARRAY metadata");
'''
    if flat:
        arrays+='''      if(dut.dc_tag_way0[s]!==reference.dc_tag_way0[s] ||
         dut.dc_tag_way1[s]!==reference.dc_tag_way1[s]) $fatal(1,"NEXT-READY-ARRAY tags");
'''
    else:
        arrays+='''      if(dut.dc_tag[s]!==reference.dc_tag[s]) $fatal(1,"NEXT-READY-ARRAY tags");
'''
    arrays+='''    end
  end
  for(genvar bank=0;bank<8;bank++) begin : g_next_ready_arrays
    always @(posedge clk or negedge clk) begin
      #2;
      if(rst_n) for(integer row=0;row<256;row++)
        if(dut.g_banked_read[bank].data[row]!==reference.g_banked_read[bank].data[row])
          $fatal(1,"NEXT-READY-ARRAY data");
    end
  end
'''
    return text.replace('endmodule',arrays+'endmodule')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','out'):ap.add_argument('--'+name,type=Path,required=True)
    a=ap.parse_args();parent=a.parent.resolve(strict=True);checked=a.leaf.resolve(strict=True);out=a.out.absolute()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert out.parent.resolve(strict=True)==ROOT and not out.exists()
    assert ROOT.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(ROOT).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(32)) and os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True,timeout=10)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    start=json.loads((checked/'started.json').read_text());done=json.loads((checked/'closed.json').read_text())
    assert done['passed'] and done['proof_passed'] and done['pins_unchanged'] and not done['errors']
    assert [(r['profile'],r['mode'],r['native_exit']) for r in done['rows']]==[
        *[(p,'positive',0) for p in leaf.PROFILES],*[('full',m,1) for m in leaf.MUTANTS]]
    pins=dict(start['pins'])
    for row in done['rows']:pins.update(row['artifacts'])
    prior=json.loads((parent/'build-started.json').read_text());defs=prior['definitions']
    assert len(defs)==len(set(defs))==153 and 'SYNTHESIS' not in defs
    source=parent/'candidate/rtl/mem/ven_l1d.sv';assert sha(source)==recipe.PARENT
    candidate=(checked/'ven_l1d.sv').read_text();assert candidate==recipe.transform(source.read_text())
    modules=[source.with_name(n) for n in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    for p in [source,*modules]:assert sha(p)==prior['pins'][str(p)]
    inputs=[parent/'build-started.json',checked/'started.json',checked/'closed.json',checked/'ven_l1d.sv',
        Path(__file__),Path(recipe.__file__),Path(leaf.__file__),Path(previous.__file__),Path(previous.original.__file__),
        HERE/'prepare_current_u_pair.py',HERE/'tb_l1d_mem_chain.sv',HERE/'l1_legacy_capture_cut_leaf.svh',
        *[HERE/n for n in ('code_word_reuse_leaf.svh','data_under_ifill_leaf.svh','prime_under_ifill_leaf.svh','next_ready_underfill_leaf.svh')],
        *modules,REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh']
    pins.update({str(p.resolve()):sha(p) for p in inputs})
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir()
    def save(name,obj):
        with (out/name).open('x') as stream:json.dump(obj,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],definitions=defs))
    begin=time.monotonic();rows=[];errors=[]
    def run(label,command,limit):
        cmd=list(map(str,command));save(label+'.command.json',cmd)
        with (out/(label+'.log')).open('x') as stream:
            child=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT,timeout=limit,pass_fds=(9,))
        return child.returncode,(out/(label+'.log')).read_text()
    try:
        for flat,mutant in ((True,False),(False,False),(True,True)):
            label=('mutant' if mutant else 'positive')+f'-lut{int(flat)}';folder=out/label;folder.mkdir()
            macros=[d for d in defs if flat or d!='VEN_L1D_TAG_LUTRAM']
            code,pp=run(label+'-preprocess',[REPO/'tools/verilator_serial.sh','-E',
                *['+define+'+d for d in macros],source],30);assert code==0
            changed=candidate
            if mutant:changed=changed.replace('(mc_old_slot && cacheable)','mc_old_slot',1)
            original=source.read_text().replace('module ven_l1d #(','module parent_l1d #(',1).replace('endmodule : ven_l1d','endmodule : parent_l1d',1)
            for name,text in (('ven_l1d.sv',changed),('parent_l1d.sv',original),
                              ('tb_l1d_mem_chain.sv',fixture(previous.original.ports(pp),flat))):
                (folder/name).write_text(text);pins[str(folder/name)]=sha(folder/name)
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-sv',
                '-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                    ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(HERE),*['+define+'+d for d in macros],'--top-module','tb_l1d_mem_chain',
                '--Mdir',folder/'obj','-j','32','--output-split','20000','--output-split-cfuncs','2000',
                *modules,folder/'parent_l1d.sv',folder/'ven_l1d.sv',folder/'tb_l1d_mem_chain.sv']
            rc,log=run(label+'-build',command,180);assert rc==0,(label,log[-3000:])
            binary=folder/'obj/Vtb_l1d_mem_chain'
            rc,log=run(label+'-native',['taskset','-c','12',binary],60)
            if mutant:
                # The half-cycle miter can detect this same wrong ready before
                # the directed stimulus's #1 check. Require that exact signal
                # or the dedicated check, never an arbitrary fatal/timeout.
                assert rc!=0 and ('NEXT-READY-OLD-NC accepted' in log or
                                  'CUT_EQUIV c_next_ready' in log),(label,log[-2000:])
            else:
                assert rc==0 and not re.search(r'%Error|%Fatal|MISMATCH|FAIL',log),(label,log[-2500:])
                for marker in ('L1D-MEM-CHAIN-OK accepted=150','checks=538 fresh=448 same_bank=64 held=1536',
                    'CODE-WORD-REUSE-LEAF-OK checks=51','DATA-UNDER-IFILL-OK checks=659 held_completions=640',
                    'PRIME-UNDER-IFILL-OK checks=661 completions=0','NEXT-READY-DFILL-OK checks=320','NEXT-READY-CACHE-OK'):
                    assert marker in log,(label,marker)
            row=dict(label=label,native_exit=rc,build_exit=0,binary_sha256=sha(binary),
                     definitions=macros,coverage=re.findall(r'^.*(?:-OK|_EQ).*$',log,re.M))
            rows.append(row);print(json.dumps(row),flush=True)
    except Exception as exc:errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    cg=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    events={k:int(v) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines())}
    result=dict(passed=not errors and stable and len(rows)==3 and not any(events[k] for k in ('oom','oom_kill','oom_group_kill')),
        pins=pins,pins_unchanged=stable,rows=rows,errors=errors,memory_events=events,seconds=time.monotonic()-begin,
        memory_peak=int((cg/'memory.peak').read_text()),whole_cache=True,whole_core=False,
        hardware_acceptance=False,standard_suite=False,gameplay_ipc=None)
    save('closed.json',result);print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
