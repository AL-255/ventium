"""Compare the direction derivative using complete L1s, real AXI masters and RAM.

Only an unrequested backing direction hint is exempt from the output miter.
Every AXI signal, active/credit-query direction, cache state and RAM byte is
compared. This is not a CPU, route/SMRAM seam or hardware acceptance test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import time

import prepare_backing_direction as recipe
import run_backing_pair_payload_axi as inherited
from run_backing_direction_leaf import ROOT, HERE, sha

REPO=HERE.parents[1]
FROZEN=ROOT/'v-result-carry-posted-mouse-fpga-r1/ventium/rtl/mem'


def fixture():
    original=(HERE/'tb_l1d_mem_chain.sv').read_text()
    assert hashlib.sha256(original.encode()).hexdigest()=='2edff1bb65af13558df06fd31ea58ae47cc97579dc06de0da2ca574f53854c1b'
    assert original.count('m_pair_ready=0, m_pair_ack=0;')==1
    original=original.replace('m_pair_ready=0, m_pair_ack=0;', 'm_pair_ready=1, m_pair_ack;')
    inherited.miter.BASE_OUTPUTS.update(c_rdata_hi_uncontended=1,c_pair_intent_ready=1)
    text=inherited.fixture(original)
    assert text.count('  logic c_read_ack;')==1
    text=text.replace('  logic c_read_ack;',
        '  logic c_read_ack,c_rdata_hi_uncontended,c_pair_intent_ready;\n'
        '  wire c_pair_intent=c_pair_req;\n'
        '  wire c_payload_cacheable=cacheable;')
    for owner in ('dut','control'):
        old=owner+'.dc_tag[s*2+w]'
        assert text.count(old)==1
        text=text.replace(old,f'(w ? {owner}.dc_tag_way1[s] : {owner}.dc_tag_way0[s])')
    # Address/strobes do not change in this experiment: compare them even idle.
    for n in ('m_addr','m_wstrb'):
        old=f'if ((dut.m_req || (dut.st==dut.L1_IDLE && c_req && !dut.stream_path)) && dut.{n} !== shadow_{n})'
        assert text.count(old)==1
        text=text.replace(old,f'if (dut.{n} !== shadow_{n})')
    old='if (dut.m_we !== shadow_m_we)'
    assert text.count(old)==1
    text=text.replace(old,'if ((dut.m_req || c_req) && dut.m_we !== shadow_m_we)')
    text=text.replace('`include "backing_pair_axi_leaf.svh"','`include "direction_axi_traffic.svh"')
    traffic=(HERE/'backing_pair_axi_leaf.svh').read_text()
    assert traffic.count('if(!c_req && m_pair_ready!=shadow_m_pair_ready)')==1
    traffic=traffic.replace('if(!c_req && m_pair_ready!=shadow_m_pair_ready)',
                            'if(!c_req && m_we!=shadow_m_we)')
    traffic=traffic.replace('idle_credit_changes','idle_direction_changes')
    traffic=traffic.replace('BACKING-AXI-OK','BACKING-DIRECTION-AXI-OK')
    return text,traffic


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    out=ap.parse_args().out.absolute()
    assert __debug__ and out.parent.resolve()==ROOT and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    assert os.sched_getaffinity(0)==set(range(32))
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert os.statvfs(ROOT).f_bavail*os.statvfs(ROOT).f_frsize>5*1024**3
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    leaf=ROOT/'backing-direction-leaf-r1'
    checked=json.loads((leaf/'closed.json').read_text())
    prior=json.loads((leaf/'started.json').read_text())
    assert checked['passed'] and checked['pins_unchanged'] and len(checked['rows'])==7
    pins=dict(prior['pins'])
    for row in checked['rows']: pins.update(row['artifacts'])
    source=FROZEN/'ven_l1d.sv'; old=source.read_text(); new=recipe.transform(old)
    assert new==(leaf/'ven_l1d.sv').read_text()
    assert sha(leaf/'ven_l1d.sv')==checked['derivative_sha256']
    master=FROZEN/'ven_axi_master.sv'; assert sha(master)==inherited.MASTER_SHA
    build=ROOT/'v-result-carry-core-r1/build-started.json'
    definitions=json.loads(build.read_text())['definitions']
    assert len(definitions)==len(set(definitions))==153
    assert not {'SYNTHESIS','VEN_L1D_COMB_ACK'} & set(definitions)
    assert 'VEN_L1D_TAG_LUTRAM' in definitions
    assert {'VEN_P54_LOAD_STORE_PAIR','VEN_P54_WBUF_QUAD_COMBINE',
            'VEN_P54_WBUF_ADMIT_DISPATCH'} <= set(definitions)
    modules=[FROZEN/n for n in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    inputs=[source,master,*modules,build,leaf/'started.json',leaf/'closed.json',leaf/'ven_l1d.sv',
        Path(__file__),Path(recipe.__file__),Path(inherited.__file__),Path(inherited.miter.__file__),
        HERE/'run_backing_direction_leaf.py',HERE/'prepare_backing_payload_mux.py',
        HERE/'prepare_backing_pair_payload.py',HERE/'tb_l1d_mem_chain.sv',
        HERE/'backing_pair_axi_leaf.svh',HERE/'axi_slave_bfm.sv',
        REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh']
    pins.update({str(p.resolve()):sha(p) for p in inputs})
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir(); tb,traffic=fixture()
    shutil.copyfile(Path(__file__),out/'driver_at_run.py')
    pins[str(out/'driver_at_run.py')]=sha(out/'driver_at_run.py')
    def put(name,text):
        path=out/name
        with path.open('x') as f:f.write(text)
        pins[str(path)]=sha(path)
        return path
    control=put('control_l1d.sv',inherited.miter.control_source(old))
    bench=put('tb_l1d_mem_chain.sv',tb)
    put('direction_axi_traffic.svh',traffic)
    def save(name,value):
        with (out/name).open('x') as f:json.dump(value,f,indent=2)
    save('started.json',dict(pins=pins,definitions=definitions,invocation=os.environ['INVOCATION_ID']))
    begin=time.monotonic(); rows=[]; errors=[]
    group=Path('/sys/fs/cgroup'+Path('/proc/self/cgroup').read_text().strip().split('::')[1])
    try:
        for mode in ('positive','fill-write-negative'):
            folder=out/mode; folder.mkdir()
            text=new if mode=='positive' else new.replace(
                "    m_we = 1'b0;", "    m_we = (st == L1_FILL);",1)
            sv=put(mode+'/ven_l1d.sv',text)
            command=[str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                '-j','32','-Wall','-Wno-UNUSED','-Wno-fatal',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-I'+str(out),'--top-module','tb_l1d_mem_chain','--Mdir',str(folder/'obj'),'-o','test',
                *['+define+'+d for d in definitions],*map(str,modules),str(master),
                str(HERE/'axi_slave_bfm.sv'),str(control),str(sv),str(bench)]
            with (folder/'build.log').open('x') as f:
                compiled=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,pass_fds=(9,),timeout=180)
            assert compiled.returncode==0,(mode,'compile failed')
            with (folder/'native.log').open('x') as f:
                child=subprocess.Popen(['taskset','-c','12',str(folder/'obj/test')],stdout=f,stderr=subprocess.STDOUT)
                os.sched_setaffinity(child.pid,{12})
                assert os.sched_getaffinity(child.pid)=={12}
                try: code=child.wait(timeout=40)
                except BaseException: child.kill();child.wait();raise
            log=(folder/'native.log').read_text()
            good=code==0 and 'BACKING-DIRECTION-AXI-OK' in log if mode=='positive' else (
                code in (1,-6,134) and any(x in log for x in
                    ('BACKING-DIRECTION:','BACKING-AXI-MISMATCH','PARALLEL-CACHE-MISMATCH')))
            rows.append(dict(mode=mode,passed=good,native_exit=code,build_exit=compiled.returncode,
                command=command,affinity=[12],artifacts={str(p):sha(p) for p in
                    (sv,folder/'obj/test',folder/'build.log',folder/'native.log')}))
            assert good,(mode,log[-2000:])
    except Exception as exc: errors.append(repr(exc))
    stable=all(sha(p)==h for p,h in pins.items())
    events={k:int(v) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines())}
    result=dict(passed=not errors and len(rows)==2 and stable and not any(events[k] for k in
        ('oom','oom_kill','oom_group_kill')),rows=rows,errors=errors,pins=pins,pins_unchanged=stable,
        seconds=time.monotonic()-begin,memory_events=events,memory_peak=int((group/'memory.peak').read_text()),
        full_l1=True,real_axi_master=True,route_smram_seam=False,whole_core=False,
        physical_fpga=False,gameplay_ipc=None,fmax_mhz=None)
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
