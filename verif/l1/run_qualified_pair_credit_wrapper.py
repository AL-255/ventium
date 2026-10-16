"""Port-driven tests of the exact parent/candidate no-L2 integration wrapper."""
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

HERE=Path(__file__).resolve().parent
REPO=HERE.parent.parent


def fixture():
    old=(HERE/'tb_l1axi_pair_hit.sv').read_text()
    text=old[:old.index('  task automatic step;')]
    text=recipe.once(text,'module tb_l1axi_pair_hit;','module tb_qualified_pair_wrapper;')
    text=recipe.once(text,'  always #5 clk = !clk;',
        '  always #5 clk = !clk;\n  logic axi_only_reset=0, allow_ar=1;')
    text=recipe.once(text,'ventium_l1_axi #(.ADDR_W(40), .REMAP_BASE(REMAP_BASE)',
        'ventium_l1_axi #(.ADDR_W(40), .LINE_REPLAY(0), .REMAP_BASE(REMAP_BASE)')
    text=recipe.once(text,'.axi_rst_n(rst_n)', '.axi_rst_n(rst_n && !axi_only_reset)')
    text=recipe.once(text,'.m_axi_arready(arready)', '.m_axi_arready(arready && allow_ar)')
    text=recipe.once(text,'.RD_LAT(2)', '.RD_LAT(2), .WR_LAT(14), .BUBBLE(1)')
    text=recipe.once(text,'.clk, .rst_n, .ar_count, .burst_beats,',
        '.clk, .rst_n(rst_n && !axi_only_reset), .ar_count, .burst_beats,')
    text=recipe.once(text,'.arid, .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,',
        '.arid, .araddr, .arlen, .arsize, .arburst, .arvalid(arvalid && allow_ar), .arready,')
    text=recipe.once(text,'      .core_clk(clk),', '''      .core_payload_code(core_code),
      .core_store_update_mask(4'hf), .core_store_pair_update_mask(4'hf),
      .core_store_pair_intent(store_pair_req),
      .core_read_ack(), .core_rdata_hi(), .core_rdata_hi_valid(), .core_rdata_hi_uncontended(),
      .core_next_req(1'b0), .core_next_commit(1'b0), .core_next_addr(32'd0),
      .core_next_wstrb(4'd0), .core_next_ready(),
      .core_pair_now_req(1'b0), .core_pair_now_paddr(32'd0), .core_pair_now_size_log2(2'd0),
      .core_pair_now_valid(), .core_pair_now_data(),
      .dbg_rd_valid(), .dbg_rd_addr(), .dbg_rd_data(),
      .core_clk(clk),''')
    return text+'  `include "qualified_pair_credit_wrapper.svh"\nendmodule\n'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','proof','out'):ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    parent,proof,out=args.parent.resolve(strict=True),args.proof.resolve(strict=True),args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev!=REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert out.is_relative_to(scratch) and not out.exists()
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    proven=json.loads((proof/'closed.json').read_text())
    assert proven['passed'] and proven['pins_unchanged'] and proven['native_exit']==0
    pins=dict(proven['pins']);pins.update(proven['artifacts'])
    assert all(sha(path)==value for path,value in pins.items())
    mem=parent/'ventium/rtl/mem'
    changed=recipe.transform({name:(mem/name).read_text() for name in recipe.PINS})
    manifest=parent/'input-manifest.json'
    hardware=json.loads(manifest.read_text())['hardware_defines']
    assert len(hardware)==159 and hardware.count('SYNTHESIS')==1
    defines=[flag for flag in hardware if flag!='SYNTHESIS']+['AXI_BFM_MON']
    out.mkdir()
    def save(name,value):
        with (out/name).open('x') as f:json.dump(value,f,indent=2)
    generated={name:text for name,text in changed.items() if name!='ven_l1d.sv'}
    generated.update({Path(__file__).name:Path(__file__).read_text(),
        'tb_qualified_pair_wrapper.sv':fixture(),
        'qualified_pair_credit_wrapper.svh':(HERE/'qualified_pair_credit_wrapper.svh').read_text()})
    for name,text in generated.items():
        with (out/name).open('x') as f:f.write(text)
    modules=[mem/name for name in ('ven_cdc_afifo.sv','ven_reset_sync.sv','ven_axi_cdc.sv',
        'ven_p54_bank_arb.sv','ven_p54_hit_return.sv','ven_l1d.sv')]
    modules += [parent/'ventium/rtl/northbridge/ven_cachemap.sv',HERE/'axi_slave_bfm.sv']
    for path in (Path(__file__).resolve(),HERE/'run_parallel_tag_cache.py',manifest,
                 proof/'closed.json',HERE/'tb_l1axi_pair_hit.sv',HERE/'qualified_pair_credit_wrapper.svh',
                 *modules,*(out/name for name in generated)):
        pins[str(path)]=sha(path)
    save('started.json',dict(pins=pins,hardware_defines=hardware,defines=defines,
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0))))
    result=dict(passed=False,rows=[],errors=[],whole_core=False,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None,fmax_mhz=None)
    start=time.monotonic()
    try:
        for candidate in (False,True):
            assert shutil.disk_usage(scratch).free>4*1024**3
            folder=out/('candidate' if candidate else 'parent');folder.mkdir()
            source=out if candidate else mem
            command=[str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert','-sv',
                '-j','32','--output-split','20000','--output-split-cfuncs','2000','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                *['+define+'+flag for flag in defines],'-I'+str(out),'--top-module','tb_qualified_pair_wrapper',
                '--Mdir',str(folder/'obj'),'-o','test',*map(str,modules),
                str(source/'ven_axi_master.sv'),str(source/'ventium_l1_axi.sv'),str(out/'tb_qualified_pair_wrapper.sv')]
            row=dict(candidate=candidate,command=command);result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                native=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
            row['build_exit']=native.returncode
            assert native.returncode==0, 'native build failed: '+str(folder)
            with (folder/'run.log').open('x') as f:
                native=subprocess.run(['taskset','-c','8',str(folder/'obj/test')],
                    stdout=f,stderr=subprocess.STDOUT,timeout=30)
            row['native_exit']=native.returncode
            log=(folder/'run.log').read_text();row['log']=log
            row['artifacts']={str(p):sha(p) for p in (folder/'obj/test',folder/'build.log',folder/'run.log')}
            assert native.returncode==0 and 'PAIR-CREDIT-WRAPPER-OK' in log, (folder,log)
            assert not re.search(r'\bFAIL\b|%Fatal|%Error',log), (folder,log)
            row['coverage']=next(line for line in log.splitlines() if line.startswith('PAIR-CREDIT-WRAPPER-OK'))
            row['compiler_archive']=archive_products(folder,'tb_qualified_pair_wrapper')
            save(folder.name+'/closed.json',row)
            print(folder.name,row['coverage'],flush=True)
        assert result['rows'][0]['coverage']==result['rows'][1]['coverage']
        result['passed']=True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-start,pins=pins,
        pins_unchanged=all(sha(path)==value for path,value in pins.items()))
    result['passed'] &= result['pins_unchanged'];save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
