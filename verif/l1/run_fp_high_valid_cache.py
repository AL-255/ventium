"""Full-profile, full-size L1 A/B validity/state/data miter using public traffic."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time
import traceback

import prepare_fp_high_valid_cofactor as recipe
import run_parallel_tag_cache as miter
from test_fp_high_valid_cofactor import sha

REPO=Path(__file__).resolve().parents[2]
MODEL='66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'
FIXTURE_SHA='83d4be64d0eac1c5dacdebca2d0ef8f814c000baa24cc0c2dd66485a63c8f2be'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('parent','fixture','proof','out'): ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args()
    parent, fixture, proof=[getattr(args,k).resolve(strict=True) for k in ('parent','fixture','proof')]
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    load=lambda p:json.loads(p.read_text())
    prior=load(parent/'build-started.json'); built=load(parent/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    proven=load(proof/'closed.json'); assert proven['passed'] and proven['pins_unchanged']
    assert all(sha(p)==h for p,h in proven['pins'].items())
    assert len(proven['rows'])==11
    assert sha(fixture)==FIXTURE_SHA
    source=parent/'candidate/rtl/mem/ven_l1d.sv'
    original=source.read_text(); changed=recipe.transform(original,'rtl/mem/ven_l1d.sv')
    flags=next(s.split('=',1)[1].split() for s in prior['command'] if s.startswith('VL_EXTRA_DEFINES='))
    defines=[s for s in flags if s.startswith('+define+')]
    assert len(defines)==152 and '+define+VEN_FP_LOAD_EARLY_CMD' in defines
    assert '+define+VEN_L1D_PAYLOAD_CODE_HINT' in defines and '+define+VEN_L1D_HIT_STREAM' not in defines
    tb=fixture.read_text()
    anchor='  ven_l1d dut(.*);'
    assert tb.count(anchor)==1
    tb=tb.replace(anchor,'  logic c_read_ack;\n  wire c_payload_code=c_code;\n'+anchor)
    # Observe every enabled interface response, both-edge architectural cache
    # state and every bank/tag/valid/LRU entry. No hierarchical writes.
    miter.BASE_OUTPUTS.update(c_read_ack=1,c_pair_ready=1,c_pair_ack=1,
        m_pair_req=1,m_pair_addr=32,m_pair_wdata=32,m_pair_wstrb=4,
        pair_req_ready=2,pair_req_split=2,pair_bank_conflict=1,
        pair_rsp_valid=2,pair_rsp_cancel=2,pair_rsp_owner=32,
        pair_rsp_paddr=64,pair_rsp_data=64,pair_now_valid=1,pair_now_data=32)
    tb=miter.miter_fixture(tb,False,True)
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    control=root/'control_l1d.sv'; control.write_text(miter.control_source(original))
    bench=root/'tb_l1d_mem_chain.sv'; bench.write_text(tb)
    here=Path(__file__).resolve().parent
    modules=[parent/'candidate/rtl/mem'/name for name in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    pins=dict(proven['pins'])
    for path in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),Path(miter.__file__).resolve(),
                 source,fixture,bench,control,proof/'closed.json',parent/'build-started.json',
                 parent/'build-closed.json',*modules,
                 *(here/n for n in ('high_window_payload_leaf.svh','response_payload_leaf.svh',
                                   'window_write_update_leaf.svh','store_window_warm_leaf.svh'))):
        pins[str(path)]=sha(path)
    for row in proven['rows']:
        for suffix,key in (('.smt2','query_sha256'),('.log','log_sha256')):
            path=proof/(row['name']+suffix); assert sha(path)==row[key]; pins[str(path)]=row[key]
    save('started.json',dict(pins=pins,defines=defines,invocation=os.environ['INVOCATION_ID']))
    started=time.monotonic(); result=dict(passed=False,rows=[],errors=[],whole_core=False,
        gameplay_ipc=None,fmax_mhz=None,standard_suite=False,hardware_acceptance=False)
    try:
        for mutant in (False,True):
            folder=root/('lost-next-owner' if mutant else 'positive'); folder.mkdir()
            sv=folder/'ven_l1d.sv'
            sv.write_text(changed.replace('&& !(c_next_req && rd_match)',"&& 1'b1") if mutant else changed)
            command=[str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                '-j','32','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(here),'--top-module','tb_l1d_mem_chain','--Mdir',str(folder/'obj'),'-o','test',
                *defines,*map(str,modules),str(control),str(sv),str(bench)]
            row=dict(mutant=mutant,command=command); result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                native=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
            row['build_exit']=native.returncode; assert native.returncode==0
            with (folder/'run.log').open('x') as f:
                native=subprocess.run([folder/'obj/test','+OBS='+str(folder/'cycles.txt')],
                    stdout=f,stderr=subprocess.STDOUT,timeout=40)
            log=(folder/'run.log').read_text(); row['native_exit']=native.returncode
            if mutant:
                assert native.returncode in (1,-6,134) and ('FP-HIGH-VALID:' in log or 'PARALLEL-CACHE-MISMATCH' in log), log
            else:
                assert native.returncode==0 and not re.search(r'%Error|%Fatal|FATAL|FAIL|MISMATCH',log),log
                for marker in ('L1D-MEM-CHAIN-OK accepted=150','WINDOW-WRITE-UPDATE-OK',
                               'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK'):
                    assert marker in log, marker
                row['coverage']=re.findall(r'(?:HIGH-WINDOW-PAYLOAD-OK|PARALLEL-CACHE-MITER).*',log)
                assert len(row['coverage'])==2
            row['artifacts']={str(p):sha(p) for p in (sv,folder/'obj/test',folder/'run.log',
                                                      folder/'build.log',folder/'cycles.txt')}
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)
        result['passed']=True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(pins=pins,pins_unchanged=all(sha(p)==h for p,h in pins.items()),seconds=time.monotonic()-started)
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
