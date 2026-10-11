#!/usr/bin/env python3
"""Actual full-size old/new L1 instances, including paired-read response state.

Run only after the current native synthesis/timing owners have closed, inside
the shared guarded-32 build scope. Keep the historical store/coherence corpus
and append real same-line read, backpressure and invalidation transactions.
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

import prepare_pair_now_ack_cut as patch
import run_parallel_tag_pairs as pair
from run_parallel_tag_cache import control_source, sha

READ_OUTPUTS = dict(pair_req_ready=2,pair_req_split=2,pair_bank_conflict=1,
    pair_rsp_valid=2,pair_rsp_cancel=2,pair_rsp_owner=32,pair_rsp_paddr=64,
    pair_rsp_data=64,pair_now_valid=1,pair_now_data=32)
PORTS = '''
      .pair_req_valid, .pair_cacheable(2'b11), .pair_paddr, .pair_size_log2,
      .pair_owner, .pair_req_ready, .pair_req_split, .pair_bank_conflict,
      .pair_rsp_valid, .pair_rsp_cancel, .pair_rsp_ready, .pair_rsp_owner,
      .pair_rsp_paddr, .pair_rsp_data,
      .pair_now_req, .pair_now_cacheable, .pair_now_paddr, .pair_now_size_log2,
      .pair_now_valid, .pair_now_data,
'''


def fixture(original, flat, extra):
    # Add ports before deriving the shadow so the common generator connects
    # every output to a separate comparison wire, never to another driver.
    anchor='      .clk, .rst_n, .flush_all(1\'b0), .golden(1\'b0), .cacheable(1\'b1),'
    assert original.count(anchor)==1
    source=original.replace(anchor, PORTS+anchor.replace(".flush_all(1'b0)",'.flush_all(extra_flush)')
                            .replace(".cacheable(1'b1)",'.cacheable(extra_cacheable)'))
    outputs=pair.PAIR_OUTPUTS
    try:
        pair.PAIR_OUTPUTS=outputs | READ_OUTPUTS
        result=pair.fixture(source,flat)
    finally:
        pair.PAIR_OUTPUTS=outputs
    anchor='  ven_l1d #(.L1_SETS(128)) dut ('
    assert result.count(anchor)==1
    result=result.replace(anchor,extra+'\n'+anchor)
    marker='    if (errors == 0) $display("L1D-PAIR-STORE-GATE-OK");'
    assert result.count(marker)==1
    result=result.replace(marker,'    run_pair_now_checks();\n'+marker)
    assert result.count('    $finish;')==1
    result=result.replace('    $finish;',
        '    if (errors != 0) $fatal(1,"PAIR-NOW-CACHE-FAIL");\n    $finish;')
    # In addition to the reused all-array miter, compare the real leaf's
    # independently held response identity/data, not just visible valid bits.
    checks='''
  always @(posedge clk or negedge clk) begin
    #2;
'''
    for name in ('pair_lookup_active','pair_bank_ready','pair_now_valid',
                 'pair_now_data','window_valid_q','rd_window_q','rd_full_line_q',
                 'u_pair_return.valid_q','u_pair_return.owner_q',
                 'u_pair_return.addr_q','u_pair_return.data_q'):
        checks+=f'    if (dut.{name} !== control.{name}) $fatal(1,"PAIR-NOW-CACHE-MISMATCH {name}");\n'
    checks+='''`ifdef VEN_L1D_TWO_WINDOW_REUSE
    if ({dut.shadow_valid_q,dut.shadow_line_addr_q,dut.shadow_line_q} !==
        {control.shadow_valid_q,control.shadow_line_addr_q,control.shadow_line_q})
      $fatal(1,"PAIR-NOW-CACHE-MISMATCH shadow owner/data");
`endif
  end
'''
    assert result.count('\nendmodule')==1
    return result.replace('\nendmodule',checks+'\nendmodule')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('source','leaf','out'):
        ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args()
    repo=Path(__file__).resolve().parents[2]
    source=args.source.resolve(strict=True); leaf=args.leaf.resolve(strict=True)
    root=args.out.resolve(); scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=repo.stat().st_dev
    assert shutil.disk_usage(scratch).free>5*1024**3
    subprocess.run([repo/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    assert os.environ.get('INVOCATION_ID')
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    proof=json.loads((leaf/'closed.json').read_text())
    assert proof['passed'] and proof['pins_unchanged'] and len(proof['rows'])==13
    pins=dict(proof['pins'])
    for row in proof['rows']:
        folder=leaf/row['label']
        assert sha(folder/'tb.sv')==row['source_sha256']
        assert sha(folder/'a.out')==row['binary_sha256']
        assert (folder/'run.log').read_text().strip()==row['log']
        pins.update({str(p):sha(p) for p in (folder/'tb.sv',folder/'a.out',folder/'run.log')})
    old=source.read_text(); changed=patch.transform(old)
    assert changed==(leaf/'ven_l1d.sv').read_text()
    tb_source=Path(__file__).with_name('tb_l1d_pair_store.sv')
    extra=Path(__file__).with_name('tb_l1d_pair_now_extra.svh')
    modules=[source.with_name(name) for name in ('ven_p54_bank_arb.sv','ven_p54_hit_return.sv')]
    for p in (Path(__file__),Path(patch.__file__),Path(pair.__file__),
              Path(__file__).with_name('run_parallel_tag_cache.py'),tb_source,extra,
              source,leaf/'closed.json',leaf/'ven_l1d.sv',*modules):
        pins[str(p)]=sha(p)
    assert all(sha(p)==v for p,v in pins.items())
    root.mkdir()
    def save(name,value):
        with (root/name).open('x') as f: json.dump(value,f,indent=2)
    (root/'control_l1d.sv').write_text(control_source(old))
    pins[str(root/'control_l1d.sv')]=sha(root/'control_l1d.sv')
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
                            affinity=sorted(os.sched_getaffinity(0))))
    result=dict(passed=False,rows=[],errors=[],whole_core=False,standard_suite=False,
                gameplay_ipc=None,fmax_mhz=None)
    started=time.monotonic()
    try:
        for label,flat,shadow,mutant in (
                ('ff-primary',False,False,False),('lut-primary-shadow',True,True,False),
                ('wrong-unowned',True,True,True)):
            assert shutil.disk_usage(root).free>4*1024**3
            folder=root/label; folder.mkdir()
            sv=changed
            if mutant:
                expr=patch.extract(sv)
                sv=sv.replace(expr,expr.replace('(window_reuse || shadow_reuse)',"1'b1"))
            (folder/'ven_l1d.sv').write_text(sv)
            tb=folder/'tb_l1d_pair_store.sv'
            tb.write_text(fixture(tb_source.read_text(),flat,extra.read_text()))
            pins.update({str(p):sha(p) for p in (tb,folder/'ven_l1d.sv')})
            flags=pair.FLAGS+['VEN_P54_DUAL_HIT','VEN_P54_DUAL_HIT_LEGACY_CAPTURE',
                'VEN_P54_DUAL_LOAD_PAIR','VEN_P54_DUAL_BYTE_LOAD_PAIR',
                'VEN_L1D_WINDOW_REUSE','VEN_L1D_WINDOW_KEEP_STORE']
            if flat: flags+=['VEN_L1D_TAG_LUTRAM']
            if shadow: flags+=['VEN_L1D_TWO_WINDOW_REUSE','VEN_L1D_TWO_WINDOW_KEEP_STORE']
            command=[str(repo/'tools/verilator_serial.sh'),'--binary','--assert','-sv',
                '--top-module','tb_l1d_pair_store','--Mdir',str(folder/'obj'),'-j','32',
                '--output-split','20000','--output-split-cfuncs','2000',
                '-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+w for w in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')]]
            command += ['+define+'+d for d in flags]
            command += [str(p) for p in modules]+[str(root/'control_l1d.sv'),str(folder/'ven_l1d.sv'),str(tb)]
            row=dict(label=label,mutant=mutant,definitions=flags,command=command)
            result['rows'].append(row)
            with (folder/'build.log').open('x') as f:
                child=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=240)
            row['build_exit']=child.returncode
            assert child.returncode==0,label
            binary=folder/'obj/Vtb_l1d_pair_store'
            with (folder/'run.log').open('x') as f:
                child=subprocess.run([binary],stdout=f,stderr=subprocess.STDOUT,timeout=30)
            log=(folder/'run.log').read_text()
            row.update(native_exit=child.returncode,binary_sha256=sha(binary),
                       log_sha256=sha(folder/'run.log'),build_log_sha256=sha(folder/'build.log'))
            if mutant:
                assert child.returncode!=0 and ('PAIR-NOW' in log or 'MISMATCH' in log),label
            else:
                assert child.returncode==0 and 'L1D-PAIR-STORE-GATE-OK' in log,label
                assert not re.search(r'FAIL|%Error|%Fatal|MISMATCH',log),label
                m=re.search(r'PAIR-NOW-CACHE-CHECKS checks=(\d+) returns=(\d+) held=(\d+)',log)
                assert m and int(m[1])>=12 and int(m[2])>=4 and int(m[3])==3,label
                row.update(checks=int(m[1]),returns=int(m[2]),held=int(m[3]))
            save(label+'/closed.json',row)
            print(json.dumps({k:v for k,v in row.items() if k!='command'}),flush=True)
        result['passed']=True
    except BaseException as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-started,pins=pins,
                  pins_unchanged=all(sha(p)==v for p,v in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
