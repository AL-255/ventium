"""Existing AXI fault/reset fixtures on exact parent and qualified master.

Non-pair fixtures tie the optional pair inputs inactive; all other stimulus
and checks are unchanged. Quad fixtures keep their original pair traffic.
No production sources or canonical gate scripts are edited. Compilation is
guarded and closed generated objects are losslessly archived, not discarded.
"""
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

import prepare_qualified_pair_credit as recipe
from run_parallel_tag_cache import archive_products, sha

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CASES = (
    ('id', 'tb_axi_id_contain', ('VEN_AXI_FAULT_INJECT',), 'AXI-ID-CONTAIN-GATE-OK'),
    ('rdata_id', 'tb_axi_rdata_id_contain', ('VEN_AXI_FAULT_INJECT',), 'AXI-RDATA-ID-CONTAIN-GATE-OK'),
    ('orphan_b', 'tb_axi_orphan_b_contain', ('VEN_AXI_FAULT_INJECT','VEN_AXI_B_ORPHAN_INJECT'), 'AXI-ORPHAN-B-CONTAIN-GATE-OK'),
    ('rresp', 'tb_axi_rresp_contain', ('VEN_AXI_RESP_FAULT_INJECT',), 'AXI-RRESP-CONTAIN-GATE-OK'),
    ('bresp', 'tb_axi_bresp_contain', ('VEN_AXI_RESP_FAULT_INJECT',), 'AXI-BRESP-CONTAIN-GATE-OK'),
    ('narrow_replay', 'tb_axi_narrow_replay', (), 'AXI-NARROW-REPLAY-GATE-OK'),
    ('quad', 'tb_axi_quad_pair', (), 'AXI-QUAD-PAIR-GATE-OK'),
    ('quad_error', 'tb_axi_quad_pair', ('VEN_AXI_QUAD_BRESP_ERROR','VEN_AXI_RESP_FAULT_INJECT'), 'AXI-QUAD-PAIR-ERROR-GATE-OK'),
    ('quad_split', 'tb_axi_quad_pair', ('VEN_AXI_QUAD_SPLIT_TEST',), 'AXI-QUAD-SPLIT-GATE-OK'),
)


def fixture(source, candidate):
    instances = source.count('ven_axi_master #(')
    assert instances > 0 and source.count('.core_clk(') == instances
    if candidate:
        source = source.replace('ven_axi_master #(',
            "ven_axi_master #(.PAIR_REQ_CREDIT_QUALIFIED(1'b1),")
    ports = '.dbg_rd_valid(), .dbg_rd_addr(), .dbg_rd_data(),\n      '
    if '.m_pair_req' not in source:
        ports += ".m_pair_req(1'b0), .m_pair_addr(32'd0), .m_pair_wdata(32'd0),\n"
        ports += "      .m_pair_wstrb(4'd0), .m_pair_ready(), .m_pair_ack(),\n      "
    return source.replace('.core_clk(', ports+'.core_clk(')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent','proof','out'):
        ap.add_argument('--'+name, type=Path, required=True)
    ap.add_argument('--case', action='append', choices=[row[0] for row in CASES],
                    help='explicit subset; receipt retains the selected case list')
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent, proof, out = args.parent.resolve(strict=True), args.proof.resolve(strict=True), args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert out.is_relative_to(scratch) and not out.exists()
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], pass_fds=(9,), check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    receipt=json.loads((proof/'closed.json').read_text())
    assert receipt['passed'] and receipt['pins_unchanged'] and receipt['native_exit']==0
    pins=dict(receipt['pins']); pins.update(receipt['artifacts'])
    assert all(sha(path)==value for path,value in pins.items())
    mem=parent/'ventium/rtl/mem'
    originals={name:(mem/name).read_text() for name in recipe.PINS}
    changed=recipe.transform(originals)
    manifest=parent/'input-manifest.json'
    hardware=json.loads(manifest.read_text())['hardware_defines']
    assert len(hardware)==159 and hardware.count('SYNTHESIS')==1
    defines=[flag for flag in hardware if flag!='SYNTHESIS']
    out.mkdir()
    def save(name,value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2)
    with (out/'ven_axi_master.sv').open('x') as f: f.write(changed['ven_axi_master.sv'])
    with (out/Path(__file__).name).open('x') as f: f.write(Path(__file__).read_text())
    for path in (Path(__file__).resolve(),out/Path(__file__).name,out/'ven_axi_master.sv',
                 manifest,proof/'closed.json',HERE/'run_parallel_tag_cache.py',
                 *(HERE/(top+'.sv') for _,top,_,_ in CASES)):
        pins[str(path)]=sha(path)
    selected=[row for row in CASES if args.case is None or row[0] in args.case]
    save('started.json',dict(pins=pins,hardware_defines=hardware,defines=defines,
        selected_cases=[row[0] for row in selected],
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    result=dict(passed=False,rows=[],errors=[],whole_core=False,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    start=time.monotonic()
    try:
        for label,top,extra,marker in selected:
            for candidate in (False,True):
                assert shutil.disk_usage(scratch).free>4*1024**3
                folder=out/(label+('-candidate' if candidate else '-parent')); folder.mkdir()
                bench=folder/(top+'.sv')
                # A raw held, uncredited split pair is the generic interface
                # regression, not a legal qualified producer. Keep default 0.
                qualified=candidate and label!='quad_split'
                with bench.open('x') as f: f.write(fixture((HERE/(top+'.sv')).read_text(),qualified))
                source=out/'ven_axi_master.sv' if candidate else mem/'ven_axi_master.sv'
                command=[str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                    '-j','32','--output-split','20000','--output-split-cfuncs','2000','-Wall','-Wno-UNUSED','-Wno-fatal',
                    *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                    *['+define+'+flag for flag in (*defines,*extra)],'--top-module',top,
                    '--Mdir',str(folder/'obj'),'-o','test',str(source),str(bench)]
                row=dict(label=label,candidate=candidate,qualified=qualified,command=command,extra_defines=extra)
                result['rows'].append(row)
                with (folder/'build.log').open('x') as f:
                    native=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                        env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
                row['build_exit']=native.returncode
                assert native.returncode==0, 'build failed: '+str(folder)
                with (folder/'run.log').open('x') as f:
                    native=subprocess.run(['taskset','-c','8',str(folder/'obj/test')],
                        stdout=f,stderr=subprocess.STDOUT,timeout=30)
                row['native_exit']=native.returncode
                log=(folder/'run.log').read_text();row['log']=log
                row['artifacts']={str(p):sha(p) for p in (bench,folder/'obj/test',folder/'build.log',folder/'run.log')}
                assert native.returncode==0 and marker in log, (folder,log)
                assert not re.search(r'\bFAIL\b|%Fatal|%Error',log), (folder,log)
                row['compiler_archive']=archive_products(folder,top)
                save(folder.name+'/closed.json',row)
                print(folder.name,marker,flush=True)
        result['passed']=True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins=pins,
        pins_unchanged=all(sha(path)==value for path,value in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
