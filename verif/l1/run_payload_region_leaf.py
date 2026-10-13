"""Bounded exact-source cache-map/payload microtest, not full-core acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

import prepare_payload_region_hint as recipe
import run_payload_code_hint_leaf as mux

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def sources(parent):
    before = {name: (parent/name).read_text() for name in recipe.PARENTS}
    after = {name: recipe.transform(text, name) for name, text in before.items()}
    # Retain all actual guarded mux expressions, including bypass and stream.
    original_ports = mux.PORTS
    mux.PORTS = 'input wire c_payload_cacheable,\n' + original_ports
    try:
        control = mux.leaf(before['rtl/mem/ven_l1d.sv'], 'control', True)
        candidate = mux.leaf(after['rtl/mem/ven_l1d.sv'], 'candidate', True)
    finally:
        mux.PORTS = original_ports
    tb = (HERE/'tb_payload_region.sv').read_text()
    seam = before['rtl/mem/ventium_l1_axi.sv']
    begin = seam.index('  always_comb begin\n    core_d_hi =')
    end = seam.index(';', seam.index('  assign core_d_last =', begin)) + 1
    extent = seam[begin:end]
    for old, new in (('core_d_hi','hi'),('core_d_last','last_addr'),
                     ('core_addr','c_addr'),('core_we','c_we'),('core_wstrb','c_wstrb')):
        extent = re.sub(r'\b'+old+r'\b', new, extent)
    tb = tb.replace('  EXTENT_ASSIGNMENTS', extent)
    instances = []
    for index, module in enumerate(('control','candidate')):
        ports = [f'.{name}({wire}[{index}])' for name,wire in (
            ('c_rdata','data'),('c_rdata_hi','high'),('code_access','access_bit'),
            ('rd_match','rd'),('early_match','early'),('code_payload_select','code_sel'),
            ('shadow_payload_select','shadow_sel'),('shadow_high_payload_select','high_sel'))]
        instances.append(module+' u'+str(index)+'('+','.join(ports)+',.*);')
    tb = tb.replace('  INSTANCES','\n'.join(instances))
    return before, after, control, candidate, tb


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args()
    parent=args.parent.resolve(strict=True); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>4*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    before,after,control,candidate,tb=sources(parent)
    cachemap=parent/'rtl/northbridge/ven_cachemap.sv'
    assert sha(cachemap)==recipe.CACHEMAP
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    pins={str(parent/n):sha(parent/n) for n in recipe.PARENTS}
    for path in (Path(__file__),Path(recipe.__file__),Path(mux.__file__),Path(mux.recipe.__file__),
                 HERE/'tb_payload_region.sv',cachemap,REPO/'tools/build_scope.sh',
                 REPO/'tools/verilator_serial.sh',Path(os.environ['VENTIUM_VERILATOR_BIN']),Path('/usr/bin/z3')):
        pins[str(path.resolve())]=sha(path)
    for name,text in after.items():
        path=root/'candidate'/name; path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(text); pins[str(path)]=sha(path)
    save('started.json',dict(pins=pins,invocation=os.environ.get('INVOCATION_ID'),
        scope='exact decoder and mux combinational microtest; not cache FSM or core acceptance'))
    start=time.monotonic(); rows=[]; queries=[]
    result=dict(passed=False,whole_core=False,hardware_acceptance=False,gameplay_ipc=None)
    try:
        # Only address arithmetic is symbolic. Decoder semantics are exercised
        # natively below; do not describe this as a solver proof of the decoder.
        smt='''(set-logic QF_BV)
(declare-fun addr () (_ BitVec 32))
(declare-fun extent () (_ BitVec 2))
(define-fun last () (_ BitVec 32) (bvadd addr ((_ zero_extend 30) extent)))
(define-fun aligned () Bool (= ((_ extract 1 0) addr) #b00))
(define-fun same-region () Bool (= ((_ extract 31 14) addr) ((_ extract 31 14) last)))
'''
        for name,formula,expected in (
            ('aligned','(and aligned (not same-region))','unsat'),
            ('unsafe-unaligned','(and (not aligned) (not same-region))','sat')):
            source=root/(name+'.smt2'); source.write_text(smt+'(assert '+formula+')\n(check-sat)\n')
            done=subprocess.run(['/usr/bin/z3',source],capture_output=True,text=True,timeout=20)
            (root/(name+'.log')).write_text(done.stdout+done.stderr)
            assert done.returncode==0 and done.stdout.strip()==expected and not done.stderr
            queries.append(dict(name=name,result=expected,source_sha256=sha(source),
                                log_sha256=sha(root/(name+'.log'))))
        payload_expr=mux.statement(candidate,'code_payload_access')
        unaligned_expr=payload_expr.replace("(c_addr[1:0] == 2'd0) && ",'')
        assert payload_expr!=unaligned_expr and candidate.count(payload_expr)==1
        variants=[('positive',candidate,tb),
            ('lost-cd',candidate,tb.replace('(first_l1[snapshot] && !cr0_cd);','first_l1[snapshot];')),
            ('lost-alignment',candidate.replace(payload_expr,unaligned_expr),tb)]
        assert len(set(c+t for _,c,t in variants))==3
        for name,variant,bench in variants:
            folder=root/name; folder.mkdir()
            source=folder/'miter.sv'; source.write_text(control+variant+bench)
            command=[str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                '-j','32','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+VEN_L1D_'+d for d in ('PAYLOAD_CODE_HINT','CODE_BUFFER','CODE_WORD_REUSE',
                    'CODE_PAYLOAD_SELECT','RESPONSE_PAYLOAD_SELECT','HIGH_PAYLOAD_SELECT')],
                '--top-module','tb','--Mdir',str(folder/'obj'),'-o','test',str(cachemap),str(source)]
            row=dict(name=name,command=command); rows.append(row)
            with (folder/'build.log').open('x') as log:
                built=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=120)
            row['build_exit']=built.returncode; assert built.returncode==0, name
            with (folder/'run.log').open('x') as log:
                done=subprocess.run([folder/'obj/test'],stdout=log,stderr=subprocess.STDOUT,timeout=40)
            text=(folder/'run.log').read_text(); row['native_exit']=done.returncode
            row['log']=text
            if name=='positive':
                assert done.returncode==0 and 'PAYLOAD-REGION-OK vectors=262144' in text,text
                assert not re.search(r'Error|FATAL|FAIL|MISMATCH',text),text
            else:
                assert done.returncode in (-6,1,134) and 'PAYLOAD-REGION-DATA' in text,text
            row['artifacts']={str(p):sha(p) for p in (source,folder/'build.log',folder/'run.log',folder/'obj/test')}
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)
        result['passed']=True
    except Exception as error:
        result['error']=repr(error)
    result.update(rows=rows,queries=queries,pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  seconds=time.monotonic()-start)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','pins')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
